# Trusted candidate validation

DEV-236 adds a local validation service. The service pins policy outside the Rig
clone, resolves required checks from the final diff, runs a clean committed
snapshot, stores receipts, and enforces inline stage assertions. Existing local
exit-status workstreams and `WORKFLOW.md` deployments still work.

This increment does not publish target PRs or GitHub checks, upload to GCS, or
implement Coverage Factory. A local receipt is not proof of deployment or merge
protection. The later publisher must verify the current head with this service
before publishing; an agent's result map is insufficient.

## Definitions and policy

A check stage may use this gate instead of `command` / `timeout_ms`:

```yaml
gate:
  evaluator: candidate_validation
  required:
    - check: architecture-tests
      assertion: exit_status
      equals: 0
    - check: architecture-tests
      assertion: test_count
      equals: 1
  success: complete
  failure: blocked
```

The gate has no expression language or separate registry. Every selected check
must complete and exit zero, and every required assertion must be present and
match exactly. Evaluator evidence, its identity, and the service's gate verdict
and rationale are recorded separately. The same evidence can satisfy one stage
contract and fail another. A candidate cannot choose which stage contract the
coordinator uses.

[The example workstream](../factory/workstreams/rig-validation.yaml) invokes the
focused check in [the example policy](../factory/policies/rig-local.yaml).
This is a demo policy, not a complete Rig production policy: it runs one existing
architecture regression and requires exactly one test. Rig compilation,
packaging and broader architecture coverage must be declared in approved
production policy according to the change's scope.

Policy YAML version 1 requires `revision`, `environment` (`image` by SHA-256 and
`runner_version: docker-v1`), and a nonempty `checks` list. Each check declares
`id`, `adapter`, `command` as argv, `timeout_ms` (1..300000), `paths`, and
`result_format`. Path selectors are `*`, exact repository-relative files, or
directory prefixes ending in `/`. They are not arbitrary glob expressions.
The diff uses both sides of renames. Unknown or uncovered paths block. An empty
diff still runs checks. Every applicable coverage adapter blocks until the real
Coverage Factory adapter exists, including when an ordinary check also matches.

Supported command result formats:

- `exit_status`: service-observed exit status and completion assertions.
- `unittest`: also parses Python unittest's test and skipped-test counts. Zero
  tests and any skipped required test block, even when Python exits zero.
- `assertions_v1`: parses exactly `{"assertions": {"name": scalar}}` from stdout;
  values must be booleans, integers or strings. This is a reusable command
  evaluator format, not a Coverage Factory scoring contract. Output cannot
  override service-observed `exit_status` or `completed`.

Missing assertions, malformed/truncated output, missing commands/images, OOM,
source substitution and deadlines cannot qualify a candidate. The service owns
the deadline; exits 124 and 137 alone are recorded as exits, not inferred timeouts.

## Isolation and evidence

Final validation rejects dirty candidates. The service exports the exact commit
into a fresh directory without `.git`, verifies tracked file bytes, executable
bits and symlink targets, and stages that snapshot into a disposable image without
executing it. Each command runs as UID/GID 65534 with a read-only root, a 512 MiB
writable `/tmp`, one CPU, 512 MiB memory, 128 PIDs, no network, no capabilities,
no privilege escalation and no host mounts. Build commands must direct generated
files to `/tmp` (Cargo gets `CARGO_TARGET_DIR=/tmp/target`). The image must already
contain dependencies. Missing images do not trigger an automatic pull.

Git inspection uses a private temporary metadata copy containing only regular
object, ref, HEAD and index files. It never loads candidate config, hooks,
alternates, or service global/system config. Inherited Git environment settings
are cleared. Arbitrary clean/process filters named by candidate attributes have
no configured commands to run. Base checks, workspace checks and branch lookup
use the same boundary; links in copied metadata fail closed.

The trusted service alone can reach the Docker daemon. Candidate containers get
no daemon socket, source Git metadata, host home, API tokens, publisher/check
credentials, policy files, or receipt-store mounts. Docker/host administrators
remain trusted operators. These local limits support the demo checks; heavier
Rig builds need an approved runner configuration rather than silently relaxed
limits or network access.

Receipts contain task/run/attempt identity, candidate/base SHAs, source tree and
file digest, policy revision/digest, service implementation digest, immutable
base image, sealed candidate-image digest, command/adapter identity, resource
limits, timestamps/duration/exit cause, assertions, artifact byte counts and
SHA-256 checksums, and producer identity. Command logs are bounded and redacted.
Generated logs are not committed into this source repository.

