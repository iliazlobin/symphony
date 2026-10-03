"""Reuse the laptop Codex login through private, in-memory app-server auth RPCs.

The host client never starts a thread or a model turn. Coding and tool execution
remain in the guardian-owned container. No personal home is copied or mounted.
"""
from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import selectors
import stat
import subprocess
import sys
import time
import uuid

MAX_FRAME = 4 * 1024 * 1024
REFRESH_METHOD = "account/chatgptAuthTokens/refresh"
AUTH_ERROR = "Local Codex sign-in needs recovery; no credentials were exposed"


class LocalCodexAuthError(Exception):
    """Safe authentication failure, without provider payloads or credentials."""


def _paths(binary, home, cwd):
    try:
        return _validated_paths(binary, home, cwd)
    except (OSError, ValueError, TypeError):
        raise LocalCodexAuthError(AUTH_ERROR) from None


def _validated_paths(binary, home, cwd):
    binary, home, cwd = Path(binary), Path(home), Path(cwd)
    expected_home = Path.home() / ".codex"
    if (not binary.is_absolute() or not binary.is_file() or not os.access(binary, os.X_OK)
            or not home.is_absolute() or home != expected_home or home.is_symlink()
            or not cwd.is_absolute() or cwd.is_symlink() or cwd == home or home in cwd.parents):
        raise LocalCodexAuthError(AUTH_ERROR)
    for directory in (home, cwd):
        info = directory.lstat()
        forbidden_mode = 0o022 if directory == home else 0o077
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) & forbidden_mode or directory.resolve(strict=True) != directory):
            raise LocalCodexAuthError(AUTH_ERROR)
    credential = home / 'auth.json'
    if credential.exists() or credential.is_symlink():
        info = credential.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) & 0o077 or info.st_nlink != 1):
            raise LocalCodexAuthError(AUTH_ERROR)
    binary = binary.resolve(strict=True)
    info = binary.stat()
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) & 0o022 or cwd in binary.parents):
        raise LocalCodexAuthError(AUTH_ERROR)
    return binary, home, cwd


def _environment(home):
    return {
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(Path.home()), "CODEX_HOME": str(home),
        "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "RUST_LOG": "error",
    }


def cached_status(*, binary, home, cwd):
    result = {"state": "local", "source": "local_codex", "credential_present": False,
              "sign_in_required": True, "provider_verified": False}
    try:
        binary, home, cwd = _paths(binary, home, cwd)
        checked = subprocess.run([str(binary), "login", "status"], cwd=cwd,
                                 env=_environment(home), capture_output=True, text=True, timeout=10)
        signed_in = checked.returncode == 0 and "Logged in using ChatGPT" in checked.stdout + checked.stderr
        result.update(credential_present=signed_in, sign_in_required=not signed_in)
    except (LocalCodexAuthError, OSError, subprocess.SubprocessError):
        pass
    return result


class _Messages:
    def __init__(self, process):
        self.process = process
        self.buffer = bytearray()

    def take(self):
        if b"\n" not in self.buffer:
            return None
        line, _, remaining = self.buffer.partition(b"\n")
        self.buffer[:] = remaining
        try:
            message = json.loads(line)
        except (ValueError, RecursionError):
            raise LocalCodexAuthError(AUTH_ERROR) from None
        if not isinstance(message, dict):
            raise LocalCodexAuthError(AUTH_ERROR)
        if "id" in message and (isinstance(message["id"], bool) or not isinstance(message["id"], (str, int))):
            raise LocalCodexAuthError(AUTH_ERROR)
        return message

    def read(self):
        data = os.read(self.process.stdout.fileno(), 65536)
        if not data:
            raise LocalCodexAuthError(AUTH_ERROR)
        self.buffer.extend(data)
        if len(self.buffer) > MAX_FRAME:
            raise LocalCodexAuthError(AUTH_ERROR)

    def next(self, deadline):
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while time.monotonic() < deadline:
                message = self.take()
                if message is not None:
                    return message
                if selector.select(max(0, deadline - time.monotonic())):
                    self.read()
        raise LocalCodexAuthError(AUTH_ERROR)


def _send(process, message):
    try:
        data = json.dumps(message, separators=(",", ":")).encode() + b"\n"
        if len(data) > MAX_FRAME:
            raise LocalCodexAuthError(AUTH_ERROR)
        process.stdin.write(data)
        process.stdin.flush()
    except (BrokenPipeError, OSError, ValueError):
        raise LocalCodexAuthError(AUTH_ERROR) from None


def _stop(process):
    if process is None:
        return
    try:
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)
    finally:
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                stream.close()


