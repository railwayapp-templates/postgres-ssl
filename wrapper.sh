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
# WAL archiving + PITR (tool-agnostic env contract)
#
# Backboard / frontend / template speak `WAL_ARCHIVE_*` (this service's own
# archive bucket) and `WAL_RECOVER_FROM_*` (only on restored services, points
# at source's bucket for read-during-recovery). The translation below maps
# that contract onto pgBackRest's native `PGBACKREST_REPO{1,2}_S3_*` so the
# rest of this script can stay pgBackRest-shaped.
#
# Three modes:
#   - WAL_ARCHIVE_* only → standalone archiving service. REPO1 = archive.
#   - WAL_RECOVER_FROM_* only → restored service, no ongoing archiving. REPO1
#     = source bucket (read for archive-get during recovery). After promote
#     no archive_command runs; user enables PITR via the standard flow if
#     they want continued archiving (which provisions a fresh bucket then).
#   - WAL_ARCHIVE_* + WAL_RECOVER_FROM_* → restored service that already has
#     PITR re-enabled. REPO1 = recover-from, REPO2 = archive; the archive-
#     push wrapper adds --repo=2 so post-promote WAL never sprays into the
#     source bucket.
if [ -n "${WAL_RECOVER_FROM_BUCKET:-}" ]; then
  export PGBACKREST_REPO1_S3_BUCKET="$WAL_RECOVER_FROM_BUCKET"
  export PGBACKREST_REPO1_S3_KEY="$WAL_RECOVER_FROM_KEY"
  export PGBACKREST_REPO1_S3_KEY_SECRET="$WAL_RECOVER_FROM_SECRET"
  export PGBACKREST_REPO1_S3_REGION="$WAL_RECOVER_FROM_REGION"
  export PGBACKREST_REPO1_S3_ENDPOINT="$WAL_RECOVER_FROM_ENDPOINT"
  export PGBACKREST_REPO1_PATH="${WAL_RECOVER_FROM_PATH:-/pgbackrest}"
  if [ -n "${WAL_ARCHIVE_BUCKET:-}" ]; then
    export PGBACKREST_REPO2_S3_BUCKET="$WAL_ARCHIVE_BUCKET"
    export PGBACKREST_REPO2_S3_KEY="$WAL_ARCHIVE_KEY"
    export PGBACKREST_REPO2_S3_KEY_SECRET="$WAL_ARCHIVE_SECRET"
    export PGBACKREST_REPO2_S3_REGION="$WAL_ARCHIVE_REGION"
    export PGBACKREST_REPO2_S3_ENDPOINT="$WAL_ARCHIVE_ENDPOINT"
    export PGBACKREST_REPO2_PATH="${WAL_ARCHIVE_PATH:-/pgbackrest}"
  fi
elif [ -n "${WAL_ARCHIVE_BUCKET:-}" ]; then
  export PGBACKREST_REPO1_S3_BUCKET="$WAL_ARCHIVE_BUCKET"
  export PGBACKREST_REPO1_S3_KEY="$WAL_ARCHIVE_KEY"
  export PGBACKREST_REPO1_S3_KEY_SECRET="$WAL_ARCHIVE_SECRET"
  export PGBACKREST_REPO1_S3_REGION="$WAL_ARCHIVE_REGION"
  export PGBACKREST_REPO1_S3_ENDPOINT="$WAL_ARCHIVE_ENDPOINT"
  export PGBACKREST_REPO1_PATH="${WAL_ARCHIVE_PATH:-/pgbackrest}"
fi

# Helpers gate on whichever role is active. PGBACKREST_REPO1_S3_BUCKET acts
# as the "any pgBackRest at all" gate (rendering pgbackrest.conf, running
# stanza-create); WAL_ARCHIVE_BUCKET specifically gates writing
# archive_mode=on / archive_command (this service archives outgoing WAL);
# WAL_RECOVER_FROM_BUCKET + POSTGRES_RECOVERY_TARGET_TIME together gate
# arming archive recovery on first boot.
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
# Two orthogonal thresholds gate the "WAL is accumulating, do something":
#   - archive-push-queue-max=5GiB (set in /etc/pgbackrest/pgbackrest.conf
#     below) governs the SPOOL. Trips on transient S3 stalls; pgBackRest
#     drops segments from spool and reports success to archive_command.
#     Generous buffer to absorb multi-hour outages cleanly.
#   - pgbackrest-archive-push-wrapper.sh's PGBACKREST_DROP_THRESHOLD_MB
#     (default 500 MiB) governs pg_wal/. Trips on HARD failures (bad creds,
#     deleted bucket, expired keys) where pgbackrest's foreground returns
#     non-zero and retrying without operator intervention has zero chance
#     of success. Smaller cap because we shouldn't hold 5 GiB of pg_wal
#     hostage waiting for a config fix.
# Either way, PITR window truncates; DB stays up.
# -----------------------------------------------------------------------------

