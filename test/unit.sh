#!/usr/bin/env bash
# Runs every test/unit-*.sh. Adding a unit test is dropping a new file here;
# neither this script nor the workflow needs an edit.
set -u
cd "$(dirname "$0")/.."

status=0
for t in test/unit-*.sh; do
  [ -e "$t" ] || continue
  echo "::group::$t"
  if bash "$t"; then
    echo "::endgroup::"
  else
    echo "::endgroup::"
    echo "::error file=$t::$t failed"
    status=1
  fi
done
exit "$status"
