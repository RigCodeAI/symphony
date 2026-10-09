#!/usr/bin/env python3
"""Small root-only GCP transport for bootstrap, backups and redacted pilot evidence.

Credential values and access tokens never go through Terraform or stdout. Agent
users cannot invoke this transport or obtain the instance metadata identity.
"""
import argparse
import base64
from contextlib import closing
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

CONFIG = Path("/etc/factory/config.json")
PUBLIC_CONFIG = Path("/etc/factory/public.json")
EVENTS = Path("/var/log/factory-events.log")
DATA_ROOT = Path("/srv/factory")
TOKEN_PATTERN = re.compile(r"(?:sk-|gh[pousr]_|github_pat_)[A-Za-z0-9_-]+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+")


def event(name):
    with EVENTS.open("a") as handle:
        handle.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} FACTORY_EVENT {name}\n")


def request(url, method="GET", data=None, headers=None):
    # Do not include response bodies, URLs or Authorization in error messages.
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    for attempt in range(6):
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                return response.read()
        except urllib.error.HTTPError as exc:
            if attempt < 5 and exc.code in (401, 403, 404, 429, 500, 502, 503, 504):
                time.sleep(min(2 ** attempt, 8))
                continue
            raise RuntimeError(f"cloud request failed: HTTP {exc.code}") from None
        except urllib.error.URLError:
            if attempt < 5:
                time.sleep(min(2 ** attempt, 8))
                continue
            raise RuntimeError("cloud request failed: transport unavailable") from None


class Cloud:
    def __init__(self, config):
        self.config = config

    def headers(self):
        reply = json.loads(request(
            "http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token",
            headers={"Metadata-Flavor": "Google"}))
        return {"Authorization": "Bearer " + reply["access_token"]}

    def object(self, bucket, name):
        return request("https://storage.googleapis.com/storage/v1/b/" +
                       urllib.parse.quote(bucket, safe="") + "/o/" +
                       urllib.parse.quote(name, safe="") + "?alt=media", headers=self.headers())

    def put(self, bucket, name, payload):
        url = "https://storage.googleapis.com/upload/storage/v1/b/" + urllib.parse.quote(bucket, safe="")
        url += "/o?uploadType=media&ifGenerationMatch=0&name=" + urllib.parse.quote(name, safe="")
        # Immutable names: an existing object never gets overwritten. Compare its
        # checksum on retries, so interrupted archival can safely finish.
        try:
            return request(url, "POST", payload,
                           {**self.headers(), "Content-Type": "application/octet-stream"})
        except RuntimeError as exc:
            if str(exc) != "cloud request failed: HTTP 412":
                raise
            if self.object(bucket, name) != payload:
                raise RuntimeError("existing object checksum differs; refusing overwrite") from None
            return b""

    def secret(self, key):
        reference = self.config["secret_ids"][key]
        version = self.config["secret_versions"][key]
        prefix = "projects/" + self.config["project_id"] + "/secrets/"
        if not reference.startswith(prefix) or not re.fullmatch(r"[1-9][0-9]*", str(version)):
            raise ValueError("secret reference must use this project and a pinned numeric version")
        data = json.loads(request("https://secretmanager.googleapis.com/v1/" + reference +
                                 "/versions/" + str(version) + ":access", headers=self.headers()))
        return base64.b64decode(data["payload"]["data"], validate=True)


def safe_unpack(payload, destination):
    destination = Path(destination)
    if destination.exists():
        raise ValueError("release destination already exists")
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
        members = archive.getmembers()
        for member in members:
            parts = Path(member.name).parts
            if (member.name.startswith("/") or ".." in parts or not parts or
                    not (member.isfile() or member.isdir())):
                raise ValueError("release archive contains unsafe paths or file types")
        destination.mkdir(parents=True, mode=0o755)
        destination.chmod(0o755)
        try:
            for member in members:
                target = destination / member.name
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True, mode=0o755)
                    target.chmod(0o755)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                    with archive.extractfile(member) as source, target.open("xb") as output:
                        output.write(source.read())
                    target.chmod(0o755 if member.mode & 0o111 else 0o644)
            for directory, _subdirs, _files in os.walk(destination):
                os.chmod(directory, 0o755)
        except Exception:
            # Preserve the rejected candidate for inspection; it is never activated.
            raise


