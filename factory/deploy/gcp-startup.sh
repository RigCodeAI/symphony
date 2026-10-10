#!/usr/bin/env bash
# Runs as root on a Debian 12 VM. No values of secrets are logged or persisted
# in instance metadata, Terraform inputs, release archives or object backups.
set -Eeuo pipefail
umask 077
trap 'printf "FACTORY_EVENT startup_failed\n" >>/var/log/factory-events.log' ERR

[[ "$EUID" -eq 0 ]] || { echo 'Startup requires root' >&2; exit 1; }
# The Compute startup unit omits a login environment. Re-enter as the actual
# root account so tools resolve its normal home rather than an unset HOME.
if [[ -z "${HOME:-}" ]]; then
  exec runuser --user root -- bash "$0" "$@"
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl git python3 python3-venv sqlite3 jq openssh-server \
  iptables iptables-persistent util-linux build-essential autoconf m4 \
  libncurses-dev libssl-dev libwxgtk3.2-dev libgl1-mesa-dev libglu1-mesa-dev \
  libpng-dev libssh-dev unixodbc-dev xsltproc fop libxml2-utils time xz-utils

# Never expose the instance service identity to the unprivileged smoke agent.
# The agent user has no sudo, Docker socket or privileged service membership.
for tool in iptables ip6tables; do
  "$tool" -N FACTORY_METADATA 2>/dev/null || true
  "$tool" -F FACTORY_METADATA
  # Google also serves DNS on this address. The system resolver runs as a
  # non-root user; blocking port 53 breaks package/tool downloads after reboot.
  "$tool" -A FACTORY_METADATA -p udp --dport 53 -j RETURN
  "$tool" -A FACTORY_METADATA -p tcp --dport 53 -j RETURN
  "$tool" -A FACTORY_METADATA -m owner --uid-owner 0 -j RETURN
  "$tool" -A FACTORY_METADATA -j REJECT
done
iptables -C OUTPUT -d 169.254.169.254/32 -j FACTORY_METADATA 2>/dev/null || \
  iptables -I OUTPUT -d 169.254.169.254/32 -j FACTORY_METADATA
ip6tables -C OUTPUT -d fd20:ce::254/128 -j FACTORY_METADATA 2>/dev/null || \
  ip6tables -I OUTPUT -d fd20:ce::254/128 -j FACTORY_METADATA
netfilter-persistent save

install -d -m 0700 /usr/local/lib/factory
# Service users read public settings; private config stays root-owned 0600.
install -d -m 0755 /etc/factory
install -d -m 0755 /opt/factory
metadata='http://169.254.169.254/computeMetadata/v1/instance/attributes'
curl --fail --silent --show-error --retry 8 -H 'Metadata-Flavor: Google' \
  "$metadata/factory-config" >/etc/factory/config.json
curl --fail --silent --show-error --retry 8 -H 'Metadata-Flavor: Google' \
  "$metadata/factory-cloud-io" >/usr/local/lib/factory/cloud_io.py
chmod 0600 /etc/factory/config.json /usr/local/lib/factory/cloud_io.py
helper_sha256="$(curl --fail --silent --show-error -H 'Metadata-Flavor: Google' "$metadata/factory-cloud-io-sha256")"
[[ "$helper_sha256" =~ ^[a-f0-9]{64}$ ]] || exit 1
printf '%s  /usr/local/lib/factory/cloud_io.py\n' "$helper_sha256" | sha256sum --check --status
role="$(jq -er '.role | select(. == "worker" or . == "coordinator")' /etc/factory/config.json)"
revision="$(jq -er '.service_revision | select(test("^[a-f0-9]{40}$"))' /etc/factory/config.json)"
digest="$(jq -er '.release_sha256 | select(test("^[a-f0-9]{64}$"))' /etc/factory/config.json)"
service_user="factory-$role"

