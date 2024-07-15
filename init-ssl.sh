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

# Use sudo to create the directory as root
sudo mkdir -p "$SSL_DIR"

# Use sudo to change ownership as root
sudo chown postgres:postgres "$SSL_DIR"

# Generate self-signed 509v3 certificates
# ref: https://www.postgresql.org/docs/16/ssl-tcp.html#SSL-CERTIFICATE-CREATION

openssl req -new -x509 -days "${SSL_CERT_DAYS:-820}" -nodes -text -out "$SSL_ROOT_CRT" -keyout "$SSL_ROOT_KEY" -subj "/CN=root-ca"

chmod og-rwx "$SSL_ROOT_KEY"

openssl req -new -nodes -text -out "$SSL_SERVER_CSR" -keyout "$SSL_SERVER_KEY" -subj "/CN=localhost"

chown postgres:postgres "$SSL_SERVER_KEY"

chmod og-rwx "$SSL_SERVER_KEY"

cat >| "$SSL_V3_EXT" <<EOF
[v3_req]
authorityKeyIdentifier = keyid, issuer
basicConstraints = critical, CA:TRUE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = DNS:localhost
EOF

openssl x509 -req -in "$SSL_SERVER_CSR" -extfile "$SSL_V3_EXT" -extensions v3_req -text -days "${SSL_CERT_DAYS:-820}" -CA "$SSL_ROOT_CRT" -CAkey "$SSL_ROOT_KEY" -CAcreateserial -out "$SSL_SERVER_CRT"

chown postgres:postgres "$SSL_SERVER_CRT"

# PostgreSQL configuration, enable ssl and set paths to certificate files
cat >> "$POSTGRES_CONF_FILE" <<EOF
ssl = on
ssl_cert_file = '$SSL_SERVER_CRT'
ssl_key_file = '$SSL_SERVER_KEY'
ssl_ca_file = '$SSL_ROOT_CRT'
EOF