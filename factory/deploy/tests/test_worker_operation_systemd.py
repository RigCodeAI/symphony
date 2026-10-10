"""Opt-in systemd qualification on a dedicated disposable worker host.

Ordinary test discovery skips this card. Set FACTORY_SYSTEMD_TEST_DISPOSABLE=1
only when deliberately running it on a disposable, root-managed systemd worker.
Also set FACTORY_SYSTEMD_TEST_MANAGER_REEXEC=1 to authorize PID 1 re-execution
while the controlled held/live test unit exists; this is required for a receipt.
It uses a private test socket path, never the installed broker socket. Set
FACTORY_SYSTEMD_TEST_RECEIPT to a new root-owned output path to request a
root-private qualification receipt after every check and cleanup succeeds.
"""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from types import SimpleNamespace
from unittest.mock import patch


DEPLOY = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("worker_operation", DEPLOY / "worker_operation.py")
engine = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = engine
spec.loader.exec_module(engine)

INSTALL_CONFIG = Path("/etc/factory/worker-operations.json")
REQUIRED_CHECKS = (
    "held_launch",
    "duplicate_prepare",
    "stale_identity_rejected",
    "setsid_child_terminated",
    "natural_exit",
    "restart_recovery",
    "manager_reexec",
)
_REVISION_RE = re.compile(r"^[0-9a-f]{40}$")
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_MACHINE_ID_RE = re.compile(r"^[0-9a-f]{32}$")


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key")
        value[key] = item
    return value


def _read_protected_install_config() -> dict[str, object]:
    """Read the installed pin without following links or accepting loose modes."""

    parent_info = INSTALL_CONFIG.parent.lstat()
    if (
        not stat.S_ISDIR(parent_info.st_mode)
        or parent_info.st_uid != 0
        or stat.S_IMODE(parent_info.st_mode) & 0o022
    ):
        raise RuntimeError("installed worker operation config directory is unsafe")
    before = INSTALL_CONFIG.lstat()
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != 0
        or stat.S_IMODE(before.st_mode) != 0o600
    ):
        raise RuntimeError("installed worker operation config must be root-owned mode 0600")
    descriptor = os.open(
        INSTALL_CONFIG,
        os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != 0
            or opened.st_dev != before.st_dev
            or opened.st_ino != before.st_ino
        ):
            raise RuntimeError("installed worker operation config changed while opening")
        content = bytearray()
        while len(content) <= 32 * 1024:
            chunk = os.read(descriptor, min(8192, 32 * 1024 + 1 - len(content)))
            if not chunk:
                break
            content.extend(chunk)
        if len(content) > 32 * 1024:
            raise RuntimeError("installed worker operation config is too large")
    finally:
        os.close(descriptor)

    value = json.loads(content.decode("utf-8"), object_pairs_hook=_unique_object)
    if not isinstance(value, dict):
        raise RuntimeError("installed worker operation config is not an object")
    return value


