# Contained worker operations (DEV-233)

This is the chosen SSH/systemd control path for native delegation. The code and
installation files are under development locally. They have not been deployed or
qualified on the intended worker. Native delegation remains blocked until the
worker supplies a current containment qualification receipt. Public Linear setup
and the real delegate/replay/stop pilot remain pending.

The existing `factory-worker` identity keeps its qualified subscription auth.
A separate `factory-control` account receives a forced SSH command through the
existing pinned coordinator key. It has no sudo or polkit grant, PTY or forwarding.
A root-owned Unix socket broker checks the kernel peer UID. The agent cannot use
that socket or create system units. The broker asks PID 1 to launch a fixed,
root-owned wrapper as `factory-worker`; it never executes task code as root.

There is one active or unknown operation per worker UID/host. This proves process
containment, not isolation between historical tasks sharing the worker home and
subscription auth. Publisher, Linear and control credentials stay outside the
agent account and its environment.

## Operation contract

The coordinator pins the SSH host, machine identity, service revision and release
checksum in the durable run. It never retries an operation on another machine.
The worker reserves the operation ID and canonical request digest before launch.
A repeated ID cannot create another unit; changed arguments reject. A lost launch
response reserves capacity. Unit names are hashes of operation IDs, not paths or
client-selected systemd properties.

The prepared unit waits. Its operation ID, OS boot, machine, unit invocation,
cgroup and request digest are returned and committed by the current coordinator
worker before release. Only a matching root-written release marker allows the
wrapper to exec. Stream loss, coordinator restart or a stale identity cannot
authorize another launch.

The unit has no capabilities, no delegation, a read-only cgroup hierarchy and
hidden system/control sockets. Only its dedicated workspace and qualified worker
home/caches are writable. It inherits a fixed runtime environment; request and
coordinator secret environments are discarded. Child `setsid` calls remain inside
the same cgroup.

Cancellation commits a stop tombstone immediately and runs bounded control work
outside the webhook handler. It validates the exact operation/boot/invocation,
sends TERM, then KILL if needed. Capacity releases only after a recorded empty
cgroup and terminal main process. An exact terminal invocation with an empty `ControlGroup`
property can prove systemd released the empty cgroup; a still-reported path requires
readable `cgroup.events` with recursive population zero. A missing unit, missing evidence, changed boot,
connection failure or timeout stays unknown. The stopped run cannot restart.
Normal stream completion also requires termination proof before stage completion;
an unproven outcome stays reconciling and reserves capacity.

## Reviewable installation change

The [installer](../factory/deploy/install-worker-operations.sh) and
[service template](../factory/deploy/factory-worker-operations.service) are explicit
operator actions. Existing bootstrap/activation does not invoke them. Installation
creates the control account, a root-owned forced-command key, private operation
ledger, worker-readable held manifests, a protected contained-workspace parent,
and broker configuration/service. It does
not start or enable the service and does not modify public ingress or cloud IAM.
It rejects account groups or writable root code paths that broaden access.

The new root broker and control-account grant need review before installation.
After approval, run the installer on a verified release as root, using only the
coordinator's bare public key, then review the emitted configuration before
explicit service activation. Do not run it from this source checkout or execute
worker-controlled caches as root. SSH still requires the existing authenticated
host key and private-network access. Use `factory-control@<existing-worker-alias>` to reuse the existing strict host/key
pin, or add a dedicated control alias with `User factory-control`. Keep the operator
pilot route separate.

The installer creates `/srv/factory/contained-workspaces` as root:factory-worker
0750 and preserves the legacy `/srv/factory/workspaces` tree. Before configuring an
issue workspace, an operator must provision its worker-owned leaf under this
protected parent and its matching coordinator clone path. The worker can clone
and edit inside the leaf, but cannot rename or replace sibling workspace names.
The current pilot uses explicit, pre-provisioned issue workspace mappings; it
does not automatically provision contained workspaces.

The concrete access change is:

- Create the system account/private group `factory-control` with home
  `/var/lib/factory-control` and a forced-command Ed25519 key. Its root-owned
  home and `.ssh` are 0755; `authorized_keys` is 0644. No sudo or polkit rule.
- Create root-owned `/var/lib/factory-operations/records` (0700) and `gates`
  (0755); manifests and release markers are root-owned 0644. The agent can
  read its launch gate but cannot write it or read the private ledger.
- Write `/etc/factory/worker-operations.json` as root 0600, pinned to the
  machine and verified immutable release. Write one system unit,
  `factory-worker-operations.service`. It runs the protected Python broker as
  root with group `factory-control` and supplementary `factory-worker` only
  for workspace traversal, an empty capability bounding set, a protected
  filesystem and writable ledger/runtime directories only.
- The broker creates `/run/factory-operations/control.sock` (0660) beneath a
  root-owned control-group directory (0750) and checks the peer UID. Each
  operation creates one uniquely hashed transient service as `factory-worker`.
  No cloud IAM, public ingress, dashboard access or publisher grant changes.

After review, these are the actual root host commands; substitute the verified
release and the coordinator's **public** key file. Use an idle disposable worker
with the existing runtime and worker account, never an active factory worker:

```bash
/opt/factory/releases/<revision>/factory/deploy/install-worker-operations.sh \
  /opt/factory/releases/<revision> /root/coordinator-public-key
FACTORY_SYSTEMD_TEST_DISPOSABLE=1 \
  FACTORY_SYSTEMD_TEST_MANAGER_REEXEC=1 \
  FACTORY_SYSTEMD_TEST_RECEIPT=/root/worker-operations-qualification.json \
  /usr/bin/python3 -I \
  /opt/factory/releases/<revision>/factory/deploy/tests/test_worker_operation_systemd.py
```

