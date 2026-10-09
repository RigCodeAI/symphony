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

Region `us-central1` has zero used CPUs, with limits 200 general CPUs, 200 N2
CPUs and 72 E2 CPUs; disk/address quotas are sufficient. The exact boot image
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
loaded outside Terraform. `git-read` has no version yet. The pinned release was
uploaded without overwrite to `releases/430d667736c049127018f6ca93042c01a3f97203.tar.gz`.

The reviewed compute plan would create six resources including exactly two
private VMs (`e2-standard-2` and `n2-standard-16`), no changes or destruction.
It has not been applied. No VM has been created.

## Remaining prerequisites and acceptance

The repository-only read credential must be loaded into `git-read` before worker
bootstrap. The billing Credits page currently requires a separate browser
passkey check; credit balance, expiry and eligibility are unverified. The
approved budget is independent of assumed credit coverage. See the walkthrough
for cost estimates; retained disks already incur charges while compute is off.

Remaining: compute apply, real subscription worker pass/fail smoke, definition
rejection on the deployed service, service restart, worker stop/start, retained
compute recreation, evidence checksums and final drift plan. No PR or completed
DEV-230 claim has been made.
