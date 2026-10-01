from __future__ import annotations

import asyncio
import base64
import io
import json
import os
import shutil
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

from aiohttp import ClientSession, web

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from symphony_workspace import ROOT, SessionBroker, Workspace, clean_headers, valid_value, load_workspace
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
