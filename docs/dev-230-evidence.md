# DEV-230 live acceptance receipt

Date: 2026-10-10. All times are UTC. The live checks passed for the manual,
single-worker pilot described here. This does not claim production isolation,
durable in-flight recovery, native Linear dispatch or capacity beyond one worker.

## Final outcome

Final service source: `445f25184a53f48300f5d585392a011b042a0aef`.
Release SHA-256: `6054a90eedd33d931ef989c569e6bd91c722577d5379bdb87836f03e1f45603e`.
The coordinator and worker activated this exact release after compute recreation.
The coordinator returned healthy state JSON, and the final Terraform plan exited
0 with `No changes. Your infrastructure matches the configuration.`

The compute-only teardown and recreation passed. The reviewed `compute_enabled=false`
plan removed exactly six resources: two VMs and four dependent access/alert
resources. The `compute_enabled=true` plan recreated exactly those six. The four
original protected disks, Terraform state, archive bucket and backup bucket
remained. All four disks are attached with `autoDelete=false`.

| VM | Instance ID | Created | `startup_ready` | Private IP | Type |
| --- | --- | --- | --- | --- | --- |
| Coordinator | `5979280685983365649` | 04:54:23.139 | 04:55:47 | `10.42.0.3` | `e2-standard-2` |
| Worker | `3666704121532283408` | 04:54:23.805 | 04:55:27 | `10.42.0.2` | `n2-standard-16` |

Neither VM has an external IP. The retained boot/data disks are respectively
30/100 GiB for the coordinator and 50/500 GiB for the worker.

## Recreated worker and retained state

Strict coordinator-to-worker SSH passed after recreation. The worker presented
the same authenticated host key as before, and the pinned GCS object stayed at
generation `1791607845060213`, fingerprint
`SHA256:hSgoI5fIyRHUwG2nfLltQ3GznYmYZrbknAlFgvARV1s`.

Before either fresh model run, these retained values matched their prior
receipts:

| Data | SHA-256 or metadata |
| --- | --- |
| Coordinator retention marker | `e069a3c2a00a171c6f5b5d36898733afbe07d613239eab0920347438043d5f22` |
| Worker retention marker | `be4fdadff18b516c7c9cc63ea87bb9bf7aae81fb1d4d85c6edd9006e7b270b9a` |
| Earlier pass report | `0603cf7baaeb25ca6c6261f7a4171639b4cedb6182fdb808b43466aa9ac29713` |
| Earlier fail report | `dcc66eafa1b1fdb825716d8f41b4a67b189a74508c54d2351dcebf0b8541137e` |
| Worker Codex auth file | regular file, mode `0600`, UID `1000`, mtime `1791603758` |

The worker remained logged in to ChatGPT with Codex CLI `0.159.2`; Rust was
`1.91.1`. DNS and sandbox namespaces worked, worker metadata HTTP was denied,
the Git read credential was absent, the seed push URL was disabled, and the
worker had no `sudo`. No secret contents were printed.

The initial recreation on `67d7fb1` failed on coordinator instance
`3352180655674097698` and worker instance `3016822406542262307`: GCE generated
a new `/etc/ssh` host key, the immutable public pin rejected overwrite, and
strict coordinator SSH rejected the new key. A later `d6ee995` recovery boot
also exposed missing `/run/sshd` after stopping SSH. Final source `445f251`
retains the root-only
worker host key under `/srv/factory/ssh-host-keys`, orders SSH after the
`/srv/factory` mount, and creates and validates `/run/sshd` as root:root mode
`0755` before SSH restarts.

The one-time public pin rotation was authenticated against GCP project
`factory-511117`, worker instance `3016822406542262307`, and the public key
printed on that VM's serial console at `2026-10-10T04:49:56.225676Z`. The
recreated worker instance `3666704121532283408` emitted the same public key on
its serial console at `2026-10-10T04:55:24.204686Z`. The exact serial
fingerprint matched the replacement object; the old generation
`1791603779515946` was conditionally removed, and the new generation is
`1791607845060213`. No SSH handshake or `ssh-keyscan` result was used as
rotation authority. Receipts are under
`gs://factory-511117-rig-factory-archive/deployments/dev230/hostkey-rotation-20261010/`.

## Fresh final-source runs

The coordinator submitted both runs over private SSH using the existing local
workstream runner. Each used service source `445f251...`, release SHA above, and
Rig commit `39d6d5d998366bf13af19eb74ae47d598ecf92bd`. The coordinator release
did not change during either run.

