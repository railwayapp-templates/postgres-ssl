#!/bin/bash
# upgrade-job.sh — one-shot in-place major upgrade job (pg_upgrade --link).
#
# Runs as the entrypoint of the dual-binary upgrade image (Dockerfile.upgrade),
# against the SAME volume the database service owns, while that service is
# stopped. The orchestrating workflow guarantees exclusivity (volume lock +
# service maintenance lock); this script still refuses the obvious hazards.
#
# Modes (first argument, default "upgrade"):
#   check    — initdb a throwaway target cluster and run pg_upgrade --check.
#              Read-only with respect to the volume. Exit 0 = upgradeable,
#              exit 1 = blockers (printed), exit 2 = precondition failure.
#   upgrade  — the real thing: --check first, then pg_upgrade --link into a
#              new data dir on the volume, write the completion marker (the
#              commit point), then swap directories. Crash-safe: re-running
#              resumes from the marker. Exit 0 = upgraded (or already done).
#   status   — print the marker + on-disk major as JSON and exit 0. Used by
#              the workflow to decide roll-back vs roll-forward on resume.
#   manifest — print the extensions available on the TARGET major as JSON.
#              Feeds the dashboard preflight's extension check.
#
# Marker contract (volume root, .railway-major-upgrade.json):
#   absent               — nothing committed; any failure rolls back.
#   phase == "upgraded"  — pg_upgrade succeeded; directory swap may be
#                          incomplete. Roll FORWARD (re-run upgrade mode).
#   phase == "completed" — swap done; the runtime image of TO major boots.
# The runtime wrapper.sh refuses to boot while a non-completed marker exists,
# and refuses an image/data major mismatch, so no mismatched boot can ever
# touch the data directory.

set -uo pipefail

FROM_MAJOR="${PG_UPGRADE_FROM:?PG_UPGRADE_FROM not set}"
TO_MAJOR="${PG_UPGRADE_TO:?PG_UPGRADE_TO not set}"

EXPECTED_VOLUME_MOUNT_PATH="/var/lib/postgresql/data"
VOLUME_ROOT="$EXPECTED_VOLUME_MOUNT_PATH"
PGDATA="${PGDATA:-$VOLUME_ROOT/pgdata}"
MARKER_FILE="$VOLUME_ROOT/.railway-major-upgrade.json"

OLD_BINDIR="/usr/lib/postgresql/${FROM_MAJOR}/bin"
NEW_BINDIR="/usr/lib/postgresql/${TO_MAJOR}/bin"
NEW_DATA_DIR="${PGDATA}.upgrade-${TO_MAJOR}"
OLD_KEEP_DIR="${PGDATA}.old-${FROM_MAJOR}"

MODE="${1:-upgrade}"

log() { echo "upgrade-job: $*"; }
# Machine-readable result line the workflow scrapes from the job logs.
result() {
  echo "RAILWAY_UPGRADE_RESULT: $1"
}
die() {
  local code="$1"; shift
  log "ERROR: $*"
  result "{\"ok\": false, \"mode\": \"$MODE\", \"error\": \"$*\"}"
  exit "$code"
}

# Plain `.field` with an explicit null map, not `// empty`: jq's `//` treats a
# literal `false` as absent, so a boolean field would read back as missing.
read_marker_field() {
  [ -f "$MARKER_FILE" ] || { echo ""; return; }
  jq -r ".$1" "$MARKER_FILE" 2>/dev/null | sed 's/^null$//'
}

write_marker() {
  local json="$1"
  local tmp="${MARKER_FILE}.tmp"
  echo "$json" > "$tmp"
  # The marker is the commit point — it must be durable before we act on it.
  sync "$tmp"
  mv "$tmp" "$MARKER_FILE"
  sync "$MARKER_FILE" 2>/dev/null || sync
}

as_postgres() {
  if [ "$(id -u)" = "0" ]; then
    gosu postgres "$@"
  else
    "$@"
  fi
}

data_major() {
  [ -f "$PGDATA/PG_VERSION" ] && cat "$PGDATA/PG_VERSION" || echo ""
}

