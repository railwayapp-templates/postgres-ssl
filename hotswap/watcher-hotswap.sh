#!/bin/sh
# watcher-hotswap.sh <dir>
#
# Runs INSIDE a running postgres-ssl container, as root. Replaces the PITR backup watcher and the
# archive-push wrapper with the copies in <dir> and restarts only the watcher; Postgres keeps
# running. Not part of the image: the platform runs it in containers deployed from an older image,
# so a watcher fix reaches them without a restart. A new deploy installs the image's own scripts.
#
# The container is never left without a watcher:
#   - if the new watcher does not stay up, the previous scripts go back and the previous watcher is
#     started again (exit 5);
#   - if the run itself is cut short after the old watcher stopped (the exec session died), the
#     next run finds the saved environment and starts the watcher from it.
#
# Exit status:
#   0  swapped, or the installed scripts already match <dir> and a watcher is running
#   2  <dir> is incomplete or a script in it does not parse; not run as root
#   3  not applicable: no watcher running (archiving off), or the process layout is not the one
#      wrapper.sh creates
#   4  a pgBackRest backup is running; nothing changed, run it again later
#   5  the swap did not go through; the message says what the container runs now
set -eu
NEW=${1:?directory holding the new scripts}
BIN=/usr/local/bin
FILES="pgbackrest-backup-watcher.sh pgbackrest-archive-push-wrapper.sh"
# The watcher's environment (it holds the bucket credentials): root-only, kept from the moment the
# old watcher may be stopped until a watcher is confirmed running again.
ENVIRON=/tmp/.watcher-environ
# Messages must never abort the run: once the exec session is gone a write fails.
say() { echo "hotswap: $*" 2>/dev/null || true; }
err() { echo "hotswap: $*" >&2 2>/dev/null || true; }

for f in $FILES; do
  [ -s "$NEW/$f" ] || { err "$NEW/$f is missing"; exit 2; }
  sh -n "$NEW/$f" 2>/dev/null || bash -n "$NEW/$f" || { err "$NEW/$f does not parse"; exit 2; }
done
[ "$(id -u)" = 0 ] || { err "must run as root (running as $(id -un))"; exit 2; }

# The watcher's main loop is the session leader; its per-iteration subshells share the command line.
watcher_pid() { ps -eo pid=,sid=,args= | awk '$1 == $2 && /pgbackrest-backup-watcher\.sh/ { print $1 }'; }
installed_is() { # <dir> <suffix>: the installed scripts are byte-identical to <dir>/<name><suffix>
  for f in $FILES; do cmp -s "$1/$f$2" "$BIN/$f" || return 1; done
}
install_from() { # <dir> <suffix>. New inode per file: a running watcher keeps reading the one it
  # opened, and postgres picks up the archive-push wrapper on its next archive_command.
  for f in $FILES; do
    install -m 755 -o root -g root "$1/$f$2" "$BIN/.$f.new" || return 1
    mv -f "$BIN/.$f.new" "$BIN/$f" || return 1
  done
}
# Same environment, same user, own session, output on the container's log stream. bash reads the
# NUL-separated environment and execs straight into the watcher, so no helper process is left
# behind; a backgrounded command is not a process group leader, so setsid(1) does not fork either.
# Succeeds only if one watcher is up after 2s and it is still the same one 5s later.
start_watcher() {
  cd /
  # shellcheck disable=SC2016  # expanded by the inner bash
  ENVIRON="$ENVIRON" bash -c 'mapfile -d "" -t e < "$ENVIRON"
exec env -i "${e[@]}" setsid gosu postgres /usr/local/bin/pgbackrest-backup-watcher.sh' \
    > /proc/1/fd/1 2> /proc/1/fd/2 < /dev/null &
  sleep 2
  STARTED=$(watcher_pid)
  [ -n "$STARTED" ] || return 1
  [ "$(printf '%s\n' "$STARTED" | grep -c .)" = 1 ] || return 1
  sleep 5
  [ "$(watcher_pid)" = "$STARTED" ]
}

