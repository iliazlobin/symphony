#!/usr/bin/env python3
"""One public workspace listener supervising project engines on private Unix sockets."""
from __future__ import annotations

import argparse
import asyncio
import base64
import contextlib
import fcntl
import hashlib
import json
import ipaddress
import os
from pathlib import Path
import re
import secrets
import select
import signal
import stat
import subprocess
import sys
import time
import urllib.parse

from yarl import URL
from aiohttp import ClientError, ClientSession, ClientTimeout, DummyCookieJar, UnixConnector, WSMsgType, web
import yaml

from symphony_control import ControlError, load_config, read_private

ROOT = Path(__file__).resolve().parents[1]
MAX_BODY = 1_048_576
HOP_HEADERS = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade"}
SLUG = re.compile(r"[a-z0-9][a-z0-9-]{0,79}")


def private_directory(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) & 0o077):
        raise ControlError("Workspace state must be an owned mode-0700 directory")


def load_workspace(path):
    config = json.loads(read_private(Path(path)))
    origin = urllib.parse.urlsplit(config.get("public_origin", ""))
    if (not isinstance(config.get("public_origin"), str) or re.search(r"[\s\x00-\x1f\x7f\\]", config["public_origin"])
            or origin.scheme not in ("http", "https") or not origin.hostname or origin.username
            or origin.password or origin.path or origin.query or origin.fragment
            or (origin.scheme == "http" and origin.hostname not in ("localhost", "127.0.0.1", "::1"))):
        raise ControlError("Workspace needs one bare HTTPS or loopback HTTP public origin")
    listen_port = config.get("listen_port", origin.port or (443 if origin.scheme == "https" else 80))
    if type(listen_port) is not int or not 1 <= listen_port <= 65535:
        raise ControlError("Workspace needs one valid listen_port")
    if origin.scheme == "http" and config.get("bind_host", "127.0.0.1") not in ("localhost", "127.0.0.1", "::1"):
        raise ControlError("HTTP workspace origins may bind only to loopback")
    projects = config.get("projects")
    if not isinstance(projects, list) or not 1 <= len(projects) <= 20:
        raise ControlError("Workspace needs 1 to 20 registered project configurations")
    registered, policy, state_dirs = {}, None, set()
    for item in projects:
        project = load_config(item["config"])
        slug = project["repository"].split("/")[-1]
        if not SLUG.fullmatch(slug) or slug in registered:
            raise ControlError("Workspace project slugs must be unique and safe")
        if Path(project["profile_bin"]).resolve() != (ROOT / "profiles" / slug / "profile.py").resolve():
            raise ControlError("Workspace project must use this release's reviewed profile")
        state_dir = str(Path(project["state_dir"]).resolve())
        if state_dir in state_dirs:
            raise ControlError("Workspace projects must retain distinct private state directories")
        state_dirs.add(state_dir)
        settings = yaml.safe_load(read_private(Path(project["workflow_path"])).split("---\n", 2)[1])
        browser = settings.get("browser_auth", {})
        if browser.get("provider") != "google":
            raise ControlError("Shared workspace sessions require reviewed Google browser identity")
        identity_policy = {key: browser.get(key) for key in ("provider", "client_id", "client_secret", "allowed_emails", "allowed_subjects", "trusted_proxy_ips")}
        identity_policy["credential_file"] = project.get("google_oauth_client_file")
        if policy is not None and identity_policy != policy:
            raise ControlError("Workspace projects must share the same reviewed browser admission policy")
        policy = identity_policy
        project["_workspace_publication"] = item.get("publication", False) is True
        registered[slug] = project
    state = Path(config["state_dir"]).expanduser()
    private_directory(state)
    # macOS Unix socket paths must fit 104 bytes; no project state is moved here.
    runtime = Path("/private/tmp" if sys.platform == "darwin" else "/tmp") / ("symphony-workspace-" + hashlib.sha256(str(state).encode()).hexdigest()[:16])
    private_directory(runtime)
    return {**config, "projects": registered, "origin": origin, "runtime": runtime, "secret_file": state / "cookie-key", "listen_port": listen_port}



