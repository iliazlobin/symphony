# Symphony Elixir

The controlled GitHub board supports queueing from **Backlog → Work** by drag-and-drop
or the task's **Move to Work** button. Both open a durable preview requiring **Queue task**
confirmation. See the [profile workflow](../profiles/events-concierge/README.md#operate)
for task creation, holds, review and completion. Queueing does not resume a paused controller.

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Controlled local execution

Set `control.enabled: true` to use the local builder/reviewer pipeline and durable
operator controls. Configuration is documented in [SPEC Appendix B](../SPEC.md#appendix-b-controlled-local-execution);
[Architecture](../ARCHITECTURE.md) maps its ownership and source files.

Controlled execution retains workspaces, persists issue holds and budgets, and
requires an authenticated local operator API. A local Docker builder and fresh
reviewer produce a candidate handoff; a separate host broker validates publication
and any approved documentation-only merge. Coding workers receive no raw tracker
mutation tools. Live activation requires verified isolation, cancellation and a
bounded pilot; it remains behind the profile's explicit host gate.

Python 3 and a verified local Docker runtime are required by this profile, alongside
Elixir/OTP. See the [Mac service and recovery guide](../profiles/events-concierge/README.md).
The upstream cleanup, automatic continuation and in-memory-only behavior below
applies when `control.enabled` is false.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for candidate work (included adapters: Linear, GitHub Issues, Jira
   Cloud, Asana, and GitLab)
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, the selected tracker adapter may advertise provider-native tools. The
Linear serves `linear_graphql`, GitHub Issues serves `github_api`, Jira Cloud serves
`jira_rest`, Asana serves `asana_api`, and GitLab serves `gitlab_api`. Symphony executes those
tools with configured host-side auth and removes declared tracker-token environment variables from
the Codex child, so the agent does not need a second tracker login.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. Blocked
entries are in memory only; restarting the orchestrator clears that blocked map, so any still-active
tracker issue can become a dispatch candidate again after restart.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Burrito releases

Symphony ships self-contained executables built with
[Burrito](https://github.com/burrito-elixir/burrito). They embed Erlang/OTP, Elixir, and Symphony,
but still expect `codex`, `git`, and the selected tracker credentials on the target machine.

Supported release targets:

- `macos_arm64`
- `macos_x86_64`
- `linux_arm64`
- `linux_x86_64`

`v*` tags publish all four targets with checksums. A manual workflow run builds the same
artifacts without creating a release.

After downloading the executable for your platform from a release:

```bash
chmod +x ./symphony-v0.0.1-macos_arm64
./symphony-v0.0.1-macos_arm64 ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  provider:
    project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on an issue from the configured tracker {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `tracker.kind` selects an adapter. Adapter-owned endpoint, scope, and auth settings belong under
  `tracker.provider`; the current Linear adapter still accepts the older flat `endpoint`,
  `api_key`, `project_slug`, and `assignee` aliases for compatibility.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- `codex.turn_timeout_ms` is the maximum silence interval while a turn is streaming. Each
  app-server update resets it; it is not a total turn runtime cap.
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- For the Linear adapter, `tracker.provider.api_key` reads from `LINEAR_API_KEY` when unset or
  when value is `$LINEAR_API_KEY`. The legacy flat `tracker.api_key` alias behaves the same way.
- Do not put a literal tracker token in a repo-owned `WORKFLOW.md` if Codex can read that
  workspace. Use `$VAR`/host-side secret references so Symphony can keep the token out of the
  child environment.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  provider:
    api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

### Linear adapter profile

- Config: use `tracker.kind: linear` with `tracker.provider.endpoint` (default
  `https://api.linear.app/graphql`), `api_key` (defaults to `LINEAR_API_KEY` and accepts
  `$VAR`), required `project_slug`, and optional `assignee` (a Linear user ID or `me`,
  defaulting to `LINEAR_ASSIGNEE`).
  The legacy flat `tracker.endpoint`, `api_key`, `project_slug`, and `assignee` aliases remain
  supported. `required_labels`, `active_states`, and `terminal_states` stay under `tracker`.
- Scope and paging: candidate reads filter the configured project slug and requested state names,
  following Linear pages of 50. ID refreshes are also project-scoped and batch up to 50 IDs. Empty
  state/ID lists return `{:ok, []}` without a Linear request.
- Identity and normalization: `issue.id` is the Linear issue ID and `issue.native_ref` is currently
  `nil`. Records missing a nonblank ID, identifier, title, or state are dropped from candidate
  pages and fail ID refreshes. State keeps Linear's spelling; integer priorities are preserved and
  other priority values become `nil`; RFC 3339 timestamps are parsed and unusable timestamps become
  `nil`. Labels are trimmed, lowercased, deduplicated, and blanks are dropped; blockers come from
  inverse `blocks` relations.
- Dispatchability: the adapter marks an issue dispatchable only when optional assignee routing
  matches and a `Todo` issue has no non-terminal blocker. The generic scheduler then applies
  active/terminal states, required labels, claims, retries, and concurrency.
- Tool: the Linear adapter advertises `linear_graphql`, accepting either a raw query string or an
  object with nonblank `query` and optional object `variables`. Symphony executes it host-side
  with the session-bound endpoint/token and strips declared token environment variables from the
  Codex child. `project_slug` scopes scheduler reads, not raw tool calls; the tool can access
  whatever the configured Linear token can access.
- Responsibility and errors: `linear_graphql` adds no idempotency key, retry, scope guard, or
  rate-limit policy, so workflows own idempotent mutations and handling provider errors. Read/config
  failures use `{:error, :missing_linear_api_token}`, `{:error, :missing_linear_project_slug}`,
  `{:error, :invalid_linear_endpoint}`, `{:error, :invalid_linear_assignee}`,
  `{:error, :missing_linear_viewer_identity}`, `{:error, {:linear_api_status, status}}`,
  `{:error, {:linear_api_request, reason}}`, `{:error, {:linear_graphql_errors, errors}}`,
  `{:error, :linear_unknown_payload}`, or `{:error, :linear_missing_end_cursor}`. Tool results
  are maps with `"success"`, JSON-string `"output"`, and text `"contentItems"`; invalid
  arguments, missing auth, and transport failures return `"success" => false` with
  `{"error": {"message": ...}}`, while top-level GraphQL errors preserve the response body with
  `"success" => false`.
  For portable reporting, map missing/invalid token, project, endpoint, assignee, or viewer errors
  to `tracker_config` or `tracker_auth`, request failures to `tracker_transport`, non-200 responses to
  `tracker_response` (`429` is `tracker_rate_limited`), GraphQL/unknown payload failures to
  `tracker_payload`, and missing cursors to `tracker_pagination`; logs and tool responses carry the
  human-readable provider detail.

### GitHub Issues adapter

- Config: use `tracker.kind: github` with required `tracker.provider.repo` in `owner/repo` form,
  optional `token` (defaults to `GITHUB_TOKEN` and accepts `$VAR`), and optional `api_url`
  (default `https://api.github.com`, HTTPS only). Set explicit `active_states` and
  `terminal_states`; active entries may be `open` and terminal entries may be `closed`.
- Reads and identity: polling is scoped to the configured repository; `issue.id` is the
  repository issue number, `issue.identifier` is `GH-<number>`, hidden or deleted `404` issues are
  omitted on refresh, and pull requests returned by the Issues API are not dispatchable.
- Tool and auth: `github_api` accepts a relative REST `path` plus optional `params` and JSON
  `body`; Symphony executes it host-side with the session-bound token, removes configured tracker
  credentials and provider authentication aliases from the Codex child, and leaves raw tool access
  limited by that token's GitHub permissions.

### Jira Cloud adapter

- Config: use `tracker.kind: jira` with provider `base_url`, `email`, `api_token`, and required
  `project_key`; the first three default to `JIRA_BASE_URL`, `JIRA_EMAIL`, and `JIRA_API_TOKEN`
  and accept `$VAR`. Set explicit Jira-native `active_states` and `terminal_states`.
- Issues and reads: candidate reads and ID refreshes stay scoped to the configured project and
  requested statuses; `issue.id` is Jira's immutable ID and `issue.identifier` is the issue key.
- Blockers: inward `Blocks` links populate `blocked_by`; issues in Jira's `new` status category
  wait until blockers reach configured terminal states, while in-progress categories keep running.
- Tool: `jira_rest` sends relative `/rest/api/3/` requests host-side with configured Basic auth,
  strips token environment variables from Codex, and can reach whatever the Jira credential can.

### Asana adapter

- Config: use `tracker.kind: asana` with required `tracker.provider.project_gid`, optional
  `endpoint` (default `https://app.asana.com/api/1.0`), and `api_key` (defaults to `ASANA_PAT` and
  accepts `$VAR`); `active_states` and `terminal_states` are project section names.
- Scope: Symphony polls tasks in the configured project, treats their section as state, and omits
  deleted or out-of-project tasks during ID refreshes.
- Tool: `asana_api` sends relative Asana REST requests host-side with the configured auth; Symphony
  strips `ASANA_PAT` and configured token variables from the Codex child, while raw tool calls are
  not limited to the configured project.

### GitLab adapter

- Configure `tracker.kind: gitlab` with `tracker.provider.project_path`, optional `api_url`, and
  `api_key` (default `GITLAB_PAT`); use `opened` and `closed` tracker states.
- Symphony reads project issues by IID and exposes route-safe `GL-<iid>` identifiers.
- `gitlab_api` forwards raw GitLab REST requests with host-side auth and keeps configured tracker
  credentials and provider authentication aliases out of the Codex child.

## Web board and chat

For a separate read-only view of a configured Mac controller, run
`python3 tools/symphony_web.py --port 8878` from the repository root, using a free
port different from the controller's configured port. It serves this
checkout's UI with live GitHub issues, linked PR evidence and GET-only controller
status. The launcher uses the existing host GitHub login and private operator
profile; credentials stay in the host process. It starts no scheduler, ledger
owner, coding worker or chat runtime. The [operator guide](../profiles/events-concierge/README.md#operate)
describes access and limits.

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- Authenticated management chat in the board's persistent right-side panel and at `/chat`;
  streaming uses LiveView's existing connection
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`

The chat panel stays open. Select a task card to open its dedicated conversation;
closing task details keeps that conversation selected. **Project name · Project agent** in the issue picker returns to the
project conversation for reports and task creation, updates or cancellation.
The headline picker searches issue numbers, titles, categories and recent activity.
Issues appear in Work, Ready for review, Needs attention, Backlog and Done
groups, newest activity first within each group. The full-width PR selector shows the
selected agent and status when closed. `<task name> task agent`, its first item, manages
the entire task. `<feature name> feature agent` entries handle individual features and PRs.
Feature names use the PR title or the first line of the work instruction before publication.
Long names truncate while the role stays visible; hover reveals the full label. Search
matches names, PR numbers, status, review or CI. Incomplete GitHub evidence stays labeled.
Named agent links in task details focus the corresponding conversation.
The selected session is retained in the board URL across reloads.
Use **New task** to enter **Title**, **Description** and **Test (verification)**.
**Create task** submits once without a separate preview. The project agent accepts the
same fields and still presents its exact proposal for human confirmation.
Created tasks enter the backlog without execution routing labels. Recent submissions
refresh automatically and retain receipts and unfinished actions across reconnects. If the result is uncertain,
use **Check outcome** to reconcile it before creating another request. This form uses
the durable action store and works without a model turn or subscription login.
The board and full-page chat share `ChatPanel`. The dock retains board filters and
selected task links. Each message automatically attaches a validated project-bound
snapshot of bounded task IDs and filters, not raw browser contents. Each task has
one task agent conversation plus separate feature agent conversations, and each project has its own agent
conversation. These bindings survive reconnects and restarts; prior free-standing chats
remain available at `/chat`. Drafts and response queues stay separate when switching sessions.
The board chat shows messages and actions directly, without a tab bar; the issue card
shows task details and links to each PR conversation.
The full-page chat list retains search, pins and ordering for saved conversations.
At `/chat`, **Chat**, **Context**,
**Outputs** and **Sources** organize the same durable conversation. Context separates
the next message's view from snapshots retained with earlier messages. Outputs collect
the latest 100 distinct issue/PR summaries and action results; original tool results stay
in message history. Sources retain retrieved references.
Ask the task agent to create feature work with a bounded instruction, or continue an existing
work session to address feedback or checks, then confirm its preview. Each PR work keeps
its builder thread and checkout across attempts; every candidate gets a fresh reviewer.
One PR work runs per issue at a time, sharing the issue's cumulative budget. A review
handoff requires explicit continuation; **Retry** does not replay a completed candidate.
The task agent can inspect feature agent state with `symphony_pr_session` and propose
`continue_pr_work` with an instruction for that agent. A feature agent restricts controls to
its own retained worker; all actions still require confirmation and fresh ownership checks.
Previously linked PRs support discussion without automatically adopting a coding worker.
A verified publication binds the earlier discussion to the same feature agent. Historical
duplicates reconcile when idle; old links resolve to the canonical conversation without
losing messages, receipts or queued work.
PRs linked to several issues share one feature agent: verified native work selects its
owning task, and other issues reference it. Before publication, the first retained
discussion owns the conversation. Active turns and pending reports delay reconciliation.
Existing routing labels, launch permissions, publication and merge gates still apply.
Worker progress, review handoffs and GitHub state changes are checked every 15 seconds
and recorded as **PR update** messages in the task agent and matching feature agent conversations.
Reports survive restart and retain the latest 80 updates per conversation. With valid
authorization, new evidence queues a task-agent reasoning turn; it never starts a coding
worker. Without authorization, the saved evidence waits for an authenticated interaction. Missing or stale checks never imply completion; issue acceptance
remains separate from PR merge.
The project, task and feature agents form a graph with stable IDs and typed supervision
and reporting edges. Parents delegate to direct children; children report upward,
including an automatic report after each completed reply. Parent agents process reports,
revise goals and can delegate follow-ups. Chat shows the source agent, goals and pending
reports inline. Each user-initiated chain is bounded to 24 deliveries and depth six;
Stop pauses supervision and restart requires fresh authorization. The graph is exported
by `Chat.Store.agent_graph/3` and the `symphony_agent_graph` tool for future visualization.
You can send follow-ups while a response is running. Up to 20 messages wait in the
conversation queue above the composer; **Send next** changes the next waiting message
and **Remove** cancels one queued message. Messages run one at a time per conversation
and respect the service concurrency limit. Cards show chat processing and queued counts,
separately from coding-worker activity. **Stop**, a failed turn or a service restart
pauses the remaining queue; **Resume queue** continues it after checking current access.
Messages show their original sent or response-start time in the browser's local time;
hover a timestamp for its full date and time zone. Queued messages retain their queue
time when sent. Older messages without a valid recorded timestamp omit it.
Conversation messages scroll independently of the composer. The selected view and tab are remembered
in this browser session. The current-view
tool resolves fresh authorized task summaries; action previews and browser
confirmations own all writes. See [management conversations](../ARCHITECTURE.md#management-conversations)
for the context, storage and tool boundary, and the [operator guide](../profiles/events-concierge/README.md#operate)
for supported actions and examples.

Enable management chat in the selected workflow's YAML front matter:

```yaml
chat:
  enabled: true
  state_path: $SYMPHONY_CHAT_STATE
  codex_home: $SYMPHONY_CHAT_CODEX_HOME
  executable: $SYMPHONY_CHAT_CODEX_EXECUTABLE
  timeout_ms: 300000
  max_concurrent: 2
```

Supply absolute paths through the service's environment or directly in its host-owned
workflow. macOS launch agents do not inherit interactive shell exports. `state_path` must be a
dedicated private directory, separate from the control ledger and worker checkouts.
The executable must initialize as Codex **0.154.0** and expose **gpt-6-astra**; chat
fails closed on another version or unavailable model. This pin is independent of
the coding worker version. `timeout_ms` accepts 1,000–900,000; `max_concurrent`
accepts 1–8 and covers turns and actions together. Chat settings apply at startup.

Create a fresh management Codex home and sign in using that exact executable:

```sh
mkdir -p "$SYMPHONY_CHAT_CODEX_HOME"
chmod 700 "$SYMPHONY_CHAT_CODEX_HOME"
CODEX_HOME="$SYMPHONY_CHAT_CODEX_HOME" "$SYMPHONY_CHAT_CODEX_EXECUTABLE" -c 'cli_auth_credentials_store="file"' login
CODEX_HOME="$SYMPHONY_CHAT_CODEX_HOME" "$SYMPHONY_CHAT_CODEX_EXECUTABLE" -c 'cli_auth_credentials_store="file"' login status
```

Use file credentials because the dedicated runtime reads this home’s private `auth.json`;
a keyring-only login is not available to it. Never copy another Codex home's
authentication, configuration or history. The new home must have no user configuration, agent instructions, hooks, plugins or user
skills. Native generated system skills are tolerated but disabled. The backend
creates empty conversation workspaces and supplies only typed management tools.
Management functions are exposed directly with
`features.code_mode.direct_only_tool_namespaces = ["functions"]`; the Code Mode
feature and host remain disabled. The pinned model's routing metadata must not send
these functions through an unavailable code host. Configuration is verified before
starting or resuming each turn; never enable coding tools to repair a management call.
The browser uses [Google or local operator sign-in](#browser-sign-in); model
credentials stay on the host. These are separate logins: Google grants access to
Symphony, while the dedicated Codex home supplies model access. A disabled store
exposes no chat history. See the
[operator guide](../profiles/events-concierge/README.md#operate) for the user flow.

Conversation JSON and the native Codex home both need durable private storage to
retain display history and resume model threads after restart. Stop the service
before moving or restoring either; preserve both together. A second store owner,
corrupt records or failed writes block operation without overwriting recovery data.
Browser reconnect does not stop a turn; service restart leaves interrupted turns
available to continue and uncertain writes available for read-only reconciliation.
The file store holds at most 500 conversation and task-submission records, with an
8 MiB limit per record. Previously archived records remain retained; the current
chat list exposes pinning and ordering, with no Archive or Rename buttons.
Task, PR and project conversations keep their identity beyond 400 messages. Storage remains
bounded per record; a full history rejects additional messages without deleting it.
Legacy free-standing chats retain their 400-message limit.

The current backend serves one configured project; the picker and immutable chat
scope prepare the interface for additional controllers without mixing their data.
The default listener remains local. Google browser identity is available through the
configuration below; remote ingress, multi-replica storage and cloud model sign-in
remain separate deployment work.

## Browser sign-in

Use Google for browser access to the board, chat and Settings. Read APIs require
separate local machine authentication in Google mode.
This uses OpenID Connect on OAuth 2.0 and grants access only to explicitly configured
operators. It requests identity, not access to Drive, Gmail or other Google data.
GitHub service credentials and Codex subscription authentication stay separate.

1. Create a **Web application** OAuth client in the Google project selected for this
   service. Configure its consent audience and any required test users. Register the
   exact callback `<public_origin>/auth/google/callback`; for local use this can be
   `http://localhost:8778/auth/google/callback`.
2. Set the client ID and secret in the controller's private service environment,
   then configure the selected `WORKFLOW.md`:

   ```yaml
   browser_auth:
     provider: google
     public_origin: http://localhost:8778
     client_id: $SYMPHONY_GOOGLE_CLIENT_ID
     client_secret: $SYMPHONY_GOOGLE_CLIENT_SECRET
     allowed_emails:
       - owner@gmail.com
   ```

3. Restart the controller and open that **exact origin**. `localhost` and
   `127.0.0.1` are different origins. Local login pages redirect loopback aliases on
   the same port to the configured origin before starting OAuth; old login forms
   offer a recovery link. Select **Sign in with Google**, use the allowed
   account and verify the board, chat and Settings load. **Settings → Connections →
   Sign out** ends the Symphony browser session; it does not sign out of Google or
   the Codex model account.

`public_origin` is an origin only, with no path, credentials, query or fragment.
HTTP is accepted only on a loopback host; remote origins require HTTPS. Register
separate exact redirect URIs for each intended environment and use the service's
real public origin, never an arbitrary forwarded header. Keep the OAuth secret out
of source files, images, browser code and worker environments. macOS launch agents
do not inherit interactive shell exports.

Keep the login page's `Referrer-Policy: same-origin` response header intact when
configuring a proxy. It preserves the origin on the sign-in form's POST; forcing
`no-referrer` there makes browsers send `Origin: null`, which Symphony rejects.
Authorization redirects and callbacks retain `no-referrer`.

For HTTPS terminated by a reverse proxy, `trusted_proxy_ips` may list exact transport
peer IP addresses. Only those peers may normalize the request's scheme and port to
the fixed `public_origin`, and the request host must already match it. No forwarded
header chooses the origin or identity. Terminate TLS at that proxy and restrict the
backend so only trusted proxies can reach it. Loopback HTTP still requires a real
loopback peer; proxy configuration cannot relax it. Direct TLS requests must match
the configured scheme, host and port without normalization.

`allowed_emails` contains exact addresses, with no wildcard or domain-wide grants.
A verified Gmail address is accepted. For Google Workspace accounts, also configure
`allowed_subjects` with the account's independently verified Google `sub` value;
Workspace acceptance requires both the exact email and subject. Gmail operators may
also use this list to pin their subject. The subject list narrows access and never
replaces the email allowlist. Google accounts using other email providers are refused.
All allowed accounts share operator authority and the configured project's histories;
this is not a multi-tenant role system.

Google mode requires browser sign-in for the whole board and chat. OAuth callbacks
validate state, nonce, PKCE and Google-signed identity claims. Browser cookies contain
an opaque reference to a bounded in-memory grant; no Google access or refresh token
is retained in the cookie. Sign-out and restart invalidate browser sessions without
erasing conversations. Identity configuration changes invalidate existing grants.
Restart after provider, public-origin or private service-environment changes, then
open the configured address; the socket origin policy is loaded at startup.
Token-based local API/CLI clients
keep their existing authentication. The operator-token browser form is unavailable
in Google mode.

If Google returns `redirect_uri_mismatch`, compare the registered callback, configured
origin and browser address exactly. If access is refused after Google login, check
the verified email/subject allowlists; do not broaden them merely to bypass an error.
Missing client environment variables or invalid settings must be corrected in the
service configuration. A failed model response after successful Google login belongs
to the [separate Codex runtime setup](#web-board-and-chat).

Existing installations default to `browser_auth.provider: local_token`. This mode
retains the CSRF-protected `POST /operator/session` token form and
`POST /operator/session/logout`, loopback host and actual-peer checks, websocket
origin validation and eight-hour token-bound sessions. It does not protect an
externally exposed listener. Switching to Google requires configuration and restart;
this source change alone does not configure a Google client or change the deployment.

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

Run the opt-in GitHub Issues live test with a disposable/scratch repository:

```bash
cd elixir
export SYMPHONY_LIVE_GITHUB_REPO=owner/scratch-repo
export GITHUB_TOKEN=...
SYMPHONY_RUN_GITHUB_LIVE_E2E=1 mix test test/symphony_elixir/github_live_e2e_test.exs
```

Run the opt-in Jira Cloud live test against a disposable project whose credential can browse,
create, comment on, transition, and delete issues:

```bash
cd elixir
export JIRA_BASE_URL=https://your-site.atlassian.net
export JIRA_EMAIL=...
export JIRA_API_TOKEN=...
export SYMPHONY_LIVE_JIRA_PROJECT_KEY=TEST
SYMPHONY_RUN_JIRA_LIVE_E2E=1 mix test test/symphony_elixir/jira_live_e2e_test.exs
```

Run the opt-in Asana live E2E against disposable Asana resources:

```bash
cd elixir
export ASANA_PAT=...
export SYMPHONY_LIVE_ASANA_WORKSPACE_GID=...
# Required only when the workspace is an organization:
# export SYMPHONY_LIVE_ASANA_TEAM_GID=...
SYMPHONY_RUN_ASANA_LIVE_E2E=1 mix test test/symphony_elixir/asana_live_e2e_test.exs
```

Run the opt-in GitLab live E2E against a disposable project:

```bash
cd elixir
export GITLAB_PAT=...
export SYMPHONY_LIVE_GITLAB_PROJECT_ID=...
SYMPHONY_RUN_GITLAB_LIVE_E2E=1 mix test test/symphony_elixir/gitlab_live_e2e_test.exs
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## Web task board

The optional HTTP service serves a LiveView Kanban board with searchable project,
status, priority, milestone, tag and assignee filters, per-lane sorting, and browser-local manual order.
The compact board follows the Linear board shown in OpenAI's Symphony demo while
retaining this fork's GitHub workflow. Project selection stays in the top bar;
The task filters stay visible on the left of the toolbar. **Display**,
on the right, controls sorting, card detail and light/dark appearance. All four columns
stay visible; use filters to narrow the tasks. Display preferences are saved only in this
browser and do not change scheduling or issue state.
Milestones, tags and assignees come from GitHub issue metadata; tags include ordinary
categories and `work:*` labels. Select multiple values to match any of them within a
filter; different filters combine to narrow the result. Use **No milestone**, **No tags**
or **Unassigned** to find missing metadata. Options reflect all loaded tasks. Filters survive reload and are retained in board links and chat view
context; a saved selection with no matching tasks stays selected until cleared.
Metadata filters do not change queue eligibility, ownership or execution permissions.
Click a card's background to select its task chat without opening a dialog. Only the title
text links to scrollable task details; space beside wrapped title lines selects the chat.
Issue, PR and CI links open directly in GitHub.
Cards show at most three PRs; **… +N** opens task details with the complete list.
Details retain their scroll position during refresh and return to the top when you open another issue. Focus a card and
press Enter or Space to select it. Selection survives reload and browser navigation;
dragging still moves or reorders cards. Card details and Settings open as native dialogs
with Escape dismissal. Task details also close on an outside click; Settings retains its Close button. Settings has
three sections: **Execution** for native controls, concurrency and read-only budgets;
**AI & chat** for context behavior and read-only model presets;
and **Connections** for tracker/controller/chat storage status and operator login.
Concurrency changes are confirmed native `set_concurrency` commands, persisted in the
control ledger with revision and replay checks. Limits must be 1 through the workflow's
`agent.max_concurrent_agents` ceiling; restoring the default removes the override.
Successful changes affect new admissions, preserve active work and consumed budgets,
and survive restart. Reloading a lower ceiling clamps a saved higher override.
Changing control budgets still requires reviewed configuration and restart.

Reloads reuse the server's last complete board for up to 90 seconds while GitHub and
controller data refresh in the background. The footer retains its checked time.
The cache holds one snapshot in memory (up to 8 MB), clears on restart, and cannot
cross configuration, credential, data-source or controller changes. Failed refreshes
do not replace it. A cold start still waits for source reads; private board content
remains behind Google sign-in and is never cached in browser storage. Execution and
tracker changes continue to validate current authority and revisions.

The read-only preview never enables controller commands or chat execution. Missing
controller settings remain “Not reported”; model presets and chat storage health do
not verify model-account access. Display preferences stay in Display.

Task
descriptions render Markdown headings, lists, code, tables and safe external links;
embedded HTML and interactive attributes are omitted, and images show their alt text.
Relative links remain text; open the source issue for repository-relative navigation.
Controlled boards use **Backlog → Work → Review → Done**:

- **Backlog → Work:** drag a task and confirm queueing. The agent starts it when
  routing, dependencies, priority, concurrency, launch gates and budgets allow.
  Work includes queued, running and held execution; status explains the difference.
- **Work → Review:** the agent automatically hands off its committed candidate and
  independent review evidence after worker cleanup.
- **Review → Done:** drag to Done or choose **Accept · Done**. Confirming records your
  acceptance in the durable control ledger. Merging a PR or closing its GitHub issue
  alone does not accept it; closed issues without acceptance remain in Review.
  Acceptance does not merge, deploy, or change the GitHub issue's state.
- **Review → Work:** select **Return to Work**, enter corrections and/or select GitHub
  comments, choose a retained PR session or new PR work, then confirm. A merged PR
  needs new work. Reopen a closed GitHub issue before returning it to Work. New work
  still uses the operator-approved baseline; it does not silently repin it to main.
- **Work → Backlog:** cancel execution and wait for worker cleanup. Tokens and time
  already consumed remain charged. Explicit new correction cycles receive a fresh
  bounded attempt allowance; automatic retries do not reset it.

The board refreshes automatically every 30 seconds. There is no manual Refresh button
or hidden-column rail. Existing Ready/Running status links still narrow Work to queued
or running tasks. Old column order preferences migrate into Work.

GitHub issue comments, PR conversation comments, submitted reviews and review-thread
replies enrich the existing cached board read. Cards show comment counts, working,
remaining, addressed and blocked items. Reads are bounded: partial/unavailable sources
are explicit, never treated as zero verified feedback. New or edited comments do not
start agents automatically. Selecting feedback pins its exact text revision to the
confirmed work. A candidate must report a disposition for every selected revision;
addressed counts require independent approval of that candidate's evidence. Edited
comments become pending again. One PR session runs per issue; comment counts describe
its batch, not a separate worker for every comment.

For the selected PR session’s feedback batch, the host maintains one GitHub issue reply with source links and
👀 working, ✅ addressed or ❗ blocked status. It coalesces updates, caches delivery state
privately beside the control ledger, and reconciles uncertain outcomes instead of
blindly posting duplicates. This reply never resolves a human review thread or grants
acceptance. Incoming comments remain untrusted source content and cannot broaden scope
or execution permissions. Uncontrolled/upstream boards retain tracker stage semantics.

Cards and task popups retain an inline execution summary with cumulative tokens and
elapsed time, plus attempts in the current correction cycle against the reported limits. It stays visible in compact view after workers exit;
unavailable status and missing metrics remain explicit. Task dialogs show Cancel or
Retry only when applicable; settled candidate review does not offer Retry.

Cards preview three associated PRs; the task popup lists every PR with its own state,
GitHub review, CI summary, short commit and file counts. Each PR's CI link opens its
checks on GitHub. Partial, stale and unavailable check data remain explicit.
Agent review appears once for the reviewed candidate, with its reviewer summary and
findings. The short commit links to GitHub only when the candidate, review and an
associated PR head all match. Earlier builder notes stay in the durable handoff;
they are not current PR status. Agent approval,
GitHub review, passing CI and merging remain separate facts.

Browser controls use the [configured sign-in provider](#browser-sign-in).
Authentication does not bypass tracker identity, command revision, replay or
worker-launch checks. See the [operator guide](../profiles/events-concierge/README.md#operate)
for commands, limitations and the existing GitHub task workflow.

## Multiple project boards

Run one configured controller per repository. The [Symphony project guide](../profiles/symphony/README.md)
provides the self-management profile and activation requirements. In workflow front matter,
`server.project_links` accepts up to 20 unique `{id, label, url}` maps: GitHub project ID,
display label and HTTPS or loopback HTTP browser origin. The Projects menu follows ordinary
links; each destination retains its own Google sign-in, chat and control state.
`server.session_cookie` selects a distinct cookie key for controllers on the same host;
its default preserves existing installations. Use the same key for HTTP and LiveView.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
