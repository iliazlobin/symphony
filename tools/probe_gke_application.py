#!/usr/bin/env python3
"""Exercise the real packaged app locally, without provider credentials or network.

This is a bounded HTTP/LiveView protocol smoke, not visual browser acceptance.
The only Docker resources touched are a newly labelled container and volume.
No host state, credentials, Docker socket or project checkout enters the image.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
from html.parser import HTMLParser
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import struct
import subprocess
import sys
import time
import urllib.parse

ROOT = "/var/lib/symphony"
LABEL = "com.symphony.application-probe"
PROJECT = "github:example/integration"
TITLE = "New chat"
MESSAGE = "Verify the explicit missing-sign-in state."
AUTH_ERROR = "Sign in to the dedicated management-chat Codex runtime, then try again."
LIMIT = 4_194_304
LOCAL_DOCKER_HOST = None


class DockerError(RuntimeError):
    def __init__(self, operation, diagnostic):
        self.diagnostic = diagnostic
        super().__init__("Docker operation failed: " + operation + "; " + diagnostic[-2000:])


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def workflow():
    return {
        "tracker": {"kind": "github", "project_slug": "example/integration",
                    "provider": {"repo": "example/integration", "api_url": "https://127.0.0.1:9",
                                 "token": "disposable-not-a-provider-credential"},
                    "active_states": ["open"], "terminal_states": ["closed"]},
        "control": {"enabled": True, "initial_mode": "paused", "state_path": ROOT + "/control.json"},
        "workspace": {"root": ROOT + "/workspaces"},
        "codex": {"command": "/bin/false"},
        "chat": {"enabled": True, "max_concurrent": 1, "timeout_ms": 15000,
                 "state_path": ROOT + "/chat", "codex_home": ROOT + "/chat-codex",
                 "executable": "/opt/symphony/bin/codex"},
        "server": {"host": "127.0.0.1", "port": 8080},
        "observability": {"dashboard_enabled": False}, "polling": {"interval_ms": 1000},
    }


class Page(HTMLParser):
    def __init__(self, text):
        super().__init__()
        self.csrf = None
        self.live = None
        self.design_editor = None
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "meta" and attrs.get("name") == "csrf-token":
            self.csrf = attrs.get("content")
        if "data-phx-main" in attrs:
            self.live = attrs
        if "data-design-editor-js" in attrs:
            self.design_editor = attrs


class Browser:
    """A cookie-preserving loopback HTTP client; never follows redirects."""
    def __init__(self):
        self.cookies = {}

    def request(self, path, fields=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", 8080, timeout=10)
        values = {"Cookie": self.cookie()}
        values.update(headers or {})
        data = urllib.parse.urlencode(fields).encode() if fields is not None else None
        if data is not None:
            values.update({"Content-Type": "application/x-www-form-urlencoded", "Origin": "http://127.0.0.1:8080"})
        try:
            connection.request("POST" if data is not None else "GET", path, body=data, headers=values)
            response = connection.getresponse()
            body = response.read(LIMIT + 1)
            require(len(body) <= LIMIT, "HTTP response exceeded bound")
            for name, value in response.getheaders():
                if name.lower() == "set-cookie":
                    key, val = value.split(";", 1)[0].split("=", 1)
                    self.cookies[key] = val
            return response.status, body.decode("utf-8", errors="replace")
        finally:
            connection.close()

    def cookie(self):
        return "; ".join(key + "=" + value for key, value in self.cookies.items())


class LiveSocket:
    """Minimal bounded RFC6455 text transport for the observed Phoenix v2 events."""
    def __init__(self, browser, path):
        status, text = browser.request(path)
        page = Page(text)
        require(status == 200 and page.csrf and page.live, "LiveView HTTP bootstrap missing")
        self.sock = socket.create_connection(("127.0.0.1", 8080), timeout=10)
        self.pending = b""
        nonce = base64.b64encode(os.urandom(16)).decode()
        query = urllib.parse.urlencode({"_csrf_token": page.csrf, "vsn": "2.0.0"})
        request = ("GET /live/websocket?" + query + " HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n"
                   "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                   "Sec-WebSocket-Key: " + nonce + "\r\nOrigin: http://127.0.0.1:8080\r\n"
                   "Cookie: " + browser.cookie() + "\r\n\r\n")
        self.sock.sendall(request.encode())
        while b"\r\n\r\n" not in self.pending:
            chunk = self.sock.recv(4096)
            require(chunk, "WebSocket handshake closed unexpectedly")
            self.pending += chunk
            require(len(self.pending) < 65536, "WebSocket handshake exceeded bound")
        header, self.pending = self.pending.split(b"\r\n\r\n", 1)
        lines = header.decode().split("\r\n")
        headers = {key.lower(): value for key, value in (line.split(": ", 1) for line in lines[1:] if ": " in line)}
        accept = base64.b64encode(hashlib.sha1((nonce + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        require(lines[0].split()[1] == "101" and headers.get("sec-websocket-accept") == accept, "WebSocket handshake rejected")
        self.topic = "lv:" + page.live["id"]
        self.ref = 0
        self.join_ref = "1"
        self.join = self.call("phx_join", {"url": "http://127.0.0.1:8080" + path,
            "params": {"_csrf_token": page.csrf, "_mounts": 0, "_mount_attempts": 0},
            "session": page.live["data-phx-session"], "static": page.live.get("data-phx-static"), "flash": None})

    def exact(self, size):
        while len(self.pending) < size:
            data = self.sock.recv(min(65536, size - len(self.pending)))
            require(data, "WebSocket closed unexpectedly")
            self.pending += data
        result, self.pending = self.pending[:size], self.pending[size:]
        return result

    def send(self, payload, opcode=1):
        require(len(payload) <= LIMIT, "WebSocket send exceeded bound")
        mask = os.urandom(4)
        size = len(payload)
        length = bytes([size | 128]) if size < 126 else (b"\xfe" + struct.pack("!H", size) if size <= 65535 else b"\xff" + struct.pack("!Q", size))
        self.sock.sendall(bytes([128 | opcode]) + length + mask + bytes(value ^ mask[index % 4] for index, value in enumerate(payload)))

    def receive(self):
        fragments = bytearray()
        while True:
            first, second = self.exact(2)
            opcode, size = first & 15, second & 127
            require(not first & 112 and not second & 128, "Unsupported WebSocket frame")
            if size in (126, 127):
                size = int.from_bytes(self.exact(2 if size == 126 else 8), "big")
            require(size <= LIMIT and size + len(fragments) <= LIMIT, "WebSocket response exceeded bound")
            payload = self.exact(size)
            if opcode == 9:
                require(size <= 125 and first & 128, "Invalid WebSocket ping")
                self.send(payload, 10)
                continue
            if opcode == 10:
                continue
            require(opcode in (0, 1), "WebSocket ended or sent nontext data")
            fragments.extend(payload)
            if first & 128:
                return json.loads(fragments)

    def call(self, event, payload):
        self.ref += 1
        reference = str(self.ref)
        self.send(json.dumps([self.join_ref, reference, self.topic, event, payload]).encode())
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            message = self.receive()
            if message[2] != self.topic:
                continue
            if message[1] == reference and message[3] == "phx_reply":
                require(message[4].get("status") == "ok", "LiveView event failed")
                return message[4].get("response", {})
            require(message[3] not in ("phx_error", "phx_close"), "LiveView topic ended: " + message[3])
        raise RuntimeError("LiveView event timed out")

    def event(self, cid, name, values=None):
        return self.call("event", {"type": "form" if values is not None else "click", "event": name,
            "value": urllib.parse.urlencode(values) if values is not None else {}, "cid": cid})

    def close(self):
        self.sock.close()


def chat_component(join):
    components = join.get("rendered", {}).get("c", {})
    matches = [int(cid) for cid, component in components.items() if "chat-app" in json.dumps(component)]
    require(len(matches) == 1, "Expected the real shared chat component")
    return matches[0]


def records():
    files = list(Path(ROOT + "/chat").glob("*.json"))
    require(1 <= len(files) <= 2, "Unexpected persistent conversation count")
    saved = [json.loads(path.read_text()) for path in files]
    require(all(chat["project_id"] == PROJECT and chat.get("conversation_role") in ("legacy", "main")
                and chat.get("task_id") is None and path.stem == chat["id"]
                for path, chat in zip(files, saved)), "Unexpected persistent conversation scope")
    return saved


def record(chat_id=None, role="legacy"):
    selected = [chat for chat in records() if chat["conversation_role"] == role
                and (chat_id is None or chat["id"] == chat_id)]
    require(len(selected) == 1, "Expected exactly one persistent " + role + " conversation")
    return selected[0]


def design_assets(browser):
    """Read the normal Idea page and its embedded native-editor dependencies."""
    path = "/?" + urllib.parse.urlencode({"view": "idea", "project": PROJECT})
    status, body = browser.request(path)
    editor = Page(body).design_editor
    require(status == 200 and editor, "Packaged Idea editor bootstrap missing")
    base = editor.get("data-design-editor-assets", "")
    require(re.fullmatch(r"/design-editor/[0-9a-f]{12}/", base), "Design asset path escaped the package")
    entry = editor.get("data-design-editor-js", "")
    stylesheet = editor.get("data-design-editor-css", "")
    require(re.fullmatch(re.escape(base) + r"editor-[A-Z0-9]+\.js", entry), "Design entry escaped the package")
    require(re.fullmatch(re.escape(base) + r"editor-[A-Z0-9]+\.css", stylesheet), "Design stylesheet escaped the package")
    status, code = browser.request(entry)
    require(status == 200 and code, "Packaged native editor JavaScript missing")
    imports = set(re.findall(r'\bfrom\s*["\'](\./chunks/[A-Za-z0-9_-]+\.js)["\']', code))
    require(0 < len(imports) <= 16, "Native editor entry chunks missing or unbounded")
    for target in sorted(imports):
        status, chunk = browser.request(base + target[2:])
        require(status == 200 and chunk, "Packaged native editor chunk missing: " + target)
    status, css = browser.request(stylesheet)
    require(status == 200 and css, "Packaged native editor CSS missing")
    fonts = re.findall(r'url\(["\']?(\./files/[A-Za-z0-9_-]+\.woff2)', css)
    require(fonts, "Native editor stylesheet font missing")
    status, font = browser.request(base + fonts[0][2:])
    require(status == 200 and font, "Packaged native editor font missing")
    status, _body = browser.request(base + "manifest.json")
    require(status == 404, "Native editor source manifest was exposed")


def inside(phase):
    require(os.getuid() == 10001, "Probe must share the application's unprivileged identity")
    require(not Path(ROOT + "/chat-codex/auth.json").exists(), "Provider credentials must be absent")
    browser = Browser()
    deadline = time.monotonic() + 90
    while True:
        try:
            status, body = browser.request("/api/v1/state")
            if status == 200:
                break
        except OSError:
            pass
        require(time.monotonic() < deadline, "Normal application did not become ready")
        time.sleep(0.2)
    require(json.loads(body)["counts"] == {"running": 0, "retrying": 0, "blocked": 0}, "Unexpected task runtime activity")
    for path in ("/", "/chat", "/?assistant=1", "/dashboard.css", "/dashboard.js", "/favicon.png", "/vendor/phoenix_html/phoenix_html.js", "/vendor/phoenix/phoenix.js", "/vendor/phoenix_live_view/phoenix_live_view.js"):
        status, body = browser.request(path)
        require(status == 200 and body, "Packaged route or asset missing: " + path)
    path = "/chat?" + urllib.parse.urlencode({"project": PROJECT})
    locked = LiveSocket(browser, path)
    require("Unlock chat" in json.dumps(locked.join), "Unauthenticated chat was not locked")
    locked.close()
    _, page = browser.request(path)
    status, _ = browser.request("/operator/session", {"_csrf_token": Page(page).csrf, "operator_token": os.environ["SYMPHONY_CONTROL_TOKEN"], "return_to": "/chat"})
    require(status == 302, "CSRF-protected loopback login failed")
    status, control = browser.request("/api/v1/control", headers={"Authorization": "Bearer " + os.environ["SYMPHONY_CONTROL_TOKEN"]})
    require(status == 200 and json.loads(control)["mode"] == "paused" and json.loads(control)["issues"] == {}, "Real controller was not paused and empty")
    design_assets(browser)
    if phase == "recover":
        saved = record()
        path += "&chat=" + saved["id"]
    live = LiveSocket(browser, path)
    cid = chat_component(live.join)
    require("new-chat-button" in json.dumps(live.join), "Real Chat.Store controls were unavailable")
    if phase == "create":
        live.event(cid, "new-chat")
        live.event(cid, "send-message", {"message": MESSAGE})
        deadline = time.monotonic() + 25
        while record()["status"] == "running" and time.monotonic() < deadline:
            time.sleep(0.1)
    saved = record()
    require(saved["title"] == TITLE and saved["project_id"] == PROJECT, "Conversation identity did not persist")
    require(saved["status"] == "error" and saved["error"] == AUTH_ERROR, "Real Codex did not report missing subscription sign-in")
    require(saved["codex_thread_id"] is None and saved["proposals"] == [] and saved.get("usage") is None, "Unexpected model or task action")
    require([m["text"] for m in saved["messages"]] == [MESSAGE, ""], "Persistent messages did not match the no-model check")
    if phase == "recover":
        require(MESSAGE in json.dumps(live.join) and AUTH_ERROR in json.dumps(live.join), "Restarted LiveView did not recover conversation summary/content")
    live.close()
    require(len(records()) == (1 if phase == "create" else 2), "Unexpected journal count before canonical board selection")
    previous_main_id = record(role="main")["id"] if phase == "recover" else None
    embedded = LiveSocket(browser, "/?" + urllib.parse.urlencode({"project": PROJECT}))
    chat_component(embedded.join)
    canonical = record(role="main")
    require(len(records()) == 2 and record(saved["id"]) == saved, "Board selection changed standalone history or created extra conversations")
    require(canonical["title"] == "Project agent" and canonical["project_id"] == PROJECT
            and canonical["status"] == "idle" and canonical["messages"] == [] and canonical["proposals"] == []
            and canonical["codex_thread_id"] is None and canonical.get("usage") is None,
            "Canonical project conversation was not idle, scoped and provider-free")
    require(previous_main_id is None or previous_main_id == canonical["id"], "Restart replaced the canonical project conversation")
    require("project-agent-breadcrumb" in json.dumps(embedded.join) and canonical["id"] in json.dumps(embedded.join),
            "Board did not render its canonical project-agent conversation")
    shared = LiveSocket(browser, "/chat?" + urllib.parse.urlencode({"project": PROJECT, "chat": canonical["id"]}))
    chat_component(shared.join)
    require(canonical["id"] in json.dumps(shared.join) and canonical["title"] in json.dumps(shared.join)
            and record(canonical["id"], "main") == canonical and record(saved["id"]) == saved,
            "Standalone chat did not reopen the unchanged canonical project conversation")
    shared.close()
    settings = embedded.call("event", {"type": "click", "event": "open-settings", "value": {}})
    require(all(marker in json.dumps(settings) for marker in ("settings-execution", "settings-ai", "settings-connections", "Service available")), "Real Settings panel or Chat.Store health did not load")
    embedded.call("event", {"type": "click", "event": "settings-tab", "value": {"tab": "connections"}})
    embedded.close()
    journal = json.loads(Path(ROOT + "/control.json").read_text())
    require(journal["mode"] == "paused" and journal["issues"] == {}, "Task ledger changed during chat probe")
    require(not Path(ROOT + "/chat-codex/auth.json").exists(), "Probe unexpectedly created authentication")
    print(json.dumps({"phase": phase, "chat_id": saved["id"], "canonical_chat_id": canonical["id"], "normal_app": True, "provider_auth": False, "model_calls": False, "task_admission": False}))


def image_reference(value):
    if not re.fullmatch(r"(?:sha256:|[A-Za-z0-9./:_-]+@sha256:)[0-9a-f]{64}", value):
        raise argparse.ArgumentTypeError("Use an immutable local image ID or repository digest, never a tag")
    return value


def local_docker_host():
    context = os.environ.get("DOCKER_CONTEXT")
    host = None if context else os.environ.get("DOCKER_HOST")
    if not host:
        if not context:
            context = subprocess.run(["docker", "context", "show"], check=True, capture_output=True, text=True, timeout=10).stdout.strip()
        result = subprocess.run(["docker", "context", "inspect", "--format", "{{json .Endpoints.docker.Host}}", context], check=True, capture_output=True, text=True, timeout=10)
        host = json.loads(result.stdout)
    require(isinstance(host, str), "Docker endpoint is unavailable")
    uri = urllib.parse.urlsplit(host)
    require(uri.scheme == "unix" and not uri.netloc and uri.path.startswith("/") and not uri.query and not uri.fragment and "\x00" not in host, "Application probe requires a local Unix-socket Docker endpoint")
    return host


def docker(arguments, data=None, timeout=120):
    require(LOCAL_DOCKER_HOST is not None, "Local Docker endpoint was not pinned")
    environment = {key: value for key, value in os.environ.items() if key not in ("DOCKER_HOST", "DOCKER_CONTEXT")}
    result = subprocess.run(["docker", "--host", LOCAL_DOCKER_HOST, *arguments], env=environment, input=data, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise DockerError(arguments[0], result.stderr)
    return result.stdout.strip()


def check_owner(kind, name, owner, missing_ok=False):
    try:
        value = json.loads(docker([kind, "inspect", name]))[0]
    except DockerError as error:
        if missing_ok and "no such " + kind in error.diagnostic.lower():
            return None
        raise
    labels = value.get("Labels") if kind == "volume" else value.get("Config", {}).get("Labels")
    require((labels or {}).get(LABEL) == owner, "Refusing cleanup of a resource not owned by this probe")
    return value


def initialization_script():
    return "import os,pathlib,sys; r=pathlib.Path('/var/lib/symphony'); os.chown(r,0,0); p=r/'WORKFLOW.md'; p.write_text(sys.stdin.read()); os.chmod(p,0o600); os.chown(p,10001,10001); os.chmod(r,0o700); os.chown(r,10001,10001)"


def cancelled(signum, _frame):
    signal.signal(signum, signal.SIG_IGN)
    raise RuntimeError("Application probe interrupted; cleaning up its disposable resources")


def run(image):
    global LOCAL_DOCKER_HOST
    LOCAL_DOCKER_HOST = local_docker_host()
    docker(["image", "inspect", image])
    owner = secrets.token_hex(16)
    name = "symphony-app-probe-" + owner
    volume = name + "-state"
    source = Path(__file__).read_text()
    token = secrets.token_hex(32)
    volume_intent = False
    container_intents = set()
    results = []
    try:
        volume_intent = True
        docker(["volume", "create", "--label", LABEL + "=" + owner, volume])
        content = "---\n" + json.dumps(workflow()) + "\n---\nDisposable packaged application check.\n"
        initializer = name + "-initialize"
        container_intents.add(initializer)
        docker(["run", "--rm", "--name", initializer, "--label", LABEL + "=" + owner, "-i", "--pull", "never", "--network", "none", "--user", "0:0", "--read-only", "--cap-drop", "ALL", "--cap-add", "CHOWN", "--security-opt", "no-new-privileges", "--mount", "type=volume,source=" + volume + ",target=" + ROOT, "--entrypoint", "python3", image, "-I", "-c", initialization_script()], content)
        container_intents.remove(initializer)
        for phase in ("create", "recover"):
            container_intents.add(name)
            docker(["run", "-d", "--pull", "never", "--name", name, "--label", LABEL + "=" + owner,
                    "--network", "none", "--user", "10001:10001", "--read-only", "--cap-drop", "ALL",
                    "--security-opt", "no-new-privileges", "--pids-limit", "256", "--memory", "2g", "--cpus", "2",
                    "--tmpfs", "/tmp:rw,nosuid,size=256m,mode=1777", "--mount", "type=volume,source=" + volume + ",target=" + ROOT,
                    "--env", "SYMPHONY_CONTROL_TOKEN=" + token, image, "serve", "--workflow", ROOT + "/WORKFLOW.md", "--state-root", ROOT])
            evidence = docker(["exec", "-i", "--user", "10001:10001", name, "python3", "-I", "-", "--inside", phase], source, timeout=150)
            results.append(json.loads(evidence))
            check_owner("container", name, owner)
            docker(["stop", "--time", "20", name], timeout=30)
            docker(["rm", name])
            container_intents.remove(name)
        require(results[0]["chat_id"] == results[1]["chat_id"], "Restart changed conversation identity")
        require(results[0]["canonical_chat_id"] == results[1]["canonical_chat_id"], "Restart changed canonical project conversation identity")
        return {"image": image, "checks": results, "scope": "isolated local HTTP/LiveView protocol; no visual browser or cloud acceptance"}
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        for owned in container_intents:
            try:
                if check_owner("container", owned, owner, missing_ok=True):
                    diagnostic = docker(["logs", "--tail", "20", owned], timeout=10)
                    if diagnostic:
                        print("Disposable application log: " + diagnostic[-2000:], file=sys.stderr)
            except (OSError, RuntimeError, subprocess.SubprocessError):
                pass
        raise
    finally:
        for owned in container_intents:
            if check_owner("container", owned, owner, missing_ok=True):
                docker(["stop", "--time", "20", owned], timeout=30)
                docker(["rm", owned])
        if volume_intent and check_owner("volume", volume, owner, missing_ok=True):
            docker(["volume", "rm", volume])


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--inside" and sys.argv[2] in ("create", "recover"):
        inside(sys.argv[2])
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True, type=image_reference)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, cancelled)
    print(json.dumps(run(args.image), indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("Application probe failed: " + str(error), file=sys.stderr)
        sys.exit(1)
