#!/usr/bin/env bash
# Drives the watcher's real gap_recovery_step over stubbed Postgres/pgBackRest
# observations: an archive_command failure that Postgres retries successfully
# ends without a backup, and WAL that is actually missing still ends in a diff.
# shellcheck disable=SC2034  # globals below are read by the sourced watcher functions
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHER="$ROOT/pgbackrest-backup-watcher.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

for fn in segment_to_number catalog_max_for_wal clear_gap_recovery_state \
          archive_failure_resolved archive_failure_step gap_recovery_step; do
  body=$(sed -n "/^${fn}() {\$/,/^}\$/p" "$WATCHER")
  eval "$body"
  declare -F "$fn" >/dev/null || { echo "could not load ${fn} from the watcher"; exit 1; }
done

GAP_MARKER="$WORK/gap_pending"
STATE="$WORK/state"
SEGMENTS_PER_LOG_FILE=256
WAL_LAG_GAP_THRESHOLD_SEGMENTS=32
GAP_RECOVERY_BACKOFF_SECONDS=600
NOW=1000000
CATALOG_MAX=""
BACKUP_RC=0

date() { echo "$NOW"; }
log() { printf '%s\n' "$*" >> "$WORK/log"; }
read_state() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | tail -1; return 0; }
write_state_field() { printf '%s=%s\n' "$1" "$2" >> "$STATE"; }
refresh_archiver_stats() { return 0; }
finalize_pending_archive_path_migration_if_needed() { return 1; }
probe_async_duplicate_error() { return 1; }
wal_has_async_archive_duplicate_error() { return 1; }
migrate_to_new_archive_path() { echo migrate >> "$WORK/actions"; }
kick_async_daemon() { echo kick >> "$WORK/actions"; }
run_backup() { echo "backup:$1" >> "$WORK/actions"; return "$BACKUP_RC"; }
# The catalog max is reported per timeline, as pgbackrest info does.
probe_catalog_max() {
  local wal="${1:-$LAST_ARCHIVED_WAL}"
  [ -z "$wal" ] && { echo ""; return 0; }
  [ "${CATALOG_MAX:0:8}" = "${wal:0:8}" ] && echo "$CATALOG_MAX" || echo ""
}

failures=0
check() {
  local what="$1"; shift
  if "$@"; then return 0; fi
  echo "FAIL [$CASE]: $what"
  failures=$((failures + 1))
}
actions() { [ -f "$WORK/actions" ] && tr '\n' ' ' < "$WORK/actions" | sed 's/ $//'; return 0; }
actions_are() { [ "$(actions)" = "$1" ]; }
state_is() { [ "$(read_state "$1")" = "$2" ]; }
logged() { grep -q -- "$1" "$WORK/log" 2>/dev/null; }
marker_absent() { [ ! -e "$GAP_MARKER" ]; }
marker_present() { [ -e "$GAP_MARKER" ]; }

begin() {
  CASE="$1"
  rm -f "$STATE" "$GAP_MARKER" "$WORK/log" "$WORK/actions"
  NOW=1000000
  BACKUP_RC=0
  GAP_STATE_DIAG=""
  write_state_field last_full_failed_count "$2"
}
# observe <failed_count> <last_failed_wal> <failed_epoch> <last_archived_wal> <archived_epoch> <catalog_max>
observe() {
  FAILED_COUNT="$1"; LAST_FAILED_WAL="$2"; LAST_FAILED_EPOCH="$3"
  LAST_ARCHIVED_WAL="$4"; LAST_ARCHIVED_EPOCH="$5"; CATALOG_MAX="$6"
  ARCHIVED_COUNT=0
  gap_recovery_step
}

# One archive-push outlives archive-timeout; the async worker has already put
# the segment in the bucket and Postgres's retry returns at once.
begin "single timeout, segment already in the bucket" 1828
observe 1829 00000001000003F300000018 999990 00000001000003F300000017 999940 00000001000003F300000019
check "the failure is followed, not treated as a gap" [ "$GAP_STATE_DIAG" = "archive-failing" ]
check "gap marker stays absent while Postgres still retries" marker_absent
check "nothing is run on first sight" actions_are ""
check "the failure is logged once" logged "archive-failure: archive_command failed for 00000001000003F300000018"
NOW=$((NOW + 60))
observe 1829 00000001000003F300000018 999990 00000001000003F30000001A 1000030 00000001000003F30000001A
check "no backup once Postgres archived on retry" actions_are ""
check "gap marker never appears" marker_absent
check "the failure folds into the anchor" state_is last_full_failed_count 1829
check "the follow-up clock is reset" state_is last_lag_detected_at 0
check "the outcome is logged" logged "archive-failure: over"
check "state reads clear" [ "$GAP_STATE_DIAG" = "clear" ]
NOW=$((NOW + 60))
observe 1829 00000001000003F300000018 999990 00000001000003F30000001B 1000090 00000001000003F30000001B
check "a settled failure stays settled" actions_are ""
check "a settled failure logs nothing more" [ "$(wc -l < "$WORK/log")" -eq 2 ]

# The failure is resolved before the watcher's first look at it.
begin "failure already over at first sight" 7
observe 8 000000010000019A0000002C 999990 000000010000019A00000032 1000000 000000010000019A00000032
check "no backup" actions_are ""
check "no gap marker" marker_absent
check "anchor advanced" state_is last_full_failed_count 8
check "one line, the outcome" [ "$(wc -l < "$WORK/log")" -eq 1 ]

