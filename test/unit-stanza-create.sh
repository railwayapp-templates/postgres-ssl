#!/usr/bin/env bash
# Drives the watcher's real stanza_create_step over a stub pgBackRest:
# stanza-create runs on every poll while `pgbackrest info` reports a stanza
# that is not whole, and once per interval while info reports a whole stanza
# or gives no answer at all.
# shellcheck disable=SC2034  # globals below are read by the sourced watcher functions
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHER="$ROOT/pgbackrest-backup-watcher.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

command -v jq >/dev/null || { echo "jq is required (the watcher parses pgbackrest info with it)"; exit 1; }

for fn in stanza_create_step probe_stanza_status end_half_stanza_sighting \
          stanza_create_error_excerpt half_created_stanza_kind; do
  body=$(sed -n "/^${fn}() {\$/,/^}\$/p" "$WATCHER")
  eval "$body"
  declare -F "$fn" >/dev/null || { echo "could not load ${fn} from the watcher"; exit 1; }
done

STATE="$WORK/state"
STANZA_CREATE_INTERVAL_SECONDS=3600
PGBACKREST_REPO1_PATH=/cluster-1
NOW=1000000
INFO_OUT=""
INFO_RC=0
CREATE_OUT=""
CREATE_RC=0

date() { echo "$NOW"; }
log() { printf '%s\n' "$*" >> "$WORK/log"; }
debug() { :; }
read_state() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | tail -1; return 0; }
write_state_field() { printf '%s=%s\n' "$1" "$2" >> "$STATE"; }
half_created_stanza_step() { echo "half:$1" >> "$WORK/actions"; }
# timeout [options] <seconds> <command...>: run the command.
timeout() {
  while [ "${1#--}" != "$1" ]; do shift; done
  shift
  "$@"
}
# Stub pgBackRest: `info` prints $INFO_OUT and exits $INFO_RC; `stanza-create`
# is recorded, prints $CREATE_OUT and exits $CREATE_RC.
pgbackrest() {
  case " $* " in
    *" info "*)
      echo info >> "$WORK/probes"
      printf '%s' "$INFO_OUT"
      return "$INFO_RC"
      ;;
    *" stanza-create "*)
      echo stanza-create >> "$WORK/actions"
      [ -n "$CREATE_OUT" ] && printf '%s\n' "$CREATE_OUT"
      return "$CREATE_RC"
      ;;
  esac
  return 64
}

# The shape of `pgbackrest --stanza=main --repo=1 info --output=json`.
info_json() {
  printf '[{"archive":[],"backup":[],"cipher":"none","db":[],"name":"main","repo":[{"cipher":"none","key":1,"status":{"code":%s,"message":"%s"}}],"status":{"code":%s,"lock":{"backup":{"held":false}},"message":"%s"}}]' \
    "$1" "$2" "$1" "$2"
}
info_reports() { INFO_RC=0; INFO_OUT=$(info_json "$1" "$2"); }
info_gives_no_answer() { INFO_RC=124; INFO_OUT=""; }

failures=0
check() {
  local what="$1"; shift
  if "$@"; then return 0; fi
  echo "FAIL [$CASE]: $what"
  failures=$((failures + 1))
}
actions() { [ -f "$WORK/actions" ] && tr '\n' ' ' < "$WORK/actions" | sed 's/ $//'; return 0; }
actions_are() { [ "$(actions)" = "$1" ]; }
runs() { [ -f "$WORK/actions" ] && grep -c '^stanza-create$' "$WORK/actions"; return 0; }
ran() { [ "$(runs)" = "$1" ] || { [ "$1" = 0 ] && [ -z "$(runs)" ]; }; }
probes() { [ -f "$WORK/probes" ] && wc -l < "$WORK/probes" | tr -d ' '; return 0; }
state_is() { [ "$(read_state "$1")" = "$2" ]; }
logged() { grep -q -- "$1" "$WORK/log" 2>/dev/null; }
nothing_logged() { [ ! -s "$WORK/log" ]; }

# begin <case> [last_stanza_create_at]: a state file whose last run is the
# given epoch; no argument leaves the field out.
begin() {
  CASE="$1"
  rm -f "$STATE" "$WORK/log" "$WORK/actions" "$WORK/probes"
  NOW=1000000
  STANZA_CREATE_INTERVAL_SECONDS=3600
  CREATE_OUT=""
  CREATE_RC=0
  info_reports 0 ok
  [ "$#" -ge 2 ] && write_state_field last_stanza_create_at "$2"
  return 0
}
# poll [n]: n watcher iterations, 60s apart.
poll() {
  local n="${1:-1}" i
  for ((i = 0; i < n; i++)); do
    NOW=$((NOW + 60))
    stanza_create_step
  done
}

# No run on record: stanza-create runs without waiting for info.
begin "no run on record"
info_gives_no_answer
poll
check "stanza-create runs" ran 1
check "info is not consulted" [ -z "$(probes)" ]
check "the run is stamped" state_is last_stanza_create_at 1000060

