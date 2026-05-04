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

Invariant: `repo1` is always "this service's own destination bucket" —
the only place this service writes WAL. `repo2`, when present, is a
read-only recovery source. No two services ever share a destination
bucket. Two modes:

- `WAL_ARCHIVE_*` only → standalone archiving service. `repo1` = own bucket.
- `WAL_ARCHIVE_*` + `WAL_RECOVER_FROM_*` → PITR-restored fork. `repo1` =
  fork's own fresh bucket (writes from boot), `repo2` = source's bucket
  (read-only during recovery; ignored after promote, the fork's new
  timeline doesn't exist there). The fork archives to its own bucket
  from day one — no separate "re-enable PITR after restore" step.

`archive_command` points at `/usr/local/bin/pgbackrest-archive-push-wrapper.sh`
rather than calling `pgbackrest archive-push` directly. The wrapper tries the
real push; on failure it measures `pg_wal/`, and when it exceeds the
threshold (default 500 MiB, override via `WAL_DROP_THRESHOLD_MB`) it
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
- `WAL_DROP_THRESHOLD_MB=500` (default) governs **`pg_wal/`** when
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
| `WAL_RECOVER_FROM_BUCKET` / `_ENDPOINT` / `_REGION` / `_KEY` / `_SECRET` / `_PATH` | source-bucket coordinates on a PITR-restored fork; mounted as `repo2` (read-only) so `archive-get` and the empty-volume `pgbackrest restore` can pull source WAL during replay. Set by backboard on restore; not normally a manual knob. |
| `POSTGRES_RECOVERY_TARGET_TIME` | ISO 8601 timestamp; stages archive-recovery replay on next start |
| `POSTGRES_ARCHIVE_TIMEOUT` | seconds Postgres waits before forcing a WAL switch (default `60`) |
| `WAL_BACKUP_FULL_INTERVAL_HOURS` | image-owned full base-backup cadence (default `168` = weekly; `0` disables periodic fulls). Initial / gap-recovery fulls fire regardless. |
| `WAL_BACKUP_DIFF_INTERVAL_HOURS` | image-owned differential base-backup cadence (default `24`; `0` disables) |
| `WAL_BACKUP_RETENTION_FULL` | full backups kept by `pgbackrest expire` (default `4`) |
| `WAL_BACKUP_RETENTION_DIFF` | differentials kept by `pgbackrest expire` (default `14`) |

Image-level tuning knobs (pgBackRest-native, internal):

| Env var | Purpose |
|---|---|
| `WAL_DROP_THRESHOLD_MB` | `pg_wal/` size at which the archive-push wrapper drops failing segments to keep Postgres running (default `500`). Outside the `PGBACKREST_*` namespace on purpose — pgBackRest treats unknown `PGBACKREST_*` vars as config options and warns about them on every push. |
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

Stanza initialization (`pgbackrest stanza-create --repo=1`) runs
automatically the first time the container boots with `WAL_ARCHIVE_BUCKET`
set: a background task waits for Postgres to accept connections, then
writes the stanza metadata into the bucket. The command is idempotent
and runs on every subsequent boot — already-correct repo metadata is a
no-op; a mismatch (e.g. `WAL_ARCHIVE_PATH` pointing at another cluster's
repo) errors loudly, which is the safety we want. The `--repo=1` scope
keeps stanza-create off `repo2` on a fork, where source already owns the
stanza and we have read-only intent.

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

When `POSTGRES_RECOVERY_TARGET_TIME` is set on a brand-new container
(no `$PGDATA/PG_VERSION`), the wrapper runs `pgbackrest --repo=1 restore
--type=time --target=<T> --target-action=promote` against the source
bucket *before* `docker-entrypoint` initializes anything. pgBackRest
pulls the most recent base backup ≤ T plus the WAL chain forward into
`$PGDATA`, writes `recovery.signal` + recovery params, and Postgres
boots straight into archive recovery. A `.pgbackrest_restored` marker is
written on success; `configure_pgbackrest_recovery` defers to the
restore's own settings on subsequent starts of the same volume.

If `$PGDATA` is already populated (the legacy snapshot-based restore
flow), the conf.d-include path is used as before — `recovery_target_time`
+ `restore_command` are written to `$PGDATA/conf.d/pgbackrest-recovery.conf`,
`recovery.signal` is touched, and Postgres replays WAL from the source
bucket via `archive-get`. The two paths share the same env contract
(`WAL_RECOVER_FROM_*` + `POSTGRES_RECOVERY_TARGET_TIME`) and only differ
on the initial-volume question.

#### Image-owned base backups

When `WAL_ARCHIVE_BUCKET` is set, the wrapper forks a background watcher
(`pgbackrest-backup-watcher.sh`) that polls Postgres every 60 s and
runs `pgbackrest backup` against the archive bucket when one of three
conditions holds:

1. **Initial backup** — `pg_stat_archiver.archived_count > 0` and no
   full has been recorded on this volume. Triggers the first
   `--type=full`, anchoring the PITR window from the first archived LSN
   forward.
2. **Gap recovery** — either the archive-push wrapper dropped a segment
   (touches `$PGDATA/.pgbackrest_gap_pending`) or
   `pg_stat_archiver.failed_count` grew since the last full. Once
   archive failures have been quiescent for 5 minutes, runs a fresh full
   so the PITR window resumes from the new base. The dropped segment
   itself remains unrestorable; everything from the new base forward is.
3. **Periodic** — `WAL_BACKUP_FULL_INTERVAL_HOURS` (default 168 h /
   weekly) for fulls, `WAL_BACKUP_DIFF_INTERVAL_HOURS` (default 24 h)
   for differentials. Set either to `0` to disable that schedule.

State persists at `$PGDATA/.pgbackrest_backup_state` (key=value lines:
`last_full_at`, `last_diff_at`, `last_full_failed_count`). The
bucket-side `pgbackrest --stanza=main info --output=json` is the
canonical source of truth for what actually exists in the repo; the
local file is a cache that survives restarts. A wiped volume re-derives
from a single redundant initial full — pgBackRest's stanza locks
prevent concurrent backups across cluster nodes.

#### Per-cluster archive paths

Each cluster archives under a sub-prefix derived from its
`system_identifier`:
`${WAL_ARCHIVE_PATH}/cluster-<system_identifier>`. The path is
persisted in `$PGDATA/.pgbackrest_repo_path` so the archive-push
wrapper, the backup watcher, and `pgbackrest stanza-create` all
converge on the same value.

Why per-cluster: a wipe-and-reuse-bucket cycle (operator drops the
data volume, redeploys the service against the same `WAL_ARCHIVE_BUCKET`)
produces a brand-new `system_identifier` from `initdb`. Without
discrimination, pgBackRest's stanza-create would refuse the new
cluster on system-id mismatch and the new cluster's WAL would never
land — silent data loss for any operator who didn't notice. With
per-cluster paths, the new cluster lands at
`cluster-<new_sysid>`, the previous cluster's archive stays put at
`cluster-<old_sysid>`, and both histories coexist. The bucket
becomes a multi-history store: list its `cluster-*` sub-prefixes to
enumerate every cluster that ever archived to it; pick a subprefix
to restore from.

Backward compat: if the legacy path (`${WAL_ARCHIVE_PATH}` directly,
without a `cluster-*` sub-prefix) already holds an `archive.info`
matching our `system_identifier`, the marker is written with the
legacy path and we keep using it. Existing PITR-enabled services
from before per-cluster pathing aren't asked to migrate.

`WAL_RECOVER_FROM_PATH` on a restored service must point at the
specific source-side `cluster-<sysid>` sub-prefix the user wants to
restore from — `pgbackrest restore` reads from one path. Backboard
discovers per-cluster sub-prefixes by listing the bucket and
surfaces them as separate "histories" in the restore UI.

In HA, every Postgres node runs the watcher and standbys exit early on
`SELECT pg_is_in_recovery()` — only the leader performs backups. v1 of
the watcher backs up from the primary; `--backup-standby` is a
follow-up. After a Patroni failover, the new leader's watcher takes
over; if its local state is stale, an extra full may run, which is
harmless.

**Known gap**: pgBackRest's `archive-push-queue-max` trip drops segments
without going through the archive-push wrapper *and* without
incrementing `failed_count`, so neither gap signal fires. Until log
parsing or LSN-lag detection lands, queue-max-trip gaps are sealed by
the next periodic full rather than promptly.

`pgbackrest backup` is invoked with `--type=full` or `--type=diff`
depending on the trigger; the `process-max=backup` setting (default
`clamp(cpus/4, 1, 16)`) caps copy concurrency to leave CPU for live DB
traffic. `pgbackrest expire` runs automatically after each backup and
removes fulls/diffs beyond `WAL_BACKUP_RETENTION_FULL` /
`_DIFF`, plus the WAL their manifests no longer pin.

#### Retention

For PITR-enabled services, **`pgbackrest expire` is the sole WAL
retention authority** — no bucket-side lifecycle policy. Backup
manifests pin the WAL needed to make each backup restorable; expire
releases both together when a backup ages out. Earlier iterations
proposed a bucket-side TTL as a safety net but it's superfluous: any
TTL shorter than expire's horizon would yank WAL out from under live
manifests, and any TTL ≥ that horizon is redundant.

The default retention (full=4, diff=14, weekly fulls + daily diffs)
covers approximately a four-week PITR window before the oldest full
ages out. Tune via `WAL_BACKUP_RETENTION_FULL`,
`WAL_BACKUP_RETENTION_DIFF`, `WAL_BACKUP_FULL_INTERVAL_HOURS`,
`WAL_BACKUP_DIFF_INTERVAL_HOURS`.

### Disabling PITR

When `WAL_ARCHIVE_BUCKET` is removed (the gating env var), the
container on next start wipes the archive-side state so a later
re-enable starts from a clean slate:

- `$PGDATA/conf.d/pgbackrest.conf` (archive settings)
- `$PGDATA/.pgbackrest_backup_state` and `$PGDATA/.pgbackrest_gap_pending`
  (backup-watcher state — bucket-scoped, so re-enable starts from
  `NEEDS_INITIAL_BACKUP` rather than a stale cache)
- `/etc/pgbackrest/pgbackrest.conf` (image-level operator policy — only
  removed when both `WAL_ARCHIVE_BUCKET` and `WAL_RECOVER_FROM_BUCKET`
  are unset, since recovery-only services still need it)
- `$PGDATA/pgbackrest-spool` (staged segments are useless without a
  repo to push to; any in-flight WAL was already covered by the
  archive-push wrapper's drop-on-failure path)
- `$PGDATA/conf.d/pgbackrest-recovery.conf` and the
  `$PGDATA/.pitr_staging` / `$PGDATA/.pitr_configured` /
  `$PGDATA/.pgbackrest_restored` markers are scoped to
  `WAL_RECOVER_FROM_BUCKET` and only cleared when *that* variable goes
  away.

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
