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
# Gated on WAL_ARCHIVE_BUCKET — "does this service archive outgoing WAL?".
# Skips when unset (vanilla services, restored services that haven't re-
# enabled PITR).
#
# /etc/pgbackrest/pgbackrest.conf is rendered by wrapper.sh and is already
# in place by the time this script runs.
#
# This handles the fresh-DB path. wrapper.sh handles the existing-DB path
# (idempotent reapply), the disable path, and the recovery-target path.
# Runs as the postgres user inside docker-entrypoint's gosu context — no
# chown is needed because every file we create is postgres-owned by default.

set -e

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

# Write the per-cluster repo-path marker now that pg_control exists. Doing
# it here (during initdb's post-initdb hook phase, BEFORE the real postmaster
# launches) means the very first archive_command invocation reads the
# correct PGBACKREST_REPO1_PATH from the marker — no race with the bootstrap
# subshell in wrapper.sh, no archive-push fired against the wrong path.
if [ ! -f "$PGDATA/.pgbackrest_repo_path" ] && [ -f "$PGDATA/global/pg_control" ]; then
  sysid=$(pg_controldata "$PGDATA" 2>/dev/null \
    | awk -F: '/Database system identifier/ { gsub(/[ \t]/,"",$2); print $2 }')
  if [ -n "$sysid" ]; then
    cluster_path="${WAL_ARCHIVE_PATH:-/pgbackrest}/cluster-${sysid}"
    echo "$cluster_path" > "$PGDATA/.pgbackrest_repo_path"
    chmod 0640 "$PGDATA/.pgbackrest_repo_path"
    echo "pgbackrest: per-cluster repo path = ${cluster_path}"
  fi
fi
