#!/bin/bash
# pgbackrest-backup-watcher.sh — long-running daemon that triggers pgBackRest
# base backups based on archiving health. Forked from wrapper.sh at container
# start when WAL_ARCHIVE_BUCKET is set; same pattern as bootstrap_pgbackrest_stanza.
#
# Triggers (any of):
#   1. NEEDS_INITIAL_BACKUP — first archive-push success after enable. Takes
#      the first full so PITR is restorable from this LSN forward. Replaces
#      v1's "immediate snapshot on enable" race: pgbackrest backup brackets
#      the base in pg_backup_start/stop so the LSN window of the base and
#      the WAL covering it are the same thing — no coordination gap.
#   2. Gap recovery — archive-push had hard failures since the last full
#      (either pgbackrest-archive-push-wrapper.sh dropped a segment and
#      touched .pgbackrest_gap_pending, or pg_stat_archiver.failed_count grew
#      since the last full's checkpoint). Once failures are decisively over,
#      runs a fresh full so PITR window resumes from this base forward.
#   3. Periodic — full every WAL_BACKUP_FULL_INTERVAL_HOURS, diff every
#      WAL_BACKUP_DIFF_INTERVAL_HOURS.
#
# State persists at $PGDATA/.pgbackrest_backup_state (key=value lines, no JSON
# dep). The bucket-side `pgbackrest --stanza=main info` is the canonical
# source of truth for backup history; the local file is a cache that survives
# restarts. A wiped volume / fresh failover-promote with stale local state
# triggers an extra full — harmless, pgBackRest's stanza locks prevent
# concurrent backups across nodes.
#
# HA: every node runs the watcher. Standbys exit early via pg_is_in_recovery().
# Only the leader runs backups. v1 of this watcher backs up from the primary;
# `--backup-standby` is a follow-up.
#
# Idle-DB heartbeat: each iteration emits a tiny non-transactional WAL record
# via pg_logical_emit_message. Without it, idle Postgres never advances the
# LSN, so archive_timeout=60 never forces a segment switch and
# pg_stat_archiver.last_archived_time stalls until the next CHECKPOINT
# (default 5 min) — meaning the picker's "latest restorable" lags wall-clock
# by minutes on quiet services. The heartbeat keeps PITR RPO tracking
# archive_timeout (~60s) instead of checkpoint_timeout (~5min). Cost is
# ~one 16MB WAL segment per minute on idle DBs (zstd-3 compresses to a
# handful of KB → ~30-70MB/day). Set WAL_HEARTBEAT_DISABLED=1 to skip.
#
# Known gap: pgBackRest's archive-push-queue-max trip drops segments without
# incrementing pg_stat_archiver.failed_count and without going through our
# archive-push wrapper, so neither gap signal fires. Until log-parsing or LSN-
# lag detection lands, queue-max-trip gaps are sealed by the next periodic
# full rather than promptly. Documented in README.

set -u

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
STATE_FILE="$PGDATA/.pgbackrest_backup_state"
GAP_MARKER="$PGDATA/.pgbackrest_gap_pending"

# POLL_INTERVAL_SECONDS / GAP_RESOLVED_GRACE_SECONDS are env-overridable so
# the e2e harness can exercise gap-recovery in <1 min instead of 5+. The
# defaults are conservative; nothing user-facing advertises these knobs.
POLL_INTERVAL_SECONDS="${WAL_BACKUP_POLL_INTERVAL_SECONDS:-60}"

# Failures must have been quiescent for this long before a gap-recovery backup
# fires. Hard failures often resolve and re-fail (intermittent S3, half-rotated
# creds); without the grace the watcher burns one full per flap.
GAP_RESOLVED_GRACE_SECONDS="${WAL_BACKUP_GAP_RESOLVED_GRACE_SECONDS:-300}"

FULL_INTERVAL_HOURS="${WAL_BACKUP_FULL_INTERVAL_HOURS:-168}"
DIFF_INTERVAL_HOURS="${WAL_BACKUP_DIFF_INTERVAL_HOURS:-24}"

