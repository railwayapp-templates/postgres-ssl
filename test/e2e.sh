#!/usr/bin/env bash
# test/e2e.sh — end-to-end test harness for the pgBackRest archive + PITR flow.
#
# Spins up a local MinIO bucket, builds the postgres-ssl-pitr image for a
# single PG version (default 17, override with PG_VERSION=18 etc.), and
# walks every assertion in the PR test plan in sequence. Each assertion is
# a `t_*` function; failure aborts the run and dumps the relevant container
# logs. Final exit code is the count of failed tests.
#
# Run: ./test/e2e.sh
# Or:  PG_VERSION=18 ./test/e2e.sh
# Or:  ./test/e2e.sh t_vanilla_boot t_pitr_happy_path   # subset
#
# Designed for a single-host docker daemon. Tests share a docker network
# (pgssl-test-net) and a MinIO instance; volumes are scoped per test. The
# bucket is wiped between tests that need a clean archive state.

set -uo pipefail

PG_VERSION="${PG_VERSION:-17}"
IMAGE="postgres-ssl-pitr:${PG_VERSION}"
NET="pgssl-test-net"
MINIO="minio-test"
MINIO_USER="minioadmin"
MINIO_PASS="minioadmin123"
BUCKET="pgbackrest"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKERFILE="${REPO_ROOT}/Dockerfile.${PG_VERSION}"

# Major-upgrade re-anchor tests: $PG_VERSION is the TARGET major (so they use
# the suite's own $IMAGE for the upgraded side) and one major below is the
# source. Those tests use the Railway data layout — PGDATA a subdirectory of
# the volume — because upgrade-job.sh refuses a PGDATA that IS the volume root
# (--link needs a sibling directory on the same filesystem). Every other test
# in this file leaves PGDATA at the image default, which is the volume root.
UPG_FROM_VERSION="${UPG_FROM_VERSION:-$((PG_VERSION - 1))}"
UPG_FROM_IMAGE="postgres-ssl-pitr:${UPG_FROM_VERSION}"
UPG_JOB_IMAGE="postgres-upgrade-e2e:${UPG_FROM_VERSION}-${PG_VERSION}"
PGDATA_IN_VOLUME="/var/lib/postgresql/data/pgdata"
UPGRADE_MARKER_IN_VOLUME="/var/lib/postgresql/data/.railway-major-upgrade.json"

PASS=0
FAIL=0
FAILED_TESTS=()

# ----- color / log helpers ---------------------------------------------------
if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; N=""
fi
log()  { echo "${B}==>${N} $*"; }
ok()   { echo "${G}PASS${N} $*"; PASS=$((PASS+1)); }
ko()   { echo "${R}FAIL${N} $*"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); }
note() { echo "  ${Y}note:${N} $*"; }

# Capture failure detail; called from `assert_*` helpers.
fail_dump() {
  local label="$1"; shift
  echo "${R}--- failure detail (${label}) ---${N}" >&2
  for c in "$@"; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${c}$"; then
      local cstate
      cstate=$(docker inspect -f 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' "$c" 2>/dev/null)
      echo "${R}--- docker logs ${c} ($cstate) (last 60) ---${N}" >&2
      docker logs --tail 60 "$c" 2>&1 | sed 's/^/    /' >&2
    else
      echo "${R}--- container ${c} not found in 'docker ps -a' (already removed?) ---${N}" >&2
    fi
  done
}

# ----- assertion helpers -----------------------------------------------------
assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  if [ "$actual" = "$expected" ]; then return 0; fi
  echo "  expected: $expected"
  echo "  actual:   $actual"
  echo "  msg:      $msg"
  return 1
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then return 0; fi
  echo "  expected to contain: $needle"
  echo "  actual:              $haystack"
  echo "  msg:                 $msg"
  return 1
}

assert_file_absent() {
  local container="$1" path="$2" msg="$3"
  if docker exec "$container" test ! -e "$path"; then return 0; fi
  echo "  expected absent: $path"
  echo "  msg:             $msg"
  return 1
}

assert_file_present() {
  local container="$1" path="$2" msg="$3"
  if docker exec "$container" test -e "$path"; then return 0; fi
  echo "  expected present: $path"
  echo "  msg:              $msg"
  return 1
}

# ----- environment management ------------------------------------------------
ensure_image() {
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "image $IMAGE already built"
    return
  fi
  log "building $IMAGE from $DOCKERFILE"
  docker build -q -f "$DOCKERFILE" -t "$IMAGE" "$REPO_ROOT" >/dev/null
}

# Rebuild $IMAGE unconditionally. ensure_image above skips the build when the
# tag already exists, which silently tests a stale copy of wrapper.sh /
# pgbackrest-init.sh / the watcher — those are COPY'd in, so the tag says
# nothing about which version of them the image holds. Tests that assert on
# entrypoint behavior call this instead. Docker's layer cache keeps the repeat
# cheap: only the COPY layers re-run.
rebuild_image() {
  log "rebuilding $IMAGE from $DOCKERFILE"
  docker build -q -f "$DOCKERFILE" -t "$IMAGE" "$REPO_ROOT" >/dev/null
}

# Images for the major-upgrade re-anchor tests: the source major's runtime image
# and the dual-binary job image, plus the rebuild above. Always builds, for the
# same reason — upgrade-job.sh is COPY'd into the job image.
ensure_upgrade_images() {
  rebuild_image || return 1
  log "building $UPG_FROM_IMAGE (upgrade source major)"
  docker build -q -f "${REPO_ROOT}/Dockerfile.${UPG_FROM_VERSION}" \
    -t "$UPG_FROM_IMAGE" "$REPO_ROOT" >/dev/null || return 1
  log "building $UPG_JOB_IMAGE"
  docker build -q -f "${REPO_ROOT}/Dockerfile.upgrade" \
    --build-arg "FROM_VERSION=${UPG_FROM_VERSION}" \
    --build-arg "TO_VERSION=${PG_VERSION}" \
    -t "$UPG_JOB_IMAGE" "$REPO_ROOT" >/dev/null || return 1
}

ensure_network() {
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
}

ensure_minio() {
  if docker ps --format '{{.Names}}' | grep -q "^${MINIO}$"; then
    return
  fi
  log "starting MinIO"
  docker rm -f "$MINIO" >/dev/null 2>&1 || true
  docker volume rm minio-test-data >/dev/null 2>&1 || true
  docker volume create minio-test-data >/dev/null
  docker run -d --name "$MINIO" --network "$NET" \
    -e "MINIO_ROOT_USER=$MINIO_USER" \
    -e "MINIO_ROOT_PASSWORD=$MINIO_PASS" \
    -v minio-test-data:/data \
    quay.io/minio/minio:latest server /data >/dev/null
  # wait for ready
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if docker run --rm --network "$NET" --entrypoint /bin/sh quay.io/minio/mc:latest -c \
       "mc alias set local http://${MINIO}:9000 ${MINIO_USER} ${MINIO_PASS}" >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  echo "MinIO failed to come up" >&2
  exit 1
}

mc() {
  docker run --rm --network "$NET" --entrypoint /bin/sh quay.io/minio/mc:latest -c "
    mc alias set local http://${MINIO}:9000 ${MINIO_USER} ${MINIO_PASS} >/dev/null
    $*
  "
}

reset_bucket() {
  mc "mc rm -r --force local/${BUCKET} >/dev/null 2>&1; mc mb -p local/${BUCKET} >/dev/null"
}

# Run a one-off pgbackrest restore into a target volume. Bypasses the
# wrapper, simulating an externally-staged volume that the wrapper later
# boots into. --recovery-option pins the restore_command in postgresql.auto.conf
# to the recovery conf the wrapper re-renders on every boot — without that,
# archive-get during recovery would fall back to env vars that no longer
# exist (the wrapper stopped exporting PGBACKREST_REPO*_*).
#
# Caller's container sets WAL_RECOVER_FROM_* + POSTGRES_RECOVERY_TARGET_TIME,
# and configure_pgbackrest_recovery writes conf.d/pgbackrest-recovery.conf
# with the recovery_target params plus its own restore_command. Postgres
# loads conf.d before auto.conf, so auto.conf's restore_command wins — both
# are equivalent (--config=...recovery-source.conf), so they can coexist
# without conflict.
pgbackrest_restore_into() {
  local vol="$1" path="${2:-/pgbackrest}"
  docker run --rm --network "$NET" \
    -e "PGBACKREST_REPO1_S3_BUCKET=$BUCKET" \
    -e "PGBACKREST_REPO1_S3_ENDPOINT=http://${MINIO}:9000" \
    -e "PGBACKREST_REPO1_S3_REGION=us-east-1" \
    -e "PGBACKREST_REPO1_S3_KEY=$MINIO_USER" \
    -e "PGBACKREST_REPO1_S3_KEY_SECRET=$MINIO_PASS" \
    -e "PGBACKREST_REPO1_S3_URI_STYLE=path" \
    -e "PGBACKREST_REPO1_PATH=$path" \
    -e "PGBACKREST_REPO1_TYPE=s3" \
    -v "$vol:/var/lib/postgresql/data" \
    --entrypoint /bin/bash \
    "$IMAGE" \
    -c 'set -e
chown -R postgres:postgres /var/lib/postgresql/data
chmod 0700 /var/lib/postgresql/data
gosu postgres pgbackrest --stanza=main --pg1-path=/var/lib/postgresql/data \
  --recovery-option=restore_command="pgbackrest --config=/etc/pgbackrest/pgbackrest-recovery-source.conf --stanza=main archive-get %f %p" \
  restore' \
    >/dev/null 2>&1
}

# Common runner for an archiving service. All test containers carry the
# postgres-ssl-e2e=1 label so the trap can find and clean them up.
#
# Defaults to the suite's own $IMAGE. Prefix a call with
# `ARCHIVING_PG_IMAGE=<image>` to boot a different major against the same
# bucket — the major-upgrade re-anchor tests need both sides of a version pair.
# A prefix assignment on a bash function call is scoped to that call, so the
# override cannot leak into later ones.
run_archiving_pg() {
  local name="$1" vol="$2"; shift 2
  docker run -d --name "$name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e "POSTGRES_PASSWORD=test" \
    -e "WAL_ARCHIVE_BUCKET=$BUCKET" \
    -e "WAL_ARCHIVE_ENDPOINT=http://${MINIO}:9000" \
    -e "WAL_ARCHIVE_REGION=us-east-1" \
    -e "WAL_ARCHIVE_KEY=$MINIO_USER" \
    -e "WAL_ARCHIVE_SECRET=$MINIO_PASS" \
    -e "WAL_ARCHIVE_PATH=/pgbackrest" \
    -e "PGBACKREST_REPO1_S3_URI_STYLE=path" \
    "$@" \
    -v "$vol:/var/lib/postgresql/data" \
    "${ARCHIVING_PG_IMAGE:-$IMAGE}" >/dev/null
}

# Wait for postgres to accept connections. 120 s default — restored
# clusters need pgbackrest's archive-get to fetch + apply each WAL segment
# during recovery, which adds tens of seconds under suite-load (multiple
# concurrent docker-execs, MinIO contending for I/O). 60 s was the original
# vanilla-boot ceiling and was tight even there; the bump is harmless for
# fast paths (returns as soon as pg_isready succeeds) and load-bearing for
# restore + recovery paths.
wait_for_pg() {
  local container="$1" deadline=$(($(date +%s) + 120))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker exec "$container" pg_isready -U postgres -q 2>/dev/null; then
      return 0
    fi
    # Bail early if the container has exited — no point polling a dead
    # postmaster, and we want the test to fail-fast with an actionable
    # log dump rather than burning the whole timeout.
    local status
    status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "")
    if [ "$status" = "exited" ]; then
      return 1
    fi
    sleep 1
  done
  return 1
}

# Wait for the cluster to finish recovery and promote (i.e.
# pg_is_in_recovery() returns 'f'). pg_isready / wait_for_pg returns true
# during archive recovery — postgres accepts read-only connections before
# the promote completes — which can let restart-mid-flight tests rip the
# container before recovery flushes recovery.signal. Use this helper after
# wait_for_pg in tests that depend on the cluster being fully promoted
# (e.g. a second boot must NOT re-stage recovery).
wait_for_promoted() {
  local container="$1" deadline=$(($(date +%s) + 120))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local in_rec
    in_rec=$(docker exec "$container" psql -U postgres -At -c "SELECT pg_is_in_recovery()" 2>/dev/null || echo "?")
    [ "$in_rec" = "f" ] && return 0
    sleep 1
  done
  return 1
}

# Poll `docker logs` for a pattern rather than checking once. Guards against
# a real (if narrow) race: a container can flip to State.Status=exited a
# beat before the docker log driver has drained its last buffered stdout,
# so a single grep taken right after detecting "exited" can miss a line
# that's actually there — a moment later fail_dump's own `docker logs` call
# on the same container sees it fine. Tests that assert on a log message
# following an expected-exit should use this instead of a one-shot grep.
wait_for_log_line() {
  local container="$1" pattern="$2" timeout="${3:-10}"
  local deadline=$(($(date +%s) + timeout))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    docker logs "$container" 2>&1 | grep -q -- "$pattern" && return 0
    sleep 0.5
  done
  return 1
}

cleanup_test_resources() {
  [ "${E2E_KEEP_CONTAINERS:-0}" = "1" ] && return 0
  docker rm -f $(docker ps -aq --filter "label=postgres-ssl-e2e=1") 2>/dev/null >/dev/null || true
  for v in $(docker volume ls -q --filter "label=postgres-ssl-e2e=1" 2>/dev/null); do
    docker volume rm "$v" >/dev/null 2>&1 || true
  done
}

# Spawn a per-test container with a tag so cleanup can find it.
spawn() {
  local name="$1" vol="$2"; shift 2
  docker run -d --name "$name" --label postgres-ssl-e2e=1 --network "$NET" "$@" "$IMAGE" >/dev/null
}

new_volume() {
  local name="$1"
  # Stop anything holding the volume, then remove + recreate so the test
  # gets a guaranteed empty mount (a previous failed run could have left a
  # populated volume of the same name, and `docker volume create` is a
  # no-op on an existing volume).
  for c in $(docker ps -aq --filter "volume=$name" 2>/dev/null); do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  docker volume rm "$name" >/dev/null 2>&1 || true
  docker volume create --label postgres-ssl-e2e=1 "$name" >/dev/null
  # Sanity check: the freshly-minted volume must be empty. If something
  # races, fail loudly rather than silently testing on populated state.
  local contents
  contents=$(docker run --rm -v "$name:/v" alpine sh -c 'ls -A /v' 2>/dev/null)
  if [ -n "$contents" ]; then
    echo "${R}new_volume: $name is not empty after recreate (contents: $contents)${N}" >&2
    exit 1
  fi
}

# ----- tests -----------------------------------------------------------------

