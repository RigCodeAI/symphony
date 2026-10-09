#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
  printf 'Usage: sudo %s /opt/factory/releases/<40-character-revision>\n' "${0##*/}" >&2
}

fail() {
  printf 'activation failed: %s\n' "$*" >&2
  exit 1
}

[[ "$EUID" -eq 0 ]] || fail "must run as root"
[[ "$#" -eq 1 ]] || { usage; exit 2; }

script_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=factory/deploy/lib.sh
source "$script_dir/lib.sh"

readonly factory_root="/opt/factory"
readonly config_file="/etc/factory/public.json"
readonly pending_config="/etc/factory/public.pending.json"
readonly data_root="/srv/factory"
readonly service_name="factory-coordinator.service"
readonly health_url="http://127.0.0.1:8080/api/v1/state"
readonly health_attempts=30
readonly candidate_input="$1"

desired_config="$config_file"
if [[ -e "$pending_config" || -L "$pending_config" ]]; then
  [[ -f "$pending_config" && ! -L "$pending_config" ]] || fail "pending public config must be a regular file"
  desired_config="$pending_config"
fi
[[ -f "$desired_config" && ! -L "$desired_config" ]] || fail "public config is missing"
[[ -O "$desired_config" && "$(stat -c %a -- "$desired_config")" == 644 ]] || \
  fail "selected public config must be root-owned mode 0644"
[[ -d "$factory_root/releases" ]] || fail "release directory is missing"

candidate="$(realpath -e -- "$candidate_input")" || fail "candidate release does not exist"
[[ -d "$candidate" && ! -L "$candidate_input" ]] || fail "candidate must be a real directory"
releases_real="$(realpath -e -- "$factory_root/releases")" || fail "release directory cannot be resolved"
case "$candidate" in
  "$releases_real/"*) ;;
  *) fail "candidate must be inside $factory_root/releases" ;;
esac

revision="$(factory_release_revision "$candidate")" || fail "candidate release manifest is invalid"
[[ "$(basename -- "$candidate")" == "$revision" ]] || fail "candidate directory does not match its manifest revision"
candidate_sha="$(factory_release_sha256 "$candidate")" || fail "candidate SHA marker is invalid"
config_release="$(python3 - "$desired_config" <<'PY'
import json
import re
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as source:
        config = json.load(source)
except (OSError, ValueError, AttributeError):
    raise SystemExit("invalid public config")
value = config.get("release_sha256")
revision = config.get("service_revision")
if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
    raise SystemExit("public config has no valid release_sha256")
if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
    raise SystemExit("public config has no valid service_revision")
print(revision, value)
PY
)" || fail "public release identity is invalid"
read -r expected_revision expected_sha <<<"$config_release"
role="$(python3 - "$desired_config" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as source:
        value = json.load(source).get("role")
except (OSError, ValueError, AttributeError):
    raise SystemExit("invalid public config")
if value not in {"coordinator", "worker"}:
    raise SystemExit("public config has an invalid role")
print(value)
PY
)" || fail "public role is invalid"
validation_user="factory-$role"
[[ "$revision" == "$expected_revision" ]] || fail "candidate revision does not match public config"
[[ "$candidate_sha" == "$expected_sha" ]] || fail "candidate SHA does not match public config"

for required in \
  "$candidate/factory/workstreams/local-rig.yaml" \
  "$candidate/factory/examples/pass.json" \
  "$candidate/factory/examples/fail.json" \
  "$candidate/elixir/mix.exs" \
  "$candidate/factory/deploy/PILOT-WORKFLOW.md"; do
  [[ -f "$required" && ! -L "$required" ]] || fail "candidate is missing a required file"
done

validate_with_mise() {
  local input="$1"
  runuser --user "$validation_user" -- env \
    PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}" \
    FACTORY_RELEASE_DIR="$candidate" \
    FACTORY_ROLE="$role" \
    FACTORY_DATA_ROOT="$data_root" \
    bash -Eeuo pipefail -c '
      source "$FACTORY_RELEASE_DIR/factory/deploy/env.sh"
      cd -- "$FACTORY_RELEASE_DIR/elixir"
      mise exec -- mix workstream.run \
        ../factory/workstreams/local-rig.yaml \
        --inputs "../factory/examples/$1.json" \
        --validate-only
    ' -- "$input"
}

