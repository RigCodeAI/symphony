# DEV-233 local checkpoint

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
