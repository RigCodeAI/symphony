#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
  printf 'Usage: %s --revision <40-hex> --run-id <id> --case <pass|fail> --expected-sha256 <64-hex> --worker-name <name> --worker-ip <ip> --initiator-host <name>\n' "${0##*/}" >&2
}

fail() {
  printf 'worker pilot failed: %s\n' "$*" >&2
  exit 1
}

revision=""
run_id=""
case_name=""
expected_sha=""
worker_name=""
worker_ip=""
initiator_host=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --revision) [[ "$#" -ge 2 ]] || { usage; exit 2; }; revision="$2"; shift 2 ;;
    --run-id) [[ "$#" -ge 2 ]] || { usage; exit 2; }; run_id="$2"; shift 2 ;;
    --case) [[ "$#" -ge 2 ]] || { usage; exit 2; }; case_name="$2"; shift 2 ;;
    --expected-sha256) [[ "$#" -ge 2 ]] || { usage; exit 2; }; expected_sha="$2"; shift 2 ;;
    --worker-name) [[ "$#" -ge 2 ]] || { usage; exit 2; }; worker_name="$2"; shift 2 ;;
    --worker-ip) [[ "$#" -ge 2 ]] || { usage; exit 2; }; worker_ip="$2"; shift 2 ;;
    --initiator-host) [[ "$#" -ge 2 ]] || { usage; exit 2; }; initiator_host="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "release revision is invalid"
