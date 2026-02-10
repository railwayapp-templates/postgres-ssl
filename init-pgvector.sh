#!/bin/bash

# Create the pgvector extension in the default database
# This runs as part of docker-entrypoint-initdb.d after database initialization
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS vector;
EOSQL

