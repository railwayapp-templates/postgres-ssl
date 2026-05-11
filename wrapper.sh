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
# destination bucket — write-only for this service) and `WAL_RECOVER_FROM_*`
# (only on PITR-restored forks, points at source's bucket for read-during-
# recovery). Neither is exported as PGBACKREST_REPO*_*: pgBackRest's option
# resolution is command-line > env vars > config file > defaults, so a global
# REPO1_* export silently overrides any --config we pass during recovery.
#
# Instead, we materialise two non-overlapping config files and route every
# pgbackrest invocation through one of them via --config:
#
#   /etc/pgbackrest/pgbackrest.conf — rendered by render_pgbackrest_conf.
#     Has the service's own archive bucket as repo1. archive_command,
#     stanza-create, and the watcher's backup all read this and only this.
#
#   /etc/pgbackrest/pgbackrest-recovery-source.conf — written by
#     restore_from_pgbackrest_if_empty_volume and re-rendered by
#     configure_pgbackrest_recovery on every boot when WAL_RECOVER_FROM_*
#     is set. Has source's read-only bucket as repo1 (numbering is per-
#     config). The persisted restore_command in postgresql.auto.conf
#     references this file via --config, so archive-get during recovery
#     reads source's bucket without leaking into archive_command.
#
# This isolation is load-bearing: pgBackRest 2.58's archive-push fans out
# to every configured repo with no per-call scoping. A fork that has both
# its own bucket and source's bucket configured in the same pgbackrest
# would push every WAL to source's read-only bucket, fail with 403, and
# silently degrade the new service's PITR window.
#
# The watcher and archive-push wrapper set PGBACKREST_REPO1_PATH locally
# from the .pgbackrest_repo_path marker — that's a per-call override of
# the path within the service's own repo1, not a cross-repo conflict.

# Helpers gate on whichever role is active. WAL_ARCHIVE_BUCKET gates the
# archiving path (rendering /etc/pgbackrest/pgbackrest.conf, archive_mode=on,
# archive_command, the watcher, stanza-create); WAL_RECOVER_FROM_BUCKET +
# POSTGRES_RECOVERY_TARGET_TIME together gate arming archive recovery on
# first boot.
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
#   - pgbackrest-archive-push-wrapper.sh's WAL_DROP_THRESHOLD_MB
#     (default 500 MiB) governs pg_wal/. Trips on HARD failures (bad creds,
#     deleted bucket, expired keys) where pgbackrest's foreground returns
#     non-zero and retrying without operator intervention has zero chance
#     of success. Smaller cap because we shouldn't hold 5 GiB of pg_wal
#     hostage waiting for a config fix.
# Either way, PITR window truncates; DB stays up.
# -----------------------------------------------------------------------------

PGBACKREST_CONF_FILE="/etc/pgbackrest/pgbackrest.conf"
# Dedicated config holding repo2 (= source bucket) settings for archive-get
# during recovery only. Lives under /etc/pgbackrest so the default conf
# never has repo2 — archive_command + stanza-create read only the default
# and can't fan out to source's read-only bucket.
PGBACKREST_RECOVERY_S3_CONF="/etc/pgbackrest/pgbackrest-recovery-source.conf"
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

# Written by restore_from_pgbackrest_if_empty_volume after a successful
# `pgbackrest restore` populates an empty volume. Tells configure_pgbackrest_recovery
# to bail — pgbackrest restore already wrote recovery.signal + recovery params,
# our conf.d/pgbackrest-recovery.conf path would duplicate them.
PGBACKREST_RESTORED_MARKER="$PGDATA/.pgbackrest_restored"

# Per-cluster archive sub-path: the effective repo1-path, persisted inside
# PGDATA so the watcher, archive-push wrapper, and stanza-create subshell
# all converge on the same value. Per-cluster pathing means a wipe-and-
# reuse-bucket cycle (volume wiped, container redeployed against the same
# WAL_ARCHIVE_BUCKET) lets the new cluster's history coexist with the old
# at distinct sub-prefixes — no system-id collision, no orphaned data, no
# silent overwrite. Mono surfaces all sub-paths as separate "histories"
# the user can browse and restore from.
PGBACKREST_REPO_PATH_MARKER="$PGDATA/.pgbackrest_repo_path"

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

