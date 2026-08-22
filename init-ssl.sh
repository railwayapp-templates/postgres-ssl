#!/bin/bash

# exit as soon as any of these commands fail, this prevents starting a database without certificates
set -e

# Set up needed variables
SSL_DIR="/var/lib/postgresql/data/certs"

SSL_SERVER_CRT="$SSL_DIR/server.crt"
SSL_SERVER_KEY="$SSL_DIR/server.key"
SSL_SERVER_CSR="$SSL_DIR/server.csr"

SSL_ROOT_KEY="$SSL_DIR/root.key"
SSL_ROOT_CRT="$SSL_DIR/root.crt"

SSL_V3_EXT="$SSL_DIR/v3.ext"

POSTGRES_CONF_FILE="$PGDATA/postgresql.conf"

# A malformed day count must fail loudly, not degrade silently: bash
# arithmetic would turn a typo into a nonsense value and openssl into a
# cert that expires at birth, and SSL_CERT_DAYS=0 issues a certificate
# that is expired the moment it is written.
SSL_CERT_DAYS_VALUE="${SSL_CERT_DAYS:-820}"
case "$SSL_CERT_DAYS_VALUE" in
  ''|0|*[!0-9]*)
    echo "init-ssl: SSL_CERT_DAYS='${SSL_CERT_DAYS}' is not a positive integer; refusing to issue certificates with it" >&2
    exit 1
    ;;
esac

# Idempotency: docker-entrypoint-initdb.d runs on first init only, but a
# re-execution (manual run, unusual entrypoint ordering) must not rotate a
# CA that clients have pinned into their trust stores — that is an outage.
# Regenerate only when the set is absent or incomplete, and say so.
if [ -f "$SSL_ROOT_CRT" ] && [ -f "$SSL_SERVER_CRT" ] && [ -f "$SSL_SERVER_KEY" ]; then
  echo "init-ssl: certificates already present in $SSL_DIR; keeping them"
else
  echo "init-ssl: certificate set incomplete or absent in $SSL_DIR; generating"

# Use sudo to create the directory as root
sudo mkdir -p "$SSL_DIR"

# Use sudo to change ownership as root
sudo chown postgres:postgres "$SSL_DIR"

# Generate self-signed 509v3 certificates
# ref: https://www.postgresql.org/docs/16/ssl-tcp.html#SSL-CERTIFICATE-CREATION

openssl req -new -x509 -days "$SSL_CERT_DAYS_VALUE" -nodes -text -out "$SSL_ROOT_CRT" -keyout "$SSL_ROOT_KEY" -subj "/CN=root-ca"

chmod 600 "$SSL_ROOT_KEY"

openssl req -new -nodes -text -out "$SSL_SERVER_CSR" -keyout "$SSL_SERVER_KEY" -subj "/CN=localhost"

chown postgres:postgres "$SSL_SERVER_KEY"

chmod 600 "$SSL_SERVER_KEY"

# Clients that verify the server certificate (sslmode=verify-full) match
# the hostname they dial against the cert's SAN entries. localhost alone
# only admits local connections; include the service's private hostname
# when the environment provides one.
SSL_SAN="DNS:localhost"
if [ -n "${RAILWAY_PRIVATE_DOMAIN:-}" ]; then
  SSL_SAN="${SSL_SAN},DNS:${RAILWAY_PRIVATE_DOMAIN}"
fi

cat >| "$SSL_V3_EXT" <<EOF
[v3_req]
authorityKeyIdentifier = keyid, issuer
basicConstraints = critical, CA:TRUE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = ${SSL_SAN}
EOF

openssl x509 -req -in "$SSL_SERVER_CSR" -extfile "$SSL_V3_EXT" -extensions v3_req -text -days "$SSL_CERT_DAYS_VALUE" -CA "$SSL_ROOT_CRT" -CAkey "$SSL_ROOT_KEY" -CAcreateserial -out "$SSL_SERVER_CRT"

chown postgres:postgres "$SSL_SERVER_CRT"

fi

# PostgreSQL configuration, enable ssl and set paths to certificate files.
# Guarded so a re-execution does not append a second copy of the block.
if ! grep -q "^ssl_cert_file = '$SSL_SERVER_CRT'" "$POSTGRES_CONF_FILE" 2>/dev/null; then
  cat >> "$POSTGRES_CONF_FILE" <<EOF
ssl = on
ssl_cert_file = '$SSL_SERVER_CRT'
ssl_key_file = '$SSL_SERVER_KEY'
ssl_ca_file = '$SSL_ROOT_CRT'
shared_preload_libraries = 'pg_stat_statements'
EOF
fi