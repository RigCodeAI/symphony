# Earlier native Linear integration attempt — 2026-10-10

This records the DEV-245 attempt before the transport repair. The current worker pin,
qualification and subscription blocker are in the [transport deployment checkpoint](transport-deployment.md).

The user authorized the two pinned coordinator-only secret accesses, a newer coordinator
release with retained rollback/data, the exact signed webhook route and one disposable
native acceptance issue. No worker upgrade, publisher access or source PR is included.

The installed app authenticated with client ID `571c3dc755d9e63cfe74748787f6a533` and scopes
`read,write,app:assignable`. Its actual app user is **Rig Factory**,
`ce9f2ad8-ef28-4253-bdc8-ae208f63a425`. The app record UUID is not its client/user identity.
The token sees Rig organization and DEV team only. Temporary preflight tokens were revoked;
client secrets and tokens stayed in coordinator memory. See [identity](linear-app-identity.json).

Terraform imported the existing two containers without reading values. The reviewed access
plan added only `secretAccessor` for the coordinator on `linear-client-secret` and
`linear-webhook-signing`, with version 1 selected by deployment config, plus container labels.
It added no worker or publisher secret access. See [IAM review](linear-secret-access-review.json).

The reviewed ingress/deployment plan applied 3 additions, 4 changes and 1 conditional IAM
replacement. It added the separate 8081 backend/health check and exact `/hooks/linear` route;
dashboard and all other paths retain IAP. Only Google proxy/health ranges reach 8080/8081.
Coordinator release access includes the candidate and retained active rollback archive.
Worker metadata and its old release access were excluded from changes. See
[plan review](linear-ingress-plan-review.json). This first candidate was staged before the later activation below.

The committed candidate `f663e7ad641fe8ab777a168398385bd0edaa565f` built on the actual
coordinator as `factory-coordinator`. Its SHA was
`96d4231c2976dfa18276cc03896d20a067478a9aff26166ddfc26a76a89f3608`.
The real `WorkerOperation.qualify/1` call passed against the unchanged worker control
revision `cc85ca7871a27afb03bc2b6e86722a142ff93e7e`. It started no Symphony application or
operation. Valid preparation passed; missing agent/workstream references blocked before
acknowledgement/dispatch. See [Elixir preflight](elixir-qualification-preflight.json).

Live API preflight found two GraphQL query mismatches: `AgentSession` exposes `issue { id }`,
and `AgentActivity` exposes `agentSession { id }`. A new activity lookup returns HTTP 200
with `INPUT_ERROR` / `Entity not found: AgentActivity`, rather than null. The client fix
uses these relations and recognizes only that specific absence as permission to create the
persisted acknowledgement UUID. See [schema](linear-schema-preflight.json),
[query error](linear-query-error-preflight.json) and [absent activity](linear-activity-preflight.json).
These are real schema/API reads; no synthetic receipts were introduced into the pilot.

