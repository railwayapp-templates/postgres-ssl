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
#              Exit 0 = upgradeable, exit 1 = blockers (printed), exit 2 =
#              precondition failure, exit 3 = environment failure (the
#              quiesce below could not start or cleanly stop the old server
#              — its log is printed). NOT strictly read-only: a cluster that
#              was not shut down cleanly (the platform stops containers with
#              SIGKILL, so that is the common case) is first quiesced —
#              start the old server, replay its WAL, shut down cleanly —
#              which is exactly what the next normal boot would have done.
#              Only a cleanly-shut-down volume is checked without writes.
#              Volumes with recovery.signal / standby.signal are refused
#              outright (exit 2) in both modes: quiescing would consume the
#              recovery intent, and those shapes can't be upgraded in place.
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
#   absent               — nothing committed; any failure rolls back. One
#                          exception: when the disk shape itself proves
#                          pg_upgrade finished (old cluster's pg_control
#                          renamed to pg_control.old AND the new dir's
#                          PG_VERSION is the target major), upgrade mode
#                          rolls FORWARD — the old cluster can no longer be
#                          started, so a lost marker must not brick the
#                          volume.
#   phase == "upgraded"  — pg_upgrade succeeded; directory swap may be
#                          incomplete. Roll FORWARD (re-run upgrade mode).
#   phase == "completed" — swap done; the runtime image of TO major boots.
# Both phases are scoped to the marker's own (from, to) pair: a completed
# marker of a PREVIOUS pair is history, not state — the job proceeds when
# the data major matches its FROM (and overwrites the marker at its own
# commit point); an in-flight marker of a foreign pair is refused outright.
# The runtime wrapper.sh refuses to boot while a non-completed marker exists,
# and refuses an image/data major mismatch, so no mismatched boot can ever
# touch the data directory.

set -uo pipefail

FROM_MAJOR="${PG_UPGRADE_FROM:?PG_UPGRADE_FROM not set}"
TO_MAJOR="${PG_UPGRADE_TO:?PG_UPGRADE_TO not set}"

# The cluster's superuser. The official entrypoint runs
# `initdb --username="$POSTGRES_USER"`, so a service deployed with a custom
# POSTGRES_USER has no 'postgres' role at all — pg_upgrade must connect as
# the cluster's actual install user, and the target cluster must be initdb'd
# with the SAME name (pg_upgrade requires the install users to match). The
# job inherits the service's variables in production, so this resolves to
# the right name there; ad-hoc runs against a custom-user volume need -e.
PG_SUPERUSER="${POSTGRES_USER:-postgres}"

EXPECTED_VOLUME_MOUNT_PATH="/var/lib/postgresql/data"
VOLUME_ROOT="$EXPECTED_VOLUME_MOUNT_PATH"
# The dispatcher must pass the SERVICE's own PGDATA to this container. The
# `:-` default below never applies in practice: the official postgres base
# image this job is built FROM exports PGDATA=/var/lib/postgresql/data — the
# volume ROOT — so a dispatch that doesn't set PGDATA is refused by
# check_mount ("PGDATA is the volume root") rather than defaulting to the
# pgdata subdir. In production the job runs as a deployment of the database
# service and inherits its variables, which include the real PGDATA; any
# ad-hoc `docker run` (harnesses, manual recovery) needs `-e PGDATA=…` —
# postgres-ha's t_ha_major_upgrade_full_choreography hit exactly this.
PGDATA="${PGDATA:-$VOLUME_ROOT/pgdata}"
# Strip trailing slashes. Every sibling path below is built by appending a
# suffix to $PGDATA, so "…/pgdata/" would put the new cluster INSIDE the data
# dir ("…/pgdata/.upgrade-17") — the swap's first rename then orphans it and
# the volume wedges at phase=upgraded forever.
while [ "${PGDATA%/}" != "$PGDATA" ] && [ -n "${PGDATA%/}" ]; do PGDATA="${PGDATA%/}"; done
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
# Every result payload is built with jq --arg, never by string interpolation:
# several interpolated values trace back to bytes a DB superuser can write
# (PG_VERSION contents, marker fields), and hand-built JSON would let a
# crafted value close the string and plant duplicate keys — JSON.parse takes
# the LAST duplicate, so `", "ok": true` inside an error message would flip a
# failed result to ok:true for the workflow.
die() {
  local code="$1"; shift
  log "ERROR: $*"
  result "$(jq -nc --arg mode "$MODE" --arg error "$*" '{ok: false, mode: $mode, error: $error}')"
  exit "$code"
}