# ----- preconditions ---------------------------------------------------------

check_mount() {
  if [ -n "${RAILWAY_ENVIRONMENT:-}" ] && [ "${RAILWAY_VOLUME_MOUNT_PATH:-}" != "$EXPECTED_VOLUME_MOUNT_PATH" ]; then
    die 2 "Railway volume not mounted at $EXPECTED_VOLUME_MOUNT_PATH (got '${RAILWAY_VOLUME_MOUNT_PATH:-}')"
  fi
  if [[ ! "$PGDATA" =~ ^"$EXPECTED_VOLUME_MOUNT_PATH" ]]; then
    die 2 "PGDATA ($PGDATA) is not under the volume mount path"
  fi
  # The new cluster dir lives NEXT TO the data dir and must share its
  # filesystem for --link's hardlinks; a PGDATA that IS the volume root has
  # no sibling slot inside the volume. Legacy layouts upgrade via the
  # dump/restore fallback instead.
  if [ "$PGDATA" = "$VOLUME_ROOT" ] || [ "$PGDATA" = "$VOLUME_ROOT/" ]; then
    die 2 "PGDATA is the volume root — this data layout is not supported for in-place upgrade"
  fi
}

JOB_LOCK_FILE="$VOLUME_ROOT/.railway-major-upgrade.lock"

# Exclude a second upgrade job on the same volume. This is the hazard that can
# actually happen (an activity retry racing a still-running attempt); a
# postgres running in ANOTHER container is not detectable from here — separate
# PID and IPC namespaces make postmaster.pid's liveness and shmem checks
# meaningless across containers — and is excluded by the orchestrator instead
# (volume lock + service maintenance restriction + the deploy pipeline
# stopping the incumbent before this container starts).
take_job_lock() {
  command -v flock >/dev/null 2>&1 || return 0
  exec 9>"$JOB_LOCK_FILE" || return 0
  if ! flock -n 9; then
    die 2 "another upgrade job is already running on this volume"
  fi
}

# Clear a stale postmaster.pid. Same reasoning wrapper.sh documents for the
# runtime image: this script IS the container entrypoint, so no postgres of
# ours is running yet, and any pid file on disk belongs to a container that
# was killed rather than shut down (SIGKILL after the stop grace period —
# bash as PID 1 never forwards SIGTERM to postgres).
clear_stale_pidfile() {
  if [ -f "$PGDATA/postmaster.pid" ]; then
    log "removing stale postmaster.pid (no postgres running in this container)"
    rm -f "$PGDATA/postmaster.pid" 2>/dev/null || true
  fi
}

cluster_state() {
  "$OLD_BINDIR/pg_controldata" "$PGDATA" 2>/dev/null \
    | awk -F: '/Database cluster state/ {sub(/^ +/,"",$2); print $2}'
}

# pg_upgrade refuses a cluster that was not shut down cleanly, and it is right
# to: unreplayed WAL would be silently dropped by --link. A container killed
# mid-flight leaves exactly that state, so recover it here — start the OLD
# server so it replays its WAL, then shut it down cleanly. Isolated to a unix
# socket in /tmp with no TCP listener, so nothing can connect meanwhile.
ensure_clean_shutdown() {
  local state
  state="$(cluster_state)"
  case "$state" in
    "shut down"|"shut down in recovery")
      log "cluster state: $state"
      return 0
      ;;
    "")
      die 2 "could not read cluster state from $PGDATA (pg_controldata failed)"
      ;;
  esac

  log "cluster state is '$state' — replaying WAL and shutting down cleanly before upgrade"
  as_postgres "$OLD_BINDIR/pg_ctl" -D "$PGDATA" -w -t 600 \
    -o "-c listen_addresses='' -k /tmp" start >/dev/null 2>&1 \
    || die 3 "the old server could not start to complete crash recovery"
  as_postgres "$OLD_BINDIR/pg_ctl" -D "$PGDATA" -w -t 600 -m fast stop >/dev/null 2>&1 \
    || die 3 "the old server did not shut down cleanly after recovery"

  state="$(cluster_state)"
  case "$state" in
    "shut down"|"shut down in recovery") log "cluster is now cleanly shut down" ;;
    *) die 3 "cluster still not cleanly shut down (state: $state)" ;;
  esac
}

