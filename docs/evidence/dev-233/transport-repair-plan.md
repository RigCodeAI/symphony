# Reviewed worker transport repair and repeat acceptance

Status: the reviewed worker repair is installed on control release
`a4c95481b898d05817d24cbcf76635d9c4b739c5` and qualified. The coordinator candidate
is staged but held on the previous active release because subscription readiness returned
`usage_paused`. No thread or turn started. Reset-credit approval is pending.
See the [deployment checkpoint](transport-deployment.md).

The coordinator clarified that the necessary scoped bridge fix, immutable control pin
update and repeat integration testing are covered by the existing installation/testing
authorization. The sequence below records the reviewed scope.

The first real native attempt and two no-turn diagnostics timed out before initialize
completed. The real-pipe regression reproduced a short request waiting for EOF under
`read(65536)`; it passes with `read1(65536)`. The change is limited to
`factory/deploy/worker_operation_transport.py` and its focused transport test.
It changes stdin forwarding, not dispatch policy, permissions, model or billing.

## Reviewed deployment scope

1. Pin the reviewed fix to a new immutable source release and archive digest. Retain
   coordinator `080c048448cc949cf796f10564f16c8cf83a60e8`, worker application
   `541279aeb6a5366571e1ee8935e134c728d91c63` and worker-control
   `cc85ca7871a27afb03bc2b6e86722a142ff93e7e` as rollback artifacts.
2. Stage the protected worker-control release, allowing the worker to read only the exact
   new archive if needed. Inspect the Terraform plan first; no VM replacement, disk
   deletion, new secret grants, model changes or publisher access is included.
3. While no agent operations are active, retain the old root-owned configuration,
   forced-command authorized key, unit file and qualification receipt. Explicitly install
   the new control helpers and activate the operations broker without upgrading the worker application. The existing
   privileged route uses a bounded startup-script maintenance reset of the idle VM; restore
   exact metadata afterward and requalify the new boot. No new administrator key, OS Login
   enablement or privilege grant is included. Re-run the contained-operation qualification card, including
   cancellation, restart/duplicate and secret boundaries, and the short live initialize
   probe. Record a new root receipt for the same worker machine, current boot and exact new pin.
4. Update the coordinator's protected worker-control revision/digest only after that
   receipt passes. Verify actual Elixir broker qualification and no-turn app-server startup
   using the unchanged DefaultCloud model, effort, subscription auth and sandbox.
   Roll back control/config/pins if qualification or health fails; retain all run records.

## Replacement disposable acceptance scope

Create one clearly marked disposable issue, retaining Adam as human assignee and the
explicit `factory:rig` label. Provision a separate protected workspace leaf and dedicated
Rig clone with push disabled. Keep DEV-245's failed/stopped evidence unchanged.

Capture the actual native created delivery before delegation, acknowledge one run, replay
its exact signed delivery within the freshness window, and verify one run/acknowledgement.
Observe the real terminal sleep and contained process before testing restart and native
undelegation. Require exact empty-cgroup termination proof and no replacement launch.
Recheck bad signatures, unrelated delivery and invalid definition routing. Keep dashboard
IAP and all existing credential boundaries. Do not publish, merge, close DEV-233 or claim
acceptance until active-work cancellation and recovery pass.

Local tests and live diagnostic outcomes are recorded in
[transport repair verification](transport-repair-verification.json) and
[native attempt evidence](native-live-partial.json).
