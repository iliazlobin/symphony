"""Guard the host configuration and task workspace boundary."""
import importlib.util
import hashlib
import json
import configparser
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
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
    def oauth_file(self, root):
        path = root / "google-client.json"
        path.write_text(json.dumps({"web": {
            "client_id": "fixture.apps.googleusercontent.com", "client_secret": "fixture-secret",
            "redirect_uris": ["http://localhost:8778/auth/google/callback"],
        }}))
        path.chmod(0o600)
        return path

    def test_optional_oauth_file_preserves_existing_environment(self):
        with patch.dict(os.environ, {"SYMPHONY_GOOGLE_CLIENT_ID": "existing"}), \
                patch.object(profile, "read_private") as read:
            self.assertEqual(profile.google_oauth_environment({}), {})
            self.assertEqual(os.environ["SYMPHONY_GOOGLE_CLIENT_ID"], "existing")
            read.assert_not_called()

    def test_oauth_file_rejects_missing_unsafe_and_non_web_credentials_without_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = self.oauth_file(root)
            cases = [None, "", "relative.json", str(root / "missing.json")]
            for location in cases:
                with self.subTest(location=location), self.assertRaises(profile.ControlError):
                    profile.google_oauth_environment({"google_oauth_client_file": location})
            for mode in (0o400, 0o644, 0o700):
                path.chmod(mode)
                with self.subTest(mode=mode), self.assertRaises(profile.ControlError):
                    profile.google_oauth_environment({"google_oauth_client_file": str(path)})
            path.chmod(0o600)
            for document in ('{"web": "fixture-secret"}', '{"installed": {}}',
                             '{"web": {"client_id": "fixture-secret"}}',
                             '{"web": {"client_id": "wrong-host", "client_secret": "fixture-secret"}}',
                             '{"web": {"client_id": "fixture.apps.googleusercontent.com", "client_secret": "x\\u0000"}}',
                             '{"web": {"client_id": "fixture.apps.googleusercontent.com", "client_secret": 4}}',
                             '{"fixture-secret"', 'null', '[]'):
                path.write_text(document)
                with self.subTest(document=document), self.assertRaises(profile.ControlError) as raised:
                    profile.google_oauth_environment({"google_oauth_client_file": str(path)})
                self.assertNotIn("fixture-secret", str(raised.exception))
                self.assertNotIn(str(path), str(raised.exception))

    def test_oauth_file_rejects_symlink_and_other_owner(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = self.oauth_file(root)
            link = root / "client-link.json"
            link.symlink_to(path)
            with self.assertRaises(profile.ControlError):
                profile.google_oauth_environment({"google_oauth_client_file": str(link)})
            with patch.object(profile.os, "getuid", return_value=os.getuid() + 1), \
                    self.assertRaises(profile.ControlError):
                profile.google_oauth_environment({"google_oauth_client_file": str(path)})

    def test_controller_loads_oauth_without_changing_parent_or_worker_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = self.oauth_file(root)
            workflow = root / "WORKFLOW.md"
            workflow.write_text(WORKFLOW)
            workflow.chmod(0o600)
            binary = root / "elixir/bin/symphony"
            binary.parent.mkdir(parents=True)
            binary.touch()
            config = {"google_oauth_client_file": str(path), "workflow_path": str(workflow),
                      "state_dir": str(root), "base_sha": "a" * 40, "_token": "control-fixture",
                      "workspace_root": str(root / "workspaces"), "profile_bin": "profile.py",
                      "_config_path": str(root / "config.json"), "api_url": "http://127.0.0.1:8778",
                      "codex_home": str(root / "worker-home")}
            with patch.object(profile, "ROOT", root), patch.object(profile.os, "chdir"), \
                    patch.object(profile.os, "execve") as execute, patch.object(profile, "run", return_value="github-fixture") as gh, \
                    patch.dict(os.environ, {"SYMPHONY_GOOGLE_CLIENT_ID": "ambient-id", "SYMPHONY_GOOGLE_CLIENT_SECRET": "ambient-secret"}):
                profile.start_service(config)
                self.assertEqual(os.environ["SYMPHONY_GOOGLE_CLIENT_SECRET"], "ambient-secret")
                launched = execute.call_args.args[2]
                self.assertEqual(launched["SYMPHONY_GOOGLE_CLIENT_ID"], "fixture.apps.googleusercontent.com")
                self.assertEqual(launched["SYMPHONY_GOOGLE_CLIENT_SECRET"], "fixture-secret")
                self.assertEqual(launched["SYMPHONY_CONTROL_TOKEN"], "control-fixture")
                self.assertEqual(launched["GITHUB_TOKEN"], os.environ.get("GITHUB_TOKEN", "github-fixture"))
                self.assertNotIn("SYMPHONY_GOOGLE_CLIENT_SECRET", profile.worker_env(config))
                self.assertNotIn("SYMPHONY_GOOGLE_CLIENT_ID", profile.worker_env(config))
                self.assertNotIn("fixture-secret", str(execute.call_args.args[:2]))
                path.write_text("malformed fixture-secret")
                execute.reset_mock()
                gh.reset_mock()
                with self.assertRaises(profile.ControlError):
                    profile.start_service(config)
                execute.assert_not_called()
                gh.assert_not_called()

    def test_initialized_worker_config_disables_apps_and_preserves_role_permissions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            state, source = root / "state", root / "source"
            source.mkdir()
            base = "a" * 40
            args = SimpleNamespace(state_dir=str(state), source=str(source), base_sha=base,
                                   integration_branch="codex/pilot", port=8777)
            with patch.object(profile, "run", side_effect=[base, profile.REMOTE, WORKFLOW]):
                profile.initialize(args)
            installed = json.loads((state / "config.json").read_text())
            self.assertIs(installed["worker_launch_enabled"], False)
            workflow = profile.yaml.safe_load((state / "WORKFLOW.md").read_text().split("---\n", 2)[1])
            self.assertEqual(workflow["agent"]["max_concurrent_agents"], 1)
            # The generated scalar sections are also valid INI when the TOML
            # root keys get an explicit section; no Codex/auth calls are needed.
            config = configparser.RawConfigParser(delimiters=("=",))
            config.read_string("[root]\n" + (state / "codex/config.toml").read_text())
            self.assertEqual(config["shell_environment_policy"]["inherit"], '"none"')
            self.assertEqual(dict(config["shell_environment_policy.set"]),
                             {"path": '"/usr/local/bin:/usr/bin:/bin"'})
            self.assertFalse(config.getboolean("features", "apps"))
            self.assertFalse(config.getboolean("features", "multi_agent"))
            self.assertEqual(config["root"]["approval_policy"], '"on-request"')
            self.assertEqual(config["root"]["approvals_reviewer"], '"user"')
            for role in ("builder", "reviewer"):
                self.assertFalse(config.getboolean("permissions.symphony-" + role + ".network", "enabled"))
                self.assertEqual(config["permissions.symphony-" + role + ".filesystem"]['":root"'], '"deny"')

    def test_explicit_command_environment_finds_tools_without_ambient_variables(self):
        config = configparser.RawConfigParser(delimiters=("=",))
        config.read_string("[root]\n" + profile.permission_config())
        self.assertEqual(config["shell_environment_policy"]["inherit"], '"none"')
        explicit = {key.upper(): json.loads(value)
                    for key, value in config["shell_environment_policy.set"].items()}
        self.assertEqual(explicit, {"PATH": "/usr/local/bin:/usr/bin:/bin"})
        with patch.dict(os.environ, {"PATH": "/nonexistent-ambient-bin",
                                     "SYMPHONY_TEST_AMBIENT": "must-not-inherit"}):
            result = subprocess.run(
                ["/bin/sh", "-c", 'command -v git && command -v cat && test -z "${SYMPHONY_TEST_AMBIENT+x}"'],
                env=explicit, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(path.startswith(("/usr/local/bin/", "/usr/bin/", "/bin/"))
                            for path in result.stdout.splitlines()))

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

    def test_retained_worker_identity_is_forwarded_only_for_valid_builder_scope(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            config = self.sandbox_config(root)
            home = root / "codex"
            home.mkdir()
            (home / "auth.json").write_text("{}")
            (root / "bin").mkdir()
            (root / "bin/codex-rules").touch()
            config.update(worker_launch_enabled=True, codex_home=str(home), worker_image_id="sha256:" + "a" * 64)
            environment = {"SYMPHONY_CONTAINER_CIDFILE": str(root / "owned.cid"),
                           "SYMPHONY_CONTAINER_OWNER": "b" * 32, "SYMPHONY_WORKER_ROLE": "builder",
                           "SYMPHONY_PR_WORK_ID": "c" * 32, "SYMPHONY_PR_WORK_RESUME": "true"}
            with patch.dict(os.environ, environment, clear=True), patch.object(profile, "run"), \
                    patch.object(profile.os, "execve") as execute:
                profile.codex_server(config)
                env = execute.call_args.args[2]
                self.assertEqual(env["SYMPHONY_PR_WORK_ID"], "c" * 32)
                self.assertEqual(env["SYMPHONY_PR_WORK_RESUME"], "true")
            for changes in ({"SYMPHONY_WORKER_ROLE": "reviewer"}, {"SYMPHONY_PR_WORK_ID": "../other"},
                            {"SYMPHONY_PR_WORK_RESUME": "false"}, {"SYMPHONY_PR_WORK_ID": ""}):
                with patch.dict(os.environ, dict(environment, **changes), clear=True), \
                        patch.object(profile, "run"), patch.object(profile.os, "execve") as execute, \
                        self.assertRaises(profile.ControlError):
                    profile.codex_server(config)
                execute.assert_not_called()

    def test_checks_effective_yaml_not_matching_prompt_text(self):
        profile.validate_workflow(WORKFLOW)
        for changed in (WORKFLOW.replace("enabled: true", "enabled: false"), WORKFLOW.replace("initial_mode: paused", "initial_mode: running"), WORKFLOW.replace("max_concurrent_agents: 1", "max_concurrent_agents: 8"), WORKFLOW.replace("iliazlobin/events-concierge", "example/other")):
            with self.assertRaises(profile.ControlError):
                profile.validate_workflow(changed + "\ninitial_mode: paused\nmax_concurrent_agents: 1\nenabled: true")

    def test_workflow_accepts_only_integer_one_to_five_task_slots(self):
        for slots in ("1", "2", "3", "4", "5"):
            with self.subTest(slots=slots):
                profile.validate_workflow(WORKFLOW.replace("max_concurrent_agents: 1", "max_concurrent_agents: " + slots))
        for slots in ("true", "false", "yes", "on", "1.0", "5.0", "2.5", "'1'", "'5'", "0", "-1", "6", "8", "null", "[]", "{}"):
            with self.subTest(slots=slots), self.assertRaisesRegex(profile.ControlError, "one to five task slots"):
                profile.validate_workflow(WORKFLOW.replace("max_concurrent_agents: 1", "max_concurrent_agents: " + slots))

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
