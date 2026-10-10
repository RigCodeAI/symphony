# DEV-233 current decision and live status

The scoped native delegation, restart-survival, active-stop and durable-metadata acceptance
passed on 2026-10-10 with DEV-248. This does not qualify the full Factory Setup flow or establish
publication and merge behavior. See the [restart repair acceptance record](evidence/dev-233/restart-repair-acceptance.md).

The initial read-only snapshot was taken on 2026-10-10, 07:37–07:48 UTC. Its observations and
the earlier DEV-245/246/247 runs below remain historical evidence; the current deployment and
acceptance results are recorded separately.

## Confirmed facts

| Item | Observed result |
| --- | --- |
| Existing project/region/zone | `factory-511117`, `us-central1`, `us-central1-a` |
| Worker | `rig-factory-worker-01`, running, private IP `10.42.0.2` |
| Coordinator | `rig-factory-coordinator`, running, private IP `10.42.0.3`, service active |
| Coordinator and root worker control | Source commit `064f892f95847ea2eed0eb684da36c6e1bb5fce6`; archive SHA-256 `67267e73e9c587f0b6115398d89cdac462b23dcb8749df34895a34b9d0a0af89` |
| Worker app release | `541279aeb6a5366571e1ee8935e134c728d91c63`, unchanged |
| Worker platform | Debian systemd `252.39-1~deb12u2`, PID 1 systemd, cgroup v2 |
| Worker identity | `factory-worker`, UID 1000, only `factory-worker` group |
| Worker machine pin | `fe9b1ece921d40aeac95b10940000311` |
| Worker boot | `f76f87db6972439ca13738e1d54594fa` |
| Runtime | Root-owned executable Node `v24.19.0`, Codex `0.159.2`, Rust binary present; separate App Server startup/readiness passed with GPT-6 Luna, medium effort and no model turn |
| Subscription auth | File metadata only: worker-owned mode 0600; contents were not read |
| Workload | Four stopped runs with trusted termination proofs; no executing attempts, no operation awaiting reconciliation, and no worker processes after final idle restart |
| Worker control | Included in the current source commit above; actual SSH and root containment acceptance passed |
| Coordinator configuration | Current deployed source passed four candidate routes, default callback and invalid-reference checks |
| Existing SSH route | Local pinned OS Login/IAP key → coordinator → existing private worker key/host pin; no key was added |
| Coordinator integrations | Linear workflow active with coordinator-only client/signing secrets; no secret values are recorded here |
| HTTPS ingress | `https://factory.rig.ai/hooks/linear` is healthy on its separate backend; dashboard and every other path retain IAP |
| DNS | `factory.rig.ai` resolves to A `8.232.241.86` with DNS-only proxying; no AAAA record. Cloud DNS API is disabled, so DNS is externally managed. |
| Linear workspace | Rig, organization `9b259b98-cb6c-4256-88af-3a3f385c3fa7`; DEV team `41e1aa00-b853-44a9-930d-79e424259565` |
| Linear app | Client ID `571c3dc755d9e63cfe74748787f6a533`; app-user ID `ce9f2ad8-ef28-4253-bdc8-ae208f63a425`; scopes `read,write,app:assignable`; access limited to Rig/DEV |
| Pilot issues | DEV-245 failed before a thread or turn; DEV-246's first restart failed; DEV-247's live stop passed. DEV-248 is the accepted restart run; Adam remains its human assignee. |
| Secret containers | `linear-client-secret` and `linear-webhook-signing` are provisioned for the coordinator; values are not included |

See [worker preflight](evidence/dev-233/worker-preflight.json),
[coordinator preflight](evidence/dev-233/coordinator-preflight.json) and
[name-only secret inventory](evidence/dev-233/linear-secret-inventory.json).
The original preflight files remain point-in-time observations; current containment
evidence is recorded separately below.

## Current live outcome

Coordinator and root worker control use source commit
`064f892f95847ea2eed0eb684da36c6e1bb5fce6`, archive SHA-256
`67267e73e9c587f0b6115398d89cdac462b23dcb8749df34895a34b9d0a0af89`. The worker app remains
`541279aeb6a5366571e1ee8935e134c728d91c63`; worker machine
`fe9b1ece921d40aeac95b10940000311` is on boot
`f76f87db6972439ca13738e1d54594fa`, under systemd 252.39. Maintenance preserved the VM,
disks, network and worker app/auth baseline; no worker key or IAM grant was added. The root
card passed all seven checks including manager re-execution, the worker transport suite passed
16 tests, the actual SSH qualification passed eight checks, and the Elixir preflight passed all
four candidate routes plus default callback and invalid-reference checks. See the [restart
repair acceptance record](evidence/dev-233/restart-repair-acceptance.md) for receipts.

