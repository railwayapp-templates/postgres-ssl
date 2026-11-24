#!/bin/sh
# apt-newest-installable.sh <package> [version-pattern]
#
# Prints the newest version of <package> that matches the pattern (a shell
# glob, default "*") and that apt can install next to the packages on hold.
#
# The image holds the Postgres server at the minor its tag names. PGDG builds
# each extension package against the newest minor of a major and, when that
# minor changes what extensions link against, makes the package depend on it
# (e.g. postgresql-18-pgvector 0.8.7-1.pgdg13+2 depends on
# postgresql-18 (>> 18.7)). The build of an older minor tag then needs the
# newest extension package that still accepts the held server; the build of
# the newest minor gets the newest package, as before.
set -eu

pkg=$1
pattern=${2:-*}

tried=""
for version in $(apt-cache madison "$pkg" | awk -F'|' '{ gsub(/ /, "", $2); if (!seen[$2]++) print $2 }'); do
  # shellcheck disable=SC2254  # the pattern is a glob on purpose
  case "$version" in
    $pattern) ;;
    *) continue ;;
  esac
  if apt-get install -s -y "$pkg=$version" >/dev/null 2>&1; then
    printf '%s\n' "$version"
    exit 0
  fi
  tried="$tried $version"
done

echo "apt-newest-installable: no version of $pkg matching '$pattern' can be installed (tried:${tried:- none})" >&2
exit 1
