# Working on Rig Symphony

Keep responses plain and simple. Avoid overly technical or flowery language.

## Start here

- This is `RigCodeAI/symphony`, where we build the factory service. The factory's
  initial coding target is the separate `RigCodeAI/rig` repository on `main`.
- Read [README.md](README.md), the assigned Linear ticket (acceptance criteria,
  verification, comments and dependencies), and the
  [Factory Setup specification](https://linear.app/rigai/project/factory-setup-a2dff7721c28/overview).
  Read [elixir/AGENTS.md](elixir/AGENTS.md) before changing anything under `elixir/`.
- The Linear project is a draft design, not proof of implemented or deployed behavior.
  Check source and tests before claiming capabilities. Resolve material conflicts
  between ticket and project before implementing the affected behavior.
- [SPEC.md](SPEC.md) defines the shared Symphony contract. Update it in the same change
  when extending shared behavior. Preserve existing `WORKFLOW.md` compatibility.
- Local `docs/rig-software-factory-spec.md` and `docs/factory-setup-ticket-drafts.md`,
  when present, are earlier drafts. They omit newer workstream decisions and contain
  obsolete profile terminology and unpublished-ticket notes. Use live Linear for current
  scope and dependencies; do not recreate tickets from those drafts.

## Use subagents when relevant

- Use subagents for well-scoped independent investigation, implementation, testing or
  review when that helps the task. Keep small or tightly dependent work in the main agent.
- Explicitly select **GPT-6 Luna** (`gpt-6-luna`) with **max reasoning** for subagents.
  Use a delegation mode that permits these settings and supply the necessary context.
  If unavailable, report the limitation instead of silently using another model.
- Give each subagent a clear deliverable and explicit file/module ownership for edits.
  Tell it other agents may be working and not to revert their edits. Avoid simultaneous
  writers to the same files. The main agent integrates and verifies results.
- For non-trivial changes, use an independent adversarial review of the design and
  adjacent failure paths. This development review does not satisfy a factory validation
  gate or authorize merging.
- These settings apply to subagents developing this repository. Factory cloud/review
  agent definitions have separately configured and qualified runtime settings.

## Architecture and ownership

Extend existing owners; do not introduce a second scheduler. Paths below are under
`elixir/lib/symphony_elixir/` unless stated otherwise.

| Responsibility | Starting point |
| --- | --- |
| Scheduling, claims, retries and reconciliation | `orchestrator.ex` |
| Issue execution and supervision | `agent_runner.ex`, `agent_runtime_supervisor.ex` |
| Workspace safety and remote execution | `workspace.ex`, `path_safety.ex`, `ssh.ex` |
| Codex app-server and tools | `codex/` |
| Configuration and workflow loading | `config.ex`, `config/schema.ex`, `workflow.ex`, `workflow_store.ex` |
| Tracker contract and Linear integration | `tracker.ex`, `tracker/issue.ex`, `linear/` |
| Dashboard and HTTP interface | `elixir/lib/symphony_elixir_web/` |
| Tests and logging conventions | `elixir/test/`, `elixir/docs/logging.md` |

## Factory design boundaries

- Deliver the assigned increment, not the whole roadmap. Start with DEV-229's local
  agent → executable-check workstream, then DEV-232's durable runs and human wait.
  The first local demo needs neither Linear/GCP nor Daybreak, publication or merge.
- A **workstream** declares stages, inputs/outputs, transitions and inline gates.
  An **agent** owns instructions, model/effort, Daybreak, permissions and skill references.
  A **skill** supplies reusable guidance; an **evaluator** produces structured evidence.
  Gates are service-enforced requirements, not agent opinions.
- Use versioned workstream YAML, agent YAML or Markdown frontmatter, and `SKILL.md`
  directories. `factory/workstreams/`, `factory/agents/` and `factory/skills/` are proposed
  locations until implemented. Do not add a separate profile object, gate registry,
  arbitrary expression language or general distributed workflow platform.
- Validate references, required inputs, transitions and bounded repair cycles. Pin resolved
  definitions and policy versions per run. Persist stage attempts, artifact identities,
  gate outcomes, waits, counters and external operation identities.
- Keep one coordinator owner and one branch writer per task. Reconcile worker liveness
  before replacement; unreachable does not mean terminated. Human waits release execution
  capacity. Restart and duplicate events must not repeat side effects.
- Native Linear delegation selects Default, High Effort or Daybreak cloud agents while
  preserving the human assignee. Project/team membership alone must not dispatch work.
  Review agents are internal and cannot receive delegation. Stop/undelegation stops further
  work. Persist questions and deliver human replies once.
- Validate the exact candidate commit with trusted policy and an isolated runner before
  publication or normal review. Missing, failed, forged, stale or incomplete evidence blocks
  advancement. Keep publisher/check credentials outside agent/test environments. Require
  the trusted `factory/validation` GitHub check for the current head before merge.
- Preserve the same PR and branch through retries and review fixes. Reviews use separate
  checkouts/conversations, a pinned rubric, and recorded base/head. New heads invalidate old
  review and validation decisions. Bound candidate-validation repair and review-fix loops
  separately to three unsuccessful rounds before human escalation.
- The initial factory waits for a human to merge in GitHub. A Linear status, answered
  question or bot approval does not authorize factory merging. Coordinate with Rig's
  existing PR-feedback automation so only one system owns fixes.
- Confirm GitHub merge and durable archival before deleting merged workspaces. Linear Done
  alone is insufficient. Cleanup must not implicitly close open PRs. Retain redacted
  conversations and validation evidence permanently outside disposable workspaces.
- Coverage Factory owns scenarios, frozen oracles, specimen qualification and scoring.
  Consume its versioned contracts; do not invent validators or equate a merged capability
  PR with proven coverage. Synthetic receipts belong only in contract tests.
- GCP/Terraform is the initial deployment direction. Qualify one worker before expanding;
  roughly twelve combined cloud/review slots is a target, not measured capacity. Verify
  model/authentication/Daybreak on the intended worker. Do not assume desktop settings
  transfer or silently switch to API billing.

## Implementation and verification

- For the implemented local workstream, start at
  [docs/local-workstreams.md](docs/local-workstreams.md). Its validation command
  checks definitions before dispatch; its run command uses a dedicated Rig clone.

- Preserve unrelated changes. Read ticket dependencies live before parallelizing work.
- `elixir/WORKFLOW.md` is an upstream sample, not Factory Setup policy. It targets upstream
  Symphony, uses different statuses, closes PRs on rework and invokes merging. Its
  `before_remove` hook can close PRs. Do not run it unchanged for Rig factory tasks.
- Keep managed issue workspaces separate from this source checkout. Never launch a factory
  coding turn here. Preserve configured workspace-root safety checks.
- Follow [elixir/README.md](elixir/README.md) for setup. From `elixir/`, use
  `mise exec -- mix setup`, `mise exec -- mix build`, and focused
  `mise exec -- mix test <test-file>`. Elixir code changes require
  `mise exec -- make all` before handoff; follow nested guidance for specs and PR bodies.
- Test observable behavior, especially restart, duplicate delivery, stale evidence,
  cancellation and recovery. Execute the ticket's acceptance/verification steps and
  report missing prerequisites and unverified stages plainly.
- Live E2E tests create external resources and run real agents. Use the documented
  disposable setup deliberately; unit tests do not prove a deployment works.
- For Rig worker qualification, read the actual target revision's toolchain, build and
  architecture guidance. Do not infer successful Rust compilation from source-only CI.
- Update docs with behavior/config changes. Keep proposed, implemented, locally tested and
  deployed behavior distinct. Documentation-only edits need link/diff checks, not runtime
  tests. Record exact commands and evidence for implementation work.
