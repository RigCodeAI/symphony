#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# These pins are the inspected DEV-229 baseline. Node follows Rig's qualification
# CI; Codex CLI follows the version in Rig's review-feedback workflow. Update
# them only after checking Rig main and recording the replacement revision.
readonly RIG_REPOSITORY="https://github.com/RigCodeAI/rig.git"
readonly RIG_COMMIT="39d6d5d998366bf13af19eb74ae47d598ecf92bd"
readonly NODE_VERSION="24.19.0"
readonly CODEX_VERSION="0.159.2"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: bootstrap-linux.sh /absolute/path/to/new-rig-workspace

Prepares a Debian or Ubuntu Linux user for the DEV-229 local Rig smoke task,
then clones and verifies the pinned Rig main revision into a new workspace.
The destination must not already exist. This script does not sign in, start an
agent, build, test, publish, or create cloud resources.
EOF
}

run_as_root() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

if [[ "$#" -ne 1 ]]; then
  usage
  exit 2
fi

workspace_path="$1"
[[ "$workspace_path" = /* ]] || fail "the Rig workspace path must be absolute"
[[ ! -e "$workspace_path" && ! -L "$workspace_path" ]] || fail "the Rig workspace path already exists"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
symphony_root="$(realpath -e -- "$script_dir/../..")"
workspace_path="$(realpath -m -- "$workspace_path")"
case "$workspace_path" in
  "$symphony_root"|"$symphony_root"/*)
    fail "the Rig workspace must be outside the Symphony source checkout"
    ;;
esac

workspace_parent="$(dirname -- "$workspace_path")"
nearest_existing="$workspace_parent"
while [[ ! -d "$nearest_existing" ]]; do
  nearest_existing="$(dirname -- "$nearest_existing")"
done
if git -C "$nearest_existing" rev-parse --show-toplevel >/dev/null 2>&1; then
  fail "choose a new workspace outside any existing Git checkout"
fi

tools_root_arg="${RIG_TOOLS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/rig-tools}"
tools_root="$(realpath -m -- "$tools_root_arg")"
case "$tools_root" in
  "$symphony_root"|"$symphony_root"/*|"$workspace_path"|"$workspace_path"/*)
    fail "RIG_TOOLS_DIR must be outside the Symphony and Rig checkouts"
    ;;
esac
nearest_existing="$tools_root"
while [[ ! -d "$nearest_existing" ]]; do
  nearest_existing="$(dirname -- "$nearest_existing")"
done
if git -C "$nearest_existing" rev-parse --show-toplevel >/dev/null 2>&1; then
  fail "RIG_TOOLS_DIR must be outside existing Git checkouts"
fi

if [[ -n "${OPENAI_API_KEY:-}" || -n "${CODEX_API_KEY:-}" || -n "${CODEX_ACCESS_TOKEN:-}" ]]; then
  fail "API key or access-token environment credentials are set; this pilot requires ChatGPT subscription sign-in"
fi

[[ -r /etc/os-release ]] || fail "cannot identify the Linux distribution"
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-} ${ID_LIKE:-}" in
  *debian*|*ubuntu*) ;;
  *) fail "this bootstrap supports Debian or Ubuntu only" ;;
esac
command -v apt-get >/dev/null 2>&1 || fail "apt-get is required"

mkdir -p -- "$workspace_parent"
run_as_root apt-get update
run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential \
  ca-certificates \
  curl \
  git \
  python3 \
  python3-venv \
  time \
  xz-utils

git clone --depth=1 --no-checkout --branch main --single-branch "$RIG_REPOSITORY" "$workspace_path"
if ! git -C "$workspace_path" cat-file -e "${RIG_COMMIT}^{commit}" 2>/dev/null; then
  git -C "$workspace_path" fetch --depth=1 origin "$RIG_COMMIT"
fi
git -C "$workspace_path" checkout --detach "$RIG_COMMIT"
actual_commit="$(git -C "$workspace_path" rev-parse HEAD)"
[[ "$actual_commit" = "$RIG_COMMIT" ]] || fail "Rig checkout did not resolve to the reviewed pin"

rust_toolchain="$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$workspace_path/rust-toolchain.toml")"
[[ "$rust_toolchain" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Rig rust-toolchain.toml must pin a stable Rust release"

export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
export PATH="$CARGO_HOME/bin:$PATH"

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/rig-dev229-bootstrap.XXXXXX")"
trap 'rm -rf -- "$temporary_dir"' EXIT

if ! command -v rustup >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o "$temporary_dir/rustup-init.sh"
  sh "$temporary_dir/rustup-init.sh" -y --profile minimal --default-toolchain none
  export PATH="$CARGO_HOME/bin:$PATH"
fi

command -v rustup >/dev/null 2>&1 || fail "rustup installation did not provide the rustup command"
rust_components=(--profile minimal)
component_line="$(sed -n 's/^[[:space:]]*components[[:space:]]*=[[:space:]]*\[\(.*\)\].*/\1/p' "$workspace_path/rust-toolchain.toml")"
component_line="${component_line//\"/}"
IFS=',' read -r -a component_names <<< "$component_line"
for component_name in "${component_names[@]}"; do
  component_name="${component_name//[[:space:]]/}"
  [[ -n "$component_name" ]] && rust_components+=(--component "$component_name")
done
rustup toolchain install "$rust_toolchain" "${rust_components[@]}"

mkdir -p -- "$tools_root"
case "$(uname -m)" in
  x86_64) node_arch="x64" ;;
  aarch64) node_arch="arm64" ;;
  *) fail "unsupported Linux architecture: $(uname -m)" ;;
