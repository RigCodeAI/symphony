# DEV-233 native live acceptance, 2026-10-10

This is the historical checkpoint before the stream and stopped-state repairs.
The later [restart repair acceptance](restart-repair-acceptance.md) records the fresh
passing DEV-248 run and current deployment pins. Results below describe the earlier releases.

Native delegation, duplicate rejection and active-work undelegation passed on a real
subscription worker. Active work did not survive a coordinator restart. DEV-233 remains
unaccepted at that boundary; no publication or merge was attempted.

## Authentication and deployed pins

The user's Google CLI sign-in completed successfully on another tab. The existing IAP/SSH
connection worked afterward. The actual no-turn app-server check started a session with
`gpt-6-luna`, medium effort and Daybreak disabled, then stopped its exact contained operation.
No reset was consumed by this agent and no API-billing fallback was used. See the
[readiness result](app-resume-readiness.json) and [termination proof](app-resume-stop-proof.json).

Coordinator `a4c95481b898d05817d24cbcf76635d9c4b739c5` was activated for DEV-246
([receipt](transport-coordinator-activation.json)). The later immutable configuration for
DEV-247 uses coordinator source `3e81a8a418f585928bc9f4462f5187584a3bad38`, archive SHA-256
`fd1f4ae714539b331906ae5840c935e4dceed9e3a40d21c05aad780ea4a5cc3d`. The workstream and
agent source bytes match a4; this release adds the third fixture route without changing code.
The protected Linear configuration is loaded at service startup, so it needed a new pinned
configuration and an idle restart. Both older stopped fixtures and SQLite data were retained.

The reviewed Terraform change affected only coordinator release metadata and the exact archive
read condition. Worker resources and credentials were unchanged. See the
[reviewed plan](coordinator-cancellation-plan-reviewed.json),
[staging](coordinator-cancellation-staged.json), [build](coordinator-cancellation-build-status.json),
[protected environment](coordinator-cancellation-environment.json),
[real Elixir preflight](coordinator-cancellation-elixir-qualification.json) and
[activation](coordinator-cancellation-activation.json).

Worker control remains `a4c95481b898d05817d24cbcf76635d9c4b739c5`, archive
`e805385f93cf360d79ddb3d5537d02f4cff5a544d2e33aa2cd960f05fdc7802c`; worker application
remains `541279aeb6a5366571e1ee8935e134c728d91c63`. The dedicated DEV-247 Rig clones have
push disabled ([worker](native-worker-clone-dev247.json),
[coordinator](native-coordinator-clone-dev247.json)).

## Restart experiment: DEV-246

Actual native delegation preserved Adam as human assignee and created one acknowledged run,
`run-ef2e798787754ccf02ef91637fc5eb7d`, session
`f95a51d9-cf38-417d-a738-bb237d4a907d`, acknowledgement
`5bf9b6f0-69b7-4da4-98f3-776320ed113c`.

The captured original signed created delivery was replayed within the 45-second timestamp
window. It returned 200 `duplicate`; the same body with a zero signature returned 401
([receipt](dev246-created-replay.json)). A foreground `sleep 180`, PID 4219, was observed in
its exact operation cgroup ([before restart](dev246-live-before-restart-2.json)). The
coordinator restart retained the same run, session and acknowledgement without replacement,
but the worker processes were gone afterward and the run was reconciling
([restart](dev246-coordinator-restart.json), [after restart](dev246-live-after-restart.json)).
The SSH stream closing appears to have ended the operation. This does not prove active-work
survival or cancellation of active work after restart.

Native undelegation subsequently stopped that run. Authentic stop replay returned 200
`duplicate`; a zero signature returned 401 ([receipt](dev246-stop-replay.json)). An actual
unrelated description update replay returned 422 `unsupported_event`, with the negative
signature control returning 401 ([receipt](dev246-unrelated-replay.json)). Original HTTP
responses were not captured, so these receipts describe replay responses only.

## Active cancellation experiment: DEV-247

No coordinator restart occurred between delegation and undelegation for this fixture.
Native delegation preserved Adam as human assignee and created one acknowledged run,
`run-e65005caafe229f8a542d4b80b12c82f`, session
`b8423098-7b7d-470e-ad89-0a9e86eef22a`, acknowledgement
`c79c7124-7dc4-48bb-a4c5-9ad6c45be8fe`.

Created delivery `6542a4bb-f6ed-42cb-8414-1372fd96ccc9` was replayed at age 1,563 ms:
200 `duplicate`, then 401 for the zero-signature control
([receipt](dev247-created-replay.json)). At 16:29:24 UTC the foreground `sleep 180`, PID
5150, was running in
`factory-operation-5a2457b186d5fd6a64d68c620ccbc7658552f3f29fd44dbad44c85d2d95600bc.service`.
All seven observed processes lacked the checked Linear and API-billing environment names;
no environment values were read into evidence
([live observation](dev247-live-before-stop-1.json)).

Native undelegation was sent while that command was active. Stop delivery
`c8071d78-c841-4228-9c63-bc7658804348` replayed at age 957 ms: 200 `duplicate`, then 401
for the negative signature control ([receipt](dev247-stop-replay.json)). The same run was
stopped with termination `terminated`, and all operation processes were absent
([observation](dev247-after-stop.json)). The root-owned termination proof binds the same
operation, unit, machine, boot and invocation `1910d27590774d09bf97247cf5403993`; it records
MainPID 0, cgroup populated 0 and released cgroup at 16:29:35 UTC
([durable audit](dev247-durable-audit.json)). No later stage or replacement operation was
created. The foreground command was stopped well before its 180-second natural finish.

## Retention, verification and remaining limits

The stopped-run read-only audit found three runs, three operations, three stage attempts,
three Linear tasks, nine Linear events and nineteen run events. All three runs were stopped;
all three exact worker identities returned retained `terminated` proofs. An idle coordinator
restart preserved the same identities and acknowledgements and left no worker processes
([after restart](dev247-after-audit-restart.json)). The DEV-246 and DEV-247 stage-attempt
records still say `executing` inside stopped runs. The DEV-246 canceled operation also retains
`:unknown` in its reconciliation field, although its exact root status receipt proves termination.
These stored metadata fields are not live-process claims.

The bounded observers were stopped. Their raw bodies and signatures were removed, while
redacted receipt metadata, durable run data, conversations and dedicated workspaces remain
([DEV-246 cleanup](dev246-observer-finished.json),
[DEV-247 cleanup](dev247-observer-finished.json)). Private credential snapshots and raw
process output were excluded from repository evidence.

Verification used the existing scoped SSH helper to execute the reviewed staging, build,
Elixir qualification, activation, observation, authentic replay, cleanup and read-only audit
scripts. JSON assertions checked retained run/session/acknowledgement/assignee identities,
three terminal proofs, absence of workers after stop and idle restart, and no replacement.
No source code changed in this checkpoint; earlier focused transport and containment results
remain in [transport deployment](transport-deployment.md).

Active-work survival across coordinator restart remains a failed acceptance boundary. Durable
attempt and reconciliation metadata also remain inconsistent with the retained termination proofs.
Signed-in dashboard viewer access, provider token lifecycle accounting, Daybreak and scaled
capacity remain unqualified. These results do not establish full Factory Setup deployment,
publication, review or merge behavior.
