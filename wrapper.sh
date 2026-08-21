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

# Strip trailing slashes from PGDATA. Postgres itself tolerates them, but
# the major-upgrade job builds sibling paths by appending to $PGDATA
# ("${PGDATA}.upgrade-<to>"), so a value with a trailing slash must never be
# allowed to take root on a volume — normalize here exactly like
# upgrade-job.sh does, so both programs agree on every derived path.
while [ "${PGDATA%/}" != "$PGDATA" ] && [ -n "${PGDATA%/}" ]; do PGDATA="${PGDATA%/}"; done
export PGDATA

# check if PGDATA starts with the expected volume mount path
# this ensures data files are stored in the correct location
# if not, print error and exit to prevent data loss or access issues
if [[ ! "$PGDATA" =~ ^"$EXPECTED_VOLUME_MOUNT_PATH" ]]; then
  echo "PGDATA variable does not start with the expected volume mount path, expected to start with $EXPECTED_VOLUME_MOUNT_PATH"
  echo "Please update the PGDATA variable to start with the expected volume mount path and redeploy the service"
  exit 1
fi

# -----------------------------------------------------------------------------
# Volume-lifetime lock shared with the major-upgrade job. upgrade-job.sh
# holds this file EXCLUSIVELY (flock -n) for its whole run; the runtime
# holds it SHARED for the container's lifetime. Together they make both
# races refuse instead of corrupting: a job dispatched against a live
# database fails its exclusive lock, and a database deployed while a job is
# mid-flight fails here. The fd is opened by THIS shell, which stays alive
# as PID 1 (docker-entrypoint.sh below is a child, not an exec), so the
# lock is held exactly as long as the container regardless of what postgres
# does with its inherited copy of the fd — closing a duplicate descriptor
# does not release a flock while the original stays open.
#
# Legacy PGDATA-at-the-volume-root layouts skip the lock on first init:
# creating the lock file inside an empty PGDATA would make docker-entrypoint
# skip initdb (it checks `ls -A`), and that layout can't take an in-place
# upgrade anyway (no sibling slot on the volume for the new data dir).
# -----------------------------------------------------------------------------
UPGRADE_LOCK_FILE="$EXPECTED_VOLUME_MOUNT_PATH/.railway-major-upgrade.lock"
if command -v flock >/dev/null 2>&1 && [ -d "$EXPECTED_VOLUME_MOUNT_PATH" ] \
  && ! { [ "$PGDATA" = "$EXPECTED_VOLUME_MOUNT_PATH" ] && [ ! -f "$PGDATA/PG_VERSION" ]; }; then
  # The 2>/dev/null MUST be scoped by the brace group, never put on the exec
  # itself: redirections on a bare `exec` are permanent for the shell, so
  # `exec 8>>file 2>/dev/null` would silence stderr for THIS SHELL AND
  # EVERYTHING IT SPAWNS — postgres's entire log stream and pgBackRest's
  # archive errors would vanish from `docker logs`. The brace group scopes
  # the stderr redirect to the open attempt; the fd opened by exec is
  # permanent either way.
  if { exec 8>>"$UPGRADE_LOCK_FILE"; } 2>/dev/null; then
    if ! flock -n -s 8; then
      echo "A major version upgrade job is currently running against this volume."
      echo "The database must not start until it finishes; retry the deploy once the upgrade completes."
      exit 1
    fi
  else
    echo "wrapper: could not open $UPGRADE_LOCK_FILE; continuing without the upgrade lock" >&2
  fi
fi

# -----------------------------------------------------------------------------
# Runtime lock: at most one postgres container touches this volume at a time.
# Held EXCLUSIVELY (fd 9) for the container's lifetime, same shell-as-PID-1
# mechanics as the upgrade lock above — the kernel releases it only when the
# last process holding the open description exits, so "lock free" really
# means every process of the previous container is gone, however that
# container ended (graceful stop, SIGKILL, OOM).
#
# Why: a redeploy can leave the old and new containers briefly overlapping
# on the shared volume. The stale-postmaster.pid removal below cannot see
# the old container's postgres (different PID namespace), and worse, a
# still-shutting-down old postmaster unlinks postmaster.pid on its way out
# — deleting the file the NEW postgres just wrote. Postgres treats a missing
# lock file as fatal on its once-per-minute recheck and shuts itself down.
# Waiting on the previous holder before touching the data directory closes
# both directions of that race.
#
# Fail-stop on timeout: refusing to boot (the restart policy retries) beats
# starting a second postmaster against a volume the previous one may still
# be using. Same legacy-layout skip as the upgrade lock: never create files
# inside an empty PGDATA-at-the-volume-root, or docker-entrypoint skips
# initdb.
# -----------------------------------------------------------------------------
RUNTIME_LOCK_FILE="$EXPECTED_VOLUME_MOUNT_PATH/.railway-postgres-runtime.lock"
RUNTIME_LOCK_WAIT_SECONDS="${RUNTIME_LOCK_WAIT_SECONDS:-300}"
# Must be a whole number of seconds: `flock -w` rejects anything else with a
# usage error, whose non-zero exit is indistinguishable from a hold timeout
# below — so a typo'd override would surface as "previous container did not
# release the volume" and instant-fail every boot DURING a real overlap,
# exactly when the wait matters. Fall back loudly instead.
case "$RUNTIME_LOCK_WAIT_SECONDS" in
  ''|*[!0-9]*)
    echo "wrapper: RUNTIME_LOCK_WAIT_SECONDS='${RUNTIME_LOCK_WAIT_SECONDS}' is not a whole number of seconds; using 300" >&2
    RUNTIME_LOCK_WAIT_SECONDS=300
    ;;
esac
if command -v flock >/dev/null 2>&1 && [ -d "$EXPECTED_VOLUME_MOUNT_PATH" ] \
  && ! { [ "$PGDATA" = "$EXPECTED_VOLUME_MOUNT_PATH" ] && [ ! -f "$PGDATA/PG_VERSION" ]; }; then
  # Brace-group-scoped stderr for the same reason as the upgrade lock above.
  if { exec 9>>"$RUNTIME_LOCK_FILE"; } 2>/dev/null; then
    if ! flock -n -x 9; then
      echo "wrapper: another postgres container still holds this volume (overlapping deploy); waiting up to ${RUNTIME_LOCK_WAIT_SECONDS}s for it to shut down"
      if ! flock -w "$RUNTIME_LOCK_WAIT_SECONDS" -x 9; then
        echo "wrapper: previous container did not release the volume within ${RUNTIME_LOCK_WAIT_SECONDS}s; refusing to start postgres on a volume another postmaster may still be using"
        exit 1
      fi
      echo "wrapper: previous container released the volume; continuing boot"
    fi
  else
    echo "wrapper: could not open $RUNTIME_LOCK_FILE; continuing without the runtime lock" >&2
  fi
fi

# -----------------------------------------------------------------------------
# Major-version guards. Both are fail-stop and loud, and both run before
# anything touches the data directory, so a mismatched boot can never corrupt
# data or initdb over a half-swapped upgrade.
#
# 1. A major-upgrade marker (written by the upgrade job image) in any phase
#    other than "completed" means the volume is mid-upgrade: the data
#    directory may be absent or half-swapped. Refuse to boot; the upgrade
#    workflow resolves it (roll forward or roll back), never this container.
# 2. On-disk PG_VERSION must match this image's major. Postgres itself would
#    refuse anyway, but deep in startup with a confusing error; failing here
#    names the actual problem and the fix. A fresh volume (no PG_VERSION)
#    skips the check — that's first init.
# -----------------------------------------------------------------------------
UPGRADE_MARKER_FILE="$EXPECTED_VOLUME_MOUNT_PATH/.railway-major-upgrade.json"
if [ -f "$UPGRADE_MARKER_FILE" ]; then
  # `|| true` so an unreadable marker still lands in the fail-stop branch
  # below instead of tripping set -e with no message.
  MARKER_PHASE=$(jq -r '.phase // empty' "$UPGRADE_MARKER_FILE" 2>/dev/null || true)
  if [ "$MARKER_PHASE" != "completed" ]; then
    echo "A major version upgrade is in progress on this volume (marker phase: ${MARKER_PHASE:-unreadable})."
    echo "The database must not start until the upgrade workflow finishes or rolls back."
    exit 1
  fi
fi

# The marker above catches every phase pg_upgrade writes one for — but the
# upgrade job only writes its FIRST marker on pg_upgrade's own success, so a
# crash DURING pg_upgrade --link leaves no marker at all. pg_upgrade renames
# global/pg_control to .old before it links the first relation file (its own
# recovery advice is to rename it back), so this exact shape — .old present,
# the real file absent — means a link was interrupted. PG_VERSION at the
# PGDATA root is untouched by that rename, so it still matches THIS image's
# major and the version-mismatch guard below would not catch it either;
# without this check postgres would fail deep in startup with a bare "could
# not open file "global/pg_control"" instead of naming the actual cause.
if [ -f "$PGDATA/global/pg_control.old" ] && [ ! -f "$PGDATA/global/pg_control" ]; then
  echo "This looks like an interrupted major version upgrade: pg_control is disabled (renamed to pg_control.old),"
  echo "the shape pg_upgrade leaves if it crashes mid-link. A database major-version-upgrade job resolves this"
  echo "volume; starting postgres against it directly will fail."
  exit 1
fi

# Belt-and-suspenders for a crash between finish_swap's two renames: PGDATA
# itself is gone at that point (renamed to .old-<from>), so neither guard
# above has anything to check — the pg_control.old one above looks under
# $PGDATA, which no longer exists. No legitimate first init ever has
# upgrade-job sibling directories sitting next to an empty/missing PGDATA;
# only a job that started swapping directories and never finished does.
# Without this, docker-entrypoint would initdb a fresh empty cluster over
# what's actually a split, unfinished upgrade sitting in those siblings.
if [ ! -f "$PGDATA/PG_VERSION" ] \
  && { compgen -G "${PGDATA}.upgrade-*" >/dev/null 2>&1 || compgen -G "${PGDATA}.old-*" >/dev/null 2>&1; }; then
  echo "PGDATA is empty or missing, but upgrade-job sibling directories exist next to it"
  echo "(${PGDATA}.upgrade-* / ${PGDATA}.old-*) — this looks like an interrupted major version"
  echo "upgrade caught mid-swap, not a fresh volume. A database major-version-upgrade job"
  echo "resolves this volume; starting postgres against it directly would initdb a new, empty"
  echo "cluster over real data sitting in those siblings."
  exit 1
fi

# The image's own major, for the mismatch guard. Filesystem first, PG_MAJOR
# env second — deliberately in that order (mirrors postgres-ha's
# image_major()): the installed server tree under /usr/lib/postgresql is
# baked into the image and nothing at deploy time can change it, while
# PG_MAJOR is an env var a service variable can override — trusted alone, a
# stray user-set PG_MAJOR=16 on a 17 image would refuse every boot of a
# perfectly matched data directory. Exactly one numeric entry = the image's
# major; zero or several (never true for runtime images) falls back to the
# env; neither = the guard abstains.
detect_image_major() {
  local d name majors=()
  for d in /usr/lib/postgresql/*/; do
    [ -d "$d" ] || continue
    name="${d%/}"; name="${name##*/}"
    case "$name" in ''|*[!0-9]*) continue ;; esac
    majors+=("$name")
  done
  if [ "${#majors[@]}" -eq 1 ]; then
    if [ -n "${PG_MAJOR:-}" ] && [ "$PG_MAJOR" != "${majors[0]}" ]; then
      echo "wrapper: PG_MAJOR=${PG_MAJOR} disagrees with the installed server tree (${majors[0]}); trusting the filesystem — a service variable can override the env, not the image contents" >&2
    fi
    echo "${majors[0]}"
    return 0
  fi
  echo "${PG_MAJOR:-}"
}

