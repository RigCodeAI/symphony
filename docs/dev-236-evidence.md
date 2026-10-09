# DEV-236 acceptance evidence

Observed on 2026-10-09 in a disposable Linux aarch64 service container using
Elixir 1.19.5 / OTP 28 and the pinned Python image in `factory/policies/rig-local.yaml`.
The development PR implements Symphony; its demo candidate belongs to Rig and
was committed only in a disposable local clone with pushing disabled.

| Acceptance criterion | Evidence |
| --- | --- |
| Passing candidate receipt bound to SHA, policy/environment, commands and checksums | Real Rig architecture regression passed on candidate `f3c77e518dc84de62f4b6113692a333c0ddeae79`; receipt and identifiers below. Deterministic container fixture also passes. |
| Failed, skipped-required, missing, stale and malformed results cannot qualify | `ValidationTest` exercises failures, exits 124/137, explicit service deadline, skipped/zero unittest results, missing/forged receipt, malformed assertions, corrupted artifacts, stale attempt/policy/source, and final focused-run rejection. Policy tests reject absent/incomplete/duplicate results and unavailable adapters. |
| Source or policy weakening invalidates eligibility; feedback supports retry | The Rig demo invalidates the final receipt after a source edit and re-verifies after restoration. Fixtures reject committed source changes and candidate-owned policy edits; authenticated check/log feedback is returned. |
| Same evaluator output, two explicit contracts, trusted service gates | `ValidationLifecycleTest` loads two YAML workstreams. A signed receipt containing `qualified=true`, `detected=false`, exit zero passes qualification and fails detection. Verdict, evidence identity and rationale are recorded separately. Forged verdict/feedback and PID metadata are discarded. |
| Durable lifecycle and bounded repairs | Real OTP coordinator restart preserves the signed receipt, pinned policy and human wait despite changed policy files. Forged results stop after three failed validation rounds, separately from transport and review counters. Existing durable/duplicate/liveness tests pass. |

## Real check and stored identity

Base Rig commit: `39d6d5d998366bf13af19eb74ae47d598ecf92bd`.
Candidate: `f3c77e518dc84de62f4b6113692a333c0ddeae79`.
This adds a harmless README comment; no Rig candidate was pushed or published.

Exact check, executed in the isolated clean snapshot:

```bash
python3 -m unittest discover -s tools -p test_architecture.py \
  -k test_supported_node_python_consumer_passes
```

Observed: one test, no skips, exit 0. Source digest before and after was
`4ea2d8d496733e5e2cc2ec6a6fa3f1f8e616c3f14983de41c1c2a3c46d8d934c`.
Policy digest: `7c435bf39be44853bdcf5c6603c376c43dae738ce9d6c0e4a07c3f5f600375b2`.
Service implementation digest: `6569cb743ddd568475a8cac135e900db2b36cc26b8fac3007bab36e8cfcd4ff6`.
Final receipt ID: `4da14146aa1ecbfca25109d8eef376a8e54d321181177ea2d8def57a40e037a0`.
Manifest checksum: `dd2f8ebcc80c309d046aab690e4bc4b31565036fa157a5b191c98c449b50de3b`.
The 98-byte log has SHA-256
`d10ffbd9f0faa72cd6837063279524e199b59fbc3d035051302a1e8dbc4b36ad`.
The receipt additionally records the immutable base image, sealed image digest,
resource limits, duration, assertion outcomes, timestamps and producer identity.

The raw private archive, report and incremental candidate bundle are retained at
`/private/tmp/dev236-evidence/final/` on the development host. The archive key is
private and is not committed or printed. Service/test logs are retained under
`/private/tmp/dev236-evidence/`. Generated logs are not part of this source PR.
The [repeatable demo](trusted-validation.md#repeatable-demo-and-focused-checks)
recreates these observations using a fresh output directory.

## Checks and self-review

The Linux service source was copied explicitly with `docker cp` and formatted
files copied back, avoiding stale bind mounts. Exact final focused command:

```bash
SYMPHONY_RUN_VALIDATION_DOCKER=1 mix test \
  test/symphony_elixir/validation_test.exs \
  test/symphony_elixir/validation_policy_test.exs \
  test/symphony_elixir/validation_lifecycle_test.exs \
  test/symphony_elixir/workstream_test.exs \
  test/symphony_elixir/workstream_run_test.exs \
  test/symphony_elixir/workstream_runner_test.exs \
  test/symphony_elixir/durable_workstream_test.exs
```

- Compilation with warnings as errors, format and specs checks passed.
- Final focused run: 90 tests, zero failures. A later type-branch cleanup reran
  the four affected lifecycle/runner files: 37 tests, zero failures.
- The standalone `mix validation.run` interface produced a passing Rig receipt.
- Earlier broad snapshot: 410 tests, zero failures, six opt-in skips; coverage
  91.04% failed the repository's 100% threshold. The later feedback and type-branch
  changes were verified with focused tests rather than another full-suite run.
- `make all` stopped at strict Credo findings, including existing and added
  readability/complexity findings. Final Dialyzer reports only two unchanged
  `workstream_store.ex` warnings. Broad checks are non-blocking under the approved
  alpha policy; they are not reported as green. GitHub protections remain intact.

Self-review fixed the applicable-coverage bypass, zero/skipped-test acceptance,
root storage overlap, stale incremental service digests, opaque result metadata,
and missing actionable repair logs. Deadline causes are owned by the service,
not guessed from exit values. Candidate execution is unprivileged with sealed
source, no network/host mounts and no producer credentials. No extra formal
review was required under the alpha development override.

This is local validation evidence. Production GitHub checks/publication, GCS
archival and real Coverage Factory adapters remain their assigned later tickets.
