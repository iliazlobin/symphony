"""Guard the host configuration and task workspace boundary."""
import importlib.util
import hashlib
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
    def sandbox_config(self, root):
        from worker_policy import render_policy

        workspaces = root / "workspaces"
        workspaces.mkdir(mode=0o700)
        policy = root / "worker-apparmor"
        content = render_policy(workspaces)
        policy.write_text(content)
        policy.chmod(0o600)
        seccomp = profile.ROOT / "profiles/events-concierge/seccomp-codex.json"
        return {"state_dir": str(root), "workspace_root": str(workspaces), "worker_sandbox": {
            "workspace_root": str(workspaces), "apparmor_profile": "symphony-codex",
            "apparmor_sha256": hashlib.sha256(content.encode()).hexdigest(),
            "seccomp_sha256": hashlib.sha256(seccomp.read_bytes()).hexdigest(),
        }}

    def test_worker_policy_rejects_drift_and_different_workspace_scope(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = self.sandbox_config(Path(tmp).resolve())
            options = profile.container_launch_options(config)
            self.assertEqual(options[-2:], ["--apparmor-profile", "symphony-codex"])
            for field in ("apparmor_sha256", "seccomp_sha256", "workspace_root", "apparmor_profile"):
                changed = {**config, "worker_sandbox": {**config["worker_sandbox"], field: "changed"}}
                with self.subTest(field=field), self.assertRaises(profile.ControlError):
                    profile.container_launch_options(changed)
            policy = Path(tmp) / "worker-apparmor"
            policy.write_text(policy.read_text() + "# changed outside review\n")
            config["worker_sandbox"]["apparmor_sha256"] = hashlib.sha256(policy.read_bytes()).hexdigest()
            with self.assertRaisesRegex(profile.ControlError, "does not match"):
                profile.container_launch_options(config)

    def test_actual_worker_entrypoint_passes_verified_policies_for_both_roles(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            config = self.sandbox_config(root)
            home = root / "codex"
            home.mkdir()
            (home / "auth.json").write_text("{}")
            (root / "bin").mkdir()
            (root / "bin/codex-rules").touch()
            config.update(worker_launch_enabled=True, codex_home=str(home), worker_image_id="sha256:" + "a" * 64)
            for role in ("builder", "reviewer"):
                with self.subTest(role=role), patch.dict(os.environ, {
                    "SYMPHONY_CONTAINER_CIDFILE": str(root / "owned.cid"),
                    "SYMPHONY_CONTAINER_OWNER": "b" * 32, "SYMPHONY_WORKER_ROLE": role,
                }), patch.object(profile, "run") as sync, patch.object(profile.os, "execve") as execute:
                    profile.codex_server(config)
                    args = execute.call_args.args[1]
                    self.assertEqual(args[-4:], profile.container_launch_options(config))
                    self.assertEqual(execute.call_args.args[2]["SYMPHONY_WORKER_ROLE"], role)
                    sync.assert_called_once()

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
