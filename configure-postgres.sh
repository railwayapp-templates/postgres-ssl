#!/bin/bash
set -e

# Check if the environment variables are set and apply the configurations accordingly
if [ ! -z "${POSTGRES_MAX_CONNECTIONS}" ]; then
    psql -U postgres -c "ALTER SYSTEM SET max_connections = ${POSTGRES_MAX_CONNECTIONS};"
fi

if [ ! -z "${POSTGRES_SHARED_BUFFERS}" ]; then
    psql -U postgres -c "ALTER SYSTEM SET shared_buffers = '${POSTGRES_SHARED_BUFFERS}';"
fi

if [ ! -z "${CONNECTION_CHECK_INTERVAL}" ]; then
    psql -U postgres -c "ALTER SYSTEM SET client_connection_check_interval = ${CONNECTION_CHECK_INTERVAL};"
fi

# Reload the PostgreSQL configuration
psql -U postgres -c "SELECT pg_reload_conf();"