# Plain `.field` with an explicit null map, not `// empty`: jq's `//` treats a
# literal `false` as absent, so a boolean field would read back as missing.
read_marker_field() {
  [ -f "$MARKER_FILE" ] || { echo ""; return; }
  jq -r ".$1" "$MARKER_FILE" 2>/dev/null | sed 's/^null$//'
}

# A marker file that exists but cannot be parsed still means an upgrade
# touched this volume (same contract as postgres-ha's guards and wrapper.sh's
# boot gate): treating it as "nothing in flight" would let this job proceed
# over — and overwrite — state whose meaning it cannot know. Refuse and let
# an operator look. Both stateful modes call this before reading phases;
# write_marker's atomic tmp+rename means only external damage produces this.
refuse_unreadable_marker() {
  [ -f "$MARKER_FILE" ] || return 0
  if [ -z "$(read_marker_field phase)" ]; then
    die 2 "the upgrade marker at $MARKER_FILE exists but cannot be read (or has no phase) — refusing to guess; inspect or remove it, then re-run"
  fi
}

# The marker is the commit point — it must be durable before we act on it,
# so every step is checked and fatal. die(3) here fires BEFORE the caller
# mutates any directory: after pg_upgrade the old cluster's pg_control has
# been renamed away, so proceeding on a marker that may not exist would
# leave a volume neither direction can interpret. The rename itself is only
# durable once the PARENT DIRECTORY is fsynced — syncing the file alone
# leaves the new directory entry volatile on ext4/xfs.
write_marker() {
  local json="$1"
  local tmp="${MARKER_FILE}.tmp"
  echo "$json" > "$tmp" || die 3 "failed to write the upgrade marker temp file"
  sync "$tmp" || die 3 "failed to fsync the upgrade marker temp file"
  mv "$tmp" "$MARKER_FILE" || die 3 "failed to move the upgrade marker into place"
  sync "$MARKER_FILE" || die 3 "failed to fsync the upgrade marker"
  sync "$VOLUME_ROOT" 2>/dev/null || sync || die 3 "failed to fsync the volume root after the marker rename"
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

# Exclusive flock on the volume-root lock file, held for this job's lifetime.
# The runtime image (wrapper.sh) holds the SAME file with a SHARED flock for
# its container's whole life, so this excludes BOTH hazards that share the
# volume: a second upgrade job (an activity retry racing a still-running
# attempt) and a live database container the orchestrator failed to stop —
# postmaster.pid can't detect the latter (separate PID/IPC namespaces make
# its liveness and shmem checks meaningless across containers), but the
# flock, living in the shared filesystem, can. The orchestrator's own
# exclusion (volume lock + service maintenance restriction + stopping the
# incumbent before this container starts) remains the first line of defense;
# this is the in-image backstop that turns a workflow bug into a refusal
# instead of a corrupted volume.
take_job_lock() {
  command -v flock >/dev/null 2>&1 \
    || { log "flock not available; continuing without the upgrade lock"; return 0; }
  # Brace group scopes the stderr silence to the open attempt (a bare
  # `exec 9>>… 2>/dev/null` would blackhole this shell's stderr for good —
  # the exact bug wrapper.sh's lock open once had). Proceeding without the
  # lock is deliberate but must never be silent: the orchestrator's stop +
  # single-mount remain the real exclusion, and the log line is the only
  # record that the in-image backstop was absent for this run.
  if ! { exec 9>>"$JOB_LOCK_FILE"; } 2>/dev/null; then
    log "could not open $JOB_LOCK_FILE; continuing without the upgrade lock"
    return 0
  fi
  if ! flock -n 9; then
    die 2 "the volume is in use — another upgrade job, or a still-running database container, holds the upgrade lock"
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

# A recovery.signal or standby.signal volume can't be upgraded in place:
# it's a standby or a mid-restore cluster whose recovery intent lives in
# those files, and ensure_clean_shutdown's quiesce would CONSUME them —
# postgres eats recovery.signal on promote — silently turning a
# point-in-time restore into "whatever WAL happened to be local". Refuse
# loudly in both modes, before anything touches the cluster.
refuse_recovery_shapes() {
  local sig
  for sig in recovery.signal standby.signal; do
    if [ -f "$PGDATA/$sig" ]; then
      die 2 "$PGDATA/$sig is present — this cluster is mid-recovery or a standby, which cannot be upgraded in place. Let recovery finish (or promote the standby), then re-run."
    fi
  done
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
  # The server's own output goes to a log file that is PRINTED on failure:
  # a WAL-replay failure is exactly the moment the FATAL lines matter, and
  # discarding them leaves the job log with nothing but a generic message.
  local quiesce_log="/tmp/pg-quiesce.log"
  rm -f "$quiesce_log"
  as_postgres "$OLD_BINDIR/pg_ctl" -D "$PGDATA" -w -t 600 -l "$quiesce_log" \
    -o "-c listen_addresses='' -k /tmp" start >/dev/null 2>&1 \
    || { print_quiesce_log "$quiesce_log"; die 3 "the old server could not start to complete crash recovery (server log above)"; }
  as_postgres "$OLD_BINDIR/pg_ctl" -D "$PGDATA" -w -t 600 -m fast stop >/dev/null 2>&1 \
    || { print_quiesce_log "$quiesce_log"; die 3 "the old server did not shut down cleanly after recovery (server log above)"; }

  state="$(cluster_state)"
  case "$state" in
    "shut down"|"shut down in recovery") log "cluster is now cleanly shut down" ;;
    *) print_quiesce_log "$quiesce_log"; die 3 "cluster still not cleanly shut down (state: $state; server log above)" ;;
  esac
}

