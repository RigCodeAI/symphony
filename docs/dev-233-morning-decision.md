# DEV-233 morning decision card

The initial read-only snapshot was taken on 2026-10-10, 07:37–07:48 UTC and preceded the
maintenance, DNS and integration work recorded below. Worker-control revision
`a4c95481b898d05817d24cbcf76635d9c4b739c5` is now deployed and qualified. The coordinator
remains on `080c048448cc949cf796f10564f16c8cf83a60e8`; candidate coordinator release
`a4c95481b898d05817d24cbcf76635d9c4b739c5` is staged but not active. The exact HTTPS
`/hooks/linear` backend is healthy, and dashboard/all other paths remain behind IAP.

DEV-245 retains one acknowledged run/session that failed before a thread, turn or sleep began.
Undelegation replay and recovery after that stopped run passed. A newer no-turn readiness check
reached account, model and usage limits, then stopped with `usage_paused`; it did not start a
thread or turn. DEV-246 and two push-disabled clones are prepared but have never been delegated.
Active-work cancellation, restart during in-flight work, push and PR remain unverified. DEV-233
is not complete.

## Confirmed facts

| Item | Observed result |
| --- | --- |
| Existing project/region/zone | `factory-511117`, `us-central1`, `us-central1-a` |
| Worker | `rig-factory-worker-01`, running, private IP `10.42.0.2` |
| Coordinator | `rig-factory-coordinator`, running, private IP `10.42.0.3`, service active |
| Active coordinator release | `080c048448cc949cf796f10564f16c8cf83a60e8`; built Mix project, durable SQLite service active |
| Worker app release | `541279aeb6a5366571e1ee8935e134c728d91c63`, unchanged |
| Worker platform | Debian systemd `252.39-1~deb12u2`, PID 1 systemd, cgroup v2 |
| Worker identity | `factory-worker`, UID 1000, only `factory-worker` group |
| Worker machine pin | `fe9b1ece921d40aeac95b10940000311` |
| Worker boot | `5734c5bd0a864f4fae49e6a088bbf2e4` |
| Runtime | Root-owned executable Node `v24.19.0`, Codex `0.159.2`, Rust binary present; this does not requalify model/authentication |
| Subscription auth | File metadata only: worker-owned mode 0600; contents were not read |
| Workload | No agent operation is active; the readiness probe ended with main PID 0 and an empty/released cgroup |
| Worker control | `a4c95481b898d05817d24cbcf76635d9c4b739c5`, deployed; archive SHA-256 `e805385f93cf360d79ddb3d5537d02f4cff5a544d2e33aa2cd960f05fdc7802c` |
| Candidate coordinator | `a4c95481b898d05817d24cbcf76635d9c4b739c5`, built and staged, not activated |
| Existing SSH route | Local pinned OS Login/IAP key → coordinator → existing private worker key/host pin; no key was added |
| Coordinator integrations | Linear workflow active with coordinator-only client/signing secrets; no secret values are recorded here |
| HTTPS ingress | `https://factory.rig.ai/hooks/linear` is healthy on its separate backend; dashboard and every other path retain IAP |
| DNS | `factory.rig.ai` resolves to A `8.232.241.86` with DNS-only proxying; no AAAA record. Cloud DNS API is disabled, so DNS is externally managed. |
| Linear workspace | Rig, organization `9b259b98-cb6c-4256-88af-3a3f385c3fa7`; DEV team `41e1aa00-b853-44a9-930d-79e424259565` |
| Linear app | Client ID `571c3dc755d9e63cfe74748787f6a533`; app-user ID `ce9f2ad8-ef28-4253-bdc8-ae208f63a425`; scopes `read,write,app:assignable`; access limited to Rig/DEV |
| Pilot issues | DEV-245 retains Adam as human assignee and has `factory:rig`; its one run/session is stopped. DEV-246 is provisioned with two push-disabled clones and has never been delegated. |
| Secret containers | `linear-client-secret` and `linear-webhook-signing` are provisioned for the coordinator; values are not included |

