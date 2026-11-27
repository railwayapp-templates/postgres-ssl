#!/usr/bin/env python3
"""Real backup/WAL ciphertext and PITR proof, with disposable local Postgres.

Default storage is disposable MinIO. --s3-credentials accepts a JSON file with
endpoint, bucketName, region, accessKeyId, secretAccessKey, urlStyle (Railway
bucket credentials format). Only a unique test prefix is written; no existing
objects are deleted. Credentials and cipher keys never appear in command args.
"""

import argparse
import json
from pathlib import Path
import re
import secrets
import subprocess
import tempfile
import time
import uuid


class Qualification:
    def __init__(self, args, directory):
        self.args = args
        self.directory = Path(directory)
        self.identifier = "pgssl-crypt-" + uuid.uuid4().hex[:10]
        self.network = self.identifier
        self.prefix = "/" + self.identifier
        self.containers = []
        self.volumes = []
        self.secret_values = []
        self.archive_key = secrets.token_hex(32)
        self.fork_key = secrets.token_hex(32)
        self.secret_values.extend([self.archive_key, self.fork_key])

    def command(self, *args, timeout=90, check=True, binary=False):
        result = subprocess.run(
            ["docker", *args], capture_output=True, timeout=timeout,
            text=not binary, check=False, **({} if binary else {"errors": "replace"}),
        )
        if check and result.returncode:
            # Never include command args or unfiltered provider diagnostics.
            output = result.stderr if not binary else result.stderr.decode(errors="replace")
            for secret in self.secret_values:
                output = output.replace(secret, "[redacted]")
            raise RuntimeError("Docker operation failed: " + output[-2000:])
        return result.stdout if check else result

    def env_file(self, name, values):
        path = self.directory / (name + ".env")
        path.touch(mode=0o600)
        for key, value in values.items():
            if "\n" in str(value) or "\r" in str(value):
                raise ValueError("multiline environment value for " + key)
        path.write_text("".join(f"{key}={value}\n" for key, value in values.items()))
        return str(path)

    def setup(self):
        self.command("network", "create", self.network)
        if self.args.s3_credentials:
            self.storage = json.loads(Path(self.args.s3_credentials).read_text())
        else:
            name = self.identifier + "-s3"
            self.containers.append(name)
            self.storage = {
                "endpoint": f"http://{name}:9000", "bucketName": "encryption-test",
                "region": "us-east-1", "accessKeyId": "local-test",
                "secretAccessKey": secrets.token_hex(24), "urlStyle": "path",
            }
            env = self.env_file("minio", {
                "MINIO_ROOT_USER": self.storage["accessKeyId"],
                "MINIO_ROOT_PASSWORD": self.storage["secretAccessKey"],
            })
            self.command("run", "-d", "--name", name, "--network", self.network,
                         "--env-file", env, self.args.storage_image, "server", "/data")
        self.secret_values.extend([self.storage["accessKeyId"], self.storage["secretAccessKey"]])
        self.s3_env = self.env_file("s3", {
            "S3_ENDPOINT": self.storage["endpoint"],
            "S3_ACCESS_KEY": self.storage["accessKeyId"],
            "S3_SECRET_KEY": self.storage["secretAccessKey"],
            "S3_PATH": "on" if self.storage["urlStyle"] == "path" else "off",
        })
        if not self.args.s3_credentials:
            self.until(lambda: self.mc("mb", "--ignore-existing", self.bucket, check=False).returncode == 0)

    @property
    def bucket(self):
        return "test/" + self.storage["bucketName"]

    def mc(self, *args, check=True, binary=False):
        name = self.identifier + "-client-" + uuid.uuid4().hex[:8]
        try:
            return self.command(
                "run", "--rm", "--name", name, "--network", self.network,
                "--env-file", self.s3_env, "--entrypoint", "sh",
                self.args.storage_image, "-ec",
                'mc alias set test "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" '
                '--path "$S3_PATH" >/dev/null; exec mc "$@"', "mc", *args,
                check=check, binary=binary,
            )
        finally:
            # Killing a timed-out Docker client does not kill its container.
            self.command("rm", "-f", name, check=False)

    def role(self, prefix, path, key=None):
        values = {
            prefix + "_BUCKET": self.storage["bucketName"],
            prefix + "_ENDPOINT": self.storage["endpoint"],
            prefix + "_REGION": self.storage["region"],
            prefix + "_KEY": self.storage["accessKeyId"],
            prefix + "_SECRET": self.storage["secretAccessKey"],
            prefix + "_S3_URI_STYLE": "path" if self.storage["urlStyle"] == "path" else "host",
            prefix + "_PATH": path,
        }
        if key is not None:
            values[prefix + "_CIPHER_TYPE"] = "aes-256-cbc"
            values[prefix + "_CIPHER_PASS"] = key
        return values

    def new_volume(self, suffix):
        volume = self.identifier + "-" + suffix + "-data"
        self.volumes.append(volume)
        self.command("volume", "create", volume)
        return volume

    def start(self, suffix, values, volume=None):
        name = self.identifier + "-" + suffix
        volume = volume or self.new_volume(suffix)
        self.containers.append(name)
        values = {
            "POSTGRES_HOST_AUTH_METHOD": "trust", "WAL_HEARTBEAT_DISABLED": "1",
            "WAL_BACKUP_FULL_INTERVAL_HOURS": "0", "WAL_BACKUP_DIFF_INTERVAL_HOURS": "0",
            # Small-file restores from a real remote bucket otherwise use a
            # single worker and spend most of the test waiting on round trips.
            "PGBACKREST_PROCESS_MAX": "8",
            **values,
        }
        env = self.env_file(suffix, values)
        self.command("run", "-d", "--name", name, "--network", self.network,
                     "--env-file", env, "-v", volume + ":/var/lib/postgresql/data",
                     self.args.image)
        return name

    def external_restore(self, suffix, source_path):
        """Pre-populate PGDATA before the image boots, as an external restore does."""
        volume = self.new_volume(suffix)
        env = self.env_file(suffix + "-restore", {
            "PGBACKREST_REPO1_TYPE": "s3",
            "PGBACKREST_REPO1_PATH": source_path,
            "PGBACKREST_REPO1_S3_BUCKET": self.storage["bucketName"],
            "PGBACKREST_REPO1_S3_ENDPOINT": self.storage["endpoint"],
            "PGBACKREST_REPO1_S3_REGION": self.storage["region"],
            "PGBACKREST_REPO1_S3_KEY": self.storage["accessKeyId"],
            "PGBACKREST_REPO1_S3_KEY_SECRET": self.storage["secretAccessKey"],
            "PGBACKREST_REPO1_S3_URI_STYLE": "path" if self.storage["urlStyle"] == "path" else "host",
            "PGBACKREST_REPO1_CIPHER_TYPE": "aes-256-cbc",
            "PGBACKREST_REPO1_CIPHER_PASS": self.archive_key,
            "PGBACKREST_PROCESS_MAX": "8",
        })
        name = self.identifier + "-external-restore"
        try:
            self.command(
                "run", "--rm", "--name", name, "--network", self.network,
                "--env-file", env, "-v", volume + ":/var/lib/postgresql/data",
                "--entrypoint", "bash", self.args.image, "-euc",
                'install -d -m 0700 -o postgres -g postgres /var/lib/postgresql/data; '
                'gosu postgres pgbackrest --stanza=main --pg1-path=/var/lib/postgresql/data '
                '--recovery-option="restore_command=pgbackrest '
                '--config=/etc/pgbackrest/pgbackrest-recovery-source.conf '
                '--stanza=main archive-get %f %p" restore; '
                'test -f /var/lib/postgresql/data/PG_VERSION; '
                'test -f /var/lib/postgresql/data/global/pg_control; '
                'test ! -f /var/lib/postgresql/data/.pgbackrest_restored; '
                'test "$(cat /var/lib/postgresql/data/.pgbackrest_repo_path)" = "$PGBACKREST_REPO1_PATH"',
                timeout=300 if self.args.s3_credentials else 90,
            )
        finally:
            self.command("rm", "-f", name, check=False)
        return volume

    def sql(self, name, sql, check=True):
        result = self.command("exec", "-u", "postgres", name, "psql", "-h", "127.0.0.1",
                              "-At", "-v", "ON_ERROR_STOP=1", "-c", sql, check=check)
        return result.strip() if check else result

    def until(self, predicate, seconds=180):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(1)
        raise AssertionError("Timed out waiting for qualification condition")

    def ready(self, name):
        def available():
            if self.command("inspect", "-f", "{{.State.Status}}", name).strip() == "exited":
                raise AssertionError("PostgreSQL exited before becoming ready")
            return self.sql(name, "SELECT 1", check=False).returncode == 0
        self.until(available, seconds=300 if self.args.s3_credentials else 180)

    def info(self, name):
        result = self.command("exec", "-u", "postgres", name, "pgbackrest",
                              "--stanza=main", "info", "--output=json", check=False)
        return json.loads(result.stdout) if result.returncode == 0 else []

    def full_backup(self, name):
        def complete():
            info = self.info(name)
            return bool(info and info[0].get("backup"))
        self.until(complete)

    def objects(self, path):
        listing = self.mc("ls", "--recursive", "--json", self.bucket + path)
        return [json.loads(line)["key"] for line in listing.splitlines()
                if json.loads(line).get("type") == "file"]

    def ciphertext(self, path):
        objects = self.objects(path)
        wal = [key for key in objects if re.search(r"/archive/.*/[0-9A-F]{24}-", "/" + key)]
        backup = [key for key in objects if "/pg_data/" in "/" + key]
        metadata = [key for key in objects if key.endswith(("backup.info", "archive.info"))]
        assert wal and backup and len(metadata) == 2, "missing backup/WAL/metadata objects"
        # Inspect raw bytes fetched with storage credentials only, without
        # pgBackRest or its passphrase. OpenSSL's salted encryption envelope
        # must be present on metadata, a data file, and an archived WAL file.
        for key in [*metadata, backup[0], wal[-1]]:
            data = self.mc("cat", self.bucket + path + "/" + key, binary=True)
            assert data.startswith(b"Salted__"), "object is not encrypted: " + key
        print("PASS: raw backup metadata, data and WAL objects carry encryption envelopes", flush=True)

    def run(self):
        self.setup()
        for suffix, key in [("leading-space-key", " " + self.archive_key),
                            ("trailing-space-key", self.archive_key + " ")]:
            invalid = self.start(suffix, self.role("WAL_ARCHIVE", self.prefix + "/invalid", key))
            self.until(lambda: self.command("inspect", "-f", "{{.State.Status}}", invalid).strip() == "exited")
            assert self.command("inspect", "-f", "{{.State.ExitCode}}", invalid).strip() != "0"
            logs = self.command("logs", invalid, check=False)
            assert "must not begin or end with whitespace" in logs.stdout + logs.stderr
            assert self.archive_key not in logs.stdout + logs.stderr
        print("PASS: surrounding-whitespace keys refuse startup without disclosing or trimming the key", flush=True)
        source = self.start("source", self.role("WAL_ARCHIVE", self.prefix + "/source", self.archive_key))
        self.ready(source)
        self.full_backup(source)
        assert self.command("exec", source, "stat", "-c", "%a:%U",
                            "/etc/pgbackrest/pgbackrest.conf").strip() == "640:postgres"
        source_path = self.command("exec", source, "cat", "/var/lib/postgresql/data/.pgbackrest_repo_path").strip()
        self.sql(source, "CREATE TABLE encryption_proof(marker text); INSERT INTO encryption_proof VALUES ('before-target')")
        time.sleep(1)
        target = self.sql(source, "SELECT clock_timestamp()")
        time.sleep(1)
        self.sql(source, "INSERT INTO encryption_proof VALUES ('after-target')")
        segment = self.sql(source, "SELECT pg_walfile_name(pg_current_wal_lsn())")
        self.sql(source, "SELECT pg_switch_wal()")
        self.until(lambda: (self.sql(source, "SELECT coalesce(last_archived_wal,'') FROM pg_stat_archiver") >= segment))
        self.ciphertext(source_path)
        source_metadata = self.mc("cat", self.bucket + source_path + "/backup/main/backup.info", binary=True)
        for suffix, key in [("no-key", None), ("wrong-key", self.fork_key)]:
            values = self.role("WAL_RECOVER_FROM", source_path, key)
            bad = self.start(suffix, {**values, "POSTGRES_RECOVERY_TARGET_TIME": target})
            self.until(lambda: self.command("inspect", "-f", "{{.State.Status}}", bad).strip() == "exited")
            assert self.command("inspect", "-f", "{{.State.ExitCode}}", bad).strip() != "0"
            assert self.command("cp", bad + ":/var/lib/postgresql/data/global/pg_control",
                                str(self.directory / "unexpected-control"), check=False).returncode != 0
            logs = self.command("logs", bad, check=False)
            assert "unable to load info file" in logs.stdout + logs.stderr
        print("PASS: missing and wrong recovery keys refuse startup", flush=True)
        fork = self.start("fork", {
            **self.role("WAL_RECOVER_FROM", source_path, self.archive_key),
            **self.role("WAL_ARCHIVE", self.prefix + "/fork", self.fork_key),
            "POSTGRES_RECOVERY_TARGET_TIME": target,
            # A stale native option must not override either managed role.
            "PGBACKREST_REPO1_CIPHER_TYPE": "none",
        })
        self.ready(fork)
        assert self.command("exec", fork, "stat", "-c", "%a:%U",
                            "/etc/pgbackrest/pgbackrest-recovery-source.conf").strip() == "640:postgres"
        assert self.sql(fork, "SELECT pg_is_in_recovery()") == "f"
        assert self.sql(fork, "SELECT string_agg(marker, ',') FROM encryption_proof") == "before-target"
        self.full_backup(fork)
        self.sql(fork, "INSERT INTO encryption_proof VALUES ('fork-write'); SELECT pg_switch_wal()")
        fork_path = self.command("exec", fork, "cat", "/var/lib/postgresql/data/.pgbackrest_repo_path").strip()
        assert fork_path.startswith(self.prefix + "/fork/")
        self.ciphertext(fork_path)
        assert source_metadata == self.mc("cat", self.bucket + source_path + "/backup/main/backup.info", binary=True)
        self.command("restart", "--time", "20", fork)
        self.ready(fork)
        assert self.sql(fork, "SELECT count(*) FROM encryption_proof") == "2"
        print("PASS: PITR replays encrypted WAL, excludes post-target row, archives with independent key, survives restart", flush=True)
        snapshot_volume = self.external_restore("snapshot", source_path)
        snapshot = self.start("snapshot", {
            **self.role("WAL_RECOVER_FROM", source_path, self.archive_key),
            **self.role("WAL_ARCHIVE", self.prefix + "/snapshot", self.fork_key),
            "POSTGRES_RECOVERY_TARGET_TIME": target,
        }, volume=snapshot_volume)
        self.ready(snapshot)
        assert self.sql(snapshot, "SELECT pg_is_in_recovery()") == "f"
        assert self.sql(snapshot, "SELECT string_agg(marker, ',') FROM encryption_proof") == "before-target"
        self.full_backup(snapshot)
        snapshot_path = self.command("exec", snapshot, "cat", "/var/lib/postgresql/data/.pgbackrest_repo_path").strip()
        assert snapshot_path.startswith(self.prefix + "/snapshot/")
        self.ciphertext(snapshot_path)
        assert source_metadata == self.mc("cat", self.bucket + source_path + "/backup/main/backup.info", binary=True)
        self.command("restart", "--time", "20", snapshot)
        self.ready(snapshot)
        assert self.sql(snapshot, "SELECT string_agg(marker, ',') FROM encryption_proof") == "before-target"
        assert self.command("exec", snapshot, "cat", "/var/lib/postgresql/data/.pgbackrest_repo_path").strip() == snapshot_path
        print("PASS: external/snapshot restore discards copied source path, uses independent archive key and preserves its path across restart", flush=True)
        if not self.args.s3_credentials:
            # Keep the unencrypted control local; remote validation writes
            # only encrypted repositories to the supplied bucket.
            plain = self.start("plain", self.role("WAL_ARCHIVE", self.prefix + "/plain"))
            self.ready(plain)
            self.full_backup(plain)
            plain_path = self.command("exec", plain, "cat", "/var/lib/postgresql/data/.pgbackrest_repo_path").strip()
            raw = self.mc("cat", self.bucket + plain_path + "/backup/main/backup.info", binary=True)
            assert not raw.startswith(b"Salted__") and b"[backrest]" in raw
            print("PASS: omitted encryption settings retain unencrypted repository behavior", flush=True)
        # The secret must not occur in container logs (including failures).
        for name in self.containers:
            result = self.command("logs", name, check=False)
            assert all(secret not in result.stdout + result.stderr for secret in [self.archive_key, self.fork_key])
        print("PASS: no cipher passphrases in container logs", flush=True)
        print("Storage test prefix (retained for inspection): " + self.prefix, flush=True)

    def cleanup(self):
        for name in reversed(self.containers):
            self.command("rm", "-fv", name, check=False)
        for volume in self.volumes:
            self.command("volume", "rm", volume, check=False)
        self.command("network", "rm", self.network, check=False)

    def diagnostics(self):
        for name in self.containers:
            result = self.command("logs", "--tail", "35", name, check=False)
            output = result.stdout + result.stderr
            for secret in self.secret_values:
                output = output.replace(secret, "[redacted]")
            print(name + ":\n" + output, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--storage-image", default="postgres-ssl-test-minio:local")
    parser.add_argument("--s3-credentials", help="private Railway/S3 credential JSON file")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="pgssl-encryption-") as directory:
        qualification = Qualification(args, directory)
        try:
            qualification.run()
        except Exception:
            qualification.diagnostics()
            raise
        finally:
            qualification.cleanup()


if __name__ == "__main__":
    main()
