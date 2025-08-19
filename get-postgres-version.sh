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
LATEST_VERSION=$(curl -s "https://hub.docker.com/v2/repositories/library/postgres/tags?page_size=100" | \
  jq -r --arg major "$MAJOR_VERSION" '.results[] | 
    select(.name | test("^" + $major + "\\.\\d+$")) | 
    .name' | \
  sort -V | \
  tail -1)

if [ -z "$LATEST_VERSION" ]; then
  echo "Error: Could not find version for PostgreSQL $MAJOR_VERSION" >&2
  echo "Available major versions might be different. Check https://hub.docker.com/_/postgres" >&2
  exit 1
fi

echo "Found latest version: $LATEST_VERSION" >&2
echo "$LATEST_VERSION"