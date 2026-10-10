# Native Linear delegation (DEV-233)

The local implementation adds authenticated native Linear events to the existing durable
coordinator. It does not establish an installed app, public endpoint or qualified cloud run.
Publication remains disabled for the pilot candidate. DEV-234 owns human replies; ordinary
prompt events currently deduplicate the existing task rather than supplying reply inputs.

## Configuration

Use a dedicated factory workflow, never the upstream `elixir/WORKFLOW.md`. Add this map to
its YAML front matter, replacing every example ID and path before startup:

```yaml
tracker:
  kind: memory
server:
  port: 4000
linear_delegation:
  organization_id: installed-organization-uuid
  team_id: dev-team-uuid
  app_user_id: installed-app-user-uuid
  oauth_client_id: installed-app-client-id
  webhook_secret_env: LINEAR_API_TOKEN
  client_secret_env: LINEAR_API_KEY
  store_path: /srv/factory/state/linear.sqlite
  workspace_root: /srv/factory/workspaces
  workstream_path: /srv/factory/definitions/software-change.yaml
  agent_id: default-cloud
  rig_label: factory:rig
  reconcile_interval_ms: 5000
  workspaces:
    pilot-issue-uuid: /srv/factory/workspaces/pilot-rig
```

Keep the signing secret and OAuth client secret in separate coordinator environment variables.
`LINEAR_API_TOKEN` above is the webhook signing secret; `LINEAR_API_KEY` is the OAuth client
secret despite the legacy variable name. Neither value belongs in YAML, logs or evidence.
For this increment, the two references must be distinct names in `LINEAR_API_KEY`,
`LINEAR_API_TOKEN`, or `OAUTH_TOKEN`, which the current agent launch strips. Custom references
block before dispatch until the runtime supports a pinned explicit strip list.

