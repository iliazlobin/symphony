#!/bin/sh
# Explicit operator apply: CI resources only; never reads credential values.
set -eu
if [ "$#" -ne 1 ]; then
  echo 'usage: deploy/ci/install.sh us-west1-docker.pkg.dev/iz27-platform-dev/symphony/ci-runner@sha256:<digest>' >&2
  exit 2
fi
ci_image=$1
python3 - "$ci_image" <<'PY'
import re, sys
if not re.fullmatch(r'us-west1-docker\.pkg\.dev/iz27-platform-dev/symphony/ci-runner@sha256:[0-9a-f]{64}', sys.argv[1]):
    raise SystemExit('A reviewed private CI image digest is required.')
PY
ci_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
expected_context=gke_iz27-platform-dev_us-west1-a_platform-dev
test "$(kubectl config current-context)" = "$expected_context"
test "$(kubectl -n default get service kubernetes -o jsonpath='{.spec.clusterIP}')" = 10.48.0.1
test "$(kubectl -n kube-system get service kube-dns -o jsonpath='{.spec.clusterIP}')" = 10.48.0.10
umask 077
ci_charts=$(mktemp -d)
trap 'rm -rf "$ci_charts"' EXIT HUP INT TERM
ci_version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["arc_version"])' "$ci_dir/versions.json")
for ci_chart in gha-runner-scale-set-controller gha-runner-scale-set; do
  helm pull "oci://ghcr.io/actions/actions-runner-controller-charts/$ci_chart" \
    --version "$ci_version" --destination "$ci_charts"
  python3 - "$ci_dir/versions.json" "$ci_chart" "$ci_charts/$ci_chart-$ci_version.tgz" <<'PY'
import hashlib, json, pathlib, sys
expected = json.load(open(sys.argv[1]))['charts'][sys.argv[2]]['archive_sha256']
if hashlib.sha256(pathlib.Path(sys.argv[3]).read_bytes()).hexdigest() != expected:
    raise SystemExit('ARC chart archive does not match reviewed checksum.')
PY
done
kubectl apply -f "$ci_dir/foundation.yaml"
test "$(kubectl -n symphony-ci-runners get secret symphony-ci-github-app -o jsonpath='{.metadata.name}')" = symphony-ci-github-app
helm upgrade --install symphony-ci-controller \
  "$ci_charts/gha-runner-scale-set-controller-$ci_version.tgz" \
  --namespace symphony-ci-system --values "$ci_dir/controller-values.yaml" \
  --wait --atomic --timeout 5m
helm upgrade --install symphony-ci \
  "$ci_charts/gha-runner-scale-set-$ci_version.tgz" \
  --namespace symphony-ci-runners --values "$ci_dir/runner-values.yaml" \
  --set-string "template.spec.initContainers[0].image=$ci_image" \
  --set-string "template.spec.containers[0].image=$ci_image" \
  --wait --atomic --timeout 5m
kubectl -n symphony-ci-system get deployments,pods
kubectl -n symphony-ci-runners get autoscalingrunnersets,pods
