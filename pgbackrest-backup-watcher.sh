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
#   2. Gap recovery — a state machine that fires whenever WAL coverage is
#      diverging from the S3 catalog, regardless of cause. Entry conditions
#      (any of):
#        - pgbackrest-archive-push-wrapper.sh dropped a segment and touched
#          .pgbackrest_gap_pending (bucket gone, hard archive-push failure)
#        - LSN-lag probe found pg_stat_archiver.last_archived_wal more than
#          WAL_LAG_GAP_THRESHOLD_SEGMENTS ahead of the catalog max (async
#          worker silently wedged — queue-max-trip or hung connection)
#      Recovery flow once in the state:
#        - Wait GAP_RECOVERY_BACKOFF_SECONDS (default 10 min) for natural
#          async recovery. Most short Tigris/S3 hiccups self-heal here.
#        - Still no catalog progress → pkill the async daemon. Foreground
#          archive-push respawns it on the next WAL switch. Cycle repeats
#          every GAP_RECOVERY_BACKOFF_SECONDS until catalog advances OR
#          the postgres process exits.
#        - Catalog max > catalog max at detection (proof async pushed to S3
#          successfully) → take a diff backup to re-anchor latestRestorableAt,
#          then clear the gap marker.
#      Diff (not full) is enough because the customer-visible state is
#      "latestRestorableAt is fresh", which a diff produces in seconds.
#      Historical missing segments stay missing in the old chain; retention
#      eventually rolls them off.
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
# LSN-lag detection: pgBackRest async mode returns archive_command success to
# Postgres as soon as the WAL segment lands in the local spool, BEFORE the
# async worker uploads it to S3. If the async worker hangs, dies without
# releasing its lock, or hits an unrecoverable upload error, the spool keeps
# accepting WAL (foreground returns 0) while the S3 catalog stays frozen.
# archive-push-queue-max eventually drops segments and ALSO returns 0 to
# Postgres — so pg_stat_archiver.failed_count never increments and the
# archive-push wrapper never sees a non-zero exit.
#
# Detection: every iteration, compare pg_stat_archiver.last_archived_wal
# against the catalog max from `pgbackrest info --output=json` (parsed with
# jq for robustness — earlier grep+sort+sed extraction had a silent catch-all
# that collapsed unparseable output into "lag=0", missing real wedges). When
# lag ≥ WAL_LAG_GAP_THRESHOLD_SEGMENTS (default 32 ≈ 512 MiB) the watcher
# enters the gap-recovery state machine — see the "Gap recovery" entry in
# the file header for the full flow.

set -u

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
STATE_FILE="$PGDATA/.pgbackrest_backup_state"
GAP_MARKER="$PGDATA/.pgbackrest_gap_pending"
PGBACKREST_CONF_FILE="/etc/pgbackrest/pgbackrest.conf"
SPOOL_ERR_DIR="$PGDATA/pgbackrest-spool/archive/main/out"

# POLL_INTERVAL_SECONDS / GAP_RECOVERY_BACKOFF_SECONDS are env-overridable so
# the e2e harness can exercise gap-recovery in <1 min instead of 10+. The
# defaults are conservative; nothing user-facing advertises these knobs.
POLL_INTERVAL_SECONDS="${WAL_BACKUP_POLL_INTERVAL_SECONDS:-60}"

# Until the first full lands the loop polls on a tighter cadence so a race
# with wrapper.sh's bootstrap stanza-create (or a slow first postmaster
# bind) doesn't cost a full minute per retry. After that, normal cadence.
INITIAL_POLL_SECONDS="${WAL_BACKUP_INITIAL_POLL_SECONDS:-5}"

# Cooldown between gap-recovery actions. After initial detection, the state
# machine waits this long for natural async recovery before kicking the async
# daemon. Each subsequent pkill cycle also waits this long before the next
# pkill. Catalog advance breaks out of the wait immediately.
GAP_RECOVERY_BACKOFF_SECONDS="${WAL_BACKUP_GAP_RECOVERY_BACKOFF_SECONDS:-600}"

FULL_INTERVAL_HOURS="${WAL_BACKUP_FULL_INTERVAL_HOURS:-168}"
DIFF_INTERVAL_HOURS="${WAL_BACKUP_DIFF_INTERVAL_HOURS:-24}"

# How often to verify the S3 catalog actually contains a full backup (seconds).
# Catches divergence between local state (last_full_at) and S3 reality — e.g.
# the backup command returned exit 0 but the catalog write never completed, or a
# volume survived a redeployment with stale state pointing at a different stanza
# path. 0 disables periodic verification (NEEDS_INITIAL_BACKUP still fires on
# fresh state). Default: 3600 (1 hour).
CATALOG_VERIFY_INTERVAL_SECONDS="${WAL_BACKUP_CATALOG_VERIFY_INTERVAL_SECONDS:-3600}"

# Minimum spacing between retries of a FAILING full backup (seconds).
# NEEDS_INITIAL_BACKUP and the catalog-verify rc=1 self-heal both leave
# last_full_at empty, which makes decide_action want a full every poll — so a
# full that keeps failing (S3 down, broken backup.info) would hammer S3 with
# full-sized pushes every ~60s. run_backup records last_full_failure_at only on
# a failed full (and clears it on success); decide_action suppresses the next
# full until this elapses. A full that follows a *deliberate* last_full_at clear
# (fresh enable, rc=1 self-heal, WAL_REGRESSION migrate) carries no fresh
# failure marker, so it fires immediately — only failing retries are throttled.
FULL_RETRY_BACKOFF_SECONDS="${WAL_BACKUP_FULL_RETRY_BACKOFF_SECONDS:-600}"

# LSN-lag detection — see file header. Detection runs every iteration (no
# probe throttle): `pgbackrest info` is local-to-S3 round-trip, ~50-200ms,
# cheap enough to call every minute. 32 segments ≈ 512 MiB — far enough above
# the steady-state hand-off-vs-upload skew to avoid false positives, far
# enough below archive-push-queue-max (default 5 GiB / 320 segments) to leave
# headroom for the recovery state machine to act before the queue actually
# trips and drops segments.
WAL_LAG_GAP_THRESHOLD_SEGMENTS="${WAL_LAG_GAP_THRESHOLD_SEGMENTS:-32}"

# Resolved cadence in seconds. WAL_BACKUP_FULL_INTERVAL_SECONDS overrides
# the hours setting — bash arithmetic precludes fractional hours, so the
# e2e harness needs a second-level knob to exercise retention rollover
# inside a single test cycle. 0 means "no periodic full" (gap-recovery
# and NEEDS_INITIAL_BACKUP still fire); any positive value sets the
# cadence. Defaults to FULL_INTERVAL_HOURS * 3600 when unset, preserving
# existing prod behavior.
FULL_INTERVAL_SECONDS="${WAL_BACKUP_FULL_INTERVAL_SECONDS:-$((FULL_INTERVAL_HOURS * 3600))}"
DIFF_INTERVAL_SECONDS="${WAL_BACKUP_DIFF_INTERVAL_SECONDS:-$((DIFF_INTERVAL_HOURS * 3600))}"

log() { echo "pgbackrest-watcher: $*"; }

# State file is `key=value\n`-shaped: trivially read/written by bash without
# adding a JSON dep. Schema (all values are integer epoch seconds or counts):
#   last_full_at=<epoch>             — last successful full backup
#   last_diff_at=<epoch>             — last successful diff/incr backup
#   last_full_failed_count=<int>     — pg_stat_archiver.failed_count after last full
#   last_catalog_verify_at=<epoch>   — last S3 catalog probe (catalog_check_backup)
#   last_full_failure_at=<epoch>     — epoch a full backup last FAILED (written
#                                      in run_backup on a failed full, cleared
#                                      on success). decide_action throttles
#                                      retries of a failing full to one per
#                                      FULL_RETRY_BACKOFF_SECONDS; a full after a
#                                      deliberate last_full_at clear is never
#                                      delayed (no fresh failure marker).
#   last_lag_detected_at=<epoch>     — when current gap-recovery cycle started
#   catalog_max_at_detection=<wal>   — catalog max segment at detection (recovery
#                                       proof is "current catalog_max > this")
#   last_force_recovery_at=<epoch>   — last time we pkill'd the async daemon
#   force_attempts=<int>             — pkill cycles this gap-recovery cycle
#   archive_migration_orig_path=<path> — pre-migration repo1-path, set on the
#                                       first WAL_REGRESSION self-heal and
#                                       never cleared. Successive migrations
#                                       compose suffix off this (orig-<e2>),
#                                       not the live path (orig-<e1>-<e2>),
#                                       so a customer who triggers multiple
#                                       rollbacks gets flat sibling prefixes
#                                       (cluster-X, cluster-X-e1, cluster-X-e2)
#                                       rather than a deepening chain.
#   archive_migration_pending_new_path=<path>
#                                     — in-flight migration target, and the
#                                       interlock that blocks backups until the
#                                       migration finalizes. Written before
#                                       apply_active_path; cleared on success.
#                                       On retry after a transient
#                                       apply_active_path failure, reuse this
#                                       instead of computing a fresh epoch —
#                                       otherwise every retry would create a
#                                       new cluster-X-<epoch> sibling and
#                                       spam orphaned prefixes.
#                                       Also set by wrapper.sh when a boot-time
#                                       re-anchor moves archiving onto a
#                                       re-identified cluster's own path, so the
#                                       same finalization + gating applies to
#                                       both producers.
#                                       Both fields were named wal_regression_*
#                                       before the re-anchor path shared them;
#                                       migrate_legacy_state_field_names renames
#                                       them in place on startup.
#   probe_fail_since=<epoch>         — epoch when pgbackrest info first failed
#                                       in the current consecutive-failure run
#                                       (0 = probes are succeeding). Reset to 0
#                                       on any successful probe. Used by the
#                                       S3-blind-spot kick: if probes have been
#                                       failing for > GAP_RECOVERY_BACKOFF_SECONDS
#                                       AND pg_stat_archiver shows WAL advancing,
#                                       pkill the async daemon without S3
#                                       confirmation — the probe blackout itself
#                                       is evidence the async worker may be wedged
#                                       on a hung S3 connection.
#   probe_fail_archived_at_start=<int> — ARCHIVED_COUNT snapshot taken when the
#                                       consecutive-failure run began. If count
#                                       has grown since then, postgres is still
#                                       handing WAL to the spool while S3 is dark
#                                       — strengthens the kick signal.
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

