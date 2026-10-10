# DEV-233 morning decision card

The initial read-only snapshot was taken on 2026-10-10, 07:37–07:48 UTC. It preceded
worker maintenance and the DNS change recorded below. The live worker control path is now
installed and qualified. Dashboard HTTPS ingress has been applied with IAP for `domain:rig.ai`;
certificate issuance and signed-in access are tracked separately. The public webhook
route, native Linear acceptance, push and PR remain pending.

## Confirmed facts

| Item | Observed result |
| --- | --- |
| Existing project/region/zone | `factory-511117`, `us-central1`, `us-central1-a` |
| Worker | `rig-factory-worker-01`, running, private IP `10.42.0.2` |
| Coordinator | `rig-factory-coordinator`, running, private IP `10.42.0.3`, service active |
| Active release on both | `541279aeb6a5366571e1ee8935e134c728d91c63` |
| Worker platform | Debian systemd `252.39-1~deb12u2`, PID 1 systemd, cgroup v2 |
| Worker identity | `factory-worker`, UID 1000, only `factory-worker` group |
| Worker machine pin | `fe9b1ece921d40aeac95b10940000311` |
| Runtime | Root-owned executable Node `v24.19.0`, Codex `0.159.2`, Rust binary present; this does not requalify model/authentication |
| Subscription auth | File metadata only: worker-owned mode 0600; contents were not read |
| Workload | No visible Codex/Node/Cargo/Rust or operation units; about 61 GiB memory available and 461 GiB data disk free |
| Control installation | Installed and active; root containment receipt passed on systemd 252. The actual coordinator forced-SSH path also passed. See the current outcome below. |
| Existing SSH route | Local pinned OS Login/IAP key → coordinator → existing private worker key/host pin; no key was added |
| Coordinator integrations | Legacy idle pilot; only `worker_ssh` secret ref, no integration environment names. The current HTTPS plan has no Linear webhook route. |
| HTTPS inventory | Initial inventory had no forwarding rules or SSL certificates. A dashboard-only plan has since been reviewed; apply is pending separately. |
| DNS | `factory.rig.ai` resolves to A `8.232.241.86` with DNS-only proxying; no AAAA record. Cloud DNS API is disabled, so DNS is externally managed. |
| Linear workspace | Rig, organization `9b259b98-cb6c-4256-88af-3a3f385c3fa7`; DEV team `41e1aa00-b853-44a9-930d-79e424259565` |
| Linear setup still unknown | Connector search found no `Default Cloud` user or `factory:rig` label; app admin settings/installation were not available through that search |
| Secret containers | Name-only search for `linear` returned no containers; no values or versions were accessed |

See [worker preflight](evidence/dev-233/worker-preflight.json),
[coordinator preflight](evidence/dev-233/coordinator-preflight.json) and
[name-only secret inventory](evidence/dev-233/linear-secret-inventory.json).
The original preflight files remain point-in-time observations; current containment
evidence is recorded separately below.

## Current outcome after worker qualification

The root card passed on control source `cc85ca7871a27afb03bc2b6e86722a142ff93e7e`,
archive SHA-256 `59a9c8668cc258ce19fc50d9d339d3c6fa1920b70b8b14c531bdbfeb6124cb01`,
systemd 252, machine `fe9b1ece921d40aeac95b10940000311` and boot
`4418dae454694f88ab9bbc4280b94547`. The broker service is active. The card passed held
launch, duplicate prepare, stale identity rejection, `setsid` child termination, natural
exit, restart recovery and manager re-execution. The coordinator's real forced-SSH checks
also passed RPC/stream, stop proof and replay, natural-exit proof and replay; arbitrary
commands were rejected.

