#!/usr/bin/env python3
"""One fenced Kubernetes App Server lifetime; scheduling remains in Symphony.

This adapter is intentionally not a drop-in Docker guardian replacement. Its caller
must reserve the auth slot, prepare the isolated workspace PVC, and wait for the
terminal intent before consuming artifacts or releasing either volume. An existing
intent can only be cancelled, never reattached or relaunched. Kubernetes objects are
retained for recovery; API disappearance is not evidence of process termination.
"""

from __future__ import annotations

import argparse
import base64
import copy
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import select
import stat
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit

OWNER_LABEL = "symphony.openai.com/owner"
IMAGE_PREFIX = "us-west1-docker.pkg.dev/iz27-platform-dev/symphony/worker@sha256:"
CONTEXT = "gke_iz27-platform-dev_us-west1-a_platform-dev"
UID = re.compile(r"[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}")
NAME = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")
CONFIG_KEYS = {"version", "kubectl", "kubeconfig", "context", "server", "ca_sha256",
               "namespace", "namespace_uid", "image", "workspace_pvc", "auth_pvc"}


class RunnerError(RuntimeError):
    """Execution is blocked; retained state must not be discarded to retry."""


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def private_file(path):
    path = Path(path).absolute()
    if path.resolve(strict=True) != path:
        raise RunnerError("Private control paths must not contain symlinks")
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RunnerError("Control files must be regular, owner-only files")
    return path


def validate_config(config):
    if set(config) != CONFIG_KEYS or config["version"] != 1:
        raise RunnerError("Unknown or incomplete runner configuration")
    if config["context"] != CONTEXT or config["namespace"] != "symphony-workers":
        raise RunnerError("This pilot only supports the approved Symphony GKE target")
    if not UID.fullmatch(config["namespace_uid"]):
        raise RunnerError("Namespace UID must be pinned")
    endpoint = urlsplit(config["server"])
    try:
        private_endpoint = ipaddress.ip_address(endpoint.hostname).is_private
    except ValueError:
        private_endpoint = False
    if (endpoint.scheme != "https" or not private_endpoint or endpoint.username or
            endpoint.password or endpoint.path not in ("", "/") or endpoint.query or endpoint.fragment):
        raise RunnerError("The Kubernetes endpoint must be an explicit private HTTPS IP")
    if not re.fullmatch(r"[a-f0-9]{64}", config["ca_sha256"]):
        raise RunnerError("Cluster CA digest must be pinned")
    if not re.fullmatch(re.escape(IMAGE_PREFIX) + r"[a-f0-9]{64}", config["image"]):
        raise RunnerError("Worker image must be an approved repository digest")
    for key in ("workspace_pvc", "auth_pvc"):
        claim = config[key]
        if (set(claim) != {"name", "uid"} or not NAME.fullmatch(claim["name"]) or
                not UID.fullmatch(claim["uid"])):
            raise RunnerError("PVC names and UIDs must be pinned")
    if config["workspace_pvc"] == config["auth_pvc"] or config["workspace_pvc"]["name"] == config["auth_pvc"]["name"]:
        raise RunnerError("Workspace and auth must use separate volumes")
    for key in ("kubectl", "kubeconfig"):
        path = Path(config[key])
        if not path.is_absolute() or path.resolve(strict=True) != path or not path.is_file():
            raise RunnerError("Runner CLI and kubeconfig must use canonical absolute files")
    if not os.access(config["kubectl"], os.X_OK):
        raise RunnerError("kubectl is not executable")
    private_file(config["kubeconfig"])
    return config