# Read Postgres' system_identifier from pg_control. Empty when pg_control
# isn't on disk yet (fresh volume, pre-initdb).
read_postgres_sysid() {
  [ ! -f "$PGDATA/global/pg_control" ] && return 0
  pg_controldata "$PGDATA" 2>/dev/null \
    | awk -F: '/Database system identifier/ { gsub(/[ \t]/,"",$2); print $2 }'
}

# Resolve the effective repo1-path for archiving:
#
#   1. Marker file present → trust it. Idempotent across boots; survives
#      container restarts; wiped with the volume.
#   2. pg_control exists, marker absent → derive
#      `${WAL_ARCHIVE_PATH}/cluster-<sysid>`, write marker.
#   3. Pre-initdb (no pg_control) → return `${WAL_ARCHIVE_PATH}` as a
#      placeholder; the marker gets written by pgbackrest-init.sh's
#      post-initdb hook or by the bootstrap subshell once Postgres is up,
#      so subsequent reads converge.
#
# After wipe-and-reuse-bucket, the new cluster (different sysid) gets a
# fresh marker pointing at a fresh `cluster-<new_sysid>` path. The previous
# cluster's data at `cluster-<old_sysid>` is untouched and remains visible
# to the bucket lister (mono UI).
derive_pgbackrest_repo_path() {
  local user_path="${WAL_ARCHIVE_PATH:-/pgbackrest}"

  if [ -f "$PGBACKREST_REPO_PATH_MARKER" ]; then
    cat "$PGBACKREST_REPO_PATH_MARKER"
    return 0
  fi

  local sysid
  sysid=$(read_postgres_sysid)
  if [ -z "$sysid" ]; then
    echo "$user_path"
    return 0
  fi

  local cluster_path="${user_path%/}/cluster-${sysid}"
  write_pgbackrest_repo_path_marker "$cluster_path"
  echo "$cluster_path"
}

