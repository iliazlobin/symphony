"""Bootstrap-only boundary checks; no Docker, cloud, or model calls."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("gke_bootstrap", Path(__file__).with_name("entrypoint.py"))
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.state = Path(self.directory.name) / "control.json"
        self.paused = {"version": 1, "revision": 7, "mode": "paused", "issues": {}, "commands": {}}

    def write_state(self, value):
        self.state.write_text(json.dumps(value), encoding="utf-8")
        return self.state.read_bytes()

    def test_fresh_start_permitted_but_readiness_requires_native_journal(self):
        bootstrap.validate_state(self.state)
        with self.assertRaisesRegex(ValueError, "not initialized"):
            bootstrap.validate_state(self.state, required=True)
        self.assertFalse(self.state.exists())

    def test_retained_paused_revision_is_preserved(self):
        original = self.write_state(self.paused)
        bootstrap.validate_state(self.state, required=True)
        self.assertEqual(original, self.state.read_bytes())

    def test_running_draining_and_existing_task_state_fail_without_reset(self):
        for changes in ({"mode": "running"}, {"mode": "draining"}, {"issues": {"6": {"active": None}}}):
            with self.subTest(changes=changes):
                original = self.write_state({**self.paused, **changes})
                with self.assertRaisesRegex(ValueError, "empty, paused"):
                    bootstrap.validate_state(self.state)
                self.assertEqual(original, self.state.read_bytes())

    def test_invalid_state_and_symlinks_fail(self):
        for changes in ({"version": 2}, {"version": True}, {"revision": True}, {"revision": -1}, {"commands": []}):
            with self.subTest(changes=changes):
                self.write_state({**self.paused, **changes})
                with self.assertRaises(ValueError):
                    bootstrap.validate_state(self.state)
        original = self.write_state(self.paused)
        link = self.state.with_name("link.json")
        link.symlink_to(self.state)
        with self.assertRaisesRegex(ValueError, "regular file"):
            bootstrap.validate_state(link)
        self.assertEqual(original, self.state.read_bytes())

    def test_oversized_journal_fails(self):
        self.state.write_bytes(b" " * (bootstrap.MAX_STATE_BYTES + 1))
        with self.assertRaises(ValueError):
            bootstrap.validate_state(self.state)

    def test_launcher_cannot_inherit_control_credentials_or_replace_workflow(self):
        with mock.patch.object(bootstrap, "STATE_PATH", self.state), \
             mock.patch.object(bootstrap.Path, "mkdir"), \
             mock.patch.object(bootstrap.os, "execve") as execute, \
             mock.patch.dict(bootstrap.os.environ, {"SYMPHONY_CONTROL_TOKEN": "test-only-control-token", "ERL_FLAGS": "untrusted"}), \
             contextlib.redirect_stdout(io.StringIO()):
            bootstrap.main(["serve"])
        binary, arguments, environment = execute.call_args.args
        self.assertEqual(binary, "/opt/symphony/symphony")
        self.assertEqual(arguments[-1], "/opt/symphony/WORKFLOW.md")
        self.assertNotIn("SYMPHONY_CONTROL_TOKEN", environment)
        self.assertEqual(environment["ERL_FLAGS"], "+S 2:2")
        with self.assertRaisesRegex(ValueError, "custom workflow"):
            bootstrap.main(["serve", "/tmp/alternative.md"])


if __name__ == "__main__":
    unittest.main()
