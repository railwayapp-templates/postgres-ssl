#!/bin/bash

# exit as soon as any of these commands fail, this prevents starting a database without certificates or with the wrong volume mount path
set -e

EXPECTED_VOLUME_MOUNT_PATH="/var/lib/postgresql/data"

# check if the Railway volume is mounted to the correct path
# we do this by checking the current mount path (RAILWAY_VOLUME_MOUNT_PATH) agiant the expected mount path
# if the paths are different, we print an error message and exit
# only perform this check if this image is deployed to Railway by checking for the existence of the RAILWAY_ENVIRONMENT variable
if [ -n "$RAILWAY_ENVIRONMENT" ] && [ "$RAILWAY_VOLUME_MOUNT_PATH" != "$EXPECTED_VOLUME_MOUNT_PATH" ]; then
  echo "Railway volume not mounted to the correct path, expected $EXPECTED_VOLUME_MOUNT_PATH but got $RAILWAY_VOLUME_MOUNT_PATH"
  echo "Please update the volume mount path to the expected path and redeploy the service"
  exit 1
fi

# check if PGDATA starts with the expected volume mount path
# this ensures data files are stored in the correct location
# if not, print error and exit to prevent data loss or access issues
if [[ ! "$PGDATA" =~ ^"$EXPECTED_VOLUME_MOUNT_PATH" ]]; then
  echo "PGDATA variable does not start with the expected volume mount path, expected to start with $EXPECTED_VOLUME_MOUNT_PATH"
  echo "Please update the PGDATA variable to start with the expected volume mount path and redeploy the service"
  exit 1
fi

# Set up needed variables
SSL_DIR="/var/lib/postgresql/data/certs"
INIT_SSL_SCRIPT="/docker-entrypoint-initdb.d/init-ssl.sh"
POSTGRES_CONF_FILE="$PGDATA/postgresql.conf"

# Regenerate if the certificate is not a x509v3 certificate
if [ -f "$SSL_DIR/server.crt" ] && ! openssl x509 -noout -text -in "$SSL_DIR/server.crt" | grep -q "DNS:localhost"; then
  echo "Did not find a x509v3 certificate, regenerating certificates..."
  bash "$INIT_SSL_SCRIPT"
fi

# Regenerate if the certificate has expired or will expire
# 2592000 seconds = 30 days
if [ -f "$SSL_DIR/server.crt" ] && ! openssl x509 -checkend 2592000 -noout -in "$SSL_DIR/server.crt"; then
  echo "Certificate has or will expire soon, regenerating certificates..."
  bash "$INIT_SSL_SCRIPT"
fi

# Generate a certificate if the database was initialized but is missing a certificate
# Useful when going from the base postgres image to this ssl image
if [ -f "$POSTGRES_CONF_FILE" ] && [ ! -f "$SSL_DIR/server.crt" ]; then
  echo "Database initialized without certificate, generating certificates..."
  bash "$INIT_SSL_SCRIPT"
fi

# Adds pg_stat_statements to shared_preload_libraries in a config file
# Usage: add_pg_stat_statements <config_file>
add_pg_stat_statements() {
  local config_file="$1"
  local current_libs
  # Extract value - handles quoted ('val', "val") and unquoted (val) formats
  current_libs=$(grep -E "^[[:space:]]*shared_preload_libraries" "$config_file" 2>/dev/null | tail -1 | sed "s/.*=[[:space:]]*//; s/^['\"]//; s/['\"].*$//; s/[[:space:]]*$//")
  if [ -n "$current_libs" ]; then
    echo "shared_preload_libraries = '${current_libs},pg_stat_statements'" >> "$config_file"
  else
    echo "shared_preload_libraries = 'pg_stat_statements'" >> "$config_file"
  fi
}

# Ensure pg_stat_statements is in shared_preload_libraries for existing databases
# This handles databases created before this setting was added
AUTO_CONF_FILE="$PGDATA/postgresql.auto.conf"
if [ -f "$POSTGRES_CONF_FILE" ] && ! grep -q "pg_stat_statements" "$POSTGRES_CONF_FILE"; then
  echo "Adding pg_stat_statements to shared_preload_libraries..."
  add_pg_stat_statements "$POSTGRES_CONF_FILE"
  # Only update auto.conf if it has shared_preload_libraries set (which would override postgresql.conf)
  # and doesn't already have pg_stat_statements
  if grep -q "^[[:space:]]*shared_preload_libraries" "$AUTO_CONF_FILE" 2>/dev/null && ! grep -q "pg_stat_statements" "$AUTO_CONF_FILE" 2>/dev/null; then
    add_pg_stat_statements "$AUTO_CONF_FILE"
  fi
fi

# -----------------------------------------------------------------------------
# Opt-in pgBackRest WAL archiving + PITR
#
# All helpers are no-ops unless PGBACKREST_REPO1_S3_BUCKET is set, so the
# image behaves identically to pre-pgBackRest releases when unused.
#
# Three storage tiers absorb backup backpressure so Postgres never halts:
#   1. Local spool dir (/var/lib/postgresql/pgbackrest-spool, ~few GiB)
#   2. (future) dedicated backup service WAL volume — not in this image
#   3. S3 (the configured repo)
#
# pgBackRest is run in async mode: archive_command writes WAL into the spool
# dir and returns in milliseconds; a background worker pushes to S3. When
# archive-push-queue-max trips, pgBackRest drops WAL and tells Postgres the
# push succeeded, keeping Postgres running. PITR window truncates; DB stays up.
# -----------------------------------------------------------------------------

PGBACKREST_CONF_FILE="/etc/pgbackrest/pgbackrest.conf"

