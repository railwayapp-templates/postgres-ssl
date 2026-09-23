#!/usr/bin/env bash
# Unit tests for the backup stall watchdog in pgbackrest-backup-watcher.sh.
#
# No Docker, no Postgres, no bucket: the watcher is sourced for its functions
# (it returns before starting the daemon when sourced) and `pgbackrest` is a
# stub on PATH whose `backup` either hangs with frozen progress or copies and
# finishes, and whose `info --output=json` reports that progress under
# status.lock.backup exactly where pgBackRest does.
#
# Usage: ./test/unit-backup-stall.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'pkill -KILL -f "$WORK/" 2>/dev/null; rm -rf "$WORK"' EXIT

FAILS=0
pass() { echo "  ok: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

mkdir -p "$WORK/bin" "$WORK/stub" "$WORK/pgdata"

# ---- stubs ------------------------------------------------------------------

cat > "$WORK/bin/pgbackrest" <<'STUB'
#!/usr/bin/env bash
# Stub pgbackrest. $STUB_DIR/mode selects the backup behaviour:
#   hang     — take the "lock", report fixed progress, ignore SIGTERM, never exit
#   progress — copy one step per second for $STUB_DIR/steps steps, then exit 0
d="$STUB_DIR"
case " $* " in
  *" backup "*)
    echo "$$" > "$d/backup.pid"
    echo "0" > "$d/size-cplt"
    case "$(cat "$d/mode")" in
      hang)
        trap '' TERM
        sleep 3600 &
        echo "$!" > "$d/grandchild.pid"
        while :; do wait; done
        ;;
      progress)
        steps=$(cat "$d/steps")
        for i in $(seq 1 "$steps"); do
          sleep 1
          echo $((i * 1000)) > "$d/size-cplt"
        done
        rm -f "$d/backup.pid"
        exit 0
        ;;
    esac
    ;;
  *" info "*)
    pid=$(cat "$d/backup.pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "[{\"name\":\"main\",\"status\":{\"code\":0,\"lock\":{\"backup\":{\"held\":true,\"size-cplt\":$(cat "$d/size-cplt"),\"size\":100000},\"restore\":{\"held\":false}}}}]"
    else
      echo '[{"name":"main","status":{"code":0,"lock":{"backup":{"held":false},"restore":{"held":false}}}}]'
    fi
    ;;
  *) exit 0 ;;
esac
STUB

cat > "$WORK/bin/psql" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB

# GNU timeout is in the image; macOS runners lack it.
if ! command -v timeout >/dev/null 2>&1; then
  cat > "$WORK/bin/timeout" <<'STUB'
#!/usr/bin/env bash
shift
exec "$@"
STUB
fi
chmod +x "$WORK"/bin/*

export PATH="$WORK/bin:$PATH" STUB_DIR="$WORK/stub" PGDATA="$WORK/pgdata"

# shellcheck source=../pgbackrest-backup-watcher.sh
source "$ROOT/pgbackrest-backup-watcher.sh"

reset_state() { rm -f "$STATE_FILE" "$STUB_DIR"/*; }

# ---- 1. pure window / verdict ----------------------------------------------
echo "window + verdict"
BACKUP_STALL_SECONDS=1800
BACKUP_STALL_MIN_BYTES_PER_SECOND=4194304
assert_eq "no size reported → floor" "$(backup_stall_window_seconds 0)" 1800
assert_eq "112 GiB → one 11% step at 4 MiB/s (~53 min)" \
  "$(backup_stall_window_seconds $((112 * 1024 * 1024 * 1024)))" 3153
assert_eq "1 TiB → 11% of size at 4 MiB/s" \
  "$(backup_stall_window_seconds $((1024 * 1024 * 1024 * 1024)))" 28835
assert_eq "junk size → floor" "$(backup_stall_window_seconds abc)" 1800
backup_is_stalled 2000 200 0 && pass "1800s without progress is a stall" || fail "1800s without progress is a stall"
backup_is_stalled 1999 200 0 && fail "1799s without progress is not a stall" || pass "1799s without progress is not a stall"
backup_is_stalled 20000 0 $((1024 * 1024 * 1024 * 1024)) \
  && fail "1 TiB backup between progress steps is not a stall" \
  || pass "1 TiB backup between progress steps is not a stall"

# ---- 2. frozen progress → killed, recorded as a failed full ---------------
echo "stalled backup is killed"
reset_state
BACKUP_STALL_SECONDS=3
BACKUP_STALL_POLL_SECONDS=1
BACKUP_STALL_KILL_GRACE_SECONDS=2
echo hang > "$STUB_DIR/mode"
start=$(date +%s)
run_backup full > "$WORK/hang.log" 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))
cat "$WORK/hang.log" | sed 's/^/    | /'
[ "$rc" -ne 0 ] && pass "run_backup fails (rc=$rc)" || fail "run_backup should fail on a stalled backup"
grep -q "backup stalled: no progress for [0-9]*s; killed" "$WORK/hang.log" \
  && pass "distinct stall line logged" || fail "stall line missing"
grep -q "backup --type=full failed" "$WORK/hang.log" \
  && pass "recorded as a backup failure" || fail "failure line missing"
[ -n "$(read_state last_full_failure_at)" ] \
  && pass "last_full_failure_at set (retry backoff applies)" || fail "last_full_failure_at not set"
assert_eq "last_full_at stays empty" "$(read_state last_full_at)" ""
[ "$elapsed" -lt 30 ] && pass "returned in ${elapsed}s" || fail "took ${elapsed}s"
sleep 1
kill -0 "$(cat "$STUB_DIR/backup.pid")" 2>/dev/null \
  && fail "TERM-ignoring backup still alive" || pass "backup process SIGKILLed after grace"
kill -0 "$(cat "$STUB_DIR/grandchild.pid")" 2>/dev/null \
  && fail "backup's child still alive" || pass "backup's child process killed too"

# ---- 3. moving progress → untouched even past the stall window ------------
echo "progressing backup is left alone"
reset_state
BACKUP_STALL_SECONDS=3
BACKUP_STALL_POLL_SECONDS=1
echo progress > "$STUB_DIR/mode"
echo 8 > "$STUB_DIR/steps"
start=$(date +%s)
run_backup diff > "$WORK/progress.log" 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))
cat "$WORK/progress.log" | sed 's/^/    | /'
assert_eq "run_backup succeeds" "$rc" 0
[ "$elapsed" -ge 8 ] && pass "ran ${elapsed}s, past the 3s window" || fail "finished too early (${elapsed}s)"
grep -q "backup stalled" "$WORK/progress.log" && fail "progressing backup was killed" || pass "no stall kill"
grep -q "backup --type=diff completed" "$WORK/progress.log" && pass "completed normally" || fail "completion line missing"
[ -n "$(read_state last_diff_at)" ] && pass "last_diff_at recorded" || fail "last_diff_at missing"

# ---- 4. watchdog off --------------------------------------------------------
echo "WAL_BACKUP_STALL_SECONDS=0 runs unsupervised"
reset_state
BACKUP_STALL_SECONDS=0
echo progress > "$STUB_DIR/mode"
echo 2 > "$STUB_DIR/steps"
run_backup diff > "$WORK/off.log" 2>&1
assert_eq "run_backup succeeds" "$?" 0

echo
if [ "$FAILS" -ne 0 ]; then
  echo "unit-backup-stall: $FAILS failure(s)"
  exit 1
fi
echo "unit-backup-stall: all passed"
