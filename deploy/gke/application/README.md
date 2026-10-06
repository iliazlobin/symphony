# Symphony application on GKE

This renderer prepares the full Phoenix board and management chat behind HTTPS and
IAP at `symphony.iliazlobin.com`. It uses the existing `symphony` namespace and
`shared-dev` pool, with a new retained `symphony-application-state` volume. The Mac
service and the subscription pilot's `symphony-journal` are separate owners.

The [application package contract](../README.md#required-application-package) owns
image construction and subscription authentication. `render.py` emits a Kubernetes
JSON List; it does not build images, read secrets, call Google Cloud or verify image
provenance. A rendered file is not deployment acceptance.

## Prerequisites

- Verify the intended Google account, project `iz27-platform-dev`, explicit numeric
  project number and private GKE context. Preserve existing namespace policies,
  workers, CI runners, pilot volumes and IAM. The app needs no Kubernetes API token.
- Confirm Gateway API and the global external managed Gateway class are enabled.
  Certificate Manager API must also be enabled through its approved owning setup.
  The separate edge Terraform change owns `symphony-web-ip`, certificate map
  `symphony-web-cert-map`, SSL policy `symphony-web-tls` and the valid certificate;
  DNS remains an explicit prerequisite. The renderer does not create these resources.
- Use a reviewed Linux amd64 application image from
  `us-west1-docker.pkg.dev/iz27-platform-dev/symphony/application@sha256:…`, built
  from the exact reviewed source revision with the IAP implementation. Check its
  provenance and OCI revision before rendering activation; syntax cannot prove them.
- Verify the `shared-retain` StorageClass retains its backing disk and supports
  `ReadWriteOncePod`. Confirm `shared-dev` can fit requests of 250m CPU/512Mi memory
  and a 1 CPU/1Gi limit. These are initial bounds, not measured capacity results.
- Verify cluster DNS `10.48.0.10` and node-local DNS `169.254.20.10` against the cluster.
  The application policy allows DNS and public IPv4 TCP 443, excluding private and
  metadata ranges. It creates no VPC, node-pool or namespace-wide permission changes.
- Deliver two private Secrets separately in namespace `symphony`: `symphony-iap-oauth`
  with key `secret` for the custom OAuth client secret; `symphony-application-secrets`
  with `github-token`, `control-token` and `workspace-secret`. Supply a repository
  scoped GitHub token, a strong random control token and a stable workspace secret
  of at least 64 bytes. Do not put values in manifests, command arguments, Git or logs.
  Do not import Mac credentials, sessions, workspaces, journals or Codex configuration.
- Configure the custom OAuth client and IAP access for **only
  `iliazlobin91@gmail.com`**. Reconcile inherited/broader IAP grants before activation.
  The application independently checks the signed audience and the same allowlist;
  it does not trust forwarded identity fields. IAP identity does not grant bearer API
  access. Chat starts unenrolled with fresh retained authentication storage.

GKE uses [GCPBackendPolicy for IAP and HealthCheckPolicy for the Service's health
check](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/configure-gateway-resources).
The [certificate map annotation](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/secure-gateway)
must not be combined with `tls.certificateRefs`. A precreated global IP is referenced
as a [NamedAddress](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/deploying-gateways).

## Bootstrap the protected backend

Use an operator-private working directory and set only these public identifiers:

```sh
umask 077
SYMPHONY_PROJECT_NUMBER='<verified numeric project number>'
SYMPHONY_IAP_CLIENT_ID='<public custom OAuth client ID>'
python3 deploy/gke/application/render.py bootstrap \
  --hostname symphony.iliazlobin.com \
  --project-number "$SYMPHONY_PROJECT_NUMBER" \
  --iap-client-id "$SYMPHONY_IAP_CLIENT_ID" > bootstrap.json
```

Review `bootstrap.json`, validate it against the actual cluster API, then apply it
in the verified context under the authorized onboarding. It contains a ClusterIP
Service, HTTPS-only Gateway/HTTPRoute, enabled IAP backend policy, `/healthz` policy
and a Gateway policy attaching `symphony-web-tls` (MODERN, TLS 1.2 minimum). It
contains no workload, ConfigMap, PVC, Secret or EndpointSlice. Its Service
selector must have **zero endpoints** before and throughout bootstrap. Bootstrap
does not remove an already activated Deployment; never use it as deactivation.

Wait for the Gateway, route and frontend/backend/health policies to reconcile. Resolve the
**numeric backend service ID** from the controller-created Service NEG and Gateway
backend mapping; do not guess a generated name or choose another application's
backend. Verify that exact backend has IAP enabled, the reviewed client ID and sole
user access before activating a Pod. Keep the endpoint set empty if any check fails.
The required audience is `/projects/PROJECT_NUMBER/global/backendServices/BACKEND_ID`.

## Activate the reviewed application

Supply the reviewed image/revision and the verified audience:

```sh
SYMPHONY_APPLICATION_IMAGE='<reviewed application@sha256 digest>'
SYMPHONY_SOURCE_REVISION='<reviewed 40-character lowercase source SHA>'
SYMPHONY_IAP_AUDIENCE='/projects/<number>/global/backendServices/<numeric ID>'
python3 deploy/gke/application/render.py activate \
  --hostname symphony.iliazlobin.com \
  --project-number "$SYMPHONY_PROJECT_NUMBER" \
  --iap-client-id "$SYMPHONY_IAP_CLIENT_ID" \
  --image "$SYMPHONY_APPLICATION_IMAGE" \
  --source-revision "$SYMPHONY_SOURCE_REVISION" \
  --iap-audience "$SYMPHONY_IAP_AUDIENCE" > activate.json
```

Review the complete diff and cluster validation before applying `activate.json`.
It creates one `Recreate` Pod with UID/GID 10001, dropped capabilities, a read-only
root, `/tmp` emptyDir and no service-account token. The 10Gi RWOP claim retains the
control, Idea, Specification, Design, Assurance, conversation and chat-authentication
state beneath stable `/var/lib/symphony` paths. Do not move path-bound journals.
The digest-named immutable workflow ConfigMap is mounted as a regular `subPath` file
because the package rejects symlinked configuration. A workflow update changes the
Pod template and replaces its sole writer.

Controls initially pause; native task execution remains `/bin/false`, hooks and SSH
workers are absent, and no publisher is deployed. Keep task execution and automatic
merge disabled. Management chat uses the packaged Codex with one conversation at a
time; dedicated subscription enrollment is a separate explicit operation. A GitHub
task confirmation can create a real issue when the supplied token has write access;
do not use it as a disposable UI test or accept existing tasks during onboarding.

Only the application's selector receives the additional network allowances. Ingress
is TCP 8080 from [GFE/health-check source ranges](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/firewall-rules)
`35.191.0.0/16` and `130.211.0.0/22`. There is no NodePort, HTTP listener, public Pod
address, sidecar, host mount or application cloud IAM identity. Allowing these source
ranges identifies the load balancer path, not the browser user; signed IAP assertions
remain mandatory on application pages and sockets.

## Verify and retain recovery

- Confirm one Ready Pod, the exact runtime image digest and matching source revision,
  bound new PVC, intended node pool, enabled IAP backend, attached MODERN/TLS 1.2
  frontend policy and expected health policy.
  Confirm the old Mac service, pilot state and runner namespaces remain unchanged.
- Without a login, HTTPS must require IAP; another account must be denied. Log in as
  `iliazlobin91@gmail.com` in the existing Chrome profile and exercise the actual board,
  chat panel and LiveView WebSocket. The proxy must preserve the signed
  `x-goog-iap-jwt-assertion`, exact Host and exact HTTPS Origin for Upgrade requests.
  Verify tampered/wrong-audience assertions and wrong Host/Origin are denied on app
  pages and sockets. GET `/healthz` returns only `ok`; it exposes no runtime data.
- Verify fresh control mode is paused, native execution is disabled and no publisher
  runs. Save a disposable UI record, restart the Pod through the normal Deployment
  and verify retained data. A new browser grant is expected after replacement because
  browser grants are process-owned even with a stable workspace secret.
- Preserve the applied manifests, immutable image provenance, preceding compatible
  image/workflow and private retained-volume backup. Backup only after writers have
  stopped; snapshot support and retention must be verified separately. Roll back
  using compatible reviewed code and the same stable state paths. Never restore an
  older complete snapshot over newer operator changes, adopt the pilot PVC or delete
  this PVC as part of ordinary Deployment/Gateway removal. Retain preceding workflow
  ConfigMaps while their images remain rollback candidates.

Local source checks cover rendering and entrypoint interoperability:

```sh
python3 -m unittest discover -s tools/tests -p 'test_gke_application_deployment.py' -v
python3 -m unittest discover -s tools/tests -p 'test_gke_application_entrypoint.py' -v
git diff --check
```

Controller acceptance, TLS/IAP/browser behavior, Pod capacity, persistent-volume
restart and chat subscription behavior require live verification; the renderer tests
cannot establish them.