check_from_major() {
  local major
  major="$(data_major)"
  [ -n "$major" ] || die 2 "no PG_VERSION found at $PGDATA — nothing to upgrade"
  if [ "$major" != "$FROM_MAJOR" ]; then
    die 2 "data directory is major $major, this job upgrades $FROM_MAJOR -> $TO_MAJOR"
  fi
}

# ----- initdb of the target cluster ------------------------------------------

# Match the old cluster's page-checksum setting; pg_upgrade requires parity.
checksum_flag() {
  local version
  version="$("$OLD_BINDIR/pg_controldata" "$PGDATA" 2>/dev/null | awk -F: '/Data page checksum version/ {gsub(/ /,"",$2); print $2}')"
  if [ -n "$version" ] && [ "$version" != "0" ]; then
    echo "--data-checksums"
  fi
}

init_new_cluster() {
  local target_dir="$1"
  rm -rf "$target_dir"
  as_postgres mkdir -p "$target_dir"
  # Locale/encoding inherit the image defaults, which match how the runtime
  # image initdb'd the old cluster; pg_upgrade --check verifies the pairing
  # and aborts on any mismatch before anything is touched.
  # shellcheck disable=SC2046
  as_postgres "$NEW_BINDIR/initdb" $(checksum_flag) --username=postgres -D "$target_dir" >/dev/null \
    || die 3 "initdb of the target cluster failed"
}

run_pg_upgrade() {
  local extra="$1" new_dir="$2" out rc
  cd /tmp || die 3 "cannot cd to /tmp"
  out=$(as_postgres "$NEW_BINDIR/pg_upgrade" \
    --old-bindir "$OLD_BINDIR" \
    --new-bindir "$NEW_BINDIR" \
    --old-datadir "$PGDATA" \
    --new-datadir "$new_dir" \
    --username=postgres \
    --jobs "$(nproc)" \
    $extra 2>&1)
  rc=$?
  echo "$out"
  return $rc
}

# pg_upgrade --check prints its findings to stdout and detail files into cwd.
print_check_details() {
  for f in /tmp/pg_upgrade_output.d/*/*.txt /tmp/*.txt; do
    [ -f "$f" ] || continue
    echo "----- $(basename "$f") -----"
    cat "$f"
  done
}

# ----- modes ------------------------------------------------------------------

mode_status() {
  local phase from to major
  phase="$(read_marker_field phase)"
  from="$(read_marker_field from)"
  to="$(read_marker_field to)"
  major="$(data_major)"
  result "{\"ok\": true, \"mode\": \"status\", \"phase\": \"${phase:-none}\", \"from\": \"${from:-}\", \"to\": \"${to:-}\", \"dataMajor\": \"${major:-}\"}"
  exit 0
}

mode_manifest() {
  local list
  list=$(ls /usr/share/postgresql/"$TO_MAJOR"/extension/*.control 2>/dev/null \
    | sed 's|.*/||; s|\.control$||' | sort -u | jq -R . | jq -sc .)
  result "{\"ok\": true, \"mode\": \"manifest\", \"targetMajor\": \"$TO_MAJOR\", \"extensions\": ${list:-[]}}"
  exit 0
}

mode_check() {
  check_mount
  take_job_lock
  clear_stale_pidfile
  check_from_major
  ensure_clean_shutdown

  local tmp_new="/tmp/pg-upgrade-check-target"
  init_new_cluster "$tmp_new"

  local out
  if out=$(run_pg_upgrade "--check" "$tmp_new"); then
    log "$out"
    rm -rf "$tmp_new"
    result "{\"ok\": true, \"mode\": \"check\", \"from\": \"$FROM_MAJOR\", \"to\": \"$TO_MAJOR\"}"
    exit 0
  else
    log "$out"
    print_check_details
    rm -rf "$tmp_new"
    result "{\"ok\": false, \"mode\": \"check\", \"from\": \"$FROM_MAJOR\", \"to\": \"$TO_MAJOR\", \"error\": \"pg_upgrade --check found blockers\"}"
    exit 1
  fi
}

