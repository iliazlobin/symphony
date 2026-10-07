#!/usr/bin/env python3
"""Read-only operator, private target and bounded control-capacity admission."""
import json
import os
import re
import subprocess

CONTEXT = "gke_iz27-platform-dev_us-west1-a_platform-dev"


def command(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise ValueError(f"{args[0]} failed; inspect private operator diagnostics")
    return result.stdout


def cpu(value):
    value = str(value)
    return float(value[:-1]) / 1000 if value.endswith("m") else float(value)


def memory(value):
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([KMGTPE]i?|m|)", str(value))
    if not match:
        raise ValueError("Unsupported memory quantity")
    number, unit = match.groups()
    if unit == "m":
        return float(number) / 1000
    if not unit:
        return float(number)
    return float(number) * (1024 if unit.endswith("i") else 1000) ** ("KMGTPE".index(unit[0]) + 1)


def requests(pod, resource):
    parse = cpu if resource == "cpu" else memory
    spec = pod["spec"]
    regular = sum(parse(c.get("resources", {}).get("requests", {}).get(resource, 0))
                  for c in spec.get("containers", []))
    initial = max([parse(c.get("resources", {}).get("requests", {}).get(resource, 0))
                   for c in spec.get("initContainers", [])] or [0])
    return max(regular, initial) + parse(spec.get("overhead", {}).get(resource, 0))


def verify_capacity(nodes, pods, quotas):
    controls = [n for n in nodes["items"] if n["metadata"].get("labels", {}).get(
        "cloud.google.com/gke-nodepool") == "platform-ci-control"]
    if len(controls) != 1:
        raise ValueError("Require the approved fixed private CI control node")
    node = controls[0]
    if node["metadata"]["labels"].get("node-restriction.kubernetes.io/workload") != "platform-ci-control":
        raise ValueError("Control node lacks the protected placement label")
    trusted = {"foundation-ci-system", "symphony-ci-system"}
    bounded = set()
    for quota in quotas["items"]:
        namespace = quota["metadata"].get("namespace")
        if namespace not in trusted or quota["metadata"].get("name") != "bounded-control":
            continue
        hard = quota["spec"]["hard"]
        if (cpu(hard.get("requests.cpu", "999")) > 0.3 or
                memory(hard.get("requests.memory", "999Gi")) > memory("640Mi") or
                int(hard.get("pods", "999")) > 3):
            raise ValueError("Live CI control quota exceeds reserved capacity")
        bounded.add(namespace)
    if "foundation-ci-system" not in bounded:
        raise ValueError("Require the bounded foundation control quota before Symphony installation")
    used = {"cpu": 0, "memory": 0}
    control_used = {namespace: {"cpu": 0, "memory": 0} for namespace in bounded}
    for pod in pods["items"]:
        if pod.get("status", {}).get("phase") in ("Succeeded", "Failed"):
            continue
        spec = pod["spec"]
        namespace = pod["metadata"].get("namespace")
        if namespace == "symphony-ci-system" and namespace not in bounded:
            raise ValueError("Existing Symphony controls require their bounded quota")
        if namespace in bounded:
            for resource in used:
                control_used[namespace][resource] += requests(pod, resource)
        if spec.get("nodeName") not in (node["metadata"]["name"], None, ""):
            continue
        if not spec.get("nodeName"):
            selector = spec.get("nodeSelector", {})
            if selector.get("node-restriction.kubernetes.io/workload", "platform-ci-control") != "platform-ci-control":
                continue
            if selector.get("cloud.google.com/gke-nodepool", "platform-ci-control") != "platform-ci-control":
                continue
            if not any(t.get("effect", "NoSchedule") in ("", "NoSchedule") and
                       (t.get("operator") == "Exists" and t.get("key", "") in ("", "workload") or
                        t.get("key") == "workload" and t.get("value") == "platform-ci-control")
                       for t in spec.get("tolerations", [])):
                continue
        if namespace in bounded:
            continue  # The complete live namespace quota is reserved below.
        for resource in used:
            used[resource] += requests(pod, resource)
    # Only verified live quotas justify substituting their reservation for Pod
    # requests. Reserve both sets, plus managed DNS even before it appears.
    if any(values["cpu"] > 0.3 or values["memory"] > memory("640Mi")
           for values in control_used.values()):
        raise ValueError("Existing CI control Pods exceed reserved quota capacity")
    if used["cpu"] + 0.6 + 0.27 > cpu(node["status"]["allocatable"]["cpu"]):
        raise ValueError("Insufficient control CPU including both CI quotas and managed DNS")
    if used["memory"] + memory("1280Mi") + memory("256Mi") > memory(node["status"]["allocatable"]["memory"]):
        raise ValueError("Insufficient control memory including both CI quotas and managed DNS")


def main():
    if command(["gcloud", "config", "get-value", "account"]).strip() != "iliazlobin27@gmail.com":
        raise ValueError("Unexpected active cloud operator")
    if not os.environ.get("KUBECONFIG"):
        raise ValueError("Set the task-local private KUBECONFIG")
    repo = json.loads(command(["gh", "api", "repos/iliazlobin/symphony"]))
    if repo.get("id") != 1370642365 or repo.get("private") is not False:
        raise ValueError("This installation is restricted to the approved public Symphony repository")
    cluster = json.loads(command(["gcloud", "container", "clusters", "describe", "platform-dev",
                                 "--zone=us-west1-a", "--project=iz27-platform-dev", "--format=json"]))
    privacy = cluster.get("privateClusterConfig", {})
    if not privacy.get("enablePrivateNodes") or not privacy.get("enablePrivateEndpoint") or privacy.get("privateEndpoint") != "10.40.0.2":
        raise ValueError("Unexpected cluster privacy boundary")
    if not {"platform-ci", "platform-ci-control"} <= {p["name"] for p in cluster["nodePools"]}:
        raise ValueError("Reviewed job and control pools must exist")
    config = json.loads(command(["kubectl", "config", "view", "--minify", "-o", "json"]))
    target = config["clusters"][0]["cluster"]
    if config["current-context"] != CONTEXT or target.get("insecure-skip-tls-verify") or not target.get("certificate-authority-data"):
        raise ValueError("Unexpected private TLS context")
    if not re.fullmatch(r"https://127\.0\.0\.1:[0-9]+", target.get("server", "")) or target.get("tls-server-name") != "10.40.0.2":
        raise ValueError("Require the private IAP tunnel and TLS server name")
    verify_capacity(json.loads(command(["kubectl", "get", "nodes", "-o", "json"])),
                    json.loads(command(["kubectl", "get", "pods", "-A", "-o", "json"])),
                    json.loads(command(["kubectl", "get", "resourcequotas", "-A", "-o", "json"])))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f"Symphony CI preflight stopped: {error}") from error
