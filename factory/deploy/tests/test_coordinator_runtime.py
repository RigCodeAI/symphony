import importlib.util
import hashlib
import json
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

DEPLOY = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, DEPLOY / (name + ".py"))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


cloud_io = module("cloud_io")
entrypoint = module("coordinator_entrypoint")


@unittest.skipUnless(os.geteuid() == 0, "protected runtime fixtures require the disposable root container")
class CoordinatorRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir="/root")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.revision = "a" * 40
        self.release = self.root / self.revision
        self.release.mkdir()
        self.directory = self.root / "runtime"
        self.public = self.root / "public.json"
        self.account = SimpleNamespace(pw_gid=0)
        self.config = {
            "role": "coordinator", "service_revision": self.revision,
            "coordinator_workflow": "linear",
            "coordinator_secret_env": {"LINEAR_API_KEY": "linear_api", "LINEAR_API_TOKEN": "linear_signing"},
            "secret_ids": {"linear_api": "projects/test/secrets/linear-api", "linear_signing": "projects/test/secrets/signing"},
            "secret_versions": {"linear_api": "1", "linear_signing": "7"},
        }
        self.fetched = []
        self.cloud = SimpleNamespace(config=self.config, secret=self.secret)
        self.workflow = self.root / (self.revision + ".md")
        self.workflow.write_text("---\ntracker:\n  kind: memory\n---\nControlled")

    def secret(self, key):
        self.fetched.append(key)
        return {"linear_api": b"oauth-$()-literal", "linear_signing": b'quote-"-backslash-\\'}[key]

    def prepare(self):
        with patch.object(cloud_io.pwd, "getpwnam", return_value=self.account):
            cloud_io.prepare_coordinator_environment(self.cloud, self.directory, self.public)
        public = {"service_revision": self.revision, "coordinator_workflow": self.config["coordinator_workflow"],
                  "coordinator_secret_env": self.config["coordinator_secret_env"],
                  "coordinator_secret_versions": {env: self.config["secret_versions"][key] for env, key in self.config["coordinator_secret_env"].items()},
                  "coordinator_secret_fingerprints": {env: hashlib.sha256(f"{env}\n{key}\n{self.config['secret_ids'][key]}\n{self.config['secret_versions'][key]}".encode()).hexdigest() for env, key in self.config["coordinator_secret_env"].items()},
                  "enable_linear_webhook": self.config.get("enable_linear_webhook", False)}
        self.public.write_text(json.dumps(public))

    def runtime(self):
        with patch.object(entrypoint.pwd, "getpwnam", return_value=self.account), patch.object(entrypoint, "LINEAR_WORKFLOW_ROOT", self.root):
            return entrypoint.runtime(self.release, self.directory, self.public)

    def test_protected_pinned_credentials_are_literal_and_inherited_values_are_removed(self):
        self.prepare()
        path = self.directory / (self.revision + ".json")
        self.assertEqual(path.stat().st_mode & 0o777, 0o640)
        self.assertEqual(path.stat().st_uid, 0)
        with patch.dict(os.environ, {"OAUTH_TOKEN": "inherited-unapproved", "SAFE": "keep"}):
            workflow, env = self.runtime()
        self.assertEqual(workflow, self.workflow)
        self.assertEqual(env["LINEAR_API_KEY"], "oauth-$()-literal")
        self.assertEqual(env["LINEAR_API_TOKEN"], 'quote-"-backslash-\\')
        self.assertNotIn("OAUTH_TOKEN", env)
        self.assertEqual(env["SAFE"], "keep")
        self.assertEqual(self.fetched, ["linear_api", "linear_signing"])

    def test_worker_role_and_arbitrary_environment_names_cannot_fetch_integrations(self):
        for change in ({"role": "worker"}, {"coordinator_secret_env": {"PATH": "linear_api"}},
                       {"coordinator_secret_env": {"LINEAR_API_KEY": "worker_ssh"}}):
            with self.subTest(change=change):
                original = dict(self.config)
                self.config.update(change)
                with self.assertRaises(ValueError):
                    self.prepare()
                self.config.clear()
                self.config.update(original)
        self.assertEqual(self.fetched, [])

    def test_missing_stale_or_writable_credentials_block_startup(self):
        self.prepare()
        path = self.directory / (self.revision + ".json")
        path.chmod(0o660)
        with self.assertRaises(ValueError):
            self.runtime()
        path.chmod(0o640)
        public = json.loads(self.public.read_text())
        public["coordinator_secret_versions"]["LINEAR_API_KEY"] = "2"
        self.public.write_text(json.dumps(public))
        with self.assertRaises(ValueError):
            self.runtime()
        path.unlink()
        with self.assertRaises(ValueError):
            self.runtime()

    def test_symlink_runtime_cannot_supply_credentials(self):
        self.prepare()
        path = self.directory / (self.revision + ".json")
        target = self.root / "secret-target"
        path.rename(target)
        path.symlink_to(target)
        with self.assertRaises(ValueError):
            self.runtime()

    def test_same_version_different_secret_reference_is_stale(self):
        self.prepare()
        self.config["secret_ids"]["linear_api"] = "projects/test/secrets/replacement"
        public = json.loads(self.public.read_text())
        public["coordinator_secret_fingerprints"]["LINEAR_API_KEY"] = hashlib.sha256(f"LINEAR_API_KEY\nlinear_api\n{self.config['secret_ids']['linear_api']}\n1".encode()).hexdigest()
        self.public.write_text(json.dumps(public))
        with self.assertRaises(ValueError):
            self.runtime()

    def test_same_revision_rotation_is_rejected_before_fetch_and_preserves_old_environment(self):
        self.prepare()
        path = self.directory / (self.revision + '.json')
        before = path.read_bytes()
        self.fetched.clear()
        self.config['secret_versions']['linear_api'] = '2'
        with self.assertRaisesRegex(ValueError, 'distinct service revision'):
            self.prepare()
        self.assertEqual(self.fetched, [])
        self.assertEqual(path.read_bytes(), before)
        path.unlink()
        with self.assertRaisesRegex(ValueError, 'distinct service revision'):
            self.prepare()
        self.assertEqual(self.fetched, [])

    def test_cold_boot_candidate_preparation_restores_previous_linear_credentials_for_rollback(self):
        self.prepare()
        snapshots = self.root / 'snapshots'
        public_bytes = self.public.read_bytes()
        self.public.unlink()  # Initial candidate has not promoted its public config.
        with patch.object(cloud_io.pwd, 'getpwnam', return_value=self.account):
            cloud_io.prepare_coordinator_environments(self.cloud, self.directory, self.public, snapshots)
        self.public.write_bytes(public_bytes)
        previous_path = self.directory / (self.revision + '.json')
        previous_path.unlink()  # /run is empty after reboot.
        previous_snapshot = snapshots / (self.revision + '.json')
        self.assertEqual(previous_snapshot.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(b'oauth-$()-literal', previous_snapshot.read_bytes())
        next_config = dict(self.config, service_revision='c' * 40)
        candidate = SimpleNamespace(config=next_config, secret=self.secret)
        restored = []
        def old_cloud(config):
            self.assertEqual(config['service_revision'], self.revision)
            return SimpleNamespace(config=config, secret=lambda key: restored.append(key) or self.secret(key))
        with patch.object(cloud_io.pwd, 'getpwnam', return_value=self.account), patch.object(cloud_io, 'Cloud', side_effect=old_cloud):
            cloud_io.prepare_coordinator_environments(candidate, self.directory, self.public, snapshots)
        self.assertEqual(restored, ['linear_api', 'linear_signing'])
        self.assertTrue(previous_path.exists())
        self.assertTrue((self.directory / ('c' * 40 + '.json')).exists())
        self.assertEqual(self.runtime()[0], self.workflow)

    def test_pending_candidate_configuration_and_old_release_rollback_select_their_own_pins(self):
        self.prepare()
        pending = self.public.with_name('public.pending.json')
        pending.write_text(self.public.read_text())
        old_revision = 'b' * 40
        self.public.write_text(json.dumps({'service_revision': old_revision}))
        self.assertEqual(self.runtime()[0], self.workflow)
        old_release = self.root / old_revision
        old_release.mkdir()
        with patch.object(entrypoint.pwd, 'getpwnam', return_value=self.account):
            workflow, env = entrypoint.runtime(old_release, self.directory, self.public)
        self.assertEqual(workflow, old_release / 'factory/deploy/PILOT-WORKFLOW.md')
        self.assertFalse(entrypoint.ALLOWED_ENV.intersection(env))

    def test_cold_boot_invalid_same_revision_candidate_restores_active_runtime_before_rejection(self):
        self.prepare()
        snapshots = self.root / 'snapshots'
        public_bytes = self.public.read_bytes()
        self.public.unlink()
        with patch.object(cloud_io.pwd, 'getpwnam', return_value=self.account):
            cloud_io.prepare_coordinator_environments(self.cloud, self.directory, self.public, snapshots)
        self.public.write_bytes(public_bytes)
        path = self.directory / (self.revision + '.json')
        old = path.read_bytes()
        path.unlink()
        self.config['secret_versions']['linear_api'] = '2'
        self.fetched.clear()
        pending = json.loads(self.public.read_text())
        pending['coordinator_secret_versions']['LINEAR_API_KEY'] = '2'
        self.public.with_name('public.pending.json').write_text(json.dumps(pending))
        with patch.object(cloud_io.pwd, 'getpwnam', return_value=self.account), patch.object(cloud_io, 'Cloud', side_effect=lambda config: SimpleNamespace(config=config, secret=self.secret)):
            with self.assertRaisesRegex(ValueError, 'distinct service revision'):
                cloud_io.prepare_coordinator_environments(self.cloud, self.directory, self.public, snapshots)
        self.assertEqual(path.read_bytes(), old)
        self.assertEqual(self.fetched, ['linear_api', 'linear_signing'])
        self.assertEqual(self.runtime()[0], self.workflow)

    def test_new_pilot_requires_empty_protected_runtime_while_legacy_pilot_still_starts(self):
        self.config.update(coordinator_workflow="pilot", coordinator_secret_env={})
        self.prepare()
        workflow, env = self.runtime()
        self.assertEqual(workflow, self.release / "factory/deploy/PILOT-WORKFLOW.md")
        self.assertFalse(entrypoint.ALLOWED_ENV.intersection(env))
        (self.directory / (self.revision + ".json")).unlink()
        with self.assertRaises(ValueError):
            self.runtime()
        self.public.write_text(json.dumps({"service_revision": self.revision}))
        self.assertEqual(self.runtime()[0], workflow)

    def test_failed_fetch_preserves_previous_per_release_environment(self):
        self.prepare()
        path = self.directory / (self.revision + ".json")
        before = path.read_bytes()
        self.cloud.secret = lambda key: b"bad\ncredential"
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(path.read_bytes(), before)

    def test_invalid_selector_and_unpinned_version_fail_closed(self):
        self.config["coordinator_workflow"] = "../../untrusted"
        with self.assertRaises(ValueError):
            self.prepare()
        self.config["coordinator_workflow"] = "linear"
        self.config["secret_versions"]["linear_api"] = "latest"
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(self.fetched, [])


if __name__ == "__main__":
    unittest.main()
