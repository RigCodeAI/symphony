#!/usr/bin/env bash
# Run as root inside a disposable dev230-checked Linux container. The image
# provides the actual pinned Elixir/OTP runtime and dependency cache; the tiny
# mise front-end below only forwards `mise exec --` to that runtime.
set -Eeuo pipefail
umask 077

source_root="${FACTORY_TEST_SOURCE:-/factory-source/deploy}"
source_repo="$(cd -P -- "$source_root/../.." >/dev/null 2>&1 && pwd)"
[[ "$EUID" -eq 0 && -d "$source_root" && -f "$source_repo/elixir/mix.exs" && -d /workspace/elixir/deps ]] || {
  echo 'Run inside the dev230-checked Linux image with the repository mounted read-only' >&2
  exit 2
}

elixir_version="$(elixir --version | sed -n 's/^Elixir \([^ ]*\).*/\1/p')"
otp_version="$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>/dev/null)"
[[ "$elixir_version" == 1.19.5 && "$otp_version" == 28 ]] || {
  echo "unexpected test runtime: Elixir ${elixir_version:-missing}, OTP ${otp_version:-missing}" >&2
  exit 1
}

revision=dddddddddddddddddddddddddddddddddddddddd
release="/srv/factory/releases/$revision"
build_dir="/srv/factory/build/$revision"
mkdir -p /opt/factory /srv/factory/releases "$release/factory/deploy" \
  "$release/elixir" /srv/factory/tmp "$build_dir" \
  /srv/factory/homes/factory-coordinator /srv/factory/logs/coordinator
if ! id factory-coordinator >/dev/null 2>&1; then
  useradd --home-dir /srv/factory/homes/factory-coordinator --shell /bin/bash factory-coordinator
fi
chown -R factory-coordinator:factory-coordinator /srv/factory/homes/factory-coordinator \
  /srv/factory/tmp /srv/factory/logs/coordinator
chmod 0755 /opt/factory /srv/factory /srv/factory/releases /srv/factory/homes
chmod 0755 /srv/factory/logs /srv/factory/build
chmod 0750 /srv/factory/tmp /srv/factory/logs/coordinator

cp "$source_root/lib.sh" "$source_root/service.sh" "$source_root/build.sh" \
  "$source_root/coordinator_entrypoint.py" "$source_root/PILOT-WORKFLOW.md" \
  "$release/factory/deploy/"
cp -R "$source_repo/elixir/." "$release/elixir/"
# Seed the isolated candidate build with the pinned image's cached dependencies
# and compile outputs, then build the mounted candidate source normally.
cp -R /workspace/elixir/deps "$build_dir/deps"
cp -R /workspace/elixir/_build/dev "$build_dir/dev"
printf '{"service_revision":"%s"}\n' "$revision" >"$release/RELEASE.json"
printf '%064d\n' 0 >"$release/.verified-sha256"
chmod -R a+rX "$release"
ln -s /srv/factory/releases /opt/factory/releases
ln -s "$release" /opt/factory/current

# This regression reproduces the service's readonly globals before starting
# the actual entrypoint; helpers must not declare locals with those names.
# shellcheck source=factory/deploy/lib.sh
source "$release/factory/deploy/lib.sh"
readonly factory_root=/opt/factory
[[ "$(factory_active_release "$factory_root")" == "$release" ]]
readonly release_dir="$release"
[[ "$(factory_release_revision "$release_dir")" == "$revision" ]]
[[ "$(factory_release_sha256 "$release_dir")" == "$(printf '%064d' 0)" ]]
factory_load_runtime_env "$release_dir" coordinator
chown -R factory-coordinator:factory-coordinator /srv/factory/homes/factory-coordinator/.cache

# dev230-checked has the exact pinned Erlang/Elixir runtime installed globally;
# this test-only shim checks the toolchain then forwards the real Mix commands.
cat >/usr/local/bin/mise <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == exec && "${2:-}" == -- ]] || exit 2
# The service starts without /usr/local/bin in PATH. mise owns selecting the
# installed runtime and adds its bin directory for Mix.
export PATH="/usr/local/bin:$PATH"
[[ "$(elixir --version | sed -n 's/^Elixir \([^ ]*\).*/\1/p')" == 1.19.5 ]]
[[ "$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>/dev/null)" == 28 ]]
shift 2
exec "$@"
SH
chmod 0755 /usr/local/bin/mise

chown -R factory-coordinator:factory-coordinator "$build_dir"
"$release/factory/deploy/build.sh" "$release" coordinator

service_log=/tmp/factory-service-entrypoint.log
if runuser --user factory-coordinator -- env PATH=/usr/bin:/bin \
  /usr/bin/env escript --version >/dev/null 2>&1; then
  echo 'test PATH unexpectedly exposes escript before mise selects the runtime' >&2
  exit 1
