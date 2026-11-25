#!/bin/bash
# watcher-hotswap.sh against a published image whose watcher predates #169. One database, five phases:
#   1. old watcher: archive failures that lose no WAL  -> a diff backup (the bug #169 fixed)
#   2. watcher-hotswap.sh in the running container     -> Postgres never restarts
#   3. this repo's watcher: the same failures          -> no backup; running the swap again is a no-op
#   4. a new watcher that exits at once                -> the previous scripts and watcher come back
#   5. a swap cut short after the old watcher stopped  -> the next run starts the watcher again
#
#   IMAGE=ghcr.io/railwayapp-templates/postgres-ssl@sha256:<digest> [SFX=-a] test/e2e-watcher-hotswap.sh
#
# Waits are generous: a base backup on a loaded Docker VM can take minutes. SFX names the
# containers, so several images can be tested at the same time. EXTRA_ENV adds `-e NAME=value`
# words to the Postgres container, for settings a version handles differently.
#
# Default IMAGE: the postgres-ssl:18 build of Oct 9 that the databases in the Nov 22 PITR escalation
# run. The platform swaps a container only when the watcher installed in it is a version this test
# passed on, so run it on an image of every watcher version before listing that version there.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
IMAGE=${IMAGE:-ghcr.io/railwayapp-templates/postgres-ssl@sha256:fcc6686a3f4f1962fe4ed77a15884553b7bd611ae1cea3204687968c5c09d517}
MINIO_IMAGE=postgres-ssl-test-minio:local
# Built from source (see Dockerfile.minio); reuse the e2e harness's copy when it is there.
docker image inspect "$MINIO_IMAGE" >/dev/null 2>&1 \
  || docker build -q -f "$ROOT/test/Dockerfile.minio" -t "$MINIO_IMAGE" "$ROOT/test" >/dev/null \
  || { echo "building the test MinIO image failed" >&2; exit 1; }
SFX=${SFX:-}
NET=hotswap-net$SFX MINIO=hotswap-minio$SFX PG=hotswap-pg$SFX VOL=hotswap-vol$SFX MVOL=hotswap-minio-data$SFX BUCKET=hotswap
MU=minioadmin MP=minioadmin123 USR=hotswap-user PASS=hotswap-pass-12345
PGDATA_DIR=/var/lib/postgresql/data/pgdata
say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { say "FAIL: $*"; say "--- last container log lines"; docker logs "$PG" 2>&1 | tail -25 | cut -c1-240; exit 1; }
mc() { docker run --rm --network "$NET" --entrypoint /bin/sh "$MINIO_IMAGE" -c "mc alias set local http://${MINIO}:9000 ${MU} ${MP} >/dev/null; $*"; }
q() { docker exec "$PG" psql -U postgres -h 127.0.0.1 -At -c "$1" 2>/dev/null; }
count() { docker logs "$PG" 2>&1 | grep -c -- "$1" || true; }
wait_log() { local pat=$1 secs=$2 min=${3:-1}; local end=$(( $(date +%s) + secs )); while [ "$(date +%s)" -lt "$end" ]; do [ "$(count "$pat")" -ge "$min" ] && return 0; sleep 2; done; return 1; }
readonly_on()  { mc "mc admin policy detach local readwrite --user ${USR} 2>/dev/null; mc admin policy attach local readonly --user ${USR} 2>/dev/null" >/dev/null; }
readonly_off() { mc "mc admin policy detach local readonly --user ${USR} 2>/dev/null; mc admin policy attach local readwrite --user ${USR} 2>/dev/null" >/dev/null; }
# One round of archive failures that lose no WAL: pushes are refused for a few segments, then accepted again.
fail_pushes_then_recover() {
  local before; before=$(q "select failed_count from pg_stat_archiver")
  readonly_on
  for _ in 1 2 3 4 5; do q "insert into t select g from generate_series(1,100) g; select pg_switch_wal()" >/dev/null; sleep 2; done
  local after; after=$(q "select failed_count from pg_stat_archiver")
  [ "${after:-0}" -gt "${before:-0}" ] || die "failed_count did not grow ($before -> $after)"
  readonly_off
  say "failed_count $before -> $after, pushes accepted again"
}

