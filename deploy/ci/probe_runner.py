#!/usr/bin/env python3
"""Check real job isolation and workspace replacement, without any credentials."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import urllib.error
import urllib.request


def verify_privileges():
    status = Path("/proc/self/status").read_text()
    # Older GKE gVisor versions omit NoNewPrivs from proc; query the same
    # kernel bit directly without setting it. Zero or unsupported still fail.
    prctl = ctypes.CDLL(None, use_errno=True).prctl
    prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
    prctl.restype = ctypes.c_int
    no_new_privileges = prctl(39, 0, 0, 0, 0)  # PR_GET_NO_NEW_PRIVS
    if not re.search(r"^CapEff:\s+0+$", status, re.M) or no_new_privileges != 1:
        raise ValueError(f"Capabilities or privilege escalation enabled (kernel flag={no_new_privileges})")


def probe(write_sentinel=False):
    if os.getuid() != 1001:
        raise ValueError("Expected unprivileged UID 1001")
    for path in ("/var/run/secrets/kubernetes.io/serviceaccount/token", "/var/run/docker.sock",
                 "/run/containerd/containerd.sock", str(Path.home() / ".config/gcloud"),
                 str(Path.home() / ".config/gh")):
        if Path(path).exists():
            raise ValueError("Unexpected credential or host-control mount")
    if any(shutil.which(tool) for tool in ("sudo", "docker", "kubectl", "gcloud")):
        raise ValueError("Unexpected privileged control tool")
    if any(os.environ.get(key) for key in ("GOOGLE_APPLICATION_CREDENTIALS",
           "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE", "DOCKER_HOST", "GH_TOKEN", "GITHUB_APP_PRIVATE_KEY")):
        raise ValueError("Unexpected long-lived or cloud credential configuration")
    verify_privileges()
    sentinel = Path.home() / ".symphony-ci-sentinel"
    if sentinel.exists():
        raise ValueError("Previous job workspace survived")
    if write_sentinel:
        sentinel.write_text("The next runner must not contain this file.\n")
    expected = json.loads((Path(__file__).parent / "versions.json").read_text())
    version_env = dict(os.environ)
    version_env.pop("ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT", None)
    runner = subprocess.check_output(["/home/runner/bin/Runner.Listener", "--version"],
                                     env=version_env, text=True).strip()
    if runner != expected["runner_version"]:
        raise ValueError("Unexpected runner version")
    node = subprocess.check_output(["node", "--version"], text=True).strip()
    if node != "v" + expected["node_version"]:
        raise ValueError("Unexpected Node version")
    elixir = subprocess.check_output(["elixir", "--version"], text=True)
    if f'Elixir {expected["elixir_version"]}' not in elixir or "Erlang/OTP 28" not in elixir:
        raise ValueError("Unexpected Elixir/OTP version")
    for host, port in (("10.48.0.1", 443), ("10.40.0.2", 443), ("10.40.0.10", 22),
                       ("169.254.169.254", 80), ("1.1.1.1", 443)):
        try:
            connection = socket.create_connection((host, port), timeout=2)
        except OSError:
            continue
        connection.close()
        raise ValueError(f"Direct protected/public endpoint reachable: {host}:{port}")
    with urllib.request.urlopen("https://api.github.com/", timeout=25) as response:
        if response.status != 200:
            raise ValueError("Allowed GitHub proxy access failed")
    for url in ("https://example.com/", "https://10.48.0.1/", "https://169.254.169.254/"):
        try:
            urllib.request.urlopen(url, timeout=10).close()
        except urllib.error.URLError as error:
            if "403" not in str(error):
                raise ValueError("Expected explicit proxy denial") from error
        else:
            raise ValueError("Proxy allowed an unlisted/protected destination")
    print(json.dumps({"runner": os.environ.get("RUNNER_NAME"), "revision": os.environ.get("GITHUB_SHA"),
                      "runner_version": runner, "node": node, "uid": os.getuid(),
                      "no_new_privileges": "verified via PR_GET_NO_NEW_PRIVS",
                      "network_isolation": "passed", "previous_job_data": "absent",
                      "sentinel_written": write_sentinel}, sort_keys=True))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-sentinel", action="store_true")
    probe(parser.parse_args().write_sentinel)