def pack(repository, output):
    repo = Path(repository).resolve()
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=repo).strip():
        raise ValueError("commit deployment source before packaging")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    raw = subprocess.check_output(["git", "archive", "--format=tar", revision], cwd=repo)
    buffer = io.BytesIO()
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as source, tarfile.open(fileobj=buffer, mode="w:") as dest:
        for member in source.getmembers():
            if not (member.isfile() or member.isdir()):
                raise ValueError("release source must contain regular files/directories only")
            dest.addfile(member, source.extractfile(member) if member.isfile() else None)
        data = json.dumps({"service_revision": revision}, sort_keys=True).encode()
        marker = tarfile.TarInfo("RELEASE.json")
        marker.size, marker.mode, marker.mtime = len(data), 0o644, 0
        dest.addfile(marker, io.BytesIO(data))
    payload = gzip.compress(buffer.getvalue(), mtime=0)
    with Path(output).open("xb") as handle:
        handle.write(payload)
    print(json.dumps({"service_revision": revision, "release_sha256": hashlib.sha256(payload).hexdigest(),
                      "release_object": f"releases/{revision}.tar.gz", "path": str(Path(output).resolve())}))


def credential_values():
    values = []
    path = Path("/run/factory/model-auth.json")
    if path.exists():
        data = json.loads(path.read_text())
        def walk(value):
            if isinstance(value, dict):
                for key, item in value.items():
                    if isinstance(item, str) and re.search(r"token|secret|password|key", key, re.I) and len(item) >= 8:
                        values.append(item)
                    else:
                        walk(item)
            elif isinstance(value, list):
                for item in value:
                    walk(item)
        walk(data)
    return values


def redact(payload, values):
    text = payload.decode("utf-8", errors="replace")
    for value in values:
        text = text.replace(value, "[REDACTED]")
    return TOKEN_PATTERN.sub("[REDACTED]", text).encode()


