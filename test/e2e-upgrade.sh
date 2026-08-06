#!/usr/bin/env bash
# test/e2e-upgrade.sh — end-to-end test harness for the in-place major
# upgrade job (Dockerfile.upgrade + upgrade-job.sh) and the runtime
# wrapper's major-version guards.
#
# Builds the runtime images for FROM and TO majors (default 16 -> 17,
# override with FROM_VERSION/TO_VERSION) plus the dual-binary job image,
# then walks every assertion in sequence. Each assertion is a `t_*`
# function; failure dumps the relevant container logs. Final exit code is
# the count of failed tests.
#
# Run: ./test/e2e-upgrade.sh
# Or:  FROM_VERSION=15 TO_VERSION=17 ./test/e2e-upgrade.sh
# Or:  ./test/e2e-upgrade.sh t_upgrade_happy_path t_upgrade_idempotent
#
# Designed for a single-host docker daemon. Volumes are scoped per test.

set -uo pipefail

FROM_VERSION="${FROM_VERSION:-16}"
TO_VERSION="${TO_VERSION:-17}"
FROM_IMAGE="postgres-ssl-e2e:${FROM_VERSION}"
TO_IMAGE="postgres-ssl-e2e:${TO_VERSION}"
JOB_IMAGE="postgres-upgrade-e2e:${FROM_VERSION}-${TO_VERSION}"

# The chained-upgrade test (FROM -> TO -> TO+1 on one volume) needs a third
# major; it self-skips when no Dockerfile exists for it.
CHAIN_VERSION="$((TO_VERSION + 1))"
CHAIN_IMAGE="postgres-ssl-e2e:${CHAIN_VERSION}"
CHAIN_JOB_IMAGE="postgres-upgrade-e2e:${TO_VERSION}-${CHAIN_VERSION}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGDATA_IN_VOLUME="/var/lib/postgresql/data/pgdata"
MARKER_PATH="/var/lib/postgresql/data/.railway-major-upgrade.json"
# Docker network for the remote-client tests: the default bridge has no name
# resolution, a user-defined one does.
E2E_NET="upg-e2e-net"

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

fail_dump() {
  local label="$1"; shift
  echo "${R}--- failure detail (${label}) ---${N}" >&2
  for c in "$@"; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${c}$"; then
      echo "${R}--- docker logs ${c} (last 60) ---${N}" >&2
      docker logs --tail 60 "$c" 2>&1 | sed 's/^/    /' >&2
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
  echo "  actual (tail):       $(echo "$haystack" | tail -5)"
  echo "  msg:                 $msg"
  return 1
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if ! echo "$haystack" | grep -qF -- "$needle"; then return 0; fi
  echo "  expected NOT to contain: $needle"
  echo "  msg:                     $msg"
  return 1
}

# ----- environment management ------------------------------------------------
# Always build. The scripts under test (wrapper.sh, upgrade-job.sh) are
# COPY'd into these images, so an existence check would silently test a stale
# copy of the very code being changed. Docker's layer cache makes the repeat
# build cheap — only the COPY layers re-run.
ensure_images() {
  for pair in "$FROM_VERSION:$FROM_IMAGE" "$TO_VERSION:$TO_IMAGE"; do
    local ver="${pair%%:*}" img="${pair#*:}"
    log "building runtime image $img"
    docker build -q -f "$REPO_ROOT/Dockerfile.${ver}" -t "$img" "$REPO_ROOT" >/dev/null || exit 1
  done
  log "building job image $JOB_IMAGE"
  docker build -q -f "$REPO_ROOT/Dockerfile.upgrade" \
    --build-arg "FROM_VERSION=$FROM_VERSION" --build-arg "TO_VERSION=$TO_VERSION" \
    -t "$JOB_IMAGE" "$REPO_ROOT" >/dev/null || exit 1
  docker network inspect "$E2E_NET" >/dev/null 2>&1 || docker network create "$E2E_NET" >/dev/null
}

# Built lazily by the chained-upgrade test only — a TO -> TO+1 job image is
# a full apt-install build, not worth paying when the test self-skips.
ensure_chain_images() {
  [ -f "$REPO_ROOT/Dockerfile.${CHAIN_VERSION}" ] || return 1
  log "building runtime image $CHAIN_IMAGE"
  docker build -q -f "$REPO_ROOT/Dockerfile.${CHAIN_VERSION}" -t "$CHAIN_IMAGE" "$REPO_ROOT" >/dev/null || return 1
  log "building job image $CHAIN_JOB_IMAGE"
  docker build -q -f "$REPO_ROOT/Dockerfile.upgrade" \
    --build-arg "FROM_VERSION=$TO_VERSION" --build-arg "TO_VERSION=$CHAIN_VERSION" \
    -t "$CHAIN_JOB_IMAGE" "$REPO_ROOT" >/dev/null || return 1
}

# Run a shell snippet against a (stopped) volume, via the job image.
in_volume() {
  local vol="$1" snippet="$2"
  docker run --rm --label postgres-upgrade-e2e=1 \
    -v "$vol:/var/lib/postgresql/data" --entrypoint /bin/sh "$JOB_IMAGE" -c "$snippet"
}

# psql from a SECOND container over the docker network — a remote client, so
# it exercises pg_hba's `host all all all` rule rather than the loopback
# lines that make localhost-only tests blind to remote-auth regressions.
remote_psql() {
  local host="$1" sql="$2"
  docker run --rm --network "$E2E_NET" --label postgres-upgrade-e2e=1 \
    -e PGPASSWORD=test --entrypoint psql "$FROM_IMAGE" \
    -h "$host" -U postgres -d postgres -tAc "$sql" 2>&1
}

# Removing a container is asynchronous enough that the next `docker volume rm`
# can still see the volume as in-use. Wait for the name to actually disappear
# before returning, so callers can rely on the volume being free.
remove_container() {
  local name="$1" deadline=$(($(date +%s) + 30))
  docker rm -f "$name" >/dev/null 2>&1
  while [ "$(date +%s)" -lt "$deadline" ]; do
    docker ps -a --format '{{.Names}}' | grep -qx "$name" || return 0
    sleep 1
  done
  echo "  container $name did not go away"
  return 1
}

# A volume that a dying container still holds fails to delete — and with the
# failure swallowed, the "fresh" volume silently carries the previous test's
# data (or its still-terminating postgres). Retry until the delete really
# succeeds, and fail the test rather than proceed on a dirty volume.
fresh_volume() {
  local vol="$1" deadline=$(($(date +%s) + 60))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! docker volume inspect "$vol" >/dev/null 2>&1; then
      docker volume create "$vol" >/dev/null
      return 0
    fi
    docker volume rm "$vol" >/dev/null 2>&1
    sleep 1
  done
  echo "  could not free volume $vol (still in use)"
  return 1
}

# Start a runtime postgres container on a volume. Extra docker args pass
# through after name+vol+image.
#
# Container names are reused across tests, so a leftover container of the same
# name must be removed first and the run must FAIL LOUDLY otherwise: a swallowed
# name conflict leaves the old container (on the old volume) answering, and every
# later psql in the test silently seeds or asserts against the wrong database.
run_pg() {
  local name="$1" vol="$2" image="$3"; shift 3
  remove_container "$name" || return 1
  if ! docker run -d --name "$name" --label postgres-upgrade-e2e=1 \
    -e "POSTGRES_PASSWORD=test" \
    -e "PGDATA=$PGDATA_IN_VOLUME" \
    "$@" \
    -v "$vol:/var/lib/postgresql/data" \
    "$image" >/dev/null; then
    echo "  docker run failed for container $name on volume $vol"
    return 1
  fi
}

# Waits for the FINAL server, never the temporary one docker-entrypoint runs
# during initdb to execute the init scripts. That temp server logs its own
# "ready to accept connections" and then shuts down, so both pg_isready on the
# unix socket and a log grep will happily match it — and a seed issued then dies
# with "the database system is shutting down". The discriminator is TCP: the
# temp server is started with listen_addresses='' and has no TCP listener, so a
# TCP-ready answer can only come from the real one.
wait_for_pg() {
  local container="$1" deadline=$(($(date +%s) + 120))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker exec "$container" pg_isready -q -h 127.0.0.1 -p 5432 -U postgres 2>/dev/null; then
      return 0
    fi
    if [ "$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null)" = "exited" ]; then
      return 1
    fi
    sleep 1
  done
  return 1
}

psql_in() {
  local container="$1" sql="$2"
  docker exec "$container" psql -U postgres -tAc "$sql" 2>&1
}

# Same, but fails the test when postgres reports an error. Setup steps must
# never be silently swallowed — a seed that didn't run turns into a confusing
# "relation does not exist" three assertions later.
psql_must() {
  local container="$1" sql="$2" out
  out="$(psql_in "$container" "$sql")"
  if echo "$out" | grep -qE "^(ERROR|FATAL|psql: error)"; then
    echo "  psql failed: $sql"
    echo "  output: $out"
    fail_dump "psql:$container" "$container"
    return 1
  fi
}

# Clean stop: shut postgres down through pg_ctl so pg_control records
# "shut down". `docker stop` alone is NOT clean on this image — bash as PID 1
# never forwards SIGTERM, so postgres is SIGKILLed after the grace period and
# leaves an unclean cluster plus a stale postmaster.pid (see kill_pg, which
# exercises that path deliberately).
stop_pg() {
  local name="$1"
  docker exec "$name" gosu postgres pg_ctl -D "$PGDATA_IN_VOLUME" -w -t 60 -m fast stop >/dev/null 2>&1
  docker stop -t 30 "$name" >/dev/null 2>&1
  remove_container "$name"
}

