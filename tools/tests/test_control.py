"""Operator protocol tests: unavailable is unknown, no ambient credential routing."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from types import SimpleNamespace
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import symphony_control as control
import symphony_service as service


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.requests.append((self.path, self.headers.get("Authorization")))
        code, body, headers = self.server.response
        self.send_response(code)
        for name, value in headers.items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.server.payloads.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        self.do_GET()


@contextlib.contextmanager
def server(response=(200, b'{"revision":4}', {})):
    host = HTTPServer(("127.0.0.1", 0), Handler)
    host.response, host.requests, host.payloads = response, [], []
    thread = threading.Thread(target=host.serve_forever, daemon=True)
    thread.start()
    try:
        yield host, {"api_url": "http://127.0.0.1:" + str(host.server_port), "_token": "x" * 48, "repository": "example/repo"}
    finally:
        host.shutdown()
        host.server_close()
        thread.join()


class ControlTests(unittest.TestCase):
    def test_stop_waits_for_launchd_to_remove_departing_job(self):
        replies = [SimpleNamespace(returncode=0), SimpleNamespace(returncode=0), SimpleNamespace(returncode=113)]
        with patch.object(service, "launchctl", side_effect=replies) as command, patch.object(service.time, "sleep") as pause:
            service.wait_unloaded("gui/501", "fixture")
            self.assertEqual(command.call_count, 3)
            self.assertEqual(pause.call_count, 2)

    def test_stop_does_not_claim_completion_when_launchd_keeps_job(self):
        with patch.object(service, "launchctl", return_value=SimpleNamespace(returncode=0)), patch.object(service.time, "monotonic", side_effect=[0, 11]):
            with self.assertRaisesRegex(control.ControlError, "has not finished unloading"):
                service.wait_unloaded("gui/501", "fixture")

    def test_private_configuration_rejects_permissions_symlinks_and_remote_urls(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            token = root / "token"
            token.write_text("x" * 48)
            token.chmod(0o600)
            config = root / "config.json"
            content = {"api_url": "http://127.0.0.1:8777", "token_file": str(token)}
            config.write_text(json.dumps(content))
            config.chmod(0o600)
            self.assertEqual(control.load_config(config)["_token"], "x" * 48)
            config.chmod(0o644)
            with self.assertRaises(control.ControlError):
                control.load_config(config)
            config.chmod(0o600)
            for url in ("https://example.com:8777", "http://localhost:8777", "http://127.0.0.1:8777@evil.test", "http://127.0.0.1", "http://127.0.0.1:8777/?x=1"):
                content["api_url"] = url
                config.write_text(json.dumps(content))
                with self.assertRaises(control.ControlError):
                    control.load_config(config)
            link = root / "link"
            link.symlink_to(token)
            with self.assertRaises(control.ControlError):
                control.read_private(link)
            fifo = root / "fifo"
            os.mkfifo(fifo, 0o600)
            with self.assertRaises(control.ControlError):
                control.read_private(fifo)

    def test_controls_preserve_idempotency_key_and_revision(self):
        with server() as (host, config):
            for _ in range(2):
                self.assertEqual(control.control(config, "cancel", 3, "same-request", "7"), {"revision": 4})
            self.assertEqual(host.payloads, [dict(action="cancel", expected_revision=3, command_id="same-request", issue_id="7")] * 2)
            self.assertTrue(all(auth == "Bearer " + "x" * 48 for _, auth in host.requests))
        for action, revision, key, issue in (("deploy", 0, "a", None), ("resume", True, "a", None), ("resume", -1, "a", None), ("cancel", 0, "a", None), ("retry", 1, "", "7")):
            with self.assertRaises(control.ControlError):
                control.control({}, action, revision, key, issue)

    def test_redirects_do_not_forward_token(self):
        with server() as (destination, _):
            with server((302, b"", {"Location": "http://127.0.0.1:" + str(destination.server_port) + "/api/v1/control"})) as (_, config):
                with self.assertRaisesRegex(control.ControlError, "redirects"):
                    control.request_json(config, "/api/v1/control")
            self.assertEqual(destination.requests, [])

    def test_unknown_and_rejected_state_never_become_idle(self):
        for response in ((409, b'{"error":"revision_conflict"}', {}), (200, b'{"error":{"code":"snapshot_unavailable"}}', {}), (200, b"not json", {}), (200, b"x" * (control.MAX_MESSAGE + 1), {})):
            with server(response) as (_, config):
                with self.assertRaises(control.ControlError):
                    control.status(config)

    def test_ambient_proxy_is_ignored(self):
        with server() as (_, config), patch.dict(os.environ, {"HTTP_PROXY": "http://127.0.0.1:1", "http_proxy": "http://127.0.0.1:1", "NO_PROXY": "", "no_proxy": ""}):
            self.assertEqual(control.request_json(config, "/api/v1/state"), {"revision": 4})

    def test_mcp_protocol_and_validation(self):
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "symphony_control", "arguments": {"action": "deploy"}}},
            {"jsonrpc": "2.0", "id": 4, "method": "unknown"},
            {"jsonrpc": "2.0", "id": 5, "method": "initialize", "params": [1]},
        ]
        output = io.StringIO()
        control.mcp({}, io.StringIO("\n".join(map(json.dumps, messages)) + "\n"), output)
        replies = list(map(json.loads, output.getvalue().splitlines()))
        self.assertEqual([reply["id"] for reply in replies], [1, 2, 3, 4, 5])
        self.assertEqual(len(replies[1]["result"]["tools"]), 3)
        self.assertTrue(replies[2]["result"]["isError"])
        self.assertEqual(replies[3]["error"]["code"], -32601)
        self.assertEqual(replies[4]["error"]["code"], -32600)


if __name__ == "__main__":
    unittest.main()
