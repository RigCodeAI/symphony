# Local Rig pilot instructions

Work in the dedicated Rig checkout created for this run. The bootstrap pins
`RigCodeAI/rig` `main` at
`39d6d5d998366bf13af19eb74ae47d598ecf92bd`; if that pin no longer matches the
current reviewed target, stop and ask the coordinator to refresh it. Do not use
an existing Rig checkout or edit the Symphony source repository.

For the smoke task, add one Unix regression test in
`crates/rig-agent-hooks/src/agent.rs`. The test should create a project
`.codex/hooks.json` symlink to a file outside the repository, verify that
`install_codex` rejects the unsafe configuration, and verify that the target
file remains unchanged. Keep this test-only; the current implementation already
rejects symlink configuration files.

The service runs this focused check from the Rig repository root after the agent
stage. Implementation agents must not run Cargo or the measurement themselves:

```bash
cargo test --locked -p sivere-agent-hooks --lib agent::tests::agent_hook_refuses_a_configuration_file_symlink -- --exact
```

The service runs the command with `/usr/bin/time -v` and reports its elapsed
time and maximum resident set size. Capture the command's
normal failure output if it fails. An explicitly supplied failing-demo task may
deliberately invert one assertion in its disposable clone; the coordinator
retains the evidence and removes that clone afterward.

Use the ordinary model selected in the local agent definition and the ChatGPT
subscription login prepared by `factory/scripts/bootstrap-linux.sh`. Do not
switch to API billing or Daybreak. Do not push, create or update a pull request,
merge, publish, or provision cloud resources. Before reporting completion,
inspect the diff and report the pinned Rig commit, changed file, check result,
and measurement. Keep build logs and environment output free of credentials.
