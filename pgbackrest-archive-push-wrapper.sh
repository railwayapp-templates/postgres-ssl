#!/bin/bash
# pgbackrest-archive-push-wrapper.sh — invoked by Postgres as archive_command.
#
# Wraps `pgbackrest archive-push` so that any kind of archive failure (hard
# repo error, stuck async worker, anything else) cannot fill pg_wal/ and halt
# Postgres. When pgbackrest fails AND pg_wal/ has grown past a threshold
# (default 500 MiB, override via WAL_DROP_THRESHOLD_MB), the wrapper returns
# success to Postgres anyway. Postgres recycles the WAL segment as if
# archiving were disabled. The PITR window gets a coverage gap from this
# segment forward; below the threshold pg_stat_archiver.failed_count climbs
# normally and the dashboard surfaces "PITR broken — fix archiving config",
# so the underlying issue (bad creds, deleted bucket, expired keys, …) gets
# fixed before the threshold trips and the failure signal disappears.
#
# The env var name avoids the PGBACKREST_* prefix on purpose: pgBackRest
# treats every PGBACKREST_* variable as a config option and warns about
# unknown names on every invocation. WAL_DROP_THRESHOLD_MB sits outside
# that namespace so it doesn't pollute logs.
#
# Why 500 MiB here, vs pgBackRest's archive-push-queue-max=5GiB:
# the two thresholds gate orthogonal failure regimes. archive-push-queue-max
# governs the SPOOL — graceful absorption of transient S3 stalls, where the
# async worker keeps retrying and most segments eventually get pushed. A
# generous buffer there absorbs hours of outage cleanly. This wrapper-side
# threshold gates the HARD-FAILURE path: bad creds, deleted bucket, expired
# keys — pgbackrest's foreground returns non-zero immediately and there's
# no realistic chance the next retry succeeds without operator intervention.
# Holding 5 GiB of pg_wal hostage waiting for a fix that requires a config
# change wastes data-volume disk; 500 MiB is enough to ride out a multi-
# minute config-redeploy window without eating into customer disk budgets.
#
# Below the threshold the wrapper surfaces pgbackrest's failure to Postgres
# normally, so transient errors retry on the next archive_timeout instead
# of being silently dropped.
#
# Cost of `du -sb $PGDATA/pg_wal` here: only fires when archive-push fails.
# Under normal operation pgbackrest succeeds in async mode (segment written
# to spool, returns in milliseconds) and the wrapper exits before du runs.
# When pgbackrest IS failing, archive_command retries on every WAL switch
# (default archive_timeout=60s) — and pg_wal has by definition stopped
# being recycled, so it's a few dozen segments at most. A directory
# traversal of a few dozen small files every minute is the cheapest
# thing happening on this host while S3 is unreachable. Not worth caching.

set -u

WAL_FILE="${1:-}"
if [ -z "$WAL_FILE" ]; then
  echo "pgbackrest-wrapper: missing WAL file argument" >&2
  exit 1
fi

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
PGWAL_THRESHOLD_MB="${WAL_DROP_THRESHOLD_MB:-500}"
PGWAL_THRESHOLD_BYTES=$(( PGWAL_THRESHOLD_MB * 1024 * 1024 ))

# Per-cluster repo-path: read the marker written by pgbackrest-init.sh /
# wrapper.sh's bootstrap subshell. Without this, every archive-push would
# go to the legacy ${WAL_ARCHIVE_PATH} root and a wipe-and-reuse-bucket
# scenario would collide on stanza identity. With it, fresh clusters land
# at ${WAL_ARCHIVE_PATH}/cluster-<sysid>; existing clusters whose marker
# was written to the legacy path keep using it (backward compat).
if [ -f "$PGDATA/.pgbackrest_repo_path" ]; then
  PGBACKREST_REPO1_PATH=$(cat "$PGDATA/.pgbackrest_repo_path")
  export PGBACKREST_REPO1_PATH
fi

# Pin archive-push to repo1 unconditionally. REPO1 is always this service's
# own destination bucket (invariant set in wrapper.sh's env translation).
# On a fork, repo2 is the source's read-only bucket — pgBackRest's default
# archive-push targets all configured repos, so without the pin the fork
# would spray its post-promote WAL into source's bucket.
pgbackrest --stanza=main --repo=1 archive-push "$WAL_FILE"
PGB_RC=$?
if [ "$PGB_RC" -eq 0 ]; then
  exit 0
fi

PGWAL_BYTES=$(du -sb "$PGDATA/pg_wal" 2>/dev/null | awk '{print $1}')
if [ -z "${PGWAL_BYTES:-}" ]; then
  exit "$PGB_RC"
fi

if [ "$PGWAL_BYTES" -ge "$PGWAL_THRESHOLD_BYTES" ]; then
  PGWAL_MB=$(( PGWAL_BYTES / 1024 / 1024 ))
  echo "pgbackrest-wrapper: pg_wal at ${PGWAL_MB} MiB (threshold ${PGWAL_THRESHOLD_MB} MiB) and archive-push failing; dropping ${WAL_FILE} to keep Postgres up" >&2
  # Signal to pgbackrest-backup-watcher.sh that a gap was just created. The
  # watcher takes a fresh full backup once archiving recovers, sealing the
  # gap forward (the dropped segment itself is unrestorable, as before).
  touch "$PGDATA/.pgbackrest_gap_pending" 2>/dev/null || true
  exit 0
fi

exit "$PGB_RC"
