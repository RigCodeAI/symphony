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

runner_path="$MIX_BUILD_PATH/project/bin/symphony"
[[ -x "$runner_path" ]] || factory_fail "coordinator executable is missing" || exit 1
[[ -f "$MIX_BUILD_PATH/project/mix.exs" ]] || factory_fail "coordinator Mix project is missing" || exit 1
[[ -f "$release_dir/factory/deploy/PILOT-WORKFLOW.md" ]] || factory_fail "pilot workflow is missing" || exit 1
[[ -x /usr/local/bin/mise ]] || factory_fail "pinned mise runtime manager is missing" || exit 1

mkdir -p -- "$data_root/logs/coordinator"
cd -- "$MIX_BUILD_PATH/project"
export MISE_TRUSTED_CONFIG_PATHS="$MIX_BUILD_PATH/project"
# Exqlite loads its SQLite NIF from the dependency's physical priv directory.
# The escript bundles BEAM files but not that directory, so run the built Mix
# project while keeping the CLI's normal workflow and startup path.
exec /usr/bin/python3 -I "$release_dir/factory/deploy/coordinator_entrypoint.py" \
  "$release_dir" /usr/local/bin/mise exec -- /usr/bin/env \
  MIX_HOME="$MIX_HOME" MIX_ARCHIVES="$MIX_HOME/archives" MIX_ESCRIPTS="$MIX_HOME/escripts" \
  mix run --no-start --no-compile --no-deps-check \
  -e 'SymphonyElixir.CLI.main(System.argv())' -- \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$data_root/logs/coordinator"
