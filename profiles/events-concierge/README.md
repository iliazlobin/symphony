# Events Concierge on the Mac

This profile connects GitHub Issues to one builder and a separate reviewer. Symphony
owns scheduling; the native API owns controls; the small MCP client forwards those
controls. See the [architecture](../../ARCHITECTURE.md) for boundaries and code ownership.

## Setup

Use Elixir 1.19.5 / OTP 28 from `elixir/mise.toml`, Python 3.9+ with
`tools/requirements.txt`, Git, GitHub CLI and Codex 0.144.6. Authenticate GitHub CLI as
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

Start the service in the foreground with `python3 profiles/events-concierge/profile.py run`.
The private dashboard is `http://127.0.0.1:8777/`. The initial mode is paused. Worker
launch has a separate host gate and remains disabled until isolation, cancellation,
authentication and a bounded pilot have passed. A resume request alone cannot enable it.

For persistence after closing the terminal, install and load the two user launch agents:

```sh
python3 tools/symphony_service.py install
python3 tools/symphony_service.py start
python3 tools/symphony_service.py status
```

Use `python3 tools/symphony_service.py stop` to unload both services. The publication
process watches completed handoffs; it does not schedule coding tasks. Keep the Mac
awake and Colima/Docker running. GKE deployment is a separate, unimplemented cutover.

```sh
python3 tools/symphony_control.py status
python3 tools/symphony_control.py drain --revision CURRENT_REVISION
python3 tools/symphony_control.py pause --revision CURRENT_REVISION
python3 tools/symphony_control.py cancel ISSUE_ID --revision CURRENT_REVISION
python3 tools/symphony_control.py retry ISSUE_ID --revision CURRENT_REVISION
python3 tools/symphony_control.py resume --revision CURRENT_REVISION
```

Read status before a change. Reuse `--command-id` after an uncertain response; a stale
revision is rejected. Pause interrupts active work and blocks dispatch; drain lets the
current bounded pipeline finish. Cancel holds the issue. Retry preserves consumed budget.
An unavailable API means status is unknown. It does not mean workers stopped.

Add a **management-only** stdio MCP server using an absolute interpreter and source path:

```sh
codex mcp add symphony -- python3 /path/to/symphony/tools/symphony_control.py mcp
```

It exposes `symphony_status`, `symphony_issue` and `symphony_control`. Never install the
management MCP server in the worker home. New MCP configuration requires a new or
reloaded management session; writing configuration does not connect an existing session.

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

The worker image matches the application's Python 3.12 / Node 22 toolchain:

```sh
docker build -f profiles/events-concierge/Dockerfile.worker -t symphony-codex:0.144.6 .
docker image inspect symphony-codex:0.144.6 --format '{{.Id}}'
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

`tools/probe_container_permissions.py` checks the pinned Linux worker without real
credentials or model calls. It verifies builder permissions, reviewer permissions on
both writable and read-only outer mounts, and reachable positive controls before
checking file and network denial. Container cancellation probes require fresh parent/child
heartbeats and container removal within 10 seconds, before their 60-second expiry.

**Activation prerequisites:** Linux permission and cancellation canaries pass with an
exact-path diagnostic AppArmor candidate. Docker's default policy still blocks Codex's
inner sandbox mounts. The temporary profile was unloaded; no worker AppArmor policy is
shipped, installed or selected by the service. The probes accept an explicitly reviewed
`--apparmor-profile symphony-codex` only alongside the existing seccomp candidate;
`--fixed-root` selects the cancellation probe's exact disposable fixture and refuses
existing state. The permission probe uses that fixture automatically.

Saving and installing a policy limited to the configured Symphony workspace root and
finite runtime paths, then wiring the launcher, needs focused approval. Revalidate
that operational configuration before a bounded issue-to-PR pilot. Dedicated worker
sign-in is verified; the pilot has not run. Keep ordinary dispatch and automatic merge
disabled while these gates are unresolved.

Retain failed workspaces and GitHub records. Do not delete the ledger or lock to reset
budgets or force ownership. Restart conservatively holds interrupted work. Resolve any
uncertain container/process ownership before retry; do not run two dispatchers for the
same profile. No application Compose stack, retained database, GCP resource or deployment
is started or changed by this profile's generic task hooks.