The maintenance retained the same VM instance, restored metadata exactly, and preserved
disks and network configuration. The active application release remains
`541279aeb6a5366571e1ee8935e134c728d91c63`. The coordinator has not run the Elixir
`WorkerOperation.qualify/1` call. HTTPS ingress, the installed Linear app and the native
delegate/replay/restart/stop pilot remain unverified. The card log records Python
`ResourceWarning`s for helper `Popen` handles; both task processes and the operation cgroup
were independently observed dead/empty after stop. A later read-only process check found
both warned helper PIDs absent; it does not establish that Python closed every helper handle.
See the [evidence index](evidence/dev-233/README.md#live-contained-worker-qualification-2026-10-10).

Dashboard viewer selection is resolved: the user chose everyone in the managed
`rig.ai` domain, represented by the IAP principal `domain:rig.ai`. This means Google
Workspace/Cloud Identity domain members, rather than an email-suffix check. Live project ownership and organization name were verified: organization
`655940658710`, display name `rig.ai`, active. This supports the selected
Google-managed IAP configuration; actual signed-in domain-member access remains
unverified until its separate browser check. Google documents
[domain principal identifiers](https://docs.cloud.google.com/iam/docs/principal-identifiers)
and [IAP domain access](https://docs.cloud.google.com/iap/docs/authenticate-users-google-accounts).
This selection does not grant worker maintenance or SSH access.

## Locally prepared changes

The reviewed checkpoint `77f72fafbb0806fa6b724aed2403896c84bcaead` remains in history.
The follow-up source supports systemd 252 with the same isolation/proof requirements;
only the unsupported expansion flag is omitted, and fixed manager paths reject `$`/`%`.
The root-owned passing receipt is still mandatory. The privileged card adds explicit
manager re-execution coverage alongside held launch, replay, escaped child termination,
natural exit and recovery. No OS upgrade is proposed for this pilot.

Coordinator wiring now selects `pilot|linear`, loads only two pinned coordinator
credentials, checks reference/version/release consistency, and preserves active pins for
restart/rollback. Integration changes require a distinct committed release. The public
webhook has its own POST-only listener on 8081 and exact HTTPS route; dashboard/API keep IAP.
All ingress remains default-off. Local test results are in the [evidence index](evidence/dev-233/README.md).

The root review assumptions changed for the v252 CLI/proof floor, credential bootstrap and
the separate public listener. Targeted review checked those changes; it is source review,
not permission to install, grant access, expose ingress or claim host qualification.

## Decisions and remaining deployment work

1. **Existing idle worker:** completed. The control service and root qualification receipt
   are installed, and the live forced-SSH operation path passed. The existing app release
   remains unchanged. The Elixir `WorkerOperation.qualify/1` call is still required before
   native dispatch; see the [access check](evidence/dev-233/worker-maintenance-access.json)
   for the earlier route investigation. No new VM is proposed.
2. **Hostname and eligibility:** selected `factory.rig.ai` and managed-domain access for
   `domain:rig.ai`. DNS resolves to `8.232.241.86` and has no AAAA record. The live GCP
   organization is `655940658710` with `rig.ai` active; the project belongs to that
   organization. Signed-in viewer access remains a separate check. Dashboard viewers need no individual email list. The applied
   dashboard HTTPS configuration has no `/hooks/linear` route. See
   [the ingress receipt](evidence/dev-233/https-ingress.md) before adding public webhook
   ingress or credential IAM changes.
3. **Assignable Linear app:** identify/install one app using app authentication and record
   its app-user ID and exact OAuth Client ID. Enable client-credentials tokens with
   `read,write,app:assignable`, and provision separate client/signing secrets privately to
   pinned Secret Manager versions; do not paste values into chat/YAML/evidence. Confirm or
   create the `factory:rig` label and choose one disposable DEV issue with its human owner
   intact. No app identity is inferred from project/team membership.

## Remaining deployment steps

These are preparation instructions, not evidence that ingress or the Linear app is live.
Use the committed, tested source head and release checksum from `cloud_io.py pack`. Read
the [release deployment walkthrough](gcp-pilot.md) before any plan.

```bash
python3 factory/deploy/cloud_io.py pack "$PWD" /private/tmp/dev233-release
# Inspect the emitted revision, checksum and archive before uploading with --no-clobber.
# Update only the existing private pilot inputs and review the complete plan.
terraform -chdir=infra/gcp/pilot plan \
  -var-file=/absolute/private/pilot.tfvars -out=/private/tmp/dev233-pilot.plan
terraform -chdir=infra/gcp/pilot show /private/tmp/dev233-pilot.plan
```

The private inputs keep the existing project/region/zone/key route and add:

```hcl
coordinator_workflow = "linear"
coordinator_secret_env = {
  LINEAR_API_KEY   = "linear_client"
  LINEAR_API_TOKEN = "linear_signing"
}
optional_integration_secrets = {
  linear_client  = { secret_id = "linear-client-secret", version = "<numeric-version>" }
  linear_signing = { secret_id = "linear-webhook-signing", version = "<numeric-version>" }
}
enable_https_iap = true
enable_linear_webhook = true
viewer_hostname = "factory.rig.ai"
iap_viewer_domains = ["rig.ai"] # Emits domain:rig.ai on the dashboard backend only.
iap_viewer_emails = [] # Existing email inputs remain supported when needed.
iap_google_managed_oauth_confirmed = true # Only after confirming organization/domain eligibility.
```

Keep existing optional refs rather than replacing unrelated entries. The dashboard HTTPS
plan was reviewed at 10 creates, 0 updates and 0 deletes with an explicit temporary
metadata-ignore overlay. It is dashboard-only; it has no Linear webhook route. Confirm the
VM, disk, IAM and routing details against the retained plan before applying. HTTPS was not
yet live when this card was updated.
Protect the source/workspace boundary: never launch a factory agent in this checkout.

On the coordinator, install a fully filled dedicated workflow as root without clobbering:

```bash
install -d -o root -g root -m 0755 /etc/factory/workflows
test ! -e /etc/factory/workflows/<candidate-revision>.md
install -o root -g root -m 0644 /root/dev233-WORKFLOW.md \
  /etc/factory/workflows/<candidate-revision>.md
```

Use the [complete workflow configuration](linear-delegation.md#configuration), with
`server.host: 0.0.0.0`, `server.port: 8080`, `server.webhook_host: 0.0.0.0` and
`server.webhook_port: 8081`. Pin the actual release, worker machine, control command,
definition path and disposable dedicated Rig workspace on both hosts. Requalify Default
Cloud on this revision; the file/binary preflight is not model or subscription proof.

The following root installation/card commands were run on the idle worker and produced the
passing receipts linked above. They are retained for audit; do not repeat the manager
re-execution card unless deliberately requalifying the idle worker:

```bash
/opt/factory/releases/<candidate-revision>/factory/deploy/install-worker-operations.sh \
  /opt/factory/releases/<candidate-revision> /root/coordinator-public-key
FACTORY_SYSTEMD_TEST_DISPOSABLE=1 FACTORY_SYSTEMD_TEST_MANAGER_REEXEC=1 \
  FACTORY_SYSTEMD_TEST_RECEIPT=/root/worker-operations-qualification.json \
  /usr/bin/python3 -I \
  /opt/factory/releases/<candidate-revision>/factory/deploy/tests/test_worker_operation_systemd.py
# Inspect every check and cleanup outcome before installing the receipt:
install -o root -g root -m 0600 /root/worker-operations-qualification.json \
  /etc/factory/worker-operations-qualified.json
systemctl daemon-reload
systemctl enable --now factory-worker-operations.service
systemctl is-active factory-worker-operations.service
```

The forced-command SSH path has since passed from the coordinator. Still run the live Elixir
`WorkerOperation.qualify/1` call against the exact configured release, requalify Default
Cloud on that revision, then run the
[live delegate/replay/restart/stop card](linear-delegation.md#live-acceptance-checklist-pending)
after HTTPS and app setup. Keep publisher/merge credentials outside these environments. No
acceptance PR or DEV-233 completion claim until the real app, HTTPS delivery, one-run recovery
and whole-tree stop pass.
