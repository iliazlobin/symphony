# Events Concierge on the Mac

This profile connects each GitHub Issue to a builder and a separate reviewer. Symphony
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
the repository owner. Select [worker authentication](#coding-worker-sign-in) explicitly; do not copy
the owner's existing Codex home, cloud credentials, application `.env` or MCP settings.

Run from this repository:

```sh
python3 -m pip install -r tools/requirements.txt
cd elixir
make all
cd ..
python3 profiles/events-concierge/profile.py init \
  --source /path/to/events-concierge --base-sha FULL_REVIEWED_COMMIT \
  --integration-branch main
python3 profiles/events-concierge/profile.py install-rules
python3 profiles/events-concierge/profile.py login
python3 profiles/events-concierge/profile.py doctor
```

The source commit must contain the reviewed application `AGENTS.md`,
`ARCHITECTURE.md` and `WORKFLOW.md`. Initialization creates private local state under
`~/Library/Application Support/Symphony/events-concierge`: configuration, an API token,
control ledger, retained workspaces, worker home, managed rules and publication receipts.
Runtime copies are pinned inputs, not another documentation home. Initialization refuses
to overwrite existing state. The canonical integration branch is
[`main`](https://github.com/iliazlobin/events-concierge/tree/main); select its reviewed,
full commit SHA explicitly and make it available in the configured source checkout.
The branch name does not advance the source pin or enable automatic merge. Existing
installations use the baseline change procedure below rather than initialization.

## Operate

Use GitHub for task intent and PR review, and the local web board or management chat
for task creation, queueing, status and authorized controls. The initial mode is paused. Worker
launch has a separate host gate; resume cannot bypass the activation prerequisites
in [Verification and recovery](#verification-and-recovery).

**Task concurrency.** A dedicated subscription credential permits one active issue
pipeline. Generated profiles set `agent.max_concurrent_agents: 1`; builder and independent
reviewer run sequentially and preserve their separate sessions. Do not raise this ceiling
while stages share one credential. Multiple independently enrolled slots require a separate
capacity design and verification. The generic scheduler supports up to five tasks; this
Mac profile's credential ownership constrains its usable concurrency.

Each active stage is capped at 2 CPUs and 4 GiB. These are limits, not guaranteed
throughput. Leave headroom for macOS, other services and cleanup. A Colima resize requires
approval for the shared-VM restart and verification of affected services afterward.

**GitHub — task and PR interface.** Create or edit work in
[Issues](https://github.com/iliazlobin/events-concierge/issues), using the
[task contract below](#task-and-publication-contract). Once execution is activated,
Move an issue to Work in Symphony to save its local routing decision. Existing issues
without a local decision can still enter through `symphony:ready`. Review the
candidate diff, independent review and check evidence in
[Pull requests](https://github.com/iliazlobin/events-concierge/pulls). A draft PR is a
review handoff; it does not mean the task is merged or deployed. Task creation and
task routing are available in the web board and project agent; GitHub receives the
configured routing labels asynchronously.

**Web board.** Open the configured browser origin; this Mac uses
[Symphony](http://localhost:8778/) with Google sign-in. Real tracker issues,
runtime activity and durable holds appear in Backlog, Work, In progress, Review and Done.
The always-visible filters narrow status, priority, milestone, labels and assignee. Search and
sorting apply within each lane. Manual drag ordering is saved in this browser and
does not change scheduler priority. GitHub issues without a priority remain unspecified.

Click a card to select its chat; click its title to open details. Click outside the
card details or press **Escape** to close them, retaining selection, filters and position.
**Settings** opens a separate popup with **Execution**, **AI & chat**, and **Connections** tabs:

- **Execution:** pause/drain/resume, maximum concurrent tasks, and read-only per-task
  budgets. Sign in, change the limit, then confirm. The range is 1 through the
  workflow ceiling. Successful changes preserve active work and consumed budgets;
  the limit controls new starts and survives restart. **Use workflow default** removes
  the saved override. Raising the configured ceiling or changing budgets remains a
  reviewed configuration change.
- **AI & chat:** explains automatic project context and reports read-only model presets.
  The full-page chat's Context tab shows the current view and retained snapshots.
- **Connections:** refresh tracker/controller/chat-storage health, inspect recorded
  usage, or sign in/out with the configured browser provider. Health does not verify
  model sign-in, tracker write permissions or worker readiness. No probe starts a model or worker.

Older controllers that do not report settings show unavailable values, not frontend
configuration defaults. A separate read-only preview never exposes execution edits;
only browser preferences are editable there.

Tracker/control failures retain last-known cards with an explicit warning. The board
refreshes tracker data every 30 seconds; runtime messages also update over LiveView.
Done records human acceptance on controlled boards. Closing an issue or merging a PR
alone leaves it in Review until accepted. Acceptance does not merge code or deploy it.

Cards link the issue, repository and related pull requests. PR draft/merge state,
GitHub review and checks for the current PR head remain separate from the worker's
candidate review. Cards preview two PRs; the task dialog lists all associated PRs
with independent status rows and direct CI links. **Agent review** summarizes the
reviewed revision once, retaining the reviewer summary and findings without a raw handoff block.
The source strip shows refresh failures and controller mode;
“Live updates connected” describes the browser connection only.

Each card and task dialog shows an inline execution summary: current state, cumulative
tokens and elapsed time, plus attempts in the current correction cycle when recorded. The summary remains visible in compact
view and after a worker exits. Exact counts are available on the metrics; missing or
stale data is identified explicitly. A settled approved candidate says **Awaiting your
review** and retains its PR links. **Stop task** appears for queued or active work;
**Retry** clears a recoverable hold within the remaining attempt allowance.
**Retry cycle** offers a new configured allowance only when attempts are exhausted and
lifetime token/time budgets remain. Both retries preserve consumed usage and require
confirmation. Reviewed candidates, closed issues and exhausted lifetime budgets do
not offer retry controls.

To try updated web code against live work without replacing the installed controller,
run this from the Symphony checkout with its pinned Elixir runtime and Python dependencies:

```sh
python3 tools/symphony_web.py --port 8878
```

Choose a free port different from the controller's. Open
[the read-only preview](http://127.0.0.1:8878/) and leave that terminal running;
Ctrl-C stops this view. It reads the existing operator profile, GitHub and the
controller's status APIs. It never starts coding workers, opens the controller's
ledger or enables browser commands. Chat is unavailable in this read-only view.
Use `--config /absolute/path/to/config.json` for another configured profile.
The profile binds the repository to the controller address; the current controller
API does not attest repository identity in its response.

Describe tasks to the project agent. A title is required; description and verification
may be empty. `chat.auto_create_backlog: true` enables creation directly from an authenticated
human project-chat turn. The receipt survives reconnects; uncertain outcomes require
reconciliation before retrying. Agent reports cannot use this authority, and creation never
queues a worker. Other writes still require their scoped action confirmation.
Declare prerequisites in the description, for example
`Depends on: #19 (technical: approved baseline)`; omitted dependencies default to none.

The single project selector shows the selected project's name. Chats form three levels:
`<project name> project agent` coordinates the project, `<task name> task agent`
coordinates one issue, and `<work name> work agent` owns one working-session conversation.
PRs are linked resources; external PR discussions do not create a coding worker.
Parents can delegate and revise goals; children report back, and parents process those
reports in their own chats. Goals and pending reports appear inline. The native scheduler
still owns coding work, and exact action confirmation and human acceptance remain separate.
Messages queue while an agent is busy. Stop pauses supervision; after restart, sign in
and resume saved queues. New PR evidence is retained without launching a model until
valid authorization is available. See [agent graph and delivery](../../ARCHITECTURE.md#management-conversations).

| Stage | What you do | What Symphony does |
| --- | --- | --- |
| Backlog | Describe the requested task to the project agent. | Creates an unqueued GitHub issue and keeps the receipt. |
| Work | Drag from Backlog or choose **Move to Work**. | Saves routing immediately, then queues eligible work by priority, dependencies, budgets and concurrency. |
| In progress | Inspect active sessions; stop through execution controls when needed. | Shows active Work automatically; runs a builder and independent reviewer. |
| Review | Inspect the candidate, PRs and checks; merge code when needed. Choose **Return with corrections**. | Retains the candidate and review evidence. A confirmed correction starts or continues a PR session and returns the issue to Work. |
| Done | Drag from Review or choose **Accept · Done**. This directly records acceptance, without another popup. | Checks the current issue and candidate, records acceptance, and retains usage and evidence. It does not close the GitHub issue, merge or deploy. |

Work retains queued, paused, blocked and failed tasks. In progress is a view of active
Work, not another human-controlled lifecycle state. The agent moves completed work to Review.
A merged PR or closed issue is not acceptance; existing closed issues without an
acceptance record also appear in Review. Accepted tasks cannot be retried or requeued.
Reopen a closed GitHub issue before returning it to Work for further corrections.

**Return with corrections** accepts written corrections, selected GitHub issue/PR comments, or
both. Continue an eligible existing PR session or start a new one from the configured
approved baseline. The preview binds the selected text revisions and exact PR head.
Confirmation renews the bounded attempt allowance for that correction cycle; cumulative
token and time budgets remain unchanged. Incoming comments never start agents by themselves.

Comment counts show working, addressed, blocked and remaining feedback. Bounded GitHub
reads share the board cache; partial or unavailable data is identified. Each selected
comment needs an evidence-backed disposition in the candidate handoff. A single GitHub
issue reply tracks the selected PR session’s current batch with 👀 working, ✅ addressed and ❗ blocked,
plus queued status and source links. The private delivery journal at
`<control.state_path>.feedback/deliveries.json` prevents blind reposting after uncertain
writes; preserve it with the ledger during backup and recovery. The reply does not
resolve review threads or accept the task.
Several comments can be handled in one PR session; the working count is not a worker count.

There is no Move dropdown, manual Refresh button or hidden-column rail. The board
refreshes automatically; use filters to hide tasks. Within a column, choose
**Display → Sort by → Manual order** before dragging to reorder. This browser preference
does not change scheduler priority. **Work → Backlog** offers confirmed cancellation;
**Backlog → Work** on a held task offers Retry when remaining limits allow it.
Cancel can stop work claimed since the card was displayed. Retry clears a hold and
saves Work routing without resetting budgets or supplying a missing answer.

Moving Backlog to Work saves the routing decision directly in the local control ledger.
The card updates immediately; GitHub routing labels synchronize automatically.
Repeated uncertain moves reuse the same command. Chat proposals retain their receipts;
use **Check outcome** to reconcile uncertain creation before requesting another task.
The native scheduler remains the only execution queue; queueing does not resume a paused controller.
“Syncing GitHub” or “GitHub sync retrying” means the local decision is saved and its
label update is pending. Retries survive restart and preserve unrelated labels. Inspect
`GET /api/v1/control` → `issues` → issue number → `routing` for sync status. Do not edit
routing labels to change a task already managed locally; use the board or project agent.

**Work but idle.** Check **Settings → Execution** for a paused or draining controller.
Review queued work before confirming **Resume**. Otherwise inspect dependencies, holds,
remaining budget, concurrency and the worker launch gate. Normal tracker polling is
30 seconds. Unavailable status is unknown, not a reason to repeatedly retry or reset.

The cumulative token budget uses Codex's reported input and output tokens, including
cached input. A short task can therefore reach its budget while repeatedly reading
repository context. A `token_budget` hold retains the candidate and consumed usage;
ordinary retry does not reset either. After resolving the failure, an explicitly authorized
`retry ISSUE_ID --renew-attempts --revision CURRENT_REVISION --command-id RECOVERY_ID`
renews only that exhausted task's configured attempt cycle. Lifetime attempts, tokens and
runtime stay recorded; other tasks and project ceilings remain unchanged. Renewal rejects
running or accepted tasks, exhausted lifetime budgets and candidates awaiting owner review.
Use **Return with corrections** for reviewed candidates. Never renew automatically after failure.

Before resuming after `main` changes, follow [Change the baseline](#change-the-baseline).
Both scheduler and publisher must use the reviewed current baseline. Otherwise a
worker can create an old-base candidate that the publisher correctly refuses.

**Browser sign-in.** With the [Google provider configured](../../elixir/README.md#browser-sign-in),
open the exact configured origin and choose **Sign in with Google**. Only explicitly
allowed accounts can read the board and chat or manage work. Machine API clients
retain their separate local authentication.

For the Mac launch agent, save the downloaded Google **Web application** client JSON
outside the repository and worker homes, owned by your user with mode `0600`. Add its
absolute path as `google_oauth_client_file` in the existing private `config.json`:

```json
"google_oauth_client_file": "/absolute/private/path/google-web-client.json"
```

The controller launcher reads the file on each start and supplies
`SYMPHONY_GOOGLE_CLIENT_ID` and `SYMPHONY_GOOGLE_CLIENT_SECRET` to the controller only.
Reference these variables in `browser_auth` in the private `WORKFLOW.md`; configure
the exact public origin and operator allowlist there. The publisher and worker
launchers do not load this file. No shell exports or secrets in launch-agent plists
are needed. Missing, unsafe or malformed configured files prevent controller startup
without printing their contents. Omitting the setting preserves existing environment
configuration. Rotate the private file and restart the controller to load a new client;
follow the existing drain/restart procedure to preserve active work.

**Settings → Connections → Sign out** ends the Symphony session. Restarting the
controller also signs browsers out; saved conversations remain. Google sign-in does
not provide the separate Codex subscription login or GitHub service credentials.

### Coding worker sign-in

OpenRouter chat, Google browser login and Codex coding
authentication are independent. With `codex.auth_preflight: true`, controlled startup checks
the account, token-free authentication status and provider rate limits before a model turn.
Permanent authentication failures remain in Work with **Worker sign-in required**;
automatic retries stop and the hold survives restart and global resume. Temporary transport
failures retain bounded retries. Cards and chat show short messages; service logs retain diagnostics.

The default `worker_auth_source: "dedicated"` keeps an independently enrolled worker
login. Each dedicated credential has one owner at a time. The host moves its sole `auth.json`
into the stage's writable home and returns the current refreshed file only after verifying
the exact container was removed. Configuration/rules remain read-only; sessions remain in
their stage. A shared credential serializes builder/reviewer execution even when task
concurrency is higher. Never restore an older authentication snapshot or copy personal credentials.

For an explicitly authorized laptop login, set these fields in the existing private
configuration while admission is drained and services are stopped:

```json
{
  "worker_auth_source": "local_codex",
  "local_codex_binary": "/absolute/trusted/path/to/codex",
  "local_codex_home": "/Users/OWNER/.codex"
}
```

The host runs an authentication-only Codex client in the private `worker_home`. Coding
and tools still run in the isolated container. The original home stays on the host;
only short-lived access tokens cross private pipes into the worker's ephemeral store.
Refresh requests must keep the same account within a stage. A new or resumed stage uses
the laptop's currently signed-in account. Tokens never enter arguments, environment or
saved session state. Private auth RPCs stay off controller output; known token fields and
values are redacted. A refresh failure holds the task without
automatic retries or resetting usage. There is no fallback between login sources.
The executable must resolve outside source/workspace/session trees to an owned,
non-group/non-other-writable file. Existing retained worker credential files block reuse.

This adapter uses the experimental external-token App Server protocol; host 0.160.0 and
worker 0.153.4 are covered by a disposable no-model probe. Revalidate when either version
changes. `doctor` reports cached sign-in, not provider validity; startup verifies the
provider before a model turn. For local login recovery, use the original CLI's `login`
and resume only within remaining budgets. The profile's `login` command never modifies
the original account. To select dedicated login again, drain/stop and remove local-only
configuration fields; never copy authentication files between modes.

For dedicated login recovery:

1. Drain admission and wait for worker cleanup; retain the task ledger and consumed usage.
2. Run `python3 profiles/events-concierge/profile.py --config /absolute/private/config.json doctor`.
   `worker_auth` reports ownership/file health, not provider validity. Resolve `active` or `recovery`
   ownership before login; a timeout never authorizes takeover.
3. Run `python3 profiles/events-concierge/profile.py --config /absolute/private/config.json login`
   to renew the dedicated subscription. A known completed/failed login releases its enrollment
   claim; interrupted login retains it until its exact child is proven stopped. Preserve the
   claim and current file during recovery; never delete markers to force a new owner.
4. Resume only previously running admission. Retry the task only within its remaining budget;
   startup verifies the provider again. Sign-in does not reset an exhausted attempt limit.

Existing installations use `local_token` until the provider is configured. In that
mode, Settings → Connections accepts the private `token_file` beside the operator
configuration. The password form posts only to the loopback service; never put the
token in a URL. The eight-hour session becomes invalid when the token changes, and
**Lock controls** ends it. This mode is not a remote access boundary.

**Operator controls.** Pause, drain, resume, cancel and retry retain native revisions,
idempotency and project checks; consequential actions require confirmation. Tracker
configuration changes disable controls in an open page until reload. A cancel receipt
is not proof of worker cleanup. Google browser configuration does not deploy a cloud
controller or change task ownership. Additional project services, delivery of answers
into running workers, automatic repairs and web publication remain separate work.

**OpenRouter management chat.** In the private workflow, set `chat.provider: openrouter`,
`chat.model` to the selected provider model, and `chat.api_key: $OPENROUTER_API_KEY`.
In the existing private operator configuration, set `openrouter_env_file` to an absolute,
owned private `.env` file containing exactly one `OPENROUTER_API_KEY` assignment.
The launcher reads only this key; it does not source the file or load other credentials.
The key is controller-only and is excluded from coding-worker and hook environments.
Keep existing `codex_home` and `executable` settings to preserve saved runtime identity.
Follow the drain/restart procedure before changing provider/model. Conversations and
bounded host tool receipts survive the change; native provider caches are not portable.
OpenRouter shows host activity during tool calls and displays only the terminal answer;
token streaming is not implemented. Tool receipts remain available for recovery.
Additional test/security/deployment executors are not enabled by changing the chat provider.

**Web chat.** After [dedicated runtime setup](../../elixir/README.md#web-board-and-chat),
select the project in the top header and sign in through the configured
browser provider. Chat stays open beside the board. Each card has one durable conversation;
selecting a card switches to it, and closing its details keeps that chat selected.
**Project name · Project agent** in the issue picker opens the project's orchestration conversation for reports, task creation,
updates and cancellation. Write proposals still require confirmation of the exact action.
The headline picker groups issues by activity category, with Done last, and sorts each
group newest first. Rows show creation date, priority, PR count and latest update;
exact timestamps are available on hover. Search a category, issue number, title or
recent activity. Each issue appears once; there is no duplicate footer.
The full-width **Pull requests** selector lists only GitHub-linked or Symphony-published
PRs for the issue. Incidental mentions are excluded. Search by number, title or status;
a published PR's retained work session opens its details on the card.
Switching cards preserves each conversation's draft. Board chat shows messages and
actions directly, while task details and PR work stay on the card. Prior conversations remain
available through the full-page `/chat` history with search, pins and ordering.

Responses appear as they arrive. Send follow-ups while a response is running to queue
up to 20 messages. The queue above the composer shows what will run next; **Send next**
changes that order and **Remove** cancels a waiting message. Each conversation runs one
message at a time, within the service-wide concurrency limit. Cards show **Chat processing**
and the number queued, separately from the coding task's execution state.
**Stop** interrupts the chat response, not a coding task, and pauses queued messages.
Failure or service restart also pauses the queue; **Resume queue** checks current access
before continuing. Closing the browser leaves accepted turns running.

Codex handles its native compaction; OpenRouter receives bounded saved source context.
The app retains visible messages, tool receipts and per-turn provider/model metadata.
In the full-page chat, **Sources** shows retrieved references; **Outputs** shows up to 100 distinct issue/PR
artifacts and action results, with earlier tool results retained in history. Task and
main conversations keep the same identity across reconnects and restarts. The current
service supplies one configured project; additional controllers are not aggregated yet.

**View context.** The full-page chat's **Context** tab shows what automatically accompanies the next
message: project, filters, displayed task count and selected card. Earlier snapshots
remain attached to their messages. Current
context refreshes as you filter, scroll, switch lanes or open a card.
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
queue/unqueue tasks locally and request native pause/drain/resume/cancel/retry.
Fresh open, unqueued Backlog tasks with no hold or active execution can be queued
directly after confirmation. Editing, unqueueing, and queueing an already cancelled
task preserve the existing cancelled, idle requirement. Queueing a cancelled task
retains its hold; retry is a separate action. Local routing retains dependency, budget,
capacity and host launch gates. GitHub receives only the configured intake labels.
Creating a task requires explicit intake labels in the tracker configuration so a new
unlabeled issue cannot launch itself.
Feedback is saved to the GitHub issue; it is not injected into an active coding turn.
To work on a separate PR, ask the issue chat to create a PR work session with its scope
and acceptance checks, then confirm the preview. To address review feedback or CI,
ask it to continue that session and confirm the new instruction. The builder resumes
its retained thread and checkout; each candidate receives a fresh independent review.
Sessions share the issue budget and run one at a time. They do not bypass local routing,
holds, controller mode or launch gates. A completed candidate needs explicit continuation;
Retry alone does not rebuild it. Existing PRs are not automatically adopted, and CI failures
do not automatically start repairs. Deployment, merge and direct input into a running
worker are not chat actions. External GitHub edits can still race the final issue patch; refresh and
review the issue after changes.

| Read tools | Confirmed workflow actions |
| --- | --- |
| Current view, project status, task search, task details with PRs/CI and retained work, project documents | Create/edit task, feedback, queue/unqueue, pause/drain/resume, cancel/retry, create/continue PR work |

The separate read-only preview shows the panel's availability state but does not
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

## Workspace service

The workspace owns one public listener, browser session broker and supervised private
project engines. Engines use owner-only Unix sockets, retain their existing state and
keep their own native schedulers. The publication watcher remains a separate child
only for a project with an explicitly enabled existing watcher.

Prepare an owned mode-0600 workspace configuration after all projects are initialized:

```json
{
  "public_origin": "http://localhost:8778",
  "bind_host": "127.0.0.1",
  "state_dir": "/absolute/private/workspace-state",
  "projects": [
    {"config": "/absolute/events-concierge/config.json", "publication": true},
    {"config": "/absolute/symphony/config.json", "publication": false}
  ]
}
```

Project `api_url` values become `http://127.0.0.1:8778/projects/<slug>`. Existing project
workflow identity policies must match; the workspace supplies the shared public origin.
Register one Google callback: `http://localhost:8778/auth/google/callback`. Keep each
project's token, ledger, chat store, baseline and launch/merge gates unchanged.

**Activate a tested release:** install `tools/requirements.txt`; drain and settle all
native work, retries, chat responses, queued reports and unknown action outcomes.
Back up configuration/state, stop the old project launch agents and archive their
plist files outside `~/Library/LaunchAgents` so they cannot return at login. Then start
one service:

```sh
python3 tools/symphony_workspace.py --config /absolute/workspace.json check
python3 tools/symphony_service.py --workspace-config /absolute/workspace.json install
python3 tools/symphony_service.py --workspace-config /absolute/workspace.json start
python3 tools/symphony_service.py --workspace-config /absolute/workspace.json status
```

Check both project-scoped control snapshots and switch between project tabs after one
sign-in. No listener should remain on 8779. Startup waits up to three minutes per engine,
with each health request bounded to five
seconds or the remaining deadline. The listener stays unavailable until every engine
reports healthy. A slow cold start changes no admission policy or project state.
The workspace has an exclusive owner lock; another launch cannot replace live sockets.
Each guard monitors a private parent pipe;
the native engine inherits only the ownership lock, never that pipe. Abrupt gateway
death stops its exact process group before a replacement can take ownership. Guard-only failure is
cleaned before engine restart, keeping the group leader unreaped until cleanup.
If both supervisors die together, a surviving engine retains the lock and replacement
fails closed. Settle its ownership manually before restarting; never delete the lock
or unlink its socket to force a replacement.
An engine failure returns an unavailable
response until its supervised restart. Broker failure denies authorization. Logout
revokes the shared grant; each active view rechecks it. Workspace restart signs out
browsers; durable project conversations remain.

For legacy acceptance bound to an old runtime fingerprint, stop all ledger owners and
use `mix acceptance.recover_legacy --help` from the reviewed release's `elixir/` directory.
Recovery needs no live workflow or API credentials; its isolated Python lock removes the inherited environment.
Select explicit issue IDs, the original fingerprint and the stopped ledger revision.
Run the default dry run first, then `--apply --backup /absolute/new-private-backup.json`,
and repeat the dry run. Recovery validates retained evidence and adds only stable project
identity; it preserves decisions, commands, revisions and budgets. Keep the exact-byte
backup. An older build cannot read the new field; never restore a stale backup over
subsequent operator changes. An uncertain persistence result requires inspection before restart.

Use the same service command with `stop` only after settling all work. The command
refuses active native work or retries; unavailable snapshots require investigation.
A direct OS kill can interrupt work and leaves retained state for reconciliation.
Do not start standalone project services alongside the workspace. Preserve the previous
configuration/release for rollback; restore its services only after stopping the workspace.

Keep the Mac awake and Colima/Docker running. A service PID alone does not prove task
progress. The [cloud package](../../deploy/gke/README.md) has separate release acceptance.

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
attempt allowance. Add `--renew-attempts` only for an explicitly authorized new cycle after
the previous cycle is exhausted and the failure has been resolved. Keep the same command ID
and revision after an uncertain response.
Resume permits eligible work without changing the host launch gate.
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
configuration; this Mac uses `http://127.0.0.1:8778`. Existing CLI/MCP clients handle the
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

The local control UI is part of this profile. GKE hosting and remote browser access
have a separate [deployment contract](../../deploy/gke/README.md); a Slack command/reporting
integration is not implemented. GitHub retains issue and PR content; the local ledger
retains workflow decisions until an explicitly verified cloud ownership cutover.

## Task and publication contract

GitHub supplies issue content; Symphony owns local task routing. An open issue enters
execution through Work (or `symphony:ready` before its first local decision). Include a
bounded outcome, scope and acceptance criteria. Dispatch requires exactly one
`Depends on: none` or `Depends on: #12, #34 (technical: required schema)` declaration
(at most 20 distinct same-repository issues). Types are delivery, design, technical or process;
reasons are bounded to 160 characters. Missing targets, cycles and prerequisites lacking
local human acceptance hold dispatch. Priority orders eligible tasks and creates no dependency. Existing arbitrary Codex CLI sessions are not adopted.

Managed task checkouts are standalone clones without submodules or nested repositories.
Host validation and hooks reject Git worktree indirection, executable Git configuration,
metadata links and alternate object stores after acquiring the workspace lock. A rejection retains the checkout for review;
do not remove the guard to resume it.

The builder writes and commits only its assigned workspace. A fresh reviewer checks
the same SHA in a separate checkout. The host retains the handoff and holds the issue;
workers cannot publish, close tasks, change labels, merge or deploy. The host publication
broker checks that evidence, publishes a scoped branch and creates a draft PR. Receipts
retain its confirmed publication state and support retry after an uncertain write.
PR work uses a distinct `codex/gh-<issue>-<work-id>` branch and publication receipt.
For host publication/recovery, select it with `publish ISSUE --work-id WORK_ID` or
`inspect ISSUE --work-id WORK_ID`; `reconcile --issue-id ISSUE --work-id WORK_ID`
rechecks only that work. Use these subcommands with the existing host publication
command and configuration. A lost acknowledgment is reconciled against its exact
candidate and PR identity. Missing retained runtime state, changed remote heads or
baselines, and dirty/advanced workspaces stop continuation; preserve them for recovery.
If startup stops after the thread identity is saved but before Codex writes its first
turn, that empty thread may have no resumable history. Retry does not invent a new
identity or overwrite its state. Preserve the failed session, inspect its scope and
checkout, and explicitly create replacement work after resolving the issue hold.

Automatic merge additionally requires host enablement, `symphony:auto-merge`, an explicit
low-risk path/size allowlist, a clean independent review, a protected chosen base branch,
known required checks from pinned GitHub Apps, and matching remote head/base revisions.
Missing evidence blocks it. The user approves deployments separately. A merge is not
proof of deployment or runtime acceptance.

This profile uses an explicitly pinned source baseline. If the integration branch
moves, publication stops for stale candidates. Automatic rebase and baseline advancement
are not implemented; review and update the pin before another delivery, including after
a merge to `main`. Overlapping candidates do not gain permission to publish against a
changed base merely because their checks passed.

## Update the local Symphony release

- Integrate the intended changes into `main` before release. Merging a child PR into
  a feature branch does not deliver that change to `main`.
- Build and test a pinned `main` commit in a retained release checkout. Run every
  local project controller and its installed publisher from that same commit.
- For each existing private configuration, drain, wait for workers and chat turns to
  finish, then pause and stop its installed agents using the current release. Use
  the explicit `--config` path; verify the agents are unloaded before replacing them.
- Preserve the previous release and private configuration, workflow, ledger, feedback journal, receipts
  and chat state for recovery. Point `profile_bin` and the reviewed launch-agent
  program paths and working directory at the new release. Keep the same origins,
  credentials, gates and state directories; leave uninstalled publishers disabled.
- A controller update does not change a task's source baseline. Preserve `base_sha`
  and `integration_branch` unless separately performing the baseline procedure below.
  Do not run profile initialization over an existing installation.
- Run the project's `profile.py doctor`, start only its previously installed agents,
  and verify the release commit, repository, retained tasks/chat and paused API state.
  Restore a previously running controller only after validation and within the existing
  launch authorization. Keep projects that were paused paused.

## Change the baseline

Run the commands below from the installed Symphony checkout. Use the existing private
configuration and state directory; do not initialize a replacement profile or delete
the ledger, locks, receipts or retained workspaces. A configuration change does not
authorize worker activation, broader permissions, automatic merge or deployment.

1. Review the intended `main` revision and reconcile its `AGENTS.md`, `ARCHITECTURE.md`,
   `WORKFLOW.md` and task template with the current application. Verify the full SHA
   against GitHub and fetch its committed objects into the configured `source_path`
   without checking out or discarding unrelated local work. Resolve outstanding old-base
   candidates explicitly; changing the pin cannot reuse their prior review.
2. Read `python3 tools/symphony_control.py status`, then run
   `python3 tools/symphony_control.py drain --revision CURRENT_REVISION` with the observed
   `control.revision`. Wait for running/retrying work and process cleanup to finish;
   unavailable status means unknown ownership, not idle. Re-read status, then run
   `python3 tools/symphony_control.py pause --revision CURRENT_REVISION` with its new
   revision and confirm paused mode. Drain stops new dispatch; pausing after completion
   also stops automatic publication.
3. Run `python3 tools/symphony_service.py stop`, then
   `python3 tools/symphony_service.py status`; both controller and publisher must be
   unloaded. The controller captures its base SHA at startup, while the publisher
   reloads configuration during each pass. Do not change the pin while either is running.
4. In the existing private `config.json`, set `integration_branch` to `main` and
   `base_sha` to the reviewed full SHA. Preserve all other settings, including the
   current worker-launch gate and disabled automatic-merge gate. Review the private
   `workflow_path` against the new committed workflow and reconcile intentional runtime
   settings; do not overwrite browser/chat configuration, budgets or concurrency with
   template defaults. Keep `control.base_sha: $SYMPHONY_BASE_SHA`. Preserve private file
   ownership and mode `0600`; never print credentials or commit runtime files.
5. Run `python3 profiles/events-concierge/profile.py doctor`, then
   `python3 tools/symphony_service.py start` and
   `python3 tools/symphony_control.py status`. Confirm the intended baseline and branch,
   unchanged gates and retained evidence, healthy service/API state and **paused** mode.
   `initial_mode: paused` only initializes new state; the pause recorded before stopping
   is what prevents an idle existing profile from resuming on restart.
6. Keep the profile paused until source, workflow and runtime validation is complete.
   Re-read status immediately before an authorized
   `python3 tools/symphony_control.py resume --revision CURRENT_REVISION`, then verify
   the result. Rebuild and independently review any candidate carried onto the new base;
   retain completed task receipts and budgets without retrying them merely to migrate.

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

In the private workflow identified by `workflow_path`, set `codex.read_timeout_ms`
to `30000` for container startup. This allows 30 seconds for app-server protocol
acknowledgements; keep the task's overall runtime budget unchanged. Restart the
scheduler after editing its workflow, with active work settled and the existing
control ledger preserved. The disposable probes use the same initialization limit;
command and cancellation acceptance deadlines remain separate.

Controlled startup errors identify `initialize`, `worker_auth`, `thread_start` or `turn_start` and
retain the original failure reason. Logs record per-phase `elapsed_ms`, the worker
role and available issue/thread identifiers without adding protocol payloads. Use
these fields to locate a timeout before changing limits; a missing turn
acknowledgement does not prove that model work never began.

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