def _installed_release(config: dict[str, object]) -> tuple[str, str, str, Path]:
    revision = config.get("service_revision")
    release_sha256 = config.get("release_sha256")
    machine_id = config.get("expected_machine_id")
    wrapper_value = config.get("wrapper_path")
    if not isinstance(revision, str) or not _REVISION_RE.fullmatch(revision):
        raise RuntimeError("installed config has no valid service revision")
    if not isinstance(release_sha256, str) or not _SHA256_RE.fullmatch(release_sha256):
        raise RuntimeError("installed config has no valid release digest")
    if not isinstance(machine_id, str) or not _MACHINE_ID_RE.fullmatch(machine_id):
        raise RuntimeError("installed config has no valid machine identity")
    if not isinstance(wrapper_value, str) or not wrapper_value.startswith("/"):
        raise RuntimeError("installed config has no valid wrapper path")
    if (
        config.get("worker_user") != "factory-worker"
        or config.get("worker_group") != "factory-worker"
        or config.get("control_user") != "factory-control"
        or config.get("worker_home") != "/srv/factory/homes/factory-worker"
        or config.get("machine_id_path") != "/etc/machine-id"
        or config.get("boot_id_path") != "/proc/sys/kernel/random/boot_id"
        or config.get("cache_paths") != ["/srv/factory/tmp", f"/srv/factory/build/{revision}"]
    ):
        raise RuntimeError("installed config does not describe the expected worker runtime")

    wrapper = Path(wrapper_value).resolve(strict=True)
    release = wrapper.parents[2]
    expected_wrapper = release / "factory/deploy/worker_operation_exec.py"
    expected_test = release / "factory/deploy/tests/test_worker_operation_systemd.py"
    if wrapper != expected_wrapper or Path(__file__).resolve(strict=True) != expected_test.resolve(strict=True):
        raise RuntimeError("qualification card is not running from the configured installed release")
    if release.name != revision:
        raise RuntimeError("installed release directory does not match protected config")

    for path in (release, wrapper, expected_test, release / ".verified-sha256", release / "RELEASE.json"):
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) and path != release:
            raise RuntimeError("installed release contains a non-regular qualification file")
        if path == release and not stat.S_ISDIR(info.st_mode):
            raise RuntimeError("installed release directory is unsafe")
        if info.st_uid != 0 or stat.S_IMODE(info.st_mode) & 0o022:
            raise RuntimeError("installed release qualification files are not protected")
    marker = (release / ".verified-sha256").read_text(encoding="ascii").strip()
    if marker != release_sha256:
        raise RuntimeError("installed release digest marker differs from protected config")
    release_record = json.loads((release / "RELEASE.json").read_text(encoding="utf-8"))
    if not isinstance(release_record, dict) or release_record.get("service_revision") != revision:
        raise RuntimeError("installed release revision marker does not match protected config")
    return machine_id, revision, release_sha256, wrapper


