#!/usr/bin/env bash
# The image-managed shared_preload_libraries repair (ensure_image_preload_libraries).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
for fn in preload_value preload_has add_preload_library ensure_image_preload_libraries; do
  source <(sed -n "/^${fn}() {\$/,/^}\$/p" "$ROOT/wrapper.sh")
done
IMAGE_PRELOAD_LIBRARIES="pg_stat_statements pgaudit"
CONF="$WORK/postgresql.conf"; AUTO="$WORK/postgresql.auto.conf"

# A fresh volume (init-ssl.sh wrote both): nothing appended, auto.conf untouched.
printf "#shared_preload_libraries = ''\nshared_preload_libraries = 'pg_stat_statements,pgaudit'\n" > "$CONF"
printf "max_connections = '500'\n" > "$AUTO"
ensure_image_preload_libraries "$CONF" "$AUTO" >/dev/null
[ "$(preload_value "$CONF")" = "pg_stat_statements,pgaudit" ]
[ "$(grep -c shared_preload_libraries "$CONF")" = 2 ]
! grep -q shared_preload_libraries "$AUTO"

# A volume from before pgaudit: the list is extended, not replaced.
printf "shared_preload_libraries = 'pg_stat_statements'\t# comment\n" > "$CONF"
ensure_image_preload_libraries "$CONF" "$AUTO" | grep -q 'adding pgaudit to shared_preload_libraries in postgresql.conf'
[ "$(preload_value "$CONF")" = "pg_stat_statements,pgaudit" ]

# A volume from before pg_stat_statements too, with an operator library.
printf "shared_preload_libraries = 'auto_explain'\n" > "$CONF"
ensure_image_preload_libraries "$CONF" "$AUTO" >/dev/null
[ "$(preload_value "$CONF")" = "auto_explain,pg_stat_statements,pgaudit" ]

# An operator ALTER SYSTEM list overrides postgresql.conf wholesale, so it is
# repaired too — and a pgaudit.* GUC on a neighbouring line must not read as
# pgaudit being preloaded.
printf "shared_preload_libraries = 'pg_stat_statements,pgaudit'\n" > "$CONF"
printf "pgaudit.log = 'ddl'\nshared_preload_libraries = 'pg_stat_statements'\n" > "$AUTO"
ensure_image_preload_libraries "$CONF" "$AUTO" | grep -q 'adding pgaudit to shared_preload_libraries in postgresql.auto.conf'
[ "$(preload_value "$AUTO")" = "pg_stat_statements,pgaudit" ]
[ "$(grep -c shared_preload_libraries "$CONF")" = 1 ]

# ALTER SYSTEM's list syntax renders with spaces; the single-string gotcha
# form renders with inner double quotes. Both normalize to the same list.
printf "shared_preload_libraries = 'pg_stat_statements, pgaudit'\n" > "$AUTO"
[ "$(preload_value "$AUTO")" = "pg_stat_statements,pgaudit" ]
printf "shared_preload_libraries = '\"pg_stat_statements,pgaudit\"'\n" > "$AUTO"
[ "$(preload_value "$AUTO")" = "pg_stat_statements,pgaudit" ]
preload_has "$AUTO" pgaudit
! preload_has "$AUTO" pgaudi

# No postgresql.conf (volume not initialized yet): a no-op.
rm -f "$CONF"
ensure_image_preload_libraries "$CONF" "$AUTO" >/dev/null
echo 'image preload libraries are added to postgresql.conf and to an operator auto.conf list, by element'