device=/dev/disk/by-id/google-factory-data
for _attempt in {1..60}; do
  [[ -b "$device" ]] && break
  sleep 1
done
[[ -b "$device" ]] || { echo 'Retained data disk is absent; refusing startup' >&2; exit 1; }
if ! blkid "$device" >/dev/null 2>&1; then
  [[ -z "$(wipefs --no-act --noheadings --output TYPE "$device")" ]] || exit 1
  [[ "$(lsblk -nr -o TYPE "$device")" = disk ]] || exit 1
  mkfs.ext4 -q -L factory-data "$device"
fi
[[ "$(blkid -s TYPE -o value "$device")" = ext4 ]] || { echo 'Unexpected retained filesystem; refusing format' >&2; exit 1; }
disk_uuid="$(blkid -s UUID -o value "$device")"
install -d -m 0755 /srv/factory
if ! rg_line="$(awk '$2 == "/srv/factory" {print $1}' /etc/fstab)" || [[ -z "$rg_line" ]]; then
  printf 'UUID=%s /srv/factory ext4 defaults 0 2\n' "$disk_uuid" >>/etc/fstab
else
  [[ "$rg_line" = "UUID=$disk_uuid" ]] || { echo 'Retained disk mount identity changed' >&2; exit 1; }
fi
mountpoint -q /srv/factory || mount /srv/factory
install -d -m 0755 /srv/factory/releases
[[ ! -d /opt/factory/releases || -L /opt/factory/releases ]] || rmdir /opt/factory/releases
ln -sfn /srv/factory/releases /opt/factory/releases

id "$service_user" >/dev/null 2>&1 || useradd --create-home \
  --home-dir "/srv/factory/homes/$service_user" --shell /bin/bash "$service_user"
install -d -m 0750 -o "$service_user" -g "$service_user" \
  /srv/factory/state /srv/factory/logs /srv/factory/runs /srv/factory/workspaces /srv/factory/tmp
install -d -m 0755 /srv/factory/tools /srv/factory/mise /srv/factory/mix /srv/factory/build
install -d -m 0750 -o root -g "$service_user" /run/factory
install -d -m 0700 -o "$service_user" -g "$service_user" "/srv/factory/homes/$service_user/.ssh"
# Keep the effective config available while a candidate is being validated.
# The activation command promotes the staged public config only on success.
if [[ ! -f /etc/factory/public.json && -f /srv/factory/active-public.json ]]; then
  install -m 0644 /srv/factory/active-public.json /etc/factory/public.json
fi
# Only IDs and deployment settings are public; tokens remain in /run.
jq 'del(.secret_ids, .secret_versions, .worker_ssh_public_key)' \
  /etc/factory/config.json >/etc/factory/public.pending.json
chmod 0644 /etc/factory/public.pending.json

# Install the inspected mise executable with a pinned upstream checksum.
mise_version=2026.10.6
mise_sha256=3f44343eebc7e0d6623bcea46e304864f02dff648edd75c82871b53cc697b366
if [[ ! -x /usr/local/bin/mise ]] || [[ "$(sha256sum /usr/local/bin/mise | cut -d ' ' -f1)" != "$mise_sha256" ]]; then
  curl --proto '=https' --tlsv1.2 -fsSL --retry 8 \
    "https://github.com/jdx/mise/releases/download/v$mise_version/mise-v$mise_version-linux-x64" \
    -o /usr/local/bin/mise.new
  printf '%s  /usr/local/bin/mise.new\n' "$mise_sha256" | sha256sum --check --status
  install -m 0755 /usr/local/bin/mise.new /usr/local/bin/mise
  rm /usr/local/bin/mise.new
fi
release="/opt/factory/releases/$revision"
if [[ ! -d "$release" ]]; then
  python3 /usr/local/lib/factory/cloud_io.py get-release "$release"
