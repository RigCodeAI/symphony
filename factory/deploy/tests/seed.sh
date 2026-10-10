#!/usr/bin/env bash
# Run as root inside a disposable Linux container, never on a deployment host.
# Verify Git's actual ownership checks with a root-owned qualified seed and a
# distinct worker account. No model credentials or cloud calls are involved.
set -Eeuo pipefail
umask 077
[[ "$EUID" -eq 0 && -d /workspace/factory/deploy ]] || exit 2
cd /tmp
useradd --create-home --shell /bin/bash factory-worker
mkdir -p /srv/factory/seed /srv/factory/workspaces
chmod 0755 /srv /srv/factory /srv/factory/seed
chown factory-worker:factory-worker /srv/factory/workspaces
chmod 0700 /srv/factory/workspaces
git -C /srv/factory/seed init --quiet
printf 'qualified seed fixture\n' >/srv/factory/seed/README
git -C /srv/factory/seed add README
git -C /srv/factory/seed -c user.name=Fixture -c user.email=fixture@example.test commit --quiet -m Fixture
chmod -R a+rX /srv/factory/seed
git config --system --replace-all safe.directory /srv/factory/seed
chmod 0600 /etc/gitconfig
if runuser --user factory-worker -- git -C /srv/factory/seed rev-parse HEAD >/tmp/seed-private.log 2>&1; then
  echo 'Unreadable Git configuration unexpectedly allowed root seed' >&2; exit 1
fi
# Execute the production configuration commands from bootstrap.
sed -n '/^  git config --system --replace-all safe.directory /p; /^  git config --system --add safe.directory /p; /^  chmod 0644 \/etc\/gitconfig/p' \
  /workspace/factory/deploy/gcp-startup.sh >/tmp/seed-config.sh
[[ "$(wc -l </tmp/seed-config.sh)" -eq 3 ]]
bash /tmp/seed-config.sh
bash /tmp/seed-config.sh
[[ "$(git config --system --get-all safe.directory | wc -l)" -eq 2 ]]
seed_commit=$(git -C /srv/factory/seed rev-parse HEAD)
[[ "$(runuser --user factory-worker -- git -C /srv/factory/seed rev-parse HEAD)" = "$seed_commit" ]]
runuser --user factory-worker -- git clone --no-local --no-checkout --quiet \
  /srv/factory/seed /srv/factory/workspaces/fixture
runuser --user factory-worker -- git -C /srv/factory/workspaces/fixture checkout --detach "$seed_commit" >/dev/null 2>&1
[[ "$(runuser --user factory-worker -- git -C /srv/factory/workspaces/fixture rev-parse HEAD)" = "$seed_commit" ]]
printf 'PASS: private system-config rejection, readable exact seed exception, repeat bootstrap, worker clone at pinned revision\n'
