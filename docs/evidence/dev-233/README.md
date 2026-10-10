# DEV-233 local checkpoint

## Dashboard HTTPS ingress, 2026-10-10

The user-selected `factory.rig.ai` dashboard ingress applied ten resources, with no
VM metadata update or deletion. The reserved address was imported, backend health is
HEALTHY, and the only dashboard IAP viewer grant is `domain:rig.ai`. A scoped plan
using an explicit VM-metadata preservation overlay reports no drift after apply.
Certificate and domain status are ACTIVE; verified HTTPS returns 302 to Google
sign-in. An actual signed-in viewer session remains untested. See the
[ingress evidence](https-ingress.md). The installed coordinator lacks the Elixir
`WorkerOperation` client, so its qualification needs a newer coordinator release. The Linear webhook route and native dispatch
remain disabled.

## Live contained worker qualification, 2026-10-10

Sections below with earlier pending statuses record their own checkpoint dates; this live
qualification section supersedes those statuses for the worker control installation and
host/SSH qualification only.

The existing worker control service was installed and is active. Its root card passed on
control source `cc85ca7871a27afb03bc2b6e86722a142ff93e7e`, archive SHA-256
`59a9c8668cc258ce19fc50d9d339d3c6fa1920b70b8b14c531bdbfeb6124cb01`, systemd 252,
machine `fe9b1ece921d40aeac95b10940000311` and boot
`4418dae454694f88ab9bbc4280b94547`. The seven checks covered held launch, duplicate
prepare, stale identity rejection, `setsid` child termination, natural exit, coordinator
restart recovery and manager re-execution. The [root-card receipt](worker-live-card.json)
and [card output](worker-live-report.log) preserve the result.

The actual coordinator forced-SSH path passed eight checks: qualification, arbitrary-command
rejection, held/duplicate prepare, stale identity rejection, `setsid` child termination,
stop proof/replay, stream and natural-exit proof/replay. The [forced-SSH report](worker-ssh-qualification.json)
records the checks and safe operation identities. The [archive stat](worker-release-archive-stat.json)
records its size, digest and mode.

The maintenance retained the same VM instance, restored metadata exactly, and preserved
disks and network configuration. The active application release remains
`541279aeb6a5366571e1ee8935e134c728d91c63`. Both task processes and the operation cgroup
were observed dead/empty after stop. The output contains Python `ResourceWarning`s for
helper `Popen` handles and pipes. A later read-only check found both warned helper PIDs
1388 and 1487 absent ([process check](worker-helper-process-check.json)); this does not
prove every Python handle was closed. No private before/after maintenance snapshots or
authentication hashes are retained here.

This evidence qualifies the root systemd card and coordinator SSH transport only. The live
Elixir `WorkerOperation.qualify/1` call, public HTTPS delivery, Linear app installation and
native delegate/replay/restart/stop acceptance remain pending. The current dashboard HTTPS
plan contains no Linear webhook route.

## Coordinator client credentials and worker maintenance check, 2026-10-10

