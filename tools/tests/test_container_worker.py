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

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("container_worker", ROOT / "tools/container_worker.py")
WORKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WORKER)


class ContainerWorkerTests(unittest.TestCase):
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
        added = policy["syscalls"][-14:]
        policy["syscalls"] = policy["syscalls"][:-14]
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
                         [805437457, 1879179281])

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
