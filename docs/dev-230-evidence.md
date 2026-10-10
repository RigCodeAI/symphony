# DEV-230 live staging receipt

Date: 2026-10-10. This is partial deployment evidence, not completed acceptance.
All times below are UTC. Earlier staging facts are kept separate from the live
smoke revision and the later source candidate.

## Earlier staging and local checks

Branch: `cycle/dev-230-gcp-pilot`. Initial infrastructure commit: `fb4e306`.
Merged main includes DEV-232 `efca0ea` and DEV-236 `9e67338`.
Pinned release revision: `430d667736c049127018f6ca93042c01a3f97203`.
Release SHA-256: `c12b2362e5170b6575755a96a810e271403764be9cb27bc26c6f38c8e7ad5e26`.
This was an earlier staging release; it is not the release used for the live
smoke below.

The Linux build used `elixir:1.19.5-otp-28`, `mix setup`, and `mix build`.
The actual escript with `factory/deploy/PILOT-WORKFLOW.md` returned JSON from
`http://127.0.0.1:8080/api/v1/state` with an idle coordinator.
Focused runner/definition tests: 52 passed. Full `mix test`: 408 tests, zero
failures, six skipped and ten excluded. `make all` stopped at existing Credo
style issues (46 refactoring opportunities and 37 readability issues); the
separately run full test suite passed. Python tests: eight passed. Linux
activation tests use real service users and deterministic validator/service
stand-ins; rejection, rollback and config promotion passed.

## Applied project and resource baseline

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

Initial bootstrap history, before the later smoke: the first bootstrap stopped
before runtime compilation when Kerl's GitHub release-list lookup failed. A
manual retry succeeded and began compilation.
The fixed release pins OTP 28.5 and Elixir 1.19.5-otp-28 with three bounded install
retries, and shares root-owned readable Hex archives with the real service user.
A Linux reproduction confirmed definition validation with the shared Mix home.
The metadata/release-reader update was applied without replacing either VM.
The idle worker was restarted to retry bootstrap. Coordinator compilation completed with OTP 28.5 and Elixir 1.19.5.
VM status at that checkpoint did not establish a working service.

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

## Live coordinator-to-worker smoke

The coordinator and worker emitted `FACTORY_EVENT startup_ready` for instance
IDs `805353400918348561` and `4537606034690413329` at 04:02:05 and 04:00:14,
respectively. The idle coordinator returned state JSON from its localhost
service endpoint. Both instances then reported CPU, memory and disk metrics
between 04:06 and 04:08:13. The duplicate-error query for that interval returned
no matches. This is a short monitoring check, not a long-term alert-delivery test.

The smoke used service revision
`b2d34daf8e9f49e1fb53f5999f6c4e7278299b68`, release SHA-256
`8cffe949945e5dfa03eec573df99a3d450181fcdb7771f15b4f619517efe7f5a`, and Rig
workspace commit `39d6d5d998366bf13af19eb74ae47d598ecf92bd`. Both runs report the
same coordinator and worker instance IDs and private addresses `10.42.0.3` and
`10.42.0.2`.

The coordinator operator invoked the manual pilot command for each case:

```bash
sudo -u factory-coordinator /opt/factory/current/factory/deploy/factory-pilot \
  submit rig-factory-worker-01 dev230-pass-20261010a pass
sudo -u factory-coordinator /opt/factory/current/factory/deploy/factory-pilot \
  submit rig-factory-worker-01 dev230-fail-20261010a fail
```

This proves a manual coordinator-originated submission over private SSH and the
existing local workstream runner on the worker. It does not exercise Symphony's
scheduler or native Linear dispatch.

| Run | Agent turn | Gate result | Workstream / pilot result |
| --- | --- | --- | --- |
| `dev230-pass-20261010a` | `gpt-6-luna`, medium; 34.679 s; status `ok` | `agent_hook_refuses_a_configuration_file_symlink`: exactly one test passed; exit 0 in 4.591 s | `complete`; runner exit 0; pilot passed |
| `dev230-fail-20261010a` | `gpt-6-luna`, medium; 16.791 s; status `ok` | The same test failed its expected assertion; exit 101 | `blocked`; runner exit 1; expected negative pilot passed |

For both runs, the coordinator reports SSH exit 0, evidence validation exit 0,
and no active-release change. Each permanent archive under
`gs://factory-511117-rig-factory-archive/runs/<run-id>/` contains six
checksum-verified artifacts: `report.json`, `mix.log`, `candidate.diff`,
`finished.json`, `revision.json` and `submission.json`. The run manifest records
their SHA-256 digests. The local verification receipts are
`/tmp/dev230-private/pass-archive-verified.txt` and
`/tmp/dev230-private/fail-archive-verified.txt`.

Worker checks confirmed ChatGPT subscription login with Codex CLI `0.159.2`,
model authentication owned by the worker user with mode `0600`, DNS and sandbox
namespace availability, no `sudo`, no remaining Git read token, and a root-owned
seed with its push URL disabled. The worker could not reach the metadata service;
the coordinator metadata firewall rules were also checked. No secret payloads
were printed. These checks establish the documented trusted-smoke boundary, not
isolation for arbitrary delegated code.

The branch then advanced to source commit
`67d7fb17236491f08dc1259d602ad6d8f2271f55`, packaged with SHA-256
`477fd6910fe3203007a1f346c886ec128268939e2481e7f37e52aa79cc5e783a`. It is
newer than the `b2d34...` smoke release. The pass/fail runs above do not verify
this later source; acceptance must be checked against the exact revision shown
active after its rollout.

