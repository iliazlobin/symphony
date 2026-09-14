#!/usr/bin/env python3
"""Verify installed Codex permissions using disposable canaries, without model calls."""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time


def rpc(process, selector, request, timeout=30):
    process.stdin.write(json.dumps(request) + "\n")
    process.stdin.flush()
    deadline = time.monotonic() + timeout
    pending = getattr(process, "probe_pending", b"")
    while time.monotonic() < deadline:
        if b"\n" not in pending:
            if not selector.select(max(0, deadline - time.monotonic())):
                break
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("App server exited before responding")
            pending += chunk
            if len(pending) > 1_048_576:
                raise RuntimeError("App server probe response too large")
            continue
        line, pending = pending.split(b"\n", 1)
        response = json.loads(line)
        if response.get("id") == request["id"]:
            process.probe_pending = pending
            if "error" in response:
                raise RuntimeError(str(response["error"]))
            return response["result"]
    raise RuntimeError("App server probe timed out")


def probe(binary):
    spec = importlib.util.spec_from_file_location("profile", Path(__file__).resolve().parents[1] / "profiles/events-concierge/profile.py")
    profile = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(profile)
    results = {}
    with tempfile.TemporaryDirectory(prefix="symphony-permissions-") as directory:
        root = Path(directory).resolve()
        outside = root / "host-canary"
        outside.write_text("disposable-test-data")
        for role in ("builder", "reviewer"):
            home = root / (role + "-codex")
            home.mkdir()
            config = profile.permission_config().replace('default_permissions = "symphony-builder"', f'default_permissions = "symphony-{role}"')
            (home / "config.toml").write_text(config)
            workspace = root / (role + "-workspace")
            workspace.mkdir()
            (workspace / "read-canary").write_text("disposable-test-data")
            (workspace / ".env").write_text("FAKE_TEST_VALUE=canary")
            script = '''import json,pathlib,socket
out={}
for key,path,mode in [("outside_read",%r,"r"),("workspace_read","read-canary","r"),("workspace_write","write-canary","w"),("env_read",".env","r")]:
 try:
  with open(path,mode) as f:
   f.read() if mode=="r" else f.write("disposable-test-data")
  out[key]=True
 except OSError:
  out[key]=False
try:
 s=socket.socket(); s.settimeout(0.3); s.connect(("127.0.0.1",%d)); out["network"]=True; s.close()
except OSError: out["network"]=False
print(json.dumps(out))
'''
            with __import__("socket").socket() as listener:
                listener.bind(("127.0.0.1", 0))
                listener.listen()
                script = script % (str(outside), listener.getsockname()[1])
                env = {"PATH": profile.WORKER_PATH, "HOME": str(home), "CODEX_HOME": str(home)}
                with tempfile.TemporaryFile(mode="w+") as errors:
                    process = subprocess.Popen([binary, "app-server"], cwd=workspace, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, text=True, bufsize=1)
                    selector = selectors.DefaultSelector()
                    selector.register(process.stdout, selectors.EVENT_READ)
                    try:
                        rpc(process, selector, {"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "symphony-permission-probe", "version": "1"}, "capabilities": {"experimentalApi": True}}})
                        process.stdin.write(json.dumps({"method": "initialized", "params": {}}) + "\n")
                        process.stdin.flush()
                        response = rpc(process, selector, {"id": 2, "method": "command/exec", "params": {"command": ["/opt/homebrew/bin/python3", "-c", script], "cwd": str(workspace), "timeoutMs": 10000}})
                        if response.get("exitCode") != 0:
                            raise RuntimeError("Canary process failed: " + json.dumps(response))
                        observed = json.loads(response["stdout"])
                        expected = {"outside_read": False, "workspace_read": True, "workspace_write": role == "builder", "env_read": False, "network": False}
                        if observed != expected:
                            raise RuntimeError(f"{role} permissions mismatch: {observed}; expected {expected}")
                        # No provider call: verify thread/start also accepts the named profile.
                        thread = rpc(process, selector, {"id": 3, "method": "thread/start", "params": {"cwd": str(workspace), "config": {"default_permissions": "symphony-" + role}, "approvalPolicy": "never", "ephemeral": True}})
                        if not thread.get("thread", {}).get("id"):
                            raise RuntimeError("Named-profile thread was not created")
                        if thread.get("activePermissionProfile", {}).get("id") != "symphony-" + role:
                            raise RuntimeError("Named permission profile was not activated")
                        observed["thread_permission_metadata"] = {k: v for k, v in thread.items() if "permission" in k.lower() or "sandbox" in k.lower()}
                        other = "reviewer" if role == "builder" else "builder"
                        overridden = rpc(process, selector, {"id": 4, "method": "thread/start", "params": {"cwd": str(workspace), "config": {"default_permissions": "symphony-" + other}, "approvalPolicy": "never", "ephemeral": True}})
                        if overridden.get("activePermissionProfile", {}).get("id") != "symphony-" + other:
                            raise RuntimeError("Per-thread override was not activated")
                        if other == "reviewer" and overridden.get("sandbox", {}).get("type") != "readOnly":
                            raise RuntimeError("Per-thread reviewer is not read-only")
                        observed["opposite_thread_profile"] = overridden["activePermissionProfile"]["id"]
                        results[role] = observed
                    except Exception:
                        errors.seek(0)
                        diagnostics = errors.read()[-2000:]
                        if diagnostics:
                            print(diagnostics)
                        raise
                    finally:
                        selector.close()
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default="/opt/homebrew/bin/codex")
    args = parser.parse_args()
    print(json.dumps(probe(args.codex), indent=2))