write_pgbackrest_repo_path_marker() {
  local path="$1"
  echo "$path" > "$PGBACKREST_REPO_PATH_MARKER"
  chown postgres:postgres "$PGBACKREST_REPO_PATH_MARKER" 2>/dev/null || true
  chmod 0640 "$PGBACKREST_REPO_PATH_MARKER" 2>/dev/null || true
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

# Render /etc/pgbackrest/pgbackrest.conf with the service's own archive
# bucket as repo1 + operator-policy defaults + stanza definition. Recovery
# (when needed) lives in a separate file written by
# restore_from_pgbackrest_if_empty_volume / configure_pgbackrest_recovery,
# never touching this file. Idempotent: rewritten on every boot when the
# gate var is set.
render_pgbackrest_conf() {
  [ -z "${WAL_ARCHIVE_BUCKET:-}" ] && return 0

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

  # The default pgbackrest.conf only ever has repo1. Recovery (which needs
  # repo2 to read source's bucket) uses a separate /etc/pgbackrest/pgbackrest-recovery.conf
  # written by restore_from_pgbackrest_if_empty_volume, referenced via the
  # restore_command's --config flag.

  # Retention is always scoped to REPO1 — every service writes only to its
  # own bucket. REPO2 (source bucket on a fork) is read-only for this
  # service; source owns its own retention. pgbackrest expire runs after
  # every backup. repo1-retention-archive is left to pgBackRest's default
  # (= retention-full), which keeps WAL needed for the most recent N fulls.
  local retention_full="${WAL_BACKUP_RETENTION_FULL:-4}"
  local retention_diff="${WAL_BACKUP_RETENTION_DIFF:-14}"
  local retention_block=""
  if [ -n "${WAL_ARCHIVE_BUCKET:-}" ]; then
    retention_block="repo1-retention-full=${retention_full}"$'\n'"repo1-retention-diff=${retention_diff}"$'\n'
  fi

  cat > "$PGBACKREST_CONF_FILE" <<EOF
[global]
repo1-type=s3
repo1-s3-bucket=${WAL_ARCHIVE_BUCKET}
repo1-s3-key=${WAL_ARCHIVE_KEY}
repo1-s3-key-secret=${WAL_ARCHIVE_SECRET}
repo1-s3-region=${WAL_ARCHIVE_REGION}
repo1-s3-endpoint=${WAL_ARCHIVE_ENDPOINT}
repo1-s3-uri-style=${WAL_ARCHIVE_S3_URI_STYLE:-path}
repo1-path=${WAL_ARCHIVE_PATH:-/pgbackrest}
log-level-console=info
log-level-file=off
archive-async=y
archive-push-queue-max=5GiB
archive-get-queue-max=1GiB
spool-path=${PGBACKREST_SPOOL_DIR}
compress-type=zst
compress-level=3
start-fast=y
${retention_block}
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
  # track_commit_timestamp lets pg_last_committed_xact() return the wall-clock
  # time of the last commit. The PITR picker uses that as its upper bound:
  # `recovery_target_time` only matches commit record timestamps, so on an
  # idle DB the archive head keeps ticking with empty WAL while the latest
  # reachable target stays pinned at the last commit. Without this GUC the
  # picker falls back to lastArchivedAt and the user can pick an
  # unreachable target. Requires a restart to take effect; the entrypoint
  # rewrites this file on every boot, so first archive-enable picks it up.
  cat > "$PGBACKREST_ARCHIVE_CONF" <<EOF
archive_mode = 'on'
archive_command = '/usr/local/bin/pgbackrest-archive-push-wrapper.sh %p'
archive_timeout = '${archive_timeout}'
track_commit_timestamp = 'on'
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
    # Backup-watcher state is scoped to a particular archive bucket — when
    # the bucket goes away, drop the state so a future re-enable starts
    # from NEEDS_INITIAL_BACKUP rather than a stale "last full was X" cache.
    [ -f "$PGDATA/.pgbackrest_backup_state" ] && rm -f "$PGDATA/.pgbackrest_backup_state" && removed=1
    [ -f "$PGDATA/.pgbackrest_gap_pending" ] && rm -f "$PGDATA/.pgbackrest_gap_pending" && removed=1
  fi
  if [ -z "${WAL_RECOVER_FROM_BUCKET:-}" ]; then
    [ -f "$PGBACKREST_RECOVERY_CONF" ] && rm -f "$PGBACKREST_RECOVERY_CONF" && removed=1
    [ -f "$PITR_STAGING_FILE" ] && rm -f "$PITR_STAGING_FILE" && removed=1
    [ -f "$PITR_DONE_MARKER" ] && rm -f "$PITR_DONE_MARKER" && removed=1
    [ -f "$PGBACKREST_RESTORED_MARKER" ] && rm -f "$PGBACKREST_RESTORED_MARKER" && removed=1
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
  # pgBackRest 2.58 rejects --repo on stanza-create. In single-repo mode
  # there's nothing to scope; in dual-repo (fork) mode the source's repo2
  # already has a stanza so stanza-create on it is a no-op-or-mismatch
  # anyway — neither outcome wants this command to fan out, so we keep the
  # call vanilla and rely on dual-repo configs being post-promote-only.
  [ -z "${WAL_ARCHIVE_BUCKET:-}" ] && return 0

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

    # Re-derive the repo path now that pg_control is on disk. This is the
    # canonical first chance to do it on a fresh-cluster path: pgbackrest-init.sh
    # may also have written the marker during initdb, in which case derive
    # just reads it.
    repo_path=$(derive_pgbackrest_repo_path)
    export PGBACKREST_REPO1_PATH="$repo_path"

    # Update the rendered pgbackrest.conf so SSH-driven pgbackrest invocations
    # (mono's probePgbackrestInfo runs `gosu postgres pgbackrest info` over
    # SSH and inherits no shell env from this subshell) see the per-cluster
    # path. Without this rewrite the probe would read the conf's bootstrap
    # path (=$WAL_ARCHIVE_PATH), find no backups under it, and fail the
    # restore mutation with "No base backup has been taken yet".
    if [ -f "$PGBACKREST_CONF_FILE" ]; then
      sed -i "s|^repo1-path=.*|repo1-path=${repo_path}|" "$PGBACKREST_CONF_FILE"
    fi

    echo "pgbackrest: using repo1-path=${repo_path}"

    if gosu postgres pgbackrest --stanza=main stanza-create; then
      echo "pgbackrest: stanza-create completed"
    else
      echo "pgbackrest: stanza-create failed (will retry on next boot)" >&2
    fi
  ) &
}

