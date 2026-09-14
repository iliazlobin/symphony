"""Guard the host configuration and task workspace boundary."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("ec_profile", Path(__file__).resolve().parents[2] / "profiles/events-concierge/profile.py")
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)

WORKFLOW = """---
tracker:
  kind: github
  provider: {repo: iliazlobin/events-concierge}
  required_labels: ['symphony:ready']
  active_states: [open]
  terminal_states: [closed]
control:
  enabled: true
  initial_mode: paused
  base_sha: $SYMPHONY_BASE_SHA
agent:
  max_concurrent_agents: 1
---
Keep scope bounded.
"""


class ProfileTests(unittest.TestCase):
    def test_checks_effective_yaml_not_matching_prompt_text(self):
        profile.validate_workflow(WORKFLOW)
        for changed in (WORKFLOW.replace("enabled: true", "enabled: false"), WORKFLOW.replace("initial_mode: paused", "initial_mode: running"), WORKFLOW.replace("max_concurrent_agents: 1", "max_concurrent_agents: 8"), WORKFLOW.replace("iliazlobin/events-concierge", "example/other")):
            with self.assertRaises(profile.ControlError):
                profile.validate_workflow(changed + "\ninitial_mode: paused\nmax_concurrent_agents: 1\nenabled: true")

    def test_private_state_rejects_directory_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            real = root / "real"
            profile.private_directory(real)
            link = root / "link"
            link.symlink_to(real, target_is_directory=True)
            with self.assertRaises(profile.ControlError):
                profile.private_directory(link)

    def test_worker_requires_explicit_host_activation(self):
        with self.assertRaisesRegex(profile.ControlError, "disabled"):
            profile.codex_server({})

    def test_clone_is_pinned_and_cannot_inherit_host_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            source, workspaces, home = root / "source", root / "workspaces", root / "home"
            for directory in (source, workspaces, home):
                directory.mkdir()
            def git(*args):
                return profile.run("git", *args, cwd=source)
            git("init", "-b", "main")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            (source / "sample").write_text("committed")
            git("add", "sample")
            git("commit", "-m", "Fixture")
            base = git("rev-parse", "HEAD")
            (source / "sample").write_text("uncommitted owner work")
            (source / ".env").write_text("FAKE=canary")
            task = workspaces / "EC-7"
            task.mkdir()
            config = {"workspace_root": str(workspaces), "source_path": str(source), "base_sha": base, "worker_home": str(home)}
            original = Path.cwd()
            try:
                os.chdir(task)
                profile.workspace_create(config)
                self.assertEqual((task / "sample").read_text(), "committed")
                self.assertFalse((task / ".env").exists())
                self.assertEqual(profile.run("git", "remote", "get-url", "--push", "origin", cwd=task), "disabled://host-publishes-candidates")
                self.assertEqual(profile.before_run(config)["branch"], "codex/ec-7")
                # A repo-local hook must never run during host validation.
                marker = root / "hook-executed"
                script = task / "hook.sh"
                script.write_text("#!/bin/sh\ntouch '" + str(marker) + "'\n")
                script.chmod(0o700)
                profile.run("git", "config", "core.fsmonitor", str(script), cwd=task)
                profile.run("git", "status", "--porcelain", cwd=task)
                self.assertFalse(marker.exists())
                (task / ".env").write_text("FAKE=canary")
                with self.assertRaises(profile.ControlError):
                    profile.before_run(config)
            finally:
                os.chdir(original)


if __name__ == "__main__":
    unittest.main()
