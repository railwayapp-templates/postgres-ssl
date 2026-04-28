#!/bin/bash
# pgbackrest-helpers.sh — shared functions for wrapper.sh (root, every boot)
# and pgbackrest-init.sh (postgres user, during initdb on fresh DB).
#
# Sourced, never executed. Defines path constants and idempotent helpers
# that touch state both scripts manage in common (spool dir, conf.d include
# directive, archive conf, source-path sentinel).
#
# All file/dir creation helpers chown to postgres:postgres when running as
# root, and skip the chown otherwise — pgbackrest-init.sh already runs as
# the postgres user, so created files are postgres-owned without a chown,
# and postgres can't chown to other uids anyway.

# Path constants — used by both scripts and wrapper.sh's PITR/disable paths.
PGBACKREST_CONF_FILE="/etc/pgbackrest/pgbackrest.conf"
PGBACKREST_CONFD_DIR="$PGDATA/conf.d"
PGBACKREST_ARCHIVE_CONF="$PGBACKREST_CONFD_DIR/pgbackrest.conf"
PGBACKREST_RECOVERY_CONF="$PGBACKREST_CONFD_DIR/pgbackrest-recovery.conf"
SOURCE_PATH_SENTINEL_FILE="$PGDATA/.pgbackrest_source_path"
PITR_STAGING_FILE="$PGDATA/.pitr_staging"
PITR_DONE_MARKER="$PGDATA/.pitr_configured"
PGBACKREST_SPOOL_DIR="$PGDATA/pgbackrest-spool"
PGBACKREST_INCLUDE_DIRECTIVE="include_dir = 'conf.d'"

# Set ownership to postgres:postgres only when running as root. As the
# postgres user, files we create are already postgres-owned, and we can't
# chown to other uids regardless.
chown_postgres_if_root() {
  if [ "$(id -u)" = "0" ]; then
    chown postgres:postgres "$@"
  fi
}

# Spool lives on the volume so segments staged but not yet pushed to S3
# survive container restarts — Postgres has already advanced restart_lsn
# after archive_command returned 0 to it, so anything still in spool would
# be silently lost on an image-layer mount.
ensure_pgbackrest_spool_dir() {
  mkdir -p "$PGBACKREST_SPOOL_DIR"
  chmod 0750 "$PGBACKREST_SPOOL_DIR"
  chown_postgres_if_root "$PGBACKREST_SPOOL_DIR"
}

# Add `include_dir = 'conf.d'` to postgresql.conf if not already present.
# postgresql.conf is not rewritten by Postgres at runtime (only auto.conf is,
# by ALTER SYSTEM), so this single line is durable. Files in conf.d/ load
# after postgresql.conf and before postgresql.auto.conf, so a user
# `ALTER SYSTEM SET archive_mode = 'off'` still wins — which is the right
# semantics: env vars are the dashboard-visible source of truth, but a
# determined operator can override at the Postgres layer and the dashboard
# will surface the divergence.
ensure_pg_includes_confd() {
  local pgconf="$PGDATA/postgresql.conf"
  [ ! -f "$pgconf" ] && return 0
  if grep -qE "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'conf\.d'" "$pgconf"; then
    return 0
  fi
  echo "$PGBACKREST_INCLUDE_DIRECTIVE" >> "$pgconf"
  echo "pgbackrest: enabled include_dir 'conf.d' in postgresql.conf"
}

ensure_pgbackrest_confd_dir() {
  mkdir -p "$PGBACKREST_CONFD_DIR"
  chmod 0750 "$PGBACKREST_CONFD_DIR"
  chown_postgres_if_root "$PGBACKREST_CONFD_DIR"
}

# Write archive config to conf.d/pgbackrest.conf. Idempotent.
# Caller is responsible for guarding on PGBACKREST_REPO1_S3_BUCKET.
write_pgbackrest_archive_conf() {
  ensure_pgbackrest_confd_dir
  local archive_timeout="${POSTGRES_ARCHIVE_TIMEOUT:-60}"
  cat > "$PGBACKREST_ARCHIVE_CONF" <<EOF
archive_mode = 'on'
archive_command = '/usr/local/bin/pgbackrest-archive-push-wrapper.sh %p'
archive_timeout = '${archive_timeout}'
EOF
  chmod 0640 "$PGBACKREST_ARCHIVE_CONF"
  chown_postgres_if_root "$PGBACKREST_ARCHIVE_CONF"
  echo "pgbackrest: wrote ${PGBACKREST_ARCHIVE_CONF}"
}

# Record the current PGBACKREST_REPO1_PATH to the source-path sentinel.
# A future PITR-restored volume reads this to detect whether the operator
# pivoted PGBACKREST_REPO1_PATH before staging recovery.
stamp_source_repo_path() {
  printf '%s' "${PGBACKREST_REPO1_PATH:-}" > "$SOURCE_PATH_SENTINEL_FILE"
  chown_postgres_if_root "$SOURCE_PATH_SENTINEL_FILE"
}