# Stage PITR replay when POSTGRES_RECOVERY_TARGET_TIME (timestamp),
# POSTGRES_RECOVERY_TARGET_XID (exact xid), or
# POSTGRES_RECOVERY_TARGET_TYPE=immediate (restore-to-base-backup, no
# target needed) is set. Writes recovery settings to
# $PGDATA/conf.d/pgbackrest-recovery.conf and creates recovery.signal.
#
# `immediate` lands on the consistent-state at the end of the base backup
# and stops there — no commit timestamp anchor required. The picker uses
# it when the source has zero tracked commits (brand-new cluster); the
# user gets the seed-data state without having to fabricate a commit
# server-side.
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
# restore_command pulls from repo2, which is the source service's bucket
# (translated from `WAL_RECOVER_FROM_*` at the top of this script). Post-
# promote archive_command writes to repo1 (this fork's own bucket) — see
# the archive-push wrapper's --repo=1 pin.
configure_pgbackrest_recovery() {
  [ -z "${WAL_RECOVER_FROM_BUCKET:-}" ] && return 0
  if [ -z "${POSTGRES_RECOVERY_TARGET_TIME:-}" ] \
     && [ -z "${POSTGRES_RECOVERY_TARGET_XID:-}" ] \
     && [ "${POSTGRES_RECOVERY_TARGET_TYPE:-}" != "immediate" ]; then
    return 0
  fi
  [ ! -f "$POSTGRES_CONF_FILE" ] && return 0

  # /etc/pgbackrest is rebuilt on every boot, so always re-render the
  # recovery conf when WAL_RECOVER_FROM_* is set — postgres' restore_command
  # references it whether the auto.conf was written by the wrapper's own
  # pgbackrest restore or by an external one (e.g. test pgbackrest_restore_into).
  install -d -m 0750 -o postgres -g postgres /etc/pgbackrest
  cat > "$PGBACKREST_RECOVERY_S3_CONF" <<EOF
[global]
log-level-console=info
log-level-file=off
spool-path=${PGBACKREST_SPOOL_DIR}
repo1-type=s3
repo1-s3-bucket=${WAL_RECOVER_FROM_BUCKET}
repo1-s3-key=${WAL_RECOVER_FROM_KEY}
repo1-s3-key-secret=${WAL_RECOVER_FROM_SECRET}
repo1-s3-region=${WAL_RECOVER_FROM_REGION}
repo1-s3-endpoint=${WAL_RECOVER_FROM_ENDPOINT}
repo1-s3-uri-style=${WAL_RECOVER_FROM_S3_URI_STYLE:-path}
repo1-path=${WAL_RECOVER_FROM_PATH:-/pgbackrest}

[main]
pg1-path=${PGDATA}
pg1-port=5432
EOF
  chown postgres:postgres "$PGBACKREST_RECOVERY_S3_CONF"
  chmod 0640 "$PGBACKREST_RECOVERY_S3_CONF"

  # The pgbackrest-restore path (empty-volume restore) handles recovery
  # staging itself — recovery.signal + recovery params come out of
  # `pgbackrest restore`, not our conf.d include. Skip the include-write
  # path so we don't end up with duplicate recovery_target_time settings.
  if [ -f "$PGBACKREST_RESTORED_MARKER" ]; then
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

  local restore_cmd="pgbackrest --config=${PGBACKREST_RECOVERY_S3_CONF} --stanza=main archive-get %f %p"

  # Escape single quotes per postgresql.conf rules (' -> '') so a value with
  # an embedded apostrophe can't break the conf file or smuggle a setting.
  local escaped_restore="${restore_cmd//\'/\'\'}"

  # Pick the recovery target. TYPE=immediate is the no-anchor path —
  # postgres stops at end-of-base-backup consistency, no WAL replay past
  # that, no target value needed. XID wins over TIME for the same idle-
  # source-safe rationale as restore_from_pgbackrest_if_empty_volume:
  # recovery_target_time hangs/FATALs when no commit record exists past
  # target on an idle DB, recovery_target_xid matches an exact commit.
  # The picker emits _XID when it clamped to lastCommittedTxnAt; _TYPE
  # when the source has zero committed transactions to anchor against.
  local recovery_param
  local target_label
  if [ "${POSTGRES_RECOVERY_TARGET_TYPE:-}" = "immediate" ]; then
    recovery_param="recovery_target = 'immediate'"
    target_label="immediate"
  elif [ -n "${POSTGRES_RECOVERY_TARGET_XID:-}" ]; then
    local escaped_xid="${POSTGRES_RECOVERY_TARGET_XID//\'/\'\'}"
    recovery_param="recovery_target_xid = '${escaped_xid}'"
    target_label="xid=${POSTGRES_RECOVERY_TARGET_XID}"
  else
    local escaped_target="${POSTGRES_RECOVERY_TARGET_TIME//\'/\'\'}"
    recovery_param="recovery_target_time = '${escaped_target}'"
    target_label="time=${POSTGRES_RECOVERY_TARGET_TIME}"
  fi
  cat > "$PGBACKREST_RECOVERY_CONF" <<EOF
restore_command = '${escaped_restore}'
${recovery_param}
recovery_target_action = 'promote'
EOF
  chown postgres:postgres "$PGBACKREST_RECOVERY_CONF"
  chmod 0640 "$PGBACKREST_RECOVERY_CONF"
  touch "$PGDATA/recovery.signal"
  touch "$PITR_STAGING_FILE"
  echo "pgbackrest: PITR replay staged (${target_label})"
}

