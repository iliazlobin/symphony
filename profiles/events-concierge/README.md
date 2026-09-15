# Events Concierge on the Mac

This profile connects GitHub Issues to one builder and a separate reviewer. Symphony
owns scheduling; the native API owns controls; the small MCP client forwards those
controls. See the [architecture](../../ARCHITECTURE.md) for boundaries and code ownership.

A **project profile** is the project configuration and launch adapter: repository and
baseline, issue selection, execution budgets, workspace setup, worker settings and
publication policy. `WORKFLOW.md` provides scheduler settings, trusted hooks and the
task prompt; `AGENTS.md` and `ARCHITECTURE.md` provide agent guidance and system context.
The [host adapter](profile.py) validates and connects those inputs to the runtime.

The project profile is not an isolation boundary. Separate worker containers, scoped
mounts, Codex filesystem/network permissions and host-only publication credentials
enforce that boundary. A separate checkout prevents work from colliding but is not a
sandbox by itself. Host hooks remain trusted code outside the coding container.
The narrower terms **Codex permission profile** and **AppArmor profile** mean policy
inputs enforced by the tool sandbox and Linux kernel respectively.

## Setup

Use Elixir 1.19.5 / OTP 28 from `elixir/mise.toml`, Python 3.9+ with
`tools/requirements.txt`, Git, GitHub CLI and Codex 0.153.4. Authenticate GitHub CLI as
the repository owner. Install worker Codex authentication independently; do not copy
the owner's existing Codex home, cloud credentials, application `.env` or MCP settings.

Run from this repository:

```sh
python3 -m pip install -r tools/requirements.txt
cd elixir
make all
cd ..
python3 profiles/events-concierge/profile.py init \
  --source /path/to/events-concierge --base-sha FULL_REVIEWED_COMMIT
python3 profiles/events-concierge/profile.py install-rules
python3 profiles/events-concierge/profile.py login
python3 profiles/events-concierge/profile.py doctor
```

