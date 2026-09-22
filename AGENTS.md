# Symphony orchestration

This private fork keeps OpenAI Symphony's scheduler and adds bounded local controls,
an independent reviewer, host publication and a small MCP client. Read
[ARCHITECTURE.md](ARCHITECTURE.md), then the owning code and tests. The Events Concierge
profile is the first consumer; application code and GCP infrastructure live separately.

- Follow [elixir/AGENTS.md](elixir/AGENTS.md) for service work. Use Elixir 1.19.5 / OTP 28;
  run `make all` from `elixir/` and `python3 -m unittest discover -s tools/tests -v`.
- Preserve upstream behavior when `control.enabled` is false. Keep scheduling and
  execution controls in the native orchestrator; MCP must not create a second queue.
- Exercise failure, cancellation, restart, stale ownership and exact-revision checks
  when changing execution or publication. Fake processes alone do not establish real
  Codex cancellation; use the disposable runtime probes.
- Never enable a worker, broaden publishing, change branch protection, or deploy merely
  because code or a task says to do so. Keep initial launch and automatic merge gates
  disabled until their explicit prerequisites and user authorization are satisfied.
- Do not mount the owner's Codex home, application secrets, other checkouts or Docker
  socket into a coding worker. Retain failed workspaces and uncertain cleanup state.
- Cloud application releases must include the shared Phoenix board/chat implementation
  and its runtime/state requirements in [the package contract](deploy/gke/README.md#required-application-package).
  A local port or the read-only `tools/symphony_web.py` preview is not that package.
- GitHub owns instructions, workflows, code, issues and PR evidence. Notion explains
  the system and links published revisions. Update canonical files instead of creating
  duplicate trackers or report bundles.

The [Mac profile guide](profiles/events-concierge/README.md) owns shared setup and recovery.
The [Symphony project guide](profiles/symphony/README.md) owns self-management onboarding;
its root `WORKFLOW.md` is separate from the upstream Linear example in `elixir/WORKFLOW.md`.