## Latest rollout and retained-state checks

The `67d7fb1` release was activated on both VMs at 04:11:44.126, with SHA-256
`477fd6910fe3203007a1f346c886ec128268939e2481e7f37e52aa79cc5e783a`. The
coordinator and worker both reported that revision active. The coordinator
returned idle state JSON after `factory-coordinator.service` was restarted.
The credential check again confirmed ChatGPT login, Codex CLI `0.159.2`, worker
auth as a regular mode-0600 file owned by UID 1000, DNS access, denied worker
metadata access, no remaining Git read token and no worker `sudo`.

The archive and backup maintenance service units were started manually after
rollout and returned successfully; their periodic timer schedule was not tested.
The existing pass/fail archive objects remained checksum-verified. The backup
service produced
`gs://factory-511117-rig-factory-backups/backups/20261010T041259Z/`; its
downloaded manifest SHA-256 is
`83322b38f3d68ce0f4fe0dac21fa56d8e282d7cb9f549557fe51597fa2185213` and its
`public.json` SHA-256 is
`dc4b76b77d8708bab63d193981e0882d9115be154e72aec4a362dd4947e48c73`. The
manifest identifies revision `67d7fb1` and `databases: []`, with an explicit
note that no durable runtime SQLite database is deployed. This is a verified
configuration backup, not durable task-state or in-flight-run recovery.

After the coordinator restart and worker stop/start, both services returned
healthy and the retained marker/report hashes were unchanged:

| File | SHA-256 after restart/stop-start |
| --- | --- |
| Coordinator data marker | `e069a3c2a00a171c6f5b5d36898733afbe07d613239eab0920347438043d5f22` |
| Worker data marker | `be4fdadff18b516c7c9cc63ea87bb9bf7aae81fb1d4d85c6edd9006e7b270b9a` |
| Pass report | `0603cf7baaeb25ca6c6261f7a4171639b4cedb6182fdb808b43466aa9ac29713` |
| Fail report | `dcc66eafa1b1fdb825716d8f41b4a67b189a74508c54d2351dcebf0b8541137e` |

The worker auth file retained mode, owner and modification time, and Codex still
reported ChatGPT login. No auth-file digest or secret contents were recorded.
The post-rollout receipts are under `/tmp/dev230-private/`: `cloud-credential-67.txt`,
`restart-retention-before.txt`, `stopstart-verified.txt`,
`stopstart-final-verified.txt` and `backup-verified.txt`.

## Live invalid definition rejection

The deployed fixture `050804ffeaac1fbbe219c9979fe029714d86b1ea`, based on
`67d7fb1`, referenced `factory/agents/missing-worker.yaml`. The actual worker
validation rejected it at 04:20:44 UTC and coordinator validation at 04:21:56 UTC
with `definition_file_error` / `enoent`. Both current links stayed on `67d7fb1`.
The before/after hashes of both hosts' `public.json`, `active-public.json` and
`active.json` were identical. The coordinator remained healthy, and its dated
failure event recorded exit 1 at the activation call. The reviewed restoration
plan changed only release metadata and scoped read permissions; both hosts
subsequently completed normal bootstrap with the good release. These receipts
are `invalid-before.txt`, `invalid-after.txt`, `invalid-verified.txt` and
`restore-good-verified.txt` under `/tmp/dev230-private/`.

## Initial compute recreation attempt (failed)

The first compute recreation attempt used source `67d7fb17236491f08dc1259d602ad6d8f2271f55`.
GCE assigned coordinator instance ID `3352180655674097698` and worker instance
ID `3016822406542262307`. The coordinator reached `startup_ready` and remained
healthy. GCE generated new worker `/etc/ssh` host keys. Startup refused to
replace the immutable public host-key pin object because its checksum differed;
the coordinator then rejected the new key under strict host-key checking. No
SSH check was bypassed, and the unauthenticated handshake fingerprint was not
used to authorize rotation. Worker data verification and the recreation
acceptance check therefore remain incomplete. The coordinator marker and both
prior report hashes remained unchanged.

The recovery being implemented retains the worker's host private keys in
root-only storage and configures `sshd` to use those retained keys. If a one-time
public pin rotation is still needed, the operator will obtain the public key
through the authenticated GCP project serial console, verify it, and replace
only the scoped public pin object. Then compute recreation must be repeated and
strict coordinator-to-worker SSH, retained data checks, and a fresh smoke must
pass. This recovery has not yet been verified.

## Remaining prerequisites and acceptance

The user authorized subscription authentication and the read-only Rig token,
then confirmed its upload. On 2026-10-09 the user waived the billing credit balance/expiry check; credits remain
unverified and are no longer a deployment blocker. The approved budget is
independent of assumed credit coverage. See the walkthrough
for cost estimates; retained disks already incur charges while compute is off.

Completed here: both VMs activated `67d7fb1`; coordinator restart and worker
stop/start returned healthy, with marker and report hashes retained. The
systemd archive and backup units ran successfully. The verified backup contains
configuration only because no runtime SQLite database is deployed. The real
subscription pass/fail smoke and six-artifact permanent archives are from the
earlier `b2d34...` revision, not `67d7fb1`.

Still pending: verify the retained-host-key fix and run a fresh pass/fail smoke;
recreate
compute while retaining data and run a fresh smoke (the initial recreation
failed at worker host-key pinning); then capture a final Terraform drift plan.
No PR, push, merge or completed DEV-230 claim has been made.
