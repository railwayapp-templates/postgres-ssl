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
      echo "${R}--- docker logs ${c} (last 40) ---${N}" >&2
      docker logs --tail 40 "$c" 2>&1 | sed 's/^/    /' >&2
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

# Run a one-off pgbackrest restore into a target volume.
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
    -c 'chown -R postgres:postgres /var/lib/postgresql/data && chmod 0700 /var/lib/postgresql/data && gosu postgres pgbackrest --stanza=main --pg1-path=/var/lib/postgresql/data restore' \
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

# Wait for postgres to accept connections.
wait_for_pg() {
  local container="$1" deadline=$(($(date +%s) + 60))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker exec "$container" pg_isready -U postgres -q 2>/dev/null; then
      return 0
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
  local container="$1" deadline=$(($(date +%s) + 60))
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

  # Insert id=1 (before-target), capture target, insert id=2,3 (after).
  docker exec "$name" psql -U postgres -c "INSERT INTO pitrtest(id,marker) VALUES (1,'before');" >/dev/null
  sleep 2
  local target
  target=$(docker exec "$name" psql -U postgres -At -c "SELECT now()::timestamptz(0)")
  sleep 2
  docker exec "$name" psql -U postgres -c "INSERT INTO pitrtest(id,marker) VALUES (2,'after');" >/dev/null
  docker exec "$name" psql -U postgres -c "INSERT INTO pitrtest(id,marker) VALUES (3,'much-after'); SELECT pg_switch_wal(); SELECT pg_switch_wal();" >/dev/null
  sleep 4
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
  # leave restored container/volume around for the next sentinel test
  echo "$rest_name $rest_vol" > "/tmp/pitr-restored-${PG_VERSION}"
  docker rm -f "$src_name" >/dev/null
  docker volume rm "$src_vol" >/dev/null
}

