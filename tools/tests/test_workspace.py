from __future__ import annotations

import asyncio
import base64
import io
import json
import os
import shutil
import signal
import subprocess
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace

from aiohttp import ClientSession, web

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from symphony_workspace import ROOT, OwnedProcess, SessionBroker, Workspace, clean_headers, valid_value, load_workspace
from symphony_control import valid_api_prefix, ControlError


class BrokerTest(unittest.TestCase):
    def test_claim_completion_logout_capacity_and_expiry(self):
        now = [0]
        broker = SessionBroker(1, lambda: now[0])
        value = base64.b64encode(b"opaque-engine-value").decode()
        flow = broker.execute({"op": "issue", "kind": "flow", "value": value})["id"]
        self.assertEqual(broker.execute({"op": "complete_flow", "id": flow, "value": value}), {"error": "expired"})
        self.assertEqual(broker.execute({"op": "get", "kind": "flow", "id": flow}), {"value": value})
        self.assertEqual(broker.execute({"op": "get", "kind": "flow", "id": flow}), {"error": "expired"})
        self.assertEqual(broker.execute({"op": "issue", "kind": "session", "value": value}), {"error": "capacity"})
        self.assertEqual(broker.execute({"op": "complete_flow", "id": flow, "value": value}), {"id": flow})
        self.assertEqual(broker.execute({"op": "get", "kind": "session", "id": flow}), {"value": value})
        self.assertEqual(broker.execute({"op": "revoke", "id": flow}), {"ok": True})
        self.assertEqual(broker.execute({"op": "complete_flow", "id": flow, "value": value}), {"error": "expired"})
        token = broker.execute({"op": "issue", "kind": "session", "value": value})["id"]
        now[0] = 28800
        self.assertEqual(broker.execute({"op": "get", "kind": "session", "id": token}), {"error": "expired"})
        self.assertFalse(valid_value("!"))
        self.assertFalse(valid_value(base64.b64encode(b"x" * 65537).decode()))
        self.assertFalse(valid_value(None))

    def test_paths_and_headers_cannot_cross_repository_scope(self):
        self.assertTrue(valid_api_prefix("/projects/symphony", "iliazlobin/symphony"))
        self.assertFalse(valid_api_prefix("/projects/events-concierge", "iliazlobin/symphony"))
        self.assertFalse(valid_api_prefix("/projects/symphony/../events-concierge", "iliazlobin/symphony"))
        self.assertFalse(valid_api_prefix("/projects/symphony", None))
        headers = dict(clean_headers({"Connection": "X-Untrusted", "X-Untrusted": "secret", "Upgrade": "websocket", "Host": "localhost:8778", "Authorization": "Bearer project-token"}))
        self.assertEqual(headers, {"Host": "localhost:8778", "Authorization": "Bearer project-token"})


