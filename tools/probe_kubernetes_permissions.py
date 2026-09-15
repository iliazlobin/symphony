#!/usr/bin/env python3
"""Emit a disposable gVisor fixture and probe an existing Pod without model calls.

The manifest contains only fake credentials and emptyDir volumes. This tool never
creates, deletes, or changes cluster resources. The probe validates the fixture,
then uses kubectl exec to test Codex's named inner permission profiles.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import inspect
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = "permission-canary"
LABEL = "symphony-permission-canary"
COMMAND_PATH = "/usr/local/bin:/usr/bin:/bin"


def fixture_main():
    import json
    import os
    from pathlib import Path
    import signal
    import socket
    import subprocess
    import time

    os.umask(0o077)
    home = Path("/codex-home")
    (home / "auth.json").write_text("{}\n")
    (home / "AGENTS.md").write_text("Disposable no-model permission fixture.\n")
    (home / "runtime-canary").write_text("FAKE_RUNTIME_SENTINEL\n")
    slot = Path("/var/lib/symphony-auth/slot-01")
    slot.mkdir(mode=0o700)
    (slot / "slot.json").write_text('{"fake_auth_slot_canary":true}\n')
    (slot / "slot.lock").write_text("FAKE_AUTH_LOCK_SENTINEL\n")
    generation = slot / "homes" / ("1-" + "a" * 32)
    generation.mkdir(mode=0o700, parents=True)
    for filename in ("auth.json", "AGENTS.md", "runtime-canary"):
        (generation / filename).write_text((home / filename).read_text())
    Path("/tmp/worker-home").mkdir(mode=0o700)
    other = Path("/workspace/other")
    other.mkdir(mode=0o700)
    (other / "sentinel").write_text("FAKE_OTHER_CHECKOUT_SENTINEL\n")
    for role in ("builder", "reviewer"):
        workspace = Path("/workspace") / role
        workspace.mkdir(mode=0o700)
        (workspace / "read-canary").write_text("disposable\n")
        (workspace / ".env").write_text("FAKE_TEST_VALUE=disposable\n")
        git_env = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": "/tmp/worker-home",
                   "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                   "GIT_CONFIG_COUNT": "0"}
        subprocess.run(["git", "init", "--quiet", "--template=", str(workspace)],
                       env=git_env, check=True, timeout=10)
        for args in (["add", "read-canary"], ["-c", "user.name=Symphony Canary", "-c",
                     "user.email=canary@invalid", "commit", "--quiet", "-m", "Disposable fixture"]):
            subprocess.run(["git", *args], cwd=workspace, env=git_env, check=True, timeout=10)
    auth_fd = os.open(home / "auth.json", os.O_RDONLY)
    persistent_auth_fd = os.open(generation / "auth.json", os.O_RDONLY)
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(64)
    listener.settimeout(0.2)
    evidence = {"pid": os.getpid(), "auth_fd": auth_fd, "persistent_auth_fd": persistent_auth_fd,
                "codex_home": str(generation), "port": listener.getsockname()[1],
                "fake_credentials_only": True}
    Path("/tmp/fixture.json").write_text(json.dumps(evidence))
    signal.signal(signal.SIGTERM, lambda _sig, _frame: sys_exit())
    deadline = time.monotonic() + 600
    print(json.dumps({"fixture_ready": True, "fake_credentials_only": True}), flush=True)
    while time.monotonic() < deadline:
        try:
            connection, _ = listener.accept()
            connection.close()
        except TimeoutError:
            pass
    listener.close()
    os.close(auth_fd)
    os.close(persistent_auth_fd)


def sys_exit():
    raise SystemExit(0)


def in_pod_probe_main(config):
    import json
    import os
    from pathlib import Path
    import selectors
    import socket
    import subprocess
    import tempfile
    import time

    def request(process, selector, payload, timeout=45):
        process.stdin.write(json.dumps(payload).encode() + b"\n")
        process.stdin.flush()
        deadline = time.monotonic() + timeout
        pending = getattr(process, "probe_pending", b"")
        while time.monotonic() < deadline:
            if b"\n" not in pending:
                if not selector.select(max(0, deadline - time.monotonic())):
                    break
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError("App Server exited before responding")
                pending += chunk
                if len(pending) > 1048576:
                    raise RuntimeError("App Server probe output exceeded limit")
                continue
            line, pending = pending.split(b"\n", 1)
            response = json.loads(line)
            if response.get("id") == payload["id"]:
                process.probe_pending = pending
                if "error" in response:
                    raise RuntimeError("App Server RPC error: " + json.dumps(response["error"]))
                return response["result"]
        raise RuntimeError("App Server probe response timed out")

    # Refuse to inspect any home that is not the exact fake fixture.
    if Path("/codex-home/auth.json").read_text() != "{}\n":
        raise RuntimeError("Canary authentication is not the expected fake fixture")
    fixture = json.loads(Path("/tmp/fixture.json").read_text())
    if fixture.get("fake_credentials_only") is not True:
        raise RuntimeError("Fixture provenance missing")
    slot = "/var/lib/symphony-auth/slot-01"
    codex_home = slot + "/homes/1-" + "a" * 32
    if (fixture.get("codex_home") != codex_home or
            Path(codex_home + "/auth.json").read_text() != "{}\n"):
        raise RuntimeError("Persistent auth canary is not the expected fake generation")
    version = subprocess.check_output(["codex", "--version"], text=True, timeout=10).strip()
    if version != "codex-cli 0.153.4":
        raise RuntimeError("Unexpected Codex version: " + version)
    kernel = Path("/proc/version").read_text().strip()
    results = {}
    for role in ("builder", "reviewer"):
        workspace = "/workspace/" + role
        Path(codex_home + "/config.toml").write_text(config.replace(
            'default_permissions = "symphony-builder"',
            'default_permissions = "symphony-' + role + '"'))
        proc_paths = {
            "proc_root_auth_read": "/proc/1/root/codex-home/auth.json",
            "proc_self_auth_read": "/proc/self/root/codex-home/auth.json",
            "proc_fd_auth_read": "/proc/%d/fd/%d" % (fixture["pid"], fixture["auth_fd"]),
            "proc_root_persistent_auth_read": "/proc/1/root" + codex_home + "/auth.json",
            "proc_self_persistent_auth_read": "/proc/self/root" + codex_home + "/auth.json",
            "proc_fd_persistent_auth_read": "/proc/%d/fd/%d" % (fixture["pid"], fixture["persistent_auth_fd"]),
        }
        outer = {}
        paths = {"auth_read": "/codex-home/auth.json", "env_read": workspace + "/.env",
                 "host_input_read": "/codex-home/AGENTS.md", "runtime_read": "/codex-home/runtime-canary",
                 "other_checkout_read": "/workspace/other/sentinel",
                 "persistent_auth_read": codex_home + "/auth.json",
                 "persistent_config_read": codex_home + "/config.toml",
                 "persistent_rules_read": codex_home + "/AGENTS.md",
                 "auth_journal_read": slot + "/slot.json", "auth_lock_read": slot + "/slot.lock",
                 **proc_paths}
        for name, path in paths.items():
            outer[name] = bool(Path(path).read_text())
        outer["auth_directory_list"] = bool(list(Path(slot).iterdir()))
        with socket.create_connection(("127.0.0.1", fixture["port"]), timeout=2):
            outer["network"] = True
        control = Path(workspace) / ".outer-write-control"
        control.write_text("disposable")
        control.unlink()
        outer["workspace_write"] = True
        if not all(outer.values()):
            raise RuntimeError("Trusted outer control failed: " + json.dumps(outer))

        script = '''import json,os,pathlib,socket,subprocess
out={"command_path":os.environ.get("PATH")=="/usr/local/bin:/usr/bin:/bin","ambient_environment":"GIT_TERMINAL_PROMPT" in os.environ}
paths=__PATHS__
paths.update({"workspace_read":"read-canary"})
for key,path in paths.items():
 try:
  with open(path) as f:f.read()
  out[key]=True
 except OSError:out[key]=False
try:list(pathlib.Path("/var/lib/symphony-auth/slot-01").iterdir());out["auth_directory_list"]=True
except OSError:out["auth_directory_list"]=False
for key,path in [("workspace_write","write-canary"),("tmp_write","/tmp/forbidden-write")]:
 try:pathlib.Path(path).write_text("disposable");out[key]=True
 except OSError:out[key]=False
try:
 s=socket.create_connection(("127.0.0.1",__PORT__),timeout=0.3);s.close();out["network"]=True
except OSError:out["network"]=False
for key,command in (("python",["python3","--version"]),("node",["node","--version"]),("uv",["uv","--version"]),("git_diff",["git","diff","HEAD","--exit-code"]),("cat",["cat","read-canary"])):
 out[key]=subprocess.run(command,capture_output=True).returncode==0
try:
 pathlib.Path(".symphony").mkdir(exist_ok=True);pathlib.Path(".symphony/handoff.json").write_text('{"canary":true}');out["handoff_write"]=True
except OSError:out["handoff_write"]=False
out["git_commit"]=subprocess.run(["git","add","read-canary"],capture_output=True).returncode==0 and subprocess.run(["git","-c","user.name=Symphony Canary","-c","user.email=canary@invalid","commit","--allow-empty","-m","Disposable permission canary"],capture_output=True).returncode==0
print(json.dumps(out))
'''.replace("__PATHS__", repr(paths)).replace("__PORT__", str(fixture["port"]))
        expected = {name: False for name in paths}
        expected.update({"workspace_read": True, "workspace_write": role == "builder", "tmp_write": False,
                         "auth_directory_list": False,
                         "network": False, "python": True, "node": True, "uv": True, "git_diff": True,
                         "cat": True, "command_path": True, "ambient_environment": False,
                         "handoff_write": role == "builder", "git_commit": role == "builder"})
        env = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": "/tmp/worker-home",
               "CODEX_HOME": codex_home, "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"}
        with tempfile.TemporaryFile() as errors:
            process = subprocess.Popen(["codex", "app-server"], cwd=workspace, env=env,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            phase = "initialize"
            try:
                request(process, selector, {"id": 1, "method": "initialize", "params": {
                    "clientInfo": {"name": "symphony-gke-permission-canary", "version": "1"},
                    "capabilities": {"experimentalApi": True}}})
                process.stdin.write(b'{"method":"initialized","params":{}}\n')
                process.stdin.flush()
                phase = "thread/start"
                thread = request(process, selector, {"id": 2, "method": "thread/start", "params": {
                    "cwd": workspace, "config": {"default_permissions": "symphony-" + role},
                    "approvalPolicy": "never", "ephemeral": True}})
                if (not thread.get("thread", {}).get("id") or
                        thread.get("activePermissionProfile") != {"id": "symphony-" + role, "extends": ":workspace"}):
                    raise RuntimeError("Named permission profile was not verified")
                phase = "command/exec"
                command = request(process, selector, {"id": 3, "method": "command/exec", "params": {
                    "command": ["/usr/local/bin/python3", "-I", "-c", script],
                    "cwd": workspace, "timeoutMs": 20000}})
                if command.get("exitCode") != 0:
                    raise RuntimeError("Sandbox command failed: " + json.dumps(command))
                observed = json.loads(command["stdout"])
                if observed != expected:
                    raise RuntimeError("Permission mismatch: " + json.dumps({"observed": observed, "expected": expected}))
                results[role] = {"outer_controls": outer, "inner_permissions": observed,
                                 "active_profile": "symphony-" + role, "outer_checkout_writable": True}
            except Exception as exc:
                errors.seek(0)
                diagnostics = errors.read()[-4000:].decode(errors="replace")
                raise RuntimeError(json.dumps({"role": role, "phase": phase, "error": str(exc),
                                                "app_server_stderr": diagnostics})) from exc
            finally:
                selector.close()
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
                process.stdin.close()
                process.stdout.close()
    print(json.dumps({"codex_version": version, "kernel": kernel, "model_turns_started": 0,
                      "real_credentials_loaded": False, "roles": results}, sort_keys=True), flush=True)


def permission_config():
    spec = importlib.util.spec_from_file_location("symphony_canary_profile", ROOT / "profiles/events-concierge/profile.py")
    profile = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(profile)
    return profile.permission_config()


def fixture_source():
    return inspect.getsource(sys_exit) + "\n" + inspect.getsource(fixture_main) + "\nfixture_main()\n"


def manifest(namespace, pod, image):
    for value in (namespace, pod):
        if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", value):
            raise ValueError("Namespace and Pod name must be short DNS labels")
    if not re.fullmatch(r"[a-z0-9][a-z0-9./_:-]*@sha256:[a-f0-9]{64}", image):
        raise ValueError("Worker image must use a verified sha256 digest")
    source = fixture_source()
    return {
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": pod, "namespace": namespace,
                     "labels": {"app.kubernetes.io/name": LABEL, "app.kubernetes.io/part-of": "symphony"},
                     "annotations": {"symphony.openai.com/fixture-sha256": hashlib.sha256(source.encode()).hexdigest()}},
        "spec": {"runtimeClassName": "gvisor", "restartPolicy": "Never", "activeDeadlineSeconds": 600,
                 "terminationGracePeriodSeconds": 10, "automountServiceAccountToken": False,
                 "enableServiceLinks": False,
                 "nodeSelector": {"node-restriction.kubernetes.io/workload": "symphony"},
                 "tolerations": [{"key": "workload", "operator": "Equal", "value": "symphony", "effect": "NoSchedule"}],
                 "securityContext": {"runAsNonRoot": True, "runAsUser": 10001, "runAsGroup": 10001,
                                     "fsGroup": 10001},
                 "containers": [{"name": CONTAINER, "image": image, "imagePullPolicy": "IfNotPresent",
                                 "command": ["/usr/local/bin/python3", "-I", "-u", "-c", source],
                                 "env": [{"name": "HOME", "value": "/tmp/worker-home"},
                                         {"name": "CODEX_HOME", "value": "/codex-home"}],
                                 "securityContext": {"readOnlyRootFilesystem": True,
                                                     "capabilities": {"drop": ["ALL"]}},
                                 "resources": {"requests": {"cpu": "500m", "memory": "512Mi"},
                                               "limits": {"cpu": "2", "memory": "2Gi"}},
                                 "volumeMounts": [{"name": "workspace", "mountPath": "/workspace"},
                                                  {"name": "codex-home", "mountPath": "/codex-home"},
                                                  {"name": "persistent-auth", "mountPath": "/var/lib/symphony-auth"},
                                                  {"name": "temporary", "mountPath": "/tmp"}],
                                 "readinessProbe": {"exec": {"command": ["/usr/local/bin/python3", "-I", "-c",
                                                                              "import pathlib; assert pathlib.Path('/tmp/fixture.json').is_file()"]},
                                                    "periodSeconds": 2}}],
                 "volumes": [{"name": "workspace", "emptyDir": {"sizeLimit": "256Mi"}},
                             {"name": "codex-home", "emptyDir": {"sizeLimit": "256Mi"}},
                             {"name": "persistent-auth", "emptyDir": {"sizeLimit": "256Mi"}},
                             {"name": "temporary", "emptyDir": {"sizeLimit": "256Mi"}}]}}


def kubectl(args, command, *, timeout=30):
    request_timeout = "240s" if command and command[0] == "exec" else "20s"
    return subprocess.run([args.kubectl, "--kubeconfig", args.kubeconfig, "--context", args.context,
                           "--request-timeout=" + request_timeout, *command], capture_output=True, text=True,
                          check=True, timeout=timeout).stdout


def validate_pod(actual, expected):
    metadata = actual.get("metadata", {})
    spec = actual.get("spec", {})
    if not metadata.get("uid") or metadata.get("deletionTimestamp"):
        raise ValueError("Canary Pod is missing identity or being deleted")
    if actual.get("status", {}).get("phase") != "Running":
        raise ValueError("Canary Pod is not running")
    for key, value in expected["metadata"]["annotations"].items():
        if metadata.get("annotations", {}).get(key) != value:
            raise ValueError("Fixture annotation mismatch")
    for key in ("runtimeClassName", "restartPolicy", "activeDeadlineSeconds", "terminationGracePeriodSeconds",
                "automountServiceAccountToken", "enableServiceLinks", "securityContext", "volumes"):
        if spec.get(key) != expected["spec"][key]:
            raise ValueError("Unsafe fixture Pod field: " + key)
    # These are the exact GKE RuntimeClass and standard eviction defaults seen
    # on the admitted pilot Pod. Unknown selectors/tolerations remain rejected.
    if spec.get("nodeSelector") != {
            **expected["spec"]["nodeSelector"], "sandbox.gke.io/runtime": "gvisor"}:
        raise ValueError("Unsafe fixture node selection")
    tolerations = expected["spec"]["tolerations"] + [
        {"key": "node.kubernetes.io/not-ready", "effect": "NoExecute",
         "operator": "Exists", "tolerationSeconds": 300},
        {"key": "node.kubernetes.io/unreachable", "effect": "NoExecute",
         "operator": "Exists", "tolerationSeconds": 300},
        {"key": "sandbox.gke.io/runtime", "effect": "NoSchedule",
         "operator": "Equal", "value": "gvisor"},
    ]
    if (sorted(json.dumps(item, sort_keys=True) for item in spec.get("tolerations", [])) !=
            sorted(json.dumps(item, sort_keys=True) for item in tolerations)):
        raise ValueError("Unsafe fixture scheduling tolerations")
    if any(spec.get(key) for key in ("hostNetwork", "hostPID", "hostIPC", "shareProcessNamespace",
                                    "initContainers", "ephemeralContainers", "hostAliases")):
        raise ValueError("Unexpected host namespace or additional container")
    if len(spec.get("containers", [])) != 1:
        raise ValueError("Fixture must contain exactly one trusted container")
    container = spec["containers"][0]
    for key, value in expected["spec"]["containers"][0].items():
        if key == "readinessProbe":
            if container.get(key, {}).get("exec") != value["exec"]:
                raise ValueError("Readiness command mismatch")
        elif container.get(key) != value:
            raise ValueError("Unsafe fixture container field: " + key)
    if any(container.get(key) for key in ("envFrom", "lifecycle", "volumeDevices", "ports")):
        raise ValueError("Unexpected fixture authority")
    statuses = actual.get("status", {}).get("containerStatuses", [])
    if (len(statuses) != 1 or statuses[0].get("name") != CONTAINER or
            statuses[0].get("restartCount") != 0 or not statuses[0].get("ready") or
            not statuses[0].get("state", {}).get("running")):
        raise ValueError("Fixture is not a fresh, ready container")
    expected_digest = expected["spec"]["containers"][0]["image"].rsplit("@", 1)[1]
    image_id = statuses[0].get("imageID", "")
    if image_id != expected_digest and not image_id.endswith("@" + expected_digest):
        raise ValueError("Running image differs from the verified native manifest digest")


def probe(args):
    expected = manifest(args.namespace, args.pod, args.image)
    namespace = json.loads(kubectl(args, ["get", "namespace", args.namespace, "-o", "json"]))
    if namespace["metadata"]["uid"] != args.namespace_uid:
        raise ValueError("Namespace identity changed")
    before = json.loads(kubectl(args, ["get", "pod", args.pod, "-n", args.namespace, "-o", "json"]))
    validate_pod(before, expected)
    runtime = json.loads(kubectl(args, ["get", "runtimeclass", "gvisor", "-o", "json"]))
    if runtime.get("handler") != "gvisor":
        raise ValueError("Unexpected gVisor runtime handler")
    node = json.loads(kubectl(args, ["get", "node", before["spec"]["nodeName"], "-o", "json"]))
    if node["metadata"].get("labels", {}).get("node-restriction.kubernetes.io/workload") != "symphony":
        raise ValueError("Pod did not land on the dedicated worker node")
    source = inspect.getsource(in_pod_probe_main) + "\nin_pod_probe_main(" + repr(permission_config()) + ")\n"
    output = kubectl(args, ["exec", "-n", args.namespace, args.pod, "-c", CONTAINER, "--",
                           "/usr/local/bin/python3", "-I", "-u", "-c", source], timeout=270)
    result = json.loads(output)
    after = json.loads(kubectl(args, ["get", "pod", args.pod, "-n", args.namespace, "-o", "json"]))
    validate_pod(after, expected)
    if (before["metadata"]["uid"] != after["metadata"]["uid"] or
            before["status"]["containerStatuses"][0]["containerID"] != after["status"]["containerStatuses"][0]["containerID"]):
        raise ValueError("Pod or container identity changed during probe")
    return {"namespace_uid": args.namespace_uid, "pod_uid": after["metadata"]["uid"],
            "node": after["spec"]["nodeName"], "runtime_class": "gvisor",
            "image": args.image, "image_id": after["status"]["containerStatuses"][0]["imageID"],
            "permission_probe": result, "cleanup_performed": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["manifest", "probe"])
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--pod", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--namespace-uid")
    parser.add_argument("--kubeconfig")
    parser.add_argument("--context")
    parser.add_argument("--kubectl", default="kubectl")
    args = parser.parse_args()
    if args.mode == "probe" and not all((args.namespace_uid, args.kubeconfig, args.context)):
        parser.error("probe requires --namespace-uid, --kubeconfig and --context")
    try:
        result = manifest(args.namespace, args.pod, args.image) if args.mode == "manifest" else probe(args)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except subprocess.CalledProcessError as exc:
        print(json.dumps({"error": "kubectl operation failed", "stderr": exc.stderr[-12000:]}), file=sys.stderr)
        return 1
    except (ValueError, OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