The coordinator supports Linear's server-to-server app grant with `client_secret_env`
instead of the compatible `token_env`. The existing stripped `LINEAR_API_KEY` now holds
the OAuth client secret; `LINEAR_API_TOKEN` remains the separate signing secret. Fixed
scopes are `read,write,app:assignable`. Tokens stay in bounded coordinator memory per
immutable issue run, renew on expiry or one HTTP 401, and are never written to durable
task records or worker environments. Official HTTPS endpoints are fixed; redirects and
automatic HTTP retries are disabled. Failure/status diagnostics redact credentials.
See [exact app setup](../../linear-delegation.md#linear-app-setup).

Focused verification in the pinned `dev233-check` runtime: **35 tests passed**
([output](client-credentials-focused.log)), covering separate run tokens, fixed scopes,
ordinary GraphQL integration, missing credentials, expiry, restart, bounded 401 renewal,
redacted failures/status, delegation compatibility and agent credential exclusion.
Command: `mix test test/symphony_elixir/linear_oauth_test.exs
test/symphony_elixir/linear_delegation_test.exs test/symphony_elixir/linear_agent_client_test.exs
test/symphony_elixir/app_server_options_test.exs`. Compile with warnings as errors,
specs, escript build and changed-file formatting passed ([build](client-credentials-build.log)).
A fresh controlled coordinator startup retained both listeners
([output](client-credentials-service.log)); no real app token was minted. Broad tests
were not repeated. Live Linear setup/HTTPS/acceptance remain pending.

Targeted Luna/max review found no credential exposure or unbounded 401 loop, but identified
the app-wide provider token lifetime limit: a lost memory cache does not revoke old tokens
at Linear. The local cache cap is not a provider quota guarantee. This limitation is now
explicit in the app setup guide; sustained/scaled operation needs token lifecycle accounting.
Self-review checked exclusive authentication configuration, matching issue-run cache keys,
fixed endpoints/scopes, redacted errors, restart and unchanged worker secret stripping.

The user approved process-control installation/testing, but the established service-key
route cannot perform root maintenance: `factory-worker`'s noninteractive sudo requires a
password, and known administrator/root logins with that key are denied
([receipt](worker-maintenance-access.json)). This tests that route only; another existing
administrator route is being investigated. No worker staging, installation, privileged
qualification, metadata/key/IAM change or dispatch ran during this check. Existing auth
and worker data were untouched.

## Selected dashboard domain, 2026-10-10

The user selected managed-domain dashboard access as `domain:rig.ai`. Source adds
`iap_viewer_domains` with a default empty set, keeps existing email input/resource
addresses and scopes both grants to the dashboard backend's
`roles/iap.httpsResourceAccessor`. Operator tunnel/OS Login inputs are separate.
The [morning card](../../dev-233-morning-decision.md) records the selection while
hostname, managed-domain/organization eligibility, app and ingress rollout stay pending.

Focused Terraform checks: **nine module mock plans** passed
([output](iap-domain-module.log)); **four root mock plans** passed
([output](iap-domain-root.log)). They cover domain-only and mixed access, unchanged
email addresses/grants, disabled ingress, malformed domains, the empty-viewer gate
and unconfirmed organization rejection. Commands: `terraform -chdir=infra/gcp/modules/pilot
test` and `terraform -chdir=infra/gcp/pilot test -filter=tests/iap-domain.tftest.hcl`.
Both configurations validate; recursive formatting and diff checks pass. Self-review
confirmed only dashboard backend IAM is added and ingress remains default-off.
No broad tests, cloud IAM changes or apply ran. Mock plans do not verify real domain
eligibility or access; check the managed customer and eligible users before deployment,
including any primary/secondary domains attached to the same customer. See Google's
[domain semantics](https://docs.cloud.google.com/iam/docs/principals-overview#domains).

## Existing-worker compatibility and deployment wiring, 2026-10-10

Read-only IAP/SSH preflight found the existing worker idle, with systemd 252.39,
cgroup v2 and the protected runtime. Both hosts still run `541279a…`; control
installation, app/HTTPS setup and actual delegate/stop acceptance remain pending.
See the [morning decision card](../../dev-233-morning-decision.md) and retained
[worker](worker-preflight.json)/[coordinator](coordinator-preflight.json) observations.
No secret payload, host configuration or cloud access grant was changed.

Follow-up source permits v252 while retaining fixed held execution, exact proof and
operator receipt requirements. A separate webhook listener excludes dashboard/API routes;
coordinator credential bootstrap checks root permissions and immutable reference pins,
restores prior pins for cold-boot rollback and rejects same-revision changes. The earlier
reviewed code checkpoint `77f72fafbb0806fa6b724aed2403896c84bcaead` remains in history.
These changed root/deployment assumptions received a targeted Luna/max source review.
Source review and mocks do not qualify the host or authorize access changes.
Final self-review checked fixed manager arguments, exact receipt identity, immutable
credential pins, cold-boot rollback and the public listener's limited routing. The final
Python and fresh-process service checks were repeated after the rollback changes.

Focused checks used the existing `dev233-check` container (Elixir 1.19.5/OTP 28):

- `mix compile`, `mix specs.check` and changed-file formatting passed; HTTP/worker-client/
  credential exclusion tests passed **15 tests** ([output](compat-elixir.log)).
- Python engine/transport/receipt/coordinator-runtime/cloud helpers ran **65 tests**:
  **64 passed, one real systemd card skipped** ([output](compat-python.log)). Tests
  cover v252 receipt/proof handling, substitution rejection, selected credential isolation,
  stale references, same-revision rejection and cold-boot restoration.
- Terraform mock plans passed **five tests**, including exact public webhook routing,
  retained dashboard IAP and role-scoped refs ([output](compat-terraform.log)). They created
  no cloud resources. Recursive format and shell syntax checks passed.
- A fresh disposable Docker container ran the real compiled coordinator entrypoint in
  pilot and Linear modes, proving both listeners and public API exclusion
  ([output](compat-service.log)). This used controlled credentials and no agent/delegate.
- The activation harness passed invalid-definition preservation, same-revision rejection
  before restart, unbound webhook rollback, config promotion and worker activation
  ([output](compat-activation.log)). Its service/cloud controls are stand-ins.

Commands: `docker exec -w /workspace/elixir dev233-check mix test
test/symphony_elixir/linear_http_test.exs test/symphony_elixir/worker_operation_test.exs
test/symphony_elixir/app_server_options_test.exs`; `docker exec -w /workspace
dev233-check python3 -m unittest factory.deploy.tests.test_worker_operation
factory.deploy.tests.test_worker_operation_transport factory.deploy.tests.test_worker_operation_systemd
factory.deploy.tests.test_coordinator_runtime factory.deploy.tests.test_cloud_io`;
`terraform -chdir=infra/gcp/modules/pilot test`; and the documented
`factory/deploy/tests/service-entrypoint.sh` / `activation.sh` disposable container cards.
Broad CI was not repeated; the earlier 488-test result and known lint/coverage/Dialyzer
limits below remain the broad-check boundary. Actual systemd qualification, subscription
requalification, app installation and real HTTPS/Linear delivery remain unverified.

## Contained-operation integration, 2026-10-10

The branch now includes merged DEV-231 revision
`937ab21450dacd9fcc7cb1ee64ea4c668e498e84` through merge `fdfd511`.
The selected SSH/root-broker/systemd adapter, held launch, durable registration,
trusted termination checks and asynchronous cancellation are implemented locally.
The installer and service are concrete reviewable files; neither has run on a live worker.
See [installation and qualification](../../contained-worker-operations.md).

Checks in the same pinned Docker runtime used below:

- Compilation, public specs and formatting passed. The integrated focused batch passed
  **84 tests** ([output](contained-focused.log)). After client refinements, the affected
  client/delegation/SSH batch passed **38 tests** ([output](contained-regression.log));
  final client/format checks passed **11 tests** ([output](worker-client-final.log)).
- Python engine, broker/real Unix socket and real held-wrapper checks passed **32 tests**.
  The disposable systemd card was **skipped** ([output](worker-control-python.log)).
  Fake-manager tests do not prove systemd termination or generate a qualification receipt.
  The controller/broker integration specifically covers held → stream ready → release →
  normal completion with proof-driven stream cleanup.
- `bash -n factory/deploy/install-worker-operations.sh` and container
  `systemd-analyze verify` on the service template with `/source` substituted passed.
  These verify syntax, not installation, privileges or a running broker.
- Fresh-process HTTP intake and recovery smokes passed ([output](contained-smokes.log),
  [intake report](contained-intake-report.json), [recovery report](contained-recovery-report.json)).
- Broad coverage ran **488 tests, zero failures, six skipped, ten excluded**.
  Coverage **75.86%** fails the configured 100% threshold
  ([output](contained-coverage.log)). `make all` stops at lint with 85 refactoring,
  69 readability and two design suggestions ([output](contained-make-all.log)).
  Dialyzer was run separately; the final output has only the two previously observed
  store warnings at lines 879 and 938 ([output](contained-regression.log)).
  The full quality gate is red; the alpha exception does not make it green.

Self-review checked durable reserve/ack/release ordering, exact machine/boot/invocation
fencing, fixed environment and peer-UID boundaries, unknown capacity through restart,
and responsive intake during cancellation. Review caught systemd's pruning of empty
cgroups; the implementation now distinguishes present populated-zero evidence from
an exact terminal invocation with a released cgroup. Qualification remains disabled
without the current root-owned receipt. The new root service/control-account grant
requires installation review. Public hostname/app access and the real native
delegate/replay/stop pilot remain pending. No acceptance PR exists.

## Earlier checkpoint `bc3e3d9`

Checked on 2026-10-10 in branch `cycle/dev-233`, based on
`37775bcc23ee4c12acdee9bfe882693b284b9d56`. This checkpoint is local implementation
evidence, not installed-app or remote-worker acceptance. No DEV-233 acceptance PR exists.

The host lacks Elixir/mise. Checks used the cached Elixir 1.19.5/OTP 28 Docker image
`dev230-checked:latest`, image ID
`sha256:930b428bffd3752c5a53310b0b93173e0fdf95e307970bb2c5854d894611d3c9`.
The source mount was read-only; checks ran in a writable copy.
Retained log copies trim trailing spaces and terminal control codes; original
outputs remain under `/private/tmp/dev233-contained-*` on this host.

### Checkpoint focused checks

`mix compile`, `mix specs.check`, `mix format --check-formatted` and the ten test files
listed in [the test card](../../linear-delegation.md) passed: **86 tests, zero failures**.
See [raw focused output](focused-tests.log). Linux cancellation tests used real processes;
held registration survived coordinator restart before any effect was released.

Both `mix run --no-start ../factory/scripts/linear-intake-smoke.exs` and
`mix run --no-start ../factory/scripts/recovery-smoke.exs` passed in separate processes
with fresh disposable directories. Their retained reports are
[HTTP intake](linear-intake-smoke.json) and [durable recovery](recovery-smoke.json).
They use controlled intake/workers, not a model or the Linear API.

### Earlier broad checks

Before the last cancellation integration, the broad suite ran **449 tests, zero failures,
six skipped and ten excluded**. Coverage was **79.41%**, below the configured 100% threshold,
so that command failed. Lint reported 66 refactoring, 47 readability and one design suggestion.
Dialyzer reported two warnings in existing store helpers. `make all` therefore did not pass.
The final cancellation changes were compiled and covered by the focused checks above;
broad CI has not been rerun for them while DEV-231 owns the heavy build slot.
Raw broad output remains in `/private/tmp/dev233-final-checks.log`,
`/private/tmp/dev233-lint-final.log` and `/private/tmp/dev233-dialyzer-final.log` on this host.

### Checkpoint review and remaining acceptance

Reviewed durable receipt/ack ordering, crash gaps, definition pinning, current ownership,
credential isolation and cancellation capacity. Regression tests cover stop receipts before
task linking, orphaned pinned runs, stale ownership checks, and changed definitions before
enqueue. No private token or raw prompt is saved in intake receipts.

The local process-group adapter deliberately reports unknown even after cleanup. It cannot
prove that descendants did not escape. Production dispatch is blocked until contained
worker execution control is integrated. The shared Default Cloud readiness/agent change
DEV-231 has an open qualification PR; it is not merged into this checkpoint.
Public webhook hostname, app installation/admin IDs, intended-worker qualification,
remote halt proof and the real delegate/replay/stop pilot remain unverified.
Publication remains disabled. See [live acceptance checklist](../../linear-delegation.md).

### First live control installation (2026-10-10)

`worker-install-first-card.log` records the approved installation on the existing
worker at release `241e93aa0685e31657d88e26d41a02bec43eccbc`. The installer
passed; the host card failed before operation launch because its fixture mkdir
inherited startup umask 077. No receipt or enabled broker resulted. The fixture
now sets its required directory modes explicitly. This is a test fixture fix,
not evidence of successful containment.

### Installed wrapper alignment

- `worker-transfer-check.log`: second maintenance stopped before unpack because
  the staged archive was truncated after reset. Later staging validates the full
  bytes and checksum, fsyncs the file and directory, and independently rereads
  the remote checksum before reset. SSH exit 0 alone was insufficient.
- `worker-installed-wrapper-first-card.log`: verified release `2b093e97`
  installed, but the real wrapper exited before manager-reexec recovery. Source
  diagnosis found the `--manifest` CLI mismatch and card roots incompatible with
  the production wrapper. No receipt or broker activation resulted.
- `worker-wrapper-focused.log`: 37 tests, 36 passed and the real systemd card
  skipped locally. Covers the actual CLI parser, rejected command shapes and
  rejection of a writable workspace parent. Live qualification is still pending.

The fix uses a separate protected contained-workspace parent, preserving legacy
worker-owned workspaces. The real card now launches the installed wrapper against
its actual protected gates and contained-workspace parent.

### Initial held-state check

`worker-initial-held-state.log` records the verified installed production path at
`bc6b4203`: its first status was unknown. Source inspection found preparation could return
during systemd activation; that race is consistent with this result. The
controlled unit was subsequently killed by card cleanup (observed exit signal 9),
not the previous wrapper CLI failure. No receipt or service activation resulted.
Preparation now waits for a live exact unit and populated cgroup. The fixed unit
also starts in the canonical workspace, which the real card explicitly checks.

## Installed Linear integration preflight — 2026-10-10

[Native integration preflight](native-integration.md) records the authenticated app identity,
restricted secret/ingress plans, matching fixture clones, real Elixir qualification and the
live GraphQL contract corrections. It does not yet establish native delegation acceptance.