esac

node_archive="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"
node_install="${tools_root}/node-v${NODE_VERSION}-linux-${node_arch}"
node_binary="$node_install/bin/node"
if [[ ! -x "$node_binary" ]]; then
  [[ ! -e "$node_install" ]] || fail "partial Node installation exists at $node_install; remove it or choose another RIG_TOOLS_DIR"
  curl --proto '=https' --tlsv1.2 -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${node_archive}" -o "$temporary_dir/$node_archive"
  curl --proto '=https' --tlsv1.2 -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o "$temporary_dir/SHASUMS256.txt"
  awk -v archive="$node_archive" '$2 == archive { print; count++ } END { if (count != 1) exit 1 }' \
    "$temporary_dir/SHASUMS256.txt" >"$temporary_dir/node-checksum.txt" || fail "Node checksum entry is missing or ambiguous"
  (cd "$temporary_dir" && sha256sum --check node-checksum.txt)
  tar -xJf "$temporary_dir/$node_archive" -C "$temporary_dir"
  mv -- "$temporary_dir/node-v${NODE_VERSION}-linux-${node_arch}" "$node_install"
fi
[[ "$("$node_binary" --version)" = "v$NODE_VERSION" ]] || fail "Node version mismatch at $node_binary"
export PATH="$node_install/bin:$PATH"

codex_prefix="$tools_root/codex"
codex_binary="$codex_prefix/bin/codex"
if [[ ! -x "$codex_binary" ]] || ! "$codex_binary" --version 2>&1 | grep -Fq "$CODEX_VERSION"; then
  mkdir -p -- "$codex_prefix"
  : >"$temporary_dir/npmrc"
  npm_config_cache="$temporary_dir/npm-cache" \
    "$node_install/bin/npm" install --global --prefix "$codex_prefix" \
      --cache "$temporary_dir/npm-cache" --userconfig "$temporary_dir/npmrc" \
      --no-audit --no-fund --loglevel=error \
      "@openai/codex@$CODEX_VERSION"
fi
codex_version_text="$("$codex_binary" --version 2>&1)" || fail "Codex CLI did not start"
[[ "$codex_version_text" = *"$CODEX_VERSION"* ]] || fail "Codex CLI version mismatch: $codex_version_text"

printf 'Rig workspace: %s\n' "$workspace_path"
printf 'Rig commit: %s\n' "$actual_commit"
printf 'Rust: %s\n' "$(rustup run "$rust_toolchain" rustc --version)"
printf 'Cargo: %s\n' "$(rustup run "$rust_toolchain" cargo --version)"
printf 'Python: %s\n' "$(python3 --version 2>&1)"
printf 'Node: %s\n' "$("$node_binary" --version)"
printf 'Codex CLI: %s\n' "$codex_version_text"
printf '\nNext: add these tool directories to PATH, then run `codex login` and choose Sign in with ChatGPT.\n'
printf 'Verify the selected method with `codex login status`; it must report ChatGPT.\n'
printf 'Tool PATH entries for a later shell:\nexport PATH=%q:%q:%q:"$PATH"\n' \
  "$CARGO_HOME/bin" "$node_install/bin" "$codex_prefix/bin"