`client_secret_env` enables server-to-server app authentication with fixed scopes
`read,write,app:assignable`. The coordinator mints a token on the first API lookup for
each delegated issue run and keeps it in memory only, scoped to that run. This increment
allows one immutable run per issue. It renews before expiry or once after HTTP 401;
a second 401 fails rather than looping. Network/token failures are redacted, with no
automatic retry or redirect. Restart discards tokens and mints fresh ones as needed.
The cache is bounded to 1,000 unexpired run entries; an exhausted cache blocks new
authentication. Tokens and client credentials do not enter task records, evidence or
worker environments. Existing `token_env` workflows remain compatible; configure exactly
one of `token_env` and `client_secret_env`. Do not use copied access tokens as durable
production credentials. See [Linear client-credentials authentication](https://linear.app/developers/oauth-2-0-authentication).

The cache limit bounds process memory, not Linear's app-wide token quota. Tokens discarded
by a crash/restart or a blocked candidate can remain active at Linear until their provider
expiry (up to 30 days). Repeated restarts/runs can therefore exhaust the provider's
1,000-active-token limit; acquisition then fails closed. This single-run pilot does not
implement app-wide token lifecycle/revocation accounting. Before sustained operation or
scaling, add that lifecycle and verify it against the installed app; do not infer quota
recovery from local cache pruning or restart. Operator secret rotation invalidates existing
client-credentials tokens and requires a new pinned secret version/release.

## Linear app setup

Create a private OAuth app named **Default Cloud Agent** and enable client-credentials
tokens and webhooks. Use `read`, `write`, `app:assignable`; no `admin` scope is required.
`app:mentionable` is optional. Limit app-user team access to DEV. Subscribe to Agent session
events (`AgentSessionEvent`), Inbox Notifications (`AppUserNotification`) and Issue updates.
Permission Change events are not consumed by this increment. Store separate
`linear-client-secret` and `linear-webhook-signing` values privately in Secret Manager;
share only the Client ID and secret references/versions with the deployment operator.

Use the app token's `{ viewer { id } }` query to get its app-user ID. Copy the exact Client ID
from app details and verify it against signed events' `oauthClientId`; do not assume that
field is an OAuth object UUID. Rig organization is `9b259b98-cb6c-4256-88af-3a3f385c3fa7`,
DEV team is `41e1aa00-b853-44a9-930d-79e424259565`. Confirm the `factory:rig` label and use
one disposable DEV issue with its human assignee intact; select the app as delegate.

The webhook must be HTTPS at `/hooks/linear` on the chosen hostname. No hostname is
selected yet. The server-to-server grant does not use an interactive callback; this
service implements no OAuth callback endpoint. Any registration-required redirect URI
must be chosen separately, not inferred from the webhook listener. A workspace admin
must complete app setup. See [Linear agent setup](https://linear.app/developers/agents),
[app authentication](https://linear.app/developers/oauth-actor-authorization) and
[interaction best practices](https://linear.app/developers/agent-best-practices).

The configured paths must be absolute. The issue workspace must already exist as a dedicated
Git clone beneath `workspace_root`. No clone is created implicitly. The definition must be
named `software-change`, with an agent entry using `default-cloud`; its instruction, skill
and agent references must resolve. A qualified `AgentReadiness.dispatch/1` implementation is
required for production dispatch. Its absence fails closed with `worker_readiness_unavailable`.
The shipped [software-change definition](../factory/workstreams/software-change.yaml) references
DEV-231's `factory/agents/default-cloud.yaml`. It implements a local candidate, checks that
HEAD exists and the working tree is clean, then pauses at a durable human wait. This local
inspection does not qualify arbitrary Rig candidates using the
demo validation policy or publish them. DEV-231 supplies the shared agent/readiness implementation; the intended worker must
remain qualified before production dispatch.
Production qualification also requires `worker_control` with an exact machine and verified
release, plus a current root-owned containment receipt. Its absence returns
`worker_execution_control_unavailable` before acknowledgement or launch. See
[contained worker operations](contained-worker-operations.md) for configuration and the
reviewable installation change. Controlled test callbacks cannot enable production control.

From `elixir/`, start the configured workflow with:

```bash
mise exec -- ./bin/symphony /absolute/path/to/factory/WORKFLOW.md --port 4000
```

The service only accepts the configured organization/app identity. It fetches the current
issue and session through the app token. Eligible issues have the configured DEV team,
`DEV-` identifier, `factory:rig` label, app delegate and Backlog, Todo or In Progress status.
Completed/canceled state types reject. Project membership never dispatches work.

## Event and recovery behavior

- `AgentSessionEvent` created: validate current ownership/session and routing, queue one run,
  persist its activity UUID, reconcile acknowledgement through `agentActivity(id)`, then allow
  a freshly authorized stage. The acknowledgement identifies the run and disabled publication.
- Duplicate delivery: return HTTP 200 without repeating execution. A reused delivery ID with
  different normalized contents rejects. A repeated session-created event reuses the task.
- Prompted stop and `issueUnassignedFromYou`: persist a permanent stop tombstone, request
  cancellation and reject advancement from later queued events.
- Issue delegate/state updates: clear the authorization lease and recheck current scope;
  an earlier in-flight check cannot restore a cleared lease.
- Coordinator restart: reuse existing worker/run identities, reconcile pending activity IDs,
  replay pending stop receipts and reuse pinned definitions even if their source file changed.

Qualification records the resolved definition digest. Enqueue checks that digest again;
changing the definition between qualification and enqueue blocks before creating a run.
An orphaned existing run reuses its pinned definition and rechecks readiness and current
credential isolation before linking it to the task.

The dashboard/JSON snapshot exposes issue, session, run, selected agent, current stage, attempt
and cancellation outcome. Receipt records omit prompt text and credentials. Stopped tasks
retain their evidence and workspaces. There is no automatic cleanup, merge or redelegation
reset in this increment.

A stage executor receives an `on_process_start` callback. It must hold execution until the
coordinator durably accepts the operation's external identity. The production registration
path accepts a systemd operation identity: operation ID, machine, OS boot, unit,
invocation, cgroup and request digest. Only the current supervised worker can register
it. Repeated identical registration is safe across coordinator restart; conflicting or
stale identity rejects. The Codex launcher and executable checks use the same held-launch
control path when configured.

The provisional local process-group adapter remains available for controlled tests. It
always reports `unknown`, since a descendant can escape with `setsid`. Terminating the
Elixir task or SSH client cannot prove remote termination. Stop commits immediately, then
bounded supervised cancellation verifies the exact worker invocation and its whole cgroup.
Unknown execution reserves capacity through restart. Reconciliation frees the slot only
after trusted termination proof; the stopped task cannot restart. A completed SSH stream
without proof leaves the run reconciling. The chosen SSH/root-broker/systemd transport is
implemented locally; deployment and real containment qualification remain pending.

The verifier bounds raw intake to 256 KiB, requires unique signature/delivery/event headers,
checks HMAC-SHA256 over original bytes and checks the signed `webhookTimestamp` within
60 seconds. It returns 401 for failed authentication, 400 for malformed requests, 422 for
unsupported/scope-unrelated events and 503 when disabled/unavailable. Durable intake precedes
HTTP 200; asynchronous API/readiness checks do not hold the webhook response open.

## Engineer test card

From `elixir/`:

```bash
mise exec -- mix compile
mise exec -- mix specs.check
mise exec -- mix test test/symphony_elixir/software_change_test.exs test/symphony_elixir/linear_store_test.exs test/symphony_elixir/linear_agent_client_test.exs test/symphony_elixir/linear_webhook_test.exs test/symphony_elixir/linear_http_test.exs test/symphony_elixir/linear_delegation_test.exs test/symphony_elixir/workstream_cancellation_test.exs test/symphony_elixir/workstream_store_test.exs test/symphony_elixir/durable_workstream_test.exs test/symphony_elixir/extensions_test.exs
mise exec -- mix run --no-start ../factory/scripts/linear-intake-smoke.exs /tmp/factory-linear-intake-demo
mise exec -- make all
```

The HTTP test sends signed, pretty-printed JSON to a real local server, repeats the delivery,
changes its raw bytes and changes the app identity. Lifecycle tests use controlled workers,
a real SQLite store and a real executable gate. They prove acknowledgement ordering, one
run/worker through restart, pinned definitions, routing failures, stop tombstones and no
subsequent stage after controlled cancellation. They do not run a model or contact Linear.
Each fixture owns a fresh temporary directory and removes only that directory after its test.
Linux-only cancellation tests launch real held processes and process groups, including a
TERM-ignoring child and an escaped descendant. They verify identity fencing, bounded cleanup,
durable registration before effects and preservation of unknown outcomes. They skip on
other operating systems and do not prove a remote systemd boundary.

The smoke requires a new absolute directory and retains `report.json`, its workflow and
SQLite database there. It starts the real application through workflow configuration, uses
only a loopback ephemeral HTTP port, sends a controlled undelegation receipt and verifies
duplicate/invalid-signature behavior across coordinator restart. Inspect its report before
removing only that disposable output directory. It makes no Linear API call or agent turn.

## GCP coordinator deployment

The idle pilot remains the default. The local Terraform interface adds finite
`coordinator_workflow = "linear"`, `coordinator_secret_env` and opt-in
`enable_linear_webhook`. These source changes have not been applied to GCP.
Map exactly `LINEAR_API_KEY` to the OAuth client secret and `LINEAR_API_TOKEN` to the
separate signing secret using existing `optional_integration_secrets` keys and pinned
numeric versions. Pilot mode accepts no credential mapping. No payload goes through Terraform.

Startup fetches selected values as root into per-release files under
`/run/factory/coordinator`, root-owned mode 0640 with only the coordinator group allowed
to read. The unprivileged entrypoint checks ownership/mode, release, finite workflow,
environment allowlist, version and reference fingerprints before exec. Inherited credential
variables are discarded. Worker environments continue to strip these names and the root
broker uses its fixed credential-free runtime environment.

Install the dedicated workflow as root at
`/etc/factory/workflows/<service_revision>.md`, root-owned mode 0644 under root-owned
0755 directories. Use a new release revision and do not overwrite an existing workflow.
The workflow must set dashboard `server.host: 0.0.0.0`, `server.port: 8080`,
`server.webhook_host: 0.0.0.0` and `server.webhook_port: 8081`, plus the real IDs,
dedicated workspace and pinned worker-control configuration described above.
The entrypoint uses the matching protected pending config during candidate startup;
rollback uses the prior revision's active config and workflow. Configuration/credential
pin changes at the same release revision reject before any secret fetch. Make a distinct
committed release for those changes.

Root-private snapshots in `/srv/factory/coordinator-config` retain only reference/version
and deployment settings, never fetched payloads. On cold boot, startup reloads the prior
active Linear release's pinned credentials before preparing a different candidate, so
health rollback can start the previous release. Preserve its secret containers/access and
workflow until the new release is healthy. Missing snapshots or unavailable prior secrets
block preparation rather than silently losing rollback. Do not include credential files
in evidence or copy them to workers.

With explicit HTTPS/IAP opt-in, the URL map keeps the IAP dashboard backend as default.
Only exact `/hooks/linear` on the configured viewer hostname reaches the separate no-IAP
backend on port 8081. That listener accepts only signed POST intake and returns 404 for
dashboard/API/other paths and methods. Firewall access remains limited to Google load
balancer proxy/health ranges. Candidate activation requires a coordinator-owned
`0.0.0.0:8081` listener and a 404 response for its API path when enabled; dashboard health
alone cannot activate it. This is local wiring, not a provisioned public endpoint.

See the [morning decision card](dev-233-morning-decision.md) for the checked host facts,
remaining app/hostname decisions and exact staged commands.

## Live acceptance checklist (pending)

1. Confirm the public webhook hostname and admin access; install one assignable Linear app
   using app authentication. Record organization/app/OAuth identity IDs, without secret values.
2. Provision the signing secret and OAuth token to the coordinator only. Register the HTTPS
   `/hooks/linear` endpoint and the required native session, app notification and Issue updates.
3. Qualify Default Cloud readiness on the intended worker; install the explicit software-change
   definition and dedicated Rig clone. Review the control account/root broker installation,
   run the disposable systemd card, and install its reviewed current containment receipt.
   Prove natural completion, replay/recovery and external whole-tree cancellation work.
4. Delegate one disposable eligible DEV/Rig issue with its human assignee intact. Record the
   acknowledged activity UUID, run/stage IDs, selected agent and pinned definition digests.
5. Replay the same signed delivery within its freshness window and restart the coordinator;
   verify one run and no repeated side effect. Test invalid signature and invalid routing.
6. Stop/undelegate during active work; verify remote process termination and no later stage
   or restart after queued events. Keep the candidate local with no push/PR/merge.

Do not mark DEV-233 complete or open its acceptance PR until these live steps pass. Retain
the local branch and evidence if app access, hostname or worker qualification is unavailable.

## Primary contracts

The integration follows Linear's [agent authentication/delegation](https://linear.app/developers/agents),
[session interaction](https://linear.app/developers/agent-interaction),
[webhook authentication](https://linear.app/developers/webhooks),
[stop signals](https://linear.app/developers/agent-signals) and
[undelegation guidance](https://linear.app/developers/agent-best-practices).
The GraphQL schema supports a caller-supplied activity UUID and lookup; it does not promise
that repeated create mutations are idempotent. Reconciliation uses the stable lookup.