def job_manifest(config, workspace, owner, role, generation, deadline, expires_at=None):
    if not re.fullmatch(r"[a-f0-9]{32}", owner) or role not in ("builder", "reviewer"):
        raise RunnerError("Unknown owner or role")
    if type(generation) is not int or generation < 1:
        raise RunnerError("Auth generation must be positive")
    if type(deadline) is not int or not 1 <= deadline <= 3600:
        raise RunnerError("Pilot deadline must be between 1 and 3600 seconds")
    workspace = str(Path(workspace).absolute())
    if not workspace.startswith("/var/lib/symphony/workspaces/") or ".." in Path(workspace).parts:
        raise RunnerError("Workspace must be an isolated controller-visible task path")
    if any(c in workspace for c in ("\n", "\r", "\0")):
        raise RunnerError("Invalid workspace path")
    labels = {"app.kubernetes.io/name": "symphony-worker", OWNER_LABEL: owner}
    container = {
        "name": "worker", "image": config["image"], "imagePullPolicy": "IfNotPresent",
        "command": ["/usr/local/bin/python", "-I", "/opt/symphony/worker_entrypoint.py", "app-server"],
        "args": ["--role", role, "--owner", owner, "--generation", str(generation),
                 "--deadline-seconds", str(deadline), "--expires-at", str(expires_at or int(time.time()) + deadline)],
        "workingDir": workspace, "stdin": True, "stdinOnce": True, "tty": False,
        "env": [
            {"name": "HOME", "value": "/tmp/worker-home"},
            {"name": "SYMPHONY_POD_UID", "valueFrom": {"fieldRef": {"fieldPath": "metadata.uid"}}},
            {"name": "SYMPHONY_JOB_UID", "valueFrom": {"fieldRef": {
                "fieldPath": "metadata.labels['batch.kubernetes.io/controller-uid']"}}},
        ],
        "securityContext": {"privileged": False, "readOnlyRootFilesystem": True,
                            "capabilities": {"drop": ["ALL"]}},
        "resources": {"requests": {"cpu": "1", "memory": "2Gi", "ephemeral-storage": "1Gi"},
                      "limits": {"cpu": "2", "memory": "4Gi", "ephemeral-storage": "2Gi"}},
        "volumeMounts": [
            {"name": "workspace", "mountPath": workspace, "readOnly": role == "reviewer"},
            {"name": "auth", "mountPath": "/var/lib/symphony-auth"},
            {"name": "tmp", "mountPath": "/tmp"}],
        "terminationMessagePolicy": "File",
    }
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
        "containers": [container], "volumes": [
            {"name": "workspace", "persistentVolumeClaim": {"claimName": config["workspace_pvc"]["name"]}},
            {"name": "auth", "persistentVolumeClaim": {"claimName": config["auth_pvc"]["name"]}},
            {"name": "tmp", "emptyDir": {"sizeLimit": "512Mi"}}],
    }
    return {"apiVersion": "batch/v1", "kind": "Job",
            "metadata": {"name": "symphony-" + role + "-" + owner,
                         "namespace": config["namespace"], "labels": labels},
            "spec": {"suspend": True, "parallelism": 1, "completions": 1, "backoffLimit": 0,
                     "podReplacementPolicy": "Failed", "activeDeadlineSeconds": deadline,
                     "template": {"metadata": {"labels": labels}, "spec": pod}}}