# Ungraceful stop: what the platform actually does when a deployment is
# stopped (and what any crash looks like) — unreplayed WAL, cluster state
# "in production", stale postmaster.pid.
kill_pg() {
  local name="$1"
  docker kill -s KILL "$name" >/dev/null 2>&1
  remove_container "$name"
}

# Run the upgrade job in a given mode on a volume; captures combined output.
# Sets JOB_OUT and JOB_RC.
run_job() {
  local vol="$1" mode="${2:-upgrade}"
  JOB_OUT=$(docker run --rm --label postgres-upgrade-e2e=1 \
    -e "PGDATA=$PGDATA_IN_VOLUME" \
    -v "$vol:/var/lib/postgresql/data" \
    "$JOB_IMAGE" "$mode" 2>&1)
  JOB_RC=$?
}

# Boot a runtime image on a volume and expect the wrapper to REFUSE (exit
# nonzero) with a message containing $3. Sets BOOT_OUT.
expect_boot_refusal() {
  local vol="$1" image="$2" needle="$3"
  local name="refusal-$RANDOM"
  docker run -d --name "$name" --label postgres-upgrade-e2e=1 \
    -e "POSTGRES_PASSWORD=test" -e "PGDATA=$PGDATA_IN_VOLUME" \
    -v "$vol:/var/lib/postgresql/data" "$image" >/dev/null
  local deadline=$(($(date +%s) + 30)) status="running"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    status="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)"
    [ "$status" = "exited" ] && break
    sleep 1
  done
  BOOT_OUT=$(docker logs "$name" 2>&1)
  local exit_code
  exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$name" 2>/dev/null)
  remove_container "$name"
  if [ "$status" != "exited" ] || [ "$exit_code" = "0" ]; then
    echo "  expected the container to exit nonzero (status=$status exit=$exit_code)"
    return 1
  fi
  assert_contains "$BOOT_OUT" "$needle" "refusal message"
}

# Seed a FROM-major cluster with recognizable data, then stop it cleanly.
# Leaves the volume ready for the job. $2 optional extra SQL.
seed_from_cluster() {
  local vol="$1" extra_sql="${2:-}"
  fresh_volume "$vol" || return 1
  run_pg seed-pg "$vol" "$FROM_IMAGE" || return 1
  wait_for_pg seed-pg || { fail_dump seed seed-pg; return 1; }
  psql_must seed-pg "CREATE TABLE upgrade_canary (id serial PRIMARY KEY, body text)" || return 1
  psql_must seed-pg "INSERT INTO upgrade_canary (body) SELECT 'row-' || g FROM generate_series(1, 1000) g" || return 1
  psql_must seed-pg "CREATE INDEX upgrade_canary_body_idx ON upgrade_canary (body)" || return 1
  psql_must seed-pg "CREATE EXTENSION IF NOT EXISTS vector" || return 1
  psql_must seed-pg "CREATE TABLE embeddings (id int, v vector(3)); INSERT INTO embeddings VALUES (1, '[1,2,3]')" || return 1
  if [ -n "$extra_sql" ]; then
    psql_must seed-pg "$extra_sql" || return 1
  fi
  # Prove the seed is durable before handing the volume to the job.
  assert_eq "$(psql_in seed-pg 'SELECT count(*) FROM upgrade_canary')" "1000" "seed persisted" || return 1
  stop_pg seed-pg
}

# Reads one marker field. Uses a plain `.field` and maps jq's "null" to the
# empty string rather than `// empty`, because jq's `//` treats a literal
# `false` as absent — a boolean field read that way comes back empty.
marker_field() {
  local vol="$1" field="$2"
  docker run --rm -v "$vol:/var/lib/postgresql/data" --entrypoint /bin/sh "$JOB_IMAGE" \
    -c "jq -r '.$field' $MARKER_PATH 2>/dev/null" | sed 's/^null$//'
}

volume_data_major() {
  local vol="$1"
  docker run --rm -v "$vol:/var/lib/postgresql/data" --entrypoint /bin/sh "$JOB_IMAGE" \
    -c "cat $PGDATA_IN_VOLUME/PG_VERSION 2>/dev/null"
}

cleanup_all() {
  # CI sets this so its failure-diagnostics step can still `docker logs` the
  # containers — this trap otherwise removes them before that step runs,
  # making the collection loop dead code. The runner VM is discarded either
  # way, so nothing leaks.
  [ "${E2E_KEEP_CONTAINERS:-0}" = "1" ] && return 0
  docker ps -aq --filter label=postgres-upgrade-e2e=1 | xargs -r docker rm -f >/dev/null 2>&1
  docker volume ls -q | grep '^upg-e2e-' | xargs -r docker volume rm >/dev/null 2>&1
  docker network rm "$E2E_NET" >/dev/null 2>&1
}
trap cleanup_all EXIT

# ----- tests -------------------------------------------------------------------

# Regression: the new wrapper guards must not disturb a vanilla fresh init +
# boot + restart on the FROM major.
t_vanilla_boot() {
  local vol="upg-e2e-vanilla"
  fresh_volume "$vol" || return 1
  run_pg vanilla-pg "$vol" "$FROM_IMAGE" || return 1
  wait_for_pg vanilla-pg || { fail_dump vanilla vanilla-pg; return 1; }
  psql_in vanilla-pg "SELECT 1" | grep -q 1 || return 1
  docker restart vanilla-pg >/dev/null
  wait_for_pg vanilla-pg || { fail_dump vanilla-restart vanilla-pg; return 1; }
  stop_pg vanilla-pg
}

# check mode on a healthy cluster: exit 0, volume untouched, FROM still boots.
t_check_pass() {
  local vol="upg-e2e-checkpass"
  seed_from_cluster "$vol" || return 1
  run_job "$vol" check
  assert_eq "$JOB_RC" 0 "check mode exit code" || { echo "$JOB_OUT" | tail -20; return 1; }
  assert_contains "$JOB_OUT" '"ok":true' "machine-readable result" || return 1
  assert_eq "$(volume_data_major "$vol")" "$FROM_VERSION" "data major untouched by check" || return 1
  run_pg checkpass-pg "$vol" "$FROM_IMAGE" || return 1
  wait_for_pg checkpass-pg || { fail_dump checkpass checkpass-pg; return 1; }
  assert_eq "$(psql_in checkpass-pg 'SELECT count(*) FROM upgrade_canary')" "1000" "data intact after check" || return 1
  stop_pg checkpass-pg
}

# A prepared transaction is a version-independent pg_upgrade blocker: check
# exits 1, names it, and the FROM cluster still boots untouched.
#
# Deliberately NOT using reg*/aclitem columns here: pg_upgrade gates those
# checks on the SOURCE major (both fire from 14/15, neither fires from 16+),
# so they make a poor assertion for a harness parameterized over version
# pairs — and that gating is exactly what the dashboard preflight has to
# mirror.
t_check_blocker() {
  local vol="upg-e2e-blocker"
  fresh_volume "$vol" || return 1
  run_pg blocker-pg "$vol" "$FROM_IMAGE" || return 1
  wait_for_pg blocker-pg || { fail_dump blocker blocker-pg; return 1; }
  psql_in blocker-pg "ALTER SYSTEM SET max_prepared_transactions = 10" >/dev/null
  docker restart blocker-pg >/dev/null
  wait_for_pg blocker-pg || { fail_dump blocker-restart blocker-pg; return 1; }
  psql_in blocker-pg "BEGIN; CREATE TABLE prep_canary (x int); PREPARE TRANSACTION 'e2e_blocker_tx'" >/dev/null
  assert_eq "$(psql_in blocker-pg 'SELECT count(*) FROM pg_prepared_xacts')" "1" "prepared transaction staged" || return 1
  stop_pg blocker-pg

  run_job "$vol" check
  assert_eq "$JOB_RC" 1 "check mode exit code with blocker" || { echo "$JOB_OUT" | tail -20; return 1; }
  assert_contains "$JOB_OUT" "prepared transaction" "blocker named in output" || return 1

  # Untouched: the old cluster still boots and the blocker is still there.
  run_pg blocker2-pg "$vol" "$FROM_IMAGE" || return 1
  wait_for_pg blocker2-pg || { fail_dump blocker2 blocker2-pg; return 1; }
  assert_eq "$(psql_in blocker2-pg 'SELECT count(*) FROM pg_prepared_xacts')" "1" "cluster untouched by a failed check" || return 1
  psql_in blocker2-pg "ROLLBACK PREPARED 'e2e_blocker_tx'" >/dev/null
  stop_pg blocker2-pg
}

# reg*/aclitem columns block ONLY from a pre-16 source. Runs on the pairs
# where that gating says it must fire, and asserts pg_upgrade agrees — this is
# the ground truth the dashboard preflight's version gating mirrors.
t_check_blocker_pre16_types() {
  if [ "$FROM_VERSION" -ge 16 ]; then
    note "skipped: reg*/aclitem checks only fire from a pre-16 source"
    return 0
  fi
  local vol="upg-e2e-pre16types"
  seed_from_cluster "$vol" "CREATE TABLE t_aclitem (c aclitem); CREATE TABLE t_regproc (c regproc)" || return 1
  run_job "$vol" check
  assert_eq "$JOB_RC" 1 "check exit code with pre-16 type blockers" || { echo "$JOB_OUT" | tail -20; return 1; }
  assert_contains "$JOB_OUT" "reg* data types" "reg* blocker named" || return 1
  assert_contains "$JOB_OUT" "aclitem" "aclitem blocker named" || return 1
}