log() { echo "pgbackrest-watcher: $*"; }

# State file is `key=value\n`-shaped: trivially read/written by bash without
# adding a JSON dep. Schema (all values are integer epoch seconds or counts):
#   last_full_at=<epoch>
#   last_diff_at=<epoch>
#   last_full_failed_count=<int>
read_state() {
  local field="$1"
  [ ! -f "$STATE_FILE" ] && return 0
  grep -E "^${field}=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

write_state_field() {
  local field="$1" value="$2"
  local tmp
  tmp=$(mktemp "$STATE_FILE.XXXX") || return 1
  if [ -f "$STATE_FILE" ]; then
    grep -vE "^${field}=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
  fi
  echo "${field}=${value}" >> "$tmp"
  mv "$tmp" "$STATE_FILE"
}

# Stats from pg_stat_archiver. Sets globals so callers can branch on them
# without repeated psql round-trips.
ARCHIVED_COUNT=0
FAILED_COUNT=0
LAST_ARCHIVED_EPOCH=0
LAST_FAILED_EPOCH=0

refresh_archiver_stats() {
  local stats
  stats=$(psql -U postgres -tAXq -F' ' -c "
    SELECT
      archived_count,
      failed_count,
      COALESCE(EXTRACT(EPOCH FROM last_archived_time)::bigint, 0),
      COALESCE(EXTRACT(EPOCH FROM last_failed_time)::bigint, 0)
    FROM pg_stat_archiver
  " 2>/dev/null) || return 1
  [ -z "$stats" ] && return 1
  read -r ARCHIVED_COUNT FAILED_COUNT LAST_ARCHIVED_EPOCH LAST_FAILED_EPOCH <<<"$stats"
}

# 0 = standby (skip backups). 1 = leader-or-unknown (proceed; pgBackRest's
# stanza lock is the second-line guarantee against double-trigger).
is_standby() {
  local r
  r=$(psql -U postgres -tAXq -c "SELECT pg_is_in_recovery()" 2>/dev/null) || return 1
  [ "$r" = "t" ]
}

# Returns 0 if archive failures look decisively over.
gap_recovered() {
  local now="$1" last_fail="$2"
  # Never failed (fresh stat reset, or never had a failure) → trivially recovered.
  [ "$last_fail" -eq 0 ] && return 0
  [ $((now - last_fail)) -ge "$GAP_RESOLVED_GRACE_SECONDS" ]
}

run_backup() {
  local type="$1"
  log "running pgbackrest backup --type=$type"
  # --repo=1 scopes backup + post-backup expire to this service's own bucket.
  # On a fork repo2 is source's read-only bucket; without the pin pgBackRest
  # would default to writing the new base into both repos.
  if pgbackrest --stanza=main --repo=1 backup --type="$type"; then
    local now; now=$(date +%s)
    case "$type" in
      full)
        write_state_field last_full_at "$now"
        write_state_field last_diff_at "$now"
        # Re-read failed_count *after* the backup so a failure during the
        # backup itself is folded into the high-water mark; otherwise the
        # next iteration would see growth and re-trigger immediately.
        refresh_archiver_stats || true
        write_state_field last_full_failed_count "$FAILED_COUNT"
        [ -f "$GAP_MARKER" ] && rm -f "$GAP_MARKER" && log "cleared gap marker"
        ;;
      diff|incr)
        write_state_field last_diff_at "$now"
        ;;
    esac
    log "backup --type=$type completed"
    return 0
  fi
  log "backup --type=$type failed (will retry on next poll)"
  return 1
}

