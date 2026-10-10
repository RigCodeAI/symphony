#!/usr/bin/env bash
# Run as root in a disposable Linux container.
set -Eeuo pipefail
source_root="${FACTORY_TEST_SOURCE:-/factory-source/deploy}"
[[ "$EUID" = 0 && -f "$source_root/mix.sh" ]]
id factory-worker >/dev/null 2>&1 || useradd --create-home factory-worker
test_dir=$(mktemp -d /tmp/factory-mix-timeout.XXXXXX)
trap 'rm -rf -- "$test_dir"' EXIT
chmod 0755 "$test_dir"
mkdir "$test_dir/cache"
chown factory-worker:factory-worker "$test_dir/cache"
cat >/usr/local/bin/mise <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" = exec && "$2" = -- ]]
shift 2
export MIX_HOME=/root/protected-mise-cache MIX_ARCHIVES=/root/protected-mise-cache/archives
exec "$@"
SH
chmod 0755 /usr/local/bin/mise
cat >"$test_dir/mix" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$EUID" != 0 && "$MIX_HOME" = "$EXPECTED_CACHE" ]]
[[ "$MIX_ARCHIVES" = "$MIX_HOME/archives" && "$MIX_ESCRIPTS" = "$MIX_HOME/escripts" ]]
if [[ "$1" = slow ]]; then exec sleep 10; fi
[[ "$#" = 2 && "$1" = workstream.run && "$2" = 'input with spaces' ]]
printf 'UID=%s MixHome=%s arguments preserved\n' "$EUID" "$MIX_HOME"
SH
chmod 0755 "$test_dir/mix"
runuser --user factory-worker -- env PATH="$test_dir:/usr/bin:/bin" \
  MIX_HOME="$test_dir/cache" EXPECTED_CACHE="$test_dir/cache" \
  timeout --signal=TERM --kill-after=1s 5s /bin/bash "$source_root/mix.sh" \
  workstream.run 'input with spaces'
status=0
runuser --user factory-worker -- env PATH="$test_dir:/usr/bin:/bin" \
  MIX_HOME="$test_dir/cache" EXPECTED_CACHE="$test_dir/cache" \
  timeout --signal=TERM --kill-after=1s 0.2s /bin/bash "$source_root/mix.sh" slow || status=$?
[[ "$status" = 124 ]]
if MIX_HOME="$test_dir/cache" /bin/bash "$source_root/mix.sh" workstream.run ignored; then
  echo 'root Mix entrypoint unexpectedly accepted' >&2; exit 1
fi
printf 'PASS: external timeout starts service-user Mix, restores role caches, preserves arguments and stops a slow runner\n'