print_quiesce_log() {
  [ -f "$1" ] || return 0
  echo "----- old server log ($1) -----"
  tail -100 "$1"
  echo "----- end of old server log -----"
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
# Both directions must be EXPLICIT: initdb's default flipped to checksums-ON
# in PostgreSQL 18, so a checksums-off source (the fleet default for clusters
# initdb'd before 18) meeting an 18 target's default fails --check with "old
# cluster does not use data checksums but the new one does". Emit
# --no-data-checksums when the target's initdb knows the flag (18+; older
# initdb rejects it, and its default is off anyway).
checksum_flag() {
  local version
  version="$("$OLD_BINDIR/pg_controldata" "$PGDATA" 2>/dev/null | awk -F: '/Data page checksum version/ {gsub(/ /,"",$2); print $2}')"
  if [ -n "$version" ] && [ "$version" != "0" ]; then
    echo "--data-checksums"
  elif [ "$version" = "0" ] && "$NEW_BINDIR/initdb" --help 2>/dev/null | grep -q -- "--no-data-checksums"; then
    echo "--no-data-checksums"
  fi
}

# Effective CPU allocation for --jobs: cgroup v2 cpu.max, then cgroup v1
# cfs quota, then nproc. Same derivation as wrapper.sh's detect_cpus — a
# Railway container's nproc reports the HOST's cores, so sizing off it
# oversubscribes a small allocation badly (pg_upgrade forks per-database
# workers that each fork dump/restore pipelines).
detect_cpus() {
  local quota period

  if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r quota period < /sys/fs/cgroup/cpu.max
    if [ "$quota" != "max" ] && [ -n "$quota" ] && [ -n "$period" ] && [ "$period" -gt 0 ]; then
      echo $(( (quota + period - 1) / period ))
      return
    fi
  fi

  if [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
    quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
    period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
    if [ "$quota" -gt 0 ] && [ "$period" -gt 0 ]; then
      echo $(( (quota + period - 1) / period ))
      return
    fi
  fi

  nproc 2>/dev/null || echo 1
}

init_new_cluster() {
  local target_dir="$1"
  rm -rf "$target_dir"
  # target_dir is a SIBLING of PGDATA under the volume root, and on a real
  # Railway volume only PGDATA itself is postgres-owned (the entrypoint chowns
  # exactly that path) — the volume root is root:root. `as_postgres mkdir`
  # would run the mkdir AS postgres, which can't create an entry in a
  # root-owned parent. Create it as whatever user we already are (root in
  # every real deployment), then hand ownership to postgres so everything
  # written INTO it from here on can run unprivileged.
  mkdir -p "$target_dir" || die 3 "failed to create the target cluster directory"
  if [ "$(id -u)" = "0" ]; then
    chown postgres:postgres "$target_dir" \
      || die 3 "failed to chown the target cluster directory to postgres"
  fi
  # Locale/encoding inherit the image defaults, which match how the runtime
  # image initdb'd the old cluster; pg_upgrade --check verifies the pairing
  # and aborts on any mismatch before anything is touched. The superuser must
  # be the OLD cluster's install user (see PG_SUPERUSER) — pg_upgrade
  # requires both clusters' install users to match, and a custom
  # POSTGRES_USER cluster has no 'postgres' role at all.
  # shellcheck disable=SC2046
  as_postgres "$NEW_BINDIR/initdb" $(checksum_flag) --username="$PG_SUPERUSER" -D "$target_dir" >/dev/null \
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
    --username="$PG_SUPERUSER" \
    --jobs "$(detect_cpus)" \
    $extra 2>&1)
  rc=$?
  echo "$out"
  return $rc
}

# check's throwaway target cluster lives in /tmp, so a plain --check never
# exercises the real sibling slot next to $PGDATA — which is exactly where
# upgrade mode puts the target cluster, and where a real Railway volume's
# root:root ownership once failed every upgrade AFTER a green preflight (see
# init_new_cluster's history). Prove the slot is creatable the same way the
# real run will create it, then remove the probe. Uses a distinct suffix so
# it can never collide with (or destroy) a real in-flight upgrade directory.
probe_sibling_slot() {
  local probe="${NEW_DATA_DIR}.preflight"
  rm -rf "$probe" 2>/dev/null
  if ! mkdir -p "$probe" 2>/dev/null; then
    die 2 "cannot create the upgrade directory next to $PGDATA (volume root not writable?) — the real upgrade would fail after this check"
  fi
  if [ "$(id -u)" = "0" ] && ! chown postgres:postgres "$probe" 2>/dev/null; then
    rm -rf "$probe"
    die 2 "cannot hand the upgrade directory to postgres — the real upgrade would fail after this check"
  fi
  rm -rf "$probe"
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
  result "$(jq -nc --arg phase "${phase:-none}" --arg from "${from:-}" --arg to "${to:-}" --arg major "${major:-}" \
    '{ok: true, mode: "status", phase: $phase, from: $from, to: $to, dataMajor: $major}')"
  exit 0
}

mode_manifest() {
  local list
  list=$(ls /usr/share/postgresql/"$TO_MAJOR"/extension/*.control 2>/dev/null \
    | sed 's|.*/||; s|\.control$||' | sort -u | jq -R . | jq -sc .)
  result "$(jq -nc --arg to "$TO_MAJOR" --argjson ext "${list:-[]}" \
    '{ok: true, mode: "manifest", targetMajor: $to, extensions: $ext}')"
  exit 0
}

mode_check() {
  check_mount
  take_job_lock

  # A marker mid-upgrade means the volume's state belongs to the upgrade
  # workflow, not to a preflight: name that instead of failing on whatever
  # half-swapped shape the disk happens to be in.
  refuse_unreadable_marker
  local phase
  phase="$(read_marker_field phase)"
  if [ -n "$phase" ] && [ "$phase" != "completed" ]; then
    die 2 "a major upgrade is already in progress on this volume (marker phase: $phase) — resolve it before running check"
  fi

  clear_stale_pidfile
  check_from_major
  refuse_recovery_shapes
  # Before the quiesce, so an unwritable volume root gets the precise
  # refusal instead of a generic quiesce failure.
  probe_sibling_slot
  # Quiesces an unclean cluster (WAL replay + clean shutdown — what the next
  # normal boot would do); see the header for why check is only strictly
  # read-only on a cleanly-shut-down volume.
  ensure_clean_shutdown

  local tmp_new="/tmp/pg-upgrade-check-target"
  init_new_cluster "$tmp_new"

  local out
  if out=$(run_pg_upgrade "--check" "$tmp_new"); then
    log "$out"
    rm -rf "$tmp_new"
    result "$(jq -nc --arg from "$FROM_MAJOR" --arg to "$TO_MAJOR" \
      '{ok: true, mode: "check", from: $from, to: $to}')"
    exit 0
  else
    log "$out"
    print_check_details
    rm -rf "$tmp_new"
    result "$(jq -nc --arg from "$FROM_MAJOR" --arg to "$TO_MAJOR" \
      '{ok: false, mode: "check", from: $from, to: $to, error: "pg_upgrade --check found blockers"}')"
    exit 1
  fi
}

# Carry per-cluster files the new data dir must inherit from the old one,
# called before the swap's renames (idempotent — re-copying from the same
# source on a resume is a no-op in effect):
#
#   pg_hba.conf / pg_ident.conf — the new cluster's copies are bare initdb
#     defaults, which lack the `host all all all <method>` line the official
#     entrypoint appends at init time (and any custom rules the user added).
#     Without the carry, every remote client gets "no pg_hba.conf entry"
#     after the upgrade — localhost still works via the default local trust
#     line, which is exactly why it's easy to miss. wrapper.sh additionally
#     self-heals a missing host line from config state (belt and braces).
#
#   .pitr_configured / .pitr_staging / .pgbackrest_restored — PITR lifecycle
#     sentinels that live inside $PGDATA but describe VOLUME-level history.
#     A PITR-restored fork keeps WAL_RECOVER_FROM_* + POSTGRES_RECOVERY_TARGET_TIME
#     set forever; only these sentinels tell wrapper.sh that recovery already
#     promoted. Losing them to the swap makes the next boot re-stage archive
#     recovery against the source bucket and the database never becomes
#     ready. wrapper.sh also treats a completed upgrade marker as proof of
#     promoted recovery (defense in depth); this carry keeps the sentinels
#     themselves truthful.
carry_cluster_config() {
  local src="$1" dst="$2" f
  for f in pg_hba.conf pg_ident.conf; do
    [ -f "$src/$f" ] || continue
    cp -p "$src/$f" "$dst/$f" || die 3 "failed to carry $f into the new data dir"
  done
  for f in .pitr_configured .pitr_staging .pgbackrest_restored; do
    [ -f "$src/$f" ] || continue
    cp -p "$src/$f" "$dst/$f" || die 3 "failed to carry $f into the new data dir"
  done
}

# postgresql.conf and postgresql.auto.conf (ALTER SYSTEM settings) are NOT
# carried into the new cluster — deliberately: either file can hold a GUC the
# target major removed (old_snapshot_threshold in 17, promote_trigger_file in
# 16, …), and an unrecognized parameter in those files refuses the whole
# boot. The user's tuning must not silently evaporate either, so keep
# reference copies at the volume root — they outlive the old dir's reclaim —
# and the completed marker records needsConfigReview so the dashboard can
# surface "re-apply your ALTER SYSTEM settings" instead of the user
# discovering it via a post-upgrade max_connections regression.
stash_old_config() {
  local src="$1" f
  for f in postgresql.conf postgresql.auto.conf; do
    [ -f "$src/$f" ] || continue
    cp -p "$src/$f" "$VOLUME_ROOT/.pre-upgrade-${FROM_MAJOR}-${f}" 2>/dev/null \
      || log "could not stash $f at the volume root (non-fatal; the copy in $(basename "$OLD_KEEP_DIR") remains until reclaim)"
  done
}

finish_swap() {
  # $PGDATA holds the OLD cluster and the NEW one is complete: move old aside,
  # promote new. Two renames; a crash between them leaves no $PGDATA, which
  # the marker (phase=upgraded) makes recoverable — and which wrapper.sh
  # refuses to boot into, so nothing can initdb over the gap.
  #
  # Never begin the renames unless the target cluster is really there and
  # really the target major (unless $PGDATA already IS the promoted target —
  # the resume path after a crash between the second rename and the completed
  # marker). The first rename takes $PGDATA apart; doing that on the strength
  # of a marker alone would convert "resumable degenerate state" into "no
  # data dir at all" when the new dir was lost or is a partial initdb.
  if [ "$(data_major)" != "$TO_MAJOR" ] \
    && [ "$(cat "$NEW_DATA_DIR/PG_VERSION" 2>/dev/null)" != "$TO_MAJOR" ]; then
    die 3 "cannot finish the swap: $NEW_DATA_DIR is missing or is not a $TO_MAJOR cluster — volume left untouched; restore the pre-upgrade backup or re-run the upgrade from scratch"
  fi

  # Before the renames, carry auth config + PITR sentinels from wherever the
  # old cluster currently sits (still at $PGDATA on a first pass, already
  # moved aside on a resume after a crash between the renames), and stash the
  # old cluster's postgresql{,.auto}.conf as reference copies (see
  # stash_old_config for why they are stashed, not carried).
  if [ -d "$NEW_DATA_DIR" ]; then
    if [ -d "$PGDATA" ] && [ "$(data_major)" = "$FROM_MAJOR" ]; then
      carry_cluster_config "$PGDATA" "$NEW_DATA_DIR"
      stash_old_config "$PGDATA"
    elif [ -d "$OLD_KEEP_DIR" ]; then
      carry_cluster_config "$OLD_KEEP_DIR" "$NEW_DATA_DIR"
      stash_old_config "$OLD_KEEP_DIR"
    fi
  fi

  if [ -d "$PGDATA" ] && [ "$(data_major)" = "$FROM_MAJOR" ]; then
    mv "$PGDATA" "$OLD_KEEP_DIR" || die 3 "failed to move old data dir aside"
  fi
  if [ ! -d "$PGDATA" ]; then
    [ -d "$NEW_DATA_DIR" ] || die 3 "no new data dir to promote — volume needs the pre-upgrade backup"
    mv "$NEW_DATA_DIR" "$PGDATA" || die 3 "failed to promote new data dir"
  fi

  # needsReindex: pg_upgrade preserves index FILES verbatim, but any index on
  # collatable columns (text/varchar btree) is only valid for the glibc that
  # built it — and the source cluster may have run on an older base image.
  # We can't read the OLD runtime image's glibc from here, so record the flag
  # unconditionally and let the operator/dashboard drive the REINDEX; an
  # automatic REINDEX of an arbitrarily large database inside the upgrade
  # window is the wrong default (documented follow-up in the README).
  # needsConfigReview: postgresql{,.auto}.conf were not carried (see
  # stash_old_config) — the dashboard surfaces "re-apply your ALTER SYSTEM
  # settings" off this flag, pointing at the stashed reference copies.
  write_marker "$(jq -nc \
    --arg from "$FROM_MAJOR" --arg to "$TO_MAJOR" --arg old "$(basename "$OLD_KEEP_DIR")" \
    '{phase: "completed", from: $from, to: $to, oldDataDir: $old, needsAnalyze: true, needsReindex: true, needsConfigReview: true, completedAt: (now | todate)}')"
  log "upgrade $FROM_MAJOR -> $TO_MAJOR complete"
  result "$(jq -nc --arg from "$FROM_MAJOR" --arg to "$TO_MAJOR" \
    '{ok: true, mode: "upgrade", phase: "completed", from: $from, to: $to}')"
  exit 0
}

mode_upgrade() {
  check_mount
  take_job_lock

  # Resume handling: the marker decides, but only for THIS job's version
  # pair. Markers are never deleted after an upgrade, so a later upgrade of
  # the same volume (16→17 done, now 17→18) finds the previous pair's
  # completed marker — reading that as "already done" would report success
  # while the data stays on the old major, and the workflow would flip the
  # image tag into a boot refusal.
  refuse_unreadable_marker
  local marker_phase marker_from marker_to
  marker_phase="$(read_marker_field phase)"
  marker_from="$(read_marker_field from)"
  marker_to="$(read_marker_field to)"
  case "$marker_phase" in
    completed)
      # "Already done" needs BOTH the marker and the data directory to say
      # so: a completed same-pair marker sitting over FROM-major data (a
      # partial manual restore put the old cluster back without touching the
      # volume-root marker) must re-run the upgrade, not no-op to success —
      # the workflow would flip the image tag onto FROM data and the service
      # would boot-refuse after a "successful" job.
      if [ "$marker_to" = "$TO_MAJOR" ] && [ "$(data_major)" = "$TO_MAJOR" ]; then
        log "marker says completed for ${marker_from:-?} -> $TO_MAJOR and the data directory is $TO_MAJOR — nothing to do"
        result "$(jq -nc '{ok: true, mode: "upgrade", phase: "completed", alreadyDone: true}')"
        exit 0
      fi
      if [ "$(data_major)" != "$FROM_MAJOR" ]; then
        die 2 "marker records a completed ${marker_from:-?} -> ${marker_to:-?} upgrade but the data directory is major '$(data_major)'; this job upgrades $FROM_MAJOR -> $TO_MAJOR"
      fi
      log "marker records a completed ${marker_from:-?} -> ${marker_to:-?} upgrade (history); data is $FROM_MAJOR — proceeding with $FROM_MAJOR -> $TO_MAJOR"
      ;;
    upgraded)
      # A foreign-pair in-flight marker must NOT drive finish_swap: this
      # job's NEW_DATA_DIR/OLD_KEEP_DIR names embed ITS majors, so it would
      # be swapping directories that belong to a different job. Refuse
      # loudly; only the matching pair's job can resolve the volume.
      if [ "$marker_from" != "$FROM_MAJOR" ] || [ "$marker_to" != "$TO_MAJOR" ]; then
        die 2 "marker records an in-flight ${marker_from:-?} -> ${marker_to:-?} upgrade; this job ($FROM_MAJOR -> $TO_MAJOR) refuses to finish another pair's swap — run the ${marker_from:-?}-${marker_to:-?} job to resolve it"
      fi
      log "marker says upgraded — resuming directory swap"
      finish_swap
      ;;
    "")
      # No marker, but the disk shape can still prove pg_upgrade finished:
      # --link renames the old cluster's pg_control to pg_control.old as its
      # last act, and the new data dir carries the target major's
      # PG_VERSION. If the marker write was lost (crash after pg_upgrade,
      # or a marker durability failure on an earlier image), this is the
      # only window where "no marker" does NOT mean "roll back" — the old
      # cluster can't be restarted (pg_control is gone), so roll forward.
      # This keeps the marker from being a single point of failure.
      if [ -f "$PGDATA/global/pg_control.old" ] \
        && [ "$(cat "$NEW_DATA_DIR/PG_VERSION" 2>/dev/null)" = "$TO_MAJOR" ]; then
        log "no marker, but the disk shape shows a finished pg_upgrade (pg_control.old present, new dir is $TO_MAJOR) — resuming directory swap"
        finish_swap
      fi
      ;;
    *)
      # A phase this job does not recognize (the HA workflow's "reseed" on a
      # replica volume, or a future writer's new state) is someone else's
      # in-flight state — same reading as postgres-ha's guards, where
      # anything other than absent/completed is in flight. Proceeding would
      # overwrite that owner's marker at our commit point and take away its
      # ability to resolve the volume.
      die 2 "marker phase '$marker_phase' is not this job's to resolve — refusing to upgrade over another writer's in-flight state"
      ;;
  esac

  check_from_major
  clear_stale_pidfile
  refuse_recovery_shapes
  ensure_clean_shutdown
  init_new_cluster "$NEW_DATA_DIR"

  local out
  if ! out=$(run_pg_upgrade "--check" "$NEW_DATA_DIR"); then
    log "$out"
    print_check_details
    rm -rf "$NEW_DATA_DIR"
    result "$(jq -nc --arg from "$FROM_MAJOR" --arg to "$TO_MAJOR" \
      '{ok: false, mode: "upgrade", from: $from, to: $to, error: "pg_upgrade --check found blockers"}')"
    exit 1
  fi
  log "$out"

  if ! out=$(run_pg_upgrade "--link" "$NEW_DATA_DIR"); then
    log "$out"
    # No marker was written: the old cluster may have been modified by
    # pg_upgrade's failed run and MUST NOT be restarted in place. The
    # workflow rolls back to the pre-upgrade backup.
    rm -rf "$NEW_DATA_DIR"
    result "$(jq -nc --arg from "$FROM_MAJOR" --arg to "$TO_MAJOR" \
      '{ok: false, mode: "upgrade", from: $from, to: $to, error: "pg_upgrade failed after check passed"}')"
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