Disposable [DEV-245](https://linear.app/rigai/issue/DEV-245/disposable-dev-233-native-delegation-acceptance)
retains Adam as assignee and has the explicit `factory:rig` label. It was delegated for the acceptance attempt below and is now undelegated.
Matching dedicated coordinator/worker clones are at the previously qualified Rig commit
`39d6d5d998366bf13af19eb74ae47d598ecf92bd`, not a claim about the current remote `main` tip.
Push is disabled. Existing worker qualification files and all broker audit records remain.
See [worker clone](native-worker-clone.json) and [coordinator clone](native-coordinator-clone.json).

These preflights alone are not DEV-233 acceptance. The actual native attempt is recorded below.

The corrected candidate `4a0b36e7e6e01bda3b9e0d518b441fa55ddb658a` also built and
passed actual Elixir worker qualification. Activation then failed the durable SQLite
startup: the escript could not load `Exqlite.Sqlite3NIF.open/2`. The health check
automatically restored coordinator release `541279aeb6a5366571e1ee8935e134c728d91c63`;
the dashboard returned HTTP 200 and no issue had been delegated. Data, the worker release
and control receipt were retained. See [rollback preflight](coordinator-rollback-preflight.json).
The physical-library service entrypoint then passed a fresh Linux smoke on Elixir
1.19.5 / OTP 28: durable SQLite opened/migrated, dashboard health returned 200,
webhook GET returned 404 and unsigned POST returned 400. No dispatch event was sent.
The service fix was pinned to `080c048448cc949cf796f10564f16c8cf83a60e8`, built on
and activated on the actual coordinator. Dashboard health returned 200. The real
`WorkerOperation.qualify/1` and valid preparation passed; unknown agent/workstream
references blocked. These checks establish broker and definition readiness, not successful
model startup. See [activation](coordinator-runtime-activation.json),
[Elixir qualification](elixir-qualification-runtime.json) and
[reviewed runtime plan](coordinator-runtime-plan-review.json).

Worker application revision `541279aeb6a5366571e1ee8935e134c728d91c63`, control revision
`cc85ca7871a27afb03bc2b6e86722a142ff93e7e`, machine/boot identity, disks and network
were preserved. See [preservation](worker-runtime-preservation.json). Public TLS checks
verified the exact webhook path separately from IAP-protected dashboard paths; signed-in
viewer access was not tested. See [HTTPS probes](public-runtime-probes.json).

## Actual native attempt: partial, not accepted

Revoking the last preflight client-credentials token made the app user inactive in the
observed Linear account. A bounded 180-second coordinator-only bootstrap token kept the
app assignable through delegation. The native run then acquired its own app token; the
bootstrap token was revoked successfully. No token or secret payload was saved. This is
an observed bootstrap workaround, not a permanent activation/token-lifecycle solution.
See [bootstrap and observer cleanup](native-observers-finished.json).

DEV-245 produced one acknowledged native run and preserved Adam's human assignee:

- Run: `run-d8d02683e2ce5992d098289c3edf4cc3`.
- Session: `ba067e10-6e28-447b-acf3-f0cfe281b908`.
- Acknowledgement: `db1d26d0-abbb-42f5-a454-eeac8b38355c`.
- One agent stage attempt and one contained operation were durably registered.

The contained node/Codex processes had no Linear or API-billing environment variables.
Startup failed before any agent thread, turn or requested `sleep 180` was observed.
The durable result is `:agent_execution_failed`. Cleanup returned an exact systemd
termination proof with `main_pid: 0` and `cgroup_populated: 0`. This is failed-startup
cleanup; it does not prove cancellation of active coding work.

Native undelegation stopped the retained task. Its exact original signed delivery replay
returned HTTP 200 `duplicate`; changing only the signature to zeros returned 401. An
exact captured description-only Issue update replay returned 422 `unsupported_event`,
and its invalid-signature copy returned 401. The created delivery was durably handled,
but its original bytes were not captured, so exact created-event replay was not tested.
See [stop replay](native-stop-replay.json) and [unrelated replay](native-unrelated-replay.json).

A real coordinator restart retained the same run/session/acknowledgement, with the task
stopped and no worker process. A final controlled durable audit confirmed one run, one
operation, one stage attempt and one task; retained created/stop events were handled and
a later issue update was ignored after stop. See [durable evidence](native-live-partial.json).
Raw captured request bodies and signatures were deleted after replay; metadata receipts,
the SQLite store, workspaces, conversations and broker records were retained.

## Startup blocker and local repair

A bounded no-turn `AppServer.start_session/2` diagnostic returned `response_timeout`.
A second probe sent only `initialize` through the contained worker stream, timed out
after 15 seconds and terminated the exact operation. Both probes preserved operation
identities before release and have trusted empty-cgroup proofs. See
[startup diagnostic](app-startup-diagnostic.json) and [termination proofs](native-observers-finished.json).

The local forced-SSH input bridge used `BufferedReader.read(65536)`, which waits for
that byte count or EOF on persistent stdin. A real pipe regression reproduced failure
to forward a short initialize-style request while the writer stayed open. The local fix
uses `read1(65536)` when available, forwarding available bytes without waiting for EOF.
The regression passes after the change. At this checkpoint the fix was not deployed.
It was subsequently installed and qualified; see the
[deployment evidence](transport-deployment.md).

DEV-233 remains unaccepted. Active-work undelegation and restart during a live turn
still require an available subscription and a replacement disposable attempt.
The existing stopped issue must not be reset to manufacture acceptance. See
[reviewed repair and acceptance plan](transport-repair-plan.md).