The source commit must contain the reviewed application `AGENTS.md`,
`ARCHITECTURE.md` and `WORKFLOW.md`. Initialization creates private local state under
`~/Library/Application Support/Symphony/events-concierge`: configuration, an API token,
control ledger, retained workspaces, worker home, managed rules and publication receipts.
Runtime copies are pinned inputs, not another documentation home. Initialization refuses
to overwrite existing state. The initial [pilot](https://github.com/iliazlobin/events-concierge/issues/6)
targets a draft PR into `codex/symphony-onboarding` from the
[pinned baseline](https://github.com/iliazlobin/events-concierge/tree/cae67523a6e125682f3a87a0bb4ec95d85a633ee).
This pilot target does not select a permanent release branch or enable automatic merge.

## Operate

Use GitHub for task intent and PR review, a management chat for status and authorized
controls, and the local web board for task inspection and bounded controls. The initial mode is paused. Worker
launch has a separate host gate; resume cannot bypass the activation prerequisites
in [Verification and recovery](#verification-and-recovery).

**GitHub — task and PR interface.** Create or edit work in
[Issues](https://github.com/iliazlobin/events-concierge/issues), using the
[task contract below](#task-and-publication-contract). Once execution is activated,
`symphony:ready` makes an eligible open issue available to the scheduler. Review the
candidate diff, independent review and check evidence in
[Pull requests](https://github.com/iliazlobin/events-concierge/pulls). A draft PR is a
review handoff; it does not mean the task is merged or deployed. Task creation and
queue-label changes are available in GitHub and the optional web chat.

**Web board.** Open [Symphony](http://127.0.0.1:8777/). Real tracker issues,
runtime activity and durable holds appear in Backlog, Ready, Running, Review and
Done. Top autocomplete filters select project, status and priority; search and
sorting apply within each lane. Manual drag ordering is saved in this browser and
does not change scheduler priority. GitHub issues without a priority remain unspecified.

Click a card or **Settings** to open a popup above the board. **Close**, **Escape**,
or clicking outside the popup returns to the same filters and position. Settings
has **Execution**, **AI & chat**, and **Connections** tabs:

- **Execution:** pause/drain/resume, maximum concurrent tasks, and read-only per-task
  budgets. Unlock first, change the limit, then confirm. The range is 1 through the
  workflow ceiling. Successful changes preserve active work and consumed budgets;
  the limit controls new starts and survives restart. **Use workflow default** removes
  the saved override. Raising the configured ceiling or changing budgets remains a
  reviewed configuration change.
- **AI & chat:** save per-project defaults for sharing the board view and identifying
  the selected card. These are browser-local; composer switches override one chat's
  current choices without saving new defaults. **Cancel** discards edits; **Restore
  defaults** stages enabled choices until **Save preferences**. Existing messages stay
  unchanged. Model presets are read-only.
- **Connections:** refresh tracker/controller/chat-storage health, inspect recorded
  usage, or unlock/lock the operator session. Health does not verify model sign-in,
  tracker write permissions or worker readiness. No probe starts a model or worker.

Older controllers that do not report settings show unavailable values, not frontend
configuration defaults. The port 8778 read-only preview never exposes execution edits;
only browser preferences are editable there.

Tracker/control failures retain last-known cards with an explicit warning. The board
refreshes tracker data every 30 seconds; runtime messages also update over LiveView.
Done means the tracker is terminal; it does not establish merge, acceptance or deployment.

Cards link the issue, repository and related pull requests. PR draft/merge state,
GitHub review and checks for the current PR head remain separate from the worker's
candidate review. The source strip shows refresh failures and controller mode;
“Live updates connected” describes the browser connection only.

To try updated web code against live work without replacing the installed controller,
run this from the Symphony checkout with its pinned Elixir runtime and Python dependencies:

```sh
python3 tools/symphony_web.py --port 8778
```

Open [the local live board](http://127.0.0.1:8778/) and leave that terminal running;
Ctrl-C stops this view. It reads the existing operator profile, GitHub and the
controller's status APIs. It never starts coding workers, opens the controller's
ledger or enables browser commands. Chat is unavailable in this read-only view.
Use `--config /absolute/path/to/config.json` for another configured profile.
The profile binds the repository to the controller address; the current controller
API does not attest repository identity in its response.

**New task** opens the configured GitHub issue form. Create the issue and manage its
intake labels in GitHub, then refresh the board. Moving across lanes cannot fabricate
workflow progress. Moving Ready to Backlog requests a confirmed native cancellation;
moving a held Backlog card to Ready offers native retry. Cancel can stop work claimed
since the card was displayed; retry clears a hold without resetting budgets or
providing a missing answer. Other transitions explain the owning workflow action.

**Local operator controls.** In Settings → Connections, unlock with the token from the private
`token_file` beside the operator configuration. The password form posts only to the
loopback service; never put the token in a URL. The signed browser session expires
after eight hours and becomes invalid when the token changes. Tracker configuration
changes disable controls in an open page until you reload it.
**Lock controls** clears this browser session and disconnects its sockets. Pause, drain,
resume, cancel and retry use native revisions, idempotency and project checks; each
consequential action has a confirmation. A cancel receipt is not proof of worker cleanup.

The board and read APIs retain the local observability access model. Google sign-in,
remote access, additional project services, delivery of answers into running workers,
automatic repairs and web publication actions remain separate implementation work.
Do not expose this local listener as an authenticated GCP application.

**Web chat.** After [dedicated runtime setup](../../elixir/README.md#web-board-and-chat),
select one project on the board and open **Chat** in the right-side panel. A task
popup also offers **Discuss this task**. Unlock with the local operator token. Use
**New chat** for a separate topic; **History** opens searchable history with rename
and archive actions. Project changes clear the current selection and draft. A chat
stays with its original project. This service currently supplies one configured
project; additional controllers are not aggregated yet.

Responses stream as they arrive. **Stop** interrupts the chat response, not a coding
task. Closing the tab leaves the response running; reopen its URL to reconnect.
After a service restart, send another message to continue an interrupted conversation.
Codex handles native compaction while the app retains visible messages and receipts.
The optional **Context / Outputs** drawer shows retrieved sources, task widgets and
actions. References update the board filters or open a task popup while keeping
the conversation open. `/chat` remains available as a full-page conversation view.

**Manage the view context.** The composer shows what will accompany the next message:
project, filters, displayed task count and the selected card. Switch off **Share this
view** to send no current board snapshot, or uncheck **Identify selected card** to
remove its explicit selection (the card may still be part of the displayed task list).
Sharing off does not erase earlier messages or sources; start a new chat for a fresh
conversation. Context refreshes as you filter, scroll, switch lanes or open a card.
It includes up to 50 task IDs and marks truncated lists. It excludes arbitrary screen
text, screenshots, password fields and other browser tabs. Tools recheck task details
and authorization before using a snapshot; the snapshot is not approval to act.

Try “Explain this card and all its PR checks”, “Which tasks in this view need input?”,
“Explain this project's architecture”, or “Create a task
to improve the admin filters, with acceptance criteria”. Read tools render status,
task cards and commit-pinned document references. A write first renders its exact
preview; **Confirm** applies it and **Cancel** discards it. A receipt records the
action, not proof of worker completion. **Check outcome** reconciles uncertain
writes without repeating them; do not create a replacement request meanwhile.

Chat can create a backlog issue, edit title/description/state/priority, add feedback,
queue/unqueue intake labels and request native pause/drain/resume/cancel/retry.
Editing or changing intake labels requires a cancelled, idle task. For new work:
create the issue, cancel it to hold admission, queue it, then retry when ready.
Queueing adds only the configured intake labels; retry releases the hold but retains
dependency, budget and host launch gates. Creating a task requires explicit intake
labels in the tracker configuration so a new unlabeled issue cannot launch itself.
Feedback is saved to the GitHub issue; it is not injected into an active coding turn.
Deployment, merge, arbitrary code execution and worker input delivery are not chat
actions. External GitHub edits can still race the final issue patch; refresh and
review the issue after changes.

| Read tools | Confirmed workflow actions |
| --- | --- |
| Current view, project status, filtered task search, task details with all fetched PRs/CI, committed project documents | Create or edit a task, add issue feedback, queue/unqueue, pause/drain/resume, cancel/retry |

The read-only preview on port 8778 shows the panel's availability state but does not
start a chat runtime. A signed-in dedicated management account and an explicitly
installed controller revision are required for live model responses.

**External management agent — controls through MCP.** Ask a connected agent:

- “Show the current mode, running tasks, holds and publication blockers.”
- “Inspect runtime details for GH-6 and link its GitHub issue.”
- “Read current status, then drain Symphony now and let the current task finish.”
- “Cancel issue #6, then confirm its execution state.”

The connector exposes only `symphony_status`, `symphony_issue` and `symphony_control`.
It does not create tasks, send arbitrary prompts to a worker, merge PRs or deploy.
An agent can prepare a task through separate GitHub tools when authorized.

Register it in the management Codex environment, replacing both paths with absolute
paths to this checkout and a Python interpreter with `tools/requirements.txt` installed:

```sh
codex mcp add symphony -- "/path/to/python3" "/path/to/symphony/tools/symphony_control.py" mcp
```

Never register management MCP in the worker home. Start or reload the management
session after changing its configuration, then verify that `symphony_status` is
available and responds; a saved configuration alone does not connect a session.

**Identifiers matter.** With this GitHub adapter, issue **#6** has runtime identifier
`GH-6` and control `issue_id` **`"6"`**. `symphony_issue`, the CLI `issue` command and
runtime HTTP details use `GH-6`. Cancel/retry and publisher commands use `6`; MCP/HTTP
send it as a string. Copy identifiers from status rather than using GitHub's separate
global database ID or a Codex session ID. Runtime details can return 404 for an issue
that is not currently running, retrying or input-blocked; check GitHub and durable
control status for queued work, review holds and completed handoffs.

**Terminal — local operation and recovery.** Run these commands from the Symphony
checkout with the configured Python interpreter. For another configuration of this
Events Concierge profile, place `--config /path/to/config.json` before the action.
Start with read-only checks:

```sh
python3 tools/symphony_service.py status
python3 tools/symphony_control.py status
python3 tools/symphony_control.py issue GH-6
python3 tools/symphony_publish.py inspect 6
```

The last two commands are examples for issue #6: runtime details require a tracked
session, and publisher inspection requires a settled, independently approved
candidate. An unavailable API means worker state is unknown, not that workers stopped.

For an initialized host, install and start both persistent user services:

```sh
python3 tools/symphony_service.py install
python3 tools/symphony_service.py start
```

`python3 tools/symphony_service.py stop` unloads the scheduler and publication service.
For foreground scheduler diagnosis, use `python3 profiles/events-concierge/profile.py run`
only when the persistent scheduler is stopped. The publication service watches
completed handoffs; it does not schedule coding tasks. Keep the Mac awake and
Colima/Docker running. Service process status alone does not prove task progress.

Read `status` immediately before a control change and use its **`control.revision`**:

```sh
python3 tools/symphony_control.py drain --revision CURRENT_REVISION
python3 tools/symphony_control.py pause --revision CURRENT_REVISION
python3 tools/symphony_control.py cancel 6 --revision CURRENT_REVISION
python3 tools/symphony_control.py retry 6 --revision CURRENT_REVISION
python3 tools/symphony_control.py resume --revision CURRENT_REVISION
```

These are separate actions, not a sequence to run together. Drain stops new dispatch
while the current bounded pipeline finishes; pause interrupts active work. Cancel
holds one issue and requests cleanup; retry clears its hold within the remaining
budget. Resume permits eligible work without changing the host launch gate.
Re-read status to confirm the resulting state.
MCP reloads its original validated operator configuration for each tool call.
Reconnect an existing MCP adapter after updating its Python implementation; running
adapters do not reload code. Service configuration changes still require the
appropriate service restart.

Each mutation accepts `--command-id UNIQUE_ID`; supply one when a request might need
retrying. After an uncertain response, reuse the same ID, revision and action rather
than sending another command. A changed body for the same ID or a new command with a
stale revision is rejected. In MCP, pass `expected_revision`, `command_id`, `action`, and `issue_id` for cancel/retry.

Publisher recovery commands are `publish ISSUE_ID`, `merge ISSUE_ID`, `reconcile` and
`watch` under `tools/symphony_publish.py`; unlike `inspect`, they can write GitHub.
Use them only for authorized publication or recovery. They retain the exact-candidate,
review, repository and merge gates described below; do not start a second publication
watcher alongside the installed service. `symphony_control.py status` includes the
publication receipts and confirmed PR links.

**HTTP — programmatic interface.** The base URL is the local `api_url` in operator
configuration, normally `http://127.0.0.1:8777`. Existing CLI/MCP clients handle the
private token; custom clients must follow the
[control API contract](../../SPEC.md#b2-native-control-api).

| Route | Purpose |
| --- | --- |
| `GET /api/v1/state` | Runtime sessions, counts, usage and rate limits. |
| `GET /api/v1/GH-6` | Runtime details for that issue identifier, when tracked. |
| `GET /api/v1/control` | Durable operating mode, revision, holds, budgets and handoffs. |
| `POST /api/v1/control` | Authorized pause, drain, resume, cancel or retry with revision and command ID. |
| `POST /api/v1/refresh` | Request a tracker refresh; does not enable workers or bypass admission. |

Control reads/writes and refresh in this controlled profile require bearer
authentication. Control routes accept local clients and reject browser Origin headers;
the web adapter exposes the same bounded native controls. Keep tokens out of URLs and chat; never embed them in browser
scripts. State/details are the local observability view; use CLI/MCP status to combine
that view with host launch settings and publication receipts.

**Codex App Server — internal worker protocol.** Symphony starts a separate Codex
app-server process for each builder/reviewer stage and uses JSON-RPC over stdio to
start threads/turns and receive events. This is not the operator HTTP API or the
management MCP server, and operators do not need to call it directly. Existing
independently launched VS Code/CLI sessions are not adopted by Symphony.

GKE hosting, remote/mobile access, a control UI and a Slack command/reporting integration
are not implemented by this profile. GitHub remains the task record; this Mac is the
current execution host.

## Task and publication contract

GitHub is the only backlog. An open issue needs `symphony:ready`, a bounded outcome,
scope, acceptance criteria and exactly one `Depends on: none` or `Depends on: #12, #34`
declaration (at most 20 distinct same-repository issues). Missing/open/unreadable
dependencies hold dispatch. Existing arbitrary Codex CLI sessions are not adopted.

Managed task checkouts are standalone clones without submodules or nested repositories.
Host validation and hooks reject Git worktree indirection, executable Git configuration,
metadata links and alternate object stores after acquiring the workspace lock. A rejection retains the checkout for review;
do not remove the guard to resume it.

The builder writes and commits only its assigned workspace. A fresh reviewer checks
the same SHA in a separate checkout. The host retains the handoff and holds the issue;
workers cannot publish, close tasks, change labels, merge or deploy. The host publication
broker checks that evidence, publishes a scoped branch and creates a draft PR. Receipts
retain its confirmed publication state and support retry after an uncertain write.

Automatic merge additionally requires host enablement, `symphony:auto-merge`, an explicit
low-risk path/size allowlist, a clean independent review, a protected chosen base branch,
known required checks from pinned GitHub Apps, and matching remote head/base revisions.
Missing evidence blocks it. The user approves deployments separately. A merge is not
proof of deployment or runtime acceptance.

This first profile uses an explicitly pinned source baseline. If the integration branch
moves, publication stops for stale candidates. The operator must reconcile/review the
new baseline, update the host pin and restart before another delivery; automatic rebase
and baseline advancement are not implemented.

## Verification and recovery

Run `python3 -m unittest discover -s tools/tests -v` and `make all` in `elixir/`.
`tools/probe_permissions.py` tests the installed Mac Codex against disposable canaries
without model calls. `tools/probe_cancellation.py` exposes the native Mac process-group
limitation; native Codex can leave detached command children running. Live activation
requires the dedicated container boundary and its real cancellation checks.

The worker image pins Codex 0.153.4 with the application's Python 3.12 / Node 22
toolchain. [Codex 0.153.1 added Astra support](https://learn.chatgpt.com/docs/changelog);
the pinned hotfix preserves the configured `gpt-6-astra` model. Rebuilds require fresh
permission, cancellation and model-startup checks before updating the active image pin:

```sh
docker build -f profiles/events-concierge/Dockerfile.worker -t symphony-codex:0.153.4 .
docker image inspect symphony-codex:0.153.4 --format '{{.Id}}'
python3 tools/probe_cancellation.py --container-image sha256:VERIFIED_IMAGE_ID
```

Record the verified immutable image ID in the private host configuration. This alone
does not authorize worker launch. Each builder/reviewer has separate runtime state;
only its reviewed configuration, managed rules and dedicated authentication are mounted.

Controlled threads select `symphony-builder` or `symphony-reviewer` through
`config.default_permissions`. Startup requires the same `activePermissionProfile.id`
in Codex's response. Missing or unexpected metadata stops execution before any turn.
The client omits legacy sandbox overrides; builder tools can write the checkout,
reviewer tools cannot, and both deny command network access and outside-file/`.env`
reads. `tools/probe_permissions.py` verifies those restrictions and named role selection
on the installed Mac Codex without model calls.
The dedicated worker configuration explicitly sets `[features] apps = false`.
Account-connected Apps otherwise operate outside the command network sandbox; they
are not available to builders or reviewers. Do not add external MCP servers to this
worker configuration or copy the management session's integrations into it.

`tools/probe_container_permissions.py` checks the pinned Linux worker without real
credentials or model calls. It verifies builder permissions, reviewer permissions on
both writable and read-only outer mounts, and reachable positive controls before
checking file and network denial. Container cancellation probes require fresh parent/child
heartbeats and container removal within 10 seconds, before their 60-second expiry.

**Operational sandbox:** `tools/worker_policy.py --workspace-root PATH` renders the
reviewed AppArmor template for the configured private `workspaces` directory. It
admits direct task/reviewer checkout paths, exact canary paths and finite runtime
mount operations. It does not install policies or change permissions by itself.
Store the reviewed output as mode-0600 `worker-apparmor` beside operator `config.json`.
After authorization, install that exact source as root-owned mode-0644
`/etc/apparmor.d/symphony-codex` inside Colima, parse/load it with
`sudo apparmor_parser -r -T /etc/apparmor.d/symphony-codex`, and verify
`symphony-codex (enforce)` in `/sys/kernel/security/apparmor/profiles`.
Keep Docker's default policy in place for other containers.

The private operator configuration's `worker_sandbox` object records
`apparmor_profile: "symphony-codex"`, the canonical `workspace_root`, and the SHA-256
digests `apparmor_sha256` and `seccomp_sha256`. The latter identifies this repository's
`profiles/events-concierge/seccomp-codex.json`. Review configuration updates while
worker launch is disabled; retain the previous private configuration for recovery.
The service's worker entrypoint compares the rendered source with the configured
scope and checks both digests before selecting the Docker security options.
`profile.py doctor` reports `worker_sandbox_source_verified`; this verifies source
configuration, not that the guest policy is currently loaded or a model can run.
Changed policy content fails closed and requires review, installation and validation.

Validate the operational selection with fake authentication and no model calls:

```sh
python3 tools/probe_container_permissions.py --operator-config "/path/to/config.json"
python3 tools/probe_cancellation.py --operator-config "/path/to/config.json"
```

Operator mode selects the pinned image and the same policy options as the service,
and puts the disposable fixture under its workspace root. Existing fixtures and
uncertain cleanup markers are retained/refused rather than overwritten. Keep worker
launch disabled until these checks pass; then allow only the bounded pilot issue and
validate builder, independent reviewer and host draft-PR publication. Ordinary
dispatch follows pilot acceptance. Automatic merge has separate prerequisites and
can stay disabled while agents produce draft PRs.

Retain failed workspaces and GitHub records. Do not delete the ledger or lock to reset
budgets or force ownership. Restart conservatively holds interrupted work. Resolve any
uncertain container/process ownership before retry; do not run two dispatchers for the
same profile. No application Compose stack, retained database, GCP resource or deployment
is started or changed by this profile's generic task hooks.

Colima's data disk is shared with other local containers. Check capacity with
`docker --context colima system df` and `colima ssh -- df -h /var/lib/containerd`.
Remove only identified disposable build cache within the task's scope. Growing the
data disk requires stopping and restarting Colima; coordinate that interruption and
verify affected services afterward. Do not prune application images or volumes to
make a worker test pass.
