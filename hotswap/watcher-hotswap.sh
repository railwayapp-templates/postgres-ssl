#!/bin/sh
# watcher-hotswap.sh <dir>
#
# Runs INSIDE a running postgres-ssl container, as root. Replaces the PITR backup watcher and the
# archive-push wrapper with the copies in <dir> and restarts only the watcher; Postgres keeps
# running. Not part of the image: the platform runs it in containers deployed from an older image,
# so a watcher fix reaches them without a restart. A new deploy installs the image's own scripts.
#
# Exit status:
#   0  swapped, or the installed scripts already match <dir>
#   2  <dir> is incomplete or a script in it does not parse; not run as root
#   3  not applicable: no watcher running (archiving off), or the process layout is not the one
#      wrapper.sh creates
#   4  a pgBackRest backup is running; nothing changed, run it again later
#   5  the swap started but did not finish (see the message)
set -eu
NEW=${1:?directory holding the new scripts}
BIN=/usr/local/bin
for f in pgbackrest-backup-watcher.sh pgbackrest-archive-push-wrapper.sh; do
  [ -s "$NEW/$f" ] || { echo "hotswap: $NEW/$f is missing" >&2; exit 2; }
  sh -n "$NEW/$f" 2>/dev/null || bash -n "$NEW/$f" || { echo "hotswap: $NEW/$f does not parse" >&2; exit 2; }
done
[ "$(id -u)" = 0 ] || { echo "hotswap: must run as root (running as $(id -un))" >&2; exit 2; }

# The watcher's main loop is the session leader; its per-iteration subshells share the command line.
watcher_pid() { ps -eo pid=,sid=,args= | awk '$1 == $2 && /pgbackrest-backup-watcher\.sh/ { print $1 }'; }
OLD=$(watcher_pid)
# shellcheck disable=SC2086  # one pid per word
[ "$(printf '%s\n' "$OLD" | grep -c .)" -le 1 ] || { echo "hotswap: more than one watcher is running: $(printf '%s ' $OLD)" >&2; exit 3; }
[ -n "$OLD" ] || { echo "hotswap: no running watcher found" >&2; exit 3; }
# The watcher is its own session and process group leader (wrapper.sh starts it with setsid).
[ "$(ps -o pgid= -p "$OLD" | tr -d ' ')" = "$OLD" ] || { echo "hotswap: watcher $OLD is not a process group leader" >&2; exit 3; }
if cmp -s "$NEW/pgbackrest-backup-watcher.sh" "$BIN/pgbackrest-backup-watcher.sh" \
  && cmp -s "$NEW/pgbackrest-archive-push-wrapper.sh" "$BIN/pgbackrest-archive-push-wrapper.sh"; then
  echo "hotswap: already current (watcher $OLD)"
  exit 0
fi
# Never interrupt a base backup.
# shellcheck disable=SC2009  # pgrep cannot express "the pgbackrest binary, with a backup verb"
if ps -eo args= | grep -E '(^|/)pgbackrest( |$)' | grep -Eq ' backup( |$)'; then
  echo "hotswap: a pgbackrest backup is running; run this again when it has finished" >&2; exit 4
fi

# The watcher's environment holds the bucket credentials: private file, removed on every exit path.
# Read as postgres: root in a container has no ptrace capability over another user's process.
umask 077
trap 'rm -f /tmp/.watcher-environ' EXIT
gosu postgres cat "/proc/$OLD/environ" > /tmp/.watcher-environ
[ -s /tmp/.watcher-environ ] || { echo "hotswap: could not read the watcher's environment" >&2; exit 3; }
umask 022

# New inode for each file: the running watcher keeps reading the old one until it is stopped, and
# postgres picks up the new archive-push wrapper on its next archive_command.
for f in pgbackrest-backup-watcher.sh pgbackrest-archive-push-wrapper.sh; do
  cp -p "$BIN/$f" "/tmp/$f.before-hotswap"
  install -m 755 -o root -g root "$NEW/$f" "$BIN/.$f.new"
  mv -f "$BIN/.$f.new" "$BIN/$f"
done

# By process group, with pkill: a negative pid is not portable across sh builtins.
pkill -TERM -g "$OLD" || true
i=0
while kill -0 "$OLD" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -le 30 ] || { pkill -KILL -g "$OLD" || true; sleep 1; break; }
  sleep 1
done
if kill -0 "$OLD" 2>/dev/null; then
  echo "hotswap: the old watcher $OLD did not stop; the new scripts are installed but no new watcher was started" >&2
  exit 5
fi

# Same environment, same user, own session, output on the container's log stream.
cd /
# bash reads the NUL-separated environment and execs straight into the watcher, so no helper
# process is left behind. A backgrounded command is not a process group leader, so setsid(1)
# does not fork either.
# shellcheck disable=SC2016  # expanded by the inner bash
bash -c 'mapfile -d "" -t e < /tmp/.watcher-environ
exec env -i "${e[@]}" setsid gosu postgres /usr/local/bin/pgbackrest-backup-watcher.sh' \
  > /proc/1/fd/1 2> /proc/1/fd/2 < /dev/null &
sleep 2
NEWPID=$(watcher_pid)
[ -n "$NEWPID" ] && [ "$NEWPID" != "$OLD" ] || { echo "hotswap: the new watcher did not start" >&2; exit 5; }
echo "hotswap: watcher $OLD replaced by $NEWPID ($(ps -o user= -p "$NEWPID" | tr -d ' '))"