[[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || fail "expected release SHA is invalid"
[[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || fail "run id is invalid"
[[ "$case_name" == pass || "$case_name" == fail ]] || fail "case must be pass or fail"
[[ "$worker_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || fail "worker name is invalid"
[[ "$initiator_host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$ ]] || fail "initiator host is invalid"
[[ "$(id -un)" == factory-worker ]] || fail "must run as factory-worker"

script_path="$(realpath -e -- "${BASH_SOURCE[0]}")" || fail "worker runner path is unavailable"
script_dir="$(cd -P -- "$(dirname -- "$script_path")" >/dev/null 2>&1 && pwd)"
# shellcheck source=factory/deploy/lib.sh
source "$script_dir/lib.sh"

readonly factory_root="/opt/factory"
readonly data_root="/srv/factory"
readonly public_config="/etc/factory/public.json"
release_dir="$(realpath -e -- "$factory_root/releases/$revision")" || fail "pinned release directory is missing"
readonly release_dir
readonly workspaces="$data_root/workspaces"
readonly runs="$data_root/runs"
readonly seed="$data_root/seed"

releases_real="$(realpath -e -- "$factory_root/releases")" || fail "release directory cannot be resolved"
[[ -d "$release_dir" && "$release_dir" == "$releases_real/"* ]] || fail "pinned release is outside the releases directory"
[[ "$(factory_release_revision "$release_dir")" == "$revision" ]] || fail "pinned release manifest does not match"
actual_sha="$(factory_release_sha256 "$release_dir")" || fail "pinned release SHA is invalid"
[[ "$actual_sha" == "$expected_sha" ]] || fail "worker and coordinator release SHA differ"
[[ -f "$public_config" && ! -L "$public_config" ]] || fail "public worker config is missing"

python3 - "$public_config" "$revision" "$expected_sha" "$worker_name" "$worker_ip" <<'PY' || fail "worker public configuration does not match this submission"
import ipaddress
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    config = json.load(source)
if config.get("role") != "worker":
    raise SystemExit(1)
if config.get("service_revision") != sys.argv[2] or config.get("release_sha256") != sys.argv[3]:
    raise SystemExit(1)
try:
    parsed_expected = ipaddress.ip_address(sys.argv[5])
except ValueError:
    raise SystemExit(1)
if not isinstance(parsed_expected, ipaddress.IPv4Address) or not parsed_expected.is_private:
    raise SystemExit(1)
expected_ip = str(parsed_expected)
matches = [host for host in config.get("worker_hosts", []) if host.get("name") == sys.argv[4]]
if len(matches) != 1:
    raise SystemExit(1)
try:
    parsed_actual = ipaddress.ip_address(matches[0].get("ip", ""))
except ValueError:
    raise SystemExit(1)
if not isinstance(parsed_actual, ipaddress.IPv4Address) or not parsed_actual.is_private:
    raise SystemExit(1)
actual_ip = str(parsed_actual)
if expected_ip != actual_ip:
    raise SystemExit(1)
PY

active_before="$(factory_active_release "$factory_root")" || fail "worker has no active release"
[[ "$active_before" == "$release_dir" ]] || fail "worker active release does not match the pinned submission"
[[ "$(factory_release_sha256 "$active_before")" == "$expected_sha" ]] || fail "worker active release SHA differs"
[[ -d "$seed" && ! -L "$seed" ]] || fail "worker seed clone is missing"
[[ -d "$workspaces" && -d "$runs" ]] || fail "worker data directories are missing"
[[ "$(stat -c %u -- "$seed")" == 0 && "$(stat -c %u -- "$seed/.git")" == 0 ]] || \
  fail "worker seed must be root-owned"
[[ -d "$seed/.git" && ! -L "$seed/.git" ]] || fail "worker seed metadata is unsafe"
seed_mode="$(stat -c %a -- "$seed")"
git_mode="$(stat -c %a -- "$seed/.git")"
(( (8#$seed_mode & 022) == 0 && (8#$git_mode & 022) == 0 )) || fail "worker seed must be read-only to service users"
[[ -f "$seed.REVISION" && ! -L "$seed.REVISION" && "$(stat -c %u -- "$seed.REVISION")" == 0 && \
   "$(stat -c %a -- "$seed.REVISION")" == 644 ]] || fail "root-owned seed revision marker is missing"
seed_revision="$(tr -d '[:space:]' <"$seed.REVISION")"
[[ "$seed_revision" =~ ^[0-9a-f]{40}$ ]] || fail "seed revision marker is invalid"

# The user account can hold only one active pilot, even when requests arrive
# from separate coordinator processes.
lock_file="$workspaces/.factory-pilot.lock"
exec 9>"$lock_file"
if ! flock -n 9; then
  fail "worker already has an active pilot"
fi

workspace="$workspaces/$run_id"
run_dir="$runs/$run_id"
[[ ! -e "$workspace" && ! -L "$workspace" ]] || fail "workspace for this run id already exists"
[[ ! -e "$run_dir" && ! -L "$run_dir" ]] || fail "evidence for this run id already exists"
mkdir -m 0700 -- "$run_dir"

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
seed_commit="$(git -C "$seed" rev-parse HEAD 2>/dev/null)" || fail "worker seed is not a Git checkout"
[[ "$seed_commit" == "$seed_revision" ]] || fail "worker seed HEAD differs from its root-owned revision marker"
git clone --no-local --no-checkout --quiet -- "$seed" "$workspace" || fail "fresh workspace clone failed"
git -C "$workspace" checkout --detach "$seed_commit" >/dev/null 2>&1 || fail "fresh workspace could not be pinned to the seed commit"
[[ "$(git -C "$workspace" rev-parse HEAD)" == "$seed_commit" ]] || fail "fresh workspace commit differs from the seed"

# Replace all remotes with inert values. The inherited seed URL cannot carry a
# credential into the workspace and every normal push route is disabled.
git -C "$workspace" remote set-url origin DISABLED || fail "could not remove the seed fetch URL"
git -C "$workspace" remote set-url --push origin DISABLED || fail "could not disable the workspace push URL"
git -C "$workspace" config --local push.default nothing
git -C "$workspace" config --local --unset-all credential.helper 2>/dev/null || true
[[ "$(git -C "$workspace" remote get-url origin)" == DISABLED ]] || fail "workspace fetch URL was not cleared"
[[ "$(git -C "$workspace" remote get-url --push origin)" == DISABLED ]] || fail "workspace push URL was not disabled"

raw_dir=""
cleanup() {
  if [[ -n "$raw_dir" && -d "$raw_dir" ]]; then
    rm -rf -- "$raw_dir"
  fi
}
trap cleanup EXIT

factory_load_runtime_env "$release_dir" worker || fail "worker runtime environment is unavailable"
for credential_name in OPENAI_API_KEY CODEX_API_KEY CODEX_ACCESS_TOKEN; do
  if [[ -n "${!credential_name:-}" ]]; then
    fail "API credential environment variables must be unset for subscription sign-in"
  fi
done

raw_dir="$(mktemp -d "$TMPDIR/factory-pilot-${run_id}.XXXXXX")" || fail "private task staging directory could not be created"
chmod 0700 "$raw_dir"

input_file="$release_dir/factory/examples/$case_name.json"
definition="$release_dir/factory/workstreams/local-rig.yaml"
[[ -f "$input_file" && -f "$definition" ]] || fail "pinned workstream inputs are missing"
cd -- "$release_dir/elixir"

runner_exit=127
if timeout --signal=TERM --kill-after=10s 3600s \
  factory_mix workstream.run "$definition" \
    --inputs "$input_file" \
    --workspace "$workspace" \
    --workspace-root "$workspaces" \
    >"$raw_dir/runner.stdout" 2>"$raw_dir/runner.stderr"; then
  runner_exit=0
else
  runner_exit=$?
fi

python3 "$release_dir/factory/deploy/sanitize.py" report \
  "$raw_dir/runner.stdout" "$runner_exit" "$raw_dir/report.json" || {
    printf '{"report_parse_error":true,"runner_exit_status":%s,"status":"runner-error"}\n' \
      "$runner_exit" >"$raw_dir/report.json"
  }

diff_status=0
if git -C "$workspace" add -N -- . >"$raw_dir/diff-command.log" 2>&1 && \
   git -C "$workspace" diff --binary --no-ext-diff --no-renames HEAD >"$raw_dir/candidate.diff" 2>>"$raw_dir/diff-command.log"; then
  :
else
  diff_status=$?
  : >"$raw_dir/candidate.diff"
fi
python3 - "$raw_dir/mix.log" "$raw_dir/runner.stderr" \
  "$raw_dir/runner.stdout" "$raw_dir/diff-command.log" <<'PY'
from pathlib import Path
import sys

output = Path(sys.argv[1])
limit = 10 * 1024 * 1024
marker = b"\n[remaining output truncated by factory-pilot]\n"
remaining = limit - len(marker)
with output.open("wb") as target:
    for label, filename in zip((b"[runner stderr]\n", b"[runner stdout]\n", b"[diff collection]\n"), sys.argv[2:]):
        if remaining <= 0:
            break
        target.write(label)
        remaining -= len(label)
        with open(filename, "rb") as source:
            while remaining > 0:
                chunk = source.read(min(64 * 1024, remaining))
                if not chunk:
                    break
                target.write(chunk)
                remaining -= len(chunk)
            if source.read(1):
                target.write(marker)
                break
    if output.stat().st_size >= limit - len(marker) and output.stat().st_size < limit:
        target.write(marker)
PY
python3 "$release_dir/factory/deploy/sanitize.py" text \
  "$raw_dir/mix.log" "$raw_dir/mix.log.safe" 10485760 || fail "mix log sanitization failed"
python3 "$release_dir/factory/deploy/sanitize.py" text \
  "$raw_dir/candidate.diff" "$raw_dir/candidate.diff.safe" 10485760 || fail "candidate diff sanitization failed"

active_after=""
active_changed=false
if active_after="$(factory_active_release "$factory_root" 2>/dev/null)"; then
  after_sha="$(factory_release_sha256 "$active_after" 2>/dev/null || true)"
  if [[ "$active_after" != "$release_dir" || "$after_sha" != "$expected_sha" ]]; then
    active_changed=true
  fi
else
  active_changed=true
fi

python3 - "$raw_dir/report.json" "$raw_dir/revision.json" \
  "$revision" "$expected_sha" "$run_id" "$case_name" "$worker_name" "$worker_ip" \
  "$initiator_host" "$seed_commit" "$started_at" "$runner_exit" "$diff_status" \
  "$active_changed" "$active_before" "$active_after" <<'PY'
import json
import sys
from datetime import datetime, timezone

with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
expected = "complete" if sys.argv[6] == "pass" else "blocked"
expected_exit = 0 if sys.argv[6] == "pass" else None
report_status = report.get("status", "runner-error")
runner_exit = int(sys.argv[12])
active_changed = sys.argv[14] == "true"
attempts = report.get("attempts", [])
agent_status = None
gate_exit = None
gate_timed_out = None
gate_ok = False
if isinstance(attempts, list) and len(attempts) == 2:
    agent, gate = attempts
    agent_result = agent.get("result", {}) if isinstance(agent, dict) else {}
    gate_result = gate.get("result", {}) if isinstance(gate, dict) else {}
    gate_evidence = gate_result.get("evidence", {}) if isinstance(gate_result, dict) else {}
    agent_status = agent_result.get("status")
    gate_exit = gate_evidence.get("exit_status")
    gate_timed_out = gate_evidence.get("timed_out")
    expected_gate_exit = gate_exit == 0 if sys.argv[6] == "pass" else isinstance(gate_exit, int) and gate_exit != 0
    gate_ok = isinstance(agent, dict) and isinstance(gate, dict) and (
        agent.get("type") == "agent" and agent.get("stage") == "implement" and
        agent_status == "ok" and gate.get("type") == "check" and
        gate.get("stage") == "validate" and gate_result.get("status") == "ok" and
        expected_gate_exit and gate_timed_out is False
    )
pilot_ok = report_status == expected and gate_ok and (expected_exit is None or runner_exit == expected_exit)
if sys.argv[6] == "fail" and runner_exit == 0:
    pilot_ok = False
if active_changed or int(sys.argv[13]) != 0:
    pilot_ok = False
payload = {
    "version": 1,
    "run_id": sys.argv[5],
    "case": sys.argv[6],
    "service_revision": sys.argv[3],
    "release_sha256": sys.argv[4],
    "workspace_commit": sys.argv[10],
    "worker_name": sys.argv[7],
    "worker_ip": sys.argv[8],
    "initiated_by": "factory-pilot",
    "initiator_role": "coordinator",
    "initiator_host": sys.argv[9],
    "transport": "openssh-private-config",
    "workstream_status": report_status,
    "expected_workstream_status": expected,
    "agent_stage_status": agent_status,
    "gate_exit_status": gate_exit,
    "gate_timed_out": gate_timed_out,
    "gate_stage_result": "passed" if gate_ok else "failed",
    "runner_exit_status": runner_exit,
    "diff_exit_status": int(sys.argv[13]),
    "active_release_before": sys.argv[15],
    "active_release_after": sys.argv[16],
    "active_release_changed": active_changed,
    "pilot_result": "passed" if pilot_ok else "failed",
    "started_at": sys.argv[11],
    "finished_at": datetime.now(timezone.utc).isoformat(),
}
with open(sys.argv[2], "w", encoding="utf-8") as target:
    json.dump(payload, target, sort_keys=True, indent=2)
    target.write("\n")
PY

pilot_result="$(python3 - "$raw_dir/revision.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    print(json.load(source)["pilot_result"])
PY
)"

python3 - "$script_dir/cloud_io.py" "$raw_dir" "$run_dir" <<'PY' || fail "evidence redaction failed"
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys

helper = Path(sys.argv[1])
raw_dir, run_dir = Path(sys.argv[2]), Path(sys.argv[3])
spec = importlib.util.spec_from_file_location("factory_cloud_io", helper)
if spec is None or spec.loader is None:
    raise SystemExit("redaction helper unavailable")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
values = module.credential_values()
limits = {"report.json": 2 * 1024 * 1024, "mix.log.safe": 10 * 1024 * 1024,
          "candidate.diff.safe": 10 * 1024 * 1024, "revision.json": 256 * 1024}
renamed = {"mix.log.safe": "mix.log", "candidate.diff.safe": "candidate.diff"}
for name, limit in limits.items():
    source = raw_dir / name
    if not source.is_file() or source.is_symlink() or source.stat().st_size > limit:
        raise SystemExit("evidence artifact is missing, unsafe or too large")
    data = module.redact(source.read_bytes(), values)
    target_name = renamed.get(name, name)
    target = run_dir / target_name
    temporary = run_dir / (name + ".tmp")
    with temporary.open("xb") as output:
        os.chmod(temporary, 0o600)
        output.write(data)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, target)

artifacts = {}
for name in limits:
    target_name = renamed.get(name, name)
    data = (run_dir / target_name).read_bytes()
    artifacts[target_name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
finished = {"version": 1, "run_id": run_dir.name, "status": "finished", "artifacts": artifacts}
target = run_dir / "finished.json"
temporary = run_dir / "finished.json.tmp"
with temporary.open("x", encoding="utf-8") as output:
    os.chmod(temporary, 0o600)
    json.dump(finished, output, sort_keys=True, indent=2)
    output.write("\n")
    output.flush()
    os.fsync(output.fileno())
os.replace(temporary, target)
PY

if [[ "$active_changed" == true ]]; then
  fail "worker active release changed during the run; sanitized evidence was retained"
fi
if [[ "$pilot_result" != passed ]]; then
  fail "workstream did not meet the expected $case_name outcome; sanitized evidence was retained"
fi
printf 'Pilot %s completed with workstream status %s.\n' "$run_id" \
  "$(python3 - "$run_dir/revision.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    print(json.load(source)["workstream_status"])
PY
)"