# When a restored service is created with an empty volume + WAL_RECOVER_FROM_*
# + POSTGRES_RECOVERY_TARGET_TIME, restore the data dir directly from the
# source bucket via pgbackrest. Replaces v1's "snapshot replicate, then
# archive-get during recovery" two-step. The restore command pulls the most
# recent base backup ≤ T, applies WAL forward to T, writes recovery.signal +
# recovery params; postmaster boots straight into recovery and promotes.
#
# The .pgbackrest_restored marker tells configure_pgbackrest_recovery to
# stay out of the way (its conf.d include would duplicate what pgbackrest
# restore already wrote).
#
# Container restart on an already-restored volume: $PGDATA is populated, so
# the empty-PGDATA gate fails and we skip — Postgres starts normally.
restore_from_pgbackrest_if_empty_volume() {
  # Log gate state up front so post-mortems on "why did pgbackrest restore
  # run when I expected it to be skipped" don't require guessing.
  echo "pgbackrest: restore-gate WAL_RECOVER_FROM_BUCKET=${WAL_RECOVER_FROM_BUCKET:+set} POSTGRES_RECOVERY_TARGET_TIME=${POSTGRES_RECOVERY_TARGET_TIME:+set} POSTGRES_RECOVERY_TARGET_XID=${POSTGRES_RECOVERY_TARGET_XID:+set} POSTGRES_RECOVERY_TARGET_TYPE=${POSTGRES_RECOVERY_TARGET_TYPE:-} PG_VERSION=$([ -f "$PGDATA/PG_VERSION" ] && echo present || echo missing) RESTORED_MARKER=$([ -f "$PGBACKREST_RESTORED_MARKER" ] && echo present || echo missing) PGDATA=$PGDATA"

  [ -z "${WAL_RECOVER_FROM_BUCKET:-}" ] && return 0
  if [ -z "${POSTGRES_RECOVERY_TARGET_TIME:-}" ] \
     && [ -z "${POSTGRES_RECOVERY_TARGET_XID:-}" ] \
     && [ "${POSTGRES_RECOVERY_TARGET_TYPE:-}" != "immediate" ]; then
    return 0
  fi
  [ -f "$PGDATA/PG_VERSION" ] && return 0
  [ -f "$PGBACKREST_RESTORED_MARKER" ] && return 0

  echo "pgbackrest: empty PGDATA + recovery target — restoring from source bucket"

  install -d -m 0700 -o postgres -g postgres "$PGDATA"

  # Recovery uses a dedicated config that has only the source bucket as its
  # one and only repo (named repo1 *within this file* — pgBackRest numbers
  # repos per-config). The default /etc/pgbackrest/pgbackrest.conf is
  # untouched and has only the service's own bucket, so archive_command
  # (post-promote) and stanza-create can never fan out to source's bucket.
  # The recovery conf is referenced by --config in both this restore call
  # and in the restore_command pgBackRest writes into postgresql.auto.conf.
  install -d -m 0750 -o postgres -g postgres /etc/pgbackrest
  cat > "$PGBACKREST_RECOVERY_S3_CONF" <<EOF
[global]
log-level-console=info
log-level-file=off
spool-path=${PGBACKREST_SPOOL_DIR}
repo1-type=s3
repo1-s3-bucket=${WAL_RECOVER_FROM_BUCKET}
repo1-s3-key=${WAL_RECOVER_FROM_KEY}
repo1-s3-key-secret=${WAL_RECOVER_FROM_SECRET}
repo1-s3-region=${WAL_RECOVER_FROM_REGION}
repo1-s3-endpoint=${WAL_RECOVER_FROM_ENDPOINT}
repo1-s3-uri-style=${WAL_RECOVER_FROM_S3_URI_STYLE:-path}
repo1-path=${WAL_RECOVER_FROM_PATH:-/pgbackrest}

[main]
pg1-path=${PGDATA}
pg1-port=5432
EOF
  chown postgres:postgres "$PGBACKREST_RECOVERY_S3_CONF"
  chmod 0640 "$PGBACKREST_RECOVERY_S3_CONF"

  # restore_command persisted in postgresql.auto.conf — references the
  # recovery conf so archive-get during replay reads from the source
  # bucket without touching the default config.
  local recovery_restore_cmd="pgbackrest --config=${PGBACKREST_RECOVERY_S3_CONF} --stanza=main archive-get %f %p"

  # Pick the recovery target type. _TYPE=immediate wins outright — there's
  # no target value, pgbackrest stops at end-of-base-backup consistency.
  # _XID wins over _TIME for the idle-source-safe rationale:
  # recovery_target_time requires postgres to observe a WAL record with
  # timestamp > target before declaring "target reached" and firing
  # recovery_target_action=promote; on an idle DB no such record exists,
  # so recovery FATALs with "recovery ended before configured recovery
  # target was reached" and the cluster either loops the FATAL or hangs
  # in hot_standby read-only mode. recovery_target_xid matches an exact
  # transaction ID — applying the target xid's commit is unambiguously
  # "target reached." The picker (mono's volumeInstancePITRRestore
  # mutation) sets _XID when it clamped target down to lastCommittedTxnAt,
  # sets _TYPE=immediate when the source has zero tracked commits and
  # there's no time/xid to pin to.
  local pgbackrest_args=(
    --config="$PGBACKREST_RECOVERY_S3_CONF"
    --stanza=main
    --pg1-path="$PGDATA"
    --recovery-option="restore_command=$recovery_restore_cmd"
    restore
    --target-action=promote
  )
  local restore_label
  if [ "${POSTGRES_RECOVERY_TARGET_TYPE:-}" = "immediate" ]; then
    pgbackrest_args+=( --type=immediate )
    restore_label="immediate"
    echo "pgbackrest: using --type=immediate (restore-to-base-backup; no target value, no commit-timestamp anchor needed)"
  elif [ -n "${POSTGRES_RECOVERY_TARGET_XID:-}" ]; then
    pgbackrest_args+=( --type=xid --target="$POSTGRES_RECOVERY_TARGET_XID" )
    restore_label="xid=${POSTGRES_RECOVERY_TARGET_XID}"
    echo "pgbackrest: using recovery_target_xid=${POSTGRES_RECOVERY_TARGET_XID} (idle-source-safe; target-time fallback would FATAL on no-record-after-target)"
  else
    pgbackrest_args+=( --type=time --target="$POSTGRES_RECOVERY_TARGET_TIME" )
    restore_label="time=${POSTGRES_RECOVERY_TARGET_TIME}"
  fi

  # --pg1-path is taken from $PGDATA so this works in restore-only mode too,
  # where render_pgbackrest_conf has been called but didn't include repo2.
  if ! gosu postgres pgbackrest "${pgbackrest_args[@]}"; then
    echo "pgbackrest: restore from source bucket failed; fix env vars (WAL_RECOVER_FROM_*, POSTGRES_RECOVERY_TARGET_TIME, POSTGRES_RECOVERY_TARGET_XID, POSTGRES_RECOVERY_TARGET_TYPE) and redeploy" >&2
    exit 1
  fi

  touch "$PGBACKREST_RESTORED_MARKER"
  chown postgres:postgres "$PGBACKREST_RESTORED_MARKER" 2>/dev/null || true

  echo "pgbackrest: restore complete (${restore_label}); postgres will replay forward and promote on first start"
}

