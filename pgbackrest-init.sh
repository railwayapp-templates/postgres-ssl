#!/bin/bash
# pgbackrest-init.sh — runs once during initdb from /docker-entrypoint-initdb.d/.
#
# When PGBACKREST_REPO1_S3_BUCKET is set, writes archive config to
# postgresql.auto.conf so a freshly initialized DB starts with pgBackRest
# archiving on. The pgbackrest.conf file is rendered by wrapper.sh and is
# already in place by the time this script runs.
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

archive_timeout="${POSTGRES_ARCHIVE_TIMEOUT:-60}"
cat >> "$PGDATA/postgresql.auto.conf" <<EOF
# pgbackrest-config-begin (managed by pgbackrest-init.sh)
archive_mode = 'on'
archive_command = '/usr/local/bin/pgbackrest-archive-push-wrapper.sh %p'
archive_timeout = '${archive_timeout}'
restore_command = 'pgbackrest --stanza=main archive-get %f %p'
# pgbackrest-config-end
EOF

# Stamp the source repo path so a future PITR-restored volume can detect
# whether the operator pivoted PGBACKREST_REPO1_PATH before staging recovery
# (see configure_pgbackrest_recovery in wrapper.sh).
printf '%s' "${PGBACKREST_REPO1_PATH:-}" > "$PGDATA/.pgbackrest_source_path"

echo "pgbackrest: archive config written to postgresql.auto.conf during initdb"