# Returns the type to run on stdout, or empty if no action.
decide_action() {
  refresh_archiver_stats || return 0

  local now; now=$(date +%s)
  local last_full last_diff last_full_failed
  last_full=$(read_state last_full_at)
  last_diff=$(read_state last_diff_at)
  last_full_failed=$(read_state last_full_failed_count)
  : "${last_full_failed:=0}"

  # NEEDS_INITIAL_BACKUP — archiving has produced any segments, no full on record.
  if [ -z "$last_full" ] && [ "$ARCHIVED_COUNT" -gt 0 ]; then
    echo "full"; return 0
  fi
  [ -z "$last_full" ] && return 0  # archiving hasn't started, wait

  # Gap recovery — explicit drop marker OR failed_count grew since last full.
  # Either signal indicates archive-push had problems since the last
  # LSN-coordinated baseline, so a fresh full re-anchors the PITR window.
  local has_gap=0
  [ -f "$GAP_MARKER" ] && has_gap=1
  [ "$FAILED_COUNT" -gt "$last_full_failed" ] && has_gap=1

  if [ "$has_gap" -eq 1 ]; then
    if gap_recovered "$now" "$LAST_FAILED_EPOCH"; then
      echo "full"; return 0
    fi
    return 0  # gap still open, waiting for grace
  fi

  # Periodic full.
  if [ "$FULL_INTERVAL_HOURS" -gt 0 ] \
     && [ "$now" -ge $((last_full + FULL_INTERVAL_HOURS * 3600)) ]; then
    echo "full"; return 0
  fi

  # Periodic diff.
  if [ "$DIFF_INTERVAL_HOURS" -gt 0 ]; then
    local diff_anchor="${last_diff:-$last_full}"
    if [ "$now" -ge $((diff_anchor + DIFF_INTERVAL_HOURS * 3600)) ]; then
      echo "diff"; return 0
    fi
  fi
}

# Emits a few bytes of WAL with no table side-effects so archive_timeout=60
# has something to flush on idle DBs. transactional=false bypasses txn
# context — non-blocking, cheap. Failure is non-fatal: a temporarily blocked
# emit just postpones the next segment switch by one tick.
emit_wal_heartbeat() {
  [ "${WAL_HEARTBEAT_DISABLED:-0}" = "1" ] && return 0
  psql -U postgres -tAXq -c \
    "SELECT pg_logical_emit_message(false, 'rwy_pitr_heartbeat', '')" \
    >/dev/null 2>&1 || true
}

watcher_iteration() {
  pg_isready -h 127.0.0.1 -p 5432 -U postgres -q 2>/dev/null || return 0
  is_standby && return 0

  emit_wal_heartbeat

  local action
  action=$(decide_action)
  [ -z "$action" ] && return 0

  run_backup "$action" || true
}

# wrapper.sh forks us unconditionally; bail silently if archiving isn't on.
# A fork has both WAL_ARCHIVE_* (own bucket / repo1) and WAL_RECOVER_FROM_*
# (source bucket / repo2). The watcher targets only repo1 (run_backup pins
# --repo=1), so the fork archives normally from boot — no skip path.
[ -z "${WAL_ARCHIVE_BUCKET:-}" ] && exit 0

# Per-cluster repo-path: read the marker (written by pgbackrest-init.sh
# during initdb, or by wrapper.sh's bootstrap subshell on existing volumes).
# pgbackrest backup needs to target the same path that archive-push is
# pushing to, otherwise stanza-create / backup land at the wrong prefix.
# The marker may not exist yet on the very first watcher iteration (we're
# forked from wrapper.sh before exec'ing docker-entrypoint), so the loop
# below re-reads it on every iteration as a cheap fallback.
sync_repo_path_from_marker() {
  if [ -f "$PGDATA/.pgbackrest_repo_path" ]; then
    PGBACKREST_REPO1_PATH=$(cat "$PGDATA/.pgbackrest_repo_path")
    export PGBACKREST_REPO1_PATH
  fi
}

sync_repo_path_from_marker

log "starting (poll=${POLL_INTERVAL_SECONDS}s, full=${FULL_INTERVAL_HOURS}h, diff=${DIFF_INTERVAL_HOURS}h, gap_grace=${GAP_RESOLVED_GRACE_SECONDS}s, repo1-path=${PGBACKREST_REPO1_PATH:-unset})"

while true; do
  sync_repo_path_from_marker
  watcher_iteration
  sleep "$POLL_INTERVAL_SECONDS"
done
