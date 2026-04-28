#!/bin/bash
# pgbackrest-init.sh — runs once during initdb from /docker-entrypoint-initdb.d/.
#
# When the service has its own archive bucket (`WAL_ARCHIVE_BUCKET` set),
# writes archive config to $PGDATA/conf.d/pgbackrest.conf and adds
# `include_dir = 'conf.d'` to postgresql.conf so a freshly initialized DB
# starts with archiving on. Never write to postgresql.auto.conf — ALTER
# SYSTEM rewrites it and would clobber any sentinel-bracketed block we used
# to scope a managed section, breaking clean disable.
#
# Restored services have only WAL_RECOVER_FROM_* (no archive bucket of their
# own); they skip this path entirely so a wiped volume's fresh initdb
# doesn't accidentally start writing archive_command into the source's
# bucket via the wrapper's translation of WAL_RECOVER_FROM_* to REPO1.
#
# /etc/pgbackrest/pgbackrest.conf is rendered by wrapper.sh and is already
# in place by the time this script runs.
#
# This handles the fresh-DB path. wrapper.sh handles the existing-DB path
# (idempotent reapply), the disable path, and the recovery-target path.
# Runs as the postgres user inside docker-entrypoint's gosu context — no
# chown is needed because every file we create is postgres-owned by default.

set -e

# Stamp a marker the wrapper uses to detect "this volume was just initdb'd
# fresh, not restored from a snapshot." Without it, a wiped volume on a
# restored service still has WAL_RECOVER_FROM_* + POSTGRES_RECOVERY_TARGET_TIME
# set, the wrapper would arm archive recovery, restore_command would fetch
# source WAL whose system_identifier doesn't match the freshly-init'd cluster,
# and Postgres would refuse to start. With this marker, the wrapper sees fresh
# init and silently skips arming recovery, letting Postgres start as a normal
# fresh DB — graceful behavior on accidental wipe.
touch "$PGDATA/.fresh_initdb"

if [ -z "${WAL_ARCHIVE_BUCKET:-}" ]; then
  exit 0
fi

# Spool lives on the volume so segments staged but not yet pushed to S3
# survive container restarts.
mkdir -p "$PGDATA/pgbackrest-spool"
chmod 0750 "$PGDATA/pgbackrest-spool"

# Add the include directive once. postgresql.conf is not rewritten by
# Postgres at runtime (only auto.conf is, by ALTER SYSTEM), so this single
# line is durable. Regex tolerates single-quoted, double-quoted, and
# unquoted forms — postgresql.conf treats them as equivalent.
if ! grep -qE "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*['\"]?conf\.d['\"]?[[:space:]]*$" "$PGDATA/postgresql.conf"; then
  echo "include_dir = 'conf.d'" >> "$PGDATA/postgresql.conf"
fi

mkdir -p "$PGDATA/conf.d"
chmod 0750 "$PGDATA/conf.d"

archive_timeout="${POSTGRES_ARCHIVE_TIMEOUT:-60}"
cat > "$PGDATA/conf.d/pgbackrest.conf" <<EOF
archive_mode = 'on'
archive_command = '/usr/local/bin/pgbackrest-archive-push-wrapper.sh %p'
archive_timeout = '${archive_timeout}'
EOF
chmod 0640 "$PGDATA/conf.d/pgbackrest.conf"

echo "pgbackrest: archive config written to ${PGDATA}/conf.d/pgbackrest.conf during initdb"