class WorkspaceConfigurationTest(unittest.TestCase):
    def test_registered_projects_share_identity_but_not_state_and_use_one_release(self):
        with tempfile.TemporaryDirectory(prefix="sw-config-", dir="/private/tmp" if sys.platform == "darwin" else "/tmp") as directory:
            root = Path(directory)
            projects = []
            def write(path, value):
                path.write_text(value)
                path.chmod(0o600)
            for slug in ("events-concierge", "symphony"):
                state = root / slug
                state.mkdir(mode=0o700)
                token, workflow, config = state / "token", state / "WORKFLOW.md", state / "config.json"
                write(token, "fixture-" + "x" * 48)
                policy = {"provider": "google", "client_id": "$GOOGLE_CLIENT_ID", "client_secret": "$GOOGLE_CLIENT_SECRET", "allowed_emails": ["owner@gmail.com"]}
                write(workflow, "---\n" + json.dumps({"browser_auth": policy}) + "\n---\nTask")
                write(config, json.dumps({"repository": "iliazlobin/" + slug, "api_url": "http://127.0.0.1:8778/projects/" + slug,
                                          "token_file": str(token), "workflow_path": str(workflow), "state_dir": str(state),
                                          "profile_bin": str(ROOT / "profiles" / slug / "profile.py"), "google_oauth_client_file": "/private/host/client.json"}))
                projects.append({"config": str(config)})
            workspace = root / "workspace.json"
            write(workspace, json.dumps({"public_origin": "http://localhost:8778", "state_dir": str(root / "workspace-state"), "projects": projects}))
            loaded = load_workspace(workspace)
            self.assertEqual(list(loaded["projects"]), ["events-concierge", "symphony"])
            self.assertFalse(loaded["secret_file"].exists())
            try:
                config = json.loads(Path(projects[1]["config"]).read_text())
                config["state_dir"] = str(root / "events-concierge")
                write(Path(projects[1]["config"]), json.dumps(config))
                with self.assertRaisesRegex(ControlError, "distinct"):
                    load_workspace(workspace)
                config["state_dir"] = str(root / "symphony")
                config["profile_bin"] = "/another/release/profile.py"
                write(Path(projects[1]["config"]), json.dumps(config))
                with self.assertRaisesRegex(ControlError, "reviewed profile"):
                    load_workspace(workspace)
                config["profile_bin"] = str(ROOT / "profiles/symphony/profile.py")
                write(Path(projects[1]["config"]), json.dumps(config))
                policy["trusted_proxy_ips"] = ["127.0.0.1"]
                write(root / "symphony/WORKFLOW.md", "---\n" + json.dumps({"browser_auth": policy}) + "\n---\nTask")
                with self.assertRaisesRegex(ControlError, "admission policy"):
                    load_workspace(workspace)
                policy.pop("trusted_proxy_ips")
                policy["allowed_emails"] = ["other@gmail.com"]
                write(root / "symphony/WORKFLOW.md", "---\n" + json.dumps({"browser_auth": policy}) + "\n---\nTask")
                with self.assertRaisesRegex(ControlError, "admission policy"):
                    load_workspace(workspace)
            finally:
                shutil.rmtree(loaded["runtime"])


class GatewayTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sw-", dir="/private/tmp" if sys.platform == "darwin" else "/tmp")
        self.runners, self.clients = [], []
        self.workspace = Workspace({"projects": {"events": {"repository": "owner/events"}, "symphony": {"repository": "owner/symphony"}},
                                    "origin": SimpleNamespace(netloc="localhost:8778", hostname="localhost", port=8778)})
        for slug in self.workspace.config["projects"]:
            app = web.Application()
            async def endpoint(request, project=slug):
                if request.path == "/live/websocket":
                    ws = web.WebSocketResponse()
                    await ws.prepare(request)
                    async for message in ws:
                        await ws.send_str(project + ":" + message.data)
                    return ws
                return web.json_response({"project": project, "path": request.path, "auth": request.headers.get("Authorization"), "cookie": request.headers.get("Cookie")})
            app.router.add_route("*", "/{path:.*}", endpoint)
            runner = web.AppRunner(app)
            await runner.setup()
            socket = str(Path(self.temp.name) / (slug + ".sock"))
            await web.UnixSite(runner, socket).start()
            self.runners.append(runner)
            from aiohttp import UnixConnector
            client = ClientSession(connector=UnixConnector(path=socket))
            self.workspace.clients[slug] = client
            self.clients.append(client)
        gateway = web.Application(client_max_size=1048576)
        gateway.router.add_route("*", "/{path:.*}", self.workspace.proxy)
        runner = web.AppRunner(gateway)
        await runner.setup()
        site = web.TCPSite(runner, "127.0.0.1", 0)
        await site.start()
        self.runners.append(runner)
        self.url = "http://127.0.0.1:" + str(site._server.sockets[0].getsockname()[1])
        self.client = ClientSession()
        self.clients.append(self.client)

    async def asyncTearDown(self):
        for client in self.clients:
            await client.close()
        for runner in reversed(self.runners):
            await runner.cleanup()
        self.temp.cleanup()

    async def test_two_tabs_route_http_websockets_and_bearer_scope_explicitly(self):
        headers = {"Host": "localhost:8778", "Cookie": "_symphony_workspace=shared-grant", "Authorization": "Bearer selected-project-token"}
        for slug in ("events", "symphony", "events"):
            async with self.client.get(self.url + "/projects/" + slug + "/api/v1/control", headers=headers) as response:
                self.assertEqual(response.status, 200)
                payload = await response.json()
                self.assertEqual(payload, {"project": slug, "path": "/api/v1/control", "auth": headers["Authorization"], "cookie": headers["Cookie"]})
        async with self.client.ws_connect(self.url + "/projects/events/live/websocket", headers=headers) as events:
            async with self.client.ws_connect(self.url + "/projects/symphony/live/websocket", headers=headers) as symphony:
                await events.send_str("one")
                await symphony.send_str("two")
                self.assertEqual((await events.receive()).data, "events:one")
                self.assertEqual((await symphony.receive()).data, "symphony:two")
                await events.send_str("three")
                self.assertEqual((await events.receive()).data, "events:three")

    async def test_unrecognized_scope_and_root_api_fail_closed_and_legacy_links_redirect(self):
        headers = {"Host": "localhost:8778"}
        for path, expected in [("/projects/missing/", 404), ("/projects%2Fsymphony%2F", 404), ("/api/v1/control", 400), ("/live/websocket", 400)]:
            async with self.client.get(self.url + path, headers=headers, allow_redirects=False) as response:
                self.assertEqual(response.status, expected)
        async with self.client.get(self.url + "/?chat_task=github%3Aowner%2Fsymphony%3A27", headers=headers, allow_redirects=False) as response:
            self.assertEqual(response.status, 303)
            self.assertTrue(response.headers["Location"].startswith("/projects/symphony/?"))
        async with self.client.get(self.url + "/projects/events/", headers={"Host": "evil.example"}) as response:
            self.assertEqual(response.status, 400)
        async with self.client.post(self.url + "/projects/events/", headers=headers, data=io.BytesIO(b"x" * 1048577)) as response:
            self.assertEqual(response.status, 413)
        await self.runners[0].cleanup()
        async with self.client.get(self.url + "/projects/events/", headers=headers) as response:
            self.assertEqual(response.status, 503)

    async def test_single_owner_lock_and_partial_start_failure_cleanup(self):
        state = Path(self.temp.name)
        config = {"state_dir": str(state), "runtime": state, "secret_file": state / "cookie-key"}
        first = Workspace(config.copy())
        second = Workspace(config.copy())
        async def fail(app):
            raise RuntimeError("project startup failed")
        with patch.object(first, "start_engines", side_effect=fail):
            with self.assertRaisesRegex(RuntimeError, "startup failed"):
                await first.start(None)
        self.assertIsNone(first.lock_fd)
        with patch.object(first, "start_engines", return_value=None):
            await first.start(None)
        with self.assertRaisesRegex(ControlError, "already owned"):
            await second.start(None)
        self.assertIsNone(second.lock_fd)
        await first.stop(None)

    async def test_owned_monitor_retries_transient_spawn_failure(self):
        read_fd, write_fd = os.pipe()
        next_read_fd, next_write_fd = os.pipe()
        attempts = []
        workspace = Workspace({})
        class Completed:
            async def wait(self):
                return 1
        class Recovered:
            async def wait(self):
                workspace.stopping = True
                return 0
        async def spawn(slug):
            attempts.append(slug)
            if len(attempts) == 1:
                raise OSError("temporary process capacity")
            workspace.children[slug] = Recovered()
            workspace.owner_pipes[slug] = next_write_fd
        workspace.children["fixture"] = Completed()
        workspace.owner_pipes["fixture"] = write_fd
        try:
            with patch.object(workspace, "spawn", side_effect=spawn), patch("symphony_workspace.asyncio.sleep", return_value=None):
                await workspace.monitor("fixture")
            self.assertEqual(attempts, ["fixture", "fixture"])
            self.assertEqual(workspace.owner_pipes, {})
        finally:
            os.close(read_fd)
            os.close(next_read_fd)

    async def test_shutdown_reaps_an_already_exited_owned_group(self):
        workspace = Workspace({})
        child = OwnedProcess(sys.executable, "-c", "pass", start_new_session=True)
        workspace.children["fixture"] = child
        try:
            while not child.exited():
                await asyncio.sleep(0.01)
            await workspace.stop(None)
            self.assertEqual(child.returncode, 0)
        finally:
            if child.returncode is None:
                child.signal_group(signal.SIGKILL)
                await child.wait()


