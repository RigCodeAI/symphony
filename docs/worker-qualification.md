# Worker qualification

DEV-231 adds explicit named definitions and an operator-only bounded qualification
command. It runs independently of normal workstream dispatch. The evidence record is
[DEV-231](dev-231-evidence.md); a successful arithmetic turn does not prove Rig build,
review quality, concurrency capacity, entitlement for every task or deployed readiness.

| Agent | Model | Effort | Daybreak |
| --- | --- | --- | --- |
| DefaultCloud | gpt-6-luna | medium | off |
| HighEffortCloud | gpt-6-luna | high | off |
| DaybreakCloud | gpt-6-sol | high | on |
| DefaultReview | gpt-6.1-sol | high | off |
| DaybreakReview (optional) | gpt-6.1-sol | high | on |
| DaybreakCloudLuna (comparison) | gpt-6-luna | high | on |

These are investigation candidates, not a final production model selection. Cloud candidates reuse one [Rig skill](../factory/skills/factory-rig/SKILL.md)
and instruction file. Review candidates share the bounded qualification skill and review guidance.
Each definition pins subscription reference
`projects/factory-511117/secrets/model-auth/versions/1`. No credential values belong in YAML,
inputs, commands or receipts. The service supplies the resolved reference; comparing it
only binds configuration. Deployment owns loading the actual subscription material.

## Run one probe

From the isolated Symphony source's `elixir/` directory, under the worker service identity
with its existing subscription home and Codex/Node PATH:

```bash
mise exec -- mix agent.qualify ../factory/agents/default-cloud.yaml \
  --workspace /srv/factory/tmp/qualification/workspace \
  --workspace-root /srv/factory/tmp/qualification \
  --receipt /srv/factory/tmp/qualification/DefaultCloud-attempt-1.json \
  --authentication-reference projects/factory-511117/secrets/model-auth/versions/1 \
  --source-revision <tested-source-commit> \
  --deployment-revision <active-release-commit> \
  --worker rig-factory-worker-01
```

Create workspace and receipt parent directories first, with private permissions. Use a
new receipt filename for every attempt. The command creates receipts with mode 0600 and
never overwrites them. A blocked probe still writes its receipt and exits nonzero. It
allows one arithmetic turn, disables tools and network access, caps RPCs at 30 seconds
and the turn at 90 seconds, then stops the app-server. Shared guidance forbids file edits.
The workspace-write sandbox remains the version-1 policy; this is not an isolated evaluator.

Preflight reads account type/plan, paginated model catalog, limits and selected config
values/layer versions. It rejects unsupported model, effort, access program, non-ChatGPT
authentication and explicit usage pauses. It never chooses a fallback or API billing.
`daybreak: true` requests saved `daybreakEnabled` and turn `cyberAccessProgram: daybreakBlue`.
Ordinary definitions request `standard`. Thread model/effort/saved toggle must match.
A `model/rerouted` event or failed/interrupted turn blocks success.

## Read the receipt

`requested` comes from the pinned agent definition. `observation.configured` records the
thread-start response. `observation.effective` stays null where the installed protocol has
no per-turn model/effort/program telemetry. `runtime` records allowlisted server identity,
model capabilities, config provenance and observed limits; unknown limits are not zero.
Receipts exclude raw diagnostics and account/reset-credit IDs. `qualified` for an ordinary
agent means the exact marker returned with verified configuration. It does not assert
per-turn telemetry. Daybreak remains blocked even after a completed response if the
effective program cannot be observed. Optional unsupported Daybreak Review stops before
thread/turn launch. Normal `AppServer.start_session` and WorkstreamRunner always reject
Daybreak; the probe is a deliberate operator action, not a routing fallback.

Coordinator integration uses `AgentReadiness.dispatch/1`, then AppServer options `agent`,
`model`, `reasoning_effort`, `authentication_reference`. `secret_environment_names` is an
optional list of extra variable names to **remove**, never forward. Invalid names fail
before launch. WorkstreamRunner pins these names and the auth reference in execution context.

Native routing can reference `factory/agents/default-cloud.yaml` as agent identifier
`default-cloud`. Stage inputs and prompts belong to the workstream, not the agent.
The definition uses shared Rig instructions and skill references, without a separate profile.
