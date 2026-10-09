#!/usr/bin/env bash
# Run inside a disposable Linux container as root. The validator and service
# controls are deterministic stand-ins: these tests verify activation ordering
# and rollback, not schema validation, live service health or model execution.
set -Eeuo pipefail
umask 077
[[ "$EUID" -eq 0 && -d /workspace/factory/deploy ]] || exit 2
mkdir -p /opt/factory /srv/factory/releases /srv/factory/tmp /srv/factory/build \
  /srv/factory/homes/factory-coordinator /srv/factory/homes/factory-worker /etc/factory /tmp/controls
ln -s /srv/factory/releases /opt/factory/releases
for role in coordinator worker; do
  useradd --home-dir "/srv/factory/homes/factory-$role" --shell /bin/bash "factory-$role"
  chown "factory-$role:factory-$role" "/srv/factory/homes/factory-$role"
done
chmod 0755 /opt/factory /srv/factory /srv/factory/releases /srv/factory/homes /tmp/controls
cat >/tmp/controls/mise <<'EOF'
#!/bin/bash
if [[ -f "$FACTORY_RELEASE_DIR/reject" ]]; then
  echo 'missing_agent_reference' >&2
  exit 1
fi
echo 'definition valid'
EOF
cat >/tmp/controls/systemctl <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>/tmp/service-calls
EOF
cat >/tmp/controls/curl <<'EOF'
#!/bin/bash
[[ ! -f "$(readlink -f /opt/factory/current)/unhealthy" ]]
EOF
cat >/tmp/controls/sleep <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 0755 /tmp/controls/*
export PATH="/tmp/controls:$PATH"

candidate() {
  local letter="$1" rev
  rev="$(printf '%040d' 0 | tr 0 "$letter")"
  mkdir -p "/srv/factory/releases/$rev/factory/examples" "/srv/factory/releases/$rev/factory/workstreams" \
    "/srv/factory/releases/$rev/elixir"
  cp -R /workspace/factory/deploy "/srv/factory/releases/$rev/factory/deploy"
  printf '{"service_revision":"%s"}\n' "$rev" >"/srv/factory/releases/$rev/RELEASE.json"
  printf '%064d\n' 0 | tr 0 "$letter" >"/srv/factory/releases/$rev/.verified-sha256"
  touch "/srv/factory/releases/$rev/elixir/mix.exs" "/srv/factory/releases/$rev/factory/examples/pass.json" \
    "/srv/factory/releases/$rev/factory/examples/fail.json" "/srv/factory/releases/$rev/factory/workstreams/local-rig.yaml"
  chmod -R a+rX "/srv/factory/releases/$rev"
  printf '%s\n' "$rev"
}

pending() {
  python3 - "$1" "${2:-coordinator}" <<'PY'
import json, pathlib, sys
revision, role = sys.argv[1:]
pathlib.Path('/etc/factory/public.pending.json').write_text(json.dumps({
    'role': role, 'service_revision': revision, 'release_sha256': revision[0] * 64}))
PY
  chmod 0644 /etc/factory/public.pending.json
}

original="$(candidate a)"
invalid="$(candidate b)"
unhealthy="$(candidate c)"
good="$(candidate d)"
worker="$(candidate e)"
ln -s "/srv/factory/releases/$original" /opt/factory/current
pending "$original"
mv /etc/factory/public.pending.json /etc/factory/public.json
cp /etc/factory/public.json /srv/factory/active-public.json
chmod 0644 /srv/factory/active-public.json
printf '{"service_revision":"%s"}\n' "$original" >/srv/factory/active.json

touch "/srv/factory/releases/$invalid/reject"
pending "$invalid"
if bash "/srv/factory/releases/$invalid/factory/deploy/activate.sh" "/opt/factory/releases/$invalid" >/tmp/invalid.log 2>&1; then
  echo 'Invalid definition unexpectedly activated' >&2; exit 1
fi
grep -q missing_agent_reference /tmp/invalid.log
[[ "$(readlink -f /opt/factory/current)" = "/srv/factory/releases/$original" ]]
[[ ! -e /tmp/service-calls ]]
grep -q "$original" /etc/factory/public.json

touch "/srv/factory/releases/$unhealthy/unhealthy"
pending "$unhealthy"
if bash "/srv/factory/releases/$unhealthy/factory/deploy/activate.sh" "/opt/factory/releases/$unhealthy" >/tmp/unhealthy.log 2>&1; then
  echo 'Unhealthy service unexpectedly activated' >&2; exit 1
fi
[[ "$(readlink -f /opt/factory/current)" = "/srv/factory/releases/$original" ]]
grep -q "$original" /etc/factory/public.json
grep -q "$original" /srv/factory/active.json
[[ "$(wc -l </tmp/service-calls)" -eq 2 ]]

pending "$good"
bash "/srv/factory/releases/$good/factory/deploy/activate.sh" "/opt/factory/releases/$good"
[[ "$(readlink -f /opt/factory/current)" = "/srv/factory/releases/$good" ]]
grep -q "$good" /etc/factory/public.json
grep -q "$good" /srv/factory/active-public.json
[[ ! -e /etc/factory/public.pending.json ]]
source /workspace/factory/deploy/lib.sh
[[ "$(factory_active_release /opt/factory)" = "/srv/factory/releases/$good" ]]

pending "$worker" worker
before="$(wc -l </tmp/service-calls)"
bash "/srv/factory/releases/$worker/factory/deploy/activate.sh" "/opt/factory/releases/$worker"
[[ "$(wc -l </tmp/service-calls)" -eq "$before" ]]
grep -q "$worker" /etc/factory/public.json
printf 'PASS: invalid definition preservation, health rollback, config promotion, canonical release lookup, worker activation\n'
