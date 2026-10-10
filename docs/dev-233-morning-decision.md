# DEV-233 morning decision card

Prepared from read-only checks on 2026-10-10, 07:37–07:48 UTC. No question was sent
overnight. No broker/account installation, privileged systemd card, public ingress,
IAM grant, app creation, secret payload access, release activation, push or PR was performed.

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
| Control installation | No `factory-control` account, broker service/socket/config or containment receipt |
| Existing SSH route | Local pinned OS Login/IAP key → coordinator → existing private worker key/host pin; no key was added |
| Coordinator integrations | Legacy idle pilot; only `worker_ssh` secret ref, no integration environment names, ingress off |
| HTTPS inventory | No forwarding rules or SSL certificates returned in this project |
| DNS | Cloud DNS API disabled; this does not establish absence of externally hosted DNS |
| Linear workspace | Rig, organization `9b259b98-cb6c-4256-88af-3a3f385c3fa7`; DEV team `41e1aa00-b853-44a9-930d-79e424259565` |
| Linear setup still unknown | Connector search found no `Default Cloud` user or `factory:rig` label; app admin settings/installation were not available through that search |
| Secret containers | Name-only search for `linear` returned no containers; no values or versions were accessed |

See [worker preflight](evidence/dev-233/worker-preflight.json),
[coordinator preflight](evidence/dev-233/coordinator-preflight.json) and
[name-only secret inventory](evidence/dev-233/linear-secret-inventory.json).
These are point-in-time observations, not a containment or live-delegation receipt.

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

## Decisions queued for morning

1. **Existing idle worker:** authorize the reviewed root broker/account installation and
   disposable qualification card, including PID 1 re-execution, on this existing worker.
   Worker root maintenance access was not established by the read-only service-user SSH
   route. Use the existing administrator's GCP maintenance route; no new SSH/IAM grant is
   assumed. No new VM, project, region or key pair is needed by the source design.
2. **Hostname and dashboard access:** choose a DNS hostname controlled by Rig, confirm
   DNS administration and Google-managed IAP eligibility, and provide the dashboard viewer
   allowlist. `factory.rig.ai` is only an example, not a selected or verified hostname.
   The same host can receive `/hooks/linear` through the separate signed backend. Review
   the concrete Terraform plan before authorizing public ingress or credential IAM changes.
3. **Assignable Linear app:** identify/install one app using app authentication and record
   its app-user/OAuth-client UUIDs. Provision separate OAuth/signing values privately to
   pinned Secret Manager versions; do not paste values into chat/YAML/evidence. Confirm or
   create the `factory:rig` label and choose one disposable DEV issue with its human owner
   intact. No app identity is inferred from project/team membership.

## Exact staged commands after those decisions

These commands are preparation instructions, not evidence that they ran. Replace the
candidate revision with the committed, tested source head and the release checksum from
`cloud_io.py pack`. Read the [release deployment walkthrough](gcp-pilot.md) before any plan.

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
  LINEAR_API_KEY   = "linear_oauth"
  LINEAR_API_TOKEN = "linear_signing"
}
optional_integration_secrets = {
  linear_oauth   = { secret_id = "<chosen-oauth-container>", version = "<numeric-version>" }
  linear_signing = { secret_id = "<chosen-signing-container>", version = "<numeric-version>" }
}
enable_https_iap = true
enable_linear_webhook = true
viewer_hostname = "<chosen-hostname>"
iap_viewer_emails = ["<approved-viewer>"]
iap_google_managed_oauth_confirmed = true # Only after confirming eligibility.
```

Keep existing optional refs rather than replacing unrelated entries. Check the plan for
VM replacement, disk/data loss, unrelated IAM changes, retained prior credential access,
and the exact IAP/default and webhook routes. Apply remains pending authorization.
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

Once the verified release and the existing coordinator's **public** key are staged on
the idle worker, the reviewed root installation/card is:

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

Then qualify the forced-command SSH path from the coordinator and run the
[live delegate/replay/restart/stop card](linear-delegation.md#live-acceptance-checklist-pending).
Keep publisher/merge credentials outside these environments. No acceptance PR or DEV-233
completion claim until the real app, HTTPS delivery, one-run recovery and whole-tree stop pass.