See [worker preflight](evidence/dev-233/worker-preflight.json),
[coordinator preflight](evidence/dev-233/coordinator-preflight.json) and
[name-only secret inventory](evidence/dev-233/linear-secret-inventory.json).
The original preflight files remain point-in-time observations; current containment
evidence is recorded separately below.

## Current live outcome

Worker-control revision `a4c95481b898d05817d24cbcf76635d9c4b739c5`, archive SHA-256
`e805385f93cf360d79ddb3d5537d02f4cff5a544d2e33aa2cd960f05fdc7802c`, is deployed on machine
`fe9b1ece921d40aeac95b10940000311`, boot `5734c5bd0a864f4fae49e6a088bbf2e4`, under systemd
252. The worker transport tests passed 11/11 as `factory-worker` from the source directory with
the normal fixture umask; the root systemd card passed all seven checks, including manager
re-execution. Actual forced-SSH held, duplicate, stale, setsid stop/stream, natural-exit and
empty-cgroup checks passed. The built Elixir
`WorkerOperation.qualify/1` resolved DEV-245 and DEV-246 and rejected invalid workspace, agent
and workstream references. The pinned definition digest is
`99e757299a34663b640412055c6a1a9a1f3177486e40180576aab33e1bfff1de`.

The maintenance retained the same VM, restored the exact original metadata and preserved
disks, network configuration, worker app configuration and pinned auth/data baseline. No
worker privilege, key, OS Login or worker IAM grant was added. Coordinator metadata and the
exact archive-read permission were updated for startup; see the [coordinator plan
review](evidence/dev-233/transport-coordinator-plan-review.json). The
worker app remains `541279aeb6a5366571e1ee8935e134c728d91c63`. The active coordinator remains
`080c048448cc949cf796f10564f16c8cf83a60e8`, with its built Mix project and durable SQLite
service. Candidate coordinator `a4c95481b898d05817d24cbcf76635d9c4b739c5` is staged with
protected configuration and rollback, not activated. See the [transport deployment
checkpoint](evidence/dev-233/transport-deployment.md), [worker preservation
evidence](evidence/dev-233/transport-worker-preservation.json), [forced-SSH
qualification](evidence/dev-233/transport-forced-ssh-qualification.json) and [Elixir
qualification](evidence/dev-233/transport-elixir-qualification.json).

HTTPS redirects to Google sign-in with verified TLS; actual signed-in access remains untested.
The existing coordinator's exact `/hooks/linear` route is healthy, while dashboard and other
paths remain behind IAP. The installed Linear app delivered one delegation for DEV-245. Adam
remained the issue assignee, and the coordinator persisted and acknowledged one run/session.
The run failed with `agent_execution_failed` before a thread, turn or sleep began. The exact
signed undelegation delivery replay returned HTTP 200 as a duplicate; a zero-signature request
returned 401. A captured replay of a description-only Issue update returned 422
`unsupported_event`; the original response was not captured. After coordinator restart, the
same single run and acknowledgement remained stopped and no worker process was present. The
created-event replay was not captured.

The first contained AppServer attempt and earlier no-turn diagnostics failed before a thread,
turn or sleep began. Those historical startup failures are recorded in the [native integration
evidence](evidence/dev-233/native-integration.md). The transport repair is now deployed and
qualified. The latest no-turn check completed account, model and limits reads through the
repaired stream, then returned `usage_paused` before creating a thread or turn. Exact operation
cleanup was verified with main PID 0 and an empty/released cgroup. The desktop account tool
reports 100% weekly usage, ordinary usage disallowed and two reset credits; approval to consume
one is pending, and none has been used. See [app readiness](evidence/dev-233/transport-app-readiness.json)
and [stop proof](evidence/dev-233/transport-app-stop-proof.json).

Revoking the last preflight client-credentials token made the app user inactive. During the
observed delegation, the coordinator retained a bootstrap token in bounded RAM for up to 180
seconds, through routing, and revoked it after acquiring the run token. This confirms only
that observed startup path; it is not a long-term token lifecycle or quota-recovery solution.

