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
# Postgres config is delivered via a managed include directory (conf.d/)
# rather than postgresql.auto.conf. ALTER SYSTEM rewrites auto.conf and
# strips comments, so any sentinel-bracketed approach there is fragile.
# postgresql.conf is not rewritten by Postgres at runtime, so adding a
# one-time `include_dir = 'conf.d'` directive is durable; from then on,
# enable/disable is just write/remove of conf.d/pgbackrest.conf. conf.d
# loads before auto.conf so a determined operator's `ALTER SYSTEM SET
# archive_mode = 'off'` still wins; the dashboard surfaces the divergence
# from the image's intended state by reading pg_settings.
#
# pgBackRest pushes WAL direct to S3 (no intermediary service). It runs in
# async mode: archive_command writes WAL into the local spool dir and
# returns in milliseconds; a background worker pushes from there to S3.
# When archive-push-queue-max=5GiB trips during a sustained S3 outage,
# pgBackRest drops WAL and reports success to Postgres rather than letting
# pg_wal fill the data volume and halting the database. PITR window
# truncates; DB stays up.
#
# Path constants and the helpers shared with pgbackrest-init.sh
# (ensure_pgbackrest_spool_dir, ensure_pg_includes_confd,
# write_pgbackrest_archive_conf, stamp_source_repo_path) live in
# pgbackrest-helpers.sh; the wrapper here adds the boot-time-only paths
# (rendering /etc/pgbackrest/pgbackrest.conf, disable cleanup, stanza
# bootstrap, recovery staging).
# -----------------------------------------------------------------------------

. /usr/local/bin/pgbackrest-helpers.sh

# Fresh init + POSTGRES_RECOVERY_TARGET_TIME is a footgun: archive recovery
# only runs on existing data, so a fresh container would silently ignore
# the target on this boot. On the next boot pgbackrest-init.sh has stamped
# .pgbackrest_source_path to the current write path, and configure_pgbackrest_recovery
# would refuse to start (stamp == current write path). Catch it here before
# initdb runs, with a message that points at the actual fix.
validate_no_pitr_on_fresh_db() {
  [ -z "$PGBACKREST_REPO1_S3_BUCKET" ] && return 0
  [ -z "$POSTGRES_RECOVERY_TARGET_TIME" ] && return 0
  [ -f "$POSTGRES_CONF_FILE" ] && return 0
  echo "pgbackrest: REFUSING to start: POSTGRES_RECOVERY_TARGET_TIME is set, but \$PGDATA is uninitialized." >&2
  echo "pgbackrest: PITR replays WAL onto a base snapshot. Restore the volume from a base snapshot first," >&2
  echo "pgbackrest: or unset POSTGRES_RECOVERY_TARGET_TIME to initialize a fresh database." >&2
  exit 1
}

