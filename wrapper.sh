#!/bin/bash

# exit as soon as any of these commands fail, this prevents starting a database without certificates or with the wrong volume mount path
set -e

EXPECTED_VOLUME_MOUNT_PATHS=("/var/lib/postgresql" "/var/lib/postgresql/data")

# Function to check if a path matches any of the expected volume mount paths
# Usage: check_path_matches "exact" "/path/to/check" - for exact match
# Usage: check_path_matches "starts_with" "/path/to/check" - for prefix match
check_path_matches() {
  local match_type="$1"
  local path_to_check="$2"
  
  for expected_path in "${EXPECTED_VOLUME_MOUNT_PATHS[@]}"; do
    if [ "$match_type" = "exact" ]; then
      if [ "$path_to_check" = "$expected_path" ]; then
        return 0  # true - path matches
      fi
    elif [ "$match_type" = "starts_with" ]; then
      if [[ "$path_to_check" =~ ^"$expected_path" ]]; then
        return 0  # true - path starts with expected path
      fi
    fi
  done
  
  return 1  # false - no match found
}

# check if the Railway volume is mounted to one of the correct paths
# we do this by checking the current mount path (RAILWAY_VOLUME_MOUNT_PATH) against the expected mount paths
# if the paths don't match any of the expected paths, we print an error message and exit
# only perform this check if this image is deployed to Railway by checking for the existence of the RAILWAY_ENVIRONMENT variable
if [ -n "$RAILWAY_ENVIRONMENT" ] && ! check_path_matches "exact" "$RAILWAY_VOLUME_MOUNT_PATH"; then
  echo "Railway volume not mounted to any of the correct paths"
  echo "Expected one of: ${EXPECTED_VOLUME_MOUNT_PATHS[*]}"
  echo "But got: $RAILWAY_VOLUME_MOUNT_PATH"
  echo "Please update the volume mount path to one of the expected paths and redeploy the service"
  exit 1
fi

# check if PGDATA starts with one of the expected volume mount paths
# this ensures data files are stored in the correct location
# if not, print error and exit to prevent data loss or access issues
if ! check_path_matches "starts_with" "$PGDATA"; then
  echo "PGDATA variable does not start with any of the expected volume mount paths"
  echo "Expected to start with one of: ${EXPECTED_VOLUME_MOUNT_PATHS[*]}"
  echo "But got: $PGDATA"
  echo "Please update the PGDATA variable to start with one of the expected volume mount paths and redeploy the service"
  exit 1
fi

# Set up needed variables
SSL_DIR="/var/lib/postgresql/certs"
INIT_SSL_SCRIPT="/docker-entrypoint-initdb.d/init-ssl.sh"
POSTGRES_CONF_FILE="$PGDATA/postgresql.conf"

# Regenerate if the certificate is not a x509v3 certificate
if [ -f "$SSL_DIR/server.crt" ] && ! openssl x509 -noout -text -in "$SSL_DIR/server.crt" | grep -q "DNS:localhost"; then
  echo "Did not find a x509v3 certificate, regenerating certificates..."
  bash "$INIT_SSL_SCRIPT"
fi

# Regenerate if the certificate has expired or will expire
# 2592000 seconds = 30 days
if [ -f "$SSL_DIR/server.crt" ] && ! openssl x509 -checkend 2592000 -noout -in "$SSL_DIR/server.crt"; then
  echo "Certificate has or will expire soon, regenerating certificates..."
  bash "$INIT_SSL_SCRIPT"
fi

# Generate a certificate if the database was initialized but is missing a certificate
# Useful when going from the base postgres image to this ssl image
if [ -f "$POSTGRES_CONF_FILE" ] && [ ! -f "$SSL_DIR/server.crt" ]; then
  echo "Database initialized without certificate, generating certificates..."
  bash "$INIT_SSL_SCRIPT"
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
# appropriate PGHOST & PGPORT and redirect
# the output to stdout if LOG_TO_STDOUT is true
if [[ "$LOG_TO_STDOUT" == "true" ]]; then
    /usr/local/bin/docker-entrypoint.sh "$@" 2>&1
else
    /usr/local/bin/docker-entrypoint.sh "$@"
fi
