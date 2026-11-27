#!/usr/bin/env bash
# Exercise the real stanza health step with an isolated, recording pgBackRest.
# No database, bucket, daemon, credentials or live filesystem is used.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
LOCK_HOLDER_PID=''
cleanup() {
  if [ -n "$LOCK_HOLDER_PID" ]; then
    : > "$WORK/release-holder"
    wait "$LOCK_HOLDER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
export PGDATA="$WORK/pgdata"
mkdir -p "$PGDATA"
source "$ROOT/pgbackrest-backup-watcher.sh"

FAILS=0
CASES=0
assert_eq() {
  if [ "$2" != "$3" ]; then
    printf 'FAIL: %s: expected <%s>, got <%s>\n' "$1" "$3" "$2"
    FAILS=$((FAILS + 1))
  fi
}
count_lines() { wc -l < "$1" | tr -d ' '; }
timeout() {
  printf '%s\n' "$1" >> "$WORK/timeouts"
  shift
  "$@"
}
pgbackrest() {
  local attempt rc
  printf '%s\n' "$*" >> "$WORK/commands"
  attempt=$(count_lines "$WORK/commands")
  rc=$(sed -n "${attempt}p" "$WORK/sequence")
  rc=${rc:-99}
  case "$rc" in
    50) echo "ERROR: [050]: unable to acquire lock on file 'test-archive.lock': Resource temporarily unavailable" ;;
    55) echo "ERROR: [055]: archive.info exists but backup.info is missing on repo1" ;;
    78) echo "ERROR: [078]: repository is not accessible" ;;
  esac
  return "$rc"
}
sleep() {
  printf '%s\n' "$1" >> "$WORK/delays"
  # Test-only clock advancement, scoped to this test process. No real wait.
  SECONDS=$((SECONDS + $1))
  [ "$CLOCK_EXHAUST_ON_SLEEP" = 1 ] && SECONDS=$((SECONDS + 60))
  return 0
}
half_created_stanza_step() {
  printf '%s\n' "$1" >> "$WORK/repairs"
}
reset_case() {
  CASES=$((CASES + 1))
  SECONDS=0
  CLOCK_EXHAUST_ON_SLEEP=0
  rm -f "$STATE_FILE"
  printf '%s\n' "$@" > "$WORK/sequence"
  for file in commands delays repairs timeouts logs; do : > "$WORK/$file"; done
  write_state_field half_stanza_first_seen_at 12345
}
run_step() { stanza_create_step > "$WORK/logs" 2>&1; }
assert_delays() {
  local delay
  while IFS= read -r delay; do
    case "$delay" in
      1|2|3) ;;
      *) echo "FAIL: retry delay must be an integer from 1 through 3"; FAILS=$((FAILS + 1)) ;;
    esac
  done < "$WORK/delays"
}
assert_timeouts() {
  local value previous=61
  while IFS= read -r value; do
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ] || [ "$value" -gt 60 ] || [ "$value" -ge "$previous" ]; then
      echo "FAIL: attempts must share one decreasing 60-second timeout budget"
      FAILS=$((FAILS + 1))
    fi
    previous=$value
  done < "$WORK/timeouts"
}

reset_case 0
run_step
assert_eq 'immediate success attempts' "$(count_lines "$WORK/commands")" 1
assert_eq 'immediate success delays' "$(count_lines "$WORK/delays")" 0
assert_eq 'successful stanza clears pending corruption sighting' "$(read_state half_stanza_first_seen_at)" ''
assert_timeouts

for sequence in '50 0' '50 50 0'; do
  read -r -a codes <<< "$sequence"
  reset_case "${codes[@]}"
  run_step
  assert_eq 'transient contention attempts' "$(count_lines "$WORK/commands")" "${#codes[@]}"
  assert_eq 'transient contention delays' "$(count_lines "$WORK/delays")" "$((${#codes[@]} - 1))"
  assert_eq 'recovered contention is not logged as a failed stanza' "$(grep -c 'stanza-create: exited rc=' "$WORK/logs" || true)" 0
  assert_eq 'recovered stanza clears pending sighting' "$(read_state half_stanza_first_seen_at)" ''
  assert_eq 'lock contention does not trigger corruption migration' "$(count_lines "$WORK/repairs")" 0
  assert_delays
  assert_timeouts
