#!/bin/bash
set -e

# Set PGPORT to 5432
export PGPORT=5432

# Execute the original entrypoint script
/docker-entrypoint.sh "$@"
