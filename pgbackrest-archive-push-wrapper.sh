#!/bin/bash
# pgbackrest-archive-push-wrapper.sh — invoked by Postgres as archive_command.
#
# Wraps `pgbackrest archive-push` so that any kind of archive failure (hard
# repo error, stuck async worker, anything else) cannot fill pg_wal/ and halt
# Postgres. When pgbackrest fails AND pg_wal/ has grown past a threshold
# (default 5 GiB, override via PGBACKREST_DROP_THRESHOLD_GIB), the wrapper
# returns success to Postgres anyway. Postgres recycles the WAL segment as
# if archiving were disabled. The PITR window gets a coverage gap from this
# segment forward; the dashboard reads pg_stat_archiver to surface "PITR
# broken — fix archiving config" so the underlying issue (bad creds, deleted
# bucket, expired keys, …) gets fixed.
#
# 5 GiB matches pgBackRest's own archive-push-queue-max in the spool path:
# both failure regimes (queueable S3 stalls; unqueueable hard errors) get
# the same WAL-budget ceiling before we trade coverage for availability.
#
# Below the threshold the wrapper surfaces pgbackrest's failure to Postgres
# normally, so transient S3 issues retry on the next archive_timeout instead
# of being silently dropped.
#
# Cost of `du -sb $PGDATA/pg_wal` here: only fires when archive-push fails.
# Under normal operation pgbackrest succeeds in async mode (segment written
# to spool, returns in milliseconds) and the wrapper exits before du runs.
# When pgbackrest IS failing, archive_command retries on every WAL switch
# (default archive_timeout=60s) — and pg_wal has by definition stopped
# being recycled, so it's a few hundred segments at most. A directory
# traversal of a few hundred small files every minute is the cheapest
# thing happening on this host while S3 is unreachable. Not worth caching.

set -u

WAL_FILE="${1:-}"
if [ -z "$WAL_FILE" ]; then
  echo "pgbackrest-wrapper: missing WAL file argument" >&2
  exit 1
fi

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
PGWAL_THRESHOLD_GIB="${PGBACKREST_DROP_THRESHOLD_GIB:-5}"
PGWAL_THRESHOLD_BYTES=$(( PGWAL_THRESHOLD_GIB * 1024 * 1024 * 1024 ))

pgbackrest --stanza=main archive-push "$WAL_FILE"
PGB_RC=$?
if [ "$PGB_RC" -eq 0 ]; then
  exit 0
fi

PGWAL_BYTES=$(du -sb "$PGDATA/pg_wal" 2>/dev/null | awk '{print $1}')
if [ -z "${PGWAL_BYTES:-}" ]; then
  exit "$PGB_RC"
fi

if [ "$PGWAL_BYTES" -ge "$PGWAL_THRESHOLD_BYTES" ]; then
  PGWAL_GIB=$(( PGWAL_BYTES / 1024 / 1024 / 1024 ))
  echo "pgbackrest-wrapper: pg_wal at ${PGWAL_GIB} GiB (threshold ${PGWAL_THRESHOLD_GIB} GiB) and archive-push failing; dropping ${WAL_FILE} to keep Postgres up" >&2
  exit 0
fi

exit "$PGB_RC"