IMAGE_MAJOR=$(detect_image_major)
if [ -f "$PGDATA/PG_VERSION" ]; then
  DATA_MAJOR=$(cat "$PGDATA/PG_VERSION")
  if [ -n "$IMAGE_MAJOR" ] && [ "$DATA_MAJOR" != "$IMAGE_MAJOR" ]; then
    echo "This image runs PostgreSQL $IMAGE_MAJOR but the data directory holds major version $DATA_MAJOR."
    echo "Changing the image tag does not upgrade the data files. Set the image back to postgres $DATA_MAJOR,"
    echo "or run a major version upgrade from the service's settings."
    exit 1
  fi
fi

# Set up needed variables
SSL_DIR="/var/lib/postgresql/data/certs"
INIT_SSL_SCRIPT="/docker-entrypoint-initdb.d/init-ssl.sh"
POSTGRES_CONF_FILE="$PGDATA/postgresql.conf"

# H1 (audit follow-up): clear stale postmaster.pid. wrapper.sh runs once
# at container start — no postgres has been spawned yet — so any
# postmaster.pid on disk is from a previous container that didn't get a
# graceful shutdown (docker rm -f sends SIGKILL; the kernel reaps
# postgres before it can remove its pid file).
#
# Postgres normally self-heals: on start it reads postmaster.pid, calls
# kill(pid, 0), and removes the file if the PID is dead. The trouble in
# a container is that postgres ALSO checks if the PID belongs to the
# same UID — and the watcher's psql/pg_isready subprocesses run as the
# same postgres UID, so the stale PID number often points at a live
# (unrelated) watcher subprocess. postgres reads same-UID + alive →
# concludes "another postmaster is already running" → FATAL.
#
# Removing the file unconditionally here is safe because (a) wrapper.sh
# is the container entrypoint and runs exactly once per container, (b)
# no postgres process is running at this point, and (c) docker
# guarantees only one wrapper.sh per container instance. Avoids the
# need for a graceful-shutdown handoff that re-parents children onto
# postmaster (postmaster panics with SIGCHLD on unknown children).
#
# "No postgres running" additionally covers OTHER containers on this
# volume once the runtime lock (fd 9, above) is held: any previous
# container running this image keeps that lock until its last process
# exits, so reaching this line means no lock-honoring postmaster can
# still be alive on the volume. A previous container from an image
# WITHOUT the lock can still overlap; the unasked-clean-exit shaping at
# the bottom of this file is what recovers that case.
if [ -f "$PGDATA/postmaster.pid" ]; then
  echo "wrapper: removing stale $PGDATA/postmaster.pid (no postgres running at container start)"
  rm -f "$PGDATA/postmaster.pid" 2>/dev/null || true
fi

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

# Re-apply the ssl settings when the certificates exist but postgresql.conf
# doesn't reference them. The checks above are keyed on the CERTIFICATE, which
# lives at the volume root and therefore survives anything that replaces the
# data directory — a major upgrade promotes a freshly initdb'd $PGDATA, so
# postgresql.conf loses `ssl = on` while server.crt is still right there. The
# result is a database that silently comes back with SSL off, rejecting every
# sslmode=require client. Keying this on the CONFIG instead self-heals that
# and any other path that resets postgresql.conf.
if [ -f "$POSTGRES_CONF_FILE" ] && [ -f "$SSL_DIR/server.crt" ] \
  && ! grep -qE "^[[:space:]]*ssl[[:space:]]*=" "$POSTGRES_CONF_FILE"; then
  echo "wrapper: postgresql.conf has no ssl settings but certificates exist, re-applying"
  cat >> "$POSTGRES_CONF_FILE" <<EOF
ssl = on
ssl_cert_file = '$SSL_DIR/server.crt'
ssl_key_file = '$SSL_DIR/server.key'
ssl_ca_file = '$SSL_DIR/root.crt'
EOF
fi

# Re-append the remote-access rule when pg_hba.conf has been reset to
# initdb's defaults. The official entrypoint writes `host all all all
# <method>` ONCE, at initdb time — any path that regenerates pg_hba.conf
# afterwards (a major upgrade promotes a freshly initdb'd data directory;
# the upgrade job carries the old pg_hba across, but this heals every other
# route too) leaves only initdb's default local/loopback lines, so the
# database comes back healthy-looking while EVERY remote client fails with
# "no pg_hba.conf entry". The method mirrors the entrypoint's default.
#
# The heal fires ONLY on the recognizable bare-initdb shape: loopback host
# rules present, and no host-family rule with any other address. Anything
# else is an authored policy and is left alone — a config the operator
# narrowed by address (`host all all 10.0.0.0/8 …`), by database/user
# (`host mydb appuser all …`), or by TLS (`hostssl …`) must never get a
# wide-open `host all all all` silently appended under it: pg_hba is
# first-match-wins, so the append would re-admit exactly the clients the
# narrowing excluded. Likewise a file with NO host rules at all is a
# deliberate local-only lockdown, not an initdb reset (initdb always writes
# the loopback lines).
PG_HBA_FILE="$PGDATA/pg_hba.conf"
hba_has_loopback_host_rule() {
  grep -qE "^[[:space:]]*host([[:space:]]+[^[:space:]]+){2}[[:space:]]+(127\.0\.0\.1/32|::1/128)([[:space:]]|$)" "$PG_HBA_FILE"
}
hba_has_authored_host_rule() {
  grep -E "^[[:space:]]*host(ssl|nossl|gssenc|nogssenc)?[[:space:]]" "$PG_HBA_FILE" \
    | grep -vE "[[:space:]](127\.0\.0\.1/32|::1/128)([[:space:]]|$)" | grep -q .
}
if [ -f "$POSTGRES_CONF_FILE" ] && [ -f "$PG_HBA_FILE" ] \
  && hba_has_loopback_host_rule && ! hba_has_authored_host_rule; then
  echo "wrapper: pg_hba.conf holds only initdb's loopback host rules, re-appending the remote-access rule (remote clients would be refused)"
  cat >> "$PG_HBA_FILE" <<EOF

host all all all ${POSTGRES_HOST_AUTH_METHOD:-scram-sha-256}
EOF
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

# Raise max_connections so PgBouncer (3 replicas × default_pool_size=20 = 60
# backend connections) doesn't exhaust the PostgreSQL default of 100. Writing
# to auto.conf overrides postgresql.conf without touching the file Postgres
# manages itself. Skipped if already set (e.g. via ALTER SYSTEM by the user).
if [ -f "$POSTGRES_CONF_FILE" ] && ! grep -q "^[[:space:]]*max_connections" "$AUTO_CONF_FILE" 2>/dev/null; then
  echo "wrapper: setting max_connections = 500 in postgresql.auto.conf"
  echo "max_connections = 500" >> "$AUTO_CONF_FILE"
fi
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
# archive_mode = 'off'` (or `ALTER SYSTEM SET track_commit_timestamp = 'off'`,
# which silently degrades the PITR picker's `recovery_target_time` ceiling
# to lastArchivedAt) still wins; the dashboard surfaces the divergence
# from the image's intended state by reading pg_settings.
#
# pgBackRest pushes WAL direct to S3 (no intermediary service). It runs in
# async mode: archive_command writes WAL into the local spool dir and
# returns in milliseconds; a background worker pushes from there to S3.
# Two thresholds gate the "WAL is accumulating, do something", sized
# identically (see compute_volume_thresholds) AND checked as ONE shared
# budget, not two independent ones:
#   - archive-push-queue-max (set in /etc/pgbackrest/pgbackrest.conf) governs
#     the SPOOL. pgBackRest drops segments from spool and reports success to
#     archive_command once this is exceeded.
#   - pgbackrest-archive-push-wrapper.sh's WAL_DROP_THRESHOLD_MB governs
#     pg_wal/ + spool COMBINED. Trips when pgbackrest's foreground returns
#     non-zero and pg_wal-plus-spool has grown past this size.
# Both size to 5 GiB on volumes ≥10 GiB, scaling down to ~50% of volume below
# that, floor 128 MiB — a transient S3 stall (500s, timeouts, connection
# resets — the async worker keeps retrying and most segments eventually get
# pushed) gets the full budget before either threshold trips, instead of the
# wrapper's old 10x-smaller pg_wal-only cap giving up first. Checking the
# wrapper's threshold against the SUM (not pg_wal alone) matters because
# pg_wal and the spool can both be filling for different reasons at once
# (foreground copy-to-spool failing vs. background upload stalled) — without
# summing, the two caps could each independently reach 5 GiB, letting a
# single outage hold up to ~2x the intended budget on disk. Only the two
# explicit no-recovery-possible errors (NoSuchBucket, InvalidAccessKeyId —
# see pgbackrest-archive-push-wrapper.sh) bypass this and drop immediately,
# since no amount of waiting helps those.
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

# Identity fingerprint of the cluster the repo-path marker was derived from
# (`sysid=` + `pg_version=`), written next to the marker every time the marker
# is derived. The marker on its own cannot say whether it still belongs to the
# cluster on disk — it is a bare path that wins VERBATIM over derivation, by
# design, so that the effective repo path is stable across boots. When the
# cluster underneath it is REPLACED (pg_upgrade initdb's a new cluster: new
# system_identifier and new PG_VERSION), a marker that outlives the swap keeps
# archiving into the previous cluster's repo — archive-push then fails against
# that repo's archive.info forever and stanza-create errors on the system-id
# mismatch. Comparing this fingerprint against the live values on every boot
# catches that whatever the cause, which is the point: the major-upgrade
# marker is deleted/aged out eventually, and a cluster re-identified by any
# other route needs exactly the same handling.
#
# Holds no path on purpose. The marker is the sole authority on the active
# path, so there is nothing here that can drift out of sync with it — and a
# WAL_REGRESSION migration (which re-points the path of a cluster whose
# identity did NOT change) must not look like a re-identification.
PGBACKREST_REPO_ANCHOR_FILE="$PGDATA/.pgbackrest_repo_anchor"

# Sentinel: WAL_ARCHIVE_BUCKET was set to something we couldn't honor (an
# unresolved Railway template ref, a bucket-id UUID, whitespace, …). The
# monitor reads this to distinguish "PITR was never enabled" from "PITR is
# enabled but wired to junk." Lives under PGDATA so it survives container
# restarts and gets wiped with the volume.
PGBACKREST_INVALID_BUCKET_MARKER="$PGDATA/.pgbackrest_invalid_bucket"

