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
  # If validate_wal_archive_bucket in wrapper.sh detected a junk bucket it
  # exports PGBACKREST_BUCKET_INVALID_REASON and unsets WAL_ARCHIVE_BUCKET
  # before calling docker-entrypoint.sh. Write the sentinel here (during
  # initdb, AFTER PGDATA exists) so docker logs show the misconfiguration
  # and the monitor can distinguish "never configured" from "misconfigured."
  if [ -n "${PGBACKREST_BUCKET_INVALID_REASON:-}" ]; then
    printf '%s\n' "${PGBACKREST_BUCKET_INVALID_REASON}" > "$PGDATA/.pgbackrest_invalid_bucket" 2>/dev/null || true
    chmod 0640 "$PGDATA/.pgbackrest_invalid_bucket" 2>/dev/null || true
    echo "pgbackrest: wrote invalid-bucket sentinel (reason=${PGBACKREST_BUCKET_INVALID_REASON})"
  fi
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

# This is the last initdb-era writer of boot-parsed config, so flush the
# whole volume filesystem here: initdb's sample, the entrypoint's pg_hba
# append, init-ssl's ssl block, and the include_dir line above are all
# buffered writes that nothing fsyncs. A block-level volume snapshot taken
# before the page cache flushes them captures the new file sizes with zeroed
# data blocks, and a copy restored from that snapshot fails to boot on the
# torn file ("syntax error ... near token \"\"").
sync -f "$PGDATA/PG_VERSION"

mkdir -p "$PGDATA/conf.d"
chmod 0750 "$PGDATA/conf.d"

archive_timeout="${POSTGRES_ARCHIVE_TIMEOUT:-60}"
# Accept everything Postgres itself accepts for this GUC: a bare integer or
# an integer with a time unit ('5min', '1h', …), including 0 — a legitimate
# value that turns the forced segment switch off. On anything else WARN and
# default to 60: exiting here fails the whole initdb under set -e, killing a
# fresh service over a knob typo — and only on the fresh-init path, since
# wrapper.sh's existing-DB reapply has no such gate (refused once, accepted
# on restart is the wrong shape for a validation to have).
if ! printf '%s' "$archive_timeout" | grep -qE '^[0-9]+(ms|s|min|h|d)?$'; then
  echo "pgbackrest: POSTGRES_ARCHIVE_TIMEOUT='${POSTGRES_ARCHIVE_TIMEOUT}' is not a valid archive_timeout (integer with optional ms/s/min/h/d unit); using 60" >&2
  archive_timeout=60
fi
# track_commit_timestamp lets pg_last_committed_xact() return the wall-clock
# time of the last commit. The PITR picker uses that as its upper bound:
# `recovery_target_time` only matches commit record timestamps, so on an idle
# DB the archive head keeps ticking with empty WAL while the latest reachable
# target stays pinned at the last commit. Without this GUC the picker falls
# back to the last full backup's stop time and the user gets a window pinned
# 24+ hours behind real time on the default diff cadence.
#
# Mirrors wrapper.sh's apply_pgbackrest_archive_conf — that function returns
# early when postgresql.conf doesn't exist yet (fresh-init pre-postmaster),
# so this initdb-phase write is the first chance to seed the GUC for the
# very first postmaster start. Without this, fresh PITR-enabled clusters
# would boot once with track_commit_timestamp=off, take the first base
# backup with no commit-ts data, and only pick up the GUC on the second
# boot when wrapper.sh's idempotent rewrite runs against an existing
# postgresql.conf — leaving a window where the picker can't compute a
# tight ceiling.
cat > "$PGDATA/conf.d/pgbackrest.conf" <<EOF
archive_mode = 'on'
archive_command = '/usr/local/bin/pgbackrest-archive-push-wrapper.sh %p'
archive_timeout = '${archive_timeout}'
track_commit_timestamp = 'on'
EOF
chmod 0640 "$PGDATA/conf.d/pgbackrest.conf"

echo "pgbackrest: archive config written to ${PGDATA}/conf.d/pgbackrest.conf during initdb"

# Write the per-cluster repo-path marker now that pg_control exists. Doing
# it here (during initdb's post-initdb hook phase, BEFORE the real postmaster
# launches) means the very first archive_command invocation reads the
# correct PGBACKREST_REPO1_PATH from the marker — no race with the bootstrap
# subshell in wrapper.sh, no archive-push fired against the wrong path.
if [ ! -f "$PGDATA/.pgbackrest_repo_path" ] && [ -f "$PGDATA/global/pg_control" ]; then
  # pg_controldata failing must not pass silently (set -e alone does not
  # cover a pipeline without pipefail): an empty sysid here skips the
  # marker block and the first archive-push fires against an unanchored
  # repo path. Fail the init instead.
  if ! pg_controldata_out=$(pg_controldata "$PGDATA" 2>/dev/null); then
    echo "pgbackrest: pg_controldata failed on $PGDATA; cannot derive the system identifier" >&2
    exit 1
  fi
  sysid=$(printf '%s\n' "$pg_controldata_out" \
    | awk -F: '/Database system identifier/ { gsub(/[ \t]/,"",$2); print $2 }')
  if [ -n "$sysid" ]; then
    cluster_path="${WAL_ARCHIVE_PATH:-/pgbackrest}/cluster-${sysid}"
    # Publish via tmp+rename: a torn in-place write leaves an empty marker
    # that still passes the -f gate and anchors the whole stack to an empty
    # repo path.
    cluster_path_tmp="${PGDATA}/.pgbackrest_repo_path.tmp"
    echo "$cluster_path" > "$cluster_path_tmp" \
      && chmod 0640 "$cluster_path_tmp" \
      && mv "$cluster_path_tmp" "$PGDATA/.pgbackrest_repo_path" \
      || { echo "pgbackrest: failed to write the repo-path marker atomically" >&2; exit 1; }
    echo "pgbackrest: per-cluster repo path = ${cluster_path}"
    # Fingerprint the cluster that path was derived from. wrapper.sh compares
    # it against the live cluster on every boot and re-anchors archiving to a
    # fresh sub-path when they diverge (a pg_upgrade, or any other route to a
    # new system_identifier) — see PGBACKREST_REPO_ANCHOR_FILE there. Seeding
    # it here rather than letting wrapper.sh backfill it next boot means the
    # first boot after initdb already carries a derived fingerprint instead of
    # an adopted one.
    anchor_tmp="${PGDATA}/.pgbackrest_repo_anchor.tmp"
    printf 'sysid=%s\npg_version=%s\n' "$sysid" "$(cat "$PGDATA/PG_VERSION")" \
      > "$anchor_tmp" \
      && chmod 0640 "$anchor_tmp" \
      && mv "$anchor_tmp" "$PGDATA/.pgbackrest_repo_anchor" \
      || { echo "pgbackrest: failed to write the repo anchor atomically" >&2; exit 1; }
  else
    echo "pgbackrest: pg_controldata produced no system identifier; refusing to anchor the repo path" >&2
    exit 1
  fi
fi