PGBACKREST_CONF_FILE="/etc/pgbackrest/pgbackrest.conf"
PGBACKREST_CONFD_DIR="$PGDATA/conf.d"
PGBACKREST_ARCHIVE_CONF="$PGBACKREST_CONFD_DIR/pgbackrest.conf"
PGBACKREST_RECOVERY_CONF="$PGBACKREST_CONFD_DIR/pgbackrest-recovery.conf"
PGBACKREST_SPOOL_DIR="$PGDATA/pgbackrest-spool"

# PITR staging stamps. .pitr_staging is written when a replay is handed off
# to Postgres; .pitr_configured is written on the boot AFTER Postgres consumes
# recovery.signal (i.e., promote succeeded), so subsequent boots skip
# re-arming recovery. Source-bucket / repo-path divergence checks are gone:
# under the new-service restore design, the restored service has its own
# bucket (`WAL_ARCHIVE_*`) and reads from the source's bucket via the
# distinct `WAL_RECOVER_FROM_*` repo, so no shared write path exists.
PITR_STAGING_FILE="$PGDATA/.pitr_staging"
PITR_DONE_MARKER="$PGDATA/.pitr_configured"

# Add `include_dir = 'conf.d'` to postgresql.conf if not already present.
# postgresql.conf is not rewritten by Postgres at runtime (only auto.conf is,
# by ALTER SYSTEM), so this single line is durable. Called from both the
# archive-conf write path and the recovery-staging path.
#
# The detection regex accepts single-quoted, double-quoted, and unquoted
# forms because postgresql.conf treats all three as equivalent. Without the
# tolerance, a hand-tuned image (or a future PG release that changes the
# default quoting) would silently get a duplicate include_dir line on every
# boot — Postgres tolerates duplicates (last wins, both point at the same
# dir) but the noise is avoidable.
ensure_pg_includes_confd() {
  [ ! -f "$POSTGRES_CONF_FILE" ] && return 0
  if grep -qE "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*['\"]?conf\.d['\"]?[[:space:]]*$" "$POSTGRES_CONF_FILE"; then
    return 0
  fi
  echo "include_dir = 'conf.d'" >> "$POSTGRES_CONF_FILE"
  echo "pgbackrest: enabled include_dir 'conf.d' in postgresql.conf"
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
  # pgbackrest-init.sh creates the spool on the fresh-init path. Spool
  # lives under $PGDATA so segments staged but not yet pushed to S3
  # survive container restarts.
  if [ -f "$POSTGRES_CONF_FILE" ]; then
    install -d -m 0750 -o postgres -g postgres "$PGBACKREST_SPOOL_DIR"
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

  # Two-repo mode: REPO1 reads source's WAL (archive-get during recovery),
  # REPO2 receives the restored cluster's post-promote pushes. The
  # archive-push wrapper picks the right repo at command time via --repo;
  # here we just declare repo2 so pgBackRest reads the corresponding env vars.
  local repo2_block=""
  if [ -n "${PGBACKREST_REPO2_S3_BUCKET:-}" ]; then
    repo2_block="repo2-type=s3"$'\n'
  fi

  cat > "$PGBACKREST_CONF_FILE" <<EOF
[global]
repo1-type=s3
${repo2_block}log-level-console=info
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

# Write archive config to $PGDATA/conf.d/pgbackrest.conf when the service has
# its own archive bucket and the DB is already initialized. Idempotent:
# rewritten on every boot. Fresh-init is handled by pgbackrest-init.sh from
# initdb. Restored services without WAL_ARCHIVE_BUCKET skip this — they read
# from repo1 during recovery via configure_pgbackrest_recovery and run as
# plain non-archiving Postgres after promote.
apply_pgbackrest_archive_conf() {
  [ -z "${WAL_ARCHIVE_BUCKET:-}" ] && return 0
  [ ! -f "$POSTGRES_CONF_FILE" ] && return 0
  ensure_pg_includes_confd
  install -d -m 0750 -o postgres -g postgres "$PGBACKREST_CONFD_DIR"

  local archive_timeout="${POSTGRES_ARCHIVE_TIMEOUT:-60}"
  cat > "$PGBACKREST_ARCHIVE_CONF" <<EOF
archive_mode = 'on'
archive_command = '/usr/local/bin/pgbackrest-archive-push-wrapper.sh %p'
archive_timeout = '${archive_timeout}'
EOF
  chown postgres:postgres "$PGBACKREST_ARCHIVE_CONF"
  chmod 0640 "$PGBACKREST_ARCHIVE_CONF"
  echo "pgbackrest: wrote ${PGBACKREST_ARCHIVE_CONF}"
}

# Granular cleanup driven by the WAL_* contract. Each role has its own gate:
#   - WAL_ARCHIVE_BUCKET unset → drop archive config (archive_mode=on /
#     archive_command). Without this, archive_command would fire with no
#     creds and Postgres would refuse to recycle WAL until disk filled.
#   - WAL_RECOVER_FROM_BUCKET unset → drop recovery config + PITR markers so
#     a future restore-from-this-service starts cleanly.
#   - Both unset → also wipe /etc/pgbackrest/pgbackrest.conf and the spool;
#     pgBackRest is not in use at all.
# The `include_dir = 'conf.d'` line in postgresql.conf is left in place
# (no-op when conf.d has no pgbackrest files).
clear_pgbackrest_state_if_disabled() {
  local removed=0
  if [ -z "${WAL_ARCHIVE_BUCKET:-}" ]; then
    [ -f "$PGBACKREST_ARCHIVE_CONF" ] && rm -f "$PGBACKREST_ARCHIVE_CONF" && removed=1
  fi
  if [ -z "${WAL_RECOVER_FROM_BUCKET:-}" ]; then
    [ -f "$PGBACKREST_RECOVERY_CONF" ] && rm -f "$PGBACKREST_RECOVERY_CONF" && removed=1
    [ -f "$PITR_STAGING_FILE" ] && rm -f "$PITR_STAGING_FILE" && removed=1
    [ -f "$PITR_DONE_MARKER" ] && rm -f "$PITR_DONE_MARKER" && removed=1
  fi
  if [ -z "${WAL_ARCHIVE_BUCKET:-}" ] && [ -z "${WAL_RECOVER_FROM_BUCKET:-}" ]; then
    [ -f "$PGBACKREST_CONF_FILE" ] && rm -f "$PGBACKREST_CONF_FILE" && removed=1
    [ -d "$PGBACKREST_SPOOL_DIR" ] && rm -rf "$PGBACKREST_SPOOL_DIR" && removed=1
  fi
  if [ "$removed" = "1" ]; then
    echo "pgbackrest: cleared stale archive/recovery state for the disabled role(s)"
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
# vars and restart, and the next boot will re-stage cleanly.
#
# restore_command pulls from repo1, which under the new-service restore
# design is the source service's bucket (translated from `WAL_RECOVER_FROM_*`
# at the top of this script). Post-promote archive_command writes to repo2
# (the restored service's own bucket) — see archive-push-repo in the
# rendered pgbackrest.conf.
configure_pgbackrest_recovery() {
  [ -z "${WAL_RECOVER_FROM_BUCKET:-}" ] && return 0
  [ -z "$POSTGRES_RECOVERY_TARGET_TIME" ] && return 0
  [ ! -f "$POSTGRES_CONF_FILE" ] && return 0

  # Wiped volume on a restored service: pgbackrest-init.sh's `.fresh_initdb`
  # marker is present, the env vars still say "recover to T," but the cluster
  # was just initdb'd and has no relationship to source's WAL stream. Skip
  # arming recovery silently — Postgres starts as a normal fresh DB instead
  # of refusing to start on a system_identifier mismatch later.
  if [ -f "$PGDATA/.fresh_initdb" ]; then
    echo "pgbackrest: ignoring POSTGRES_RECOVERY_TARGET_TIME — volume was freshly initdb'd, no source WAL relationship to recover from"
    return 0
  fi


  if [ -f "$PITR_DONE_MARKER" ]; then
    return 0
  fi

  if [ -f "$PITR_STAGING_FILE" ] && [ ! -f "$PGDATA/recovery.signal" ]; then
    rm -f "$PITR_STAGING_FILE"
    rm -f "$PGBACKREST_RECOVERY_CONF"
    touch "$PITR_DONE_MARKER"
    echo "pgbackrest: previous PITR replay completed; marker written"
    return 0
  fi

  ensure_pg_includes_confd
  install -d -m 0750 -o postgres -g postgres "$PGBACKREST_CONFD_DIR"

  local restore_cmd="pgbackrest --stanza=main --repo=1 archive-get %f %p"

  # Escape single quotes per postgresql.conf rules (' -> '') so a value with
  # an embedded apostrophe can't break the conf file or smuggle a setting.
  local escaped_target="${POSTGRES_RECOVERY_TARGET_TIME//\'/\'\'}"
  local escaped_restore="${restore_cmd//\'/\'\'}"
  cat > "$PGBACKREST_RECOVERY_CONF" <<EOF
restore_command = '${escaped_restore}'
recovery_target_time = '${escaped_target}'
recovery_target_action = 'promote'
EOF
  chown postgres:postgres "$PGBACKREST_RECOVERY_CONF"
  chmod 0640 "$PGBACKREST_RECOVERY_CONF"
  touch "$PGDATA/recovery.signal"
  touch "$PITR_STAGING_FILE"
  echo "pgbackrest: PITR replay staged (target=${POSTGRES_RECOVERY_TARGET_TIME})"
}

render_pgbackrest_conf
clear_pgbackrest_state_if_disabled
apply_pgbackrest_archive_conf
configure_pgbackrest_recovery
bootstrap_pgbackrest_stanza

# Marker only meaningful on the first boot after initdb; clear it now that
# the wrapper has had its chance to act on it.
[ -f "$PGDATA/.fresh_initdb" ] && rm -f "$PGDATA/.fresh_initdb"

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
