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
    "$IMAGE" >/dev/null
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

cleanup_test_resources() {
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
  sleep 5

  local alive
  alive=$(docker exec "$name" psql -U postgres -At -c "SELECT 1" 2>/dev/null || echo "DEAD")
  assert_eq "$alive" "1" "postgres alive after S3 outage" || { ko t_s3_unreachable_pg_stays_up ""; docker start "$MINIO" >/dev/null; return; }

  local failed_count
  failed_count=$(docker exec "$name" psql -U postgres -At -c "SELECT failed_count FROM pg_stat_archiver" 2>/dev/null || echo 0)
  if [ "$failed_count" -lt 1 ]; then
    ko t_s3_unreachable_pg_stays_up "pg_stat_archiver.failed_count should grow under S3 outage; got $failed_count"
    docker start "$MINIO" >/dev/null
    return
  fi

  log "restarting MinIO; archiver should catch up"
  docker start "$MINIO" >/dev/null
  sleep 8

  local archived_count
  archived_count=$(docker exec "$name" psql -U postgres -At -c "SELECT archived_count FROM pg_stat_archiver")
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
  run_archiving_pg "$name" "$vol"
  wait_for_pg "$name" >&2 || return 1
  # wait for stanza-create
  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
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

  if ! docker logs "$name" 2>&1 | grep -q "restore from source bucket failed"; then
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
  sleep 6

  if ! docker logs "$rest_name" 2>&1 | grep -q "PITR replay staged (target=$target)"; then
    ko t_pitr_retry_after_failed_staging "second attempt did not re-stage with new target"
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
# WAL_BACKUP_GAP_RESOLVED_GRACE_SECONDS=10 so the watcher's decision loop
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
    -e "WAL_BACKUP_GAP_RESOLVED_GRACE_SECONDS=10" \
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

  local before_count
  before_count=$(docker logs "$name" 2>&1 | grep -c "backup --type=full completed" || true)

  # Drop the gap marker by hand (no real failures to keep the test fast). The
  # watcher's gap_recovered() trivially-recovers when LAST_FAILED_EPOCH=0
  # (pg_stat_archiver clean), so the marker alone is enough to fire the
  # gap-recovery branch on the next poll.
  docker exec -u postgres "$name" touch /var/lib/postgresql/data/.pgbackrest_gap_pending

  # `cleared gap marker` is emitted right before `backup --type=full
  # completed` in run_backup(). Wait on both signals inside the loop —
  # checking them separately races against docker's stdout flush window
  # (the two echoes can land in different `docker logs` snapshots even
  # though the watcher emits them back-to-back in the same shell).
  local deadline=$(($(date +%s) + 30)) hit=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local logs now_count
    logs=$(docker logs "$name" 2>&1)
    now_count=$(echo "$logs" | grep -c "backup --type=full completed" || true)
    if [ "$now_count" -gt "$before_count" ] \
       && echo "$logs" | grep -q "cleared gap marker"; then
      hit=1; break
    fi
    sleep 2
  done
  if [ "$hit" != "1" ]; then
    ko t_watcher_gap_recovery_full "watcher did not take gap-recovery full or did not log 'cleared gap marker'"
    fail_dump t_watcher_gap_recovery_full "$name"
    return
  fi

  # Marker should be cleared by run_backup() after the full lands.
  if docker exec "$name" test -f /var/lib/postgresql/data/.pgbackrest_gap_pending; then
    ko t_watcher_gap_recovery_full ".pgbackrest_gap_pending was not cleared after gap-recovery full"
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

# G1. Real failure-driven gap recovery via pg_stat_archiver.failed_count
# growth (with the .pgbackrest_gap_pending marker NEVER touched). Catches
# the t_watcher_gap_recovery_full test's cheat: that test pokes the marker
# directly. This one drives the watcher purely off failed_count.
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
    -e WAL_BACKUP_GAP_RESOLVED_GRACE_SECONDS=10 \
    -v "$vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$name" || { ko t_watcher_gap_recovery_failed_count_path "no startup"; fail_dump t_watcher_gap_recovery_failed_count_path "$name"; return; }

  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c "CREATE TABLE t(id int); SELECT pg_switch_wal();" >/dev/null
  wait_for_watcher_backup "$name" full 60 || { ko t_watcher_gap_recovery_failed_count_path "no initial full"; fail_dump t_watcher_gap_recovery_failed_count_path "$name"; return; }

  local before_count
  before_count=$(docker logs "$name" 2>&1 | grep -c "backup --type=full completed" || true)

  # Disable the user → archive-push gets 403 → archive_command returns
  # non-zero (wrapper threshold not met) → Postgres bumps failed_count.
  mc "mc admin user disable local ${user}" >/dev/null
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

  # Marker should NOT have been written — that's the whole point of this
  # test (proves the failed_count branch fires independently of the marker).
  if docker exec "$name" test -f /var/lib/postgresql/data/.pgbackrest_gap_pending; then
    ko t_watcher_gap_recovery_failed_count_path ".pgbackrest_gap_pending was written; threshold should not have tripped"
    return
  fi

  # Re-enable the user → archive-push succeeds again → grace window starts
  # from last_failed_time. Wait grace + a few polls.
  mc "mc admin user enable local ${user}" >/dev/null

  local deadline=$(($(date +%s) + 60)) hit=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local now_count
    now_count=$(docker logs "$name" 2>&1 | grep -c "backup --type=full completed" || true)
    if [ "$now_count" -gt "$before_count" ]; then hit=1; break; fi
    sleep 2
  done
  if [ "$hit" != "1" ]; then
    ko t_watcher_gap_recovery_failed_count_path "watcher did not take gap-recovery full via failed_count path"
    fail_dump t_watcher_gap_recovery_failed_count_path "$name"
    return
  fi

  # last_full_failed_count must have advanced past 0 — otherwise next
  # iteration would re-trigger immediately.
  local last_failed_in_state
  last_failed_in_state=$(docker exec "$name" grep -E "^last_full_failed_count=" /var/lib/postgresql/data/.pgbackrest_backup_state 2>/dev/null | cut -d= -f2)
  if [ -z "$last_failed_in_state" ] || [ "$last_failed_in_state" = "0" ]; then
    ko t_watcher_gap_recovery_failed_count_path "last_full_failed_count not advanced (got '$last_failed_in_state'); next poll would re-trigger"
    return
  fi

  ok t_watcher_gap_recovery_failed_count_path
  note "failed_count=${failed_count} → grace → 2nd full; marker never written; last_full_failed_count=${last_failed_in_state}"
  mc "mc admin user remove local ${user}" >/dev/null 2>&1 || true
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
  if ! docker logs "$rest_name" 2>&1 | grep -q "unable to find backup set"; then
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
  if ! docker logs "$rest_name" 2>&1 | grep -q "restore from source bucket failed"; then
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
  # actually runs, so wait_for_pg returning is sufficient evidence that
  # the line is in the buffer, but harmless to give it a couple seconds
  # in case docker's log shipping lags under suite-load.
  local deadline=$(($(date +%s) + 10)) hit=0
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

  ok t_restored_marker_persists_across_restarts
  note ".pgbackrest_restored survived restart; configure_pgbackrest_recovery deferred"
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
#   idleRestore         → t_pitr_idle_source_target_time_fatals
#                         t_pitr_idle_source_target_xid_succeeds
#   gaps                → t_pitr_missing_wal_segment_fatals
#   lifecycle           → t_lifecycle_enable_disable_reenable
#   restoreThenRestore  → t_chain_restore_r1_to_r2

# Set up an idle source: archiving postgres with exactly one row-insert
# committed *after* the base backup, then several empty WAL switches (no
# commits). The commit's xid lands in WAL replayed forward from the backup
# checkpoint, so recovery_target_xid can match it; recovery_target_time
# past the commit, however, has no later record to terminate on, which
# is the FATAL the time-only test pins.
#
# Ordering matters: the schema (CREATE TABLE) is set up *before* the backup
# so the restored cluster has the table at end of base restore; the INSERT
# happens *after* the backup so the commit is in post-checkpoint WAL. This
# is the key fix vs. taking the backup last — in that case, the xid commit
# is in pre-checkpoint WAL (already applied via base restore, not in replay
# stream), and recovery_target_xid never finds it → FATAL.
#
# Echoes "<src_name>|<src_vol>|<src_path>|<post_commit_target>|<commit_xid>"
# on stdout. Caller splits on '|'. Designed so two related tests
# (target_time-FATALs and target_xid-succeeds) can share one source setup
# but each owns its own restore container/volume.
setup_idle_source() {
  local name="$1"
  local vol="${name}-vol"
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true
  run_archiving_pg "$name" "$vol"
  wait_for_pg "$name" >&2 || return 1
  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done

  # Each docker exec below MUST succeed — silent failures here used to
  # produce empty fields in the echoed metadata, which the calling test
  # then passed verbatim to `docker run -e POSTGRES_RECOVERY_TARGET_TIME=`,
  # the wrapper saw the env var as unset, skipped the pgbackrest restore
  # path entirely, and ran initdb instead. Test then waited 120s for a
  # FATAL that would never come.
  docker exec "$name" psql -U postgres -c "CREATE TABLE pitrtest(id int, marker text);" >/dev/null \
    || { echo "setup_idle_source: CREATE TABLE failed; container probably exited" >&2; return 1; }
  local source_path
  source_path=$(docker exec "$name" cat /var/lib/postgresql/data/.pgbackrest_repo_path 2>/dev/null) \
    || { echo "setup_idle_source: read .pgbackrest_repo_path failed" >&2; return 1; }
  if [ -z "$source_path" ]; then
    source_path="/pgbackrest"
  fi
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
  ' >/dev/null 2>&1 \
    || { echo "setup_idle_source: pgbackrest manual full failed" >&2; return 1; }

  # Single post-backup commit; capture its xid via xmin in a separate SELECT.
  # Two-call pattern (vs. INSERT … RETURNING xmin) is deliberate — psql -At
  # on a RETURNING statement still prints the command tag `INSERT 0 1`
  # alongside the value, so a `$(…)` capture grabs both lines and the
  # second one corrupts any env var it gets piped into. The follow-up
  # SELECT cleanly returns just the xmin value.
  docker exec "$name" psql -U postgres -c "INSERT INTO pitrtest VALUES (1, 'only-commit');" >/dev/null \
    || { echo "setup_idle_source: post-backup INSERT failed" >&2; return 1; }
  local commit_xid
  commit_xid=$(docker exec "$name" psql -U postgres -At -c \
    "SELECT xmin::text::bigint FROM pitrtest WHERE id=1") \
    || { echo "setup_idle_source: xmin capture failed" >&2; return 1; }
  if [ -z "$commit_xid" ] || [ "$commit_xid" = "0" ]; then
    echo "setup_idle_source: captured xid is empty/zero (got '$commit_xid')" >&2
    return 1
  fi
  echo "setup_idle_source: captured commit xid=${commit_xid} (post-backup INSERT)" >&2

  # Force the commit's WAL segment to ship to S3 BEFORE we generate a string
  # of empty switches — without this, the segment with the commit could lag
  # behind the empty ones in archive (async push order isn't guaranteed
  # under load) and the restore would miss it.
  docker exec "$name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null \
    || { echo "setup_idle_source: pg_switch_wal failed" >&2; return 1; }
  sleep 3

  # Sleep so target NOW() lands strictly past the commit's WAL timestamp,
  # then push several empty WAL switches. archive_command ships them; archive
  # head advances past target while pg_last_committed_xact stays at the
  # only insert's commit.
  local target
  target=$(docker exec "$name" psql -U postgres -At -c "SELECT now()::timestamptz(0)") \
    || { echo "setup_idle_source: target capture failed" >&2; return 1; }
  if [ -z "$target" ]; then
    echo "setup_idle_source: target empty" >&2
    return 1
  fi
  for _ in 1 2 3 4 5; do
    docker exec "$name" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null \
      || { echo "setup_idle_source: late pg_switch_wal failed" >&2; return 1; }
    sleep 1
  done
  sleep 4  # let the last batch of empty segments ship to S3

  echo "${name}|${vol}|${source_path}|${target}|${commit_xid}"
}

# I1. Idle source + target_time only → recovery FATALs loud.
# Mirrors test-postgres-pitr/idleRestore for the no-clamp regression: when
# the target is past the last commit but inside the archived WAL, postgres
# walks WAL to archive head, never sees a record with commit time > target,
# and FATALs with "recovery ended before configured recovery target was
# reached". The wrapper.sh comment block at the recovery-target-type pick
# explicitly documents this — this test pins it as observable behavior so a
# future refactor that silently degrades (e.g. switches to
# recovery_target_action='shutdown') trips the suite.
t_pitr_idle_source_target_time_fatals() {
  local src_name=t-idle-time-src-${PG_VERSION}
  local rest_name=t-idle-time-rest-${PG_VERSION}
  local rest_vol=${rest_name}-vol

  local meta
  meta=$(setup_idle_source "$src_name") \
    || { ko t_pitr_idle_source_target_time_fatals "setup_idle_source failed"; return; }
  local src_vol src_path target _xid
  IFS='|' read -r _src_name src_vol src_path target _xid <<< "$meta"

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

  # Wait up to 120s for the FATAL to land. pgbackrest restore needs a few
  # seconds on a fresh volume; postgres then walks WAL through archive-get
  # before declaring the target unreachable.
  local deadline=$(($(date +%s) + 120)) found=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker logs "$rest_name" 2>&1 | grep -q "recovery ended before configured recovery target was reached"; then
      found=1; break
    fi
    sleep 3
  done
  if [ "$found" != "1" ]; then
    ko t_pitr_idle_source_target_time_fatals "expected 'recovery ended before configured recovery target was reached' FATAL within 120s"
    fail_dump t_pitr_idle_source_target_time_fatals "$rest_name"
    return
  fi

  ok t_pitr_idle_source_target_time_fatals
  note "idle source + target_time only → recovery FATALs as documented"
  docker rm -f "$src_name" "$rest_name" >/dev/null
  docker volume rm "$src_vol" "$rest_vol" >/dev/null
}

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

# ----- runner ----------------------------------------------------------------

ALL_TESTS=(
  t_vanilla_boot
  t_archiving_boot
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
  t_pitr_target_before_retention_window_refuses
  t_retention_expire_cascades_to_wal
  t_empty_volume_restore_refuses_on_bad_creds
  t_volume_wipe_same_bucket_preserves_both
  t_restore_change_target_after_promote_noop
  t_restore_then_wipe_volume_redoes_restore
  t_restored_service_can_enable_archive_after_promote
  t_restored_marker_persists_across_restarts
  # learnings from test-postgres-pitr (image-level mirrors of the railway
  # mutation-driven e2e flows)
  t_pitr_idle_source_target_time_fatals
  t_pitr_target_xid_routes_xid_through_stack
  t_pitr_missing_wal_segment_fatals
  t_lifecycle_enable_disable_reenable
  t_chain_restore_r1_to_r2
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