OLD=$(watcher_pid)
# shellcheck disable=SC2086  # one pid per word
[ "$(printf '%s\n' "$OLD" | grep -c .)" -le 1 ] || { err "more than one watcher is running: $(printf '%s ' $OLD)"; exit 3; }

if [ -z "$OLD" ]; then
  # No watcher. Either archiving is off (nothing to do), or an earlier run of this script stopped
  # the watcher and was cut short before a new one was up: its saved environment is still here.
  [ -s "$ENVIRON" ] || { err "no running watcher found"; exit 3; }
  trap '' HUP INT TERM PIPE
  installed_is "$NEW" "" || install_from "$NEW" "" || { err "an earlier swap was cut short and the scripts could not be installed; NO watcher is running, run this again"; exit 5; }
  if start_watcher; then
    rm -f "$ENVIRON"
    say "an earlier swap was cut short; watcher started as $STARTED ($(ps -o user= -p "$STARTED" | tr -d ' '))"
    exit 0
  fi
  err "an earlier swap was cut short and the watcher did not start; NO watcher is running, run this again"
  exit 5
fi

# The watcher is its own session and process group leader (wrapper.sh starts it with setsid).
[ "$(ps -o pgid= -p "$OLD" | tr -d ' ')" = "$OLD" ] || { err "watcher $OLD is not a process group leader"; exit 3; }
if installed_is "$NEW" ""; then
  rm -f "$ENVIRON"
  say "already current (watcher $OLD)"
  exit 0
fi
# Never interrupt a base backup.
# shellcheck disable=SC2009  # pgrep cannot express "the pgbackrest binary, with a backup verb"
if ps -eo args= | grep -E '(^|/)pgbackrest( |$)' | grep -Eq ' backup( |$)'; then
  err "a pgbackrest backup is running; run this again when it has finished"; exit 4
fi

# Read as postgres: root in a container has no ptrace capability over another user's process.
umask 077
rm -f "$ENVIRON"
gosu postgres cat "/proc/$OLD/environ" > "$ENVIRON" || true
[ -s "$ENVIRON" ] || { rm -f "$ENVIRON"; err "could not read the watcher's environment"; exit 3; }
umask 022
for f in $FILES; do cp -p "$BIN/$f" "/tmp/$f.before-hotswap"; done

# From here to the end nothing may cut the run short: a signal from a closing exec session is
# ignored, and every step that can fail is handled.
trap '' HUP INT TERM PIPE
set +e
install_from "$NEW" "" || {
  install_from /tmp .before-hotswap
  rm -f "$ENVIRON"
  err "installing the new scripts failed; the previous scripts are back and watcher $OLD was not touched"
  exit 5
}

# By process group, with pkill: a negative pid is not portable across sh builtins.
pkill -TERM -g "$OLD"
i=0
while kill -0 "$OLD" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -le 30 ] || { pkill -KILL -g "$OLD"; sleep 1; break; }
  sleep 1
done
if kill -0 "$OLD" 2>/dev/null; then
  install_from /tmp .before-hotswap
  rm -f "$ENVIRON"
  err "the old watcher $OLD did not stop; the previous scripts are back and it keeps running"
  exit 5
fi

if start_watcher; then
  rm -f "$ENVIRON"
  say "watcher $OLD replaced by $STARTED ($(ps -o user= -p "$STARTED" | tr -d ' '))"
  exit 0
fi

# The new watcher did not stay up. Stop whatever is left of it and go back to the previous one.
for p in $(watcher_pid); do pkill -KILL -g "$p"; done
sleep 1
install_from /tmp .before-hotswap
if start_watcher; then
  rm -f "$ENVIRON"
  err "the new watcher did not stay up; the previous scripts are back and the previous watcher runs again as $STARTED"
  exit 5
fi
err "the new watcher did not stay up and the previous one did not start either; NO watcher is running, run this again"
exit 5