# A whole stanza: one run per interval, nothing on the polls in between.
begin "whole stanza" 1000000
poll 59
check "no run inside the interval" ran 0
check "info is asked on every poll" [ "$(probes)" = 59 ]
poll
check "one run when the interval has passed" ran 1
check "the run is stamped" state_is last_stanza_create_at 1003600
poll 59
check "no further run inside the next interval" ran 1
poll
check "second run one interval later" ran 2
check "a healthy stanza logs nothing" nothing_logged

# A stanza with no backup yet has both info files: same as whole.
begin "whole stanza, no backup yet" 1000000
info_reports 2 "no valid backups"
poll 59
check "no run inside the interval" ran 0

# A stanza that is not whole: stanza-create on every poll.
for broken in "1:missing stanza path" "3:missing stanza data" "99:other"; do
  begin "stanza not whole (code ${broken%%:*})" 1000000
  info_reports "${broken%%:*}" "${broken#*:}"
  poll 3
  check "stanza-create runs on every poll" ran 3
done

# stanza-create repaired it: back to one run per interval.
begin "stanza repaired" 1000000
info_reports 1 "missing stanza path"
poll
check "runs while the stanza is missing" ran 1
info_reports 2 "no valid backups"
poll 59
check "no run once info reports it whole" ran 1
poll
check "next run one interval after the repair" ran 2

# info gives no answer: stanza-create waits.
begin "info killed by its timeout" 1000000
info_gives_no_answer
poll
check "no run" ran 0
for silent in "" "not json" "[]" '[{"name":"other","status":{"code":0}}]' '[{"name":"main"}]'; do
  begin "info exits 0 without a status for the stanza: '${silent}'" 1000000
  INFO_RC=0; INFO_OUT="$silent"
  poll
  check "no run" ran 0
done
begin "info exits non-zero with a status in its output" 1000000
info_reports 1 "missing stanza path"; INFO_RC=1
poll
check "no run" ran 0

# The bucket stays silent: stanza-create runs once the interval has passed,
# and a run that fails is not repeated on the next poll.
begin "no answer for hours" 1000000
info_gives_no_answer
CREATE_RC=124
poll 59
check "no run inside the interval" ran 0
poll
check "runs with no answer once the interval has passed" ran 1
check "the failure is logged" logged "stanza-create: exited rc=124"
poll 59
check "the failed run is not repeated inside the next interval" ran 1
poll
check "runs again one interval later" ran 2

# The bucket answers again and the stanza is broken: no waiting out the interval.
begin "answer after a blackout, stanza not whole" 1000000
info_gives_no_answer
poll 5
check "no run during the blackout" ran 0
info_reports 3 "missing stanza data"
poll
check "runs on the first answer" ran 1

# Interval 0: every poll, as before.
begin "interval 0" 1000000
STANZA_CREATE_INTERVAL_SECONDS=0
info_gives_no_answer
poll 3
check "stanza-create runs on every poll" ran 3
check "info is not consulted" [ -z "$(probes)" ]

# An unreadable stamp counts as due.
for stamp in garbage 0 0000123 1000100 92233720368547758080; do
  begin "last run stamp '${stamp}'" "$stamp"
  info_gives_no_answer
  poll
  check "stanza-create runs" ran 1
  check "the stamp is rewritten" state_is last_stanza_create_at 1000060
done

# A half-created stanza reaches its confirmation gate on every poll.
begin "half-created stanza" 1000000
info_reports 1 "missing stanza path"
CREATE_RC=55
CREATE_OUT="ERROR: [055]: archive.info exists but backup.info is missing on repo1"
poll 2
check "each poll is a sighting" actions_are "stanza-create half:backup.info-missing stanza-create half:backup.info-missing"
check "the failure line carries the error" logged "stanza-create: exited rc=55; ERROR: \[055\]: archive.info exists but backup.info is missing on repo1"

# A half-created sighting ends when the stanza is found whole, by either command.
begin "sighting ended by info" 1000000
write_state_field half_stanza_first_seen_at 999990
poll
check "no stanza-create" ran 0
check "the sighting is cleared" state_is half_stanza_first_seen_at ""
check "logged as transient" logged "half-created stanza: pgbackrest info reports a whole stanza at /cluster-1; the earlier sighting was transient"

begin "sighting ended by stanza-create" 1000000
write_state_field half_stanza_first_seen_at 999990
info_reports 3 "missing stanza data"
poll
check "stanza-create ran" ran 1
check "the sighting is cleared" state_is half_stanza_first_seen_at ""
check "logged as transient" logged "half-created stanza: stanza-create now succeeds at /cluster-1; the earlier sighting was transient"

begin "sighting kept while info gives no answer" 1000000
write_state_field half_stanza_first_seen_at 999990
info_gives_no_answer
poll
check "the sighting is kept" state_is half_stanza_first_seen_at 999990

if [ "$failures" -ne 0 ]; then
  echo "${failures} stanza-create check(s) failed"
  exit 1
fi
echo 'stanza-create regression tests passed'