class SessionBroker:
    """One bounded revocable grant owner; engine crashes do not reset browser grants."""
    def __init__(self, capacity=1000, clock=time.monotonic):
        self.entries, self.capacity, self.clock = {}, capacity, clock

    def execute(self, command):
        now = self.clock()
        self.entries = {key: value for key, value in self.entries.items() if value[2] > now}
        op, identity = command.get("op"), command.get("id")
        if op == "revoke":
            self.entries.pop(identity, None)
            return {"ok": True}
        if op == "issue" and command.get("kind") in ("flow", "session") and valid_value(command.get("value")):
            if len(self.entries) >= self.capacity:
                return {"error": "capacity"}
            identity = secrets.token_urlsafe(32)
            kind = command["kind"]
            self.entries[identity] = (kind, command["value"], now + (600 if kind == "flow" else 28800))
            return {"id": identity}
        entry = self.entries.get(identity) if isinstance(identity, str) else None
        if op == "get" and entry and entry[0] == command.get("kind"):
            if entry[0] == "flow":
                self.entries[identity] = ("completing", entry[1], entry[2])
            return {"value": entry[1]}
        if op == "complete_flow" and entry and entry[0] == "completing" and valid_value(command.get("value")):
            self.entries[identity] = ("session", command["value"], now + 28800)
            return {"id": identity}
        return {"error": "expired"}

    async def handle(self, request):
        try:
            command = await request.json()
            if not isinstance(command, dict):
                raise ValueError()
            return web.json_response(self.execute(command))
        except (ValueError, TypeError):
            raise web.HTTPBadRequest(text="Invalid session operation") from None


