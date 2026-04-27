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

cat >> "$PGDATA/postgresql.auto.conf" <<'EOF'
# pgbackrest-config-begin (managed by pgbackrest-init.sh)
archive_mode = 'on'
archive_command = '/usr/local/bin/pgbackrest-archive-push-wrapper.sh %p'
archive_timeout = '60'
restore_command = 'pgbackrest --stanza=main archive-get %f %p'
# pgbackrest-config-end
EOF

echo "pgbackrest: archive config written to postgresql.auto.conf during initdb"