# Wrong source major: a FROM->TO job pointed at a TO-major volume refuses.
t_refuses_wrong_major() {
  local vol="upg-e2e-wrongmajor"
  fresh_volume "$vol" || return 1
  run_pg wrong-pg "$vol" "$TO_IMAGE" || return 1
  wait_for_pg wrong-pg || { fail_dump wrongmajor wrong-pg; return 1; }
  stop_pg wrong-pg
  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 2 "job refuses wrong source major" || { echo "$JOB_OUT" | tail -10; return 1; }
  assert_contains "$JOB_OUT" "this job upgrades $FROM_VERSION" "message names the majors" || return 1
}

# The platform stops deployments by killing the container, so the job must
# handle an unclean cluster: replay WAL with the old binaries, shut down
# cleanly, then upgrade. Without this, pg_upgrade refuses and every real
# upgrade fails. Committed rows written right before the kill must survive.
t_recovers_unclean_shutdown() {
  local vol="upg-e2e-unclean"
  fresh_volume "$vol" || return 1
  run_pg unclean-pg "$vol" "$FROM_IMAGE" || return 1
  wait_for_pg unclean-pg || { fail_dump unclean unclean-pg; return 1; }
  psql_must unclean-pg "CREATE TABLE unclean_canary (id int)" || return 1
  psql_must unclean-pg "INSERT INTO unclean_canary SELECT generate_series(1, 500)" || return 1
  psql_must unclean-pg "CHECKPOINT" || return 1
  psql_must unclean-pg "INSERT INTO unclean_canary SELECT generate_series(501, 700)" || return 1
  kill_pg unclean-pg

  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "upgrade after unclean shutdown" || { echo "$JOB_OUT" | tail -30; return 1; }
  assert_contains "$JOB_OUT" "replaying WAL" "recovery path was taken" || return 1
  assert_eq "$(marker_field "$vol" phase)" "completed" "marker completed" || return 1

  run_pg unclean2-pg "$vol" "$TO_IMAGE" || return 1
  wait_for_pg unclean2-pg || { fail_dump unclean2 unclean2-pg; return 1; }
  assert_eq "$(psql_in unclean2-pg 'SELECT count(*) FROM unclean_canary')" "700" "post-checkpoint rows replayed and upgraded" || return 1
  stop_pg unclean2-pg
}

# A second concurrent job on the same volume is refused (activity-retry race).
t_refuses_concurrent_job() {
  local vol="upg-e2e-concurrent"
  seed_from_cluster "$vol" || return 1
  # Hold the lock from a sleeper container, then try a real job.
  docker run -d --name lockholder --label postgres-upgrade-e2e=1 \
    -v "$vol:/var/lib/postgresql/data" --entrypoint /bin/sh "$JOB_IMAGE" \
    -c "exec 9>/var/lib/postgresql/data/.railway-major-upgrade.lock; flock 9; sleep 60" >/dev/null
  sleep 2
  run_job "$vol" upgrade
  local rc="$JOB_RC" out="$JOB_OUT"
  docker rm -f lockholder >/dev/null 2>&1
  assert_eq "$rc" 2 "second job refused" || { echo "$out" | tail -10; return 1; }
  assert_contains "$out" "holds the upgrade lock" "lock message" || return 1
}

# The whole point: upgrade succeeds, marker completes, the TO image boots,
# and every seeded object (rows, index, pgvector data) survived.
t_upgrade_happy_path() {
  local vol="upg-e2e-happy"
  seed_from_cluster "$vol" || return 1
  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "upgrade exit code" || { echo "$JOB_OUT" | tail -30; return 1; }
  assert_eq "$(marker_field "$vol" phase)" "completed" "marker phase" || return 1
  assert_eq "$(marker_field "$vol" needsReindex)" "true" "collation-reindex flag recorded" || return 1
  assert_eq "$(marker_field "$vol" needsConfigReview)" "true" "config-review flag recorded" || return 1
  # postgresql{,.auto}.conf are not carried; their reference copies must land
  # at the volume root, where they outlive the old dir's 24h reclaim.
  in_volume "$vol" "test -f /var/lib/postgresql/data/.pre-upgrade-${FROM_VERSION}-postgresql.conf \
    && test -f /var/lib/postgresql/data/.pre-upgrade-${FROM_VERSION}-postgresql.auto.conf" \
    || { echo "  pre-upgrade config stash missing at the volume root"; return 1; }
  assert_eq "$(volume_data_major "$vol")" "$TO_VERSION" "on-disk major is now TO" || return 1
  # The rollback body must survive the upgrade itself (reclaim is a separate,
  # grace-gated path — see t_old_datadir_reclaimed).
  in_volume "$vol" "test -f ${PGDATA_IN_VOLUME}.old-${FROM_VERSION}/PG_VERSION" \
    || { echo "  pgdata.old-${FROM_VERSION} missing right after the upgrade"; return 1; }

  run_pg happy-pg "$vol" "$TO_IMAGE" || return 1
  wait_for_pg happy-pg || { fail_dump happy happy-pg; return 1; }
  assert_eq "$(psql_in happy-pg 'SELECT count(*) FROM upgrade_canary')" "1000" "rows survived" || return 1
  assert_contains "$(psql_in happy-pg "SELECT body FROM upgrade_canary WHERE body = 'row-500'")" "row-500" "index-reachable row" || return 1
  assert_eq "$(psql_in happy-pg 'SELECT count(*) FROM embeddings')" "1" "pgvector rows survived" || return 1
  assert_contains "$(psql_in happy-pg "SELECT v <-> '[1,2,3]' FROM embeddings LIMIT 1")" "0" "pgvector operator works on TO major" || return 1
  assert_contains "$(psql_in happy-pg 'SHOW server_version')" "$TO_VERSION." "server is TO major" || return 1
  stop_pg happy-pg
}

# Re-running a completed upgrade is a no-op success (activity retries).
t_upgrade_idempotent() {
  local vol="upg-e2e-happy"
  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "idempotent re-run exit code" || { echo "$JOB_OUT" | tail -10; return 1; }
  assert_contains "$JOB_OUT" '"alreadyDone":true' "no-op signaled" || return 1
}

# status mode reports the terminal state for the workflow's resume decision.
t_status_mode() {
  local vol="upg-e2e-happy"
  run_job "$vol" status
  assert_eq "$JOB_RC" 0 "status exit code" || return 1
  assert_contains "$JOB_OUT" '"phase":"completed"' "status phase" || return 1
  assert_contains "$JOB_OUT" "\"dataMajor\":\"$TO_VERSION\"" "status data major" || return 1
}

# manifest mode lists the TO major's installable extensions (preflight feed).
t_manifest_mode() {
  local vol="upg-e2e-happy"
  run_job "$vol" manifest
  assert_eq "$JOB_RC" 0 "manifest exit code" || return 1
  assert_contains "$JOB_OUT" '"vector"' "pgvector present in manifest" || return 1
  assert_contains "$JOB_OUT" '"pg_stat_statements"' "contrib extension present" || return 1
}

# pg_upgrade promotes a freshly initdb'd data directory, so postgresql.conf
# loses the ssl settings while the certificates survive at the volume root.
# A database that comes back with SSL off rejects every sslmode=require client,
# so the wrapper must re-apply the settings from the config's own state.
t_ssl_survives_upgrade() {
  local vol="upg-e2e-ssl"
  seed_from_cluster "$vol" || return 1
  run_pg ssl-before "$vol" "$FROM_IMAGE" || return 1
  wait_for_pg ssl-before || { fail_dump ssl-before ssl-before; return 1; }
  assert_eq "$(psql_in ssl-before 'SHOW ssl')" "on" "ssl on before upgrade" || return 1
  stop_pg ssl-before

  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "upgrade exit code" || { echo "$JOB_OUT" | tail -20; return 1; }

  run_pg ssl-after "$vol" "$TO_IMAGE" || return 1
  wait_for_pg ssl-after || { fail_dump ssl-after ssl-after; return 1; }
  assert_eq "$(psql_in ssl-after 'SHOW ssl')" "on" "ssl still on after upgrade" || return 1
  # And a TLS connection actually completes, not just the setting being present.
  assert_contains "$(docker exec ssl-after psql 'sslmode=require host=localhost user=postgres dbname=postgres' -tAc 'SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()' 2>&1)" "t" "sslmode=require connection is encrypted" || return 1
  stop_pg ssl-after
}

# After the upgraded database boots, the staged statistics rebuild runs and
# flips needsAnalyze off.
t_analyze_staged() {
  local vol="upg-e2e-happy"
  run_pg analyze-pg "$vol" "$TO_IMAGE" || return 1
  wait_for_pg analyze-pg || { fail_dump analyze analyze-pg; return 1; }
  local deadline=$(($(date +%s) + 120))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ "$(marker_field "$vol" needsAnalyze)" = "false" ]; then
      stop_pg analyze-pg
      return 0
    fi
    sleep 5
  done
  fail_dump analyze analyze-pg
  stop_pg analyze-pg
  echo "  needsAnalyze never flipped to false"
  return 1
}

# No marker, TO image on FROM data: the wrapper refuses with an explicit
# message BEFORE postgres touches anything.
t_mismatch_boot_failstop() {
  local vol="upg-e2e-mismatch"
  seed_from_cluster "$vol" || return 1
  expect_boot_refusal "$vol" "$TO_IMAGE" "does not upgrade the data files" || return 1
}