def _systemd_version() -> int:
    result = subprocess.run(
        ["/usr/bin/systemctl", "--version"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5,
        check=False,
        env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"},
    )
    if result.returncode != 0:
        raise RuntimeError("systemctl --version failed")
    first = result.stdout.decode("ascii", "replace").splitlines()[0]
    match = re.match(r"systemd\s+(\d+)", first)
    if not match:
        raise RuntimeError("could not determine systemd version")
    return int(match.group(1))


def _process_cgroup(pid: int) -> str:
    for line in Path(f"/proc/{pid}/cgroup").read_text(encoding="ascii").splitlines():
        hierarchy, _, path = line.partition("::")
        if hierarchy == "0" and path:
            return path
    raise RuntimeError(f"process {pid} has no unified cgroup path")


def process_live(pid: int) -> bool:
    try:
        state = Path(f"/proc/{pid}/stat").read_text(encoding="ascii").rsplit(") ", 1)[1].split()[0]
        return state not in ("Z", "X")
    except FileNotFoundError:
        return False


@unittest.skipUnless(
    os.environ.get("FACTORY_SYSTEMD_TEST_DISPOSABLE") == "1",
    "requires explicit opt-in and an installed disposable systemd worker",
)
class SystemdContainmentTest(unittest.TestCase):
    def setUp(self) -> None:
        self.assertEqual(sys.platform, "linux")
        self.assertEqual(os.geteuid(), 0)
        self.assertEqual(Path("/proc/1/comm").read_text(encoding="ascii").strip(), "systemd")
        self.config = _read_protected_install_config()
        machine_id, revision, release_sha256, self.wrapper = _installed_release(self.config)
        current_machine_id = Path("/etc/machine-id").read_text(encoding="ascii").strip().lower()
        self.assertEqual(machine_id, current_machine_id)
        self.boot_id = _normalized_boot_id()
        self.service_revision = revision
        self.release_sha256 = release_sha256
        self.systemd_version = _systemd_version()
        self.assertGreaterEqual(self.systemd_version, 252)

        self.worker = pwd.getpwnam("factory-worker")
        self.root = Path(tempfile.mkdtemp(prefix="factory-systemd-test-", dir="/var/lib"))
        self.root.chmod(0o711)
        self.addCleanup(self._write_receipt_if_passed)
        self.addCleanup(self._remove_test_root)

        self.workspaces = self.root / "workspaces"
        self.workspaces.mkdir(mode=0o711)
        self.workspace = self.workspaces / "candidate"
        self.workspace.mkdir(mode=0o700)
        os.chown(self.workspace, self.worker.pw_uid, self.worker.pw_gid)
        self.records = self.root / "records"
        self.records.mkdir(mode=0o700)
        self.gates = self.root / "gates"
        self.gates.mkdir(mode=0o755)

        # The engine only needs this path to exist and marks it inaccessible in
        # the unit. A private fixture socket prevents accidentally targeting
        # the installed /run/factory-operations/control.sock broker.
        self.test_socket_path = self.root / "control.sock"
        self.test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.test_socket.bind(str(self.test_socket_path))
        os.chmod(self.test_socket_path, 0o600)
        self.test_socket.listen(1)
        self.addCleanup(self._close_test_socket)

        self.identities: list[dict[str, str]] = []
        self.checks: set[str] = set()
        self.managers: list[object] = []
        self.controller = self._new_controller()
        capabilities = self.controller.capabilities()
        self.assertTrue(capabilities.get("contained"), "required systemd/cgroup controls unavailable")
        self.assertEqual(capabilities.get("systemd_version"), self.systemd_version)
        self.assertTrue(capabilities.get("worker_account_isolated"))
        self.assertEqual(self.controller.manager.control_socket_path, str(self.test_socket_path))

    def tearDown(self) -> None:
        cleanup_errors: list[str] = []
        for identity in getattr(self, "identities", []):
            unit = identity["unit"]
            try:
                shown = subprocess.run(
                    ["/usr/bin/systemctl", "show", "--no-pager", "--property=LoadState", unit],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    timeout=5,
                    check=False,
                )
                if shown.returncode != 0 or b"LoadState=loaded" not in shown.stdout:
                    continue
                subprocess.run(
                    ["/usr/bin/systemctl", "kill", "--kill-whom=all", "--signal=KILL", unit],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=5,
                    check=False,
                )
                stopped = subprocess.run(
                    ["/usr/bin/systemctl", "stop", unit],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=5,
                    check=False,
                )
                if stopped.returncode != 0:
                    cleanup_errors.append(f"could not stop test-created unit {unit}")
            except (OSError, subprocess.TimeoutExpired):
                cleanup_errors.append(f"could not inspect or stop test-created unit {unit}")
        if cleanup_errors:
            self.fail("; ".join(cleanup_errors))
        self._units_cleaned = True

    def _new_controller(self):
        manager = engine.SystemdManager(control_socket_path=str(self.test_socket_path))
        self.managers.append(manager)
        return engine.OperationController(
            manager,
            records_dir=str(self.records),
            operation_dir=str(self.gates),
            workspace_root=str(self.workspaces),
            wrapper_path=str(self.wrapper),
            worker_home=str(self.config["worker_home"]),
            cache_paths=tuple(self.config["cache_paths"]),
            expected_machine_id=str(self.config["expected_machine_id"]),
            machine_id_path=str(self.config["machine_id_path"]),
            boot_id_path=str(self.config["boot_id_path"]),
        )

    def _reexec_manager(self, identity, expected_status):
        if os.environ.get("FACTORY_SYSTEMD_TEST_MANAGER_REEXEC") != "1":
            self.fail("manager re-execution needs explicit FACTORY_SYSTEMD_TEST_MANAGER_REEXEC=1 on the disposable worker")
        reply = subprocess.run(
            ["/usr/bin/systemctl", "daemon-reexec"], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15, check=False,
        )
        self.assertEqual(reply.returncode, 0, "system manager re-execution failed")
        deadline = time.monotonic() + 10
        recovered = None
        while time.monotonic() < deadline:
            try:
                snapshot = self.controller.manager.inspect(identity["unit"])
                if snapshot and snapshot.invocation_id == identity["invocation_id"] and snapshot.control_group == identity["control_group"]:
                    recovered = self.controller.status(identity)
                    if recovered["status"] == expected_status:
                        break
            except engine.OperationError:
                pass
            time.sleep(0.05)
        self.assertIsNotNone(recovered, "same systemd invocation did not recover")
        self.assertEqual(recovered["status"], expected_status)

    def test_held_stop_natural_exit_and_durable_restart_proofs(self) -> None:
        effect = self.workspace / "processes.json"
        child_code = "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)"
        program = f"""import json,os,subprocess,sys,time
child = subprocess.Popen([sys.executable, '-c', {child_code!r}], start_new_session=True)
with open({str(effect)!r}, 'w', encoding='utf-8') as output:
    json.dump([os.getpid(), child.pid], output)
time.sleep(60)
"""
        request = {
            "operation_id": "contained-test/" + uuid.uuid4().hex,
            "argv": ["/usr/bin/python3", "-u", "-c", program],
            "workspace": str(self.workspace),
        }
        identity = self.controller.prepare(request)
        self.identities.append(identity)
        self.assertFalse(effect.exists(), "held launch must not execute before release")
        self.assertEqual(self.controller.status(identity)["status"], "held")
        self.checks.add("held_launch")

        self.assertEqual(self.controller.prepare(request), identity)
        self.assertFalse(effect.exists(), "duplicate prepare must not release or duplicate work")
        self.checks.add("duplicate_prepare")

        stale = dict(identity, invocation_id="0" * 32)
        self.assertEqual(self.controller.stop(stale)["status"], "unknown")
        self.assertFalse(effect.exists(), "stale identity must not act on the held unit")
        self.checks.add("stale_identity_rejected")
        self._reexec_manager(identity, "held")
        self.assertFalse(effect.exists(), "manager re-execution must not release a held operation")

        # Reconstruct the controller as a broker restart while the unit remains
        # held, then ensure status and the same reservation recover in place.
        self.controller = self._new_controller()
        self.assertEqual(self.controller.status(identity)["status"], "held")
        self.assertEqual(self.controller.prepare(request), identity)

        self.assertEqual(self.controller.release(identity)["status"], "released")
        deadline = time.monotonic() + 5
        while not effect.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(effect.exists(), "released operation did not begin")
        parent_pid, child_pid = json.loads(effect.read_text(encoding="utf-8"))
        self.assertEqual(os.getpgid(child_pid), child_pid, "child should leave the parent's process group")
        self.assertNotEqual(os.getpgid(parent_pid), os.getpgid(child_pid))
        self.assertEqual(_process_cgroup(parent_pid), identity["control_group"])
        self.assertEqual(_process_cgroup(child_pid), identity["control_group"])
        self.assertTrue(process_live(child_pid))
        self._reexec_manager(identity, "running")
        self.assertTrue(process_live(parent_pid))
        self.assertTrue(process_live(child_pid))
        self.assertEqual(_process_cgroup(child_pid), identity["control_group"])
        self.checks.add("manager_reexec")

        stopped = self.controller.stop(identity)
        self.assertEqual(stopped["status"], "terminated")
        self.assertEqual(stopped["termination_proof"]["invocation_id"], identity["invocation_id"])
        self.assertFalse(process_live(parent_pid))
        self.assertFalse(process_live(child_pid))
        self.assertEqual(self.controller.prepare(request), identity, "same operation must never launch again")
        self.assertEqual(json.loads(effect.read_text(encoding="utf-8")), [parent_pid, child_pid])
        self.checks.add("setsid_child_terminated")

        self.controller = self._new_controller()
        recovered = self.controller.status(identity)
        self.assertEqual(recovered["status"], "terminated")
        self.assertEqual(recovered["termination_proof"], stopped["termination_proof"])
        self.assertEqual(self.controller.prepare(request), identity)
        self.checks.add("restart_recovery")

        natural_effect = self.workspace / "natural-exit.txt"
        natural_request = {
            "operation_id": "contained-natural/" + uuid.uuid4().hex,
            "argv": [
                "/usr/bin/python3",
                "-c",
                f"from pathlib import Path; Path({str(natural_effect)!r}).write_text('once\\n')",
            ],
            "workspace": str(self.workspace),
        }
        natural_identity = self.controller.prepare(natural_request)
        self.identities.append(natural_identity)
        self.assertEqual(self.controller.release(natural_identity)["status"], "released")
        deadline = time.monotonic() + 10
        terminal = None
        while time.monotonic() < deadline:
            if natural_effect.exists():
                snapshot = self.controller.manager.inspect(natural_identity["unit"])
                # Wait for systemd's release before asking the controller to
                # persist proof, so this check exercises the released path.
                if snapshot and snapshot.control_group == "" and snapshot.main_pid == 0:
                    terminal = self.controller.status(natural_identity)
                    if terminal["status"] == "terminated":
                        break
            time.sleep(0.02)
        self.assertTrue(natural_effect.exists(), "natural-exit command did not execute")
        self.assertEqual(natural_effect.read_text(encoding="utf-8"), "once\n")
        self.assertIsNotNone(terminal)
        self.assertEqual(terminal["status"], "terminated")
        self.assertEqual(terminal["termination_proof"]["invocation_id"], natural_identity["invocation_id"])
        self.assertEqual(terminal["termination_proof"]["cgroup_state"], "released")
        self.assertEqual(terminal["termination_proof"]["systemd_version"], self.systemd_version)
        self.checks.add("natural_exit")

        restarted = self._new_controller()
        recovered_natural = restarted.status(natural_identity)
        self.assertEqual(recovered_natural["status"], "terminated")
        self.assertEqual(recovered_natural["termination_proof"], terminal["termination_proof"])
        self.assertEqual(restarted.prepare(natural_request), natural_identity)
        self.assertEqual(natural_effect.read_text(encoding="utf-8"), "once\n")
        self.checks.add("restart_recovery")

    def _remove_test_root(self) -> None:
        if hasattr(self, "root"):
            shutil.rmtree(self.root)
            self._root_removed = True

    def _close_test_socket(self) -> None:
        if hasattr(self, "test_socket"):
            self.test_socket.close()

    def _write_receipt_if_passed(self) -> None:
        output_value = os.environ.get("FACTORY_SYSTEMD_TEST_RECEIPT")
        if not output_value:
            return
        outcome = getattr(self, "_outcome", None)
        result = getattr(outcome, "result", None)
        if result is None or any(test is self for test, _ in [*result.failures, *result.errors]):
            return
        if not getattr(self, "_units_cleaned", False) or not getattr(self, "_root_removed", False):
            return
        if set(getattr(self, "checks", set())) != set(REQUIRED_CHECKS):
            return

        output = Path(output_value)
        if not output.is_absolute() or ".." in output.parts:
            raise AssertionError("qualification receipt path must be absolute and canonical")
        parent = output.parent
        try:
            resolved_parent = parent.resolve(strict=True)
        except OSError as error:
            raise AssertionError("qualification receipt parent must already exist") from error
        if resolved_parent != parent:
            raise AssertionError("qualification receipt parent must not use symlinks")
        cursor = parent
        while True:
            info = cursor.lstat()
            if (
                not stat.S_ISDIR(info.st_mode)
                or info.st_uid != 0
                or stat.S_IMODE(info.st_mode) & 0o022
            ):
                raise AssertionError("qualification receipt path must be under root-owned protected directories")
            if cursor == cursor.parent:
                break
            cursor = cursor.parent

        current = _read_protected_install_config()
        current_machine_id, revision, release_sha256, _wrapper = _installed_release(current)
        boot_id = _normalized_boot_id()
        version = _systemd_version()
        if (
            current_machine_id != self.config.get("expected_machine_id")
            or revision != self.service_revision
            or release_sha256 != self.release_sha256
            or boot_id != self.boot_id
            or version != self.systemd_version
        ):
            raise AssertionError("worker, release, boot or systemd version changed during qualification")

        receipt = {
            "status": "passed",
            "protocol_version": engine.PROTOCOL_VERSION,
            "machine_id": current_machine_id,
            "boot_id": boot_id,
            "service_revision": revision,
            "release_sha256": release_sha256,
            "systemd_version": version,
            "checks": list(REQUIRED_CHECKS),
        }
        payload = (json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        descriptor = os.open(
            output,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        try:
            os.fchmod(descriptor, 0o600)
            view = memoryview(payload)
            while view:
                view = view[os.write(descriptor, view):]
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        directory_fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)


def _normalized_boot_id() -> str:
    value = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip().lower().replace("-", "")
    if not re.fullmatch(r"[0-9a-f]{32}", value):
        raise RuntimeError("kernel boot ID is unavailable or malformed")
    return value


class QualificationReceiptGuardTest(unittest.TestCase):
    def test_cleanup_failure_cannot_emit_a_passing_receipt(self) -> None:
        card = SystemdContainmentTest("test_held_stop_natural_exit_and_durable_restart_proofs")
        card.checks = set(REQUIRED_CHECKS)
        card._units_cleaned = True
        card._root_removed = True
        # unittest resets outcome.success inside each cleanup callback; its
        # accumulated result is the authoritative failure record.
        card._outcome = SimpleNamespace(success=True, result=SimpleNamespace(failures=[(card, "cleanup failed")], errors=[]))
        with patch.dict(os.environ, {"FACTORY_SYSTEMD_TEST_RECEIPT": "/should-not-be-written"}), \
                patch.object(Path, "lstat", side_effect=AssertionError("receipt writer reached filesystem")):
            card._write_receipt_if_passed()


if __name__ == "__main__":
    unittest.main()
