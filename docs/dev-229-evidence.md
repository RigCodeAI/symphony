# DEV-229 local qualification

Qualification date: 2026-10-09. This is a local Linux smoke result, not a cloud
rollout, full Rig build, trusted candidate receipt, or concurrency guarantee.
The [short entry point](local-workstreams.md) contains the repeatable commands.

## Acceptance evidence

| Requirement | Observed evidence |
| --- | --- |
| Fresh worker and dedicated Rig clone | The bootstrap installed the pinned tools and cloned Rig at `39d6d5d998366bf13af19eb74ae47d598ecf92bd` outside Symphony. |
| Real subscription agent turn and small change | `codex login status` reported `Logged in using ChatGPT`. App-server returned `gpt-6-luna`; both turns requested medium effort. The passing candidate added a Unix configuration-file symlink regression. |
| Passing gate advances | [Pass report](../factory/evidence/dev-229/pass.json): one test passed, Cargo exit 0, workstream `complete`. [Candidate diff](../factory/evidence/dev-229/pass.diff). |
| Failing gate prevents advancement | [Fail report](../factory/evidence/dev-229/fail.json): the intentionally wrong assertion failed, Cargo exit 101, workstream `blocked`, Mix exit 1. [Candidate diff](../factory/evidence/dev-229/fail.diff). |
| Same local definition | Both reports pin identical hashes for the workstream, two agent definitions, instructions, and shared skill. Only task inputs and disposable clone paths differ. |
| Reject before dispatch | Loader tests cover missing references/inputs, unknown fields, unsupported settings, invalid transitions, unavailable outputs, cycles, and bounded repair limits. |
| Shared skill | `local-worker.yaml` and `local-repair.yaml` resolve the same `factory/skills/local-rig/SKILL.md` path and hash. |
| Workspace and publication safeguards | Runner rejects the source checkout, definition overlap, root equality, symlink escape, and linked worktrees. Both Rig clones had push URL `DISABLED`; neither was committed or published. |
| Existing deployments | Existing workflow/app-server tests run in the full suite; the local entry point avoids tracker startup and preserves default app-server settings. |

## Worker and tools

The fresh Debian worker used the official `elixir:1.19.5-otp-28` image, digest
`sha256:d170fadffd75b36146ff40b6e8d5cc881c59d136ae5a2c34a1b394ec33b6cffa`,
on Linux aarch64. The bootstrap ran as user `worker`, using sudo for apt packages.
The disposable Docker smoke worker ran as root with three CPUs and a 12 GiB
container memory limit. Its creation options were:

```bash
docker run -d --name dev229-live \
  --cap-add SYS_ADMIN \
  --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined \
  --security-opt systempaths=unconfined \
  --cpus 3 --memory 12g dev229-linux-tools:clean sleep infinity
```

`dev229-linux-tools:clean` was a local snapshot of that image after the bootstrap,
not a published worker image. The options permit Codex's user/mount/PID namespace
sandbox. The following probe succeeded before the real turns:

```bash
unshare -Urmpf sh -c 'mount --make-rslave /; mount -t proc proc /proc'
```

| Tool | Observed version |
| --- | --- |
| Rust | `rustc 1.91.1 (ed61e7d7e 2025-11-07)` |
| Cargo | `cargo 1.91.1 (ea2d97820 2025-10-10)` |
| Python | `3.13.5` |
| Node | `24.19.0` (explicit tool PATH) |
| Codex CLI | `0.159.2` |
| Elixir | `1.19.5` |
| Erlang | OTP `28`, ERTS `16.4.0.6` |
| mise | `2026.10.4` |

Bootstrap command, run with temporary read-only Git credentials available to Git:

```bash
bash factory/scripts/bootstrap-linux.sh /home/worker/workspaces/rig-pass
```

The executed bootstrap SHA-256 was
`b63585f43ec016b4a893a2d5541c3688e2c0c2309389fac5d4005156c98fea34`,
matching the checked-in script. The second clone was copied from the clean pinned
clone before either agent edited it:

