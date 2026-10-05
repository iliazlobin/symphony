import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("container_auth", ROOT / "tools/container_auth.py")
AUTH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUTH)
OWNER, OTHER = "a" * 32, "b" * 32


class ContainerAuthTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / "dedicated-codex"
        self.home.mkdir(mode=0o700)
        self.auth = self.home / "auth.json"
        self.auth.write_text("FAKE INITIAL TOKEN")
        self.auth.chmod(0o600)
        self.stage = self.root / "stage-state" / OWNER / "builder"
        self.stage.mkdir(mode=0o700, parents=True)
        self.cid = self.root / ("lock." + OWNER + ".cid")
        self.lease = AUTH.AuthLease(self.home)

    def claim(self):
        self.lease.claim(OWNER, self.stage, self.cid, "builder")

    def test_claim_moves_sole_credential_without_reading_it(self):
        inode = self.auth.stat().st_ino
        with patch.object(Path, "read_bytes", side_effect=AssertionError("No token reads")):
            self.claim()
        self.assertFalse(self.auth.exists())
        self.assertEqual((self.stage / "auth.json").stat().st_ino, inode)
        self.assertEqual(self.lease.status(), {"state": "active", "credential_present": True,
                                             "sign_in_required": False, "provider_verified": False})
        self.assertNotIn("TOKEN", (self.home / ".symphony-auth/owner.json").read_text())

    def test_retirement_returns_rotated_file_and_preserves_sessions(self):
        self.claim()
        replacement = self.stage / "replacement"
        replacement.write_text("FAKE ROTATED TOKEN")
        replacement.chmod(0o600)
        os.replace(replacement, self.stage / "auth.json")
        inode = (self.stage / "auth.json").stat().st_ino
        (self.stage / "session").write_text("preserved thread")
        self.lease.retire(OWNER, self.stage, self.cid)
        self.assertEqual(self.auth.stat().st_ino, inode)
        self.assertEqual(self.auth.read_text(), "FAKE ROTATED TOKEN")
        self.assertFalse((self.stage / "auth.json").exists())
        self.assertTrue((self.stage / "session").exists())
        reviewer = self.root / "stage-state" / OTHER / "reviewer"
        reviewer.mkdir(mode=0o700, parents=True)
        self.lease.claim(OTHER, reviewer, self.root / "second.cid", "reviewer")
        self.assertEqual((reviewer / "auth.json").stat().st_ino, inode)

    def test_crash_before_move_retains_claim_and_guardian_recovers_it(self):
        original = AUTH.os.replace

        def fail_auth(source, target):
            if Path(source).name == "auth.json":
                raise OSError("Injected interruption")
            return original(source, target)

        with patch.object(AUTH.os, "replace", side_effect=fail_auth), self.assertRaises(OSError):
            self.claim()
        self.assertEqual(self.lease.status()["state"], "recovery")
        self.assertTrue(self.auth.exists())
        self.lease.retire(OWNER, self.stage, self.cid)
        self.assertTrue(self.auth.exists())
        self.assertEqual(self.lease.status()["state"], "idle")

    def test_crash_after_move_never_restores_prior_seed(self):
        original = AUTH.os.replace

        def fail_after_move(source, target):
            original(source, target)
            if Path(source).name == "auth.json":
                raise OSError("Injected interruption after move")

        with patch.object(AUTH.os, "replace", side_effect=fail_after_move), self.assertRaises(OSError):
            self.claim()
        self.assertFalse(self.auth.exists())
        self.assertTrue((self.stage / "auth.json").exists())
        self.lease.retire(OWNER, self.stage, self.cid)
        self.assertTrue(self.auth.exists())
        self.assertFalse((self.stage / "auth.json").exists())

    def test_uncertain_return_keeps_ownership_until_same_current_file_returns(self):
        self.claim()
        original = AUTH.os.replace

        def fail_return(source, target):
            if Path(source).name == "auth.json":
                raise OSError("Interrupted return")
            return original(source, target)

        with patch.object(AUTH.os, "replace", side_effect=fail_return), self.assertRaises(OSError):
            self.lease.retire(OWNER, self.stage, self.cid)
        self.assertEqual(self.lease.status()["state"], "recovery")
        self.lease.retire(OWNER, self.stage, self.cid)
        self.assertEqual(self.lease.status()["state"], "idle")

    def test_cancelled_waiter_cannot_release_active_owner_or_take_over_on_timeout(self):
        self.claim()
        other = self.root / "stage-state" / OTHER / "reviewer"
        other.mkdir(mode=0o700, parents=True)
        self.lease.retire(OTHER, other, self.root / "waiter.cid")
        with self.assertRaises(AUTH.AuthLeaseBusy):
            self.lease.wait_claim(OTHER, other, self.root / "waiter.cid", "reviewer", timeout=0)
        self.assertEqual(self.lease.status()["state"], "active")
        with self.assertRaisesRegex(AUTH.AuthLeaseError, "Stale"):
            self.lease.retire(OWNER, other, self.cid)
        self.assertFalse(self.auth.exists())

    def test_waiter_uses_latest_credential_after_actual_retirement(self):
        self.claim()
        other = self.root / "stage-state" / OTHER / "reviewer"
        other.mkdir(mode=0o700, parents=True)
        calls = []

        def retire(_seconds):
            calls.append(True)
            self.lease.retire(OWNER, self.stage, self.cid)

        self.lease.wait_claim(OTHER, other, self.root / "second.cid", "reviewer", sleep=retire)
        self.assertEqual(calls, [True])
        self.assertTrue((other / "auth.json").exists())
        self.assertFalse((self.stage / "auth.json").exists())

    def test_ambiguous_missing_linked_or_truncated_credentials_fail_closed(self):
        for failure in ("duplicate", "missing", "linked", "empty"):
            with self.subTest(failure=failure):
                self.claim()
                current = self.stage / "auth.json"
                if failure == "duplicate":
                    self.auth.write_text("DO NOT RESTORE")
                    self.auth.chmod(0o600)
                elif failure == "missing":
                    current.unlink()
                elif failure == "linked":
                    current.unlink()
                    current.symlink_to(self.root / "missing")
                else:
                    current.write_text("")
                with self.assertRaises((AUTH.AuthLeaseError, OSError)):
                    self.lease.retire(OWNER, self.stage, self.cid)
                # Reset only synthetic fixture ownership for the next case.
                for path in (self.auth, current):
                    if path.exists() or path.is_symlink():
                        path.unlink()
                (self.home / ".symphony-auth/owner.json").unlink()
                self.auth.write_text("FAKE INITIAL TOKEN")
                self.auth.chmod(0o600)

    def test_enrollment_blocks_worker_and_retains_claim_after_interruption(self):
        with self.lease.enrollment() as home:
            self.assertEqual(home, self.home)
            state = json.loads((self.home / ".symphony-auth/owner.json").read_text())
            self.assertEqual(state["claim"]["role"], "enrollment")
        self.assertEqual(self.lease.status()["state"], "idle")
        with self.assertRaises(RuntimeError):
            with self.lease.enrollment():
                raise RuntimeError("Interrupted host enrollment")
        with self.assertRaises(AUTH.AuthLeaseBusy):
            self.claim()
        self.assertEqual(self.lease.status()["state"], "active")

    def test_marker_cleanup_identity_and_cli_are_token_free(self):
        marker = AUTH.prepare_marker(self.cid, OWNER, self.home, self.stage)
        self.claim()
        with self.assertRaises(AUTH.AuthLeaseError):
            AUTH.retire_marker(marker, OTHER, self.cid)
        result = subprocess.run([sys.executable, "-I", str(ROOT / "tools/container_auth.py"), "retire",
                                 "--marker", str(marker), "--owner", OWNER, "--cidfile", str(self.cid)],
                                env={}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertTrue(self.auth.exists())
        marker.chmod(0o644)
        with self.assertRaises(AUTH.AuthLeaseError):
            AUTH.retire_marker(marker, OWNER, self.cid)

    def test_refuses_personal_home_and_outside_stage(self):
        with self.assertRaises(AUTH.AuthLeaseError):
            AUTH.AuthLease((Path.home() / ".codex").resolve())
        outside = self.root / "other"
        outside.mkdir(mode=0o700)
        with self.assertRaises(AUTH.AuthLeaseError):
            self.lease.claim(OWNER, outside, self.cid, "builder")
        self.auth.chmod(0o644)
        with self.assertRaises(AUTH.AuthLeaseError):
            self.claim()

    def test_dangling_journal_links_cannot_be_treated_as_empty_ownership(self):
        self.lease.root.mkdir(mode=0o700)
        (self.lease.root / "owner.json").symlink_to(self.root / "missing-journal")
        with self.assertRaises(AUTH.AuthLeaseError):
            self.claim()
        with self.assertRaises(AUTH.AuthLeaseError):
            self.lease.status()
        self.assertTrue(self.auth.exists())

    def test_auth_files_are_never_read_by_the_lease(self):
        original = Path.read_text

        def read(path, *args, **kwargs):
            if path.name == "auth.json":
                raise AssertionError("Credential content must remain opaque")
            return original(path, *args, **kwargs)

        with patch.object(Path, "read_text", read):
            self.claim()
            self.lease.status()
            self.lease.retire(OWNER, self.stage, self.cid)
            self.lease.status()

    def test_real_guardian_and_wrapper_return_latest_auth_only_after_container_removal(self):
        source = (ROOT / "elixir/lib/symphony_elixir/process_group.ex").read_text()
        guardian = textwrap.dedent(re.search(r'@guardian ~S"""\n(.*?)\n  """', source, re.S).group(1))
        docker = self.root / "docker"
        state = self.root / "docker-state.json"
        state.write_text("{}")
        docker.write_text(f"#!{sys.executable}\n" + textwrap.dedent("""
            import json,os,pathlib,sys
            args=sys.argv[1:]
            path=pathlib.Path(os.environ['FAKE_DOCKER_STATE'])
            state=json.loads(path.read_text())
            if args[:2]==['context','inspect']:
                print('unix:///fixture.sock');sys.exit(0)
            assert args[:2]==['--host','unix:///fixture.sock']
            command=args[2]
            if command=='create':
                owner=os.environ['SYMPHONY_CONTAINER_OWNER']
                mounts=[args[i+1] for i,value in enumerate(args) if value=='--mount']
                stage=pathlib.Path(next(value.split('src=')[1].split(',dst=')[0]
                                        for value in mounts if value.endswith('dst=/codex-home')))
                home=pathlib.Path(os.environ['FAKE_DEDICATED_HOME'])
                assert (stage/'auth.json').is_file() and not (home/'auth.json').exists()
                state.update(owner=owner,cid='a'*64,stage=str(stage));path.write_text(json.dumps(state))
                pathlib.Path(args[args.index('--cidfile')+1]).write_text(state['cid'])
                print(state['cid'])
            elif command=='start':
                stage=pathlib.Path(state['stage'])
                current=stage/'auth.json'
                replacement=stage/'fresh-auth'
                replacement.write_text('FAKE REFRESHED AUTH');replacement.chmod(0o600)
                os.replace(replacement,current)
                state['refreshed_inode']=current.stat().st_ino;path.write_text(json.dumps(state))
            elif command=='inspect':
                if state.get('removed'):
                    print('Error: No such object: '+args[-1],file=sys.stderr);sys.exit(1)
                print(state['owner']+' '+state['cid'])
            elif command=='rm':
                assert args[-1]==state['cid']
                state['removed']=True;path.write_text(json.dumps(state))
            else: raise RuntimeError('Unexpected Docker command')
        """))
        docker.chmod(0o700)
        workspace = self.root / "checkout"
        workspace.mkdir(mode=0o700)
        (self.home / "config.toml").write_text('model="fixture"\n')
        env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ.get("PATH", ""),
                   FAKE_DOCKER_STATE=str(state), FAKE_DEDICATED_HOME=str(self.home))
        process = subprocess.Popen([sys.executable, "-I", "-u", "-c", guardian, str(self.root / "run.lock"),
                                    sys.executable, "-I", str(ROOT / "tools/container_worker.py"),
                                    "--workspace", str(workspace), "--codex-home", str(self.home),
                                    "--image", "sha256:" + "a" * 64], env=env, cwd=workspace,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            process.wait(timeout=8)
            self.assertEqual(process.returncode, 0, process.stderr.read().decode())
            observed = json.loads(state.read_text())
            self.assertTrue(observed['removed'])
            self.assertEqual(self.auth.stat().st_ino, observed['refreshed_inode'])
            self.assertEqual(self.auth.read_text(), 'FAKE REFRESHED AUTH')
            self.assertEqual(self.lease.status()['state'], 'idle')
            self.assertEqual(list(self.root.glob('*.auth')), [])
            self.assertEqual(list(self.root.glob('*.intent')), [])
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()


if __name__ == "__main__":
    unittest.main()
