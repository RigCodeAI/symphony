# GCP pilot operator walkthrough

This is DEV-230's manual cloud pilot for `RigCodeAI/symphony`, targeting a
disposable clone of `RigCodeAI/rig`. The existing Symphony coordinator runs with
an empty memory tracker. A command on the coordinator submits the merged DEV-229
two-stage runner to the worker over private SSH. Native Linear dispatch, durable
stage recovery, conversation viewer and production candidate validation belong
to later tickets.

Deployment status and pilot evidence are tracked in
[DEV-230](https://linear.app/rigai/issue/DEV-230/provision-and-actually-deploy-the-gcp-pilot-with-terraform).
Configuration and local checks alone do not establish a working deployment.

For DEV-233's proposed native Linear deployment, use the
[coordinator procedure](linear-delegation.md#gcp-coordinator-deployment) and
[morning decision card](dev-233-morning-decision.md). The default manual pilot remains idle.
The new path requires a protected revision-specific workflow installed without clobbering,
separate coordinator-only credential refs, real worker containment qualification and an
explicit signed webhook ingress route. Integration pin changes require a distinct release.
None of these DEV-233 deployment actions has been performed.

## Historical verification on source `445f251`

The original live manual pilot checks passed on source
`445f25184a53f48300f5d585392a011b042a0aef`, release SHA-256
`6054a90eedd33d931ef989c569e6bd91c722577d5379bdb87836f03e1f45603e`.
This source is now historical: a later review confirmed startup for both
coordinator and worker ran Mix/build steps as root against each role's
service-owned dependency/build tree, and root bootstrap could reuse legacy
worker-owned tools. The repaired revision and its live checks are recorded below; the
historical smoke does not validate that repair.
The reviewed compute-only teardown removed exactly two VMs and four dependent
access/alert resources; recreation added exactly those six resources. Four
protected disks, state, archives and backups were retained. The recreated
coordinator (`5979280685983365649`) and worker (`3666704121532283408`) reached
`startup_ready` at 04:55:47 and 04:55:27 UTC, on private addresses `10.42.0.3`
and `10.42.0.2`, with no external IPs. All four attached disks have
`autoDelete=false`.

Before fresh model runs, retained markers, earlier reports and worker auth
metadata matched their receipts. The worker auth file remained regular mode
`0600`, owned by UID 1000, with its prior modification time. ChatGPT login with
Codex CLI `0.159.2`, Rust `1.91.1`, DNS, namespaces, denied worker metadata
access, absent Git read token, disabled push URL and no worker `sudo` were
verified. Strict private SSH passed with the retained key and unchanged GCS pin
generation `1791607845060213`.

Fresh pass and expected-failure runs both passed their pilot checks on source
`445f251` at the time. The pass run completed with gate exit 0 and runner exit 0.
The negative run had the expected gate exit 101 and blocked runner exit 1; its pilot wrapper
correctly returned success. Each run's six permanent artifacts was downloaded
and checked against its manifest. Monitoring returned CPU, memory and disk
metrics for both new instances and no duplicate-error matches through 04:57:10.
The final Terraform drift plan returned no changes (detailed exit code 0).
See the [pilot evidence receipt](dev-230-evidence.md) for run IDs, hashes and
the exact verification record.

Local checks recorded for source `445f251` passed: Terraform format/validation
for all three roots, three mock-provider plans, 19 Python tests, 12 shell syntax
checks, and the Linux OpenSSH host-key/runtime fixture. The Linux Elixir build and 52 focused tests
passed; full `mix test` passed 408 with zero failures, six skipped and ten
excluded. `make all` still reports existing Credo style issues (46 refactoring,
37 readability), recorded under the alpha exception.

The earlier subscription smoke used `b2d34daf8e9f49e1fb53f5999f6c4e7278299b68`;
it is historical evidence for that release only. The missing-agent candidate
was rejected on `67d7fb1`, with both active links and six configuration hashes
unchanged, and the reviewed `67d7fb1` configuration was restored. No invalid
candidate was tested on `445f251`.

The first compute recreation failed when GCE regenerated worker host keys; a
later recovery boot exposed missing `/run/sshd`. Source `445f251` retains
the root-only host key on the data disk, orders SSH after the mount, and
validates/creates `/run/sshd` before restarting SSH. A one-time pin rotation was
authenticated against GCP project and VM identity plus the VM serial-console
public key; no live handshake or `ssh-keyscan` was trusted. Receipts are in the
[host-key rotation archive](gs://factory-511117-rig-factory-archive/deployments/dev230/hostkey-rotation-20261010/).

Coordinator restart and worker stop/start plus manual archive/backup service
invocations passed on `67d7fb1`. The verified backup had `databases: []`; it is
a configuration snapshot, not task-state or in-flight recovery. Periodic timer
cadence and alert delivery were not measured. Credits remain unverified after
the user's waiver of the balance/expiry check.

Historical `445f251` redacted receipt destination:
`gs://factory-511117-rig-factory-archive/deployments/dev230/final-20261010-445f251/`.
Its `manifest.json` records artifact digests.

## Restart-privilege repair verification

Current tested service source: `541279aeb6a5366571e1ee8935e134c728d91c63`.
Release SHA-256: `40a3e683da0ce8a074de05ca335a5daf44ab0e974a2bed78acdf446abc1af242`.
Both existing VMs activated this release without replacement or disk changes.

Mix/build commands run as the service user with a cleared environment and role
caches, set after mise selects the runtime. The coordinator launches the CLI
from its matching user-built Mix project so SQLite can load its physical native
library. Startup does not compile or fetch dependencies. Root validates its
source, runtime and protected tool trees
before reuse; it never executes the legacy worker-owned tools. SSH/Codex home
setup runs as the service user and rejects symlinks. The worker's executable Mix
entrypoint preserves the external timeout.

Two actual Linux builds and the root-path, symlink, activation, service-entrypoint
and timeout fixtures passed. Repeated live startup on this exact source evaluated
a modified cached dependency as UID 1000 with the intended Mix home; its original
bytes were restored and checked against the pre-test hash. The coordinator and
worker recorded `startup_ready` at 05:56:15 and 05:58:36 UTC.

Fresh subscription runs `dev230-boundary-20261010b` and
`dev230-boundary-fail-20261010b` verified complete/gate 0 and blocked/gate 101.
Their twelve artifacts independently matched permanent manifests. At 06:02:28
both machines were healthy and idle; archive maintenance succeeded and final
Terraform drift returned no changes. The same Credo 46/37 baseline remains in
broad CI; other checks passed. No merge was performed.

See [the evidence receipt](dev-230-evidence.md) for exact hashes, intermediate
failures, restoration details and verification limits. Repair receipts are in
`gs://factory-511117-rig-factory-archive/deployments/dev230/build-boundary-20261010-541279a/`.
This pilot does not claim production or arbitrary-code isolation.

## Proposed pilot and approved spending input

Project: `factory-511117`, expected number `292978199748`. Region `us-central1`,
zone `us-central1-a`; live quota is sufficient and both private VM types were created. Start with one
`e2-standard-2` coordinator and one `n2-standard-16` worker. Data disks are 100
and 500 GiB; boot disks are 30 and 50 GiB. All disks use zonal `pd-balanced`.
`worker_count` is configurable between zero and one; DEV-244 qualifies expansion.

The user supplied **$2,000** as the pilot spending limit on 2026-10-09, interpreted
as the monthly GCP alert budget. It does not authorize API model billing, broader
worker capacity or repository-wide administration. Budget alerts are alerts,
not an automatic stop mechanism. Stop the worker when idle and inspect costs.

Estimated fixed cost for 730 hours of continuous operation:

| Item | USD/month estimate |
| --- | ---: |
| Coordinator at $0.06701142/hour | 48.92 |
| Worker at $0.776944/hour | 567.17 |
| 680 GiB balanced disks at approximately $0.10/GiB-month | 68.00 |
| NAT for two VMs plus one external NAT address | 5.69 |
| Base with HTTPS ingress disabled | 689.78 |
| Optional HTTPS forwarding rule plus external address | 21.90 |

Allow approximately $750–850/month for a low-volume pilot including modest
archive growth, snapshots, logs, transfer and optional ingress. This allowance is
not a measured bill or cap. GCP credits, discounts, taxes and model charges are
unverified. Permanent evidence grows with use. Retained disks keep costing about
$68/month after compute teardown; storage, snapshots and network resources also
continue to incur charges until deliberately removed.

Prices checked on 2026-10-09: [VM pricing](https://cloud.google.com/products/compute/pricing/general-purpose),
[disk pricing](https://cloud.google.com/compute/disks-image-pricing),
[NAT pricing](https://cloud.google.com/nat/pricing),
[network pricing](https://cloud.google.com/vpc/network-pricing).

## Restore access and verify the project

The operator account is `adam@rig.ai`; GCP CLI sign-in is working. Its default
project remains `rig-web`. Use explicit
project arguments and never change another project's infrastructure.

```bash
gcloud auth login adam@rig.ai
gcloud projects describe factory-511117 \
  --format='json(projectId,projectNumber,lifecycleState,parent)'
gcloud billing projects describe factory-511117 --format=json
gcloud compute regions describe us-central1 --project=factory-511117 \
  --format='table(quotas.metric,quotas.limit,quotas.usage)'
gcloud compute instances list --project=factory-511117
gcloud compute images list --project=debian-cloud --no-standard-images \
  --filter='name~^debian-12-bookworm-v' --sort-by=~creationTimestamp --limit=3
```

Expected project number: `292978199748`, project active, billing enabled and
quota for at least 18 vCPUs plus the disks. Choose an exact dated Debian 12 image,
never an image family. Also inspect existing buckets, service accounts and
secrets before applying; import deliberate matching resources instead of
overwriting existing ones.

Open [the project's billing page](https://console.cloud.google.com/billing?project=factory-511117),
follow its linked billing account to inspect **Credits** if needed. The user
waived the balance/expiry check on 2026-10-09; credit coverage remains unverified.
A linked billing account alone does not prove credit coverage.
Record the billing account ID without payment details. Confirm budget/monitoring
notification recipients and IAP operator accounts; recommend `adam@rig.ai` for
the initial pilot. Grant only scoped deployment/operator permissions if existing
access lacks them; do not make blanket IAM changes as a workaround.

For Terraform, use a short-lived operator access token, never a checked-in key:

```bash
export GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)"
```

Do not use shell tracing or print this environment variable. Refresh it when
expired. Terraform requires Compute, service account/IAM, Secret Manager, GCS,
monitoring and billing-budget administration for the scoped resources. Required
APIs are enabled by the pilot root without disabling them on teardown.

## State bootstrap and release staging

Use Terraform `1.13.5`; the committed lockfiles pin the Google provider. Copy
`infra/gcp/pilot/terraform.tfvars.example` to a private, ignored inputs file.
Fill release SHA/hash, dated image, billing account, `$2,000` budget, recipients,
operator emails, SSH public key and numeric secret version IDs. Secret payloads
must never appear in those inputs.

The first state-bucket bootstrap uses local state because its GCS bucket does
not exist yet. Review the bootstrap plan before applying it. Keep that local
bootstrap state private and back it up to the new bucket; do not delete it or
use a second root to manage the same bucket.

```bash
terraform -chdir=infra/gcp/bootstrap init
terraform -chdir=infra/gcp/bootstrap plan -out=/tmp/dev230-state.plan
# Apply only the reviewed plan after confirming project, billing and budget.
terraform -chdir=infra/gcp/bootstrap apply /tmp/dev230-state.plan
gcloud storage cp infra/gcp/bootstrap/terraform.tfstate \
  gs://factory-511117-symphony-tfstate/bootstrap/terraform.tfstate
terraform -chdir=infra/gcp/pilot init \
  -backend-config=backend.hcl.example
```

The bootstrap state copy is a recovery copy; the pilot root uses a real GCS
backend with locking and versioning. Archive objects and Terraform state are in
different buckets. Operator access to state is independent of runtime identities.

Commit the service code before packaging. Packaging rejects a dirty source tree;
it records the source commit and prints only artifact identifiers/checksums.

```bash
python3 factory/deploy/cloud_io.py pack . /tmp/dev230-release.tar.gz
```

Use the printed commit, `release_object` and `release_sha256` in private inputs.
First plan/apply the pilot with `compute_enabled=false` to establish storage,
identities, empty secret containers, budgets and retained disks. This stage is
billable too; its reviewed plan is part of the same spending decision. Upload
the release artifact to the `release_bucket` output under the printed object
name. Use `gcloud storage cp --no-clobber` so an existing pinned release is not
overwritten.

## Load credentials outside Terraform

The user selected Codex subscription authentication and a GitHub credential
limited to reading `RigCodeAI/rig`. Do not reuse a desktop GitHub token with
push/PR permissions on a worker. Prepare a fine-grained GitHub token with access
to that repository and **Contents: read-only**. No publisher credential is
installed on this pilot. Git cloning uses the token only during root bootstrap;
the token is removed before the agent runs.

After the empty containers exist, run these commands locally. They upload bytes
without printing credentials. `codex login status` must report ChatGPT. Never
paste credentials into Linear or this chat.

```bash
codex login status
gcloud secrets versions add model-auth --project=factory-511117 \
  --data-file="$HOME/.codex/auth.json"
read -rs 'dev230_read_token?Read-only Rig token: '
printf '%s' "$dev230_read_token" | gcloud secrets versions add git-read \
  --project=factory-511117 --data-file=-
unset dev230_read_token
dev230_keydir="$(mktemp -d)"
ssh-keygen -q -t ed25519 -N '' -f "$dev230_keydir/worker"
gcloud secrets versions add worker-ssh --project=factory-511117 \
  --data-file="$dev230_keydir/worker"
cat "$dev230_keydir/worker.pub"  # Public half only: put in private Terraform inputs.
rm -r "$dev230_keydir"
```

Pin the numeric versions returned by those uploads. Version IDs are safe inputs;
payloads and `latest` are not. The worker keeps its regular mode-0600 Codex auth
file on the retained disk so token refresh survives restart. The same pinned
secret ID/version preserves that file; changing the pinned version explicitly
seeds credential rotation. Evidence and configuration object backups exclude
this file. Protected data-disk snapshots can contain runtime authentication and
must retain the same private access controls as the disk. Check that the uploaded Codex auth file is subscription
authentication rather than an API key before upload. If a CLI uses a keyring,
perform subscription sign-in on a disposable worker setup and upload its auth
file deliberately; do not invent an export or silently switch billing modes.

Generate the SSH key before the first pilot plan if that plan requires its
public half; keep the private half mode 0600 until secret-container staging is
complete, then upload and remove it. Only the coordinator has access to its
private key. The worker's SSH host private key is retained root-only under
`/srv/factory/ssh-host-keys`; `sshd` is configured to use that key. A systemd
drop-in requires `/srv/factory` to be mounted and checks the mountpoint before
`ssh.service` starts, so a new VM cannot silently fall back to GCE-generated
host keys. Bootstrap creates and validates `/run/sshd` as root-owned mode `0755`
on each boot before restarting SSH, because `/run` is temporary. The matching
public key is published through the scoped GCS identity and pinned in coordinator
`known_hosts`; no public worker SSH or unauthenticated host-key discovery is
enabled.

## Apply and inspect the real service

```bash
terraform -chdir=infra/gcp/pilot plan -var-file=/absolute/private/pilot.tfvars \
  -var=compute_enabled=true -out=/tmp/dev230-pilot.plan
terraform -chdir=infra/gcp/pilot show /tmp/dev230-pilot.plan
# Apply the exact reviewed plan, then retain redacted apply output and IDs.
terraform -chdir=infra/gcp/pilot apply /tmp/dev230-pilot.plan
terraform -chdir=infra/gcp/pilot output -json
gcloud compute ssh rig-factory-coordinator --project=factory-511117 \
  --zone=us-central1-a --tunnel-through-iap
```

Inside the coordinator:

```bash
sudo systemctl status factory-coordinator --no-pager
sudo journalctl -u google-startup-scripts -n 100 --no-pager
sudo journalctl -u factory-coordinator -n 100 --no-pager
curl --fail http://127.0.0.1:8080/api/v1/state
cat /srv/factory/active.json
sudo systemctl restart factory-coordinator
curl --fail http://127.0.0.1:8080/api/v1/state
```

Expected: bootstrap finishes, coordinator is active, health returns JSON,
`active.json` identifies the deployed commit/hash, and restart returns healthy.
Wait for `FACTORY_EVENT startup_ready` on each VM before running the smoke.
Use Cloud Logging to inspect the worker startup logs; SSH operators enter
through the coordinator, not a public worker address.

For a browser dashboard, use an IAP SSH tunnel:

```bash
gcloud compute ssh rig-factory-coordinator --project=factory-511117 \
  --zone=us-central1-a --tunnel-through-iap -- -N -L 8080:127.0.0.1:8080
```

Open [localhost:8080](http://localhost:8080). Stop the tunnel with Ctrl-C.
Optional managed HTTPS/IAP infrastructure is gated by a verified hostname,
organization support and an explicit Google identity allowlist. Proposed
`factory.rig.ai` and `hooks.factory.rig.ai` are inputs, not configured DNS or live
webhook endpoints. Do not publish the dashboard without the identity gate.

The selected dashboard audience is the managed `rig.ai` domain. Set
`iap_viewer_domains = ["rig.ai"]` to produce `domain:rig.ai`, scoped to the dashboard
backend's `roles/iap.httpsResourceAccessor`. Existing `iap_viewer_emails` inputs retain
their user grants and Terraform resource addresses; both inputs can be combined.
These dashboard inputs grant no operator SSH or OS Login access. Confirm that `rig.ai`
is a Google Workspace/Cloud Identity managed domain and its intended users are eligible
for this project's Google-managed IAP OAuth before enabling ingress. That confirmation
is pending; a matching email suffix alone is insufficient. See Google's
[principal identifiers](https://docs.cloud.google.com/iam/docs/principal-identifiers)
and [IAP authentication guidance](https://docs.cloud.google.com/iap/docs/authenticate-users-google-accounts).

## Smoke, definition rejection and retention

From the coordinator as its service identity, submit the same definition used
in the local qualification:

```bash
sudo -u factory-coordinator /opt/factory/current/factory/deploy/factory-pilot \
  submit rig-factory-worker-01 dev230-pass-001 pass
sudo -u factory-coordinator /opt/factory/current/factory/deploy/factory-pilot \
  submit rig-factory-worker-01 dev230-fail-001 fail
sudo systemctl start factory-maintenance@archive.service
sudo systemctl start factory-maintenance@backup.service
```

Expected pass: real subscription app-server turn, one regression test passes,
workstream complete, exit 0. Expected fail: the intentionally wrong assertion
fails, workstream blocked, runner exit nonzero. The pilot command itself exits
zero when it verifies this expected failure. Reports record the definition digests,
immutable service revision, coordinator origin and private worker address. Both
clones have publishing disabled; neither Rig candidate is pushed. A worker lock
rejects concurrent smoke submissions and unique run IDs reject accidental reuse.
The verified 2026-10-10 runs (`dev230-pass-20261010a` and
`dev230-fail-20261010a`) used revision `b2d34daf8e9f49e1fb53f5999f6c4e7278299b68`,
before the `67d7fb1` rollout. After compute recreation, source `445f251` was
smoked with `dev230-recreate-20261010a` and
`dev230-recreate-fail-20261010a`; both expected outcomes passed. The fresh pass
completed with gate and runner exit 0. The negative run's gate exited 101 and
runner exited 1 as expected; the pilot wrapper returned success. All six
permanent artifacts from both `445f251` runs matched their manifests. Exact
report hashes and timing are in the [pilot evidence receipt](dev-230-evidence.md).

Before deleting a clone, confirm its archive manifest and each uploaded checksum.
Evidence lives under `runs/<run-id>/` in the permanent private archive bucket.
Raw logs are sanitized before collection; archive transport sanitizes again.
The archived coordinator submission receipt records transport and collection
outcomes independently of the worker's report.
The manifest is uploaded last. Retrying cannot overwrite an existing different
object. Transcripts/reports do not expire automatically.

Invalid rollout rehearsal uses a disposable committed release whose workstream
has a missing agent reference. Upload/package it with a new checksum and revision,
update the desired release inputs, and rerun startup/activation deliberately.
Do not edit the active immutable source. The candidate must fail the existing
`mix workstream.run --validate-only` command before `current` changes. Record its
diagnostic, `readlink -f /opt/factory/current`, `active.json`, and successful health
of the previous coordinator. Restore the good desired Terraform release inputs
and verify the worker can still run that revision. A service that fails its
post-activation health check also restores the previous symlink and restarts it.
Startup stages `/etc/factory/public.pending.json`; the existing public settings
and retained `/srv/factory/active-public.json` stay effective until activation
succeeds. A rejected candidate must preserve those settings as well as the link.

This rehearsal passed on `67d7fb1` using fixture
`050804ffeaac1fbbe219c9979fe029714d86b1ea`. Both hosts rejected the missing
agent definition before promotion; both active links and six configuration
hashes stayed unchanged, and restoring the good desired release succeeded. This
rejection was not repeated on source `445f251`.

Stop/start the worker from the operator shell:

```bash
gcloud compute instances stop rig-factory-worker-01 --project=factory-511117 --zone=us-central1-a
gcloud compute instances start rig-factory-worker-01 --project=factory-511117 --zone=us-central1-a
```

Stop only after the manual run finishes; stopping a live process is not durable
stage recovery. Before compute recreation, archive every run, finish backups
and confirm no smoke process remains. Plan with `compute_enabled=false`:
only VM/optional ingress resources and their dependent access bindings may be
removed. Protected boot/data disks, state, evidence, backups and releases must
remain. Apply that reviewed plan, then plan/apply `compute_enabled=true` using
the good release. Verify retained marker files, report checksums, health and a
fresh private-worker smoke. The 2026-10-10 second teardown and recreation passed:
each reviewed plan changed exactly six resources (two VMs and four dependent
access/alert resources), while the original four disks, state, archives and
backups remained. Both recreated hosts retained their private IPs and attached
disks with `autoDelete=false`; the strict SSH pin, data markers, prior reports,
fresh pass/fail runs, monitoring query and final drift plan all passed. This
proves compute recreation, not in-flight lifecycle recovery; DEV-232/DEV-242
supply that later contract.

The first `67d7fb1` recreation failed because GCE generated a different worker
host key. A later recovery boot also found `/run/sshd` missing. Revision
`445f25184a53f48300f5d585392a011b042a0aef` fixes the worker key to the root-only
retained file `/srv/factory/ssh-host-keys/ssh_host_ed25519_key`. It requires and
checks the `/srv/factory` mount before `ssh.service`; bootstrap validates and
creates `/run/sshd` as root-owned mode `0755` before restarting SSH. Strict
host-key checking remains enabled. The final recreation confirmed the same key
and current pin generation after VM replacement.

The one-time pin rotation was authenticated and verified. The project identity
receipt binds `factory-511117` worker instance `3016822406542262307` to the
public key printed on its GCP serial console at
`2026-10-10T04:49:56.225676Z`. The recreated worker instance
`3666704121532283408` emitted the same key on its serial console at
`2026-10-10T04:55:24.204686Z`. Its fingerprint is
`SHA256:hSgoI5fIyRHUwG2nfLltQ3GznYmYZrbknAlFgvARV1s`. The operator
confirmed that exact key against the GCS pin, conditionally removed the expected
old generation `1791603779515946`, then uploaded and downloaded the replacement.
The verified new generation is `1791607845060213`. For future rotations, first
authenticate the exact GCP project and VM identity, obtain the public key from
the serial console, and compare it before conditionally replacing the current
pin generation. Never use `ssh-keyscan` or a live SSH handshake as rotation
authority. The identity, serial-key and before/after verification receipts are
under `gs://factory-511117-rig-factory-archive/deployments/dev230/hostkey-rotation-20261010/`.
That archive includes `hostkey-authenticated-identity.txt`,
`hostkey-rotation-verified.txt`, `hostkey-before-rotation.json` and
`hostkey-after-rotation.json`.

After the second teardown, the reviewed configuration was reapplied. Retained
markers, strict coordinator-to-worker SSH and service health were verified; the
fresh pass/fail smoke and monitoring check then passed on source `445f251`.
Exact VM IDs, reports and verification hashes are in the [pilot evidence receipt](dev-230-evidence.md).

Finally run the normal plan with the same committed configuration and variables.
The post-recreation `445f251` plan passed with no changes and detailed exit code 0. Remove temporary
plan/artifact files only after retaining redacted receipts. Do not run
`terraform destroy` as compute cleanup: destruction safeguards deliberately
block deleting retained resources.

## Backup, portability and limitations

Coordinator maintenance is configured to archive every five minutes, check
health each minute and back up hourly. Daily data-disk snapshots retain 14 days;
rotating backups retain 30 days. Permanent evidence has no age deletion rule.
These configured intervals and alert policies were not measured over time.

On 2026-10-10, archive and backup systemd services ran successfully on `67d7fb1`.
The verified configuration backup is
`gs://factory-511117-rig-factory-backups/backups/20261010T041259Z/`; manifest
SHA-256 `83322b38f3d68ce0f4fe0dac21fa56d8e282d7cb9f549557fe51597fa2185213`,
`public.json` SHA-256
`dc4b76b77d8708bab63d193981e0882d9115be154e72aec4a362dd4947e48c73`. Its
`databases: []` entry means this is a configuration snapshot. No runtime SQLite
database is deployed, so this does not provide task-state or in-flight recovery.
The two `445f251` smoke runs were archived separately under their run IDs;
all six artifacts per run matched their permanent manifests. See the
[pilot evidence receipt](dev-230-evidence.md) for verification details.

To recreate in another GCP project, bootstrap a distinct state bucket; change
project, bucket names, billing account, region/zone and resource prefix; reauthorize
secrets/accounts; upload the same pinned release and private archive export;
restore a verified SQLite backup and retained data before enabling dispatch;
update endpoints/DNS only when their integrations exist. Test old evidence links
and reconciled tasks after the later viewer/recovery tickets land. A different
cloud requires another provider module; the source bundle, bootstrap, SQLite
backup format and evidence manifest stay portable.

This trusted smoke user can read its intended model authentication file, and its
gate executes candidate build/test code as the same user. Each run starts from
a root-owned seed checked against the qualified Rig revision; its candidate clone
is intentionally mutable. Metadata identity is
blocked for that user, but this is **not an isolation boundary for arbitrary
delegated code**. Do not enable untrusted tasks, publisher credentials, privileged
containers or production dispatch on this pilot. The build measurements describe
one focused test, not a full Rig build or capacity guarantee.