```bash
git clone --no-hardlinks /home/worker/workspaces/rig-pass \
  /home/worker/workspaces/rig-fail
git -C /home/worker/workspaces/rig-pass remote set-url --push origin DISABLED
git -C /home/worker/workspaces/rig-fail remote set-url --push origin DISABLED
```

The worker reused the signed-in ChatGPT session through a temporary local auth
file. No API key was used. Git clone credentials were removed before dispatch.
Reports retain only session/model metadata and redacted gate output, not auth
files, prompts, or raw app-server traffic.

## Exact run and test commands

The service source was copied explicitly into `/service` using `docker cp`,
compiled there, and compared with the host files. Colima bind mounts served
stale source during initial investigation; results from those stale copies are
excluded from this qualification.

From `/service/elixir`, with the bootstrap's PATH entries and Rust homes:

```bash
export PATH=/home/worker/.cargo/bin:/home/worker/.local/share/rig-tools/node-v24.19.0-linux-arm64/bin:/home/worker/.local/share/rig-tools/codex/bin:/usr/local/bin:/usr/bin:/bin
export CARGO_HOME=/home/worker/.cargo
export RUSTUP_HOME=/home/worker/.rustup
export CARGO_BUILD_JOBS=3

mise exec -- mix workstream.run ../factory/workstreams/local-rig.yaml \
  --inputs ../factory/examples/pass.json --validate-only
MIX_ENV=test mise exec -- mix workstream.run ../factory/workstreams/local-rig.yaml \
  --inputs ../factory/examples/pass.json \
  --workspace /home/worker/workspaces/rig-pass \
  --workspace-root /home/worker/workspaces
MIX_ENV=test mise exec -- mix workstream.run ../factory/workstreams/local-rig.yaml \
  --inputs ../factory/examples/fail.json \
  --workspace /home/worker/workspaces/rig-fail \
  --workspace-root /home/worker/workspaces

mise exec -- mix test test/symphony_elixir/workstream_test.exs \
  test/symphony_elixir/workstream_runner_test.exs \
  test/symphony_elixir/app_server_options_test.exs \
  test/mix/tasks/workstream_run_test.exs
mise exec -- make all
bash -n ../factory/scripts/bootstrap-linux.sh
```

The gate itself executes the following exact regression filter and additionally
requires `running 1 test` in Cargo output:

```bash
/usr/bin/time -v cargo test --locked -p sivere-agent-hooks --lib \
  agent::tests::agent_hook_refuses_a_configuration_file_symlink -- --exact
```

## Initial focused-build measurements

Both measurements started after removing each disposable clone's `target`
directory. Toolchains and downloaded Cargo dependencies were cached. Builds
ran sequentially with `CARGO_BUILD_JOBS=3`.

| Run | Agent duration | Gate duration | Cargo wall time | Peak RSS (KiB) | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| Passing regression | 19.018 s | 1.369 s | 1.35 s | 270460 | 1 passed |
| Intentionally failing regression | 20.739 s | 1.396 s | 1.38 s | 270112 | 1 failed |

GNU time's RSS measurement covers the Cargo command and its descendants; it
is not total worker or model memory. These numbers establish only a small
focused-crate baseline.

## Development checks and review

The final `mise exec -- make all` passed in the exact Linux source snapshot:
345 tests, zero failures, six opt-in skips, 100% coverage, strict format/lint,
and zero Dialyzer warnings. [Full gate log](../factory/evidence/dev-229/make-all.log).
The [source manifest](../factory/evidence/dev-229/source.sha256.json) identifies
all 17 implementation and definition files compared byte-for-byte with the host.
Dependency fetching reported advisories for existing locked dependencies; the
lockfile was unchanged and those advisories did not fail the gate.

The independent
GPT-6 Luna/max review checked schema safety, scoped app-server settings,
credential filtering, repair feedback, and adjacent process lifecycle behavior.
Its confirmed findings were fixed. It found no blocker in the final PID handshake
and process-group cleanup. Deliberate `setsid` escape is outside this trusted-code
smoke runner's process-group scope; isolated candidate validation is DEV-236.

Durable runs and restart recovery remain DEV-232. There is no Daybreak, tracker
integration, target PR publication, or target merge in this increment. Rig's
production semantic-artifact build remains outside this focused regression demo.
