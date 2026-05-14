#!/bin/bash
# get-postgres-version.sh
# Usage: ./get-postgres-version.sh 16
# Returns: 16.10 (latest minor version for PostgreSQL 16)

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <major_version>" >&2
    echo "Example: $0 16" >&2
    exit 1
fi

MAJOR_VERSION=$1

# Validate input is a number
if ! [[ "$MAJOR_VERSION" =~ ^[0-9]+$ ]]; then
    echo "Error: Major version must be a number" >&2
    exit 1
fi

echo "Fetching latest PostgreSQL $MAJOR_VERSION version..." >&2

# Query Docker Hub API for the latest version of this major release
# We look for tags that are major.minor format (no alpine, bookworm, etc)
# Paginate through results to find older major versions
LATEST_VERSION=""
NEXT_URL="https://hub.docker.com/v2/repositories/library/postgres/tags?page_size=100"

while [ -n "$NEXT_URL" ] && [ -z "$LATEST_VERSION" ]; do
  RESPONSE=$(curl -s "$NEXT_URL")

  # Collect all matching version tags on this page, sorted descending.
  CANDIDATES=$(echo "$RESPONSE" | \
    jq -r --arg major "$MAJOR_VERSION" '.results[] |
      select(.name | test("^" + $major + "\\.\\d+$")) |
      .name' | \
    sort -rV)

  # Pick the newest candidate whose multi-platform manifest is fully published
  # (images array non-empty). A tag with images:[] means Docker Hub received
  # the push but hasn't finished publishing all platforms — building against it
  # fails with "no match for platform in manifest".
  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    IMAGE_COUNT=$(curl -s "https://hub.docker.com/v2/repositories/library/postgres/tags/${candidate}" | \
      jq '.images | length')
    if [ "${IMAGE_COUNT:-0}" -gt 0 ]; then
      LATEST_VERSION="$candidate"
      break
    fi
    echo "Skipping ${candidate}: manifest not fully published yet (images=0)" >&2
  done <<< "$CANDIDATES"

  # Advance to next page only if we still haven't found a usable version.
  if [ -z "$LATEST_VERSION" ]; then
    NEXT_URL=$(echo "$RESPONSE" | jq -r '.next // empty')
  fi
done

if [ -z "$LATEST_VERSION" ]; then
  echo "Error: Could not find version for PostgreSQL $MAJOR_VERSION" >&2
  echo "Available major versions might be different. Check https://hub.docker.com/_/postgres" >&2
  exit 1
fi

echo "Found latest version: $LATEST_VERSION" >&2
echo "$LATEST_VERSION"