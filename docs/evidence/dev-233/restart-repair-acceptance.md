# DEV-233 restart repair acceptance, 2026-10-10

The fresh DEV-248 native run passed the previously failed coordinator restart and
stopped-metadata checks. Its same foreground worker survived restart, then native
undelegation terminated that exact operation. Four retained native runs are stopped,
with four trusted termination proofs. Rig candidate publication and merge remain disabled.

The [earlier native checkpoint](native-live-acceptance.md) records the DEV-246 failure
and DEV-247 cancellation result. Those observations remain historical evidence.

## Source and deployment

Coordinator and root worker control use source
`064f892f95847ea2eed0eb684da36c6e1bb5fce6`, archive SHA-256
`67267e73e9c587f0b6115398d89cdac462b23dcb8749df34895a34b9d0a0af89`.
The worker application remains `541279aeb6a5366571e1ee8935e134c728d91c63`.
Worker machine is `fe9b1ece921d40aeac95b10940000311`, current boot
`f76f87db6972439ca13738e1d54594fa`, systemd 252.

Commit `9c02607` moved stream pipe ownership to the worker broker and normalized
confirmed canceled attempts. Its live SSH check exposed a second problem: input EOF
detached the output reader. The [initial result](restart-repair/initial-worker-ssh-qualification.json)
and [corrected harness result](restart-repair/initial-worker-ssh-qualification2.json)
retain that failure. Commit `064f892` preserves output after input half-close and
detects a full Unix peer close without adding protocol bytes. Only full disconnect
releases the client attachment; process stdin stays open until trusted termination.

The [reviewed Terraform plan](restart-repair/coordinator-plan-reviewed.json) changed
only coordinator release metadata and the exact archive-read condition. Previous
archive permissions were retained. Worker installation used the existing idle reset
route, added no keys or grants, and restored exact startup metadata. The
[preservation receipt](restart-repair/worker-maintenance8-preservation.json) confirms
VM identity, disks, network and metadata were retained. The startup observer initially
reported a timeout because a kernel log line split its marker; the
[observer result](restart-repair/maintenance-observer-result.json) explains the
follow-up and the [current maintenance results](restart-repair/worker-maintenance8-console-status.json)
record all stages and final status passed.

The root card passed all seven required checks, including systemd manager
re-execution. Sixteen transport tests ran on the worker. The
[actual forced-SSH check](restart-repair/worker-ssh-qualification.json) passed eight
checks, including held/duplicate preparation, stale identity rejection, termination
of a child using `setsid`, output draining and natural-exit replay.

The coordinator [build](restart-repair/coordinator-build-status.json),
[protected environment](restart-repair/coordinator-environment.json),
[real Elixir preflight](restart-repair/coordinator-elixir-qualification.json) and
[activation](restart-repair/coordinator-activation.json) passed. Preflight resolved
all four disposable routes and rejected unknown workspace, agent and workstream
references. The [subscription readiness check](restart-repair/app-readiness.json)
started GPT-6 Luna with medium effort and Daybreak disabled, without a model turn,
then its [exact stop proof](restart-repair/app-stop-proof.json) confirmed termination.
This agent consumed no reset and used no API-billing fallback.

## Native restart and active stop

DEV-248 retained Adam as human assignee. Native delegation created one run
`run-755c6496a6d2a56b40545cb09e088289`, session
`2a02d74d-35bd-42ca-abf5-ad77131f45f7` and acknowledgement
`da61db7d-2178-42c5-87cd-d9fbd7f7a7c1`.

The original signed created delivery replayed at age 1,004 ms returned 200
`duplicate`; a zero signature returned 401
([receipt](restart-repair/dev248-created-replay.json)). The actual foreground
`sleep 240`, PID 2674, start ticks 23122, was observed in its contained cgroup
([before restart](restart-repair/dev248-live-before-restart.json)). After a
[coordinator-only restart](restart-repair/dev248-coordinator-restart.json), all
seven worker process identities, the sleep PID/start time/cgroup and the native
run/session/acknowledgement/assignee/attempt IDs remained the same
([after restart](restart-repair/dev248-live-after-restart.json),
[assertions](restart-repair/dev248-restart-assertions.json)). The observations were
62.88 seconds apart. No replacement was launched. Recovery stayed in reconciliation
and retained capacity; the coordinator conversation did not automatically resume.

Native undelegation was sent while that same sleep was active. The original signed
stop replay returned 200 `duplicate`, and the negative signature control returned
401 ([receipt](restart-repair/dev248-stop-replay.json)). All worker processes were
absent afterward ([observation](restart-repair/dev248-after-stop.json)). Exact root
proof binds the same unit, operation, boot and invocation
`6caa290c21bf491eadde73d72df149f4`, with MainPID 0, cgroup populated 0 and released
cgroup at 18:59:34 UTC. This occurred before the 240-second natural finish.

An actual description-only delivery replay returned 422 `unsupported_event`; its
negative signature control returned 401
([receipt](restart-repair/dev248-unrelated-replay.json)). Original HTTP responses
were not captured; these are replay responses.

## Durable state, retention and verification

Startup repaired the two historical confirmed stops without another stop RPC.
Their attempts now say `canceled` and their canceled operations no longer retain
reconciliation. Completed evidence was preserved. External identities, pinned
definitions/policy, sessions, acknowledgements and human assignees were unchanged
([legacy audit](restart-repair/legacy-stopped-audit.json)). A stopped run may retain
its current-attempt pointer to the canceled attempt for audit; that pointer is not
an active-work claim.

The final [durable audit](restart-repair/dev248-durable-audit.json) contains four
runs, four operations, four stage attempts, four Linear tasks, twelve Linear events
and twenty-eight run events. All four runs are stopped with trusted exact termination
proofs. No attempt remains executing and no canceled operation retains reconciliation.
An [idle restart observation](restart-repair/dev248-after-audit-restart.json) retained
the four stopped task identities and launched no worker processes. The bounded
[observer cleanup](restart-repair/dev248-observer-finished.json) removed seven raw
request bodies/signatures and retained redacted receipt metadata. Durable runs,
conversations and dedicated clones were retained; [clone pushes remain disabled](restart-repair/fixture-retention.json).

Focused verification used:

- `python3 -m unittest factory.deploy.tests.test_worker_operation_transport factory.deploy.tests.test_worker_operation`: 43 passing tests.
- `python3 -m py_compile` for the changed Python files and `git diff --check`: passed.
- Docker Elixir 1.19.5/OTP 28: compile, build, specs and changed-file formatting passed; six focused files passed 59 tests, with the final durable-file rerun passing 16 tests.
- Equivalent broad CI: 500 tests, zero failures, six skipped and ten excluded; setup/build/format passed. Credo baseline findings, 76.06% coverage against a 100% gate, and two existing Dialyzer warnings remain nonpassing. The new nesting finding was repaired and rechecked.
- The scoped SSH helper executed reviewed deploy, preflight, restart, native observation, authentic replay, cleanup and durable-audit scripts. JSON assertions verified the identities and proof boundaries above.

See [source/self-review results](restart-repair/source-validation.json) and
[broad CI results](restart-repair/broad-results.json). Broad CI remains non-blocking
under the alpha instructions; no GitHub protection was bypassed.

This qualifies one ordinary subscription worker and the tested native delegation,
restart-survival and active-stop path. Worker broker restart, automatic conversation
resume, signed-in dashboard access, provider token lifecycle, Daybreak and scaled
capacity remain unqualified. These results do not establish candidate publication,
review, merge or full Factory Setup deployment.
