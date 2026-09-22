# Symphony project

Symphony manages its own GitHub issues and PRs through the same board, chat, candidate
review and publication path as an application project. The repository is
[iliazlobin/symphony](https://github.com/iliazlobin/symphony); the initial settings task is
[#27](https://github.com/iliazlobin/symphony/issues/27).

## Ownership

| Input or state | Symphony project |
| --- | --- |
| Versioned execution policy | [Root WORKFLOW.md](../../WORKFLOW.md) |
| Source and PR base | Explicit reviewed commit on `main` |
| Browser origin | `http://localhost:8779` |
| Private configuration | `~/Library/Application Support/Symphony/symphony/config.json` |
| Launch agents | `com.iliazlobin.symphony.symphony` and `.publication` |
| Worker policy | `symphony-self-codex`, scoped to this project's workspaces |
| Initial state | Paused; worker launch and automatic merge disabled |

- Each controller owns one repository, token, ledger, workspace root, worker home,
  receipts and chat store. Issue numbers are repository-scoped.
- **Projects** opens the configured project's board. Navigation does not combine
  controller state or carry authentication, task selection or chat authority across projects.
- The distinct session cookie keeps project sign-ins from replacing each other on
  `localhost`. Each Google origin still requires its own valid callback configuration.
- Existing PR enrichment associates GitHub issues with their linked PRs, current-head
  checks and review evidence. An unlinked PR is not inferred to belong to a task.
- Shared Docker resources and account limits have no global admission coordinator.
  Keep the new project paused until aggregate capacity and its worker boundary are verified.

## Initialize after review

Run from a release containing this profile. Pin a reviewed `main` commit that includes
root `WORKFLOW.md`; initialization reads the committed policy and refuses existing state.

```sh
python3 profiles/symphony/profile.py init \
  --source /path/to/symphony --base-sha FULL_REVIEWED_MAIN_COMMIT \
  --integration-branch main
python3 profiles/symphony/profile.py doctor
```

Initialization creates private configuration only. It does not install a service,
create credentials, add queue labels or launch a worker. The initial Google allowlist
is empty and therefore denies sign-in until the operator configures access.

## Activate the board

- Configure the private workflow's Google allowlist and set `google_oauth_client_file`
  in its private `config.json`. Register `http://localhost:8779/auth/google/callback`
  on the approved Google web client. Do not copy owner credentials into a worker home.
- The launcher supplies private `chat` and `management-codex` directories for this
  project. Native task intake uses that store without a model login. For chat turns,
  set `management_codex_binary` to the pinned management executable and authenticate
  this fresh home using the [chat setup](../../elixir/README.md#web-board-and-chat).
  Browser identity and model authentication are separate.
- After approval to start this controller, install and start its launch agents with
  the explicit new configuration:

```sh
python3 tools/symphony_service.py --config "/path/to/symphony/config.json" install
python3 tools/symphony_service.py --config "/path/to/symphony/config.json" start
python3 tools/symphony_control.py --config "/path/to/symphony/config.json" status
```

Verify repository identity, paused mode and disabled launch/merge gates. Check Google
sign-in, the settings issue, its card links and linked PR evidence on the new board.

For navigation from Events Concierge, add the root workflow's `server.project_links`
list to that project's private workflow during its approved configuration update.
Keep its existing `server.session_cookie` default. These are browser links, not remote
control endpoints; destination auth is checked independently. Replacing a controller
binary or changing authentication still requires its normal approved restart.

## Enable implementation work

- Build and pin a dedicated worker image containing Elixir 1.19.5 / OTP 28, Python,
  the approved Codex runtime and cached project test dependencies. The Events Concierge
  Python/Node image does not establish Symphony's Elixir test readiness.
- Install managed rules and authenticate the new dedicated worker home through the
  [shared setup procedure](../events-concierge/README.md#setup).
- Render the worker policy with `python3 tools/worker_policy.py --workspace-root PATH
  --profile-name symphony-self-codex`. Review, install and verify this distinct profile;
  never replace Events Concierge's `symphony-codex` policy.
- Run the existing permission/cancellation probes with the new `--operator-config`.
  Verify combined host capacity before enabling launch and resuming a bounded pilot.
- Queue tasks with `symphony:ready` only after execution activation. The publisher
  targets this repository and its pinned `main` baseline; keep automatic merge disabled.
- The self-project publisher follows this repository's PR template and description checks.
- Settings task #27 remains in Backlog. Its future editor must distinguish runtime
  concurrency overrides from reviewed policy changes and verified activation.

A Symphony PR changes a candidate checkout, not the running controller. Review and
merge do not restart the service. Deploy a tested release separately, preserve each
project's state, and follow the [baseline and recovery procedure](../events-concierge/README.md#change-the-baseline)
using this project's profile entrypoint and explicit configuration path.
