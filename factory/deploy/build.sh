#!/usr/bin/env bash
# Build a release with service-owned Mix state. The root branch only validates
# fixed paths and drops privileges; all Mix code runs in --as-service mode.
set -Eeuo pipefail
umask 077

factory_build_fail() {
  printf 'factory build: %s\n' "$*"
  exit 1
}

factory_build_revision() {
  python3 - "$1/RELEASE.json" <<'PY'
import json
import re
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as source:
        revision = json.load(source).get("service_revision")
except (OSError, ValueError, AttributeError):
    raise SystemExit("invalid release marker")
if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
    raise SystemExit("invalid release revision")
print(revision)
PY
}

factory_build_mode_is_private() {
  local factory_build_mode="$1"
  [[ "$factory_build_mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$factory_build_mode & 0022) == 0 ))
}

factory_build_mix() {
  /usr/local/bin/mise exec -- /usr/bin/env \
    MIX_HOME="$factory_build_home/.mix" \
    MIX_ARCHIVES="$factory_build_home/.mix/archives" \
    MIX_ESCRIPTS="$factory_build_home/.mix/escripts" \
    mix "$@"
}

if [[ "${1:-}" == --as-service ]]; then
  [[ "$#" -eq 6 ]] || factory_build_fail "invalid service invocation"
  factory_build_release="$2"
  factory_build_role="$3"
  factory_build_revision="$4"
  factory_build_uid="$5"
  factory_build_gid="$6"

  case "$factory_build_role" in
    coordinator|worker) ;;
    *) factory_build_fail "unknown service role" ;;
  esac
  [[ "$factory_build_revision" =~ ^[0-9a-f]{40}$ ]] || factory_build_fail "invalid revision"
  [[ "$factory_build_uid" =~ ^[0-9]+$ && "$factory_build_gid" =~ ^[0-9]+$ ]] || \
    factory_build_fail "invalid service identity"
  [[ "$factory_build_uid" -gt 0 ]] || factory_build_fail "Mix must not run as root"
  [[ "$EUID" -eq "$factory_build_uid" ]] || factory_build_fail "Mix must run as the service user"

  factory_build_home="/srv/factory/homes/factory-$factory_build_role"
  factory_build_dir="/srv/factory/build/$factory_build_revision"
  factory_build_project="$factory_build_dir/project"
  [[ "${HOME:-}" == "$factory_build_home" ]] || factory_build_fail "unexpected service home"
  [[ "${MISE_DATA_DIR:-}" == /srv/factory/mise ]] || factory_build_fail "unexpected mise data path"
  [[ "${MIX_HOME:-}" == "$factory_build_home/.mix" ]] || factory_build_fail "unexpected Mix home"
  [[ "${MIX_BUILD_PATH:-}" == "$factory_build_dir" ]] || factory_build_fail "unexpected Mix build path"
  [[ "${MIX_DEPS_PATH:-}" == "$factory_build_dir/deps" ]] || factory_build_fail "unexpected Mix dependency path"
  [[ "${MISE_TRUSTED_CONFIG_PATHS:-}" == "$factory_build_project" ]] || \
    factory_build_fail "unexpected trusted project path"
  [[ -d "$factory_build_release/elixir" && ! -L "$factory_build_release/elixir" ]] || \
    factory_build_fail "release source is unavailable"

  # Recreate the project copy as the service user. Mix's configured escript
  # path is project-relative, so building the immutable release directly would
  # write bin/symphony into the root-owned release tree.
  if [[ -e "$factory_build_project" || -L "$factory_build_project" ]]; then
    rm -rf -- "$factory_build_project"
  fi
  install -d -m 0700 "$factory_build_project"
  cp -R -- "$factory_build_release/elixir/." "$factory_build_project/"
  install -d -m 0700 \
    "$factory_build_home/.mix" \
    "$factory_build_home/.mix/archives" \
    "$factory_build_home/.mix/escripts" \
    "$factory_build_home/.cache/mise" \
    "$factory_build_home/.config/mise"
  cd -- "$factory_build_project"

  factory_build_mix local.hex --force
  factory_build_mix local.rebar --force
  factory_build_mix setup
  factory_build_mix build
  [[ -x "$factory_build_project/bin/symphony" ]] || \
    factory_build_fail "Mix build did not produce the release executable"
  exit 0
fi

