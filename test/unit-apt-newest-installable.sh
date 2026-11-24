#!/usr/bin/env bash
# apt-newest-installable.sh: the extension package the image build installs
# next to a held Postgres server.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PICK="$ROOT/apt-newest-installable.sh"

# Stub apt: `apt-cache madison` prints $MADISON; `apt-get install -s` succeeds
# unless the requested version is listed in $UNINSTALLABLE, and records what
# it was asked for.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/apt-cache" <<'EOF'
#!/bin/sh
[ "$1" = madison ] || exit 2
printf '%s\n' "$MADISON"
EOF
cat > "$WORK/bin/apt-get" <<'EOF'
#!/bin/sh
for arg; do spec=$arg; done
echo "$*" >> "$APT_GET_LOG"
case " $UNINSTALLABLE " in *" ${spec#*=} "*) exit 100 ;; esac
exit 0
EOF
chmod +x "$WORK/bin/apt-cache" "$WORK/bin/apt-get"
export PATH="$WORK/bin:$PATH" APT_GET_LOG="$WORK/apt-get.log"

# The pool as PGDG served it on 2026-11-24: each version once per index it is
# listed in, newest first.
export MADISON=" postgresql-18-pgvector | 0.8.7-1.pgdg13+2 | http://apt.postgresql.org/pub/repos/apt trixie-pgdg/main amd64 Packages
 postgresql-18-pgvector | 0.8.7-1.pgdg13+2 | http://apt.postgresql.org/pub/repos/apt trixie-pgdg/18 amd64 Packages
 postgresql-18-pgvector | 0.8.7-1.pgdg13+1 | http://apt.postgresql.org/pub/repos/apt trixie-pgdg/main amd64 Packages
 postgresql-18-pgvector | 0.8.6-1.pgdg13+2 | http://apt.postgresql.org/pub/repos/apt trixie-pgdg/main amd64 Packages"

# The newest minor of the major: every build installs, the newest is taken and
# nothing older is even tried.
: > "$APT_GET_LOG"
export UNINSTALLABLE=""
[ "$("$PICK" postgresql-18-pgvector '0.8.*')" = "0.8.7-1.pgdg13+2" ]
[ "$(wc -l < "$APT_GET_LOG" | tr -d ' ')" = 1 ]
grep -q -- '-s .*postgresql-18-pgvector=0.8.7-1.pgdg13+2$' "$APT_GET_LOG"

# An older minor on hold: the newest build depends on a newer server, so the
# build before it is taken.
export UNINSTALLABLE="0.8.7-1.pgdg13+2"
[ "$("$PICK" postgresql-18-pgvector '0.8.*')" = "0.8.7-1.pgdg13+1" ]

# Two builds refuse the held server.
export UNINSTALLABLE="0.8.7-1.pgdg13+2 0.8.7-1.pgdg13+1"
[ "$("$PICK" postgresql-18-pgvector '0.8.*')" = "0.8.6-1.pgdg13+2" ]

# The pattern is the pin: a newer extension minor in the pool is never taken,
# whether or not it would install.
export UNINSTALLABLE=""
MADISON_WITH_NEXT_MINOR=" postgresql-18-pgvector | 0.9.0-1.pgdg13+1 | http://apt.postgresql.org/pub/repos/apt trixie-pgdg/main amd64 Packages
$MADISON"
[ "$(MADISON="$MADISON_WITH_NEXT_MINOR" "$PICK" postgresql-18-pgvector '0.8.*')" = "0.8.7-1.pgdg13+2" ]

# No pattern: any version, newest installable first.
[ "$(MADISON="$MADISON_WITH_NEXT_MINOR" "$PICK" postgresql-18-pgvector)" = "0.9.0-1.pgdg13+1" ]

# Nothing in the pinned minor installs: the build stops, naming what it tried.
export UNINSTALLABLE="0.8.7-1.pgdg13+2 0.8.7-1.pgdg13+1 0.8.6-1.pgdg13+2"
if out=$("$PICK" postgresql-18-pgvector '0.8.*' 2>"$WORK/err"); then
  echo "expected a failure, got '$out'" >&2
  exit 1
fi
[ -z "$out" ]
grep -q "no version of postgresql-18-pgvector matching '0.8.\*' can be installed (tried: 0.8.7-1.pgdg13+2 0.8.7-1.pgdg13+1 0.8.6-1.pgdg13+2)" "$WORK/err"

# The pinned minor is gone from the pool altogether.
export UNINSTALLABLE=""
if "$PICK" postgresql-18-pgvector '0.7.*' >/dev/null 2>"$WORK/err"; then
  echo "expected a failure for a pruned minor" >&2
  exit 1
fi
grep -q "(tried: none)" "$WORK/err"

echo "apt-newest-installable takes the newest build the held server accepts, inside the pinned pattern"
