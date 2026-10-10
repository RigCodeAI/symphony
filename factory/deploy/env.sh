#!/usr/bin/env bash

# Source from a release-pinned service or pilot script after setting
# FACTORY_RELEASE_DIR and FACTORY_ROLE.
factory_deploy_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=factory/deploy/lib.sh
source "$factory_deploy_dir/lib.sh"

factory_load_runtime_env "${FACTORY_RELEASE_DIR:?FACTORY_RELEASE_DIR is required}" \
  "${FACTORY_ROLE:?FACTORY_ROLE is required}"
