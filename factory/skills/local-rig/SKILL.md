---
name: local-rig
description: Work on a small, local Rig change in an isolated checkout and verify it with the narrowest real repository check.
---

# Local Rig work

Use this shared skill for both implementation and review agents working on the
local Rig pilot. It gives repository guidance; the workstream and service decide
whether a gate passes.

## Read the target checkout first

Work only in the Rig checkout assigned to this run. Confirm its root with
`git rev-parse --show-toplevel` and record `git rev-parse HEAD`. Read the target
revision's `AGENTS.md` files, `README.md`, `rust-toolchain.toml`, `Cargo.toml`,
`Cargo.lock`, and the component ownership guide relevant to the changed path.
The DEV-229 baseline inspected from Rig `main` is
`39d6d5d998366bf13af19eb74ae47d598ecf92bd`; it pins Rust 1.91.1. Re-read the
checkout's files if its revision differs.

Use `docs/workspace-and-boundaries.md` for the root Cargo workspace rules. It
states that production packages share the root manifest and lockfile, and that
ordinary CI does not compile the full workspace. Do not use a component-local
`--workspace` command as if that component had its own workspace.

## Keep the change small

Follow existing ownership and nearby test patterns. Prefer a focused regression
test when it proves a narrow behavior. Keep generated files, build output,
credentials, and unrelated edits out of the diff. Do not edit the Symphony
source checkout or any upstream repository.

For Rust code, let the pinned `rust-toolchain.toml` select Cargo and Rust, and
use `--locked` so dependency resolution cannot rewrite the lockfile. The service
owns verification for the DEV-229 agent stage; implementation agents leave Cargo
execution and measurement to its following gate. That smoke check is:

```bash
cargo test --locked -p sivere-agent-hooks --lib agent::tests::agent_hook_refuses_a_configuration_file_symlink -- --exact
```

The gate runs the command under GNU `time -v` and records the elapsed time and
maximum resident set size. These numbers describe one
check on one worker; they do not establish safe concurrency or a full-workspace
build profile. Do not start a full Rig build unless the task's workstream
explicitly requests it.

## Authentication and external actions

Use the agent definition's ordinary Codex model with the user's ChatGPT
subscription sign-in. Do not use an API key, access token, Daybreak, or a
fallback billing mode. If ChatGPT sign-in or the selected model is unavailable,
stop and report the blocker. Sign in with `codex login`, then confirm
`codex login status` reports ChatGPT. See the [Codex authentication
docs](https://learn.chatgpt.com/docs/auth). Never print, copy, or commit
credential files, environment values, or login output that contains a token.

Do not push, open or update a pull request, merge, publish a package, or create
cloud resources. Preserve the existing branch and all unrelated workspace
changes. Report the exact files changed and the full focused check command with
its observed result.
