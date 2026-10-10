# DEV-234 question and reply acceptance

Status: implementation and scoped acceptance in progress. No deployment or live
question/reply result is claimed by this record yet. Factory candidate publication
remains disabled. DEV-233's broker and worker application pins are unchanged.

## Scope

The coordinator stores questions before native elicitation, handles authenticated
human prompt events, and delivers replies once by provider activity identity.
A wait stops the contained operation before releasing capacity. Continuation
creates a fresh app-server thread using pinned stage context, saved human input
and the same dedicated workspace. Old JSON-RPC request IDs are not replayed.
Trusted approval waits require an explicit current artifact digest.

## Local checks

Checks run in the isolated `dev234-check` container with Elixir 1.19.5 / OTP 28
and the existing dependency cache. The source checkout has no local Elixir runtime.
Compilation with warnings-as-errors and `mix specs.check` passed. The combined
focused suite passed 167 tests with zero failures; a follow-up run of run/runner
and delegation tests passed 54 tests after the final continuation fixes. Webhook
checks passed 17 tests, including signed empty-body stop events. Broad CI is
running separately. This is local behavior evidence; live acceptance is pending.

## Scoped live fixture

[DEV-249](https://linear.app/rigai/issue/DEV-249/disposable-dev-234-question-and-restart-acceptance)
is a harmless disposable task owned by Adam. Matching dedicated worker and
coordinator clones were prepared from Rig seed
`39d6d5d998366bf13af19eb74ae47d598ecf92bd`, on branch
`cycle/dev-249-disposable`, with their push URLs set to `DISABLED`.
No deployment configuration or delegation was changed during this preparation.
Existing disposable clones were preserved. Operator access used the existing
IAP/SSH route; no IAM, budget, billing, VM or endpoint change was made.

## Self-review

The review checked activity/session identity, reply commit/replay ordering, exact
worker/attempt callback authorization, safe termination before capacity release,
and separation of clarifications from trusted approval gates. Regression tests
cover the two concrete data-loss risks found: a second question after same-stage
continuation, and saved input lost before a successful transport retry. Native
permission, secret and unsupported multi-question requests block explicitly.
No general independent review was added under the alpha guidance.

## Remaining acceptance

- Verify native elicitation, independent work and trusted wait termination.
- Restart while waiting; answer through the native agent conversation.
- Replay the provider reply and verify exactly one continuation and stage result.
- Verify a mid-turn reply remains durable until its safe boundary.
- Retain redacted receipts and remove temporary raw webhook signatures.
- Run broad CI in the background and inspect results before engineer handoff.