def regular_read(directory_fd, name):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
    with os.fdopen(fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 10 * 1024 * 1024:
            raise ValueError("pilot evidence must be a regular file at most 10 MiB")
        data = handle.read(10 * 1024 * 1024 + 1)
        if len(data) > 10 * 1024 * 1024:
            raise ValueError("pilot evidence exceeds 10 MiB per artifact")
        return data


def archive_runs(cloud):
    root = DATA_ROOT / "runs"
    for run in sorted(root.iterdir()):
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}", run.name) or not run.is_dir() or run.is_symlink():
            raise ValueError("invalid run directory")
        if not (run / "finished.json").is_file():
            continue
        fd = os.open(run, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            try:
                marker = os.stat(".archived", dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                marker = None
            if marker:
                if marker.st_uid != 0 or not stat.S_ISREG(marker.st_mode):
                    raise ValueError("archive completion marker must be root-owned and regular")
                continue
            manifest = {"version": 1, "run_id": run.name, "artifacts": {}}
            values = credential_values()
            names = ("report.json", "mix.log", "candidate.diff", "finished.json", "revision.json")
            if cloud.config.get("role") == "coordinator":
                names += ("submission.json",)
            for name in names:
                data = redact(regular_read(fd, name), values)
                digest = hashlib.sha256(data).hexdigest()
                cloud.put(cloud.config["archive_bucket"], f"runs/{run.name}/{name}", data)
                manifest["artifacts"][name] = {"sha256": digest, "bytes": len(data)}
            data = json.dumps(manifest, sort_keys=True, indent=2).encode()
            cloud.put(cloud.config["archive_bucket"], f"runs/{run.name}/manifest.json", data)
            marker_fd = os.open(".archived", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                0o600, dir_fd=fd)
            with os.fdopen(marker_fd, "w") as handle:
                handle.write(hashlib.sha256(data).hexdigest() + "\n")
        finally:
            os.close(fd)


def backup(cloud):
    # DEV-232 owns the runtime database. Back up any configured *.sqlite files
    # with SQLite's online backup API, never by copying live WAL files.
    bucket = cloud.config["backup_bucket"]
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    active = DATA_ROOT / "active.json"
    revision = json.loads(active.read_text())["service_revision"] if active.exists() else cloud.config["service_revision"]
    manifest = {"version": 1, "service_revision": revision, "databases": []}
    state = DATA_ROOT / "state"
    with tempfile.TemporaryDirectory(prefix="factory-backup-") as directory:
        for path in sorted(state.glob("*.sqlite")):
            if path.is_symlink():
                raise ValueError("backup database must not be a symlink")
            target = Path(directory) / path.name
            with closing(sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=30)) as source, closing(sqlite3.connect(target)) as dest:
                source.backup(dest)
                if dest.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                    raise RuntimeError("SQLite backup integrity check failed")
            payload = target.read_bytes()
            cloud.put(bucket, f"backups/{stamp}/{path.name}", payload)
            manifest["databases"].append({"name": path.name, "sha256": hashlib.sha256(payload).hexdigest()})
        if not manifest["databases"]:
            manifest["note"] = "This deployed pilot has no durable runtime SQLite database yet."
        public = PUBLIC_CONFIG.read_bytes()
        cloud.put(bucket, f"backups/{stamp}/public.json", public)
        cloud.put(bucket, f"backups/{stamp}/manifest.json", json.dumps(manifest, sort_keys=True).encode())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("pack")
    p.add_argument("repository")
    p.add_argument("output")
    p = sub.add_parser("get-release")
    p.add_argument("destination")
    p = sub.add_parser("secret")
    p.add_argument("key")
    p.add_argument("destination")
    sub.add_parser("publish-hostkey")
    sub.add_parser("hostkeys")
    sub.add_parser("archive")
    sub.add_parser("backup")
    args = parser.parse_args()
    if args.command == "pack":
        return pack(args.repository, args.output)
    if os.geteuid() != 0:
        raise PermissionError("cloud transport is root-only")
    stat = CONFIG.stat()
    if stat.st_uid != 0 or stat.st_mode & 0o077:
        raise PermissionError("cloud config must be root-owned and mode 0600")
    cloud = Cloud(json.loads(CONFIG.read_text()))
    if args.command == "get-release":
        data = cloud.object(cloud.config["release_bucket"], cloud.config["release_object"])
        digest = hashlib.sha256(data).hexdigest()
        if digest != cloud.config["release_sha256"]:
            raise ValueError("release archive checksum mismatch")
        safe_unpack(data, args.destination)
        marker = json.loads((Path(args.destination) / "RELEASE.json").read_text())
        if marker["service_revision"] != cloud.config["service_revision"]:
            raise ValueError("release revision mismatch")
        (Path(args.destination) / ".verified-sha256").write_text(digest + "\n")
    elif args.command == "secret":
        path = Path(args.destination)
        with path.open("xb") as handle:
            os.chmod(path, 0o600)
            handle.write(cloud.secret(args.key))
    elif args.command == "publish-hostkey":
        cloud.put(cloud.config["release_bucket"], "host-keys/" + cloud.config["instance_name"] + ".pub",
                  Path("/etc/ssh/ssh_host_ed25519_key.pub").read_bytes())
    elif args.command == "hostkeys":
        records = []
        for worker in cloud.config["worker_hosts"]:
            raw = cloud.object(cloud.config["release_bucket"], "host-keys/" + worker["name"] + ".pub").decode().strip().split()
            if len(raw) < 2 or raw[0] != "ssh-ed25519":
                raise ValueError("worker host key must be ed25519")
            records.append(worker["ip"] + " " + " ".join(raw[:2]))
        Path("/run/factory/known_hosts").write_text("\n".join(records) + "\n")
    elif args.command == "archive":
        archive_runs(cloud)
    elif args.command == "backup":
        backup(cloud)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        command = sys.argv[1] if len(sys.argv) > 1 else "unknown"
        if command in ("archive", "backup") and os.geteuid() == 0:
            event(command + "_failed")
        # Error text is constrained; unexpected exceptions don't expose payloads.
        detail = f": {exc}" if isinstance(exc, (ValueError, RuntimeError, PermissionError)) else ""
        print(f"factory {command} failed ({type(exc).__name__}){detail}", file=sys.stderr)
        sys.exit(1)