Dashboard viewer selection is resolved: the user chose everyone in the managed
`rig.ai` domain, represented by the IAP principal `domain:rig.ai`. This means Google
Workspace/Cloud Identity domain members, rather than an email-suffix check. Live project ownership and organization name were verified: organization
`655940658710`, display name `rig.ai`, active. This supports the selected
Google-managed IAP configuration; actual signed-in domain-member access remains
unverified until its separate browser check. Google documents
[domain principal identifiers](https://docs.cloud.google.com/iam/docs/principal-identifiers)
and [IAP domain access](https://docs.cloud.google.com/iap/docs/authenticate-users-google-accounts).
This selection does not grant worker maintenance or SSH access.

## Deployment and staged coordinator

Worker-control repair and qualification are complete for the pinned worker under systemd 252;
the exact transport and preservation records are in the [evidence index](evidence/dev-233/README.md).
The maintenance steps and intermediate failures are recorded in [maintenance
attempts](evidence/dev-233/transport-maintenance-attempts.json); worker privilege and access
changes, plus the coordinator-only archive-read permission, are scoped above.

Coordinator wiring selects `pilot|linear`, loads only two pinned coordinator credentials,
checks reference/version/release consistency, and preserves active pins for restart/rollback.
The existing release explicitly enables the POST-only listener on 8081 and exact HTTPS route;
dashboard and all other paths keep IAP. Candidate coordinator a4c9548 is built and staged with
protected configuration and rollback, but not activated. Activation is a separate pending
step after the usage blocker clears. See the [ingress receipt](evidence/dev-233/https-ingress.md)
and [prior coordinator activation record (historical)](evidence/dev-233/coordinator-runtime-activation.json).

## Decisions and current status

1. **Worker control:** deployed and qualified on the pinned machine/boot under systemd 252.
   The 11 transport tests, seven-check root card, forced-SSH operations and actual Elixir
   qualification passed. The worker app remains on release
   `541279aeb6a5366571e1ee8935e134c728d91c63`. **Coordinator candidate:** built and staged,
   not activated; the active coordinator remains on `080c048448cc949cf796f10564f16c8cf83a60e8`.
2. **Hostname and ingress:** `factory.rig.ai` and managed-domain dashboard access
   `domain:rig.ai` are selected. The HTTPS `/hooks/linear` backend is active and healthy;
   dashboard and all other paths retain IAP. Actual signed-in dashboard access is still
   untested. See the [ingress receipt](evidence/dev-233/https-ingress.md).
3. **Linear app and issue routing:** the installed app has
   client ID `571c3dc755d9e63cfe74748787f6a533`, app-user ID
   `ce9f2ad8-ef28-4253-bdc8-ae208f63a425`, and `read,write,app:assignable` scopes. Its token
   sees the Rig organization and DEV team. DEV-245 retains Adam as assignee, has
   `factory:rig`, and produced one acknowledged run/session that stopped before a thread or
   turn. DEV-246 is a separately provisioned fixture and has never been delegated.

## Remaining acceptance work

The transport repair is deployed, but the no-turn readiness check is blocked by `usage_paused`.
The desktop account reports 100% weekly usage and two reset credits. Approval to consume one
reset is pending; no reset was consumed. The created-event replay was not captured. Preserve
DEV-245 as the failed/stopped evidence issue; use DEV-246 or another separately approved
disposable fixture for active-work acceptance. After usage is available, rerun full startup
readiness with a fresh operation identity, activate the staged coordinator, start the bounded
observer before native delegation, capture/replay the actual created delivery, and verify the
operation is still live. Restart the coordinator, verify the same operation remains active,
then undelegate and confirm termination with no replacement launch. If EOF already ended the
operation, that is not proof of active cancellation. Do not
push, publish, open an acceptance PR or mark DEV-233 complete until these live checks pass. See
the [transport deployment checkpoint](evidence/dev-233/transport-deployment.md) and [current
Linear delegation status](linear-delegation.md#current-live-status-and-remaining-acceptance).
The bounded bootstrap-token observation does not establish a long-term token lifecycle or
quota-recovery solution for sustained use.
