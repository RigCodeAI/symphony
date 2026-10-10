#!/usr/bin/env bash
# Explicit operator installation only. Bootstrap/activation do not call this.
set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
[[ "$EUID" -eq 0 && "$#" -eq 2 ]] || {
  printf 'Usage (root, after review): %s /opt/factory/releases/<revision> /path/to/coordinator-public-key\n' "${0##*/}" >&2
  exit 2
}
operation_release="$(realpath -e -- "$1")"
[[ "$operation_release" =~ ^/(opt|srv)/factory/releases/[0-9a-f]{40}$ ]] || exit 2
# Validate the library before sourcing root code. Never adopt a worker-writable tree.
python3 - "$operation_release" <<'PY'
import os, stat, sys
from pathlib import Path
root = Path(sys.argv[1])
for path in [*root.parents, root, *root.rglob('*')]:
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise SystemExit('release tree must already be protected and root-owned')
PY
source "$operation_release/factory/deploy/lib.sh"
operation_revision="$(factory_release_revision "$operation_release")"
operation_sha="$(factory_release_sha256 "$operation_release")"
[[ "${operation_release##*/}" == "$operation_revision" ]] || exit 2
for operation_helper in worker_operation.py worker_operation_transport.py worker_operation_exec.py; do
  [[ -f "$operation_release/factory/deploy/$operation_helper" ]] || exit 2
done
operation_public_key="$(cat -- "$2")"
[[ "$operation_public_key" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+={0,2}$ ]] || {
  printf 'Supply one bare Ed25519 coordinator public key, without options or comment.\n' >&2
  exit 2
}
# Separate control from the agent's subscription-auth UID. No sudo or polkit rule.
if ! id factory-control >/dev/null 2>&1; then
  useradd --system --user-group --home-dir /var/lib/factory-control --shell /bin/sh factory-control
fi
[[ "$(id -u factory-control)" -ne 0 && "$(id -u factory-control)" != "$(id -u factory-worker)" ]] || exit 2
python3 - <<'PY'
import grp, os, pwd
account = pwd.getpwnam('factory-control')
if account.pw_dir != '/var/lib/factory-control' or account.pw_shell != '/bin/sh':
    raise SystemExit('existing control account needs operator migration')
if account.pw_gid != grp.getgrnam('factory-control').gr_gid:
    raise SystemExit('control account primary group needs operator migration')
if set(os.getgrouplist(account.pw_name, account.pw_gid)) != {account.pw_gid}:
    raise SystemExit('control account has unexpected supplemental access')
worker = pwd.getpwnam('factory-worker')
if worker.pw_uid == 0 or worker.pw_gid != grp.getgrnam('factory-worker').gr_gid:
    raise SystemExit('worker account primary identity needs operator migration')
if set(os.getgrouplist(worker.pw_name, worker.pw_gid)) != {worker.pw_gid}:
    raise SystemExit('worker account has unexpected supplemental access')
PY
for operation_dir in /var/lib/factory-control /var/lib/factory-control/.ssh /var/lib/factory-operations /var/lib/factory-operations/records /var/lib/factory-operations/gates; do
  [[ ! -L "$operation_dir" && ( ! -e "$operation_dir" || -d "$operation_dir" ) ]] || exit 2
  if [[ -e "$operation_dir" ]]; then
    operation_mode="$(stat -c %a -- "$operation_dir")"
    [[ "$(stat -c %u -- "$operation_dir")" == 0 ]] && (( (8#$operation_mode & 0022) == 0 )) || exit 2
  fi
done
install -d -o root -g root -m 0755 /var/lib/factory-control /var/lib/factory-control/.ssh /var/lib/factory-operations /var/lib/factory-operations/gates
install -d -o root -g root -m 0700 /var/lib/factory-operations/records
operation_keys=/var/lib/factory-control/.ssh/authorized_keys
[[ ! -L "$operation_keys" && ( ! -e "$operation_keys" || -f "$operation_keys" ) ]] || exit 2
[[ ! -e "$operation_keys" || "$(stat -c %u -- "$operation_keys")" == 0 ]] || exit 2
if [[ -e "$operation_keys" ]]; then
  operation_key_mode="$(stat -c %a -- "$operation_keys")"
  (( (8#$operation_key_mode & 0022) == 0 )) || exit 2
fi
printf 'restrict,command="/usr/bin/python3 -I %s/factory/deploy/worker_operation_transport.py --ssh" %s\n' \
  "$operation_release" "$operation_public_key" >"$operation_keys"
chown root:root "$operation_keys"
chmod 0644 "$operation_keys"
[[ -d /etc/factory && ! -L /etc/factory && ! -L /etc/factory/worker-operations.json ]] || exit 2
operation_config_mode="$(stat -c %a -- /etc/factory)"
[[ "$(stat -c %u -- /etc/factory)" == 0 ]] && (( (8#$operation_config_mode & 0022) == 0 )) || exit 2
python3 - "$operation_release" "$operation_revision" "$operation_sha" <<'PY'
import json, os, sys
release, revision, release_sha = sys.argv[1:]
config = {
    'version': 1, 'socket_path': '/run/factory-operations/control.sock',
    'records_dir': '/var/lib/factory-operations/records',
    'operation_dir': '/var/lib/factory-operations/gates',
    'workspace_root': '/srv/factory/workspaces',
    'wrapper_path': release + '/factory/deploy/worker_operation_exec.py',
    'worker_home': '/srv/factory/homes/factory-worker',
    'cache_paths': ['/srv/factory/tmp', '/srv/factory/build/' + revision],
    'machine_id_path': '/etc/machine-id',
    'boot_id_path': '/proc/sys/kernel/random/boot_id',
    'worker_user': 'factory-worker', 'worker_group': 'factory-worker',
    'control_user': 'factory-control',
    'service_revision': revision, 'release_sha256': release_sha,
}
with open('/etc/machine-id', encoding='ascii') as source:
    config['expected_machine_id'] = source.read().strip()
if len(config['expected_machine_id']) != 32 or any(c not in '0123456789abcdef' for c in config['expected_machine_id']):
    raise SystemExit('worker machine identity unavailable')
path = '/etc/factory/worker-operations.json'
with open(path + '.new', 'x', encoding='utf-8') as target:
    os.chmod(path + '.new', 0o600)
    json.dump(config, target, sort_keys=True, indent=2)
    target.write('\n')
    target.flush()
    os.fsync(target.fileno())
os.replace(path + '.new', path)
PY
[[ ! -L /etc/systemd/system/factory-worker-operations.service ]] || exit 2
if [[ -e /etc/systemd/system/factory-worker-operations.service ]]; then
  [[ -f /etc/systemd/system/factory-worker-operations.service && "$(stat -c %u -- /etc/systemd/system/factory-worker-operations.service)" == 0 ]] || exit 2
  operation_unit_mode="$(stat -c %a -- /etc/systemd/system/factory-worker-operations.service)"
  (( (8#$operation_unit_mode & 0022) == 0 )) || exit 2
fi
sed "s|@RELEASE@|$operation_release|g" "$operation_release/factory/deploy/factory-worker-operations.service" \
  >/etc/systemd/system/factory-worker-operations.service
chmod 0644 /etc/systemd/system/factory-worker-operations.service
systemd-analyze verify /etc/systemd/system/factory-worker-operations.service
printf 'Configuration installed. Service has not been enabled or started.\n'
printf 'Review root broker and control-account access before explicit activation.\n'
