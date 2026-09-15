"""The standalone board is profile-bound and never becomes a second worker host."""
import contextlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import symphony_web as web


class WebLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.workflow = self.root / "WORKFLOW.md"
        self.workflow.write_text("""---
tracker:
  kind: github
  provider: {repo: example/repo, token: literal-secret-must-not-copy}
  required_labels: [symphony:ready, reviewed]
hooks:
  before_run: do-not-execute
---
Private worker instructions must not be copied.
""")
        self.workflow.chmod(0o600)
        self.config = {
            "repository": "example/repo", "workflow_path": str(self.workflow),
            "api_url": "http://127.0.0.1:8777", "_token": "controller-secret",
        }

    def make_runtime(self, repository):
        runtime = repository / ".runtime"
        mix = runtime / "elixir-1.19.5/bin/mix"
        mix.parent.mkdir(parents=True)
        mix.write_text("#!/bin/sh\nexit 0\n")
        mix.chmod(0o700)
        (runtime / "mix-1.19").mkdir()
        return runtime

    def test_workflow_keeps_scope_and_labels_but_no_worker_hooks_or_inline_secrets(self):
        tracker = web.tracker_scope(self.config)
        self.assertEqual(tracker["required_labels"], ["symphony:ready", "reviewed"])
        directory = self.root / "disposable"
        directory.mkdir(mode=0o700)
        path = web.write_workflow(directory, tracker)
        text = path.read_text()
        settings = json.loads(text.split("---\n")[1])
        self.assertEqual(settings["tracker"]["provider"], {
            "repo": "example/repo", "api_url": "https://api.github.com", "token": "$GITHUB_TOKEN"})
        self.assertEqual(settings["tracker"]["active_states"], ["open"])
        self.assertEqual(settings["tracker"]["terminal_states"], ["closed"])
        self.assertTrue(settings["control"]["enabled"])
        self.assertEqual(settings["control"]["state_path"], str(directory / "control.json"))
        self.assertFalse(settings["chat"]["enabled"])
        self.assertIsNone(settings["server"]["port"])
        self.assertNotIn("hooks", settings)
        self.assertNotIn("do-not-execute", text)
        self.assertNotIn("literal-secret", text)
        self.assertNotIn("Private worker", text)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual((directory / "workspaces").stat().st_mode & 0o777, 0o700)
        self.assertFalse((directory / "control.json").exists())

    def test_scope_mismatch_unsafe_yaml_and_invalid_labels_fail_before_launch(self):
        for front in [
            "tracker: {kind: linear, provider: {repo: example/repo}}",
            "tracker: {kind: github, provider: {repo: other/repo}}",
            "tracker: {kind: github, provider: {repo: example/repo, api_url: https://other.test}}",
            "tracker: {kind: github, provider: {repo: example/repo}, required_labels: ready}",
            "tracker: {kind: github, provider: {repo: example/repo}, required_labels: ['']}",
            "tracker: [",
            "!!python/object/apply:os.system ['touch should-never-exist']",
            "[]",
        ]:
            with self.subTest(front=front):
                self.workflow.write_text("---\n" + front + "\n---\nTask")
                with self.assertRaises(web.ControlError), patch.object(web.subprocess, "Popen") as child:
                    web.tracker_scope(self.config)
                child.assert_not_called()
        self.workflow.write_text("No front matter")
        with self.assertRaisesRegex(web.ControlError, "front matter"):
            web.tracker_scope(self.config)

    def test_runtime_found_in_checkout_or_canonical_git_common_root(self):
        runtime = self.make_runtime(self.root)
        with patch.object(web.subprocess, "run", side_effect=OSError):
            self.assertEqual(web.runtime_directory(self.root), runtime)
        worktree = self.root / "worktree"
        worktree.mkdir()
        reply = SimpleNamespace(returncode=0, stdout=str(self.root / ".git") + "\n")
        with patch.object(web.subprocess, "run", return_value=reply):
            self.assertEqual(web.runtime_directory(worktree), runtime.resolve())
        with patch.object(web.subprocess, "run", return_value=SimpleNamespace(returncode=1, stdout="")):
            with self.assertRaisesRegex(web.ControlError, "Pinned Elixir"):
                web.runtime_directory(worktree)

    def test_environment_keeps_credentials_server_side_and_removes_worker_authority(self):
        original = {
            "PATH": "/usr/bin:/bin", "GITHUB_TOKEN": "existing-github-secret",
            "SYMPHONY_CONTROL_TOKEN": "browser-authority", "SYMPHONY_PROFILE_BIN": "/worker-launcher",
            "SYMPHONY_CONTROL_STATE": "/real/control.json", "SYMPHONY_OPERATOR_CONFIG": "/real/config.json",
            "SYMPHONY_WORKSPACE_ROOT": "/real/workspaces", "ERL_AFLAGS": "unsafe", "MIX_ENV": "prod",
        }
        with patch.object(web.subprocess, "run") as command:
            env = web.child_environment(self.config, self.root / ".runtime", original)
        command.assert_not_called()
        self.assertEqual(env["GITHUB_TOKEN"], "existing-github-secret")
        self.assertEqual(env["SYMPHONY_BOARD_CONTROL_TOKEN"], "controller-secret")
        self.assertEqual(env["SYMPHONY_BOARD_API_URL"], "http://127.0.0.1:8777")
        self.assertEqual(env["MIX_HOME"], str(self.root / ".runtime/mix-1.19"))
        self.assertEqual(env["MIX_ENV"], "dev")
        self.assertEqual(env["ERL_FLAGS"], "+S 4:4")
        self.assertNotIn("SYMPHONY_CONTROL_TOKEN", env)
        self.assertNotIn("SYMPHONY_PROFILE_BIN", env)
        self.assertNotIn("SYMPHONY_CONTROL_STATE", env)
        self.assertNotIn("ERL_AFLAGS", env)
        self.assertIn("SYMPHONY_CONTROL_TOKEN", original)

    def test_github_authentication_is_captured_and_errors_never_echo_credentials(self):
        reply = SimpleNamespace(returncode=0, stdout="captured-github-secret\n", stderr="")
        with patch.object(web.subprocess, "run", return_value=reply) as command:
            self.assertEqual(web.github_token({}), "captured-github-secret")
        self.assertEqual(command.call_args.args[0], ["gh", "auth", "token", "--hostname", "github.com"])
        self.assertTrue(command.call_args.kwargs["capture_output"])
        for result in [SimpleNamespace(returncode=1, stdout="secret", stderr="another-secret"),
                       SimpleNamespace(returncode=0, stdout="not a token", stderr="")]:
            with patch.object(web.subprocess, "run", return_value=result):
                with self.assertRaises(web.ControlError) as error:
                    web.github_token({})
                self.assertNotIn("secret", str(error.exception))
        with patch.object(web.subprocess, "run", side_effect=subprocess.TimeoutExpired("gh", 15)):
            with self.assertRaisesRegex(web.ControlError, "authentication unavailable"):
                web.github_token({})

    def test_same_controller_port_and_invalid_ports_cannot_start_anything(self):
        for port in [8777, 0, 65536, -1, True, "8778"]:
            with self.subTest(port=port), patch.object(web.subprocess, "Popen") as child:
                with self.assertRaisesRegex(web.ControlError, "different from"):
                    web.launch(self.config, port, self.root)
                child.assert_not_called()

    def test_launcher_starts_only_standalone_entrypoint_and_keeps_workflow_until_stopped(self):
        runtime = self.make_runtime(self.root)
        script = self.root / "elixir/tools/read_only_board.exs"
        script.parent.mkdir(parents=True)
        script.touch()
        child = Mock(pid=12345)
        child.wait.return_value = 0
        paths = []

        def started(command, **kwargs):
            self.assertEqual(command[:3], [str(runtime / "elixir-1.19.5/bin/mix"), "run", "--no-start"])
            self.assertEqual(command[3], str(script))
            self.assertNotIn("--", command)
            self.assertEqual(command[-1], "8778")
            self.assertEqual(kwargs["cwd"], self.root / "elixir")
            self.assertTrue(kwargs["start_new_session"])
            self.assertNotIn("SYMPHONY_CONTROL_TOKEN", kwargs["env"])
            path = Path(command[-2])
            self.assertTrue(path.is_file())
            self.assertNotEqual(path, self.workflow)
            paths.append(path)
            return child

        def stopped(_child):
            self.assertTrue(paths[0].exists())

        with patch.object(web.subprocess, "Popen", side_effect=started), \
             patch.object(web, "stop_child", side_effect=stopped), \
             patch.dict(os.environ, {"GITHUB_TOKEN": "secret"}):
            self.assertEqual(web.launch(self.config, 8778, self.root), 0)
        self.assertFalse(paths[0].parent.exists())
        self.assertTrue(self.workflow.exists())

    def test_signal_requests_stop_and_uncertain_cleanup_retains_private_configuration(self):
        runtime = self.make_runtime(self.root)
        script = self.root / "elixir/tools/read_only_board.exs"
        script.parent.mkdir(parents=True)
        script.touch()
        child = Mock(pid=12345)
        paths = []

        def started(command, **_kwargs):
            paths.append(Path(command[-2]))
            signal.getsignal(signal.SIGINT)(signal.SIGINT, None)
            return child

        previous_handler = signal.getsignal(signal.SIGINT)
        with patch.object(web.subprocess, "Popen", side_effect=started), \
             patch.object(web, "stop_child"), patch.dict(os.environ, {"GITHUB_TOKEN": "secret"}):
            self.assertEqual(web.launch(self.config, 8778, self.root), 130)
        self.assertEqual(signal.getsignal(signal.SIGINT), previous_handler)
        self.assertFalse(paths[0].parent.exists())

        with patch.object(web.subprocess, "Popen", side_effect=started), \
             patch.object(web, "stop_child", side_effect=web.ControlError("not stopped")), \
             patch.dict(os.environ, {"GITHUB_TOKEN": "secret"}):
            with self.assertRaisesRegex(web.ControlError, "retained private temporary"):
                web.launch(self.config, 8778, self.root)
        self.assertTrue(paths[-1].is_file())
        self.assertEqual(paths[-1].parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(signal.getsignal(signal.SIGINT), previous_handler)
        import shutil
        shutil.rmtree(paths[-1].parent)

    def test_process_cleanup_terminates_then_kills_stubborn_owned_group(self):
        child = Mock(pid=12345)
        child.wait.side_effect = [subprocess.TimeoutExpired("owned", 0.1), 0]
        with patch.object(web, "signal_group") as send, patch.object(web, "group_exists", return_value=False):
            web.stop_child(child, timeout=0.1)
        self.assertEqual([call.args for call in send.call_args_list], [(12345, signal.SIGTERM), (12345, signal.SIGKILL)])
        self.assertEqual(child.wait.call_count, 2)

    def test_already_exited_parent_does_not_leave_descendants_unchecked(self):
        child = Mock(pid=12345)
        child.wait.return_value = 0
        with patch.object(web, "signal_group") as send, \
             patch.object(web, "group_exists", side_effect=[True, True, False]), patch.object(web.time, "sleep"):
            web.stop_child(child, timeout=0.1)
        self.assertEqual([call.args for call in send.call_args_list], [(12345, signal.SIGTERM), (12345, signal.SIGKILL)])

    def test_real_owned_process_is_stopped_and_reaped(self):
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
        try:
            web.stop_child(child, timeout=2)
            self.assertIsNotNone(child.poll())
            self.assertFalse(web.group_exists(child.pid))
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=2)

    def test_main_uses_existing_private_profile_and_reports_errors_without_traceback(self):
        with patch.object(web, "load_config", return_value=self.config) as load, \
             patch.object(web, "launch", return_value=0) as launch:
            self.assertEqual(web.main(["--config", "/private/profile.json", "--port", "8778"]), 0)
        load.assert_called_once_with("/private/profile.json")
        launch.assert_called_once_with(self.config, 8778)
        error = io.StringIO()
        with patch.object(web, "load_config", side_effect=web.ControlError("Private configuration unavailable")), \
             contextlib.redirect_stderr(error):
            self.assertEqual(web.main([]), 1)
        self.assertEqual(error.getvalue(), "Private configuration unavailable\n")


if __name__ == "__main__":
    unittest.main()
