#!/usr/bin/env python3
"""A bounded subscription proof, never a Symphony scheduler or live-task runner.

The trusted operator verifies the admitted Job/Pod and starts ``run`` using a
private kubectl exec stream. PID1 ``idle`` logs no authentication or RPC output.
The operator supplies a fresh prior terminal receipt on stdin (``{}`` for the
first enrollment). The whole slot PVC is retained; only Codex handles tokens.
"""
from __future__ import annotations

import argparse
from collections import deque
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import signal
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
PRIVATE = Path("/tmp/symphony-pilot")
SLOT = Path("/var/lib/symphony-auth/slot-01")
WORKSPACE = Path("/var/lib/symphony/workspaces/subscription-pilot")
CODEX = "/usr/local/bin/codex"
MAX_JSON = 1_048_576
STAGE_MAX_SECONDS = {"enrollment": 1500, "task": 900, "retire": 900}
# Pinned Codex polls device authorization for 900 seconds. Allow its completion
# notification a small grace period while retaining the absolute stage deadline.
ENROLLMENT_WAIT_SECONDS = 930
UID = re.compile(r"[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}")
RULES = b"This is an isolated subscription pilot. Complete only the fixed addition task. Never inspect credentials, modify instructions, access the network, install software or request more permissions.\n"
PROMPT = "Create only addition.py containing a function add(a, b) that returns the sum of two integers. Run a Python check for add(2, 3) == 5, add(-4, 4) == 0 and add(0, 0) == 0. Do not install anything, access the network, inspect credentials, change instructions or commit."
# This verifier runs ONLY through Codex's named inner command sandbox. Generated
# source is never imported/executed by the outer trusted wrapper.
VERIFY = '''import hashlib,json,pathlib,runpy
p=pathlib.Path("addition.py")
assert p.is_file() and not p.is_symlink() and p.stat().st_size <= 4096
m=runpy.run_path(str(p)); add=m["add"]
assert add(2,3)==5 and add(-4,4)==0 and add(0,0)==0
print(json.dumps({"passed":3,"artifact_sha256":hashlib.sha256(p.read_bytes()).hexdigest()},sort_keys=True))
'''


class PilotError(RuntimeError):
    """Fixed safe messages only; never include upstream RPC/authentication text."""


def rpc_error_summary(error):
    """Return only fixed categories and bounded protocol/status numbers."""
    if not isinstance(error, dict):
        return {"category": "invalid_rpc_error"}
    message = error.get("message", "")
    message = message.lower() if isinstance(message, str) else ""
    category = "provider_error"
    phrases = (("chatgpt login is disabled", "login_policy_denied"),
               ("external auth is active", "external_auth_forbidden"),
               ("device code login is not enabled", "device_login_unavailable"),
               ("dns", "dns_failure"), ("name resolution", "dns_failure"),
               ("certificate", "tls_failure"), ("tls", "tls_failure"),
               ("timed out", "network_timeout"), ("timeout", "network_timeout"),
               ("error sending request", "transport_failure"),
               ("connection", "connection_failure"), ("expected value", "invalid_provider_response"))
    for phrase, value in phrases:
        if phrase in message:
            category = value
            break
    result = {"category": category}
    code = error.get("code")
    if type(code) is int and -32768 <= code <= -32000:
        result["rpc_code"] = code
    status = re.search(r"device code request failed with status ([1-5][0-9]{2})(?:\s|$)", message)
    if status:
        result.update(category="device_auth_http_error", http_status=int(status.group(1)))
    return result


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


AUTH = load_module("symphony_pilot_auth", ROOT / "tools/kubernetes_auth.py")


def configuration():
    profile = load_module("symphony_pilot_profile", ROOT / "profiles/events-concierge/profile.py")
    return ('cli_auth_credentials_store = "file"\nforced_login_method = "chatgpt"\n'
            'web_search = "disabled"\n' + profile.permission_config()).encode()


def private_read(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or info.st_nlink != 1 or info.st_size > MAX_JSON):
            raise PilotError("Private pilot state is invalid")
        return json.loads(stream.read(MAX_JSON + 1))