class CrashOwnershipTest(unittest.TestCase):
    def test_abrupt_gateway_death_stops_owned_groups_before_replacement(self):
        self.exercise_failure("gateway")

    def test_guard_death_cleans_its_group_before_engine_restart(self):
        self.exercise_failure("guard")

    def test_guard_and_gateway_death_retains_engine_lock_until_manual_cleanup(self):
        self.exercise_failure("both")

    def exercise_failure(self, failure):
        with tempfile.TemporaryDirectory(prefix="sw-crash-", dir="/private/tmp" if sys.platform == "darwin" else "/tmp") as directory:
            root = Path(directory)
            runtime = root / "runtime"
            runtime.mkdir(mode=0o700)
            profile = root / "fixture_engine.py"
            profile.write_text('''import asyncio, json, os, signal, subprocess, sys
from pathlib import Path
from aiohttp import web
async def main():
    state = Path(json.loads(Path(sys.argv[2]).read_text())["state_dir"])
    app = web.Application()
    async def status(request):
        return web.json_response({"running": [], "retrying": []})
    app.router.add_route("*", "/{path:.*}", status)
    runner = web.AppRunner(app)
    await runner.setup()
    await web.UnixSite(runner, os.environ["SYMPHONY_WORKSPACE_ENGINE_SOCKET"]).start()
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    loop.add_signal_handler(signal.SIGTERM, lambda: loop.call_later(2, stop.set))
    descendant = subprocess.Popen([sys.executable, "-c", "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)"])
    lock = (state.parent / "workspace.lock").stat()
    inherited = False
    for entry in Path("/dev/fd").iterdir():
        try:
            info = os.fstat(int(entry.name))
            inherited |= info.st_ino == lock.st_ino and info.st_dev == lock.st_dev
        except (OSError, ValueError):
            pass
    (state / "engine.json").write_text(json.dumps({"engine": os.getpid(), "descendant": descendant.pid, "inherited_lock": inherited}))
    await stop.wait()
    await runner.cleanup()
asyncio.run(main())
''')
            harness = root / "fixture_gateway.py"
            harness.write_text('''import asyncio, json, signal, sys
from pathlib import Path
from types import SimpleNamespace
from aiohttp import web
sys.path.insert(0, sys.argv[1])
from symphony_workspace import application
async def main():
    state = Path(sys.argv[2])
    raw = json.loads((state / "fixture.json").read_text())
    raw.update(runtime=state / "runtime", secret_file=state / "cookie-key", origin=SimpleNamespace(netloc="localhost:8778", hostname="localhost", port=8778))
    runner = web.AppRunner(application(raw))
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    (state / "ready.json").write_text(json.dumps({"port": site._server.sockets[0].getsockname()[1]}))
    stop = asyncio.Event()
    asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, stop.set)
    await stop.wait()
    await runner.cleanup()
asyncio.run(main())
''')
            projects = {}
            for slug in ("alpha", "beta"):
                state = root / slug
                state.mkdir(mode=0o700)
                config = state / "config.json"
                config.write_text(json.dumps({"state_dir": str(state)}))
                projects[slug] = {"state_dir": str(state), "profile_bin": str(profile), "_config_path": str(config), "_token": "fixture", "_workspace_publication": False}
            (root / "fixture.json").write_text(json.dumps({"state_dir": str(root), "public_origin": "http://localhost:8778", "listen_port": 8778, "projects": projects}))
            processes, outputs = [], []
            def start():
                output = (root / ("gateway-" + str(len(processes)) + ".log")).open("wb")
                outputs.append(output)
                process = subprocess.Popen([sys.executable, str(harness), str(ROOT / "tools"), str(root)], stdout=output, stderr=output)
                processes.append(process)
                return process
            def wait_until(predicate, timeout=12):
                until = time.monotonic() + timeout
                while time.monotonic() < until:
                    if predicate():
                        return
                    time.sleep(0.02)
                self.fail("Timed out waiting for isolated workspace ownership fixture")
            def running(pid):
                result = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
                return result.returncode == 0 and result.stdout.strip() and not result.stdout.strip().startswith("Z")
            records = []
            try:
                first = start()
                ready = root / "ready.json"
                wait_until(ready.exists)
                records = [json.loads((root / slug / "engine.json").read_text()) for slug in projects]
                self.assertTrue(all(entry["inherited_lock"] for entry in records))
                before = {slug: (runtime / (slug + ".sock")).stat().st_ino for slug in projects}
                if failure == "guard":
                    original = records[0]
                    guard = os.getpgid(original["engine"])
                    self.assertNotEqual(guard, first.pid)
                    os.kill(guard, signal.SIGKILL)
                    def restarted():
                        try:
                            return json.loads((root / "alpha" / "engine.json").read_text())["engine"] != original["engine"]
                        except (OSError, ValueError):
                            return False
                    wait_until(restarted)
                    self.assertFalse(running(original["engine"]))
                    self.assertFalse(running(original["descendant"]))
                    self.assertIsNone(first.poll())
                    new_records = [json.loads((root / slug / "engine.json").read_text()) for slug in projects]
                    first.terminate()
                    self.assertEqual(first.wait(timeout=6), 0, (root / "gateway-0.log").read_text())
                    wait_until(lambda: all(not running(entry[key]) for entry in new_records for key in ("engine", "descendant")))
                    return
                if failure == "both":
                    # Prevent the gateway from observing guard exit: this models
                    # both supervisors failing before either can clean the engine.
                    os.kill(first.pid, signal.SIGSTOP)
                    os.kill(os.getpgid(records[0]["engine"]), signal.SIGKILL)
                first.kill()  # Abrupt gateway death: no application cleanup callback.
                first.wait(timeout=3)
                ready.unlink()
                conflicting = start()
                self.assertEqual(conflicting.wait(timeout=4), 1)
                outputs[1].flush()
                self.assertIn("already owned", (root / "gateway-1.log").read_text())
                self.assertEqual(before, {slug: (runtime / (slug + ".sock")).stat().st_ino for slug in projects})
                if failure == "both":
                    self.assertTrue(running(records[0]["engine"]))
                    # Only this disposable fixture's exact known group is killed.
                    os.killpg(os.getpgid(records[0]["engine"]), signal.SIGKILL)
                wait_until(lambda: all(not running(entry[key]) for entry in records for key in ("engine", "descendant")))
                replacement = start()
                wait_until(ready.exists)
                new_records = [json.loads((root / slug / "engine.json").read_text()) for slug in projects]
                self.assertTrue(all(old["engine"] != new["engine"] for old, new in zip(records, new_records)))
                self.assertTrue(all(not running(entry["engine"]) for entry in records))
                replacement.terminate()
                self.assertEqual(replacement.wait(timeout=6), 0, (root / "gateway-2.log").read_text())
                wait_until(lambda: all(not running(entry[key]) for entry in new_records for key in ("engine", "descendant")))
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=3)
                for entry in records:
                    if running(entry["engine"]):
                        os.killpg(os.getpgid(entry["engine"]), signal.SIGKILL)
                for output in outputs:
                    output.close()