t_vanilla_boot() {
  local name=t-vanilla-${PG_VERSION}
  local vol=${name}-vol
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -v "$vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$name" || { ko t_vanilla_boot "postgres did not start"; fail_dump t_vanilla_boot "$name"; return; }

  local archive_mode
  archive_mode=$(docker exec "$name" psql -U postgres -At -c "SHOW archive_mode")
  assert_eq "$archive_mode" "off" "archive_mode should be off when WAL_ARCHIVE_BUCKET unset" || { ko t_vanilla_boot ""; fail_dump t_vanilla_boot "$name"; return; }

  if docker exec "$name" test -d /var/lib/postgresql/data/conf.d; then
    ko t_vanilla_boot "conf.d/ should not exist"; return
  fi
  if docker exec "$name" test -d /var/lib/postgresql/data/pgbackrest-spool; then
    ko t_vanilla_boot "pgbackrest-spool/ should not exist"; return
  fi
  ok t_vanilla_boot
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

t_collation_refresh_no_permission_error() {
  # Regression: fork_collation_refresh's mktemp ran as root (mode 0600,
  # root-owned) while the gosu postgres psql call read it as the postgres
  # user — a deterministic "Permission denied" on every PG15+ boot. Central
  # Station thread production-postgres-crash-looping-after-b350b460
  # (2026-08-04) reported a crash loop on a service that hit this.
  local name=t-collation-${PG_VERSION}
  local vol=${name}-vol
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -v "$vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$name" || { ko t_collation_refresh_no_permission_error "postgres did not start"; fail_dump t_collation_refresh_no_permission_error "$name"; return; }

  # fork_collation_refresh's pg_isready poll succeeds on its first 2s tick
  # since postgres is already up; give psql a few seconds to run and its
  # output to flush before reading logs.
  sleep 5
  local logs
  logs=$(docker logs "$name" 2>&1)
  if echo "$logs" | grep -q "collation-refresh:.*Permission denied"; then
    ko t_collation_refresh_no_permission_error "collation-refresh temp file was not readable by postgres"
    fail_dump t_collation_refresh_no_permission_error "$name"
    return
  fi
  ok t_collation_refresh_no_permission_error
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

t_invalid_bucket_skips_archive() {
  # Sets WAL_ARCHIVE_BUCKET to junk shapes the upstream resolver might leak
  # (unresolved Railway template ref + bucket-id UUID). The image guard must
  # refuse to enable archiving rather than writing the junk into
  # pgbackrest.conf and letting pgbackrest hard-fail every archive_command
  # until pgbackrest-archive-push-wrapper.sh's WAL_DROP_THRESHOLD_MB drops WAL.
  for bad in '${{121ccc45-0912-457e-8dc0-76625fe644bb.BUCKET}}' '121ccc45-0912-457e-8dc0-76625fe644bb'; do
    local name=t-badbucket-${PG_VERSION}
    local vol=${name}-vol
    new_volume "$vol"
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --label postgres-ssl-e2e=1 --network "$NET" \
      -e POSTGRES_PASSWORD=test \
      -e "WAL_ARCHIVE_BUCKET=${bad}" \
      -e "WAL_ARCHIVE_ENDPOINT=http://${MINIO}:9000" \
      -e "WAL_ARCHIVE_REGION=us-east-1" \
      -e "WAL_ARCHIVE_KEY=$MINIO_USER" \
      -e "WAL_ARCHIVE_SECRET=$MINIO_PASS" \
      -v "$vol:/var/lib/postgresql/data" \
      "$IMAGE" >/dev/null
    wait_for_pg "$name" || { ko t_invalid_bucket_skips_archive "postgres did not start with bucket=${bad}"; fail_dump t_invalid_bucket_skips_archive "$name"; return; }

    local archive_mode
    archive_mode=$(docker exec "$name" psql -U postgres -At -c "SHOW archive_mode")
    assert_eq "$archive_mode" "off" "archive_mode should be off for invalid bucket (${bad})" || { ko t_invalid_bucket_skips_archive ""; fail_dump t_invalid_bucket_skips_archive "$name"; return; }

    # The junk must NOT have landed in pgbackrest.conf — that's the whole
    # point. clear_pgbackrest_state_if_disabled treats the unset vars as
    # "archiving off" and tears down any stale config.
    if docker exec "$name" test -f /etc/pgbackrest/pgbackrest.conf; then
      ko t_invalid_bucket_skips_archive "pgbackrest.conf should not exist when bucket is invalid"; fail_dump t_invalid_bucket_skips_archive "$name"; return
    fi
    if docker exec "$name" test -f /var/lib/postgresql/data/conf.d/pgbackrest.conf; then
      ko t_invalid_bucket_skips_archive "conf.d/pgbackrest.conf should not exist when bucket is invalid"; fail_dump t_invalid_bucket_skips_archive "$name"; return
    fi

    # Sentinel must be present so the dashboard can distinguish "PITR never
    # enabled" from "PITR enabled but wired to junk." PGDATA in this image is
    # /var/lib/postgresql/data directly (no pgdata sub-path).
    if ! docker exec "$name" test -f /var/lib/postgresql/data/.pgbackrest_invalid_bucket; then
      ko t_invalid_bucket_skips_archive "sentinel .pgbackrest_invalid_bucket missing under PGDATA"; fail_dump t_invalid_bucket_skips_archive "$name"; return
    fi

    # Poll for the validator's guard log line. wait_for_pg returning is
    # sufficient evidence that postgres + the wrapper-side init script
    # have both run (validator fires very early, well before postgres
    # accepts connections), but docker's json-file log driver has been
    # observed to lag the line a few seconds beyond wait_for_pg under
    # suite-load. Without this polling loop, the test is a flake.
    local log_deadline=$(($(date +%s) + 30)) log_hit=0
    while [ "$(date +%s)" -lt "$log_deadline" ]; do
      if docker logs "$name" 2>&1 | grep -q "WAL_ARCHIVE_BUCKET.*looks invalid"; then
        log_hit=1; break
      fi
      sleep 1
    done
    if [ "$log_hit" != "1" ]; then
      ko t_invalid_bucket_skips_archive "expected guard log line missing for bucket=${bad}"; fail_dump t_invalid_bucket_skips_archive "$name"; return
    fi

    docker rm -f "$name" >/dev/null
    docker volume rm "$vol" >/dev/null
  done
  ok t_invalid_bucket_skips_archive
}

t_archiving_boot() {
  local name=t-arch-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true
  run_archiving_pg "$name" "$vol"
  docker container update --label-add postgres-ssl-e2e=1 "$name" >/dev/null 2>&1 || true
  wait_for_pg "$name" || { ko t_archiving_boot "postgres did not start"; fail_dump t_archiving_boot "$name"; return; }

  # Wait up to 15s for stanza-create to complete (it runs in background).
  local deadline=$(($(date +%s) + 15)) found=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker logs "$name" 2>&1 | grep -q "stanza-create completed"; then found=1; break; fi
    sleep 1
  done
  [ "$found" = "1" ] || { ko t_archiving_boot "stanza-create did not complete"; fail_dump t_archiving_boot "$name"; return; }

  local archive_mode archive_command
  archive_mode=$(docker exec "$name" psql -U postgres -At -c "SHOW archive_mode")
  archive_command=$(docker exec "$name" psql -U postgres -At -c "SHOW archive_command")
  assert_eq "$archive_mode" "on" "archive_mode" || { ko t_archiving_boot ""; return; }
  assert_contains "$archive_command" "pgbackrest-archive-push-wrapper.sh" "archive_command points at wrapper" || { ko t_archiving_boot ""; return; }

  # include_dir line must be in postgresql.conf
  if ! docker exec "$name" grep -qE "^include_dir = 'conf.d'" /var/lib/postgresql/data/postgresql.conf; then
    ko t_archiving_boot "include_dir = 'conf.d' missing from postgresql.conf"; return
  fi

  # Force a WAL switch and verify a segment landed in MinIO.
  docker exec "$name" psql -U postgres -c "CREATE TABLE t(id int); INSERT INTO t VALUES (1); SELECT pg_switch_wal();" >/dev/null
  sleep 4
  local wal_count
  # WAL lands under <repo1-path>/archive/main, where repo1-path is now per-
  # cluster (`pgbackrest/cluster-<sysid>/...`). Walking the whole bucket-
  # prefix tree counts segments under any cluster sub-path.
  wal_count=$(mc "mc find local/${BUCKET}/pgbackrest --name '*.zst' 2>/dev/null | wc -l")
  if [ "${wal_count:-0}" -lt 1 ]; then
    ko t_archiving_boot "expected at least 1 WAL segment in bucket, got $wal_count"
    fail_dump t_archiving_boot "$name"
    return
  fi
  ok t_archiving_boot
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

# A service that sets PGHOSTADDR (an app-side pattern equivalent to the
# PGHOST=${{ Postgres.RAILWAY_PRIVATE_DOMAIN }} case above) must not break
# stanza bootstrap: libpq honors PGHOSTADDR even over an explicit -h to the
# local socket, so pgbackrest's stanza-create subshell would otherwise try
# to reach itself over the (bogus, non-local) address instead of falling
# back to the socket. wrapper.sh clears it alongside PGHOST/PGPORT before
# forking those subshells.
t_archiving_boot_survives_pghostaddr() {
  local name=t-arch-pghostaddr-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true
  run_archiving_pg "$name" "$vol" -e "PGHOSTADDR=10.255.255.1"
  docker container update --label-add postgres-ssl-e2e=1 "$name" >/dev/null 2>&1 || true
  # wait_for_pg's own readiness probe (docker exec ... pg_isready, no -h)
  # would ALWAYS fail here regardless of wrapper.sh's own fix, and NOT
  # because of an -h precedence subtlety: verified empirically that
  # PGHOSTADDR overrides even an explicit socket-path -h (pg_isready -h
  # /var/run/postgresql still tries the bogus TCP address and fails) — it
  # unconditionally forces a TCP connection to that address, full stop.
  # This is a test-infrastructure limitation, not the product's: `docker
  # exec` always sees the CONTAINER's declared env (what `docker run -e`
  # set), never whatever wrapper.sh's already-running process later unset
  # in its own memory — an unset inside one process can't retroactively
  # change what a brand-new exec'd process sees, and there is no `-h` value
  # that out-ranks PGHOSTADDR once it's present in that process's own
  # environment. So the check itself must clear it for the exec, same as
  # wrapper.sh clears it for what it forks.
  local deadline=$(($(date +%s) + 120)) ready=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker exec -e PGHOSTADDR= "$name" pg_isready -U postgres -q 2>/dev/null; then
      ready=1
      break
    fi
    sleep 1
  done
  [ "$ready" = "1" ] || { ko t_archiving_boot_survives_pghostaddr "postgres did not start"; fail_dump t_archiving_boot_survives_pghostaddr "$name"; return; }

  # A wider deadline than t_archiving_boot's 15s: stanza-create can hit a
  # transient lock-contention retry (30s backoff, unrelated to PGHOSTADDR —
  # reproduced with the same shape and timing on a plain manual boot) before
  # succeeding.
  local sc_deadline=$(($(date +%s) + 60)) found=0
  while [ "$(date +%s)" -lt "$sc_deadline" ]; do
    if docker logs "$name" 2>&1 | grep -q "stanza-create completed"; then found=1; break; fi
    sleep 1
  done
  [ "$found" = "1" ] || { ko t_archiving_boot_survives_pghostaddr "stanza-create did not complete despite PGHOSTADDR"; fail_dump t_archiving_boot_survives_pghostaddr "$name"; return; }

  ok t_archiving_boot_survives_pghostaddr
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

t_alter_system_survives_restart() {
  local name=t-altersys-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true
  run_archiving_pg "$name" "$vol"
  wait_for_pg "$name" || { ko t_alter_system_survives_restart "no startup"; return; }

  docker exec "$name" psql -U postgres -c "ALTER SYSTEM SET work_mem = '64MB';" >/dev/null
  docker restart "$name" >/dev/null
  wait_for_pg "$name" || { ko t_alter_system_survives_restart "no restart"; return; }

  local work_mem archive_mode
  work_mem=$(docker exec "$name" psql -U postgres -At -c "SHOW work_mem")
  archive_mode=$(docker exec "$name" psql -U postgres -At -c "SHOW archive_mode")
  assert_eq "$work_mem" "64MB" "work_mem from auto.conf" || { ko t_alter_system_survives_restart ""; return; }
  assert_eq "$archive_mode" "on" "archive_mode preserved across ALTER SYSTEM" || { ko t_alter_system_survives_restart ""; return; }

  ok t_alter_system_survives_restart
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

t_s3_unreachable_pg_stays_up() {
  local name=t-s3down-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true
  run_archiving_pg "$name" "$vol" -e "WAL_DROP_THRESHOLD_MB=999999"
  wait_for_pg "$name" || { ko t_s3_unreachable_pg_stays_up "no startup"; return; }
  # wait for stanza-create
  sleep 4

  docker exec "$name" psql -U postgres -c "CREATE TABLE t(id int); INSERT INTO t SELECT g FROM generate_series(1,1000) g; SELECT pg_switch_wal();" >/dev/null
  sleep 3

  log "stopping MinIO to simulate S3 outage"
  docker stop "$MINIO" >/dev/null
  for i in 1 2 3 4; do
    docker exec "$name" psql -U postgres -c "INSERT INTO t SELECT g FROM generate_series(1,100000) g; SELECT pg_switch_wal();" >/dev/null 2>&1
  done

  local alive
  alive=$(docker exec "$name" psql -U postgres -At -c "SELECT 1" 2>/dev/null || echo "DEAD")
  assert_eq "$alive" "1" "postgres alive after S3 outage" || { ko t_s3_unreachable_pg_stays_up ""; docker start "$MINIO" >/dev/null; return; }

  # A fixed sleep here raced the archiver's own retry/backoff on a loaded
  # runner: docker stop returning is not the same instant pgbackrest's
  # archive-push actually observes the connection refusal and reports back to
  # postgres, and that latency is exactly what varies under load. Poll
  # instead of guessing a sleep long enough for the slowest runner.
  local failed_count=0
  local deadline=$(($(date +%s) + 30))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    failed_count=$(docker exec "$name" psql -U postgres -At -c "SELECT failed_count FROM pg_stat_archiver" 2>/dev/null || echo 0)
    [ "$failed_count" -ge 1 ] && break
    sleep 1
  done
  if [ "$failed_count" -lt 1 ]; then
    ko t_s3_unreachable_pg_stays_up "pg_stat_archiver.failed_count should grow under S3 outage; got $failed_count"
    docker start "$MINIO" >/dev/null
    return
  fi

  log "restarting MinIO; archiver should catch up"
  docker start "$MINIO" >/dev/null

  local archived_count=0
  deadline=$(($(date +%s) + 30))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    archived_count=$(docker exec "$name" psql -U postgres -At -c "SELECT archived_count FROM pg_stat_archiver" 2>/dev/null || echo 0)
    [ "$archived_count" -ge 1 ] && break
    sleep 1
  done
  if [ "$archived_count" -lt 1 ]; then
    ko t_s3_unreachable_pg_stays_up "archived_count did not climb after S3 came back; got $archived_count"
    return
  fi

  ok t_s3_unreachable_pg_stays_up
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

t_queue_max_5gib_trips() {
  local name=t-qmax-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"

  # Create a read-only MinIO user so PUTs fail but GETs succeed (info-check
  # passes, async PUTs fail → pg_wal grows, eventually pgBackRest's own
  # archive-push-queue-max=5GiB drops segments).
  mc 'mc admin user add local readonly readonlypass123 >/dev/null 2>&1 || true
      cat > /tmp/p.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject","s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::*"]}]}
EOF
      mc admin policy create local readonly /tmp/p.json >/dev/null 2>&1 || true
      mc admin policy attach local readonly --user readonly >/dev/null 2>&1 || true' >/dev/null

  # Boot once with valid creds so the bucket has archive.info + a baseline
  # `t` table to insert into, then restart with the read-only creds.
  docker rm -f "$name" >/dev/null 2>&1 || true
  run_archiving_pg "$name" "$vol"
  wait_for_pg "$name" || { ko t_queue_max_5gib_trips "initial boot"; return; }
  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c "CREATE TABLE t(id int);" >/dev/null
  docker rm -f "$name" >/dev/null

  # Restart with the read-only creds + a high WAL_DROP_THRESHOLD_MB so only
  # pgBackRest's queue-max can trip. Override archive-push-queue-max via env
  # to a small value so the trip fires deterministically with a few hundred
  # MiB of WAL — pumping 5+ GiB to hit the production default is too long
  # under suite load and tail-of-distribution makes the test flaky.
  docker run -d --name "$name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_ARCHIVE_BUCKET=$BUCKET" \
    -e "WAL_ARCHIVE_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_ARCHIVE_REGION=us-east-1 \
    -e WAL_ARCHIVE_KEY=readonly \
    -e WAL_ARCHIVE_SECRET=readonlypass123 \
    -e WAL_ARCHIVE_PATH=/pgbackrest \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e PGBACKREST_ARCHIVE_PUSH_QUEUE_MAX=128MiB \
    -e WAL_DROP_THRESHOLD_MB=999999 \
    -v "$vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$name" || { ko t_queue_max_5gib_trips "ro boot"; return; }

  log "pumping WAL with read-only creds; queue-max=128MiB so trip is fast"
  docker exec "$name" psql -U postgres -c "ALTER TABLE t ADD COLUMN IF NOT EXISTS payload text;" >/dev/null 2>&1
  # ~80 MiB of WAL per iteration. Pump 12 iterations (~960 MiB) to give the
  # async worker plenty of room to fail PUTs and the spool to overflow the
  # 128 MiB cap.
  for i in $(seq 1 12); do
    docker exec "$name" psql -U postgres -c "INSERT INTO t SELECT g, repeat('x', 1000) FROM generate_series($((i*80000)), $(((i+1)*80000))) g; SELECT pg_switch_wal();" >/dev/null 2>&1
  done

  # Wait up to 30s for the trip line to appear — async worker retry/backoff
  # can lag the foreground archive-push, and queue-max is checked by the
  # async worker, not the foreground.
  local deadline=$(($(date +%s) + 30)) dropped=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    dropped=$(docker logs "$name" 2>&1 | grep -cE "dropped WAL file.*archive queue exceeded" || true)
    [ "$dropped" -ge 1 ] && break
    sleep 2
  done
  if [ "$dropped" -lt 1 ]; then
    ko t_queue_max_5gib_trips "expected 'dropped WAL file ... archive queue exceeded' log lines; got $dropped"
    fail_dump t_queue_max_5gib_trips "$name"
    return
  fi

  local alive
  alive=$(docker exec "$name" psql -U postgres -At -c "SELECT 1" 2>/dev/null || echo DEAD)
  assert_eq "$alive" "1" "postgres alive after queue-max trip" || { ko t_queue_max_5gib_trips ""; return; }

  ok t_queue_max_5gib_trips
  note "$dropped 'archive queue exceeded' WAL drops logged at queue-max=128MiB"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

t_wrapper_drop_on_bad_creds() {
  local name=t-wrap-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"

  # Boot with valid creds to set up a clean stanza, then restart with bad
  # secret + low WAL_DROP_THRESHOLD_MB to make the wrapper-side drop
  # observable in a small WAL window.
  docker rm -f "$name" >/dev/null 2>&1 || true
  run_archiving_pg "$name" "$vol"
  wait_for_pg "$name" || { ko t_wrapper_drop_on_bad_creds "init boot"; return; }
  sleep 6
  docker exec "$name" psql -U postgres -c "CREATE TABLE t(id int);" >/dev/null
  docker rm -f "$name" >/dev/null

  docker run -d --name "$name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_ARCHIVE_BUCKET=$BUCKET" \
    -e "WAL_ARCHIVE_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_ARCHIVE_REGION=us-east-1 \
    -e WAL_ARCHIVE_KEY=$MINIO_USER \
    -e "WAL_ARCHIVE_SECRET=DELIBERATELY_BAD_CREDS" \
    -e WAL_ARCHIVE_PATH=/pgbackrest \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e WAL_DROP_THRESHOLD_MB=50 \
    -v "$vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$name" || { ko t_wrapper_drop_on_bad_creds "bad-creds boot"; return; }

  for i in 1 2 3 4 5 6; do
    docker exec "$name" psql -U postgres -c "INSERT INTO t SELECT g FROM generate_series($((i*100000)), $(((i+1)*100000))) g; SELECT pg_switch_wal();" >/dev/null 2>&1
  done
  sleep 3

  local wrap_drops
  wrap_drops=$(docker logs "$name" 2>&1 | grep -c "pgbackrest-wrapper:.*dropping" || true)
  if [ "$wrap_drops" -lt 1 ]; then
    ko t_wrapper_drop_on_bad_creds "expected wrapper drop messages; got $wrap_drops"
    fail_dump t_wrapper_drop_on_bad_creds "$name"
    return
  fi

  # No "invalid option" warnings — that was the rename point.
  local invopt
  invopt=$(docker logs "$name" 2>&1 | grep -c "invalid option 'drop-threshold-mb'" || true)
  if [ "$invopt" -gt 0 ]; then
    ko t_wrapper_drop_on_bad_creds "PGBACKREST_DROP_THRESHOLD_MB still pollutes pgbackrest config (rename not applied)"
    return
  fi

  local alive
  alive=$(docker exec "$name" psql -U postgres -At -c "SELECT 1" 2>/dev/null || echo DEAD)
  assert_eq "$alive" "1" "postgres alive" || { ko t_wrapper_drop_on_bad_creds ""; return; }

  ok t_wrapper_drop_on_bad_creds
  note "$wrap_drops wrapper-side drops; 0 'invalid option' warnings"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

# Helpers used by the PITR happy/sentinel/quoting tests. Leaves a source DB
# running with a backup taken and a captured target time. Caller reads the
# names back from /tmp/pitr-source-${PG_VERSION}.
setup_pitr_source() {
  local name=t-src-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true
  # WAL_HEARTBEAT_DISABLED=1: the source cluster doesn't need to keep
  # emitting heartbeat WAL after the initial setup completes. Without
  # this, the source's watcher emits pg_logical_emit_message every
  # poll-interval, archive_timeout=60 forces a segment switch every
  # minute, and any downstream test that exceeds ~60s between
  # source_count_before/source_count_after captures sees a false
  # "leaked write" because the source cluster's own background
  # archiving advanced the count.
  run_archiving_pg "$name" "$vol" -e "WAL_HEARTBEAT_DISABLED=1"
  wait_for_pg "$name" >&2 || return 1
  # wait for stanza-create
  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  # Wait for the watcher's NEEDS_INITIAL_BACKUP to land BEFORE the manual
  # backup + test inserts. Without this guard, the watcher's full and
  # the manual full race; whichever runs LATER becomes the latest base
  # for pgbackrest restore. If the watcher wins, its backup_end_lsn is
  # AFTER the test's target_time, and recovery FATALs with "requested
  # recovery stop point is before consistent recovery point".
  wait_for_watcher_backup "$name" full 60 >&2 || {
    echo "setup_pitr_source: watcher initial full did not land within 60s" >&2
    return 1
  }
  docker exec "$name" psql -U postgres -c "CREATE TABLE pitrtest(id int, marker text, ts timestamptz default now());" >/dev/null
  # Per-cluster path: read the marker so the manual full goes to the same
  # sub-prefix archive_command is pushing to. Restore-side tests read
  # /tmp/pitr-source-path-${PG_VERSION} to point WAL_RECOVER_FROM_PATH at
  # the source's per-cluster sub-prefix.
  docker exec -u postgres "$name" bash -c '
    if [ -f /var/lib/postgresql/data/.pgbackrest_repo_path ]; then
      export PGBACKREST_REPO1_PATH="$(cat /var/lib/postgresql/data/.pgbackrest_repo_path)"
    else
      export PGBACKREST_REPO1_PATH="$WAL_ARCHIVE_PATH"
    fi
    export PGBACKREST_REPO1_S3_BUCKET="$WAL_ARCHIVE_BUCKET"
    export PGBACKREST_REPO1_S3_KEY="$WAL_ARCHIVE_KEY"
    export PGBACKREST_REPO1_S3_KEY_SECRET="$WAL_ARCHIVE_SECRET"
    export PGBACKREST_REPO1_S3_REGION="$WAL_ARCHIVE_REGION"
    export PGBACKREST_REPO1_S3_ENDPOINT="$WAL_ARCHIVE_ENDPOINT"
    pgbackrest --stanza=main backup --type=full
  ' >/dev/null 2>&1
  local source_path
  source_path=$(docker exec "$name" cat /var/lib/postgresql/data/.pgbackrest_repo_path 2>/dev/null \
    || echo "/pgbackrest")

  # Insert id=1 (before-target), capture target, insert id=2 (post-target),
  # capture the segment id=2's commit lives in, then insert id=3 + force
  # switches.
  #
  # Sleeps are wider than they look: target_time gets `timestamptz(0)`-rounded
  # to the second, and a target captured too close to the manual backup's
  # stop_time can land < backup_stop_lsn's mapped time once postgres rounds.
  # That trips "requested recovery stop point is before consistent recovery
  # point" on restore. 4 s pre-target + 4 s post-target keeps target safely
  # inside the post-backup WAL window even with sub-second jitter.
  docker exec "$name" psql -U postgres -c "INSERT INTO pitrtest(id,marker) VALUES (1,'before');" >/dev/null
  sleep 4
  local target
  target=$(docker exec "$name" psql -U postgres -At -c "SELECT now()::timestamptz(0)")
  sleep 4
  docker exec "$name" psql -U postgres -c "INSERT INTO pitrtest(id,marker) VALUES (2,'after');" >/dev/null

  # Capture the WAL segment id=2's commit lives in BEFORE issuing any
  # switch. Recovery to `target` STOPS when it sees a record dated > target;
  # id=2's commit is the first such record, and its segment must have
  # shipped to the bucket by the time the restore boots. Probing
  # pg_stat_archiver.last_archived_time (wall-clock) is unsound here —
  # an unrelated earlier segment finishing right then advances the wall-
  # clock without proving the target-spanning segment has shipped.
  local id2_segment
  id2_segment=$(docker exec "$name" psql -U postgres -At -c \
    "SELECT pg_walfile_name(pg_current_wal_lsn())")

  docker exec "$name" psql -U postgres -c "INSERT INTO pitrtest(id,marker) VALUES (3,'much-after'); SELECT pg_switch_wal(); SELECT pg_switch_wal();" >/dev/null

  # Wait for last_archived_wal to reach (>=) id2_segment. Segment names
  # are zero-padded hex on a single timeline, so bash string-compare is
  # the right ordering.
  local archive_deadline=$(($(date +%s) + 90)) shipped_id2=0
  while [ "$(date +%s)" -lt "$archive_deadline" ]; do
    local last_archived_wal
    last_archived_wal=$(docker exec "$name" psql -U postgres -At -c \
      "SELECT last_archived_wal FROM pg_stat_archiver" 2>/dev/null || echo "")
    if [ -n "$last_archived_wal" ]; then
      if [ "$last_archived_wal" = "$id2_segment" ] \
         || [ "$last_archived_wal" \> "$id2_segment" ]; then
        shipped_id2=1; break
      fi
    fi
    docker exec "$name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null 2>&1 || true
    sleep 2
  done
  if [ "$shipped_id2" != 1 ]; then
    echo "setup_pitr_source: WARN — segment $id2_segment (id=2 post-target commit) did not ship within 90 s; restore-side tests may FATAL with 'recovery ended before configured recovery target was reached'" >&2
  fi

  echo "$target" > "/tmp/pitr-target-${PG_VERSION}"
  echo "$name $vol" > "/tmp/pitr-source-${PG_VERSION}"
  echo "$source_path" > "/tmp/pitr-source-path-${PG_VERSION}"
}

# Read the source service's per-cluster repo path captured by setup_pitr_source.
# Falls back to /pgbackrest for the legacy single-cluster layout.
pitr_source_path() {
  cat "/tmp/pitr-source-path-${PG_VERSION}" 2>/dev/null || echo "/pgbackrest"
}

t_pitr_happy_path() {
  setup_pitr_source >&2 || { ko "${FUNCNAME[0]}" "setup_pitr_source failed"; return; }
  read -r src_name src_vol < "/tmp/pitr-source-${PG_VERSION}"
  local target; target=$(cat "/tmp/pitr-target-${PG_VERSION}")
  local src_path; src_path=$(pitr_source_path)
  local rest_name=t-rest-${PG_VERSION}
  local rest_vol=${rest_name}-vol
  new_volume "$rest_vol"

  if ! pgbackrest_restore_into "$rest_vol" "$src_path"; then
    ko t_pitr_happy_path "pgbackrest restore failed"; return
  fi
  docker rm -f "$rest_name" >/dev/null 2>&1 || true
  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=$MINIO_USER \
    -e WAL_RECOVER_FROM_SECRET=$MINIO_PASS \
    -e "WAL_RECOVER_FROM_PATH=$src_path" \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e "POSTGRES_RECOVERY_TARGET_TIME=$target" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$rest_name" || { ko t_pitr_happy_path "restored pg did not start"; fail_dump t_pitr_happy_path "$rest_name"; return; }

  local rows
  rows=$(docker exec "$rest_name" psql -U postgres -At -c "SELECT count(*) FROM pitrtest WHERE id IN (2,3)")
  if [ "$rows" -ne 0 ]; then
    ko t_pitr_happy_path "rows after target time should be excluded; got $rows"
    return
  fi
  local before
  before=$(docker exec "$rest_name" psql -U postgres -At -c "SELECT count(*) FROM pitrtest WHERE id=1")
  if [ "$before" -ne 1 ]; then
    ko t_pitr_happy_path "id=1 (before target) should be present; got $before"
    return
  fi

  ok t_pitr_happy_path
  docker rm -f "$src_name" "$rest_name" >/dev/null
  docker volume rm "$src_vol" "$rest_vol" >/dev/null
}

t_pitr_sentinel_blocks_retrigger() {
  # Self-contained: own source, own first-restore, own restart-with-different-
  # target. Previous version inherited /tmp/pitr-restored-${PG_VERSION} from
  # t_pitr_happy_path and silently no-op'd if the file was missing — that
  # phantom-pass is no longer possible (and the runner now ko's anything that
  # exits without recording PASS/FAIL anyway), but rebuilding state in-test
  # also makes this runnable in isolation, in any order.
  setup_pitr_source >&2 \
    || { ko t_pitr_sentinel_blocks_retrigger "setup_pitr_source failed"; return; }
  read -r src_name src_vol < "/tmp/pitr-source-${PG_VERSION}"
  local target; target=$(cat "/tmp/pitr-target-${PG_VERSION}")
  local src_path; src_path=$(pitr_source_path)
  local rest_name=t-sentinel-${PG_VERSION}
  local rest_vol=${rest_name}-vol
  new_volume "$rest_vol"

  if ! pgbackrest_restore_into "$rest_vol" "$src_path"; then
    ko t_pitr_sentinel_blocks_retrigger "pgbackrest restore failed"; return
  fi
  docker rm -f "$rest_name" >/dev/null 2>&1 || true
  # Boot 1: original target, recover + promote, insert a post-promote row.
  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=$MINIO_USER \
    -e WAL_RECOVER_FROM_SECRET=$MINIO_PASS \
    -e "WAL_RECOVER_FROM_PATH=$src_path" \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e "POSTGRES_RECOVERY_TARGET_TIME=$target" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$rest_name" \
    || { ko t_pitr_sentinel_blocks_retrigger "boot 1: restored pg did not start"; fail_dump t_pitr_sentinel_blocks_retrigger "$rest_name"; return; }
  wait_for_promoted "$rest_name" \
    || { ko t_pitr_sentinel_blocks_retrigger "boot 1: did not promote"; fail_dump t_pitr_sentinel_blocks_retrigger "$rest_name"; return; }
  docker exec "$rest_name" psql -U postgres -c "INSERT INTO pitrtest(id,marker) VALUES (100,'post-promote');" >/dev/null \
    || { ko t_pitr_sentinel_blocks_retrigger "post-promote insert failed"; return; }
  docker rm -f "$rest_name" >/dev/null

  # Boot 2: change target to a far-past time. The .pitr_configured /
  # .pgbackrest_restored markers must keep the wrapper from re-staging
  # recovery — replaying again on a promoted timeline would corrupt the
  # cluster. Verify by asserting the post-promote row survives.
  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=$MINIO_USER \
    -e WAL_RECOVER_FROM_SECRET=$MINIO_PASS \
    -e "WAL_RECOVER_FROM_PATH=$src_path" \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e "POSTGRES_RECOVERY_TARGET_TIME=2020-01-01 00:00:00+00" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$rest_name" \
    || { ko t_pitr_sentinel_blocks_retrigger "boot 2: pg did not start"; fail_dump t_pitr_sentinel_blocks_retrigger "$rest_name"; return; }

  # The sentinel marker is written by configure_pgbackrest_recovery's
  # "previous PITR replay completed" branch. Either marker (.pitr_configured
  # or .pgbackrest_restored) is enough to gate retrigger; the older
  # configure_pgbackrest_recovery path uses .pitr_configured.
  if ! docker exec "$rest_name" bash -c 'test -f /var/lib/postgresql/data/.pitr_configured || test -f /var/lib/postgresql/data/.pgbackrest_restored'; then
    ko t_pitr_sentinel_blocks_retrigger "neither .pitr_configured nor .pgbackrest_restored marker present after boot 2"
    fail_dump t_pitr_sentinel_blocks_retrigger "$rest_name"
    return
  fi
  local rows
  rows=$(docker exec "$rest_name" psql -U postgres -At -c "SELECT count(*) FROM pitrtest WHERE id=100")
  if [ "$rows" != "1" ]; then
    ko t_pitr_sentinel_blocks_retrigger "post-promote row should be preserved on restart with different target; got $rows"
    fail_dump t_pitr_sentinel_blocks_retrigger "$rest_name"
    return
  fi

  ok t_pitr_sentinel_blocks_retrigger
  docker rm -f "$rest_name" "$src_name" >/dev/null
  docker volume rm "$rest_vol" "$src_vol" >/dev/null
}

t_empty_volume_restore_refuses_when_no_backup() {
  local name=t-norestore-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true
  # Empty volume + WAL_RECOVER_FROM_* + recovery target against an empty bucket.
  # Under the v2 image-owned-restore design, restore_from_pgbackrest_if_empty_volume
  # is the only path that populates PGDATA — when it can't find a backup, the
  # wrapper must `exit 1` rather than silently degrading to a vanilla initdb,
  # which would mask data loss for an operator who set the wrong recover-from
  # env vars. Pins the loud-refuse guarantee.
  docker run -d --name "$name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=$MINIO_USER \
    -e WAL_RECOVER_FROM_SECRET=$MINIO_PASS \
    -e WAL_RECOVER_FROM_PATH=/pgbackrest \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e "POSTGRES_RECOVERY_TARGET_TIME=2026-01-01 00:00:00+00" \
    -v "$vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null

  # Wait for the container to exit (max 30s — pgbackrest fails fast on
  # missing backup set).
  local deadline=$(($(date +%s) + 30)) status="running"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    status=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
    [ "$status" = "exited" ] && break
    sleep 1
  done
  if [ "$status" != "exited" ]; then
    ko t_empty_volume_restore_refuses_when_no_backup "wrapper should have exited; status=$status"
    fail_dump t_empty_volume_restore_refuses_when_no_backup "$name"
    return
  fi

  local exit_code; exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$name")
  if [ "$exit_code" = "0" ]; then
    ko t_empty_volume_restore_refuses_when_no_backup "wrapper exited 0; expected non-zero refusal"
    return
  fi

  if ! wait_for_log_line "$name" "restore from source bucket failed"; then
    ko t_empty_volume_restore_refuses_when_no_backup "expected 'restore from source bucket failed' in logs"
    fail_dump t_empty_volume_restore_refuses_when_no_backup "$name"
    return
  fi

  # Wrapper must have refused before initdb / configure_pgbackrest_recovery
  # ran — none of these files should exist.
  if docker run --rm -v "$vol:/data" alpine test -f /data/PG_VERSION; then
    ko t_empty_volume_restore_refuses_when_no_backup "PG_VERSION should not exist; initdb must not have run"
    return
  fi
  if docker run --rm -v "$vol:/data" alpine test -f /data/.pitr_staging; then
    ko t_empty_volume_restore_refuses_when_no_backup ".pitr_staging should not exist (recovery never staged)"
    return
  fi
  if docker run --rm -v "$vol:/data" alpine test -f /data/conf.d/pgbackrest-recovery.conf; then
    ko t_empty_volume_restore_refuses_when_no_backup "conf.d/pgbackrest-recovery.conf should not exist"
    return
  fi
  ok t_empty_volume_restore_refuses_when_no_backup
  note "wrapper exit=$exit_code; PGDATA untouched"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

t_recovery_target_apostrophe_escaped() {
  setup_pitr_source >&2 || { ko "${FUNCNAME[0]}" "setup_pitr_source failed"; return; }
  read -r src_name src_vol < "/tmp/pitr-source-${PG_VERSION}"
  local src_path; src_path=$(pitr_source_path)
  local rest_name=t-apos-${PG_VERSION}
  local rest_vol=${rest_name}-vol
  new_volume "$rest_vol"
  pgbackrest_restore_into "$rest_vol" "$src_path"

  # An apostrophe in the target value would, without escaping, terminate
  # the recovery_target_time = '...' string in pgbackrest-recovery.conf
  # and let the rest of the value smuggle a setting. With escaping,
  # postgres simply parses the string and rejects the (now-invalid)
  # timestamp value cleanly.
  local malicious="2099-01-01 00:00:00+00'; archive_command = 'rm -rf /'"
  docker rm -f "$rest_name" >/dev/null 2>&1 || true
  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=$MINIO_USER \
    -e WAL_RECOVER_FROM_SECRET=$MINIO_PASS \
    -e "WAL_RECOVER_FROM_PATH=$src_path" \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e "POSTGRES_RECOVERY_TARGET_TIME=$malicious" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  sleep 6

  # The conf file should:
  #   1. Have the apostrophe doubled ('' inside the value) so the entire
  #      malicious string lives INSIDE the recovery_target_time = '...'
  #      assignment.
  #   2. Never have an archive_command directive at the start of a line —
  #      that would mean the injection escaped the value and registered as
  #      its own setting.
  local recovery_conf
  recovery_conf=$(docker run --rm -v "$rest_vol:/data" alpine cat /data/conf.d/pgbackrest-recovery.conf 2>/dev/null)
  if echo "$recovery_conf" | grep -qE "^archive_command"; then
    ko t_recovery_target_apostrophe_escaped "apostrophe injection produced a top-level archive_command directive"
    echo "  conf: $recovery_conf"
    return
  fi
  if ! echo "$recovery_conf" | grep -q "''; archive_command = ''rm"; then
    ko t_recovery_target_apostrophe_escaped "apostrophe was not doubled (expected ' → '')"
    echo "  conf: $recovery_conf"
    return
  fi
  ok t_recovery_target_apostrophe_escaped
  docker rm -f "$rest_name" "$src_name" >/dev/null
  docker volume rm "$rest_vol" "$src_vol" >/dev/null
}

t_pitr_retry_after_failed_staging() {
  setup_pitr_source >&2 || { ko "${FUNCNAME[0]}" "setup_pitr_source failed"; return; }
  read -r src_name src_vol < "/tmp/pitr-source-${PG_VERSION}"
  local src_path; src_path=$(pitr_source_path)
  local rest_name=t-retry-${PG_VERSION}
  local rest_vol=${rest_name}-vol
  new_volume "$rest_vol"
  pgbackrest_restore_into "$rest_vol" "$src_path"

  # First attempt: target unreachable (in the future).
  docker rm -f "$rest_name" >/dev/null 2>&1 || true
  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=$MINIO_USER \
    -e WAL_RECOVER_FROM_SECRET=$MINIO_PASS \
    -e "WAL_RECOVER_FROM_PATH=$src_path" \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e "POSTGRES_RECOVERY_TARGET_TIME=2099-01-01 00:00:00+00" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  sleep 8

  # Container should be exited with .pitr_staging present, no .pitr_configured.
  local status
  status=$(docker inspect -f '{{.State.Status}}' "$rest_name")
  assert_eq "$status" "exited" "first attempt should fail" || { ko t_pitr_retry_after_failed_staging "first attempt didn't fail as expected"; return; }

  # Second attempt: corrected target.
  local target; target=$(cat "/tmp/pitr-target-${PG_VERSION}")
  docker rm -f "$rest_name" >/dev/null
  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=$MINIO_USER \
    -e WAL_RECOVER_FROM_SECRET=$MINIO_PASS \
    -e "WAL_RECOVER_FROM_PATH=$src_path" \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e "POSTGRES_RECOVERY_TARGET_TIME=$target" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null

  # Poll for the staging log instead of `sleep 6 + single grep`. The fixed
  # sleep was racy on slow CI runners — `docker run -d` returns when the
  # container is created, not when it starts, and wrapper.sh runs cert
  # checks + conf rendering + state-dir wiring before reaching
  # configure_pgbackrest_recovery. On busy hosts the staging log can land
  # 8+ seconds after `docker run` returns, past the old fixed sleep.
  local deadline=$(($(date +%s) + 30)) found=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker logs "$rest_name" 2>&1 | grep -q "PITR replay staged (target=$target)"; then
      found=1; break
    fi
    sleep 2
  done
  if [ "$found" != "1" ]; then
    ko t_pitr_retry_after_failed_staging "second attempt did not re-stage with new target within 30s"
    fail_dump t_pitr_retry_after_failed_staging "$rest_name"
    return
  fi
  ok t_pitr_retry_after_failed_staging
  docker rm -f "$rest_name" "$src_name" >/dev/null
  docker volume rm "$rest_vol" "$src_vol" >/dev/null
}

t_disable_cleanup() {
  local name=t-disable-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true
  run_archiving_pg "$name" "$vol"
  wait_for_pg "$name" || { ko t_disable_cleanup "init"; return; }
  sleep 6

  # Drop a user file in conf.d/ to verify it's preserved.
  docker exec -u postgres "$name" bash -c "echo '# user' > /var/lib/postgresql/data/conf.d/user.conf"
  docker rm -f "$name" >/dev/null

  # Restart with NO WAL_ARCHIVE_*.
  docker run -d --name "$name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -v "$vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$name" || { ko t_disable_cleanup "restart"; return; }
  sleep 2

  if docker exec "$name" test -f /var/lib/postgresql/data/conf.d/pgbackrest.conf; then
    ko t_disable_cleanup "conf.d/pgbackrest.conf should be removed"; return
  fi
  if ! docker exec "$name" test -f /var/lib/postgresql/data/conf.d/user.conf; then
    ko t_disable_cleanup "user file removed (should be preserved)"; return
  fi
  if docker exec "$name" test -d /var/lib/postgresql/data/pgbackrest-spool; then
    ko t_disable_cleanup "pgbackrest-spool/ should be removed"; return
  fi
  if docker exec "$name" test -f /etc/pgbackrest/pgbackrest.conf; then
    ko t_disable_cleanup "/etc/pgbackrest/pgbackrest.conf should be removed"; return
  fi
  # Watcher state files are scoped to a particular archive bucket — disabling
  # archiving must clear them so a future re-enable starts from
  # NEEDS_INITIAL_BACKUP and not a stale "last full was X" cache.
  if docker exec "$name" test -f /var/lib/postgresql/data/.pgbackrest_backup_state; then
    ko t_disable_cleanup ".pgbackrest_backup_state should be removed when archiving is disabled"; return
  fi
  if docker exec "$name" test -f /var/lib/postgresql/data/.pgbackrest_gap_pending; then
    ko t_disable_cleanup ".pgbackrest_gap_pending should be removed when archiving is disabled"; return
  fi
  local mode
  mode=$(docker exec "$name" psql -U postgres -At -c "SHOW archive_mode")
  assert_eq "$mode" "off" "archive_mode should revert to off" || { ko t_disable_cleanup ""; return; }
  ok t_disable_cleanup
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

# ----- watcher / image-owned base backup tests -------------------------------
#
# These cover the watcher daemon (pgbackrest-backup-watcher.sh) added in the
# image-owned-base-backups change set: NEEDS_INITIAL_BACKUP, gap-recovery
# triggered by .pgbackrest_gap_pending, periodic full + diff cadence,
# empty-volume restore from S3, retention-driven expire, and the dual-repo
# guard. Tests pass WAL_BACKUP_POLL_INTERVAL_SECONDS=5 and
# WAL_BACKUP_GAP_RECOVERY_BACKOFF_SECONDS=10 so the watcher's decision loop
# turns over fast enough for second-scale assertions.
#
# Standby-branch coverage (HA replica exits early via pg_is_in_recovery) is
# intentionally out of scope: this single-host harness has no replication
# topology. The is_standby() function is small + black-box-tested via the
# postgres-ha repo's e2e once HA backups land.

# Count backups by type using `pgbackrest info` text output. The text format
# emits one indented `<type> backup: ...` line per backup, where <type> is
# full|diff|incr — easy to grep without pulling in jq or python (neither is in
# the postgres-ssl image).
count_backups_of_type() {
  local container="$1" want_type="$2"
  docker exec -u postgres "$container" bash -c "
    export PGBACKREST_REPO1_S3_BUCKET=\"\$WAL_ARCHIVE_BUCKET\"
    export PGBACKREST_REPO1_S3_KEY=\"\$WAL_ARCHIVE_KEY\"
    export PGBACKREST_REPO1_S3_KEY_SECRET=\"\$WAL_ARCHIVE_SECRET\"
    export PGBACKREST_REPO1_S3_REGION=\"\$WAL_ARCHIVE_REGION\"
    export PGBACKREST_REPO1_S3_ENDPOINT=\"\$WAL_ARCHIVE_ENDPOINT\"
    if [ -f /var/lib/postgresql/data/.pgbackrest_repo_path ]; then
      export PGBACKREST_REPO1_PATH=\"\$(cat /var/lib/postgresql/data/.pgbackrest_repo_path)\"
    else
      export PGBACKREST_REPO1_PATH=\"\${WAL_ARCHIVE_PATH:-/pgbackrest}\"
    fi
    pgbackrest --stanza=main info 2>/dev/null | grep -cE '^[[:space:]]+${want_type} backup: ' || true
  " 2>/dev/null | tail -1
}

# Boot an archiving service tuned for fast watcher iteration.
run_archiving_pg_fast_watcher() {
  local name="$1" vol="$2"; shift 2
  run_archiving_pg "$name" "$vol" \
    -e "WAL_BACKUP_POLL_INTERVAL_SECONDS=5" \
    -e "WAL_BACKUP_GAP_RECOVERY_BACKOFF_SECONDS=10" \
    "$@"
}

# Wait for the watcher to log a successful backup of the given type, with a
# deadline (default 60s). Returns 0 on hit, 1 on timeout.
wait_for_watcher_backup() {
  local container="$1" want_type="$2" deadline_secs="${3:-60}"
  local deadline=$(($(date +%s) + deadline_secs))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker logs "$container" 2>&1 | grep -q "pgbackrest-watcher: backup --type=${want_type} completed"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# Count backups of a type in an EXPLICIT repo path, rather than in whatever the
# container's marker currently points at (count_backups_of_type). Two things
# need this: asserting a previous cluster's prefix still holds its backups after
# archiving moved off it, and probing at all from a container whose PGDATA is
# not the volume root. This is the same per-call PGBACKREST_REPO1_PATH override
# mono's usePitrHistories uses to enumerate a bucket's histories.
count_backups_at_path() {
  local container="$1" want_type="$2" path="$3"
  docker exec -u postgres "$container" bash -c "
    export PGBACKREST_REPO1_S3_BUCKET=\"\$WAL_ARCHIVE_BUCKET\"
    export PGBACKREST_REPO1_S3_KEY=\"\$WAL_ARCHIVE_KEY\"
    export PGBACKREST_REPO1_S3_KEY_SECRET=\"\$WAL_ARCHIVE_SECRET\"
    export PGBACKREST_REPO1_S3_REGION=\"\$WAL_ARCHIVE_REGION\"
    export PGBACKREST_REPO1_S3_ENDPOINT=\"\$WAL_ARCHIVE_ENDPOINT\"
    export PGBACKREST_REPO1_PATH=\"$path\"
    pgbackrest --stanza=main info 2>/dev/null | grep -cE '^[[:space:]]+${want_type} backup: ' || true
  " 2>/dev/null | tail -1
}

# Objects under a repo path (a leading-slash path concatenates onto the bucket).
# Used as the "the previous cluster's prefix was not touched" measurement.
bucket_objects_under() {
  mc "mc ls --recursive local/${BUCKET}${1} 2>/dev/null | wc -l" | tail -1 | tr -d ' '
}

# The cluster's live system_identifier, read from pg_control rather than from
# the repo-path marker — the assertions have to compare the marker against an
# independently-derived identity, not against itself.
cluster_sysid() {
  local container="$1" pgdata="${2:-/var/lib/postgresql/data}"
  docker exec "$container" pg_controldata "$pgdata" 2>/dev/null \
    | awk -F: '/Database system identifier/ { gsub(/[ \t]/,"",$2); print $2 }'
}

# Shut postgres down through pg_ctl so pg_control records "shut down", then drop
# the container. `docker rm -f` alone is not clean on this image — bash as PID 1
# never forwards the signal, so postgres is SIGKILLed and the cluster is left
# "in production" (upgrade-job.sh recovers from that, but a test asserting the
# archive path should not also be exercising crash recovery).
stop_pg_clean() {
  local name="$1" pgdata="${2:-/var/lib/postgresql/data}"
  docker exec "$name" gosu postgres pg_ctl -D "$pgdata" -w -t 60 -m fast stop >/dev/null 2>&1 || true
  docker rm -f "$name" >/dev/null 2>&1 || true
}

# Run the one-shot upgrade job against a volume. No network: the job never
# touches S3. Sets JOB_OUT / JOB_RC like test/e2e-upgrade.sh's run_job.
run_upgrade_job() {
  local vol="$1" mode="${2:-upgrade}"
  JOB_OUT=$(docker run --rm --label postgres-ssl-e2e=1 \
    -e "PGDATA=$PGDATA_IN_VOLUME" \
    -v "$vol:/var/lib/postgresql/data" \
    "$UPG_JOB_IMAGE" "$mode" 2>&1)
  JOB_RC=$?
}

# Run a shell snippet against a stopped volume (planting or reading state
# between two containers' lifetimes). Uses the job image because it is the one
# image guaranteed to exist for both majors in the pair.
in_stopped_volume() {
  local vol="$1" snippet="$2"
  docker run --rm --label postgres-ssl-e2e=1 \
    -v "$vol:/var/lib/postgresql/data" --entrypoint /bin/sh "$UPG_JOB_IMAGE" -c "$snippet"
}

t_watcher_initial_full() {
  local name=t-init-full-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true
  run_archiving_pg_fast_watcher "$name" "$vol"
  wait_for_pg "$name" || { ko t_watcher_initial_full "no startup"; fail_dump t_watcher_initial_full "$name"; return; }

  # Force a WAL switch so the watcher sees ARCHIVED_COUNT > 0 and trips
  # NEEDS_INITIAL_BACKUP. Without traffic it could sit idle indefinitely.
  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null

  if ! wait_for_watcher_backup "$name" full 60; then
    ko t_watcher_initial_full "watcher did not take an initial full within 60s"
    fail_dump t_watcher_initial_full "$name"
    return
  fi

  # State file should have last_full_at populated.
  if ! docker exec "$name" grep -q "^last_full_at=" /var/lib/postgresql/data/.pgbackrest_backup_state; then
    ko t_watcher_initial_full ".pgbackrest_backup_state missing last_full_at"
    fail_dump t_watcher_initial_full "$name"
    return
  fi

  # `pgbackrest info` should show exactly one full.
  local fulls
  fulls=$(count_backups_of_type "$name" full)
  if [ "$fulls" != "1" ]; then
    ko t_watcher_initial_full "expected 1 full in repo, got $fulls"
    return
  fi
  ok t_watcher_initial_full
  note "initial full landed; .pgbackrest_backup_state populated"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

t_watcher_periodic_full() {
  local name=t-period-full-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true
  run_archiving_pg_fast_watcher "$name" "$vol"
  wait_for_pg "$name" || { ko t_watcher_periodic_full "no startup"; return; }

  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null
  wait_for_watcher_backup "$name" full 60 || { ko t_watcher_periodic_full "no initial full"; return; }

  # Backdate last_full_at to epoch 0 so the periodic check fires on the next
  # poll. Surgical state-file edit (key=value lines, write-replace), no env
  # override needed.
  docker exec -u postgres "$name" bash -c '
    f=/var/lib/postgresql/data/.pgbackrest_backup_state
    grep -v "^last_full_at=" "$f" > "$f.tmp" 2>/dev/null || true
    echo "last_full_at=0" >> "$f.tmp"
    mv "$f.tmp" "$f"
  '

  # Write a sentinel into the log so we can scope grep to the SECOND backup.
  local before_count
  before_count=$(docker logs "$name" 2>&1 | grep -c "backup --type=full completed" || true)

  # Watcher polls every 5s; give it three cycles.
  local deadline=$(($(date +%s) + 30)) hit=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local now_count
    now_count=$(docker logs "$name" 2>&1 | grep -c "backup --type=full completed" || true)
    if [ "$now_count" -gt "$before_count" ]; then hit=1; break; fi
    sleep 2
  done
  if [ "$hit" != "1" ]; then
    ko t_watcher_periodic_full "watcher did not take periodic full after backdating last_full_at"
    fail_dump t_watcher_periodic_full "$name"
    return
  fi

  local fulls
  fulls=$(count_backups_of_type "$name" full)
  if [ "$fulls" != "2" ]; then
    ko t_watcher_periodic_full "expected 2 fulls in repo after periodic, got $fulls"
    return
  fi
  ok t_watcher_periodic_full
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

t_watcher_periodic_diff() {
  local name=t-period-diff-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true
  # Diffs are off by default (WAL_BACKUP_DIFF_INTERVAL_HOURS=0) — block-
  # incremental fulls + daily-full cadence already cover the window. Opt in
  # for the test so we can exercise the diff branch of decide_action().
  run_archiving_pg_fast_watcher "$name" "$vol" -e "WAL_BACKUP_DIFF_INTERVAL_HOURS=24"
  wait_for_pg "$name" || { ko t_watcher_periodic_diff "no startup"; return; }

  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null
  wait_for_watcher_backup "$name" full 60 || { ko t_watcher_periodic_diff "no initial full"; return; }

  # Keep last_full_at fresh, backdate last_diff_at. Watcher should pick
  # `diff` (full not due, diff anchor stale).
  docker exec -u postgres "$name" bash -c '
    f=/var/lib/postgresql/data/.pgbackrest_backup_state
    awk -v now=$(date +%s) "
      BEGIN { seen_full=0; seen_diff=0 }
      /^last_full_at=/ { print \"last_full_at=\" now; seen_full=1; next }
      /^last_diff_at=/ { print \"last_diff_at=0\"; seen_diff=1; next }
      { print }
      END {
        if (!seen_full) print \"last_full_at=\" now
        if (!seen_diff) print \"last_diff_at=0\"
      }
    " "$f" > "$f.tmp"
    mv "$f.tmp" "$f"
  '

  if ! wait_for_watcher_backup "$name" diff 30; then
    ko t_watcher_periodic_diff "watcher did not take diff within 30s"
    fail_dump t_watcher_periodic_diff "$name"
    return
  fi

  local diffs
  diffs=$(count_backups_of_type "$name" diff)
  if [ "$diffs" -lt 1 ]; then
    ko t_watcher_periodic_diff "expected ≥1 diff in repo, got $diffs"
    return
  fi
  # Full count must still be 1 — diff branch must not have promoted to full.
  local fulls
  fulls=$(count_backups_of_type "$name" full)
  if [ "$fulls" != "1" ]; then
    ko t_watcher_periodic_diff "diff branch promoted to full unexpectedly (full count=$fulls)"
    return
  fi
  ok t_watcher_periodic_diff
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

t_watcher_gap_recovery_full() {
  local name=t-gap-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true
  run_archiving_pg_fast_watcher "$name" "$vol"
  wait_for_pg "$name" || { ko t_watcher_gap_recovery_full "no startup"; return; }

  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null
  wait_for_watcher_backup "$name" full 60 || { ko t_watcher_gap_recovery_full "no initial full"; return; }

  local before_diff_count
  before_diff_count=$(docker logs "$name" 2>&1 | grep -c "backup --type=diff completed" || true)

  # Drop the gap marker by hand (simulates a wrapper-touched failure where
  # we want recovery without orchestrating a real archive-push outage).
  # On the next iteration, gap_recovery_step sees the marker, back-fills
  # state with current catalog max, and waits for the catalog to advance.
  docker exec -u postgres "$name" touch /var/lib/postgresql/data/.pgbackrest_gap_pending

  # Force WAL to keep flowing so archive-push runs and the catalog advances
  # past the back-filled detection point. Once advance is observed, the
  # state machine fires a diff backup to anchor a fresh restore point.
  # Loop because a single switch may race the watcher's next iteration —
  # the diff fires the iteration AFTER catalog advance is observed.
  local deadline=$(($(date +%s) + 60)) hit=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    docker exec "$name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null 2>&1
    local logs now_diff_count
    logs=$(docker logs "$name" 2>&1)
    now_diff_count=$(echo "$logs" | grep -c "backup --type=diff completed" || true)
    if [ "$now_diff_count" -gt "$before_diff_count" ] \
       && echo "$logs" | grep -q "cleared by gap-recovery diff"; then
      hit=1; break
    fi
    sleep 3
  done
  if [ "$hit" != "1" ]; then
    ko t_watcher_gap_recovery_full "watcher did not take gap-recovery diff or did not log 'cleared by gap-recovery diff'"
    fail_dump t_watcher_gap_recovery_full "$name"
    return
  fi

  # Marker should be cleared by clear_gap_recovery_state() after the diff.
  if docker exec "$name" test -f /var/lib/postgresql/data/.pgbackrest_gap_pending; then
    ko t_watcher_gap_recovery_full ".pgbackrest_gap_pending was not cleared after gap-recovery diff"
    return
  fi

  ok t_watcher_gap_recovery_full
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

t_dual_repo_archives_to_own_bucket() {
  # End-to-end: a restored fork archives WAL to its OWN bucket post-promote
  # while source's bucket rejects any leaked writes. Pins the dual-repo
  # design (REPO1 = own writable bucket, REPO2 = source read-only) where
  # archive-push in pgBackRest 2.58 fans out to all configured repos — both
  # the read-only creds at the boundary AND wrapper.sh's post-promote
  # repo2-drop have to be in place for the fork to archive cleanly.
  setup_pitr_source >&2 || { ko "${FUNCNAME[0]}" "setup_pitr_source failed"; return; }
  read -r src_name src_vol < "/tmp/pitr-source-${PG_VERSION}"
  local target; target=$(cat "/tmp/pitr-target-${PG_VERSION}")
  local src_path; src_path=$(pitr_source_path)

  # Read-only creds for the fork's WAL_RECOVER_FROM_* — production parallel
  # where the source service hands the fork narrow read-only credentials.
  mc 'mc admin user add local rofork rofork123pass >/dev/null 2>&1 || true
      cat > /tmp/p-rofork.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject","s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::*"]}]}
EOF
      mc admin policy create local rofork /tmp/p-rofork.json >/dev/null 2>&1 || true
      mc admin policy attach local rofork --user rofork >/dev/null 2>&1 || true' >/dev/null

  local fork_bucket=pgbackrest-fork
  mc "mc rm -r --force local/${fork_bucket} >/dev/null 2>&1; mc mb -p local/${fork_bucket} >/dev/null"

  local source_count_before
  source_count_before=$(mc "mc ls --recursive local/${BUCKET} | wc -l" | tail -1 | tr -d ' ')

  local fork_name=t-fork-archive-${PG_VERSION}
  local fork_vol=${fork_name}-vol
  new_volume "$fork_vol"
  docker rm -f "$fork_name" >/dev/null 2>&1 || true
  docker run -d --name "$fork_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_ARCHIVE_BUCKET=$fork_bucket" \
    -e "WAL_ARCHIVE_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_ARCHIVE_REGION=us-east-1 \
    -e WAL_ARCHIVE_KEY=$MINIO_USER \
    -e WAL_ARCHIVE_SECRET=$MINIO_PASS \
    -e WAL_ARCHIVE_PATH=/pgbackrest \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=rofork \
    -e WAL_RECOVER_FROM_SECRET=rofork123pass \
    -e "WAL_RECOVER_FROM_PATH=$src_path" \
    -e "POSTGRES_RECOVERY_TARGET_TIME=$target" \
    -e WAL_BACKUP_POLL_INTERVAL_SECONDS=5 \
    -v "$fork_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null

  wait_for_pg "$fork_name" || { ko t_dual_repo_archives_to_own_bucket "fork pg did not start"; fail_dump t_dual_repo_archives_to_own_bucket "$fork_name"; return; }
  wait_for_promoted "$fork_name" || { ko t_dual_repo_archives_to_own_bucket "fork did not promote"; fail_dump t_dual_repo_archives_to_own_bucket "$fork_name"; return; }

  # Generate WAL post-promote so the watcher has something to back up.
  docker exec "$fork_name" psql -U postgres -c "CREATE TABLE forkprobe(id int); INSERT INTO forkprobe VALUES (1); SELECT pg_switch_wal();" >/dev/null

  # Wait up to 180 s for the watcher's first full to land. Under suite load
  # the fork's bootstrap_pgbackrest_stanza fork can race the watcher poll —
  # the watcher's first few backup attempts return "has a stanza-create
  # been performed?" until stanza-create catches up. Each retry is on a 5 s
  # poll, so even with 5–10 retries the second-or-third try succeeds well
  # within the bumped window. 90 s was tight enough that a slow stanza-
  # create + a couple of retry windows tipped past it.
  if ! wait_for_watcher_backup "$fork_name" full 180; then
    ko t_dual_repo_archives_to_own_bucket "watcher did not take initial full into fork bucket"
    fail_dump t_dual_repo_archives_to_own_bucket "$fork_name"
    return
  fi

  # Fork bucket must have a backup + WAL.
  local fork_count
  fork_count=$(mc "mc ls --recursive local/${fork_bucket} | wc -l" | tail -1 | tr -d ' ')
  if [ "$fork_count" -lt 5 ]; then
    ko t_dual_repo_archives_to_own_bucket "fork bucket should have backup files; got $fork_count"
    fail_dump t_dual_repo_archives_to_own_bucket "$fork_name"
    return
  fi

  # Source bucket must be unchanged — no fork writes accepted (read-only
  # creds reject any archive-push that fanned out to repo2 on Boot 1).
  local source_count_after
  source_count_after=$(mc "mc ls --recursive local/${BUCKET} | wc -l" | tail -1 | tr -d ' ')
  if [ "$source_count_after" -ne "$source_count_before" ]; then
    ko t_dual_repo_archives_to_own_bucket "source bucket leaked writes from fork; before=$source_count_before after=$source_count_after"
    return
  fi

  ok t_dual_repo_archives_to_own_bucket
  note "fork wrote $fork_count objects to own bucket; source untouched ($source_count_before objects)"
  mc "mc rm -r --force local/${fork_bucket}" >/dev/null 2>&1 || true
  docker rm -f "$src_name" "$fork_name" >/dev/null
  docker volume rm "$src_vol" "$fork_vol" >/dev/null
}

t_empty_volume_restore_from_s3() {
  # Source: standalone archiving service with a base backup + a "before-target"
  # row, captured target time, and "after-target" rows.
  setup_pitr_source >&2 || { ko "${FUNCNAME[0]}" "setup_pitr_source failed"; return; }
  read -r src_name src_vol < "/tmp/pitr-source-${PG_VERSION}"
  local target; target=$(cat "/tmp/pitr-target-${PG_VERSION}")
  local src_path; src_path=$(pitr_source_path)
  local rest_name=t-empty-restore-${PG_VERSION}
  local rest_vol=${rest_name}-vol
  new_volume "$rest_vol"

  # KEY DIFFERENCE vs. t_pitr_happy_path: no manual `pgbackrest_restore_into`.
  # The empty volume + WAL_RECOVER_FROM_* + POSTGRES_RECOVERY_TARGET_TIME must
  # cause wrapper.sh to run `pgbackrest restore` itself before docker-entrypoint
  # touches anything. This is the v2 "restore from S3 directly" path.
  docker rm -f "$rest_name" >/dev/null 2>&1 || true
  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=$MINIO_USER \
    -e WAL_RECOVER_FROM_SECRET=$MINIO_PASS \
    -e "WAL_RECOVER_FROM_PATH=$src_path" \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e "POSTGRES_RECOVERY_TARGET_TIME=$target" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$rest_name" || { ko t_empty_volume_restore_from_s3 "restored pg did not start"; fail_dump t_empty_volume_restore_from_s3 "$rest_name"; return; }

  # The .pgbackrest_restored marker must exist (set by
  # restore_from_pgbackrest_if_empty_volume after a successful restore).
  if ! docker exec "$rest_name" test -f /var/lib/postgresql/data/.pgbackrest_restored; then
    ko t_empty_volume_restore_from_s3 ".pgbackrest_restored marker missing — wrapper did not run pgbackrest restore"
    fail_dump t_empty_volume_restore_from_s3 "$rest_name"
    return
  fi

  # configure_pgbackrest_recovery must have stayed out of the way (its conf.d
  # include would duplicate what `pgbackrest restore` already wrote).
  if docker exec "$rest_name" test -f /var/lib/postgresql/data/conf.d/pgbackrest-recovery.conf; then
    ko t_empty_volume_restore_from_s3 "conf.d/pgbackrest-recovery.conf must not be written when .pgbackrest_restored is set"
    return
  fi
  if docker exec "$rest_name" test -f /var/lib/postgresql/data/.pitr_staging; then
    ko t_empty_volume_restore_from_s3 ".pitr_staging must not be written on the empty-volume restore path"
    return
  fi

  # Time travel verified: id=1 (before target) present, id=2,3 (after) absent.
  local rows_before rows_after
  rows_before=$(docker exec "$rest_name" psql -U postgres -At -c "SELECT count(*) FROM pitrtest WHERE id=1")
  rows_after=$(docker exec "$rest_name" psql -U postgres -At -c "SELECT count(*) FROM pitrtest WHERE id IN (2,3)")
  if [ "$rows_before" != "1" ]; then
    ko t_empty_volume_restore_from_s3 "id=1 (before target) should be present; got $rows_before"
    return
  fi
  if [ "$rows_after" != "0" ]; then
    ko t_empty_volume_restore_from_s3 "id=2,3 (after target) should be absent; got $rows_after"
    return
  fi

  ok t_empty_volume_restore_from_s3
  docker rm -f "$rest_name" "$src_name" >/dev/null
  docker volume rm "$rest_vol" "$src_vol" >/dev/null
}

t_retention_expires_old_fulls() {
  local name=t-retain-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true

  # Retention=2 means at most 2 fulls retained. After the third full, the
  # oldest is expired by `pgbackrest expire` (which runs automatically after
  # every backup) along with any WAL it pinned.
  run_archiving_pg_fast_watcher "$name" "$vol" -e "WAL_BACKUP_RETENTION_FULL=2"
  wait_for_pg "$name" || { ko t_retention_expires_old_fulls "no startup"; return; }

  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null
  wait_for_watcher_backup "$name" full 60 || { ko t_retention_expires_old_fulls "no initial full"; return; }

  # Take two more fulls back-to-back via direct pgbackrest invocation. Each
  # invocation runs `pgbackrest expire` after the backup commits. Use
  # take_pgbackrest_backup so the per-cluster repo path is honored.
  for i in 2 3; do
    take_pgbackrest_backup "$name" full || { ko t_retention_expires_old_fulls "manual full #$i failed"; return; }
  done

  local fulls
  fulls=$(count_backups_of_type "$name" full)
  if [ "$fulls" != "2" ]; then
    ko t_retention_expires_old_fulls "expected 2 fulls retained after expire, got $fulls"
    fail_dump t_retention_expires_old_fulls "$name"
    return
  fi

  # Confirm the rendered conf carries repo1-retention-full=2 (was rendered
  # from WAL_BACKUP_RETENTION_FULL by render_pgbackrest_conf).
  if ! docker exec "$name" grep -q "^repo1-retention-full=2" /etc/pgbackrest/pgbackrest.conf; then
    ko t_retention_expires_old_fulls "WAL_BACKUP_RETENTION_FULL not rendered into pgbackrest.conf"
    return
  fi

  ok t_retention_expires_old_fulls
  note "took 3 fulls; oldest expired; 2 retained"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

# ----- defense-in-depth + lifecycle tests ------------------------------------
#
# These cover the customer-perceived PITR window contract end-to-end and the
# volume × bucket lifecycle transitions that surface in real ops. The mono
# mutation pre-validates target ≥ earliestBackupAt, but that check can be
# stale by the time the workflow boots the restored container, and operators
# hitting the image directly bypass the mutation entirely. So the image must
# carry the same loud-refuse guarantee.

# Run a manual `pgbackrest backup --type=<type>` inside the container, with
# all REPO1_S3_* env vars exported from the WAL_ARCHIVE_* set the wrapper
# already populated. Triggers `pgbackrest expire` automatically post-backup.
take_pgbackrest_backup() {
  local container="$1" backup_type="${2:-full}"
  docker exec -u postgres "$container" bash -c "
    export PGBACKREST_REPO1_S3_BUCKET=\"\$WAL_ARCHIVE_BUCKET\"
    export PGBACKREST_REPO1_S3_KEY=\"\$WAL_ARCHIVE_KEY\"
    export PGBACKREST_REPO1_S3_KEY_SECRET=\"\$WAL_ARCHIVE_SECRET\"
    export PGBACKREST_REPO1_S3_REGION=\"\$WAL_ARCHIVE_REGION\"
    export PGBACKREST_REPO1_S3_ENDPOINT=\"\$WAL_ARCHIVE_ENDPOINT\"
    if [ -f /var/lib/postgresql/data/.pgbackrest_repo_path ]; then
      export PGBACKREST_REPO1_PATH=\"\$(cat /var/lib/postgresql/data/.pgbackrest_repo_path)\"
    else
      export PGBACKREST_REPO1_PATH=\"\${WAL_ARCHIVE_PATH:-/pgbackrest}\"
    fi
    pgbackrest --stanza=main backup --type=$backup_type
  " >/dev/null 2>&1
}

# Count zst-compressed WAL segments under any cluster sub-path's archive/main/
# tree. With per-cluster paths, the prefix changed from
# pgbackrest/archive/main to pgbackrest/cluster-<sysid>/archive/main, so walk
# the whole bucket-prefix tree rather than hardcoding either layout.
count_archived_wal_segments() {
  mc "mc find local/${BUCKET}/pgbackrest --name '*.zst' 2>/dev/null | wc -l" \
    | tail -1 | tr -d ' '
}

# G1. Failure-driven gap recovery via pg_stat_archiver.failed_count growth.
# Exercises the failed_count entry condition of the gap-recovery state
# machine — drives the watcher purely off failed_count rather than touching
# the marker by hand. The state machine itself touches
# .pgbackrest_gap_pending as a consequence of detection (that's the
# "marker" used to remember we're in recovery across iterations), so this
# test asserts the resulting gap-recovery diff lands and clears state,
# not that the marker stays absent.
t_watcher_gap_recovery_failed_count_path() {
  local name=t-gap-fc-${PG_VERSION}
  local vol=${name}-vol
  local user=t-gap-fc-user
  local pass=t-gap-fc-pass-12345
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true

  # Dedicated MinIO user the test can disable/enable mid-flight without
  # locking out the harness's admin creds. Idempotent — if a prior failed
  # run left the user behind, recreate it cleanly.
  mc "
    mc admin user remove local ${user} >/dev/null 2>&1 || true
    mc admin user add local ${user} ${pass}
    mc admin policy attach local readwrite --user ${user} 2>/dev/null || true
  " >/dev/null

  # Threshold absurdly high so the wrapper NEVER drops on its own → no
  # .pgbackrest_gap_pending marker ever written → the only signal the
  # watcher has is failed_count growing past last_full_failed_count.
  # archive_timeout=5 so failed_count grows in seconds, not minutes.
  docker run -d --name "$name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_ARCHIVE_BUCKET=$BUCKET" \
    -e "WAL_ARCHIVE_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_ARCHIVE_REGION=us-east-1 \
    -e "WAL_ARCHIVE_KEY=${user}" \
    -e "WAL_ARCHIVE_SECRET=${pass}" \
    -e WAL_ARCHIVE_PATH=/pgbackrest \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e WAL_DROP_THRESHOLD_MB=999999 \
    -e POSTGRES_ARCHIVE_TIMEOUT=5 \
    -e WAL_BACKUP_POLL_INTERVAL_SECONDS=5 \
    -e WAL_BACKUP_GAP_RECOVERY_BACKOFF_SECONDS=10 \
    -v "$vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$name" || { ko t_watcher_gap_recovery_failed_count_path "no startup"; fail_dump t_watcher_gap_recovery_failed_count_path "$name"; return; }

  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c "CREATE TABLE t(id int); SELECT pg_switch_wal();" >/dev/null
  wait_for_watcher_backup "$name" full 60 || { ko t_watcher_gap_recovery_failed_count_path "no initial full"; fail_dump t_watcher_gap_recovery_failed_count_path "$name"; return; }

  local before_diff_count
  before_diff_count=$(docker logs "$name" 2>&1 | grep -c "backup --type=diff completed" || true)

  # Switch the user to read-only → PutObject fails with AccessDenied →
  # archive_command returns non-zero (wrapper threshold not met) → Postgres
  # bumps failed_count. Disabling the user entirely would produce
  # InvalidAccessKeyId, which the archive-push wrapper instant-drops (exit 0)
  # to avoid stacking failed_count on a bucket that's been deleted — keeping
  # failed_count=0 and defeating this test's whole premise.
  mc "
    mc admin policy detach local readwrite --user ${user} 2>/dev/null || true
    mc admin policy attach local readonly --user ${user} 2>/dev/null || true
  " >/dev/null
  for i in 1 2 3 4 5; do
    docker exec "$name" psql -U postgres -c "INSERT INTO t SELECT g FROM generate_series(${i}00000, ${i}00100) g; SELECT pg_switch_wal();" >/dev/null 2>&1
    sleep 2
  done

  local failed_count
  failed_count=$(docker exec "$name" psql -U postgres -At -c "SELECT failed_count FROM pg_stat_archiver" 2>/dev/null || echo 0)
  if [ "${failed_count:-0}" -lt 1 ]; then
    ko t_watcher_gap_recovery_failed_count_path "expected failed_count to grow under disabled user; got $failed_count"
    fail_dump t_watcher_gap_recovery_failed_count_path "$name"
    return
  fi

  # Restore write access → archive-push succeeds again → catalog advances
  # past detection point → state machine takes a diff to re-anchor the
  # PITR window. (Marker may have been written by the failed_count entry
  # condition — that's fine; it's the wrapper-threshold marker we're
  # exercising in the OTHER test, this one exercises the failed_count
  # entry condition into the same state machine.)
  mc "
    mc admin policy detach local readonly --user ${user} 2>/dev/null || true
    mc admin policy attach local readwrite --user ${user} 2>/dev/null || true
  " >/dev/null

  local deadline=$(($(date +%s) + 60)) hit=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    docker exec "$name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null 2>&1
    local now_count
    now_count=$(docker logs "$name" 2>&1 | grep -c "backup --type=diff completed" || true)
    if [ "$now_count" -gt "$before_diff_count" ]; then hit=1; break; fi
    sleep 3
  done
  if [ "$hit" != "1" ]; then
    ko t_watcher_gap_recovery_failed_count_path "watcher did not take gap-recovery diff via failed_count path"
    fail_dump t_watcher_gap_recovery_failed_count_path "$name"
    return
  fi

  # last_full_failed_count must have advanced past 0 — otherwise next
  # iteration would re-trigger immediately. clear_gap_recovery_state
  # writes this field as part of post-diff cleanup.
  local last_failed_in_state
  last_failed_in_state=$(docker exec "$name" grep -E "^last_full_failed_count=" /var/lib/postgresql/data/.pgbackrest_backup_state 2>/dev/null | cut -d= -f2)
  if [ -z "$last_failed_in_state" ] || [ "$last_failed_in_state" = "0" ]; then
    ko t_watcher_gap_recovery_failed_count_path "last_full_failed_count not advanced (got '$last_failed_in_state'); next poll would re-trigger"
    return
  fi

  ok t_watcher_gap_recovery_failed_count_path
  note "failed_count=${failed_count} → catalog advanced → gap-recovery diff; last_full_failed_count=${last_failed_in_state}"
  mc "mc admin user remove local ${user}" >/dev/null 2>&1 || true
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

# LSN-lag detection path — pgBackRest async mode returns archive_command
# success to Postgres the moment the WAL lands in the spool, BEFORE the
# upload to S3 is confirmed. With a small queue-max + a failing async
# worker, segments accumulate in spool, queue-max trips, and pgBackRest's
# foreground drops new segments while returning 0 to Postgres. Some pushes
# still surface as failures (foreground catches a prior async error and
# returns non-zero), so in practice failed_count and archived_count BOTH
# grow under load — but only the LSN-lag comparison catches the silent
# half (the drops, which contribute to handoff WAL advancing without the
# repo catalog moving).
#
# The unique-to-LSN-lag fingerprint is `last_lag_detected_at` in the
# watcher state file — only `gap_recovery_step` writes it. This
# test asserts the probe fired by checking that field, plus the absence
# of wrapper-side drop log lines (which would mean the wrapper, not the
# probe, wrote the marker).
t_watcher_gap_recovery_lsn_lag_path() {
  local name=t-gap-lag-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true

  # Phase 1: boot with writable creds + standard config to land an initial
  # full backup and seed the S3 catalog. The lag probe needs a real "max"
  # to compare against — without an initial full + WAL push, the probe
  # short-circuits via the "no matching timeline in catalog" branch.
  run_archiving_pg_fast_watcher "$name" "$vol"
  wait_for_pg "$name" || { ko t_watcher_gap_recovery_lsn_lag_path "init boot"; return; }
  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c "CREATE TABLE t(id int); SELECT pg_switch_wal();" >/dev/null
  wait_for_watcher_backup "$name" full 60 || { ko t_watcher_gap_recovery_lsn_lag_path "no initial full"; fail_dump t_watcher_gap_recovery_lsn_lag_path "$name"; return; }
  docker rm -f "$name" >/dev/null

  # Phase 2: restart with read-only creds, small queue-max, high
  # wrapper-drop threshold, and aggressively-shortened watcher cadences so
  # the lag probe trips within the test window.
  docker run -d --name "$name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_ARCHIVE_BUCKET=$BUCKET" \
    -e "WAL_ARCHIVE_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_ARCHIVE_REGION=us-east-1 \
    -e WAL_ARCHIVE_KEY=readonly \
    -e WAL_ARCHIVE_SECRET=readonlypass123 \
    -e WAL_ARCHIVE_PATH=/pgbackrest \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e PGBACKREST_ARCHIVE_PUSH_QUEUE_MAX=128MiB \
    -e WAL_DROP_THRESHOLD_MB=999999 \
    -e WAL_BACKUP_POLL_INTERVAL_SECONDS=5 \
    -e WAL_BACKUP_GAP_RECOVERY_BACKOFF_SECONDS=10 \
    -e WAL_LAG_GAP_THRESHOLD_SEGMENTS=4 \
    -v "$vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$name" || { ko t_watcher_gap_recovery_lsn_lag_path "ro boot"; fail_dump t_watcher_gap_recovery_lsn_lag_path "$name"; return; }

  # Pump ~960 MiB of WAL with read-only creds → spool overflows the 128 MiB
  # queue-max → pgBackRest's foreground starts dropping new segments.
  docker exec "$name" psql -U postgres -c "ALTER TABLE t ADD COLUMN IF NOT EXISTS payload text;" >/dev/null 2>&1
  for i in $(seq 1 12); do
    docker exec "$name" psql -U postgres -c "INSERT INTO t SELECT g, repeat('x', 1000) FROM generate_series($((i*80000)), $(((i+1)*80000))) g; SELECT pg_switch_wal();" >/dev/null 2>&1
  done

  # Wait for the probe to write the gap marker. Detection runs every
  # iteration (POLL_INTERVAL_SECONDS=5) → marker should land within
  # ~10-15s of the first drop. Poll on the marker FILE rather than a
  # specific log line because docker log timing through high-volume
  # pgbackrest output can race a one-shot "gap detected" line; the marker
  # + state file are durable evidence.
  local deadline=$(($(date +%s) + 90)) hit=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker exec "$name" test -f /var/lib/postgresql/data/.pgbackrest_gap_pending 2>/dev/null; then
      hit=1; break
    fi
    sleep 2
  done
  if [ "$hit" != "1" ]; then
    ko t_watcher_gap_recovery_lsn_lag_path "gap marker not written within deadline"
    fail_dump t_watcher_gap_recovery_lsn_lag_path "$name"
    return
  fi

  # Wait one more poll for write_state_field to land last_lag_detected_at
  # (touch happens immediately before the state write — usually same shell
  # tick, but tolerate a few seconds of fs flush lag).
  sleep 3

  # Assert: last_lag_detected_at recorded in the watcher state file. This
  # is the durable fingerprint of the LSN-lag detection branch — only
  # gap_recovery_step writes this field on new detection (the
  # wrapper-touched path back-fills it on the same iteration). Tested via
  # the state file rather than a log line because docker's json-file log
  # driver under high-volume pgbackrest error output (each failed PUT is
  # ~3-4 KiB of XML) intermittently fails to surface specific log lines
  # to `docker logs | grep` in this CI's harness — the state file is
  # robust to that timing.
  local last_lag_at
  last_lag_at=$(docker exec "$name" grep -E "^last_lag_detected_at=" /var/lib/postgresql/data/.pgbackrest_backup_state 2>/dev/null | cut -d= -f2)
  if [ -z "$last_lag_at" ] || [ "$last_lag_at" = "0" ]; then
    ko t_watcher_gap_recovery_lsn_lag_path "last_lag_detected_at not written to state (got '$last_lag_at') — LSN-lag detection did not fire"
    fail_dump t_watcher_gap_recovery_lsn_lag_path "$name"
    return
  fi

  ok t_watcher_gap_recovery_lsn_lag_path
  note "LSN-lag detection wrote marker + last_lag_detected_at=${last_lag_at}"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

# WAL_REGRESSION self-heal via async-spool probe. Simulates the post-volume-
# rollback failure mode by planting a synthetic ArchiveDuplicateError in the
# async spool's .error directory — the same shape pgBackRest writes when it
# tries to push a segment whose name already exists in S3 with different
# content. The probe path runs before any of the foreground-signal branches,
# so we don't need to coordinate with pg_stat_archiver or wait through a
# pkill backoff: a single planted .error file is enough to fire migrate.
#
# Engineering a "real" rollback would require stopping postgres, snapshotting
# PGDATA, advancing the LSN with extra archive-pushes, then restoring the
# snapshot — doable but heavy. The probe is also the only detection path
# that fires when the foreground archive_command hasn't been re-invoked yet
# (last_failed_wal still NULL on a quiet DB), so it's the most defensive of
# the three branches to pin down with automation.
t_watcher_wal_regression_async_spool_probe() {
  local name=t-walreg-spool-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true

  run_archiving_pg_fast_watcher "$name" "$vol"
  wait_for_pg "$name" || { ko t_watcher_wal_regression_async_spool_probe "no startup"; fail_dump t_watcher_wal_regression_async_spool_probe "$name"; return; }
  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c "CREATE TABLE t(id int); SELECT pg_switch_wal();" >/dev/null
  wait_for_watcher_backup "$name" full 60 || { ko t_watcher_wal_regression_async_spool_probe "no initial full"; fail_dump t_watcher_wal_regression_async_spool_probe "$name"; return; }

  # Snapshot the original marker + last_archived_wal so we can assert the
  # migration target and that the old path's full survives.
  local orig_path orig_full_count last_archived
  orig_path=$(docker exec "$name" cat /var/lib/postgresql/data/.pgbackrest_repo_path)
  orig_full_count=$(count_backups_of_type "$name" full)

  # After a full backup pgBackRest archives a backup history file
  # (e.g. 000000010000000000000003.00000028.backup) via archive_command, and
  # pg_stat_archiver reflects it as last_archived_wal. That name is not a
  # plain 24-char WAL segment, so segment_to_number rejects it and the
  # probe_async_duplicate_error boundary check fails silently. Force a WAL
  # switch here so the next archived file is a real segment, then poll until
  # last_archived_wal is exactly 24 hex chars before planting the .error.
  docker exec "$name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null
  local seg_deadline=$(($(date +%s) + 20))
  last_archived=""
  while [ "$(date +%s)" -lt "$seg_deadline" ]; do
    local candidate
    candidate=$(docker exec "$name" psql -U postgres -At \
      -c "SELECT last_archived_wal FROM pg_stat_archiver" 2>/dev/null)
    if [ "${#candidate}" -eq 24 ]; then
      last_archived="$candidate"
      break
    fi
    sleep 1
  done
  if [ -z "$last_archived" ]; then
    ko t_watcher_wal_regression_async_spool_probe "no 24-char WAL segment in last_archived_wal after pg_switch_wal"
    fail_dump t_watcher_wal_regression_async_spool_probe "$name"
    return
  fi

  # Pre-kill the async daemon so the synthetic .error file isn't auto-
  # cleaned by the daemon's inotify-driven re-queue: the planted WAL
  # segment IS in S3 with the same checksum, so the daemon would exit 0
  # and remove the file in sub-second time, before the first watcher
  # poll. The "kicking async daemon" log-line assertion below covers the
  # production behavior (daemon alive when migrate fires).
  docker exec "$name" pkill -f "archive-push:async" 2>/dev/null || true

  # Plant synthetic async status files matching pgBackRest's real on-disk
  # format (see src/command/archive/common.c — archiveAsyncStatus writes
  # `<exit_code>\n<message>\n`). First line is the integer exit code
  # (45 == ArchiveDuplicateError), which is what probe_async_duplicate_error
  # matches against — version-stable across 2.x phrasing changes. File name =
  # last_archived_wal → predicate's "same timeline, segment ≤ catalog_max"
  # reduces to equality, the boundary case the migration's `-le` (not `-lt`)
  # was widened to catch. Also plant an alphabetically-earlier stale exit-45
  # on another timeline so the probe must continue scanning until it finds
  # the catalog-valid candidate, and plant a stale .ok to prove migration
  # clears all old-path async statuses, not just .error files.
  docker exec "$name" sh -c "
    mkdir -p /var/lib/postgresql/data/pgbackrest-spool/archive/main/out
    cat > /var/lib/postgresql/data/pgbackrest-spool/archive/main/out/000000000000000000000001.error <<EOF
45
stale duplicate error from another timeline
EOF
    cat > /var/lib/postgresql/data/pgbackrest-spool/archive/main/out/${last_archived}.error <<EOF
45
WAL segment ${last_archived} already exists in the archive with a different checksum
EOF
    cat > /var/lib/postgresql/data/pgbackrest-spool/archive/main/out/${last_archived}.ok <<EOF
0
stale ok from old archive path
EOF
    chown postgres:postgres /var/lib/postgresql/data/pgbackrest-spool/archive/main/out/000000000000000000000001.error \
      /var/lib/postgresql/data/pgbackrest-spool/archive/main/out/${last_archived}.error \
      /var/lib/postgresql/data/pgbackrest-spool/archive/main/out/${last_archived}.ok
  " || { ko t_watcher_wal_regression_async_spool_probe "could not plant async status files"; fail_dump t_watcher_wal_regression_async_spool_probe "$name"; return; }

  # Wait for the watcher to log the migration. Poll = 5s; 60s allows two
  # iterations + state writes + the next iteration's post-migrate full to
  # start landing in the log buffer.
  local deadline=$(($(date +%s) + 60)) hit_migrate=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker logs "$name" 2>&1 | grep -q "wal-regression: migrating archive path"; then
      hit_migrate=1; break
    fi
    sleep 2
  done
  if [ "$hit_migrate" != "1" ]; then
    ko t_watcher_wal_regression_async_spool_probe "watcher did not log wal-regression migration within deadline"
    fail_dump t_watcher_wal_regression_async_spool_probe "$name"
    return
  fi

  # Migrate must explicitly kick the async daemon so the post-migrate
  # closing WAL reaches the NEW path on the next archive_command (~60s),
  # not after a 10-min gap-recovery loop pkill. Without this, the daemon
  # holds the OLD repo1-path for its lifetime and self-heal stalls.
  # Poll briefly: between "migrating" and "kicking" the watcher runs a
  # psql round-trip + several state writes, so the kick log can lag the
  # migration log by a few seconds on a loaded CI runner.
  local kick_deadline=$(($(date +%s) + 15)) hit_kick=0
  while [ "$(date +%s)" -lt "$kick_deadline" ]; do
    if docker logs "$name" 2>&1 | grep -q "archive-migration: kicking async daemon"; then
      hit_kick=1; break
    fi
    sleep 1
  done
  if [ "$hit_kick" != "1" ]; then
    ko t_watcher_wal_regression_async_spool_probe "migrate did not kick the async daemon (kick log line missing)"
    fail_dump t_watcher_wal_regression_async_spool_probe "$name"
    return
  fi

  # Marker must now point at `<orig_path>-<digits>` (epoch suffix). Epoch
  # is wall-clock seconds, so >=1 decimal digit; we don't pin a specific
  # value because clock skew under CI load can shift it.
  local new_path
  new_path=$(docker exec "$name" cat /var/lib/postgresql/data/.pgbackrest_repo_path)
  case "$new_path" in
    "${orig_path}-"[0-9]*) ;;
    *)
      ko t_watcher_wal_regression_async_spool_probe "marker did not get an epoch suffix; orig=${orig_path}, new=${new_path}"
      fail_dump t_watcher_wal_regression_async_spool_probe "$name"
      return ;;
  esac

  # State file must record the pre-migration path so successive migrations
  # land at cluster-X-<e2> rather than chaining suffixes (cluster-X-<e1>-<e2>).
  local orig_in_state
  orig_in_state=$(docker exec "$name" grep -E "^archive_migration_orig_path=" \
    /var/lib/postgresql/data/.pgbackrest_backup_state 2>/dev/null | cut -d= -f2-)
  if [ "$orig_in_state" != "$orig_path" ]; then
    ko t_watcher_wal_regression_async_spool_probe "archive_migration_orig_path expected '${orig_path}', got '${orig_in_state}'"
    fail_dump t_watcher_wal_regression_async_spool_probe "$name"
    return
  fi

  # Pending target must only clear after marker flip + async spool cleanup
  # finalize successfully. If this sticks, a later iteration is expected to
  # retry finalization rather than trusting stale old-path .ok/.error files.
  local pending_in_state
  pending_in_state=$(docker exec "$name" grep -E "^archive_migration_pending_new_path=" \
    /var/lib/postgresql/data/.pgbackrest_backup_state 2>/dev/null | cut -d= -f2-)
  if [ -n "$pending_in_state" ]; then
    ko t_watcher_wal_regression_async_spool_probe "archive_migration_pending_new_path should be clear after finalize, got '${pending_in_state}'"
    fail_dump t_watcher_wal_regression_async_spool_probe "$name"
    return
  fi

  # The rendered pgbackrest.conf must have repo1-path rewritten too —
  # defense for bare-shell diagnostics that don't go through the
  # PGBACKREST_REPO1_PATH env override that mono's picker uses.
  local conf_path
  conf_path=$(docker exec "$name" grep -E "^repo1-path=" \
    /etc/pgbackrest/pgbackrest.conf 2>/dev/null | cut -d= -f2-)
  if [ "$conf_path" != "$new_path" ]; then
    ko t_watcher_wal_regression_async_spool_probe "pgbackrest.conf repo1-path expected '${new_path}', got '${conf_path}'"
    fail_dump t_watcher_wal_regression_async_spool_probe "$name"
    return
  fi

  # migrate cleans planted async status files so the next iteration's probe
  # doesn't re-fire on a leftover .error, and future archive-push calls can't
  # treat stale old-path .ok files as proof a segment reached the NEW path.
  if docker exec "$name" sh -c "
    test -e /var/lib/postgresql/data/pgbackrest-spool/archive/main/out/000000000000000000000001.error || \
    test -e /var/lib/postgresql/data/pgbackrest-spool/archive/main/out/${last_archived}.error || \
    test -e /var/lib/postgresql/data/pgbackrest-spool/archive/main/out/${last_archived}.ok
  "; then
    ko t_watcher_wal_regression_async_spool_probe "migrate did not clean planted async status files"
    fail_dump t_watcher_wal_regression_async_spool_probe "$name"
    return
  fi

  # Wait for the post-migrate NEEDS_INITIAL_BACKUP full to land at the new
  # path. last_full_at="" was written before the marker flip, so the next
  # iteration's decide_action takes a full unconditionally. Drive WAL
  # switches to keep the archive-push warm; the stanza-create on the new
  # path needs at least one segment to anchor against.
  local full_deadline=$(($(date +%s) + 120)) full_hit=0
  while [ "$(date +%s)" -lt "$full_deadline" ]; do
    local now_count
    now_count=$(docker logs "$name" 2>&1 | grep -c "backup --type=full completed" || true)
    if [ "$now_count" -gt 1 ]; then full_hit=1; break; fi   # initial + post-migrate
    docker exec "$name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null 2>&1
    sleep 3
  done
  if [ "$full_hit" != "1" ]; then
    ko t_watcher_wal_regression_async_spool_probe "post-migrate full did not land within deadline"
    fail_dump t_watcher_wal_regression_async_spool_probe "$name"
    return
  fi

  # Old path's full survives — the migration is non-destructive. Probe
  # the old path directly with a per-call PGBACKREST_REPO1_PATH override.
  # This is the exact mechanism mono's usePitrHistories uses to enumerate
  # orphaned histories in the restore UI, so this assertion also confirms
  # the UI's discovery path works end-to-end after self-heal.
  local old_fulls_after
  old_fulls_after=$(docker exec -u postgres "$name" bash -c "
    export PGBACKREST_REPO1_S3_BUCKET=\"\$WAL_ARCHIVE_BUCKET\"
    export PGBACKREST_REPO1_S3_KEY=\"\$WAL_ARCHIVE_KEY\"
    export PGBACKREST_REPO1_S3_KEY_SECRET=\"\$WAL_ARCHIVE_SECRET\"
    export PGBACKREST_REPO1_S3_REGION=\"\$WAL_ARCHIVE_REGION\"
    export PGBACKREST_REPO1_S3_ENDPOINT=\"\$WAL_ARCHIVE_ENDPOINT\"
    export PGBACKREST_REPO1_PATH=\"$orig_path\"
    pgbackrest --stanza=main info 2>/dev/null | grep -cE '^[[:space:]]+full backup: ' || true
  " 2>/dev/null | tail -1)
  if [ "${old_fulls_after:-0}" -lt "$orig_full_count" ]; then
    ko t_watcher_wal_regression_async_spool_probe "old path full count regressed: was ${orig_full_count}, now ${old_fulls_after}"
    fail_dump t_watcher_wal_regression_async_spool_probe "$name"
    return
  fi

  ok t_watcher_wal_regression_async_spool_probe
  note "migrated ${orig_path} → ${new_path}; old full preserved (${old_fulls_after} visible at ${orig_path})"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

# G2. PITR target older than oldest-retained full → wrapper exits 1 with a
# clear "no matching backup set" error. Image-level defense-in-depth for the
# mono mutation's pre-validation, which can be stale by the time the
# restored container actually boots.
t_pitr_target_before_retention_window_refuses() {
  local src_name=t-rwsrc-${PG_VERSION}
  local src_vol=${src_name}-vol
  local rest_name=t-rwrest-${PG_VERSION}
  local rest_vol=${rest_name}-vol
  reset_bucket
  new_volume "$src_vol"

  # Retention=2 + 3 fulls → oldest expired. Take the fulls back-to-back
  # to keep the test fast. setup_pitr_source isn't reusable here because
  # we need explicit timing control + an early target capture.
  docker rm -f "$src_name" >/dev/null 2>&1 || true
  run_archiving_pg_fast_watcher "$src_name" "$src_vol" -e "WAL_BACKUP_RETENTION_FULL=2"
  wait_for_pg "$src_name" || { ko t_pitr_target_before_retention_window_refuses "src no startup"; return; }

  for _ in $(seq 1 15); do
    docker logs "$src_name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$src_name" psql -U postgres -c "CREATE TABLE t(id int); SELECT pg_switch_wal();" >/dev/null
  wait_for_watcher_backup "$src_name" full 60 || { ko t_pitr_target_before_retention_window_refuses "no initial full"; return; }

  # T_TARGET captured during the original full's window. Once retention
  # culls that backup, T_TARGET points into a hole — pgbackrest restore
  # must error with code 075.
  local target
  target=$(docker exec "$src_name" psql -U postgres -At -c "SELECT now()::timestamptz(0)")
  sleep 2

  # Insert + WAL switch between fulls so each backup has distinct WAL
  # ranges; pgbackrest expire then has clear segments to remove with the
  # oldest full.
  docker exec "$src_name" psql -U postgres -c "INSERT INTO t VALUES (2); SELECT pg_switch_wal();" >/dev/null
  sleep 2
  take_pgbackrest_backup "$src_name" full || { ko t_pitr_target_before_retention_window_refuses "manual full #2 failed"; return; }
  docker exec "$src_name" psql -U postgres -c "INSERT INTO t VALUES (3); SELECT pg_switch_wal();" >/dev/null
  sleep 2
  take_pgbackrest_backup "$src_name" full || { ko t_pitr_target_before_retention_window_refuses "manual full #3 failed"; return; }

  local fulls
  fulls=$(count_backups_of_type "$src_name" full)
  if [ "$fulls" != "2" ]; then
    ko t_pitr_target_before_retention_window_refuses "expected 2 fulls after expire, got $fulls"
    fail_dump t_pitr_target_before_retention_window_refuses "$src_name"
    return
  fi

  # Now attempt restore to T_TARGET on a fresh empty volume. The mono path
  # uses WAL_RECOVER_FROM_* against the source bucket; the image must
  # refuse loudly because no retained backup has stop_time ≤ T_TARGET.
  # Read the source's per-cluster path so WAL_RECOVER_FROM_PATH targets
  # the correct sub-prefix.
  local src_path
  src_path=$(docker exec "$src_name" cat /var/lib/postgresql/data/.pgbackrest_repo_path 2>/dev/null \
    || echo "/pgbackrest")
  new_volume "$rest_vol"
  docker rm -f "$rest_name" >/dev/null 2>&1 || true
  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=$MINIO_USER \
    -e WAL_RECOVER_FROM_SECRET=$MINIO_PASS \
    -e "WAL_RECOVER_FROM_PATH=$src_path" \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e "POSTGRES_RECOVERY_TARGET_TIME=$target" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null

  local deadline=$(($(date +%s) + 30)) status="running"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    status=$(docker inspect -f '{{.State.Status}}' "$rest_name" 2>/dev/null || echo missing)
    [ "$status" = "exited" ] && break
    sleep 1
  done
  if [ "$status" != "exited" ]; then
    ko t_pitr_target_before_retention_window_refuses "wrapper should have exited; status=$status"
    fail_dump t_pitr_target_before_retention_window_refuses "$rest_name"
    return
  fi
  local exit_code; exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$rest_name")
  if [ "$exit_code" = "0" ]; then
    ko t_pitr_target_before_retention_window_refuses "wrapper exited 0; expected non-zero refusal"
    return
  fi
  if ! wait_for_log_line "$rest_name" "unable to find backup set"; then
    ko t_pitr_target_before_retention_window_refuses "expected 'unable to find backup set' from pgbackrest; logs:"
    fail_dump t_pitr_target_before_retention_window_refuses "$rest_name"
    return
  fi
  if docker run --rm -v "$rest_vol:/data" alpine test -f /data/PG_VERSION; then
    ko t_pitr_target_before_retention_window_refuses "PG_VERSION exists; initdb should not have run"
    return
  fi

  ok t_pitr_target_before_retention_window_refuses
  note "target=${target}; oldest full expired; wrapper exit=${exit_code}; PGDATA untouched"
  docker rm -f "$src_name" "$rest_name" >/dev/null
  docker volume rm "$src_vol" "$rest_vol" >/dev/null
}

# G3. WAL retention cascades on expire — when a full is expired, the WAL
# pinned by its manifest is removed too. Pins the README's "expire is the
# source of truth for WAL retention" claim and validates the 2× bucket-TTL
# safety-net guidance (TTL only matters if expire is actually working).
t_retention_expire_cascades_to_wal() {
  local name=t-walret-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true
  run_archiving_pg_fast_watcher "$name" "$vol" -e "WAL_BACKUP_RETENTION_FULL=2"
  wait_for_pg "$name" || { ko t_retention_expire_cascades_to_wal "no startup"; return; }

  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c "CREATE TABLE t(id int);" >/dev/null
  # Force several WAL switches so the bucket has more than one segment per
  # full's pinned range — a single-segment bucket would make the cascade
  # un-observable.
  for i in 1 2 3 4 5; do
    docker exec "$name" psql -U postgres -c "INSERT INTO t VALUES ($i); SELECT pg_switch_wal();" >/dev/null
    sleep 1
  done
  wait_for_watcher_backup "$name" full 60 || { ko t_retention_expire_cascades_to_wal "no initial full"; return; }

  # Take a second full so retention=2 is at the boundary; capture WAL count
  # *before* the third full (which is what triggers expire of the first).
  for i in 6 7 8; do
    docker exec "$name" psql -U postgres -c "INSERT INTO t VALUES ($i); SELECT pg_switch_wal();" >/dev/null
    sleep 1
  done
  take_pgbackrest_backup "$name" full || { ko t_retention_expire_cascades_to_wal "manual #2 failed"; return; }
  for i in 9 10 11; do
    docker exec "$name" psql -U postgres -c "INSERT INTO t VALUES ($i); SELECT pg_switch_wal();" >/dev/null
    sleep 1
  done

  local wal_before; wal_before=$(count_archived_wal_segments)

  take_pgbackrest_backup "$name" full || { ko t_retention_expire_cascades_to_wal "manual #3 failed (expire trigger)"; return; }
  sleep 3  # let pgbackrest expire's S3 deletes settle

  local wal_after; wal_after=$(count_archived_wal_segments)

  if [ "${wal_after:-0}" -ge "${wal_before:-0}" ]; then
    ko t_retention_expire_cascades_to_wal "expected WAL count to drop after expire; before=$wal_before after=$wal_after"
    fail_dump t_retention_expire_cascades_to_wal "$name"
    return
  fi

  local fulls; fulls=$(count_backups_of_type "$name" full)
  if [ "$fulls" != "2" ]; then
    ko t_retention_expire_cascades_to_wal "expected 2 fulls retained, got $fulls"
    return
  fi

  ok t_retention_expire_cascades_to_wal
  note "WAL segments before expire=${wal_before}, after=${wal_after} (cascaded with expired full)"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

# G4. Empty-volume restore with bad creds → loud refuse. The wrapper exits
# non-zero, PGDATA stays empty, no half-init. Operator with a typo in
# WAL_RECOVER_FROM_KEY must NOT silently get a vanilla initdb.
t_empty_volume_restore_refuses_on_bad_creds() {
  setup_pitr_source >&2 || { ko "${FUNCNAME[0]}" "setup_pitr_source failed"; return; }
  read -r src_name src_vol < "/tmp/pitr-source-${PG_VERSION}"
  local target; target=$(cat "/tmp/pitr-target-${PG_VERSION}")
  local src_path; src_path=$(pitr_source_path)
  local rest_name=t-badcreds-${PG_VERSION}
  local rest_vol=${rest_name}-vol
  new_volume "$rest_vol"
  docker rm -f "$rest_name" >/dev/null 2>&1 || true

  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=DELIBERATELY_BAD_KEY \
    -e WAL_RECOVER_FROM_SECRET=DELIBERATELY_BAD_SECRET \
    -e "WAL_RECOVER_FROM_PATH=$src_path" \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e "POSTGRES_RECOVERY_TARGET_TIME=$target" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null

  local deadline=$(($(date +%s) + 30)) status="running"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    status=$(docker inspect -f '{{.State.Status}}' "$rest_name" 2>/dev/null || echo missing)
    [ "$status" = "exited" ] && break
    sleep 1
  done
  if [ "$status" != "exited" ]; then
    ko t_empty_volume_restore_refuses_on_bad_creds "wrapper should have exited; status=$status"
    fail_dump t_empty_volume_restore_refuses_on_bad_creds "$rest_name"
    return
  fi
  local exit_code; exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$rest_name")
  if [ "$exit_code" = "0" ]; then
    ko t_empty_volume_restore_refuses_on_bad_creds "wrapper exited 0; expected non-zero refusal"
    return
  fi
  if ! wait_for_log_line "$rest_name" "restore from source bucket failed"; then
    ko t_empty_volume_restore_refuses_on_bad_creds "expected 'restore from source bucket failed' in logs"
    fail_dump t_empty_volume_restore_refuses_on_bad_creds "$rest_name"
    return
  fi
  if docker run --rm -v "$rest_vol:/data" alpine test -f /data/PG_VERSION; then
    ko t_empty_volume_restore_refuses_on_bad_creds "PG_VERSION exists; initdb should not have run"
    return
  fi

  ok t_empty_volume_restore_refuses_on_bad_creds
  note "wrapper exit=${exit_code}; PGDATA untouched"
  docker rm -f "$src_name" "$rest_name" >/dev/null
  docker volume rm "$src_vol" "$rest_vol" >/dev/null
}

# E1. Wipe volume + reuse same bucket → both clusters' archives preserved
# side-by-side via per-cluster repo paths. The new cluster's initdb produces
# a different system_identifier; pgbackrest-init.sh writes a marker file
# pointing at `${WAL_ARCHIVE_PATH}/cluster-<new_sysid>`, and stanza-create
# runs cleanly there. The previous cluster's data at `cluster-<old_sysid>`
# is untouched. Mono UI can list all `cluster-*` sub-paths and surface
# them as separate restorable histories.
t_volume_wipe_same_bucket_preserves_both() {
  local name=t-wipebucket-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"

  # Cluster A: archive + take initial full at its per-cluster path.
  docker rm -f "$name" >/dev/null 2>&1 || true
  run_archiving_pg_fast_watcher "$name" "$vol"
  wait_for_pg "$name" || { ko t_volume_wipe_same_bucket_preserves_both "A no startup"; return; }
  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c "CREATE TABLE t(id int); INSERT INTO t VALUES (1); SELECT pg_switch_wal();" >/dev/null
  wait_for_watcher_backup "$name" full 60 || { ko t_volume_wipe_same_bucket_preserves_both "A no initial full"; return; }

  local sysid_a path_a
  sysid_a=$(docker exec "$name" cat /var/lib/postgresql/data/.pgbackrest_repo_path 2>/dev/null | sed 's|.*/cluster-||')
  path_a=$(docker exec "$name" cat /var/lib/postgresql/data/.pgbackrest_repo_path 2>/dev/null)
  if [ -z "$sysid_a" ]; then
    ko t_volume_wipe_same_bucket_preserves_both "cluster A didn't write per-cluster marker"
    fail_dump t_volume_wipe_same_bucket_preserves_both "$name"
    return
  fi

  # Wipe: stop container, recreate volume, redeploy with identical env. New
  # initdb runs on the empty volume → new system_identifier → new marker
  # path → new stanza, no collision.
  docker rm -f "$name" >/dev/null
  new_volume "$vol"
  run_archiving_pg_fast_watcher "$name" "$vol"
  wait_for_pg "$name" || { ko t_volume_wipe_same_bucket_preserves_both "C no startup"; fail_dump t_volume_wipe_same_bucket_preserves_both "$name"; return; }
  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c "CREATE TABLE u(id int); INSERT INTO u VALUES (1); SELECT pg_switch_wal();" >/dev/null
  wait_for_watcher_backup "$name" full 60 || { ko t_volume_wipe_same_bucket_preserves_both "C no initial full"; fail_dump t_volume_wipe_same_bucket_preserves_both "$name"; return; }

  local sysid_c path_c
  sysid_c=$(docker exec "$name" cat /var/lib/postgresql/data/.pgbackrest_repo_path 2>/dev/null | sed 's|.*/cluster-||')
  path_c=$(docker exec "$name" cat /var/lib/postgresql/data/.pgbackrest_repo_path 2>/dev/null)
  if [ -z "$sysid_c" ]; then
    ko t_volume_wipe_same_bucket_preserves_both "cluster C didn't write per-cluster marker"
    return
  fi
  if [ "$sysid_a" = "$sysid_c" ]; then
    ko t_volume_wipe_same_bucket_preserves_both "cluster A and C share a system_identifier — initdb didn't generate a new one"
    return
  fi

  # Cluster C's stanza must be at its own path; cluster A's at the original.
  # `mc find` lists archive.info files; one per per-cluster sub-path.
  local cluster_dirs
  cluster_dirs=$(mc "mc find local/${BUCKET} --name archive.info 2>/dev/null" \
    | grep -oE 'cluster-[0-9]+' | sort -u)
  if [ "$(echo "$cluster_dirs" | grep -c .)" -lt 2 ]; then
    ko t_volume_wipe_same_bucket_preserves_both "expected 2 cluster-* sub-paths in bucket; got: $cluster_dirs"
    fail_dump t_volume_wipe_same_bucket_preserves_both "$name"
    return
  fi

  # Cluster A's full is still browsable at its old path. (Probing from
  # within the running C container, but pointing pgbackrest at A's path.)
  local a_fulls
  a_fulls=$(docker exec -u postgres "$name" bash -c "
    export PGBACKREST_REPO1_S3_BUCKET=\"\$WAL_ARCHIVE_BUCKET\"
    export PGBACKREST_REPO1_S3_KEY=\"\$WAL_ARCHIVE_KEY\"
    export PGBACKREST_REPO1_S3_KEY_SECRET=\"\$WAL_ARCHIVE_SECRET\"
    export PGBACKREST_REPO1_S3_REGION=\"\$WAL_ARCHIVE_REGION\"
    export PGBACKREST_REPO1_S3_ENDPOINT=\"\$WAL_ARCHIVE_ENDPOINT\"
    export PGBACKREST_REPO1_PATH=\"$path_a\"
    pgbackrest --stanza=main info 2>/dev/null | grep -cE '^[[:space:]]+full backup: ' || true
  " 2>/dev/null | tail -1)
  if [ "${a_fulls:-0}" -lt 1 ]; then
    ko t_volume_wipe_same_bucket_preserves_both "cluster A's full not visible at $path_a; got $a_fulls"
    fail_dump t_volume_wipe_same_bucket_preserves_both "$name"
    return
  fi

  # Cluster C's full is at its own path.
  local c_fulls
  c_fulls=$(count_backups_of_type "$name" full)
  if [ "${c_fulls:-0}" -lt 1 ]; then
    ko t_volume_wipe_same_bucket_preserves_both "cluster C's full not visible; got $c_fulls"
    return
  fi

  # No archive-push errors on cluster C — its archive_command pushes to
  # the new per-cluster path, no system-id collision.
  local failed_count
  failed_count=$(docker exec "$name" psql -U postgres -At -c "SELECT failed_count FROM pg_stat_archiver" 2>/dev/null || echo 0)
  if [ "${failed_count:-0}" -gt 0 ]; then
    ko t_volume_wipe_same_bucket_preserves_both "cluster C had archive failures (expected zero); got $failed_count"
    fail_dump t_volume_wipe_same_bucket_preserves_both "$name"
    return
  fi

  ok t_volume_wipe_same_bucket_preserves_both
  note "A=cluster-${sysid_a} (${a_fulls} full), C=cluster-${sysid_c} (${c_fulls} full); both in bucket"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

# Bring an archiving cluster on the source major up to "has a full backup at
# cluster-<sysid>", then shut it down cleanly and upgrade the volume in place.
# Shared by the two re-anchor tests below; exports SYSID_A / PATH_A /
# OLD_OBJECTS_BEFORE for their assertions. Returns non-zero after recording its
# own ko(), so callers just `return`.
seed_upgraded_volume() {
  local test_name="$1" name="$2" vol="$3"
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true

  ARCHIVING_PG_IMAGE="$UPG_FROM_IMAGE" run_archiving_pg_fast_watcher "$name" "$vol" \
    -e "PGDATA=$PGDATA_IN_VOLUME"
  if ! wait_for_pg "$name"; then
    ko "$test_name" "source major (${UPG_FROM_VERSION}) did not start"
    fail_dump "$test_name" "$name"
    return 1
  fi
  # Wait for the stanza before generating WAL: archive-push against a repo with
  # no stanza fails, and this test has no business exercising that race.
  for _ in $(seq 1 20); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c \
    "CREATE TABLE upgrade_canary(id int); INSERT INTO upgrade_canary SELECT generate_series(1,1000); SELECT pg_switch_wal();" >/dev/null
  if ! wait_for_watcher_backup "$name" full 90; then
    ko "$test_name" "no initial full on the source major"
    fail_dump "$test_name" "$name"
    return 1
  fi

  SYSID_A=$(cluster_sysid "$name" "$PGDATA_IN_VOLUME")
  PATH_A=$(docker exec "$name" cat "$PGDATA_IN_VOLUME/.pgbackrest_repo_path" 2>/dev/null)
  local anchor_a
  anchor_a=$(docker exec "$name" cat "$PGDATA_IN_VOLUME/.pgbackrest_repo_anchor" 2>/dev/null | tr '\n' ' ')

  if [ -z "$SYSID_A" ] || [ "$PATH_A" != "/pgbackrest/cluster-${SYSID_A}" ]; then
    ko "$test_name" "source cluster's marker is not its own per-cluster path: sysid=${SYSID_A}, marker=${PATH_A}"
    fail_dump "$test_name" "$name"
    return 1
  fi
  # The anchor must be seeded by initdb (pgbackrest-init.sh), not adopted later:
  # a fresh cluster's fingerprint has to be the derived one.
  case "$anchor_a" in
    *"sysid=${SYSID_A}"*"pg_version=${UPG_FROM_VERSION}"*) ;;
    *)
      ko "$test_name" "source anchor should name sysid=${SYSID_A} pg_version=${UPG_FROM_VERSION}, got '${anchor_a}'"
      fail_dump "$test_name" "$name"
      return 1 ;;
  esac

  local src_objects
  src_objects=$(bucket_objects_under "$PATH_A")
  if [ "${src_objects:-0}" -lt 1 ]; then
    ko "$test_name" "source cluster archived nothing under ${PATH_A}"
    fail_dump "$test_name" "$name"
    return 1
  fi

  stop_pg_clean "$name" "$PGDATA_IN_VOLUME"

  run_upgrade_job "$vol" upgrade
  if [ "$JOB_RC" != "0" ]; then
    ko "$test_name" "upgrade job failed (rc=${JOB_RC})"
    echo "$JOB_OUT" | tail -20
    return 1
  fi

  # Baseline for "the upgraded cluster never wrote to the previous cluster's
  # prefix" — taken here, with the source stopped and the upgrade done, not
  # before the shutdown: a clean `pg_ctl stop` switches WAL and archives the
  # shutdown checkpoint's segment, so a pre-shutdown count is one object short
  # of the real starting state through no fault of the upgraded cluster. The
  # upgrade job itself never touches S3.
  OLD_OBJECTS_BEFORE=$(bucket_objects_under "$PATH_A")
  return 0
}

# After the upgraded database boots, wait for a full backup to land and assert
# the whole end state: WAL and a full under the NEW cluster prefix, the previous
# cluster's prefix untouched, marker + anchor naming the new identity, data
# intact. Shared by both re-anchor tests. Returns non-zero after its own ko().
assert_reanchored_end_state() {
  local test_name="$1" name="$2" sysid_b="$3"
  local path_b="/pgbackrest/cluster-${sysid_b}"

  # A successful full is the end-to-end proof that archiving works at the new
  # path: `pgbackrest backup` brackets pg_backup_start/stop and waits for the
  # closing WAL segment to be archived before reporting success, so it cannot
  # succeed while archive-push is failing. Keep switching WAL while we wait —
  # an idle cluster only produces a segment per archive_timeout.
  local deadline=$(($(date +%s) + 150)) got_full=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker logs "$name" 2>&1 | grep -q "pgbackrest-watcher: backup --type=full completed"; then
      got_full=1; break
    fi
    docker exec "$name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null 2>&1
    sleep 3
  done
  if [ "$got_full" != "1" ]; then
    ko "$test_name" "no full backup landed after the upgrade"
    fail_dump "$test_name" "$name"
    return 1
  fi

  local wal_objects
  wal_objects=$(bucket_objects_under "${path_b}/archive/main")
  if [ "${wal_objects:-0}" -lt 1 ]; then
    ko "$test_name" "no WAL under the new cluster prefix ${path_b}/archive/main"
    fail_dump "$test_name" "$name"
    return 1
  fi

  local new_fulls
  new_fulls=$(count_backups_at_path "$name" full "$path_b")
  if [ "${new_fulls:-0}" -lt 1 ]; then
    ko "$test_name" "no full visible at ${path_b}; got ${new_fulls}"
    fail_dump "$test_name" "$name"
    return 1
  fi

  # The previous cluster's history is untouched — same object count as before
  # the upgrade, and its own full still browsable. This is what keeps the
  # pre-upgrade PITR window restorable from mono's history picker.
  local old_objects_after old_fulls
  old_objects_after=$(bucket_objects_under "$PATH_A")
  if [ "${old_objects_after:-0}" != "${OLD_OBJECTS_BEFORE:-0}" ]; then
    ko "$test_name" "previous cluster's prefix ${PATH_A} changed: ${OLD_OBJECTS_BEFORE} objects before, ${old_objects_after} after"
    fail_dump "$test_name" "$name"
    return 1
  fi
  old_fulls=$(count_backups_at_path "$name" full "$PATH_A")
  if [ "${old_fulls:-0}" -lt 1 ]; then
    ko "$test_name" "previous cluster's full no longer visible at ${PATH_A}; got ${old_fulls}"
    fail_dump "$test_name" "$name"
    return 1
  fi

  local canary
  canary=$(docker exec "$name" psql -U postgres -At -c "SELECT count(*) FROM upgrade_canary" 2>/dev/null)
  if [ "$canary" != "1000" ]; then
    ko "$test_name" "upgraded data missing: expected 1000 canary rows, got '${canary}'"
    fail_dump "$test_name" "$name"
    return 1
  fi
  return 0
}

# A major upgrade REPLACES the cluster: pg_upgrade initdb's the target and the
# job swaps it into place, so the service comes back with a new
# system_identifier and a new PG_VERSION. Archiving has to follow it onto
# `cluster-<new_sysid>` — the previous cluster's repo records the old system id
# in its archive.info, so every archive-push against it fails and stanza-create
# refuses the mismatch outright.
#
# This is the natural path (the job's directory swap promotes a freshly initdb'd
# data dir, so the upgraded PGDATA inherits none of the old cluster's pgbackrest
# files and the path is derived fresh). t_reanchor_stale_marker_after_upgrade
# below covers the same upgrade with the old cluster's marker surviving into it.
t_upgrade_archive_reanchors_to_new_cluster_path() {
  local name=t-upg-reanchor-${PG_VERSION}
  local vol=${name}-vol
  if ! ensure_upgrade_images; then
    ko "${FUNCNAME[0]}" "could not build the upgrade-pair images"
    return
  fi
  seed_upgraded_volume "${FUNCNAME[0]}" "$name" "$vol" || return

  run_archiving_pg_fast_watcher "$name" "$vol" -e "PGDATA=$PGDATA_IN_VOLUME"
  if ! wait_for_pg "$name"; then
    ko "${FUNCNAME[0]}" "upgraded database (${PG_VERSION}) did not start"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi
  for _ in $(seq 1 20); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done

  local sysid_b path_b anchor_b
  sysid_b=$(cluster_sysid "$name" "$PGDATA_IN_VOLUME")
  path_b=$(docker exec "$name" cat "$PGDATA_IN_VOLUME/.pgbackrest_repo_path" 2>/dev/null)
  anchor_b=$(docker exec "$name" cat "$PGDATA_IN_VOLUME/.pgbackrest_repo_anchor" 2>/dev/null | tr '\n' ' ')

  if [ -z "$sysid_b" ] || [ "$sysid_b" = "$SYSID_A" ]; then
    ko "${FUNCNAME[0]}" "pg_upgrade should have produced a new system_identifier; got '${sysid_b}' (was '${SYSID_A}')"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi
  if [ "$path_b" != "/pgbackrest/cluster-${sysid_b}" ]; then
    ko "${FUNCNAME[0]}" "marker should be /pgbackrest/cluster-${sysid_b}, got '${path_b}'"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi
  case "$anchor_b" in
    *"sysid=${sysid_b}"*"pg_version=${PG_VERSION}"*) ;;
    *)
      ko "${FUNCNAME[0]}" "anchor should name sysid=${sysid_b} pg_version=${PG_VERSION}, got '${anchor_b}'"
      fail_dump "${FUNCNAME[0]}" "$name"
      return ;;
  esac

  assert_reanchored_end_state "${FUNCNAME[0]}" "$name" "$sysid_b" || return

  ok "${FUNCNAME[0]}"
  note "upgrade ${UPG_FROM_VERSION}→${PG_VERSION} moved archiving ${PATH_A} → ${path_b}; old prefix untouched (${OLD_OBJECTS_BEFORE} objects)"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

# The same upgrade, but with the previous cluster's pgbackrest state surviving
# into the upgraded data directory: a stale repo-path marker, its anchor, a
# backup state claiming a recent full, and a stale async spool status.
#
# Today's job reaches the upgraded state by swapping in a fresh data directory,
# which drops all of that — so this plants it deliberately. That is not a
# hypothetical shape: it is what any upgrade route that carries $PGDATA's
# configuration forward produces, and what the legacy PGDATA-is-the-volume-root
# layout produces by construction (those files live outside the swapped
# directory). With the marker winning verbatim, the upgraded cluster would
# archive into the previous cluster's repo forever.
#
# Everything asserted here is boot-time behavior: the flip happens before
# postgres starts, so no WAL is ever pushed at the stale path.
t_reanchor_stale_marker_after_upgrade() {
  local name=t-upg-stalemarker-${PG_VERSION}
  local vol=${name}-vol
  if ! ensure_upgrade_images; then
    ko "${FUNCNAME[0]}" "could not build the upgrade-pair images"
    return
  fi
  seed_upgraded_volume "${FUNCNAME[0]}" "$name" "$vol" || return

  # Plant the previous cluster's state into the upgraded data directory.
  # last_full_at/last_diff_at are far-future so that a full backup can only
  # come from the re-anchor resetting this file — not from the periodic
  # schedule and not from NEEDS_INITIAL_BACKUP on empty state.
  local stale_ok="000000010000000000000009.ok"
  if ! in_stopped_volume "$vol" "
    set -e
    D=$PGDATA_IN_VOLUME
    echo '${PATH_A}' > \$D/.pgbackrest_repo_path
    printf 'sysid=%s\npg_version=%s\n' '${SYSID_A}' '${UPG_FROM_VERSION}' > \$D/.pgbackrest_repo_anchor
    printf 'last_full_at=%s\nlast_diff_at=%s\n' 9999999999 9999999999 > \$D/.pgbackrest_backup_state
    mkdir -p \$D/pgbackrest-spool/archive/main/out
    printf '0\nstale ok from the previous cluster\n' > \$D/pgbackrest-spool/archive/main/out/${stale_ok}
    chown -R postgres:postgres \$D/.pgbackrest_repo_path \$D/.pgbackrest_repo_anchor \
      \$D/.pgbackrest_backup_state \$D/pgbackrest-spool
  " >/dev/null 2>&1; then
    ko "${FUNCNAME[0]}" "could not plant the previous cluster's pgbackrest state"
    return
  fi

  run_archiving_pg_fast_watcher "$name" "$vol" -e "PGDATA=$PGDATA_IN_VOLUME"
  if ! wait_for_pg "$name"; then
    ko "${FUNCNAME[0]}" "upgraded database (${PG_VERSION}) did not start"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi

  local sysid_b path_b anchor_b
  sysid_b=$(cluster_sysid "$name" "$PGDATA_IN_VOLUME")
  local expected_path="/pgbackrest/cluster-${sysid_b}"

  # The re-anchor must be reported, and must name both identities — this line is
  # the only signal an operator gets that a service's archive prefix moved.
  if ! wait_for_log_line "$name" "cluster re-identified" 30; then
    ko "${FUNCNAME[0]}" "boot did not detect the re-identified cluster"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi
  if ! wait_for_log_line "$name" "re-anchored to ${expected_path}" 30; then
    ko "${FUNCNAME[0]}" "boot did not report re-anchoring to ${expected_path}"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi

  path_b=$(docker exec "$name" cat "$PGDATA_IN_VOLUME/.pgbackrest_repo_path" 2>/dev/null)
  anchor_b=$(docker exec "$name" cat "$PGDATA_IN_VOLUME/.pgbackrest_repo_anchor" 2>/dev/null | tr '\n' ' ')
  if [ "$path_b" != "$expected_path" ]; then
    ko "${FUNCNAME[0]}" "marker should have flipped to ${expected_path}, got '${path_b}'"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi
  case "$anchor_b" in
    *"sysid=${sysid_b}"*"pg_version=${PG_VERSION}"*) ;;
    *)
      ko "${FUNCNAME[0]}" "anchor should name sysid=${sysid_b} pg_version=${PG_VERSION}, got '${anchor_b}'"
      fail_dump "${FUNCNAME[0]}" "$name"
      return ;;
  esac

  # The rendered conf follows the marker, for `pgbackrest info` callers that
  # don't go through the PGBACKREST_REPO1_PATH override.
  local conf_path
  conf_path=$(docker exec "$name" grep -E "^repo1-path=" /etc/pgbackrest/pgbackrest.conf 2>/dev/null | cut -d= -f2-)
  if [ "$conf_path" != "$expected_path" ]; then
    ko "${FUNCNAME[0]}" "pgbackrest.conf repo1-path should be ${expected_path}, got '${conf_path}'"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi

  # A stale `.ok` is the dangerous leftover: pgBackRest reads it as proof the
  # segment was already pushed and skips the upload, silently punching a hole in
  # the new path's WAL coverage.
  if docker exec "$name" test -e "$PGDATA_IN_VOLUME/pgbackrest-spool/archive/main/out/${stale_ok}"; then
    ko "${FUNCNAME[0]}" "stale async status ${stale_ok} survived the re-anchor"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi

  # The migration gate must end up released, or the watcher never backs up again.
  local pending
  pending=$(docker exec "$name" grep -E "^archive_migration_pending_new_path=" \
    "$PGDATA_IN_VOLUME/.pgbackrest_backup_state" 2>/dev/null | cut -d= -f2-)
  if [ -n "$pending" ]; then
    ko "${FUNCNAME[0]}" "archive_migration_pending_new_path should be clear after the re-anchor, got '${pending}'"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi

  assert_reanchored_end_state "${FUNCNAME[0]}" "$name" "$sysid_b" || return

  ok "${FUNCNAME[0]}"
  note "stale marker at ${PATH_A} re-anchored to ${expected_path} before postgres started; planted state reset, spool cleaned"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

# Fleet safety for the rollout itself: a volume that predates the anchor file
# has a marker and no fingerprint. That must ADOPT the live identity for the
# path it already archives to, never re-anchor — "no fingerprint" is not
# evidence of a changed cluster, and treating it as one would move every
# existing PITR-enabled service to a fresh prefix on its next redeploy,
# orphaning its whole restore history.
t_reanchor_backfills_missing_anchor() {
  local name=t-anchor-backfill-${PG_VERSION}
  local vol=${name}-vol
  if ! rebuild_image; then
    ko "${FUNCNAME[0]}" "could not rebuild $IMAGE"
    return
  fi
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true

  run_archiving_pg_fast_watcher "$name" "$vol"
  if ! wait_for_pg "$name"; then
    ko "${FUNCNAME[0]}" "no startup"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi
  # Poll rather than single-shot: wait_for_pg's socket probe also answers for
  # docker-entrypoint's TEMPORARY initdb-time server, so under suite load this
  # read can land before 99-pgbackrest-init.sh has written the marker. The
  # marker is guaranteed by END of init; give it a bounded window.
  local path_before="" _deadline=$(($(date +%s) + 30))
  while [ "$(date +%s)" -lt "$_deadline" ]; do
    path_before=$(docker exec "$name" cat /var/lib/postgresql/data/.pgbackrest_repo_path 2>/dev/null)
    [ -n "$path_before" ] && break
    sleep 1
  done
  if [ -z "$path_before" ]; then
    ko "${FUNCNAME[0]}" "no repo-path marker after first boot"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi

  # Reproduce a pre-anchor volume: marker present, fingerprint absent.
  docker exec "$name" rm -f /var/lib/postgresql/data/.pgbackrest_repo_anchor
  docker restart "$name" >/dev/null
  if ! wait_for_pg "$name"; then
    ko "${FUNCNAME[0]}" "no startup after removing the anchor"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi

  if ! wait_for_log_line "$name" "adopted repo-path anchor" 30; then
    ko "${FUNCNAME[0]}" "boot did not adopt an anchor for the existing marker"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi
  if docker logs "$name" 2>&1 | grep -q "cluster re-identified"; then
    ko "${FUNCNAME[0]}" "a missing anchor was treated as a re-identified cluster"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi

  local path_after anchor_after sysid
  path_after=$(docker exec "$name" cat /var/lib/postgresql/data/.pgbackrest_repo_path 2>/dev/null)
  anchor_after=$(docker exec "$name" cat /var/lib/postgresql/data/.pgbackrest_repo_anchor 2>/dev/null | tr '\n' ' ')
  sysid=$(cluster_sysid "$name")
  if [ "$path_after" != "$path_before" ]; then
    ko "${FUNCNAME[0]}" "archive path moved on a missing anchor: '${path_before}' → '${path_after}'"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi
  case "$anchor_after" in
    *"sysid=${sysid}"*"pg_version=${PG_VERSION}"*) ;;
    *)
      ko "${FUNCNAME[0]}" "adopted anchor should name sysid=${sysid} pg_version=${PG_VERSION}, got '${anchor_after}'"
      fail_dump "${FUNCNAME[0]}" "$name"
      return ;;
  esac

  ok "${FUNCNAME[0]}"
  note "missing anchor adopted (sysid=${sysid}); archive path stayed at ${path_after}"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

# The migration machinery's state fields were wal_regression_* before the
# boot-time re-anchor started sharing them. A volume that redeploys onto the
# renaming image carries the old names, and the in-flight case is the one that
# matters: a pending migration recorded under the old name must keep gating
# backups and still finalize, not silently read as "nothing pending" and let the
# watcher back up against stale old-path spool statuses.
#
# Plants a pending migration equal to the live marker — the shape left by an
# attempt that flipped the marker and died before cleanup — so the watcher's
# finalize path has to pick it up through the renamed field.
t_legacy_wal_regression_state_fields_migrate() {
  local name=t-legacy-state-${PG_VERSION}
  local vol=${name}-vol
  if ! rebuild_image; then
    ko "${FUNCNAME[0]}" "could not rebuild $IMAGE"
    return
  fi
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true

  run_archiving_pg_fast_watcher "$name" "$vol"
  if ! wait_for_pg "$name"; then
    ko "${FUNCNAME[0]}" "no startup"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi
  for _ in $(seq 1 20); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c "CREATE TABLE t(id int); SELECT pg_switch_wal();" >/dev/null
  if ! wait_for_watcher_backup "$name" full 90; then
    ko "${FUNCNAME[0]}" "no initial full"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi

  local marker_path legacy_orig
  marker_path=$(docker exec "$name" cat /var/lib/postgresql/data/.pgbackrest_repo_path 2>/dev/null)
  legacy_orig="/pgbackrest/cluster-legacy-orig"
  if ! docker exec -u postgres "$name" sh -c "
    printf 'wal_regression_orig_path=%s\nwal_regression_pending_new_path=%s\n' \
      '${legacy_orig}' '${marker_path}' >> /var/lib/postgresql/data/.pgbackrest_backup_state
  "; then
    ko "${FUNCNAME[0]}" "could not plant legacy state fields"
    return
  fi

  docker restart "$name" >/dev/null
  if ! wait_for_pg "$name"; then
    ko "${FUNCNAME[0]}" "no startup after planting legacy state fields"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi

  if ! wait_for_log_line "$name" "state: renamed wal_regression_pending_new_path" 60; then
    ko "${FUNCNAME[0]}" "watcher did not rename the legacy pending field"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi

  # The renamed field must carry its VALUE, and must be the field the finalize
  # path actually reads — a rename that missed a reader would leave the gate
  # stuck and the watcher permanently silent.
  if ! wait_for_log_line "$name" "archive-migration: finalizing pending archive-path migration at ${marker_path}" 60; then
    ko "${FUNCNAME[0]}" "planted pending migration was not finalized through the renamed field"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi

  local leftover orig_after pending_after
  leftover=$(docker exec "$name" grep -cE "^wal_regression_" /var/lib/postgresql/data/.pgbackrest_backup_state 2>/dev/null || true)
  if [ "${leftover:-0}" != "0" ]; then
    ko "${FUNCNAME[0]}" "legacy wal_regression_* lines survived the rename (${leftover} left)"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi
  orig_after=$(docker exec "$name" grep -E "^archive_migration_orig_path=" \
    /var/lib/postgresql/data/.pgbackrest_backup_state 2>/dev/null | cut -d= -f2-)
  if [ "$orig_after" != "$legacy_orig" ]; then
    ko "${FUNCNAME[0]}" "archive_migration_orig_path should carry '${legacy_orig}', got '${orig_after}'"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi
  pending_after=$(docker exec "$name" grep -E "^archive_migration_pending_new_path=" \
    /var/lib/postgresql/data/.pgbackrest_backup_state 2>/dev/null | cut -d= -f2-)
  if [ -n "$pending_after" ]; then
    ko "${FUNCNAME[0]}" "the migration gate should be released after finalize, got '${pending_after}'"
    fail_dump "${FUNCNAME[0]}" "$name"
    return
  fi

  ok "${FUNCNAME[0]}"
  note "legacy wal_regression_* fields renamed in place; pending migration at ${marker_path} finalized through the new name"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

# E2. Restore + change recovery target after promote → no-op. Pins the
# README guarantee that a different POSTGRES_RECOVERY_TARGET_TIME on a
# subsequent boot is ignored once .pitr_configured / .pgbackrest_restored
# is set. Replaying again on a promoted timeline would corrupt the cluster.
t_restore_change_target_after_promote_noop() {
  setup_pitr_source >&2 || { ko "${FUNCNAME[0]}" "setup_pitr_source failed"; return; }
  read -r src_name src_vol < "/tmp/pitr-source-${PG_VERSION}"
  local target_t1; target_t1=$(cat "/tmp/pitr-target-${PG_VERSION}")
  local src_path; src_path=$(pitr_source_path)
  local rest_name=t-target-noop-${PG_VERSION}
  local rest_vol=${rest_name}-vol
  new_volume "$rest_vol"

  docker rm -f "$rest_name" >/dev/null 2>&1 || true
  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=$MINIO_USER \
    -e WAL_RECOVER_FROM_SECRET=$MINIO_PASS \
    -e "WAL_RECOVER_FROM_PATH=$src_path" \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e "POSTGRES_RECOVERY_TARGET_TIME=$target_t1" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$rest_name" || { ko t_restore_change_target_after_promote_noop "first boot"; fail_dump t_restore_change_target_after_promote_noop "$rest_name"; return; }
  wait_for_promoted "$rest_name" || { ko t_restore_change_target_after_promote_noop "first boot did not promote in time"; fail_dump t_restore_change_target_after_promote_noop "$rest_name"; return; }
  local rows_t1
  rows_t1=$(docker exec "$rest_name" psql -U postgres -At -c "SELECT count(*) FROM pitrtest WHERE id IN (2,3)")
  assert_eq "$rows_t1" "0" "T1 restore: rows after T1 absent" || { ko t_restore_change_target_after_promote_noop ""; return; }

  # Restart with a different (much later) target. The marker(s) must keep
  # recovery from re-running.
  docker rm -f "$rest_name" >/dev/null
  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=$MINIO_USER \
    -e WAL_RECOVER_FROM_SECRET=$MINIO_PASS \
    -e "WAL_RECOVER_FROM_PATH=$src_path" \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e "POSTGRES_RECOVERY_TARGET_TIME=2099-01-01 00:00:00+00" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$rest_name" || { ko t_restore_change_target_after_promote_noop "restart"; fail_dump t_restore_change_target_after_promote_noop "$rest_name"; return; }

  # No new restore: PG_VERSION already exists, restore_from_pgbackrest_if_empty_volume
  # bails on the populated-volume check.
  if docker logs "$rest_name" 2>&1 | grep -q "restoring from source bucket"; then
    ko t_restore_change_target_after_promote_noop "wrapper attempted a second restore on populated volume"
    fail_dump t_restore_change_target_after_promote_noop "$rest_name"
    return
  fi
  # No new conf.d/pgbackrest-recovery.conf written either.
  if docker exec "$rest_name" test -f /var/lib/postgresql/data/conf.d/pgbackrest-recovery.conf; then
    ko t_restore_change_target_after_promote_noop "conf.d/pgbackrest-recovery.conf reappeared after restart"
    return
  fi
  # T1 contents preserved — T2 was ignored, no new replay happened.
  local rows_after
  rows_after=$(docker exec "$rest_name" psql -U postgres -At -c "SELECT count(*) FROM pitrtest WHERE id IN (2,3)")
  assert_eq "$rows_after" "0" "after-T2 rows still absent (T2 ignored)" || { ko t_restore_change_target_after_promote_noop ""; return; }
  local rows_id1
  rows_id1=$(docker exec "$rest_name" psql -U postgres -At -c "SELECT count(*) FROM pitrtest WHERE id=1")
  assert_eq "$rows_id1" "1" "id=1 still present" || { ko t_restore_change_target_after_promote_noop ""; return; }

  ok t_restore_change_target_after_promote_noop
  note "T2 (2099) ignored on second boot; cluster stayed on T1 timeline"
  docker rm -f "$src_name" "$rest_name" >/dev/null
  docker volume rm "$src_vol" "$rest_vol" >/dev/null
}

# E3. Restore → wipe volume → re-restore is idempotent. Wrapper runs
# pgbackrest restore again on the empty volume; same env vars produce the
# same outcome. Documents the "force a re-stage by wiping the volume"
# operator pattern.
t_restore_then_wipe_volume_redoes_restore() {
  setup_pitr_source >&2 || { ko "${FUNCNAME[0]}" "setup_pitr_source failed"; return; }
  read -r src_name src_vol < "/tmp/pitr-source-${PG_VERSION}"
  local target; target=$(cat "/tmp/pitr-target-${PG_VERSION}")
  local src_path; src_path=$(pitr_source_path)
  local rest_name=t-redo-${PG_VERSION}
  local rest_vol=${rest_name}-vol
  new_volume "$rest_vol"
  docker rm -f "$rest_name" >/dev/null 2>&1 || true

  local restore_env=(
    -e POSTGRES_PASSWORD=test
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET"
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000"
    -e WAL_RECOVER_FROM_REGION=us-east-1
    -e "WAL_RECOVER_FROM_KEY=$MINIO_USER"
    -e "WAL_RECOVER_FROM_SECRET=$MINIO_PASS"
    -e "WAL_RECOVER_FROM_PATH=$src_path"
    -e PGBACKREST_REPO1_S3_URI_STYLE=path
    -e "POSTGRES_RECOVERY_TARGET_TIME=$target"
  )

  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    "${restore_env[@]}" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$rest_name" || { ko t_restore_then_wipe_volume_redoes_restore "1st boot"; fail_dump t_restore_then_wipe_volume_redoes_restore "$rest_name"; return; }
  wait_for_promoted "$rest_name" || { ko t_restore_then_wipe_volume_redoes_restore "1st boot did not promote"; fail_dump t_restore_then_wipe_volume_redoes_restore "$rest_name"; return; }
  if ! docker exec "$rest_name" test -f /var/lib/postgresql/data/.pgbackrest_restored; then
    ko t_restore_then_wipe_volume_redoes_restore "1st boot didn't write .pgbackrest_restored"
    return
  fi

  # Wipe volume + redeploy with identical env. wrapper must run pgbackrest
  # restore again from scratch. new_volume() handles container-still-holds-
  # volume races that bare `docker volume rm` doesn't — without it, the wipe
  # silently no-ops and the .pgbackrest_restored marker from the first boot
  # short-circuits restore_from_pgbackrest_if_empty_volume.
  docker rm -f "$rest_name" >/dev/null
  new_volume "$rest_vol"

  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    "${restore_env[@]}" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$rest_name" || { ko t_restore_then_wipe_volume_redoes_restore "2nd boot after wipe"; fail_dump t_restore_then_wipe_volume_redoes_restore "$rest_name"; return; }

  # Poll for the restore log line — wrapper writes it before pgbackrest
  # actually runs, so wait_for_pg returning should be sufficient evidence
  # that the line is in the buffer. Use a generous deadline anyway —
  # docker's json-file log shipping has been observed to lag a few
  # seconds beyond wait_for_pg under suite-load on slow runners.
  local deadline=$(($(date +%s) + 30)) hit=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker logs "$rest_name" 2>&1 | grep -q "restoring from source bucket"; then
      hit=1; break
    fi
    sleep 1
  done
  if [ "$hit" != "1" ]; then
    ko t_restore_then_wipe_volume_redoes_restore "2nd boot did not re-run pgbackrest restore"
    fail_dump t_restore_then_wipe_volume_redoes_restore "$rest_name"
    return
  fi
  if ! docker exec "$rest_name" test -f /var/lib/postgresql/data/.pgbackrest_restored; then
    ko t_restore_then_wipe_volume_redoes_restore "2nd boot didn't re-write .pgbackrest_restored"
    return
  fi
  # Same data outcome as 1st boot: id=1 present, id=2,3 absent.
  local rows_after
  rows_after=$(docker exec "$rest_name" psql -U postgres -At -c "SELECT count(*) FROM pitrtest WHERE id IN (2,3)")
  assert_eq "$rows_after" "0" "id=2,3 absent in re-restored cluster" || { ko t_restore_then_wipe_volume_redoes_restore ""; return; }

  ok t_restore_then_wipe_volume_redoes_restore
  note "wipe + redeploy → wrapper re-restored from source"
  docker rm -f "$src_name" "$rest_name" >/dev/null
  docker volume rm "$src_vol" "$rest_vol" >/dev/null
}

# E4. Restore + add WAL_ARCHIVE_* without clearing recover-from → dual-repo
# A restored service that's already promoted (.pgbackrest_restored marker
# present, recovery.signal consumed by Postgres) must be able to opt into
# archiving by adding WAL_ARCHIVE_* on a subsequent restart, even if the
# recover-from vars are still set. The post-promote repo2-drop in
# render_pgbackrest_conf keeps archive-push pointed at REPO1 only.
t_restored_service_can_enable_archive_after_promote() {
  setup_pitr_source >&2 || { ko "${FUNCNAME[0]}" "setup_pitr_source failed"; return; }
  read -r src_name src_vol < "/tmp/pitr-source-${PG_VERSION}"
  local target; target=$(cat "/tmp/pitr-target-${PG_VERSION}")
  local src_path; src_path=$(pitr_source_path)
  local rest_name=t-postpromote-archive-${PG_VERSION}
  local rest_vol=${rest_name}-vol
  local new_bucket=pgbackrest-restored
  new_volume "$rest_vol"

  # Read-only creds on the source bucket — production parallel.
  mc 'mc admin user add local roenable roenable123pass >/dev/null 2>&1 || true
      cat > /tmp/p-roenable.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject","s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::*"]}]}
EOF
      mc admin policy create local roenable /tmp/p-roenable.json >/dev/null 2>&1 || true
      mc admin policy attach local roenable --user roenable >/dev/null 2>&1 || true' >/dev/null

  mc "mc rm -r --force local/${new_bucket} >/dev/null 2>&1; mc mb -p local/${new_bucket} >/dev/null"

  # Phase 1: restore → cluster running, recovery.signal consumed at promote.
  docker rm -f "$rest_name" >/dev/null 2>&1 || true
  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=roenable \
    -e WAL_RECOVER_FROM_SECRET=roenable123pass \
    -e "WAL_RECOVER_FROM_PATH=$src_path" \
    -e "POSTGRES_RECOVERY_TARGET_TIME=$target" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$rest_name" || { ko t_restored_service_can_enable_archive_after_promote "phase1 wait_for_pg"; fail_dump t_restored_service_can_enable_archive_after_promote "$rest_name"; return; }
  wait_for_promoted "$rest_name" || { ko t_restored_service_can_enable_archive_after_promote "phase1 promote"; fail_dump t_restored_service_can_enable_archive_after_promote "$rest_name"; return; }

  # Sanity: .pgbackrest_restored marker should be present after promote.
  # configure_pgbackrest_recovery doesn't touch .pitr_configured on this
  # flow — .pgbackrest_restored is the single durable "we did a restore"
  # marker and it's enough for render_pgbackrest_conf to recognise post-
  # promote on subsequent boots.
  if ! docker exec "$rest_name" test -f /var/lib/postgresql/data/.pgbackrest_restored; then
    ko t_restored_service_can_enable_archive_after_promote ".pgbackrest_restored marker missing after restore"
    fail_dump t_restored_service_can_enable_archive_after_promote "$rest_name"
    return
  fi

  # Phase 2: add WAL_ARCHIVE_* with recover-from vars STILL set, on a
  # restart (so render_pgbackrest_conf sees no recovery.signal +
  # .pgbackrest_restored → drops repo2 from rendered config).
  docker rm -f "$rest_name" >/dev/null
  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=roenable \
    -e WAL_RECOVER_FROM_SECRET=roenable123pass \
    -e "WAL_RECOVER_FROM_PATH=$src_path" \
    -e "WAL_ARCHIVE_BUCKET=$new_bucket" \
    -e "WAL_ARCHIVE_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_ARCHIVE_REGION=us-east-1 \
    -e WAL_ARCHIVE_KEY=$MINIO_USER \
    -e WAL_ARCHIVE_SECRET=$MINIO_PASS \
    -e WAL_ARCHIVE_PATH=/pgbackrest \
    -e WAL_BACKUP_POLL_INTERVAL_SECONDS=5 \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$rest_name" || { ko t_restored_service_can_enable_archive_after_promote "phase2 wait_for_pg"; fail_dump t_restored_service_can_enable_archive_after_promote "$rest_name"; return; }

  local source_count_before
  source_count_before=$(mc "mc ls --recursive local/${BUCKET} | wc -l" | tail -1 | tr -d ' ')

  docker exec "$rest_name" psql -U postgres -c "CREATE TABLE postarchive(id int); INSERT INTO postarchive VALUES (1); SELECT pg_switch_wal();" >/dev/null
  if ! wait_for_watcher_backup "$rest_name" full 90; then
    ko t_restored_service_can_enable_archive_after_promote "watcher did not take initial full into new bucket"
    fail_dump t_restored_service_can_enable_archive_after_promote "$rest_name"
    return
  fi

  local new_bucket_objects
  new_bucket_objects=$(mc "mc ls --recursive local/${new_bucket} 2>/dev/null | wc -l" | tail -1 | tr -d ' ')
  if [ "${new_bucket_objects:-0}" -lt 5 ]; then
    ko t_restored_service_can_enable_archive_after_promote "new bucket should have backup files; got $new_bucket_objects"
    return
  fi

  local source_count_after
  source_count_after=$(mc "mc ls --recursive local/${BUCKET} | wc -l" | tail -1 | tr -d ' ')
  if [ "$source_count_after" -ne "$source_count_before" ]; then
    ko t_restored_service_can_enable_archive_after_promote "source bucket leaked writes; before=$source_count_before after=$source_count_after"
    return
  fi

  ok t_restored_service_can_enable_archive_after_promote
  note "post-promote archive-add wrote $new_bucket_objects to new bucket; source untouched"
  mc "mc rm -r --force local/${new_bucket}" >/dev/null 2>&1 || true
  docker rm -f "$src_name" "$rest_name" >/dev/null
  docker volume rm "$src_vol" "$rest_vol" >/dev/null
}

# E5. Restored marker persists across restarts. Once .pgbackrest_restored
# is set, configure_pgbackrest_recovery must early-return on every
# subsequent boot — no duplicate recovery.signal, no duplicate conf.d
# include. Catches a regression where a future change forgets to gate
# on the marker.
t_restored_marker_persists_across_restarts() {
  setup_pitr_source >&2 || { ko "${FUNCNAME[0]}" "setup_pitr_source failed"; return; }
  read -r src_name src_vol < "/tmp/pitr-source-${PG_VERSION}"
  local target; target=$(cat "/tmp/pitr-target-${PG_VERSION}")
  local src_path; src_path=$(pitr_source_path)
  local rest_name=t-marker-persist-${PG_VERSION}
  local rest_vol=${rest_name}-vol
  new_volume "$rest_vol"
  docker rm -f "$rest_name" >/dev/null 2>&1 || true

  local restore_env=(
    -e POSTGRES_PASSWORD=test
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET"
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000"
    -e WAL_RECOVER_FROM_REGION=us-east-1
    -e "WAL_RECOVER_FROM_KEY=$MINIO_USER"
    -e "WAL_RECOVER_FROM_SECRET=$MINIO_PASS"
    -e "WAL_RECOVER_FROM_PATH=$src_path"
    -e PGBACKREST_REPO1_S3_URI_STYLE=path
    -e "POSTGRES_RECOVERY_TARGET_TIME=$target"
  )

  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    "${restore_env[@]}" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$rest_name" || { ko t_restored_marker_persists_across_restarts "1st boot"; return; }
  wait_for_promoted "$rest_name" || { ko t_restored_marker_persists_across_restarts "1st boot did not promote"; fail_dump t_restored_marker_persists_across_restarts "$rest_name"; return; }

  if ! docker exec "$rest_name" test -f /var/lib/postgresql/data/.pgbackrest_restored; then
    ko t_restored_marker_persists_across_restarts "first boot didn't write .pgbackrest_restored"
    return
  fi

  # Restart with same env vars + same volume.
  docker rm -f "$rest_name" >/dev/null
  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    "${restore_env[@]}" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$rest_name" || { ko t_restored_marker_persists_across_restarts "2nd boot"; fail_dump t_restored_marker_persists_across_restarts "$rest_name"; return; }

  if ! docker exec "$rest_name" test -f /var/lib/postgresql/data/.pgbackrest_restored; then
    ko t_restored_marker_persists_across_restarts ".pgbackrest_restored disappeared on restart"
    return
  fi
  # configure_pgbackrest_recovery must NOT have rewritten the include —
  # restore already set its own recovery params; layering ours would be
  # a duplicate (and on a promoted timeline would break future starts).
  if docker exec "$rest_name" test -f /var/lib/postgresql/data/conf.d/pgbackrest-recovery.conf; then
    ko t_restored_marker_persists_across_restarts "conf.d/pgbackrest-recovery.conf reappeared after restart (marker not respected)"
    return
  fi
  # Wrapper logs from second boot must NOT show "PITR replay staged".
  # That message is emitted by configure_pgbackrest_recovery's else-branch.
  local replay_staged_count
  replay_staged_count=$(docker logs "$rest_name" 2>&1 | grep -c "PITR replay staged" || true)
  if [ "${replay_staged_count:-0}" -gt 0 ]; then
    ko t_restored_marker_persists_across_restarts "configure_pgbackrest_recovery re-staged on restart; marker not respected (count=$replay_staged_count)"
    fail_dump t_restored_marker_persists_across_restarts "$rest_name"
    return
  fi
  # /etc/pgbackrest/pgbackrest-recovery-source.conf carries the source
  # bucket's read credentials. Post-promote, archive_command uses the main
  # /etc/pgbackrest/pgbackrest.conf — the recovery-source conf is unused.
  # With .pgbackrest_restored present, configure_pgbackrest_recovery must
  # NOT rewrite it on every boot; otherwise we leak source creds onto
  # disk on every restart for no functional benefit.
  if docker exec "$rest_name" test -f /etc/pgbackrest/pgbackrest-recovery-source.conf; then
    ko t_restored_marker_persists_across_restarts "pgbackrest-recovery-source.conf rewritten post-promote (marker not gating)"
    fail_dump t_restored_marker_persists_across_restarts "$rest_name"
    return
  fi

  ok t_restored_marker_persists_across_restarts
  note ".pgbackrest_restored survived restart; configure_pgbackrest_recovery deferred"
  docker rm -f "$src_name" "$rest_name" >/dev/null
  docker volume rm "$src_vol" "$rest_vol" >/dev/null
}

# E6. Restarting WHILE still mid-replay (recovery.signal still present) must
# re-render pgbackrest-recovery-source.conf, even though .pgbackrest_restored
# is already set from the first boot's successful `pgbackrest restore` call.
# Production regression: a restore that crashed before promoting (e.g. ran
# out of disk) and got redeployed (fresh container, same volume) came back
# with pgbackrest-recovery-source.conf missing — configure_pgbackrest_recovery
# bailed on the marker alone, without checking whether recovery had actually
# finished. Postgres could then only replay local WAL and FATALed with
# "recovery ended before configured recovery target was reached", unable to
# reach the archive at all. This must NOT regress: the marker alone is not
# sufficient to skip re-rendering; recovery.signal must also be gone.
#
# Doesn't reuse setup_pitr_source: that source's backup-to-target gap is a
# handful of INSERTs, which promotes in well under a second — nowhere near
# enough of a replay window to reliably catch mid-flight. This test builds
# its own source with a bulk insert between the base backup and the target
# so recovery has real, measurable replay work, then force-kills the
# restore as soon as it accepts connections (wait_for_pg returns true
# during recovery, before promote) rather than racing a fixed sleep.
t_recovery_conf_persists_across_restart_mid_replay() {
  local src_name=t-src-heavy-${PG_VERSION}
  local src_vol=${src_name}-vol
  reset_bucket
  new_volume "$src_vol"
  docker rm -f "$src_name" >/dev/null 2>&1 || true
  run_archiving_pg "$src_name" "$src_vol" -e "WAL_HEARTBEAT_DISABLED=1"
  wait_for_pg "$src_name" || { ko t_recovery_conf_persists_across_restart_mid_replay "source did not start"; return; }
  for _ in $(seq 1 15); do
    docker logs "$src_name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  wait_for_watcher_backup "$src_name" full 60 || {
    ko t_recovery_conf_persists_across_restart_mid_replay "watcher initial full did not land within 60s"
    docker rm -f "$src_name" >/dev/null; docker volume rm "$src_vol" >/dev/null
    return
  }

  docker exec -u postgres "$src_name" bash -c '
    if [ -f /var/lib/postgresql/data/.pgbackrest_repo_path ]; then
      export PGBACKREST_REPO1_PATH="$(cat /var/lib/postgresql/data/.pgbackrest_repo_path)"
    else
      export PGBACKREST_REPO1_PATH="$WAL_ARCHIVE_PATH"
    fi
    export PGBACKREST_REPO1_S3_BUCKET="$WAL_ARCHIVE_BUCKET"
    export PGBACKREST_REPO1_S3_KEY="$WAL_ARCHIVE_KEY"
    export PGBACKREST_REPO1_S3_KEY_SECRET="$WAL_ARCHIVE_SECRET"
    export PGBACKREST_REPO1_S3_REGION="$WAL_ARCHIVE_REGION"
    export PGBACKREST_REPO1_S3_ENDPOINT="$WAL_ARCHIVE_ENDPOINT"
    pgbackrest --stanza=main backup --type=full
  ' >/dev/null 2>&1
  local src_path
  src_path=$(docker exec "$src_name" cat /var/lib/postgresql/data/.pgbackrest_repo_path 2>/dev/null || echo "/pgbackrest")

  # Bulk insert between the base backup and the target — gives the restore
  # real WAL to replay instead of a handful of rows, so recovery takes long
  # enough (seconds, not milliseconds) to reliably catch it mid-flight.
  docker exec "$src_name" psql -U postgres -c "
    CREATE TABLE bigdata (id serial, payload text);
    INSERT INTO bigdata (payload) SELECT repeat('x', 500) FROM generate_series(1, 400000);
  " >/dev/null
  docker exec "$src_name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null
  local target
  target=$(docker exec "$src_name" psql -U postgres -At -c "SELECT now()::timestamptz(0)")
  sleep 4
  docker exec "$src_name" psql -U postgres -c "INSERT INTO bigdata (payload) VALUES ('post-target');" >/dev/null

  # Capture the segment BEFORE switching — pg_current_wal_lsn() points at
  # the post-target commit's LSN, and pg_walfile_name resolves that LSN to
  # the segment presently holding it. Recovery only stops-and-promotes on a
  # record timestamped strictly after target (a commit, not a bare segment
  # switch); without a post-target commit there's nothing to satisfy that,
  # and replay runs out of WAL and FATALs with "recovery ended before
  # configured recovery target was reached" instead of promoting — same
  # pattern every other target-time restore test in this file relies on
  # (see id2_segment / id11_segment above).
  local last_segment
  last_segment=$(docker exec "$src_name" psql -U postgres -At -c "SELECT pg_walfile_name(pg_current_wal_lsn())")
  docker exec "$src_name" psql -U postgres -c "SELECT pg_switch_wal(); SELECT pg_switch_wal();" >/dev/null
  local archive_deadline=$(($(date +%s) + 90)) shipped=0
  while [ "$(date +%s)" -lt "$archive_deadline" ]; do
    local last_archived_wal
    last_archived_wal=$(docker exec "$src_name" psql -U postgres -At -c "SELECT last_archived_wal FROM pg_stat_archiver" 2>/dev/null || echo "")
    if [ -n "$last_archived_wal" ] && { [ "$last_archived_wal" = "$last_segment" ] || [ "$last_archived_wal" \> "$last_segment" ]; }; then
      shipped=1; break
    fi
    docker exec "$src_name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null 2>&1 || true
    sleep 2
  done
  if [ "$shipped" != 1 ]; then
    ko t_recovery_conf_persists_across_restart_mid_replay "bulk-insert segment did not ship within 90s"
    docker rm -f "$src_name" >/dev/null; docker volume rm "$src_vol" >/dev/null
    return
  fi

  local rest_name=t-midreplay-restart-${PG_VERSION}
  local rest_vol=${rest_name}-vol
  new_volume "$rest_vol"
  docker rm -f "$rest_name" >/dev/null 2>&1 || true

  local restore_env=(
    -e POSTGRES_PASSWORD=test
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET"
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000"
    -e WAL_RECOVER_FROM_REGION=us-east-1
    -e "WAL_RECOVER_FROM_KEY=$MINIO_USER"
    -e "WAL_RECOVER_FROM_SECRET=$MINIO_PASS"
    -e "WAL_RECOVER_FROM_PATH=$src_path"
    -e PGBACKREST_REPO1_S3_URI_STYLE=path
    -e "POSTGRES_RECOVERY_TARGET_TIME=$target"
  )

  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    "${restore_env[@]}" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null

  # Tight-poll pg_isready and kill the instant it succeeds — wait_for_pg
  # returns true during recovery, before promote, so this catches the
  # restore genuinely mid-replay instead of racing a fixed sleep against
  # an unknown promote time.
  local caught=0 i
  for i in $(seq 1 600); do
    if docker exec "$rest_name" pg_isready -U postgres -q 2>/dev/null; then
      caught=1
      break
    fi
    local status
    status=$(docker inspect -f '{{.State.Status}}' "$rest_name" 2>/dev/null || echo "")
    if [ "$status" = "exited" ]; then
      ko t_recovery_conf_persists_across_restart_mid_replay "1st boot exited before becoming ready"
      fail_dump t_recovery_conf_persists_across_restart_mid_replay "$rest_name"
      docker rm -f "$src_name" "$rest_name" >/dev/null; docker volume rm "$src_vol" "$rest_vol" >/dev/null
      return
    fi
    sleep 0.2
  done
  if [ "$caught" -ne 1 ]; then
    ko t_recovery_conf_persists_across_restart_mid_replay "1st boot never became ready"
    fail_dump t_recovery_conf_persists_across_restart_mid_replay "$rest_name"
    docker rm -f "$src_name" "$rest_name" >/dev/null; docker volume rm "$src_vol" "$rest_vol" >/dev/null
    return
  fi

  if ! docker exec "$rest_name" test -f /var/lib/postgresql/data/recovery.signal; then
    ko t_recovery_conf_persists_across_restart_mid_replay "test setup: promoted too fast to catch mid-replay (recovery.signal already gone)"
    docker rm -f "$src_name" "$rest_name" >/dev/null; docker volume rm "$src_vol" "$rest_vol" >/dev/null
    return
  fi
  if ! docker exec "$rest_name" test -f /var/lib/postgresql/data/.pgbackrest_restored; then
    ko t_recovery_conf_persists_across_restart_mid_replay "1st boot didn't write .pgbackrest_restored"
    docker rm -f "$src_name" "$rest_name" >/dev/null; docker volume rm "$src_vol" "$rest_vol" >/dev/null
    return
  fi

  # Simulate a crash + resize + redeploy: forcibly remove the container
  # (same volume, same env) and boot a fresh one — /etc/pgbackrest is on
  # the container's root filesystem, so this wipes the recovery conf that
  # was in place, exactly like a real redeploy would.
  docker kill "$rest_name" >/dev/null 2>&1 || true
  docker rm -f "$rest_name" >/dev/null
  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    "${restore_env[@]}" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$rest_name" || { ko t_recovery_conf_persists_across_restart_mid_replay "2nd boot"; fail_dump t_recovery_conf_persists_across_restart_mid_replay "$rest_name"; docker rm -f "$src_name" "$rest_name" >/dev/null; docker volume rm "$src_vol" "$rest_vol" >/dev/null; return; }

  if ! docker exec "$rest_name" test -f /etc/pgbackrest/pgbackrest-recovery-source.conf; then
    ko t_recovery_conf_persists_across_restart_mid_replay "pgbackrest-recovery-source.conf missing on restart mid-replay (marker bailed without checking recovery.signal)"
    fail_dump t_recovery_conf_persists_across_restart_mid_replay "$rest_name"
    docker rm -f "$src_name" "$rest_name" >/dev/null; docker volume rm "$src_vol" "$rest_vol" >/dev/null
    return
  fi

  # The real proof: recovery must be able to actually finish now that it
  # can still reach the archive, not just have the conf file present.
  if ! wait_for_promoted "$rest_name"; then
    ko t_recovery_conf_persists_across_restart_mid_replay "did not promote after restart mid-replay"
    fail_dump t_recovery_conf_persists_across_restart_mid_replay "$rest_name"
    docker rm -f "$src_name" "$rest_name" >/dev/null; docker volume rm "$src_vol" "$rest_vol" >/dev/null
    return
  fi

  local missing_file_count
  missing_file_count=$(docker logs "$rest_name" 2>&1 | grep -c "unable to open missing file.*pgbackrest-recovery-source.conf" || true)
  if [ "${missing_file_count:-0}" -gt 0 ]; then
    ko t_recovery_conf_persists_across_restart_mid_replay "logs show missing-file errors despite eventual promote (count=$missing_file_count)"
    docker rm -f "$src_name" "$rest_name" >/dev/null; docker volume rm "$src_vol" "$rest_vol" >/dev/null
    return
  fi

  ok t_recovery_conf_persists_across_restart_mid_replay
  note "recovery conf re-rendered on mid-replay restart; recovery completed and promoted"
  docker rm -f "$src_name" "$rest_name" >/dev/null
  docker volume rm "$src_vol" "$rest_vol" >/dev/null
}

# ----- learnings from test-postgres-pitr (railway-side e2e harness) ----------
#
# These mirror flows from ../test-postgres-pitr/e2e/run-test.ts at the image
# level. That suite exercises the same contract through the Railway mutation
# pipeline (deploys real projects, drives load via libpq, asserts on the
# restored cluster). The image-level versions below pin the same invariants
# in seconds-not-minutes — same load-bearing assertions, no GraphQL/Temporal
# surface area to flake against.
#
# Coverage map (PITR-harness flow → image-level test):
#   idleRestore         → t_pitr_target_xid_routes_xid_through_stack
#                         (target_time on a quiet source no longer FATALs —
#                          the watcher's emit_pitr_anchor commit gives
#                          recovery a stop record; covered in happy-path)
#   gaps                → t_pitr_missing_wal_segment_fatals
#   lifecycle           → t_lifecycle_enable_disable_reenable
#   restoreThenRestore  → t_chain_restore_r1_to_r2

# I2. POSTGRES_RECOVERY_TARGET_XID drives the full plumbing chain.
# Pins four observable points along the wrapper → pgbackrest → postgres
# pipeline so a regression in any layer trips the suite:
#
#   1. wrapper logs "using recovery_target_xid=<xid>"
#      → bash branch in restore_from_pgbackrest_if_empty_volume fired
#   2. pgbackrest restore line shows "--type=xid"
#      → wrapper threaded $restore_type / $restore_target all the way to
#        the pgbackrest invocation
#   3. postgresql.auto.conf written by pgbackrest carries
#      `recovery_target_xid = '<xid>'`
#      → pgbackrest 2.58 honored --type=xid and emitted the right knob
#        (catches a future pgbackrest version that silently drops the
#        flag, or our pgbackrest config not threading --target-action
#        through alongside)
#   4. postgres logs "starting point-in-time recovery to XID <xid>"
#      → postmaster parsed the recovery target and started archive
#        recovery in xid mode (different log line than the time-mode
#        "starting point-in-time recovery to <ts>")
#
# What this does NOT pin: that recovery actually terminates at target_xid
# and promotes with the row contract honored. The xid → COMMIT-record
# matching itself is postgres's responsibility, and reproducing it
# deterministically against synthetic local WAL is brittle (the segment
# carrying target_xid's COMMIT can lap behind the segment-name probe in
# ways that don't reproduce in production where archive head is hours
# ahead). End-to-end XID success is exercised by test-postgres-pitr's
# `idleRestore` flow on a real Railway deployment — the layer where
# postgres's behavior is what we're really measuring.
t_pitr_target_xid_routes_xid_through_stack() {
  setup_pitr_source >&2 || { ko t_pitr_target_xid_routes_xid_through_stack "setup_pitr_source failed"; return; }
  read -r src_name src_vol < "/tmp/pitr-source-${PG_VERSION}"
  local target; target=$(cat "/tmp/pitr-target-${PG_VERSION}")
  local src_path; src_path=$(pitr_source_path)
  local rest_name=t-xid-route-${PG_VERSION}
  local rest_vol=${rest_name}-vol

  local target_xid
  target_xid=$(docker exec "$src_name" psql -U postgres -At -c \
    "SELECT xmin::text::bigint FROM pitrtest WHERE id=1")
  if [ -z "$target_xid" ] || [ "$target_xid" = "0" ]; then
    ko t_pitr_target_xid_routes_xid_through_stack "captured xid empty/zero (got '$target_xid')"
    return
  fi

  new_volume "$rest_vol"
  docker rm -f "$rest_name" >/dev/null 2>&1 || true
  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=$MINIO_USER \
    -e WAL_RECOVER_FROM_SECRET=$MINIO_PASS \
    -e "WAL_RECOVER_FROM_PATH=$src_path" \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e "POSTGRES_RECOVERY_TARGET_TIME=$target" \
    -e "POSTGRES_RECOVERY_TARGET_XID=$target_xid" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null

  # Don't wait for promote — recovery's xid-match termination is what
  # idleRestore exercises end-to-end. We only care about the routing
  # observations, all of which land in the first ~10 s of container life.
  local deadline=$(($(date +%s) + 30)) saw_wrapper=0 saw_pgbackrest=0 saw_postgres=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local logs
    logs=$(docker logs "$rest_name" 2>&1)
    echo "$logs" | grep -q "using recovery_target_xid=${target_xid}" && saw_wrapper=1
    echo "$logs" | grep -qE "pgbackrest .*--type=xid"               && saw_pgbackrest=1
    echo "$logs" | grep -qE "starting point-in-time recovery to XID ${target_xid}" && saw_postgres=1
    [ "$saw_wrapper" = 1 ] && [ "$saw_pgbackrest" = 1 ] && [ "$saw_postgres" = 1 ] && break
    sleep 2
  done
  if [ "$saw_wrapper" != 1 ]; then
    ko t_pitr_target_xid_routes_xid_through_stack "wrapper did not log 'using recovery_target_xid=${target_xid}'"
    fail_dump t_pitr_target_xid_routes_xid_through_stack "$rest_name"
    return
  fi
  if [ "$saw_pgbackrest" != 1 ]; then
    ko t_pitr_target_xid_routes_xid_through_stack "pgbackrest restore not invoked with --type=xid"
    fail_dump t_pitr_target_xid_routes_xid_through_stack "$rest_name"
    return
  fi
  if [ "$saw_postgres" != 1 ]; then
    ko t_pitr_target_xid_routes_xid_through_stack "postgres did not log XID-mode recovery start"
    fail_dump t_pitr_target_xid_routes_xid_through_stack "$rest_name"
    return
  fi

  # Read postgresql.auto.conf out of the volume — it persists past
  # container exit (recovery may FATAL on synthetic WAL, but the conf
  # was written before that). pgbackrest writes auto.conf during
  # `pgbackrest restore`, well before postgres starts. Catches a
  # pgbackrest regression that drops `recovery_target_xid` while still
  # writing the `recovery_target_action` line.
  local auto_conf
  auto_conf=$(docker run --rm -v "${rest_vol}:/data" alpine cat /data/postgresql.auto.conf 2>/dev/null || echo "")
  if [ -z "$auto_conf" ]; then
    ko t_pitr_target_xid_routes_xid_through_stack "postgresql.auto.conf missing or unreadable"
    return
  fi
  if ! echo "$auto_conf" | grep -qE "^recovery_target_xid = '${target_xid}'$"; then
    ko t_pitr_target_xid_routes_xid_through_stack "auto.conf missing 'recovery_target_xid = ${target_xid}'"
    echo "  auto.conf:"
    echo "$auto_conf" | sed 's/^/    /'
    return
  fi
  # The time path's recovery_target_time MUST NOT also be present —
  # both knobs in auto.conf is undefined behavior in postgres and would
  # mean the wrapper failed to suppress _TIME when _XID was set.
  if echo "$auto_conf" | grep -qE "^recovery_target_time = "; then
    ko t_pitr_target_xid_routes_xid_through_stack "auto.conf carries both recovery_target_xid AND recovery_target_time — wrapper did not suppress _TIME"
    return
  fi

  ok t_pitr_target_xid_routes_xid_through_stack
  note "wrapper → pgbackrest → auto.conf (recovery_target_xid='${target_xid}') → postgres all routed XID; recovery termination covered upstream"
  docker rm -f "$src_name" "$rest_name" >/dev/null
  docker volume rm "$src_vol" "$rest_vol" >/dev/null
}

# G3. Restore over a WAL gap → loud refuse.
# Mirrors test-postgres-pitr/gaps at the image level. Custom setup (not
# setup_pitr_source) so we have tight control over which segment contains
# the only post-target commit: that's the segment we delete to manufacture
# a gap recovery has to walk through.
#
# Setup invariant: at the moment we delete, the LATEST archived segment is
# the one carrying the post-target INSERT's commit, and it's the only
# archived segment with a record dated > target. Recovery walks all
# pre-target segments, hits the archive-get failure for the missing
# segment (or runs out of WAL trying to find a record > target), and
# FATALs. Either signature counts as loud refuse.
t_pitr_missing_wal_segment_fatals() {
  local src_name=t-walgap-src-${PG_VERSION}
  local src_vol=${src_name}-vol
  local rest_name=t-walgap-rest-${PG_VERSION}
  local rest_vol=${rest_name}-vol
  reset_bucket
  new_volume "$src_vol"
  docker rm -f "$src_name" >/dev/null 2>&1 || true
  run_archiving_pg "$src_name" "$src_vol"
  wait_for_pg "$src_name" || { ko t_pitr_missing_wal_segment_fatals "src no startup"; fail_dump t_pitr_missing_wal_segment_fatals "$src_name"; return; }
  for _ in $(seq 1 15); do
    docker logs "$src_name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done

  docker exec "$src_name" psql -U postgres -c "CREATE TABLE pitrtest(id int);" >/dev/null
  if ! take_pgbackrest_backup "$src_name" full; then
    ko t_pitr_missing_wal_segment_fatals "manual full failed"; fail_dump t_pitr_missing_wal_segment_fatals "$src_name"; return
  fi
  local src_path
  src_path=$(docker exec "$src_name" cat /var/lib/postgresql/data/.pgbackrest_repo_path 2>/dev/null \
    || echo "/pgbackrest")

  # Pre-target inserts — each one + switch ships a segment with a commit
  # whose time is < target. These segments stay in archive; recovery walks
  # them fine.
  docker exec "$src_name" psql -U postgres -c "INSERT INTO pitrtest VALUES (1); SELECT pg_switch_wal();" >/dev/null
  sleep 2
  docker exec "$src_name" psql -U postgres -c "INSERT INTO pitrtest VALUES (2); SELECT pg_switch_wal();" >/dev/null
  sleep 3

  # Capture target = NOW. Strictly after id=2's commit, strictly before
  # id=3's commit (added next).
  local target
  target=$(docker exec "$src_name" psql -U postgres -At -c "SELECT now()::timestamptz(0)")
  sleep 3

  # Single post-target INSERT, then switch_wal so the segment carrying its
  # commit ships and becomes the LATEST archived segment.
  docker exec "$src_name" psql -U postgres -c "INSERT INTO pitrtest VALUES (3); SELECT pg_switch_wal();" >/dev/null

  # Wait for archive head to advance past target. Probing pg_stat_archiver
  # is deterministic; trust the wrapper to keep archive_command running.
  local d=$(($(date +%s) + 60))
  while [ "$(date +%s)" -lt "$d" ]; do
    local last_archived
    last_archived=$(docker exec "$src_name" psql -U postgres -At -c \
      "SELECT last_archived_time::timestamptz(0) FROM pg_stat_archiver" 2>/dev/null || echo "")
    if [ -n "$last_archived" ] && [ "$last_archived" \> "$target" ]; then
      break
    fi
    docker exec "$src_name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null 2>&1 || true
    sleep 2
  done

  # Identify and delete the LATEST archived segment. By construction it
  # contains id=3's commit (the only commit dated > target). Pre-target
  # segments stay so backup-recovery can reach min_recovery_endpoint and
  # the early WAL replay is well-formed; the gap is strictly at the
  # post-target frontier.
  local segments last
  segments=$(mc "mc find local/${BUCKET}${src_path}/archive --name '00000001*.zst' 2>/dev/null | sort")
  local n
  n=$(echo "$segments" | grep -c .)
  if [ "$n" -lt 3 ]; then
    ko t_pitr_missing_wal_segment_fatals "expected ≥3 archived WAL segments in bucket; got $n"
    return
  fi
  last=$(echo "$segments" | tail -1)
  mc "mc rm '${last}'" >/dev/null
  note "deleted latest segment $last (the only one with records > target)"

  new_volume "$rest_vol"
  docker rm -f "$rest_name" >/dev/null 2>&1 || true
  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=$MINIO_USER \
    -e WAL_RECOVER_FROM_SECRET=$MINIO_PASS \
    -e "WAL_RECOVER_FROM_PATH=$src_path" \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e "POSTGRES_RECOVERY_TARGET_TIME=$target" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null

  # Two acceptable failure signatures:
  #   - pgbackrest's archive-get prints "WAL segment ... not found" and
  #     postgres logs the corresponding "could not locate" / archive-get
  #     fatal during recovery
  #   - postgres FATALs "recovery ended before configured recovery target
  #     was reached" if the deleted segment happened to be past the target
  # Either is "loud refuse" — recovery did NOT silently promote on partial
  # WAL. Wait up to 180s; archive-get retries a few times before giving up.
  local deadline=$(($(date +%s) + 180)) found=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker logs "$rest_name" 2>&1 | grep -qE "(WAL file .* missing|archive-get.*FATAL|recovery ended before configured recovery target was reached|requested WAL segment.*has already been removed)"; then
      found=1; break
    fi
    sleep 5
  done
  if [ "$found" != "1" ]; then
    ko t_pitr_missing_wal_segment_fatals "expected loud-refuse log line for missing WAL segment; none found within 180s"
    fail_dump t_pitr_missing_wal_segment_fatals "$rest_name"
    return
  fi

  # Cluster must NOT be promoted with partial WAL — pg_is_in_recovery should
  # be 't' (still trying) or psql should be unreachable. If it returns 'f',
  # postgres silently promoted on incomplete WAL, which is a data-integrity
  # bug we want to catch.
  local in_rec
  in_rec=$(docker exec "$rest_name" psql -U postgres -At -c "SELECT pg_is_in_recovery()" 2>/dev/null || echo "?")
  if [ "$in_rec" = "f" ]; then
    ko t_pitr_missing_wal_segment_fatals "cluster promoted despite missing WAL segment — silent data-integrity bug"
    fail_dump t_pitr_missing_wal_segment_fatals "$rest_name"
    return
  fi

  ok t_pitr_missing_wal_segment_fatals
  note "missing WAL segment → loud refuse; cluster not promoted (pg_is_in_recovery='${in_rec}')"
  docker rm -f "$src_name" "$rest_name" >/dev/null
  docker volume rm "$src_vol" "$rest_vol" >/dev/null
}

# L1. enable → disable → re-enable lifecycle. Mirrors test-postgres-pitr's
# `lifecycle` flow at the image level. Pins the round-trip property: every
# disable cleans up state cleanly, every re-enable picks up where any other
# fresh service would start (NEEDS_INITIAL_BACKUP, fresh full lands).
# t_disable_cleanup covers half of this in isolation; this test exercises
# the full cycle so a regression in the re-enable branch (e.g. a stale
# .pgbackrest_backup_state surviving disable, suppressing the next full)
# trips the suite.
t_lifecycle_enable_disable_reenable() {
  local name=t-lifecycle-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true

  # Phase 1: enable + take initial full.
  run_archiving_pg_fast_watcher "$name" "$vol"
  wait_for_pg "$name" || { ko t_lifecycle_enable_disable_reenable "phase1 startup"; return; }
  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c "CREATE TABLE t(id int); INSERT INTO t VALUES (1); SELECT pg_switch_wal();" >/dev/null
  wait_for_watcher_backup "$name" full 60 \
    || { ko t_lifecycle_enable_disable_reenable "phase1 initial full"; fail_dump t_lifecycle_enable_disable_reenable "$name"; return; }

  # Phase 2: disable. Restart with no WAL_ARCHIVE_*. Must come back archive_mode=off
  # and have wiped the watcher state file (covered in detail by t_disable_cleanup).
  docker rm -f "$name" >/dev/null
  docker run -d --name "$name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -v "$vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$name" || { ko t_lifecycle_enable_disable_reenable "phase2 startup"; return; }
  local mode
  mode=$(docker exec "$name" psql -U postgres -At -c "SHOW archive_mode")
  assert_eq "$mode" "off" "archive_mode should be off after disable" \
    || { ko t_lifecycle_enable_disable_reenable ""; return; }
  if docker exec "$name" test -f /var/lib/postgresql/data/.pgbackrest_backup_state; then
    ko t_lifecycle_enable_disable_reenable ".pgbackrest_backup_state must be wiped on disable so re-enable starts clean"
    return
  fi

  # Write data while archiving is OFF — would form a gap if we restored, but
  # here we're confirming the cluster keeps accepting writes.
  docker exec "$name" psql -U postgres -c "INSERT INTO t VALUES (2);" >/dev/null

  # Phase 3: re-enable against a fresh bucket (operator pointing at a new
  # destination, the more common case). Watcher must take a fresh initial
  # full — proving disable-cleanup didn't leave anything stale.
  docker rm -f "$name" >/dev/null
  reset_bucket
  run_archiving_pg_fast_watcher "$name" "$vol"
  wait_for_pg "$name" || { ko t_lifecycle_enable_disable_reenable "phase3 startup"; fail_dump t_lifecycle_enable_disable_reenable "$name"; return; }
  mode=$(docker exec "$name" psql -U postgres -At -c "SHOW archive_mode")
  assert_eq "$mode" "on" "archive_mode should be on after re-enable" \
    || { ko t_lifecycle_enable_disable_reenable ""; return; }

  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c "INSERT INTO t VALUES (3); SELECT pg_switch_wal();" >/dev/null
  if ! wait_for_watcher_backup "$name" full 90; then
    ko t_lifecycle_enable_disable_reenable "phase3 watcher did not take fresh initial full after re-enable"
    fail_dump t_lifecycle_enable_disable_reenable "$name"
    return
  fi

  # Pre-disable rows survived (t.id 1+2); fresh bucket has its own full
  # (verifies the cycle is truly fresh, not resuming the old archive).
  local rows fulls
  rows=$(docker exec "$name" psql -U postgres -At -c "SELECT count(*) FROM t")
  assert_eq "$rows" "3" "t should have 3 rows preserved across the cycle" \
    || { ko t_lifecycle_enable_disable_reenable ""; return; }
  fulls=$(count_backups_of_type "$name" full)
  assert_eq "$fulls" "1" "fresh bucket should have exactly 1 full after re-enable" \
    || { ko t_lifecycle_enable_disable_reenable ""; return; }

  ok t_lifecycle_enable_disable_reenable
  note "enable → disable → re-enable round-trip; rows preserved, fresh full landed"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

# C1. Chain restore S → R1 → R2. Mirrors test-postgres-pitr's
# restoreThenRestore. R1 is restored from S at T1 and archives to its own
# bucket; R2 is restored from R1's bucket at T2 (T2 > T1) and archives to
# yet another bucket. Pins:
#   - R1's bucket is a complete archive (full + WAL) on its own — no
#     implicit dependency on S.
#   - R2 inherits S→R1's restore window (id=1 'before' from S, id=10 'on-r1'
#     from R1) and applies R2's restore window (id=2,3 excluded by R1's T1,
#     id=11 excluded by R2's T2).
#   - Each restore promotes cleanly; chain invariants hold all the way down.
t_chain_restore_r1_to_r2() {
  setup_pitr_source >&2 || { ko t_chain_restore_r1_to_r2 "setup_pitr_source failed"; return; }
  read -r src_name src_vol < "/tmp/pitr-source-${PG_VERSION}"
  local target_t1; target_t1=$(cat "/tmp/pitr-target-${PG_VERSION}")
  local src_path; src_path=$(pitr_source_path)

  local r1_name=t-chain-r1-${PG_VERSION}
  local r1_vol=${r1_name}-vol
  local r1_bucket=pgbackrest-chain-r1
  local r2_name=t-chain-r2-${PG_VERSION}
  local r2_vol=${r2_name}-vol
  local r2_bucket=pgbackrest-chain-r2

  mc "mc rm -r --force local/${r1_bucket} >/dev/null 2>&1; mc mb -p local/${r1_bucket} >/dev/null"
  mc "mc rm -r --force local/${r2_bucket} >/dev/null 2>&1; mc mb -p local/${r2_bucket} >/dev/null"
  new_volume "$r1_vol"
  docker rm -f "$r1_name" >/dev/null 2>&1 || true

  # R1: restore from S at T1 + archive into its own bucket. Mirrors what the
  # mono createServiceFromPITR mutation patches onto a forked service.
  docker run -d --name "$r1_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=$MINIO_USER \
    -e WAL_RECOVER_FROM_SECRET=$MINIO_PASS \
    -e "WAL_RECOVER_FROM_PATH=$src_path" \
    -e "WAL_ARCHIVE_BUCKET=$r1_bucket" \
    -e "WAL_ARCHIVE_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_ARCHIVE_REGION=us-east-1 \
    -e WAL_ARCHIVE_KEY=$MINIO_USER \
    -e WAL_ARCHIVE_SECRET=$MINIO_PASS \
    -e WAL_ARCHIVE_PATH=/pgbackrest \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e "POSTGRES_RECOVERY_TARGET_TIME=$target_t1" \
    -e WAL_BACKUP_POLL_INTERVAL_SECONDS=5 \
    -v "$r1_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$r1_name" || { ko t_chain_restore_r1_to_r2 "R1 did not start"; fail_dump t_chain_restore_r1_to_r2 "$r1_name"; return; }
  wait_for_promoted "$r1_name" || { ko t_chain_restore_r1_to_r2 "R1 did not promote"; fail_dump t_chain_restore_r1_to_r2 "$r1_name"; return; }

  # Chain semantics check on R1: should have id=1 (before T1) and NOT id=2,3.
  local r1_pre r1_post
  r1_pre=$(docker exec "$r1_name" psql -U postgres -At -c "SELECT count(*) FROM pitrtest WHERE id=1")
  r1_post=$(docker exec "$r1_name" psql -U postgres -At -c "SELECT count(*) FROM pitrtest WHERE id IN (2,3)")
  assert_eq "$r1_pre" "1" "R1 should have id=1 inherited from S" || { ko t_chain_restore_r1_to_r2 ""; return; }
  assert_eq "$r1_post" "0" "R1 should NOT have id=2,3 (excluded by T1 restore)" || { ko t_chain_restore_r1_to_r2 ""; return; }

  # Order matters: R1's bucket must hold a full whose stop_time ≤ T2, so
  # pgbackrest at R2 can pick it. Take a manual full ourselves rather than
  # racing the watcher's poll loop — under suite load the watcher's
  # NEEDS_INITIAL_BACKUP trip can lag past the 120s window even with the
  # 5s poll interval. take_pgbackrest_backup uses R1's WAL_ARCHIVE_*
  # creds, so the backup goes to r1_bucket exactly like the watcher
  # would have written it.
  #
  # Manual backup with retry. Don't pre-wait on a "stanza-create completed"
  # log line — bootstrap_pgbackrest_stanza races recovery + S3 I/O under
  # suite load and the log line can lag well past 90 s even after stanza
  # is actually ready. Cleaner check: just attempt the backup, and on the
  # "stanza missing data in the repo" error retry with backoff. After
  # ~10 retries (~120 s wall time) bootstrap has either landed or
  # something else is wrong.
  #
  # Stderr is appended to /tmp/pgssl-r1-backup-err.log so the post-mortem
  # has the actual pgbackrest error instead of a generic "manual full
  # failed" — surfaces in the ko message on terminal failure.
  docker exec "$r1_name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null
  : > /tmp/pgssl-r1-backup-err.log
  local backup_attempt backup_ok=0
  for backup_attempt in $(seq 1 10); do
    if docker exec -u postgres "$r1_name" bash -c '
      if [ -f /var/lib/postgresql/data/.pgbackrest_repo_path ]; then
        export PGBACKREST_REPO1_PATH="$(cat /var/lib/postgresql/data/.pgbackrest_repo_path)"
      else
        export PGBACKREST_REPO1_PATH="$WAL_ARCHIVE_PATH"
      fi
      export PGBACKREST_REPO1_S3_BUCKET="$WAL_ARCHIVE_BUCKET"
      export PGBACKREST_REPO1_S3_KEY="$WAL_ARCHIVE_KEY"
      export PGBACKREST_REPO1_S3_KEY_SECRET="$WAL_ARCHIVE_SECRET"
      export PGBACKREST_REPO1_S3_REGION="$WAL_ARCHIVE_REGION"
      export PGBACKREST_REPO1_S3_ENDPOINT="$WAL_ARCHIVE_ENDPOINT"
      pgbackrest --stanza=main backup --type=full
    ' 2>>/tmp/pgssl-r1-backup-err.log >/dev/null; then
      backup_ok=1
      break
    fi
    sleep 12
  done
  if [ "$backup_ok" != 1 ]; then
    ko t_chain_restore_r1_to_r2 "R1 manual full failed after 10 attempts (~2 min); last 30 lines of pgbackrest stderr: $(tail -30 /tmp/pgssl-r1-backup-err.log 2>/dev/null | tr '\n' '|')"
    fail_dump t_chain_restore_r1_to_r2 "$r1_name"
    return
  fi

  # Capture R1's per-cluster repo path for R2's WAL_RECOVER_FROM_PATH.
  local r1_path
  r1_path=$(docker exec "$r1_name" cat /var/lib/postgresql/data/.pgbackrest_repo_path 2>/dev/null \
    || echo "/pgbackrest")

  # Now drive R1 forward post-promote: insert id=10 'on-r1' (pre-T2),
  # capture T2, insert id=11 'post-t2', force WAL switches so the segments
  # spanning T2 ship to archive (recovery needs WAL with a record dated
  # > T2 to declare "target reached" before promoting).
  docker exec "$r1_name" psql -U postgres -c "INSERT INTO pitrtest(id,marker) VALUES (10,'on-r1');" >/dev/null
  sleep 2
  local target_t2
  target_t2=$(docker exec "$r1_name" psql -U postgres -At -c "SELECT now()::timestamptz(0)")
  sleep 2
  docker exec "$r1_name" psql -U postgres -c "INSERT INTO pitrtest(id,marker) VALUES (11,'post-t2');" >/dev/null

  # Capture the WAL segment id=11's commit lives in BEFORE we issue any
  # switch. pg_current_wal_lsn() now points just past id=11's commit; the
  # segment name from pg_walfile_name is the segment carrying that LSN
  # (until the next switch closes it). This is the segment R2 must see
  # in r1_bucket — the previous probe used pg_stat_archiver.last_archived_time
  # (wall-clock) which can advance without shipping the segment whose
  # *content* spans T2, so R2's recovery walked all-but-the-needed WAL
  # and FATALed.
  local id11_segment
  id11_segment=$(docker exec "$r1_name" psql -U postgres -At -c \
    "SELECT pg_walfile_name(pg_current_wal_lsn())")

  # Two switches — first closes id11_segment (ships it), second nudges the
  # archiver if WAL volume alone wouldn't cross the segment boundary.
  docker exec "$r1_name" psql -U postgres -c "SELECT pg_switch_wal(); SELECT pg_switch_wal();" >/dev/null

  # Wait until pg_stat_archiver.last_archived_wal has reached id11_segment.
  # WAL segment names are zero-padded hex sortable as strings, so >=
  # semantics fall out of bash's `\>` (lexicographic = numeric-by-segment).
  local r1_ship_deadline=$(($(date +%s) + 90)) shipped_id11=0
  while [ "$(date +%s)" -lt "$r1_ship_deadline" ]; do
    local last_archived_wal
    last_archived_wal=$(docker exec "$r1_name" psql -U postgres -At -c \
      "SELECT last_archived_wal FROM pg_stat_archiver" 2>/dev/null || echo "")
    if [ -n "$last_archived_wal" ]; then
      if [ "$last_archived_wal" = "$id11_segment" ] \
         || [ "$last_archived_wal" \> "$id11_segment" ]; then
        shipped_id11=1; break
      fi
    fi
    docker exec "$r1_name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null 2>&1
    sleep 2
  done
  if [ "$shipped_id11" != 1 ]; then
    ko t_chain_restore_r1_to_r2 "R1's archiver did not ship segment ${id11_segment} (with id=11/post-T2 commit) within 90s"
    fail_dump t_chain_restore_r1_to_r2 "$r1_name"
    return
  fi

  # R2: restore from R1's bucket at T2 + archive into its own bucket.
  new_volume "$r2_vol"
  docker rm -f "$r2_name" >/dev/null 2>&1 || true
  docker run -d --name "$r2_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$r1_bucket" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=$MINIO_USER \
    -e WAL_RECOVER_FROM_SECRET=$MINIO_PASS \
    -e "WAL_RECOVER_FROM_PATH=$r1_path" \
    -e "WAL_ARCHIVE_BUCKET=$r2_bucket" \
    -e "WAL_ARCHIVE_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_ARCHIVE_REGION=us-east-1 \
    -e WAL_ARCHIVE_KEY=$MINIO_USER \
    -e WAL_ARCHIVE_SECRET=$MINIO_PASS \
    -e WAL_ARCHIVE_PATH=/pgbackrest \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e "POSTGRES_RECOVERY_TARGET_TIME=$target_t2" \
    -v "$r2_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$r2_name" || { ko t_chain_restore_r1_to_r2 "R2 did not start"; fail_dump t_chain_restore_r1_to_r2 "$r2_name"; return; }
  wait_for_promoted "$r2_name" || { ko t_chain_restore_r1_to_r2 "R2 did not promote"; fail_dump t_chain_restore_r1_to_r2 "$r2_name"; return; }

  # Chain semantics on R2:
  #   id=1   pre-T1 (S)            → present (inherited via R1)
  #   id=2,3 post-T1 (S)           → absent  (excluded by R1's restore)
  #   id=10  on-R1 pre-T2          → present (inherited from R1)
  #   id=11  post-T2 (R1)          → absent  (excluded by R2's restore)
  local pre_t1 post_t1 on_r1 post_t2
  pre_t1=$(docker exec "$r2_name" psql -U postgres -At -c "SELECT count(*) FROM pitrtest WHERE id=1")
  post_t1=$(docker exec "$r2_name" psql -U postgres -At -c "SELECT count(*) FROM pitrtest WHERE id IN (2,3)")
  on_r1=$(docker exec "$r2_name" psql -U postgres -At -c "SELECT count(*) FROM pitrtest WHERE id=10")
  post_t2=$(docker exec "$r2_name" psql -U postgres -At -c "SELECT count(*) FROM pitrtest WHERE id=11")
  assert_eq "$pre_t1"  "1" "R2 pre-T1 (id=1) should be inherited via R1"               || { ko t_chain_restore_r1_to_r2 ""; return; }
  assert_eq "$post_t1" "0" "R2 post-T1 (id=2,3) excluded by R1's restore"              || { ko t_chain_restore_r1_to_r2 ""; return; }
  assert_eq "$on_r1"   "1" "R2 on-R1 (id=10) inherited from R1's pre-T2 timeline"      || { ko t_chain_restore_r1_to_r2 ""; return; }
  assert_eq "$post_t2" "0" "R2 post-T2 (id=11) excluded by R2's restore"               || { ko t_chain_restore_r1_to_r2 ""; return; }

  ok t_chain_restore_r1_to_r2
  note "S→R1@T1, R1→R2@T2; chain semantics intact (pre-T1=1, post-T1=0, on-r1=1, post-T2=0)"
  mc "mc rm -r --force local/${r1_bucket}" >/dev/null 2>&1 || true
  mc "mc rm -r --force local/${r2_bucket}" >/dev/null 2>&1 || true
  docker rm -f "$src_name" "$r1_name" "$r2_name" >/dev/null
  docker volume rm "$src_vol" "$r1_vol" "$r2_vol" >/dev/null
}

# M2. Catalog-verify self-heal. local state can carry last_full_at while S3
# has lost the full (catalog wiped, redeploy that dropped the bucket, restore
# from before the full). NEEDS_INITIAL_BACKUP only fires on empty state, so
# without catalog verification the watcher rides a phantom full forever. This
# wipes the catalog out from under the running container (volume keeps
# last_full_at), then asserts the verify repairs the stanza (rc=2 →
# stanza-create) and on the next cycle sees "no full present" (rc=1), clears
# last_full_at, and takes a fresh full.
t_catalog_verify_deadlock_selfheals() {
  local name=t-verify-deadlock-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true
  # WAL_BACKUP_INITIAL_POLL_SECONDS=20: after the first skipped iteration
  # (pg_isready fails while postgres is still initializing), the watcher sleeps
  # 20s before its next attempt. This gives us a reliable window to inject the
  # deadlock condition after postgres is up without racing the first real
  # watcher iteration.
  run_archiving_pg_fast_watcher "$name" "$vol" \
    -e WAL_BACKUP_CATALOG_VERIFY_INTERVAL_SECONDS=5 \
    -e WAL_BACKUP_INITIAL_POLL_SECONDS=20

  wait_for_pg "$name" || { ko t_catalog_verify_deadlock_selfheals "startup"; return; }

  # Inject the deadlock condition: last_full_at is set but S3 stanza is empty.
  # This mimics what happens when a container is killed mid-first-full and a
  # new one starts on the same volume.
  #
  # Flow on the watcher's next iteration (≤20s away):
  #   1. stanza_create_step → stanza didn't exist → creates it (empty backup.info)
  #   2. decide_action: last_full_at set → skip NEEDS_INITIAL → catalog-verify
  #   3. catalog_check_backup: pgbackrest info exits 0, 0 backups → rc=1
  #   4. "clearing last_full_at to trigger new full" → NEEDS_INITIAL fires → full
  local fake_at; fake_at=$(( $(date +%s) - 60 ))
  docker exec "$name" bash -c \
    "printf 'last_full_at=${fake_at}\n' > /var/lib/postgresql/data/.pgbackrest_backup_state"

  # Wait for the rc=1 self-heal log line (proves the catalog-verify path fired).
  local deadline=$(($(date +%s) + 60)) got_clear=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    docker logs "$name" 2>&1 | grep -q "clearing last_full_at to trigger new full" \
      && { got_clear=1; break; }
    sleep 2
  done
  if [ "$got_clear" != 1 ]; then
    ko t_catalog_verify_deadlock_selfheals "catalog-verify rc=1 self-heal did not fire"
    fail_dump t_catalog_verify_deadlock_selfheals "$name"
    return
  fi

  wait_for_watcher_backup "$name" full 90 || {
    ko t_catalog_verify_deadlock_selfheals "no fresh full after rc=1 self-heal"
    fail_dump t_catalog_verify_deadlock_selfheals "$name"
    return
  }

  ok t_catalog_verify_deadlock_selfheals
  note "stale last_full_at + empty stanza → catalog-verify rc=1 cleared last_full_at → fresh full taken"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

# M1. Gap-recovery in progress must suppress periodic-full AND catalog-
# verify-driven full. Asserts that with the gap marker present, an
# overdue catalog-verify cycle (interval=5s) doesn't fire a full backup
# — gap-recovery owns the marker, decide_action stays silent. Without
# the ordering fix, a verify mid-recovery could see backup.info just
# rotated by retention and force a full through a wedged S3.
t_gap_marker_suppresses_catalog_verify_full() {
  local name=t-gap-verify-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true
  run_archiving_pg_fast_watcher "$name" "$vol" \
    -e WAL_BACKUP_CATALOG_VERIFY_INTERVAL_SECONDS=5
  wait_for_pg "$name" || { ko t_gap_marker_suppresses_catalog_verify_full "startup"; return; }
  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null
  wait_for_watcher_backup "$name" full 60 || { ko t_gap_marker_suppresses_catalog_verify_full "no initial full"; fail_dump t_gap_marker_suppresses_catalog_verify_full "$name"; return; }

  # Inject the gap marker, then nuke the catalog metadata (simulating a
  # transient S3 hiccup that reports "no full present" mid-recovery).
  docker exec -u postgres "$name" touch /var/lib/postgresql/data/.pgbackrest_gap_pending
  local before_full_count
  before_full_count=$(docker logs "$name" 2>&1 | grep -c "backup --type=full completed" || true)

  # Wait long enough for several catalog-verify cycles (interval=5s) +
  # several watcher iterations (POLL=5s) to elapse. ~20s is 4 cycles.
  sleep 20

  # Critical assertion: no NEW fulls. The marker must have suppressed
  # both the catalog-verify-clear-state path AND the periodic-full path.
  local after_full_count
  after_full_count=$(docker logs "$name" 2>&1 | grep -c "backup --type=full completed" || true)
  if [ "$after_full_count" -gt "$before_full_count" ]; then
    ko t_gap_marker_suppresses_catalog_verify_full "watcher took an extra full while gap marker present (before=$before_full_count after=$after_full_count)"
    fail_dump t_gap_marker_suppresses_catalog_verify_full "$name"
    return
  fi
  # And the marker is still in place (we never let recovery complete).
  if ! docker exec "$name" test -f /var/lib/postgresql/data/.pgbackrest_gap_pending; then
    ko t_gap_marker_suppresses_catalog_verify_full "gap marker cleared without recovery; test premise broken"
    return
  fi

  ok t_gap_marker_suppresses_catalog_verify_full
  note "gap marker held for ~20s through catalog-verify cycles; no extra full taken"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

# L4. .pgbackrest_stanza_create_timeout sentinel must NOT appear after a
# happy-path boot. The full timeout-then-clear cycle (postgres never
# reaches pg_isready in 600s → sentinel written → restart with healthy
# postgres → sentinel cleared) is hard to drive in CI without a 10-min
# wait, so this test pins the cheap half: a normal boot does not write
# the sentinel. The cleanup branch is exercised inline in
# bootstrap_pgbackrest_stanza right after `stanza-create completed`,
# which has run by the time this test inspects.
t_stanza_create_timeout_sentinel_absent_on_success() {
  local name=t-stanza-sentinel-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true

  run_archiving_pg_fast_watcher "$name" "$vol"
  wait_for_pg "$name" || { ko t_stanza_create_timeout_sentinel_absent_on_success "startup"; fail_dump t_stanza_create_timeout_sentinel_absent_on_success "$name"; return; }

  # Wait for stanza-create to complete (with a generous deadline because
  # initdb + first-boot SQL can stretch this on a busy host).
  local deadline=$(($(date +%s) + 60)) hit=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker logs "$name" 2>&1 | grep -q "stanza-create completed"; then hit=1; break; fi
    sleep 1
  done
  if [ "$hit" != "1" ]; then
    ko t_stanza_create_timeout_sentinel_absent_on_success "stanza-create did not complete within deadline"
    fail_dump t_stanza_create_timeout_sentinel_absent_on_success "$name"
    return
  fi

  if docker exec "$name" test -f /var/lib/postgresql/data/.pgbackrest_stanza_create_timeout; then
    ko t_stanza_create_timeout_sentinel_absent_on_success ".pgbackrest_stanza_create_timeout written on happy-path boot"
    fail_dump t_stanza_create_timeout_sentinel_absent_on_success "$name"
    return
  fi

  ok t_stanza_create_timeout_sentinel_absent_on_success
  note "no .pgbackrest_stanza_create_timeout sentinel after happy-path boot"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

# L7. .pgbackrest_invalid_bucket sentinel is cleared on disable.
# After a service boots with a junk bucket (sentinel written) and the
# operator clears the env to disable archiving, the sentinel must not
# linger on the volume — otherwise the dashboard surfaces "PITR enabled
# but wired to junk" for a service that's actually in "never enabled"
# state.
t_invalid_bucket_sentinel_cleared_on_disable() {
  local name=t-bad-cleanup-${PG_VERSION}
  local vol=${name}-vol
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true

  # Phase 1: boot with a UUID-shape bucket (validator rejects it).
  docker run -d --name "$name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e WAL_ARCHIVE_BUCKET=121ccc45-0912-457e-8dc0-76625fe644bb \
    -e "WAL_ARCHIVE_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_ARCHIVE_REGION=us-east-1 \
    -e "WAL_ARCHIVE_KEY=$MINIO_USER" \
    -e "WAL_ARCHIVE_SECRET=$MINIO_PASS" \
    -v "$vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$name" || { ko t_invalid_bucket_sentinel_cleared_on_disable "phase1 startup"; fail_dump t_invalid_bucket_sentinel_cleared_on_disable "$name"; return; }
  if ! docker exec "$name" test -f /var/lib/postgresql/data/.pgbackrest_invalid_bucket; then
    ko t_invalid_bucket_sentinel_cleared_on_disable "phase1 did not write invalid-bucket sentinel"
    fail_dump t_invalid_bucket_sentinel_cleared_on_disable "$name"
    return
  fi

  # Phase 2: redeploy with no WAL_ARCHIVE_*. clear_pgbackrest_state_if_disabled
  # must remove the sentinel as part of the WAL_ARCHIVE_BUCKET-unset branch.
  docker rm -f "$name" >/dev/null
  docker run -d --name "$name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -v "$vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$name" || { ko t_invalid_bucket_sentinel_cleared_on_disable "phase2 startup"; fail_dump t_invalid_bucket_sentinel_cleared_on_disable "$name"; return; }

  if docker exec "$name" test -f /var/lib/postgresql/data/.pgbackrest_invalid_bucket; then
    ko t_invalid_bucket_sentinel_cleared_on_disable ".pgbackrest_invalid_bucket survived disable; clear function leaks it"
    fail_dump t_invalid_bucket_sentinel_cleared_on_disable "$name"
    return
  fi

  ok t_invalid_bucket_sentinel_cleared_on_disable
  note "invalid-bucket sentinel cleared by clear_pgbackrest_state_if_disabled on disable"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

# ----- runner ----------------------------------------------------------------

ALL_TESTS=(
  t_vanilla_boot
  t_collation_refresh_no_permission_error
  t_invalid_bucket_skips_archive
  t_archiving_boot
  t_archiving_boot_survives_pghostaddr
  t_alter_system_survives_restart
  t_s3_unreachable_pg_stays_up
  t_queue_max_5gib_trips
  t_wrapper_drop_on_bad_creds
  t_pitr_happy_path
  t_pitr_sentinel_blocks_retrigger
  t_empty_volume_restore_refuses_when_no_backup
  t_recovery_target_apostrophe_escaped
  t_pitr_retry_after_failed_staging
  t_disable_cleanup
  t_watcher_initial_full
  t_watcher_periodic_full
  t_watcher_periodic_diff
  t_watcher_gap_recovery_full
  t_dual_repo_archives_to_own_bucket
  t_empty_volume_restore_from_s3
  t_retention_expires_old_fulls
  t_watcher_gap_recovery_failed_count_path
  t_watcher_gap_recovery_lsn_lag_path
  t_watcher_wal_regression_async_spool_probe
  t_pitr_target_before_retention_window_refuses
  t_retention_expire_cascades_to_wal
  t_empty_volume_restore_refuses_on_bad_creds
  t_volume_wipe_same_bucket_preserves_both
  # major-upgrade archive re-anchor (these build their own version-pair images)
  t_upgrade_archive_reanchors_to_new_cluster_path
  t_reanchor_stale_marker_after_upgrade
  t_reanchor_backfills_missing_anchor
  t_legacy_wal_regression_state_fields_migrate
  t_restore_change_target_after_promote_noop
  t_restore_then_wipe_volume_redoes_restore
  t_restored_service_can_enable_archive_after_promote
  t_restored_marker_persists_across_restarts
  t_recovery_conf_persists_across_restart_mid_replay
  # learnings from test-postgres-pitr (image-level mirrors of the railway
  # mutation-driven e2e flows)
  t_pitr_target_xid_routes_xid_through_stack
  t_pitr_missing_wal_segment_fatals
  t_lifecycle_enable_disable_reenable
  t_chain_restore_r1_to_r2
  # audit follow-ups (M1/L4/L7 — see plan ok-fix-all-of-cheerful-wolf.md)
  t_catalog_verify_deadlock_selfheals
  t_gap_marker_suppresses_catalog_verify_full
  t_stanza_create_timeout_sentinel_absent_on_success
  t_invalid_bucket_sentinel_cleared_on_disable
)

trap 'cleanup_test_resources' EXIT

ensure_image
ensure_network
ensure_minio

if [ "$#" -gt 0 ]; then
  TESTS=("$@")
else
  TESTS=("${ALL_TESTS[@]}")
fi

for t in "${TESTS[@]}"; do
  log "running $t (PG ${PG_VERSION})"
  if ! declare -f "$t" > /dev/null; then
    ko "$t" "no such test"
    continue
  fi
  before_pass=$PASS
  before_fail=$FAIL
  "$t"
  # Every test must end via ok() or ko(); a return without recording
  # either is a phantom-pass landmine (e.g. silent skip on a missing
  # state-file dependency). Convert to a hard failure so it can't hide.
  if [ "$PASS" -eq "$before_pass" ] && [ "$FAIL" -eq "$before_fail" ]; then
    ko "$t" "test exited without recording PASS or FAIL — likely a silent skip"
  fi
done

echo
log "summary: ${G}${PASS} passed${N}, ${R}${FAIL} failed${N}"
if [ "$FAIL" -gt 0 ]; then
  echo "${R}failed:${N} ${FAILED_TESTS[*]}"
fi
exit "$FAIL"
