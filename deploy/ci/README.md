# GitHub Actions on private GKE

`symphony-linux` is Symphony's repository-scoped [ARC](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets) scale set on `iz27-platform-dev/platform-dev`, `us-west1-a`. Each Linux job receives a new unprivileged gVisor Pod. Source/configuration establishes the intended boundaries; actual GitHub jobs and operator Pod checks establish activation.

## Public repository admission

- Keep GitHub's [fork approval policy](https://docs.github.com/en/rest/actions/permissions#set-fork-pr-contributor-approval-permissions-for-a-repository) at `all_external_contributors`. Both installer modes verify this before any Kubernetes operation, then verify the exact public repository ID, operator, private TLS/IAP context, approved pools and control capacity before namespace writes. This does not monitor later policy changes.
- Required `make-all` and `validate-pr-description` jobs use GKE only when repository variable `SYMPHONY_GKE_CI=enabled` and the event is a push to `main` or a same-repository PR from a trusted writer. Fork and Dependabot PRs use `ubuntu-latest`; all required coverage and job names remain. Leave the variable absent until native acceptance; remove it to restore hosted routing for subsequent required jobs.
- Forks can modify workflow YAML and target `symphony-linux` directly: routing is **not admission enforcement**. Before [approving an external run](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/approve-runs-from-forks), inspect current workflow changes and reusable workflows; never approve outside runs targeting self-hosted/GKE runners. Never execute an untrusted PR head with `pull_request_target`. This personal repository lacks organization runner-group workflow restrictions, so trusted maintainer review is part of admission. Drain the scale set if that review cannot be maintained. [GitHub warns against public self-hosted execution](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners).
- Manual dispatch requires repository write access; select a reviewed revision. Public logs/artifacts remain public even when compute is private.

## Roles and boundaries

- `gcp-foundation` owns the shared private `platform-ci` job pool, fixed `platform-ci-control` node and ARC 0.15.0 CRDs. Repository installers verify exact shared schemas and use `--skip-crds`. Application, coding-worker, retained-volume, DNS and Terraform state changes are outside this package.
- `symphony-ci-system` runs the namespace-scoped controller, listener and internal HTTPS CONNECT proxy on protected control-node placement. Its three-Pod quota reserves 300m CPU/640Mi. Preflight reserves both foundation and Symphony control quotas plus 270m/256Mi for managed DNS, and counts other live/pending Pod requests. Recreate upgrades preserve the capacity bound.
- `symphony-ci-runners` permits one job Pod, scale-set min/max 0/1, 2 CPU/6Gi requests and fresh bounded home/temp storage. Less than 4 allocatable CPU on the shared job node prevents two 2-CPU jobs running concurrently across repositories; pending work has no FIFO guarantee. Jobs use UID 1001, gVisor, read-only root, no capabilities/privilege escalation, Kubernetes token/cloud identity, host mount/socket, App key, Docker/container mode or model authentication.
- NetworkPolicies allow job DNS and its namespace-local proxy only. The ConfigMap in [foundation.yaml](foundation.yaml) permits HTTPS to GitHub, Hex, npm and PyPI while rejecting private and unlisted destinations. The reviewed foundation proxy image is reused with Symphony-specific configuration; foundation's proxy configuration is unchanged. HTTPS remains end-to-end encrypted. Trusted controls separately reach the private Kubernetes API.
- Use a distinct private GitHub App installed **only on `iliazlobin/symphony`**, Administration read/write and Metadata read, webhooks disabled. Deliver its fields through the approved private operator channel to `symphony-ci-runners/symphony-ci-github-app`; never Git, Terraform, image, Helm values, arguments or jobs. ARC creates a separate listener Secret; job Pods receive single-job JIT registration only. Never reuse foundation App credentials, personal tokens or application/model secrets.

## Build and install

