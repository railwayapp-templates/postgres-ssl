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
without blocking Postgres; if the queue fills, pgBackRest drops WAL and
keeps Postgres running rather than letting `pg_wal` fill the data volume.

`archive_command` points at `/usr/local/bin/pgbackrest-archive-push-wrapper.sh`
rather than calling `pgbackrest archive-push` directly. The wrapper tries the
real push; on failure it measures `pg_wal/`, and when it exceeds the
threshold (default 10 GiB, override via `PGBACKREST_DROP_THRESHOLD_GIB`) it
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
| `PGBACKREST_REPO1_PATH` | path prefix in bucket (e.g. `/pgbackrest`) |
| `POSTGRES_RECOVERY_TARGET_TIME` | ISO 8601 timestamp; stages archive-recovery replay on next start |

Stanza initialization (`pgbackrest stanza-create`) runs automatically the
first time the container boots with `PGBACKREST_REPO1_S3_BUCKET` set: a
background task waits for Postgres to accept connections, then writes the
stanza metadata into the bucket. The command is idempotent and runs on
every subsequent boot — already-correct repo metadata is a no-op; a
mismatch (e.g. `PGBACKREST_REPO1_PATH` pointing at another cluster's
repo) errors loudly, which is the safety we want.

When `POSTGRES_RECOVERY_TARGET_TIME` is set, the container writes a
`recovery.signal` file and the matching `recovery_target_time` /
`restore_command` / `recovery_target_action=promote` into
`postgresql.auto.conf`. Postgres enters archive recovery, replays WAL from
the bucket to the target timestamp, and promotes. A sentinel file
(`$PGDATA/.pitr_configured`) prevents re-triggering on later restarts —
PITR is expected to run against a fresh volume restored from a base
snapshot.

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

This image does not enforce the coupling — pgBackRest's own
`repo1-retention-*` knobs are intentionally left at defaults and not
exposed, since the bucket lifecycle is the source of truth.

### Disabling PITR

When `PGBACKREST_REPO1_S3_BUCKET` is removed (the gating env var), the
container on next start strips the previously-written pgbackrest block
from `postgresql.auto.conf` and removes `/etc/pgbackrest/pgbackrest.conf`
so `archive_mode` and `archive_command` go away cleanly. Without this
cleanup, Postgres would still try to fire the configured `archive_command`
on every WAL switch — pgbackrest would fail with no creds, and Postgres
would refuse to recycle WAL until the disk filled. The cleanup is bounded
to a single sentinel-bracketed block (`# pgbackrest-config-begin` /
`# pgbackrest-config-end`) written by either `pgbackrest-init.sh` or
`wrapper.sh`, so user-managed `postgresql.auto.conf` entries are never
touched.

### A note about ports

By default, this image is hardcoded to listen on port `5432` regardless of what
is set in the `PGPORT` environment variable. We did this to allow connections
to the postgres service over the `RAILWAY_TCP_PROXY_PORT`. If you need to
change this behavior, feel free to build your own image without passing the
`--port` parameter to the `CMD` command in the Dockerfile.