# After a completed upgrade, booting the OLD image is also refused loudly.
t_old_image_on_upgraded_data() {
  local vol="upg-e2e-happy"
  expect_boot_refusal "$vol" "$FROM_IMAGE" "data directory holds major version $TO_VERSION" || return 1
}

# A non-completed marker blocks EVERY runtime boot — both majors. An
# UNREADABLE marker must refuse too: a file we cannot parse still means an
# upgrade touched this volume, and "nothing in flight" is the one
# interpretation that can lose data (same contract as postgres-ha's guards).
t_boot_refused_mid_upgrade() {
  local vol="upg-e2e-midmarker"
  seed_from_cluster "$vol" || return 1
  docker run --rm -v "$vol:/var/lib/postgresql/data" --entrypoint /bin/sh "$JOB_IMAGE" \
    -c "echo '{\"phase\": \"upgraded\", \"from\": \"$FROM_VERSION\", \"to\": \"$TO_VERSION\"}' > $MARKER_PATH"
  expect_boot_refusal "$vol" "$FROM_IMAGE" "upgrade is in progress" || return 1
  expect_boot_refusal "$vol" "$TO_IMAGE" "upgrade is in progress" || return 1

  docker run --rm -v "$vol:/var/lib/postgresql/data" --entrypoint /bin/sh "$JOB_IMAGE" \
    -c "echo '{not json' > $MARKER_PATH"
  expect_boot_refusal "$vol" "$FROM_IMAGE" "marker phase: unreadable" || return 1
  in_volume "$vol" "rm -f $MARKER_PATH"
}

# Crash between the two directory renames: marker=upgraded, old dir moved
# aside, no $PGDATA. Re-running the job completes the swap deterministically.
t_resume_after_crash_between_swaps() {
  local vol="upg-e2e-crashswap"
  seed_from_cluster "$vol" || return 1
  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "initial upgrade" || return 1
  # Reconstruct the crash window: pgdata back to "old moved aside, new not
  # yet promoted", marker back to phase=upgraded.
  docker run --rm -v "$vol:/var/lib/postgresql/data" --entrypoint /bin/sh "$JOB_IMAGE" -c "
    set -e
    cd /var/lib/postgresql/data
    mv pgdata pgdata.upgrade-${TO_VERSION}
    echo '{\"phase\": \"upgraded\", \"from\": \"$FROM_VERSION\", \"to\": \"$TO_VERSION\"}' > $MARKER_PATH
  "
  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "resume exit code" || { echo "$JOB_OUT" | tail -20; return 1; }
  assert_eq "$(marker_field "$vol" phase)" "completed" "marker completed after resume" || return 1
  run_pg resume-pg "$vol" "$TO_IMAGE" || return 1
  wait_for_pg resume-pg || { fail_dump resume resume-pg; return 1; }
  assert_eq "$(psql_in resume-pg 'SELECT count(*) FROM upgrade_canary')" "1000" "data intact after resume" || return 1
  stop_pg resume-pg
}

# pg_hba.conf: initdb writes only local/loopback lines; the `host all all all`
# rule that admits remote clients is appended by the official entrypoint at
# init time and must survive the upgrade (the job carries the old pg_hba
# across the swap) — a localhost-only check can't see this regression, so
# assert from a SECOND container over the docker network. Custom user rules
# must survive too. Then strip the host rules to simulate any other path that
# regenerates pg_hba, and assert the wrapper self-heals it from config state.
t_remote_auth_survives_upgrade() {
  local vol="upg-e2e-remotehba"
  seed_from_cluster "$vol" || return 1

  run_pg hba-before "$vol" "$FROM_IMAGE" --network "$E2E_NET" || return 1
  wait_for_pg hba-before || { fail_dump hba-before hba-before; return 1; }
  assert_eq "$(remote_psql hba-before 'SELECT 1')" "1" "remote client connects before upgrade" || return 1
  # A recognizable user-added rule, to prove the carry preserves custom lines
  # rather than resetting to a default file.
  docker exec hba-before bash -c \
    "echo 'host all all 192.0.2.0/24 trust # e2e-custom-hba-rule' >> $PGDATA_IN_VOLUME/pg_hba.conf" || return 1
  stop_pg hba-before

  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "upgrade exit code" || { echo "$JOB_OUT" | tail -20; return 1; }

  run_pg hba-after "$vol" "$TO_IMAGE" --network "$E2E_NET" || return 1
  wait_for_pg hba-after || { fail_dump hba-after hba-after; return 1; }
  assert_eq "$(remote_psql hba-after 'SELECT count(*) FROM upgrade_canary')" "1000" \
    "remote client connects and reads data after upgrade" || return 1
  assert_contains "$(docker exec hba-after cat "$PGDATA_IN_VOLUME/pg_hba.conf" 2>&1)" \
    "e2e-custom-hba-rule" "custom pg_hba rule carried across the upgrade" || return 1
  stop_pg hba-after

  # Wrapper self-heal layer: reset pg_hba to initdb's default shape — local
  # lines plus the loopback host rules and nothing else, which is what any
  # path that regenerates the file actually produces. The heal is keyed on
  # exactly that shape (see t_narrowed_hba_not_rewidened for the negative),
  # so remote auth must come back on the next boot.
  in_volume "$vol" "printf '%s\n' \
    'local all all trust' \
    'host all all 127.0.0.1/32 trust' \
    'host all all ::1/128 trust' \
    'local replication all trust' \
    'host replication all 127.0.0.1/32 trust' \
    'host replication all ::1/128 trust' \
    > $PGDATA_IN_VOLUME/pg_hba.conf" || return 1
  run_pg hba-healed "$vol" "$TO_IMAGE" --network "$E2E_NET" || return 1
  wait_for_pg hba-healed || { fail_dump hba-healed hba-healed; return 1; }
  assert_contains "$(docker logs hba-healed 2>&1)" "re-appending" "wrapper reported the pg_hba heal" || return 1
  assert_eq "$(remote_psql hba-healed 'SELECT 1')" "1" "remote client connects after the wrapper heal" || return 1
  stop_pg hba-healed
}

# A PITR-restored fork keeps WAL_RECOVER_FROM_* + POSTGRES_RECOVERY_TARGET_TIME
# set forever; only the sentinels inside $PGDATA (.pitr_configured /
# .pgbackrest_restored) record that recovery already promoted. If the swap
# loses them, the first post-upgrade boot re-stages archive recovery against
# the SOURCE bucket and the database hangs at "the database system is
# starting up" forever. The job must carry the sentinels across; the wrapper
# must also treat the completed marker itself as proof (defense in depth).
t_pitr_fork_survives_upgrade() {
  local vol="upg-e2e-pitrfork"
  local recover_env=(
    -e "WAL_RECOVER_FROM_BUCKET=e2e-nonexistent-bucket"
    -e "WAL_RECOVER_FROM_ENDPOINT=e2e.invalid"
    -e "WAL_RECOVER_FROM_REGION=auto"
    -e "WAL_RECOVER_FROM_KEY=junk"
    -e "WAL_RECOVER_FROM_SECRET=junk"
    -e "POSTGRES_RECOVERY_TARGET_TIME=2026-01-01 00:00:00+00"
  )
  seed_from_cluster "$vol" || return 1
  # The restored-fork post-promote shape: both sentinels present.
  in_volume "$vol" "touch $PGDATA_IN_VOLUME/.pitr_configured $PGDATA_IN_VOLUME/.pgbackrest_restored \
    && chown postgres:postgres $PGDATA_IN_VOLUME/.pitr_configured $PGDATA_IN_VOLUME/.pgbackrest_restored" || return 1

  # Baseline: the fork shape boots on the FROM major without re-staging.
  run_pg fork-before "$vol" "$FROM_IMAGE" "${recover_env[@]}" || return 1
  wait_for_pg fork-before || { fail_dump fork-before fork-before; return 1; }
  stop_pg fork-before

  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "upgrade exit code" || { echo "$JOB_OUT" | tail -20; return 1; }
  in_volume "$vol" "test -f $PGDATA_IN_VOLUME/.pitr_configured && test -f $PGDATA_IN_VOLUME/.pgbackrest_restored" \
    || { echo "  PITR sentinels did not survive the swap"; return 1; }

  # The regression: with the same fork env, the upgraded database must become
  # READY (no recovery staged against the unreachable source bucket).
  run_pg fork-after "$vol" "$TO_IMAGE" "${recover_env[@]}" || return 1
  wait_for_pg fork-after || { fail_dump fork-after fork-after; return 1; }
  local logs; logs="$(docker logs fork-after 2>&1)"
  assert_not_contains "$logs" "PITR replay staged" "no recovery re-staged after upgrade" || return 1
  in_volume "$vol" "test ! -f $PGDATA_IN_VOLUME/recovery.signal" \
    || { echo "  recovery.signal appeared on the upgraded fork"; return 1; }
  assert_eq "$(psql_in fork-after 'SELECT count(*) FROM upgrade_canary')" "1000" "data intact on the upgraded fork" || return 1
  stop_pg fork-after

  # Defense-in-depth layer: even with the sentinels gone (an older job, a
  # manual wipe), the completed marker alone must prevent re-staging.
  in_volume "$vol" "rm -f $PGDATA_IN_VOLUME/.pitr_configured $PGDATA_IN_VOLUME/.pgbackrest_restored" || return 1
  run_pg fork-marker "$vol" "$TO_IMAGE" "${recover_env[@]}" || return 1
  wait_for_pg fork-marker || { fail_dump fork-marker fork-marker; return 1; }
  assert_not_contains "$(docker logs fork-marker 2>&1)" "PITR replay staged" \
    "completed marker alone prevents re-staging" || return 1
  stop_pg fork-marker
}

