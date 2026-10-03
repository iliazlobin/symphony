#!/usr/bin/env python3
"""Verify local-auth bridging in the pinned container using fake credentials only.

No model thread, turn or provider request is started. The production guardian
owns one disposable container; the fake host CLI and home are never mounted.
"""
from __future__ import annotations

import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time

from probe_cancellation import Connection, disposable_root
from probe_runtime import resolve_runtime, verify_container_policy

ROOT = Path(__file__).resolve().parents[1]
HOST_METHODS = {"initialize", "initialized", "getAuthStatus", "account/read"}


def fake_token(claims):
    def encoded(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).rstrip(b"=").decode()

    return encoded({"alg": "none", "typ": "JWT"}) + "." + encoded(claims) + ".fake"


def fake_host(root):
    """Create an auth-only fixture outside worker-controlled storage."""
    home, client = root / "home", root / "auth-client"
    home.mkdir(mode=0o700)
    (home / ".codex").mkdir(mode=0o700)
    client.mkdir(mode=0o700)
    methods = root / "methods.jsonl"
    methods.write_text("")
    methods.chmod(0o600)
    binary = root / "fake-codex"
    claims = {"email": "canary@example.invalid", "exp": int(time.time()) + 3600,
              "https://api.openai.com/auth": {"chatgpt_account_id": "fake-symphony-canary", "chatgpt_plan_type": "pro"}}
    token = fake_token(claims)
    source = '''import base64,json,sys
from pathlib import Path
def encoded(value):
 return base64.urlsafe_b64encode(json.dumps(value).encode()).rstrip(b"=").decode()
token=encoded({"alg":"none","typ":"JWT"})+"."+encoded(CLAIMS)+".fake"
for line in sys.stdin:
 request=json.loads(line);method=request.get("method")
 with Path(METHODS).open("a") as audit:audit.write(json.dumps(method)+"\\n")
 if method not in {"initialize","initialized","getAuthStatus","account/read"}:sys.exit(81)
 if method=="initialized":continue
 if method=="initialize":result={"userAgent":"fake-symphony-auth-only"}
 elif method=="getAuthStatus":result={"authMethod":"chatgpt","authToken":token,"requiresOpenaiAuth":True}
 else:result={"account":{"type":"chatgpt","email":"canary@example.invalid","planType":"pro"},"requiresOpenaiAuth":True}
 print(json.dumps({"id":request["id"],"result":result}),flush=True)
'''
    binary.write_text("#!" + sys.executable + "\nMETHODS=" + repr(str(methods)) + "\nCLAIMS=" + repr(claims) + "\n" + source)
    binary.chmod(0o700)
    return {"home": home, "client": client, "binary": binary, "methods": methods, "token": token}


def verify_auth_responses(status, account):
    if (status.get("authMethod") != "chatgptAuthTokens" or status.get("authToken") is not None
            or not isinstance(account.get("account"), dict) or account["account"].get("type") != "chatgpt"):
        raise RuntimeError("The pinned worker did not use token-free external ChatGPT authentication")


def verify_fixture_state(root, host, info):
    if list(root.rglob("auth.json")) or list(host["home"].rglob("auth.json")):
        raise RuntimeError("Ephemeral worker authentication was persisted to disk")
    if list(root.glob("*.cid.auth")):
        raise RuntimeError("Local authentication unexpectedly claimed a dedicated credential")
    for path in root.rglob("*"):
        if path.is_file() and not path.is_symlink() and host["token"].encode() in path.read_bytes():
            raise RuntimeError("Ephemeral worker authentication leaked into retained files")
    host_root = host["home"].parent
    for mount in info.get("Mounts", []):
        source = Path(mount["Source"]).resolve()
        if source == host_root or host_root in source.parents:
            raise RuntimeError("The worker mounted fake personal authentication inputs")
    methods = [json.loads(line) for line in host["methods"].read_text().splitlines()]
    if not methods or not set(methods) <= HOST_METHODS or "getAuthStatus" not in methods:
        raise RuntimeError("The host client escaped its authentication-only RPC contract")


