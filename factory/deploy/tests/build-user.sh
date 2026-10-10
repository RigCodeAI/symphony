#!/usr/bin/env bash
# Run in a disposable dev230-checked Linux container with factory mounted at
# /factory-source:ro. It uses real Symphony source, pinned runtime and Mix.
# Credentials and cloud access are not required.
set -Eeuo pipefail
umask 077
[[ "$EUID" = 0 && -f /.dockerenv && -d /workspace/elixir/deps && -f /factory-source/deploy/build.sh ]] || {
  echo "Run in dev230-checked with factory mounted at /factory-source:ro" >&2
  exit 2
}
revision=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
release=/srv/factory/releases/$revision
mkdir -p "$release/elixir" "$release/factory/deploy" /srv/factory/homes /srv/factory/build /srv/factory/mise /srv/factory/tmp
chmod 0755 /srv /srv/factory /srv/factory/releases /srv/factory/homes /srv/factory/build
useradd --home-dir /srv/factory/homes/factory-worker --create-home --shell /bin/bash factory-worker
install -d -m 0700 -o factory-worker -g factory-worker "/srv/factory/build/$revision" "/srv/factory/homes/factory-worker/.mix"
tar -C /workspace/elixir --exclude=./_build --exclude=./deps --exclude=./bin -cf - . | tar -C "$release/elixir" -xf -
cp /factory-source/deploy/build.sh "$release/factory/deploy/build.sh"
printf '{"service_revision":"%s"}\n' "$revision" >"$release/RELEASE.json"
printf '%064d\n' 0 >"$release/.verified-sha256"
chmod -R a+rX,go-w "$release"
cp -R /workspace/elixir/deps "/srv/factory/build/$revision/deps"
cp -R /root/.mix/. /srv/factory/homes/factory-worker/.mix/
chown -R factory-worker:factory-worker "/srv/factory/build/$revision" /srv/factory/homes/factory-worker/.mix
cat >/usr/local/bin/mise <<'MISE'
#!/usr/bin/env bash
# Run in a disposable dev230-checked Linux container with factory mounted at
# /factory-source:ro. It uses real Symphony source, pinned runtime and Mix.
# Credentials and cloud access are not required.
set -Eeuo pipefail
[[ "$1" = exec && "$2" = -- ]]
[[ "$EUID" = "$(id -u factory-worker)" && "$EUID" != 0 ]]
[[ -z "${OPENAI_API_KEY:-}${GIT_CONFIG_VALUE_0:-}${NODE_OPTIONS:-}" ]]
shift 2
# Match the actual mise Elixir backend's injected root runtime cache paths.
export MIX_HOME=/srv/factory/mise/runtime-mix MIX_ARCHIVES=/srv/factory/mise/runtime-mix/archives
exec "$@"
MISE
chmod 0755 /usr/local/bin/mise
export OPENAI_API_KEY=harmless-regression-value GIT_CONFIG_VALUE_0=harmless-regression-value NODE_OPTIONS=harmless-regression-value
bash "$release/factory/deploy/build.sh" "$release" worker
[[ -x "/srv/factory/build/$revision/project/bin/symphony" && ! -e "$release/elixir/bin/symphony" ]]
runuser --user factory-worker -- python3 - "/srv/factory/build/$revision/deps/jason/mix.exs" <<'PY'
from pathlib import Path
import sys
with Path(sys.argv[1]).open('a') as target:
    target.write('\n{uid, 0} = System.cmd("/usr/bin/id", ["-u"])\n')
    target.write('File.write!("/srv/factory/homes/factory-worker/build-uid", uid)\n')
PY
runuser --user factory-worker -- rm -rf -- "/srv/factory/build/$revision/lib"
bash "$release/factory/deploy/build.sh" "$release" worker
[[ "$(tr -d '[:space:]' </srv/factory/homes/factory-worker/build-uid)" = "$(id -u factory-worker)" ]]
[[ "$(stat -c %u /srv/factory/homes/factory-worker/build-uid)" = "$(id -u factory-worker)" ]]
[[ ! -e "$release/elixir/bin/symphony" ]]
printf 'PASS: actual Symphony setup/build twice; cached worker dependency executed as UID %s; cleared credentials; escript outside root source\n' "$(id -u factory-worker)"