t_pitr_sentinel_blocks_retrigger() {
  if [ ! -f "/tmp/pitr-restored-${PG_VERSION}" ]; then
    note "skipping (run t_pitr_happy_path first)"
    return
  fi
  read -r rest_name rest_vol < "/tmp/pitr-restored-${PG_VERSION}"
  local src_path; src_path=$(pitr_source_path)

  docker exec "$rest_name" psql -U postgres -c "INSERT INTO pitrtest(id,marker) VALUES (100,'post-promote');" >/dev/null
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
    -e "POSTGRES_RECOVERY_TARGET_TIME=2020-01-01 00:00:00+00" \
    -v "$rest_vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$rest_name" || { ko t_pitr_sentinel_blocks_retrigger "restart"; return; }

  if ! docker exec "$rest_name" test -f /var/lib/postgresql/data/.pitr_configured; then
    ko t_pitr_sentinel_blocks_retrigger ".pitr_configured marker not written"
    return
  fi
  local rows
  rows=$(docker exec "$rest_name" psql -U postgres -At -c "SELECT count(*) FROM pitrtest WHERE id=100")
  if [ "$rows" -ne 1 ]; then
    ko t_pitr_sentinel_blocks_retrigger "post-promote row should be preserved on restart; got $rows"
    return
  fi
  ok t_pitr_sentinel_blocks_retrigger
  docker rm -f "$rest_name" >/dev/null
  docker volume rm "$rest_vol" >/dev/null
  rm -f "/tmp/pitr-restored-${PG_VERSION}"
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

  local deadline=$(($(date +%s) + 30)) hit=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local now_count
    now_count=$(docker logs "$name" 2>&1 | grep -c "backup --type=full completed" || true)
    if [ "$now_count" -gt "$before_count" ]; then hit=1; break; fi
    sleep 2
  done
  if [ "$hit" != "1" ]; then
    ko t_watcher_gap_recovery_full "watcher did not take gap-recovery full"
    fail_dump t_watcher_gap_recovery_full "$name"
    return
  fi

  # Marker should be cleared by run_backup() after the full lands.
  if docker exec "$name" test -f /var/lib/postgresql/data/.pgbackrest_gap_pending; then
    ko t_watcher_gap_recovery_full ".pgbackrest_gap_pending was not cleared after gap-recovery full"
    return
  fi

  if ! docker logs "$name" 2>&1 | grep -q "cleared gap marker"; then
    ko t_watcher_gap_recovery_full "expected 'cleared gap marker' log line"
    fail_dump t_watcher_gap_recovery_full "$name"
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

  if ! wait_for_watcher_backup "$fork_name" full 90; then
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

# G9-companion: confirms the watcher's boot-time bucket reconcile clears a
# stale cache when the bucket has been swapped out under it. Drives the new
# reconcile_state_with_bucket() path in pgbackrest-backup-watcher.sh.
t_watcher_reconciles_state_against_bucket_on_boot() {
  local name=t-recon-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true

  # Phase 1: archive + take initial full into bucket A. State file gets a
  # last_full_at entry.
  run_archiving_pg_fast_watcher "$name" "$vol"
  wait_for_pg "$name" || { ko t_watcher_reconciles_state_against_bucket_on_boot "phase1 startup"; return; }
  for _ in $(seq 1 15); do
    docker logs "$name" 2>&1 | grep -q "stanza-create completed" && break
    sleep 1
  done
  docker exec "$name" psql -U postgres -c "CREATE TABLE t(id int); SELECT pg_switch_wal();" >/dev/null
  wait_for_watcher_backup "$name" full 60 || { ko t_watcher_reconciles_state_against_bucket_on_boot "no initial full"; return; }
  if ! docker exec "$name" grep -q "^last_full_at=" /var/lib/postgresql/data/.pgbackrest_backup_state; then
    ko t_watcher_reconciles_state_against_bucket_on_boot "phase1 didn't populate last_full_at"
    return
  fi

  # Phase 2: stop, wipe the bucket externally (simulates "operator pointed
  # WAL_ARCHIVE_BUCKET at a freshly-created bucket"), restart with same env.
  # On boot, reconcile must clear the stale last_full_at.
  docker rm -f "$name" >/dev/null
  reset_bucket

  run_archiving_pg_fast_watcher "$name" "$vol"
  wait_for_pg "$name" || { ko t_watcher_reconciles_state_against_bucket_on_boot "phase2 startup"; return; }

  # Reconcile fires once before the watcher's main loop. Wait a few polls.
  local deadline=$(($(date +%s) + 30)) reconciled=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker logs "$name" 2>&1 | grep -q "reconcile: bucket has no full but cache claims"; then
      reconciled=1; break
    fi
    sleep 2
  done
  if [ "$reconciled" != "1" ]; then
    ko t_watcher_reconciles_state_against_bucket_on_boot "watcher did not log reconcile-cleared"
    fail_dump t_watcher_reconciles_state_against_bucket_on_boot "$name"
    return
  fi

  # Force a WAL switch and confirm NEEDS_INITIAL_BACKUP fires (bucket truly
  # empty + cache cleared → archived_count > 0 + last_full_at empty → full).
  docker exec "$name" psql -U postgres -c "INSERT INTO t VALUES (1); SELECT pg_switch_wal();" >/dev/null
  if ! wait_for_watcher_backup "$name" full 60; then
    ko t_watcher_reconciles_state_against_bucket_on_boot "watcher did not take fresh initial full after reconcile"
    fail_dump t_watcher_reconciles_state_against_bucket_on_boot "$name"
    return
  fi

  ok t_watcher_reconciles_state_against_bucket_on_boot
  note "stale cache cleared on boot; NEEDS_INITIAL_BACKUP re-fired against the empty bucket"
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
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
  # t_watcher_reconciles_state_against_bucket_on_boot — depends on
  # reconcile_state_with_bucket() in the watcher, which isn't on the
  # per-cluster-archive-paths branch yet. Reinstate when D1 lands.
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
  "$t"
done

echo
log "summary: ${G}${PASS} passed${N}, ${R}${FAIL} failed${N}"
if [ "$FAIL" -gt 0 ]; then
  echo "${R}failed:${N} ${FAILED_TESTS[*]}"
fi
exit "$FAIL"
