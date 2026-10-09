# DEV-232 alpha evidence

Base: DEV-229 PR #1, confirmed merged at `88c3b466feadb4302b1ffb888be6e207827ac6c5`.
The live ticket/project/dependencies and comments were refreshed after release.
This is local controlled-worker evidence, not Linear/GCP/model qualification.

| Ticket requirement | Observed evidence |
| --- | --- |
| Manual task retains phase/workspace after restart | OTP tests and smoke kill/restart at the committed agent → check boundary and persisted human wait; complete records compare equal. |
| Duplicate delivery and ambiguous worker safety | Repeated queue/answer/completion inputs execute once; uncertain workers reserve capacity and block replacement; a second OS process cannot acquire the SQLite writer lock. |
| Failed migration preserves recoverable data | Version-2 ALTER followed by invalid SQL rolls back; reopening restores the original wait/run. Store tests inspect rolled-back schema and prior rows. |
| Pinned definitions, evidence, counters, stages and side effects survive | Updated skill changes new runs only; gate/repair/transport counters persist; a lost action receipt reconciles its existing effect; committed receipts are acknowledged without another stage. Fresh BEAM recovery compares complete readable state, including opaque metadata. |

## Commands and results

Verified in an owned disposable Linux aarch64 container, image `elixir:1.19.5-otp-28`,
OTP 28 / Elixir 1.19.5, three CPUs and 10 GiB memory. Source was copied explicitly into
`/service`, not read through a potentially stale Colima mount. Mise `2026.10.4` ran with
`MISE_DISABLE_TOOLS=erlang,elixir` to use the pinned image's system runtimes.

From `/service/elixir`:

```bash
mise exec -- mix test test/symphony_elixir/durable_workstream_test.exs \
  test/symphony_elixir/workstream_run_test.exs test/symphony_elixir/workstream_store_test.exs \
  test/symphony_elixir/workstream_test.exs test/symphony_elixir/workstream_runner_test.exs \
  test/symphony_elixir/core_test.exs test/symphony_elixir/orchestrator_status_test.exs
mise exec -- mix run --no-start ../factory/scripts/recovery-smoke.exs /tmp/dev232-smoke-verified
mise exec -- mix specs.check
mise exec -- mix pr_body.check --file /tmp/pr-body.md
```

Results: **174 focused tests, 0 failures**; smoke `passed`; public specs and PR-body checks
passed. The final smoke stored pass run `run-32201cd4d44c96c8d0fec908ef1f0c55` and fail run
`run-62794d10587f66bcb4f774e05c5606e0`. A separate fresh `mix run --no-start` process reopened
that database and observed one complete run and one blocked run. The passing workspace's
check log contained one line. A concurrent second BEAM/OS process returned
`database_ownership_conflict`, proving database ownership beyond one VM's process registry.

Broad checks were also run under the approved alpha exception:

- `mise exec -- make all`: setup/build/format/specs passed; stopped at Credo style/nesting
  findings in the added code. It did not complete Dialyzer.
- `mise exec -- mix test --cover`: **386 tests, 0 failures, 6 skipped**. Coverage gate failed
  at **96.06%**, below the repository's 100% threshold. Store coverage is 77.87%; several
  defensive filesystem/driver-error branches remain uncovered. Coverage was not weakened.

These broader failures are reported as alpha maintenance work, not a green full gate.
GitHub-enforced checks/protections remain the coordinator's merge boundary.

## Review and limits

Owner self-review checked single-writer ownership, atomic event/transition commits,
receipt acknowledgements, workspace/database separation, pinned policy and fresh-process
serialization. The independent restart review found event namespace collision, writable
DB overlap and unenforced policy pins; regression tests cover all three fixes. Opaque
execution evidence now uses JSON string keys, avoiding transient BEAM atoms on recovery.

A worker without a durably registered identity remains conservatively blocked after a
spawn-window crash. Full-host/external-process recovery requires an authoritative liveness
or action adapter; absence alone never authorizes replacement. Durable mode is manual-only.
The normal tracker runtime still has its prior in-memory behavior. No production agent,
Daybreak, Linear, cloud, publisher, merge or isolated trusted validator is claimed here.

The reproducible engineer test card and safe cleanup are in
[durable-workstreams.md](durable-workstreams.md). Local raw logs and closed smoke data were
retained in `/private/tmp/dev232-verified-evidence` and `/private/tmp/dev232-*.log` for this
session; generated logs are not committed to the repository.
