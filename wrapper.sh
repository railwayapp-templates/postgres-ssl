#!/bin/bash

SSL_DIR="/var/lib/postgresql/data/certs"
INIT_SSL_SCRIPT="/usr/local/bin/init-ssl.sh"

# Check if certificates need to be regenerated
if [ "$REGENERATE_CERTS" = "true" ] || [ ! -f "$SSL_DIR/server.key" ] || [ ! -f "$SSL_DIR/server.crt" ] || [ ! -f "$SSL_DIR/root.crt" ]; then
    echo "Running init-ssl.sh to generate new certificates..."
    bash "$INIT_SSL_SCRIPT"
else
    echo "Certificates already exist and REGENERATE_CERTS is not set to true. Skipping certificate generation."
fi

# unset PGHOST to force psql to use Unix socket path
# this is specific to Railway and allows
# us to use PGHOST after the init
unset PGHOST

## unset PGPORT also specific to Railway
## since postgres checks for validity of
## the value in PGPORT we unset it in case
## it ends up being empty
unset PGPORT

# Call the entrypoint script with the
# approriate PGHOST & PGPORT
/usr/local/bin/docker-entrypoint.sh "$@"