# Fork the backup watcher. Subshell pattern matches bootstrap_pgbackrest_stanza
# — gosu drops to postgres so the watcher's psql calls use peer auth via the
# Unix socket and `pgbackrest backup` runs as the right uid. The watcher gates
# itself on WAL_ARCHIVE_BUCKET / WAL_RECOVER_FROM_BUCKET internally, so the
# fork is unconditional and cheap when archiving isn't on.
fork_pgbackrest_backup_watcher() {
  [ -z "${WAL_ARCHIVE_BUCKET:-}" ] && return 0
  gosu postgres /usr/local/bin/pgbackrest-backup-watcher.sh &
}

render_pgbackrest_conf
restore_from_pgbackrest_if_empty_volume
clear_pgbackrest_state_if_disabled
apply_pgbackrest_archive_conf
configure_pgbackrest_recovery

# After a pgbackrest restore the volume's certs/ dir is empty: pgbackrest only
# backs up PGDATA (`/var/lib/postgresql/data/pgdata`), and certs live one
# directory up at `/var/lib/postgresql/data/certs`. The cert-generation block
# at the top of this script ran before restore — at that point PGDATA was
# empty, so its "postgresql.conf exists AND cert missing → regenerate" branch
# didn't fire. Re-check now that the volume is in its final state. We only
# regenerate cert files; postgresql.conf is already restored from source and
# already references these paths, so we don't re-run init-ssl.sh (which would
# append duplicate ssl_*_file lines and clobber any custom
# shared_preload_libraries with `'pg_stat_statements'`).
if [ -f "$POSTGRES_CONF_FILE" ] && [ ! -f "$SSL_DIR/server.crt" ]; then
  echo "Generating SSL certs after restore (cert files were not in pgbackrest backup)..."
  sudo mkdir -p "$SSL_DIR"
  sudo chown postgres:postgres "$SSL_DIR"
  openssl req -new -x509 -days "${SSL_CERT_DAYS:-820}" -nodes -text \
    -out "$SSL_DIR/root.crt" -keyout "$SSL_DIR/root.key" -subj "/CN=root-ca"
  chmod og-rwx "$SSL_DIR/root.key"
  openssl req -new -nodes -text \
    -out "$SSL_DIR/server.csr" -keyout "$SSL_DIR/server.key" -subj "/CN=localhost"
  chown postgres:postgres "$SSL_DIR/server.key"
  chmod og-rwx "$SSL_DIR/server.key"
  cat >| "$SSL_DIR/v3.ext" <<EOF
