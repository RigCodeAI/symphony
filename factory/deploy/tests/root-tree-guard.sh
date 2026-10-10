#!/usr/bin/env bash
# Run as root in a disposable Linux container. Exercise startup's protected
# cache/source checks with root-owned and service-owned fixture trees.
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

temporary="$(mktemp -d /tmp/factory-root-tree-guard.XXXXXX)"
trap 'rm -rf -- "$temporary"' EXIT
sed -n '/^factory_assert_root_tree() {$/,/^}$/p; /^factory_assert_root_directory() {$/,/^}$/p' \
  "$source_root/gcp-startup.sh" >"$temporary/production-guards.sh"
[[ -s "$temporary/production-guards.sh" ]] || {
  echo 'could not extract production root-tree guards' >&2
  exit 1
}
# shellcheck source=factory/deploy/gcp-startup.sh
source "$temporary/production-guards.sh"

mkdir -m 0755 "$temporary/good"
printf 'trusted fixture\n' >"$temporary/good/source"
chmod 0644 "$temporary/good/source"
factory_assert_root_tree "$temporary/good"

mkdir -m 0755 "$temporary/service-owned"
printf 'worker cache\n' >"$temporary/service-owned/input"
chown factory-worker:factory-worker "$temporary/service-owned/input"
if factory_assert_root_tree "$temporary/service-owned" >"$temporary/service-owned.out" 2>&1; then
  echo 'root-tree guard accepted a worker-owned file' >&2
  exit 1
fi

mkdir -m 0755 "$temporary/group-writable"
printf 'writable fixture\n' >"$temporary/group-writable/input"
chmod 0664 "$temporary/group-writable/input"
if factory_assert_root_tree "$temporary/group-writable" >"$temporary/group-writable.out" 2>&1; then
  echo 'root-tree guard accepted a group-writable file' >&2
  exit 1
fi

mkdir -m 0755 "$temporary/escaping-link"
printf 'outside\n' >"$temporary/outside"
ln -s "$temporary/outside" "$temporary/escaping-link/link"
if factory_assert_root_tree "$temporary/escaping-link" >"$temporary/escaping-link.out" 2>&1; then
  echo 'root-tree guard accepted an escaping symlink' >&2
  exit 1
fi

mkdir -m 0700 -p /root/.config/mise
factory_assert_root_tree /root/.config/mise
chmod 0770 /root/.config/mise
if factory_assert_root_tree /root/.config/mise >"$temporary/mise-config.out" 2>&1; then
  echo 'root-tree guard accepted a group-writable root mise config' >&2
  exit 1
fi
chmod 0700 /root/.config/mise

[[ ! -e /usr/local/bin/mise && ! -L /usr/local/bin/mise ]] || {
  echo 'disposable image already has /usr/local/bin/mise; cannot test the pinned shim exception' >&2
  exit 2
}
cp /bin/true /usr/local/bin/mise
chmod 0755 /usr/local/bin/mise
mkdir -m 0755 "$temporary/mise-shim"
ln -s /usr/local/bin/mise "$temporary/mise-shim/mise"
factory_assert_root_tree "$temporary/mise-shim"
rm /usr/local/bin/mise

factory_assert_root_directory /usr/local/bin
mkdir -m 0775 "$temporary/writable-parent"
if factory_assert_root_directory "$temporary/writable-parent" >"$temporary/parent.out" 2>&1; then
  echo 'root-directory guard accepted a group-writable parent' >&2
  exit 1
fi

printf 'PASS: protected tree rejects worker ownership, writable files, escaping symlinks and writable root config; exact mise shim path is allowed\n'
