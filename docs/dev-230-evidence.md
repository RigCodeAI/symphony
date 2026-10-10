# DEV-230 live staging receipt

Date: 2026-10-09. This is partial deployment evidence, not completed acceptance.

## Source and local checks

Branch: `cycle/dev-230-gcp-pilot`. Initial infrastructure commit: `fb4e306`.
Merged main includes DEV-232 `efca0ea` and DEV-236 `9e67338`.
Pinned release revision: `430d667736c049127018f6ca93042c01a3f97203`.
Release SHA-256: `c12b2362e5170b6575755a96a810e271403764be9cb27bc26c6f38c8e7ad5e26`.

The Linux build used `elixir:1.19.5-otp-28`, `mix setup`, and `mix build`.
The actual escript with `factory/deploy/PILOT-WORKFLOW.md` returned JSON from
`http://127.0.0.1:8080/api/v1/state` with an idle coordinator.
Focused runner/definition tests: 52 passed. Full `mix test`: 408 tests, zero
failures, six skipped and ten excluded. `make all` stopped at existing Credo
style issues (46 refactoring opportunities and 37 readability issues); the
separately run full test suite passed. Python tests: eight passed. Linux
activation tests use real service users and deterministic validator/service
stand-ins; rejection, rollback and config promotion passed.

## Live project and applied resources

Authenticated operator: `adam@rig.ai`. Every resource operation targets
`factory-511117`, number `292978199748`, which is ACTIVE. Billing is enabled on
`019E70-29AB53-7909FE`. The default gcloud project remains `rig-web`.

Before compute creation, region `us-central1` had zero used CPUs, with limits
200 general CPUs, 200 N2 CPUs and 72 E2 CPUs; disk/address quotas were sufficient. The exact boot image
is `projects/debian-cloud/global/images/debian-12-bookworm-v20261006`.

The reviewed state bootstrap applied two resources. State bucket:
`gs://factory-511117-symphony-tfstate`. Bootstrap recovery state is stored under
`bootstrap/terraform.tfstate`; the pilot backend prefix is `dev-230/pilot`.

The reviewed compute-disabled pilot applied 56 resources, zero changes or
destruction. It created private networking/NAT, identities, scoped IAM, three
secret containers, retained disks, snapshot schedules, evidence/release/backup
buckets, monitoring and the monthly budget. A subsequent real plan reports:

```text
No changes. Your infrastructure matches the configuration.
```

Redacted bootstrap/apply/drift outputs and their SHA-256 manifest are retained
under `gs://factory-511117-rig-factory-archive/deployments/dev230/staging-20261009-430d667/`.

| Resource | Applied identity |
| --- | --- |
| Coordinator reserved address | `rig-factory-coordinator-ip`: `10.42.0.3` |
| Worker reserved address | `rig-factory-worker-01-ip`: `10.42.0.2` |
| Coordinator disks | `rig-factory-coordinator-boot` 30 GiB, `rig-factory-coordinator-data` 100 GiB |
| Worker disks | `rig-factory-worker-01-boot` 50 GiB, `rig-factory-worker-01-data` 500 GiB |
| Permanent archive | `factory-511117-rig-factory-archive` |
| Rotating backups | `factory-511117-rig-factory-backups` |
| Pinned releases | `factory-511117-rig-factory-releases` |
| Budget | `0c283784-b898-4301-872c-41b2795a276b`, USD 2,000 monthly |

All disks are `pd-balanced` in `us-central1-a`. The configured notification
recipient and future IAP operator are `adam@rig.ai`. Runtime identities are
`rig-factory-coordinator@factory-511117.iam.gserviceaccount.com` and
`rig-factory-worker@factory-511117.iam.gserviceaccount.com`.

Subscription auth shape was verified without printing values and loaded into
`model-auth` version 1. The generated worker SSH key was loaded into `worker-ssh`
version 1, then its temporary private file was removed. Secret payloads were
loaded outside Terraform. `git-read` version 1 is enabled; the user confirmed its upload. The pinned release was
uploaded without overwrite to `releases/430d667736c049127018f6ca93042c01a3f97203.tar.gz`.

The reviewed compute plan applied six resources including exactly two private
VMs, zero changes or destruction. Both report RUNNING, with private addresses
only and no external access configuration:

| Instance | Instance ID | Machine type | Private IP |
| --- | --- | --- | --- |
| `rig-factory-coordinator` | `805353400918348561` | `e2-standard-2` | `10.42.0.3` |
| `rig-factory-worker-01` | `4537606034690413329` | `n2-standard-16` | `10.42.0.2` |

The first bootstrap stopped before runtime compilation when Kerl's GitHub
release-list lookup failed. A manual retry succeeded and began compilation.
The fixed release pins OTP 28.5 and Elixir 1.19.5-otp-28 with three bounded install
retries, and shares root-owned readable Hex archives with the real service user.
A Linux reproduction confirmed definition validation with the shared Mix home.
The metadata/release-reader update was applied without replacing either VM.
The idle worker was restarted to retry bootstrap. Coordinator compilation completed with OTP 28.5 and Elixir 1.19.5.
VM status does not establish a working service.

A worker restart exposed that the metadata firewall also blocked Google's
DNS endpoint for the unprivileged resolver. Startup now permits TCP/UDP port 53
while retaining the metadata deny. On the live coordinator, the service user
resolved `github.com` after this change while an HTTP metadata request still
failed immediately. The worker's failed retry had not started compilation.

Detailed startup logs then identified that the Compute startup unit leaves
`HOME` unset. Kerl immediately rejects that environment but suppresses its error
on a non-TTY; Hex likewise rejects the missing home. Re-entering through the
actual root account restored its environment and `mix hex.info` succeeded on
the coordinator. The bootstrap now uses that account setup. A focused restart
review also identified that Codex refreshes would otherwise be lost from `/run`;
the retained auth file and pinned-version rotation behavior were fixed before
the first real model turn. Fifteen focused Python tests pass. A disposable Linux
container with the actual fixed paths and a distinct worker UID confirmed
worker-owned mode-0600 auth, root-owned source marker and same-version restart
preservation without another secret fetch. These use synthetic credentials and
are contract checks, not live subscription evidence.

Earlier fixed release revision: `f61e6b785b1bfef2cdfcfc5769e7d0f6592aaaa9`.
Fixed archive SHA-256:
`563b0561af59fa891c4475aa19b8890bcc922a70b20ee306183b63cc2c1c3c37`.

## Remaining prerequisites and acceptance

The user authorized subscription authentication and the read-only Rig token,
then confirmed its upload. On 2026-10-09 the user waived the billing credit balance/expiry check; credits remain
unverified and are no longer a deployment blocker. The approved budget is
independent of assumed credit coverage. See the walkthrough
for cost estimates; retained disks already incur charges while compute is off.

Remaining: successful bootstrap, real subscription worker pass/fail smoke, definition
rejection on the deployed service, service restart, worker stop/start, retained
compute recreation, evidence checksums and final drift plan. No PR or completed
DEV-230 claim has been made.