class LocalCodexAuth:
    def __init__(self, *, binary, home, cwd):
        self.binary, self.home, self.cwd = _paths(binary, home, cwd)
        self.process = None
        self.messages = None
        self.account_id = None
        self.secrets = set()

    def __enter__(self):
        try:
            self.process = subprocess.Popen([str(self.binary), "app-server"], cwd=self.cwd,
                                            env=_environment(self.home), stdin=subprocess.PIPE,
                                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            self.messages = _Messages(self.process)
            deadline = time.monotonic() + 9
            self._rpc("initialize", {
                "clientInfo": {"name": "symphony-local-auth", "version": "1"},
                "capabilities": {"experimentalApi": True},
            }, deadline)
            _send(self.process, {"method": "initialized", "params": {}})
            return self
        except (OSError, LocalCodexAuthError):
            _stop(self.process)
            raise LocalCodexAuthError(AUTH_ERROR) from None

    def __exit__(self, *_exc):
        _stop(self.process)
        self.secrets.clear()

    def _rpc(self, method, params, deadline):
        if method not in ("initialize", "getAuthStatus", "account/read"):
            raise LocalCodexAuthError(AUTH_ERROR)
        identity = "symphony-host-auth-" + uuid.uuid4().hex
        _send(self.process, {"id": identity, "method": method, "params": params})
        while time.monotonic() < deadline:
            response = self.messages.next(deadline)
            if response.get("id") != identity:
                if "id" in response and "method" in response:
                    raise LocalCodexAuthError(AUTH_ERROR)
                continue
            if "error" in response or not isinstance(response.get("result"), dict):
                raise LocalCodexAuthError(AUTH_ERROR)
            return response["result"]
        raise LocalCodexAuthError(AUTH_ERROR)

    def cached_tokens(self, *, refresh=False, previous_account_id=None, deadline=None):
        if refresh and (self.account_id is None or previous_account_id not in (None, self.account_id)):
            raise LocalCodexAuthError(AUTH_ERROR)
        deadline = min(deadline or float("inf"), time.monotonic() + 9)
        # Refresh only for an authenticated worker's same-account unauthorized
        # callback. Routine bootstrap uses the existing native cache as-is.
        status = self._rpc("getAuthStatus", {"includeToken": True, "refreshToken": refresh}, deadline)
        token = status.get("authToken")
        if status.get("authMethod") != "chatgpt" or not isinstance(token, str) or not 16 <= len(token) <= 16384:
            raise LocalCodexAuthError(AUTH_ERROR)
        try:
            encoded = token.split(".")[1]
            claims = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
            auth = claims["https://api.openai.com/auth"]
            account_id = auth["chatgpt_account_id"]
        except (ValueError, IndexError, KeyError, TypeError):
            raise LocalCodexAuthError(AUTH_ERROR) from None
        if not isinstance(account_id, str) or not 1 <= len(account_id) <= 256:
            raise LocalCodexAuthError(AUTH_ERROR)
        if self.account_id is not None and account_id != self.account_id:
            raise LocalCodexAuthError(AUTH_ERROR)
        self.account_id = account_id
        self.secrets.add(token)
        if len(self.secrets) > 32:
            raise LocalCodexAuthError(AUTH_ERROR)
        tokens = {"accessToken": token, "chatgptAccountId": account_id}
        plan = auth.get("chatgpt_plan_type")
        if isinstance(plan, str) and 1 <= len(plan) <= 128:
            tokens["chatgptPlanType"] = plan
        return tokens

    def scrub(self, value):
        if isinstance(value, str):
            for secret in self.secrets:
                value = value.replace(secret, "[redacted]")
            return value
        if isinstance(value, list):
            return [self.scrub(item) for item in value]
        if isinstance(value, dict):
            return {self.scrub(key): None if key.lower().replace("_", "") in
                    ("accesstoken", "refreshtoken", "authtoken", "idtoken") else self.scrub(item)
                    for key, item in value.items()}
        return value


def _refresh(process, request, auth):
    params = request.get("params")
    identity = request.get("id")
    if (isinstance(identity, bool) or not isinstance(identity, (str, int))
            or not isinstance(params, dict) or params.get("reason") != "unauthorized"
            or set(params) - {"reason", "previousAccountId"}):
        raise LocalCodexAuthError(AUTH_ERROR)
    tokens = auth.cached_tokens(refresh=True, previous_account_id=params.get("previousAccountId"))
    _send(process, {"id": identity, "result": tokens})


def _bootstrap(process, messages, request, auth):
    if request.get("method") != "initialize" or "id" not in request:
        raise LocalCodexAuthError(AUTH_ERROR)
    params = request.get("params")
    if not isinstance(params, dict):
        raise LocalCodexAuthError(AUTH_ERROR)
    capabilities = params.setdefault("capabilities", {})
    if not isinstance(capabilities, dict):
        raise LocalCodexAuthError(AUTH_ERROR)
    capabilities["experimentalApi"] = True
    _send(process, request)
    deadline = time.monotonic() + 20
    initialized = None
    while initialized is None:
        response = messages.next(deadline)
        if response.get("id") == request["id"]:
            initialized = response
        elif "id" in response:
            raise LocalCodexAuthError(AUTH_ERROR)
    if "error" in initialized:
        raise LocalCodexAuthError(AUTH_ERROR)
    _send(process, {"method": "initialized", "params": {}})
    identity = "symphony-worker-auth-" + uuid.uuid4().hex
    tokens = auth.cached_tokens(deadline=deadline)
    _send(process, {"id": identity, "method": "account/login/start",
                    "params": {"type": "chatgptAuthTokens", **tokens}})
    deadline = min(deadline, time.monotonic() + 9)
    while True:
        response = messages.next(deadline)
        if response.get("method") == REFRESH_METHOD:
            _refresh(process, response, auth)
        elif response.get("id") == identity:
            result = response.get("result")
            if "error" in response or not isinstance(result, dict) or result.get("type") != "chatgptAuthTokens":
                raise LocalCodexAuthError(AUTH_ERROR)
            return auth.scrub(initialized)
        elif "id" in response:
            raise LocalCodexAuthError(AUTH_ERROR)


def bridge(worker_command, env, auth):
    """Relay worker RPCs, keeping bootstrap and token refresh private to the host."""
    process = None
    try:
        process = subprocess.Popen(worker_command, env=env, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        messages = _Messages(process)
        inputs = bytearray()
        initialized = False
        auth_status_requests = set()
        with selectors.DefaultSelector() as selector:
            selector.register(sys.stdin.buffer, selectors.EVENT_READ, "input")
            selector.register(process.stdout, selectors.EVENT_READ, "worker")
            while True:
                while initialized and (message := messages.take()) is not None:
                    if message.get("method") == REFRESH_METHOD:
                        _refresh(process, message, auth)
                        continue
                    if str(message.get("method", "")).startswith("account/"):
                        if "id" in message:
                            raise LocalCodexAuthError(AUTH_ERROR)
                        continue
                    if message.get("id") in auth_status_requests and "method" not in message:
                        auth_status_requests.remove(message["id"])
                        result = message.get("result", {})
                        if not isinstance(result, dict) or result.get("authToken") is not None:
                            raise LocalCodexAuthError(AUTH_ERROR)
                    safe = auth.scrub(message)
                    sys.stdout.buffer.write(json.dumps(safe, separators=(",", ":")).encode() + b"\n")
                    sys.stdout.buffer.flush()
                for key, _events in selector.select(0.1):
                    if key.data == "worker":
                        data = os.read(process.stdout.fileno(), 65536)
                        if not data:
                            return process.wait(timeout=3)
                        messages.buffer.extend(data)
                        if len(messages.buffer) > MAX_FRAME:
                            raise LocalCodexAuthError(AUTH_ERROR)
                        continue
                    data = os.read(sys.stdin.buffer.fileno(), 65536)
                    if not data:
                        return 0
                    inputs.extend(data)
                    if len(inputs) > MAX_FRAME:
                        raise LocalCodexAuthError(AUTH_ERROR)
                    while b"\n" in inputs:
                        line, _, remaining = inputs.partition(b"\n")
                        inputs[:] = remaining
                        try:
                            request = json.loads(line)
                        except (ValueError, RecursionError):
                            raise LocalCodexAuthError(AUTH_ERROR) from None
                        if not isinstance(request, dict):
                            raise LocalCodexAuthError(AUTH_ERROR)
                        if "id" in request and (isinstance(request["id"], bool) or not isinstance(request["id"], (str, int))):
                            raise LocalCodexAuthError(AUTH_ERROR)
                        if (not isinstance(request.get("params", {}), dict)
                                and not (request.get("method") == "account/rateLimits/read" and request.get("params") is None)):
                            raise LocalCodexAuthError(AUTH_ERROR)
                        if not initialized:
                            ready = _bootstrap(process, messages, request, auth)
                            sys.stdout.buffer.write(json.dumps(ready, separators=(",", ":")).encode() + b"\n")
                            sys.stdout.buffer.flush()
                            initialized = True
                        elif request.get("method") == "initialized":
                            continue
                        elif (str(request.get("method", "")).startswith("account/login")
                              or request.get("method") == "account/logout"
                              or (request.get("method") == "getAuthStatus" and
                                  request.get("params", {}).get("includeToken") is True)):
                            raise LocalCodexAuthError(AUTH_ERROR)
                        else:
                            if request.get("method") == "getAuthStatus":
                                identity = request.get("id")
                                if isinstance(identity, bool) or not isinstance(identity, (str, int)):
                                    raise LocalCodexAuthError(AUTH_ERROR)
                                auth_status_requests.add(identity)
                            _send(process, request)
    except (OSError, subprocess.SubprocessError, RecursionError):
        raise LocalCodexAuthError(AUTH_ERROR) from None
    finally:
        _stop(process)
