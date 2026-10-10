# DEV-231 qualification evidence

Qualification uses the existing private GCP pilot worker `rig-factory-worker-01`,
project `factory-511117`, zone `us-central1-a`. Operator access passes through
`rig-factory-coordinator` over IAP, then its service-owned pinned SSH configuration.
No infrastructure, credential material, account resets or active release is changed.

Active worker source: `541279aeb6a5366571e1ee8935e134c728d91c63`.
Active release SHA-256: `40a3e683da0ce8a074de05ca335a5daf44ab0e974a2bed78acdf446abc1af242`.
The qualification implementation is compiled in an isolated service-owned copy,
using copied cached dependencies. Receipts pin its source commit separately from
that active deployment. This is candidate qualification, not release activation.

The installed Codex CLI is `0.159.2`. The current subscription account reports
`chatgpt`, plan `self_serve_business_prolite`. The advertised catalog includes
standard access for `gpt-6.1-sol`, `gpt-6-astra`, `gpt-6-sol`, `gpt-6-luna`;
only the latter two advertise `daybreakBlue`. These observations do not themselves
prove successful inference or Daybreak entitlement.

Compile with warnings as errors and 96 focused behavior tests passed in the
isolated copy. The tests cover loader/readiness, workstream execution, legacy
app-server options, exact named requests, credential exclusion, unsupported
capabilities, model reroutes, failed turns and the absolute qualification deadline.
Later hardening rejects explicit null authentication and prevents notifications from
extending named RPC deadlines; named definitions and request settings are unchanged.


## Live result matrix

Attempts ran on 2026-10-10 from 06:33:53 to 06:34:14 UTC. Tested qualification source:
`de571095e8fe8a87e5f5759512cc88db5aff2449`. Each receipt pins the agent YAML revision,
shared resource digests, this source commit, active deployment, worker and subscription
reference `projects/factory-511117/secrets/model-auth/versions/1`.

| Agent | Request | Observed configuration | Result |
| --- | --- | --- | --- |
| DefaultCloud | luna / medium / standard | Exact match, saved Daybreak false | Qualified bounded turn |
| HighEffortCloud | luna / high / standard | Exact match, saved Daybreak false | Qualified bounded turn |
| DefaultReview | 6.1-sol / high / standard | Exact match, saved Daybreak false | Qualified bounded turn |
| DaybreakCloud | 6-sol / high / daybreakBlue | Exact match, saved Daybreak true | Completed turn; effective program unobservable |
| DaybreakCloudLuna | luna / high / daybreakBlue | Exact match, saved Daybreak true | Completed turn; effective program unobservable |
| DaybreakReview (optional) | 6.1-sol / high / daybreakBlue | No thread started | Access program not advertised |

All five inference attempts returned their exact `QUALIFIED <name>: 42` marker. No
`model/verification` event was observed. No provider fallback or model reroute occurred.
Both Blue requests were accepted and completed; **this does not prove effective Daybreak
execution**. The installed experimental schema describes `daybreakEnabled` as a saved
choice, not a grant. Its turn-start/completion response has no effective model, effort
or Cyber program fields. `model/verification` reports a verification name rather than
effective program selection. All per-turn effective fields remain null in these receipts,
including ordinary attempts. Ordinary qualification reports verified thread configuration
and task success; it does not fabricate inference telemetry.

Preflight in the optional Review attempt rejects `access_program_not_advertised` before
thread or turn launch and retains the exact catalog snapshot. Normal dispatch separately
returns `daybreak_execution_unverified` before launching any app-server, even for models
that advertise Blue. No automatic subscription fallback is possible through the named
entry points.

## Retained evidence

Both rounds of [redacted receipts](../factory/evidence/dev-231/) and
[SHA-256 manifest](../factory/evidence/dev-231/artifacts.sha256.json) are committed.
Each original receipt was created exclusively with mode 0600; blocked attempts exited 1
and ordinary successes exited 0. Receipt hashes and every source/resource digest were
independently checked after retrieval. Raw account IDs, reset-credit IDs, credential
files and raw runtime diagnostics are excluded.

DefaultCloud and HighEffortCloud both successfully loaded and used the **same**
`factory/skills/factory-rig/SKILL.md` and implementation instruction file. Their receipts
record identical shared-resource hashes alongside different pinned agent hashes. The
probe appended its qualification-only request to those pinned resources. The review
probe shares the bounded qualification skill with optional Daybreak Review.

Every live preflight reported ordinary usage allowed, spend control false, and a primary
weekly window of 10080 minutes with 69% used, resetting at Unix time `1792206641`.
The secondary window and credit balance were null; credits were present and not unlimited.
These account-wide snapshots are observations, not per-probe consumption measurements.
No reset credits were redeemed and no additional credit/API mode was enabled.
Config provenance records the session's `forced_login_method: chatgpt`, user config hash
`5a2847da34afa9f3867fc957eadfaa3644994dd5684ab5512f35984b8f8c5c94` and system config hash
`44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a`.

## Commands and acceptance boundary

Operator transport uses the coordinator, not a direct worker login:

```bash
gcloud compute ssh rig-factory-coordinator --project=factory-511117 \
  --zone=us-central1-a --tunnel-through-iap \
  --command 'sudo -u factory-coordinator ssh -n -T -F /run/factory/ssh_config 10.42.0.2 <bounded-command>'
```

