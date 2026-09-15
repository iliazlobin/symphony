#!/usr/bin/env python3
"""Check real Codex command cancellation with disposable, self-expiring processes.

No model calls or credentials. Uses the exact embedded production guardian and
the checked-in worker permission configuration. Surviving probes expire after
eight seconds; this script never searches for or kills processes by a name/PID.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import tempfile
import time


@contextmanager
def disposable_root(parent):
    root = Path(tempfile.mkdtemp(prefix="symphony-cancellation-", dir=parent)).resolve()
    try:
        yield root
    finally:
        if list(root.glob("*.cid.intent")):
            raise RuntimeError("Container cleanup remains unverified; retained recovery markers in " + str(root))
        shutil.rmtree(root)


class Connection:
    def __init__(self, process):
        self.process = process
        self.selector = selectors.DefaultSelector()
        self.selector.register(process.stdout, selectors.EVENT_READ)
        self.buffer = b""
        self.diagnostics = []

    def send(self, request):
        self.process.stdin.write(json.dumps(request).encode() + b"\n")
        self.process.stdin.flush()

    def response(self, request_id, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                try:
                    result = json.loads(line)
                except json.JSONDecodeError:
                    self.diagnostics = (self.diagnostics + [line.decode(errors="replace")])[-30:]
                    continue
                if result.get("id") == request_id:
                    if "error" in result:
                        raise RuntimeError(str(result["error"]))
                    return result["result"]
            if not self.selector.select(max(0, deadline - time.monotonic())):
                break
            data = os.read(self.process.stdout.fileno(), 65536)
            if not data:
                raise RuntimeError("Guardian exited before responding: " + "\n".join(self.diagnostics))
            self.buffer += data
        raise RuntimeError("App-server response timed out")


def identity(pid):
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "lstart=", "-o", "pgid=", "-o", "comm="],
        capture_output=True, text=True, check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def probe(binary, native_terminate=False, container_image=None, seccomp_policy=None, apparmor_profile=None):
    repository = Path(__file__).resolve().parents[1]
    source = (repository / "elixir/lib/symphony_elixir/process_group.ex").read_text()
    guardian = re.search(r'@guardian ~S"""\n(.*?)\n  """', source, re.S)
    if not guardian:
        raise RuntimeError("Cannot locate production process guardian")
    guardian_source = __import__("textwrap").dedent(guardian.group(1))
    spec = importlib.util.spec_from_file_location("profile", repository / "profiles/events-concierge/profile.py")
    profile = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(profile)
    results = {}

    temporary_parent = repository / ".runtime" if container_image else None
    with disposable_root(temporary_parent) as root:
        home = root / "codex"
        home.mkdir()
        (home / "config.toml").write_text(profile.permission_config())

        for mode in ("pipe", "pty", "detached_child"):
            workspace = root / mode
            workspace.mkdir()
            marker = workspace / "canary.json"
            env = {"PATH": profile.WORKER_PATH, "HOME": str(Path.home() if container_image else home), "CODEX_HOME": str(home)}
            command = [binary, "app-server"]
            if container_image:
                command = ["/opt/homebrew/bin/python3", "-I", str(repository / "tools/container_worker.py"),
                           "--workspace", str(workspace), "--codex-home", str(home), "--image", container_image]
                if seccomp_policy:
                    command += ["--seccomp-policy", str(Path(seccomp_policy).resolve())]
                if apparmor_profile:
                    command += ["--apparmor-profile", apparmor_profile]
            process = subprocess.Popen(
                ["/opt/homebrew/bin/python3", "-I", "-u", "-c", guardian_source,
                 str(root / (mode + ".lock"))] + command,
                cwd=workspace, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            connection = Connection(process)
            started = time.monotonic()

            try:
                connection.send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "symphony-cancellation-probe", "version": "1"}, "capabilities": {"experimentalApi": True}}})
                connection.response(1)
                connection.send({"method": "initialized", "params": {}})
                script = """import json,os,pathlib,subprocess,sys,time
