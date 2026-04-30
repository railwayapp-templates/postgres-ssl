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
  wal_count=$(mc "mc find local/${BUCKET}/pgbackrest/archive --name '*.zst' 2>/dev/null | wc -l")
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
  # pgBackRest's queue-max can trip.
  docker run -d --name "$name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_ARCHIVE_BUCKET=$BUCKET" \
    -e "WAL_ARCHIVE_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_ARCHIVE_REGION=us-east-1 \
    -e WAL_ARCHIVE_KEY=readonly \
    -e WAL_ARCHIVE_SECRET=readonlypass123 \
    -e WAL_ARCHIVE_PATH=/pgbackrest \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e WAL_DROP_THRESHOLD_MB=999999 \
    -v "$vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$name" || { ko t_queue_max_5gib_trips "ro boot"; return; }

  log "pumping >5 GiB of WAL with read-only creds"
  # Need ~16 MiB of WAL per segment; with a 1 KB payload per row, 200k rows
  # ≈ 200 MiB of writes. Pump until pg_wal crosses 5.5 GiB or we've done
  # 50 iterations.
  docker exec "$name" psql -U postgres -c "ALTER TABLE t ADD COLUMN IF NOT EXISTS payload text;" >/dev/null 2>&1
  for i in $(seq 1 50); do
    docker exec "$name" psql -U postgres -c "INSERT INTO t SELECT g, repeat('x', 1000) FROM generate_series($((i*200000)), $(((i+1)*200000))) g; SELECT pg_switch_wal();" >/dev/null 2>&1
    local pgwal
    pgwal=$(docker exec "$name" du -sm /var/lib/postgresql/data/pg_wal/ 2>/dev/null | awk '{print $1}')
    [ "${pgwal:-0}" -ge 5500 ] && break
  done
  sleep 3

  local dropped
  dropped=$(docker logs "$name" 2>&1 | grep -c "dropped WAL file.*archive queue exceeded 5GB" || true)
  if [ "$dropped" -lt 1 ]; then
    ko t_queue_max_5gib_trips "expected 'dropped WAL file ... archive queue exceeded 5GB' log lines; got $dropped"
    fail_dump t_queue_max_5gib_trips "$name"
    return
  fi

  local alive
  alive=$(docker exec "$name" psql -U postgres -At -c "SELECT 1" 2>/dev/null || echo DEAD)
  assert_eq "$alive" "1" "postgres alive after queue-max trip" || { ko t_queue_max_5gib_trips ""; return; }

  ok t_queue_max_5gib_trips
  note "$dropped 'archive queue exceeded 5GB' WAL drops logged"
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
  docker exec -u postgres "$name" bash -c '
    export PGBACKREST_REPO1_S3_BUCKET="$WAL_ARCHIVE_BUCKET"
    export PGBACKREST_REPO1_S3_KEY="$WAL_ARCHIVE_KEY"
    export PGBACKREST_REPO1_S3_KEY_SECRET="$WAL_ARCHIVE_SECRET"
    export PGBACKREST_REPO1_S3_REGION="$WAL_ARCHIVE_REGION"
    export PGBACKREST_REPO1_S3_ENDPOINT="$WAL_ARCHIVE_ENDPOINT"
    export PGBACKREST_REPO1_PATH="$WAL_ARCHIVE_PATH"
    pgbackrest --stanza=main backup --type=full
  ' >/dev/null 2>&1

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
}