finish_swap() {
  # $PGDATA holds the OLD cluster and the NEW one is complete: move old aside,
  # promote new. Two renames; a crash between them leaves no $PGDATA, which
  # the marker (phase=upgraded) makes recoverable — and which wrapper.sh
  # refuses to boot into, so nothing can initdb over the gap.
  if [ -d "$PGDATA" ] && [ "$(data_major)" = "$FROM_MAJOR" ]; then
    mv "$PGDATA" "$OLD_KEEP_DIR" || die 3 "failed to move old data dir aside"
  fi
  if [ ! -d "$PGDATA" ]; then
    [ -d "$NEW_DATA_DIR" ] || die 3 "no new data dir to promote — volume needs the pre-upgrade backup"
    mv "$NEW_DATA_DIR" "$PGDATA" || die 3 "failed to promote new data dir"
  fi

  write_marker "$(jq -nc \
    --arg from "$FROM_MAJOR" --arg to "$TO_MAJOR" --arg old "$(basename "$OLD_KEEP_DIR")" \
    '{phase: "completed", from: $from, to: $to, oldDataDir: $old, needsAnalyze: true, completedAt: (now | todate)}')"
  log "upgrade $FROM_MAJOR -> $TO_MAJOR complete"
  result "{\"ok\": true, \"mode\": \"upgrade\", \"phase\": \"completed\", \"from\": \"$FROM_MAJOR\", \"to\": \"$TO_MAJOR\"}"
  exit 0
}

mode_upgrade() {
  check_mount
  take_job_lock

  # Resume handling: the marker decides, never guesswork.
  case "$(read_marker_field phase)" in
    completed)
      log "marker says completed — nothing to do"
      result "{\"ok\": true, \"mode\": \"upgrade\", \"phase\": \"completed\", \"alreadyDone\": true}"
      exit 0
      ;;
    upgraded)
      log "marker says upgraded — resuming directory swap"
      finish_swap
      ;;
  esac

  check_from_major
  clear_stale_pidfile
  ensure_clean_shutdown
  init_new_cluster "$NEW_DATA_DIR"

  local out
  if ! out=$(run_pg_upgrade "--check" "$NEW_DATA_DIR"); then
    log "$out"
    print_check_details
    rm -rf "$NEW_DATA_DIR"
    result "{\"ok\": false, \"mode\": \"upgrade\", \"from\": \"$FROM_MAJOR\", \"to\": \"$TO_MAJOR\", \"error\": \"pg_upgrade --check found blockers\"}"
    exit 1
  fi
  log "$out"

  if ! out=$(run_pg_upgrade "--link" "$NEW_DATA_DIR"); then
    log "$out"
    # No marker was written: the old cluster may have been modified by
    # pg_upgrade's failed run and MUST NOT be restarted in place. The
    # workflow rolls back to the pre-upgrade backup.
    rm -rf "$NEW_DATA_DIR"
    result "{\"ok\": false, \"mode\": \"upgrade\", \"from\": \"$FROM_MAJOR\", \"to\": \"$TO_MAJOR\", \"error\": \"pg_upgrade failed after check passed\"}"
    exit 3
  fi
  log "$out"

  # THE commit point: from here recovery always rolls forward.
  write_marker "$(jq -nc \
    --arg from "$FROM_MAJOR" --arg to "$TO_MAJOR" \
    '{phase: "upgraded", from: $from, to: $to, upgradedAt: (now | todate)}')"

  finish_swap
}

case "$MODE" in
  check) mode_check ;;
  upgrade) mode_upgrade ;;
  status) mode_status ;;
  manifest) mode_manifest ;;
  *) die 2 "unknown mode '$MODE' (expected check|upgrade|status|manifest)" ;;
esac
