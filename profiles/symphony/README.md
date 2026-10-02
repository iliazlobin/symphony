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
| Browser address | `http://localhost:8778/projects/symphony/` |
| Private configuration | `~/Library/Application Support/Symphony/symphony/config.json` |
| Workspace service | `com.iliazlobin.symphony.workspace` |
| Worker policy | `symphony-self-codex`, scoped to this project's workspaces |
| Initial state | Paused; worker launch and automatic merge disabled |

- Each controller owns one repository, token, ledger, workspace root, worker home,
  receipts and chat store. Issue numbers are repository-scoped.
- The workspace owns one public origin and browser grant. Project selection changes
  the explicit `/projects/<slug>/` scope; two tabs remain independent.
- Private project engines retain separate ledgers, stores and native schedulers.
  Engine restart preserves the workspace grant; workspace restart requires sign-in.
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

Use the [shared workspace service](../events-concierge/README.md#workspace-service).
Register only `http://localhost:8778/auth/google/callback` on the reviewed Google web
client. Every project must use the same admitted browser identity policy. Browser
identity and OpenRouter credentials remain separate from native worker authentication.

Keep private state paths, paused mode, baseline and disabled launch/merge gates
unchanged when adding this project. Its control client uses
`http://127.0.0.1:8778/projects/symphony`. Switching projects does not authorize execution.

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
project's state, and follow the [local release update procedure](../events-concierge/README.md#update-the-local-symphony-release)
using this project's profile entrypoint and explicit configuration path. Changing a task's
source baseline is a separate [operation](../events-concierge/README.md#change-the-baseline).
