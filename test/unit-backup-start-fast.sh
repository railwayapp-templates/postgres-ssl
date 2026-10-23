#!/usr/bin/env bash
# Unit tests for the backup start mode in pgbackrest-backup-watcher.sh
# (decide_backup_start_fast and its helpers).
#
# No Docker, no Postgres, no bucket: the watcher is sourced for its functions,
# `psql` is a stub that answers the checkpoint-settings query from
# $STUB_DIR/wait (or fails when $STUB_DIR/psql-fails exists), and `pgbackrest`
# is a stub whose `backup` records its arguments in $STUB_DIR/backup.args.
#
# Usage: ./test/unit-backup-start-fast.sh

# BACKUP_STALL_* knobs set below are read by the sourced watcher functions.
# shellcheck disable=SC2034
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILS=0
pass() { echo "  ok: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

mkdir -p "$WORK/bin" "$WORK/stub" "$WORK/pgdata"

cat > "$WORK/bin/pgbackrest" <<'STUB'
#!/usr/bin/env bash
d="$STUB_DIR"
case " $* " in
  *" backup "*) echo "$*" > "$d/backup.args"; exit 0 ;;
  *" info "*) echo '[{"name":"main","status":{"code":0,"lock":{"backup":{"held":false},"restore":{"held":false}}}}]' ;;
  *) exit 0 ;;
esac
STUB

cat > "$WORK/bin/psql" <<'STUB'
#!/usr/bin/env bash
d="$STUB_DIR"
[ -e "$d/psql-fails" ] && exit 1
case "$*" in
  *checkpoint_completion_target*) cat "$d/wait" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WORK"/bin/*

export PATH="$WORK/bin:$PATH" STUB_DIR="$WORK/stub" PGDATA="$WORK/pgdata"
unset PGBACKREST_START_FAST PGBACKREST_DB_TIMEOUT


# shellcheck source=../pgbackrest-backup-watcher.sh
source "$ROOT/pgbackrest-backup-watcher.sh"

# Runs one supervised backup with $1 as the server's worst-case wait and
# prints the flags pgbackrest received after --no-expire-auto.
backup_flags() {
  rm -f "$STUB_DIR/backup.args" "$STUB_DIR/psql-fails"
  echo "$1" > "$STUB_DIR/wait"
  [ "${2:-}" = psql-fails ] && touch "$STUB_DIR/psql-fails"
  run_backup_supervised full > "$STUB_DIR/log" 2>&1
  sed -n 's/.*--no-expire-auto//p' "$STUB_DIR/backup.args" | tr -d ' '
}

echo "limit"
BACKUP_STALL_SECONDS=0
assert_eq "default db-timeout" "$(backup_start_wait_limit_seconds)" 1800
assert_eq "PGBACKREST_DB_TIMEOUT in seconds" "$(PGBACKREST_DB_TIMEOUT=3600 backup_start_wait_limit_seconds)" 3600
assert_eq "PGBACKREST_DB_TIMEOUT=45m" "$(PGBACKREST_DB_TIMEOUT=45m backup_start_wait_limit_seconds)" 2700
assert_eq "PGBACKREST_DB_TIMEOUT=2h" "$(PGBACKREST_DB_TIMEOUT=2h backup_start_wait_limit_seconds)" 7200
assert_eq "PGBACKREST_DB_TIMEOUT=900s" "$(PGBACKREST_DB_TIMEOUT=900s backup_start_wait_limit_seconds)" 900
assert_eq "unparseable PGBACKREST_DB_TIMEOUT falls back to the default" "$(PGBACKREST_DB_TIMEOUT=1800.5 backup_start_wait_limit_seconds)" 1800
BACKUP_STALL_SECONDS=600
assert_eq "stall floor below db-timeout bounds the wait" "$(backup_start_wait_limit_seconds)" 600
BACKUP_STALL_SECONDS=0

echo "decision (db-timeout 1800s)"
assert_eq "checkpoint_timeout=5min (540s) → spread start" "$(backup_flags 540)" ""
assert_eq "checkpoint_timeout=16min (1728s) → spread start" "$(backup_flags 1728)" ""
assert_eq "checkpoint_timeout=17min (1836s) → --start-fast" "$(backup_flags 1836)" "--start-fast"
if grep -q "backup start: a spread checkpoint could wait up to 1836s" "$STUB_DIR/log"; then
  pass "reason logged with the measured wait"
else
  fail "reason line missing"
fi
assert_eq "checkpoint_timeout=20min (2160s) → --start-fast" "$(backup_flags 2160)" "--start-fast"
assert_eq "unknown settings (psql fails) → spread start" "$(backup_flags 2160 psql-fails)" ""
if grep -q "backup start:" "$STUB_DIR/log"; then
  fail "logged a decision it did not take"
else
  pass "nothing logged when the server cannot be asked"
fi
assert_eq "junk from psql → spread start" "$(backup_flags 'ERROR: boom')" ""

echo "limits other than the default"
assert_eq "PGBACKREST_DB_TIMEOUT=1h makes 2160s fit" "$(PGBACKREST_DB_TIMEOUT=3600 backup_flags 2160)" ""
BACKUP_STALL_SECONDS=600
BACKUP_STALL_POLL_SECONDS=1
assert_eq "WAL_BACKUP_STALL_SECONDS=600 bounds a 5min checkpoint (540s) still" "$(backup_flags 540)" ""
assert_eq "WAL_BACKUP_STALL_SECONDS=600 forces fast at 720s" "$(backup_flags 720)" "--start-fast"
BACKUP_STALL_SECONDS=0

echo "operator decides"
export PGBACKREST_START_FAST=n
assert_eq "PGBACKREST_START_FAST=n leaves a 2160s wait alone" "$(backup_flags 2160)" ""
export PGBACKREST_START_FAST=y
assert_eq "PGBACKREST_START_FAST=y adds no flag of its own" "$(backup_flags 2160)" ""
export PGBACKREST_START_FAST=
assert_eq "PGBACKREST_START_FAST set but empty is still the operator's" "$(backup_flags 2160)" ""
unset PGBACKREST_START_FAST

echo
if [ "$FAILS" -ne 0 ]; then
  echo "unit-backup-start-fast: $FAILS failure(s)"
  exit 1
fi
echo "unit-backup-start-fast: all passed"
