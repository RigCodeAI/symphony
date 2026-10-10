# DEV-233 transport deployment checkpoint

Observed on 2026-10-10. The worker transport repair is installed and qualified. Native
active-work cancellation and restart acceptance remain incomplete because subscription
readiness returned `usage_paused` before a thread or turn started.

## Installed and verified

- Worker control: `a4c95481b898d05817d24cbcf76635d9c4b739c5`.
- Archive SHA-256: `e805385f93cf360d79ddb3d5537d02f4cff5a544d2e33aa2cd960f05fdc7802c`.
- Machine: `fe9b1ece921d40aeac95b10940000311`; boot:
  `5734c5bd0a864f4fae49e6a088bbf2e4`; systemd 252.
- Worker application remains `541279aeb6a5366571e1ee8935e134c728d91c63`.
- Coordinator candidate a4c9548 built from the committed source and is staged with protected
  configuration, existing secret-version references and rollback. It is not activated;
  the live coordinator remains `080c048448cc949cf796f10564f16c8cf83a60e8`.

The original source check was `python3 -m unittest
factory.deploy.tests.test_worker_operation_transport
factory.deploy.tests.test_worker_operation`: 38 passed. On the worker, the exact candidate
transport suite passed 11/11 as factory-worker from the source directory with the normal
fixture umask ([test output](transport-worker-tests.log)). The root systemd card used `FACTORY_SYSTEMD_TEST_DISPOSABLE=1`,
`FACTORY_SYSTEMD_TEST_MANAGER_REEXEC=1` and a unique root-only receipt output. All seven
checks passed: held launch, duplicate prepare, stale identity rejection, setsid child
termination, natural exit, restart recovery and manager re-execution.

Actual forced SSH tests passed held/duplicate/stale behavior, observed a detached process
group inside the same cgroup, terminated both processes, checked exact empty-cgroup proof,
and checked stream and natural-exit replay. General shell commands were rejected.
See [forced SSH evidence](transport-forced-ssh-qualification.json).

The actual built Elixir coordinator qualified the new worker pin, resolved the DEV-245 and
DEV-246 routes, and rejected unknown workspace, agent and workstream definitions. The new
resolved definition digest is
`99e757299a34663b640412055c6a1a9a1f3177486e40180576aab33e1bfff1de`.
See [Elixir qualification](transport-elixir-qualification.json).

## Maintenance and preservation

The existing authorized temporary startup-metadata route required six bounded idle VM resets.
The intermediate attempts exposed helper issues: a health-probe newline, a preservation
manifest size limit, cache permissions affected by umask, snapshot reuse after a fresh old
receipt, a socket readiness race, and the unit-test harness. Detailed output from the fifth attempt was not captured;
the account, source directory and fixture umask were corrected before the sixth attempt. They are
recorded in [maintenance attempts](transport-maintenance-attempts.json). The fifth attempt
installed the candidate, failed its unit-test gate and successfully restored/requalified the
old control pin. The sixth passed installation, both test gates, preservation and broker
health. No agent turn was running during maintenance.

Each attempt restored the exact original metadata. The same VM, disks and network remained;
worker app configuration and the pinned auth/data manifest matched. No worker key, OS Login, privilege,
secret, model, billing or publisher grant was added. The reviewed coordinator-only Terraform
change updated release metadata and exact archive read access, retaining rollback archives
and the existing host-key object ([plan review](transport-coordinator-plan-review.json)). Old releases, root control snapshots,
run records and both disposable workspaces remain. See
[preservation evidence](transport-worker-preservation.json). The final
[idle audit](transport-worker-idle.json) found no live contained work. Three completed
systemd-run helpers remained as zombies; the audit observed their cgroups empty.

## Current blocker and safe state

The no-turn AppServer probe now completes initialize and account/model/usage reads through
the short persistent SSH stream. Agent readiness returned `usage_paused`; full thread
configuration, inference and terminal execution remain unverified. The exact probe operation
terminated with main PID 0 and an empty/released cgroup. See
[readiness](transport-app-readiness.json) and [termination proof](transport-app-stop-proof.json).
The extra startup-envelope warning and bundled bubblewrap fallback warning were observed;
no terminal command was executed to qualify that fallback.

The desktop account tool separately reported `ordinaryUsageAllowed=false`, 100% weekly
usage and two available reset credits. No reset was consumed. Explicit approval to use one
was requested because the reset tool requires approval for every redemption. OpenAI's
[App Server documentation](https://learn.chatgpt.com/docs/app-server) describes reading limits,
consuming an earned reset with an idempotency key, then refreshing limits.

The live coordinator is healthy and still has the single original DEV-245 stopped
run/session/acknowledgement. See [held coordinator health](transport-coordinator-held-health.json).
DEV-246 (`4082e503-0c3c-40e4-a4a7-8680d4353b35`) is a separate disposable issue retaining
Adam as assignee and factory:rig scope. Its matching provisioned clones have push disabled.
It has never been delegated. No new webhook observer or bootstrap-token process was started.

After usage is available, rerun full startup readiness with a fresh operation identity,
activate the staged coordinator, then start the bounded observer before native delegation.
Replay the actual created delivery within 45 seconds. Observe sleep 180 in the exact cgroup,
restart the coordinator, and check whether the same operation is still active before
undelegating. If EOF already ended the operation, that observation is restart cleanup and
cannot prove native active-work cancellation. Preserve the evidence and use a separate
bounded disposable fixture for the cancellation check. Do not reset immutable issue runs,
publish, merge, close DEV-233 or claim acceptance before the actual checks pass.