printf 'Validating the pass definition...\n'
validate_with_mise pass || fail "pass workstream validation failed"
printf 'Validating the fail definition...\n'
validate_with_mise fail || fail "fail workstream validation failed"

old_link="$factory_root/current"
had_old=false
old_target=""
if [[ -L "$old_link" ]]; then
  old_target="$(realpath -e -- "$old_link")" || fail "existing active release link is broken"
  [[ "$old_target" == "$releases_real/"* ]] || fail "existing active release is outside releases"
  had_old=true
elif [[ -e "$old_link" ]]; then
  fail "current must be a symlink"
fi

active_file="$data_root/active.json"
last_error="$data_root/last-error.json"
active_public="$data_root/active-public.json"
mkdir -p -- "$data_root"
old_active=""
old_active_exists=false
[[ ! -L "$active_file" ]] || fail "active metadata must not be a symlink"
if [[ -f "$active_file" && ! -L "$active_file" ]]; then
  old_active="$(cat -- "$active_file")"
  old_active_exists=true
fi

[[ ! -L "$active_public" ]] || fail "effective public config snapshot must not be a symlink"
[[ ! -e "$config_file" || ( -f "$config_file" && ! -L "$config_file" ) ]] || \
  fail "effective public config must be a regular file"
if [[ -f "$config_file" ]]; then
  [[ -O "$config_file" && "$(stat -c %a -- "$config_file")" == 644 ]] || \
    fail "effective public config must be root-owned mode 0644"
fi
if [[ -f "$active_public" ]]; then
  [[ -O "$active_public" && "$(stat -c %a -- "$active_public")" == 644 ]] || \
    fail "effective public config snapshot must be root-owned mode 0644"
fi

public_backup="$data_root/.public-backup.$$"
active_public_backup="$data_root/.active-public-backup.$$"
pending_backup="$data_root/.pending-public-backup.$$"
public_existed=false
active_public_existed=false
had_pending=false
if [[ -f "$config_file" ]]; then
  install -m 0600 -- "$config_file" "$public_backup"
  public_existed=true
fi
if [[ -f "$active_public" ]]; then
  install -m 0600 -- "$active_public" "$active_public_backup"
  active_public_existed=true
fi
if [[ "$desired_config" == "$pending_config" ]]; then
  install -m 0600 -- "$pending_config" "$pending_backup"
  had_pending=true
fi

atomic_link() {
  local destination="$1" link="$2" temp="$factory_root/.current.$$"
  rm -f -- "$temp"
  ln -s -- "$destination" "$temp"
  mv -Tf -- "$temp" "$link"
}

atomic_copy() {
  local source="$1" target="$2" mode="$3" temporary="${2}.tmp.$$"
  install -m "$mode" -- "$source" "$temporary" || return 1
  mv -Tf -- "$temporary" "$target"
}

publish_effective_config() {
  if [[ "$had_pending" == true ]]; then
    mv -Tf -- "$pending_config" "$config_file" || return 1
  fi
  atomic_copy "$config_file" "$active_public" 0644
}

restore_effective_config() {
  if [[ "$public_existed" == true ]]; then
    atomic_copy "$public_backup" "$config_file" 0644 || return 1
  elif [[ "$active_public_existed" == true ]]; then
    atomic_copy "$active_public_backup" "$config_file" 0644 || return 1
  else
    rm -f -- "$config_file"
  fi

  if [[ "$active_public_existed" == true ]]; then
    atomic_copy "$active_public_backup" "$active_public" 0644 || return 1
  else
    rm -f -- "$active_public"
  fi

  if [[ "$had_pending" == true ]]; then
    atomic_copy "$pending_backup" "$pending_config" 0644 || return 1
  fi
}

discard_config_backups() {
  rm -f -- "$public_backup" "$active_public_backup" "$pending_backup"
}