On the worker, source the active release's `factory/deploy/lib.sh`, call
`factory_load_runtime_env <active-release-directory> worker`, then enter the isolated
source `elixir/` directory. Override `MIX_BUILD_PATH` and `MIX_DEPS_PATH` to copied caches
under `/srv/factory/tmp/dev231`; set `MISE_TRUSTED_CONFIG_PATHS` to that source and
`ERL_FLAGS='+S 2:2'`. Run `factory_mix compile --warnings-as-errors` and the focused
files `agent_readiness_test.exs`, `agent_qualification_test.exs`, `workstream_test.exs`,
`workstream_runner_test.exs`, `app_server_options_test.exs`, `app_server_test.exs` under
`test/symphony_elixir/`, plus `test/mix/tasks/workstream_run_test.exs`. No heavy Rig/local build was used.

Run each definition with the [documented probe command](worker-qualification.md),
substituting its YAML, a distinct receipt filename, the exact tested source above and
active deployment. A final actual-worker guard check used the Daybreak definition with
`command: "must-not-launch"`; it returned `{:error, :daybreak_execution_unverified}`.
This is a dispatch rejection demonstration, not an additional inference attempt.

## Recommendation and remaining decisions

Keep Daybreak routing disabled. The demonstrated blocker is effective-program
observability, not a failed login or a proven lack of entitlement on the Blue-capable
models. Optional 6.1-sol Daybreak Review has the separate exact-model catalog blocker.
Resolve the effective-program verification boundary with supported runtime evidence
before enabling either; do not remove the guard because a saved toggle or answer succeeded.

DefaultCloud luna/medium, HighEffortCloud luna/high and DefaultReview 6.1-sol/high are
usable candidates for continued **single-worker, bounded** subscription investigation.
An engineer must choose final production models and validate real implementation/review
quality before expanding scope. No capacity recommendation follows from arithmetic.
The stable native integration reference is `factory/agents/default-cloud.yaml`, identified
as `default-cloud` by its workstream. It has no required inputs of its own; stage inputs
and prompts are owned by the workstream. Exact AppServer readiness/exclusion options are
listed in [worker qualification](worker-qualification.md).

The deployed release remains unchanged. These results do not claim native delegation,
review-quality validation, candidate publication, trusted Rig validation or twelve-slot
capacity. The tested source is a candidate implementation and is not activated on GCP.


## Self-review and integration notes

One concise self-review checked the admission boundary, legacy definitions, explicit
subscription binding, provider fallback, revision pinning, receipt redaction and deadline.
It caught the idle-timeout reset and explicit-null inheritance; both now fail closed.
Focused fake protocol tests cover exact requests and unsupported capabilities; the CLI
fixture now responds to readiness requests and verifies its actual failed-gate evidence.

Qualification executes **locally under the service identity on the qualified worker**.
Operator SSH is only the transport used to invoke the probe. WorkstreamRunner does not
supply an AppServer `worker_host`, and arbitrary SSH wrapped in `codex_command` does not
establish remote process identity or prove termination. Existing AppServer `worker_host`
transport remains separate. No cancellation/remote orchestration contract is added here.
Native transport and durable cancellation should follow sequentially in DEV-233; a port,
BEAM PID or local SSH PID is not proof of remote liveness or termination.

Stable integration: load `factory/agents/default-cloud.yaml` with Workstream.load_agent/1,
use AgentReadiness.dispatch/1 before scheduling, and pass the loaded agent plus its exact
model/effort and the resolved worker authentication reference to AppServer. Normal startup
then performs the runtime checks. Additional secret_environment_names are exclusions only
and remain unioned with existing protected names. Do not forward secret values.


## Broad alpha checks

The equivalent `make -C elixir all` was run remotely in the isolated copy with the pinned
mise runtime and private caches. Setup, escript build, formatting and public-spec checks
passed. Strict Credo stopped the pipeline (47 readability issues, 51 refactoring findings,
including qualification readability/complexity findings). Coverage and Dialyzer were not
reached by `make all`; this result is not a clean CI claim. No lint rules were disabled.

A separate full test run finished: **425 tests, 2 failures, 6 skipped, 10 excluded**.
The two failures are `ExtensionsTest` dashboard cases at lines 483 and 568, raising
`Enumerable not implemented for LazyHTML` in Phoenix LiveView's client proxy. This change
has no dashboard, dependency or lockfile edits. All 96 focused changed-behavior tests,
including the corrected CLI gate fixture, passed with compilation warnings treated as
errors. The actual-worker dispatch guard returned the expected error. Alpha handoff
retains these broad failures explicitly; it does not treat broad CI as green.


## Final committed-source verification

After deadline and authentication hardening, the exact source
`ebe5b5115e05c09d27ec150444778fa3ce948dd8` was archived to the isolated worker copy.
The six definitions were rerun once, writing exclusive `*-2.json` receipt paths from
06:46:44 to 06:47:04 UTC on 2026-10-10. All results match the first matrix: three
ordinary successes, two completed Blue turns blocked on effective-program observability,
and optional Review rejected before inference. No request settings, agent revisions or
shared-resource hashes changed. These final-source receipts are the current qualification
reference; the first round is retained as history. Both rounds have verified artifact hashes.

Second-round weekly usage snapshots reported 73% used with the same window/reset,
ordinary usage allowed and spend control false. This is shared account state, not a
measured cost of the probes. The final PR changes after this source pin only retain these
receipts and describe their results. No release activation, secret update or API fallback
was performed.

PR body validation passed against the exact tracked template. Source/receipt links and
all twelve receipt artifact hashes passed the final audit.
