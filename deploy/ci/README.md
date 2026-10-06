# Private Linux CI

The repository-scoped `symphony-ci` scale set runs Linux CI on private GKE nodes. [ARC](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets) creates a new gVisor Pod for each job and removes it afterward. GitHub still stores workflow logs, artifacts and caches; this public repository's [workflow logs and artifacts remain readable](https://docs.github.com/en/actions/how-tos/monitor-workflows/use-workflow-run-logs) by users with repository read access. This bootstrap package adds an opt-in smoke workflow; the required `make-all` and `validate-pr-description` checks stay on their existing runners until the private pilot is verified.

## Public repository admission

- Before registering runners, set GitHub's [fork approval policy](https://docs.github.com/en/rest/actions/permissions#set-fork-pr-contributor-approval-permissions-for-a-repository) to `all_external_contributors`. The installer reads that policy through the operator's existing `gh` authentication and stops on a missing, weaker or unverifiable policy before any Kubernetes or Helm operation. Keep the policy enabled while the scale set is registered; this install-time check does not monitor later settings changes.
- A fork can change workflow YAML or add a job targeting `symphony-ci`. Routing same-repository PRs to GKE and fork/Dependabot PRs to `ubuntu-latest` keeps the normal required checks running, but is **not an access boundary**. Before [approving any external workflow run](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/approve-runs-from-forks), inspect the current head's workflow files, including added jobs and reusable workflows; do not approve an external run that targets private/self-hosted runners. Do not use `pull_request_target` to execute an untrusted PR head. This personal repository has no organization-level [runner-group workflow restrictions](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/manage-access), so admission depends on this maintainer review as well as the job isolation below.
- The smoke workflow accepts only [`workflow_dispatch`](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow), which requires repository write access. Dispatch the reviewed default-branch revision; selecting an arbitrary branch is not a trust check. Keep App and operator credentials outside jobs, and keep job tokens read-only. If these approval controls cannot be maintained, drain the scale set rather than relying on workflow routing alone.

## Resources and isolation