# One-shot rename of the pre-generalization field names, run once at startup so
# every reader below can assume the new names exist and nothing needs a
# read-with-fallback (a fallback would deadlock the "cleared" state: writing the
# new key empty while a legacy key still held a path would keep resolving to
# the stale path forever).
#
# Renamed rather than dual-read because the migration machinery is no longer
# WAL_REGRESSION-specific — wrapper.sh's boot-time re-anchor sets the same
# pending field. A state file written by the previous image version is
# converted on the first poll after the upgrade; one that has already been
# converted (or never had the legacy fields) is untouched.
migrate_legacy_state_field_names() {
  [ ! -f "$STATE_FILE" ] && return 0
  local legacy new value
  for legacy in wal_regression_orig_path wal_regression_pending_new_path; do
    grep -qE "^${legacy}=" "$STATE_FILE" 2>/dev/null || continue
    new="archive_migration_${legacy#wal_regression_}"
    value=$(read_state "$legacy")
    # Keep whichever value the new name already carries: only the legacy
    # writer could have set the legacy key, so a populated new key means this
    # rename already ran and the legacy line is a leftover.
    if [ -z "$(read_state "$new")" ] && [ -n "$value" ]; then
      write_state_field "$new" "$value" || return 1
    fi
    local tmp
    tmp=$(mktemp "$STATE_FILE.XXXX") || return 1
    grep -vE "^${legacy}=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$STATE_FILE" || { rm -f "$tmp"; return 1; }
    log "state: renamed ${legacy} → ${new}"
  done
  return 0
}

# Stats from pg_stat_archiver. Sets globals so callers can branch on them
# without repeated psql round-trips.
ARCHIVED_COUNT=0
FAILED_COUNT=0
LAST_ARCHIVED_EPOCH=0
LAST_FAILED_EPOCH=0
LAST_ARCHIVED_WAL=""
LAST_FAILED_WAL=""

# COALESCE(…, '-') keeps fields non-empty so `read -r`'s whitespace
# IFS-splitting doesn't collapse trailing empty columns into the previous one
# and corrupt the bind. The sentinel is stripped below.
refresh_archiver_stats() {
  local stats wal_field failed_wal_field
  stats=$(psql -U "${PGUSER:-postgres}" -tAXq -F' ' -c "
    SELECT
      archived_count,
      failed_count,
      COALESCE(EXTRACT(EPOCH FROM last_archived_time)::bigint, 0),
      COALESCE(EXTRACT(EPOCH FROM last_failed_time)::bigint, 0),
      COALESCE(last_archived_wal, '-'),
      COALESCE(last_failed_wal, '-')
    FROM pg_stat_archiver
  " 2>/dev/null) || return 1
  [ -z "$stats" ] && return 1
  read -r ARCHIVED_COUNT FAILED_COUNT LAST_ARCHIVED_EPOCH LAST_FAILED_EPOCH wal_field failed_wal_field <<<"$stats"
  if [ "$wal_field" = "-" ]; then
    LAST_ARCHIVED_WAL=""
  else
    LAST_ARCHIVED_WAL="$wal_field"
  fi
  if [ "$failed_wal_field" = "-" ]; then
    LAST_FAILED_WAL=""
  else
    LAST_FAILED_WAL="$failed_wal_field"
  fi
}

# 0 = standby (skip backups). 1 = leader-or-unknown (proceed; pgBackRest's
# stanza lock is the second-line guarantee against double-trigger).
is_standby() {
  local r
  r=$(psql -U "${PGUSER:-postgres}" -tAXq -c "SELECT pg_is_in_recovery()" 2>/dev/null) || return 1
  [ "$r" = "t" ]
}

run_backup() {
  local type="$1"
  log "running pgbackrest backup --type=$type"
  # --repo=1 scopes backup + post-backup expire to this service's own bucket.
  # On a fork repo2 is source's read-only bucket; without the pin pgBackRest
  # would default to writing the new base into both repos.
  #
  # --no-expire-auto: pgBackRest's default (expire-auto=y) runs retention
  # cleanup as part of this same command, so a failure/timeout during expire
  # (e.g. a slow S3-compatible endpoint on the post-backup bucket listing)
  # makes `backup` itself return non-zero even though the backup already
  # landed and is durable in the catalog. That false failure used to keep
  # last_full_at empty forever, so decide_action treated the backup as
  # permanently overdue and re-ran a brand-new FULL upload every retry
  # cycle — unbounded egress from re-uploading the entire database in a
  # loop, invisible to anything watching for backup *failures* because the
  # backup itself kept succeeding. Expire now runs as its own explicit,
  # non-gating step below, only after the backup is confirmed to have
  # actually succeeded.
  pgbackrest --stanza=main --repo=1 backup --type="$type" --no-expire-auto
  local exit_code=$?

  # Exit 55 = FileMissingError: backup.info absent — stanza was never
  # initialized (bootstrap stanza-create failed or timed out on first boot).
  # Run stanza-create now and retry once; the watcher loop handles the rest.
  if [ "$exit_code" -eq 55 ]; then
    log "stanza not initialized (exit 55), running stanza-create then retrying backup..."
    pgbackrest --stanza=main stanza-create || true
    pgbackrest --stanza=main --repo=1 backup --type="$type" --no-expire-auto
    exit_code=$?
  fi

  if [ "$exit_code" -ne 0 ]; then
    # Record the failure time only for fulls so decide_action can space
    # repeated initial/periodic full *retries* (FULL_RETRY_BACKOFF_SECONDS)
    # without hammering S3 every poll. Diffs aren't gated.
    [ "$type" = "full" ] && write_state_field last_full_failure_at "$(date +%s)"
    log "backup --type=$type failed (will retry on next poll)"
    return 1
  fi

  local now; now=$(date +%s)
  case "$type" in
    full)
      write_state_field last_full_at "$now"
      write_state_field last_diff_at "$now"
      # Clear the failure marker so a subsequent deliberate last_full_at clear
      # (catalog-verify rc=1, WAL_REGRESSION migrate) re-fires the full
      # immediately rather than inheriting this run's backoff.
      write_state_field last_full_failure_at ""
      # clear_gap_recovery_state refreshes pg_stat_archiver and writes
      # last_full_failed_count itself — folds failures-during-backup into
      # the anchor so the next iteration doesn't re-fire detection.
      clear_gap_recovery_state "cleared by full backup"
      ;;
    diff|incr)
      write_state_field last_diff_at "$now"
      ;;
  esac
  log "backup --type=$type completed"

  # Retention is best-effort and deliberately decoupled from backup success
  # (see --no-expire-auto above): a failure here just leaves old
  # backups/WAL around for one more cycle. The next scheduled backup (full
  # or diff, per the normal cadence — no dedicated retry loop for expire
  # alone) tries again; nothing about current restorability regresses in
  # the meantime. Log line is deliberately distinct from "backup
  # --type=$type failed" above so this can't be mistaken for a backup
  # failure by anything grepping watcher logs.
  if ! pgbackrest --stanza=main --repo=1 expire; then
    log "pgbackrest expire failed after successful backup --type=$type (retention not enforced this cycle; will retry after next backup)"
  fi

  emit_pitr_anchor
  return 0
}

