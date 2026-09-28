#!/usr/bin/env bash
# Execute the actual post-upgrade restore helper against a recording SQL client.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
source <(sed -n '/^fork_post_upgrade_config_restore() {$/,/^}$/p' "$ROOT/wrapper.sh")
EXPECTED_VOLUME_MOUNT_PATH="$WORK"
UPGRADE_MARKER_FILE="$WORK/marker"
CONFIG_RESTORE_SKIP_GUCS=archive_command
pg_isready() { return 0; }
psql() { printf '%s\n' "$*" >> "$WORK/sql"; }
update_upgrade_marker() { printf '%s\n' "$*" >> "$WORK/reviewed"; }
for bucket in '' backups; do
  export WAL_ARCHIVE_BUCKET="$bucket"
  for level in minimal replica logical; do
    printf '{"from":16,"stashedAutoConf":true,"needsConfigReview":true}\n' > "$UPGRADE_MARKER_FILE"
    printf "wal_level = '%s'\n" "$level" > "$WORK/.pre-upgrade-16-postgresql.auto.conf"
    : > "$WORK/sql"
    : > "$WORK/reviewed"
    fork_post_upgrade_config_restore
    wait
    if [ "$bucket" = backups ] && [ "$level" = minimal ]; then
      ! grep -q 'ALTER SYSTEM SET.*wal_level' "$WORK/sql"
    else
      grep -q "ALTER SYSTEM SET.*wal_level.*'$level'" "$WORK/sql"
    fi
    grep -q 'needsConfigReview = false' "$WORK/reviewed"
  done
done
echo 'config restore preserves logical/replica and rejects minimal only with archiving'