- The platform repository owns the private `symphony-ci` node pool in `iz27-platform-dev/platform-dev`, `us-west1-a`. It starts at zero and is capped at one node. This package does not resize `shared-dev`, activate the coding pool, deploy Symphony or change application state.
- This repository owns `symphony-ci-system` for the ARC controller/listener and `symphony-ci-runners` for job Pods. The controller watches only the latter namespace; the job service account has no role bindings, token mount or cloud identity. Controller and listener request 150m CPU/256Mi in total on the separate trusted `symphony-services` pool, using its protected selector and NoSchedule toleration. Job Pods select the dedicated gVisor CI pool; they never tolerate the services taint.
- `maxRunners: 1`, a one-Pod quota and zero retained storage bound execution. Each job gets disposable runner home, checkout and temporary files. A [minimal init process](https://github.com/krallin/tini#subreaping) reaps orphaned children; both the image and Pod command invoke it. The image runs as UID 1001, with read-only root, no additional capabilities, no privilege escalation, no Docker/socket/container hooks and no model authentication.
- Network policies deny incoming traffic and allow DNS plus public IPv4 TCP 443. Private networks, Kubernetes API and link-local metadata remain denied to jobs. This is a public-HTTPS port policy, **not a hostname allowlist**; arbitrary public HTTPS is reachable. GitHub, Hex, npm and PyPI need outbound access. DNS selectors and the pinned addresses must match the actual cluster.
- The GitHub App is installed only on `iliazlobin/symphony`, with repository Administration read/write and Metadata read. Its private key lives in the pre-created `symphony-ci-github-app` Secret in the runner namespace, as [required by the chart](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/authenticate-to-the-api). ARC's trusted controller also creates a listener configuration Secret in its own namespace. Job Pods receive only their short-lived ARC JIT registration, never the App key. Keep both namespaces free of application credentials; do not grant job RBAC or mount the source Secret.
- GKE workload logging retains controller/listener and runner output after ephemeral Pod removal. Confirm collection and retention in the deployed project. Job and Pod deadlines bound execution; a stalled scale-set registration, quota denial or exhausted node capacity leaves work queued rather than increasing limits.

## Build and install

Use the existing platform [private access runbook](https://github.com/iliazlobin/gcp-foundation/blob/main/README.md) and verify the account, project, private cluster and approved platform plan. Deploy only after source review/checks and the bounded pool setup. Preserve the existing remote Terraform state and application resources.

The platform-owned `symphony-services` capacity change must be approved and deployed
before installing these trusted controls. Keep `shared-dev` fixed. The separately
owned [shared CI pool alignment](https://github.com/iliazlobin/symphony/pull/60)
must also reach approved trunk before installation against `platform-ci`; preserve
its job-pool selectors and platform-owned CRD installation contract. This placement
change grants no shared-pool migration or takeover of that release.

Build the committed [Dockerfile](Dockerfile) for Linux amd64. It pins the existing Elixir 1.19.5/OTP 28 image, official runner 2.337.0 checksum and Node 22.14.0 checksum. Publish to the existing private repository and record the resulting immutable digest and source revision in the PR/deployment evidence; tags are not deployment pins.

```sh
ci_revision=$(git rev-parse HEAD)
docker buildx build --platform linux/amd64 --build-arg SOURCE_REVISION="$ci_revision" \
  -f deploy/ci/Dockerfile -t "us-west1-docker.pkg.dev/iz27-platform-dev/symphony/ci-runner:$ci_revision" \
  --push .
```

For local amd64 validation on Apple Silicon, [Elixir documents an Erlang JIT emulation workaround](https://hexdocs.pm/mix/Mix.Tasks.Release.html#using-images): pass `ERL_AFLAGS='+JMsingle true'` to the disposable test container only. Give its temporary filesystem execute permission to match GKE's disk-backed `emptyDir`. This local workaround is not baked into the native GKE image; local results do not replace the native pilot below.

Create the dedicated GitHub App and install it only on this repository. The planned Secret Manager home is `projects/iz27-platform-dev/secrets/symphony-ci-github-app`; retain one JSON payload with `github_app_id`, `github_app_installation_id` and `github_app_private_key`. After the reviewed source and platform setup are approved, apply `deploy/ci/foundation.yaml` to create the two CI namespaces and their restrictions. Deliver those fields to `symphony-ci-runners/symphony-ci-github-app` over a private operator channel; keep values out of Git, Terraform, command arguments, logs and Helm values. Do not reuse a personal GitHub token, Codex home, model authentication volume or application credential. Verify the installed repository and App permissions without printing credentials.

Put `gh`, `kubectl` and `helm` on the operator's PATH, verify that `gh` can read this repository's Actions approval policy, and set `KUBECONFIG` to the task's private access file. Review [foundation.yaml](foundation.yaml), [controller-values.yaml](controller-values.yaml), [runner-values.yaml](runner-values.yaml) and [versions.json](versions.json). The install helper verifies external-contributor approval, the context, API/DNS service addresses and downloaded chart checksums before applying CI resources. It accepts only the private registry's reviewed digest and supplies it to both init and runner containers; the source placeholder cannot be deployed through this helper.

```sh
deploy/ci/install.sh 'us-west1-docker.pkg.dev/iz27-platform-dev/symphony/ci-runner@sha256:<reviewed-digest>'
```

ARC 0.15.0 is pinned by both OCI and archive digests. The controller image is also pinned by digest. Initial install uses the chart CRDs; upgrades must inspect CRD changes and follow [ARC's upgrade procedure](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets#upgrading-arc). Rotate the runner image when GitHub requires/security updates it; rebuild and reverify the same boundaries.

## Verify and operate

1. Confirm controller and listener are Running on `symphony-services`, no idle runners, and the scale set's repository URL/name/max/min. Inspect rendered Helm roles: the controller may manage CI resources only; the job service account must not have secret, Pod, exec or cloud access.
2. After the bootstrap workflow is merged to the default branch, start the [private-ci-smoke workflow](../../.github/workflows/private-ci-smoke.yml) on the reviewed revision. The first job verifies the actual tools, UID, capability restrictions, absent privileged paths, DNS/HTTPS and denied API/metadata, then leaves a file. The second job repeats the checks and requires that file to be absent. Check distinct runner names and Pod UIDs, the exact image digest, gVisor RuntimeClass, dedicated node, absence of SA token/App key mounts, and removal of both runners/Pods. The workflow's checks are not independent Pod admission evidence; inspect the actual Pod manifests from the operator API.
3. After the queue drains, verify zero runner Pods and registrations, and the CI pool's managed instance-group target returning to zero. Autoscaler removal is delayed; do not delete a running node to claim cleanup. Confirm application/coding workloads and retained volumes are unchanged.
4. Open a separate routing PR for the two required jobs: use `symphony-ci` for pushes to `main` and same-repository PR heads from trusted writers; route fork and Dependabot PRs to `ubuntu-latest`. Retain the job names, triggers and full `make all`, Python and asset checks on both paths; never skip an untrusted job into a successful required check. Keep mise tool setup and existing cache steps only on hosted runners. On GKE, use the image's pinned tools, direct `npm` commands and `python3 deploy/ci/probe_runner.py`; the probe's UID and filesystem checks do not apply to hosted runners. Set `permissions: contents: read`, checkout `persist-credentials: false`, bounded timeouts and PR-description temporary files under `RUNNER_TEMP`. Require real executions of both routing paths, cold GKE compilation timing/memory evidence, independent Copilot review and all checks before merging this routing change. A timeout or failed check remains a failure; preserve branch protection and human task acceptance.

Use `kubectl -n symphony-ci-system logs deployment/symphony-ci-controller`, `kubectl -n symphony-ci-system get pods` and `kubectl -n symphony-ci-runners get pods,events` for failure diagnosis; logs can contain job code output and must remain private. Preserve failed check evidence. For maintenance, set both Helm `minRunners` and `maxRunners` to zero, wait for active work and runner cleanup, then update only the reviewed CI release. A rollback uses the prior image/chart digests; never delete namespaces, credentials or retained application resources as cleanup.

Before reverting service placement, establish enough capacity for the controller,
listener and application. Do not silently return them to an overcommitted shared
node or delete a services node with live owners. Retain the services pool until all
assigned owners are removed through their normal recovery procedures.

Linux CI activation does not make every workflow private. [Release verification](../../.github/workflows/burrito-release.yml) still includes native macOS and Linux ARM checks on their existing runners. Migrate them only after private runners for those architectures exist and pass the same tests; do not remove or relabel their evidence. Repository billing/service holds may prevent dispatch before a runner is assigned even when GKE is healthy.
