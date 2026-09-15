---
tracker:
  kind: memory
  project_slug: GKE bootstrap — unconfigured
polling:
  interval_ms: 60000
workspace:
  root: /tmp/symphony-workspaces
agent:
  max_concurrent_agents: 1
  max_turns: 1
codex:
  command: /bin/false
control:
  enabled: true
  initial_mode: paused
  state_path: /var/lib/symphony/control.json
  max_attempts: 1
  max_total_runtime_ms: 60000
  max_total_tokens: 1
observability:
  dashboard_enabled: false
server:
  host: 0.0.0.0
  port: 8080
---
GKE controller bootstrap is paused and unconfigured. The memory tracker is empty.
Do not execute tasks. Kubernetes runner, model authentication, independent review
and publication adapters require separate implementation and acceptance.
