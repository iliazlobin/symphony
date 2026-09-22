"""Self-management uses the same host pipeline without sharing project authority."""
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import symphony_service as service
from worker_policy import render_policy

spec = importlib.util.spec_from_file_location("self_profile_adapter", ROOT / "profiles/events-concierge/profile.py")
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)
REPOSITORY = "iliazlobin/symphony"
REMOTE = "https://github.com/" + REPOSITORY + ".git"
ENTRY = ROOT / "profiles/symphony/profile.py"


class SelfProjectTests(unittest.TestCase):
    def test_workflow_binds_self_repository_and_disables_initial_dispatch(self):
        content = (ROOT / "WORKFLOW.md").read_text()
        profile.validate_workflow(content, REPOSITORY)
        settings = profile.yaml.safe_load(content.split("---\n", 2)[1])
        self.assertEqual(settings["control"]["max_total_tokens"], 1_000_000)
        self.assertEqual(settings["control"]["initial_mode"], "paused")
        self.assertEqual(settings["browser_auth"]["provider"], "google")
        self.assertEqual(settings["browser_auth"]["allowed_emails"], [])
        self.assertEqual(settings["server"]["session_cookie"], "_symphony_self_key")
        with self.assertRaises(profile.ControlError):
            profile.validate_workflow(content)
        with self.assertRaises(profile.ControlError):
            profile.validate_workflow(content, "example/unregistered")

    def test_initialization_and_real_checkout_preserve_project_scope_and_owner_edits(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            source = root / "source"
            source.mkdir()
            def git(*args):
                return profile.run("git", *args, cwd=source)
            git("init", "-b", "main")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            git("remote", "add", "origin", REMOTE)
            (source / "WORKFLOW.md").write_text((ROOT / "WORKFLOW.md").read_text())
            (source / "sample").write_text("committed")
            git("add", ".")
            git("commit", "-m", "Fixture")
            base = git("rev-parse", "HEAD")
            (source / "sample").write_text("owner edit")
            (source / ".env").write_text("CANARY=owner-only")
            state = root / "symphony"
            args = SimpleNamespace(state_dir=str(state), source=str(source), base_sha=base,
                                   integration_branch="main", port=8779)
            profile.initialize(args, REPOSITORY, ENTRY)
            config = profile.load_config(state / "config.json")
            self.assertEqual(config["repository"], REPOSITORY)
            self.assertEqual(config["profile_bin"], str(ENTRY))
            self.assertEqual(config["api_url"], "http://127.0.0.1:8779")
            self.assertFalse(config["worker_launch_enabled"])
            self.assertFalse(config["auto_merge"]["enabled"])
            self.assertTrue((state / "chat").is_dir())
            self.assertTrue((state / "management-codex").is_dir())
            before = (state / "config.json").read_bytes()
            with self.assertRaises(profile.ControlError):
                profile.initialize(args, REPOSITORY, ENTRY)
            self.assertEqual(before, (state / "config.json").read_bytes())
            checkout = state / "workspaces/GH-27"
            checkout.mkdir()
            previous = Path.cwd()
            try:
                os.chdir(checkout)
                profile.workspace_create(config)
                profile.before_run(config)
                self.assertEqual((checkout / "sample").read_text(), "committed")
                self.assertFalse((checkout / ".env").exists())
                self.assertEqual(profile.run("git", "remote", "get-url", "origin", cwd=checkout), REMOTE)
                self.assertEqual(profile.run("git", "remote", "get-url", "--push", "origin", cwd=checkout),
                                 "disabled://host-publishes-candidates")
                with self.assertRaises(profile.ControlError):
                    profile.before_run({**config, "repository": "iliazlobin/events-concierge"})
            finally:
                os.chdir(previous)
            self.assertEqual((source / "sample").read_text(), "owner edit")
            with self.assertRaisesRegex(profile.ControlError, "disabled"):
                profile.codex_server(config)

    def test_self_controller_supplies_durable_intake_paths_without_ambient_chat_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            workflow = root / "WORKFLOW.md"
            workflow.write_text((ROOT / "WORKFLOW.md").read_text())
            workflow.chmod(0o600)
            binary = root / "elixir/bin/symphony"
            binary.parent.mkdir(parents=True)
            binary.touch()
            config = {"repository": REPOSITORY, "workflow_path": str(workflow), "state_dir": str(root),
                      "base_sha": "a" * 40, "_token": "fixture", "workspace_root": str(root / "workspaces"),
                      "profile_bin": str(ENTRY), "_config_path": str(root / "config.json"),
                      "api_url": "http://127.0.0.1:8779", "management_codex_binary": "/reviewed/codex"}
            with patch.object(profile, "ROOT", root), patch.object(profile.os, "chdir"), \
                    patch.object(profile.os, "execve") as execute, patch.object(profile, "run", return_value="fixture"), \
                    patch.dict(os.environ, {"SYMPHONY_CHAT_CODEX_HOME": "/other/project"}):
                profile.start_service(config)
                env = execute.call_args.args[2]
                self.assertEqual(env["SYMPHONY_CHAT_STATE"], str(root / "chat"))
                self.assertEqual(env["SYMPHONY_CHAT_CODEX_HOME"], str(root / "management-codex"))
                self.assertEqual(env["SYMPHONY_CHAT_CODEX_EXECUTABLE"], "/reviewed/codex")
                self.assertEqual(os.environ["SYMPHONY_CHAT_CODEX_HOME"], "/other/project")
                self.assertIn("8779", execute.call_args.args[1])

    def test_profile_refuses_cross_project_config_before_any_operation(self):
        with patch.object(profile, "load_config", return_value={"repository": "iliazlobin/events-concierge"}), \
                patch.object(sys, "argv", ["profile.py", "doctor"]):
            self.assertEqual(profile.main(REPOSITORY, ENTRY), 1)

    def test_service_definitions_cannot_replace_the_other_project(self):
        def config(slug):
            return {"repository": "iliazlobin/" + slug, "state_dir": "/private/" + slug,
                    "profile_bin": str(ROOT / "profiles" / slug / "profile.py"),
                    "_config_path": "/private/" + slug + "/config.json"}
        ec = service.definitions(config("events-concierge"))
        own = service.definitions(config("symphony"))
        self.assertEqual(set(ec), {"com.iliazlobin.symphony.events-concierge",
                                   "com.iliazlobin.symphony.events-concierge.publication"})
        self.assertFalse(set(ec) & set(own))
        args = own["com.iliazlobin.symphony.symphony"]["ProgramArguments"]
        self.assertEqual(args[1], str(ENTRY))
        self.assertEqual(args[-1], "run")
        crossed = config("symphony")
        crossed["profile_bin"] = config("events-concierge")["profile_bin"]
        with self.assertRaises(profile.ControlError):
            service.definitions(crossed)
        with self.assertRaises(profile.ControlError):
            service.definitions({**crossed, "repository": "example/other"})

    def test_worker_policy_has_its_own_name_and_scope(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp).resolve()
            workspaces = state / "workspaces"
            workspaces.mkdir(mode=0o700)
            content = render_policy(workspaces, "symphony-self-codex")
            self.assertIn('profile "symphony-self-codex"', content)
            self.assertNotIn('profile "symphony-codex"', content)
            policy = state / "worker-apparmor"
            policy.write_text(content)
            policy.chmod(0o600)
            seccomp = ROOT / "profiles/events-concierge/seccomp-codex.json"
            config = {"repository": REPOSITORY, "state_dir": str(state), "workspace_root": str(workspaces),
                      "worker_sandbox": {"apparmor_profile": "symphony-self-codex", "workspace_root": str(workspaces),
                                         "apparmor_sha256": hashlib.sha256(content.encode()).hexdigest(),
                                         "seccomp_sha256": hashlib.sha256(seccomp.read_bytes()).hexdigest()}}
            self.assertEqual(profile.container_launch_options(config)[-1], "symphony-self-codex")
            with self.assertRaises(profile.ControlError):
                profile.container_launch_options({**config, "repository": "iliazlobin/events-concierge"})
            with self.assertRaises(ValueError):
                render_policy(workspaces, 'unconfined')

    def test_wrapper_is_callable_without_side_effects(self):
        result = subprocess.run([sys.executable, str(ENTRY), "init", "--help"],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--base-sha", result.stdout)
        self.assertIn("--state-dir", result.stdout)


if __name__ == "__main__":
    unittest.main()
