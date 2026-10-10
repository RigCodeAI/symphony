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
  oauth_client_id: installed-oauth-client-uuid
  webhook_secret_env: LINEAR_API_TOKEN
  token_env: LINEAR_API_KEY
  store_path: /srv/factory/state/linear.sqlite
  workspace_root: /srv/factory/workspaces
  workstream_path: /srv/factory/definitions/software-change.yaml
  agent_id: default-cloud
  rig_label: factory:rig
  reconcile_interval_ms: 5000
  workspaces:
    pilot-issue-uuid: /srv/factory/workspaces/pilot-rig
```

Keep the signing secret and app OAuth token in separate service environment variables.
`LINEAR_API_TOKEN` above is the webhook signing secret; `LINEAR_API_KEY` is the app OAuth
token despite the legacy variable name. Neither value belongs in YAML, logs or evidence.
For this increment, the two references must be distinct names in `LINEAR_API_KEY`,
`LINEAR_API_TOKEN`, or `OAUTH_TOKEN`, which the current agent launch strips. Custom references
block before dispatch until the runtime supports a pinned explicit strip list.

The configured paths must be absolute. The issue workspace must already exist as a dedicated
Git clone beneath `workspace_root`. No clone is created implicitly. The definition must be
named `software-change`, with an agent entry using `default-cloud`; its instruction, skill
and agent references must resolve. A qualified `AgentReadiness.dispatch/1` implementation is
required for production dispatch. Its absence fails closed with `worker_readiness_unavailable`.
The shipped [software-change definition](../factory/workstreams/software-change.yaml) references
DEV-231's `factory/agents/default-cloud.yaml`. It implements a local candidate, checks that
HEAD exists and the working tree is clean, then pauses at a durable human wait. This local
inspection does not qualify arbitrary Rig candidates using the
demo validation policy or publish them. The shared agent/readiness combination must be
integrated before production startup can dispatch.
Production qualification also requires contained worker execution control. Until that
integration exists, the default returns `worker_execution_control_unavailable` before
acknowledgement or launch. Controlled tests supply an explicit execution-control callback;
that callback is not a workflow configuration switch.

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
coordinator durably accepts the operation's external identity. The current registration
path accepts a local Linux process group identity: operation ID, machine ID, OS boot ID,
leader PID, group ID and process start ticks. Only the current supervised worker can
register it. Repeated identical registration is safe across coordinator restart; conflicting
or stale identity rejects. The ordinary Codex launcher does not yet use this held-launch
contract, so these tests do not establish controlled production execution.

The provisional local adapter verifies this identity before TERM and bounded KILL. It keeps
the result `unknown` even after group cleanup, because a descendant can escape with `setsid`.
Terminating the supervised Elixir task or local SSH process cannot prove remote termination.
Unknown external execution reserves capacity through restart. Explicit reconciliation may
release it only when a trusted adapter returns termination proof; the stopped task remains
stopped and cannot restart. External whole-tree proof remains a live acceptance requirement.

The proposed production path uses the existing SSH connection to a worker-owned transient
systemd unit. Hold launch, persist the operation ID, worker machine/OS boot identity, unit
name and invocation identity, then release. Stop/reconcile must verify those identities,
request bounded termination and prove the operation's entire cgroup is empty. A connection
failure, stale identity or missing proof keeps capacity reserved. This path needs worker
support and deployment qualification; no remote control transport is implemented here.

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

## Live acceptance checklist (pending)

1. Confirm the public webhook hostname and admin access; install one assignable Linear app
   using app authentication. Record organization/app/OAuth identity IDs, without secret values.
2. Provision the signing secret and OAuth token to the coordinator only. Register the HTTPS
   `/hooks/linear` endpoint and the required native session, app notification and Issue updates.
3. Integrate and qualify Default Cloud readiness on the intended worker; install the explicit
   software-change definition and dedicated Rig clone. Prove external cancellation works.
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