health_check() {
  local attempt
  for ((attempt = 1; attempt <= health_attempts; attempt++)); do
    if curl --connect-timeout 2 --max-time 4 --fail --silent "$health_url" >/dev/null 2>&1; then
      return 0
    fi
    if ((attempt < health_attempts)); then
      sleep 1
    fi
  done
  return 1
}

write_active() {
  python3 - "$revision" "$candidate_sha" "$data_root/active.json" <<'PY'
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

target = sys.argv[3]
payload = {
    "service_revision": sys.argv[1],
    "release_sha256": sys.argv[2],
    "activated_at": datetime.now(timezone.utc).isoformat(),
}
fd, temporary = tempfile.mkstemp(prefix="active.", dir=os.path.dirname(target))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        json.dump(payload, out, sort_keys=True)
        out.write("\n")
    os.chmod(temporary, 0o644)
    os.replace(temporary, target)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

write_error() {
  local reason="$1"
  python3 - "$revision" "$candidate_sha" "$reason" "$data_root/last-error.json" <<'PY'
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

target = sys.argv[4]
payload = {
    "service_revision": sys.argv[1],
    "release_sha256": sys.argv[2],
    "reason": sys.argv[3],
    "failed_at": datetime.now(timezone.utc).isoformat(),
}
fd, temporary = tempfile.mkstemp(prefix="last-error.", dir=os.path.dirname(target))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        json.dump(payload, out, sort_keys=True)
        out.write("\n")
    os.chmod(temporary, 0o644)
    os.replace(temporary, target)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

if [[ "$had_old" == true && "$old_target" == "$candidate" ]]; then
  if [[ "$role" == coordinator ]]; then
    systemctl restart "$service_name" || fail "active coordinator service could not be restarted"
    health_check || fail "active coordinator service health check failed"
  fi
  if ! publish_effective_config || ! write_active; then
    restore_effective_config || true
    if [[ "$old_active_exists" == true ]]; then
      factory_atomic_json "$active_file" "$old_active" || true
    else
      rm -f -- "$active_file"
    fi
    discard_config_backups
    fail "could not commit active deployment metadata"
  fi
  discard_config_backups
  rm -f -- "$last_error"
  printf 'Revision %s is already active and verified.\n' "$revision"
  exit 0
fi

atomic_link "$candidate" "$old_link"

if [[ "$role" == worker ]]; then
  if ! publish_effective_config || ! write_active; then
    activation_error="could not commit worker deployment metadata"
    if [[ "$had_old" == true ]]; then
      atomic_link "$old_target" "$old_link"
    else
      rm -f -- "$old_link"
    fi
    restore_effective_config || true
    if [[ "$old_active_exists" == true ]]; then
      factory_atomic_json "$active_file" "$old_active" || true
    else
      rm -f -- "$active_file"
    fi
    write_error "$activation_error" || true
    discard_config_backups
    fail "$activation_error; current release restored"
  fi
  discard_config_backups
  rm -f -- "$last_error"
  printf 'Activated worker revision %s. No worker task was restarted.\n' "$revision"
  exit 0
fi

activation_error=""
if ! systemctl restart "$service_name"; then
  activation_error="service restart failed"
elif ! health_check; then
  activation_error="post-activation health check failed"
else
  if publish_effective_config && write_active; then
    discard_config_backups
    rm -f -- "$last_error"
    printf 'Activated and verified revision %s.\n' "$revision"
    exit 0
  fi
  activation_error="could not commit active deployment metadata"
fi

printf 'Rolling back to the previous release after %s.\n' "$activation_error" >&2
if [[ "$had_old" == true ]]; then
  atomic_link "$old_target" "$old_link"
else
  rm -f -- "$old_link"
fi

if [[ "$old_active_exists" == true ]]; then
  factory_atomic_json "$active_file" "$old_active" || true
else
  rm -f -- "$active_file"
fi

restore_effective_config || activation_error="$activation_error; effective public config rollback failed"

if ! systemctl restart "$service_name"; then
  activation_error="$activation_error; previous service restart failed"
elif [[ "$had_old" == true ]] && ! health_check; then
  activation_error="$activation_error; previous service health check failed"
fi
write_error "$activation_error" || true
discard_config_backups
fail "$activation_error; current release restored"
