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

# Idempotency: docker-entrypoint-initdb.d runs on first init only, but a
# re-execution (manual run, unusual entrypoint ordering) must not rotate a
# CA that clients have pinned into their trust stores — that is an outage.
# Keep is keyed on VALIDITY, never mere existence: wrapper.sh re-runs this
# script precisely to REPLACE certs that are not x509v3 (no SAN) or that
# expire within 30 days, so an existence-only keep would turn both of those
# heals into no-ops. Keep only a complete set whose server.crt passes the
# SAME two tests wrapper.sh uses to decide a re-run is needed (checkend
# 2592000 = 30 days; DNS:localhost in the text output as the v3/SAN probe),
# so the two can never disagree; anything else regenerates.
if [ -f "$SSL_ROOT_CRT" ] && [ -f "$SSL_SERVER_CRT" ] && [ -f "$SSL_SERVER_KEY" ] \
  && openssl x509 -checkend 2592000 -noout -in "$SSL_SERVER_CRT" >/dev/null 2>&1 \
  && openssl x509 -noout -text -in "$SSL_SERVER_CRT" 2>/dev/null | grep -q "DNS:localhost"; then
  echo "init-ssl: valid certificates already present in $SSL_DIR; keeping them"
else
  echo "init-ssl: certificates absent, incomplete, expiring within 30 days, or missing the x509v3 SAN in $SSL_DIR; generating"

# A malformed day count must not stop the database: this script runs under
# wrapper.sh's set -e on every renewal (the checkend re-run above), so an
# exit here would crash-loop a healthy database the day its certificate
# crosses the 30-day window. Bash arithmetic would turn a typo into a
# nonsense value and openssl into a cert that expires at birth (and
# SSL_CERT_DAYS=0 is expired the moment it is written) — so WARN loudly and
# fall back to the default instead.
SSL_CERT_DAYS_VALUE="${SSL_CERT_DAYS:-820}"
case "$SSL_CERT_DAYS_VALUE" in
  ''|0|*[!0-9]*)
    echo "init-ssl: SSL_CERT_DAYS='${SSL_CERT_DAYS}' is not a positive integer; using 820 (a bad value must never stop certificate issuance)" >&2
    SSL_CERT_DAYS_VALUE=820
    ;;
esac

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