#!/bin/bash
# pgbackrest-init.sh — runs once during initdb from /docker-entrypoint-initdb.d/.
#
# When PGBACKREST_REPO1_S3_BUCKET is set, writes archive config to
# $PGDATA/conf.d/pgbackrest.conf and adds `include_dir = 'conf.d'` to
# postgresql.conf so a freshly initialized DB starts with pgBackRest
# archiving on. We never write to postgresql.auto.conf — ALTER SYSTEM
# rewrites it and would strip any sentinel comments we used to scope a
# managed block, breaking clean disable.
#
# The pgbackrest.conf file at /etc/pgbackrest/ is rendered by wrapper.sh
# and is already in place by the time this script runs.
#
# This handles the fresh-DB path. wrapper.sh handles the existing-DB path
# (idempotent reapply), the disable path, and the recovery-target path.

set -e

if [ -z "$PGBACKREST_REPO1_S3_BUCKET" ]; then
  exit 0
fi

# Spool lives on the volume so segments staged but not yet pushed to S3
# survive container restarts. wrapper.sh creates this on subsequent boots;
# at fresh-init time PGDATA exists but the spool dir doesn't, so create it
# here. This script runs as the postgres user, which is what pgbackrest
# runs as too — no chown needed.
mkdir -p "$PGDATA/pgbackrest-spool"
chmod 0750 "$PGDATA/pgbackrest-spool"

# Add the include directive once. postgresql.conf is not rewritten by
# Postgres at runtime (only auto.conf is, by ALTER SYSTEM), so this single
# line is durable.
if ! grep -qE "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'conf\.d'" "$PGDATA/postgresql.conf"; then
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

# Stamp the source repo path so a future PITR-restored volume can detect
# whether the operator pivoted PGBACKREST_REPO1_PATH before staging recovery
# (see configure_pgbackrest_recovery in wrapper.sh).
printf '%s' "${PGBACKREST_REPO1_PATH:-}" > "$PGDATA/.pgbackrest_source_path"

echo "pgbackrest: archive config written to ${PGDATA}/conf.d/pgbackrest.conf during initdb"
