#!/usr/bin/env bash

factory_fail() {
  printf 'factory: %s\n' "$*" >&2
  return 1
}

factory_release_revision() {
  local release_dir="$1"
  python3 - "$release_dir/RELEASE.json" <<'PY'
import json
import re
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as source:
        value = json.load(source).get("service_revision")
except (OSError, ValueError, AttributeError):
    raise SystemExit("invalid RELEASE.json")
if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
    raise SystemExit("RELEASE.json has no valid service_revision")
print(value)
PY
}

factory_release_sha256() {
  local release_dir="$1" value
  [[ -f "$release_dir/.verified-sha256" && ! -L "$release_dir/.verified-sha256" ]] || {
    factory_fail "release SHA marker is missing"
    return 1
  }
  value="$(tr -d '[:space:]' <"$release_dir/.verified-sha256")" || return 1
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] || {
    factory_fail "release SHA marker is invalid"
    return 1
  }
  printf '%s\n' "$value"
}

factory_active_release() {
  local factory_root="$1" current releases resolved revision
  current="$factory_root/current"
  releases="$(realpath -e -- "$factory_root/releases")" || {
    factory_fail "release directory is missing"
    return 1
  }
  [[ -L "$current" ]] || {
    factory_fail "active release symlink is missing"
    return 1
  }
  resolved="$(realpath -e -- "$current")" || {
    factory_fail "active release symlink is broken"
    return 1
  }
  [[ "$resolved" == "$releases/"* && -d "$resolved" ]] || {
    factory_fail "active release is outside the releases directory"
    return 1
  }
  revision="$(factory_release_revision "$resolved")" || return 1
  [[ "$(basename -- "$resolved")" == "$revision" ]] || {
    factory_fail "active release directory does not match its revision"
    return 1
  }
  printf '%s\n' "$resolved"
}

factory_resolve_script() {
  local source="$1" dir target
  while [[ -L "$source" ]]; do
    dir="$(cd -P -- "$(dirname -- "$source")" >/dev/null 2>&1 && pwd)" || return 1
    target="$(readlink -- "$source")" || return 1
    if [[ "$target" == /* ]]; then
      source="$target"
    else
      source="$dir/$target"
    fi
  done
  realpath -e -- "$source"
}

factory_load_runtime_env() {
  local release_dir="$1" role="$2" revision sha node_bin codex_bin
  case "$role" in
    coordinator|worker) ;;
    *) factory_fail "unknown runtime role"; return 1 ;;
  esac
  revision="$(factory_release_revision "$release_dir")" || return 1
  sha="$(factory_release_sha256 "$release_dir")" || return 1
  [[ "$(basename -- "$release_dir")" == "$revision" ]] || {
    factory_fail "release directory does not match its revision"
    return 1
  }

  export FACTORY_ROLE="$role"
  export FACTORY_RELEASE_DIR="$release_dir"
  export FACTORY_SERVICE_REVISION="$revision"
  export FACTORY_RELEASE_SHA256="$sha"
  # These roots are deployment constants. A worker request cannot redirect the
  # pinned runner to another source tree by supplying shell environment values.
  export FACTORY_ROOT="/opt/factory"
  export FACTORY_DATA_ROOT="/srv/factory"
  export MISE_DATA_DIR="$FACTORY_DATA_ROOT/mise"
  export MISE_CACHE_DIR="$FACTORY_DATA_ROOT/homes/factory-$role/.cache/mise"
  export MISE_TRUSTED_CONFIG_PATHS="$release_dir/elixir"
  export CARGO_HOME="$FACTORY_DATA_ROOT/tools/cargo"
  export RUSTUP_HOME="$FACTORY_DATA_ROOT/tools/rustup"
  export RIG_TOOLS_DIR="$FACTORY_DATA_ROOT/tools/rig-tools"
  export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-3}"
  export TMPDIR="$FACTORY_DATA_ROOT/tmp"
  export MIX_BUILD_PATH="$FACTORY_DATA_ROOT/build/$revision"
  export MIX_DEPS_PATH="$FACTORY_DATA_ROOT/build/$revision/deps"

  node_bin="$RIG_TOOLS_DIR/node-v24.19.0-linux-x64/bin"
  if [[ -x "$RIG_TOOLS_DIR/node-v24.19.0-linux-arm64/bin/node" ]]; then
    node_bin="$RIG_TOOLS_DIR/node-v24.19.0-linux-arm64/bin"
  fi
  codex_bin="$RIG_TOOLS_DIR/codex/bin"
  export PATH="$CARGO_HOME/bin:$node_bin:$codex_bin:${PATH:-/usr/local/bin:/usr/bin:/bin}"

  [[ -d "$FACTORY_DATA_ROOT/homes/factory-$role" ]] || { factory_fail "service home is missing"; return 1; }
  [[ -d "$TMPDIR" ]] || { factory_fail "runtime temporary directory is missing"; return 1; }
  mkdir -p -- "$MISE_CACHE_DIR"
  return 0
}

factory_atomic_json() {
  local target="$1" content="$2" temp
  temp="${target}.tmp.$$"
  (umask 077; printf '%s\n' "$content" >"$temp") || return 1
  mv -f -- "$temp" "$target"
}