def private_write(path, value):
    # PID1 alone writes boot.json; the sole exec owner of run.lock alone writes
    # complete.json, all under its private directory. Publish only complete JSON
    # so PID1's exists/read check cannot observe an empty or partially written file.
    if path.exists() or path.is_symlink():
        raise PilotError("Refusing to replace existing private pilot state")
    content = json.dumps(value, sort_keys=True).encode()
    descriptor, temporary = tempfile.mkstemp(prefix=".pilot-publish-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        AUTH._sync(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def identity():
    value = {"job_uid": os.environ.get("SYMPHONY_JOB_UID", ""),
             "pod_uid": os.environ.get("SYMPHONY_POD_UID", "")}
    if not all(UID.fullmatch(item) for item in value.values()):
        raise PilotError("Exact downward-API Job and Pod identities are required")
    return value


def validate_boot(boot, now=None):
    now = time.time() if now is None else now
    if (not isinstance(boot, dict) or set(boot) != {
            "owner", "stage", "generation", "expires_at", "created_at", "codex_version", "job_uid", "pod_uid"}
            or not isinstance(boot["owner"], str) or not re.fullmatch(r"[a-f0-9]{32}", boot["owner"])
            or boot["stage"] not in ("enrollment", "task", "retire")
            or type(boot["generation"]) is not int or boot["generation"] < 1
            or type(boot["expires_at"]) is not int or type(boot["created_at"]) is not int
            or not 1 <= boot["expires_at"] - boot["created_at"] <= STAGE_MAX_SECONDS[boot["stage"]]
            or not boot["created_at"] <= now < boot["expires_at"]
            or not isinstance(boot["codex_version"], str)
            or not re.fullmatch(r"0\.[0-9]+\.[0-9]+", boot["codex_version"])
            or {key: boot[key] for key in ("job_uid", "pod_uid")} != identity()):
        raise PilotError("Pilot identity, generation or absolute deadline is invalid")
    return boot


def read_receipt(stream):
    content = stream.read(MAX_JSON + 1)
    if len(content) > MAX_JSON:
        raise PilotError("Terminal receipt exceeded its size bound")
    try:
        value = json.loads(content)
    except (ValueError, UnicodeError):
        raise PilotError("Terminal receipt is not valid JSON") from None
    if not isinstance(value, dict):
        raise PilotError("Terminal receipt must be an object")
    return value


def retire_previous(slot, receipt, boot):
    status = slot.status()
    expected = boot["generation"] if boot["stage"] == "retire" else boot["generation"] - 1
    if status["generation"] != expected:
        raise PilotError("Auth generation does not match this pilot stage")
    claim = status["claim"]
    if claim is not None:
        if not receipt:
            raise PilotError("Previous owner needs fresh terminal Job and Pod evidence")
        if claim["job_uid"] == boot["job_uid"] or claim["pod_uid"] == boot["pod_uid"]:
            raise PilotError("A live stage cannot retire itself")
        slot.retire(claim["owner"], claim["generation"], receipt)
    elif receipt:
        raise PilotError("Unexpected terminal receipt without a previous claim")
    elif boot["stage"] == "retire":
        raise PilotError("The final claim is already retired")


class Heartbeat:
    def __init__(self, slot, claim, expires_at, clock=time.time, beat=lambda: None):
        self.slot, self.claim, self.expires_at, self.clock = slot, claim, expires_at, clock
        self.beat = beat
        self.next_renewal = clock() + 10

    def tick(self):
        now = self.clock()
        if now >= self.expires_at:
            raise PilotError("Pilot absolute deadline reached")
        if now >= self.next_renewal:
            self.slot.renew(self.claim["owner"], self.claim["generation"], ttl=60)
            self.next_renewal = now + 10
        self.beat()


class AppServer:
    def __init__(self, home, version, heartbeat):
        self.heartbeat = heartbeat
        self.environment = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": "/tmp/worker-home",
                            "CODEX_HOME": home, "GIT_CONFIG_NOSYSTEM": "1",
                            "GIT_CONFIG_GLOBAL": "/dev/null", "LANG": "C.UTF-8"}
        actual = subprocess.check_output([CODEX, "--version"], env=self.environment,
                                         stderr=subprocess.DEVNULL, timeout=10, text=True).strip()
        if actual != "codex-cli " + version:
            raise PilotError("Codex version differs from the reviewed pilot image")
        self.process = subprocess.Popen([CODEX, "app-server"], cwd=WORKSPACE, env=self.environment,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, start_new_session=True, bufsize=0)
        self.pending, self.next_id, self.total = b"", 0, 0
        self.notifications = deque(maxlen=64)
        self.auth_mode = None

    def close(self):
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=5)
        self.process.stdin.close()
        self.process.stdout.close()

    def send(self, message):
        self.heartbeat.tick()
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()

    def message(self, deadline):
        while True:
            self.heartbeat.tick()
            if time.monotonic() >= deadline:
                raise PilotError("Codex protocol operation timed out")
            if b"\n" in self.pending:
                line, self.pending = self.pending.split(b"\n", 1)
                value = json.loads(line)
                if not isinstance(value, dict):
                    raise PilotError("Codex protocol response was invalid")
                if "method" in value and "id" in value:
                    # Never approve permission escalation, external tokens or dynamic tools.
                    raise PilotError("Unexpected server request; pilot execution stopped")
                if value.get("method") == "account/updated":
                    self.auth_mode = value.get("params", {}).get("authMode")
                return value
            if select.select([self.process.stdout], [], [], min(0.5, max(0, deadline-time.monotonic())))[0]:
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise PilotError("Codex exited before completing the protocol")
                self.total += len(chunk)
                self.pending += chunk
                if len(self.pending) > MAX_JSON or self.total > 64 * MAX_JSON:
                    raise PilotError("Codex protocol output exceeded its bound")

    def rpc(self, method, params, timeout=45):
        self.next_id += 1
        request_id = self.next_id
        self.send({"id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while True:
            value = self.message(deadline)
            if value.get("id") == request_id:
                if "error" in value or "result" not in value:
                    summary = rpc_error_summary(value.get("error"))
                    raise PilotError("Codex rejected the " + method + " request: " + json.dumps(summary, sort_keys=True))
                return value["result"]
            if "method" in value:
                self.notifications.append(value)

    def wait(self, method, predicate, timeout):
        deadline = time.monotonic() + timeout
        while True:
            for value in list(self.notifications):
                if value.get("method") == method and predicate(value.get("params", {})):
                    self.notifications.remove(value)
                    return value["params"]
            value = self.message(deadline)
            if "method" in value:
                self.notifications.append(value)

    def initialize(self):
        self.rpc("initialize", {"clientInfo": {"name": "symphony-subscription-pilot", "version": "1"},
                                "capabilities": {"experimentalApi": True}})
        self.send({"method": "initialized", "params": {}})


def enroll(client, emit):
    login = client.rpc("account/login/start", {"type": "chatgptDeviceCode"})
    url = urlsplit(login.get("verificationUrl", ""))
    if (login.get("type") != "chatgptDeviceCode" or not isinstance(login.get("loginId"), str)
            or url.scheme != "https" or url.hostname != "auth.openai.com" or url.username or url.password
            or url.port not in (None, 443) or url.path != "/codex/device" or url.query or url.fragment
            or not re.fullmatch(r"[A-Z0-9]{4}-[A-Z0-9]{5}|[A-Z0-9]{4}-[A-Z0-9]{4}", login.get("userCode", ""))):
        raise PilotError("Device enrollment response did not match the expected provider")
    emit({"verification_url": login["verificationUrl"], "user_code": login["userCode"],
          "login_wait_timeout_seconds": ENROLLMENT_WAIT_SECONDS})
    result = client.wait("account/login/completed", lambda params: params.get("loginId") == login["loginId"],
                         ENROLLMENT_WAIT_SECONDS)
    if result.get("success") is not True:
        raise PilotError("Device enrollment did not complete successfully")


def verify_subscription(client, slot, claim):
    # In pinned 0.153.4 account/read requests refresh but can return cached account
    # state after a transient refresh failure. It does not emit account/updated.
    # getAuthStatus explicitly excludes tokens; rateLimits/read makes a provider
    # request, proving current acceptance without claiming refresh-token rotation.
    account = client.rpc("account/read", {"refreshToken": True})
    status = client.rpc("getAuthStatus", {"includeToken": False, "refreshToken": False})
    if (status.get("authMethod") != "chatgpt" or status.get("authToken") is not None
            or status.get("requiresOpenaiAuth") is not True):
        raise PilotError("Codex-managed token-free ChatGPT authentication was not verified")
    limits = client.rpc("account/rateLimits/read", None)
    if not isinstance(limits, dict) or not isinstance(limits.get("rateLimits"), dict) or not limits["rateLimits"]:
        raise PilotError("Provider-backed subscription authentication was not verified")
    slot.verify_account(claim["owner"], claim["generation"], account, status["authMethod"])


def task(client):
    thread = client.rpc("thread/start", {"cwd": str(WORKSPACE), "model": "gpt-6-astra",
                                       "approvalPolicy": "never", "ephemeral": True,
                                       "config": {"default_permissions": "symphony-builder"}})
    if (not thread.get("thread", {}).get("id") or thread.get("activePermissionProfile") != {
            "id": "symphony-builder", "extends": ":workspace"}):
        raise PilotError("The reviewed inner permission profile was not selected")
    thread_id = thread["thread"]["id"]
    started = time.monotonic()
    turn = client.rpc("turn/start", {"threadId": thread_id, "model": "gpt-6-astra", "effort": "medium",
                                     "approvalPolicy": "never", "input": [{"type": "text", "text": PROMPT}]})
    turn_id = turn.get("turn", {}).get("id")
    if not isinstance(turn_id, str) or not turn_id:
        raise PilotError("Codex returned no model turn identity")
    completed = client.wait("turn/completed", lambda params: params.get("threadId") == thread_id
                            and params.get("turn", {}).get("id") == turn_id,
                            max(0, 180 - (time.monotonic() - started)))
    if completed.get("turn", {}).get("status") != "completed":
        raise PilotError("The model turn did not complete successfully")
    result = client.rpc("command/exec", {"command": ["/usr/local/bin/python3", "-I", "-c", VERIFY],
                                         "cwd": str(WORKSPACE), "timeoutMs": 10000}, timeout=20)
    if result.get("exitCode") != 0:
        raise PilotError("Independent sandbox verification failed")
    try:
        observed = json.loads(result["stdout"])
    except (KeyError, ValueError):
        raise PilotError("Sandbox verifier did not return the expected evidence") from None
    if (set(observed) != {"passed", "artifact_sha256"} or observed["passed"] != 3
            or not re.fullmatch(r"[a-f0-9]{64}", observed["artifact_sha256"])):
        raise PilotError("Sandbox verification evidence was invalid")
    return {"model_turn_completed": True, "independent_tests_passed": 3,
            "artifact_sha256": observed["artifact_sha256"]}


def run_stage(boot, receipt, emit):
    validate_boot(boot)
    slot = AUTH.AuthSlot(SLOT)
    if not SLOT.exists():
        if boot["stage"] != "enrollment" or boot["generation"] != 1 or receipt:
            raise PilotError("Only the initial enrollment may create an auth slot")
        slot.initialize()
    retire_previous(slot, receipt, boot)
    if boot["stage"] == "retire":
        return {"stage": "retire", "generation": boot["generation"], "claim_retired": True}
    if any(key in os.environ for key in ("OPENAI_API_KEY", "CODEX_API_KEY")):
        raise PilotError("API-key environment is forbidden for this subscription pilot")
    if WORKSPACE.resolve() != WORKSPACE or not WORKSPACE.is_dir() or any(WORKSPACE.iterdir()):
        raise PilotError("Each pilot stage requires a fresh isolated empty workspace")
    Path("/tmp/worker-home").mkdir(mode=0o700, exist_ok=True)
    claim = slot.claim(boot["owner"], "enrollment" if boot["stage"] == "enrollment" else "builder",
                       boot["job_uid"], boot["pod_uid"], configuration(), RULES,
                       enrollment=boot["stage"] == "enrollment", ttl=60)
    if claim["generation"] != boot["generation"]:
        raise PilotError("Claim generation changed unexpectedly")
    heartbeat = Heartbeat(slot, claim, boot["expires_at"],
                          beat=lambda: os.utime(PRIVATE / "run.lock", None, follow_symlinks=False))
    client = None
    try:
        client = AppServer(claim["codex_home"], boot["codex_version"], heartbeat)
        client.initialize()
        if boot["stage"] == "enrollment":
            enroll(client, emit)
        verify_subscription(client, slot, claim)
        result = {"stage": boot["stage"], "generation": claim["generation"],
                  "subscription_verified": True, "provider_auth_verified": True, "refresh_requested": True}
        if boot["stage"] == "task":
            result.update(task(client))
        return result
    finally:
        if client is not None:
            client.close()


def idle(args):
    created = int(time.time())
    boot = validate_boot({"owner": args.owner, "stage": args.stage, "generation": args.generation,
                          "expires_at": args.expires_at, "created_at": created,
                          "codex_version": args.codex_version, **identity()})
    PRIVATE.mkdir(mode=0o700, exist_ok=False)
    private_write(PRIVATE / "boot.json", boot)
    started = False
    while time.time() < boot["expires_at"]:
        if (PRIVATE / "complete.json").exists():
            result = private_read(PRIVATE / "complete.json")
            return record_stop("completed", 0 if result == {"success": True} else 1)
        if not healthy_watchdog(PRIVATE / "run.lock", started=started):
            # PID1 exits, so the runtime stops every container process. This
            # independently bounds an exec client's death or stuck heartbeat.
            return record_stop("watchdog", 1)
        started = started or (PRIVATE / "run.lock").exists()
        time.sleep(0.2)
    return record_stop("deadline", 1)


def record_stop(reason, exit_code):
    # PID1 logs only fixed lifecycle categories, never exec/authentication output.
    if reason not in ("completed", "watchdog", "deadline") or exit_code not in (0, 1):
        raise PilotError("Invalid pilot stop category")
    print(json.dumps({"pilot_stop": reason, "exit_code": exit_code}, sort_keys=True), flush=True)
    return exit_code


def healthy_watchdog(path, now=None, *, started=False):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return not started  # A missing heartbeat after launch is never healthy.
    # The exec process can refresh mtime concurrently. Sampling time before lstat
    # can make a new heartbeat appear to be in the future and kill a healthy Pod.
    now = time.time() if now is None else now
    return (stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
            and not info.st_mode & 0o077 and info.st_nlink == 1
            and 0 <= now - info.st_mtime <= 30)


def run():
    boot = validate_boot(private_read(PRIVATE / "boot.json"))
    # The lock covers the entire exec lifetime, never merely individual RPCs.
    lock = os.open(PRIVATE / "run.lock", os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        receipt = read_receipt(sys.stdin.buffer)
        result = run_stage(boot, receipt, lambda value: print(json.dumps(value), flush=True))
        print(json.dumps(result, sort_keys=True), flush=True)
        private_write(PRIVATE / "complete.json", {"success": True})
        return 0
    except (Exception, KeyboardInterrupt):
        private_write(PRIVATE / "complete.json", {"success": False})
        raise
    finally:
        os.close(lock)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    boot = actions.add_parser("idle")
    boot.add_argument("--owner", required=True)
    boot.add_argument("--stage", choices=("enrollment", "task", "retire"), required=True)
    boot.add_argument("--generation", type=int, required=True)
    boot.add_argument("--expires-at", type=int, required=True)
    boot.add_argument("--codex-version", default="0.153.4")
    actions.add_parser("run")
    args = parser.parse_args()
    def interrupted(_signal, _frame):
        raise PilotError("Pilot interrupted")
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, interrupted)
    try:
        return idle(args) if args.action == "idle" else run()
    except (PilotError, AUTH.AuthSlotError) as error:
        # Both local exception classes contain only deliberately safe messages.
        print("Subscription pilot blocked: " + str(error), file=sys.stderr)
        return 1
    except (Exception, KeyboardInterrupt):
        # Exceptions may contain subprocess responses or private paths. Print a
        # fixed operator message only, retaining auth claims for reconciliation.
        print("Subscription pilot failed; retain ownership and inspect the exact Job termination.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