# Later segments reach the bucket while an earlier one keeps failing: the
# catalog max passing the failed segment says nothing about that segment.
begin "catalog ahead of a segment Postgres is still retrying" 10
observe 11 000000010000000100000018 999990 000000010000000100000017 999940 000000010000000100000019
NOW=$((NOW + 60))
observe 12 000000010000000100000018 1000050 000000010000000100000017 999940 00000001000000010000001C
check "still followed as a failure" [ "$GAP_STATE_DIAG" = "archive-failing" ]
check "anchor untouched while it fails" state_is last_full_failed_count 10
check "no backup" actions_are ""

# Postgres reports an archive after the failure, but the bucket has not
# reached the failed segment.
begin "Postgres archived again, bucket behind the failed segment" 10
observe 11 000000010000000100000018 999990 000000010000000100000018 1000000 000000010000000100000017
check "still followed as a failure" [ "$GAP_STATE_DIAG" = "archive-failing" ]
check "anchor untouched" state_is last_full_failed_count 10

# A backup-label file fails once; it has no place in the segment range.
begin "non-segment file retried successfully" 3
observe 4 000000010000038A00000099.00033998.backup 999990 000000010000038A0000009A 1000000 000000010000038A0000009A
check "resolved on Postgres's order alone" state_is last_full_failed_count 4
check "no backup" actions_are ""

# The failure lasts: the async daemon is kicked every backoff window, and
# still no backup — Postgres holds every segment.
begin "persistent failure" 40
observe 46 000000010000034B000000C8 999990 000000010000034B000000C7 999000 000000010000034B000000C7
NOW=$((NOW + 300))
observe 51 000000010000034B000000C8 1000290 000000010000034B000000C7 999000 000000010000034B000000C7
check "no kick inside the backoff window" actions_are ""
NOW=$((NOW + 300))
observe 56 000000010000034B000000C8 1000590 000000010000034B000000C7 999000 000000010000034B000000C7
check "first kick at the backoff" actions_are "kick"
NOW=$((NOW + 300))
observe 61 000000010000034B000000C8 1000890 000000010000034B000000C7 999000 000000010000034B000000C7
check "no second kick inside the next window" actions_are "kick"
NOW=$((NOW + 300))
observe 66 000000010000034B000000C8 1001190 000000010000034B000000C7 999000 000000010000034B000000C7
check "second kick one backoff later" actions_are "kick kick"
check "kick count is kept" state_is force_attempts 2
check "no gap marker from a failure alone" marker_absent
# The archive-push wrapper now drops a segment: WAL is missing, and the same
# clock and kick count carry into gap recovery.
touch "$GAP_MARKER"
NOW=$((NOW + 60))
observe 66 000000010000034B000000C8 1001190 000000010000034B000000C9 1001240 000000010000034B000000C7
check "no backup before the bucket receives WAL again" actions_are "kick kick"
check "kick count carried over" state_is force_attempts 2
NOW=$((NOW + 60))
observe 66 000000010000034B000000C8 1001190 000000010000034B000000CB 1001300 000000010000034B000000CB
check "dropped WAL ends in a diff" actions_are "kick kick backup:diff"
check "gap marker cleared by the diff" marker_absent
check "recovery logged" logged "gap-recovery: cleared by gap-recovery diff"

# Postgres restarts while a failure is being followed: pg_stat_archiver starts
# from zero, and the next failure gets a full backoff window before any kick.
begin "Postgres restart during a followed failure" 40
observe 46 000000010000034B000000C8 999990 000000010000034B000000C7 999000 000000010000034B000000C7
NOW=$((NOW + 900))
observe 0 "" 0 "" 0 ""
check "the followed failure's clock is reset" state_is last_lag_detected_at 0
write_state_field last_full_failed_count 0   # the next full re-anchors to the new counter
NOW=$((NOW + 60))
observe 1 000000010000034B000000D0 1000950 000000010000034B000000CF 1000900 000000010000034B000000CF
check "the next failure is seen as new" logged "archive-failure: archive_command failed for 000000010000034B000000D0"
check "no kick on first sight" actions_are ""

# The bucket falls behind the handoff by the lag threshold: WAL may be missing.
begin "lag at the threshold" 5
observe 5 "" 0 000000010000000200000040 1000000 000000010000000200000020
check "enters gap recovery" marker_present
check "logged as gap recovery" logged "gap-recovery: entering recovery (lag=32"
NOW=$((NOW + 60))
observe 5 "" 0 000000010000000200000041 1000060 000000010000000200000041
check "catalog advance ends in a diff" actions_are "backup:diff"
check "gap marker cleared" marker_absent

# Lag and a failure together: the lag decides.
begin "lag and failed_count together" 5
observe 9 000000010000000200000041 999990 000000010000000200000040 999000 000000010000000200000020
check "enters gap recovery" marker_present

# A failed diff leaves the gap open for the next iteration.
begin "gap-recovery diff fails" 5
touch "$GAP_MARKER"
observe 5 "" 0 000000010000000200000040 1000000 000000010000000200000040
BACKUP_RC=1
NOW=$((NOW + 60))
observe 5 "" 0 000000010000000200000041 1000060 000000010000000200000041
check "diff attempted" actions_are "backup:diff"
check "gap marker kept for the retry" marker_present

if [ "$failures" -ne 0 ]; then
  echo "${failures} archive-failure check(s) failed"
  exit 1
fi
echo 'archive-failure regression tests passed'