def probe(operator_config):
    spec = importlib.util.spec_from_file_location("profile", ROOT / "profiles/events-concierge/profile.py")
    profile = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(profile)
    runtime = resolve_runtime(profile, ROOT, operator_config=operator_config)
    source = (ROOT / "elixir/lib/symphony_elixir/process_group.ex").read_text()
    matched = re.search(r'@guardian ~S"""\n(.*?)\n  """', source, re.S)
    if not matched:
        raise RuntimeError("Cannot locate the production process guardian")
    guardian = textwrap.dedent(matched.group(1))
    docker = shutil.which("docker")
    if not docker:
        raise RuntimeError("Docker CLI unavailable")
    docker_env = {key: value for key, value in os.environ.items()
                  if key not in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG")}
    context = subprocess.run([docker, "context", "inspect", "colima", "--format", "{{.Endpoints.docker.Host}}"],
                             env=docker_env, capture_output=True, text=True, timeout=10, check=True)
    endpoint = context.stdout.strip()
    if not endpoint.startswith("unix:///") or any(value in endpoint for value in ("\n", "\r", "\0")):
        raise RuntimeError("Only the reviewed local Docker endpoint is supported")
    with tempfile.TemporaryDirectory(prefix="symphony-fake-local-auth-", dir="/private/tmp") as directory:
        host = fake_host(Path(directory).resolve())
        fake_docker = host["home"] / ".docker"
        fake_docker.mkdir(mode=0o700)
        # This context stores only the existing local Unix socket address. No
        # production Docker configuration or authentication is copied.
        subprocess.run([docker, "--config", str(fake_docker), "context", "create", "colima",
                        "--docker", "host=" + endpoint], env=docker_env, capture_output=True,
                       text=True, timeout=10, check=True)
        with disposable_root(runtime["parent"], fixed=True) as root:
            workspace, home = root / "pipe", root / "codex"
            workspace.mkdir(mode=0o700)
            home.mkdir(mode=0o700)
            (home / "config.toml").write_text(profile.permission_config())
            (home / "AGENTS.md").write_text("Disposable auth fixture; no model turns.\n")
            env = {"PATH": profile.WORKER_PATH, "HOME": str(host["home"]), "CODEX_HOME": str(home),
                   "SYMPHONY_WORKER_ROLE": "builder", "PYTHONDONTWRITEBYTECODE": "1"}
            command = [sys.executable, "-I", str(ROOT / "tools/container_worker.py"),
                       "--workspace", str(workspace), "--codex-home", str(home), "--image", runtime["image"],
                       "--auth-source", "local_codex", "--local-codex-binary", str(host["binary"]),
                       "--local-codex-home", str(host["home"] / ".codex"), "--auth-cwd", str(host["client"]),
                       "--auth-source-path", str(ROOT), *runtime["options"]]
            process = subprocess.Popen([sys.executable, "-I", "-u", "-c", guardian,
                                        str(root / "local-auth.lock"), *command], cwd=workspace, env=env,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            connection = Connection(process)
            cid, info = None, None
            try:
                connection.send({"id": 1, "method": "initialize", "params": {
                    "clientInfo": {"name": "symphony-fake-local-auth-probe", "version": "1"},
                    "capabilities": {"experimentalApi": True}}})
                connection.response(1, timeout=30)
                connection.send({"method": "initialized", "params": {}})
                connection.send({"id": 2, "method": "getAuthStatus", "params": {"includeToken": False}})
                status = connection.response(2)
                connection.send({"id": 3, "method": "account/read", "params": {"refreshToken": False}})
                account = connection.response(3)
                verify_auth_responses(status, account)
                files = list(root.glob("local-auth.lock.*.cid"))
                if len(files) != 1:
                    raise RuntimeError("Missing exact guardian container identity")
                cid = files[0].read_text().strip()
                intent = json.loads(Path(str(files[0]) + ".intent").read_text())
                if intent["docker_host"] != endpoint:
                    raise RuntimeError("Worker changed the reviewed Docker endpoint")
                inspected = subprocess.run([docker, "--host", endpoint, "inspect", cid], env=docker_env,
                                           capture_output=True, text=True, timeout=5, check=True)
                info = json.loads(inspected.stdout)[0]
                verify_container_policy(info, runtime)
                verify_fixture_state(root, host, info)
                restrictions = info["HostConfig"]
                if (not restrictions["ReadonlyRootfs"] or restrictions["Privileged"]
                        or restrictions["CapDrop"] != ["ALL"] or restrictions["CapAdd"]
                        or "no-new-privileges" not in restrictions["SecurityOpt"]):
                    raise RuntimeError("Production outer container restrictions changed")
            finally:
                connection.selector.close()
                if not process.stdin.closed:
                    process.stdin.close()
                try:
                    process.wait(timeout=40)
                except subprocess.TimeoutExpired:
                    # Only the owned, unreaped guardian handle; retain its CID
                    # intent if container removal cannot be established.
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=3)
                    raise RuntimeError("Guardian cleanup timed out; inspect retained recovery markers") from None
                finally:
                    process.stdout.close()
            if list(root.glob("*.cid.intent")) or list(root.glob("*.cid.auth")):
                raise RuntimeError("Guardian cleanup was not verified; retained recovery markers")
            absent = subprocess.run([docker, "--host", endpoint, "inspect", cid], env=docker_env,
                                    capture_output=True, text=True, timeout=5)
            if absent.returncode == 0 or not any(value in absent.stderr.lower() for value in ("no such object:", "no such container:")):
                raise RuntimeError("The guardian-owned container was not confirmed absent")
            verify_fixture_state(root, host, info)
    return {"external_auth_method": "chatgptAuthTokens", "token_hidden": True,
            "account_type": "chatgpt", "host_auth_only": True, "worker_auth_file_absent": True,
            "personal_inputs_not_mounted": True, "selected_container_policy_verified": True,
            "guardian_cleanup_verified": True, "real_codex_credentials_used": False, "model_turns": 0}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--operator-config", required=True)
    args = parser.parse_args()
    print(json.dumps(probe(args.operator_config), indent=2))
