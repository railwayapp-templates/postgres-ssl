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
dormant. When `WAL_ARCHIVE_BUCKET` is unset (and the service isn't a
PITR-restored one — see below), the image behaves identically to a
vanilla SSL Postgres image — no archiving, no extra processes, no
config changes. When set, Postgres archives WAL segments continuously
to S3-compatible storage in **async mode** with
`archive-push-queue-max=5GiB`. If S3 stalls, WAL queues in the local spool
(`$PGDATA/pgbackrest-spool`, on the data volume so it survives container
restarts) without blocking Postgres; if the queue fills, pgBackRest drops
WAL and keeps Postgres running rather than letting `pg_wal` fill the data
volume.

The image reads a tool-agnostic `WAL_ARCHIVE_*` / `WAL_RECOVER_FROM_*`
env contract and translates internally to pgBackRest's native
`PGBACKREST_REPO{1,2}_S3_*`, so swapping pgBackRest for another archiver
in the future is a wrapper change rather than a cross-repo rewrite.
Three modes:

- `WAL_ARCHIVE_*` only → standalone archiving service. `repo1` = archive bucket.
- `WAL_RECOVER_FROM_*` only → PITR-restored service, no ongoing archiving.
  `repo1` = source's bucket (read-only during recovery).
- `WAL_ARCHIVE_*` + `WAL_RECOVER_FROM_*` → restored service that has been
  re-enabled for archiving. `repo1` = source (read), `repo2` = own
  archive bucket (write).

`archive_command` points at `/usr/local/bin/pgbackrest-archive-push-wrapper.sh`
rather than calling `pgbackrest archive-push` directly. The wrapper tries the
real push; on failure it measures `pg_wal/`, and when it exceeds the
threshold (default 500 MiB, override via `PGBACKREST_DROP_THRESHOLD_MB`) it
returns success to Postgres anyway, dropping the segment. This is the
never-halt safety net for failure modes that bypass pgBackRest's own
queue-max — bad credentials, deleted bucket, expired keys,
[pgbackrest#1848](https://github.com/pgbackrest/pgbackrest/issues/1848),
[#1726](https://github.com/pgbackrest/pgbackrest/issues/1726). When the
wrapper drops a segment the PITR window gets a coverage gap from that
segment to the next post-recovery base snapshot; below the threshold the
wrapper surfaces failures normally so transient errors retry on the next
`archive_timeout`.

The two thresholds gate orthogonal failure regimes:
- `archive-push-queue-max=5GiB` (image-baked) governs the **spool**.
  Trips on transient S3 stalls — async worker keeps retrying and most
  segments eventually land. Generous buffer to absorb multi-hour outages
  cleanly.
- `PGBACKREST_DROP_THRESHOLD_MB=500` (default) governs **`pg_wal/`** when
  pgbackrest's foreground returns non-zero. Trips on hard failures (bad
  creds, deleted bucket) where retrying without operator intervention has
  zero chance of success. Smaller cap so we don't hold 5 GiB of pg_wal
  hostage waiting for a config fix.

Operator-facing env contract:

| Env var | Purpose |
|---|---|
| `WAL_ARCHIVE_BUCKET` | bucket name — gates archiving on this service |
| `WAL_ARCHIVE_ENDPOINT` | S3-compatible endpoint (e.g. `fly.storage.tigris.dev`) |
| `WAL_ARCHIVE_REGION` | bucket region |
| `WAL_ARCHIVE_KEY` / `WAL_ARCHIVE_SECRET` | bucket credentials |
| `WAL_ARCHIVE_PATH` | path prefix where archive-push writes (default `/pgbackrest`) |
| `WAL_RECOVER_FROM_BUCKET` / `_ENDPOINT` / `_REGION` / `_KEY` / `_SECRET` / `_PATH` | source-bucket coordinates on a PITR-restored service; `archive-get` reads source WAL from here during replay. Set by backboard on restore; not normally a manual knob. |
| `POSTGRES_RECOVERY_TARGET_TIME` | ISO 8601 timestamp; stages archive-recovery replay on next start |
| `POSTGRES_ARCHIVE_TIMEOUT` | seconds Postgres waits before forcing a WAL switch (default `60`) |

Image-level tuning knobs (pgBackRest-native, internal):

| Env var | Purpose |
|---|---|
| `PGBACKREST_DROP_THRESHOLD_MB` | `pg_wal/` size at which the archive-push wrapper drops failing segments to keep Postgres running (default `500`) |
| `PGBACKREST_ARCHIVE_PUSH_PROCESS_MAX` | parallel workers for `archive-push`. Default auto-sized as `clamp(cpus/8, 2, 8)`. |
| `PGBACKREST_ARCHIVE_GET_PROCESS_MAX` | parallel workers for `archive-get`. Default `1` (WAL replay is serial). |
| `PGBACKREST_BACKUP_PROCESS_MAX` | parallel workers for `backup`. Default auto-sized as `clamp(cpus/4, 1, 16)` (≤25% of CPUs to leave room for live DB). |
| `PGBACKREST_RESTORE_PROCESS_MAX` | parallel workers for `restore`. Default auto-sized as `clamp(cpus, 1, 32)` (DB is down, but pgBackRest plateaus past ~32 workers). |

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
first time the container boots with `WAL_ARCHIVE_BUCKET` set: a
background task waits for Postgres to accept connections, then writes the
stanza metadata into the bucket. The command is idempotent and runs on
every subsequent boot — already-correct repo metadata is a no-op; a
mismatch (e.g. `WAL_ARCHIVE_PATH` pointing at another cluster's repo)
errors loudly, which is the safety we want. Stanza-create only runs
against the service's own archive bucket, never against a
`WAL_RECOVER_FROM_*` source repo (which is read-only during recovery).

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
from a base snapshot first, or unset the recovery target).

##### Restored services have a separate bucket

PITR restore creates a brand-new Postgres service in the project; the
source service stays online and untouched. The restored service's
volume is populated from the source's snapshot, then booted with
`WAL_RECOVER_FROM_*` pointing at the source's bucket and
`POSTGRES_RECOVERY_TARGET_TIME` set — `archive-get` reads source WAL
during replay. After promote, the restored service has no archive
bucket of its own and runs as a plain non-archiving Postgres until the
operator opts in via the standard PITR-enable flow (which provisions a
fresh bucket on the restored service).

Source and restored services therefore never share a write path: there
is no risk of the recovered timeline overwriting the source's ongoing
WAL chain. The previous "mandatory repo-path divergence" guard and the
`.pgbackrest_source_path` sentinel are gone.

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

When `WAL_ARCHIVE_BUCKET` is removed (the gating env var), the
container on next start wipes the archive-side state so a later
re-enable starts from a clean slate:

- `$PGDATA/conf.d/pgbackrest.conf` (archive settings)
- `/etc/pgbackrest/pgbackrest.conf` (image-level operator policy — only
  removed when both `WAL_ARCHIVE_BUCKET` and `WAL_RECOVER_FROM_BUCKET`
  are unset, since recovery-only services still need it)
- `$PGDATA/pgbackrest-spool` (staged segments are useless without a
  repo to push to; any in-flight WAL was already covered by the
  archive-push wrapper's drop-on-failure path)
- `$PGDATA/conf.d/pgbackrest-recovery.conf` and the
  `$PGDATA/.pitr_staging` / `$PGDATA/.pitr_configured` markers are
  scoped to `WAL_RECOVER_FROM_BUCKET` and only cleared when *that*
  variable goes away.

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
