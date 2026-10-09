#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

deploy_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=factory/deploy/lib.sh
source "$deploy_dir/lib.sh"

readonly factory_root="/opt/factory"
readonly data_root="/srv/factory"
release_dir="$(factory_active_release "$factory_root")" || exit 1
factory_load_runtime_env "$release_dir" coordinator || exit 1

[[ -x "$release_dir/elixir/bin/symphony" ]] || factory_fail "coordinator executable is missing" || exit 1
[[ -f "$release_dir/factory/deploy/PILOT-WORKFLOW.md" ]] || factory_fail "pilot workflow is missing" || exit 1

mkdir -p -- "$data_root/logs/coordinator"
exec "$release_dir/elixir/bin/symphony" \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$data_root/logs/coordinator" \
  --port 8080 \
  "$release_dir/factory/deploy/PILOT-WORKFLOW.md"