class Intent:
    """A synced, private launch marker locked for its entire launcher lifetime."""

    def __init__(self, path, workspace=None):
        self.path = Path(path).absolute()
        parent = self.path.parent
        if parent.resolve(strict=True) != parent:
            raise RunnerError("Intent directory must not contain symlinks")
        info = parent.stat()
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise RunnerError("Intent directory must be owner-only")
        if workspace is not None:
            workspace = Path(workspace).resolve(strict=True)
            if self.path == workspace or workspace in self.path.parents:
                raise RunnerError("Launch intent must be outside the checkout")
        self.lock = os.open(str(self.path) + ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BaseException:
            os.close(self.lock)
            raise RunnerError("Launcher is active; cancel it through its owner before recovery")
        self.data = None

    def close(self):
        os.close(self.lock)

    def create(self, data):
        descriptor = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        self.data = copy.deepcopy(data)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(canonical(self.data) + b"\n")
            stream.flush()
            os.fsync(stream.fileno())
        self._sync_parent()

    def load(self):
        self.data = json.loads(private_file(self.path).read_text())
        if self.data.get("version") != 1:
            raise RunnerError("Unsupported launch intent")
        return self.data

    def update(self, **changes):
        self.data.update(changes)
        temporary = self.path.with_name(self.path.name + ".pending")
        descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(canonical(self.data) + b"\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, self.path)
        self._sync_parent()

    def _sync_parent(self):
        descriptor = os.open(self.path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


class Kubectl:
    def __init__(self, config):
        self.config = config
        self.prefix = [config["kubectl"], "--kubeconfig", config["kubeconfig"],
                       "--context", config["context"], "--namespace", config["namespace"]]

    def command(self, args, value=None):
        try:
            result = subprocess.run(self.prefix + ["--request-timeout=20s"] + args,
                                    input=None if value is None else canonical(value),
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=25, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise RunnerError("Kubernetes command unavailable or timed out; state is uncertain") from exc
        if result.returncode:
            # Do not turn credential-plugin output into logs or App Server messages.
            raise RunnerError("Kubernetes command failed; state is uncertain")
        if not result.stdout.strip():
            return None
        try:
            return json.loads(result.stdout)
        except (ValueError, UnicodeError) as exc:
            raise RunnerError("Kubernetes returned an invalid object") from exc

    def preflight(self, volumes=True):
        cluster = self.command(["config", "view", "--minify", "--raw", "-o", "jsonpath={.clusters[0].cluster}"])
        if cluster.get("server") != self.config["server"] or cluster.get("insecure-skip-tls-verify"):
            raise RunnerError("Kubeconfig target or TLS verification changed")
        try:
            digest = hashlib.sha256(base64.b64decode(cluster["certificate-authority-data"], validate=True)).hexdigest()
        except (KeyError, ValueError) as exc:
            raise RunnerError("Kubeconfig must embed the pinned cluster CA") from exc
        if digest != self.config["ca_sha256"]:
            raise RunnerError("Cluster CA identity changed")
        namespace = self.command(["get", "namespace", self.config["namespace"], "-o", "json"])
        if namespace["metadata"]["uid"] != self.config["namespace_uid"] or namespace["metadata"].get("deletionTimestamp"):
            raise RunnerError("Namespace identity changed or is being deleted")
        for key in (("workspace_pvc", "auth_pvc") if volumes else ()):
            expected = self.config[key]
            actual = self.command(["get", "pvc", expected["name"], "-o", "json"])
            if (actual["metadata"]["uid"] != expected["uid"] or actual["metadata"].get("deletionTimestamp") or
                    actual["spec"].get("accessModes") != ["ReadWriteOncePod"]):
                raise RunnerError("PVC identity or exclusive access mode changed")

    def get(self, kind, name):
        return self.command(["get", kind, name, "--ignore-not-found", "-o", "json"])

    def pods(self, job_uid):
        return self.command(["get", "pods", "-l", "batch.kubernetes.io/controller-uid=" + job_uid, "-o", "json"])

    def create(self, manifest):
        return self.command(["create", "-f", "-", "-o", "json"], manifest)

    def patch(self, kind, obj, path, value):
        metadata = obj["metadata"]
        patch = [{"op": "test", "path": "/metadata/uid", "value": metadata["uid"]},
                 {"op": "test", "path": "/metadata/resourceVersion", "value": metadata["resourceVersion"]},
                 {"op": "replace", "path": path, "value": value}]
        return self.command(["patch", kind, metadata["name"], "--type=json", "-p", canonical(patch).decode(), "-o", "json"])

    def attach(self, pod):
        return StdioAttachment(self.prefix + ["--request-timeout=0", "attach", pod["metadata"]["name"],
                                              "--container=worker", "--stdin", "--tty=false", "--quiet",
                                              "--pod-running-timeout=1s"])


class StdioAttachment:
    """No caller bytes reach a name-selected Pod until its identity is verified.

    Each launch runs in its own CLI process. Input pump is a daemon because the
    parent's stdin may remain open until the owner closes its App Server port.
    The output pump must drain before this process reports transport completion.
    """

    def __init__(self, command):
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, bufsize=0)
        self.io_error = None
        self.output_thread = None

    @property
    def returncode(self):
        return self.process.returncode

    def handshake(self, expected, timeout):
        deadline = time.monotonic() + timeout
        line = bytearray()
        while len(line) < 4096:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise RunnerError("Worker identity handshake timed out")
            byte = os.read(self.process.stdout.fileno(), 1)
            if not byte:
                raise RunnerError("Worker closed transport before identity handshake")
            if byte == b"\n":
                break
            line.extend(byte)
        else:
            raise RunnerError("Worker identity handshake exceeded its size bound")
        try:
            actual = json.loads(line)
        except (UnicodeError, ValueError) as exc:
            raise RunnerError("Worker identity handshake was invalid") from exc
        if canonical(actual) != canonical({"symphony_worker": expected}):
            raise RunnerError("Attached worker identity differs from the owned Pod")

    def start_io(self):
        def pump(source, destination, close=None):
            try:
                while True:
                    data = os.read(source, 65536)
                    if not data:
                        return
                    while data:
                        count = os.write(destination, data)
                        data = data[count:]
            except OSError:
                self.io_error = True
            finally:
                if close is not None:
                    close()
        self.output_thread = threading.Thread(target=pump, args=(self.process.stdout.fileno(), 1), daemon=True)
        input_thread = threading.Thread(target=pump, args=(0, self.process.stdin.fileno(), self.process.stdin.close), daemon=True)
        self.output_thread.start()
        input_thread.start()

    def finish_io(self):
        if self.output_thread is not None:
            self.output_thread.join(timeout=3)
            if self.output_thread.is_alive() or self.io_error:
                raise RunnerError("App Server stream did not finish cleanly")

    def poll(self):
        return self.process.poll()

    def terminate(self):
        self.process.terminate()

    def kill(self):
        self.process.kill()

    def wait(self, timeout):
        return self.process.wait(timeout=timeout)


def _contains(expected, actual):
    """Allow API defaults, but never additional container/list members."""
    if isinstance(expected, dict):
        return isinstance(actual, dict) and all(k in actual and _contains(v, actual[k]) for k, v in expected.items())
    if isinstance(expected, list):
        return isinstance(actual, list) and len(expected) == len(actual) and all(_contains(a, b) for a, b in zip(expected, actual))
    return type(expected) is type(actual) and expected == actual


def constrained_pod(expected, actual):
    """Accept known API defaults, never arbitrary added execution authority."""
    actual = copy.deepcopy(actual)
    defaults = {"dnsPolicy": "ClusterFirst", "schedulerName": "default-scheduler",
                "serviceAccount": expected["serviceAccountName"], "priority": 0,
                "preemptionPolicy": "PreemptLowerPriority"}
    for key, value in defaults.items():
        if key in actual and actual.pop(key) != value:
            return False
    if "nodeName" in actual:
        name = actual.pop("nodeName")
        if not isinstance(name, str) or not re.fullmatch(r"[a-z0-9][a-z0-9.-]{0,252}", name):
            return False
    if "overhead" in actual and actual.pop("overhead") != {"cpu": "250m", "memory": "120Mi"}:
        return False
    # RuntimeClass may add selectors: additional AND constraints only narrow placement.
    selector = actual.get("nodeSelector", {})
    if not _contains(expected["nodeSelector"], selector):
        return False
    actual["nodeSelector"] = expected["nodeSelector"]
    extra_tolerations = [
        {"key": "node.kubernetes.io/not-ready", "operator": "Exists", "effect": "NoExecute", "tolerationSeconds": 300},
        {"key": "node.kubernetes.io/unreachable", "operator": "Exists", "effect": "NoExecute", "tolerationSeconds": 300},
        {"key": "sandbox.gke.io/runtime", "operator": "Equal", "value": "gvisor", "effect": "NoSchedule"},
    ]
    tolerations = actual.get("tolerations", [])
    for tolerated in extra_tolerations:
        if tolerated in tolerations:
            tolerations.remove(tolerated)
    for key in ("hostNetwork", "hostPID", "hostIPC", "shareProcessNamespace"):
        actual.setdefault(key, False)  # These bool fields are omitted by API serialization.
    if set(actual) != set(expected):
        return False
    if set(actual["securityContext"]) != set(expected["securityContext"]):
        return False
    containers = actual.get("containers", [])
    if len(containers) != 1:
        return False
    container, wanted = containers[0], expected["containers"][0]
    if container.pop("terminationMessagePath", "/dev/termination-log") != "/dev/termination-log":
        return False
    container.setdefault("tty", False)
    if set(container) != set(wanted):
        return False
    security = container["securityContext"]
    for key, value in (("runAsUser", 10001), ("runAsGroup", 10001), ("runAsNonRoot", True), ("procMount", "Default")):
        if key in security and security.pop(key) != value:
            return False
    if set(security) != set(wanted["securityContext"]) or set(security["capabilities"]) != {"drop"}:
        return False
    for env in container["env"]:
        if "valueFrom" in env:
            field = env["valueFrom"].get("fieldRef", {})
            if field.pop("apiVersion", "v1") != "v1":
                return False
    for mount in container["volumeMounts"]:
        if mount.pop("subPath", "") or mount.pop("subPathExpr", "") or mount.pop("mountPropagation", "None") != "None":
            return False
        if mount.get("name") == "workspace":
            mount.setdefault("readOnly", False)
    for actual_mount, expected_mount in zip(container["volumeMounts"], wanted["volumeMounts"]):
        if set(actual_mount) != set(expected_mount):
            return False
    for volume, requested in zip(actual["volumes"], expected["volumes"]):
        if set(volume) != set(requested):
            return False
        source = "persistentVolumeClaim" if "persistentVolumeClaim" in volume else "emptyDir"
        if source == "persistentVolumeClaim" and volume[source].pop("readOnly", False) is not False:
            return False
        if source == "emptyDir" and volume[source].pop("medium", ""):
            return False
        if set(volume[source]) != set(requested[source]):
            return False
    return actual == expected


def terminal_evidence(pod):
    statuses = pod.get("status", {}).get("containerStatuses", [])
    if pod.get("status", {}).get("phase") not in ("Succeeded", "Failed") or len(statuses) != 1:
        return None
    status = statuses[0]
    terminated = status.get("state", {}).get("terminated")
    if (status.get("name") != "worker" or status.get("restartCount") != 0 or not terminated or
            not status.get("containerID") or not terminated.get("finishedAt") or type(terminated.get("exitCode")) is not int):
        return None
    return {"pod_uid": pod["metadata"]["uid"], "exit_code": terminated["exitCode"],
            "finished_at": terminated["finishedAt"], "container_id": status.get("containerID")}


class Runner:
    def __init__(self, config, intent, api=None, clock=time.monotonic, sleep=time.sleep):
        self.config, self.intent = config, intent
        self.api = api or Kubectl(config)
        self.clock, self.sleep = clock, sleep
        self.interrupted = False

    def _binding(self):
        return hashlib.sha256(canonical(self.config)).hexdigest()

    def _job(self):
        data = self.intent.data
        job = self.api.get("job", data["job_name"])
        if (job is None or job["metadata"]["uid"] != data.get("job_uid") or
                job["metadata"].get("namespace") != self.config["namespace"] or
                not job["metadata"].get("resourceVersion") or
                job["metadata"].get("labels", {}).get(OWNER_LABEL) != data["owner"]):
            raise RunnerError("Job ownership is missing or changed; no cleanup proof")
        for key in ("parallelism", "completions", "backoffLimit", "podReplacementPolicy"):
            if job["spec"].get(key) != data["manifest"]["spec"][key]:
                raise RunnerError("Job execution policy changed")
        if not constrained_pod(data["manifest"]["spec"]["template"]["spec"], job["spec"]["template"]["spec"]):
            raise RunnerError("Job template differs from the constrained worker manifest")
        return job

    def _pods(self):
        data = self.intent.data
        inventory = self.api.pods(data["job_uid"])
        if (inventory.get("apiVersion") != "v1" or inventory.get("kind") != "PodList" or
                not inventory.get("metadata", {}).get("resourceVersion") or inventory["metadata"].get("continue")):
            raise RunnerError("Pod inventory has no API revision")
        pods = inventory["items"]
        if len({pod["metadata"]["uid"] for pod in pods}) != len(pods):
            raise RunnerError("Pod inventory repeats an identity")
        if not pods:
            if data.get("observed_pods"):
                raise RunnerError("Owned Pod disappeared without termination evidence")
            return inventory
        observed = dict(data.get("observed_pods", {}))
        for pod in pods:
            metadata = pod["metadata"]
            owner_refs = metadata.get("ownerReferences", [])
            if (metadata.get("namespace") != self.config["namespace"] or not UID.fullmatch(metadata["uid"]) or
                    not metadata.get("resourceVersion") or metadata.get("labels", {}).get(OWNER_LABEL) != data["owner"] or
                    metadata.get("labels", {}).get("batch.kubernetes.io/controller-uid") != data["job_uid"] or
                    not any(ref.get("kind") == "Job" and ref.get("uid") == data["job_uid"] and
                            ref.get("name") == data["job_name"] and ref.get("controller") is True for ref in owner_refs)):
                raise RunnerError("Pod does not belong to the exact owned Job")
            expected = copy.deepcopy(data["manifest"]["spec"]["template"]["spec"])
            if data.get("cancelling"):
                expected["activeDeadlineSeconds"] = pod["spec"].get("activeDeadlineSeconds")
                if expected["activeDeadlineSeconds"] not in (1, data["deadline_seconds"]):
                    raise RunnerError("Unexpected Pod deadline")
            if not constrained_pod(expected, pod["spec"]):
                raise RunnerError("Admitted Pod differs from the constrained worker manifest")
            statuses = pod.get("status", {}).get("containerStatuses", [])
            if any(status.get("restartCount", 0) != 0 for status in statuses):
                raise RunnerError("Worker container restart is not an execution retry")
            if data.get("container_id") and metadata["uid"] == data.get("pod_uid"):
                if len(statuses) != 1 or statuses[0].get("containerID") != data["container_id"]:
                    raise RunnerError("Worker container identity changed")
            if metadata["uid"] in observed and observed[metadata["uid"]] != metadata["name"]:
                raise RunnerError("Pod identity changed")
            observed[metadata["uid"]] = metadata["name"]
        if not set(observed).issubset({pod["metadata"]["uid"] for pod in pods}):
            raise RunnerError("An observed Pod disappeared without termination evidence")
        if observed != data.get("observed_pods"):
            self.intent.update(observed_pods=observed)
        return inventory

    def _pod(self):
        pods = self._pods()["items"]
        if not pods:
            return None
        if len(pods) != 1:
            raise RunnerError("Duplicate Pods require explicit recovery; refusing protocol attachment")
        metadata = pods[0]["metadata"]
        data = self.intent.data
        if data.get("pod_uid") and (metadata["uid"] != data["pod_uid"] or metadata["name"] != data["pod_name"]):
            raise RunnerError("Pod replacement is not an execution retry")
        if not data.get("pod_uid"):
            self.intent.update(pod_uid=metadata["uid"], pod_name=metadata["name"], state="pod_bound")
        return pods[0]

    def launch(self, workspace, owner, role, generation, deadline, startup_timeout=180):
        overall_limit = self.clock() + deadline
        manifest = job_manifest(self.config, workspace, owner, role, generation, deadline)
        self.api.preflight()
        if self.clock() >= overall_limit or self.interrupted:
            raise RunnerError("Launch budget expired before resource creation")
        self.intent.create({"version": 1, "owner": owner, "role": role, "generation": generation,
                            "config_sha256": self._binding(), "manifest": manifest,
                            "job_name": manifest["metadata"]["name"], "job_uid": None,
                            "pod_name": None, "pod_uid": None, "state": "launch_intent",
                            "deadline_seconds": deadline})
        attached = None
        cancellation_attempted = False
        try:
            created = self.api.create(manifest)
            uid = created["metadata"]["uid"]
            if not UID.fullmatch(uid):
                raise RunnerError("Job creation returned no durable identity")
            self.intent.update(job_uid=uid, state="job_bound")
            job = self._job()
            if (job["spec"].get("suspend") is not True or
                    job["spec"].get("activeDeadlineSeconds") != deadline):
                raise RunnerError("Created Job differs from requested manifest")
            self.api.patch("job", job, "/spec/suspend", False)
            limit = min(self.clock() + startup_timeout, overall_limit)
            while self.clock() < limit and not self.interrupted:
                self._job()
                pod = self._pod()
                if pod and pod.get("status", {}).get("phase") == "Running":
                    statuses = pod.get("status", {}).get("containerStatuses", [])
                    if any(status.get("restartCount", 0) != 0 for status in statuses):
                        raise RunnerError("Worker container restart is not an execution retry")
                    if (len(statuses) == 1 and statuses[0].get("name") == "worker" and
                            statuses[0].get("containerID") and statuses[0].get("state", {}).get("running")):
                        break
                if pod and pod.get("status", {}).get("phase") in ("Succeeded", "Failed"):
                    raise RunnerError("Worker exited before protocol attachment")
                self.sleep(0.5)
            else:
                raise RunnerError("Worker startup was interrupted or exceeded its bound")
            self.intent.update(state="attaching", attachment_attempted=True,
                               container_id=pod["status"]["containerStatuses"][0]["containerID"])
            attached = self.api.attach(pod)
            attached.handshake({"owner": owner, "generation": generation, "job_uid": self.intent.data["job_uid"],
                                "pod_uid": self.intent.data["pod_uid"]}, timeout=max(0, min(10, overall_limit - self.clock())))
            verified = self._pod()
            if verified is None:
                raise RunnerError("Attached worker disappeared before protocol forwarding")
            self.intent.update(state="attached")
            attached.start_io()
            limit = overall_limit
            while attached.poll() is None and not self.interrupted and self.clock() < limit:
                if getattr(attached, "io_error", None):
                    raise RunnerError("App Server stdio forwarding failed")
                self._job()
                self._pod()
                self.sleep(0.5)
            if self.interrupted or self.clock() >= limit:
                raise RunnerError("Worker attachment was cancelled or exceeded its bound")
            if attached.returncode != 0:
                raise RunnerError("Attach transport failed; reconnection is forbidden")
            attached.finish_io()
            cancellation_attempted = True
            evidence = self.cancel(timeout=45)
            return evidence["exit_code"]
        except BaseException:
            if attached is not None and attached.poll() is None:
                attached.terminate()
                try:
                    attached.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    attached.kill()
                    attached.wait(timeout=3)
            try:
                if self.intent.data.get("job_uid") and not cancellation_attempted:
                    self.cancel(timeout=45)
            except (RunnerError, OSError, ValueError):
                self.intent.update(state="uncertain")
            if self.intent.data.get("state") != "terminated":
                self.intent.update(state="uncertain")
            raise

    def cancel(self, timeout=45):
        data = self.intent.data
        if data.get("config_sha256") != self._binding():
            raise RunnerError("Cancellation configuration differs from the launch identity")
        if not data.get("job_uid"):
            raise RunnerError("Creation acknowledgement was lost; operator recovery is required")
        if data.get("state") == "terminated":
            return data["termination"]
        self.api.preflight(volumes=False)
        job = self._job()
        self.intent.update(cancelling=True, state="cancelling")
        # No deletion, force flag, or name-only mutation. A kubelet-reported
        # terminated state must be observed before the caller releases anything.
        self.api.patch("job", job, "/spec/activeDeadlineSeconds", 1)
        limit = self.clock() + timeout
        while self.clock() < limit:
            job = self._job()
            inventory = self._pods()
            pods = inventory["items"]
            for pod in pods:
                if not terminal_evidence(pod) and pod["spec"]["activeDeadlineSeconds"] != 1:
                    self.api.patch("pod", pod, "/spec/activeDeadlineSeconds", 1)
            job_status = job.get("status", {})
            final_job = any(condition.get("type") in ("Complete", "Failed") and condition.get("status") == "True"
                            for condition in job_status.get("conditions", []))
            if (pods and final_job and job_status.get("active", 0) == 0 and job_status.get("terminating", 0) == 0 and
                    all(terminal_evidence(pod) for pod in pods)):
                selected = next((pod for pod in pods if pod["metadata"]["uid"] == data.get("pod_uid")), pods[0])
                evidence = terminal_evidence(selected)
                evidence["receipt"] = {"job": job, "pods": inventory,
                                       "selector": "batch.kubernetes.io/controller-uid=" + data["job_uid"]}
                self.intent.update(state="terminated", termination=evidence)
                return evidence
            self.sleep(0.5)
        self.intent.update(state="uncertain")
        raise RunnerError("Pod termination was not verified; retain the intent and auth claim")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("manifest", "launch", "cancel"))
    parser.add_argument("--config", required=True)
    parser.add_argument("--intent")
    parser.add_argument("--workspace")
    parser.add_argument("--owner")
    parser.add_argument("--role", choices=("builder", "reviewer"))
    parser.add_argument("--generation", type=int)
    parser.add_argument("--deadline-seconds", type=int)
    args = parser.parse_args()
    config = validate_config(json.loads(private_file(args.config).read_text()))
    if args.action == "manifest":
        print(json.dumps(job_manifest(config, args.workspace, args.owner, args.role,
                                      args.generation, args.deadline_seconds), indent=2))
        return 0
    if not args.intent:
        parser.error("--intent is required for launch/cancel")
    intent = Intent(args.intent, args.workspace if args.action == "launch" else None)
    runner = Runner(config, intent)
    def interrupted(_signum, _frame):
        runner.interrupted = True
    previous = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
    try:
        if args.action == "cancel":
            intent.load()
            runner.cancel()
            return 0
        return runner.launch(args.workspace, args.owner, args.role, args.generation, args.deadline_seconds)
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        intent.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RunnerError, ValueError, OSError, KeyError, TypeError) as error:
        print("Kubernetes runner blocked: " + str(error), file=sys.stderr)
        sys.exit(1)
