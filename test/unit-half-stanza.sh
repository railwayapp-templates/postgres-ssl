#!/usr/bin/env bash
# Exercise the production confirmation gate without running the daemon.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
source <(sed -n '/^half_created_stanza_step() {$/,/^}$/p' "$ROOT/pgbackrest-backup-watcher.sh")
date() { echo 100000; }
read_state() { echo "$STAMP"; }
write_state_field() { printf '%s=%s\n' "$1" "$2" >> "$WORK/writes"; }
log() { :; }
migrate_to_new_archive_path() { touch "$WORK/migrated"; }
HALF_STANZA_CONFIRM_SECONDS=60
for STAMP in '' garbage 0 000099940 100001 92233720368547758080; do
  rm -f "$WORK/writes" "$WORK/migrated"
  half_created_stanza_step backup.info-missing
  test ! -e "$WORK/migrated"
  grep -qx 'half_stanza_first_seen_at=100000' "$WORK/writes"
done
STAMP=99999
rm -f "$WORK/writes"
half_created_stanza_step archive.info-missing
test ! -e "$WORK/migrated"
test ! -e "$WORK/writes"
STAMP=99940
half_created_stanza_step archive.info-missing
test -e "$WORK/migrated"
grep -qx 'last_full_failure_at=' "$WORK/writes"
echo 'half-stanza confirmation regression tests passed'
