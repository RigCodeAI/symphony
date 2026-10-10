#!/usr/bin/env bash
# Run as root in a disposable Linux container with openssh-server installed.
# This executes the runtime-directory helper extracted from production startup,
# then validates and starts sshd with a temporary retained-key fixture.
set -Eeuo pipefail
umask 077

source_root="${FACTORY_TEST_SOURCE:-/workspace/factory/deploy}"
[[ "$EUID" -eq 0 && -f /.dockerenv && -f "$source_root/gcp-startup.sh" ]] || {
  echo 'Run as root in a disposable Docker container with the deploy source mounted read-only' >&2
  exit 2
}
command -v sshd >/dev/null || { echo 'openssh-server is required in the test container' >&2; exit 2; }
command -v ssh-keyscan >/dev/null || { echo 'openssh-client is required in the test container' >&2; exit 2; }
sshd_binary="$(command -v sshd)"
[[ "$sshd_binary" = /* ]] || { echo 'sshd binary path is not absolute' >&2; exit 2; }

temporary="$(mktemp -d /tmp/factory-hostkey-sshd.XXXXXX)"
server_pid=
had_runtime_dir=false
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf /run/sshd
  if [[ "$had_runtime_dir" = true && -d "$temporary/original-run-sshd" ]]; then
    mv "$temporary/original-run-sshd" /run/sshd
  fi
  rm -rf "$temporary"
}
trap cleanup EXIT

if [[ -L /run/sshd || ( -e /run/sshd && ! -d /run/sshd ) ]]; then
  echo 'unexpected initial /run/sshd path in test container' >&2
  exit 1
fi
if [[ -d /run/sshd ]]; then
  mv /run/sshd "$temporary/original-run-sshd"
  had_runtime_dir=true
fi

host_key="$temporary/retained_ed25519"
ssh-keygen -q -t ed25519 -N '' -C fixture -f "$host_key"
config="$temporary/sshd_config"
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
cat >"$config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $host_key
PidFile $temporary/sshd.pid
UsePAM no
PasswordAuthentication no
PermitRootLogin no
EOF
chmod 0600 "$config"

sed -n '/^ensure_sshd_runtime_dir() {$/,/^}$/p' "$source_root/gcp-startup.sh" \
  >"$temporary/runtime-helper.sh"
[[ -s "$temporary/runtime-helper.sh" ]] || {
  echo 'could not extract production runtime-directory helper' >&2
  exit 1
}
# shellcheck source=factory/deploy/gcp-startup.sh
source "$temporary/runtime-helper.sh"

if "$sshd_binary" -t -f "$config" >"$temporary/sshd-before.out" 2>"$temporary/sshd-before.err"; then
  echo 'sshd unexpectedly validated after /run/sshd was removed' >&2
  exit 1
fi
grep -q 'Missing privilege separation directory: /run/sshd' "$temporary/sshd-before.err"

mkdir "$temporary/symlink-target"
ln -s "$temporary/symlink-target" /run/sshd
if (ensure_sshd_runtime_dir) >"$temporary/unsafe-symlink.log" 2>&1; then
  echo 'runtime helper accepted a symlink' >&2
  exit 1
fi
[[ -L /run/sshd && -d "$temporary/symlink-target" ]]
rm /run/sshd

printf 'unsafe fixture\n' >/run/sshd
if (ensure_sshd_runtime_dir) >"$temporary/unsafe-file.log" 2>&1; then
  echo 'runtime helper accepted a non-directory path' >&2
  exit 1
fi
[[ -f /run/sshd ]]
rm /run/sshd

ensure_sshd_runtime_dir
[[ "$(stat -c '%u:%g:%a' /run/sshd)" = '0:0:755' ]]
"$sshd_binary" -t -f "$config"
effective_hostkeys="$("$sshd_binary" -T -f "$config" | awk '$1 == "hostkey" { print $2 }')"
[[ "$effective_hostkeys" = "$host_key" ]]

"$sshd_binary" -D -f "$config" -E "$temporary/sshd.log" &
server_pid=$!
for _attempt in {1..40}; do
  if ssh-keyscan -T 1 -p "$port" -t ed25519 127.0.0.1 \
    >"$temporary/observed-hostkey" 2>/dev/null && [[ -s "$temporary/observed-hostkey" ]]; then
    break
  fi
  sleep 0.1
done
[[ -s "$temporary/observed-hostkey" ]] || {
  echo 'local sshd did not present its configured host key' >&2
  exit 1
}
expected_public="$(awk '{print $1 " " $2}' "$host_key.pub")"
observed_public="$(awk '$2 == "ssh-ed25519" {print $2 " " $3}' "$temporary/observed-hostkey")"
[[ "$observed_public" = "$expected_public" ]] || {
  echo 'local sshd presented a key other than the retained fixture key' >&2
  exit 1
}

printf 'PASS: missing /run/sshd reproduced; production helper rejected unsafe paths, restored root:root 0755, and sshd -t/-T plus live host-key comparison passed\n'