docker rm -f "$PG" "$MINIO" >/dev/null 2>&1; docker volume rm "$VOL" "$MVOL" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1
docker network create "$NET" >/dev/null
docker run -d --name "$MINIO" --network "$NET" -e "MINIO_ROOT_USER=$MU" -e "MINIO_ROOT_PASSWORD=$MP" -v "$MVOL:/data" "$MINIO_IMAGE" server /data >/dev/null || { say "minio did not start"; exit 1; }
for _ in $(seq 1 40); do mc "mc ls local" >/dev/null 2>&1 && break; sleep 1; done
mc "mc ls local" >/dev/null 2>&1 || { say "minio never became ready"; exit 1; }
mc "mc mb -p local/${BUCKET} >/dev/null; mc admin user add local ${USR} ${PASS}; mc admin policy attach local readwrite --user ${USR}" >/dev/null || { say "bucket/user setup failed"; exit 1; }

say "image: $IMAGE${EXTRA_ENV:+ ($EXTRA_ENV)}"
# shellcheck disable=SC2086  # EXTRA_ENV is a list of words
docker run -d --name "$PG" --network "$NET" \
  -e POSTGRES_PASSWORD=test -e "PGDATA=$PGDATA_DIR" \
  -e "WAL_ARCHIVE_BUCKET=$BUCKET" -e "WAL_ARCHIVE_ENDPOINT=http://${MINIO}:9000" -e WAL_ARCHIVE_REGION=us-east-1 \
  -e "WAL_ARCHIVE_KEY=$USR" -e "WAL_ARCHIVE_SECRET=$PASS" -e WAL_ARCHIVE_PATH=/pgbackrest -e PGBACKREST_REPO1_S3_URI_STYLE=path \
  -e WAL_DROP_THRESHOLD_MB=999999 -e POSTGRES_ARCHIVE_TIMEOUT=5 -e WAL_BACKUP_POLL_INTERVAL_SECONDS=5 -e WAL_BACKUP_GAP_RECOVERY_BACKOFF_SECONDS=10 \
  ${EXTRA_ENV:-} \
  -v "$VOL:/var/lib/postgresql/data" "$IMAGE" >/dev/null || { say "postgres container did not start"; exit 1; }
for _ in $(seq 1 120); do docker exec -e PGHOSTADDR= -e PGHOST= "$PG" pg_isready -q -h 127.0.0.1 -p 5432 -U postgres 2>/dev/null && break; sleep 1; done
q "select 1" >/dev/null || die "postgres never accepted connections"
say "installed in the image: $(docker exec "$PG" sh -c 'cd /usr/local/bin && sha256sum pgbackrest-backup-watcher.sh pgbackrest-archive-push-wrapper.sh' | paste -sd' ' -)"
say "postgres $(q 'show server_version') up; watcher in image has $(docker exec "$PG" grep -c 'archive-failure:' /usr/local/bin/pgbackrest-backup-watcher.sh) archive-failure lines"
q "create table t(id int); select pg_switch_wal()" >/dev/null
wait_log "pgbackrest-watcher: backup --type=full completed" 900 || die "no initial full backup"
say "initial full backup done"

say "== phase 1: old watcher, one round of archive failures that lose no WAL"
d0=$(count "running pgbackrest backup --type=diff")
fail_pushes_then_recover
end=$(( $(date +%s) + 600 )); while [ "$(date +%s)" -lt "$end" ]; do q "select pg_switch_wal()" >/dev/null; [ "$(count 'pgbackrest-watcher: backup --type=diff completed')" -ge 1 ] && break; sleep 3; done
d1=$(count "running pgbackrest backup --type=diff")
say "old watcher: gap-recovery entries=$(count 'gap-recovery: entering recovery'), diff backups started $d0 -> $d1"
[ "$d1" -gt "$d0" ] || die "the old watcher did not take a diff: the reported bug did not reproduce on this image"
wait_log "pgbackrest-watcher: backup --type=diff completed" 600 || die "the diff never completed"
sleep 12

say "== phase 2: hot swap with postgres running"
started_before=$(docker inspect -f '{{.State.StartedAt}} restarts={{.RestartCount}}' "$PG")
pm_before=$(q "select pg_postmaster_start_time()")
pmpid_before=$(q "select pg_backend_pid() > 0, (select setting from pg_settings where name='data_directory')" >/dev/null; docker exec "$PG" head -1 "$PGDATA_DIR/postmaster.pid")
old_watcher=$(docker exec "$PG" sh -c "ps -eo pid=,sid=,args= | awk '\$1 == \$2 && /pgbackrest-backup-watcher\\.sh/ { print \$1 }'")
starts_before=$(count "pgbackrest-watcher: starting (")
# A client session that stays open across the swap.
( docker exec "$PG" psql -U postgres -h 127.0.0.1 -At -c "select pg_sleep(45); select 'session-survived'" > "$D/session.out" 2>&1 ) &
sess=$!
sleep 2
docker exec -u root "$PG" mkdir -p /tmp/pitr-hotswap
for f in pgbackrest-backup-watcher.sh pgbackrest-archive-push-wrapper.sh hotswap/watcher-hotswap.sh; do
  docker cp "$ROOT/$f" "$PG:/tmp/pitr-hotswap/$(basename "$f")" >/dev/null || die "docker cp $f failed"