fi
runuser --user factory-coordinator -- env PATH=/usr/bin:/bin \
  /bin/bash "$release/factory/deploy/service.sh" \
  >"$service_log" 2>&1 &
service_pid=$!
cleanup() {
  kill -TERM "$service_pid" 2>/dev/null || true
  for _ in {1..20}; do
    kill -0 "$service_pid" 2>/dev/null || break
    sleep 0.25
  done
  kill -KILL "$service_pid" 2>/dev/null || true
  wait "$service_pid" 2>/dev/null || true
}
trap cleanup EXIT

healthy=false
for _ in {1..80}; do
  if ! kill -0 "$service_pid" 2>/dev/null; then
    cat "$service_log" >&2
    echo 'service entrypoint exited before health became ready' >&2
    exit 1
  fi
  if curl --fail --silent --show-error http://127.0.0.1:8080/api/v1/state >/dev/null 2>&1; then
    healthy=true
    break
  fi
  sleep 0.25
done
[[ "$healthy" == true ]] || {
  cat "$service_log" >&2
  echo 'service entrypoint did not serve the local health endpoint' >&2
  exit 1
}

cleanup
install -d -m 0755 /etc/factory /etc/factory/workflows
install -d -m 0750 -o root -g factory-coordinator /run/factory /run/factory/coordinator
cat >"/etc/factory/workflows/$revision.md" <<'EOF'
---
tracker:
  kind: memory
server:
  host: 0.0.0.0
  port: 8080
  webhook_host: 0.0.0.0
  webhook_port: 8081
linear_delegation:
  organization_id: org-smoke
  team_id: team-smoke
  app_user_id: app-smoke
  oauth_client_id: client-smoke
  webhook_secret_env: LINEAR_API_TOKEN
  token_env: LINEAR_API_KEY
  store_path: /srv/factory/state/service-entrypoint.sqlite
  workspace_root: /srv/factory/workspaces
  workstream_path: /srv/factory/workstreams/software-change.yaml
  agent_id: factory-default
  rig_label: rig
  workspaces:
    issue-smoke: /srv/factory/workspaces/issue-smoke
---
Controlled memory-tracker startup test; no dispatch events are sent.
EOF
chmod 0644 "/etc/factory/workflows/$revision.md"
install -d -m 0750 -o factory-coordinator -g factory-coordinator \
  /srv/factory/state /srv/factory/workspaces/issue-smoke
python3 - "$revision" <<'PY'
import json
from pathlib import Path
import os
import pwd
import sys
revision = sys.argv[1]
mapping = {"LINEAR_API_KEY": "linear_api", "LINEAR_API_TOKEN": "linear_signing"}
versions = {"LINEAR_API_KEY": "1", "LINEAR_API_TOKEN": "2"}
fingerprints = {name: "a" * 64 for name in mapping}
Path('/etc/factory/public.json').write_text(json.dumps({"service_revision": revision, "coordinator_workflow": "linear", "coordinator_secret_env": mapping, "coordinator_secret_versions": versions, "coordinator_secret_fingerprints": fingerprints, "enable_linear_webhook": True}))
path = Path('/run/factory/coordinator') / (revision + '.json')
path.write_text(json.dumps({"service_revision": revision, "workflow": "linear", "environment": {name: "controlled-value" for name in mapping}, "secret_versions": versions, "secret_fingerprints": fingerprints, "enable_linear_webhook": True}))
os.chown(path, 0, pwd.getpwnam('factory-coordinator').pw_gid)
path.chmod(0o640)
PY
chmod 0644 /etc/factory/public.json
runuser --user factory-coordinator -- env PATH=/usr/bin:/bin \
  /bin/bash "$release/factory/deploy/service.sh" >"$service_log" 2>&1 &
service_pid=$!
healthy=false
for _ in {1..80}; do
  if ! kill -0 "$service_pid" 2>/dev/null; then
    cat "$service_log" >&2
    exit 1
  fi
  if curl --fail --silent http://127.0.0.1:8080/api/v1/state >/dev/null && \
     [[ "$(curl --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1:8081/api/v1/state)" == 404 ]]; then
    healthy=true
    break
  fi
  sleep 0.25
done
[[ "$healthy" == true ]] || { cat "$service_log" >&2; exit 1; }
python3 - <<'PY'
from pathlib import Path

path = Path('/srv/factory/state/service-entrypoint.sqlite')
if not path.is_file() or not path.read_bytes().startswith(b'SQLite format 3\0'):
    raise SystemExit('durable-workstream SQLite database was not opened by the service')
PY
[[ "$(curl --silent --output /dev/null --write-out '%{http_code}' -X POST http://127.0.0.1:8081/hooks/linear)" == 400 ]]

printf 'PASS: Mix service entrypoint started durable-workstream SQLite and isolated webhook listener on Elixir %s / OTP %s\n' \
  "$elixir_version" "$otp_version"
