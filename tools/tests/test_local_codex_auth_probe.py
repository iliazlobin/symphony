"""No Docker or real sign-in: validate the external-auth probe's fake boundaries."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
SPEC = importlib.util.spec_from_file_location("probe_local_codex_auth", ROOT / "tools/probe_local_codex_auth.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)
from local_codex_auth import LocalCodexAuth


class LocalCodexAuthProbeTests(unittest.TestCase):
    def test_fake_host_supplies_only_synthetic_authentication_without_persisting_credentials(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            host = PROBE.fake_host(root)
            with patch.object(Path, "home", return_value=host["home"]):
                with LocalCodexAuth(binary=host["binary"], home=host["home"] / ".codex", cwd=host["client"]) as auth:
                    tokens = auth.cached_tokens()
                    self.assertEqual(tokens["chatgptAccountId"], "fake-symphony-canary")
                    self.assertEqual(tokens["accessToken"], host["token"])
            self.assertEqual(list((host["home"] / ".codex").iterdir()), [])
            methods = [json.loads(line) for line in host["methods"].read_text().splitlines()]
            self.assertTrue(set(methods) <= PROBE.HOST_METHODS)
            self.assertNotIn("thread/start", methods)
            self.assertNotIn(tokens["accessToken"], host["methods"].read_text())

    def test_probe_refuses_wrong_auth_modes_and_any_returned_token(self):
        account = {"account": {"type": "chatgpt"}}
        PROBE.verify_auth_responses({"authMethod": "chatgptAuthTokens", "authToken": None}, account)
        for status in ({"authMethod": "chatgpt", "authToken": None},
                       {"authMethod": "chatgptAuthTokens", "authToken": "fake token"}):
            with self.assertRaises(RuntimeError):
                PROBE.verify_auth_responses(status, account)
        with self.assertRaises(RuntimeError):
            PROBE.verify_auth_responses({"authMethod": "chatgptAuthTokens", "authToken": None},
                                        {"account": {"type": "apiKey"}})

    def test_probe_refuses_disk_auth_files_mounts_and_host_model_calls(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            host_root, worker = parent / "host", parent / "worker"
            host_root.mkdir(mode=0o700)
            worker.mkdir(mode=0o700)
            host = PROBE.fake_host(host_root)
            host["methods"].write_text('"initialize"\n"getAuthStatus"\n')
            PROBE.verify_fixture_state(worker, host, {"Mounts": []})
            auth = worker / "auth.json"
            auth.write_text("fake token")
            with self.assertRaises(RuntimeError):
                PROBE.verify_fixture_state(worker, host, {"Mounts": []})
            auth.unlink()
            log = worker / "retained-session.log"
            log.write_bytes(b"diagnostic record " + host["token"].encode())
            with self.assertRaisesRegex(RuntimeError, "retained files"):
                PROBE.verify_fixture_state(worker, host, {"Mounts": []})
            log.unlink()
            with self.assertRaises(RuntimeError):
                PROBE.verify_fixture_state(worker, host, {"Mounts": [{"Source": str(host["binary"])}]})
            host["methods"].write_text('"getAuthStatus"\n"thread/start"\n')
            with self.assertRaises(RuntimeError):
                PROBE.verify_fixture_state(worker, host, {"Mounts": []})


if __name__ == "__main__":
    unittest.main()