# Screen WAL_ARCHIVE_BUCKET for known-bogus shapes before any code path
# consumes it. If invalid, unset the WAL_ARCHIVE_* vars so every existing
# `[ -z "${WAL_ARCHIVE_BUCKET:-}" ]` gate downstream treats archiving as
# off — same behavior as "never enabled." Without this, an unresolved
# `${{<bucket-id>.BUCKET}}` would land in /etc/pgbackrest/pgbackrest.conf
# verbatim; pgBackRest would then hard-fail every archive_command and
# pgbackrest-archive-push-wrapper.sh's 500 MiB WAL-drop threshold would
# eventually trip — creating a real, unrecoverable PITR gap from what is
# really an upstream wiring bug. The sentinel file lets the dashboard
# surface this state distinctly from the no-config and unresolvable-creds
# states.
#
# Caught shapes:
#   - empty → already handled by existing gates; no-op here.
#   - contains `${{` or `}}` → unresolved Railway template ref.
#   - UUID 8-4-4-4-12 hex → almost certainly a raw bucket-id from a
#     tombstoned bucket (resolver failed to map id → name).
#   - whitespace or control chars → typo or shell-escape mishap.
validate_wal_archive_bucket() {
  local val="${WAL_ARCHIVE_BUCKET:-}"
  [ -z "$val" ] && { rm -f "$PGBACKREST_INVALID_BUCKET_MARKER" 2>/dev/null || true; return 0; }

  local invalid=""
  case "$val" in
    *'${{'*|*'}}'*) invalid="unresolved-template-ref" ;;
    *[[:space:]]*) invalid="whitespace" ;;
  esac
  # UUID-shape rejection: catches Railway internal bucket-id leaks from a
  # failed resolver. WAL_ARCHIVE_BUCKET_ALLOW_UUID=1 is the escape hatch for
  # the rare customer who legitimately uses a UUID-named bucket.
  if [ -z "$invalid" ] \
    && [ "${WAL_ARCHIVE_BUCKET_ALLOW_UUID:-0}" != "1" ] \
    && echo "$val" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    invalid="uuid-shape"
  fi

  if [ -n "$invalid" ]; then
    if [ "$invalid" = "uuid-shape" ]; then
      echo "pgbackrest: WAL_ARCHIVE_BUCKET=\"${val}\" looks invalid (uuid-shape); refusing to enable archiving. If this UUID is your legitimate bucket name, set WAL_ARCHIVE_BUCKET_ALLOW_UUID=1 to override." >&2
    else
      echo "pgbackrest: WAL_ARCHIVE_BUCKET=\"${val}\" looks invalid (${invalid}); refusing to enable archiving" >&2
    fi
    # Export so pgbackrest-init.sh can write the sentinel during initdb.
    # Writing to PGDATA here would break initdb on a fresh volume:
    # docker-entrypoint.sh skips initdb when `ls -A "$PGDATA"` is non-empty,
    # even for hidden files — postgres then tries to start from uninitialized
    # data and fails. On an already-initialized volume (PG_VERSION exists)
    # initdb hooks don't run, so write the sentinel here instead.
    export PGBACKREST_BUCKET_INVALID_REASON="$invalid"
    if [ -f "$PGDATA/PG_VERSION" ]; then
      printf '%s\n' "${invalid}" > "$PGBACKREST_INVALID_BUCKET_MARKER" 2>/dev/null || true
      chown postgres:postgres "$PGBACKREST_INVALID_BUCKET_MARKER" 2>/dev/null || true
      chmod 0640 "$PGBACKREST_INVALID_BUCKET_MARKER" 2>/dev/null || true
    fi
    unset WAL_ARCHIVE_BUCKET WAL_ARCHIVE_KEY WAL_ARCHIVE_SECRET
    unset WAL_ARCHIVE_REGION WAL_ARCHIVE_ENDPOINT
    return 0
  fi

  rm -f "$PGBACKREST_INVALID_BUCKET_MARKER" 2>/dev/null || true
}
validate_wal_archive_bucket

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

# The cluster's on-disk major. Empty pre-initdb. `|| true` because this file
# runs under `set -e` and an unreadable PG_VERSION must never abort the boot.
read_postgres_major() {
  [ ! -f "$PGDATA/PG_VERSION" ] && return 0
  cat "$PGDATA/PG_VERSION" 2>/dev/null || true
}

