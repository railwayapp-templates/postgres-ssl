#!/usr/bin/env bash
# Validate the real role-specific settings parser without storage or Docker.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source <(sed -n '/^pgbackrest_cipher_config() {$/,/^}$/p' "$ROOT/wrapper.sh")
source <(sed -n '/^validate_pgbackrest_encryption() {$/,/^}$/p' "$ROOT/wrapper.sh")
source <(sed -n '/^reset_pgbackrest_archive_state_after_restore() {$/,/^}$/p' "$ROOT/wrapper.sh")
source <(sed -n '/^prepare_pgbackrest_snapshot_archive() {$/,/^}$/p' "$ROOT/wrapper.sh")
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
unset WAL_ARCHIVE_CIPHER_TYPE WAL_ARCHIVE_CIPHER_PASS WAL_RECOVER_FROM_CIPHER_TYPE WAL_RECOVER_FROM_CIPHER_PASS
test "$(pgbackrest_cipher_config WAL_ARCHIVE)" = repo1-cipher-type=none
test "$(pgbackrest_cipher_config WAL_RECOVER_FROM)" = repo1-cipher-type=none
export WAL_ARCHIVE_BUCKET=archive WAL_RECOVER_FROM_BUCKET=source
export WAL_ARCHIVE_CIPHER_TYPE=aes-256-cbc WAL_ARCHIVE_CIPHER_PASS=archive-test-key
export WAL_RECOVER_FROM_CIPHER_TYPE=aes-256-cbc WAL_RECOVER_FROM_CIPHER_PASS=recovery-test-key
validate_pgbackrest_encryption
pgbackrest_cipher_config WAL_ARCHIVE > "$WORK/archive"
pgbackrest_cipher_config WAL_RECOVER_FROM > "$WORK/recovery"
grep -qx 'repo1-cipher-pass=archive-test-key' "$WORK/archive"
grep -qx 'repo1-cipher-pass=recovery-test-key' "$WORK/recovery"
! grep -q archive-test-key "$WORK/recovery"
for role in WAL_ARCHIVE WAL_RECOVER_FROM; do
  for mode in missing invalid multiline carriage disabled leading trailing leading-tab trailing-tab; do
    (
      export "${role}_CIPHER_TYPE=aes-256-cbc" "${role}_CIPHER_PASS=do-not-log-this-secret"
      case "$mode" in
        missing) export "${role}_CIPHER_PASS=" ;;
        invalid) export "${role}_CIPHER_TYPE=invalid" ;;
        multiline) export "${role}_CIPHER_PASS="$'do-not-log-this-secret\nrepo1-cipher-type=none' ;;
        carriage) export "${role}_CIPHER_PASS="$'do-not-log-this-secret\r' ;;
        disabled) export "${role}_CIPHER_TYPE=none" ;;
        leading) export "${role}_CIPHER_PASS= do-not-log-this-secret" ;;
        trailing) export "${role}_CIPHER_PASS=do-not-log-this-secret " ;;
        leading-tab) export "${role}_CIPHER_PASS="$'\tdo-not-log-this-secret' ;;
        trailing-tab) export "${role}_CIPHER_PASS="$'do-not-log-this-secret\t' ;;
      esac
      if validate_pgbackrest_encryption > "$WORK/out" 2> "$WORK/err"; then
        echo "accepted invalid $role $mode settings" >&2
        exit 1
      fi
      ! grep -q do-not-log-this-secret "$WORK/out" "$WORK/err"
    )
  done
done
PGDATA="$WORK/data"
mkdir -p "$PGDATA"
PGBACKREST_REPO_PATH_MARKER="$PGDATA/.pgbackrest_repo_path"
PGBACKREST_REPO_ANCHOR_FILE="$PGDATA/.pgbackrest_repo_anchor"
PITR_STAGING_FILE="$PGDATA/.pitr_staging"
printf '/source/cluster-123\n' > "$PGBACKREST_REPO_PATH_MARKER"
touch "$PGBACKREST_REPO_ANCHOR_FILE" "$PGDATA/.pgbackrest_backup_state" "$PGDATA/.pgbackrest_gap_pending"
prepare_pgbackrest_snapshot_archive
test ! -f "$PGBACKREST_REPO_PATH_MARKER"
test ! -f "$PGBACKREST_REPO_ANCHOR_FILE"
test ! -f "$PGDATA/.pgbackrest_backup_state"
test ! -f "$PGDATA/.pgbackrest_gap_pending"
# A retry during replay must retain the fork's own migrated archive state.
touch "$PITR_STAGING_FILE"
printf '/fork/cluster-123-migration\n' > "$PGBACKREST_REPO_PATH_MARKER"
printf 'fork-owned\n' > "$PGDATA/.pgbackrest_backup_state"
prepare_pgbackrest_snapshot_archive
grep -qx '/fork/cluster-123-migration' "$PGBACKREST_REPO_PATH_MARKER"
grep -qx 'fork-owned' "$PGDATA/.pgbackrest_backup_state"
echo 'encryption defaults off; roles use independent keys; invalid settings refuse without logging secrets'
echo 'snapshot handoff clears source state once and preserves fork state on replay retries'
