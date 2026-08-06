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
threshold (sized to half the data volume, capped at 5 GiB, floor 128 MiB —
override via `WAL_DROP_THRESHOLD_MB`) it
returns success to Postgres anyway, dropping the segment. This is the
never-halt safety net for failure modes that bypass pgBackRest's own
queue-max — bad credentials, deleted bucket, expired keys,
[pgbackrest#1848](https://github.com/pgbackrest/pgbackrest/issues/1848),
[#1726](https://github.com/pgbackrest/pgbackrest/issues/1726). When the
wrapper drops a segment the PITR window gets a coverage gap from that
segment to the next post-recovery base snapshot; below the threshold the
wrapper surfaces failures normally so transient errors retry on the next
`archive_timeout`.

The two thresholds are deliberately sized identically (both
`min(volume/2, 5GiB)`, floor 128 MiB — see `compute_volume_thresholds`):
- `archive-push-queue-max` (image-computed) governs the **spool**. Trips
  when the async worker can't drain it — most segments eventually land
  once the outage clears.
- `WAL_DROP_THRESHOLD_MB` (image-computed) governs **`pg_wal/`** when
  pgbackrest's foreground returns non-zero. Until 2026-07-02 this was a
  fixed 500 MiB cap — 10x smaller than queue-max. A 2026-07-01 Tigris
  `sjc` outage showed why that was wrong: transient S3 errors (500s,
  timeouts, connection resets) are exactly the failure queue-max's 5 GiB
  buffer is sized to absorb, but the smaller pg_wal check tripped first
  and silently dropped WAL well short of that budget (#104). Only two
  explicit no-recovery-possible errors (`NoSuchBucket`,
  `InvalidAccessKeyId`) still bypass the threshold and drop immediately —
  every other failure, hard or transient, gets the full computed budget
  before we give up on it.

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
| `WAL_DROP_THRESHOLD_MB` | `pg_wal/` size at which the archive-push wrapper drops failing segments to keep Postgres running (default computed as half the data volume, capped at 5 GiB, floor 128 MiB — same formula as `PGBACKREST_ARCHIVE_PUSH_QUEUE_MAX`; falls back to a flat 5 GiB if volume size can't be detected). Outside the `PGBACKREST_*` namespace on purpose — pgBackRest treats unknown `PGBACKREST_*` vars as config options and warns about them on every push. |
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
`$PGDATA/.pitr_configured` before the next start — and, if the service
was ever major-upgraded, the volume-root `.railway-major-upgrade.json`
too, since a completed upgrade marker is also read as "recovery done").

When `POSTGRES_RECOVERY_TARGET_TIME` is set on a brand-new container
(no `$PGDATA/PG_VERSION`), the wrapper runs `pgbackrest --repo=2 restore
--type=time --target=<T> --target-action=promote` against the source
bucket *before* `docker-entrypoint` initializes anything. pgBackRest
pulls the most recent base backup ≤ T plus the WAL chain forward into
`$PGDATA`, writes `recovery.signal` + recovery params, and Postgres
boots straight into archive recovery. A `.pgbackrest_restored` marker is
written on success; `configure_pgbackrest_recovery` defers to the
restore's own settings on subsequent starts of the same volume.

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

Alongside it, `$PGDATA/.pgbackrest_repo_anchor` records the
`system_identifier` and `PG_VERSION` the path was derived from. The
marker wins verbatim on every boot, so this fingerprint is the only
thing that can tell "same cluster, same path" apart from "a different
cluster inherited this path" — see the archive re-anchoring paragraph
under [Major version upgrades](#major-version-upgrades). A volume
predating the file adopts its live identity on first boot and keeps
the path it already archives to.

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

**Queue-max-trip detection**: pgBackRest's `archive-push-queue-max` trip
drops segments without going through the archive-push wrapper *and*
without incrementing `failed_count`, so neither of those two gap signals
fires on its own. The backup watcher closes this independently: every
poll (`WAL_BACKUP_POLL_INTERVAL_SECONDS`, default 60s) it compares
`pg_stat_archiver.last_archived_wal` against the repo's archived
high-water mark (`pgbackrest info --output=json`); once the lag reaches
`WAL_LAG_GAP_THRESHOLD_SEGMENTS` (default 32 ≈ 512 MiB) it enters the
gap-recovery state machine the same way the other two signals do, so a
fresh full fires once grace elapses instead of waiting for the next
periodic full (#85, hardened by #86).

`pgbackrest backup` is invoked with `--type=full` or `--type=diff`
depending on the trigger; the `process-max=backup` setting (default
`clamp(cpus/4, 1, 16)`) caps copy concurrency to leave CPU for live DB
traffic. Backups run with `--no-expire-auto`; `pgbackrest expire` is then
called as its own step right after a *successful* backup, and removes
fulls/diffs beyond `WAL_BACKUP_RETENTION_FULL` / `_DIFF`, plus the WAL
their manifests no longer pin. Splitting the two matters because
pgBackRest's default (`expire-auto=y`) folds expire into the same
command, so a transient expire failure (e.g. a slow S3-compatible
endpoint on the post-backup listing) would otherwise fail the whole
`backup` invocation even though the backup itself landed and is durable
— leaving the watcher's `last_full_at` unset and re-triggering a brand
new full upload every retry cycle instead of just deferring retention to
the next backup.

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

## Major version upgrades

`Dockerfile.upgrade` builds a one-shot job image carrying two majors' server
binaries, driven by `upgrade-job.sh`. CI publishes one image per supported
(source → newer target) pair as
`ghcr.io/railwayapp-templates/postgres-ssl/upgrade:<from>-<to>`, which is what
the dashboard's upgrade workflow dispatches. Locally:

```bash
docker build -f Dockerfile.upgrade \
  --build-arg FROM_VERSION=16 --build-arg TO_VERSION=17 \
  -t postgres-upgrade:16-17 .
```

It runs against the database's own volume while the service is stopped, and
takes a mode as its argument:

| Mode | Effect |
|------|--------|
| `check` | `pg_upgrade --check` against a throwaway target cluster. Exit 1 = blockers, exit 2 = precondition refusal, exit 3 = environment failure (the quiesce could not start or stop the old server — its log is printed). Also proves the real upgrade's sibling directory slot is creatable on the volume, so a green check can't hide a volume-root permission problem the real run would hit. **Not strictly read-only**: a cluster that wasn't shut down cleanly (the platform stops containers with SIGKILL, so that's the normal case) is first quiesced — WAL replayed with the old binaries, then a clean shutdown — exactly what the next boot would have done. Only a cleanly-shut-down volume is checked without writes. |
| `upgrade` | `--check`, then `pg_upgrade --link`, then the completion marker and directory swap. |
| `status` | Prints the marker phase + on-disk major as JSON, for resume decisions. |
| `manifest` | Prints the target major's installable extensions as JSON. |

The job connects as the cluster's actual install user
(`${POSTGRES_USER:-postgres}`), and initdb's the target cluster with the same
name — a service deployed with a custom `POSTGRES_USER` has no `postgres`
role at all, and pg_upgrade requires both clusters' install users to match.
Every `RAILWAY_UPGRADE_RESULT:` payload is built with `jq --arg` (compact,
one line) so no on-disk byte a database superuser can write reaches the
workflow's JSON parser unescaped.

Volumes with `recovery.signal` or `standby.signal` are refused outright by
both `check` and `upgrade` (exit 2): those shapes can't be upgraded in
place, and the quiesce would consume a mid-restore volume's recovery intent.
Finish or promote recovery first.

`.railway-major-upgrade.json` at the volume root is the commit point
(fsynced through the parent directory, and every write checked before any
directory is mutated): `upgraded` means pg_upgrade succeeded and recovery
must roll **forward**; `completed` means the swap is done. Both phases are
scoped to the marker's own version pair — a `completed` marker from a
previous upgrade of the same volume is history, not state, so chained
upgrades (16→17, later 17→18) work; an in-flight marker of a foreign pair
is refused. If the marker is lost in the one window where roll-back is
impossible (post-pg_upgrade, the old cluster's `pg_control` is renamed
away), the job re-infers the roll-forward from the disk shape itself.
`wrapper.sh` refuses to boot while a non-completed marker exists, and
refuses any image whose major differs from the on-disk `PG_VERSION` — so no
mismatched boot can touch the data.

Both sides also hold a `flock` on the volume-root
`.railway-major-upgrade.lock`: the job exclusively for its run, the runtime
container shared for its lifetime. A job dispatched against a live database
refuses instead of corrupting the cluster, and a database deployed while a
job is mid-flight refuses to boot — in-image backstops for the
orchestrator's own exclusion. Honest scope note: the shared side only exists
on runtime images built from this change, so a service still running an
older image is protected during its first upgrade by the orchestrator's
stop-before-dispatch and the platform's single-mount guarantee alone — the
lock becomes a real backstop for that service only after it redeploys onto a
current image.

The job tolerates the platform's ungraceful container stop: it clears a stale
`postmaster.pid` and, when `pg_control` says the cluster was not shut down
cleanly, replays WAL with the old binaries and shuts down cleanly before
upgrading (pg_upgrade requires it).

Because `pg_upgrade` promotes a freshly `initdb`'d data directory, settings that
live in `postgresql.conf` do not carry over. The certificates survive at the
volume root, so `wrapper.sh` re-applies the `ssl` settings whenever the config
has none while certs exist — without that, an upgraded database comes back with
SSL off and rejects every `sslmode=require` client. `pg_hba.conf` gets the
same two-layer treatment: the job carries the old cluster's `pg_hba.conf`
(and `pg_ident.conf`) into the new data directory — it's the user's actual
config, custom rules included — and `wrapper.sh` re-appends the
`host all all all <method>` rule when (and only when) the file has been
reset to initdb's recognizable default shape — loopback host rules and
nothing else. A config the operator narrowed by address, database/user, or
TLS is an authored policy and is never silently re-widened; a file with no
host rules at all is a deliberate local-only lockdown and is left alone
too. The PITR lifecycle sentinels (`.pitr_configured`,
`.pitr_staging`, `.pgbackrest_restored`) are carried across the swap too,
and a `completed` upgrade marker is itself treated as proof that recovery
already promoted — otherwise an upgraded PITR-restored fork (whose
`WAL_RECOVER_FROM_*` env stays set forever) would re-stage archive recovery
against the source bucket and never become ready.

`postgresql.conf` and `postgresql.auto.conf` (`ALTER SYSTEM` settings) are
deliberately **not** carried: either file can hold a GUC the target major
removed, and one unrecognized parameter there refuses the whole boot. The
user's tuning must not silently evaporate either, so the job stashes both
files at the volume root as `.pre-upgrade-<from>-postgresql.conf` /
`.pre-upgrade-<from>-postgresql.auto.conf` (they outlive the old data dir's
24 h reclaim) and records `needsConfigReview: true` in the completed marker —
surfacing "re-apply your `ALTER SYSTEM` settings" is the dashboard's job,
because the alternative is the user discovering it via a post-upgrade
`max_connections` regression.

#### Disk reclaim and rollback window

The pre-upgrade cluster is kept at `${PGDATA}.old-<from>` as the rollback
body. Because `pg_upgrade --link` hardlinks data files, that directory pins
every pre-upgrade inode — space freed in the upgraded database is not
returned to the volume while it exists. Once the upgrade is confirmed (the
upgraded database up and answering past a grace period, default 24 h from
the marker's `completedAt`; `UPGRADE_OLD_DIR_RETENTION_SECONDS` overrides),
`wrapper.sh` removes it in the background and stamps `oldDataDirRemovedAt`
in the marker. Until then it is the instant-rollback path; after that,
rollback means restoring the pre-upgrade backup.

#### Collation caveat (known follow-up)

`pg_upgrade` preserves index files verbatim, but indexes on collatable
columns (text/varchar btrees) are only valid for the glibc that built them,
and the target image's glibc may differ from whatever built the source
cluster. The marker records `needsReindex: true` on every upgrade — the
image deliberately does **not** auto-`REINDEX` (rebuilding every text index
on an arbitrarily large database inside the upgrade window is the wrong
default). Surfacing that flag and driving the reindex is the dashboard's
follow-up; `wrapper.sh`'s collation-version refresh only silences the
version-mismatch warnings, it does not rebuild indexes.

### Archive re-anchoring

`pg_upgrade` initdb's the target, so an upgraded service comes back with a new
`system_identifier` and a new `PG_VERSION` — a different cluster as far as
pgBackRest is concerned. Archiving has to follow it to
`${WAL_ARCHIVE_PATH}/cluster-<new_sysid>`: the previous prefix records the old
system id in its `archive.info`, so every `archive-push` against it fails and
`stanza-create` refuses the mismatch outright.

On every boot `wrapper.sh` compares `.pgbackrest_repo_anchor` against the
cluster on disk. On a mismatch in either component, and only when
`WAL_ARCHIVE_BUCKET` is set, it moves archiving before Postgres starts: flip the
repo-path marker to the new cluster's prefix, drop the old path's async spool
statuses (a stale `.ok` would make pgBackRest skip an upload the new path never
received), reset the backup-watcher state so a full lands immediately at the new
prefix, and `stanza-create` there. No epoch suffix is needed — a fresh system
identifier makes the path collision-free and deterministic, so an interrupted
attempt recomputes the same target. The previous cluster's archive is untouched
and stays restorable as its own history in the bucket.

Detection is the fingerprint, never the upgrade marker: the marker is
removed from consideration eventually, and detection must not depend on it.
To be precise about scope: a **PITR restore cannot trip this check** —
`pgbackrest restore` copies the source's data files, so the
`system_identifier` is preserved and the restored `$PGDATA` carries the
source's repo-path marker *and* its matching anchor. (Restored forks get
their own bucket via `WAL_ARCHIVE_*`, which is what keeps them off the
source's prefix; the anchor plays no part.) The upgrade job's directory
swap likewise promotes a freshly initdb'd data directory, so today's
in-place route derives the path fresh rather than exercising the re-anchor.
The re-anchor is therefore **defense in depth for routes that don't exist
yet**: any upgrade path that carries `$PGDATA`'s pgbackrest files forward
across a re-identification (a dump/restore fallback for the legacy
PGDATA-at-the-volume-root layout, a future restore flavor that rewrites
identity). Nothing here can fail the boot — an incomplete re-anchor is
logged loudly and retried by the backup watcher, because a database that is
up with degraded archiving beats one that refuses to start.

A product consequence of per-cluster paths, accepted deliberately: **the
PITR window restarts at a major upgrade.** Archiving moves to the new
cluster's prefix and an immediate full backup re-anchors the window there;
the old prefix stays in the bucket as a browsable, restorable history of
the pre-upgrade cluster, but nothing expires it — its retention was driven
by `pgbackrest expire` runs that now happen on the new prefix only. Adding
expiry/cleanup for orphaned `cluster-*` prefixes (after a safety window) is
an open follow-up, tracked for the dashboard/backboard side; the image does
not delete archive data.

Tests: `./test/e2e-upgrade.sh` (add `FROM_VERSION=14 TO_VERSION=17` to cover a
pre-16 source, where pg_upgrade's `reg*`/`aclitem` checks fire). CI runs the
harness on 16→17 and 17→18 — the latter pins the initdb data-checksums
default flip in 18, which needs explicit parity flags. The re-anchor
tests need a bucket, so they live in the archive harness instead:
`./test/e2e.sh t_upgrade_archive_reanchors_to_new_cluster_path
t_reanchor_stale_marker_after_upgrade t_reanchor_backfills_missing_anchor`.