# Field reader for the anchor file. Empty when the file or the field is absent.
# grep sits mid-pipeline so a no-match exits 0 overall — a bare `grep` here
# would abort the boot under `set -e` the first time a field is missing.
read_pgbackrest_anchor_field() {
  local field="$1"
  [ ! -f "$PGBACKREST_REPO_ANCHOR_FILE" ] && return 0
  grep -E "^${field}=" "$PGBACKREST_REPO_ANCHOR_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

# Record which cluster the current repo-path marker belongs to. tmp+rename so
# a reader never sees a half-written fingerprint, and so a crash can only ever
# leave the PREVIOUS anchor in place — which is what makes the re-anchor
# retryable (see reanchor_pgbackrest_repo_path_if_reidentified).
write_pgbackrest_repo_anchor() {
  local sysid="$1" major="$2" tmp
  [ -z "$sysid" ] && return 1
  [ -z "$major" ] && return 1
  tmp=$(mktemp "${PGBACKREST_REPO_ANCHOR_FILE}.XXXX") || return 1
  printf 'sysid=%s\npg_version=%s\n' "$sysid" "$major" > "$tmp" || { rm -f "$tmp"; return 1; }
  chown postgres:postgres "$tmp" 2>/dev/null || true
  chmod 0640 "$tmp" 2>/dev/null || true
  mv "$tmp" "$PGBACKREST_REPO_ANCHOR_FILE" || { rm -f "$tmp"; return 1; }
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
  # Fingerprint the cluster this path was derived FROM, so a later boot can
  # tell whether the marker still belongs to the cluster on disk. Written here
  # rather than inside the marker writer: the marker writer is also the flip
  # step of a re-anchor, where the anchor must land last, as the commit point.
  write_pgbackrest_repo_anchor "$sysid" "$(read_postgres_major)" \
    || echo "pgbackrest: could not write the repo-path anchor for cluster ${sysid}" >&2
  echo "$cluster_path"
}

# tmp+rename: the archive-push wrapper `cat`s this file on every WAL switch,
# so a reader must see either the whole old path or the whole new one — same
# reasoning as the watcher's apply_active_path, which is the other writer.
write_pgbackrest_repo_path_marker() {
  local path="$1" tmp
  [ -z "$path" ] && return 1
  tmp=$(mktemp "${PGBACKREST_REPO_PATH_MARKER}.XXXX") || return 1
  printf '%s\n' "$path" > "$tmp" || { rm -f "$tmp"; return 1; }
  chown postgres:postgres "$tmp" 2>/dev/null || true
  chmod 0640 "$tmp" 2>/dev/null || true
  mv "$tmp" "$PGBACKREST_REPO_PATH_MARKER" || { rm -f "$tmp"; return 1; }
}

# Replace the backup watcher's state file with nothing but the migration gate
# (`archive_migration_pending_new_path`). Releasing the gate is the separate,
# field-preserving clear_backup_state_migration_gate below — never this.
#
# Replaced rather than edited because every field in it describes backups at
# the OLD path. Clearing last_full_at is what trips the watcher's
# NEEDS_INITIAL_BACKUP, so an immediate full fires at the new path; every other
# field the watcher reads defaults sanely when absent.
#
# The gate itself is the watcher's own migration interlock (see
# pgbackrest-backup-watcher.sh): while set, the watcher takes no backups and
# keeps retrying the spool cleanup. Setting it BEFORE the marker flip means a
# re-anchor that dies halfway can never leave the watcher backing up against
# stale old-path async statuses.
#
# Safe to write wholesale because the watcher is forked strictly after this
# runs — wrapper.sh has no concurrent writer at this point in the boot.
#
# Every call here follows a genuine re-identification (this function's only
# caller, reanchor_pgbackrest_repo_path_if_reidentified, returns early unless
# anchor_sysid/anchor_major mismatched the live cluster) — never the
# watcher's own same-cluster WAL_REGRESSION retries, which manage
# archive_migration_orig_path entirely on their own (read_state /
# write_state_field_required) and never call this function. So any
# archive_migration_orig_path already on disk belongs to the OLD identity's
# suffix chain: carrying it into the new one would compose the new cluster's
# next WAL_REGRESSION migration off the old family (cluster-<OLD
# SYSID>-<epoch>) instead of the new one. Wholesale-replace really does mean
# wholesale — there is no field to preserve.
write_backup_state_migration_gate() {
  local new_path="$1" state_file="$PGDATA/.pgbackrest_backup_state" tmp
  tmp=$(mktemp "${state_file}.XXXX") || return 1
  if ! printf 'archive_migration_pending_new_path=%s\n' "$new_path" > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  chown postgres:postgres "$tmp" 2>/dev/null || true
  chmod 0640 "$tmp" 2>/dev/null || true
  mv "$tmp" "$state_file" || { rm -f "$tmp"; return 1; }
}

# Release the watcher's migration gate WITHOUT touching the rest of its
# state. The gate-SET path deliberately replaces the whole file (see
# write_backup_state_migration_gate), but the CLEAR must not: on the
# re-anchor RETRY path (marker already flipped by an earlier attempt whose
# final anchor write failed) the state file holds real post-migration
# watcher state — a last_full_at from a full that already landed at the new
# path — and wiping it would re-arm NEEDS_INITIAL_BACKUP into one redundant
# full upload per boot until the anchor write finally succeeds.
clear_backup_state_migration_gate() {
  local state_file="$PGDATA/.pgbackrest_backup_state" tmp
  [ ! -f "$state_file" ] && return 0
  tmp=$(mktemp "${state_file}.XXXX") || return 1
  grep -vE "^archive_migration_pending_new_path=" "$state_file" > "$tmp" 2>/dev/null || true
  chown postgres:postgres "$tmp" 2>/dev/null || true
  chmod 0640 "$tmp" 2>/dev/null || true
  mv "$tmp" "$state_file" || { rm -f "$tmp"; return 1; }
}

# Drop async status files left by the previous cluster. A stale `.ok` is the
# dangerous one: pgBackRest treats it as proof the segment was already pushed
# and skips the upload, so it would silently punch holes in the NEW path's WAL
# coverage. The spool is a coordination cache, never durable data — async
# re-pushes from pg_wal on the next archive_command.
#
# Unlike the watcher's mid-flight equivalent there is no async daemon to drain
# and kill here: wrapper.sh runs exactly once per container start, before any
# postmaster of ours exists, so nothing can be writing these files.
clean_archive_spool_statuses() {
  local out_dir="$PGBACKREST_SPOOL_DIR/archive/main/out"
  [ ! -d "$out_dir" ] && return 0
  rm -f "$out_dir"/*.ok "$out_dir"/*.error 2>/dev/null || true
  return 0
}

# Move archiving onto $2, leaving the previous cluster's archive at $1 intact.
# Split out from the detection so the ordering below is readable as a unit; see
# reanchor_pgbackrest_repo_path_if_reidentified for why the order is what it is.
reanchor_pgbackrest_repo_path() {
  local current_path="$1" new_path="$2"

  # `current_path == new_path` means an earlier attempt already flipped the
  # marker and then died before writing the anchor. The state reset always
  # PRECEDES the flip, so a flipped marker also implies the state was reset —
  # do not redo it (that would re-arm a full for a path that may already have
  # one) and just finish the tail.
  if [ "$current_path" != "$new_path" ]; then
    write_backup_state_migration_gate "$new_path" || {
      echo "pgbackrest: could not reset the backup-watcher state; leaving archiving at ${current_path}" >&2
      return 1
    }
    write_pgbackrest_repo_path_marker "$new_path" || {
      echo "pgbackrest: could not write the repo-path marker for ${new_path}" >&2
      return 1
    }
    # Defense-in-depth for callers that read the conf instead of the marker
    # (operator `docker exec` shells, mono's SSH `pgbackrest info` probe when
    # it can't export the env override). bootstrap_pgbackrest_stanza rewrites
    # this again from the marker once Postgres is up; both are idempotent.
    if [ -f "$PGBACKREST_CONF_FILE" ]; then
      sed -i "s|^repo1-path=.*|repo1-path=${new_path}|" "$PGBACKREST_CONF_FILE" \
        || echo "pgbackrest: could not rewrite repo1-path in ${PGBACKREST_CONF_FILE} (the marker is authoritative)" >&2
    fi
  fi

  clean_archive_spool_statuses
  # The old cluster's gap sentinel describes the old path's coverage.
  rm -f "$PGDATA/.pgbackrest_gap_pending" 2>/dev/null || true
  # Cleanup done: release the watcher's backup gate — field-preserving, so
  # the retry path's real watcher state survives. Failing here is safe —
  # the watcher retries the same cleanup and clears the gate itself.
  clear_backup_state_migration_gate \
    || echo "pgbackrest: could not clear the pending-migration gate; the watcher will retry it" >&2
  return 0
}

# Re-anchor archiving onto the current cluster's own repo path when the cluster
# that anchored the marker is gone. Runs on EVERY boot, before stanza bootstrap
# and before Postgres starts — the only window where the flip is free: no
# postmaster means no archive_command in flight, and no async daemon of ours
# exists yet.
#
# Detection is the anchor fingerprint, never the major-upgrade marker: a
# pg_upgrade is only the most common way to acquire a new system_identifier,
# the upgrade marker is deleted/aged out eventually, and any other route to a
# re-identified cluster needs the identical response. Today's upgrade job
# reaches the same end state by a different road — its directory swap promotes
# a freshly initdb'd data dir, so the new PGDATA inherits none of the old
# cluster's pgbackrest files and the path is simply DERIVED fresh. This check
# is what keeps that from being load-bearing: any upgrade route that carries
# $PGDATA's config forward (or the dump/restore fallback for the legacy
# PGDATA-is-the-volume-root layout, where these files sit outside the swapped
# directory entirely) hands us a surviving marker pointing at the previous
# cluster's repo.
#
# The new path needs no uniqueness suffix — unlike the watcher's WAL_REGRESSION
# migration, which re-points the path of a cluster whose identity did NOT
# change and therefore has to disambiguate with an epoch. A fresh
# system_identifier makes `cluster-<sysid>` collision-free by construction,
# and deterministic: a crashed attempt recomputes exactly the same target
# instead of stranding a sibling prefix per retry.
#
# Order is chosen so every interruption converges on the next boot:
#   1. gate the watcher + clear its timestamps (state describes the old path)
#   2. flip the marker (+ conf) — the instant archiving moves
#   3. drop the old path's spool statuses, release the watcher gate
#   4. write the new anchor LAST
# The anchor is the commit point: while it still names the old cluster the next
# boot re-detects and re-runs, and every step is idempotent. Nothing here can
# fail the boot — a database that is up with degraded archiving beats a
# database that refuses to start, which is how the rest of this file treats
# archive failures.
reanchor_pgbackrest_repo_path_if_reidentified() {
  [ -z "${WAL_ARCHIVE_BUCKET:-}" ] && return 0
  [ ! -f "$PGDATA/global/pg_control" ] && return 0
  # No marker: nothing is anchored yet, so there is nothing to re-anchor.
  # derive_pgbackrest_repo_path writes both files from the live cluster.
  [ ! -f "$PGBACKREST_REPO_PATH_MARKER" ] && return 0

  local live_sysid live_major
  live_sysid=$(read_postgres_sysid)
  live_major=$(read_postgres_major)
  if [ -z "$live_sysid" ] || [ -z "$live_major" ]; then
    echo "pgbackrest: could not read the cluster identity (sysid='${live_sysid}', PG_VERSION='${live_major}'); leaving the archive path as-is" >&2
    return 0
  fi

  local anchor_sysid anchor_major
  anchor_sysid=$(read_pgbackrest_anchor_field sysid)
  anchor_major=$(read_pgbackrest_anchor_field pg_version)

  # Volume written before the anchor existed: adopt the live identity for the
  # path already in the marker. Backfilling is the only safe reading of a
  # missing anchor — "no fingerprint" is not evidence of a changed cluster,
  # and the marker's path is where this cluster's archive already lives.
  # Re-anchoring on a missing anchor would move every existing PITR-enabled
  # service to a new prefix on its next redeploy.
  if [ -z "$anchor_sysid" ] || [ -z "$anchor_major" ]; then
    if write_pgbackrest_repo_anchor "$live_sysid" "$live_major"; then
      echo "pgbackrest: adopted repo-path anchor (sysid=${live_sysid}, pg=${live_major}) for the existing archive path"
    else
      echo "pgbackrest: could not write the repo-path anchor; cluster re-identification stays undetectable until it succeeds" >&2
    fi
    return 0
  fi

  if [ "$anchor_sysid" = "$live_sysid" ] && [ "$anchor_major" = "$live_major" ]; then
    return 0
  fi

  local current_path new_path user_path
  current_path=$(cat "$PGBACKREST_REPO_PATH_MARKER" 2>/dev/null || true)
  user_path="${WAL_ARCHIVE_PATH:-/pgbackrest}"
  new_path="${user_path%/}/cluster-${live_sysid}"

  echo "pgbackrest: cluster re-identified (anchored sysid=${anchor_sysid} pg=${anchor_major}, on disk sysid=${live_sysid} pg=${live_major}); re-anchoring archiving from ${current_path} to ${new_path}"

  if ! reanchor_pgbackrest_repo_path "$current_path" "$new_path"; then
    echo "pgbackrest: re-anchor to ${new_path} did not complete; the backup watcher retries it. Archiving stays degraded until then — the database is starting regardless." >&2
    return 0
  fi

  if ! write_pgbackrest_repo_anchor "$live_sysid" "$live_major"; then
    echo "pgbackrest: re-anchored to ${new_path} but could not write the anchor; the next boot re-runs this (idempotent)" >&2
    return 0
  fi

  echo "pgbackrest: re-anchored to ${new_path}; stanza-create and an immediate full backup follow there. The previous cluster's archive is untouched at ${current_path}."
  return 0
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

# Read total filesystem bytes of the data volume. Uses `df -Pk` (POSIX) and
# returns 1024-byte blocks. Echoes 0 on any failure so callers can fall back
# to the absolute defaults.
detect_volume_total_kib() {
  local vol_path="${RAILWAY_VOLUME_MOUNT_PATH:-$EXPECTED_VOLUME_MOUNT_PATH}"
  [ ! -d "$vol_path" ] && { echo 0; return; }
  df -Pk "$vol_path" 2>/dev/null | awk 'NR==2 { print $2 }' | grep -E '^[0-9]+$' || echo 0
}

# Compute volume-proportional WAL/spool thresholds and write them to globals
# COMPUTED_WAL_DROP_MB + COMPUTED_QUEUE_MAX_MIB. Both scale DOWN from the
# absolute default (5 GiB) on smaller volumes — never up. On a 25+ GiB volume
# the absolute holds.
#
# wal-drop == queue-max, deliberately identical (was 10% of volume / 500 MiB
# cap, a 10x-smaller budget than queue-max — see 2026-07-01 Tigris "sjc"
# incident: transient S3 500s/connection-resets are exactly the failure
# pgBackRest's spool is designed to absorb generously, but the wrapper's own
# 500 MiB pg_wal check tripped first, silently dropping WAL far short of the
# 5 GiB spool budget that should have covered the whole outage). Only the two
# explicit no-recovery-possible errors (NoSuchBucket, InvalidAccessKeyId,
# checked below) bypass this and drop immediately — everything else, hard
# failure or transient, gets the full budget before we give up on it.
#
# The wrapper checks pg_wal + spool against this value as ONE combined sum
# (see pgbackrest-archive-push-wrapper.sh), not pg_wal alone — identical caps
# on two independently-checked directories would let a single outage hold
# up to ~2x this budget on disk.
#
# Floor: 128 MiB (~8 WAL segments). Below this, archiving is effectively
# disabled and the dashboard surfaces it.
compute_volume_thresholds() {
  local total_kib total_mib queue_max cap_queue
  total_kib=$(detect_volume_total_kib)
  if [ "$total_kib" -lt 1 ]; then
    COMPUTED_WAL_DROP_MB=5120
    COMPUTED_QUEUE_MAX_MIB=5120
    echo "pgbackrest: volume size unknown; using absolute threshold wal-drop=queue-max=5 GiB"
    return
  fi
  total_mib=$(( total_kib / 1024 ))

  cap_queue=$(( 5 * 1024 ))
  queue_max=$(( total_mib / 2 ))
  [ "$queue_max" -gt "$cap_queue" ] && queue_max=$cap_queue
  [ "$queue_max" -lt 128 ] && queue_max=128
  COMPUTED_QUEUE_MAX_MIB=$queue_max
  COMPUTED_WAL_DROP_MB=$queue_max

  echo "pgbackrest: volume ${total_mib} MiB; sized wal-drop=${wal_drop} MiB queue-max=${queue_max} MiB"
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
archive-push-queue-max=${COMPUTED_QUEUE_MAX_MIB:-5120}MiB
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
pg1-user=${PGUSER:-postgres}
pg1-database=${PGDATABASE:-postgres}
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
    # Stanza-create timeout sentinel is scoped to the configured archive
    # bucket; clear it so the dashboard doesn't surface "stanza
    # bootstrap timed out" against a service whose archive is now off.
    [ -f "$PGDATA/.pgbackrest_stanza_create_timeout" ] && rm -f "$PGDATA/.pgbackrest_stanza_create_timeout" && removed=1
    #
    # Intentionally NOT clearing $PGBACKREST_INVALID_BUCKET_MARKER here:
    # validate_wal_archive_bucket unsets WAL_ARCHIVE_BUCKET on rejection,
    # which makes this function see "archive disabled" and would
    # race-delete the sentinel that pgbackrest-init.sh (initdb hook) or
    # validate_wal_archive_bucket itself (existing-volume path) just
    # wrote. The validator handles the sentinel lifecycle: pgbackrest-init.sh
    # writes on a true rejection during initdb; validate_wal_archive_bucket
    # itself rm's stale sentinels at the top of every boot when
    # WAL_ARCHIVE_BUCKET is unset. Letting them own that file
    # end-to-end avoids the self-overwrite.
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
        # Drop a sentinel so the monitor can distinguish "stanza bootstrap
        # timed out" from "archiving was never enabled" — the latter has
        # no archive_command set; the former has archive_command set but
        # no stanza in the bucket. Cleared on success below + by
        # clear_pgbackrest_state_if_disabled on archive disable.
        touch "$PGDATA/.pgbackrest_stanza_create_timeout" 2>/dev/null || true
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

    while true; do
      if gosu postgres pgbackrest --stanza=main stanza-create; then
        echo "pgbackrest: stanza-create completed"
        # Clear the timeout sentinel — a successful stanza-create either
        # arrived inside the deadline (no sentinel) or after a previous
        # boot's timeout (stale sentinel from disk). Either way, the
        # current state is "stanza present" and the dashboard should
        # treat the timeout as resolved.
        rm -f "$PGDATA/.pgbackrest_stanza_create_timeout" 2>/dev/null || true
        break
      fi
      echo "pgbackrest: stanza-create failed, retrying in 30s..." >&2
      sleep 30
    done
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
# restore_command pulls from repo2, which is the source service's bucket
# (translated from `WAL_RECOVER_FROM_*` at the top of this script). Post-
# promote archive_command writes to repo1 (this fork's own bucket) — see
# the archive-push wrapper's --repo=1 pin.
configure_pgbackrest_recovery() {
  [ -z "${WAL_RECOVER_FROM_BUCKET:-}" ] && return 0
  [ -z "$POSTGRES_RECOVERY_TARGET_TIME" ] && return 0
  [ ! -f "$POSTGRES_CONF_FILE" ] && return 0

  # A COMPLETED major-upgrade marker is proof recovery already promoted on
  # this volume, equivalent to .pitr_configured. Two layers guard the
  # upgraded-restored-fork case (WAL_RECOVER_FROM_* + the target time stay
  # set forever on a fork, so re-staging would point archive recovery at the
  # source bucket and the database would never become ready): the upgrade
  # job carries .pitr_configured/.pitr_staging/.pgbackrest_restored into the
  # new data dir across its swap (layer 1), and this marker check (layer 2)
  # covers any volume whose sentinels were still lost — the job refuses
  # recovery.signal/standby.signal volumes, so only a cluster whose recovery
  # had finished can ever have been upgraded.
  local upgrade_completed=0
  if [ -f "$UPGRADE_MARKER_FILE" ] \
    && [ "$(jq -r '.phase // empty' "$UPGRADE_MARKER_FILE" 2>/dev/null || true)" = "completed" ]; then
    upgrade_completed=1
  fi

  # /etc/pgbackrest lives on the container's root filesystem, not the
  # mounted volume, so it's gone on a genuine redeploy (a brand-new
  # container) even though it'd survive a plain in-place restart of the
  # same container. A crashed-mid-replay restore that gets redeployed (e.g.
  # after a manual resize) hits exactly that case: $PGBACKREST_RESTORED_MARKER
  # is already set on the (persistent) volume from the first boot's
  # successful `pgbackrest restore`, but that marker means "the restore
  # command ran once," not "recovery finished" — postgres hasn't consumed
  # recovery.signal yet, so it still needs this conf's restore_command to
  # keep fetching WAL, and the redeploy just wiped it. Re-render on every
  # boot while that's still possibly true, and only skip once genuinely
  # done: marker (or $PITR_DONE_MARKER) present AND recovery.signal gone,
  # i.e. postgres has actually promoted — that's also when we stop, to
  # avoid leaking source-bucket creds onto disk for a long-running promoted
  # service with no functional benefit.
  local recovery_genuinely_done=0
  if [ -f "$PITR_DONE_MARKER" ] || [ "$upgrade_completed" = 1 ]; then
    recovery_genuinely_done=1
  elif [ -f "$PGBACKREST_RESTORED_MARKER" ] && [ ! -f "$PGDATA/recovery.signal" ]; then
    recovery_genuinely_done=1
  fi

  if [ "$recovery_genuinely_done" -eq 0 ]; then
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
  fi

  # Recovery already done on this volume, OR the conf.d write below would
  # duplicate what pgbackrest restore already wrote directly into
  # postgresql.auto.conf: skip the conf.d write AND the staging path.
  # Unchanged from before — this gate is about the empty-volume-restore
  # case having already written its own restore_command directly, not about
  # whether recovery has actually finished (that's handled above). The
  # completed-upgrade marker joins the gate for the same reason it sets
  # recovery_genuinely_done: staging recovery on a post-upgrade volume would
  # hang the database against the source bucket forever.
  if [ -f "$PGBACKREST_RESTORED_MARKER" ] || [ -f "$PITR_DONE_MARKER" ] \
    || [ "$upgrade_completed" = 1 ]; then
    return 0
  fi

  # PGBACKREST_RESTORED_MARKER / PITR_DONE_MARKER short-circuited above, so
  # the only paths reaching here are (a) first-time staging or (b) the
  # post-promote cleanup branch below.

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

  # POSTGRES_RECOVERY_TARGET_XID, when set, wins over _TIME — same idle-
  # source-safe rationale as restore_from_pgbackrest_if_empty_volume:
  # recovery_target_time hangs/FATALs when no commit record exists past
  # target on an idle DB, recovery_target_xid matches an exact commit.
  # The picker emits _XID when it clamped to lastCommittedTxnAt.
  local recovery_param
  if [ -n "${POSTGRES_RECOVERY_TARGET_XID:-}" ]; then
    local escaped_xid="${POSTGRES_RECOVERY_TARGET_XID//\'/\'\'}"
    recovery_param="recovery_target_xid = '${escaped_xid}'"
  else
    local escaped_target="${POSTGRES_RECOVERY_TARGET_TIME//\'/\'\'}"
    recovery_param="recovery_target_time = '${escaped_target}'"
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
  echo "pgbackrest: PITR replay staged (target=${POSTGRES_RECOVERY_TARGET_TIME})"
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
# Container restart on an already-restored volume: `.pgbackrest_restored`
# present → skip.
#
# Container restart on an externally-restored volume (e2e helper
# pgbackrest_restore_into pre-populated PGDATA; operator ran their own
# `pgbackrest restore` and brought the cluster up): PG_VERSION and
# pg_control both present, `.pgbackrest_restored` absent. We do NOT
# touch this volume — configure_pgbackrest_recovery handles staging.
# (We can't write a private in-progress marker into PGDATA before
# invoking pgbackrest, because pgbackrest then sees PGDATA as non-empty
# without PG_VERSION/backup.manifest, disables --delta, and aborts.)
#
# Container kill mid-restore (the M2 audit case): pgbackrest restore
# writes pg_control LAST (the upstream design specifically guarantees
# this: "performed last to ensure aborted restores cannot be started").
# So PG_VERSION present + pg_control absent = partial restore. Re-run
# pgbackrest with `--delta`: by this point backup.manifest is on disk,
# so pgbackrest accepts --delta and checksum-diffs the partial PGDATA
# against the base, only refetching what's missing.
restore_from_pgbackrest_if_empty_volume() {
  # Log gate state up front so post-mortems on "why did pgbackrest restore
  # run when I expected it to be skipped" don't require guessing.
  echo "pgbackrest: restore-gate WAL_RECOVER_FROM_BUCKET=${WAL_RECOVER_FROM_BUCKET:+set} POSTGRES_RECOVERY_TARGET_TIME=${POSTGRES_RECOVERY_TARGET_TIME:+set} PG_VERSION=$([ -f "$PGDATA/PG_VERSION" ] && echo present || echo missing) PG_CONTROL=$([ -f "$PGDATA/global/pg_control" ] && echo present || echo missing) RESTORED_MARKER=$([ -f "$PGBACKREST_RESTORED_MARKER" ] && echo present || echo missing) PGDATA=$PGDATA"

  [ -z "${WAL_RECOVER_FROM_BUCKET:-}" ] && return 0
  [ -z "${POSTGRES_RECOVERY_TARGET_TIME:-}" ] && return 0
  [ -f "$PGBACKREST_RESTORED_MARKER" ] && return 0
  # PG_VERSION + pg_control both present = completed external restore.
  # Skip; configure_pgbackrest_recovery handles staging.
  if [ -f "$PGDATA/PG_VERSION" ] && [ -f "$PGDATA/global/pg_control" ]; then
    return 0
  fi

  echo "pgbackrest: empty PGDATA + recovery target — restoring from source bucket (target=${POSTGRES_RECOVERY_TARGET_TIME})"

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

  # Pick the recovery target type. POSTGRES_RECOVERY_TARGET_XID, when set,
  # wins over _TIME because it's the only target type postgres can match
  # exactly on an idle source. recovery_target_time requires postgres to
  # observe a WAL record with timestamp > target before declaring "target
  # reached" and firing recovery_target_action=promote; on an idle DB no
  # such record exists, so recovery FATALs with "recovery ended before
  # configured recovery target was reached" and the cluster either loops
  # the FATAL or hangs in hot_standby read-only mode. recovery_target_xid
  # matches an exact transaction ID — applying the target xid's commit
  # is unambiguously "target reached." The picker (mono's
  # createServiceFromPITR mutation) sets _XID when it clamped target
  # down to lastCommittedTxnAt, leaves it unset for arbitrary
  # historical times.
  local restore_type="time"
  local restore_target="$POSTGRES_RECOVERY_TARGET_TIME"
  if [ -n "${POSTGRES_RECOVERY_TARGET_XID:-}" ]; then
    restore_type="xid"
    restore_target="$POSTGRES_RECOVERY_TARGET_XID"
    echo "pgbackrest: using recovery_target_xid=${POSTGRES_RECOVERY_TARGET_XID} (idle-source-safe; target-time fallback would FATAL on no-record-after-target)"
  fi

  # --pg1-path is taken from $PGDATA so this works in restore-only mode too,
  # where render_pgbackrest_conf has been called but didn't include repo2.
  #
  # --delta makes pgbackrest checksum-diff $PGDATA against the base
  # manifest and refetch only the files that differ. On a fresh-volume
  # restore pgbackrest disables --delta itself (no PG_VERSION /
  # backup.manifest yet — full restore is the only sane option anyway).
  # On a partial-PGDATA retry (container killed mid-restore: PGDATA has
  # PG_VERSION + backup.manifest but no pg_control), pgbackrest accepts
  # --delta and repairs in place. Mirrors postgres-ssl audit M2.
  if ! gosu postgres pgbackrest --config="$PGBACKREST_RECOVERY_S3_CONF" \
       --stanza=main \
       --pg1-path="$PGDATA" \
       --recovery-option=restore_command="$recovery_restore_cmd" \
       restore \
       --delta \
       --type="$restore_type" --target="$restore_target" \
       --target-action=promote; then
    echo "pgbackrest: restore from source bucket failed; fix env vars (WAL_RECOVER_FROM_*, POSTGRES_RECOVERY_TARGET_TIME, POSTGRES_RECOVERY_TARGET_XID) and redeploy" >&2
    exit 1
  fi

  touch "$PGBACKREST_RESTORED_MARKER"
  chown postgres:postgres "$PGBACKREST_RESTORED_MARKER" 2>/dev/null || true

  # pgbackrest restore copies ALL of PGDATA — including the source's
  # watcher state (`.pgbackrest_backup_state` with source's last_full_at,
  # last_full_failed_count) and any in-flight gap-recovery marker. On
  # the fork's own bucket those values are meaningless and they cause
  # the watcher to mis-detect: source's last_full_at makes
  # NEEDS_INITIAL_BACKUP skip even though the fork's bucket is empty,
  # while source's last_full_failed_count vs fork's fresh failed_count
  # triggers a phantom gap-recovery cycle that blocks the watcher's
  # actual first full. Wipe so the fork starts from a clean slate.
  rm -f "$PGDATA/.pgbackrest_backup_state" 2>/dev/null || true
  rm -f "$PGDATA/.pgbackrest_gap_pending" 2>/dev/null || true

  echo "pgbackrest: restore complete; postgres will replay forward to ${POSTGRES_RECOVERY_TARGET_TIME} and promote on first start"
}

# Fork the backup watcher. Subshell pattern matches bootstrap_pgbackrest_stanza
# — gosu drops to postgres so the watcher's psql calls use peer auth via the
# Unix socket and `pgbackrest backup` runs as the right uid. The watcher gates
# itself on WAL_ARCHIVE_BUCKET / WAL_RECOVER_FROM_BUCKET internally, so the
# fork is unconditional and cheap when archiving isn't on.
#
# Single watcher process — no external respawn wrapper. The watcher's own
# main loop runs each iteration in a subshell so set -u / set -e style
# aborts inside an iteration don't kill the outer loop. An external
# `while true; do watcher; done` supervisor would cycle the watcher's
# long-lived PID across respawns (each respawn = new gosu + new bash
# interpreter), which races the stale-postmaster.pid check in postgres
# startup on container restarts: postgres reads "PID 45" from the stale
# file, sends signal 0, and a recently-respawned watcher main process
# happens to occupy that PID → postgres FATALs instead of clearing the
# stale file. With the watcher's own main loop holding a fixed PID, only
# the transient iteration subshell churns (always short-lived,
# never lands in postmaster.pid's range at container-start time).
fork_pgbackrest_backup_watcher() {
  [ -z "${WAL_ARCHIVE_BUCKET:-}" ] && return 0
  gosu postgres /usr/local/bin/pgbackrest-backup-watcher.sh &
}

# Wait for postgres to be ready then refresh collation versions on all databases.
# ALTER DATABASE ... REFRESH COLLATION VERSION was introduced in PG 15; skipped on older versions.
# Collation version mismatches occur when the container image is rebuilt with a newer glibc but
# the database volume was initialized with the old version — postgres emits a WARNING on every
# connection until refreshed, which is harmless but noisy.
fork_collation_refresh() {
  # While a post-upgrade reindex is pending, refreshing version stamps
  # WITHOUT rebuilding would declare stale indexes current and blind the
  # reindex fork's detection — it owns the refresh until it completes.
  if [ -f "$UPGRADE_MARKER_FILE" ] && [ "$(jq -r '.needsReindex // false' "$UPGRADE_MARKER_FILE" 2>/dev/null)" = "true" ]; then
    echo "collation-refresh: deferred — the post-upgrade reindex owns collation versions until it completes"
    return 0
  fi
  (
    local i=0
    while ! gosu postgres pg_isready -q 2>/dev/null; do
      sleep 2
      i=$((i+1))
      [ $i -ge 60 ] && exit 0
    done

    local pg_major
    pg_major=$(cat "$PGDATA/PG_VERSION" 2>/dev/null || echo "0")
    [ "$pg_major" -lt 15 ] 2>/dev/null && exit 0

    local tmpfile
    tmpfile=$(mktemp /tmp/collation-refresh.XXXXXX.sql)
    cat > "$tmpfile" << 'ENDSQL'
DO $body$
DECLARE
  db record;
BEGIN
  FOR db IN
    SELECT datname FROM pg_database
    WHERE datallowconn AND datname <> 'template0'
  LOOP
    BEGIN
      EXECUTE format('ALTER DATABASE %I REFRESH COLLATION VERSION', db.datname);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END LOOP;
END
$body$;
ENDSQL
    # mktemp runs as root (this subshell isn't gosu'd) and defaults to mode
    # 0600, unreadable by the postgres user the psql call below drops to.
    # Ownership must be handed over only AFTER writing the body: the
    # container's root has CAP_CHOWN but not CAP_DAC_OVERRIDE, so the moment
    # the file belongs to postgres, root itself can no longer write it.
    chown postgres:postgres "$tmpfile"
    gosu postgres psql -v ON_ERROR_STOP=0 -q -f "$tmpfile" 2>&1 | \
      while IFS= read -r line; do [ -n "$line" ] && echo "collation-refresh: $line"; done
    rm -f "$tmpfile"
  ) &
}

compute_volume_thresholds
# Inject the computed pg_wal drop threshold into the env that postgres (and
# its archive_command wrapper) inherits, unless the operator pinned it. The
# wrapper script reads WAL_DROP_THRESHOLD_MB at archive-push time, so this
# export must precede docker-entrypoint.sh.
if [ -z "${WAL_DROP_THRESHOLD_MB:-}" ]; then
  export WAL_DROP_THRESHOLD_MB="$COMPUTED_WAL_DROP_MB"
fi

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
# (`unable to find primary cluster`). PGHOSTADDR is the same hazard: libpq
# honors it even over an explicit -h to the local socket, so it silently
# breaks stanza bootstrap, the watcher's probes, and everything else forked
# below that talks libpq — the exact class upgrade-job.sh's own PGHOST/
# PGHOSTADDR/PGPORT clearing cites this block as precedent for. A local-only
# connection is what we want from inside the container; clearing all three
# lets libpq fall back to the Unix socket.
unset PGHOST
unset PGHOSTADDR
unset PGPORT

# Write the per-cluster repo-path marker synchronously when archive is on
# and the cluster is already initialized (pg_control on disk). Without this,
# the first archive_command on an existing volume that's enabling PITR for
# the first time races bootstrap_pgbackrest_stanza's async marker write:
# postmaster fires archive-push as soon as the first WAL switch occurs
# (≤archive_timeout=60s), but the bootstrap subshell can't write the marker
# until pg_isready succeeds — and on an active DB the first archive-push
# can land first, pushing to the bucket root instead of cluster-<sysid>/.
# pgbackrest-init.sh covers the fresh-init path during initdb (pg_control
# is materialized then); this covers the existing-volume first-enable path.
if [ -n "${WAL_ARCHIVE_BUCKET:-}" ] && [ -f "$PGDATA/global/pg_control" ] && [ ! -f "$PGBACKREST_REPO_PATH_MARKER" ]; then
  _early_repo_path=$(derive_pgbackrest_repo_path)
  echo "pgbackrest: pre-fork repo-path marker = ${_early_repo_path}"
  unset _early_repo_path
fi

# …and when a marker IS present, check it still belongs to the cluster on disk.
# Disjoint from the block above (that one only fires with no marker at all) and
# deliberately ahead of stanza bootstrap: a stale marker would make
# stanza-create fail on a system-id mismatch and every archive-push fail
# against the previous cluster's archive.info. `|| true` because this file runs
# under `set -e` and a failed re-anchor must never stop the database from
# starting — the watcher retries.
reanchor_pgbackrest_repo_path_if_reidentified || true

# Serialized read-modify-write for the upgrade marker. Two background forks
# (the staged analyze and the old-dir reclaim) both update it; their mktemp
# staging keeps the WRITES apart, but without mutual exclusion the classic
# lost update remains — reclaim re-reads a marker analyze is about to
# replace and writes back a stale needsAnalyze, or reclaim's own stamp is
# clobbered. flock on a sibling lock file closes it; when flock (or the
# open) is unavailable this degrades to the old unserialized behavior,
# whose worst outcomes were benign (a re-run analyze, a missing timestamp).
# Runs in a subshell so fd 7 never leaks into the caller.
update_upgrade_marker() {
  (
    if command -v flock >/dev/null 2>&1; then
      if { exec 7>>"${UPGRADE_MARKER_FILE}.updatelock"; } 2>/dev/null; then
        flock 7 || true
      fi
    fi
    tmp_marker=$(mktemp "${UPGRADE_MARKER_FILE}.XXXX") || exit 1
    if jq "$@" "$UPGRADE_MARKER_FILE" > "$tmp_marker" 2>/dev/null; then
      mv "$tmp_marker" "$UPGRADE_MARKER_FILE"
    else
      rm -f "$tmp_marker" 2>/dev/null
      exit 1
    fi
  )
}

# After a major upgrade, planner statistics start empty (pg_upgrade does not
# carry them across majors before 18). Rebuild them in stages in the
# background once postgres accepts connections, so the database is usable
# immediately and reaches full statistics without operator action. The
# marker's needsAnalyze flag makes this one-shot across restarts.
fork_post_upgrade_analyze() {
  [ -f "$UPGRADE_MARKER_FILE" ] || return 0
  [ "$(jq -r '.needsAnalyze // false' "$UPGRADE_MARKER_FILE" 2>/dev/null)" = "true" ] || return 0
  (
    for _ in $(seq 1 120); do
      if pg_isready -q -h /var/run/postgresql -p 5432 2>/dev/null; then
        echo "post-upgrade: rebuilding planner statistics in stages"
        # Connect as the cluster's actual superuser: a custom-POSTGRES_USER
        # cluster has no 'postgres' role (the entrypoint initdb's with
        # --username="$POSTGRES_USER"), and -U postgres would fail here on
        # every boot forever.
        if analyze_out=$(vacuumdb --all --analyze-in-stages -h /var/run/postgresql -p 5432 \
             -U "${POSTGRES_USER:-postgres}" 2>&1); then
          update_upgrade_marker '.needsAnalyze = false' || true
          echo "post-upgrade: statistics rebuild complete"
        else
          # Print WHY — an auth-hardened local rule or a missing role makes
          # this fail on every boot forever, and a bare "failed" gives the
          # operator nothing to fix.
          echo "post-upgrade: statistics rebuild failed; will retry on next boot"
          printf '%s\n' "$analyze_out" | tail -20 | sed 's/^/post-upgrade:   /'
        fi
        exit 0
      fi
      sleep 5
    done
  ) &
}

# After a major upgrade, ALTER SYSTEM settings are deliberately NOT carried
# into the new cluster (either file can hold a GUC the target major removed,
# and an unrecognized parameter in postgresql.auto.conf refuses the whole
# boot). Self-heal instead of asking the operator: re-apply the stashed
# auto.conf one GUC at a time via ALTER SYSTEM — a setting the new major
# rejects fails only ITS OWN statement (logged, skipped), never the boot.
# Image-managed GUCs are never re-applied: archiving/recovery settings
# belong to the PITR machinery (a leftover ALTER SYSTEM archive_command is
# a known footgun), and connection paths / SSL file paths belong to the
# entrypoint (a stale ssl_cert_file would refuse the next boot outright).
# The preload GUCs and dynamic_library_path are skipped for a subtler
# reason: ALTER SYSTEM validates them only syntactically — the libraries
# load at postmaster start (shared_) or connection start (session_/local_),
# so re-applying a value that names a library the new major's image doesn't
# ship would pass here and then refuse every subsequent boot or connection,
# which is the exact disaster class not carrying the file avoids. The image
# also actively manages shared_preload_libraries itself (pg_stat_statements,
# see ensure_pg_stat_statements above).
# postgresql.conf itself is not re-applied: on this image it is initdb +
# entrypoint output, not a user surface — its stash stays as reference.
# One-shot across restarts via the marker's needsConfigReview flag.
CONFIG_RESTORE_SKIP_GUCS="archive_mode archive_command archive_timeout restore_command recovery_target recovery_target_name recovery_target_time recovery_target_xid recovery_target_lsn recovery_target_inclusive recovery_target_timeline recovery_target_action primary_conninfo primary_slot_name listen_addresses port unix_socket_directories data_directory hba_file ident_file external_pid_file ssl ssl_cert_file ssl_key_file ssl_ca_file ssl_crl_file shared_preload_libraries session_preload_libraries local_preload_libraries dynamic_library_path"

fork_post_upgrade_config_restore() {
  [ -f "$UPGRADE_MARKER_FILE" ] || return 0
  [ "$(jq -r '.needsConfigReview // false' "$UPGRADE_MARKER_FILE" 2>/dev/null)" = "true" ] || return 0
  local from_major stash
  from_major="$(jq -r '.from // empty' "$UPGRADE_MARKER_FILE" 2>/dev/null)"
  stash="$EXPECTED_VOLUME_MOUNT_PATH/.pre-upgrade-${from_major}-postgresql.auto.conf"
  if [ -z "$from_major" ] || [ ! -f "$stash" ]; then
    # No ALTER SYSTEM settings existed before the upgrade (or the stash is
    # gone): the review is trivially complete.
    update_upgrade_marker '.needsConfigReview = false' || true
    return 0
  fi
  (
    for _ in $(seq 1 120); do
      if pg_isready -q -h /var/run/postgresql -p 5432 2>/dev/null; then
        echo "post-upgrade: re-applying ALTER SYSTEM settings from $(basename "$stash")"
        applied=0 skipped=0 rejected=0 unreachable=0
        while IFS= read -r line; do
          case "$line" in ''|'#'*) continue ;; esac
          key="${line%%=*}"; key="$(printf '%s' "$key" | tr -d '[:space:]')"
          value="${line#*=}"
          # Trim leading whitespace only — auto.conf's value quoting IS SQL
          # literal quoting, so the raw right-hand side drops into
          # ALTER SYSTEM verbatim.
          value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//')"
          [ -n "$key" ] || continue
          case " $CONFIG_RESTORE_SKIP_GUCS " in
            *" $key "*)
              echo "post-upgrade:   $key: image-managed, not re-applied"
              skipped=$((skipped + 1)); continue ;;
          esac
          rc=0
          out=$(psql -h /var/run/postgresql -p 5432 -U "${POSTGRES_USER:-postgres}" -d postgres -v ON_ERROR_STOP=1 \
            -c "ALTER SYSTEM SET \"$key\" = $value" 2>&1 </dev/null) || rc=$?
          if [ "$rc" -eq 0 ]; then
            applied=$((applied + 1))
          elif [ "$rc" -eq 2 ]; then
            # psql exit 2 = the connection could not be established or went
            # bad — infrastructure, not a verdict on the GUC. Any other
            # nonzero is the server rejecting this statement, which is the
            # expected shape for a GUC the new major removed. (A stash whose
            # every line is a removed GUC must still clear the flag — "all
            # rejected" alone is NOT evidence of a connectivity problem.)
            echo "post-upgrade:   $key: could not reach postgres ($(printf '%s' "$out" | tail -1))"
            unreachable=$((unreachable + 1))
          else
            echo "post-upgrade:   $key: not re-applied ($(printf '%s' "$out" | tail -1))"
            rejected=$((rejected + 1))
          fi
        done < "$stash"
        if [ "$unreachable" -gt 0 ]; then
          # Some settings never got a server verdict; keep the flag so the
          # next boot retries (re-applying is idempotent).
          echo "post-upgrade: ALTER SYSTEM restore could not reach postgres for ${unreachable} setting(s); will retry on next boot"
          exit 0
        fi
        psql -h /var/run/postgresql -p 5432 -U "${POSTGRES_USER:-postgres}" -d postgres -Atc "SELECT pg_reload_conf()" >/dev/null 2>&1 || true
        update_upgrade_marker '.needsConfigReview = false' || true
        echo "post-upgrade: ALTER SYSTEM restore complete (${applied} applied, ${skipped} image-managed, ${rejected} rejected by the new major; restart-scoped settings apply on the next restart)"
        exit 0
      fi
      sleep 5
    done
  ) &
}

# pg_upgrade preserves index FILES verbatim, but an index on collatable
# columns is only valid for the collation library that built it — and the
# upgrade can change the base image under the data. Per-INDEX collation
# versions are not tracked by any supported PostgreSQL (PG13 added
# pg_depend.refobjversion, PG14 reverted it); what IS tracked is
# per-collation: the database default's datcollversion (PG15+) and each
# named collation's collversion. So: detect staleness per collation, map
# suspect collations to the indexes that depend on them (pg_index.indcollation),
# REINDEX exactly that set CONCURRENTLY in the background, and only then
# refresh the version stamps — never the reverse. When no collation is stale
# (the common case) this flips the flag with zero work.
#
# Two places where the recorded stamps CANNOT be trusted, so the suspect set
# is widened instead of comparing:
# - Pre-15 sources have no datcollversion at all: pg_upgrade stamps the new
#   database with the CURRENT library's version, so "not stale" there means
#   nothing. With no baseline, every versioned collation is suspect.
# - initdb-created (predefined, oid < 16384) collations are re-created by
#   the new cluster's initdb with current stamps — pg_dump only carries
#   user-created ones — so their staleness is inferred per PROVIDER: if any
#   preserved stamp of a provider (the database default's, or a user-created
#   collation's) proves that library changed, every predefined collation of
#   that provider is suspect too.
#
# One-shot across restarts via the marker's needsReindex flag; any failure
# keeps the flag so the next boot retries. While this flag is up,
# fork_collation_refresh's blind version refresh stands down — refreshing
# stamps without rebuilding is exactly the wart this replaces.
fork_post_upgrade_reindex() {
  [ -f "$UPGRADE_MARKER_FILE" ] || return 0
  [ "$(jq -r '.needsReindex // false' "$UPGRADE_MARKER_FILE" 2>/dev/null)" = "true" ] || return 0
  local rx_from_major rx_baseline_unknown
  rx_from_major="$(jq -r '.from // empty' "$UPGRADE_MARKER_FILE" 2>/dev/null)"
  rx_baseline_unknown=0
  if [ -n "$rx_from_major" ] && [ "$rx_from_major" -lt 15 ] 2>/dev/null; then
    rx_baseline_unknown=1
  fi
  (
    # Same connection shape as fork_post_upgrade_analyze: the cluster's
    # actual superuser over the local socket — a custom-POSTGRES_USER
    # cluster has no 'postgres' role at all.
    _rx_psql() { psql -h /var/run/postgresql -p 5432 -U "${POSTGRES_USER:-postgres}" -v ON_ERROR_STOP=1 "$@"; }
    # One pass per database: build the suspect collation set (stale stamps,
    # plus the widenings described above), then every index depending on it.
    # Output lines are "<is_exclusion> <schema-qualified name>": exclusion-
    # constraint indexes cannot be rebuilt CONCURRENTLY (REINDEX raises an
    # error when one is named directly), so they take the non-concurrent
    # path. relkind 'i' only — a partitioned parent ('I') has no storage and
    # naming it would rebuild every leaf a second time. pg_temp schemas are
    # other sessions' business; system catalogs can't be reindexed
    # concurrently and ship on C-locale name columns anyway.
    _rx_suspect_indexes() {
      _rx_psql -d "$1" -Atc "
        WITH stale_user AS (
          SELECT oid, collprovider FROM pg_collation
          WHERE oid >= 16384 AND collversion IS NOT NULL
            AND collversion IS DISTINCT FROM pg_collation_actual_version(oid)
        ), dflt AS (
          SELECT datlocprovider AS p,
                 (datcollversion IS NOT NULL AND datcollversion IS DISTINCT FROM pg_database_collation_actual_version(oid)) AS stale,
                 (pg_database_collation_actual_version(oid) IS NOT NULL) AS versioned
          FROM pg_database WHERE datname = current_database()
        ), stale_providers AS (
          SELECT collprovider AS p FROM stale_user
          UNION SELECT p FROM dflt WHERE stale
        ), suspect AS (
          SELECT oid FROM stale_user
          UNION SELECT oid FROM pg_collation
            WHERE $rx_baseline_unknown = 1 AND oid >= 16384
              AND pg_collation_actual_version(oid) IS NOT NULL
          UNION SELECT c.oid FROM pg_collation c
            WHERE c.oid < 16384 AND c.collname <> 'default'
              AND pg_collation_actual_version(c.oid) IS NOT NULL
              AND ($rx_baseline_unknown = 1 OR c.collprovider IN (SELECT p FROM stale_providers))
          UNION SELECT c.oid FROM pg_collation c, dflt d
            WHERE c.collname = 'default'
              AND (d.stale OR ($rx_baseline_unknown = 1 AND d.versioned))
        )
        SELECT DISTINCT (EXISTS (SELECT 1 FROM pg_constraint x WHERE x.conindid = i.indexrelid AND x.contype = 'x'))::int
               || ' ' || format('%I.%I', n.nspname, c.relname)
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace,
             unnest(string_to_array(i.indcollation::text, ' ')::oid[]) u(collid)
        WHERE u.collid IN (SELECT oid FROM suspect)
          AND c.relkind = 'i'
          AND n.nspname NOT IN ('pg_catalog', 'pg_toast', 'information_schema')
          AND n.nspname NOT LIKE 'pg_temp%'
          AND n.nspname NOT LIKE 'pg_toast_temp%'"
    }
    i=0
    while ! pg_isready -q -h /var/run/postgresql -p 5432 2>/dev/null; do
      sleep 5; i=$((i+1)); [ "$i" -ge 120 ] && exit 0
    done
    pg_major=$(cat "$PGDATA/PG_VERSION" 2>/dev/null || echo "0")
    if [ "$pg_major" -lt 15 ] 2>/dev/null; then
      # Defensive only: the upgrade job's supported range (14-18) can never
      # land BELOW 15, and pre-15 has no version tracking to drive this.
      exit 0
    fi
    if [ "$rx_baseline_unknown" = "1" ]; then
      echo "post-upgrade: upgraded from PG${rx_from_major} — no collation-version baseline survives pg_upgrade from a pre-15 source, so every collation-dependent index is treated as suspect"
    fi
    dbs=$(_rx_psql -d postgres -Atc "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate" 2>/dev/null) || {
      echo "post-upgrade: reindex check could not list databases; will retry on next boot"
      exit 0
    }
    total_reindexed=0 failed=0
    while IFS= read -r db; do
      [ -n "$db" ] || continue
      # Leftovers of a crashed prior CONCURRENTLY attempt are invalid
      # *_ccnew indexes; drop them before retrying.
      _rx_psql -d "$db" -Atc "SELECT format('%I.%I', n.nspname, c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_index i ON i.indexrelid = c.oid WHERE NOT i.indisvalid AND c.relname ~ '_ccnew[0-9]*$'" 2>/dev/null \
        | while IFS= read -r junk; do
            [ -n "$junk" ] || continue
            _rx_psql -d "$db" -c "DROP INDEX CONCURRENTLY IF EXISTS $junk" >/dev/null 2>&1 </dev/null || true
          done

      db_failed=0
      # Stamp-stale sets drive the REFRESH step below — only stamps that
      # really are behind get refreshed (the widened suspects above already
      # carry current stamps, initdb/createdb just wrote them).
      default_stale=$(_rx_psql -d "$db" -Atc "SELECT (datcollversion IS DISTINCT FROM pg_database_collation_actual_version(oid))::int FROM pg_database WHERE datname = current_database() AND datcollversion IS NOT NULL" 2>/dev/null) || { echo "post-upgrade: $db: collation staleness check failed; will retry on next boot"; failed=$((failed+1)); continue; }
      stale_named=$(_rx_psql -d "$db" -Atc "SELECT oid FROM pg_collation WHERE collversion IS NOT NULL AND collversion IS DISTINCT FROM pg_collation_actual_version(oid)" 2>/dev/null) || { echo "post-upgrade: $db: collation staleness check failed; will retry on next boot"; failed=$((failed+1)); continue; }
      suspect_indexes=$(_rx_suspect_indexes "$db" 2>/dev/null) || { echo "post-upgrade: $db: suspect-index enumeration failed; will retry on next boot"; failed=$((failed+1)); continue; }

      while IFS=' ' read -r is_excl idx; do
        [ -n "$idx" ] || continue
        if [ "$is_excl" = "1" ]; then
          echo "post-upgrade: reindexing $db.$idx non-concurrently (exclusion constraint; collation version changed)"
          rx_cmd="REINDEX INDEX $idx"
        else
          echo "post-upgrade: reindexing $db.$idx (collation version changed)"
          rx_cmd="REINDEX INDEX CONCURRENTLY $idx"
        fi
        if rx_out=$(_rx_psql -d "$db" -c "$rx_cmd" 2>&1 </dev/null); then
          total_reindexed=$((total_reindexed + 1))
        else
          echo "post-upgrade:   $db.$idx: reindex failed; will retry on next boot ($(printf '%s' "$rx_out" | tail -1))"
          db_failed=1
        fi
      done <<EOF_SUSPECT_INDEXES
$suspect_indexes
EOF_SUSPECT_INDEXES

      if [ "$db_failed" -eq 0 ]; then
        # Rebuilds done — NOW the version stamps may say current.
        # regcollation renders a schema-qualified, quoted-as-needed name.
        for coll_oid in $stale_named; do
          [ -n "$coll_oid" ] || continue
          _rx_psql -d "$db" -c "DO \$\$ BEGIN EXECUTE format('ALTER COLLATION %s REFRESH VERSION', ${coll_oid}::regcollation); END \$\$" >/dev/null 2>&1 || true
        done
        if [ "$default_stale" = "1" ]; then
          _rx_psql -d "$db" -c "DO \$\$ BEGIN EXECUTE format('ALTER DATABASE %I REFRESH COLLATION VERSION', current_database()); END \$\$" >/dev/null 2>&1 || true
        fi
      else
        failed=$((failed + 1))
      fi
    done <<EOF_DBS
$dbs
EOF_DBS
    if [ "$failed" -gt 0 ]; then
      exit 0
    fi
    update_upgrade_marker '.needsReindex = false' || true
    if [ "$total_reindexed" -eq 0 ]; then
      if [ "$rx_baseline_unknown" = "1" ]; then
        echo "post-upgrade: no collation-dependent indexes to rebuild"
      else
        echo "post-upgrade: collation library unchanged — no reindex needed"
      fi
    else
      echo "post-upgrade: reindexed ${total_reindexed} collation-dependent index(es)"
    fi
  ) &
}

# After a completed upgrade the previous cluster stays at ${PGDATA}.old-<from>
# as the rollback body. pg_upgrade --link hardlinked the data files, so the
# kept directory pins every pre-upgrade inode: space freed inside the upgraded
# database (dropped tables, VACUUM FULL) is not returned to the volume while
# the old directory holds the second link. Keep it until the upgrade is
# CONFIRMED — the upgraded database up and answering, past a grace period
# measured from the marker's completedAt (default 24h;
# UPGRADE_OLD_DIR_RETENTION_SECONDS overrides, mainly for tests) — then
# reclaim it in the background and stamp oldDataDirRemovedAt in the marker.
# Forked on every boot alongside the analyze task, and it sleeps out the
# remaining grace inside a long-lived container, so the reclaim does not
# depend on a redeploy happening to land after the grace elapses.
fork_old_datadir_reclaim() {
  [ -f "$UPGRADE_MARKER_FILE" ] || return 0
  [ "$(jq -r '.phase // empty' "$UPGRADE_MARKER_FILE" 2>/dev/null || true)" = "completed" ] || return 0
  compgen -G "${PGDATA}.old-*" >/dev/null 2>&1 || return 0
  (
    retention="${UPGRADE_OLD_DIR_RETENTION_SECONDS:-86400}"
    marker_stamped=0
    [ -n "$(jq -r '.oldDataDirRemovedAt // empty' "$UPGRADE_MARKER_FILE" 2>/dev/null || true)" ] && marker_stamped=1

    # A chained upgrade (16->17, then 17->18 before the first reclaim ever
    # runs) leaves TWO .old-<major> siblings on the volume at once — each
    # job's own pre-existing-rollback-body refusal only checks ITS OWN
    # FROM-suffixed name, never a glob, so nothing stops them coexisting.
    # Keying reclaim off the CURRENT marker's completedAt alone (as a single
    # `rm -rf "${PGDATA}".old-*` gated on one timestamp) would judge every
    # generation by the LATEST upgrade's clock — sweeping an older, unrelated
    # rollback body early if a later upgrade used a shorter retention
    # override, or holding it hostage to a later upgrade's own wait. A
    # directory's own mtime is set once, by the `mv` that created it in
    # finish_swap, and nothing writes into it afterward — that makes it an
    # independent per-generation clock. Loop so each sibling is judged, and
    # reclaimed, on its own schedule; the earliest deadline first, so a
    # long-overdue orphan from a previous chain link doesn't wait behind a
    # much younger one.
    while :; do
      remaining=()
      for old_dir in "${PGDATA}".old-*; do
        [ -d "$old_dir" ] || continue
        dir_mtime=$(stat -c %Y "$old_dir" 2>/dev/null) || continue
        remaining+=("$(( dir_mtime + retention )):${old_dir}")
      done
      [ "${#remaining[@]}" -eq 0 ] && break

      next=$(printf '%s\n' "${remaining[@]}" | sort -n | head -1)
      next_deadline="${next%%:*}"
      next_dir="${next#*:}"
      wait_secs=$(( next_deadline - $(date +%s) ))
      if [ "$wait_secs" -gt 0 ]; then
        echo "post-upgrade: keeping ${next_dir} for rollback; reclaiming in ${wait_secs}s"
        sleep "$wait_secs"
      fi

      # Confirmation = the upgraded database is actually up and answering, not
      # merely "the grace elapsed": a crash-looping upgrade must keep every
      # rollback body in place. If postgres never becomes ready, stop
      # entirely — the next boot's fork re-evaluates everything from scratch.
      ready=0
      for _ in $(seq 1 120); do
        if pg_isready -q -h /var/run/postgresql -p 5432 2>/dev/null; then ready=1; break; fi
        sleep 5
      done
      [ "$ready" = 1 ] || exit 0

      echo "post-upgrade: reclaiming the pre-upgrade data dir (${next_dir})"
      if ! rm -rf "$next_dir"; then
        echo "post-upgrade: could not remove ${next_dir}; will retry on next boot"
        break
      fi
      if [ "$marker_stamped" = 0 ]; then
        # Serialized against the analyze fork's update — see update_upgrade_marker.
        update_upgrade_marker --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.oldDataDirRemovedAt = $t' \
          || echo "post-upgrade: could not stamp oldDataDirRemovedAt (reclaim already done; cosmetic)"
        marker_stamped=1
      fi
      echo "post-upgrade: pre-upgrade data dir reclaimed (${next_dir})"
    done
  ) &
}

bootstrap_pgbackrest_stanza
fork_pgbackrest_backup_watcher
fork_collation_refresh
fork_post_upgrade_analyze
fork_post_upgrade_config_restore
fork_post_upgrade_reindex
fork_old_datadir_reclaim

# H1 (audit): we considered `exec docker-entrypoint.sh` and a
# trap+wait+forward-SIGTERM pattern to make `docker stop` flush
# postgres's graceful shutdown sequence and clear postmaster.pid.
# Neither survived CI: exec re-parents the watcher/bootstrap subshells
# onto postmaster (postmaster panics on SIGCHLD with exit 103); the
# trap+wait pattern disturbed docker-entrypoint's initdb-time temp
# postmaster lifecycle and broke `docker restart` (auto.conf changes
# didn't survive). The real production failure mode the audit named —
# stale postmaster.pid colliding with a recently-respawned watcher PID —
# is already mitigated by PR #86 reverting the wrapper.sh supervisor:
# the watcher's long-lived PID no longer churns, so the in-container
# kill(stale_pid, 0) liveness check no longer hits one of its
# subprocesses. Falling back to the simple foreground invocation
# preserves the e2e suite's existing behavior on docker stop / docker
# restart.
#
# The traps below deliberately do NOT forward signals or restructure the
# foreground invocation (that is the pattern CI rejected). They only
# record that a stop was requested: bash runs a trap after the foreground
# child returns, so by the time the exit-code shaping below executes the
# flag reflects whether the runtime asked us to stop. That distinction is
# what lets a postgres that dies CLEANLY BUT UNASKED — e.g. it shut itself
# down because something unlinked its postmaster.pid — exit this container
# nonzero so an ON_FAILURE restart policy can bring the database back,
# instead of the container reporting exit 0 and staying down forever.
#
# The flag is a one-shot latch: a TERM/INT that never culminates in a stop
# (an operator poking PID 1, a platform stop that gets cancelled) still
# reclassifies a LATER unasked clean exit as requested, exit 0, no restart.
# Accepted: bash defers trap execution until the foreground child returns,
# so signal-delivery time cannot be recorded and a recency check is not
# implementable in this design — and on Railway a TERM broadcast is always
# followed by container removal, so a latched flag never coexists with a
# live postgres for long.
STOP_REQUESTED=0
trap 'STOP_REQUESTED=1' TERM INT

ENTRYPOINT_EXIT=0
/usr/local/bin/docker-entrypoint.sh "$@" || ENTRYPOINT_EXIT=$?

if [ "$ENTRYPOINT_EXIT" -ne 0 ]; then
  # Failure exit codes already make the restart policy act; pass through.
  exit "$ENTRYPOINT_EXIT"
fi
if [ "$STOP_REQUESTED" = "1" ]; then
  exit 0
fi
echo "wrapper: postgres exited cleanly but no stop was requested; exiting nonzero so the restart policy can recover the database"
exit 1