# Detect the container's effective CPU allocation. Reads cgroup v2 cpu.max
# first (Railway, modern Docker, Kubernetes ≥ 1.25), then falls back to
# cgroup v1 cpu.cfs_quota_us, then to nproc. Returns the integer ceiling
# of fractional quotas (0.5 vCPU → 1) so process-max sizing is sane on the
# smallest tier. "max"/"-1" quotas mean unlimited and use the host count.
detect_cpus() {
  local quota period

  if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r quota period < /sys/fs/cgroup/cpu.max
    if [ "$quota" != "max" ] && [ -n "$quota" ] && [ -n "$period" ] && [ "$period" -gt 0 ]; then
      echo $(( (quota + period - 1) / period ))
      return
    fi
  fi

  if [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
    quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
    period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
    if [ "$quota" -gt 0 ] && [ "$period" -gt 0 ]; then
      echo $(( (quota + period - 1) / period ))
      return
    fi
  fi

  nproc 2>/dev/null || echo 1
}

# Compute per-command process-max with a clamp(value, min, max) shape.
# Sized off detected CPUs because:
#   archive-push: serial 16 MiB segment arrival + per-PUT S3 overhead.
#     cpus/8 grows gently; floor 2 gives every tier some burst headroom;
#     ceiling 8 because at ~190 MB/s/worker that already drains ~1.5 GB/s
#     of sustained WAL — well past realistic generation rates, and beyond
#     that the bottleneck is WAL arrival itself, not worker count.
#   archive-get: WAL replay is serial inside Postgres, so prefetching with
#     >1 worker yields diminishing returns. Pinned to 1.
#   backup: Steele's "≤25% of CPUs" rule (don't starve live DB traffic).
#     Floor 1, ceiling 16 to bound per-worker zstd buffer memory.
#   restore: DB is down, no other workload to protect — but ceiling at 32
#     because pgBackRest's restore throughput plateaus around there
#     (S3 GET-per-prefix and per-worker memory dominate past that).
# Per-command env overrides win when set (custom Enterprise sustaining
# extreme WAL, or operator pinning for testing).
clamp() {
  local v=$1 lo=$2 hi=$3
  [ "$v" -lt "$lo" ] && v=$lo
  [ -n "$hi" ] && [ "$v" -gt "$hi" ] && v=$hi
  echo "$v"
}

# Render /etc/pgbackrest/pgbackrest.conf with operator-policy defaults +
# stanza definition (pg1-path, pg1-port). User-supplied options (S3 bucket,
# region, key, secret, endpoint, repo path) are read by pgBackRest natively
# from PGBACKREST_* env vars, so they don't need to be in the conf file.
# Idempotent: rewritten on every boot when the gate var is set.
render_pgbackrest_conf() {
  [ -z "$PGBACKREST_REPO1_S3_BUCKET" ] && return 0

  mkdir -p /etc/pgbackrest
  # Only create the spool dir once $PGDATA is initialized; before initdb,
  # $PGDATA must be empty or docker-entrypoint refuses to run initdb.
  # pgbackrest-init.sh creates the spool on the fresh-init path.
  if [ -f "$POSTGRES_CONF_FILE" ]; then
    ensure_pgbackrest_spool_dir
  fi

  local cpus
  cpus=$(detect_cpus)
  [ "$cpus" -lt 1 ] && cpus=1

  local push_max get_max backup_max restore_max
  push_max=${PGBACKREST_ARCHIVE_PUSH_PROCESS_MAX:-$(clamp $((cpus / 8)) 2 8)}
  get_max=${PGBACKREST_ARCHIVE_GET_PROCESS_MAX:-1}
  backup_max=${PGBACKREST_BACKUP_PROCESS_MAX:-$(clamp $((cpus / 4)) 1 16)}
  restore_max=${PGBACKREST_RESTORE_PROCESS_MAX:-$(clamp "$cpus" 1 32)}

  echo "pgbackrest: detected ${cpus} vCPU; process-max push=${push_max} get=${get_max} backup=${backup_max} restore=${restore_max}"

  cat > "$PGBACKREST_CONF_FILE" <<EOF
[global]
repo1-type=s3
log-level-console=info
log-level-file=off
archive-async=y
archive-push-queue-max=5GiB
archive-get-queue-max=1GiB
spool-path=${PGBACKREST_SPOOL_DIR}
compress-type=zst
compress-level=3
start-fast=y

[global:archive-push]
process-max=${push_max}

[global:archive-get]
process-max=${get_max}

[global:backup]
process-max=${backup_max}

[global:restore]
process-max=${restore_max}

[main]
pg1-path=${PGDATA}
pg1-port=5432
EOF
  chown postgres:postgres "$PGBACKREST_CONF_FILE"
  chmod 0640 "$PGBACKREST_CONF_FILE"
  echo "pgbackrest: rendered $PGBACKREST_CONF_FILE"
}

# Refresh the source-path sentinel to track the currently-configured
# repo1-path. Skipped while a PITR replay is in flight (.pitr_staging
# present): on a restored volume the stamp must keep showing the SOURCE's
# path until promote succeeds, otherwise a retry of a failed replay would
# trip the divergence check (stamp == current write path).
refresh_source_path_stamp() {
  [ -z "$PGBACKREST_REPO1_S3_BUCKET" ] && return 0
  [ ! -d "$PGDATA" ] && return 0
  [ -f "$PITR_STAGING_FILE" ] && return 0
  local current_path="${PGBACKREST_REPO1_PATH:-}"
  if [ -f "$SOURCE_PATH_SENTINEL_FILE" ] \
     && [ "$(cat "$SOURCE_PATH_SENTINEL_FILE")" = "$current_path" ]; then
    return 0
  fi
  stamp_source_repo_path
  echo "pgbackrest: stamped source repo path '${current_path}' to ${SOURCE_PATH_SENTINEL_FILE}"
}

# Apply the shared archive-conf write on existing-DB boots. Fresh-init
# is handled by pgbackrest-init.sh inside docker-entrypoint-initdb.d/.
# The helpers chown to postgres when invoked as root, so no extra chown
# is needed here.
apply_pgbackrest_archive_conf() {
  [ -z "$PGBACKREST_REPO1_S3_BUCKET" ] && return 0
  [ ! -f "$POSTGRES_CONF_FILE" ] && return 0
  ensure_pg_includes_confd
  write_pgbackrest_archive_conf
}

# Inverse of apply_pgbackrest_archive_conf: when the gate var is unset and
# config exists from a previous boot (user just disabled PITR), wipe
# everything pgBackRest-related from the volume. Without this, pgbackrest
# would fire on every WAL switch with no creds and Postgres would refuse to
# recycle WAL until the disk filled.
#
# Cleared on disable:
#   - $PGDATA/conf.d/pgbackrest.conf, pgbackrest-recovery.conf
#   - /etc/pgbackrest/pgbackrest.conf
#   - $PGDATA/.pgbackrest_source_path (source-path sentinel)
#   - $PGDATA/.pitr_staging, $PGDATA/.pitr_configured (PITR markers — fresh
#     enable later should be able to PITR again without manual cleanup)
#   - $PGDATA/pgbackrest-spool (staged segments are useless without the
#     repo to push to; any in-flight WAL was already covered by the
#     wrapper's drop-on-failure path)
# The `include_dir = 'conf.d'` line in postgresql.conf is left in place
# (no-op when the directory has no pgbackrest files).
clear_pgbackrest_state_if_disabled() {
  [ -n "$PGBACKREST_REPO1_S3_BUCKET" ] && return 0
  local removed=0
  [ -f "$PGBACKREST_ARCHIVE_CONF" ] && rm -f "$PGBACKREST_ARCHIVE_CONF" && removed=1
  [ -f "$PGBACKREST_RECOVERY_CONF" ] && rm -f "$PGBACKREST_RECOVERY_CONF" && removed=1
  [ -f "$PGBACKREST_CONF_FILE" ] && rm -f "$PGBACKREST_CONF_FILE" && removed=1
  [ -f "$SOURCE_PATH_SENTINEL_FILE" ] && rm -f "$SOURCE_PATH_SENTINEL_FILE" && removed=1
  [ -f "$PITR_STAGING_FILE" ] && rm -f "$PITR_STAGING_FILE" && removed=1
  [ -f "$PITR_DONE_MARKER" ] && rm -f "$PITR_DONE_MARKER" && removed=1
  [ -d "$PGBACKREST_SPOOL_DIR" ] && rm -rf "$PGBACKREST_SPOOL_DIR" && removed=1
  if [ "$removed" = "1" ]; then
    echo "pgbackrest: cleared archive/recovery config and PITR state (PGBACKREST_REPO1_S3_BUCKET unset)"
  fi
}

# Run `pgbackrest stanza-create` automatically once Postgres is reachable.
# Forks a background poller so wrapper.sh can stay on its existing exec
# path. stanza-create is idempotent: a matching stanza already in the repo
# is a no-op; a mismatch errors loudly (e.g. PGBACKREST_REPO1_PATH points
# at another cluster's repo), which is the safety we want. Runs on every
# boot — the S3 round-trip is cheap and there's no marker to bookkeep.
#
# Readiness probe uses TCP (-h 127.0.0.1) rather than the Unix socket
# because docker-entrypoint.sh starts a *temporary* postmaster during
# initdb that listens only on the Unix socket (listen_addresses='') for
# init scripts to run against. A socket-based pg_isready would race with
# that temporary instance; the real postgres is the one the CMD launches
# with `-c listen_addresses=*`, which is the only one that binds TCP.
#
# Without this, the first WAL switch after enable would fail archive-push
# with "stanza is missing data in the repo" until a human exec'd in and
# ran the command — wrong default for a managed product.
#
# 600s deadline accommodates slow first boots: a freshly initdb'd cluster
# plus user-supplied init SQL can easily run a few minutes before the
# real postmaster binds TCP. If we time out, first WAL push fails until
# the next boot retries — recoverable, but louder than necessary.
bootstrap_pgbackrest_stanza() {
  [ -z "$PGBACKREST_REPO1_S3_BUCKET" ] && return 0

  (
    # No `local` here: subshells are their own scope so it's redundant, and
    # the construct misleads if the body is ever lifted out of a function.
    deadline=$(( $(date +%s) + 600 ))
    until pg_isready -h 127.0.0.1 -p 5432 -U postgres -q 2>/dev/null; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "pgbackrest: timed out waiting for Postgres before stanza-create" >&2
        exit 1
      fi
      sleep 2
    done

    if gosu postgres pgbackrest --stanza=main stanza-create; then
      echo "pgbackrest: stanza-create completed"
    else
      echo "pgbackrest: stanza-create failed (will retry on next boot)" >&2
    fi
  ) &
}

# Stage PITR replay when POSTGRES_RECOVERY_TARGET_TIME is set. Writes
# recovery settings to $PGDATA/conf.d/pgbackrest-recovery.conf and creates
# recovery.signal.
#
# Two filesystem stamps coordinate "exactly once per successful promote":
#   - .pitr_staging: written when we hand recovery off to Postgres. Means a
#     replay attempt is in flight or last attempt didn't promote yet.
#   - .pitr_configured: written on the boot AFTER Postgres consumes
#     recovery.signal (which Postgres removes only on successful promote).
#     Means PITR is done and must not run again on this volume; once set,
#     subsequent boots skip recovery even if POSTGRES_RECOVERY_TARGET_TIME
#     is changed. To re-run PITR with a different target the operator
#     must restore from a fresh snapshot (or, advanced: rm the marker).
# So a failed replay (bad target time, missing WAL, bad creds) leaves
# .pitr_staging behind WITHOUT .pitr_configured — the operator can fix env
# vars and restart, and the next boot will re-stage cleanly. The recovery
# conf file is overwritten on each staging attempt, and removed on promote
# detection.
#
# Repo-path divergence is enforced two ways:
#   1. Read path: PGBACKREST_RECOVERY_REPO1_PATH names where archive-get pulls
#      WAL from during replay (the source's path). Baked into restore_command
#      via --repo1-path=... so pgbackrest reads from there regardless of the
#      env value pgbackrest itself sees.
#   2. Write path: PGBACKREST_REPO1_PATH must NOT equal the stamped source
#      path. After promote, archive_command pushes to PGBACKREST_REPO1_PATH;
#      if that's still the source's path, the new timeline corrupts the
#      source's ongoing WAL chain. Refusing here surfaces the misconfig
#      before Postgres starts.
configure_pgbackrest_recovery() {
  [ -z "$PGBACKREST_REPO1_S3_BUCKET" ] && return 0
  [ -z "$POSTGRES_RECOVERY_TARGET_TIME" ] && return 0
  [ ! -f "$POSTGRES_CONF_FILE" ] && return 0

  if [ -f "$PITR_DONE_MARKER" ]; then
    return 0
  fi

  # Promote-success detection: a previous boot staged recovery (.pitr_staging
  # present) and Postgres has since removed recovery.signal, which it only
  # does on successful promote. Stamp the marker, drop the staging file, and
  # remove the recovery conf so subsequent boots are vanilla archive-only.
  if [ -f "$PITR_STAGING_FILE" ] && [ ! -f "$PGDATA/recovery.signal" ]; then
    rm -f "$PITR_STAGING_FILE"
    rm -f "$PGBACKREST_RECOVERY_CONF"
    touch "$PITR_DONE_MARKER"
    echo "pgbackrest: previous PITR replay completed; marker written"
    return 0
  fi

  if [ -f "$SOURCE_PATH_SENTINEL_FILE" ]; then
    local stamped_path
    stamped_path=$(cat "$SOURCE_PATH_SENTINEL_FILE")
    local current_write_path="${PGBACKREST_REPO1_PATH:-}"
    if [ "$stamped_path" = "$current_write_path" ]; then
      echo "pgbackrest: REFUSING to stage PITR — PGBACKREST_REPO1_PATH ('${current_write_path}') matches the source's stamped repo path." >&2
      echo "pgbackrest: After promote, archive_command would push the recovered timeline back into the source's repo and corrupt its WAL chain." >&2
      echo "pgbackrest: Set PGBACKREST_REPO1_PATH to a NEW prefix for the recovered cluster's writes, and PGBACKREST_RECOVERY_REPO1_PATH='${stamped_path}' so archive-get can still read source WAL during replay." >&2
      exit 1
    fi
  fi

  ensure_pg_includes_confd
  ensure_pgbackrest_confd_dir

  local recovery_read_path="${PGBACKREST_RECOVERY_REPO1_PATH:-}"
  local restore_cmd="pgbackrest --stanza=main archive-get %f %p"
  if [ -n "$recovery_read_path" ]; then
    # printf %q produces a shell-safe quoted form, so a recovery_read_path
    # with spaces, dollar signs, etc. survives the eventual sh -c that
    # Postgres uses to run restore_command. Without this, "/foo bar" would
    # split into two args and the restore_command would silently malform.
    local quoted_read_path
    printf -v quoted_read_path '%q' "$recovery_read_path"
    restore_cmd="pgbackrest --stanza=main --repo1-path=${quoted_read_path} archive-get %f %p"
  else
    echo "pgbackrest: WARNING — PGBACKREST_RECOVERY_REPO1_PATH unset; archive-get will use PGBACKREST_REPO1_PATH ('${PGBACKREST_REPO1_PATH:-}'). Set the recovery-read path explicitly to avoid coupling read and write paths." >&2
  fi

  # Escape single quotes per postgresql.conf rules (' -> '') so a value with
  # an embedded apostrophe can't break the conf file or smuggle a setting.
  local escaped_target="${POSTGRES_RECOVERY_TARGET_TIME//\'/\'\'}"
  local escaped_restore="${restore_cmd//\'/\'\'}"
  cat > "$PGBACKREST_RECOVERY_CONF" <<EOF
restore_command = '${escaped_restore}'
recovery_target_time = '${escaped_target}'
recovery_target_action = 'promote'
EOF
  chmod 0640 "$PGBACKREST_RECOVERY_CONF"
  chown_postgres_if_root "$PGBACKREST_RECOVERY_CONF"
  touch "$PGDATA/recovery.signal"
  touch "$PITR_STAGING_FILE"
  echo "pgbackrest: PITR replay staged (target=${POSTGRES_RECOVERY_TARGET_TIME})"
}

validate_no_pitr_on_fresh_db
render_pgbackrest_conf
clear_pgbackrest_state_if_disabled
apply_pgbackrest_archive_conf
configure_pgbackrest_recovery
refresh_source_path_stamp
bootstrap_pgbackrest_stanza

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
