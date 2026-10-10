# DEV-233 morning decision card

The initial read-only snapshot was taken on 2026-10-10, 07:37–07:48 UTC. Current worker
control remains deployed at `a4c95481b898d05817d24cbcf76635d9c4b739c5`; the active coordinator
is now immutable release `3e81a8a418f585928bc9f4462f5187584a3bad38`, archive SHA-256
`fd1f4ae714539b331906ae5840c935e4dceed9e3a40d21c05aad780ea4a5cc3d`. Its workstream and agent
bytes match a4; its protected configuration adds the DEV-247 fixture. Worker app revision
`541279aeb6a5366571e1ee8935e134c728d91c63` is unchanged.

The App Server startup and subscription readiness check passed with GPT-6 Luna, medium effort,
and Daybreak disabled; this agent consumed no reset. DEV-246 active work did not survive
coordinator restart: the run/session/acknowledgement remained durable and no replacement started,
but the worker processes were gone after the SSH stream closed. The stream closure appears to
have ended the operation. DEV-247 native undelegation stopped a live foreground operation
with exact empty-cgroup proof. DEV-233 remains unaccepted because active work did not survive
restart. See the [native live acceptance evidence](evidence/dev-233/native-live-acceptance.md).

## Confirmed facts

| Item | Observed result |
| --- | --- |
| Existing project/region/zone | `factory-511117`, `us-central1`, `us-central1-a` |
| Worker | `rig-factory-worker-01`, running, private IP `10.42.0.2` |
| Coordinator | `rig-factory-coordinator`, running, private IP `10.42.0.3`, service active |
| Active coordinator release | `3e81a8a418f585928bc9f4462f5187584a3bad38`; archive SHA-256 `fd1f4ae714539b331906ae5840c935e4dceed9e3a40d21c05aad780ea4a5cc3d` |
| Worker app release | `541279aeb6a5366571e1ee8935e134c728d91c63`, unchanged |
| Worker platform | Debian systemd `252.39-1~deb12u2`, PID 1 systemd, cgroup v2 |
| Worker identity | `factory-worker`, UID 1000, only `factory-worker` group |
| Worker machine pin | `fe9b1ece921d40aeac95b10940000311` |
| Worker boot | `5734c5bd0a864f4fae49e6a088bbf2e4` |
| Runtime | Root-owned executable Node `v24.19.0`, Codex `0.159.2`, Rust binary present; this does not requalify model/authentication |
| Subscription auth | File metadata only: worker-owned mode 0600; contents were not read |
| Workload | No worker processes remain; all three root operation proofs report terminated. DEV-246/247 stage-attempt rows still say `executing` inside stopped runs. |
| Worker control | `a4c95481b898d05817d24cbcf76635d9c4b739c5`, deployed; archive SHA-256 `e805385f93cf360d79ddb3d5537d02f4cff5a544d2e33aa2cd960f05fdc7802c` |
| Coordinator configuration | Active immutable release adds the DEV-247 fixture; workstream/agent source bytes match the earlier a4 release |
| Existing SSH route | Local pinned OS Login/IAP key → coordinator → existing private worker key/host pin; no key was added |
| Coordinator integrations | Linear workflow active with coordinator-only client/signing secrets; no secret values are recorded here |
| HTTPS ingress | `https://factory.rig.ai/hooks/linear` is healthy on its separate backend; dashboard and every other path retain IAP |
| DNS | `factory.rig.ai` resolves to A `8.232.241.86` with DNS-only proxying; no AAAA record. Cloud DNS API is disabled, so DNS is externally managed. |
| Linear workspace | Rig, organization `9b259b98-cb6c-4256-88af-3a3f385c3fa7`; DEV team `41e1aa00-b853-44a9-930d-79e424259565` |
| Linear app | Client ID `571c3dc755d9e63cfe74748787f6a533`; app-user ID `ce9f2ad8-ef28-4253-bdc8-ae208f63a425`; scopes `read,write,app:assignable`; access limited to Rig/DEV |
| Pilot issues | DEV-245 is the original failed/stopped run; DEV-246 restart test and DEV-247 cancellation test are both stopped. Adam remains the human assignee. |
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
252. The worker transport suite passed 11/11 tests, the seven-check root card passed including
manager re-execution, and forced-SSH plus actual Elixir worker qualification passed. Maintenance
preserved the VM, metadata after restoration, disks, network, app config and auth/data baseline.
The worker app remains `541279aeb6a5366571e1ee8935e134c728d91c63`; no worker privilege, key,
OS Login or worker IAM grant was added. See [transport qualification](evidence/dev-233/transport-deployment.md)
and [worker preservation](evidence/dev-233/transport-worker-preservation.json).

The active coordinator is `3e81a8a418f585928bc9f4462f5187584a3bad38`, archive SHA-256
`fd1f4ae714539b331906ae5840c935e4dceed9e3a40d21c05aad780ea4a5cc3d`. It has the same
workstream and agent source bytes as a4 and adds the separately approved DEV-247 fixture in
protected configuration. Coordinator metadata and the exact archive-read permission changed;
worker resources and credentials did not. See the [coordinator plan review](evidence/dev-233/coordinator-cancellation-plan-reviewed.json)
and [activation](evidence/dev-233/coordinator-cancellation-activation.json).

