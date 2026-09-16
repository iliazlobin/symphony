# Symphony on GKE

The deployed Symphony application must include the shared project-board and management-chat implementation. Its identity is the accepted source and functionality, independent of any local port, hostname or ingress address. The Mac controller and publisher remain the active task owner until cloud execution and the complete web package pass their integration checks.

## Required application package

The [application Dockerfile](application.Dockerfile) builds the shared board, management chat and Settings together with the cloud code. It compiles the full normal OTP application and checks embedded routes, modules and assets. The current infrastructure overlay does not yet deploy this application; publish and pin a reviewed image digest before deployment.

- **Web application:** the Phoenix `DashboardLive` project board, task details, multiple PRs per issue, Settings, `ChatPanel` on the right, standalone `ChatLive`, validated board-view context and existing workflow actions. Keep its router, browser session boundary, GitHub projections and control API together.
- **Management chat:** normal application supervision of `Chat.Store`, persistence, runtime and bounded dynamic tools. Retain private `chat.state_path` and a dedicated `chat.codex_home`; configure the accepted chat executable, timeout and concurrency. Chat state/authentication is separate from builder/reviewer authentication slots and must have a single owner.
- **Build inputs:** compile the complete accepted Elixir source and its `mix.lock`. `StaticAssets` embeds CSS, JavaScript, favicon and Phoenix dependency assets at compilation; copying an older service binary does not include new UI code. No separate frontend npm build is required.
- **Runtime dependencies:** provide Python for the process guardian and the management-chat Codex version required by the accepted source. The published chat runtime pins Codex `0.154.0` and `gpt-6-astra`; the worker image's `0.153.4` pin is a separate contract. Use the native Linux Codex executable or verify a portable launcher: the published chat environment omits `/usr/local/bin`, where common Node images install Node. Do not silently change either role's version or reuse Mac authentication.

`tools/symphony_web.py` is a read-only local preview that explicitly disables chat. It is not the application deployment entrypoint. A port number, static board render or healthy observability endpoint is not evidence that the full package is present.

**Release acceptance:** verify that the built Linux image includes the board/chat modules, `/` and `/chat` routes, embedded assets and supervised chat store. Run the existing dashboard, chat, persistence, workflow-integration and browser-control tests, plus a no-model Codex version/initialization smoke test inside that image. After cloud authentication and access are implemented, verify task/PR views, chat/context/actions and conversation persistence through restart from the deployed browser. The current `BrowserAuth` is loopback-only; establish the reviewed remote identity/session boundary before exposing management actions. Keep cloud activation blocked if any required component is absent.

## Build and integration check

Build the Linux amd64 application from a committed source archive. The image records that source revision and includes the official checksum-pinned native Codex package and its helpers. It contains no workflow, tokens, personal configuration or authentication records.

```sh
symphony_revision=$(git rev-parse HEAD)
symphony_context=$(mktemp -d)
git archive "$symphony_revision" | tar -x -C "$symphony_context"
docker build --platform linux/amd64 --build-arg SOURCE_REVISION="$symphony_revision" \
  -f deploy/gke/application.Dockerfile -t "symphony-application:$symphony_revision" "$symphony_context"
symphony_image=$(docker image inspect --format '{{.Id}}' "symphony-application:$symphony_revision")
python3 tools/probe_gke_application.py --image "$symphony_image"
```

The [package probe](../../tools/probe_gke_application.py) starts the actual application twice using one disposable labelled volume, no external network, no provider credentials and a paused empty ledger. It exercises loopback browser authentication and real LiveView messages, creates a chat, checks the native Codex missing-sign-in response, and recovers the conversation in standalone and board chat after restart. It checks embedded assets and cleans up only its own containers and volume. This is HTTP/LiveView protocol acceptance, not visual browser acceptance, an authenticated model turn or GKE execution.

The image entrypoint is `serve --workflow /config/WORKFLOW.md --state-root /var/lib/symphony`. An operator supplies the explicit GitHub workflow and a retained writable state mount. The [entrypoint](application_entrypoint.py) requires enabled controls starting paused, an already-paused journal without active claims, enabled chat with one concurrent writer, a dedicated retained chat home, and loopback HTTP access. The pilot also requires `codex.command: /bin/false`, no workspace hooks and no SSH workers, so resuming controls cannot enable coding execution. It never rewrites an active journal or imports a Mac home. `chat.state_path`, `chat.codex_home` and `control.state_path` must remain distinct under the retained mount; keep their absolute paths stable across replacement. Use a regular read-only file mount for the workflow. Mounted configuration links are deliberately rejected.

The first subscription login and authenticated model test remain separate acceptance gates. Browser sessions are renewed after application restart; durable conversations remain. Docker published-port traffic does not satisfy the current loopback peer check, so the protocol probe runs inside the container. Do not expose this pilot through ingress or change the browser boundary to bypass that check.

## Ownership and retained resources

The shared platform repository owns the private cluster, network, worker pool and `shared-retain` StorageClass. This repository owns the [image repository and state bucket](terraform/main.tf), namespace policies, retained 10 GiB RWOP journal and future application workloads. Keep the journal even while no cloud controller is deployed. Retained storage is not a backup or proof that an unreachable old process has stopped.

The [platform-dev overlay](../environments/platform-dev/kustomization.yaml) currently manages the controller and worker namespaces, default-deny policies, worker identity and retained journal only:

```sh
kubectl config current-context
kubectl kustomize deploy/environments/platform-dev
kubectl diff -k deploy/environments/platform-dev
kubectl apply -k deploy/environments/platform-dev
kubectl -n symphony get pods,pvc,networkpolicy
```