Use the foundation [private access runbook](https://github.com/iliazlobin/gcp-foundation/blob/main/README.md#private-access). Require reviewed source, passing checks, approved pools and established shared CRDs before deployment; preserve state and application resources.

[Dockerfile](Dockerfile) pins Linux AMD64 Elixir 1.19.5/OTP 28, Node 22.14.0 and runner 2.338.0 with immutable/checksum inputs. Its Dockerfile-specific ignore file excludes the checkout. Publish from the reviewed commit to the existing private `foundation-ci` registry with temporary Docker authentication; existing node-reader access is sufficient. Record source SHA and immutable digest before installation:

```sh
ci_revision=$(git rev-parse HEAD)
docker buildx build --platform linux/amd64 --build-arg SOURCE_REVISION="$ci_revision" \
  -f deploy/ci/Dockerfile \
  -t "us-west1-docker.pkg.dev/iz27-platform-dev/foundation-ci/symphony-ci-runner:$ci_revision" \
  --push .
```

Apple Silicon emulation may need `ERL_AFLAGS='+JMsingle true'` in a disposable test container only, as [documented by Elixir](https://hexdocs.pm/mix/Mix.Tasks.Release.html#using-images). This is not baked into the native image; local checks do not replace GKE execution.

Put `gh`, `gcloud`, `kubectl`, `helm`, Python and PyYAML on the operator PATH and set the task-local IAP `KUBECONFIG`. Review [versions.json](versions.json), [foundation.yaml](foundation.yaml), [controller-values.yaml](controller-values.yaml) and [runner-values.yaml](runner-values.yaml). Installer modes verify chart checksums and shared CRD health/schema before mutation; neither installs/upgrades CRDs or reads credential payloads. Helm error details stay private because they can include rendered Secrets.

```sh
deploy/ci/install.sh --prepare
# Deliver the separate repository-only App Secret through the approved private operator channel.
deploy/ci/install.sh 'us-west1-docker.pkg.dev/iz27-platform-dev/foundation-ci/symphony-ci-runner@sha256:<reviewed-digest>'
```

`--prepare` creates Symphony CI namespaces, quotas, policies and proxy, then waits for readiness. Full installation additionally requires App Secret metadata and installs its two ARC releases. Stop on insufficient capacity; never reduce requests or resize shared pools to force admission.

## Acceptance and operations

1. Verify controller/listener/proxy on `platform-ci-control`, scoped roles, exact repository/scale-set min/max and image digest, and zero idle runners. Job service account has no role bindings or cloud annotation.
2. Dispatch [private-ci-smoke](../../.github/workflows/private-ci-smoke.yml) at the reviewed revision. Require distinct names/Pod UIDs and fresh homes. Both probes check tools, UID/capabilities/kernel no-new-privileges, proxy allowance/denials and blocked API/IAP/metadata/direct Internet. Independently inspect actual job Pods for gVisor, protected placement, 2-CPU requests and absent token/App/host mounts.
3. Verify both Pods/registrations disappear. With other sets idle, wait for the job managed group to return to zero; autoscaler delay is expected. Never delete a running node to claim cleanup.
4. Enable `SYMPHONY_GKE_CI=enabled` after smoke acceptance. Require real GKE `make-all` and `validate-pr-description` at the reviewed PR head, then `make-all` on resulting `main`. Record cold compilation time/memory, full Elixir/Python/assets/Dialyzer results and hosted fallback evidence. Timeouts/failures remain failures; preserve branch protection and human task acceptance.

```sh
kubectl -n symphony-ci-system get deployments,pods
kubectl -n symphony-ci-runners get autoscalingrunnersets,ephemeralrunners,pods,events
gh api repos/iliazlobin/symphony/actions/runners --jq '.runners[]|{name,status,busy}'
```

Use private Cloud Logging for retained stdout; never print Secrets or raw Helm errors. Diagnose listener/proxy/scheduling/quota/autoscaling before increasing capacity. A single zone/node has no HA; interrupted jobs may need reruns.

For maintenance, set Helm min/max to zero and drain active jobs before updates. Roll back reviewed image/chart digests; preserve namespaces, CRDs, credentials, state and application resources. Coordinate ARC upgrades through foundation because [Helm does not upgrade CRDs](https://helm.sh/docs/chart_best_practices/custom_resource_definitions/). Update runner pins within GitHub's supported window and promptly for critical fixes.

[Burrito release verification](../../.github/workflows/burrito-release.yml) retains hosted native macOS/Linux ARM and Docker-dependent paths. This AMD64 shell/JavaScript runner does not support them. GKE compute/network/registry/logging costs remain separate from GitHub model quotas and account service holds.