[v3_req]
authorityKeyIdentifier = keyid, issuer
basicConstraints = critical, CA:TRUE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = DNS:localhost
EOF
  openssl x509 -req -in "$SSL_DIR/server.csr" -extfile "$SSL_DIR/v3.ext" \
    -extensions v3_req -text -days "${SSL_CERT_DAYS:-820}" \
    -CA "$SSL_DIR/root.crt" -CAkey "$SSL_DIR/root.key" -CAcreateserial \
    -out "$SSL_DIR/server.crt"
  chown postgres:postgres "$SSL_DIR/server.crt"
fi

# Unset PG* libpq env vars BEFORE forking pgbackrest's stanza-create / watcher
# subshells. Customer-set PGHOST=${{ Postgres.RAILWAY_PRIVATE_DOMAIN }} (a
# common app-side pattern) leaks into pgbackrest's libpq calls — pgbackrest
# then tries to connect to itself via the privnet domain and times out
# (`unable to find primary cluster`). A local-only connection is what we want
# from inside the container; clearing PGHOST/PGPORT lets libpq fall back to
# the Unix socket.
unset PGHOST
unset PGPORT

bootstrap_pgbackrest_stanza
fork_pgbackrest_backup_watcher

# Call the entrypoint script with the
# appropriate PGHOST & PGPORT and redirect
# the output to stdout if LOG_TO_STDOUT is true
if [[ "$LOG_TO_STDOUT" == "true" ]]; then
    /usr/local/bin/docker-entrypoint.sh "$@" 2>&1
else
    /usr/local/bin/docker-entrypoint.sh "$@"
fi
