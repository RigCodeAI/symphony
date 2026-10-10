#!/usr/bin/env bash
# Run as root in a disposable Linux container. Exercise the production helper
# with worker-owned paths and verify that root never follows worker symlinks.
set -Eeuo pipefail
umask 077

source_root="${FACTORY_TEST_SOURCE:-/workspace/factory/deploy}"
[[ "$EUID" -eq 0 && -f /.dockerenv && -f "$source_root/gcp-startup.sh" ]] || {
  echo 'Run as root in a disposable Docker container with deploy source mounted read-only' >&2
  exit 2
}

if ! id factory-worker >/dev/null 2>&1; then
  useradd --no-create-home --home-dir /srv/factory/homes/factory-worker --shell /bin/bash factory-worker
fi
worker_uid="$(id -u factory-worker)"
worker_gid="$(id -g factory-worker)"
worker_home=/srv/factory/homes/factory-worker
other_dir=/srv/factory/worker-owned
mkdir -p "$worker_home" "$other_dir"
chown "$worker_uid:$worker_gid" "$worker_home" "$other_dir"
chmod 0755 /srv/factory /srv/factory/homes
chmod 0700 "$worker_home" "$other_dir"

temporary="$(mktemp -d /tmp/factory-ssh-authorized-keys.XXXXXX)"
trap 'rm -rf -- "$temporary"' EXIT
ssh-keygen -q -t ed25519 -N '' -C fixture -f "$temporary/worker"
public_key="$(awk '{print $1 " " $2}' "$temporary/worker.pub")"

sed -n '/^factory_write_worker_authorized_keys() {$/,/^}$/p' "$source_root/gcp-startup.sh" \
  >"$temporary/production-helper.sh"
sed -n '/^factory_ensure_worker_codex_home() {$/,/^}$/p' "$source_root/gcp-startup.sh" \
  >>"$temporary/production-helper.sh"
[[ -s "$temporary/production-helper.sh" ]] || {
  echo 'could not extract production authorized-keys helper' >&2
  exit 1
}
# shellcheck source=factory/deploy/gcp-startup.sh
source "$temporary/production-helper.sh"

# A worker-controlled .ssh symlink must be rejected without touching its target.
runuser --user factory-worker -- ln -s "$other_dir" "$worker_home/.ssh"
printf 'preserve this file\n' >"$other_dir/authorized_keys"
chown "$worker_uid:$worker_gid" "$other_dir/authorized_keys"
if factory_write_worker_authorized_keys factory-worker "$worker_home" "$public_key" \
  >"$temporary/ssh-symlink.out" 2>&1; then
  echo 'production helper accepted a worker .ssh symlink' >&2
  exit 1
fi
[[ "$(cat "$other_dir/authorized_keys")" = 'preserve this file' ]]
rm "$worker_home/.ssh"

# Normal bootstrap creates and writes both paths as the service identity.
factory_write_worker_authorized_keys factory-worker "$worker_home" "$public_key"
[[ "$(stat -c '%u:%g:%a' "$worker_home/.ssh")" = "$worker_uid:$worker_gid:700" ]]
[[ "$(stat -c '%u:%g:%a' "$worker_home/.ssh/authorized_keys")" = "$worker_uid:$worker_gid:600" ]]
[[ "$(cat "$worker_home/.ssh/authorized_keys")" = "restrict $public_key" ]]

# An existing authorized_keys symlink must not redirect the user's write.
rm "$worker_home/.ssh/authorized_keys"
printf 'preserve target\n' >"$other_dir/authorized_keys"
runuser --user factory-worker -- ln -s "$other_dir/authorized_keys" "$worker_home/.ssh/authorized_keys"
if factory_write_worker_authorized_keys factory-worker "$worker_home" "$public_key" \
  >"$temporary/authorized-keys-symlink.out" 2>&1; then
  echo 'production helper accepted an authorized_keys symlink' >&2
  exit 1
fi
[[ "$(cat "$other_dir/authorized_keys")" = 'preserve target' ]]
rm "$worker_home/.ssh/authorized_keys"

# Root startup must not create/chmod/chown a worker-controlled .codex path.
runuser --user factory-worker -- ln -s "$other_dir" "$worker_home/.codex"
if factory_ensure_worker_codex_home factory-worker "$worker_home" \
  >"$temporary/codex-symlink.out" 2>&1; then
  echo 'production helper accepted a worker .codex symlink' >&2
  exit 1
fi
[[ "$(cat "$other_dir/authorized_keys")" = 'preserve target' ]]
rm "$worker_home/.codex"
factory_ensure_worker_codex_home factory-worker "$worker_home"
[[ "$(stat -c '%u:%g:%a' "$worker_home/.codex")" = "$worker_uid:$worker_gid:700" ]]

if factory_write_worker_authorized_keys factory-worker "$worker_home" 'ssh-ed25519 invalid!' \
  >"$temporary/invalid-key.out" 2>&1; then
  echo 'production helper accepted a malformed public key' >&2
  exit 1
fi

printf 'PASS: production helpers reject worker symlinks and create .codex/authorized_keys as factory-worker with 0700/0600 modes\n'
