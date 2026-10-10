#!/usr/bin/env bash
# Run as root inside a disposable dev230-checked Linux container. The image
# provides the actual pinned Elixir/OTP runtime and compiled Symphony escript;
# the tiny mise front-end below only forwards `mise exec --` to that runtime.
set -Eeuo pipefail
umask 077

source_root="${FACTORY_TEST_SOURCE:-/factory-source/deploy}"
[[ "$EUID" -eq 0 && -d "$source_root" && -x /workspace/elixir/bin/symphony ]] || {
  echo 'Run inside the dev230-checked Linux image with the deploy source mounted read-only' >&2
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
mkdir -p /opt/factory /srv/factory/releases "$release/factory/deploy" \
  "$release/elixir/bin" /srv/factory/tmp /srv/factory/build \
  /srv/factory/homes/factory-coordinator /srv/factory/logs/coordinator
if ! id factory-coordinator >/dev/null 2>&1; then
  useradd --home-dir /srv/factory/homes/factory-coordinator --shell /bin/bash factory-coordinator
fi
chown -R factory-coordinator:factory-coordinator /srv/factory/homes/factory-coordinator \
  /srv/factory/tmp /srv/factory/logs/coordinator
chmod 0755 /opt/factory /srv/factory /srv/factory/releases /srv/factory/homes
chmod 0755 /srv/factory/logs /srv/factory/build
chmod 0750 /srv/factory/tmp /srv/factory/logs/coordinator

cp "$source_root/lib.sh" "$source_root/service.sh" "$source_root/PILOT-WORKFLOW.md" \
  "$release/factory/deploy/"
cp /workspace/elixir/bin/symphony "$release/elixir/bin/symphony"
chmod 0755 "$release/elixir/bin/symphony"
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
# this test-only shim checks the toolchain then executes the real escript.
cat >/usr/local/bin/mise <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == exec && "${2:-}" == -- ]] || exit 2
# The service starts without /usr/local/bin in PATH. mise owns selecting the
# installed runtime and adds its bin directory for the escript.
export PATH="/usr/local/bin:$PATH"
[[ "$(elixir --version | sed -n 's/^Elixir \([^ ]*\).*/\1/p')" == 1.19.5 ]]
[[ "$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>/dev/null)" == 28 ]]
shift 2
exec "$@"
SH
chmod 0755 /usr/local/bin/mise

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

printf 'PASS: readonly helper callers and coordinator service entrypoint on Elixir %s / OTP %s\n' \
  "$elixir_version" "$otp_version"