done

reset_case 50 50 50 0
run_step
assert_eq 'persistent lock attempts stop at three' "$(count_lines "$WORK/commands")" 3
assert_eq 'persistent lock delays stop at two' "$(count_lines "$WORK/delays")" 2
assert_eq 'persistent lock remains a visible error' "$(grep -c 'stanza-create: exited rc=50' "$WORK/logs" || true)" 1
assert_eq 'persistent lock retains pending sighting' "$(read_state half_stanza_first_seen_at)" 12345
assert_eq 'persistent lock is not corruption' "$(count_lines "$WORK/repairs")" 0
assert_delays
assert_timeouts

for rc in 55 78 124; do
  reset_case "$rc" 0
  run_step
  assert_eq "non-lock rc=$rc is not retried" "$(count_lines "$WORK/commands")" 1
  assert_eq "non-lock rc=$rc causes no delay" "$(count_lines "$WORK/delays")" 0
  assert_eq "non-lock rc=$rc remains visible" "$(grep -c "stanza-create: exited rc=$rc" "$WORK/logs" || true)" 1
  if [ "$rc" = 55 ]; then
    assert_eq 'half-stanza recovery is preserved' "$(cat "$WORK/repairs")" backup.info-missing
  else
    assert_eq "non-corruption rc=$rc causes no migration" "$(count_lines "$WORK/repairs")" 0
  fi
done

reset_case 50 55 0
run_step
assert_eq 'corruption after contention stops retrying' "$(count_lines "$WORK/commands")" 2
assert_eq 'corruption after contention reaches recovery' "$(cat "$WORK/repairs")" backup.info-missing
assert_eq 'corruption after contention remains visible' "$(grep -c 'stanza-create: exited rc=55' "$WORK/logs" || true)" 1

reset_case 50 0
CLOCK_EXHAUST_ON_SLEEP=1
run_step
assert_eq 'elapsed budget prevents another attempt' "$(count_lines "$WORK/commands")" 1
assert_eq 'elapsed budget retains the actual lock error' "$(grep -c 'stanza-create: exited rc=50' "$WORK/logs" || true)" 1

# The fixture above controls sleep only to avoid test latency. Also exercise a
# real OS lock that is released by an independent, short-lived holder.
if command -v flock >/dev/null 2>&1; then
  reset_case
  CASES=$((CASES - 1))
  (
    flock -x 9
    : > "$WORK/holder-ready"
    while [ ! -e "$WORK/release-holder" ]; do command sleep 0.01; done
  ) 9>"$WORK/archive.lock" &
  LOCK_HOLDER_PID=$!
  while [ ! -e "$WORK/holder-ready" ]; do command sleep 0.01; done
  pgbackrest() {
    printf '%s\n' "$*" >> "$WORK/commands"
    if ! flock -n -x 8; then
      echo 'ERROR: [050]: lock held by an active archive push'
      return 50
    fi
    return 0
  } 8>"$WORK/archive.lock"
  sleep() {
    printf '%s\n' "$1" >> "$WORK/delays"
    # Release only after the first real lock conflict, regardless of scheduling.
    : > "$WORK/release-holder"
    wait "$LOCK_HOLDER_PID"
    command sleep "$1"
  }
  run_step
  : > "$WORK/release-holder"
  wait "$LOCK_HOLDER_PID"
  LOCK_HOLDER_PID=''
  assert_eq 'actual temporary OS lock is retried successfully' "$(count_lines "$WORK/commands")" 2
  assert_eq 'released OS lock does not leave an error' "$(grep -c 'stanza-create: exited rc=' "$WORK/logs" || true)" 0
  CASES=$((CASES + 1))
fi

if [ "$FAILS" -ne 0 ]; then
  echo "unit-stanza-lock-retry: $FAILS failed assertions in $CASES cases"
  exit 1
fi
echo "unit-stanza-lock-retry: all $CASES cases passed"
