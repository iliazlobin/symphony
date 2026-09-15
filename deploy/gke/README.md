# GKE controller bootstrap

This package starts **one paused, unconfigured controller and its existing observability dashboard**. It does not run GitHub tasks, Codex, a publisher, or the separate board/chat work. The empty memory tracker is an installation check, not an operational task queue. The current dashboard's “Live” badge means the service responds; it does not establish worker readiness or show the Mac's backlog.

## Package and boundaries

- The image compiles the Elixir escript from the selected checkout, using a digest-pinned official Elixir 1.19.5 / OTP 28 base. Python provides the existing journal lock and the bootstrap checks. No credentials, Codex binary, Docker socket or Kubernetes API token are mounted.
- The baked-in workflow is paused, has no tracker issues/hooks and uses `/bin/false` as its worker command. The entrypoint accepts no alternate workflow, strips inherited credentials/configuration, and refuses an existing journal unless it is empty and paused. It never resets or repairs state.
- A single `Recreate` Deployment mounts a separate 10 GiB `ReadWriteOncePod` journal PVC. UID/GID 10001, read-only root, dropped capabilities, runtime seccomp and a bounded temporary directory are explicit. RWOP and the existing filesystem lock do not replace operator fencing after an uncertain node failure.
- A ClusterIP Service and deny-all ingress/egress policy keep the bootstrap private. Access uses an authenticated Kubernetes port-forward; there is no public endpoint or identity gateway. No control token is supplied, so authenticated control APIs remain unavailable.

## Prepare and build

The package creates the dedicated `symphony` namespace with restricted Pod Security pinned to v1.35, and schedules the controller only on the existing `shared-dev` node pool. Reuse the platform-owned `shared-retain` GKE PD CSI StorageClass with `reclaimPolicy: Retain` and `volumeBindingMode: WaitForFirstConsumer`. Confirm network-policy enforcement, RWOP support, private Kubernetes access, Artifact Registry image-pull access, and shared-node **allocatable headroom** before applying. The controller requests 100m CPU/256 MiB and caps at 1 CPU/512 MiB; these are starting values for the empty bootstrap, not sizing for chat or workers. Platform IaC and application resources must have distinct ownership.

For the first installation, the [application Terraform root](terraform/main.tf) creates only the private Artifact Registry repository, its repository-scoped node image-pull grant, and the protected state bucket. Shared cluster/network/node pools remain owned by platform IaC. Use the [pinned Terraform/provider versions](terraform/versions.tf), verify the active cloud identity and `iz27-platform-dev` project, then run from the repository root:

```sh
umask 077
terraform -chdir=deploy/gke/terraform init
terraform -chdir=deploy/gke/terraform plan -out=bootstrap.tfplan
terraform -chdir=deploy/gke/terraform show bootstrap.tfplan
terraform -chdir=deploy/gke/terraform apply bootstrap.tfplan
```

Review that initial plan for exactly those three additions and no unrelated changes before applying. This first apply uses local state because the destination bucket does not exist yet. After the apply succeeds, preserve a local recovery copy and activate the [GCS backend template](terraform/backend.tf.example):

```sh
cp deploy/gke/terraform/terraform.tfstate deploy/gke/terraform/terraform.tfstate.pre-gcs
cp deploy/gke/terraform/backend.tf.example deploy/gke/terraform/backend.tf
terraform -chdir=deploy/gke/terraform init -migrate-state
terraform -chdir=deploy/gke/terraform state list
terraform -chdir=deploy/gke/terraform plan -detailed-exitcode
```

`backend.tf` and local state/plan files are ignored. Migrate **only this new root's state** to `iz27-platform-dev-symphony-tfstate`, prefix `symphony/bootstrap`; never move or import shared platform state. Confirm all three resources in remote state and a no-change plan (exit 0). Retain the local recovery copy until migration and remote state access are verified. Existing installations use their configured backend; do not repeat this bootstrap or overwrite an existing `backend.tf`.

From a clean checkout of the reviewed, published integration revision:

```sh
SOURCE_REVISION=$(git rev-parse HEAD)
IMAGE=us-west1-docker.pkg.dev/iz27-platform-dev/symphony/controller
python3 -B -m unittest discover -s deploy/gke -v
git archive "$SOURCE_REVISION" | docker build --platform linux/amd64 \
  --build-arg SOURCE_REVISION="$SOURCE_REVISION" \
  -f deploy/gke/Dockerfile -t "$IMAGE:$SOURCE_REVISION" -
```

The archive supplies exactly the committed source, excluding local ignored files and credentials. Building is local; publishing and applying require the approved deployment workflow. After publishing, use its immutable digest in `controller.yaml`, or in a reviewed Kustomize overlay. The placeholder tag intentionally does not identify a deployable release. Keep source SHA, image digest and manifest revision together. Build again from the final published board/chat integration when that work is accepted; do not substitute an unreviewed worktree for a release.

## Apply and inspect

After selecting and verifying the approved Kubernetes context and reviewing the rendered changes:

```sh
kubectl config current-context
kubectl kustomize deploy/gke
kubectl diff -k deploy/gke
kubectl apply -k deploy/gke
kubectl -n symphony rollout status deployment/symphony-controller
kubectl -n symphony exec deployment/symphony-controller -- \
  python3 -I /opt/symphony/entrypoint.py check
kubectl -n symphony port-forward --address 127.0.0.1 service/symphony-controller 8877:8080
```

Open [the GKE bootstrap dashboard](http://127.0.0.1:8877/). Port 8877 keeps this separate from the Mac controller on 8777. Readiness requires both an empty paused journal and a responding HTTP endpoint. It is not a release acceptance check. Confirm private port-forward access and network-policy denial in the actual cluster; a manifest alone is not proof of enforcement. Do not add an Ingress, broaden policies, or copy Mac credentials to make this bootstrap operational.

The launcher prints its mode to container stdout. Existing application logs rotate under `/var/lib/symphony/log/` on the journal volume; they are **not yet exported to Cloud Logging**. Inspect them through authorized `kubectl exec` or a recovery mount. The two named volumes are the only writable paths. There is no liveness restart loop: an unhealthy instance becomes unready and requires diagnosis.

## Recovery and activation limits

Before an upgrade or recovery, pause activity (the bootstrap already is), scale the Deployment to zero, and verify the previous Pod is stopped. Never force-delete an unreachable Pod or detach its volume and start a replacement until the platform owner confirms the old process cannot run. Retain the namespace, PVC and PV when removing the Deployment. Never use `kubectl delete -k deploy/gke` as cleanup: it would delete the namespace and PVC. `Retain` is not a backup: arrange and verify an approved disk snapshot/restore procedure before storing operational work.

A refused startup preserves the journal. Investigate its owner, prior mode and existing issues; do not delete the ledger or edit it to bypass the guard. This bootstrap deliberately cannot import the Mac's operational journal. Restore the last compatible image and preserved state after a failed upgrade; do not reset budgets or task ownership.

Task activation requires a separately reviewed Kubernetes Job runner with exact Pod ownership, attach transport, bounded cancellation/recovery, trusted bootstrap, approved model authentication, independent reviewer/artifact identity, and publisher integration. Board/chat additionally needs its accepted image revision, private browser authentication, retained chat state and deliberately scoped egress. None of those capabilities is supplied by this bootstrap. Keep replicas at one and the empty tracker in place until those gates pass.

References: [official Elixir images](https://hub.docker.com/_/elixir), [Kubernetes persistent volumes and RWOP](https://kubernetes.io/docs/concepts/storage/persistent-volumes/), [network policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/), [Symphony architecture](../../ARCHITECTURE.md).
