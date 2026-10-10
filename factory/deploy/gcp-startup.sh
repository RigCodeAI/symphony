#!/usr/bin/env bash
# Runs as root on a Debian 12 VM. No values of secrets are logged or persisted
# in instance metadata, Terraform inputs, release archives or object backups.
set -Eeuo pipefail
umask 077
trap 'factory_startup_exit=$?; printf "%s FACTORY_EVENT startup_failed exit=%s line=%s\n" "$(date -u +%FT%TZ)" "$factory_startup_exit" "$LINENO" >>/var/log/factory-events.log' ERR

[[ "$EUID" -eq 0 ]] || { echo 'Startup requires root' >&2; exit 1; }
# The Compute startup unit omits a login environment. Re-enter as the actual
# root account so tools resolve its normal home rather than an unset HOME.
if [[ -z "${HOME:-}" ]]; then
  exec runuser --user root -- bash "$0" "$@"
fi

ensure_sshd_runtime_dir() {
  local runtime_dir=/run/sshd runtime_owner
  if [[ -L "$runtime_dir" || ( -e "$runtime_dir" && ! -d "$runtime_dir" ) ]]; then
    echo 'Unsafe sshd runtime directory' >&2
    return 1
  fi
  if [[ -e "$runtime_dir" && ! -O "$runtime_dir" ]]; then
    echo 'sshd runtime directory must be root-owned' >&2
    return 1
  fi
  install -d -m 0755 -o root -g root "$runtime_dir"
  runtime_owner="$(stat -c '%u:%g:%a' "$runtime_dir")"
  [[ -d "$runtime_dir" && ! -L "$runtime_dir" && "$runtime_owner" = '0:0:755' ]] || {
    echo 'sshd runtime directory has unsafe ownership or permissions' >&2
    return 1
  }
}