The archive lives outside the disposable candidate and scratch directories. It
has mode 0700; its producer HMAC key has mode 0600 and never enters a candidate
container. Receipts are written to a temporary directory, fsynced, atomically
renamed, and the parent directory is fsynced before acknowledgment. Verification
checks signature, checksum, artifacts, exact identity and current clean source,
then recomputes the gate. Caller-provided verdicts are ignored. Repair feedback includes authenticated check IDs,
exit causes, assertions and bounded redacted logs; workers cannot replace that feedback.
Agent Markdown
or JSON is never accepted in place of a stored receipt.

Keep the archive and producer key together on durable service-owned storage.
Deleting the key invalidates receipt authentication. GCS retention/export and
its production identity mechanism remain DEV-237/DEV-243; this local archive is
the implemented boundary.

## Development and final interface

From `elixir/`, after the normal `mise exec -- mix setup`, use:

```bash
mise exec -- mix validation.run \
  --workspace /tmp/rig-validation/candidate \
  --policy /absolute/symphony/factory/policies/rig-local.yaml \
  --workstream /absolute/symphony/factory/workstreams/rig-validation.yaml \
  --inputs /absolute/symphony/factory/examples/pass.json --stage validate \
  --base FULL_BASE_COMMIT_SHA --task DEV-example --run local-example \
  --attempt development-1 --mode development --check architecture-tests \
  --archive /tmp/rig-validation/archive --scratch /tmp/rig-validation/scratch
```

Development validation can check tracked working-tree edits and selected checks.
It stores feedback but never qualifies final publication. It does not include
untracked files or support deleted tracked files; commit the candidate for final
scope validation. Replace `--attempt`, choose `--mode final`, and omit `--check`
to validate the full required plan on a clean committed snapshot. The command
prints the receipt and gate; a blocked or failed final validation exits nonzero.
The public `Validation.execute/5` and `verify_result/5` APIs serve action adapters.

For durable workstreams, `Orchestrator.queue_workstream/6` execution options add
absolute `validation_policy`, `validation_archive`, `validation_scratch`, and an
existing full `validation_base` commit SHA. Policy source and resolved options
are pinned at queue time and persisted with the existing SQLite run. Updating
files changes new runs only. Service implementation changes block incompatible
resumed runs. On stage completion the coordinator authenticates the receipt
again before advancing. Duplicate completion delivery retains the same attempt.
Validation repair failures are counted separately from transport retries and
review repair rounds; the third unsuccessful validation round blocks for a
human. Reviewer execution/fixes remain later work.

## Repeatable demo and focused checks

Use Linux with Docker available to the trusted service and the pinned Python
image present. Start with a local read-only source clone of Rig. The demo creates
its own clone under a new output directory, disables pushing, appends a harmless
README comment, runs development feedback, commits locally, runs final validation,
checks replay, and demonstrates source-edit invalidation:

```bash
docker pull python@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea
cd elixir
mise exec -- mix run --no-start ../factory/scripts/validation-smoke.exs \
  /absolute/rig-source /tmp/new-dev236-demo
SYMPHONY_RUN_VALIDATION_DOCKER=1 mise exec -- mix test \
  test/symphony_elixir/candidate_git_test.exs \
  test/symphony_elixir/validation_test.exs \
  test/symphony_elixir/validation_policy_test.exs \
  test/symphony_elixir/validation_lifecycle_test.exs \
  test/symphony_elixir/workstream_test.exs \
  test/symphony_elixir/workstream_run_test.exs \
  test/symphony_elixir/workstream_runner_test.exs \
  test/symphony_elixir/durable_workstream_test.exs
```

Expected: one existing Rig architecture test passes; `report.json` contains a
passing final gate, a final receipt and a distinct development receipt. The
focused tests include failing/tampered evidence, two loaded workstreams consuming
the same receipt, and coordinator restart with pinned policy and a human wait.
Docker validation tests are opt-in so ordinary CI does not silently assume a
local image or Docker daemon. Run them explicitly for validation changes.

After inspection, remove only `/tmp/new-dev236-demo/workspaces` and its scratch
folder. Preserve `archive` and `report.json` for evidence. The runner removes its
own containers and intermediate images, including after a deadline. The demo
never pushes its Rig candidate, opens a target PR, or merges it.