fi
[[ -f "$release/.verified-sha256" && "$(cat "$release/.verified-sha256")" = "$digest" ]] || \
  { echo 'Previously extracted release was not verified against this artifact' >&2; exit 1; }

# Build the pinned coordinator/worker runner outside immutable source. Worker
# executes the same two-stage runner over a coordinator-initiated private SSH.
export MISE_DATA_DIR=/srv/factory/mise
export MIX_HOME=/srv/factory/mix
export MIX_BUILD_PATH="/srv/factory/build/$revision"
export MIX_DEPS_PATH="$MIX_BUILD_PATH/deps"
mkdir -p "$MIX_BUILD_PATH"
cd "$release/elixir"
mise trust
tools_ready=false
for attempt in 1 2 3; do
  if mise --verbose install erlang@28.5 elixir@1.19.5-otp-28; then
    tools_ready=true
    break
  fi
  printf 'Runtime installer failed on attempt %s\n' "$attempt" >&2
  sleep "$((attempt * 5))"
done
[[ "$tools_ready" == true ]] || { echo 'Pinned runtime installation failed after retries' >&2; exit 1; }
mise exec -- mix local.hex --force
mise exec -- mix local.rebar --force
mise exec -- mix setup
mise exec -- mix build
chown -R "$service_user:$service_user" "$MIX_BUILD_PATH"
chmod -R a+rX /srv/factory/mise
chmod -R a+rX /srv/factory/mix
chmod -R a+rX "$release"

if [[ "$role" = worker ]]; then
  # Secret values are fetched only as root. Git's read-only credential is scoped
  # to this bootstrap invocation, then discarded before any agent starts.
  rm -f /run/factory/git-read
  python3 /usr/local/lib/factory/cloud_io.py secret git_read /run/factory/git-read
  codex_home="/srv/factory/homes/$service_user/.codex"
  [[ ! -L "$codex_home" ]] || { echo 'Codex home must not be a symlink' >&2; exit 1; }
  if [[ ! -e "$codex_home" ]]; then
    install -d -m 0700 -o "$service_user" -g "$service_user" "$codex_home"
  fi
  # The regular auth file lives on the retained worker disk. Preserve Codex's
  # refreshed tokens on reboot; a changed pinned secret version seeds rotation.
  python3 /usr/local/lib/factory/cloud_io.py model-auth
  # The qualified recipe installs tools and creates this seed once. Each smoke
  # task subsequently makes its own independent clone with publishing disabled.
  if [[ ! -d /srv/factory/seed ]]; then
    export CARGO_HOME=/srv/factory/tools/cargo
    export RUSTUP_HOME=/srv/factory/tools/rustup
    export RIG_TOOLS_DIR=/srv/factory/tools/rig-tools
    token="$(cat /run/factory/git-read)"
    basic="$(printf 'x-access-token:%s' "$token" | base64 -w0)"
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
    export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $basic"
    bash "$release/factory/scripts/bootstrap-linux.sh" /srv/factory/seed
    unset token basic GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
    git -C /srv/factory/seed remote set-url --push origin DISABLED
    chown -R "$service_user:$service_user" /srv/factory/tools
  fi
  # A run may edit its candidate clone, never the seed used by future runs.
  chown -R root:root /srv/factory/seed
  chmod -R a+rX /srv/factory/seed
  seed_pin="$(sed -n 's/^readonly RIG_COMMIT="\([a-f0-9]*\)"/\1/p' "$release/factory/scripts/bootstrap-linux.sh")"
  [[ "$seed_pin" =~ ^[a-f0-9]{40}$ && "$(git -C /srv/factory/seed rev-parse HEAD)" = "$seed_pin" ]] || \
    { echo 'Seed differs from the qualified Rig pin; operator migration required' >&2; exit 1; }
  printf '%s\n' "$seed_pin" >/srv/factory/seed.REVISION
  chmod 0644 /srv/factory/seed.REVISION
  git config --system --add safe.directory /srv/factory/seed
  rm -f /run/factory/git-read
  public_key="$(jq -er '.worker_ssh_public_key | select(startswith("ssh-ed25519 "))' /etc/factory/config.json)"
  printf 'restrict %s\n' "$public_key" >"/srv/factory/homes/$service_user/.ssh/authorized_keys"
  chmod 0600 "/srv/factory/homes/$service_user/.ssh/authorized_keys"
  chown "$service_user:$service_user" "/srv/factory/homes/$service_user/.ssh/authorized_keys"
  # Publish the worker host key through its scoped GCS identity, so the
  # coordinator pins it rather than accepting an unauthenticated ssh-keyscan.
  python3 /usr/local/lib/factory/cloud_io.py publish-hostkey
