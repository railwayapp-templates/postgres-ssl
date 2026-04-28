# SSL-enabled Postgres DB image

This repository contains the logic to build SSL-enabled Postgres images.

By default, when you deploy Postgres from the official Postgres template on
Railway, the image that is used is built from this repository!

[![Deploy on
Railway](https://railway.app/button.svg)](https://railway.app/template/postgres)

### Why though?

The official Postgres image in Docker hub does not come with SSL baked in.

Since this could pose a problem for applications or services attempting to
connect to Postgres services, we decided to roll our own Postgres image with SSL
enabled right out of the box.

### How does it work?

The Dockerfiles contained in this repository start with the official Postgres
image as base. Then the `init-ssl.sh` script is copied into the
`docker-entrypoint-initdb.d/` directory to be executed upon initialization.

### Certificate expiry

By default, the cert expiry is set to 820 days. You can control this by
configuring the `SSL_CERT_DAYS` environment variable as needed.

### Certificate renewal

When a redeploy or restart is done the certificates expiry is checked, if it has
expired or will expire in 30 days a new certificate is automatically generated.

### Available image tags

Images are automatically built weekly and tagged with multiple version levels
for flexibility:

- **Major version tags** (e.g., `:17`, `:16`, `:15`): Always points to the
  latest minor version for that major release
- **Minor version tags** (e.g., `:17.6`, `:16.10`): Pins to specific minor
  version for stability
- **Latest tag** (`:latest`): Currently points to PostgreSQL 16

Example usage:

```bash
# Auto-update to latest minor versions (recommended for development)
docker run ghcr.io/railwayapp-templates/postgres-ssl:17

# Pin to specific minor version (recommended for production)
docker run ghcr.io/railwayapp-templates/postgres-ssl:17.6
```

### Point-in-time recovery (opt-in)

The image ships with [pgBackRest](https://pgbackrest.org/) installed but
dormant. When `PGBACKREST_REPO1_S3_BUCKET` is unset, the image behaves
identically to a vanilla SSL Postgres image — no archiving, no extra
processes, no config changes. When set, Postgres archives WAL segments
continuously to S3-compatible storage in **async mode** with
`archive-push-queue-max=5GiB`. If S3 stalls, WAL queues in the local spool
(`$PGDATA/pgbackrest-spool`, on the data volume so it survives container
restarts) without blocking Postgres; if the queue fills, pgBackRest drops
WAL and keeps Postgres running rather than letting `pg_wal` fill the data
volume.

`archive_command` points at `/usr/local/bin/pgbackrest-archive-push-wrapper.sh`
rather than calling `pgbackrest archive-push` directly. The wrapper tries the
real push; on failure it measures `pg_wal/`, and when it exceeds the
threshold (default 5 GiB, matching pgBackRest's `archive-push-queue-max`;
override via `PGBACKREST_DROP_THRESHOLD_GIB`) it
returns success to Postgres anyway, dropping the segment. This is the
never-halt safety net for failure modes that bypass pgBackRest's own
queue-max — bad credentials, deleted bucket, expired keys,
[pgbackrest#1848](https://github.com/pgbackrest/pgbackrest/issues/1848),
[#1726](https://github.com/pgbackrest/pgbackrest/issues/1726). When the
wrapper drops a segment the PITR window gets a coverage gap from that
segment to the next post-recovery base snapshot; below the threshold the
wrapper surfaces failures normally so transient errors retry on the next
`archive_timeout`.

| Env var | Purpose |
|---|---|
| `PGBACKREST_REPO1_S3_BUCKET` | bucket name — gates archiving |
| `PGBACKREST_REPO1_S3_ENDPOINT` | S3-compatible endpoint (e.g. `fly.storage.tigris.dev`) |
| `PGBACKREST_REPO1_S3_REGION` | bucket region |
| `PGBACKREST_REPO1_S3_KEY` / `PGBACKREST_REPO1_S3_KEY_SECRET` | bucket credentials |
| `PGBACKREST_REPO1_PATH` | path prefix where archive-push writes (e.g. `/pgbackrest`) |
| `PGBACKREST_RECOVERY_REPO1_PATH` | path prefix archive-get reads from during PITR replay; baked into `restore_command`. Set to the source's `PGBACKREST_REPO1_PATH` so the recovered cluster can read source WAL while writing to a new prefix |
| `PGBACKREST_ARCHIVE_PUSH_PROCESS_MAX` | parallel workers for `archive-push`. Default auto-sized as `clamp(cpus/8, 2, 8)`. |
| `PGBACKREST_ARCHIVE_GET_PROCESS_MAX` | parallel workers for `archive-get`. Default `1` (WAL replay is serial). |
| `PGBACKREST_BACKUP_PROCESS_MAX` | parallel workers for `backup`. Default auto-sized as `clamp(cpus/4, 1, 16)` (≤25% of CPUs to leave room for live DB). |
| `PGBACKREST_RESTORE_PROCESS_MAX` | parallel workers for `restore`. Default auto-sized as `clamp(cpus, 1, 32)` (DB is down, but pgBackRest plateaus past ~32 workers). |
| `POSTGRES_ARCHIVE_TIMEOUT` | seconds Postgres waits before forcing a WAL switch (default `60`) |
| `POSTGRES_RECOVERY_TARGET_TIME` | ISO 8601 timestamp; stages archive-recovery replay on next start |

Per-command worker counts (`process-max`) are auto-sized at container
start from the cgroup-reported vCPU allocation (`cpu.max` on cgroup v2,
`cpu.cfs_quota_us` on v1, `nproc` as a fallback). The four commands have
different bottleneck shapes — `archive-push` is gated by serial WAL
arrival and S3 PUT overhead, `archive-get` by serial replay inside
Postgres, `backup` by the need to leave CPU for live DB traffic,
`restore` by nothing (DB is down) — so each gets its own derived
default. The `PGBACKREST_*_PROCESS_MAX` env vars (table above) are
escape hatches for workloads that disprove the heuristic. On vertical
autoscale, the new values take effect on the next container restart.

Stanza initialization (`pgbackrest stanza-create`) runs automatically the
first time the container boots with `PGBACKREST_REPO1_S3_BUCKET` set: a
background task waits for Postgres to accept connections, then writes the
stanza metadata into the bucket. The command is idempotent and runs on
every subsequent boot — already-correct repo metadata is a no-op; a
mismatch (e.g. `PGBACKREST_REPO1_PATH` pointing at another cluster's
repo) errors loudly, which is the safety we want.

All Postgres-side config the image manages (archive settings, recovery
settings) is written to `$PGDATA/conf.d/*.conf`, with a one-time
`include_dir = 'conf.d'` directive added to `postgresql.conf`. The image
does not touch `postgresql.auto.conf` — Postgres rewrites that file on
every `ALTER SYSTEM` call and strips comments, which would break any
sentinel-based cleanup. With the include-directory approach, file
existence *is* the sentinel: enable = write, disable = remove.

When `POSTGRES_RECOVERY_TARGET_TIME` is set, the container writes
`recovery_target_time`, `restore_command`, and
`recovery_target_action='promote'` into
`$PGDATA/conf.d/pgbackrest-recovery.conf` and creates `recovery.signal`.
Postgres enters archive recovery, replays WAL from the bucket to the
target timestamp, and promotes. The "PITR done" sentinel
(`$PGDATA/.pitr_configured`) is written on the boot **after** Postgres
removes `recovery.signal` (which it only does on successful promote), at
which point the recovery conf file is also removed. A failed replay
leaves the volume re-stageable — fix env vars and restart, no manual
file cleanup needed. Once the sentinel is written, later restarts skip
recovery entirely **even if `POSTGRES_RECOVERY_TARGET_TIME` is changed
to a different value** — the cluster has already promoted to a new
timeline and replaying again would corrupt it. To probe a different
target, restore from a fresh volume snapshot (or, advanced: remove
`$PGDATA/.pitr_configured` before the next start).

PITR runs only against an existing data directory. If
`POSTGRES_RECOVERY_TARGET_TIME` is set on a brand-new container with no
`$PGDATA`, the wrapper refuses to start and points at the fix (restore
from a base snapshot first, or unset the recovery target). Without this
check, initdb would silently produce a fresh database and the next
restart would deadlock on the divergence check.

##### Repo-path divergence (mandatory on PITR restore)

A restored volume carries the source's `$PGDATA` contents, including a
`.pgbackrest_source_path` sentinel that records the bucket prefix the
source has been pushing WAL to. On a PITR restore, the operator MUST set
two distinct repo paths:

- `PGBACKREST_REPO1_PATH` → a **new** prefix where the recovered
  cluster's post-promote `archive_command` will land. If left equal to
  the source's path, the recovered timeline overwrites the source's
  ongoing WAL chain and corrupts both.
- `PGBACKREST_RECOVERY_REPO1_PATH` → the **source's** path, so
  `archive-get` during replay can read source WAL. This is baked into
  `restore_command` via `--repo1-path=...`.

The container refuses to stage recovery (exits non-zero before Postgres
starts) when `PGBACKREST_REPO1_PATH` matches the stamped source path —
catching the case where the operator set the recovery-read path
correctly but forgot to pivot the post-promote write path.

#### Retention coupling

This image ships WAL archiving only — there is no `pgbackrest backup`
running in-container. The "base" for any restore is a block-level
snapshot of the data volume (e.g. a Railway volume snapshot); pgBackRest
supplies the WAL needed to replay forward from that snapshot's
checkpoint LSN to the target time.

Because of that, **bucket WAL retention must be ≥ snapshot retention**.
If snapshots live 30 days but the bucket TTL is 14 days, a 16-day-old
snapshot is unrecoverable: there is no archived WAL to bridge from its
checkpoint LSN to anywhere useful. Pick a bucket TTL (or lifecycle rule)
that covers your oldest restorable snapshot plus the longest replay
window you care about.

This image does not enforce the coupling. The bucket lifecycle is the
sole source of truth for WAL retention — the image never runs
`pgbackrest backup`/`expire`, so no `repo1-retention-*` settings are
written to `/etc/pgbackrest/pgbackrest.conf`.

### Disabling PITR

When `PGBACKREST_REPO1_S3_BUCKET` is removed (the gating env var), the
container on next start wipes all pgBackRest state from the volume so a
later re-enable starts from a clean slate:

- `$PGDATA/conf.d/pgbackrest.conf` (archive settings)
- `$PGDATA/conf.d/pgbackrest-recovery.conf` (recovery settings, if present)
- `/etc/pgbackrest/pgbackrest.conf` (image-level operator policy)
- `$PGDATA/.pgbackrest_source_path` (source-path sentinel used by
  the divergence check on PITR restore)
- `$PGDATA/.pitr_staging`, `$PGDATA/.pitr_configured` (PITR markers —
  removing them lets a fresh re-enable run PITR again later without
  manual cleanup)
- `$PGDATA/pgbackrest-spool` (staged segments are useless without a
  repo to push to; any in-flight WAL was already covered by the
  archive-push wrapper's drop-on-failure path)

With the conf-file-as-sentinel model, removal IS the disable —
`archive_mode`, `archive_command`, and any recovery settings vanish on
next start. The `include_dir = 'conf.d'` line in `postgresql.conf` is
left in place; it's a no-op when the directory has no pgbackrest files,
and any user-added include files in `conf.d/` continue to work.

### A note about ports

By default, this image is hardcoded to listen on port `5432` regardless of what
is set in the `PGPORT` environment variable. We did this to allow connections
to the postgres service over the `RAILWAY_TCP_PROXY_PORT`. If you need to
change this behavior, feel free to build your own image without passing the
`--port` parameter to the `CMD` command in the Dockerfile.