# Upgrading the same volume twice (FROM -> TO, then TO -> TO+1) must land on
# TO+1 with the data intact. Regression: a completed marker from the FIRST
# pair used to read as "already done" for ANY pair — the second job reported
# success as a silent no-op, the workflow flipped the image tag, and the
# service boot-refused on a major mismatch after a "successful" upgrade.
t_second_upgrade_reaches_next_major() {
  if [ ! -f "$REPO_ROOT/Dockerfile.${CHAIN_VERSION}" ]; then
    note "skipped: no Dockerfile.${CHAIN_VERSION} to chain onto"
    return 0
  fi
  ensure_chain_images || return 1
  local vol="upg-e2e-chain"
  seed_from_cluster "$vol" || return 1

  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "first upgrade exit code" || { echo "$JOB_OUT" | tail -20; return 1; }
  assert_eq "$(volume_data_major "$vol")" "$TO_VERSION" "data major after first upgrade" || return 1

  JOB_OUT=$(docker run --rm --label postgres-upgrade-e2e=1 \
    -e "PGDATA=$PGDATA_IN_VOLUME" \
    -v "$vol:/var/lib/postgresql/data" \
    "$CHAIN_JOB_IMAGE" upgrade 2>&1)
  JOB_RC=$?
  assert_eq "$JOB_RC" 0 "second upgrade exit code" || { echo "$JOB_OUT" | tail -30; return 1; }
  assert_not_contains "$JOB_OUT" '"alreadyDone"' "second upgrade actually ran (no silent no-op)" || return 1
  assert_eq "$(marker_field "$vol" phase)" "completed" "marker phase after chain" || return 1
  assert_eq "$(marker_field "$vol" to)" "$CHAIN_VERSION" "marker records the second pair" || return 1
  assert_eq "$(volume_data_major "$vol")" "$CHAIN_VERSION" "data major after second upgrade" || return 1

  remove_container chain-pg
  docker run -d --name chain-pg --label postgres-upgrade-e2e=1 \
    -e "POSTGRES_PASSWORD=test" -e "PGDATA=$PGDATA_IN_VOLUME" \
    -v "$vol:/var/lib/postgresql/data" "$CHAIN_IMAGE" >/dev/null || return 1
  wait_for_pg chain-pg || { fail_dump chain chain-pg; return 1; }
  assert_eq "$(psql_in chain-pg 'SELECT count(*) FROM upgrade_canary')" "1000" "data intact after two upgrades" || return 1
  assert_contains "$(psql_in chain-pg 'SHOW server_version')" "$CHAIN_VERSION." "server is TO+1" || return 1
  stop_pg chain-pg
}

# An in-flight (phase=upgraded) marker belonging to a DIFFERENT version pair
# must not drive this job's directory swap — its upgrade dirs belong to the
# other job. Refuse loudly, volume untouched. The planted marker uses NUMERIC
# majors on purpose: more than one producer writes this file (postgres-ha's
# workflow tolerates numeric majors for the same reason), and jq's -r read
# must normalize them rather than misread the pair.
t_foreign_pair_upgraded_marker_refused() {
  local vol="upg-e2e-foreignpair"
  seed_from_cluster "$vol" || return 1
  in_volume "$vol" "echo '{\"phase\": \"upgraded\", \"from\": 13, \"to\": 14}' > $MARKER_PATH" || return 1
  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 2 "foreign-pair upgraded marker refused" || { echo "$JOB_OUT" | tail -10; return 1; }
  assert_contains "$JOB_OUT" "refuses to finish another pair's swap" "refusal names the mismatch" || return 1
  assert_contains "$JOB_OUT" "13 -> 14" "numeric marker majors normalized in the message" || return 1
  assert_eq "$(volume_data_major "$vol")" "$FROM_VERSION" "volume untouched" || return 1

  # check mode must also name the in-flight marker instead of preflighting
  # over another job's half-done state.
  run_job "$vol" check
  assert_eq "$JOB_RC" 2 "check refused on a foreign in-flight marker" || { echo "$JOB_OUT" | tail -10; return 1; }
  assert_contains "$JOB_OUT" "already in progress" "check names the in-flight marker" || return 1
  in_volume "$vol" "rm -f $MARKER_PATH"
}

# A marker phase this job does not recognize (the HA workflow's "reseed" on a
# replica volume, or a future writer's state) is someone else's in-flight
# state: both modes must refuse rather than overwrite it at the commit point.
t_unknown_marker_phase_refused() {
  local vol="upg-e2e-unknownphase"
  seed_from_cluster "$vol" || return 1
  in_volume "$vol" "echo '{\"phase\": \"reseed\", \"from\": \"$FROM_VERSION\", \"to\": \"$TO_VERSION\"}' > $MARKER_PATH" || return 1
  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 2 "unknown phase refused by upgrade" || { echo "$JOB_OUT" | tail -10; return 1; }
  assert_contains "$JOB_OUT" "not this job's to resolve" "refusal names the foreign phase" || return 1
  run_job "$vol" check
  assert_eq "$JOB_RC" 2 "unknown phase refused by check" || { echo "$JOB_OUT" | tail -10; return 1; }
  assert_eq "$(volume_data_major "$vol")" "$FROM_VERSION" "volume untouched" || return 1

  # An UNREADABLE marker is someone's in-flight state we cannot even name:
  # both modes must refuse rather than proceed over (and overwrite) it.
  in_volume "$vol" "echo '{not json' > $MARKER_PATH" || return 1
  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 2 "unreadable marker refused by upgrade" || { echo "$JOB_OUT" | tail -10; return 1; }
  assert_contains "$JOB_OUT" "cannot be read" "refusal names the unreadable marker" || return 1
  run_job "$vol" check
  assert_eq "$JOB_RC" 2 "unreadable marker refused by check" || { echo "$JOB_OUT" | tail -10; return 1; }
  assert_eq "$(volume_data_major "$vol")" "$FROM_VERSION" "volume still untouched" || return 1
  in_volume "$vol" "rm -f $MARKER_PATH"
}

# The in-image job-vs-runtime backstop: with the database container RUNNING
# on the volume (its wrapper holds the shared flock for the container's
# lifetime — through docker-entrypoint's exec of postgres, which is exactly
# what this proves), both job modes must refuse, and the database must be
# unharmed. Without this, a job racing a live runtime bricks the volume
# while reporting ok:true.
t_job_refused_while_runtime_live() {
  local vol="upg-e2e-joblock"
  fresh_volume "$vol" || return 1
  run_pg lockrt-pg "$vol" "$FROM_IMAGE" || return 1
  wait_for_pg lockrt-pg || { fail_dump lockrt lockrt-pg; return 1; }
  psql_must lockrt-pg "CREATE TABLE lock_canary (id int); INSERT INTO lock_canary VALUES (1)" || return 1

  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 2 "upgrade refused while runtime is live" || { echo "$JOB_OUT" | tail -10; return 1; }
  assert_contains "$JOB_OUT" "holds the upgrade lock" "refusal names the lock" || return 1
  run_job "$vol" check
  assert_eq "$JOB_RC" 2 "check refused while runtime is live" || { echo "$JOB_OUT" | tail -10; return 1; }

  # The database kept running through both refusals.
  assert_eq "$(psql_in lockrt-pg 'SELECT count(*) FROM lock_canary')" "1" "database unharmed" || return 1
  stop_pg lockrt-pg

  # And with the runtime stopped, the same job succeeds — the lock is released
  # with the container, not leaked.
  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "upgrade succeeds once the runtime is stopped" || { echo "$JOB_OUT" | tail -20; return 1; }
}

# The runtime-vs-job direction of the same lock: a database deployed while
# an upgrade job holds the exclusive flock must refuse to boot.
t_runtime_refused_while_job_locked() {
  local vol="upg-e2e-rtlock"
  seed_from_cluster "$vol" || return 1
  docker run -d --name rt-lockholder --label postgres-upgrade-e2e=1 \
    -v "$vol:/var/lib/postgresql/data" --entrypoint /bin/sh "$JOB_IMAGE" \
    -c "exec 9>/var/lib/postgresql/data/.railway-major-upgrade.lock; flock 9; sleep 60" >/dev/null
  sleep 2
  local rc=0
  expect_boot_refusal "$vol" "$FROM_IMAGE" "upgrade job is currently running" || rc=1
  docker rm -f rt-lockholder >/dev/null 2>&1
  return "$rc"
}

# recovery.signal / standby.signal volumes are refused by BOTH modes, and the
# signal file is not consumed: check's quiesce would otherwise eat a
# mid-restore volume's recovery intent (replaying to "whatever WAL is local"
# instead of the configured target), and a standby that PASSES check would
# still fail the real run.
t_recovery_shapes_refused() {
  local vol="upg-e2e-recshape"
  seed_from_cluster "$vol" || return 1
  local sig
  for sig in recovery.signal standby.signal; do
    in_volume "$vol" "touch $PGDATA_IN_VOLUME/$sig && chown postgres:postgres $PGDATA_IN_VOLUME/$sig" || return 1
    run_job "$vol" check
    assert_eq "$JOB_RC" 2 "check refuses a $sig volume" || { echo "$JOB_OUT" | tail -10; return 1; }
    assert_contains "$JOB_OUT" "$sig" "refusal names $sig" || return 1
    run_job "$vol" upgrade
    assert_eq "$JOB_RC" 2 "upgrade refuses a $sig volume" || { echo "$JOB_OUT" | tail -10; return 1; }
    in_volume "$vol" "test -f $PGDATA_IN_VOLUME/$sig" \
      || { echo "  $sig was consumed by the refused job"; return 1; }
    in_volume "$vol" "rm -f $PGDATA_IN_VOLUME/$sig" || return 1
  done

  # The volume is still upgradeable once the signals are gone.
  run_job "$vol" check
  assert_eq "$JOB_RC" 0 "check passes after the signals are removed" || { echo "$JOB_OUT" | tail -10; return 1; }
}