Use the existing platform private-access runbook and an explicitly verified Kubernetes context. Do not use `kubectl delete -k` as cleanup: namespace or PVC deletion can remove retained state. Never force-delete a worker or detach its volume to bypass uncertain ownership.

## Infrastructure as code

The [Terraform root](terraform/main.tf) creates the private Artifact Registry repository, repository-scoped node pull grant and protected state bucket. It uses [pinned Terraform/provider versions](terraform/versions.tf). No model credentials enter Terraform. Existing installations copy the [backend template](terraform/backend.tf.example) to ignored `backend.tf`, initialize the existing remote backend and review a saved plan:

```sh
umask 077
test -e deploy/gke/terraform/backend.tf || cp deploy/gke/terraform/backend.tf.example deploy/gke/terraform/backend.tf
terraform -chdir=deploy/gke/terraform init
terraform -chdir=deploy/gke/terraform plan -out=reviewed.tfplan
terraform -chdir=deploy/gke/terraform show reviewed.tfplan
```

For a fresh environment only, create the three application resources with local state before configuring the destination backend; preserve a recovery copy and use `terraform init -migrate-state` for this root only. Verify the three resources in remote state and a no-change plan. Never migrate shared-platform state. Runtime applies require scoped authorization; do not overwrite an existing backend configuration.

## Runner and authentication implementation

These are standalone components under test, **not an enabled cloud task path**:

- [`kubernetes_runner.py`](../../tools/kubernetes_runner.py) pins the cluster, namespace/PVC identities and image; journals launch intent; creates one bounded Job; validates admitted Pods; and checks the worker identity handshake before forwarding App Server input. Lost transport is not reattached. Cancellation retains exact terminal Job/Pod evidence; missing objects or an expired lease do not release ownership.
- [`kubernetes_auth.py`](../../tools/kubernetes_auth.py) owns an exclusive subscription slot at `/var/lib/symphony-auth/slot-01` on a retained RWOP volume. It atomically moves the single current credential file into a fresh stage home after verified termination. Codex manages login and refresh. No credential snapshots, Mac-home copying, shared parallel refresh writers or API-key fallback are supported.
- [`probe_kubernetes_permissions.py`](../../tools/probe_kubernetes_permissions.py) emits a disposable, ten-minute gVisor fixture and probes the exact running Pod with fake credentials and no model turns. It checks builder/reviewer command permissions, Git/tool usability, protected paths, process aliases and network denial. It is not a cancellation or end-to-end acceptance test.

Install the [Python dependencies](../../tools/requirements.txt) in an isolated environment. Run each helper with `--help` for its bounded interface. The runner's configuration and intent must be private operator-owned files outside the checkout. `launch` additionally requires the reviewed fixed `/opt/symphony/worker_entrypoint.py`, immutable workspace staging and auth admission; that image entrypoint and controller integration are not implemented. Do not point the live `codex.command` at this adapter yet.

The required entrypoint emits one identity line before Codex starts: `{"symphony_worker":{"owner":"<nonce>","generation":1,"job_uid":"<UID>","pod_uid":"<UID>"}}`. It must fence the exact auth claim, enforce `--expires-at` even without the controller, and stop Codex on heartbeat loss. The wrapper's successful exit establishes termination only. Candidate import must complete before `turn/completed` becomes visible to the existing candidate pipeline; the existing guardian must also gain explicit Kubernetes cancellation support. RWOP volumes cannot be mounted simultaneously by a staging Pod and a worker.

Persistent credentials survive ordinary Pod replacement. **Codex 0.153.4 truncates `auth.json` during refresh**; a crash during that write can lose usable authentication. Block dispatch and enroll again; never restore stale tokens. The slot journal does not change that upstream storage behavior. [Pinned authentication storage implementation](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/login/src/auth/storage.rs)

## Runtime blocker

The real GKE Sandbox test fails at Codex `thread/start`, before model work: `bwrap: loopback: Failed RTM_NEWADDR`. This matches [gVisor issue 13438](https://github.com/google/gvisor/issues/13438). The pinned amd64 image starts on the dedicated node, but that does not establish Codex sandbox compatibility. There is no verified configuration-only fix. Installing system bubblewrap alone is not an accepted remedy; removing network isolation or granting privileged execution is not an acceptable workaround.

Keep cloud admission and real credential enrollment disabled until a reviewed runtime fix passes the complete permission canary. The pool remains capped at one node and returns to zero when idle. Canary Pods contain disposable fake data only; terminate them gracefully, verify exact container exit, then remove the completed test resource. Preserve uncertain live-worker ownership and retained volumes.

## Remaining integration gates

- Keep admission, budgets, retries and task ownership in the existing controller. A Kubernetes Job is one bounded builder or reviewer stage, not another scheduler.
- Persist exact Job and Pod identities before releasing model work. Use independent Pod deadlines, no automatic retries and terminal-process evidence before reusing a workspace or authentication slot.
- Preserve the existing candidate pipeline's exact-revision and independent-review checks. Candidate import must complete before the controller receives successful completion. Controller loss or transport failure retains uncertain ownership.
- Enroll a dedicated cloud subscription login after real gVisor permission canaries pass. Preserve Codex-managed refreshes in an exclusive retained slot, respecting the interrupted-write limit above; never clone a Mac login, restore stale credentials or fall back to API billing.
- Complete deployed browser and authenticated model acceptance for the combined application package above, including management-chat persistence and its separate dedicated subscription home.

The worker pool is bounded to zero through one node for the pilot. Larger concurrency requires measured capacity, quota and cost review. The cloud task path remains disabled until the gates above are verified.
