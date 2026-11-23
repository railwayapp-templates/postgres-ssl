#!/usr/bin/env bash
# Runs the real archive-push wrapper against a stub pgBackRest: every outcome
# that takes a segment out of the PITR chain leaves .pgbackrest_gap_pending,
# and an outcome that keeps the segment does not.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/pgbackrest-archive-push-wrapper.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/pgdata/pg_wal"
MARKER="$WORK/pgdata/.pgbackrest_gap_pending"

# Stub pgBackRest: prints $STUB_OUT, exits $STUB_RC.
cat > "$WORK/bin/pgbackrest" << 'EOF'
#!/bin/sh
[ -n "${STUB_OUT:-}" ] && printf '%s\n' "$STUB_OUT"
exit "${STUB_RC:-0}"
EOF
# Stub df: a 100 GiB filesystem with $STUB_FREE_KIB free.
cat > "$WORK/bin/df" << 'EOF'
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/stub 104857600 0 ${STUB_FREE_KIB:-52428800} 50% /stub"
EOF
# Stub du: pg_wal and the spool each hold $STUB_DIR_BYTES.
cat > "$WORK/bin/du" << 'EOF'
#!/bin/sh
echo "${STUB_DIR_BYTES:-16777216} stub"
EOF
chmod +x "$WORK/bin/pgbackrest" "$WORK/bin/df" "$WORK/bin/du"

failures=0
# run_case <name> <expected exit> <marker: yes|no> — stub behaviour comes from
# the STUB_* variables set by the caller.
run_case() {
  local name="$1" want_rc="$2" want_marker="$3" rc marker=no
  rm -f "$MARKER"
  PATH="$WORK/bin:$PATH" PGDATA="$WORK/pgdata" WAL_ARCHIVE_BUCKET=bucket \
    WAL_DROP_THRESHOLD_MB="${THRESHOLD_MB:-5120}" \
    STUB_OUT="${STUB_OUT:-}" STUB_RC="${STUB_RC:-0}" \
    STUB_FREE_KIB="${STUB_FREE_KIB:-52428800}" STUB_DIR_BYTES="${STUB_DIR_BYTES:-16777216}" \
    bash "$WRAPPER" pg_wal/000000010000000000000042 >/dev/null 2>&1
  rc=$?
  [ -e "$MARKER" ] && marker=yes
  if [ "$rc" != "$want_rc" ] || [ "$marker" != "$want_marker" ]; then
    echo "FAIL [$name]: exit=$rc (want $want_rc), gap marker=$marker (want $want_marker)"
    failures=$((failures + 1))
  fi
}

STUB_RC=0 STUB_OUT="P00   INFO: pushed WAL file '000000010000000000000042' to the archive asynchronously" \
  run_case "segment archived" 0 no

# pgBackRest drops its queue and reports the segment as archived.
STUB_RC=0 STUB_OUT="P00   WARN: dropped WAL file '000000010000000000000042' because archive queue exceeded 128MB" \
  run_case "pgBackRest queue-max drop" 0 yes

# archive-push fails with room to spare: Postgres keeps the segment and retries.
STUB_RC=82 STUB_OUT="P00  ERROR: [082]: unable to push WAL file '000000010000000000000042' to the archive asynchronously after 1m second(s)" \
  run_case "timeout with room to spare" 82 no

STUB_RC=104 STUB_OUT="<Error><Code>InvalidAccessKeyId</Code></Error>" \
  run_case "credentials revoked" 0 yes

STUB_RC=82 STUB_FREE_KIB=1024 \
  run_case "data volume almost full" 0 yes

STUB_RC=82 THRESHOLD_MB=16 \
  run_case "pg_wal and spool past the drop threshold" 0 yes

if [ "$failures" -ne 0 ]; then
  echo "${failures} archive-push wrapper check(s) failed"
  exit 1
fi
echo 'archive-push wrapper regression tests passed'