# Probes the S3 catalog for repo1 via pgbackrest info --output=json.
# Returns three distinct states:
#   0 — full backup confirmed present
#   1 — conclusively no full backup (pgbackrest exit 0, structured output
#       parsed cleanly, no `.backup[]?.type == "full"` entry)
#   2 — inconclusive (pgbackrest exit non-zero, output empty, or jq parse
#       error — S3 unreachable, auth failure, stanza not yet created, etc.)
#       Caller must NOT clear local state on rc=2.
#
# Uses jq for structured navigation rather than grep `'"type":"full"'`.
# The grep would false-positive if a future pgbackrest schema (or a key in
# a sibling section that happens to be named "type" with value "full")
# matched the literal; jq with -e returns exit 1 when the filter yields
# null/empty/false, exit 2 on parse error.
catalog_check_backup() {
  local info_out rc
  info_out=$(timeout 60 pgbackrest --stanza=main --repo=1 info --output=json 2>/dev/null)
  rc=$?
  [ "$rc" -ne 0 ] && return 2
  [ -z "$info_out" ] && return 2
  # jq -r outputs "true" or "false"; || handles parse errors (jq rc=2+).
  # Avoid capturing $? after an if...fi block — bash sets $? to 0 when the
  # condition is false and there is no else branch, masking jq's rc=1.
  local has_full
  has_full=$(printf '%s' "$info_out" \
    | jq -r '[.[]?.backup[]? | select(.type == "full")] | length > 0' 2>/dev/null) \
    || return 2
  [ "$has_full" = "true" ]  && return 0
  [ "$has_full" = "false" ] && return 1
  return 2
}

# Re-runs the catalog probe with stderr captured and logs the exit code + a
# short tail of the error. catalog_check_backup swallows stderr (2>/dev/null)
# so a permanently-rejected backup.info is invisible in container logs — this
# is called only when the deadlock breaker trips, so the cost of a second
# `pgbackrest info` is paid at most once per self-heal, not every poll.
log_catalog_probe_error() {
  local err rc
  err=$(timeout 60 pgbackrest --stanza=main --repo=1 info --output=json 2>&1 >/dev/null)
  rc=$?
  log "catalog probe diagnostic: pgbackrest info exited rc=${rc}; stderr: $(printf '%s' "$err" | tr '\n' ' ' | cut -c1-300)"
}

# Runs pgbackrest stanza-create every watcher iteration. stanza-create is
# idempotent: when the stanza already exists and backup.info is valid, it does
# a couple of S3 reads and exits 0 (silent). It only writes when backup.info is
# missing or corrupt — exactly the rc=2 deadlock scenario. Running it every
# iteration decouples stanza repair from the catalog-verify interval so a broken
# stanza is fixed on the next poll (~60s) rather than waiting up to
# CATALOG_VERIFY_INTERVAL_SECONDS (default 1h). Logs only on failure.
stanza_create_step() {
  local out rc
  out=$(timeout 60 pgbackrest --stanza=main stanza-create 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log "stanza-create: exited rc=${rc}; $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  fi
}

# LAST_OBSERVED_LAG_SEGMENTS / LAST_LAG_REPO_MAX surface the most recent
# observation to watcher_iteration's diagnostic log line.
LAST_OBSERVED_LAG_SEGMENTS=0
LAST_LAG_REPO_MAX=""
GAP_STATE_DIAG="clear"

# SEGMENTS_PER_LOG_FILE = 0x100000000 / wal_segment_size. Default 256 (=
# 16 MiB segsize × 256 = 4 GiB per logical log). Postgres allows
# wal_segment_size to be set at initdb between 1 MiB and 1 GiB (powers of 2),
# so a non-default segsize would otherwise miscompute lag by a factor of
# (default / actual). refresh_wal_segment_size() probes pg_settings on
# first iteration and caches; failover to a cluster with a different
# segsize (uncommon but legal) re-probes once per iteration. Cheap: it's
# one psql round-trip against a local socket on top of refresh_archiver_stats.
SEGMENTS_PER_LOG_FILE=256
WAL_SEGMENT_SIZE_BYTES=16777216

# Query pg_settings for wal_segment_size (reported in 8 KiB pages, the
# PGC_INTERNAL unit) and derive the segments-per-XLogId divisor. Sets
# SEGMENTS_PER_LOG_FILE (and WAL_SEGMENT_SIZE_BYTES for log line clarity).
# Failure is non-fatal: globals keep their last value (or the 16 MiB
# default) so segment_to_number doesn't crash; the resulting lag may be
# scaled wrong by a factor of 2 until the next successful probe, which is
# strictly less bad than not detecting wedges at all.
refresh_wal_segment_size() {
  local pages
  pages=$(psql -U "${PGUSER:-postgres}" -tAXq -c \
    "SELECT setting::bigint FROM pg_settings WHERE name = 'wal_segment_size'" \
    2>/dev/null) || return 1
  [ -z "$pages" ] && return 1
  case "$pages" in
    *[!0-9]*) return 1 ;;
  esac
  [ "$pages" -le 0 ] && return 1
  local bytes=$(( pages * 8 * 1024 ))
  # 0x100000000 = 4294967296. Divisor must evenly divide it for any legal
  # wal_segment_size (postgres enforces power-of-2 between 1 MiB and 1 GiB
  # at initdb).
  local per_log=$(( 4294967296 / bytes ))
  [ "$per_log" -le 0 ] && return 1
  SEGMENTS_PER_LOG_FILE="$per_log"
  WAL_SEGMENT_SIZE_BYTES="$bytes"
  return 0
}