# Render /etc/pgbackrest/pgbackrest.conf with operator-policy defaults +
# stanza definition (pg1-path, pg1-port). User-supplied options (S3 bucket,
# region, key, secret, endpoint, repo path) are read by pgBackRest natively
# from PGBACKREST_* env vars, so they don't need to be in the conf file.
# Idempotent: rewritten on every boot when the gate var is set.
render_pgbackrest_conf() {
  [ -z "$PGBACKREST_REPO1_S3_BUCKET" ] && return 0

  mkdir -p /etc/pgbackrest
  cat > "$PGBACKREST_CONF_FILE" <<EOF
[global]
repo1-type=s3
repo1-retention-full=2
repo1-retention-diff=4
repo1-retention-archive=14
repo1-retention-archive-type=incr
log-level-console=info
log-level-file=off
archive-async=y
archive-push-queue-max=5GiB
archive-get-queue-max=1GiB
spool-path=/var/lib/postgresql/pgbackrest-spool
process-max=4
compress-type=zst
compress-level=3
start-fast=y

[main]
pg1-path=${PGDATA}
pg1-port=5432
EOF
  chown postgres:postgres "$PGBACKREST_CONF_FILE"
  echo "pgbackrest: rendered $PGBACKREST_CONF_FILE"
}

# Append archive config to postgresql.auto.conf when PGBACKREST_REPO1_S3_BUCKET
# is set and the DB is already initialized. Marker-guarded so it writes once.
configure_pgbackrest_archiving() {
  [ -z "$PGBACKREST_REPO1_S3_BUCKET" ] && return 0
  [ ! -f "$POSTGRES_CONF_FILE" ] && return 0

  if [ -f "$AUTO_CONF_FILE" ] && grep -qF "# pgbackrest-config-begin" "$AUTO_CONF_FILE"; then
    return 0
  fi

  cat >> "$AUTO_CONF_FILE" <<'EOF'
# pgbackrest-config-begin (managed by wrapper.sh)
archive_mode = 'on'
archive_command = 'pgbackrest --stanza=main archive-push %p'
archive_timeout = '60'
restore_command = 'pgbackrest --stanza=main archive-get %f %p'
wal_level = replica
# pgbackrest-config-end
EOF
  echo "pgbackrest: archive config appended to postgresql.auto.conf"
}

# Inverse of configure_pgbackrest_archiving: when the gate var is unset but the
# pgbackrest block still lives in postgresql.auto.conf (user just disabled
# PITR), strip the block out. Without this, archive_mode stays on across the
# next restart with archive_command failing (pgbackrest exits with no creds),
# and Postgres refuses to recycle WAL until the disk fills.
#
# Only acts on the begin/end-sentinel block — never touches user-managed
# config in the same file.
clear_pgbackrest_archiving_if_disabled() {
  [ -n "$PGBACKREST_REPO1_S3_BUCKET" ] && return 0
  [ ! -f "$AUTO_CONF_FILE" ] && return 0
  if ! grep -qF "# pgbackrest-config-begin" "$AUTO_CONF_FILE"; then
    return 0
  fi
  sed '/# pgbackrest-config-begin/,/# pgbackrest-config-end/d' "$AUTO_CONF_FILE" > "$AUTO_CONF_FILE.tmp" \
    && mv "$AUTO_CONF_FILE.tmp" "$AUTO_CONF_FILE"
  rm -f "$PGBACKREST_CONF_FILE"
  echo "pgbackrest: archive config removed from postgresql.auto.conf (PGBACKREST_REPO1_S3_BUCKET unset)"
}

# Stage PITR replay when POSTGRES_RECOVERY_TARGET_TIME is set. Creates
# recovery.signal + recovery settings in postgresql.auto.conf. A sentinel file
# (.pitr_configured) ensures this runs exactly once per volume: Postgres
# removes recovery.signal on successful promote, and a subsequent container
# restart must not re-trigger replay on the same data.
configure_pgbackrest_recovery() {
  [ -z "$POSTGRES_RECOVERY_TARGET_TIME" ] && return 0
  [ ! -f "$POSTGRES_CONF_FILE" ] && return 0

  local marker="$PGDATA/.pitr_configured"
  if [ -f "$marker" ]; then
    return 0
  fi

  # Escape single quotes per postgresql.conf rules (' -> '') so a value with
  # an embedded apostrophe can't break the conf file or smuggle a setting.
  local escaped_target="${POSTGRES_RECOVERY_TARGET_TIME//\'/\'\'}"
  cat >> "$AUTO_CONF_FILE" <<EOF
# managed by pgbackrest-recovery (wrapper.sh)
restore_command = 'pgbackrest --stanza=main archive-get %f %p'
recovery_target_time = '${escaped_target}'
recovery_target_action = 'promote'
EOF
  touch "$PGDATA/recovery.signal"
  touch "$marker"
  echo "pgbackrest: PITR replay staged (target=${POSTGRES_RECOVERY_TARGET_TIME})"
}

render_pgbackrest_conf
clear_pgbackrest_archiving_if_disabled
configure_pgbackrest_archiving
configure_pgbackrest_recovery

# unset PGHOST to force psql to use Unix socket path
# this is specific to Railway and allows
# us to use PGHOST after the init
unset PGHOST

## unset PGPORT also specific to Railway
## since postgres checks for validity of
## the value in PGPORT we unset it in case
## it ends up being empty
unset PGPORT

# Call the entrypoint script with the
# appropriate PGHOST & PGPORT and redirect
# the output to stdout if LOG_TO_STDOUT is true
if [[ "$LOG_TO_STDOUT" == "true" ]]; then
    /usr/local/bin/docker-entrypoint.sh "$@" 2>&1
else
    /usr/local/bin/docker-entrypoint.sh "$@"
fi
