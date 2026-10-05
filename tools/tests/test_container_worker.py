import importlib.util
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("container_worker", ROOT / "tools/container_worker.py")
WORKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WORKER)


class ContainerWorkerTests(unittest.TestCase):
    def test_credential_failures_have_safe_machine_exit_codes_without_false_startup_claims(self):
        for error, expected in ((WORKER.AuthLeaseError("PRIVATE INTERNAL MESSAGE"), 78),
                                (WORKER.AuthLeaseBusy("PRIVATE INTERNAL MESSAGE"), 79),
                                (WORKER.LocalCodexAuthError("PRIVATE INTERNAL MESSAGE"), 78)):
            with self.subTest(expected=expected), patch.object(WORKER, "main", side_effect=error), \
                    patch.object(WORKER, "print") as output:
                self.assertEqual(WORKER.entrypoint(), expected)
                self.assertNotIn("PRIVATE", str(output.call_args))
                if isinstance(error, WORKER.LocalCodexAuthError):
                    self.assertNotIn("no model turn", str(output.call_args))

    def test_local_bridge_failure_exit_does_not_discard_success_or_failure_status(self):
        with patch.object(WORKER, "main", return_value=17):
            self.assertEqual(WORKER.entrypoint(), 17)

    def test_local_auth_is_explicit_and_keeps_credentials_ephemeral_without_new_mounts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            workspace, home = root / "workspace", root / "dedicated-codex"
            workspace.mkdir()
            home.mkdir()
            (home / "config.toml").write_text('model="fixture"\n')
            args = (workspace, home, "sha256:" + "a" * 64, "reviewer", root / "private.cid", "b" * 32, "/docker")
            dedicated = WORKER.create_command(*args)
            local = WORKER.create_command(*args, external_auth=True)
            self.assertEqual(dedicated[:-1], local[:-1])
            self.assertNotIn("ephemeral", dedicated[-1])
            self.assertIn('cli_auth_credentials_store="ephemeral"', local[-1])
            self.assertIn(f"type=bind,src={workspace},dst={workspace},readonly", local)
            self.assertIn("no-new-privileges", local)
            for value in (None, "true", 1):
                with self.subTest(value=value), self.assertRaises(ValueError):
                    WORKER.create_command(*args, external_auth=value)

    def test_local_entrypoint_keeps_guardian_intent_without_claiming_dedicated_auth(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "workspaces").mkdir(mode=0o700)
            workspace, home, local_home, client = (root / name for name in ("workspaces/GH-1", "codex", ".codex", "auth-client"))
            for path in (workspace, home, local_home, client):
                path.mkdir(mode=0o700)
            binary = root / "local-cli"
            binary.write_text("fixture executable")
            binary.chmod(0o700)
            (home / "config.toml").write_text('model="fixture"\n')
            cidfile = root / "private.cid"
            owner, cid = "b" * 32, "c" * 64
            argv = ["worker", "--workspace", str(workspace), "--codex-home", str(home),
                    "--image", "sha256:" + "a" * 64, "--auth-source", "local_codex",
                    "--local-codex-binary", str(binary), "--local-codex-home", str(local_home),
                    "--auth-cwd", str(client)]

            def docker(command, **kwargs):
                if "context" in command:
                    return SimpleNamespace(stdout="unix:///private/fixture.sock\n")
                self.assertIn("create", command)
                self.assertIn('cli_auth_credentials_store="ephemeral"', command[-1])
                self.assertNotIn(str(local_home), " ".join(command))
                cidfile.write_text(cid)
                return SimpleNamespace(returncode=0, stdout=cid + "\n", stderr="")

            environment = {"SYMPHONY_CONTAINER_CIDFILE": str(cidfile), "SYMPHONY_CONTAINER_OWNER": owner,
                           "SYMPHONY_WORKER_ROLE": "builder", "DOCKER_HOST": "untrusted"}
            with patch.object(sys, "argv", argv), patch.dict(os.environ, environment, clear=True), \
                    patch.object(WORKER.Path, "home", return_value=root), \
                    patch.object(WORKER.shutil, "which", return_value="/docker"), \
                    patch.object(WORKER.subprocess, "run", side_effect=docker), \
                    patch.object(WORKER, "prepare_marker") as marker, patch.object(WORKER, "AuthLease") as lease, \
                    patch.object(WORKER, "LocalCodexAuth") as auth, patch.object(WORKER, "bridge", return_value=7) as proxy, \
                    patch.object(WORKER.os, "execve") as execute:
                self.assertEqual(WORKER.main(), 7)
                marker.assert_not_called()
                lease.assert_not_called()
                execute.assert_not_called()
                auth.assert_called_once_with(binary=str(binary), home=str(local_home), cwd=str(client))
                command, env, client_auth = proxy.call_args.args
                self.assertEqual(command, ["/docker", "--host", "unix:///private/fixture.sock", "start", "--attach", "--interactive", cid])
                self.assertNotIn("DOCKER_HOST", env)
                self.assertIs(client_auth, auth.return_value.__enter__.return_value)
                self.assertEqual(json.loads(Path(str(cidfile) + ".intent").read_text()),
                                 {"owner": owner, "docker_host": "unix:///private/fixture.sock"})
                self.assertFalse(Path(str(cidfile) + ".auth").exists())
                self.assertFalse((WORKER.stage_path(home, owner, "builder") / "auth.json").exists())

    def test_auth_client_never_uses_the_checkout_or_runtime_home_as_its_host_cwd(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "workspaces").mkdir(mode=0o700)
            workspace, home, local, client = (root / name for name in ("workspaces/GH-1", "codex", ".codex", "auth-client"))
            for path in (workspace, home, local, client):
                path.mkdir(mode=0o700)
            binary = root / "local-cli"
            binary.write_text("fixture executable")
            binary.chmod(0o700)
            with patch.object(WORKER.Path, "home", return_value=root):
                WORKER.validate_local_auth_paths(workspace, home, local, client, binary)
                for cwd in (workspace, home, local, root):
                    with self.subTest(cwd=cwd.name), self.assertRaises(WORKER.LocalCodexAuthError):
                        WORKER.validate_local_auth_paths(workspace, home, local, cwd, binary)
                (workspace / "inside").mkdir(mode=0o700)
                with self.assertRaises(WORKER.LocalCodexAuthError):
                    WORKER.validate_local_auth_paths(workspace, home, local, workspace / "inside", binary)

    def test_local_personal_home_accepts_standard_mode_without_relaxing_private_client(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "workspaces").mkdir(mode=0o700)
            workspace, runtime, home, client = (root / name for name in ("workspaces/GH-1", "codex", ".codex", "auth-client"))
            for path in (workspace, runtime, home, client):
                path.mkdir(mode=0o700)
            binary = root / "local-cli"
            binary.write_text("fixture executable")
            binary.chmod(0o700)
            args = (workspace, runtime, home, client, binary)
            with patch.object(WORKER.Path, "home", return_value=root):
                home.chmod(0o755)
                self.assertEqual(WORKER.validate_local_auth_paths(*args), str(binary))
                self.assertEqual(home.stat().st_mode & 0o777, 0o755)
                for mode in (0o775, 0o777):
                    home.chmod(mode)
                    with self.subTest(mode=mode), self.assertRaises(WORKER.LocalCodexAuthError):
                        WORKER.validate_local_auth_paths(*args)
                home.chmod(0o755)
                client.chmod(0o755)
                with self.assertRaises(WORKER.LocalCodexAuthError):
                    WORKER.validate_local_auth_paths(*args)

    def test_local_personal_auth_leaf_is_checked_by_metadata_without_reading_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "workspaces").mkdir(mode=0o700)
            workspace, runtime, home, client = (root / name for name in ("workspaces/GH-1", "codex", ".codex", "auth-client"))
            for path in (workspace, runtime, home, client):
                path.mkdir(mode=0o700)
            home.chmod(0o755)
            binary = root / "local-cli"
            binary.write_text("fixture executable")
            binary.chmod(0o700)
            credential = home / "auth.json"
            credential.write_text("FAKE AUTH MUST NOT BE READ")
            credential.chmod(0o600)
            args = (workspace, runtime, home, client, binary)
            with patch.object(WORKER.Path, "home", return_value=root), \
                    patch.object(WORKER.Path, "read_text", side_effect=AssertionError("Credential read")), \
                    patch.object(WORKER.Path, "read_bytes", side_effect=AssertionError("Credential read")):
                self.assertEqual(WORKER.validate_local_auth_paths(*args), str(binary))
                for mode in (0o640, 0o604):
                    credential.chmod(mode)
                    with self.subTest(mode=mode), self.assertRaises(WORKER.LocalCodexAuthError):
                        WORKER.validate_local_auth_paths(*args)
                credential.chmod(0o600)
                os.link(credential, root / "linked-auth")
                with self.assertRaises(WORKER.LocalCodexAuthError):
                    WORKER.validate_local_auth_paths(*args)
                credential.unlink()
                credential.symlink_to(root / "linked-auth")
                with self.assertRaises(WORKER.LocalCodexAuthError):
                    WORKER.validate_local_auth_paths(*args)

    def test_local_executable_rejects_worker_trees_unsafe_modes_and_foreign_owners(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            paths = {name: root / name for name in ("workspaces", "codex", ".codex", "auth-client", "source", "stage-state", "pr-work-state")}
            for path in paths.values():
                path.mkdir(mode=0o700)
            workspace = paths["workspaces"] / "GH-1"
            workspace.mkdir(mode=0o700)
            binary = root / "local-cli"
            binary.write_text("fixture executable")
            binary.chmod(0o700)
            args = (workspace, paths["codex"], paths[".codex"], paths["auth-client"])
            with patch.object(WORKER.Path, "home", return_value=root):
                link = root / "cli-link"
                link.symlink_to(binary)
                self.assertEqual(WORKER.validate_local_auth_paths(*args, link), str(binary))
                for tree in ("workspaces", "codex", "source", "stage-state", "pr-work-state", "auth-client"):
                    supplied = paths[tree] / "worker-cli"
                    supplied.write_text("worker controlled")
                    supplied.chmod(0o700)
                    with self.subTest(tree=tree), self.assertRaises(WORKER.LocalCodexAuthError):
                        WORKER.validate_local_auth_paths(*args, supplied, paths["source"])
                for mode in (0o770, 0o707, 0o777):
                    binary.chmod(mode)
                    with self.subTest(mode=mode), self.assertRaises(WORKER.LocalCodexAuthError):
                        WORKER.validate_local_auth_paths(*args, binary)
                binary.chmod(0o700)
                with patch.object(WORKER.os, "getuid", return_value=os.getuid() + 1), \
                        self.assertRaises(WORKER.LocalCodexAuthError):
                    WORKER.validate_local_auth_paths(*args, binary)

    def test_local_retained_stage_refuses_auth_files_and_dangling_links_before_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            workspace, home = root / "workspace", root / "codex"
            workspace.mkdir(mode=0o700)
            home.mkdir(mode=0o700)
            (home / "config.toml").write_text('model="fixture"\n')
            work_id, owner = "a" * 32, "b" * 32
            stage = WORKER.prepare_stage_home(workspace, home, owner, "builder", work_id)
            argv = ["worker", "--workspace", str(workspace), "--codex-home", str(home),
                    "--image", "sha256:" + "a" * 64, "--auth-source", "local_codex",
                    "--local-codex-binary", "/fixture/codex", "--local-codex-home", str(root / ".codex"),
                    "--auth-cwd", str(root / "auth-client")]
            environment = {"SYMPHONY_CONTAINER_CIDFILE": str(root / "private.cid"),
                           "SYMPHONY_CONTAINER_OWNER": owner, "SYMPHONY_WORKER_ROLE": "builder",
                           "SYMPHONY_PR_WORK_ID": work_id, "SYMPHONY_PR_WORK_RESUME": "true"}
            credential = stage / "auth.json"
            for symlink in (False, True):
                if symlink:
                    credential.symlink_to(root / "absent-auth")
                else:
                    credential.write_text("FAKE PRIVATE AUTH")
                with self.subTest(symlink=symlink), patch.object(sys, "argv", argv), \
                        patch.dict(os.environ, environment, clear=True), \
                        patch.object(WORKER.shutil, "which", return_value="/docker"), \
                        patch.object(WORKER.subprocess, "run") as docker, \
                        patch.object(WORKER, "LocalCodexAuth") as auth, \
                        patch.object(WORKER, "AuthLease") as lease, self.assertRaises(WORKER.LocalCodexAuthError):
                    WORKER.main()
                docker.assert_not_called()
                auth.assert_not_called()
                lease.assert_not_called()
                self.assertTrue(credential.is_symlink() or credential.exists())
                credential.unlink()

    def test_auth_source_and_local_arguments_cannot_be_implicitly_selected(self):
        arguments = ["worker", "--workspace", "/fixture/work", "--codex-home", "/fixture/codex",
                     "--image", "sha256:" + "a" * 64]
        for extra in (["--auth-source", "unknown"], ["--auth-source", "local_codex"],
                      ["--local-codex-home", "/private/local"], ["--auth-source-path", "/private/source"]):
            with self.subTest(extra=extra), patch.object(sys, "argv", arguments + extra), \
                    patch.object(WORKER.shutil, "which") as docker, patch.object(WORKER, "LocalCodexAuth") as auth, \
                    patch.object(WORKER.sys, "stderr"), self.assertRaises(SystemExit):
                WORKER.main()
            docker.assert_not_called()
            auth.assert_not_called()

    def test_canary_retains_recovery_markers_when_container_cleanup_is_unverified(self):
        spec = importlib.util.spec_from_file_location("probe_cancellation", ROOT / "tools/probe_cancellation.py")
        probe = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(probe)
        with tempfile.TemporaryDirectory() as parent:
            with self.assertRaisesRegex(RuntimeError, "retained recovery markers"):
                with probe.disposable_root(parent) as root:
                    (root / "workspace.lock.owner.cid.intent").write_text("recovery")
            self.assertTrue(root.exists())
            self.assertEqual((root / "workspace.lock.owner.cid.intent").read_text(), "recovery")
            with probe.disposable_root(parent) as clean:
                (clean / "finished").write_text("done")
            self.assertFalse(clean.exists())

    def test_fixed_canary_refuses_existing_state_and_links(self):
        spec = importlib.util.spec_from_file_location("probe_cancellation", ROOT / "tools/probe_cancellation.py")
        probe = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(probe)
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory).resolve()
            fixed = parent / "symphony-sandbox-canary"
            fixed.mkdir()
            original = fixed / "existing-evidence"
            original.write_text("preserve")
            with self.assertRaises(FileExistsError):
                with probe.disposable_root(parent, fixed=True):
                    self.fail("Existing fixture must not be reused")
            self.assertEqual(original.read_text(), "preserve")
            original.unlink()
            fixed.rmdir()
            target = parent / "outside"
            target.mkdir()
            fixed.symlink_to(target, target_is_directory=True)
            with self.assertRaises(FileExistsError):
                with probe.disposable_root(parent, fixed=True):
                    self.fail("Fixture symlinks must not be followed")
            self.assertTrue(target.is_dir())
            fixed.unlink()
            with probe.disposable_root(parent, fixed=True) as clean:
                self.assertEqual(clean, fixed)
            self.assertFalse(fixed.exists())

    def test_guardian_never_reaps_leader_before_group_signals(self):
        source = (ROOT / "elixir/lib/symphony_elixir/process_group.ex").read_text()
        guardian = textwrap.dedent(re.search(r'@guardian ~S"""\n(.*?)\n  """', source, re.S).group(1))
        # A natural child exit must remain waitable during both group signals.
        # Instrument only the real child handle; do not discover or signal PIDs.
        prelude = """import os,subprocess
original_killpg=os.killpg
original_popen=subprocess.Popen
owned=[]
def spawn(*args,**kwargs):
    process=original_popen(*args,**kwargs);owned.append(process);return process
def signal_unreaped(group,signum):
    assert group==owned[0].pid and owned[0].returncode is None, 'stale group signal'
    return original_killpg(group,signum)
subprocess.Popen=spawn
os.killpg=signal_unreaped
"""
        with tempfile.TemporaryDirectory() as directory:
            process = subprocess.Popen([sys.executable, "-I", "-u", "-c", prelude + guardian,
                                        str(Path(directory) / "lock"), "/bin/echo", "finished"],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                process.wait(timeout=5)
                self.assertEqual(process.returncode, 0, process.stderr.read().decode())
                self.assertEqual(process.stdout.read().strip(), b"finished")
            finally:
                process.stdin.close()
                process.stdout.close()
                process.stderr.close()

    def test_seccomp_candidate_preserves_pinned_moby_default_and_only_adds_bwrap_operations(self):
        policy_path = ROOT / "profiles/events-concierge/seccomp-codex.json"
        policy = json.loads(policy_path.read_text())
        added = policy["syscalls"][-16:]
        policy["syscalls"] = policy["syscalls"][:-16]
        baseline = json.dumps(policy, sort_keys=True, separators=(",", ":")).encode()
        # Canonical JSON digest of official moby/profiles at
        # 61eaf32614c7c71b60bd8927d3e6a4ffc8ff1f31/seccomp/default.json.
        self.assertEqual(hashlib.sha256(baseline).hexdigest(), "9da637d2ab0a204fcbd91bd88f1be9e004a3acab61c571a9f5b8870e588a17d2")
        self.assertEqual({name for item in added for name in item["names"]},
                         {"clone", "unshare", "mount", "pivot_root", "umount2"})
        self.assertTrue(all(item["action"] == "SCMP_ACT_ALLOW" for item in added))
        self.assertTrue(all(item["includes"] == {"arches": ["arm64", "amd64"]} for item in added))
        self.assertTrue(all("args" in item for item in added if item["names"] != ["pivot_root"]))
        self.assertEqual([item["args"][0]["value"] for item in added if item["names"] == ["clone"]],
                         [805437457, 1879179281, 939655185, 2013397009])
        # The upgraded helper adds only CLONE_NEWIPC; extra namespace bits
        # and clone argument masks would broaden this reviewed boundary.
        clones = [item for item in added if item["names"] == ["clone"]]
        self.assertTrue(all(item["args"] == [{"index": 0, "value": flags, "op": "SCMP_CMP_EQ"}]
                            for item, flags in zip(clones, (0x30020011, 0x70020011, 0x38020011, 0x78020011))))

    def test_mounts_are_scoped_and_review_source_is_readonly(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            workspace, home = root / "workspace", root / "dedicated-codex"
            workspace.mkdir()
            home.mkdir()
            (home / "config.toml").write_text('model="fixture"\n')
            for role in ("builder", "reviewer"):
                command = WORKER.create_command(workspace, home, "sha256:" + "a" * 64, role, root / "private.cid", "b" * 32, "/docker")
                mounts = [command[index + 1] for index, value in enumerate(command) if value == "--mount"]
                self.assertEqual(len(mounts), 3)
                self.assertIn(f"src={workspace},dst={workspace}", mounts[0])
                self.assertEqual(mounts[0].endswith(",readonly"), role == "reviewer")
                self.assertIn(f"src={root}/stage-state/", mounts[1])
                self.assertTrue(mounts[2].endswith("dst=/codex-home/config.toml,readonly"))
                self.assertNotIn(f"src={home},", " ".join(mounts))
                self.assertNotIn("--privileged", command)
                self.assertNotIn("--pid=host", command)
                self.assertIn("--read-only", command)
                self.assertIn("no-new-privileges", command)
                self.assertNotIn("docker.sock", " ".join(command))

    def test_retained_builder_home_survives_new_guardian_owner_and_reviewer_stays_fresh(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            workspace, home = root / "workspace", root / "home"
            workspace.mkdir()
            home.mkdir()
            (home / "config.toml").write_text('model="fixture"\n')
            work_id = "c" * 32
            stage = WORKER.prepare_stage_home(workspace, home, "a" * 32, "builder", work_id)
            (stage / "retained-session").write_text("native-history")
            again = WORKER.prepare_stage_home(workspace, home, "b" * 32, "builder", work_id, resume=True)
            self.assertEqual(stage, again)
            self.assertEqual((again / "retained-session").read_text(), "native-history")
            for owner in ("a" * 32, "b" * 32):
                command = WORKER.create_command(workspace, home, "sha256:" + "a" * 64, "builder",
                                                root / "unused.cid", owner, "/docker", work_id=work_id)
                self.assertIn(f"type=bind,src={stage},dst=/codex-home", command)
            fresh_a = WORKER.prepare_stage_home(workspace, home, "a" * 32, "reviewer")
            fresh_b = WORKER.prepare_stage_home(workspace, home, "b" * 32, "reviewer")
            self.assertNotEqual(fresh_a, fresh_b)
            self.assertNotEqual(fresh_a, stage)
            with self.assertRaises(FileExistsError):
                WORKER.prepare_stage_home(workspace, home, "d" * 32, "builder", work_id)
            self.assertEqual((stage / "retained-session").read_text(), "native-history")

    def test_authentication_is_writable_only_in_the_owned_stage_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            workspace, home = root / "workspace", root / "dedicated-codex"
            workspace.mkdir()
            home.mkdir(mode=0o700)
            (home / "config.toml").write_text('model="fixture"\n')
            (home / "auth.json").write_text("FAKE AUTH")
            (home / "auth.json").chmod(0o600)
            for role in ("builder", "reviewer"):
                command = WORKER.create_command(workspace, home, "sha256:" + "a" * 64, role,
                                                root / "unused.cid", "b" * 32, "/docker")
                mounts = [command[index + 1] for index, value in enumerate(command) if value == "--mount"]
                self.assertFalse(any("dst=/codex-home/auth.json" in mount for mount in mounts))
                self.assertIn("dst=/codex-home", mounts[1])
                self.assertFalse(mounts[1].endswith(",readonly"))
                self.assertFalse(any(f"src={home}," in mount for mount in mounts))

    def test_retained_state_rejects_missing_or_foreign_scope_and_unsafe_markers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            workspace, other, home = root / "workspace", root / "other", root / "home"
            for path in (workspace, other, home):
                path.mkdir()
            work_id = "c" * 32
            args = (workspace, home, "a" * 32, "builder", work_id)
            with self.assertRaises(FileNotFoundError):
                WORKER.prepare_stage_home(*args, resume=True)
            stage = WORKER.prepare_stage_home(*args)
            with self.assertRaisesRegex(ValueError, "does not match"):
                WORKER.prepare_stage_home(other, *args[1:], resume=True)
            marker = stage.parent / "scope.json"
            original = marker.read_text()
            marker.chmod(0o644)
            with self.assertRaisesRegex(ValueError, "marker is invalid"):
                WORKER.prepare_stage_home(*args, resume=True)
            marker.chmod(0o600)
            marker.unlink()
            target = root / "retained-original"
            target.write_text(original)
            marker.symlink_to(target)
            with self.assertRaisesRegex(ValueError, "marker is invalid"):
                WORKER.prepare_stage_home(*args, resume=True)
            self.assertEqual(target.read_text(), original)
            with self.assertRaises(ValueError):
                WORKER.prepare_stage_home(workspace, home, "a" * 32, "reviewer", work_id)
            with self.assertRaises(ValueError):
                WORKER.prepare_stage_home(workspace, home, "a" * 32, "builder", "../other")
            with self.assertRaises(ValueError):
                WORKER.prepare_stage_home(workspace, home, "a" * 32, "builder", resume=True)

    def test_retained_home_parent_symlink_is_never_followed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            workspace, home, target = root / "workspace", root / "home", root / "target"
            for path in (workspace, home, target):
                path.mkdir(mode=0o700)
            (root / "pr-work-state").symlink_to(target, target_is_directory=True)
            with self.assertRaises(ValueError):
                WORKER.prepare_stage_home(workspace, home, "a" * 32, "builder", "c" * 32)
            self.assertEqual(list(target.iterdir()), [])

    def test_mutable_images_and_workspace_control_files_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            workspace, home = root / "workspace", root / "home"
            workspace.mkdir()
            home.mkdir()
            with self.assertRaises(ValueError):
                WORKER.create_command(workspace, home, "symphony:latest", "builder", root / "a.cid", "b" * 32, "/docker")
            with self.assertRaises(ValueError):
                WORKER.create_command(workspace, home, "sha256:" + "a" * 64, "builder", workspace / "a.cid", "b" * 32, "/docker")
            with self.assertRaises(ValueError):
                WORKER.create_command(workspace, home, "sha256:" + "a" * 64, "builder", root / "a.cid", "not-an-owner", "/docker")

    def test_personal_codex_home_and_descendant_mounts_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            workspace = root / "workspace"
            workspace.mkdir(mode=0o700)
            personal = root / ".codex"
            personal.mkdir(mode=0o700)
            nested = personal / "nested-worker-home"
            nested.mkdir(mode=0o700)
            sibling = root / ".codex-runtime"
            sibling.mkdir(mode=0o700)
            for home in (personal, nested, sibling):
                (home / "config.toml").write_text('model="fixture"\n')
            with patch.object(WORKER.Path, "home", return_value=root):
                for home in (personal, nested):
                    with self.subTest(home=home.name), self.assertRaisesRegex(ValueError, "personal Codex home"):
                        WORKER.create_command(workspace, home, "sha256:" + "a" * 64, "builder",
                                              root / "unused.cid", "b" * 32, "/docker")
                self.assertIn("create", WORKER.create_command(workspace, sibling, "sha256:" + "a" * 64,
                                                               "builder", root / "unused.cid", "b" * 32, "/docker"))

    def test_apparmor_candidate_never_disables_outer_isolation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            workspace, home = root / "workspace", root / "home"
            workspace.mkdir()
            home.mkdir()
            (home / "config.toml").write_text('model="fixture"\n')
            args = (workspace, home, "sha256:" + "a" * 64, "reviewer", root / "a.cid", "b" * 32, "/docker")
            policy = ROOT / "profiles/events-concierge/seccomp-codex.json"
            for name, seccomp in (("unconfined", policy), ("docker-default", policy), ("symphony-codex", None)):
                with self.assertRaises(ValueError):
                    WORKER.create_command(*args, seccomp_policy=seccomp, apparmor_profile=name)
            command = WORKER.create_command(*args, seccomp_policy=policy, apparmor_profile="symphony-codex")
            self.assertIn("apparmor=symphony-codex", command)
            self.assertIn("seccomp=" + str(policy), command)
            self.assertIn("no-new-privileges", command)
            self.assertEqual(command[command.index("--cap-drop") + 1], "ALL")
            self.assertNotIn("--cap-add", command)
            self.assertIn("--read-only", command)
            self.assertIn(f"type=bind,src={workspace},dst={workspace},readonly", command)
            default = WORKER.create_command(*args)
            self.assertFalse(any(value.startswith("apparmor=") for value in default))

    def test_guardian_removes_only_owned_container_before_allowing_next_command(self):
        self._guardian_case(matching=True)

    def test_cleanup_identity_mismatch_retains_marker_and_blocks_workspace_reuse(self):
        self._guardian_case(matching=False)

    def test_daemon_failure_retains_recovery_marker(self):
        self._guardian_case(matching=True, failure="daemon")

    def test_failed_container_removal_retains_recovery_marker(self):
        self._guardian_case(matching=True, failure="remove")

    def test_unsettled_create_retains_intent_even_when_name_is_absent(self):
        self._guardian_case(matching=True, failure="create")

    def test_renamed_container_is_removed_by_recorded_id(self):
        self._guardian_case(matching=True, failure="renamed")

    def _guardian_case(self, matching, failure=None):
        source = (ROOT / "elixir/lib/symphony_elixir/process_group.ex").read_text()
        guardian = textwrap.dedent(re.search(r'@guardian ~S"""\n(.*?)\n  """', source, re.S).group(1))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            lock = root / "workspace.lock"
            state = root / "state.json"
            fake_docker = root / "docker"
            fake_docker.write_text(f"#!{sys.executable}\n" + textwrap.dedent("""
                import json,os,pathlib,sys
                path=pathlib.Path(os.environ['FAKE_DOCKER_STATE'])
                state=json.loads(path.read_text())
                assert sys.argv[1:3]==['--host','unix:///fixture.sock']
                if state.get('failure')=='daemon':
                    print('Cannot connect to Docker daemon',file=sys.stderr); sys.exit(1)
                if sys.argv[3]=='inspect':
                    if state.get('removed') or state.get('failure')=='create' or (state.get('failure')=='renamed' and sys.argv[-1].startswith('symphony-')):
                        print('Error: No such object: '+sys.argv[-1],file=sys.stderr); sys.exit(1)
                    print(state['owner']+' '+state['cid'])
                elif sys.argv[3]=='rm':
                    assert sys.argv[-1]==state['cid']
                    if state.get('failure')=='remove':
                        print('Docker refused removal',file=sys.stderr); sys.exit(1)
                    state['removed']=True; path.write_text(json.dumps(state)); print(state['cid'])
                else: raise RuntimeError('Unexpected Docker command')
            """))
            fake_docker.chmod(0o755)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ.get("PATH", ""), FAKE_DOCKER_STATE=str(state))
            child = """import json,os,pathlib,time
cid=pathlib.Path(os.environ['SYMPHONY_CONTAINER_CIDFILE'])
owner=os.environ['SYMPHONY_CONTAINER_OWNER']
failure=%r
if failure!='create': cid.write_text('a'*64)
pathlib.Path(str(cid)+'.intent').write_text(json.dumps({'owner':owner,'docker_host':'unix:///fixture.sock'}))
pathlib.Path(os.environ['FAKE_DOCKER_STATE']).write_text(json.dumps({'owner':owner if %r else 'wrong-owner','cid':'a'*64,'failure':failure}))
time.sleep(30)
""" % (failure, matching)
            process = subprocess.Popen([sys.executable, "-I", "-u", "-c", guardian, str(lock), sys.executable, "-I", "-c", child], cwd=root, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            try:
                import time
                deadline = time.monotonic() + 3
                while not state.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(state.exists())
                process.stdin.close()
                process.wait(timeout=5)
                observed = json.loads(state.read_text())
                cleaned = matching and failure in (None, "renamed")
                self.assertEqual(observed.get("removed", False), cleaned, process.stdout.read().decode())
                markers = list(root.glob("*.intent"))
                self.assertEqual(bool(markers), not cleaned)
                next_run = subprocess.run([sys.executable, "-I", "-u", "-c", guardian, str(lock), "/bin/echo", "next"], cwd=root, env=env, input=b"", capture_output=True, timeout=5)
                if cleaned:
                    self.assertNotIn(b"operator recovery", next_run.stdout + next_run.stderr)
                else:
                    self.assertIn(b"operator recovery", next_run.stderr)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
                process.stdout.close()


if __name__ == "__main__":
    unittest.main()