# The marker-lost window: pg_upgrade finished (old cluster's pg_control
# renamed to pg_control.old, the job's completion sentinel written) but the
# marker is gone. The disk shape alone must drive the roll-forward; without
# it the volume is bricked in both directions. Reconstructed from a
# completed upgrade: put the dirs back to "post-pg_upgrade, pre-swap",
# re-plant the sentinel (finish_swap removes it from the promoted dir; in
# the real window finish_swap never ran, so it is present), delete the
# marker. The sentinel is load-bearing: pg_control.old alone means only
# that linking STARTED — see t_crash_mid_link_rolls_back_and_reruns for
# the shape where it must NOT roll forward.
t_marker_lost_after_pg_upgrade_resumes() {
  local vol="upg-e2e-lostmarker"
  seed_from_cluster "$vol" || return 1
  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "initial upgrade" || { echo "$JOB_OUT" | tail -20; return 1; }
  # The premise: pg_upgrade --link really does rename pg_control away.
  in_volume "$vol" "test -f ${PGDATA_IN_VOLUME}.old-${FROM_VERSION}/global/pg_control.old" \
    || { echo "  premise broken: pg_upgrade left no pg_control.old"; return 1; }
  in_volume "$vol" "
    set -e
    cd /var/lib/postgresql/data
    mv pgdata pgdata.upgrade-${TO_VERSION}
    touch pgdata.upgrade-${TO_VERSION}/.railway_pg_upgrade_complete
    mv pgdata.old-${FROM_VERSION} pgdata
    rm -f $MARKER_PATH
  " || return 1

  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "marker-less resume exit code" || { echo "$JOB_OUT" | tail -20; return 1; }
  assert_contains "$JOB_OUT" "disk shape shows a finished pg_upgrade" "roll-forward inferred from disk" || return 1
  assert_eq "$(marker_field "$vol" phase)" "completed" "marker rebuilt as completed" || return 1
  run_pg lostmarker-pg "$vol" "$TO_IMAGE" || return 1
  wait_for_pg lostmarker-pg || { fail_dump lostmarker lostmarker-pg; return 1; }
  assert_eq "$(psql_in lostmarker-pg 'SELECT count(*) FROM upgrade_canary')" "1000" "data intact after marker-less resume" || return 1
  stop_pg lostmarker-pg
}

# The inverse of the marker-lost window: pg_upgrade renames the old
# cluster's pg_control BEFORE it links the first user relation file
# (verified empirically — its own output prescribes the rename-back as the
# recovery), so "pg_control.old present" is NOT proof pg_upgrade finished.
# A crash mid-link leaves that rename plus a PARTIALLY-linked target dir;
# without the completion sentinel the resume must roll BACK — reverse the
# rename and redo the upgrade from scratch — never promote the partial
# target (the old inference did exactly that: silent data loss).
t_crash_mid_link_rolls_back_and_reruns() {
  local vol="upg-e2e-midlink"
  seed_from_cluster "$vol" || return 1
  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "initial upgrade" || { echo "$JOB_OUT" | tail -20; return 1; }
  # Reconstruct the mid-link crash: the old cluster back in place still
  # DISABLED (global/pg_control.old — pg_upgrade renamed it in place and the
  # swap carried it into pgdata.old-<from>), a partial target dir
  # (PG_VERSION present, no completion sentinel), no marker. Removing the
  # promoted dir first only drops hardlink counts; the old files survive.
  in_volume "$vol" "
    set -e
    cd /var/lib/postgresql/data
    rm -rf pgdata
    mv pgdata.old-${FROM_VERSION} pgdata
    mkdir -p pgdata.upgrade-${TO_VERSION}
    echo ${TO_VERSION} > pgdata.upgrade-${TO_VERSION}/PG_VERSION
    chown -R postgres:postgres pgdata.upgrade-${TO_VERSION}
    rm -f $MARKER_PATH
  " || return 1
  in_volume "$vol" "test -f ${PGDATA_IN_VOLUME}/global/pg_control.old && test ! -f ${PGDATA_IN_VOLUME}/global/pg_control" \
    || { echo "  premise broken: reconstructed old cluster is not in the disabled shape"; return 1; }

  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "mid-link crash resume exit code" || { echo "$JOB_OUT" | tail -30; return 1; }
  assert_contains "$JOB_OUT" "rolling back to the old cluster" "roll-back path taken, not roll-forward" || return 1
  assert_contains "$JOB_OUT" "restored global/pg_control" "the disable was reversed" || return 1
  assert_eq "$(marker_field "$vol" phase)" "completed" "re-run completed" || return 1
  assert_eq "$(volume_data_major "$vol")" "$TO_VERSION" "data major is TO after the re-run" || return 1

  run_pg midlink-pg "$vol" "$TO_IMAGE" || return 1
  wait_for_pg midlink-pg || { fail_dump midlink midlink-pg; return 1; }
  assert_eq "$(psql_in midlink-pg 'SELECT count(*) FROM upgrade_canary')" "1000" "data intact after roll-back + re-run" || return 1
  stop_pg midlink-pg
}

# pgdata.old-<from> is the rollback body and pins every pre-upgrade inode
# (--link hardlinks); it must survive normal boots and be reclaimed in the
# background once the upgraded database has been up past the grace period,
# stamping oldDataDirRemovedAt in the marker.
t_old_datadir_reclaimed() {
  local vol="upg-e2e-reclaim"
  seed_from_cluster "$vol" || return 1
  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "upgrade exit code" || { echo "$JOB_OUT" | tail -20; return 1; }

  # A normal boot (default 24h grace) must NOT reclaim.
  run_pg reclaim-hold "$vol" "$TO_IMAGE" || return 1
  wait_for_pg reclaim-hold || { fail_dump reclaim-hold reclaim-hold; return 1; }
  sleep 5
  local held_rc=0
  docker exec reclaim-hold test -d "${PGDATA_IN_VOLUME}.old-${FROM_VERSION}" || held_rc=1
  stop_pg reclaim-hold
  [ "$held_rc" = "0" ] || { echo "  old data dir reclaimed before the grace period"; return 1; }

  # With the grace collapsed, the same boot reclaims and stamps the marker.
  run_pg reclaim-pg "$vol" "$TO_IMAGE" -e "UPGRADE_OLD_DIR_RETENTION_SECONDS=1" || return 1
  wait_for_pg reclaim-pg || { fail_dump reclaim reclaim-pg; return 1; }
  local deadline=$(($(date +%s) + 90))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -n "$(marker_field "$vol" oldDataDirRemovedAt)" ]; then
      break
    fi
    sleep 3
  done
  assert_contains "$(docker logs reclaim-pg 2>&1)" "pre-upgrade data dir reclaimed" "reclaim reported" || { fail_dump reclaim reclaim-pg; stop_pg reclaim-pg; return 1; }
  stop_pg reclaim-pg
  in_volume "$vol" "test ! -e ${PGDATA_IN_VOLUME}.old-${FROM_VERSION}" \
    || { echo "  old data dir still present after reclaim"; return 1; }
  [ -n "$(marker_field "$vol" oldDataDirRemovedAt)" ] \
    || { echo "  marker has no oldDataDirRemovedAt after reclaim"; return 1; }
}

# A trailing slash on PGDATA must not change any derived path: it used to
# put the new cluster INSIDE the data dir and wedge the volume at
# phase=upgraded permanently.
t_trailing_slash_pgdata() {
  local vol="upg-e2e-slash"
  seed_from_cluster "$vol" || return 1
  JOB_OUT=$(docker run --rm --label postgres-upgrade-e2e=1 \
    -e "PGDATA=${PGDATA_IN_VOLUME}/" \
    -v "$vol:/var/lib/postgresql/data" \
    "$JOB_IMAGE" upgrade 2>&1)
  JOB_RC=$?
  assert_eq "$JOB_RC" 0 "upgrade with trailing-slash PGDATA" || { echo "$JOB_OUT" | tail -30; return 1; }
  assert_eq "$(marker_field "$vol" phase)" "completed" "marker completed" || return 1
  assert_eq "$(volume_data_major "$vol")" "$TO_VERSION" "data major is TO" || return 1

  # The runtime normalizes too.
  run_pg slash-pg "$vol" "$TO_IMAGE" -e "PGDATA=${PGDATA_IN_VOLUME}/" || return 1
  wait_for_pg slash-pg || { fail_dump slash slash-pg; return 1; }
  assert_eq "$(psql_in slash-pg 'SELECT count(*) FROM upgrade_canary')" "1000" "data intact with trailing-slash PGDATA" || return 1
  stop_pg slash-pg
}

