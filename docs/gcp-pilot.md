# GCP pilot operator walkthrough

This is DEV-230's manual cloud pilot for `RigCodeAI/symphony`, targeting a
disposable clone of `RigCodeAI/rig`. The existing Symphony coordinator runs with
an empty memory tracker. A command on the coordinator submits the merged DEV-229
two-stage runner to the worker over private SSH. Native Linear dispatch, durable
stage recovery, conversation viewer and production candidate validation belong
to later tickets.

Deployment status and live acceptance evidence are tracked in
[DEV-230](https://linear.app/rigai/issue/DEV-230/provision-and-actually-deploy-the-gcp-pilot-with-terraform).
Configuration and local checks alone do not establish a working deployment.

## Current verification

On 2026-10-09, Terraform validation passed for both roots and the pilot module,
formatting passed, and all three mock-provider plan tests passed. Eight focused
Python transport/archive/backup tests passed. A disposable Linux container
verified definition rejection, unhealthy-service rollback, effective-config
promotion, canonical release lookup and worker activation with deterministic
validator/service stand-ins. Python and shell syntax checks passed.

Owner self-review corrected public-settings directory access, release-path
resolution, staged-config promotion, evidence receipt ordering and scoped host-key
retry permissions. Local `codex login status` reports ChatGPT authentication.
GCP sign-in was refreshed and billing/quota were verified. The protected state
bootstrap and compute-disabled pilot were applied; the staging drift plan is
clean. The merged service compiled, its real Linux health endpoint responded,
52 focused tests passed and the full suite passed 408 tests. The broad lint gate
still reports existing style issues. See [the live staging receipt](dev-230-evidence.md).
The read-only credential upload was confirmed and both private VMs are running.
Bootstrap retry and runtime compilation are in progress; cloud readiness remains
unverified. The user waived the credit balance/expiry check; credits remain
unverified and do not block the approved pilot. No real cloud worker run, cloud restart/recreation check or final
deployment completion is claimed.

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
private key. Worker host keys are published through a scoped GCS identity and
pinned in coordinator `known_hosts`; no public worker SSH or unauthenticated
host-key discovery is enabled.

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

Stop/start the worker from the operator shell:

```bash
gcloud compute instances stop rig-factory-worker-01 --project=factory-511117 --zone=us-central1-a
gcloud compute instances start rig-factory-worker-01 --project=factory-511117 --zone=us-central1-a
```

Stop only after the manual run finishes; stopping a live process is not durable
stage recovery. To rehearse compute recreation, first archive every run, finish
backups and confirm no smoke process remains. Plan with `compute_enabled=false`:
only VM/optional ingress resources and their dependent access bindings may be
removed. Protected boot/data disks, state, evidence, backups and releases must
remain. Apply that reviewed plan, then plan/apply `compute_enabled=true` using
the good release. Verify retained marker files, report checksums, health and a
fresh private-worker smoke. This proves compute recreation, not in-flight
lifecycle recovery; DEV-232/DEV-242 supply that later contract.

Finally run the normal plan with the same committed configuration and variables.
It must exit with no unexplained changes. Remove temporary plan/artifact files
only after retaining redacted receipts. Do not run `terraform destroy` as compute
cleanup: destruction safeguards deliberately block deleting retained resources.

## Backup, portability and limitations

Coordinator maintenance timers archive every five minutes, check health each
minute and back up hourly. SQLite backups use its online backup API and an
integrity check. If no runtime SQLite database is deployed, the backup manifest
explicitly says so; configuration backup is not task persistence. Daily data-disk
snapshots retain 14 days; rotating backups retain 30 days. Permanent evidence has
no age deletion rule. Health, failed backup/archive and low disk alerts go to the
configured recipients.

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
