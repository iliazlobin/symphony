#!/usr/bin/env python3
"""Emit/validate one subscription pilot; never apply resources, exec or schedule.

Operator sequence (use umask 077 and the pinned platform-dev kubectl context):
  foundation > foundation.json; apply after review; retain its PVC permanently.
  job --image <digest> --owner <nonce> --stage enrollment --generation 1 \
      --expires-at <unix-deadline> > job.json; create after review.
  Capture fresh Namespace, PVC, Job and complete selected PodList JSON directly
  from the trusted API. Use --chunk-size=0 for the PodList and its exact selector
  batch.kubernetes.io/controller-uid=<captured-job-uid>. Do not use model output.
  validate --manifest job.json --namespace-object namespace.json --pvc-object pvc.json
      --job-object observed-job.json --pods-object pods.json --namespace-uid <uid>
      --pvc-uid <uid> --job-uid <uid> > admission.json
  Only then exec python -I /opt/symphony/tools/cloud_subscription_pilot.py run
  in the admitted Pod/container, with {} (first stage) or the prior receipt on stdin.
  Wait for the exact Job and every Pod to terminate, capture fresh objects again,
  then receipt with the same arguments plus --pod-uid <admitted-uid> > receipt.json.
  Start a new bounded task Job using generation 2 and the terminal receipt.
  No force deletion, TTL cleanup, credential output or automatic claim release.

Validation checks snapshots, not their provenance or continued freshness. The
operator owns context/CA authentication, captures immediately before exec/retire,
and retains the complete Job and Pod inventory. No file may come from the worker.
"""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import time

ROOT = Path(__file__).resolve().parent
NAMESPACE = "symphony-workers"
PVC = "symphony-subscription-auth"
APP = "symphony-subscription-pilot"
WORKSPACE = "/var/lib/symphony/workspaces/subscription-pilot"
OWNER = "symphony.openai.com/owner"
IMAGE = re.compile(r"us-west1-docker\.pkg\.dev/iz27-platform-dev/symphony/worker@sha256:[a-f0-9]{64}")
UID = re.compile(r"[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}")
MAX_JSON = 8 * 1024 * 1024


def module(name):
    spec = importlib.util.spec_from_file_location("pilot_ops_" + name, ROOT / (name + ".py"))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


RUNNER = module("kubernetes_runner")
AUTH = module("kubernetes_auth")


class OpsError(RuntimeError):
    """Safe structural validation failure; contains no credentials."""


def require(condition, message):
    if not condition:
        raise OpsError(message)


