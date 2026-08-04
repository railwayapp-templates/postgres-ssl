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

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGDATA_IN_VOLUME="/var/lib/postgresql/data/pgdata"
MARKER_PATH="/var/lib/postgresql/data/.railway-major-upgrade.json"

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
}

fresh_volume() {
  local vol="$1"
  docker volume rm "$vol" >/dev/null 2>&1 || true
  docker volume create "$vol" >/dev/null
}

# Start a runtime postgres container on a volume. Extra docker args pass
# through after name+vol+image.
run_pg() {
  local name="$1" vol="$2" image="$3"; shift 3
  docker run -d --name "$name" --label postgres-upgrade-e2e=1 \
    -e "POSTGRES_PASSWORD=test" \
    -e "PGDATA=$PGDATA_IN_VOLUME" \
    "$@" \
    -v "$vol:/var/lib/postgresql/data" \
    "$image" >/dev/null
}

wait_for_pg() {
  local container="$1" deadline=$(($(date +%s) + 90))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker exec "$container" pg_isready -q -U postgres 2>/dev/null; then return 0; fi
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

# Clean stop: shut postgres down through pg_ctl so pg_control records
# "shut down". `docker stop` alone is NOT clean on this image — bash as PID 1
# never forwards SIGTERM, so postgres is SIGKILLed after the grace period and
# leaves an unclean cluster plus a stale postmaster.pid (see kill_pg, which
# exercises that path deliberately).
stop_pg() {
  local name="$1"
  docker exec "$name" gosu postgres pg_ctl -D "$PGDATA_IN_VOLUME" -w -t 60 -m fast stop >/dev/null 2>&1
  docker stop -t 30 "$name" >/dev/null 2>&1
  docker rm -f "$name" >/dev/null 2>&1
}

# Ungraceful stop: what the platform actually does when a deployment is
# stopped (and what any crash looks like) — unreplayed WAL, cluster state
# "in production", stale postmaster.pid.
kill_pg() {
  local name="$1"
  docker kill -s KILL "$name" >/dev/null 2>&1
  docker rm -f "$name" >/dev/null 2>&1
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
  docker rm -f "$name" >/dev/null 2>&1
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
  fresh_volume "$vol"
  run_pg seed-pg "$vol" "$FROM_IMAGE"
  wait_for_pg seed-pg || { fail_dump seed seed-pg; return 1; }
  psql_in seed-pg "CREATE TABLE upgrade_canary (id serial PRIMARY KEY, body text)" >/dev/null
  psql_in seed-pg "INSERT INTO upgrade_canary (body) SELECT 'row-' || g FROM generate_series(1, 1000) g" >/dev/null
  psql_in seed-pg "CREATE INDEX upgrade_canary_body_idx ON upgrade_canary (body)" >/dev/null
  psql_in seed-pg "CREATE EXTENSION IF NOT EXISTS vector" >/dev/null
  psql_in seed-pg "CREATE TABLE embeddings (id int, v vector(3)); INSERT INTO embeddings VALUES (1, '[1,2,3]')" >/dev/null
  if [ -n "$extra_sql" ]; then
    psql_in seed-pg "$extra_sql" >/dev/null
  fi
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
  docker ps -aq --filter label=postgres-upgrade-e2e=1 | xargs -r docker rm -f >/dev/null 2>&1
  docker volume ls -q | grep '^upg-e2e-' | xargs -r docker volume rm >/dev/null 2>&1
}
trap cleanup_all EXIT

# ----- tests -------------------------------------------------------------------

# Regression: the new wrapper guards must not disturb a vanilla fresh init +
# boot + restart on the FROM major.
t_vanilla_boot() {
  local vol="upg-e2e-vanilla"
  fresh_volume "$vol"
  run_pg vanilla-pg "$vol" "$FROM_IMAGE"
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
  assert_contains "$JOB_OUT" '"ok": true' "machine-readable result" || return 1
  assert_eq "$(volume_data_major "$vol")" "$FROM_VERSION" "data major untouched by check" || return 1
  run_pg checkpass-pg "$vol" "$FROM_IMAGE"
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
  fresh_volume "$vol"
  run_pg blocker-pg "$vol" "$FROM_IMAGE"
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
  run_pg blocker2-pg "$vol" "$FROM_IMAGE"
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
  fresh_volume "$vol"
  run_pg wrong-pg "$vol" "$TO_IMAGE"
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
  fresh_volume "$vol"
  run_pg unclean-pg "$vol" "$FROM_IMAGE"
  wait_for_pg unclean-pg || { fail_dump unclean unclean-pg; return 1; }
  psql_in unclean-pg "CREATE TABLE unclean_canary (id int)" >/dev/null
  psql_in unclean-pg "INSERT INTO unclean_canary SELECT generate_series(1, 500)" >/dev/null
  psql_in unclean-pg "CHECKPOINT" >/dev/null
  psql_in unclean-pg "INSERT INTO unclean_canary SELECT generate_series(501, 700)" >/dev/null
  kill_pg unclean-pg

  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "upgrade after unclean shutdown" || { echo "$JOB_OUT" | tail -30; return 1; }
  assert_contains "$JOB_OUT" "replaying WAL" "recovery path was taken" || return 1
  assert_eq "$(marker_field "$vol" phase)" "completed" "marker completed" || return 1

  run_pg unclean2-pg "$vol" "$TO_IMAGE"
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
  assert_contains "$out" "another upgrade job is already running" "lock message" || return 1
}

# The whole point: upgrade succeeds, marker completes, the TO image boots,
# and every seeded object (rows, index, pgvector data) survived.
t_upgrade_happy_path() {
  local vol="upg-e2e-happy"
  seed_from_cluster "$vol" || return 1
  run_job "$vol" upgrade
  assert_eq "$JOB_RC" 0 "upgrade exit code" || { echo "$JOB_OUT" | tail -30; return 1; }
  assert_eq "$(marker_field "$vol" phase)" "completed" "marker phase" || return 1
  assert_eq "$(volume_data_major "$vol")" "$TO_VERSION" "on-disk major is now TO" || return 1

  run_pg happy-pg "$vol" "$TO_IMAGE"
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
  assert_contains "$JOB_OUT" '"alreadyDone": true' "no-op signaled" || return 1
}

# status mode reports the terminal state for the workflow's resume decision.
t_status_mode() {
  local vol="upg-e2e-happy"
  run_job "$vol" status
  assert_eq "$JOB_RC" 0 "status exit code" || return 1
  assert_contains "$JOB_OUT" '"phase": "completed"' "status phase" || return 1
  assert_contains "$JOB_OUT" "\"dataMajor\": \"$TO_VERSION\"" "status data major" || return 1
}

# manifest mode lists the TO major's installable extensions (preflight feed).
t_manifest_mode() {
  local vol="upg-e2e-happy"
  run_job "$vol" manifest
  assert_eq "$JOB_RC" 0 "manifest exit code" || return 1
  assert_contains "$JOB_OUT" '"vector"' "pgvector present in manifest" || return 1
  assert_contains "$JOB_OUT" '"pg_stat_statements"' "contrib extension present" || return 1
}

# After the upgraded database boots, the staged statistics rebuild runs and
# flips needsAnalyze off.
t_analyze_staged() {
  local vol="upg-e2e-happy"
  run_pg analyze-pg "$vol" "$TO_IMAGE"
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

# A non-completed marker blocks EVERY runtime boot — both majors.
t_boot_refused_mid_upgrade() {
  local vol="upg-e2e-midmarker"
  seed_from_cluster "$vol" || return 1
  docker run --rm -v "$vol:/var/lib/postgresql/data" --entrypoint /bin/sh "$JOB_IMAGE" \
    -c "echo '{\"phase\": \"upgraded\", \"from\": \"$FROM_VERSION\", \"to\": \"$TO_VERSION\"}' > $MARKER_PATH"
  expect_boot_refusal "$vol" "$FROM_IMAGE" "upgrade is in progress" || return 1
  expect_boot_refusal "$vol" "$TO_IMAGE" "upgrade is in progress" || return 1
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
  run_pg resume-pg "$vol" "$TO_IMAGE"
  wait_for_pg resume-pg || { fail_dump resume resume-pg; return 1; }
  assert_eq "$(psql_in resume-pg 'SELECT count(*) FROM upgrade_canary')" "1000" "data intact after resume" || return 1
  stop_pg resume-pg
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
  t_analyze_staged
  t_old_image_on_upgraded_data
  t_mismatch_boot_failstop
  t_boot_refused_mid_upgrade
  t_resume_after_crash_between_swaps
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
