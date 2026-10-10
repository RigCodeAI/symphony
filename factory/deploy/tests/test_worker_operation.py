from __future__ import annotations

import hashlib
import grp
import json
import os
import pwd
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from factory.deploy.worker_operation import (
    OperationCapacityError,
    OperationConflict,
    OperationController,
    OperationUnavailable,
    OperationValidationError,
    SystemdManager,
    UnitSnapshot,
)


class FakeManager:
    def __init__(self) -> None:
        self.start_calls: list[tuple[str, str, str, dict[str, object]]] = []
        self.kill_calls: list[tuple[str, str]] = []
        self.stop_calls: list[str] = []
        self.snapshot: UnitSnapshot | None = None
        self.unit: str | None = None
        self.populated = 0
        self.fail_after_start = False
        self.terminate_on_term = True
        self.on_start = None
        self.on_stop = None
        self.stream = object()
        self.claimed: set[str] = set()
        self.stream_available = True

    def capabilities(self) -> dict[str, object]:
        return {
            "contained": True,
            "system_manager": True,
            "cgroup_v2": True,
            "required_isolation": True,
            "systemd_version": 254,
            "released_cgroup_proof": True,
        }

    def start(self, unit, wrapper_path, descriptor_path, properties) -> None:
        copied_properties = dict(properties)
        self.start_calls.append((unit, wrapper_path, descriptor_path, copied_properties))
        self.unit = unit
        if self.on_start:
            self.on_start(unit, wrapper_path, descriptor_path, copied_properties)
        self.snapshot = UnitSnapshot(
            load_state="loaded",
            invocation_id="a" * 32,
            control_group=f"/system.slice/{unit}",
            active_state="active",
            sub_state="running",
            result="",
            exec_main_code="",
            exec_main_status=0,
            main_pid=1234,
            user=str(properties["User"]),
            group=str(properties["Group"]),
            syslog_identifier=str(properties["SyslogIdentifier"]),
        )
        self.populated = 1
        if self.fail_after_start:
            raise OperationUnavailable("simulated lost start response")

    def claim_stream(self, unit):
        if not self.stream_available or self.snapshot is None or unit in self.claimed:
            raise OperationUnavailable("stream unavailable")
        self.claimed.add(unit)
        return self.stream

    def inspect(self, unit):
        if self.snapshot is None or self.unit != unit:
            return None
        return self.snapshot

    def cgroup_populated(self, control_group):
        if self.snapshot is None or self.snapshot.control_group != control_group:
            raise OperationUnavailable("cgroup unavailable")
        return self.populated

    def kill(self, unit, signal_name):
        self.kill_calls.append((unit, signal_name))
        if signal_name == "TERM" and self.terminate_on_term:
            self.populated = 0
            self.snapshot = UnitSnapshot(
                **{
                    **self.snapshot.__dict__,
                    "active_state": "active",
                    "sub_state": "exited",
                    "exec_main_code": "killed",
                    "exec_main_status": 15,
                    "main_pid": 0,
                }
            )

    def stop(self, unit):
        self.stop_calls.append(unit)
        if self.on_stop:
            self.on_stop(unit)


class OperationControllerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.records = self.root / "records"
        self.operations = self.root / "public-operations"
        self.workspaces = self.root / "workspaces"
        self.home = self.root / "worker-home"
        for path, mode in (
            (self.records, 0o700),
            (self.operations, 0o755),
            (self.workspaces, 0o755),
            (self.home, 0o700),
        ):
            path.mkdir(mode=mode)
            path.chmod(mode)
        self.workspace = self.workspaces / "run-1"
        self.workspace.mkdir()
        self.machine_id_path = self.root / "machine-id"
        self.machine_id_path.write_text("b" * 32 + "\n", encoding="ascii")
        self.boot_id_path = self.root / "boot-id"
        self.boot_id_path.write_text("11111111-1111-1111-1111-111111111111\n", encoding="ascii")
        self.wrapper = self.root / "operation-wrapper"
        self.wrapper.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.wrapper.chmod(0o755)
        self.manager = FakeManager()
        self.user = pwd.getpwuid(os.getuid()).pw_name
        self.group = grp.getgrgid(os.getgid()).gr_name
        self.controller = OperationController(
            self.manager,
            records_dir=str(self.records),
            operation_dir=str(self.operations),
            workspace_root=str(self.workspaces),
            wrapper_path=str(self.wrapper),
            worker_home=str(self.home),
            machine_id_path=str(self.machine_id_path),
            boot_id_path=str(self.boot_id_path),
            worker_user=self.user,
            worker_group=self.group,
            expected_owner_uid=os.getuid(),
            operation_timeout=0.25,
            stop_timeout=0.02,
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def request(self, operation_id="run/stage/attempt-1"):
        return {
            "operation_id": operation_id,
            "argv": [sys.executable, "-c", "print('worker')"],
            "workspace": str(self.workspace),
        }

    def record_for(self, identity):
        path = self.records / f"{hashlib.sha256(identity['operation_id'].encode()).hexdigest()}.json"
        return json.loads(path.read_text(encoding="utf-8"))

    def test_prepare_reserves_before_start_and_creates_held_public_descriptor(self):
        def check_reservation(unit, wrapper, descriptor, properties):
            records = list(self.records.glob("*.json"))
            self.assertEqual(len(records), 1)
            self.assertEqual(json.loads(records[0].read_text())["state"], "starting")
            self.assertEqual(wrapper, str(self.wrapper))
            self.assertTrue(Path(descriptor).is_file())
            self.assertNotIn("-c", " ".join([wrapper, descriptor]))

        self.manager.on_start = check_reservation
        identity = self.controller.prepare(self.request())

        self.assertEqual(set(identity), {
            "kind", "operation_id", "machine_id", "boot_id", "unit",
            "invocation_id", "control_group", "request_sha256",
        })
        self.assertEqual(identity["kind"], "systemd-unit")
        self.assertEqual(identity["operation_id"], "run/stage/attempt-1")
        self.assertEqual(identity["control_group"], f"/system.slice/{identity['unit']}")
        manifest_path = Path(self.manager.start_calls[0][2])
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(manifest["argv"][1:], ["-c", "print('worker')"])
        self.assertEqual(manifest["workspace"], str(self.workspace))
        self.assertFalse(Path(manifest["release_file"]).exists())
        self.assertEqual(set(manifest["environment"]), {
            "HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "TMPDIR",
            "XDG_CACHE_HOME", "CARGO_HOME", "RUSTUP_HOME", "CODEX_HOME",
            "MISE_DATA_DIR", "MISE_CACHE_DIR", "MIX_HOME", "CARGO_BUILD_JOBS",
        })
        self.assertIn("/srv/factory/bootstrap-tools-v1/cargo/bin", manifest["environment"]["PATH"])
        self.assertIn("/srv/factory/bootstrap-tools-v1/rig-tools/codex/bin", manifest["environment"]["PATH"])
        self.assertEqual(stat.S_IMODE(manifest_path.stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE(manifest_path.parent.stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE(self.records.stat().st_mode), 0o700)

        properties = self.manager.start_calls[0][3]
        self.assertEqual(properties["Type"], "exec")
        self.assertEqual(properties["RemainAfterExit"], "yes")
        self.assertEqual(properties["Restart"], "no")
        self.assertEqual(properties["KillMode"], "control-group")
        self.assertEqual(properties["SendSIGKILL"], "yes")
        self.assertEqual(properties["TimeoutStopSec"], "2s")
        self.assertEqual(properties["User"], self.user)
        self.assertEqual(properties["Group"], self.group)
        self.assertEqual(properties["SupplementaryGroups"], "")
        self.assertEqual(properties["NoNewPrivileges"], "yes")
        self.assertEqual(properties["CapabilityBoundingSet"], "")
        self.assertEqual(properties["ProtectControlGroups"], "yes")
        self.assertEqual(properties["ProtectSystem"], "strict")
        self.assertEqual(properties["ProtectHome"], "read-only")
        self.assertEqual(properties["Delegate"], "no")
        self.assertEqual(properties["InaccessiblePaths"][-3:], [
            "/run/systemd/private", "/run/dbus/system_bus_socket", "/run/user",
        ])
        self.assertIn(str(self.workspace), properties["ReadWritePaths"])
        self.assertIn(str(self.home), properties["ReadWritePaths"])
        self.assertNotIn("OPENAI_API_KEY", " ".join(properties["Environment"]))
        self.assertFalse(self.controller.capabilities()["contained"])

    def test_release_is_exactly_bound_and_status_reconciles_the_marker(self):
        identity = self.controller.prepare(self.request())
        release_path = self.operations / hashlib.sha256(identity["operation_id"].encode()).hexdigest() / "release"

        result = self.controller.release(identity)

        self.assertEqual(result["status"], "released")
        self.assertEqual(release_path.read_bytes(), (identity["invocation_id"] + "\n").encode("ascii"))
        self.assertEqual(stat.S_IMODE(release_path.stat().st_mode), 0o644)
        self.assertEqual(self.controller.status(identity)["status"], "running")
        self.assertEqual(self.controller.release(identity)["status"], "released")
        self.assertEqual(len(self.manager.start_calls), 1)

    def test_release_decision_is_durable_before_marker_and_retry_does_not_restart(self):
        identity = self.controller.prepare(self.request())
        original = self.controller._write_public_file

        def fail_release(path, content, *, exclusive):
            if path.name == "release":
                raise OSError("simulated crash before marker write")
            return original(path, content, exclusive=exclusive)

        with patch.object(self.controller, "_write_public_file", side_effect=fail_release):
            with self.assertRaises(OperationUnavailable):
                self.controller.release(identity)

        record = self.record_for(identity)
        self.assertTrue(record["release_decision"])
        self.assertFalse(record["release_written"])
        self.assertEqual(record["state"], "release_pending")
        self.assertEqual(self.controller.release(identity)["status"], "released")
        self.assertEqual(len(self.manager.start_calls), 1)

    def test_start_response_loss_reserves_operation_and_replay_never_starts_twice(self):
        self.manager.fail_after_start = True
        with self.assertRaises(OperationUnavailable):
            self.controller.prepare(self.request())

        self.manager.fail_after_start = False
        identity = self.controller.prepare(self.request())

        self.assertEqual(len(self.manager.start_calls), 1)
        self.assertEqual(identity["invocation_id"], "a" * 32)
        self.assertEqual(self.record_for(identity)["state"], "prepared")

    def test_broker_restart_reuses_record_without_restarting_or_reconnecting_stream(self):
        identity = self.controller.prepare(self.request())
        restarted_manager = FakeManager()
        restarted_manager.snapshot = self.manager.snapshot
        restarted_manager.populated = self.manager.populated
        restarted_manager.stream_available = False
        restarted_controller = OperationController(
            restarted_manager,
            records_dir=str(self.records),
            operation_dir=str(self.operations),
            workspace_root=str(self.workspaces),
            wrapper_path=str(self.wrapper),
            worker_home=str(self.home),
            machine_id_path=str(self.machine_id_path),
            boot_id_path=str(self.boot_id_path),
            worker_user=self.user,
            worker_group=self.group,
            expected_owner_uid=os.getuid(),
        )

        self.assertEqual(restarted_controller.prepare(self.request()), identity)
        with self.assertRaises(OperationUnavailable):
            restarted_controller.claim_stream(identity)
        self.assertEqual(restarted_manager.start_calls, [])

    def test_exact_duplicate_returns_identity_but_changed_request_conflicts(self):
        identity = self.controller.prepare(self.request())
        self.assertEqual(self.controller.prepare(self.request()), identity)
        changed = self.request()
        changed["argv"] = [sys.executable, "-c", "print('different')"]
        with self.assertRaises(OperationConflict):
            self.controller.prepare(changed)
        self.assertEqual(len(self.manager.start_calls), 1)

    def test_only_one_active_or_unknown_operation_uses_worker_uid(self):
        identity = self.controller.prepare(self.request())
        with self.assertRaises(OperationCapacityError):
            self.controller.prepare(self.request("another-operation"))

        self.manager.populated = 0
        self.manager.snapshot = UnitSnapshot(
            **{
                **self.manager.snapshot.__dict__,
                "active_state": "active",
                "sub_state": "exited",
                "exec_main_code": "exited",
                "exec_main_status": 0,
                "main_pid": 0,
            }
        )
        result = self.controller.status(identity)

        self.assertEqual(result["status"], "terminated")
        self.assertEqual(result["exit_status"], 0)
        self.assertEqual(result["termination_proof"]["cgroup_populated"], 0)
        self.assertEqual(result["termination_proof"]["main_pid"], 0)
        self.assertEqual(self.manager.stop_calls, [identity["unit"]])
        self.assertEqual(self.record_for(identity)["state"], "terminated")
        second = self.controller.prepare(self.request("another-operation"))
        self.assertEqual(second["operation_id"], "another-operation")
        self.assertEqual(len(self.manager.start_calls), 2)

    def test_failed_unit_with_empty_cgroup_is_a_terminal_proof(self):
        identity = self.controller.prepare(self.request())
        self.manager.populated = 0
        self.manager.snapshot = UnitSnapshot(
            **{
                **self.manager.snapshot.__dict__,
                "active_state": "failed",
                "sub_state": "failed",
                "exec_main_code": "exited",
                "exec_main_status": 1,
                "main_pid": 0,
            }
        )

        result = self.controller.status(identity)

        self.assertEqual(result["status"], "terminated")
        self.assertEqual(result["termination_proof"]["active_state"], "failed")
        self.assertEqual(result["termination_proof"]["cgroup_populated"], 0)

    def test_released_cgroup_proves_normal_completion_and_preserves_recorded_path(self):
        identity = self.controller.prepare(self.request())
        self.manager.snapshot = UnitSnapshot(
            **{
                **self.manager.snapshot.__dict__,
                "control_group": "",
                "active_state": "active",
                "sub_state": "exited",
                "exec_main_code": "exited",
                "exec_main_status": 0,
                "main_pid": 0,
            }
        )

        def verify_durable_proof(_unit):
            record = self.record_for(identity)
            self.assertEqual(record["state"], "terminated")
            self.assertEqual(record["termination_proof"]["cgroup_state"], "released")

        self.manager.on_stop = verify_durable_proof
        result = self.controller.status(identity)

        proof = result["termination_proof"]
        self.assertEqual(result["status"], "terminated")
        self.assertEqual(proof["cgroup_state"], "released")
        self.assertEqual(proof["cgroup_populated"], 0)
        self.assertEqual(proof["control_group"], identity["control_group"])
        self.assertEqual(proof["systemd_version"], 254)
        self.assertEqual(
            set(proof),
            {
                "machine_id", "boot_id", "unit", "invocation_id", "control_group",
                "cgroup_state", "cgroup_populated", "active_state", "sub_state",
                "exec_main_code", "exec_main_status", "main_pid", "systemd_version",
                "observed_at",
            },
        )
        self.assertEqual(self.manager.stop_calls, [identity["unit"]])
        self.assertEqual(self.manager.kill_calls, [])

    def test_released_cgroup_proves_failed_terminal_unit(self):
        identity = self.controller.prepare(self.request())
        self.manager.snapshot = UnitSnapshot(
            **{
                **self.manager.snapshot.__dict__,
                "control_group": "",
                "active_state": "failed",
                "sub_state": "failed",
                "exec_main_code": "exited",
                "exec_main_status": 1,
                "main_pid": 0,
            }
        )

        result = self.controller.status(identity)

        self.assertEqual(result["status"], "terminated")
        self.assertEqual(result["termination_proof"]["cgroup_state"], "released")
        self.assertEqual(result["termination_proof"]["active_state"], "failed")
        self.assertEqual(self.manager.kill_calls, [])

    def test_released_or_mismatched_cgroup_without_exact_terminal_identity_is_unknown(self):
        identity = self.controller.prepare(self.request())
        initial = self.manager.snapshot
        cases = (
            {"control_group": "", "invocation_id": "c" * 32, "active_state": "active", "sub_state": "exited", "main_pid": 0},
            {"control_group": "", "active_state": "active", "sub_state": "running", "main_pid": 1234},
            {"control_group": "", "user": "different-worker", "active_state": "active", "sub_state": "exited", "main_pid": 0},
            {"control_group": "", "syslog_identifier": "factory-operation-" + "d" * 32, "active_state": "active", "sub_state": "exited", "main_pid": 0},
            {"control_group": "/system.slice/other.service", "active_state": "active", "sub_state": "exited", "main_pid": 0},
        )

        for changes in cases:
            with self.subTest(changes=changes):
                self.manager.snapshot = UnitSnapshot(**{**initial.__dict__, **changes})
                result = self.controller.status(identity)
                self.assertEqual(result["status"], "unknown")
                self.assertEqual(self.manager.kill_calls, [])
                self.assertEqual(self.manager.stop_calls, [])

    def test_empty_cgroup_without_released_proof_capability_stays_unknown(self):
        identity = self.controller.prepare(self.request())
        self.manager.snapshot = UnitSnapshot(
            **{
                **self.manager.snapshot.__dict__,
                "control_group": "",
                "active_state": "active",
                "sub_state": "exited",
                "exec_main_code": "exited",
                "main_pid": 0,
            }
        )
        self.manager.capabilities = lambda: {
            "systemd_version": 253,
            "released_cgroup_proof": False,
        }

        self.assertEqual(self.controller.status(identity)["status"], "unknown")
        self.assertEqual(self.manager.kill_calls, [])
        self.assertEqual(self.manager.stop_calls, [])

    def test_stop_sends_term_then_kill_and_cleans_up_only_after_durable_proof(self):
        identity = self.controller.prepare(self.request())

        def verify_durable_proof(_unit):
            record = self.record_for(identity)
            self.assertEqual(record["state"], "terminated")
            self.assertEqual(record["termination_proof"]["cgroup_populated"], 0)

        self.manager.on_stop = verify_durable_proof
        result = self.controller.stop(identity)

        self.assertEqual(result["status"], "terminated")
        self.assertEqual(self.manager.kill_calls, [(identity["unit"], "TERM")])
        self.assertEqual(self.manager.stop_calls, [identity["unit"]])
        self.assertEqual(result["termination_proof"]["active_state"], "active")
        self.assertEqual(result["termination_proof"]["sub_state"], "exited")

    def test_populated_child_after_term_and_kill_remains_unknown_and_reserved(self):
        identity = self.controller.prepare(self.request())
        self.manager.terminate_on_term = False

        result = self.controller.stop(identity)

        self.assertEqual(result["status"], "unknown")
        self.assertEqual([signal for _, signal in self.manager.kill_calls], ["TERM", "KILL"])
        self.assertEqual(self.manager.stop_calls, [])
        self.assertEqual(self.record_for(identity)["state"], "released" if self.record_for(identity)["release_written"] else "prepared")
        with self.assertRaises(OperationCapacityError):
            self.controller.prepare(self.request("another-operation"))

    def test_stale_invocation_or_boot_identity_never_receives_a_signal(self):
        identity = self.controller.prepare(self.request())
        self.manager.snapshot = UnitSnapshot(
            **{**self.manager.snapshot.__dict__, "invocation_id": "c" * 32}
        )
        result = self.controller.stop(identity)
        self.assertEqual(result["status"], "unknown")
        self.assertEqual(self.manager.kill_calls, [])

        self.manager.snapshot = UnitSnapshot(
            **{**self.manager.snapshot.__dict__, "invocation_id": identity["invocation_id"]}
        )
        self.boot_id_path.write_text("22222222-2222-2222-2222-222222222222\n", encoding="ascii")
        result = self.controller.stop(identity)
        self.assertEqual(result["status"], "unknown")
        self.assertEqual(self.manager.kill_calls, [])

    def test_missing_unit_or_cgroup_is_unknown_and_never_signaled(self):
        identity = self.controller.prepare(self.request())
        self.manager.snapshot = None
        self.assertEqual(self.controller.status(identity)["status"], "unknown")
        self.assertEqual(self.controller.stop(identity)["status"], "unknown")
        self.assertEqual(self.manager.kill_calls, [])

    def test_nonempty_cgroup_without_readable_events_is_unknown_and_never_signaled(self):
        identity = self.controller.prepare(self.request())
        with patch.object(self.manager, "cgroup_populated", side_effect=OperationUnavailable("missing events")):
            self.assertEqual(self.controller.status(identity)["status"], "unknown")
            self.assertEqual(self.controller.stop(identity)["status"], "unknown")
        self.assertEqual(self.manager.kill_calls, [])
        self.assertEqual(self.manager.stop_calls, [])

    def test_unexpected_release_marker_is_unknown_and_not_replaced(self):
        identity = self.controller.prepare(self.request())
        release_path = self.operations / hashlib.sha256(identity["operation_id"].encode()).hexdigest() / "release"
        release_path.write_text("f" * 32 + "\n", encoding="ascii")
        release_path.chmod(0o644)

        self.assertEqual(self.controller.status(identity)["status"], "unknown")
        self.assertEqual(self.controller.release(identity)["status"], "unknown")
        self.assertEqual(release_path.read_text(encoding="ascii"), "f" * 32 + "\n")

    def test_request_rejects_environment_and_noncanonical_or_escaping_workspaces(self):
        with self.assertRaises(OperationValidationError):
            self.controller.prepare({**self.request(), "env": {"GH_TOKEN": "secret"}})
        with self.assertRaises(OperationValidationError):
            self.controller.prepare({**self.request(), "workspace": str(self.workspaces)})
        outside = self.root / "outside"
        outside.mkdir()
        with self.assertRaises(OperationValidationError):
            self.controller.prepare({**self.request(), "workspace": str(outside)})

    def test_capability_does_not_claim_fake_manager_containment(self):
        capabilities = self.controller.capabilities()
        self.assertEqual(capabilities["protocol_version"], 1)
        self.assertFalse(capabilities["contained"])
        self.assertFalse(capabilities["released_cgroup_proof"])
        self.assertEqual(capabilities["systemd_version"], 254)
        self.assertIsInstance(capabilities["worker_account_isolated"], bool)
        self.assertEqual(capabilities["machine_id"], "b" * 32)
        self.assertEqual(capabilities["boot_id"], "1" * 32)

    def test_worker_account_requires_private_primary_group_and_no_extra_groups(self):
        account = SimpleNamespace(pw_name=self.user, pw_uid=1001, pw_gid=1002, pw_dir=str(self.home))
        group = SimpleNamespace(gr_name=self.group, gr_gid=1002, gr_mem=[])
        with (
            patch("pwd.getpwnam", return_value=account),
            patch("grp.getgrnam", return_value=group),
            patch("os.getgrouplist", return_value=[1002]),
            patch("pwd.getpwall", return_value=[account]),
        ):
            self.assertTrue(self.controller._worker_account_isolated())

        with (
            patch("pwd.getpwnam", return_value=account),
            patch("grp.getgrnam", return_value=group),
            patch("os.getgrouplist", return_value=[1002, 42]),
            patch("pwd.getpwall", return_value=[account]),
        ):
            self.assertFalse(self.controller._worker_account_isolated())


class SystemdManagerCommandTests(unittest.TestCase):
    def test_uses_systemd_pipe_wait_and_claims_raw_stream_once(self):
        manager = SystemdManager()
        fake_process = object()
        unit = "factory-operation-" + "a" * 64 + ".service"
        properties = {
            "Type": "exec",
            "RemainAfterExit": "yes",
            "CapabilityBoundingSet": "",
            "SupplementaryGroups": "",
            "ReadWritePaths": ["/srv/factory/workspaces/run 1"],
            "Environment": ["HOME=/home/factory-worker", "PATH=/usr/bin:/bin"],
        }
        with (
            patch("factory.deploy.worker_operation.os.geteuid", return_value=0),
            patch("factory.deploy.worker_operation._assert_trusted_executable"),
            patch("factory.deploy.worker_operation.subprocess.Popen", return_value=fake_process) as popen,
        ):
            manager.start(unit, "/trusted/wrapper", "/run/factory-op/manifest.json", properties)

        arguments, options = popen.call_args
        command = arguments[0]
        self.assertIn("--quiet", command)
        self.assertIn("--pipe", command)
        self.assertIn("--wait", command)
        self.assertIn("--expand-environment=no", command)
        self.assertNotIn("--no-block", command)
        self.assertIn("--unit=" + unit, command)
        self.assertIn("--property=ReadWritePaths=/srv/factory/workspaces/run\\x201", command)
        self.assertIn("--property=CapabilityBoundingSet=", command)
        self.assertLess(command.index("--"), command.index("/trusted/wrapper"))
        self.assertEqual(options["stdin"], subprocess.PIPE)
        self.assertEqual(options["stdout"], subprocess.PIPE)
        self.assertEqual(options["stderr"], subprocess.STDOUT)
        self.assertNotIn("OPENAI_API_KEY", options["env"])
        self.assertIs(manager.claim_stream(unit), fake_process)
        with self.assertRaises(OperationUnavailable):
            manager.claim_stream(unit)

    def test_inspect_normalizes_systemd_waitid_codes(self):
        manager = SystemdManager()
        unit = "factory-operation-" + "a" * 64 + ".service"
        output = "\n".join(
            (
                "LoadState=loaded",
                "InvocationID=" + "b" * 32,
                "ControlGroup=/system.slice/" + unit,
                "ActiveState=active",
                "SubState=exited",
                "Result=success",
                "ExecMainCode=1",
                "ExecMainStatus=0",
                "MainPID=0",
                "User=factory-worker",
                "Group=factory-worker",
                "SyslogIdentifier=factory-operation-" + "c" * 32,
                "SupplementaryGroups=",
            )
        )
        completed = subprocess.CompletedProcess([], 0, stdout=output.encode(), stderr=b"")
        with (
            patch("factory.deploy.worker_operation._assert_trusted_executable"),
            patch("factory.deploy.worker_operation.subprocess.run", return_value=completed),
        ):
            snapshot = manager.inspect(unit)

        self.assertEqual(snapshot.exec_main_code, "exited")
        self.assertEqual(snapshot.exec_main_status, 0)
        self.assertEqual(snapshot.supplementary_groups, "")

    def test_capabilities_parse_dotted_systemctl_version_and_require_cli_match(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run_path = root / "systemd-run"
            ctl_path = root / "systemctl"
            control_socket = root / "control.sock"
            cgroup_root = root / "cgroup"
            cgroup_root.mkdir()
            (cgroup_root / "cgroup.controllers").write_text("cpu\n", encoding="ascii")
            for path in (run_path, ctl_path):
                path.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
                path.chmod(0o755)
            control_socket.touch()

            def completed(stdout):
                return subprocess.CompletedProcess([], 0, stdout=stdout, stderr=b"")

            manager = SystemdManager(
                systemd_run_path=str(run_path),
                systemctl_path=str(ctl_path),
                cgroup_root=str(cgroup_root),
                control_socket_path=str(control_socket),
            )
            with (
                patch("factory.deploy.worker_operation.os.geteuid", return_value=0),
                patch("factory.deploy.worker_operation._assert_trusted_executable"),
                patch("factory.deploy.worker_operation.os.path.exists", return_value=True),
                patch.object(manager, "_detect_container", return_value=False),
                patch(
                    "factory.deploy.worker_operation.subprocess.run",
                    side_effect=[completed(b"systemd 255 (255.4)\n"), completed(b"255.4-1ubuntu8.5\n")],
                ),
            ):
                facts = manager.capabilities()

            self.assertTrue(facts["contained"])
            self.assertTrue(facts["released_cgroup_proof"])
            self.assertEqual(facts["systemd_version"], 255)

            mismatched = SystemdManager(
                systemd_run_path=str(run_path),
                systemctl_path=str(ctl_path),
                cgroup_root=str(cgroup_root),
                control_socket_path=str(control_socket),
            )
            with (
                patch("factory.deploy.worker_operation.os.geteuid", return_value=0),
                patch("factory.deploy.worker_operation._assert_trusted_executable"),
                patch("factory.deploy.worker_operation.os.path.exists", return_value=True),
                patch.object(mismatched, "_detect_container", return_value=False),
                patch(
                    "factory.deploy.worker_operation.subprocess.run",
                    side_effect=[completed(b"systemd 255 (255.4)\n"), completed(b"256.1\n")],
                ),
            ):
                facts = mismatched.capabilities()

            self.assertFalse(facts["system_manager"])
            self.assertFalse(facts["contained"])


if __name__ == "__main__":
    unittest.main()