App Server startup and subscription readiness passed with GPT-6 Luna, medium effort and Daybreak
disabled. It started without a model turn and then stopped with exact termination proof. No
reset was consumed and no API-billing fallback was used. Earlier `usage_paused` and startup-timeout
observations preceded successful reauthentication and remain historical.

Earlier run results remain distinct: DEV-245 failed before a thread or turn; DEV-246's first
restart attempt retained run/session/acknowledgement records but lost its worker after SSH
stream closure; DEV-247's native undelegation stopped its live foreground operation with exact
empty-cgroup proof. The old audit also found stale stopped-attempt metadata, which startup has
since repaired without repeating cancellation.

DEV-248 retained Adam as assignee and created one acknowledged native run. Its foreground
`sleep 240` and all seven worker process identities survived the coordinator service restart
unchanged in before/after observations 62.88 seconds apart; the same task, session,
acknowledgement and attempt remained, and
no replacement launched. Recovery stayed in reconciliation with capacity reserved; the
conversation did not automatically resume. Native undelegation then stopped that same live
operation before natural completion. The created/stop duplicate replays returned 200, invalid
signatures returned 401, and the description-only event returned 422 `unsupported_event`.

The final audit found four stopped runs, four trusted termination proofs, no executing attempts
and no operation awaiting reconciliation. A stopped run may retain its pointer to a
canceled current attempt for audit. The following idle restart retained all four task identities
and launched no worker. Signed-in dashboard access, provider token lifecycle, Daybreak, scale,
automatic conversation resume and worker broker restart remain unqualified. See the [restart
repair acceptance record](evidence/dev-233/restart-repair-acceptance.md) and the
[earlier native checkpoint](evidence/dev-233/native-live-acceptance.md).

## Deployed coordinator and worker

Worker-control repair and qualification are complete for the pinned worker under systemd
252.39. The exact transport and preservation records are in the [evidence index](evidence/dev-233/README.md).
The earlier maintenance steps and failures remain in [maintenance attempts](evidence/dev-233/transport-maintenance-attempts.json).

Coordinator wiring selects `pilot|linear`, loads only two pinned coordinator credentials,
checks reference/version/release consistency, and preserves active pins for restart/rollback.
The current coordinator and root worker control run source commit
`064f892f95847ea2eed0eb684da36c6e1bb5fce6`. The exact HTTPS webhook route remains separate
from the IAP dashboard and other paths. See the [ingress receipt](evidence/dev-233/https-ingress.md)
and [restart repair acceptance](evidence/dev-233/restart-repair-acceptance.md).

## Decisions and current status

1. **Worker control and native restart:** deployed and qualified on the pinned machine and boot
   under systemd 252.39. The 16 transport tests, seven-check root card, eight actual SSH checks,
   and Elixir candidate checks passed. DEV-248's same live operation survived coordinator
   restart and was later stopped by native undelegation; the final audit confirmed repaired stopped-run
   metadata. The worker app remains on release
   `541279aeb6a5366571e1ee8935e134c728d91c63`.
2. **Hostname and ingress:** `factory.rig.ai` and managed-domain dashboard access
   `domain:rig.ai` are selected. The HTTPS `/hooks/linear` backend is active and healthy;
   dashboard and all other paths retain IAP. Actual signed-in dashboard access is still
   untested. See the [ingress receipt](evidence/dev-233/https-ingress.md).
3. **Linear app and issue routing:** the installed app has
   client ID `571c3dc755d9e63cfe74748787f6a533`, app-user ID
   `ce9f2ad8-ef28-4253-bdc8-ae208f63a425`, and `read,write,app:assignable` scopes. Its token
   sees the Rig organization and DEV team. DEV-245 retains Adam as assignee, has
   `factory:rig`; that historical run failed before a thread or turn. DEV-246's earlier restart
   attempt failed when its SSH stream ended the worker. DEV-247's active undelegation stopped its
   worker with exact root proof. DEV-248 passed the restart and active-stop checks; Adam remains
   its human assignee.

## Remaining qualification

The scoped DEV-233 native delegation, restart-survival, active-stop and durable-metadata boundary
passed. The final audit contains four stopped runs and exact termination proofs, with no
executing attempts or operation awaiting reconciliation. A canceled current attempt may remain
the run's audit pointer. Automatic conversation resume, worker broker restart, signed-in
dashboard access, provider token lifecycle, Daybreak and scaled capacity remain unqualified.
DEV-234 still owns human replies; ordinary prompt events do not supply reply inputs. No Rig candidate
publication or merge was attempted, and these results do not establish the full Factory Setup
flow. See the [restart repair acceptance record](evidence/dev-233/restart-repair-acceptance.md)
and [earlier native checkpoint](evidence/dev-233/native-live-acceptance.md).
