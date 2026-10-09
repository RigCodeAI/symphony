import hashlib
from contextlib import closing
import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("cloud_io", Path(__file__).resolve().parents[1] / "cloud_io.py")
cloud_io = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cloud_io)


class FakeCloud:
    config = {"role": "coordinator", "archive_bucket": "archive", "backup_bucket": "backups", "service_revision": "a" * 40}

    def __init__(self):
        self.objects = {}

    def put(self, bucket, name, data):
        key = (bucket, name)
        if key in self.objects and self.objects[key] != data:
            raise ValueError("immutable object changed")
        self.objects[key] = data


def archive_bytes(name="file.txt", kind=tarfile.REGTYPE):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w:gz") as archive:
        member = tarfile.TarInfo(name)
        member.type = kind
        if kind == tarfile.REGTYPE:
            member.size = 2
            archive.addfile(member, io.BytesIO(b"ok"))
        else:
            member.linkname = "/etc/passwd"
            archive.addfile(member)
    return data.getvalue()


class ReleaseTests(unittest.TestCase):
    def test_unsafe_release_cannot_write_outside_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, kind in (("../outside", tarfile.REGTYPE), ("/tmp/outside", tarfile.REGTYPE),
                               ("link", tarfile.SYMTYPE), ("link", tarfile.LNKTYPE)):
                with self.subTest(name=name, kind=kind), self.assertRaises(ValueError):
                    cloud_io.safe_unpack(archive_bytes(name, kind), root / "release")
                self.assertFalse((root / "release").exists())
                self.assertFalse((root / "outside").exists())

    def test_existing_release_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "release"
            cloud_io.safe_unpack(archive_bytes(), root)
            with self.assertRaises(ValueError):
                cloud_io.safe_unpack(archive_bytes("replacement"), root)
            self.assertEqual((root / "file.txt").read_bytes(), b"ok")
            self.assertFalse((root / "replacement").exists())


class EvidenceTests(unittest.TestCase):
    def prepare_run(self, directory):
        run = Path(directory) / "runs" / "smoke-1"
        run.mkdir(parents=True)
        for name in ("report.json", "mix.log", "candidate.diff", "finished.json", "revision.json", "submission.json"):
            (run / name).write_text("exact-secret-value ghp_examplecredential eyJabc.def.ghi")
        return run

    def test_archive_is_redacted_and_manifest_matches_uploaded_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            run = self.prepare_run(directory)
            cloud = FakeCloud()
            with patch.object(cloud_io, "DATA_ROOT", Path(directory)), \
                    patch.object(cloud_io, "credential_values", return_value=["exact-secret-value"]):
                cloud_io.archive_runs(cloud)
            manifest = json.loads(cloud.objects[("archive", "runs/smoke-1/manifest.json")])
            for name, entry in manifest["artifacts"].items():
                uploaded = cloud.objects[("archive", f"runs/smoke-1/{name}")]
                self.assertNotIn(b"exact-secret-value", uploaded)
                self.assertNotIn(b"ghp_", uploaded)
                self.assertNotIn(b"eyJabc", uploaded)
                self.assertEqual(hashlib.sha256(uploaded).hexdigest(), entry["sha256"])
            self.assertTrue((run / ".archived").is_file())

    def test_symlink_evidence_is_rejected_without_reading_target(self):
        with tempfile.TemporaryDirectory() as directory:
            run = self.prepare_run(directory)
            outside = Path(directory) / "private.txt"
            outside.write_text("private credential")
            (run / "report.json").unlink()
            (run / "report.json").symlink_to(outside)
            cloud = FakeCloud()
            with patch.object(cloud_io, "DATA_ROOT", Path(directory)), \
                    patch.object(cloud_io, "credential_values", return_value=[]), self.assertRaises(OSError):
                cloud_io.archive_runs(cloud)
            self.assertEqual(outside.read_text(), "private credential")
            self.assertEqual(cloud.objects, {})
            self.assertFalse((run / ".archived").exists())

    def test_existing_completion_marker_is_not_followed(self):
        with tempfile.TemporaryDirectory() as directory:
            run = self.prepare_run(directory)
            outside = Path(directory) / "private.txt"
            outside.write_text("untouched")
            (run / ".archived").symlink_to(outside)
            with patch.object(cloud_io, "DATA_ROOT", Path(directory)), self.assertRaises(ValueError):
                cloud_io.archive_runs(FakeCloud())
            self.assertEqual(outside.read_text(), "untouched")


class BackupTests(unittest.TestCase):
    def test_sqlite_online_backup_contains_committed_wal_data(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            state.mkdir()
            public = root / "public.json"
            public.write_text('{"role":"coordinator"}')
            source = sqlite3.connect(state / "runs.sqlite")
            source.execute("PRAGMA journal_mode=WAL")
            source.execute("CREATE TABLE runs(id TEXT)")
            source.execute("INSERT INTO runs VALUES ('committed-in-wal')")
            source.commit()
            cloud = FakeCloud()
            with patch.object(cloud_io, "DATA_ROOT", root), patch.object(cloud_io, "PUBLIC_CONFIG", public):
                cloud_io.backup(cloud)
            source.close()
            key = next(key for key in cloud.objects if key[1].endswith("/runs.sqlite"))
            restored = root / "restored.sqlite"
            restored.write_bytes(cloud.objects[key])
            with closing(sqlite3.connect(restored)) as db:
                self.assertEqual(db.execute("SELECT id FROM runs").fetchone(), ("committed-in-wal",))
                self.assertEqual(db.execute("PRAGMA integrity_check").fetchone(), ("ok",))


class TransportTests(unittest.TestCase):
    def test_put_retries_identical_object_but_refuses_changed_content(self):
        cloud = cloud_io.Cloud({})
        with patch.object(cloud, "headers", return_value={}), \
                patch.object(cloud_io, "request", side_effect=RuntimeError("cloud request failed: HTTP 412")), \
                patch.object(cloud, "object", return_value=b"first"):
            cloud.put("bucket", "immutable", b"first")
            with self.assertRaisesRegex(RuntimeError, "checksum differs"):
                cloud.put("bucket", "immutable", b"changed")

    def test_secret_version_and_project_reject_before_network(self):
        for ref, version in (("projects/other/secrets/secret", "1"),
                             ("projects/pilot/secrets/secret", "latest")):
            cloud = cloud_io.Cloud({"project_id": "pilot", "secret_ids": {"key": ref}, "secret_versions": {"key": version}})
            with patch.object(cloud_io, "request") as request, self.assertRaises(ValueError):
                cloud.secret("key")
            request.assert_not_called()


if __name__ == "__main__":
    unittest.main()