# 24-char hex WAL filename → absolute segment count. SEGMENTS_PER_LOG_FILE
# is sourced from postgres's wal_segment_size GUC, not hardcoded, so a
# cluster initdb'd with --wal-segsize=32 (or 1, or 1024) computes lag
# correctly. Echoes empty on malformed input so callers short-circuit.
# Strict shape check before the arithmetic avoids letting a stray non-hex
# character feed `$((16#…))` and crash the watcher via set -u +
# arithmetic failure.
segment_to_number() {
  local wal="$1"
  [ ${#wal} -eq 24 ] || return 0
  case "$wal" in
    *[!0-9A-Fa-f]*) return 0 ;;
  esac
  local log seg
  log=$((16#${wal:8:8}))
  seg=$((16#${wal:16:8}))
  echo $((log * SEGMENTS_PER_LOG_FILE + seg))
}

# Echoes the highest archived WAL segment on the same timeline as the input
# WAL (defaults to LAST_ARCHIVED_WAL; "" if the catalog has no max for that
# timeline yet).
# Returns 0 on a successful probe (including empty-result), 1 on transient
# failure (pgbackrest info errored, JSON unparseable). The previous version
# silently collapsed unparseable output into "lag=0" — that's the bug that
# masked Nexa/Postgres-2xa1 and ERP-3.0 at 250+ segments lag while the
# watcher reported lag=0. jq either parses or fails loudly; no quiet zero.
probe_catalog_max() {
  local wal_for_timeline="${1:-$LAST_ARCHIVED_WAL}"
  [ -z "$wal_for_timeline" ] && { echo ""; return 0; }
  local info_out
  info_out=$(timeout 30 pgbackrest --stanza=main --repo=1 info --output=json 2>/dev/null) || return 1
  [ -z "$info_out" ] && return 1

  local tl="${wal_for_timeline:0:8}"
  local repo_max
  repo_max=$(printf '%s' "$info_out" | jq -r --arg tl "$tl" '
    [ .[]?.archive[]?.max // empty
      | select(type == "string")
      | select(length == 24)
      | select(startswith($tl))
    ] | max // ""
  ' 2>/dev/null)
  local jq_rc=$?
  [ "$jq_rc" -ne 0 ] && return 1

  echo "$repo_max"
  return 0
}

# Returns a catalog max suitable for comparing against a specific WAL file.
# If the already-probed catalog_max is empty or on another timeline (common
# after postgres restart, when pg_stat_archiver.last_archived_wal is unset),
# re-probe pgBackRest using the WAL's timeline explicitly.
catalog_max_for_wal() {
  local wal="$1" current="${2:-}"
  [ -z "$wal" ] && { echo ""; return 0; }
  if [ -n "$current" ] && [ "${current:0:8}" = "${wal:0:8}" ]; then
    echo "$current"
    return 0
  fi
  probe_catalog_max "$wal"
}

# Clears all gap-recovery state (marker file + state fields). Called after a
# successful diff (recovery confirmed) or full (re-anchors the baseline).
# Re-reads pg_stat_archiver to fold any failed pushes during the backup we
# just ran into the failed_count anchor — without this the next iteration
# would see FAILED_COUNT > last_full_failed_count and immediately re-fire
# detection.
clear_gap_recovery_state() {
  local reason="${1:-cleared}"
  refresh_archiver_stats || true
  write_state_field last_full_failed_count "${FAILED_COUNT:-0}"
  write_state_field last_lag_detected_at 0
  write_state_field catalog_max_at_detection ""
  write_state_field last_force_recovery_at 0
  write_state_field force_attempts 0
  if [ -f "$GAP_MARKER" ]; then
    rm -f "$GAP_MARKER"
    log "gap-recovery: ${reason}"
  fi
}

# Kicks the async daemon. Foreground archive-push respawns it on the next
# WAL switch (heartbeat + archive_timeout=60 guarantees one within ~60s).
# Crashed-daemon case: pkill is a no-op, respawn happens regardless.
# Hung-daemon case: pkill removes the stuck process so respawn can succeed.
# Spool is safe to disrupt — pgBackRest re-uploads from pg_wal on respawn.
#
# Target: the literal substring "archive-push:async" in the cmdline.
# pgBackRest spawns the async daemon via cfgExecParam(cfgCmdArchivePush,
# cfgCmdRoleAsync, ...) and cfgParseCommandRoleName (src/config/parse.c)
# encodes the role with a colon — argv[1] of the spawned process becomes
# "archive-push:async". The foreground caller (which runs as
# archive_command and exits in ~300ms) has "archive-push" *without* a
# colon, so the colon disambiguates: pkill matches the long-lived async
# daemon but never the short-lived foreground invocation. Verify in a
# running container with `pgrep -af archive-push:async`.
kick_async_daemon() {
  pkill -f 'archive-push:async' 2>/dev/null || true
}

# Rewrite repo1-path in pgbackrest.conf without requiring write permission on
# /etc/pgbackrest. The watcher runs as postgres; wrapper.sh chowns the conf
# file to postgres but leaves the directory root-owned, so sed -i/temp+rename
# fails even though the file itself is writable. Render to a temp file under
# PGDATA, then copy over the existing inode (file write permission is enough).
rewrite_pgbackrest_conf_path() {
  local path="$1" tmp
  [ -f "$PGBACKREST_CONF_FILE" ] || return 0
  tmp=$(mktemp "$PGDATA/.pgbackrest_conf.XXXX") || return 1
  if ! awk -v path="$path" '
    BEGIN { replaced = 0 }
    /^repo1-path=/ { print "repo1-path=" path; replaced = 1; next }
    { print }
    END { if (!replaced) print "repo1-path=" path }
  ' "$PGBACKREST_CONF_FILE" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! cat "$tmp" > "$PGBACKREST_CONF_FILE"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  return 0
}

# Source-of-truth setter for the active archive path. Updates the on-disk
# marker (read by the archive-push wrapper on every call and by the watcher's
# sync_repo_path_from_marker), rewrites repo1-path in
# /etc/pgbackrest/pgbackrest.conf, and updates the process env. Idempotent.
#
# The conf rewrite is defense-in-depth, not the load-bearing read path:
# mono's restore-picker SSH probe (packages/backboard/src/controllers/databases/
# pgbackrestInfo.ts) reads the marker via `cat $PGDATA/.pgbackrest_repo_path`
# and exports PGBACKREST_REPO1_PATH as an env override, and env > conf in
# pgBackRest's option resolution. Marker-flip alone is what the picker sees.
# The conf rewrite catches bare `pgbackrest info` invocations that don't go
# through the override — operator `docker exec` shells, future callers, etc.
apply_active_path() {
  local path="$1"
  [ -z "$path" ] && return 1
  # tmp+rename so a concurrent `cat $marker` from the archive-push wrapper
  # (called by Postgres on every WAL switch) never sees a truncated /
  # half-written file. rename(2) within the same directory is atomic on
  # POSIX filesystems — the marker is either fully OLD or fully NEW for
  # every reader. The conf rewrite below also has a non-atomic overwrite
  # window, but pgBackRest reads env > conf and the wrapper exports
  # PGBACKREST_REPO1_PATH from the marker, so the marker is the
  # load-bearing read path and the one that needs the atomicity guarantee.
  local marker="$PGDATA/.pgbackrest_repo_path"
  local tmp
  tmp=$(mktemp "${marker}.XXXX") || return 1
  printf '%s\n' "$path" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$marker" || { rm -f "$tmp"; return 1; }
  if ! rewrite_pgbackrest_conf_path "$path"; then
    log "apply_active_path: failed to rewrite repo1-path in ${PGBACKREST_CONF_FILE} (marker + env are authoritative; bare-shell diagnostics will see stale path)"
  fi
  PGBACKREST_REPO1_PATH="$path"
  export PGBACKREST_REPO1_PATH
}

# Async-spool probe for ArchiveDuplicateError (exit 45). Catches the case
# where async hit the regression but the foreground archive_command hasn't
# yet been re-invoked to surface .error to pg_stat_archiver — so
# LAST_FAILED_WAL is still NULL/stale and the failed_grew + epoch guards
# below can't fire. Echoes the WAL filename of the first catalog-valid
# matching error; returns non-zero if none found.
#
# Match key is the first line of the .error file, which pgBackRest writes as
# the integer exit code (see src/command/archive/common.c — archiveModePush
# uses the `out` queue; archiveAsyncStatusErrorWrite writes
# `<code>\n<message>`). 45 == ArchiveDuplicateError is the only
# version-stable identifier; the human-readable message phrasing has churned
# across 2.x releases ("with different checksum" → "with a different
# checksum" → …) and matching it would silently disarm on the next rename.
wal_has_async_archive_duplicate_error() {
  local wal="$1" err_file first_line
  [ -n "$wal" ] || return 1
  [ ${#wal} -eq 24 ] || return 1
  case "$wal" in *[!0-9A-Fa-f]*) return 1 ;; esac
  err_file="$SPOOL_ERR_DIR/${wal}.error"
  [ -f "$err_file" ] || return 1
  IFS= read -r first_line < "$err_file" 2>/dev/null || return 1
  [ "$first_line" = "45" ]
}

probe_async_duplicate_error() {
  local catalog_max="${1:-}"
  [ -d "$SPOOL_ERR_DIR" ] || return 1
  local err_file first_line base
  for err_file in "$SPOOL_ERR_DIR"/*.error; do
    [ -f "$err_file" ] || continue
    # Skip non-WAL-segment errors (backup history files like
    # <wal>.<offset>.backup also archive through this path and produce
    # <name>.backup.error on exit 45). Same strict shape as
    # segment_to_number's input check.
    base=$(basename "$err_file" .error)
    [ ${#base} -eq 24 ] || continue
    case "$base" in *[!0-9A-Fa-f]*) continue ;; esac
    IFS= read -r first_line < "$err_file" 2>/dev/null || continue
    [ "$first_line" = "45" ] || continue

    # When catalog_max is available, verify the failing segment is on the same
    # timeline and at or before the S3 max — guards against stale .error files
    # written on another timeline. If the first exit-45 file is stale, keep
    # scanning: a later .error may be the real WAL_REGRESSION signal.
    #
    # When catalog_max is empty (LAST_ARCHIVED_WAL unset after postgres
    # restart — the post-rollback scenario this probe is designed for), we
    # accept the first matching file in glob order regardless of age. Glob
    # is lexicographic, so this is not the most-recent .error. That's OK:
    # an exit-45 .error is self-evident proof that pgBackRest hit a segment
    # already in S3 with different content. Whichever such file we picked,
    # migration to a fresh path suffix is the correct response — the new
    # path is empty and won't conflict, and the old path's contents stay
    # reachable via mono's PITR restore UI. Picking a "wrong" exit-45 file
    # would still trigger the right action.
    local d_n
    d_n=$(segment_to_number "$base")
    [ -n "$d_n" ] || continue
    if [ -n "$catalog_max" ]; then
      local d_tl c_tl c_n
      d_tl="${base:0:8}"
      c_tl="${catalog_max:0:8}"
      c_n=$(segment_to_number "$catalog_max")
      [ "$d_tl" = "$c_tl" ] && [ -n "$c_n" ] && [ "$d_n" -le "$c_n" ] || continue
    fi

    echo "$base"
    return 0
  done
  return 1
}

write_state_field_required() {
  local field="$1" value="$2"
  if ! write_state_field "$field" "$value"; then
    log "state-write: failed to persist ${field}; refusing unsafe archive-path migration step"
    return 1
  fi
  return 0
}

# Finalizes a marker-flipped archive-path migration by forcing pgBackRest's
# async daemon to re-read repo1-path and clearing stale async status files from
# the old path. Only clear archive_migration_pending_new_path after this
# succeeds; a crash before cleanup leaves the pending field in place so the next
# watcher iteration retries this finalization instead of trusting stale
# .ok/.error files.
#
# Shared by both producers of a migration: the WAL_REGRESSION self-heal below,
# and wrapper.sh's boot-time re-anchor onto a re-identified cluster's path
# (which sets the same pending field and normally finalizes its own migration —
# this runs when that boot-time attempt did not get that far).
finalize_archive_path_migration() {
  local path="$1"

  log "archive-migration: kicking async daemon to pick up new repo1-path"
  kick_async_daemon
  # Wait up to 2s for the daemon to actually exit before cleaning spool
  # files. pkill(1) is non-blocking — in the window between signal delivery
  # and process exit the daemon's shutdown path can write a new .error/.ok
  # file, which would survive the rm below and poison the new archive path.
  local _drain_deadline=$(($(date +%s) + 2))
  while pgrep -f 'archive-push:async' >/dev/null 2>&1 \
        && [ "$(date +%s)" -lt "$_drain_deadline" ]; do
    sleep 0.2
  done
  if pgrep -f 'archive-push:async' >/dev/null 2>&1; then
    log "archive-migration: async daemon did not exit after TERM; forcing kill before cleaning spool"
    pkill -9 -f 'archive-push:async' 2>/dev/null || true
    local _kill_deadline=$(($(date +%s) + 2))
    while pgrep -f 'archive-push:async' >/dev/null 2>&1 \
          && [ "$(date +%s)" -lt "$_kill_deadline" ]; do
      sleep 0.2
    done
    if pgrep -f 'archive-push:async' >/dev/null 2>&1; then
      log "archive-migration: async daemon still alive after SIGKILL; will retry finalization"
      return 1
    fi
  fi

  # Stale async status files reference segments on the OLD path — the
  # conflict that produced .error files doesn't exist at the new (empty)
  # path, and .ok files can incorrectly satisfy future archive-push calls
  # without uploading the segment to the NEW path. The spool is a coordination
  # cache, never durable data — async re-uploads from pg_wal on next call.
  if ! rm -f "$SPOOL_ERR_DIR"/*.error "$SPOOL_ERR_DIR"/*.ok 2>/dev/null; then
    log "archive-migration: failed to clean async status files; will retry finalization"
    return 1
  fi

  # Clear the generic gap-recovery sentinel; archive_migration_pending_new_path
  # remains the migration-specific backup gate until finalization fully succeeds.
  rm -f "$GAP_MARKER"

  if ! write_state_field archive_migration_pending_new_path ""; then
    log "archive-migration: failed to clear pending migration marker; will retry finalization"
    return 1
  fi

  log "archive-migration: migration finalized at ${path}; async status cache cleared"
}

# If a prior iteration (or wrapper.sh's boot-time re-anchor) flipped the marker
# but crashed — or hit a transient state-file write failure — before clearing
# archive_migration_pending_new_path, no .error may remain to call
# migrate_to_new_archive_path again. Retry finalization directly whenever the
# active marker already equals the pending target; suppress other gap work for
# this iteration so failures keep retrying cleanly on the next poll.
finalize_pending_archive_path_migration_if_needed() {
  local pending
  pending=$(read_state archive_migration_pending_new_path)
  [ -z "$pending" ] && return 1
  [ "${PGBACKREST_REPO1_PATH:-}" != "$pending" ] && return 1

  GAP_STATE_DIAG="archive-migration-finalizing"
  log "archive-migration: finalizing pending archive-path migration at ${pending}"
  finalize_archive_path_migration "$pending" || true
  return 0
}

# Self-heals a WAL_REGRESSION condition by migrating archiving to a new S3
# path suffix (e.g. cluster-SYSID → cluster-SYSID-<epoch>). WAL_REGRESSION
# occurs when a volume snapshot rollback restores the data directory to an
# earlier LSN while S3 retains the pre-rollback WAL at the same segment names.
# pgBackRest refuses to overwrite existing S3 objects with different content
# (exit 45) so every archive-push fails — pkill-async cycles do not fix this.
#
# The migration is non-destructive: the old path and all its backups remain
# in S3 untouched and remain reachable through mono's PITR restore UI —
# usePitrHistories.tsx discovers every cluster-* sub-prefix in the bucket
# and offers each as a selectable restore source (`isCurrent` flag
# distinguishes the active path from orphans). No customer-side action is
# required to keep that data reachable. Effective immediately without a
# redeploy — see apply_active_path's docblock for the marker/env/conf
# convergence.
#
# Suffix is the wall-clock epoch at migration time, not an incrementing
# generation counter. A counter lives in PGDATA's state file — a second
# volume-snapshot rollback to a pre-self-heal PGDATA would reset the counter
# to 0 and re-pick the same `-2` suffix as a prior migration, colliding with
# the still-broken contents at that path. Epoch-suffixed paths are unique
# across rollbacks for as long as wall-clock advances. The computed epoch is
# persisted in archive_migration_pending_new_path before the state reset and
# reused on retry, so a transiently-failing apply_active_path doesn't spawn
# a new sibling prefix per poll.
#
# Crash safety: state-reset writes land BEFORE the marker flip. A crash in
# the middle leaves marker=OLD + last_full_at="" — the next iteration
# re-detects WAL_REGRESSION at the old path and re-fires this function with
# the persisted pending new_path, converging cleanly. The alternative
# (marker first) would strand the watcher at the new empty path with stale
# last_full_at, skipping NEEDS_INITIAL_BACKUP and waiting up to a full
# catalog-verify cycle to heal.
migrate_to_new_archive_path() {
  GAP_STATE_DIAG="wal-regression"

  # PGBACKREST_REPO1_PATH is normally set by wrapper.sh's exec env and
  # refreshed every iteration by sync_repo_path_from_marker, but a missing
  # marker + missing env would trip `set -u` below. Bail with a clear log
  # rather than aborting the watcher iteration mid-flow.
  if [ -z "${PGBACKREST_REPO1_PATH:-}" ]; then
    log "wal-regression: PGBACKREST_REPO1_PATH unset (marker missing, no env override); cannot migrate"
    return 1
  fi

  # Track the pre-migration path so successive migrations land at
  # cluster-SYSID-<epoch1>, cluster-SYSID-<epoch2>, … rather than chaining
  # suffixes (cluster-SYSID-<epoch1>-<epoch2>).
  local orig_path
  orig_path=$(read_state archive_migration_orig_path)
  if [ -z "$orig_path" ]; then
    orig_path="$PGBACKREST_REPO1_PATH"
    write_state_field_required archive_migration_orig_path "$orig_path" || return 1
  fi

  # Reuse the pending new_path from a prior failed attempt if present —
  # otherwise apply_active_path failures (mktemp/mv on disk-full or
  # permission errors) would compute a fresh `date +%s` every iteration and
  # accumulate orphaned cluster-X-<epochN> siblings until the underlying
  # condition cleared.
  local new_path
  new_path=$(read_state archive_migration_pending_new_path)
  if [ -z "$new_path" ]; then
    new_path="${orig_path}-$(date +%s)"
    write_state_field_required archive_migration_pending_new_path "$new_path" || return 1
  fi

  # Previous iteration may have flipped the marker and crashed before clearing
  # stale spool statuses / pending state. Do not compute a new path; finish the
  # pending migration first so stale .ok files cannot mask missing uploads at
  # the new path.
  if [ "$PGBACKREST_REPO1_PATH" = "$new_path" ]; then
    log "wal-regression: finalizing pending archive-path migration at ${new_path}"
    finalize_archive_path_migration "$new_path"
    return $?
  fi

  log "wal-regression: migrating archive path (${PGBACKREST_REPO1_PATH} → ${new_path}); old backups preserved at former path"

  # Reset backup-tracking + recovery state BEFORE flipping the marker. If
  # this function is interrupted partway through, the next iteration sees
  # marker=OLD with last_full_at="" and re-fires migrate (reusing the
  # persisted pending new_path) instead of getting stuck half-migrated.
  # Refresh stats so last_full_failed_count anchors at the current failed
  # count — matches clear_gap_recovery_state's semantics so a re-detection
  # immediately after migrate doesn't trip on a stale 0 anchor. These writes
  # are load-bearing for the post-migrate NEEDS_INITIAL_BACKUP; if any fail,
  # abort before marker flip rather than entering the new empty path with stale
  # state.
  refresh_archiver_stats || true
  write_state_field_required last_full_failed_count "${FAILED_COUNT:-0}" || return 1
  write_state_field_required last_full_at "" || return 1
  write_state_field_required last_diff_at "" || return 1
  write_state_field_required last_lag_detected_at 0 || return 1
  write_state_field_required catalog_max_at_detection "" || return 1
  write_state_field_required last_force_recovery_at 0 || return 1
  write_state_field_required force_attempts 0 || return 1

  if ! apply_active_path "$new_path"; then
    log "wal-regression: failed to apply new archive path (${new_path}); will retry"
    return 1
  fi

  if ! finalize_archive_path_migration "$new_path"; then
    return 1
  fi

  log "wal-regression: state reset; next iteration will initialize stanza and take full backup at ${new_path}"
}

# Recovery state machine. Replaces the old "wait for grace then take a full"
# path with: detect → wait 10 min → pkill → wait 10 min → pkill → … →
# (catalog advances) → take diff → clear. Repeats pkill every backoff window
# during an extended upstream outage; the diff fires the instant the catalog
# actually advances past the detection point, which is the only conclusive
# proof async has resumed pushing to S3.
#
# Called every iteration. Idempotent: re-entering the function while already
# in recovery just advances the timers / inspects current catalog max.
#
# Returns 0 always — migration-specific backup gating is handled by
# archive_migration_pending_new_path in decide_action.
gap_recovery_step() {
  local now; now=$(date +%s)

  if finalize_pending_archive_path_migration_if_needed; then
    return 0
  fi

  local catalog_max
  catalog_max=$(probe_catalog_max)
  local probe_rc=$?
  if [ "$probe_rc" -ne 0 ]; then
    GAP_STATE_DIAG="probe-failed"

    # S3 blind-spot kick: the lag probe requires S3 reads to work. When S3 is
    # completely unreachable (e.g. Tigris outage), probe_catalog_max times out
    # on every iteration — LAST_OBSERVED_LAG_SEGMENTS stays at its stale value
    # and the normal lag-threshold path never triggers, even though the async
    # worker may be wedged on a hung PUT to the same unreachable endpoint.
    #
    # Mitigation: track how long probes have been continuously failing. If the
    # blackout exceeds GAP_RECOVERY_BACKOFF_SECONDS AND pg_stat_archiver shows
    # WAL is still being handed to the spool (ARCHIVED_COUNT grew since the
    # blackout started), pkill the async daemon. The worker's hung connection
    # will be killed; on the next WAL switch archive_command respawns the async
    # process, which will retry the upload once S3 recovers.
    #
    # This does NOT touch the gap marker or enter the full gap-recovery state
    # machine — catalog proof of S3 progress is still required to clear any
    # existing marker. This is purely a "kick the stuck process" heuristic for
    # the total-S3-outage scenario.
    local probe_fail_since probe_fail_archived
    probe_fail_since=$(read_state probe_fail_since); : "${probe_fail_since:=0}"
    probe_fail_archived=$(read_state probe_fail_archived_at_start); : "${probe_fail_archived:=0}"

    if [ "$probe_fail_since" -eq 0 ]; then
      write_state_field probe_fail_since "$now"
      write_state_field probe_fail_archived_at_start "${ARCHIVED_COUNT:-0}"
      log "gap-recovery: pgbackrest info probe failed; leaving state unchanged (probe blackout started)"
    else
      local blackout_s=$(( now - probe_fail_since ))
      local archived_grew=0
      [ "${ARCHIVED_COUNT:-0}" -gt "$probe_fail_archived" ] && archived_grew=1
      log "gap-recovery: pgbackrest info probe failed; leaving state unchanged (blackout=${blackout_s}s, archived_grew=${archived_grew})"

      if [ "$blackout_s" -ge "$GAP_RECOVERY_BACKOFF_SECONDS" ] && [ "$archived_grew" -eq 1 ]; then
        log "gap-recovery: S3 unreachable for ${blackout_s}s while postgres keeps handing WAL — kicking async daemon (blind-spot kick)"
        kick_async_daemon
        # Reset the blackout clock so we don't kick on every subsequent
        # probe-fail iteration; the next kick fires after another full backoff.
        write_state_field probe_fail_since "$now"
        write_state_field probe_fail_archived_at_start "${ARCHIVED_COUNT:-0}"
      fi
    fi
    return 0
  fi

  # Probe succeeded — reset the consecutive-failure tracking.
  write_state_field probe_fail_since 0
  write_state_field probe_fail_archived_at_start 0
  LAST_LAG_REPO_MAX="$catalog_max"

  # Lag (postgres handoff minus catalog max). 0 if either side missing.
  local lag=0
  if [ -n "$LAST_ARCHIVED_WAL" ] && [ -n "$catalog_max" ]; then
    local h_n c_n
    h_n=$(segment_to_number "$LAST_ARCHIVED_WAL")
    c_n=$(segment_to_number "$catalog_max")
    if [ -n "$h_n" ] && [ -n "$c_n" ]; then
      lag=$((h_n - c_n))
      [ "$lag" -lt 0 ] && lag=0
    fi
  fi
  LAST_OBSERVED_LAG_SEGMENTS="$lag"

  # Async-spool probe runs before any of the foreground-signal branches.
  # pgBackRest async writes a .error file when push fails; the foreground
  # only surfaces that error to pg_stat_archiver on the next archive_command
  # invocation. On a quiet DB the next invocation may be a long way off, and
  # without a foreground-side failure LAST_FAILED_WAL is NULL and the
  # downstream regression detection can't fire. Read the spool directly so
  # an async-only wedge converges in one poll cycle.
  local dup_seg
  if dup_seg=$(probe_async_duplicate_error "$catalog_max") && [ -n "$dup_seg" ]; then
    # When catalog_max is empty (LAST_ARCHIVED_WAL unset after a postgres
    # restart — exactly the post-rollback scenario this probe is designed for),
    # the probe trusts exit-45 evidence directly: a segment already present in
    # S3 at a different checksum is self-evident proof of WAL_REGRESSION.
    log "wal-regression: async spool ArchiveDuplicateError for ${dup_seg} (catalog_max=${catalog_max:-unknown}) — self-healing"
    migrate_to_new_archive_path
    return 0
  fi

  # In recovery? Marker is the truth — either we set it on a previous lag
  # detection or the archive-push wrapper touched it on a hard failure.
  if [ -f "$GAP_MARKER" ]; then
    local detected_at catalog_at_detection last_force force_attempts
    detected_at=$(read_state last_lag_detected_at); : "${detected_at:=0}"
    catalog_at_detection=$(read_state catalog_max_at_detection); : "${catalog_at_detection:=}"
    last_force=$(read_state last_force_recovery_at); : "${last_force:=0}"
    force_attempts=$(read_state force_attempts); : "${force_attempts:=0}"

    # Back-fill state when the wrapper touched the marker but the watcher
    # hasn't entered the state machine yet. Treat now as detection time and
    # the current catalog max as the baseline to beat.
    if [ "$detected_at" -eq 0 ]; then
      detected_at="$now"
      write_state_field last_lag_detected_at "$now"
    fi
    # Only write a real value; an empty catalog (fresh stanza, no archive
    # entries on this timeline yet) leaves the field unset and the back-fill
    # re-fires next iteration. Writing "" would set catalog_at_detection
    # equal to the first non-empty catalog_max captured in a later
    # iteration's back-fill, and we'd then never see a difference vs.
    # current catalog_max — recovery couldn't fire.
    if [ -z "$catalog_at_detection" ] && [ -n "$catalog_max" ]; then
      catalog_at_detection="$catalog_max"
      write_state_field catalog_max_at_detection "$catalog_at_detection"
    fi

    # Recovery proof: catalog advanced past where it was when we entered
    # the state machine. This means the async daemon successfully pushed
    # at least one segment to S3 — async is working again.
    if [ -n "$catalog_max" ] && [ -n "$catalog_at_detection" ] && [ "$catalog_max" != "$catalog_at_detection" ]; then
      local c_n_curr c_n_det
      c_n_curr=$(segment_to_number "$catalog_max")
      c_n_det=$(segment_to_number "$catalog_at_detection")
      if [ -n "$c_n_curr" ] && [ -n "$c_n_det" ] && [ "$c_n_curr" -gt "$c_n_det" ]; then
        GAP_STATE_DIAG="recovering"
        log "gap-recovery: catalog advanced (${catalog_at_detection} → ${catalog_max}, ${force_attempts} pkill cycles) — taking diff to anchor restore point"
        if run_backup diff; then
          clear_gap_recovery_state "cleared by gap-recovery diff"
          GAP_STATE_DIAG="clear"
        else
          log "gap-recovery: diff failed; retry on next iteration"
        fi
        return 0
      fi
    fi

    # No catalog advance yet. Check if it's time to kick (or kick again).
    local last_action_at="$detected_at"
    [ "$last_force" -gt "$last_action_at" ] && last_action_at="$last_force"
    local since_action=$((now - last_action_at))

    if [ "$since_action" -ge "$GAP_RECOVERY_BACKOFF_SECONDS" ]; then
      # Escape hatch: after ≥2 pkill cycles with no catalog advance, check
      # whether this is a WAL_REGRESSION. Require both active pg_stat_archiver
      # evidence and the file-specific async status code 45
      # (ArchiveDuplicateError); last_failed_wal <= catalog_max alone only
      # proves the failure is at/before the repo frontier, not that pgBackRest
      # refused to overwrite a different-checksum segment.
      #
      # Failsafe behind probe_async_duplicate_error above — which converges
      # in one poll cycle and doesn't need pg_stat_archiver to be populated
      # — so in steady state this branch is dead. It survives for timeline /
      # catalog_max mismatches where the broad spool scan skipped the file but
      # LAST_FAILED_WAL can re-probe the matching timeline explicitly.
      if [ "${force_attempts:-0}" -ge 2 ] && [ -n "$LAST_FAILED_WAL" ] \
         && [ "${LAST_FAILED_EPOCH:-0}" -gt "${LAST_ARCHIVED_EPOCH:-0}" ] \
         && wal_has_async_archive_duplicate_error "$LAST_FAILED_WAL"; then
        local wr_catalog_max
        wr_catalog_max=$(catalog_max_for_wal "$LAST_FAILED_WAL" "$catalog_max") || wr_catalog_max=""
        if [ -n "$wr_catalog_max" ]; then
          local wr_f_n wr_c_n
          wr_f_n=$(segment_to_number "$LAST_FAILED_WAL")
          wr_c_n=$(segment_to_number "$wr_catalog_max")
          if [ -n "$wr_f_n" ] && [ -n "$wr_c_n" ] && [ "$wr_f_n" -le "$wr_c_n" ]; then
            log "wal-regression: detected after ${force_attempts} pkill attempts (failed_wal=${LAST_FAILED_WAL}, catalog_max=${wr_catalog_max}) — self-healing"
            migrate_to_new_archive_path
            return 0
          fi
        fi
      fi

      force_attempts=$((force_attempts + 1))
      local stuck_min=$(( (now - detected_at) / 60 ))
      log "gap-recovery: catalog frozen at ${catalog_at_detection} for ${stuck_min}min (handoff=${LAST_ARCHIVED_WAL}, lag=${lag}) — pkill async (attempt #${force_attempts})"
      kick_async_daemon
      write_state_field last_force_recovery_at "$now"
      write_state_field force_attempts "$force_attempts"
      GAP_STATE_DIAG="forced"
    else
      # No log line during the wait — the per-iteration "iteration: no
      # action (... gap_state=waiting ...)" diagnostic at the end of
      # watcher_iteration already surfaces enough state for operators
      # without printing the same line 10× per backoff cycle.
      GAP_STATE_DIAG="waiting"
    fi
    return 0
  fi

  # Not in recovery. Two independent entry conditions, both meaning
  # "WAL coverage is diverging from the catalog":
  #   - LSN lag ≥ threshold (async wedge / queue-max-trip — postgres
  #     keeps handing off, async doesn't drain to S3)
  #   - failed_count grew since the last full's anchor (foreground hard
  #     failure — archive_command returning non-zero so postgres never
  #     hands off; lag stays at 0 but archiving is broken just the same)
  local last_full_failed; last_full_failed=$(read_state last_full_failed_count); : "${last_full_failed:=0}"
  local failed_grew=0
  [ "${FAILED_COUNT:-0}" -gt "$last_full_failed" ] && failed_grew=1

  if [ "$lag" -ge "$WAL_LAG_GAP_THRESHOLD_SEGMENTS" ] || [ "$failed_grew" -eq 1 ]; then
    # Before entering the pkill-cycle state machine, check whether this is a
    # WAL_REGRESSION: pg_stat_archiver says the current failure is for a WAL at
    # or before the catalog max on the same timeline AND the async status file
    # for that WAL reports code 45 (ArchiveDuplicateError). pkill-async cannot
    # fix a duplicate-segment conflict — it is structural, not a stuck process.
    # Self-heal immediately by migrating to a new archive path suffix. `-le`
    # (not `-lt`) covers the boundary case where rollback lands exactly at the
    # last archived segment.
    #
    # Guard: LAST_FAILED_EPOCH > LAST_ARCHIVED_EPOCH confirms the failure is
    # currently active, not a stale pg_stat_archiver.last_failed_wal from an
    # old transient error (those fields are sticky until postgres restart).
    if [ "$failed_grew" -eq 1 ] && [ -n "$LAST_FAILED_WAL" ] \
       && [ "${LAST_FAILED_EPOCH:-0}" -gt "${LAST_ARCHIVED_EPOCH:-0}" ] \
       && wal_has_async_archive_duplicate_error "$LAST_FAILED_WAL"; then
      local wr_catalog_max
      wr_catalog_max=$(catalog_max_for_wal "$LAST_FAILED_WAL" "$catalog_max") || wr_catalog_max=""
      if [ -n "$wr_catalog_max" ]; then
        local wr_f_n wr_c_n
        wr_f_n=$(segment_to_number "$LAST_FAILED_WAL")
        wr_c_n=$(segment_to_number "$wr_catalog_max")
        if [ -n "$wr_f_n" ] && [ -n "$wr_c_n" ] && [ "$wr_f_n" -le "$wr_c_n" ]; then
          log "wal-regression: detected (failed_wal=${LAST_FAILED_WAL}, catalog_max=${wr_catalog_max}, failed_count=${FAILED_COUNT:-0}) — self-healing immediately"
          migrate_to_new_archive_path
          return 0
        fi
      fi
    fi

    touch "$GAP_MARKER"
    write_state_field last_lag_detected_at "$now"
    write_state_field catalog_max_at_detection "$catalog_max"
    write_state_field last_force_recovery_at 0
    write_state_field force_attempts 0
    GAP_STATE_DIAG="detected"
    log "gap-recovery: entering recovery (lag=${lag}, failed_count=${FAILED_COUNT:-0} vs anchor ${last_full_failed}, handoff=${LAST_ARCHIVED_WAL}, catalog_max=${catalog_max}) — first pkill in ${GAP_RECOVERY_BACKOFF_SECONDS}s if catalog hasn't advanced"
  else
    GAP_STATE_DIAG="clear"
  fi
}

# Sets DECIDED_ACTION to "full"|"diff"|"" (no action). Runs in the caller's
# shell — not a subshell — so the diagnostic globals (LAST_FULL_DIAG,
# GAP_MARKER_DIAG, LAST_FULL_FAILED_DIAG) survive for watcher_iteration to
# log. Without these, a misbehaving cluster looks indistinguishable from a
# correctly-idle one in production logs.
decide_action() {
  DECIDED_ACTION=""
  local now; now=$(date +%s)
  local last_full last_diff last_full_failed
  last_full=$(read_state last_full_at)
  last_diff=$(read_state last_diff_at)
  last_full_failed=$(read_state last_full_failed_count)
  : "${last_full_failed:=0}"
  LAST_FULL_DIAG="${last_full:-empty}"
  LAST_FULL_FAILED_DIAG="$last_full_failed"
  GAP_MARKER_DIAG=$([ -f "$GAP_MARKER" ] && echo "present" || echo "absent")

  # An in-flight archive-path migration is the only condition that must block
  # backups outright: until the async daemon is stopped and stale old-path spool
  # statuses are cleaned, a stale .ok can falsely satisfy archive-push on the
  # new path. Set by the WAL_REGRESSION self-heal and by wrapper.sh's boot-time
  # re-anchor. Generic WAL gaps are not gated here — if a full/diff can succeed
  # while gap-recovery is running, that is useful signal.
  local migration_pending
  migration_pending=$(read_state archive_migration_pending_new_path)
  if [ -n "$migration_pending" ]; then
    MIGRATION_PENDING_DIAG="$migration_pending"
    return 0
  fi

  # NEEDS_INITIAL_BACKUP — no full on record, take it now. pgbackrest backup
  # brackets pg_backup_start/stop and waits for the closing WAL to archive
  # before declaring success, so a broken archive_command fails the backup
  # loudly instead of producing an unrestorable base — no need to gate on
  # "archive-push has worked once". Earlier the gate cost 60-120s of dead
  # time on idle DBs (heartbeat → archive_timeout → archive-push cycle).
  # Full-retry backoff. A full that keeps FAILING (S3 down, broken backup.info)
  # would otherwise be re-attempted every poll while last_full is empty —
  # hammering S3 with full-sized pushes. run_backup records last_full_failure_at
  # only when a full FAILS (and clears it on success), so this gates *retries*
  # of a failing full without ever delaying a full that follows a deliberate
  # last_full_at clear (fresh enable, catalog-verify rc=1, WAL_REGRESSION
  # migrate — all of which leave no fresh failure marker).
  local last_full_failure full_attempt_ok=1
  last_full_failure=$(read_state last_full_failure_at)
  if [ -n "$last_full_failure" ] \
     && [ $((now - last_full_failure)) -lt "$FULL_RETRY_BACKOFF_SECONDS" ]; then
    full_attempt_ok=0
  fi

  if [ -z "$last_full" ]; then
    if [ "$full_attempt_ok" -eq 1 ]; then DECIDED_ACTION="full"; return 0; fi
    DECIDED_ACTION=""; return 0
  fi

  # Catalog verification — periodically confirm S3 actually has a full backup.
  # Catches divergence between local state and S3 reality: the backup command
  # may have returned exit 0 without committing catalog metadata (S3 partial
  # write, stanza-create race), or a volume survived a redeployment with stale
  # state pointing at a different stanza/sysid path.
  #
  # Three outcomes (catalog_check_backup):
  #   rc=0 full present     → nothing to do.
  #   rc=1 no full present   → conclusive (info succeeded, empty backup list).
  #                            Clear last_full_at so NEEDS_INITIAL re-takes the
  #                            full. Safe to act on a single rc=1 — it's a
  #                            successful probe, so it can't be a transient.
  #   rc=2 inconclusive      → info errored (S3 hiccup, auth, or a backup.info
  #                            pgBackRest rejects). Don't clear last_full (that
  #                            would burn a full on every transient hiccup, and
  #                            transient info errors are common). Instead log
  #                            the otherwise-swallowed stderr and run an
  #                            idempotent stanza-create — cheap, and it repairs
  #                            a missing/half-written backup.info so the *next*
  #                            verify returns rc=1 and the clear path takes
  #                            over. A truly-unreachable S3 makes stanza-create
  #                            a no-op; nothing is burned.
  #
  # last_catalog_verify_at is stamped on ALL outcomes (including rc=2), so the
  # probe — and the stanza-create — run at most once per interval rather than
  # every poll. That bound is also what stops the rc=2 case from spewing a log
  # line every 60s.
  local last_catalog_verify
  last_catalog_verify=$(read_state last_catalog_verify_at)
  if [ "$CATALOG_VERIFY_INTERVAL_SECONDS" -gt 0 ] \
     && { [ -z "$last_catalog_verify" ] || [ $((now - last_catalog_verify)) -ge "$CATALOG_VERIFY_INTERVAL_SECONDS" ]; }; then
    log "verifying S3 catalog has full backup"
    catalog_check_backup
    local _crc=$?
    write_state_field last_catalog_verify_at "$now"
    if [ "$_crc" -eq 0 ]; then
      log "catalog verified — full backup present in S3"
    elif [ "$_crc" -eq 1 ]; then
      log "catalog shows no full backup despite local state (last_full=${last_full}); clearing last_full_at to trigger new full"
      write_state_field last_full_at ""
      if [ "$full_attempt_ok" -eq 1 ]; then DECIDED_ACTION="full"; return 0; fi
      DECIDED_ACTION=""; return 0
    else
      log "catalog check inconclusive (pgbackrest info errored); logging probe error (stanza-create ran this iteration)"
      log_catalog_probe_error
    fi
  fi

  # Periodic full. FULL_INTERVAL_SECONDS=0 disables the periodic full while
  # still allowing NEEDS_INITIAL_BACKUP (above) and gap-recovery to fire.
  if [ "$FULL_INTERVAL_SECONDS" -gt 0 ] \
     && [ "$now" -ge $((last_full + FULL_INTERVAL_SECONDS)) ] \
     && [ "$full_attempt_ok" -eq 1 ]; then
    DECIDED_ACTION="full"; return 0
  fi

  # Periodic diff.
  if [ "$DIFF_INTERVAL_SECONDS" -gt 0 ]; then
    local diff_anchor="${last_diff:-$last_full}"
    if [ "$now" -ge $((diff_anchor + DIFF_INTERVAL_SECONDS)) ]; then
      DECIDED_ACTION="diff"; return 0
    fi
  fi
}

# Emits one transactional commit right after a successful backup so the PITR
# picker has a commit-timestamp anchor to clamp `recovery_target_time`
# against. Without this, a brand-new cluster with a base backup but zero
# user commits leaves `pg_last_committed_xact()` and
# `pg_xact_commit_timestamp(newest_commit_ts_xid from pg_control_checkpoint())`
# both NULL — the picker has no safe ceiling and any restore target FATALs
# recovery with "recovery ended before configured recovery target was
# reached" (it only stops at XLOG_XACT_COMMIT records).
#
# transactional=true produces a real XLOG_XACT_COMMIT record with a commit
# timestamp, populates `pg_commit_ts/`, and the next checkpoint persists
# `newest_commit_ts_xid` into pg_control. The picker's GREATEST-of-two-
# sources query picks it up on the next 30s probe refresh.
#
# Idempotent: every subsequent backup re-fires the emit. If the cluster
# already has user commits, the extra anchor is invisible noise (one trivial
# transaction, no table side effect). Failure is non-fatal — `pg_logical_emit_message`
# only fails on a postmaster shutdown or a write barrier, in which case the
# next iteration's backup will retry.
emit_pitr_anchor() {
  psql -U "${PGUSER:-postgres}" -tAXq -c \
    "SELECT pg_logical_emit_message(true, 'rwy_pitr_anchor', '')" \
    >/dev/null 2>&1 \
    && log "pitr anchor emitted" \
    || log "pitr anchor emit failed (non-fatal)"
}

# Emits a few bytes of WAL with no table side-effects so archive_timeout=60
# has something to flush on idle DBs. transactional=false bypasses txn
# context — non-blocking, cheap. Failure is non-fatal: a temporarily blocked
# emit just postpones the next segment switch by one tick.
emit_wal_heartbeat() {
  [ "${WAL_HEARTBEAT_DISABLED:-0}" = "1" ] && return 0
  psql -U "${PGUSER:-postgres}" -tAXq -c \
    "SELECT pg_logical_emit_message(false, 'rwy_pitr_heartbeat', '')" \
    >/dev/null 2>&1 || true
}

watcher_iteration() {
  if ! pg_isready -h 127.0.0.1 -p 5432 -U "${PGUSER:-postgres}" -q 2>/dev/null; then
    log "iteration skipped: pg_isready=fail (postgres not yet listening on TCP)"
    return 0
  fi
  if is_standby; then
    log "iteration skipped: standby"
    return 0
  fi

  emit_wal_heartbeat

  if ! refresh_archiver_stats; then
    log "iteration skipped: pg_stat_archiver query failed (transient psql error)"
    return 0
  fi

  # Cache wal_segment_size for segment_to_number's per-XLogId divisor.
  # Cheap (local psql round-trip) so we re-read every iteration to handle
  # the very-rare case of failing over onto a cluster with a different
  # segsize. Failure leaves the previous value in place; the watcher
  # never sees an arithmetic crash from a missing global.
  refresh_wal_segment_size || true

  # Idempotent stanza health — every iteration. A no-op (2 S3 reads) when the
  # stanza is healthy; repairs a missing or corrupt backup.info on the spot.
  # Running every iteration means a broken stanza is fixed on the next poll
  # rather than waiting up to CATALOG_VERIFY_INTERVAL_SECONDS.
  stanza_create_step

  # Gap-recovery state machine — detects WAL/catalog divergence and drives
  # the kick-and-diff sequence. Runs every iteration; pgbackrest info is
  # cheap enough that throttling isn't worth the false-negative window the
  # earlier throttled version introduced.
  gap_recovery_step

  decide_action
  if [ -z "$DECIDED_ACTION" ]; then
    # Surface why decide_action stayed silent so post-mortems on "watcher
    # ran for N minutes and never took a backup" don't require guessing.
    log "iteration: no action (last_full=${LAST_FULL_DIAG:-?}, archived=${ARCHIVED_COUNT:-?}, failed=${FAILED_COUNT:-?}, gap_marker=${GAP_MARKER_DIAG:-?}, gap_state=${GAP_STATE_DIAG:-?}, last_full_failed=${LAST_FULL_FAILED_DIAG:-?}, lag=${LAST_OBSERVED_LAG_SEGMENTS:-?}, migration_pending=${MIGRATION_PENDING_DIAG:-none})"
    return 0
  fi

  run_backup "$DECIDED_ACTION" || true
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

# Convert a state file written by the pre-generalization field names before any
# reader touches it. Non-fatal: a failure here leaves the legacy names in
# place, which reads as "no migration pending" — the same state a fresh volume
# starts in, and one the WAL_REGRESSION probe re-detects from the .error files
# that caused it.
migrate_legacy_state_field_names \
  || log "state: could not rename legacy wal_regression_* fields; continuing"

log "starting (poll=${POLL_INTERVAL_SECONDS}s, initial_poll=${INITIAL_POLL_SECONDS}s, full=${FULL_INTERVAL_SECONDS}s, diff=${DIFF_INTERVAL_SECONDS}s, gap_backoff=${GAP_RECOVERY_BACKOFF_SECONDS}s, lag_threshold=${WAL_LAG_GAP_THRESHOLD_SEGMENTS} segments, repo1-path=${PGBACKREST_REPO1_PATH:-unset})"

# Crash-isolate each iteration in a subshell so a future refactor accident
# (set -u trip on an unbound var, an unexpected non-zero exit, a libpq
# environment quirk, …) doesn't terminate the outer loop. The state file +
# .pgbackrest_gap_pending live on disk and survive across iterations, so a
# subshell that exits mid-recovery just resumes on the next tick. This is
# the watcher's own supervisor — keeping it inside the script (rather than
# in wrapper.sh) means the watcher's long-lived PID (the bash interpreter
# running this loop) stays pinned; only the transient iteration subshell
# churns through PIDs, and each subshell lives a few seconds. With the
# old wrapper.sh-side `while true; do gosu watcher; done` supervisor, the
# watcher's long-lived PID cycled through the same range where postgres
# lands on container start, which raced postgres's stale-postmaster.pid
# check (PID 45 from a phase-1 SIGKILL collided with a phase-2 watcher
# respawn at the same number, postgres saw it as a live postmaster and
# FATAL'd). Pinning the watcher main PID makes that race impossible.
while true; do
  (
    sync_repo_path_from_marker
    watcher_iteration
  ) || log "iteration subshell exited non-zero, continuing"
  if [ -z "$(read_state last_full_at)" ]; then
    sleep "$INITIAL_POLL_SECONDS"
  else
    sleep "$POLL_INTERVAL_SECONDS"
  fi
done
