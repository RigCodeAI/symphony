# Native Linear integration preflight — 2026-10-10

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
[plan review](linear-ingress-plan-review.json). The candidate was staged, not activated.

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
retains Adam as assignee and has the explicit `factory:rig` label. It is not yet delegated.
Matching dedicated coordinator/worker clones are at the previously qualified Rig commit
`39d6d5d998366bf13af19eb74ae47d598ecf92bd`, not a claim about the current remote `main` tip.
Push is disabled. Existing worker qualification files and all broker audit records remain.
See [worker clone](native-worker-clone.json) and [coordinator clone](native-coordinator-clone.json).

Native acknowledgement, exact delivery replay, restart and active-work undelegation still
require the corrected deployed release. Do not treat these preflights as DEV-233 acceptance.

The corrected candidate `4a0b36e7e6e01bda3b9e0d518b441fa55ddb658a` also built and
passed actual Elixir worker qualification. Activation then failed the durable SQLite
startup: the escript could not load `Exqlite.Sqlite3NIF.open/2`. The health check
automatically restored coordinator release `541279aeb6a5366571e1ee8935e134c728d91c63`;
the dashboard returned HTTP 200 and no issue had been delegated. Data, the worker release
and control receipt were retained. See [rollback preflight](coordinator-rollback-preflight.json).
The physical-library service entrypoint then passed a fresh Linux smoke on Elixir
1.19.5 / OTP 28: durable SQLite opened/migrated, dashboard health returned 200,
webhook GET returned 404 and unsigned POST returned 400. No dispatch event was sent.
The service fix will be pinned and qualified on the actual coordinator before activation.