done
docker exec -u root "$PG" sh /tmp/pitr-hotswap/watcher-hotswap.sh /tmp/pitr-hotswap || die "watcher-hotswap.sh exited $?"
sleep 8
[ "$(docker inspect -f '{{.State.Status}}' "$PG")" = running ] || die "container is not running after the swap"
[ "$(docker inspect -f '{{.State.StartedAt}} restarts={{.RestartCount}}' "$PG")" = "$started_before" ] || die "the container restarted"
[ "$(q 'select pg_postmaster_start_time()')" = "$pm_before" ] || die "postgres restarted (postmaster start time changed)"
[ "$(docker exec "$PG" head -1 "$PGDATA_DIR/postmaster.pid")" = "$pmpid_before" ] || die "postmaster pid changed"
docker exec "$PG" sh -c "kill -0 $old_watcher" 2>/dev/null && die "old watcher $old_watcher is still alive"
n_watchers=$(docker exec "$PG" sh -c "ps -eo pid=,sid=,user=,args= | grep '[p]gbackrest-backup-watcher.sh' | awk '\$1==\$2' | wc -l" | tr -d ' ')
[ "$n_watchers" = 1 ] || die "expected exactly one watcher session leader, found $n_watchers: $(docker exec "$PG" sh -c "ps -eo pid=,sid=,user=,args= | grep '[p]gbackrest-backup-watcher.sh'")"
new_watcher=$(docker exec "$PG" sh -c "ps -eo pid=,sid=,args= | awk '\$1 == \$2 && /pgbackrest-backup-watcher\\.sh/ { print \$1 }'")
[ "$(docker exec "$PG" ps -o user= -p "$new_watcher" | tr -d ' ')" = postgres ] || die "new watcher is not running as postgres"
left=$(docker exec "$PG" sh -c "ps -eo user=,args= | grep -E '^root .*(xargs|hotswap|watcher-environ)' | grep -v grep" || true); [ -z "$left" ] || die "the swap left a root helper process behind: $left"
docker exec "$PG" test -e /tmp/.watcher-environ && die "the environment dump was left on disk"
[ "$(docker exec "$PG" grep -c 'archive-failure:' /usr/local/bin/pgbackrest-backup-watcher.sh)" -ge 1 ] || die "installed watcher is not the new one"
wait_log "pgbackrest-watcher: starting (" 30 $((starts_before + 1)) || die "the new watcher's start line is not on the container log stream"
wait "$sess"; grep -q session-survived "$D/session.out" || die "the open client session did not survive: $(cat "$D/session.out")"
say "swap done: container $started_before, postmaster started $pm_before (unchanged), watcher $old_watcher -> $new_watcher, open session survived"

say "== phase 3: new watcher, the same failure"
d2=$(count "running pgbackrest backup --type=diff"); g2=$(count "gap-recovery: entering recovery"); o2=$(count "archive-failure: over")
a_before=$(q "select archived_count from pg_stat_archiver")
fail_pushes_then_recover
end=$(( $(date +%s) + 600 )); hit=0; while [ "$(date +%s)" -lt "$end" ]; do q "select pg_switch_wal()" >/dev/null; [ "$(count 'archive-failure: over')" -gt "$o2" ] && { hit=1; break; }; sleep 3; done
[ "$hit" = 1 ] || die "the new watcher never reported the archive failure as over"
sleep 15
d3=$(count "running pgbackrest backup --type=diff"); g3=$(count "gap-recovery: entering recovery")
[ "$d3" = "$d2" ] || die "the new watcher took a diff ($d2 -> $d3)"
[ "$g3" = "$g2" ] || die "the new watcher entered gap recovery ($g2 -> $g3)"
docker exec "$PG" test -f "$PGDATA_DIR/.pgbackrest_gap_pending" && die "gap marker written although no WAL was dropped"
a_after=$(q "select archived_count from pg_stat_archiver"); [ "${a_after:-0}" -gt "${a_before:-0}" ] || die "archiving did not continue after the swap ($a_before -> $a_after)"
handoff=$(q "select last_archived_wal from pg_stat_archiver")
mc "mc find local/${BUCKET}/pgbackrest --name '${handoff}-*' 2>/dev/null" | grep -q "$handoff" || die "last archived WAL $handoff is not in the bucket"
[ "$(q 'select pg_postmaster_start_time()')" = "$pm_before" ] || die "postgres restarted during phase 3"
say "new watcher: diffs $d2 -> $d3, gap-recovery entries $g2 -> $g3, archived_count $a_before -> $a_after, last archived WAL $handoff is in the bucket"
say "watcher lines after the swap:"; docker logs "$PG" 2>&1 | grep -E "archive-failure:|pgbackrest-watcher: starting" | tail -4 | cut -c1-220
again=$(docker exec -u root "$PG" sh /tmp/pitr-hotswap/watcher-hotswap.sh /tmp/pitr-hotswap) || die "the second run exited $?"
case "$again" in *"already current"*) ;; *) die "the second run did not report already current: $again" ;; esac
[ "$(docker exec "$PG" sh -c "ps -eo pid=,sid=,args= | awk '\$1 == \$2 && /pgbackrest-backup-watcher\\.sh/ { print \$1 }'")" = "$new_watcher" ] || die "the second run replaced the watcher"
say "second run: $again"

