#!/usr/bin/env python3
"""Credential-free check executed by two consecutive disposable CI jobs."""

import argparse
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import urllib.request


def probe(write_sentinel=False):
    if os.getuid() != 1001:
        raise RuntimeError("CI must run as UID 1001.")
    for forbidden in (
        "/var/run/secrets/kubernetes.io/serviceaccount/token",
        "/var/run/docker.sock",
        "/run/containerd/containerd.sock",
        "/var/lib/symphony-auth",
        "/var/lib/symphony",
    ):
        if pathlib.Path(forbidden).exists():
            raise RuntimeError(f"Unexpected protected path: {forbidden}")
    if shutil.which("sudo") or shutil.which("docker") or shutil.which("kubectl"):
        raise RuntimeError("CI image must not contain privilege or cluster-control tools.")
    for name in ("GOOGLE_APPLICATION_CREDENTIALS", "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE", "DOCKER_HOST"):
        if os.environ.get(name):
            raise RuntimeError(f"Unexpected privileged configuration: {name}")
    status = pathlib.Path("/proc/self/status").read_text()
    if not re.search(r"^CapEff:\s+0+$", status, re.M) or not re.search(r"^NoNewPrivs:\s+1$", status, re.M):
        raise RuntimeError("CI capabilities or privilege escalation are enabled.")
    sentinel = pathlib.Path.home() / ".symphony-ci-sentinel"
    if sentinel.exists():
        raise RuntimeError("Previous job data survived runner replacement.")
    if write_sentinel:
        sentinel.write_text("This file must not exist in the next runner.\n")
    expected = json.loads((pathlib.Path(__file__).parent / "versions.json").read_text())
    node = subprocess.check_output(["node", "--version"], text=True).strip()
    if node != "v" + expected["node_version"]:
        raise RuntimeError("Unexpected Node version.")
    elixir = subprocess.check_output(["elixir", "--version"], text=True)
    if f'Elixir {expected["elixir_version"]}' not in elixir or "Erlang/OTP 28" not in elixir:
        raise RuntimeError("Unexpected Elixir/OTP version.")
    version_environment = dict(os.environ)
    version_environment.pop("ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT", None)
    runner = subprocess.check_output(["/home/runner/bin/Runner.Listener", "--version"], text=True,
                                     env=version_environment).strip()
    if runner != expected["runner_version"]:
        raise RuntimeError("Unexpected GitHub runner version.")
    # These must be denied by the actual network policy; checking YAML is insufficient.
    for host, port in (("10.48.0.1", 443), ("10.40.0.2", 443), ("169.254.169.254", 80)):
        try:
            connection = socket.create_connection((host, port), timeout=2)
        except OSError:
            continue
        connection.close()
        raise RuntimeError(f"Protected endpoint reachable: {host}:{port}")
    socket.getaddrinfo("api.github.com", 443)
    with urllib.request.urlopen("https://api.github.com/", timeout=15) as response:
        if response.status != 200:
            raise RuntimeError("GitHub HTTPS access failed.")
    print(json.dumps({"runner": os.environ.get("RUNNER_NAME"), "revision": os.environ.get("GITHUB_SHA"),
                      "uid": os.getuid(), "node": node, "runner_version": runner,
                      "network_isolation": "passed", "previous_job_data": "absent",
                      "sentinel_written": write_sentinel}, sort_keys=True))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-sentinel", action="store_true")
    probe(parser.parse_args().write_sentinel)
