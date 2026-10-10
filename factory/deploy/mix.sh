#!/usr/bin/env bash
# Executable entrypoint for callers such as timeout that cannot run functions.
set -Eeuo pipefail
script_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=factory/deploy/lib.sh
source "$script_dir/lib.sh"
factory_mix "$@"
