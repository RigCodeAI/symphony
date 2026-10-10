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

Compile with warnings as errors and 89 focused behavior tests passed in the
isolated copy. The tests cover loader/readiness, workstream execution, legacy
app-server options, exact named requests, credential exclusion, unsupported
capabilities, model reroutes, failed turns and the absolute qualification deadline.
Live receipts and recommendation are added after the pinned attempts.