def valid_value(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 90_000:
        return False
    try:
        return len(base64.b64decode(value, validate=True)) <= 65_536
    except ValueError:
        return False


def clean_headers(headers):
    nominated = {part.strip().lower() for part in headers.get("Connection", "").split(",")}
    return [(key, value) for key, value in headers.items()
            if key.lower() not in HOP_HEADERS | nominated | {"x-symphony-workspace", "content-length"}]


class OwnedProcess:
    """Keep a group leader unreaped until group cleanup prevents identity reuse."""
    def __init__(self, *command, **options):
        if not hasattr(select, "kqueue") and not hasattr(os, "waitid"):
            raise ControlError("Cannot observe owned child exit safely on this platform")
        self.process = subprocess.Popen(command, **options)
        self.exit_observed, self.exit_queue = False, None
        self.wait_lock = asyncio.Lock()
        if hasattr(select, "kqueue"):
            self.exit_queue = select.kqueue()
            try:
                self.exit_queue.control([select.kevent(self.pid, filter=select.KQ_FILTER_PROC,
                                                       flags=select.KQ_EV_ADD, fflags=select.KQ_NOTE_EXIT)], 0, 0)
            except ProcessLookupError:
                self.exit_observed = True

    @property
    def pid(self):
        return self.process.pid

    @property
    def returncode(self):
        # Never poll here: reaping would free the group identity before cleanup.
        return self.process.returncode

    def exited(self):
        if not self.exit_observed:
            if self.exit_queue is not None:
                self.exit_observed = bool(self.exit_queue.control(None, 1, 0))
            else:
                self.exit_observed = os.waitid(os.P_PID, self.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None
        return self.exit_observed

    def signal_group(self, sig):
        if self.returncode is not None:
            return
        try:
            os.killpg(self.pid, sig)
        except ProcessLookupError:
            pass
        except PermissionError:
            # macOS returns EPERM for an already-dead group. Its direct leader
            # remains ours and unreaped until wait completes group cleanup.
            if not self.exited():
                raise

    async def wait(self):
        async with self.wait_lock:
            if self.returncode is not None:
                return self.returncode
            while not self.exited():
                await asyncio.sleep(0.05)
            for sig in (signal.SIGTERM, signal.SIGKILL):
                self.signal_group(sig)
                if sig == signal.SIGTERM:
                    await asyncio.sleep(0.2)
            # No await between final group signal and reap. The leader's PID stays
            # reserved even after guard-only death, including fast child exits.
            result = self.process.wait(timeout=2)
            if self.exit_queue is not None:
                self.exit_queue.close()
                self.exit_queue = None
            return result


class Workspace:
    def __init__(self, config):
        self.config = config
        self.children, self.clients, self.monitors, self.owner_pipes = {}, {}, [], {}
        self.stopping = False
        self.auth_runner, self.lock_fd = None, None
        self.broker = SessionBroker()

    def select(self, request):
        path = request.path
        if path.startswith("/projects/"):
            if not request.raw_path.startswith("/projects/"):
                raise web.HTTPNotFound(text="Unknown project")
            parts = request.raw_path.split("?", 1)[0].split("/", 3)
            slug = parts[2]
            if not SLUG.fullmatch(slug) or slug not in self.config["projects"]:
                raise web.HTTPNotFound(text="Unknown project")
            return slug, "/" + (parts[3] if len(parts) == 4 else ""), True
        if path.startswith("/api/") or path.startswith("/live"):
            raise web.HTTPBadRequest(text="Select an explicit /projects/<project>/ scope")
        requested = request.query.get("project")
        task = request.query.get("chat_task")
        if not requested and task and task.startswith("github:"):
            requested = ":".join(task.split(":")[:2])
        if requested:
            for slug, project in self.config["projects"].items():
                if requested == "github:" + project["repository"]:
                    return slug, path, False
            raise web.HTTPNotFound(text="Unknown project")
        return next(iter(self.config["projects"])), path, False

    async def proxy(self, request):
        if request.host != self.config["origin"].netloc:
            # The Mac API client uses 127.0.0.1 rather than the browser's localhost.
            parsed = urllib.parse.urlsplit("http://" + request.host)
            if not (self.config["origin"].hostname in ("localhost", "127.0.0.1", "::1")
                    and parsed.hostname in ("localhost", "127.0.0.1", "::1")
                    and parsed.port == self.config.get("listen_port", self.config["origin"].port)
                    and ipaddress.ip_address(request.remote).is_loopback):
                raise web.HTTPBadRequest(text="Invalid workspace host")
        slug, path, scoped = self.select(request)
        query = "?" + request.rel_url.raw_query_string if request.rel_url.raw_query_string else ""
        if not scoped and path in ("/", "/chat", "/login"):
            raise web.HTTPSeeOther(location=URL("/projects/" + slug + path + query, encoded=True))
        if scoped and not request.path.endswith("/") and len(request.path.split("/")) == 3:
            raise web.HTTPSeeOther(location=URL(request.path + "/" + query, encoded=True))
        target = URL("http://localhost" + path + query, encoded=True)
        client = self.clients[slug]
        headers = clean_headers(request.headers)
        try:
            if request.headers.get("Upgrade", "").lower() == "websocket":
                return await self.websocket(request, client, target, headers)
            body = await request.read()
            async with client.request(request.method, target, headers=headers, data=body, allow_redirects=False) as upstream:
                response_headers = clean_headers(upstream.headers)
                response = web.StreamResponse(status=upstream.status, headers=response_headers)
                await response.prepare(request)
                async for chunk in upstream.content.iter_chunked(64 * 1024):
                    await response.write(chunk)
                await response.write_eof()
                return response
        except (ClientError, OSError, asyncio.TimeoutError):
            raise web.HTTPServiceUnavailable(text="Project is restarting. Try again shortly.") from None

    async def websocket(self, request, client, target, headers):
        # aiohttp owns framing, masking, fragmentation and the opening handshake.
        protocols = tuple(part.strip() for part in request.headers.get("Sec-WebSocket-Protocol", "").split(",") if part.strip())
        headers = [(key, value) for key, value in headers if not key.lower().startswith("sec-websocket-")]
        async with client.ws_connect(target, headers=headers, protocols=protocols, max_msg_size=MAX_BODY, heartbeat=30) as upstream:
            downstream = web.WebSocketResponse(protocols=protocols, max_msg_size=MAX_BODY, heartbeat=30)
            await downstream.prepare(request)

            async def copy(source, destination):
                async for message in source:
                    if message.type == WSMsgType.TEXT:
                        await destination.send_str(message.data)
                    elif message.type == WSMsgType.BINARY:
                        await destination.send_bytes(message.data)
                    elif message.type in (WSMsgType.CLOSE, WSMsgType.CLOSED, WSMsgType.ERROR):
                        break
                await destination.close()

            tasks = [asyncio.create_task(copy(upstream, downstream)), asyncio.create_task(copy(downstream, upstream))]
            try:
                done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                for task in done:
                    task.result()
            finally:
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
            return downstream

    async def start(self, app):
        # Lock before unlinking sockets or writing key material. Concurrent launches
        # must fail without touching a live workspace.
        lock_path = Path(self.config["state_dir"]) / "workspace.lock"
        descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
                raise ControlError("Workspace lock must be an owned private regular file")
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (OSError, ControlError):
            os.close(descriptor)
            raise ControlError("Workspace is already owned by another service") from None
        self.lock_fd = descriptor
        secret_file = self.config["secret_file"]
        try:
            if not secret_file.exists():
                fd = os.open(secret_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, "w") as stream:
                    stream.write(secrets.token_urlsafe(64))
            self.config["secret"] = read_private(secret_file).strip()
        except BaseException:
            os.close(self.lock_fd)
            self.lock_fd = None
            raise
        if len(self.config["secret"]) < 64:
            os.close(self.lock_fd)
            self.lock_fd = None
            raise ControlError("Workspace cookie key is invalid")
        try:
            await self.start_engines(app)
        except BaseException:
            await self.stop(app)
            raise

    async def start_engines(self, app):
        auth_path = self.config["runtime"] / "auth.sock"
        self.remove_socket(auth_path)
        broker_app = web.Application(client_max_size=100_000)
        broker_app.router.add_post("/session", self.broker.handle)
        self.auth_runner = web.AppRunner(broker_app, access_log=None)
        await self.auth_runner.setup()
        await web.UnixSite(self.auth_runner, str(auth_path)).start()
        os.chmod(auth_path, 0o600)
        for slug in self.config["projects"]:
            socket_path = self.config["runtime"] / (slug + ".sock")
            # The browser owns the shared session. A proxy cookie jar would retain
            # per-project grants and override fresh browser cookies or logout.
            self.clients[slug] = ClientSession(connector=UnixConnector(path=str(socket_path)), timeout=ClientTimeout(total=65, connect=5, sock_read=60), auto_decompress=False, cookie_jar=DummyCookieJar())
            await self.spawn(slug)
            self.monitors.append(asyncio.create_task(self.monitor(slug)))
            if self.config["projects"][slug]["_workspace_publication"]:
                key = slug + ":publication"
                await self.spawn(key)
                self.monitors.append(asyncio.create_task(self.monitor(key)))
        # One listener is available only after each project has started its engine.
        for slug in self.config["projects"]:
            await self.wait_ready(slug)

    async def spawn(self, slug):
        project_slug = slug.split(":", 1)[0]
        project = self.config["projects"][project_slug]
        socket_path = self.config["runtime"] / (project_slug + ".sock")
        if ":" not in slug:
            self.remove_socket(socket_path)
        env = {**os.environ, "SYMPHONY_WORKSPACE_PROJECT": project_slug,
               "SYMPHONY_WORKSPACE_ORIGIN": self.config["public_origin"], "SYMPHONY_WORKSPACE_SECRET": self.config["secret"],
               "SYMPHONY_WORKSPACE_AUTH_SOCKET": str(self.config["runtime"] / "auth.sock"), "SYMPHONY_WORKSPACE_ENGINE_SOCKET": str(socket_path)}
        logs = Path(project["state_dir"]) / "logs"
        logs.mkdir(mode=0o700, exist_ok=True)
        role = "publication" if ":" in slug else "engine"
        with (logs / ("workspace-" + role + ".out.log")).open("ab") as out, (logs / ("workspace-" + role + ".err.log")).open("ab") as err:
            command = ([sys.executable, str(ROOT / "tools/symphony_publish.py"), "--config", project["_config_path"], "watch"]
                       if ":" in slug else [sys.executable, project["profile_bin"], "--config", project["_config_path"], "run"])
            read_fd, write_fd = os.pipe()
            try:
                wrapper = [sys.executable, str(Path(__file__).resolve()), "_owned_child", str(self.lock_fd), str(read_fd), *command]
                self.children[slug] = OwnedProcess(
                    *wrapper, env=env, stdout=out, stderr=err, start_new_session=True,
                    pass_fds=(self.lock_fd, read_fd))
                self.owner_pipes[slug] = write_fd
            except BaseException:
                os.close(write_fd)
                raise
            finally:
                os.close(read_fd)

    async def monitor(self, slug):
        delay = 1
        while not self.stopping:
            started = time.monotonic()
            await self.children[slug].wait()
            os.close(self.owner_pipes.pop(slug))
            if self.stopping:
                return
            while not self.stopping:
                await asyncio.sleep(delay)
                try:
                    await self.spawn(slug)
                    break
                except (OSError, ControlError):
                    delay = min(delay * 2, 30)
            delay = 1 if time.monotonic() - started > 60 else min(delay * 2, 30)

    async def wait_ready(self, slug):
        until = time.monotonic() + 45
        project = self.config["projects"][slug]
        while time.monotonic() < until:
            try:
                async with self.clients[slug].get("http://localhost/api/v1/control", auto_decompress=True, headers={"Host": "127.0.0.1:" + str(self.config["listen_port"]), "Authorization": "Bearer " + project["_token"]}) as response:
                    if response.status == 200 and isinstance(await response.json(), dict):
                        return
            except (ClientError, OSError, asyncio.TimeoutError, ValueError):
                pass
            await asyncio.sleep(0.2)
        raise ControlError("Project engine did not become ready: " + slug)

    @staticmethod
    def remove_socket(path):
        if path.exists() or path.is_symlink():
            info = path.lstat()
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                raise ControlError("Refusing to replace non-owned runtime socket")
            path.unlink()

    async def stop(self, app):
        self.stopping = True
        for task in self.monitors:
            task.cancel()
        await asyncio.gather(*self.monitors, return_exceptions=True)
        for descriptor in self.owner_pipes.values():
            os.close(descriptor)
        self.owner_pipes.clear()
        for child in self.children.values():
            if child.returncode is None:
                child.signal_group(signal.SIGTERM)
        for child in self.children.values():
            try:
                await asyncio.wait_for(child.wait(), timeout=10)
            except asyncio.TimeoutError:
                child.signal_group(signal.SIGKILL)
                await child.wait()
        for client in self.clients.values():
            await client.close()
        if self.auth_runner is not None:
            await self.auth_runner.cleanup()
            self.auth_runner = None
        if self.lock_fd is not None:
            for path in self.config["runtime"].glob("*.sock"):
                self.remove_socket(path)
            os.close(self.lock_fd)
            self.lock_fd = None


def application(config):
    workspace = Workspace(config)
    app = web.Application(client_max_size=MAX_BODY)
    app.router.add_route("*", "/{path:.*}", workspace.proxy)
    app.on_startup.append(workspace.start)
    app.on_cleanup.append(workspace.stop)
    return app


async def owned_child(lock_fd, owner_fd, command):
    """Hold inherited ownership until this exact engine group has stopped.

    A private pipe closing proves that the supervising process died, without PID
    reuse, process-list matching or another user's process becoming a kill target.
    """
    lock = os.fstat(lock_fd)
    owner = os.fstat(owner_fd)
    if (os.getpgrp() != os.getpid() or not stat.S_ISREG(lock.st_mode)
            or lock.st_uid != os.getuid() or stat.S_IMODE(lock.st_mode) & 0o077
            or not stat.S_ISFIFO(owner.st_mode) or owner.st_uid != os.getuid() or not command):
        raise ControlError("Invalid inherited workspace ownership")
    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    os.set_inheritable(lock_fd, False)
    os.set_inheritable(owner_fd, False)
    loop = asyncio.get_running_loop()
    stopping = asyncio.Event()

    def owner_lost():
        loop.remove_reader(owner_fd)
        stopping.set()

    loop.add_reader(owner_fd, owner_lost)
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stopping.set)
    child = None
    waits = []
    try:
        # Retain only the ownership lock through the native Python/escript/BEAM
        # path. A simultaneous gateway/guard failure cannot discard that lease.
        child = await asyncio.create_subprocess_exec(*command, close_fds=True, pass_fds=(lock_fd,))
        waits = [asyncio.create_task(child.wait()), asyncio.create_task(stopping.wait())]
        await asyncio.wait(waits, return_when=asyncio.FIRST_COMPLETED)
        # The wrapper is the group leader; it absorbs TERM while the native engine
        # settles cleanup. A forced timeout kills this group, including the wrapper.
        os.killpg(os.getpgrp(), signal.SIGTERM)
        try:
            await asyncio.wait_for(child.wait(), timeout=8)
        except asyncio.TimeoutError:
            os.killpg(os.getpgrp(), signal.SIGKILL)
        # End any remaining same-group subprocesses before releasing the lock.
        # Including this disposable group leader prevents group/PID reuse races.
        os.killpg(os.getpgrp(), signal.SIGKILL)
        return child.returncode if child.returncode is not None and child.returncode >= 0 else 1
    finally:
        for task in waits:
            task.cancel()
        await asyncio.gather(*waits, return_exceptions=True)
        loop.remove_reader(owner_fd)
        os.close(owner_fd)
        os.close(lock_fd)


def main():
    if len(sys.argv) >= 5 and sys.argv[1] == "_owned_child":
        raise SystemExit(asyncio.run(owned_child(int(sys.argv[2]), int(sys.argv[3]), sys.argv[4:])))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("command", choices=("run", "check"))
    args = parser.parse_args()
    os.umask(0o077)
    config = load_workspace(args.config)
    if args.command == "check":
        print(json.dumps({"public_origin": config["public_origin"], "projects": list(config["projects"]), "private_transport": "unix"}))
    else:
        web.run_app(application(config), host=config.get("bind_host", "127.0.0.1"), port=config["listen_port"], access_log=None, print=None)


if __name__ == "__main__":
    try:
        main()
    except (ControlError, KeyError, ValueError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
