# Local workstreams

DEV-229 adds a synchronous local agent → executable-check entry point. It does
not start tracker polling or a second scheduler. Existing `WORKFLOW.md` deployments
and the existing `bin/symphony` entry point keep their behavior.

Start with [AGENTS.md](../AGENTS.md) for ownership and
[elixir/README.md](../elixir/README.md) for the service toolchain. The checked-in
[local definition](../factory/workstreams/local-rig.yaml) uses
[local-worker](../factory/agents/local-worker.yaml). That agent and
[local-repair](../factory/agents/local-repair.yaml) reference the same
[SKILL.md](../factory/skills/local-rig/SKILL.md); no skill copy is made.

## Prepare a Linux worker

Use a disposable Debian/Ubuntu worker with Git read access to `RigCodeAI/rig`.
The bootstrap installs system build dependencies, Rust from Rig's toolchain,
Node `24.19.0`, and Codex CLI `0.159.2`. It clones the pinned Rig revision
`39d6d5d998366bf13af19eb74ae47d598ecf92bd` into a new directory. Run one heavy
build at a time. Do not use an existing Rig or Symphony checkout as the workspace.

```bash
bash factory/scripts/bootstrap-linux.sh /home/worker/workspaces/rig-pass
# Add the PATH entries printed by bootstrap, in this shell.
export CARGO_BUILD_JOBS=3
codex login
codex login status  # must report ChatGPT
git -C /home/worker/workspaces/rig-pass remote set-url --push origin DISABLED
```

Use subscription sign-in. Remove temporary Git clone credentials before running
the agent. Do not set `OPENAI_API_KEY`, `CODEX_API_KEY`, or `CODEX_ACCESS_TOKEN`;
the local runner rejects those environment credentials and its default Codex
command requires ChatGPT login. Neither this command nor its definition enables
Daybreak. The ordinary pilot model is `gpt-6-luna` with `medium` effort; desktop
development-agent settings do not choose factory runtime settings.

On a Linux container, Codex's sandbox needs user, mount, and PID namespaces,
including a private proc mount. Verify this as the worker user:

```bash
unshare -Urmpf sh -c 'mount --make-rslave /; mount -t proc proc /proc'
```

A container runtime that prohibits this must allow the sandbox before running
the demo. The qualified disposable Docker worker used `--cap-add SYS_ADMIN`,
`--security-opt seccomp=unconfined`, `--security-opt apparmor=unconfined`, and
`--security-opt systempaths=unconfined`. These are temporary worker permissions;
the agent still runs with the checked-in `workspace-write` policy. See the
[qualification record](dev-229-evidence.md) for the exact environment and results.

Set up the Symphony toolchain separately, following `elixir/README.md`:

```bash
cd elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
```

## Validate and run

From `elixir/`, validate all references, inputs, transitions, and repair bounds
without dispatching an agent:

```bash
mise exec -- mix workstream.run ../factory/workstreams/local-rig.yaml \
  --inputs ../factory/examples/pass.json --validate-only
```

Run the same definition in a dedicated clone:

```bash
mise exec -- mix workstream.run ../factory/workstreams/local-rig.yaml \
  --inputs ../factory/examples/pass.json \
  --workspace /home/worker/workspaces/rig-pass \
  --workspace-root /home/worker/workspaces
```

The agent adds one Unix symlink regression test. The gate runs the exact test
with `/usr/bin/time -v` and rejects a zero-test result. A successful run reports
`"status": "complete"`, the app-server session/model, definition digests, gate
exit status, output, elapsed time, and maximum resident set size. No commit,
push, PR, or merge is needed. A normal completed agent turn alone cannot pass
the executable gate.

For the failing demonstration, create another fresh clone before modifying
the passing one, or rerun bootstrap into a new directory:

```bash
# After clone, remove its publication route too.
git -C /home/worker/workspaces/rig-fail remote set-url --push origin DISABLED
mise exec -- mix workstream.run ../factory/workstreams/local-rig.yaml \
  --inputs ../factory/examples/fail.json \
  --workspace /home/worker/workspaces/rig-fail \
  --workspace-root /home/worker/workspaces
```

The failing task intentionally expects symlink installation to succeed. Cargo
prints the assertion failure; the report says `"status": "blocked"`, and Mix
exits nonzero. Retain the report and diff outside the workspace, then delete only
these disposable clones. Do not push either Rig candidate.

## Version 1 contract

Only `agent` and `check` stages are supported. All fields shown in the sample
are required; unknown keys, unsupported versions/settings, missing files,
duplicate names/outputs, invalid transitions, unavailable inputs, unreachable
stages, and unbounded cycles reject before dispatch. Input JSON has exactly the
declared string keys. Inputs must contain task data, never credentials.

Agent YAML contains `version`, `name`, `model`, `reasoning_effort`, `daybreak`,
`approval_policy`, `sandbox`, `instructions`, and `skills`. Version 1 requires
`daybreak: false`, `approval_policy: never`, and `sandbox: workspace-write`.
Instruction and `SKILL.md` references are relative to the agent file; agent
references are relative to the workstream file. The loader canonicalizes paths
and pins source text and SHA-256 hashes once per invocation. Agents receive the
pinned instruction/skill text. Changes on disk affect the next run.

Stages declare named `inputs` and `outputs`. Agent outputs carry the session,
model/settings and workspace identity. Checks receive their declared input
metadata in `WORKSTREAM_INPUTS_JSON` and inspect the shared workspace. Check
outputs contain the service-observed exit status and bounded output, not an
agent's opinion. The same evidence is assigned to each output name of a stage.

An agent's `next` names a stage. A check has an inline `gate` with an argv
`command`, positive `timeout_ms`, `success` (stage ID or `complete`), and
`failure` (`blocked` or a bounded repair edge). Command arrays execute literally;
an explicit shell in the array is ordinary executable code, not a gate
expression language. A repair edge must return to a preceding agent:

```yaml
failure:
  repair: implement
  max_attempts: 2
```

This allows two additional repair dispatches, after the initial failure. The
service retains the counter for the invocation and supplies the failed gate's
redacted output to the repair turn. Exhausting the budget blocks. These counters
are in memory; durable restart and human waits belong to DEV-232.

GNU `timeout` bounds executable checks and terminates their process group.
Reports cap output at 64 KiB, mark truncation, remove known credential values
and common token formats, and exclude raw app-server payloads and the initial
input map from report fields. Gate output can still contain what a check prints.
Checks receive an environment allowlist. This local same-user runner is for
trusted smoke code; it is not the isolated trusted candidate evaluator required
by DEV-236. Do not expose publisher credentials or production secrets to this
worker. Workspace separation alone is not a security boundary.

## Service verification

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/workstream_test.exs \
  test/symphony_elixir/workstream_runner_test.exs \
  test/symphony_elixir/app_server_options_test.exs \
  test/mix/tasks/workstream_run_test.exs
mise exec -- make all
```

Contract fixtures and fake app-server tests do not prove a real model turn or
Rig build. The live evidence and measurements are recorded separately. Measurements
are a first focused-crate baseline, not a full Rig package build or a concurrency
guarantee. Production packaging still requires Rig's native semantic artifact
workflow and the relevant checks for the actual change.