# A real Railway volume's ROOT is root:root drwxr-xr-x — only PGDATA itself
# is chowned to postgres (verified against a real deployment). A fresh docker
# volume does NOT reproduce this: on first mount, docker copies the image's
# own directory entry for the mount path onto the empty volume, and the
# official postgres image's own /var/lib/postgresql/data is postgres-owned
# and world-writable — so every other test in this file runs against a volume
# root the real platform never produces. `init_new_cluster` used to `mkdir`
# the sibling `.upgrade-<major>` directory AS postgres (`as_postgres mkdir`),
# which needs write access to the PARENT — the volume root. That parent is
# writable by postgres in every local test and by nobody but root in
# production, so the job passed here and failed exit 3 on every real upgrade.
# Force the real shape before running the job, so this stays caught.
t_upgrade_survives_root_owned_volume_root() {
  local vol="upg-e2e-rootvol"
  seed_from_cluster "$vol" || return 1
  in_volume "$vol" "chown root:root /var/lib/postgresql/data && chmod 0755 /var/lib/postgresql/data" \
    || { echo "  could not force the volume root to root:root"; return 1; }
  assert_eq "$(in_volume "$vol" 'stat -c "%U:%G %a" /var/lib/postgresql/data')" "root:root 755" \
    "volume root forced to the production shape" || return 1

  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "upgrade exit code against a root-owned volume root" \
    || { echo "$JOB_OUT" | tail -30; return 1; }
  assert_eq "$(marker_field "$vol" phase)" "completed" "marker phase" || return 1
  assert_eq "$(volume_data_major "$vol")" "$TO_VERSION" "on-disk major is now TO" || return 1

  run_pg rootvol-pg "$vol" "$TO_IMAGE" || return 1
  wait_for_pg rootvol-pg || { fail_dump rootvol rootvol-pg; return 1; }
  assert_eq "$(psql_in rootvol-pg 'SELECT count(*) FROM upgrade_canary')" "1000" "rows survived" || return 1
  stop_pg rootvol-pg
}

# The official entrypoint initdb's with --username="$POSTGRES_USER", so a
# custom-user cluster has NO 'postgres' role at all — the job must connect
# (and initdb the target) as the cluster's actual install user, and the
# wrapper's post-upgrade analyze must too. A hardcoded -U postgres made the
# whole feature DOA for this cohort, with a libpq error buried in pg_upgrade
# output as the only signal.
t_custom_superuser_upgrades() {
  local vol="upg-e2e-customuser"
  fresh_volume "$vol" || return 1
  remove_container custom-pg || return 1
  docker run -d --name custom-pg --label postgres-upgrade-e2e=1 \
    -e "POSTGRES_PASSWORD=test" -e "POSTGRES_USER=myuser" -e "PGDATA=$PGDATA_IN_VOLUME" \
    -v "$vol:/var/lib/postgresql/data" "$FROM_IMAGE" >/dev/null || return 1
  wait_for_pg custom-pg || { fail_dump customuser custom-pg; return 1; }
  docker exec custom-pg psql -U myuser -tAc \
    "CREATE TABLE cu_canary(id int); INSERT INTO cu_canary SELECT generate_series(1, 100)" >/dev/null \
    || { echo "  could not seed as the custom superuser"; fail_dump customuser custom-pg; return 1; }
  stop_pg custom-pg

  # Both modes must work with the service's own env (which is how production
  # dispatch delivers POSTGRES_USER to the job).
  JOB_OUT=$(docker run --rm --label postgres-upgrade-e2e=1 \
    -e "PGDATA=$PGDATA_IN_VOLUME" -e "POSTGRES_USER=myuser" \
    -v "$vol:/var/lib/postgresql/data" "$JOB_IMAGE" check 2>&1)
  JOB_RC=$?
  assert_eq "$JOB_RC" 0 "check passes on a custom-superuser cluster" || { echo "$JOB_OUT" | tail -20; return 1; }
  JOB_OUT=$(docker run --rm --label postgres-upgrade-e2e=1 \
    -e "PGDATA=$PGDATA_IN_VOLUME" -e "POSTGRES_USER=myuser" \
    -v "$vol:/var/lib/postgresql/data" "$JOB_IMAGE" upgrade 2>&1)
  JOB_RC=$?
  assert_eq "$JOB_RC" 0 "upgrade succeeds on a custom-superuser cluster" || { echo "$JOB_OUT" | tail -30; return 1; }
  assert_eq "$(volume_data_major "$vol")" "$TO_VERSION" "data major is TO" || return 1

  remove_container custom2-pg || return 1
  docker run -d --name custom2-pg --label postgres-upgrade-e2e=1 \
    -e "POSTGRES_PASSWORD=test" -e "POSTGRES_USER=myuser" -e "PGDATA=$PGDATA_IN_VOLUME" \
    -v "$vol:/var/lib/postgresql/data" "$TO_IMAGE" >/dev/null || return 1
  wait_for_pg custom2-pg || { fail_dump customuser2 custom2-pg; return 1; }
  assert_eq "$(docker exec custom2-pg psql -U myuser -tAc 'SELECT count(*) FROM cu_canary' 2>&1)" "100" \
    "data survived under the custom superuser" || return 1
  # The wrapper's staged analyze must also authenticate as the custom user
  # (a hardcoded -U postgres would fail here on every boot forever).
  local deadline=$(($(date +%s) + 120))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(marker_field "$vol" needsAnalyze)" = "false" ] && break
    sleep 5
  done
  assert_eq "$(marker_field "$vol" needsAnalyze)" "false" "staged analyze completed as the custom superuser" \
    || { fail_dump customuser2 custom2-pg; stop_pg custom2-pg; return 1; }
  stop_pg custom2-pg
}

# The pg_hba heal must NEVER re-widen an authored policy: a config narrowed
# by address keeps only its own rules — appending `host all all all` under it
# would re-admit exactly the clients the narrowing excluded (pg_hba is
# first-match-wins, so the catch-all wins for everything the narrow rules
# don't match).
t_narrowed_hba_not_rewidened() {
  local vol="upg-e2e-narrowhba"
  seed_from_cluster "$vol" || return 1
  in_volume "$vol" "printf '%s\n' \
    'local all all trust' \
    'host all all 127.0.0.1/32 trust' \
    'host all all ::1/128 trust' \
    'host all all 192.0.2.0/24 scram-sha-256' \
    > $PGDATA_IN_VOLUME/pg_hba.conf" || return 1
  run_pg narrow-pg "$vol" "$FROM_IMAGE" || return 1
  wait_for_pg narrow-pg || { fail_dump narrowhba narrow-pg; return 1; }
  assert_not_contains "$(docker logs narrow-pg 2>&1)" "re-appending" "heal must not fire on an authored policy" || return 1
  assert_not_contains "$(docker exec narrow-pg cat "$PGDATA_IN_VOLUME/pg_hba.conf" 2>&1)" "host all all all" \
    "no wide-open rule appended under the narrowed policy" || return 1
  stop_pg narrow-pg
}

# check initdb's its throwaway cluster into /tmp, so without an explicit
# probe it would never notice that the REAL upgrade's sibling directory can't
# be created on this volume — the exact green-preflight/red-upgrade class the
# root-owned-volume-root bug shipped through. A read-only volume is the
# cheapest reproducible "slot not creatable" shape.
t_check_probes_sibling_slot() {
  local vol="upg-e2e-roprobe"
  seed_from_cluster "$vol" || return 1
  JOB_OUT=$(docker run --rm --label postgres-upgrade-e2e=1 \
    -e "PGDATA=$PGDATA_IN_VOLUME" \
    -v "$vol:/var/lib/postgresql/data:ro" \
    "$JOB_IMAGE" check 2>&1)
  JOB_RC=$?
  assert_eq "$JOB_RC" 2 "check refuses when the sibling slot cannot be created" || { echo "$JOB_OUT" | tail -10; return 1; }
  assert_contains "$JOB_OUT" "cannot create the upgrade directory" "probe names the failure" || return 1

  # And on a writable volume the probe passes and leaves nothing behind.
  run_job "$vol" check
  assert_eq "$JOB_RC" 0 "check passes on the writable volume" || { echo "$JOB_OUT" | tail -20; return 1; }
  in_volume "$vol" "test ! -e ${PGDATA_IN_VOLUME}.upgrade-${TO_VERSION}.preflight" \
    || { echo "  probe directory left behind"; return 1; }
}

# "Already done" needs the marker AND the data directory to agree: a
# completed same-pair marker sitting over FROM-major data (a partial manual
# restore put the old cluster back without touching the volume-root marker)
# must re-run the upgrade, not no-op to success — the workflow would flip the
# image tag onto FROM data and the service would boot-refuse after a
# "successful" job.
t_same_pair_completed_marker_reruns() {
  local vol="upg-e2e-samepair"
  seed_from_cluster "$vol" || return 1
  in_volume "$vol" "echo '{\"phase\": \"completed\", \"from\": \"$FROM_VERSION\", \"to\": \"$TO_VERSION\"}' > $MARKER_PATH" || return 1
  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "same-pair marker over FROM data re-runs the upgrade" || { echo "$JOB_OUT" | tail -30; return 1; }
  assert_not_contains "$JOB_OUT" '"alreadyDone"' "did not no-op on the stale marker" || return 1
  assert_eq "$(volume_data_major "$vol")" "$TO_VERSION" "data actually upgraded" || return 1
}