| Run | Started–finished | Agent / gate | Workstream / runner | Pilot wrapper |
| --- | --- | --- | --- | --- |
| `dev230-recreate-20261010a` | 04:56:15–04:56:42.305 | `gpt-6-luna`, medium; agent 18.815 s, gate exit 0 in 4.219 s | `complete`; exit 0 | passed |
| `dev230-recreate-fail-20261010a` | 04:57:38–04:58:01.261 | `gpt-6-luna`, medium; agent 16.739 s, expected gate exit 101 in 3.145 s | `blocked`; runner exit 1 | passed expected failure |

The expected-failure wrapper returned success after observing the blocked run.
Both executions reached the following-stdin marker `POST_PILOT_BATCH_REACHED`.
All six permanent artifacts for each run—`candidate.diff`, `finished.json`,
`mix.log`, `report.json`, `revision.json` and `submission.json`—were downloaded
and individually matched to their permanent manifest.

| Run | Report SHA-256 | Archive verification receipt |
| --- | --- | --- |
| `dev230-recreate-20261010a` | `a48b9eb6d11a658e78172284d553685e9bb682ffd068d631565e424bc0f48f48` | `/tmp/dev230-private/recreate-pass-archive-verified.txt` |
| `dev230-recreate-fail-20261010a` | `75b443a1d55d9b7f0a23d7ad752cad409b3091dd4d46a5a5cdf2c6041e967abe` | `/tmp/dev230-private/recreate-fail-archive-verified.txt` |

Run objects are in `gs://factory-511117-rig-factory-archive/runs/<run-id>/`.
The previous real pass/fail pair (`dev230-pass-20261010a` and
`dev230-fail-20261010a`) used earlier source `b2d34daf8e9f49e1fb53f5999f6c4e7278299b68`,
release SHA `8cffe949945e5dfa03eec573df99a3d450181fcdb7771f15b4f619517efe7f5a`,
and the same Rig commit. Those runs were checks of that older release, not
evidence for the final `445f251` result.

## Invalid release, monitoring and backup

The actual missing-agent candidate `050804ffeaac1fbbe219c9979fe029714d86b1ea`
was tested on `67d7fb1`, not `445f251`. Coordinator and worker validation
rejected it before promotion. Both active links and six public/active config
hashes stayed unchanged, coordinator health remained available, and restoring
the reviewed `67d7fb1` release succeeded. This is the invalid-definition
rejection result; no invalid candidate was tested on `445f251`.

Monitoring for the recreated `445f251` VMs recorded both `startup_ready` events,
CPU, memory and disk metrics for both instances through 04:57:10, and zero
duplicate-error matches in that query window. This is a short check, not a test
of alert delivery over time.

On `67d7fb1`, coordinator restart and worker stop/start returned healthy with
the retained marker and report hashes unchanged. The archive and backup
maintenance services ran successfully. The verified backup manifest had
`databases: []`: it contained configuration, not runtime SQLite, task state or
in-flight work. Timer cadence and alert delivery were not measured. No durable
in-flight recovery is claimed.

## Earlier deployment and verification boundaries

The pilot was applied in project `factory-511117` (number `292978199748`),
`us-central1-a`. The protected state bucket is
`gs://factory-511117-symphony-tfstate`; permanent archives are in
`factory-511117-rig-factory-archive` and rotating backups in
`factory-511117-rig-factory-backups`. The original deployment used release
`430d667736c049127018f6ca93042c01a3f97203`; source
`67d7fb17236491f08dc1259d602ad6d8f2271f55` was activated before the final
`445f251` host-key and recreation fixes. Release `67d7fb1` had SHA-256
`477fd6910fe3203007a1f346c886ec128268939e2481e7f37e52aa79cc5e783a`; it was
used for the invalid-definition rehearsal and configuration backup, not the
final smoke.

Local checks for the final source passed: Terraform format and validation in all
three roots, three mock-provider plans, 19 Python tests, 12 shell syntax checks,
and the Linux OpenSSH runtime/host-key fixture. Elixir Linux build passed; 52
focused tests passed. Full `mix test` passed 408 with zero failures, six skipped
and ten excluded. Broad `make all` still reports existing Credo findings (46
refactoring and 37 readability); this is recorded under the pilot alpha exception.

The pilot is a manual coordinator-to-worker submission, not Symphony scheduling
or native Linear dispatch. It has no publisher, automatic merge, Daybreak,
API billing or qualified multi-worker capacity. The worker runs trusted smoke
code as its service user; denied metadata and no `sudo` do not make it an
isolation boundary for arbitrary delegated code. Human review and merge remain
outside this pilot.

The user set a **$2,000 monthly alert budget**, not a hard spending cap, and
waived verification of GCP credit balance/expiry. The estimated low-volume cost
is about $750–850/month; retained disks cost about $68/month while compute is
off. These are estimates, not measured bills.

Final redacted receipt destination:
`gs://factory-511117-rig-factory-archive/deployments/dev230/final-20261010-445f251/`.
The bundle's `manifest.json` records artifact digests.