else
  rm -f /run/factory/id_ed25519
  python3 /usr/local/lib/factory/cloud_io.py secret worker_ssh /run/factory/id_ed25519
  chown "$service_user:$service_user" /run/factory/id_ed25519
  expected_public="$(jq -er '.worker_ssh_public_key' /etc/factory/config.json | awk '{print $1 " " $2}')"
  [[ "$(ssh-keygen -y -f /run/factory/id_ed25519 | awk '{print $1 " " $2}')" = "$expected_public" ]] || \
    { echo 'Worker SSH secret does not match the configured public key' >&2; exit 1; }
  for attempt in {1..60}; do
    if python3 /usr/local/lib/factory/cloud_io.py hostkeys; then break; fi
    [[ "$attempt" -lt 60 ]] || exit 1
    sleep 10
  done
  cat >/run/factory/ssh_config <<'EOF'
Host *
  User factory-worker
  IdentityFile /run/factory/id_ed25519
  UserKnownHostsFile /run/factory/known_hosts
  StrictHostKeyChecking yes
  BatchMode yes
  ConnectTimeout 10
  IdentitiesOnly yes
  ForwardAgent no
  ClearAllForwardings yes
EOF
  chmod 0640 /run/factory/ssh_config /run/factory/known_hosts
  chown root:"$service_user" /run/factory/ssh_config /run/factory/known_hosts
  install -m 0644 "$release/factory/deploy/factory-coordinator.service" \
    /etc/systemd/system/factory-coordinator.service
fi

install -m 0644 "$release/factory/deploy/factory-maintenance@.service" \
  /etc/systemd/system/factory-maintenance@.service
if [[ "$role" = coordinator ]]; then
  install -m 0644 "$release/factory/deploy/factory-backup.timer" /etc/systemd/system/
  install -m 0644 "$release/factory/deploy/factory-archive.timer" /etc/systemd/system/
  install -m 0644 "$release/factory/deploy/factory-health.timer" /etc/systemd/system/
fi
systemctl daemon-reload
bash "$release/factory/deploy/activate.sh" "$release"
if [[ "$role" = coordinator ]]; then
  systemctl enable --now factory-coordinator.service factory-backup.timer factory-archive.timer factory-health.timer
fi

# Official Ops Agent installer; install is pinned by recording the installed
# package version in live evidence. It has no application secrets in its config.
if ! dpkg-query -W google-cloud-ops-agent >/dev/null 2>&1; then
  curl -fsSL https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh \
    -o /run/factory/install-ops-agent.sh
  bash /run/factory/install-ops-agent.sh --also-install
  rm /run/factory/install-ops-agent.sh
fi
# User settings merge with built-ins; retain the default hostmetrics pipeline.
cat >/etc/google-cloud-ops-agent/config.yaml <<'EOF'
logging:
  receivers:
    factory-events:
      type: files
      include_paths: [/var/log/factory-events.log]
  service:
    pipelines:
      factory:
        receivers: [factory-events]
EOF
systemctl restart google-cloud-ops-agent
printf '%s FACTORY_EVENT startup_ready\n' "$(date -u +%FT%TZ)" >>/var/log/factory-events.log
