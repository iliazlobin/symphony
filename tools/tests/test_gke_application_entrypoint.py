import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import yaml


SOURCE = Path(__file__).resolve().parents[2] / "deploy" / "gke" / "application_entrypoint.py"
SPEC = importlib.util.spec_from_file_location("gke_application_entrypoint", SOURCE)
entrypoint = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(entrypoint)


class ApplicationEntrypointTests(unittest.TestCase):
    def setUp(self):
        original_umask = os.umask(0o077)
        os.umask(original_umask)
        self.addCleanup(os.umask, original_umask)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()
        self.state = self.directory / "state"
        self.state.mkdir()
        self.workflow = self.directory / "WORKFLOW.md"
        self.config = {
            "tracker": {"kind": "github", "provider": {"repo": "operator/application", "token": "fake-test-only"}},
            "control": {"enabled": True, "initial_mode": "paused", "state_path": str(self.state / "control.json")},
            "codex": {"command": "/bin/false"},
            "workspace": {"root": str(self.directory / "workspaces")},
            "chat": {
                "enabled": True,
                "max_concurrent": 1,
                "state_path": str(self.state / "chat"),
                "codex_home": str(self.state / "chat-auth"),
                "executable": entrypoint.CHAT_EXECUTABLE,
            },
            "server": {"host": "127.0.0.1", "port": 8080},
        }
        self.mount = mock.patch.object(entrypoint.os.path, "ismount", return_value=True)
        self.mount.start()
        self.addCleanup(self.mount.stop)

    def write_workflow(self):
        self.workflow.write_text("---\n" + yaml.safe_dump(self.config) + "---\nReviewed operator prompt.\n")

    def validate(self, environment=None):
        self.write_workflow()
        return entrypoint.validate(str(self.workflow), str(self.state), environment or {})

    def test_enabled_full_package_can_boot_unenrolled_without_creating_auth(self):
        workflow, root, paths = self.validate()
        entrypoint.prepare_directories(root, paths)
        self.assertEqual(workflow, self.workflow)
        self.assertTrue(paths["chat"].is_dir())
        self.assertTrue(paths["authentication"].is_dir())
        self.assertFalse((paths["authentication"] / "auth.json").exists())
        self.assertFalse(paths["journal"].exists())

    def test_pilot_rejects_task_execution_even_if_controls_can_be_resumed(self):
        for key, value in (("codex", {"command": "/opt/symphony/bin/codex"}),
                           ("hooks", {"after_create": "git clone example"}),
                           ("worker", {"ssh_hosts": ["worker.example"]})):
            with self.subTest(key=key):
                previous = self.config.get(key)
                self.config[key] = value
                with self.assertRaises(entrypoint.ConfigurationError):
                    self.validate()
                if previous is None:
                    self.config.pop(key)
                else:
                    self.config[key] = previous

    def test_serve_executes_normal_application_with_operator_workflow(self):
        self.write_workflow()
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(entrypoint.os, "execv") as execute:
            entrypoint.main(["serve", "--workflow", str(self.workflow), "--state-root", str(self.state)])
        execute.assert_called_once_with(entrypoint.APPLICATION, [
            entrypoint.APPLICATION, entrypoint.GUARDRAILS_ACK, "--logs-root", str(self.state / "logs"), str(self.workflow),
        ])

    def test_running_or_unresolved_journal_is_preserved_and_rejected(self):
        journal = self.state / "control.json"
        for record in ({"mode": "running", "issues": {}}, {"mode": "paused", "issues": {"task": {"active": {"owner": "old"}}}}):
            journal.write_text(json.dumps(record))
            before = journal.read_bytes()
            with self.assertRaises(entrypoint.ConfigurationError):
                self.validate()
            self.assertEqual(before, journal.read_bytes())

    def test_paused_existing_journal_is_not_rewritten(self):
        journal = self.state / "control.json"
        journal.write_text('{"mode":"paused","issues":{"task":{"active":null}}}\n')
        before = journal.read_bytes()
        self.validate()
        self.assertEqual(before, journal.read_bytes())

    def test_state_requires_mount_and_cannot_overlap_workspace(self):
        with mock.patch.object(entrypoint.os.path, "ismount", return_value=False):
            with self.assertRaisesRegex(entrypoint.ConfigurationError, "mounted"):
                self.validate()
        self.config["workspace"]["root"] = str(self.state)
        with self.assertRaisesRegex(entrypoint.ConfigurationError, "separate from workspaces"):
            self.validate()

    def test_tracker_requires_explicit_repository_and_token_without_silent_fallback(self):
        provider = self.config["tracker"]["provider"]
        provider["repo"] = "$REPOSITORY"
        provider["token"] = "$TRACKER_TOKEN"
        self.validate({"REPOSITORY": "operator/application", "TRACKER_TOKEN": "fake-test-only"})
        with self.assertRaises(entrypoint.ConfigurationError):
            self.validate()
        provider["repo"] = "operator/application"
        provider["token"] = "fake-test-only"
        for url in ("http://api.github.com", "https://secret@api.github.com", "https://api.github.com/?secret=value"):
            provider["api_url"] = url
            with self.assertRaises(entrypoint.ConfigurationError):
                self.validate()

    def test_auth_directory_cannot_overlap_conversations(self):
        self.config["chat"]["codex_home"] = str(self.state / "chat" / "auth")
        with self.assertRaisesRegex(entrypoint.ConfigurationError, "must be separate"):
            self.validate()

    def test_symlink_state_and_auth_are_rejected(self):
        target = self.directory / "elsewhere"
        target.mkdir()
        (self.state / "chat-auth").symlink_to(target, target_is_directory=True)
        with self.assertRaisesRegex(entrypoint.ConfigurationError, "free of symlinks"):
            self.validate()
        (self.state / "chat-auth").unlink()
        (self.state / "chat-auth").mkdir()
        record = target / "auth.json"
        record.write_text('{"auth_mode":"chatgpt"}')
        (self.state / "chat-auth" / "auth.json").symlink_to(record)
        with self.assertRaisesRegex(entrypoint.ConfigurationError, "bounded regular file"):
            self.validate()

    def test_api_keys_and_imported_home_configuration_are_rejected(self):
        for variable in ("OPENAI_API_KEY", "CODEX_API_KEY"):
            with self.assertRaisesRegex(entrypoint.ConfigurationError, "API-key"):
                self.validate({variable: "fake-test-only"})
        home = self.state / "chat-auth"
        home.mkdir()
        (home / "auth.json").write_text('{"auth_mode":"apikey","OPENAI_API_KEY":"fake-test-only"}')
        with self.assertRaisesRegex(entrypoint.ConfigurationError, "ChatGPT subscription"):
            self.validate()
        (home / "auth.json").write_text('{"auth_mode":"chatgpt","OPENAI_API_KEY":null}')
        self.validate()
        (home / "config.toml").write_text("# Imported configuration must not be used\n")
        with self.assertRaisesRegex(entrypoint.ConfigurationError, "dedicated home"):
            self.validate()

    def test_strict_pilot_contract_rejects_disabled_chat_and_remote_bind(self):
        changes = [
            ("chat", "enabled", False), ("chat", "max_concurrent", 2),
            ("chat", "max_concurrent", True), ("chat", "executable", "/usr/local/bin/codex"),
            ("server", "host", "0.0.0.0"), ("server", "port", True),
            ("control", "enabled", False), ("control", "initial_mode", "running"),
            ("tracker", "kind", "memory"),
        ]
        for section, key, value in changes:
            with self.subTest(section=section, key=key, value=value):
                old = self.config[section][key]
                self.config[section][key] = value
                with self.assertRaises(entrypoint.ConfigurationError):
                    self.validate()
                self.config[section][key] = old

    def test_duplicate_yaml_and_parser_secrets_do_not_reach_error_output(self):
        self.write_workflow()
        self.workflow.write_text(self.workflow.read_text().replace("---\n", "---\nchat: {}\n", 1))
        with self.assertRaisesRegex(entrypoint.ConfigurationError, "unique strings"):
            entrypoint.validate(str(self.workflow), str(self.state), {})
        self.workflow.write_text("---\ntracker: [secret-would-be-here\n---\n")
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch("sys.stderr") as error:
            self.assertEqual(entrypoint.main(["serve", "--workflow", str(self.workflow), "--state-root", str(self.state)]), 1)
        self.assertNotIn("secret-would-be-here", str(error.write.call_args_list))

    def test_existing_auth_directory_must_be_private(self):
        _, root, paths = self.validate()
        paths["authentication"].mkdir(mode=0o755)
        with self.assertRaisesRegex(entrypoint.ConfigurationError, "owner-only"):
            entrypoint.prepare_directories(root, paths)


if __name__ == "__main__":
    unittest.main()
