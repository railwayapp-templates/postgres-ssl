#!/usr/bin/env bash
# Exercise the production renderer without writing to /etc or needing Postgres.
# The sourced production functions consume the fixture variables below.
# shellcheck disable=SC1090,SC2034
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
source <(sed -n '/^clamp() {$/,/^}$/p' "$ROOT/wrapper.sh")
source <(sed -n '/^render_pgbackrest_conf() {$/,/^}$/p' "$ROOT/wrapper.sh")
mkdir() { [[ "$*" == '-p /etc/pgbackrest' ]]; }
chown() { [[ "$*" == "postgres:postgres $PGBACKREST_CONF_FILE" ]]; }
detect_cpus() { echo "$TEST_CPUS"; }
export WAL_ARCHIVE_BUCKET=test-bucket WAL_ARCHIVE_KEY=test-key WAL_ARCHIVE_SECRET=test-secret
export WAL_ARCHIVE_REGION=us-east-1 WAL_ARCHIVE_ENDPOINT=http://localhost:9000
PGDATA="$WORK/pgdata"
PGBACKREST_SPOOL_DIR="$PGDATA/pgbackrest-spool"
POSTGRES_CONF_FILE="$PGDATA/postgresql.conf"
PGBACKREST_CONF_FILE="$WORK/pgbackrest.conf"
unset PGBACKREST_BACKUP_PROCESS_MAX PGBACKREST_ARCHIVE_PUSH_PROCESS_MAX
unset PGBACKREST_ARCHIVE_GET_PROCESS_MAX PGBACKREST_RESTORE_PROCESS_MAX
workers() {
  awk -v section="[global:$1]" '$0 == section { found=1; next } found && /^process-max=/ { sub(/^process-max=/, ""); print; exit }' "$PGBACKREST_CONF_FILE"
}
for TEST_CPUS in 1 4 16 64 256; do
  render_pgbackrest_conf
  [[ "$(workers backup)" == 1 ]]
  [[ "$(workers archive-push)" == "$(clamp $((TEST_CPUS / 8)) 2 8)" ]]
  [[ "$(workers archive-get)" == 1 ]]
  [[ "$(workers restore)" == "$(clamp "$TEST_CPUS" 1 32)" ]]
  grep -qx 'start-fast=n' "$PGBACKREST_CONF_FILE"
done
# Explicit overrides survive the new defaults and remain command-scoped.
PGBACKREST_BACKUP_PROCESS_MAX=4
PGBACKREST_ARCHIVE_PUSH_PROCESS_MAX=3
PGBACKREST_ARCHIVE_GET_PROCESS_MAX=2
PGBACKREST_RESTORE_PROCESS_MAX=24
render_pgbackrest_conf
[[ "$(workers backup)" == 4 ]]
[[ "$(workers archive-push)" == 3 ]]
[[ "$(workers archive-get)" == 2 ]]
[[ "$(workers restore)" == 24 ]]
echo 'backup defaults to one reader at every CPU size; command overrides remain independent'
