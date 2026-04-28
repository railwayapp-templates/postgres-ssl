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
# Runs as the postgres user inside docker-entrypoint's gosu context — no
# chown is needed because every file we create is postgres-owned by default.

set -e

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

# Stamp the source repo path so a future PITR-restored volume can detect
# whether the operator pivoted PGBACKREST_REPO1_PATH before staging recovery
# (see configure_pgbackrest_recovery in wrapper.sh).
printf '%s' "${PGBACKREST_REPO1_PATH:-}" > "$PGDATA/.pgbackrest_source_path"

echo "pgbackrest: archive config written to ${PGDATA}/conf.d/pgbackrest.conf during initdb"
