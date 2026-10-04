"""Probe authority, transport bounds and cleanup; no Docker or model execution."""
import argparse
import base64
import hashlib
import io
import importlib.util
import json
import os
from pathlib import Path
import socket
import signal
import struct
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("probe_gke_application", Path(__file__).resolve().parents[1] / "probe_gke_application.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)
IMAGE = "sha256:" + "1" * 64


class ApplicationProbeTests(unittest.TestCase):
    def test_only_immutable_image_identity_is_accepted(self):
        self.assertEqual(PROBE.image_reference(IMAGE), IMAGE)
        digest = "us-west1-docker.pkg.dev/example/project/app@sha256:" + "a" * 64
        self.assertEqual(PROBE.image_reference(digest), digest)
        for unsafe in ("app:latest", "--privileged", IMAGE + "\n", "sha256:" + "A" * 64, "app@sha256:" + "a" * 63):
            with self.subTest(unsafe=unsafe), self.assertRaises(argparse.ArgumentTypeError):
                PROBE.image_reference(unsafe)

    def test_remote_docker_endpoints_are_rejected_before_resource_creation(self):
        for value in ("tcp://127.0.0.1:2375", "ssh://host", "unix://remote/socket", "unix:relative", "unix:///tmp/socket?override=1"):
            with patch.dict(os.environ, {"DOCKER_HOST": value}, clear=True), self.assertRaisesRegex(RuntimeError, "local Unix"):
                PROBE.local_docker_host()
        with patch.dict(os.environ, {"DOCKER_HOST": "unix:///tmp/socket"}, clear=True):
            self.assertEqual(PROBE.local_docker_host(), "unix:///tmp/socket")

    def test_selected_context_is_resolved_then_pinned_without_inheriting_override(self):
        with patch.dict(os.environ, {"DOCKER_CONTEXT": "selected", "DOCKER_HOST": "ssh://ignored"}, clear=True), patch.object(PROBE.subprocess, "run", return_value=SimpleNamespace(stdout='"unix:///tmp/selected.sock"')) as execute:
            self.assertEqual(PROBE.local_docker_host(), "unix:///tmp/selected.sock")
            self.assertEqual(execute.call_args.args[0][-1], "selected")
        with patch.object(PROBE, "LOCAL_DOCKER_HOST", "unix:///tmp/selected.sock"), patch.dict(os.environ, {"DOCKER_CONTEXT": "changed", "DOCKER_HOST": "ssh://elsewhere"}), patch.object(PROBE.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout="ok", stderr="")) as execute:
            self.assertEqual(PROBE.docker(["info"]), "ok")
            self.assertEqual(execute.call_args.args[0], ["docker", "--host", "unix:///tmp/selected.sock", "info"])
            self.assertNotIn("DOCKER_CONTEXT", execute.call_args.kwargs["env"])
            self.assertNotIn("DOCKER_HOST", execute.call_args.kwargs["env"])

    def test_workflow_uses_real_components_but_cannot_admit_tasks(self):
        workflow = PROBE.workflow()
        self.assertEqual(workflow["tracker"]["kind"], "github")
        self.assertEqual(workflow["tracker"]["provider"]["api_url"], "https://127.0.0.1:9")
        self.assertTrue(workflow["control"]["enabled"])
        self.assertEqual(workflow["control"]["initial_mode"], "paused")
        self.assertEqual(workflow["codex"]["command"], "/bin/false")
        self.assertTrue(workflow["chat"]["enabled"])
        self.assertEqual(workflow["chat"]["max_concurrent"], 1)
        self.assertNotIn("hooks", workflow)
        self.assertEqual(workflow["server"], {"host": "127.0.0.1", "port": 8080})

    def test_initializer_preserves_actual_front_matter_and_private_modes(self):
        content = "---\n" + json.dumps(PROBE.workflow()) + "\n---\nDisposable check.\n"
        with tempfile.TemporaryDirectory() as root:
            script = PROBE.initialization_script().replace(PROBE.ROOT, root)
            with patch("os.chown") as ownership, patch("sys.stdin", io.StringIO(content)):
                exec(compile(script, "<probe initializer>", "exec"), {})
            emitted = Path(root, "WORKFLOW.md")
            self.assertEqual(emitted.read_text(), content)
            self.assertEqual(json.loads(emitted.read_text().splitlines()[1]), PROBE.workflow())
            self.assertEqual(emitted.stat().st_mode & 0o777, 0o600)
            self.assertEqual(Path(root).stat().st_mode & 0o777, 0o700)
            self.assertEqual(ownership.call_args.args[1:], (10001, 10001))

    def test_parse_bootstrap_uses_observed_liveview_attributes(self):
        page = PROBE.Page('<meta name="csrf-token" content="a&amp;b"><div id="phx-id" data-phx-main data-phx-session="session" data-phx-static="static"></div>')
        self.assertEqual(page.csrf, "a&b")
        self.assertEqual(page.live["id"], "phx-id")
        self.assertEqual(page.live["data-phx-session"], "session")

    def test_design_package_probe_fetches_only_allowlisted_same_origin_assets(self):
        base = "/design-editor/123456abcdef/"
        requests = []
        documents = {
            base + "editor-ABC123.js": (200, 'import {e} from "./chunks/chunk-ABC.js";'),
            base + "editor-DEF456.css": (200, 'src:url(./files/Assistant-ABC.woff2)'),
            base + "chunks/chunk-ABC.js": (200, "export const e = {}"),
            base + "files/Assistant-ABC.woff2": (200, "font bytes"),
            base + "manifest.json": (404, "Not Found"),
        }

        class Browser:
            def request(self, path):
                requests.append(path)
                if path.startswith("/?"):
                    return 200, ('<section data-design-editor-assets="' + base + '" '
                                 'data-design-editor-js="' + base + 'editor-ABC123.js" '
                                 'data-design-editor-css="' + base + 'editor-DEF456.css"></section>')
                return documents[path]

        PROBE.design_assets(Browser())
        self.assertIn(base + "chunks/chunk-ABC.js", requests)
        self.assertIn(base + "files/Assistant-ABC.woff2", requests)
        documents[base + "chunks/chunk-ABC.js"] = (404, "Not Found")
        with self.assertRaisesRegex(RuntimeError, "chunk missing"):
            PROBE.design_assets(Browser())

    def test_design_package_probe_rejects_external_or_unversioned_bootstrap(self):
        for base in ("https://esm.sh/", "/design-editor/", "/design-editor/123456abcdef/../"):
            browser = SimpleNamespace(request=lambda _path: (200, '<section data-design-editor-js="external" data-design-editor-assets="' + base + '"></section>'))
            with self.assertRaisesRegex(RuntimeError, "escaped the package"):
                PROBE.design_assets(browser)

    def test_component_selection_rejects_missing_or_ambiguous_shared_panel(self):
        self.assertEqual(PROBE.chat_component({"rendered": {"c": {"2": {"s": ['<section id="chat-app">']}}}}), 2)
        for components in ({}, {"1": {"s": ["chat-app"]}, "2": {"s": ["chat-app"]}}):
            with self.assertRaises(RuntimeError):
                PROBE.chat_component({"rendered": {"c": components}})

    def socket_pair(self):
        client, server = socket.socketpair()
        self.addCleanup(client.close)
        self.addCleanup(server.close)
        client.settimeout(1)
        result = object.__new__(PROBE.LiveSocket)
        result.sock, result.pending = client, b""
        return result, server

    def test_client_frames_are_masked_and_handle_extended_payload(self):
        client, peer = self.socket_pair()
        payload = b"x" * 130
        client.send(payload)
        data = peer.recv(1024)
        self.assertEqual(data[:2], b"\x81\xfe")
        self.assertEqual(struct.unpack("!H", data[2:4])[0], 130)
        mask = data[4:8]
        self.assertEqual(bytes(value ^ mask[index % 4] for index, value in enumerate(data[8:])), payload)

    def test_server_fragmentation_and_ping_preserve_json_message(self):
        client, peer = self.socket_pair()
        peer.sendall(b'\x01\x02{"' + b'\x89\x01p' + b'\x80\x06a": 1}')
        self.assertEqual(client.receive(), {"a": 1})
        self.assertEqual(peer.recv(128)[0], 0x8A)

    def test_masked_binary_and_unbounded_server_frames_fail(self):
        for frame in (b"\x81\x80", b"\x82\x00", b"\x81\x7f" + struct.pack("!Q", PROBE.LIMIT + 1)):
            client, peer = self.socket_pair()
            peer.sendall(frame)
            with self.assertRaises(RuntimeError):
                client.receive()

    def test_transport_eof_is_explicit(self):
        client, peer = self.socket_pair()
        peer.close()
        with self.assertRaisesRegex(RuntimeError, "closed"):
            client.receive()

    def test_websocket_upgrade_requires_exact_nonce_response(self):
        nonce_bytes = b"a" * 16
        nonce = base64.b64encode(nonce_bytes).decode()
        accept = base64.b64encode(hashlib.sha1((nonce + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()

        class Transport:
            def __init__(self, response):
                self.response = response

            def sendall(self, _data):
                pass

            def recv(self, _length):
                response, self.response = self.response, b""
                return response

        class Browser:
            def request(self, _path):
                return 200, '<meta name="csrf-token" content="token"><div id="root" data-phx-main data-phx-session="session"></div>'

            def cookie(self):
                return "session=private-test-value"

        for received, valid in ((accept, True), (accept.lower(), False), ("wrong", False), ("", False)):
            transport = Transport(("HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: " + received + "\r\n\r\n").encode())
            with patch.object(PROBE.socket, "create_connection", return_value=transport), patch.object(PROBE.os, "urandom", return_value=nonce_bytes), patch.object(PROBE.LiveSocket, "call", return_value={}):
                if valid:
                    self.assertEqual(PROBE.LiveSocket(Browser(), "/chat").topic, "lv:root")
                else:
                    with self.assertRaisesRegex(RuntimeError, "handshake rejected"):
                        PROBE.LiveSocket(Browser(), "/chat")

    def test_foreign_container_or_volume_is_never_cleaned(self):
        for kind in ("container", "volume"):
            with patch.object(PROBE, "docker", return_value='[{"Labels": {}, "Config": {"Labels": {}}}]'):
                with self.assertRaisesRegex(RuntimeError, "not owned"):
                    PROBE.check_owner(kind, "resource", "our-owner")

    def lifecycle(self, fail=False, fail_start=False):
        calls = []
        owner = "b" * 32
        count = [0]

        def execute(args, data=None, timeout=120):
            calls.append((args, data))
            if args[:2] == ["container", "inspect"]:
                return json.dumps([{"Config": {"Labels": {PROBE.LABEL: owner}}}])
            if args[:2] == ["volume", "inspect"]:
                return json.dumps([{"Labels": {PROBE.LABEL: owner}}])
            if fail_start and args[:2] == ["run", "-d"]:
                raise RuntimeError("ambiguous Docker start failure")
            if args[0] == "exec":
                count[0] += 1
                if fail:
                    raise RuntimeError("probe failed")
                return json.dumps({"phase": "create" if count[0] == 1 else "recover", "chat_id": "a" * 32})
            return ""

        with patch.object(PROBE, "local_docker_host", return_value="unix:///tmp/probe.sock"), patch.object(PROBE, "docker", side_effect=execute), patch.object(PROBE.secrets, "token_hex", side_effect=[owner, "c" * 64]):
            if fail or fail_start:
                with self.assertRaisesRegex(RuntimeError, "probe failed|ambiguous Docker start failure"):
                    PROBE.run(IMAGE)
            else:
                self.assertEqual(len(PROBE.run(IMAGE)["checks"]), 2)
        return calls

    def test_both_normal_starts_are_unprivileged_offline_and_reuse_only_probe_volume(self):
        calls = self.lifecycle()
        starts = [args for args, _ in calls if args[:2] == ["run", "-d"]]
        self.assertEqual(len(starts), 2)
        for args in starts:
            self.assertEqual(args[args.index("--network") + 1], "none")
            self.assertEqual(args[args.index("--user") + 1], "10001:10001")
            self.assertEqual(args[args.index("--pull") + 1], "never")
            self.assertIn("--read-only", args)
            self.assertNotIn("--privileged", args)
            self.assertNotIn("--publish", args)
            self.assertNotIn("--env-file", args)
            self.assertNotIn("--entrypoint", args)
            self.assertEqual(sum(argument.startswith("type=volume,source=symphony-app-probe-") for argument in args), 1)
            self.assertFalse(any("type=bind" in argument or "/.codex" in argument or "docker.sock" in argument for argument in args))
        self.assertEqual(sum(args[:2] == ["volume", "rm"] for args, _ in calls), 1)

    def test_failed_check_still_stops_exact_owned_container_and_removes_disposable_volume(self):
        calls = self.lifecycle(fail=True)
        actions = [args[0] for args, _ in calls]
        self.assertEqual(actions[-5:], ["container", "stop", "rm", "volume", "volume"])
        self.assertFalse(any("--force" in args or "-f" in args for args, _ in calls))

    def test_ambiguous_start_failure_reconciles_intent_before_removing_resources(self):
        calls = self.lifecycle(fail_start=True)
        actions = [args[0] for args, _ in calls]
        self.assertEqual(actions[-5:], ["container", "stop", "rm", "volume", "volume"])

    def test_absent_intended_resource_is_distinct_from_foreign_or_unavailable(self):
        with patch.object(PROBE, "docker", side_effect=PROBE.DockerError("container", "Error: No such container: probe")):
            self.assertIsNone(PROBE.check_owner("container", "probe", "owner", missing_ok=True))
        with patch.object(PROBE, "docker", side_effect=PROBE.DockerError("container", "Cannot connect to daemon")):
            with self.assertRaises(PROBE.DockerError):
                PROBE.check_owner("container", "probe", "owner", missing_ok=True)

    def test_sigterm_becomes_an_exception_so_resource_finally_runs(self):
        previous = signal.signal(signal.SIGTERM, PROBE.cancelled)
        cleaned = []
        try:
            with self.assertRaisesRegex(RuntimeError, "interrupted"):
                try:
                    os.kill(os.getpid(), signal.SIGTERM)
                finally:
                    cleaned.append(True)
        finally:
            signal.signal(signal.SIGTERM, previous)
        self.assertEqual(cleaned, [True])


if __name__ == "__main__":
    unittest.main()
