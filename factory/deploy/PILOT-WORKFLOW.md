---
tracker:
  kind: memory
workspace:
  root: /srv/factory/workspaces
agent:
  max_concurrent_agents: 1
  max_turns: 1
codex:
  command: codex app-server
server:
  host: 0.0.0.0
---

The GCP pilot coordinator is intentionally idle. It uses the memory tracker and
listens on port 8080 on the VM's private interfaces. The health check uses the
local address; the GCP firewall allows port 8080 only from load-balancer health
checks and proxies when optional HTTPS ingress is enabled. Pilot work starts
only through `factory-pilot submit` and runs through the pinned local workstream
on a worker.