factory_assert_root_tree() {
  local factory_tree_path="$1" factory_tree_root factory_tree_entry
  local factory_tree_owner factory_tree_mode factory_tree_target
  [[ -d "$factory_tree_path" && ! -L "$factory_tree_path" ]] || {
    echo 'Protected runtime path must be a real directory' >&2
    return 1
  }
  factory_tree_root="$(realpath -e -- "$factory_tree_path")" || return 1
  while IFS= read -r -d '' factory_tree_entry; do
    factory_tree_owner="$(stat -c %u -- "$factory_tree_entry")" || return 1
    [[ "$factory_tree_owner" = 0 ]] || {
      echo 'Protected runtime tree contains a non-root-owned path' >&2
      return 1
    }
    if [[ -L "$factory_tree_entry" ]]; then
      factory_tree_target="$(realpath -e -- "$factory_tree_entry")" || {
        echo 'Protected runtime tree contains a broken symlink' >&2
        return 1
      }
      case "$factory_tree_target" in
        "$factory_tree_root"|"$factory_tree_root"/*|/usr/local/bin/mise) ;;
        *) echo 'Protected runtime tree contains an escaping symlink' >&2; return 1 ;;
      esac
      continue
    fi
    [[ -d "$factory_tree_entry" || -f "$factory_tree_entry" ]] || {
      echo 'Protected runtime tree contains a special file' >&2
      return 1
    }
    factory_tree_mode="$(stat -c %a -- "$factory_tree_entry")" || return 1
    [[ "$factory_tree_mode" =~ ^[0-7]{3,4}$ ]] && \
      (( (8#$factory_tree_mode & 0022) == 0 )) || {
        echo 'Protected runtime tree is group- or world-writable' >&2
        return 1
      }
  done < <(find -P "$factory_tree_root" -print0)
}

factory_assert_root_directory() {
  local factory_dir_path="$1" factory_dir_owner factory_dir_mode
  [[ -d "$factory_dir_path" && ! -L "$factory_dir_path" ]] || {
    echo 'Protected runtime path must be a real directory' >&2
    return 1
  }
  factory_dir_owner="$(stat -c %u -- "$factory_dir_path")" || return 1
  factory_dir_mode="$(stat -c %a -- "$factory_dir_path")" || return 1
  [[ "$factory_dir_owner" = 0 && "$factory_dir_mode" =~ ^[0-7]{3,4}$ ]] && \
    (( (8#$factory_dir_mode & 0022) == 0 )) || {
      echo 'Protected runtime directory has unsafe ownership or mode' >&2
      return 1
    }
}

factory_ensure_root_directory() {
  local factory_dir_path="$1" factory_dir_mode="$2" factory_dir_parent
  [[ "$factory_dir_path" = /* && "$factory_dir_path" != / ]] || {
    echo 'Protected runtime path must be absolute' >&2
    return 1
  }
  if [[ ! -e "$factory_dir_path" && ! -L "$factory_dir_path" ]]; then
    factory_dir_parent="$(dirname -- "$factory_dir_path")"
    factory_assert_root_directory "$factory_dir_parent" || return 1
    install -d -m "$factory_dir_mode" -o root -g root "$factory_dir_path"
  fi
  factory_assert_root_directory "$factory_dir_path"
}

factory_git_read() {
  local factory_git_token factory_git_basic
  factory_git_token="$(cat /run/factory/git-read)"
  factory_git_basic="$(printf 'x-access-token:%s' "$factory_git_token" | base64 -w0)"
  (
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
    export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $factory_git_basic"
    "$@"
  )
  unset factory_git_token factory_git_basic
}

factory_write_worker_authorized_keys() {
  local factory_keys_user="$1" factory_keys_home="$2" factory_keys_public="$3"
  [[ "$factory_keys_user" = factory-worker && \
     "$factory_keys_home" = /srv/factory/homes/factory-worker && \
     "$factory_keys_public" =~ ^ssh-ed25519[[:space:]][A-Za-z0-9+/]+={0,2}$ ]] || {
    echo 'Worker SSH key inputs are invalid' >&2
    return 1
  }
  /usr/sbin/runuser --user "$factory_keys_user" -- \
    /usr/bin/env -i \
      HOME="$factory_keys_home" USER="$factory_keys_user" LOGNAME="$factory_keys_user" PATH=/usr/bin:/bin \
      /bin/bash -euo pipefail -c '
        worker_home="$1"
        public_key="$2"
        [[ "$EUID" -ne 0 && "$HOME" = "$worker_home" && -d "$worker_home" && ! -L "$worker_home" && -O "$worker_home" ]] || exit 1
        ssh_dir="$worker_home/.ssh"
        if [[ -e "$ssh_dir" || -L "$ssh_dir" ]]; then
          [[ -d "$ssh_dir" && ! -L "$ssh_dir" && -O "$ssh_dir" ]] || {
            echo "Unsafe worker SSH directory" >&2
            exit 1
          }
        else
          mkdir -m 0700 -- "$ssh_dir"
        fi
        chmod 0700 -- "$ssh_dir"
        authorized_keys="$ssh_dir/authorized_keys"
        if [[ -e "$authorized_keys" || -L "$authorized_keys" ]]; then
          [[ -f "$authorized_keys" && ! -L "$authorized_keys" && -O "$authorized_keys" ]] || {
            echo "Unsafe worker authorized_keys path" >&2
            exit 1
          }
        fi
        temp_file="$(mktemp "$ssh_dir/.authorized_keys.XXXXXXXX")"
        printf "restrict %s\\n" "$public_key" >"$temp_file"
        chmod 0600 -- "$temp_file"
        mv -fT -- "$temp_file" "$authorized_keys"
      ' factory-write-worker-authorized-keys "$factory_keys_home" "$factory_keys_public"
}

factory_ensure_worker_codex_home() {
  local factory_codex_user="$1" factory_codex_home="$2"
  [[ "$factory_codex_user" = factory-worker && \
     "$factory_codex_home" = /srv/factory/homes/factory-worker ]] || {
    echo 'Worker Codex home inputs are invalid' >&2
    return 1
  }
  /usr/sbin/runuser --user "$factory_codex_user" -- \
    /usr/bin/env -i \
      HOME="$factory_codex_home" USER="$factory_codex_user" LOGNAME="$factory_codex_user" PATH=/usr/bin:/bin \
      /bin/bash -euo pipefail -c '
        worker_home="$1"
        codex_home="$worker_home/.codex"
        [[ "$EUID" -ne 0 && "$HOME" = "$worker_home" && -d "$worker_home" && ! -L "$worker_home" && -O "$worker_home" ]] || exit 1
        if [[ -e "$codex_home" || -L "$codex_home" ]]; then
          [[ -d "$codex_home" && ! -L "$codex_home" && -O "$codex_home" ]] || {
            echo "Unsafe worker Codex home" >&2
            exit 1
          }
        else
          mkdir -m 0700 -- "$codex_home"
        fi
        chmod 0700 -- "$codex_home"
      ' factory-ensure-worker-codex-home "$factory_codex_home"
}

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
factory_assert_root_directory /srv
factory_assert_root_directory /srv/factory
factory_ensure_root_directory /srv/factory/releases 0755
[[ ! -d /opt/factory/releases || -L /opt/factory/releases ]] || rmdir /opt/factory/releases
ln -sfn /srv/factory/releases /opt/factory/releases

id "$service_user" >/dev/null 2>&1 || useradd --create-home \
  --home-dir "/srv/factory/homes/$service_user" --shell /bin/bash "$service_user"
install -d -m 0750 -o "$service_user" -g "$service_user" \
  /srv/factory/state /srv/factory/logs /srv/factory/runs /srv/factory/workspaces /srv/factory/tmp
factory_ensure_root_directory /srv/factory/build 0755
factory_ensure_root_directory /srv/factory/mise 0755
factory_ensure_root_directory /srv/factory/mise-root-cache 0700
factory_ensure_root_directory /root/.config 0700
factory_ensure_root_directory /root/.config/mise 0700
factory_assert_root_directory /usr
factory_assert_root_directory /usr/local
factory_assert_root_directory /usr/local/bin
install -d -m 0750 -o root -g "$service_user" /run/factory
if [[ "$role" = worker ]]; then
  worker_host_key_dir=/srv/factory/ssh-host-keys
  worker_host_key_private="$worker_host_key_dir/ssh_host_ed25519_key"
  worker_host_public_key="$(python3 /usr/local/lib/factory/cloud_io.py ensure-hostkey)"
  [[ "$worker_host_public_key" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+={0,2}$ ]] || \
    { echo 'Durable worker host public key is invalid' >&2; exit 1; }
  # Hold worker sshd behind the retained disk on future VM boots. On a fresh
  # deployment this is installed after the disk is already mounted.
  ssh_mount_dropin_dir=/etc/systemd/system/ssh.service.d
  ssh_mount_dropin="$ssh_mount_dropin_dir/10-factory-retained-disk.conf"
  [[ ! -L "$ssh_mount_dropin_dir" ]] || { echo 'Unsafe SSH unit drop-in directory' >&2; exit 1; }
  install -d -m 0755 "$ssh_mount_dropin_dir"
  [[ ! -L "$ssh_mount_dropin" && ( ! -e "$ssh_mount_dropin" || ( -f "$ssh_mount_dropin" && -O "$ssh_mount_dropin" ) ) ]] || \
    { echo 'Unsafe SSH unit drop-in file' >&2; exit 1; }
  ssh_mount_dropin_tmp="$(mktemp "$ssh_mount_dropin_dir/.factory-retained-disk.XXXXXX")"
  cat >"$ssh_mount_dropin_tmp" <<'EOF'
[Unit]
RequiresMountsFor=/srv/factory
ConditionPathIsMountPoint=/srv/factory
EOF
  chmod 0644 "$ssh_mount_dropin_tmp"
  chown root:root "$ssh_mount_dropin_tmp"
  mv -f -- "$ssh_mount_dropin_tmp" "$ssh_mount_dropin"
  systemctl stop ssh.service >/dev/null 2>&1 || true
  ensure_sshd_runtime_dir

  sshd_dropin_dir=/etc/ssh/sshd_config.d
  sshd_dropin="$sshd_dropin_dir/00-factory-worker-hostkey.conf"
  [[ ! -L "$sshd_dropin_dir" ]] || { echo 'Unsafe sshd drop-in directory' >&2; exit 1; }
  install -d -m 0755 "$sshd_dropin_dir"
  [[ ! -L "$sshd_dropin" && ( ! -e "$sshd_dropin" || ( -f "$sshd_dropin" && -O "$sshd_dropin" ) ) ]] || \
    { echo 'Unsafe sshd host-key drop-in' >&2; exit 1; }
  sshd_dropin_tmp="$(mktemp "$sshd_dropin_dir/.factory-hostkey.XXXXXX")"
  printf 'HostKey %s\n' "$worker_host_key_private" >"$sshd_dropin_tmp"
  chmod 0644 "$sshd_dropin_tmp"
  chown root:root "$sshd_dropin_tmp"
  mv -f -- "$sshd_dropin_tmp" "$sshd_dropin"

  systemctl daemon-reload
  sshd -t
  effective_hostkeys="$(sshd -T | awk '$1 == "hostkey" { print $2 }')"
  [[ "$effective_hostkeys" = "$worker_host_key_private" ]] || \
    { echo 'sshd is not configured with only the retained worker host key' >&2; exit 1; }
  systemctl enable ssh.service
  systemctl reload-or-restart ssh.service
fi
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

# Root may install the pinned runtime only from verified, root-owned source and
# data. Mix itself runs below as the service account with an empty environment.
factory_assert_root_tree "$release"
factory_assert_root_tree /srv/factory/mise
factory_assert_root_tree /srv/factory/mise-root-cache
factory_assert_root_tree /root/.config/mise
factory_assert_root_directory /usr
factory_assert_root_directory /usr/local
factory_assert_root_directory /usr/local/bin
mise_mode="$(stat -c %a /usr/local/bin/mise)"
[[ -f /usr/local/bin/mise && ! -L /usr/local/bin/mise && \
   "$(stat -c %u /usr/local/bin/mise)" = 0 && \
   "$mise_mode" =~ ^[0-7]{3,4}$ && \
   "$(sha256sum /usr/local/bin/mise | cut -d ' ' -f1)" = "$mise_sha256" ]] && \
  (( (8#$mise_mode & 0022) == 0 )) || {
  echo 'Pinned mise executable is not a protected root-owned file' >&2
  exit 1
}
factory_root_mise() {
  /usr/bin/env -i \
    HOME=/root USER=root LOGNAME=root PATH=/usr/local/bin:/usr/bin:/bin \
    MISE_DATA_DIR=/srv/factory/mise \
    MISE_CACHE_DIR=/srv/factory/mise-root-cache \
    MISE_CONFIG_DIR=/root/.config/mise \
    MISE_TRUSTED_CONFIG_PATHS="$release/elixir" \
    /bin/bash -c 'cd -- "$1"; shift; exec /usr/local/bin/mise "$@"' \
    _ "$release/elixir" "$@"
}
tools_ready=false
for attempt in 1 2 3; do
  if factory_root_mise --verbose install erlang@28.5 elixir@1.19.5-otp-28; then
    tools_ready=true
    break
  fi
  printf 'Runtime installer failed on attempt %s\n' "$attempt" >&2
  sleep "$((attempt * 5))"
done
[[ "$tools_ready" == true ]] || { echo 'Pinned runtime installation failed after retries' >&2; exit 1; }
chmod -R a+rX,go-w /srv/factory/mise
factory_assert_root_tree /srv/factory/mise
chmod -R a+rX,go-w "$release"
factory_assert_root_tree "$release"
bash "$release/factory/deploy/build.sh" "$release" "$role"

if [[ "$role" = worker ]]; then
  # Secret values are fetched only as root. Git's read-only credential is scoped
  # to this bootstrap invocation, then discarded before any agent starts.
  rm -f /run/factory/git-read
  python3 /usr/local/lib/factory/cloud_io.py secret git_read /run/factory/git-read
  codex_home="/srv/factory/homes/$service_user/.codex"
  factory_ensure_worker_codex_home "$service_user" "/srv/factory/homes/$service_user"
  # The regular auth file lives on the retained worker disk. Preserve Codex's
  # refreshed tokens on reboot; a changed pinned secret version seeds rotation.
  python3 /usr/local/lib/factory/cloud_io.py model-auth
  seed_pin="$(sed -n 's/^readonly RIG_COMMIT="\([a-f0-9]*\)"/\1/p' "$release/factory/scripts/bootstrap-linux.sh")"
  seed_repo="$(sed -n 's/^readonly RIG_REPOSITORY="\([^"]*\)"/\1/p' "$release/factory/scripts/bootstrap-linux.sh")"
  [[ "$seed_pin" =~ ^[a-f0-9]{40}$ && "$seed_repo" = https://github.com/RigCodeAI/rig.git ]] || \
    { echo 'Pinned Rig seed definition is invalid' >&2; exit 1; }
  if [[ -e /srv/factory/seed || -L /srv/factory/seed ]]; then
    factory_assert_root_tree /srv/factory/seed
    [[ "$(git -C /srv/factory/seed rev-parse HEAD)" = "$seed_pin" ]] || \
      { echo 'Seed differs from the qualified Rig pin; operator migration required' >&2; exit 1; }
  fi

  bootstrap_root=/srv/factory/bootstrap-tools-v1
  bootstrap_marker="$bootstrap_root/.factory-ready"
  if [[ -f "$bootstrap_marker" && ! -L "$bootstrap_marker" ]]; then
    [[ "$(stat -c '%u:%a' "$bootstrap_marker")" = '0:644' && \
       "$(cat "$bootstrap_marker")" = "bootstrap-tools-v1 $seed_pin" ]] || \
      { echo 'Protected tool namespace marker is invalid' >&2; exit 1; }
    factory_assert_root_tree "$bootstrap_root"
  else
    [[ ! -e "$bootstrap_root" && ! -L "$bootstrap_root" ]] || \
      { echo 'Incomplete protected tool namespace requires operator cleanup' >&2; exit 1; }
    factory_ensure_root_directory "$bootstrap_root" 0700
    install -d -m 0700 -o root -g root \
      "$bootstrap_root/cargo" "$bootstrap_root/rustup" \
      "$bootstrap_root/rig-tools" "$bootstrap_root/tmp"
    factory_assert_root_tree "$bootstrap_root"
    bootstrap_seed="$bootstrap_root/tmp/rig-seed"
    (
      /usr/bin/env -i \
        HOME=/root USER=root LOGNAME=root PATH=/usr/local/bin:/usr/bin:/bin \
        TMPDIR="$bootstrap_root/tmp" \
        CARGO_HOME="$bootstrap_root/cargo" \
        RUSTUP_HOME="$bootstrap_root/rustup" \
        RIG_TOOLS_DIR="$bootstrap_root/rig-tools" \
        /bin/bash -c '
          token="$(cat /run/factory/git-read)"
          basic="$(printf "x-access-token:%s" "$token" | base64 -w0)"
          export GIT_CONFIG_COUNT=1
          export GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
          export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $basic"
          unset token basic
          exec /bin/bash "$1" "$2"
        ' factory-bootstrap "$release/factory/scripts/bootstrap-linux.sh" "$bootstrap_seed"
    )
    [[ -d "$bootstrap_seed" && ! -L "$bootstrap_seed" && \
       "$(git -C "$bootstrap_seed" rev-parse HEAD)" = "$seed_pin" ]] || \
      { echo 'Bootstrap did not produce the pinned Rig seed' >&2; exit 1; }
    if [[ -e /srv/factory/seed || -L /srv/factory/seed ]]; then
      rm -rf -- "$bootstrap_seed"
    else
      mv -- "$bootstrap_seed" /srv/factory/seed
      git -C /srv/factory/seed remote set-url --push origin DISABLED
    fi
    rm -rf -- "$bootstrap_root/tmp"
    chown --no-dereference -R root:root "$bootstrap_root"
    chmod -R a+rX,go-w "$bootstrap_root"
    factory_assert_root_tree "$bootstrap_root"
    printf 'bootstrap-tools-v1 %s\n' "$seed_pin" >"$bootstrap_root/.factory-ready"
    chown root:root "$bootstrap_root/.factory-ready"
    chmod 0644 "$bootstrap_root/.factory-ready"
    factory_assert_root_tree "$bootstrap_root"
  fi

  if [[ ! -d /srv/factory/seed ]]; then
    factory_ensure_root_directory "$bootstrap_root/tmp" 0700
    bootstrap_seed="$bootstrap_root/tmp/rig-seed"
    factory_git_read git clone --depth=1 --no-checkout --branch main --single-branch \
      "$seed_repo" "$bootstrap_seed"
    if ! git -C "$bootstrap_seed" cat-file -e "${seed_pin}^{commit}" 2>/dev/null; then
      factory_git_read git -C "$bootstrap_seed" fetch --depth=1 origin "$seed_pin"
    fi
    git -C "$bootstrap_seed" checkout --detach "$seed_pin"
    [[ "$(git -C "$bootstrap_seed" rev-parse HEAD)" = "$seed_pin" ]] || \
      { echo 'Fetched Rig seed does not match the pinned revision' >&2; exit 1; }
    mv -- "$bootstrap_seed" /srv/factory/seed
    git -C /srv/factory/seed remote set-url --push origin DISABLED
    rm -rf -- "$bootstrap_root/tmp"
  fi
  factory_assert_root_tree /srv/factory/seed
  [[ "$(git -C /srv/factory/seed rev-parse HEAD)" = "$seed_pin" ]] || \
    { echo 'Seed differs from the qualified Rig pin; operator migration required' >&2; exit 1; }
  git -C /srv/factory/seed remote set-url --push origin DISABLED
  chmod -R a+rX,go-w /srv/factory/seed
  factory_assert_root_tree /srv/factory/seed
  [[ ! -L /srv/factory/seed.REVISION && \
     ( ! -e /srv/factory/seed.REVISION || ( -f /srv/factory/seed.REVISION && "$(stat -c %u /srv/factory/seed.REVISION)" = 0 ) ) ]] || \
    { echo 'Seed revision marker is unsafe' >&2; exit 1; }
  printf '%s\n' "$seed_pin" >/srv/factory/seed.REVISION
  chmod 0644 /srv/factory/seed.REVISION
  # This file contains the public, exact-path seed exception. Git ignores an
  # unreadable system config, so do not leave it private under bootstrap umask.
  git config --system --replace-all safe.directory /srv/factory/seed
  # upload-pack opens the metadata directory during a --no-local clone.
  git config --system --add safe.directory /srv/factory/seed/.git
  chmod 0644 /etc/gitconfig
  rm -f /run/factory/git-read
  public_key="$(jq -er '.worker_ssh_public_key | select(startswith("ssh-ed25519 "))' /etc/factory/config.json | awk 'NR == 1 {print $1 " " $2}')"
  factory_write_worker_authorized_keys "$service_user" \
    "/srv/factory/homes/$service_user" "$public_key"
  # The durable HostKey is now active. This public line is an authenticated
  # serial-console receipt so an operator can replace a stale immutable pin.
  printf 'FACTORY_WORKER_HOSTKEY %s\n' "$worker_host_public_key"
  # Publish the same normalized public key through the scoped GCS identity.
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