The resumed App Server startup and subscription readiness check passed with GPT-6 Luna, medium
effort and Daybreak disabled. It created a session but no model turn, then stopped its exact
contained operation. No reset was consumed and no API-billing fallback was used. Earlier
`usage_paused` and startup-timeout observations are historical; they preceded successful
reauthentication. See the [readiness result](evidence/dev-233/app-resume-readiness.json) and
[termination proof](evidence/dev-233/app-resume-stop-proof.json).

DEV-246 produced an acknowledged live run. A foreground `sleep 180` was observed inside its
exact operation cgroup. Coordinator restart preserved the run/session/acknowledgement and did
not launch a replacement, but SSH EOF ended the worker processes and the run entered
reconciliation. This does not pass active-work survival across restart. Later native
undelegation stopped that run. DEV-247 then produced another acknowledged run; native
undelegation while its foreground sleep was live stopped the same run. Root proof recorded
MainPID 0 and a released empty cgroup. Both created-event replays returned 200 duplicate and
401 for the zero-signature control; the unrelated description-event replay returned 422
unsupported-event and 401 for its negative control.

The final audit found all three runs stopped and all three exact worker termination proofs
recorded, with no worker processes remaining after an idle coordinator restart. DEV-246
reconciliation remains `:unknown`, and the DEV-246 and DEV-247 stage-attempt rows still say
`executing` inside stopped runs; the root receipts resolve worker termination but do not clear
that durable metadata. Dashboard viewer access, token lifecycle accounting, Daybreak and scale remain
unqualified. See the [native live acceptance record](evidence/dev-233/native-live-acceptance.md)
for run identities and receipts.

## Deployed coordinator and worker

Worker-control repair and qualification are complete for the pinned worker under systemd 252;
the exact transport and preservation records are in the [evidence index](evidence/dev-233/README.md).
The maintenance steps and intermediate failures are recorded in [maintenance
attempts](evidence/dev-233/transport-maintenance-attempts.json); worker privilege and access
changes, plus the coordinator-only archive-read permission, are scoped above.

Coordinator wiring selects `pilot|linear`, loads only two pinned coordinator credentials,
checks reference/version/release consistency, and preserves active pins for restart/rollback.
The active immutable coordinator is `3e81a8a418f585928bc9f4462f5187584a3bad38`, with the
DEV-247 route in protected configuration. It retains the a4 workstream/agent bytes. The exact
HTTPS webhook route remains separate from the IAP dashboard and other paths. See the [ingress
receipt](evidence/dev-233/https-ingress.md), [current activation](evidence/dev-233/coordinator-cancellation-activation.json)
and [live acceptance record](evidence/dev-233/native-live-acceptance.md).

## Decisions and current status

1. **Worker control:** deployed and qualified on the pinned machine/boot under systemd 252.
   The 11 transport tests, seven-check root card, forced-SSH operations and actual Elixir
   qualification passed. The worker app remains on release
   `541279aeb6a5366571e1ee8935e134c728d91c63`. The active coordinator is immutable release
   `3e81a8a418f585928bc9f4462f5187584a3bad38`; the worker app and worker control were unchanged.
2. **Hostname and ingress:** `factory.rig.ai` and managed-domain dashboard access
   `domain:rig.ai` are selected. The HTTPS `/hooks/linear` backend is active and healthy;
   dashboard and all other paths retain IAP. Actual signed-in dashboard access is still
   untested. See the [ingress receipt](evidence/dev-233/https-ingress.md).
3. **Linear app and issue routing:** the installed app has
   client ID `571c3dc755d9e63cfe74748787f6a533`, app-user ID
   `ce9f2ad8-ef28-4253-bdc8-ae208f63a425`, and `read,write,app:assignable` scopes. Its token
   sees the Rig organization and DEV team. DEV-245 retains Adam as assignee, has
   `factory:rig`; that historical run failed before a thread or turn. DEV-246 tested restart
   during active work; DEV-247 tested active undelegation with exact root termination proof.

## Remaining acceptance work

DEV-247 active-work undelegation passed with a contained sleep and exact root proof. DEV-246
restart preserved the run/session/acknowledgement and did not launch a replacement, but the
worker processes were gone after the SSH stream closed; the stream closure appears to have
ended the operation. Restart survival therefore failed. The final audit also found DEV-246
reconciliation `:unknown` and DEV-246/247 stage-attempt rows still `executing` inside stopped
runs, despite retained root termination proofs. Do not mark DEV-233 complete or open an
acceptance PR until restart survival and durable metadata reconciliation are resolved. The
bounded bootstrap-token observation does not establish a long-term token lifecycle; dashboard
viewer access, Daybreak and scaled capacity remain unqualified. See the
[native live acceptance record](evidence/dev-233/native-live-acceptance.md).