child=subprocess.Popen([sys.executable,'-I','-c','import time; time.sleep(8)'],start_new_session=%r)
pathlib.Path('canary.json').write_text(json.dumps({'parent':os.getpid(),'parent_group':os.getpgrp(),'child':child.pid,'child_group':os.getpgid(child.pid)}))
time.sleep(8)
""" % (mode == "detached_child")
                connection.send({"id": 2, "method": "command/exec", "params": {
                    "command": ["python3" if container_image else "/opt/homebrew/bin/python3", "-I", "-c", script],
                    "cwd": str(workspace), "timeoutMs": 9000,
                    "processId": "owned-canary", "tty": mode == "pty",
                }})

                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline and process.poll() is None:
                    time.sleep(0.02)
                if not marker.exists():
                    result = connection.response(2, timeout=1)
                    raise RuntimeError("Canary did not start: " + json.dumps(result))

                owned = json.loads(marker.read_text())
                before = None if container_image else {name: identity(owned[name]) for name in ("parent", "child")}
                cid = None
                if container_image:
                    cidfiles = list(root.glob(mode + ".lock.*.cid"))
                    if len(cidfiles) != 1:
                        raise RuntimeError("Missing unique guardian container identity")
                    cid = cidfiles[0].read_text().strip()
                    intent = json.loads(Path(str(cidfiles[0]) + ".intent").read_text())
                    docker_endpoint = intent["docker_host"]
                if native_terminate:
                    connection.send({"id": 3, "method": "command/exec/terminate", "params": {"processId": "owned-canary"}})
                    connection.response(3)
                # Exact equivalent of a dead Erlang port owner: close guardian stdin.
                process.stdin.close()
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if container_image:
                        docker_env = {key: value for key, value in os.environ.items() if key not in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG")}
                        inspect = subprocess.run(["docker", "--host", docker_endpoint, "inspect", cid], env=docker_env, capture_output=True, text=True)
                        absent = inspect.returncode != 0 and ("no such object:" in inspect.stderr.lower() or "no such container:" in inspect.stderr.lower())
                        alive = {"container_namespace": not absent}
                    else:
                        alive = {name: identity(owned[name]) == before[name] for name in before}
                    if not any(alive.values()):
                        break
                    time.sleep(0.05)

                process.wait(timeout=40 if container_image else 3)
                results[mode] = {
                    "cancelled": not any(alive.values()), "surviving_owned_processes": alive,
                    "parent_group": owned["parent_group"], "child_group": owned["child_group"],
                    "guardian_exit_code": process.returncode,
                }
            finally:
                connection.selector.close()
                if process.stdin and not process.stdin.closed:
                    process.stdin.close()
                try:
                    process.wait(timeout=40 if container_image else 3)
                except subprocess.TimeoutExpired:
                    # Only this still-unreaped child handle, never a discovered PID.
                    process.terminate()
                    process.wait(timeout=3)
                process.stdout.close()
                # No forced cleanup by PID: any escaped disposable children self-expire.
                time.sleep(max(0, 8.5 - (time.monotonic() - started)))

    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default="/opt/homebrew/bin/codex")
    parser.add_argument("--native-terminate", action="store_true")
    parser.add_argument("--container-image", help="Verified immutable image ID; probes exact container wrapper and guardian")
    parser.add_argument("--seccomp-policy", help="Explicit inactive compatibility policy for disposable containers only")
    parser.add_argument("--apparmor-profile", help="Explicit worker-only AppArmor compatibility profile")
    arguments = parser.parse_args()
    observed = probe(arguments.codex, arguments.native_terminate, arguments.container_image, arguments.seccomp_policy, arguments.apparmor_profile)
    print(json.dumps(observed, indent=2))
    raise SystemExit(0 if all(result["cancelled"] for result in observed.values()) else 1)
