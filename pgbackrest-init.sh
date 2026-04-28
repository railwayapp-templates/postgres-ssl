#!/bin/bash
# pgbackrest-init.sh — runs once during initdb from /docker-entrypoint-initdb.d/.
#
# When PGBACKREST_REPO1_S3_BUCKET is set, writes archive config to
# $PGDATA/conf.d/pgbackrest.conf and adds `include_dir = 'conf.d'` to
# postgresql.conf so a freshly initialized DB starts with pgBackRest
# archiving on. We never write to postgresql.auto.conf — ALTER SYSTEM
# rewrites it and would clobber any sentinel-bracketed block we used to
# scope a managed section, breaking clean disable.
#
# /etc/pgbackrest/pgbackrest.conf is rendered by wrapper.sh and is already
# in place by the time this script runs.
#
# This handles the fresh-DB path. wrapper.sh handles the existing-DB path
# (idempotent reapply), the disable path, and the recovery-target path.

set -e
. /usr/local/bin/pgbackrest-helpers.sh

if [ -z "$PGBACKREST_REPO1_S3_BUCKET" ]; then
  exit 0
fi

# PITR replays WAL onto an existing base. Setting POSTGRES_RECOVERY_TARGET_TIME
# while initdb is creating a brand-new DB is a footgun — the target would be
# silently ignored on this boot, then on the next boot the divergence check
# in wrapper.sh would refuse to start (because we just stamped the source path
# to the current write path). Fail loudly here instead.
if [ -n "$POSTGRES_RECOVERY_TARGET_TIME" ]; then
  echo "pgbackrest: REFUSING to initialize a fresh database with POSTGRES_RECOVERY_TARGET_TIME set." >&2
  echo "pgbackrest: PITR replays WAL onto a base snapshot. Restore the volume from a base snapshot first," >&2
  echo "pgbackrest: or unset POSTGRES_RECOVERY_TARGET_TIME to initialize a fresh database." >&2
  exit 1
fi

ensure_pgbackrest_spool_dir
ensure_pg_includes_confd
write_pgbackrest_archive_conf
stamp_source_repo_path

echo "pgbackrest: archive config written to ${PGBACKREST_ARCHIVE_CONF} during initdb"