t_pitr_happy_path() {
  setup_pitr_source >&2 || { ko "${FUNCNAME[0]}" "setup_pitr_source failed"; return; }
  read -r src_name src_vol < "/tmp/pitr-source-${PG_VERSION}"
  local target; target=$(cat "/tmp/pitr-target-${PG_VERSION}")
  local rest_name=t-rest-${PG_VERSION}
  local rest_vol=${rest_name}-vol
  new_volume "$rest_vol"

  if ! pgbackrest_restore_into "$rest_vol" /pgbackrest; then
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
    -e WAL_RECOVER_FROM_PATH=/pgbackrest \
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

  docker exec "$rest_name" psql -U postgres -c "INSERT INTO pitrtest(id,marker) VALUES (100,'post-promote');" >/dev/null
  docker rm -f "$rest_name" >/dev/null

  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=$MINIO_USER \
    -e WAL_RECOVER_FROM_SECRET=$MINIO_PASS \
    -e WAL_RECOVER_FROM_PATH=/pgbackrest \
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
  local rest_name=t-apos-${PG_VERSION}
  local rest_vol=${rest_name}-vol
  new_volume "$rest_vol"
  pgbackrest_restore_into "$rest_vol" /pgbackrest

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
    -e WAL_RECOVER_FROM_PATH=/pgbackrest \
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
  local rest_name=t-retry-${PG_VERSION}
  local rest_vol=${rest_name}-vol
  new_volume "$rest_vol"
  pgbackrest_restore_into "$rest_vol" /pgbackrest

  # First attempt: target unreachable (in the future).
  docker rm -f "$rest_name" >/dev/null 2>&1 || true
  docker run -d --name "$rest_name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=$MINIO_USER \
    -e WAL_RECOVER_FROM_SECRET=$MINIO_PASS \
    -e WAL_RECOVER_FROM_PATH=/pgbackrest \
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
    -e WAL_RECOVER_FROM_PATH=/pgbackrest \
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
    export PGBACKREST_REPO1_PATH=\"\${WAL_ARCHIVE_PATH:-/pgbackrest}\"
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

t_watcher_dual_repo_skips() {
  local name=t-dualrepo-${PG_VERSION}
  local vol=${name}-vol
  reset_bucket
  new_volume "$vol"
  docker rm -f "$name" >/dev/null 2>&1 || true

  # Set both WAL_RECOVER_FROM_* and WAL_ARCHIVE_*. Wrapper exports REPO1
  # (recover-from) and REPO2 (archive). The watcher must short-circuit to
  # avoid running `pgbackrest backup` against both repos (which would
  # include the source's read-only repo1).
  docker run -d --name "$name" --label postgres-ssl-e2e=1 --network "$NET" \
    -e POSTGRES_PASSWORD=test \
    -e "WAL_ARCHIVE_BUCKET=$BUCKET" \
    -e "WAL_ARCHIVE_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_ARCHIVE_REGION=us-east-1 \
    -e WAL_ARCHIVE_KEY=$MINIO_USER \
    -e WAL_ARCHIVE_SECRET=$MINIO_PASS \
    -e WAL_ARCHIVE_PATH=/pgbackrest \
    -e "WAL_RECOVER_FROM_BUCKET=$BUCKET" \
    -e "WAL_RECOVER_FROM_ENDPOINT=http://${MINIO}:9000" \
    -e WAL_RECOVER_FROM_REGION=us-east-1 \
    -e WAL_RECOVER_FROM_KEY=$MINIO_USER \
    -e WAL_RECOVER_FROM_SECRET=$MINIO_PASS \
    -e WAL_RECOVER_FROM_PATH=/pgbackrest-source \
    -e PGBACKREST_REPO1_S3_URI_STYLE=path \
    -e WAL_BACKUP_POLL_INTERVAL_SECONDS=5 \
    -v "$vol:/var/lib/postgresql/data" \
    "$IMAGE" >/dev/null
  wait_for_pg "$name" || { ko t_watcher_dual_repo_skips "no startup"; fail_dump t_watcher_dual_repo_skips "$name"; return; }
  sleep 6

  if ! docker logs "$name" 2>&1 | grep -q "pgbackrest-watcher: skipping — both WAL_RECOVER_FROM_\* and WAL_ARCHIVE_\* are set"; then
    ko t_watcher_dual_repo_skips "watcher did not log dual-repo skip"
    fail_dump t_watcher_dual_repo_skips "$name"
    return
  fi
  if docker logs "$name" 2>&1 | grep -q "pgbackrest-watcher: starting"; then
    ko t_watcher_dual_repo_skips "watcher should not have entered the poll loop"
    return
  fi
  ok t_watcher_dual_repo_skips
  docker rm -f "$name" >/dev/null
  docker volume rm "$vol" >/dev/null
}

t_empty_volume_restore_from_s3() {
  # Source: standalone archiving service with a base backup + a "before-target"
  # row, captured target time, and "after-target" rows.
  setup_pitr_source >&2 || { ko "${FUNCNAME[0]}" "setup_pitr_source failed"; return; }
  read -r src_name src_vol < "/tmp/pitr-source-${PG_VERSION}"
  local target; target=$(cat "/tmp/pitr-target-${PG_VERSION}")
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
    -e WAL_RECOVER_FROM_PATH=/pgbackrest \
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
  # invocation runs `pgbackrest expire` after the backup commits.
  for i in 2 3; do
    docker exec -u postgres "$name" bash -c '
      export PGBACKREST_REPO1_S3_BUCKET="$WAL_ARCHIVE_BUCKET"
      export PGBACKREST_REPO1_S3_KEY="$WAL_ARCHIVE_KEY"
      export PGBACKREST_REPO1_S3_KEY_SECRET="$WAL_ARCHIVE_SECRET"
      export PGBACKREST_REPO1_S3_REGION="$WAL_ARCHIVE_REGION"
      export PGBACKREST_REPO1_S3_ENDPOINT="$WAL_ARCHIVE_ENDPOINT"
      export PGBACKREST_REPO1_PATH="${WAL_ARCHIVE_PATH:-/pgbackrest}"
      pgbackrest --stanza=main backup --type=full
    ' >/dev/null 2>&1 || { ko t_retention_expires_old_fulls "manual full #$i failed"; return; }
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
  t_watcher_dual_repo_skips
  t_empty_volume_restore_from_s3
  t_retention_expires_old_fulls
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