Inspect the passing receipt and test output before enabling dispatch. After its
review, install it as root 0600 at `/etc/factory/worker-operations-qualified.json`,
then run `systemctl daemon-reload` and
`systemctl enable --now factory-worker-operations.service`. Check
`systemctl is-active factory-worker-operations.service`, then run the coordinator's
`WorkerOperation.qualify/1` using the pinned control configuration. A successful
host card alone does not prove the forced SSH route or native Linear acceptance.

Rollback first disables native dispatch and removes the qualification receipt.
Keep the broker available until exact stop/reconciliation proves every existing
operation terminated; an unknown outcome keeps capacity reserved. Then disable
and stop the broker and remove the control account's authorized key to revoke
access. Keep operation records and the immutable release for recovery/audit;
do not delete ledgers, worker home, auth or workspaces as rollback. Existing
operator pilot SSH and the prior active release are unchanged by this installer.

The expected coordinator configuration, once qualified, is:

```yaml
linear_delegation:
  # Existing organization/app/team/token/path settings also required.
  worker_control:
    host: qualified-worker-control-alias
    machine_id: qualified-worker-machine-id
    service_revision: 40-character-verified-release-revision
    release_sha256: 64-character-verified-release-checksum
    argv:
      - /srv/factory/bootstrap-tools-v1/rig-tools/codex/bin/codex
      - --disable
      - apps
      - --disable
      - plugins
      - --disable
      - multi_agent
      - -c
      - 'forced_login_method="chatgpt"'
      - app-server
```

Both coordinator and worker must map the pinned dedicated workspace path. The
coordinator keeps definition/workspace safety checks; the agent and executable
candidate check run on the worker. `codex_command` overrides cannot accompany
`worker_control`. The resolved agent authentication reference and credential
exclusions are pinned with the run. Daybreak remains blocked by DEV-231.

## Verification boundary

Controlled engine tests check crash/replay, held release, exact identities,
TERM/KILL outcomes and unknown capacity. Transport tests check real Unix peers,
framing and real held wrappers. Elixir tests check the SSH protocol, durable
registration ordering and trusted-proof-only completion. Controlled managers do
not prove real systemd containment.

The [opt-in systemd card](../factory/deploy/tests/test_worker_operation_systemd.py)
requires an explicitly supplied disposable Linux host with PID 1 systemd,
cgroup v2, the qualified runtime/account and systemd 252 or newer. It launches
real units with a `setsid` child that ignores TERM, verifies held launch and
replay, rejects a stale identity, and requires proof that both processes stopped.
It also checks natural exit through systemd's released-cgroup proof and durable
controller recovery. With the separate explicit `FACTORY_SYSTEMD_TEST_MANAGER_REEXEC=1`
opt-in, it re-executes PID 1 while held and while a child is live, then verifies the same
invocation/cgroup before stopping the whole tree. This is a host-wide manager operation;
run it only on the idle disposable qualification worker. That check is required in the receipt.
It uses a private test socket and only test-created units.
It skips without that host; a skip is unverified acceptance. No suitable host has
been qualified. The existing pilot passed read-only preflight; installation and this privileged
card remain pending. Do not run this card on an active factory worker.

A root-owned mode-0600 qualification receipt at
`/etc/factory/worker-operations-qualified.json` must match the tested machine, OS
boot, systemd version, service revision and release checksum. Missing, stale or incomplete receipts
block production qualification. The installer never creates a passing receipt.
The card can write a new root-private output receipt when
`FACTORY_SYSTEMD_TEST_RECEIPT` is supplied; it writes only after every check and
cleanup succeeds. Review that output before installing it at the fixed receipt
path. Run the card from the configured immutable release with
`FACTORY_SYSTEMD_TEST_DISPOSABLE=1` and `FACTORY_SYSTEMD_TEST_MANAGER_REEXEC=1`;
its default skip cannot generate a receipt.
The installed app, public endpoint and actual native stop pilot must still pass
[the live acceptance checklist](linear-delegation.md) before an acceptance PR.

### Existing systemd 252 worker

The adapter supports systemd 252 and newer. It adds `--expand-environment=no` on 254+
and omits that unsupported flag on 252/253. Only the protected wrapper, literal
`--manifest` and hashed descriptor path reach systemd-run; `$` and `%` in those fixed
paths reject before launch. Task argv stays in the protected descriptor and is executed
directly by the held wrapper after durable release. Isolation properties remain identical.

This compatibility decision follows the [v252.39 CLI and argv construction](https://github.com/systemd/systemd-stable/blob/v252.39/src/run/run.c),
[recursive-empty cgroup release](https://github.com/systemd/systemd-stable/blob/v252.39/src/core/cgroup.c),
[ControlGroup reporting](https://github.com/systemd/systemd-stable/blob/v252.39/src/core/dbus-unit.c)
and [cgroup serialization/restoration during manager re-execution](https://github.com/systemd/systemd-stable/blob/v252.39/src/core/unit-serialize.c).
Terminal state, matching invocation/principal/request, and zero MainPID remain mandatory
for released-cgroup proof. These source checks and local tests permit qualification on
the existing host; they do not qualify it.

The containment design follows systemd's
[whole-cgroup kill behavior](https://github.com/systemd/systemd/blob/main/man/systemd.kill.xml)
and [cgroup protection](https://github.com/systemd/systemd/blob/main/man/systemd.exec.xml),
and the kernel's [recursive population contract](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html).