[[ "$EUID" -eq 0 ]] || factory_build_fail "root is required to launch a service build"
[[ "$#" -eq 2 ]] || factory_build_fail "usage: build.sh <release-dir> <worker|coordinator>"
factory_build_input="$1"
factory_build_role="$2"
case "$factory_build_role" in
  coordinator|worker) ;;
  *) factory_build_fail "unknown service role" ;;
esac

factory_build_release="$(realpath -e -- "$factory_build_input")" || \
  factory_build_fail "release directory is missing"
factory_build_revision="$(factory_build_revision "$factory_build_release")"
[[ "$factory_build_release" == "/srv/factory/releases/$factory_build_revision" ]] || \
  factory_build_fail "release is outside the pinned releases directory"
[[ -f "$factory_build_release/.verified-sha256" && ! -L "$factory_build_release/.verified-sha256" ]] || \
  factory_build_fail "release SHA marker is missing"
factory_build_sha="$(tr -d '[:space:]' <"$factory_build_release/.verified-sha256")"
[[ "$factory_build_sha" =~ ^[0-9a-f]{64}$ ]] || factory_build_fail "release SHA marker is invalid"
factory_build_script="$(realpath -e -- "$0")"
[[ "$factory_build_script" == "$factory_build_release/factory/deploy/build.sh" ]] || \
  factory_build_fail "build script is not part of the selected release"
[[ ! -L "$factory_build_release" && -d "$factory_build_release" ]] || \
  factory_build_fail "release directory is unsafe"

factory_build_user="factory-$factory_build_role"
factory_build_uid="$(id -u "$factory_build_user")" || factory_build_fail "service account is missing"
factory_build_gid="$(id -g "$factory_build_user")" || factory_build_fail "service group is missing"
factory_build_home="$(getent passwd "$factory_build_user" | cut -d: -f6)"
[[ "$factory_build_home" == "/srv/factory/homes/$factory_build_user" && -d "$factory_build_home" && ! -L "$factory_build_home" ]] || \
  factory_build_fail "service home is missing or unsafe"
[[ "$(stat -c %u "$factory_build_home")" == "$factory_build_uid" ]] || \
  factory_build_fail "service home has the wrong owner"

factory_build_parent=/srv/factory/build
[[ -d "$factory_build_parent" && ! -L "$factory_build_parent" ]] || \
  factory_build_fail "build parent is missing or unsafe"
[[ "$(stat -c %u "$factory_build_parent")" == 0 ]] || \
  factory_build_fail "build parent must be root-owned"
factory_build_parent_mode="$(stat -c %a "$factory_build_parent")"
factory_build_mode_is_private "$factory_build_parent_mode" || \
  factory_build_fail "build parent must not be group- or world-writable"

factory_build_dir="$factory_build_parent/$factory_build_revision"
if [[ ! -e "$factory_build_dir" && ! -L "$factory_build_dir" ]]; then
  install -d -m 0700 -o "$factory_build_uid" -g "$factory_build_gid" "$factory_build_dir"
fi
[[ -d "$factory_build_dir" && ! -L "$factory_build_dir" ]] || \
  factory_build_fail "build directory is not a regular directory"
[[ "$(stat -c %u "$factory_build_dir")" == "$factory_build_uid" && \
   "$(stat -c %g "$factory_build_dir")" == "$factory_build_gid" ]] || \
  factory_build_fail "build directory is not owned by the service account"
factory_build_mode="$(stat -c %a "$factory_build_dir")"
factory_build_mode_is_private "$factory_build_mode" || \
  factory_build_fail "build directory must not be group- or world-writable"

exec /usr/sbin/runuser --user "$factory_build_user" -- \
  /usr/bin/env -i \
  HOME="$factory_build_home" USER="$factory_build_user" LOGNAME="$factory_build_user" \
  PATH=/usr/local/bin:/usr/bin:/bin \
  MISE_DATA_DIR=/srv/factory/mise \
  MISE_CACHE_DIR="$factory_build_home/.cache/mise" \
  MISE_CONFIG_DIR="$factory_build_home/.config/mise" \
  MISE_TRUSTED_CONFIG_PATHS="$factory_build_dir/project" \
  MIX_HOME="$factory_build_home/.mix" \
  MIX_BUILD_PATH="$factory_build_dir" \
  MIX_DEPS_PATH="$factory_build_dir/deps" \
  /bin/bash "$factory_build_script" --as-service \
  "$factory_build_release" "$factory_build_role" "$factory_build_revision" \
  "$factory_build_uid" "$factory_build_gid"