watchers() { docker exec "$PG" sh -c "ps -eo pid=,sid=,user=,args= | awk '\$1 == \$2 && /pgbackrest-backup-watcher\\.sh/ { print \$1 \":\" \$3 }'" | paste -sd' ' -; }
unchanged() { [ "$(q 'select pg_postmaster_start_time()')" = "$pm_before" ] || die "postgres restarted ($1)"; [ "$(docker inspect -f '{{.State.StartedAt}} restarts={{.RestartCount}}' "$PG")" = "$started_before" ] || die "the container restarted ($1)"; }

say "== phase 4: a new watcher that exits at once is rolled back"
docker exec -u root "$PG" sh -c 'mkdir -p /tmp/pitr-bad && cp /tmp/pitr-hotswap/pgbackrest-archive-push-wrapper.sh /tmp/pitr-bad/ && printf "#!/bin/bash\nexit 1\n" > /tmp/pitr-bad/pgbackrest-backup-watcher.sh'
out=$(docker exec -u root "$PG" sh /tmp/pitr-hotswap/watcher-hotswap.sh /tmp/pitr-bad 2>&1); rc=$?
[ "$rc" = 5 ] || die "a watcher that exits at once: expected exit 5, got $rc: $out"
case "$out" in *"previous watcher runs again"*) ;; *) die "no rollback reported: $out" ;; esac
for f in pgbackrest-backup-watcher.sh pgbackrest-archive-push-wrapper.sh; do
  docker exec "$PG" cmp -s "/tmp/pitr-hotswap/$f" "/usr/local/bin/$f" || die "after the rollback $f is not the previous one"
done
w4=$(watchers); case "$w4" in *" "*|"") die "after the rollback expected one watcher, found: '$w4'" ;; *:postgres) ;; *) die "after the rollback the watcher is not postgres: $w4" ;; esac
docker exec "$PG" test -e /tmp/.watcher-environ && die "the environment dump was left on disk after the rollback"
unchanged "phase 4"
say "rollback: $out"

say "== phase 5: a swap cut short after the old watcher stopped is finished by the next run"
w5=${w4%%:*}
docker exec -u root "$PG" sh -c "umask 077; gosu postgres cat /proc/$w5/environ > /tmp/.watcher-environ; pkill -KILL -g $w5; sleep 1"
[ -z "$(watchers)" ] || die "the watcher is still running: $(watchers)"
out=$(docker exec -u root "$PG" sh /tmp/pitr-hotswap/watcher-hotswap.sh /tmp/pitr-hotswap 2>&1) || die "the resuming run exited $?: $out"
case "$out" in *"cut short; watcher started"*) ;; *) die "the run did not resume: $out" ;; esac
w6=$(watchers); case "$w6" in *" "*|"") die "after resuming expected one watcher, found: '$w6'" ;; *:postgres) ;; *) die "after resuming the watcher is not postgres: $w6" ;; esac
docker exec "$PG" test -e /tmp/.watcher-environ && die "the environment dump was left on disk after resuming"
unchanged "phase 5"
a_end0=$(q "select archived_count from pg_stat_archiver"); q "insert into t values (1); select pg_switch_wal()" >/dev/null
end=$(( $(date +%s) + 120 )); while [ "$(date +%s)" -lt "$end" ]; do [ "$(q 'select archived_count from pg_stat_archiver')" -gt "$a_end0" ] && break; sleep 2; done
[ "$(q 'select archived_count from pg_stat_archiver')" -gt "$a_end0" ] || die "archiving stopped after phases 4 and 5"
say "resume: $out"
say "PASS"
[ "${KEEP:-0}" = 1 ] || { docker rm -f "$PG" "$MINIO" >/dev/null 2>&1; docker volume rm "$VOL" "$MVOL" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