# marker=upgraded (same pair) but the new data dir is gone: the swap must
# refuse BEFORE the first rename. Moving $PGDATA aside on the strength of the
# marker alone would convert a still-bootable degenerate state into "no data
# dir at all".
t_upgraded_marker_missing_new_dir_refused() {
  local vol="upg-e2e-lostnewdir"
  seed_from_cluster "$vol" || return 1
  in_volume "$vol" "echo '{\"phase\": \"upgraded\", \"from\": \"$FROM_VERSION\", \"to\": \"$TO_VERSION\"}' > $MARKER_PATH" || return 1
  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 3 "refused to swap without a valid new data dir" || { echo "$JOB_OUT" | tail -10; return 1; }
  assert_contains "$JOB_OUT" "cannot finish the swap" "refusal names the missing target" || return 1
  assert_eq "$(volume_data_major "$vol")" "$FROM_VERSION" "PGDATA left in place" || return 1
  in_volume "$vol" "test ! -e ${PGDATA_IN_VOLUME}.old-${FROM_VERSION}" \
    || { echo "  old-keep dir appeared — the swap began despite the refusal"; return 1; }
  in_volume "$vol" "rm -f $MARKER_PATH"
}

# The old cluster was initdb'd by the entrypoint with POSTGRES_INITDB_ARGS
# spliced into its initdb call, and pg_upgrade refuses any locale/encoding
# mismatch between the clusters — so the job must replay the same args into
# the target initdb, or a custom-locale service preflights and upgrades into
# a refusal forever. --locale=C is always available and differs from the
# image default (en_US.utf8), which makes it the regression discriminator.
t_custom_initdb_args_upgrade() {
  local vol="upg-e2e-initdbargs"
  fresh_volume "$vol" || return 1
  run_pg initargs-pg "$vol" "$FROM_IMAGE" -e "POSTGRES_INITDB_ARGS=--locale=C" || return 1
  wait_for_pg initargs-pg || { fail_dump initargs initargs-pg; return 1; }
  psql_must initargs-pg "CREATE TABLE ia_canary(id int); INSERT INTO ia_canary SELECT generate_series(1,100)" || return 1
  assert_eq "$(psql_in initargs-pg "SELECT datcollate FROM pg_database WHERE datname='template0'")" "C" "seed cluster really is locale=C" || return 1
  stop_pg initargs-pg

  JOB_OUT=$(docker run --rm --label postgres-upgrade-e2e=1 \
    -e "PGDATA=$PGDATA_IN_VOLUME" -e "POSTGRES_INITDB_ARGS=--locale=C" \
    -v "$vol:/var/lib/postgresql/data" "$JOB_IMAGE" upgrade 2>&1)
  JOB_RC=$?
  assert_eq "$JOB_RC" 0 "upgrade with custom initdb args" || { echo "$JOB_OUT" | tail -30; return 1; }
  assert_eq "$(volume_data_major "$vol")" "$TO_VERSION" "data major is TO" || return 1

  run_pg initargs2-pg "$vol" "$TO_IMAGE" -e "POSTGRES_INITDB_ARGS=--locale=C" || return 1
  wait_for_pg initargs2-pg || { fail_dump initargs2 initargs2-pg; return 1; }
  assert_eq "$(psql_in initargs2-pg 'SELECT count(*) FROM ia_canary')" "100" "data survived" || return 1
  assert_eq "$(psql_in initargs2-pg "SELECT datcollate FROM pg_database WHERE datname='template0'")" "C" "locale carried into the new cluster" || return 1
  stop_pg initargs2-pg
}

# postgres-ha's env contract INVERTS postgres-ssl's: POSTGRES_USER there is
# the APP user Patroni creates, and the install user is
# PATRONI_SUPERUSER_USERNAME (default postgres). The job inherits the
# service's variables, so on an HA volume it must not trust POSTGRES_USER —
# the discriminator is the volume itself (a Patroni data dir always carries
# patroni.dynamic.json). Simulated: a postgres-install-user cluster with the
# patroni file planted, dispatched with the app-user env a real HA service
# would deliver — without the discriminator the job initdb's the target as
# 'appuser' and pg_upgrade fails the install-user match.
t_patroni_volume_uses_patroni_superuser() {
  local vol="upg-e2e-patroniuser"
  seed_from_cluster "$vol" || return 1
  in_volume "$vol" "echo '{}' > $PGDATA_IN_VOLUME/patroni.dynamic.json \
    && chown postgres:postgres $PGDATA_IN_VOLUME/patroni.dynamic.json" || return 1

  JOB_OUT=$(docker run --rm --label postgres-upgrade-e2e=1 \
    -e "PGDATA=$PGDATA_IN_VOLUME" -e "POSTGRES_USER=appuser" \
    -v "$vol:/var/lib/postgresql/data" "$JOB_IMAGE" upgrade 2>&1)
  JOB_RC=$?
  assert_eq "$JOB_RC" 0 "upgrade succeeds on a patroni-shaped volume with app-user env" || { echo "$JOB_OUT" | tail -30; return 1; }
  assert_contains "$JOB_OUT" "patroni cluster detected" "the discriminator is logged" || return 1
  assert_eq "$(marker_field "$vol" phase)" "completed" "marker completed" || return 1
  assert_eq "$(volume_data_major "$vol")" "$TO_VERSION" "data major is TO" || return 1
}

# A pre-existing pgdata.old-<from> next to FROM-major data is a manual-
# intervention artifact (a partial restore COPIED the rollback body back and
# left the original). finish_swap's `mv` onto that existing directory would
# NEST pgdata inside it instead of renaming — both modes must refuse upfront
# with the volume untouched, and succeed once the leftover is cleared.
t_stale_old_keep_dir_refused() {
  local vol="upg-e2e-staleold"
  seed_from_cluster "$vol" || return 1
  in_volume "$vol" "mkdir -p ${PGDATA_IN_VOLUME}.old-${FROM_VERSION} \
    && touch ${PGDATA_IN_VOLUME}.old-${FROM_VERSION}/PG_VERSION" || return 1

  run_job "$vol" check
  assert_eq "$JOB_RC" 2 "check refuses on a stale rollback body" || { echo "$JOB_OUT" | tail -10; return 1; }
  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 2 "upgrade refuses on a stale rollback body" || { echo "$JOB_OUT" | tail -10; return 1; }
  assert_contains "$JOB_OUT" "already exists" "refusal names the leftover dir" || return 1
  assert_eq "$(volume_data_major "$vol")" "$FROM_VERSION" "PGDATA untouched" || return 1

  in_volume "$vol" "rm -rf ${PGDATA_IN_VOLUME}.old-${FROM_VERSION}" || return 1
  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "succeeds once the leftover is removed" || { echo "$JOB_OUT" | tail -20; return 1; }
}

# A service variable can set PG_MAJOR to anything; the mismatch guard must
# trust the image's installed server tree instead (adopted from postgres-ha's
# image_major()) — a stray PG_MAJOR must not refuse a perfectly matched boot.
t_pg_major_env_override_ignored() {
  local vol="upg-e2e-pgmajorenv"
  seed_from_cluster "$vol" || return 1
  run_pg envmajor-pg "$vol" "$FROM_IMAGE" -e "PG_MAJOR=$TO_VERSION" || return 1
  wait_for_pg envmajor-pg || { fail_dump envmajor envmajor-pg; return 1; }
  assert_contains "$(docker logs envmajor-pg 2>&1)" "trusting the filesystem" \
    "the env/filesystem disagreement is logged" || return 1
  assert_eq "$(psql_in envmajor-pg 'SELECT 1')" "1" "database booted despite the stray PG_MAJOR" || return 1
  stop_pg envmajor-pg
}

# ----- runner -----------------------------------------------------------------
ALL_TESTS=(
  t_vanilla_boot
  t_check_pass
  t_check_blocker
  t_check_blocker_pre16_types
  t_refuses_wrong_major
  t_recovers_unclean_shutdown
  t_refuses_concurrent_job
  t_upgrade_happy_path
  t_upgrade_idempotent
  t_status_mode
  t_manifest_mode
  t_ssl_survives_upgrade
  t_analyze_staged
  t_old_image_on_upgraded_data
  t_mismatch_boot_failstop
  t_boot_refused_mid_upgrade
  t_resume_after_crash_between_swaps
  t_remote_auth_survives_upgrade
  t_pitr_fork_survives_upgrade
  t_second_upgrade_reaches_next_major
  t_foreign_pair_upgraded_marker_refused
  t_job_refused_while_runtime_live
  t_runtime_refused_while_job_locked
  t_recovery_shapes_refused
  t_marker_lost_after_pg_upgrade_resumes
  t_crash_mid_link_rolls_back_and_reruns
  t_old_datadir_reclaimed
  t_trailing_slash_pgdata
  t_upgrade_survives_root_owned_volume_root
  t_custom_superuser_upgrades
  t_narrowed_hba_not_rewidened
  t_check_probes_sibling_slot
  t_same_pair_completed_marker_reruns
  t_upgraded_marker_missing_new_dir_refused
  t_custom_initdb_args_upgrade
  t_patroni_volume_uses_patroni_superuser
  t_stale_old_keep_dir_refused
  t_unknown_marker_phase_refused
  t_pg_major_env_override_ignored
)

TESTS=("${@:-}")
if [ -z "${TESTS[0]}" ]; then TESTS=("${ALL_TESTS[@]}"); fi

ensure_images
for t in "${TESTS[@]}"; do
  log "running $t"
  if "$t"; then ok "$t"; else ko "$t"; fi
done

echo
log "results: ${G}${PASS} passed${N}, ${R}${FAIL} failed${N}"
if [ "$FAIL" -gt 0 ]; then
  for t in "${FAILED_TESTS[@]}"; do echo "  ${R}✗${N} $t"; done
fi
exit "$FAIL"