def foundation():
    """The IPv4 HTTPS rule excludes private, metadata, multicast and special ranges."""
    return {"apiVersion": "v1", "kind": "List", "items": [
        {"apiVersion": "v1", "kind": "PersistentVolumeClaim",
         "metadata": {"name": PVC, "namespace": NAMESPACE, "labels": {"app": APP}},
         "spec": {"accessModes": ["ReadWriteOncePod"], "storageClassName": "shared-retain",
                  "resources": {"requests": {"storage": "1Gi"}}}},
        {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
         "metadata": {"name": APP, "namespace": NAMESPACE},
         "spec": {"podSelector": {"matchLabels": {"app": APP}}, "policyTypes": ["Ingress", "Egress"],
                  "ingress": [], "egress": [
                      {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
                               "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
                       "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]},
                      {"to": [{"ipBlock": {"cidr": "0.0.0.0/0", "except": [
                          "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
                          "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.168.0.0/16",
                          "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4"]}}],
                       "ports": [{"protocol": "TCP", "port": 443}]}]}}]}


def job_manifest(image, owner, stage, generation, expires_at, now=None):
    now = int(time.time()) if now is None else now
    require(isinstance(image, str) and IMAGE.fullmatch(image), "A pinned reviewed worker digest is required")
    require(isinstance(owner, str) and re.fullmatch(r"[a-f0-9]{32}", owner), "Invalid owner nonce")
    require(stage in ("enrollment", "task", "retire"), "Unknown pilot stage")
    require(type(generation) is int and generation > 0, "Invalid auth generation")
    require(type(expires_at) is int and 1 <= expires_at - now <= 900, "Deadline must be within 900 seconds")
    deadline = expires_at - now
    labels = {"app": APP, OWNER: owner}
    pod = {
        "restartPolicy": "Never", "activeDeadlineSeconds": deadline, "os": {"name": "linux"},
        "terminationGracePeriodSeconds": 20, "runtimeClassName": "gvisor",
        "automountServiceAccountToken": False, "enableServiceLinks": False,
        "serviceAccountName": "symphony-worker", "hostNetwork": False, "hostPID": False,
        "hostIPC": False, "shareProcessNamespace": False,
        "securityContext": {"runAsNonRoot": True, "runAsUser": 10001, "runAsGroup": 10001,
                            "fsGroup": 10001, "fsGroupChangePolicy": "OnRootMismatch"},
        "nodeSelector": {"node-restriction.kubernetes.io/workload": "symphony"},
        "tolerations": [{"key": "workload", "operator": "Equal", "value": "symphony", "effect": "NoSchedule"}],
        "containers": [{
            "name": "worker", "image": image, "imagePullPolicy": "IfNotPresent",
            "command": ["/usr/local/bin/python", "-I", "/opt/symphony/tools/cloud_subscription_pilot.py", "idle"],
            "args": ["--owner", owner, "--stage", stage, "--generation", str(generation),
                     "--expires-at", str(expires_at), "--codex-version", "0.153.4"],
            "workingDir": WORKSPACE, "stdin": False, "stdinOnce": False, "tty": False,
            "env": [{"name": "HOME", "value": "/tmp/worker-home"},
                    {"name": "SYMPHONY_POD_UID", "valueFrom": {"fieldRef": {"fieldPath": "metadata.uid"}}},
                    {"name": "SYMPHONY_JOB_UID", "valueFrom": {"fieldRef": {
                        "fieldPath": "metadata.labels['batch.kubernetes.io/controller-uid']"}}}],
            "securityContext": {"privileged": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
            "resources": {"requests": {"cpu": "500m", "memory": "1Gi", "ephemeral-storage": "256Mi"},
                          "limits": {"cpu": "2", "memory": "2Gi", "ephemeral-storage": "1Gi"}},
            "volumeMounts": [{"name": "workspace", "mountPath": WORKSPACE, "readOnly": False},
                             {"name": "auth", "mountPath": "/var/lib/symphony-auth"},
                             {"name": "tmp", "mountPath": "/tmp"}],
            "terminationMessagePolicy": "File"}],
        "volumes": [{"name": "workspace", "emptyDir": {"sizeLimit": "256Mi"}},
                    {"name": "auth", "persistentVolumeClaim": {"claimName": PVC}},
                    {"name": "tmp", "emptyDir": {"sizeLimit": "512Mi"}}]}
    return {"apiVersion": "batch/v1", "kind": "Job",
            "metadata": {"name": "symphony-pilot-" + owner, "namespace": NAMESPACE, "labels": labels},
            "spec": {"suspend": False, "parallelism": 1, "completions": 1, "backoffLimit": 0,
                     "podReplacementPolicy": "Failed", "activeDeadlineSeconds": deadline,
                     "template": {"metadata": {"labels": labels}, "spec": pod}}}


def identity(obj, kind, name, uid):
    meta = obj.get("metadata", {})
    require(UID.fullmatch(uid or "") and obj.get("kind") == kind and meta.get("name") == name
            and meta.get("uid") == uid and meta.get("resourceVersion") and not meta.get("deletionTimestamp"),
            "Object identity, revision or non-deletion state is unverified")
    if kind != "Namespace":
        require(meta.get("namespace") == NAMESPACE, "Unexpected namespace")


def validate(manifest, namespace, pvc, job, pods, namespace_uid, pvc_uid, job_uid, terminal=False):
    # The saved desired manifest must itself come from this bounded generator.
    # Reconstruct with its original interval so terminal checks work after expiry.
    container = manifest["spec"]["template"]["spec"]["containers"][0]
    args = container["args"]
    expires_at = int(args[7])
    canonical = job_manifest(container["image"], args[1], args[3], int(args[5]), expires_at,
                             now=expires_at - manifest["spec"]["activeDeadlineSeconds"])
    require(RUNNER.canonical(manifest) == RUNNER.canonical(canonical),
            "Saved manifest differs from the bounded pilot generator")
    identity(namespace, "Namespace", NAMESPACE, namespace_uid)
    identity(pvc, "PersistentVolumeClaim", PVC, pvc_uid)
    require(pvc.get("apiVersion") == "v1" and pvc.get("status", {}).get("phase") == "Bound"
            and pvc.get("spec", {}).get("storageClassName") == "shared-retain"
            and pvc["spec"].get("accessModes") == ["ReadWriteOncePod"]
            and pvc["spec"].get("resources", {}).get("requests", {}).get("storage") == "1Gi"
            and pvc["spec"].get("volumeName"), "Retained RWOP auth volume is unverified")
    identity(job, "Job", manifest["metadata"]["name"], job_uid)
    require(job.get("apiVersion") == "batch/v1", "Unexpected Job API version")
    wanted = manifest["spec"]
    actual = copy.deepcopy(job.get("spec", {}))
    for key, default in (("manualSelector", False), ("completionMode", "NonIndexed")):
        require(actual.pop(key, default) == default, "Unexpected Job default")
    require(actual.pop("selector", {"matchLabels": {"batch.kubernetes.io/controller-uid": job_uid}})
            == {"matchLabels": {"batch.kubernetes.io/controller-uid": job_uid}}, "Unexpected Job selector")
    require(set(actual) == set(wanted) and all(RUNNER._contains(v, actual[k]) for k, v in wanted.items() if k != "template"),
            "Job execution settings changed")
    require(job["metadata"].get("labels", {}).get(OWNER) == manifest["metadata"]["labels"][OWNER], "Wrong Job owner")
    template_meta = actual["template"].get("metadata", {})
    require(all(template_meta.get("labels", {}).get(k) == v for k, v in wanted["template"]["metadata"]["labels"].items())
            and not template_meta.get("annotations"), "Job template labels or annotations changed")
    require(pods.get("kind") == "PodList" and pods.get("apiVersion") == "v1"
            and pods.get("metadata", {}).get("resourceVersion") and not pods["metadata"].get("continue")
            and isinstance(pods.get("items"), list) and len(pods["items"]) == 1,
            "Complete single-Pod inventory is required")
    expected_pod = wanted["template"]["spec"]
    expected_image = expected_pod["containers"][0]["image"]
    for observed in [actual["template"]["spec"], *[p["spec"] for p in pods["items"]]]:
        normalized = copy.deepcopy(observed)
        for container in normalized.get("containers", []):
            container.setdefault("stdin", False)
            container.setdefault("stdinOnce", False)
        require(RUNNER.constrained_pod(expected_pod, normalized), "Admitted Pod differs from reviewed constraints")
    pod = pods["items"][0]
    meta = pod.get("metadata", {})
    require(isinstance(meta.get("name"), str) and RUNNER.NAME.fullmatch(meta["name"]), "Invalid Pod name")
    identity(pod, "Pod", meta.get("name"), meta.get("uid"))
    require(meta.get("labels", {}).get("app") == APP
            and meta["labels"].get(OWNER) == manifest["metadata"]["labels"][OWNER]
            and meta["labels"].get("batch.kubernetes.io/controller-uid") == job_uid
            and any(ref.get("uid") == job_uid and ref.get("kind") == "Job" and ref.get("controller") is True
                    and ref.get("name") == job["metadata"]["name"] for ref in meta.get("ownerReferences", [])),
            "Pod does not belong to the exact owned Job")
    status = pod.get("status", {})
    states = status.get("containerStatuses", [])
    require(len(states) == 1 and states[0].get("name") == "worker" and states[0].get("restartCount") == 0
            and states[0].get("containerID") and states[0].get("imageID", "").endswith(expected_image.split("@", 1)[1]),
            "Running container identity or digest is unverified")
    if not terminal:
        require(status.get("phase") == "Running" and states[0].get("ready") is True
                and states[0].get("state", {}).get("running", {}).get("startedAt"), "Worker is not ready for trusted exec")
    return {"namespace": NAMESPACE, "namespace_uid": namespace_uid, "pvc_uid": pvc_uid,
            "job_uid": job_uid, "pod_uid": meta["uid"], "pod_name": meta["name"],
            "container": "worker", "image": expected_image, "container_id": states[0]["containerID"]}


def receipt(manifest, namespace, pvc, job, pods, namespace_uid, pvc_uid, job_uid, pod_uid):
    observed = validate(manifest, namespace, pvc, job, pods, namespace_uid, pvc_uid, job_uid, terminal=True)
    require(observed["pod_uid"] == pod_uid, "Admitted Pod identity changed")
    value = {"job": job, "pods": pods, "selector": "batch.kubernetes.io/controller-uid=" + job_uid}
    AUTH.terminal_job_evidence(value, {"job_uid": job_uid, "pod_uid": pod_uid})
    return value


def read_json(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077
                and info.st_nlink == 1 and info.st_size <= MAX_JSON, "Snapshots must be private operator-owned regular files")
        return json.load(stream)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    actions = parser.add_subparsers(dest="action", required=True)
    actions.add_parser("foundation")
    job = actions.add_parser("job")
    for key in ("image", "owner", "stage"):
        job.add_argument("--" + key, required=True)
    job.add_argument("--generation", type=int, required=True)
    job.add_argument("--expires-at", type=int, required=True)
    for action in ("validate", "receipt"):
        sub = actions.add_parser(action)
        sub.add_argument("--manifest", required=True)
        for key in ("namespace", "pvc", "job", "pods"):
            sub.add_argument("--" + key + "-object", required=True)
        for key in ("namespace", "pvc", "job"):
            sub.add_argument("--" + key + "-uid", required=True)
        if action == "receipt":
            sub.add_argument("--pod-uid", required=True)
    args = vars(parser.parse_args())
    action = args.pop("action")
    try:
        if action == "foundation":
            result = foundation()
        elif action == "job":
            result = job_manifest(**args)
        else:
            values = {"manifest": read_json(args.pop("manifest"))}
            for key in ("namespace", "pvc", "job", "pods"):
                values[key] = read_json(args.pop(key + "_object"))
            result = globals()[action](**values, **args)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OpsError, AUTH.AuthSlotError, IndexError, KeyError, TypeError, ValueError, OSError):
        parser.exit(1, "Pilot manifest or runtime snapshot failed validation; retain ownership.\n")


if __name__ == "__main__":
    raise SystemExit(main())
