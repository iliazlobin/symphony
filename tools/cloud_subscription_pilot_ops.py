#!/usr/bin/env python3
"""Emit/validate one subscription pilot; never apply resources, exec or schedule.

Operator sequence (use umask 077 and the pinned platform-dev kubectl context):
  foundation > foundation.json; apply after review; retain its PVC permanently.
  job --image <digest> --owner <nonce> --stage enrollment --generation 1 \
      --expires-at <unix-deadline> > job.json; create after review.
  Capture fresh Namespace, PVC and Job JSON directly from the trusted API.
  Capture the complete PodList using kubectl get --raw with this endpoint:
  /api/v1/namespaces/symphony-workers/pods?labelSelector=batch.kubernetes.io%2Fcontroller-uid%3D<job-uid>
  Quote the endpoint. A native PodList preserves its collection resourceVersion
  and continuation marker; kubectl get pods can reformat it as List and lose
  this evidence even with --chunk-size=0. Do not reconstruct metadata or use
  model output. A nonempty continuation marker requires a new complete capture.
  validate --manifest job.json --namespace-object namespace.json --pvc-object pvc.json
      --job-object observed-job.json --pods-object pods.json --namespace-uid <uid>
      --pvc-uid <uid> --job-uid <uid> > admission.json
  Only then exec python -I /opt/symphony/tools/cloud_subscription_pilot.py run
  in the admitted Pod/container, with {} (first stage) or the prior receipt on stdin.
  Wait for the exact Job and every Pod to terminate, capture fresh objects again,
  then receipt with the same arguments plus --pod-uid <admitted-uid> > receipt.json.
  Start a new bounded task Job using generation 2 and the terminal receipt.
  No force deletion, TTL cleanup, credential output or automatic claim release.
  If garbage collection removed the already-terminal Pod, audit-receipt accepts
  one original successful GKE audit response plus the prior admission. Keep the
  fresh empty native PodList unchanged; never splice archived Pods into it.

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
STAGE_MAX_SECONDS = {"enrollment": 1500, "task": 900, "retire": 900}


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
                               "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}},
                              {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
                               "podSelector": {"matchLabels": {"k8s-app": "node-local-dns"}}}],
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
    require(type(expires_at) is int and 1 <= expires_at - now <= STAGE_MAX_SECONDS[stage],
            "Deadline exceeds the bounded pilot stage lifetime")
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


def identity(obj, kind, name, uid, typed_pod_list_item=False, archived_terminal=False):
    meta = obj.get("metadata", {})
    known_kind = obj.get("kind") == kind or (
        typed_pod_list_item and kind == "Pod" and "kind" not in obj)
    require(UID.fullmatch(uid or "") and known_kind and meta.get("name") == name
            and meta.get("uid") == uid and meta.get("resourceVersion")
            and (not meta.get("deletionTimestamp") or (archived_terminal and kind == "Pod")),
            "Object identity, revision or non-deletion state is unverified")
    if kind != "Namespace":
        require(meta.get("namespace") == NAMESPACE, "Unexpected namespace")


def validate(manifest, namespace, pvc, job, pods, namespace_uid, pvc_uid, job_uid, terminal=False,
             archived_terminal_pod=None):
    # The saved desired manifest must itself come from this bounded generator.
    # Reconstruct with its original interval so terminal checks work after expiry.
    container = manifest["spec"]["template"]["spec"]["containers"][0]
    args = container["args"]
    expires_at = int(args[7])
    interval = manifest["spec"]["activeDeadlineSeconds"]
    require(type(interval) is int, "Pilot lifetime must be an integer number of seconds")
    canonical = job_manifest(container["image"], args[1], args[3], int(args[5]), expires_at,
                             now=expires_at - interval)
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
    archived = archived_terminal_pod is not None
    require(not archived or terminal, "Archived Pods cannot authorize execution")
    require(pods.get("kind") == "PodList" and pods.get("apiVersion") == "v1"
            and pods.get("metadata", {}).get("resourceVersion") and not pods["metadata"].get("continue")
            and isinstance(pods.get("items"), list) and len(pods["items"]) == (0 if archived else 1),
            "Complete single-Pod inventory is required")
    pod = archived_terminal_pod if archived else pods["items"][0]
    expected_pod = wanted["template"]["spec"]
    expected_image = expected_pod["containers"][0]["image"]
    for observed in [actual["template"]["spec"], pod["spec"]]:
        normalized = copy.deepcopy(observed)
        for container in normalized.get("containers", []):
            container.setdefault("stdin", False)
            container.setdefault("stdinOnce", False)
        require(RUNNER.constrained_pod(expected_pod, normalized), "Admitted Pod differs from reviewed constraints")
    meta = pod.get("metadata", {})
    require(isinstance(meta.get("name"), str) and RUNNER.NAME.fullmatch(meta["name"]), "Invalid Pod name")
    # Native typed PodList items can omit TypeMeta; the validated envelope fixes
    # their type. An explicit conflicting kind is never accepted.
    identity(pod, "Pod", meta.get("name"), meta.get("uid"), typed_pod_list_item=not archived,
             archived_terminal=archived)
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


def audit_receipt(manifest, namespace, pvc, job, pods, namespace_uid, pvc_uid, job_uid,
                  audit, admission):
    """Recover only from an authenticated original GKE activity response.

    File ownership and provenance fields do not authenticate an export. The
    operator must fetch it from Cloud Logging, never from the worker/model.
    This path cannot authorize exec or release a claim from deletion alone.
    """
    require(isinstance(audit, list) and len(audit) == 1 and isinstance(admission, dict),
            "One original audit entry and saved admission are required")
    entry = audit[0]
    require(isinstance(entry, dict), "Original audit entry is malformed")
    payload = entry.get("protoPayload", {})
    require(isinstance(payload, dict), "Original audit payload is malformed")
    pod = payload.get("response", {})
    require(isinstance(pod, dict) and isinstance(payload.get("status", {}), dict),
            "Original audit response is malformed")
    require(entry.get("logName") == "projects/iz27-platform-dev/logs/cloudaudit.googleapis.com%2Factivity"
            and entry.get("insertId")
            and entry.get("resource") == {"type": "k8s_cluster", "labels": {
                "project_id": "iz27-platform-dev", "cluster_name": "platform-dev", "location": "us-west1-a"}}
            and payload.get("@type") == "type.googleapis.com/google.cloud.audit.AuditLog"
            and payload.get("serviceName") == "k8s.io"
            and payload.get("methodName") in ("io.k8s.core.v1.pods.patch", "io.k8s.core.v1.pods.delete")
            and type(payload.get("status", {}).get("code")) is int and payload["status"]["code"] == 0
            and payload.get("resourceName") == f"core/v1/namespaces/{NAMESPACE}/pods/{admission.get('pod_name')}"
            and pod.get("@type") == "core.k8s.io/v1.Pod"
            and pod.get("apiVersion") == "v1" and pod.get("kind") == "Pod",
            "Original successful GKE Pod response provenance is unverified")
    if payload["methodName"] == "io.k8s.core.v1.pods.delete":
        metadata = pod.get("metadata", {})
        require(metadata.get("deletionTimestamp")
                and type(metadata.get("deletionGracePeriodSeconds")) is int
                and metadata["deletionGracePeriodSeconds"] == 0,
                "Only a completed terminal Pod deletion response is accepted")
    else:
        require(not pod.get("metadata", {}).get("deletionTimestamp"),
                "The archived patch path requires a non-deleting terminal Pod")
    observed = validate(manifest, namespace, pvc, job, pods, namespace_uid, pvc_uid, job_uid,
                        terminal=True, archived_terminal_pod=pod)
    require(observed == admission, "Archived Pod differs from its exact saved admission")
    value = {"job": job, "pods": pods, "selector": "batch.kubernetes.io/controller-uid=" + job_uid,
             "archived_terminal_pod": pod}
    AUTH.terminal_job_evidence(value, {"job_uid": job_uid, "pod_uid": admission["pod_uid"]})
    audit_at = AUTH.evidence_timestamp(entry.get("timestamp"))
    received_at = AUTH.evidence_timestamp(entry.get("receiveTimestamp"))
    finished_at = AUTH.evidence_timestamp(pod["status"]["containerStatuses"][0]["state"]["terminated"]["finishedAt"])
    require(finished_at <= audit_at <= received_at, "Audit timestamp precedes the observed termination")
    if pod["metadata"].get("deletionTimestamp"):
        require(AUTH.evidence_timestamp(pod["metadata"]["deletionTimestamp"]) <= audit_at,
                "Audit record precedes the terminal deletion")
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
    for action in ("validate", "receipt", "audit-receipt"):
        sub = actions.add_parser(action)
        sub.add_argument("--manifest", required=True)
        for key in ("namespace", "pvc", "job", "pods"):
            sub.add_argument("--" + key + "-object", required=True)
        for key in ("namespace", "pvc", "job"):
            sub.add_argument("--" + key + "-uid", required=True)
        if action == "receipt":
            sub.add_argument("--pod-uid", required=True)
        if action == "audit-receipt":
            sub.add_argument("--audit-object", required=True, help="Private original one-entry Cloud Logging JSON export")
            sub.add_argument("--admission-object", required=True, help="Private admission captured before the old exec")
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
            if action == "audit-receipt":
                for key in ("audit", "admission"):
                    values[key] = read_json(args.pop(key + "_object"))
            result = globals()[action.replace("-", "_")](**values, **args)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OpsError, AUTH.AuthSlotError, AttributeError, IndexError, KeyError, TypeError, ValueError, OSError):
        parser.exit(1, "Pilot manifest or runtime snapshot failed validation; retain ownership.\n")


if __name__ == "__main__":
    raise SystemExit(main())
