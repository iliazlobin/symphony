import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("worker_policy", ROOT / "tools/worker_policy.py")
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)


class WorkerPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.parent = Path(self.temporary.name).resolve()
        self.root = self.parent / "Application Support" / "Symphony" / "workspaces"
        self.root.mkdir(parents=True, mode=0o700)

    def test_rejects_policy_injection_and_noncanonical_or_broad_roots(self):
        for value in ("/", "/workspaces", "/tmp/workspaces", "workspaces",
                      str(self.root) + "/", str(self.root) + "/../workspaces",
                      str(self.root).replace("Symphony/", "Symphony//")):
            with self.subTest(value=value), self.assertRaises((OSError, ValueError)):
                POLICY.render_policy(value)
        for character in ('*', '?', '[', ']', '{', '}', '@', '$', '"', "'", '\\', '\n', '\r', '\t', '#', ',', '\0'):
            value = str(self.root.parent / ("injected" + character) / "workspaces")
            with self.subTest(character=repr(character)), self.assertRaises(ValueError):
                POLICY.render_policy(value)

    def test_requires_owned_private_directory_and_rejects_ancestor_symlinks(self):
        self.root.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "private directory"):
            POLICY.render_policy(self.root)
        self.root.chmod(0o700)
        link = self.parent / "linked"
        link.symlink_to(self.root.parent, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlinks"):
            POLICY.render_policy(link / "workspaces")
        with patch.object(POLICY.os, "getuid", return_value=os.getuid() + 1):
            with self.assertRaisesRegex(ValueError, "private directory"):
                POLICY.render_policy(self.root)

    def test_task_bind_sources_are_scoped_and_never_recursive(self):
        rendered = POLICY.render_policy(self.root)
        sources = re.findall(r'mount options=\(rw,rbind\) "(/oldroot[^"\n]+)" ->', rendered)
        expected = {
            "/oldroot" + str(self.root) + "/" + workspace + suffix
            for workspace in ("GH-[0-9]*", "symphony-sandbox-canary/pipe",
                              "symphony-sandbox-canary/pty", "symphony-sandbox-canary/detached_child")
            for suffix in ("/", "/.git/", "/.codex/", "/.agents/")
        }
        self.assertEqual(set(sources), expected)
        self.assertTrue(all("**" not in source for source in sources))
        # Linux test fixtures can live below /tmp. Reject binding that whole
        # directory, while allowing the exact private task root checked above.
        self.assertNotRegex(rendered, r'/oldroot/tmp/"? ->')
        self.assertNotIn("/oldroot/**", rendered)
        self.assertNotIn("/newroot/**", rendered)
        self.assertNotIn("/oldroot" + str(self.root) + '/"', rendered)
        self.assertNotIn("  mount,", rendered)
        self.assertNotIn("  remount,", rendered)
        self.assertNotIn("  pivot_root,", rendered)

    def test_metadata_write_exceptions_and_masks_remain_narrow(self):
        rendered = POLICY.render_policy(self.root)
        writable = [line for line in rendered.splitlines()
                    if "rw,nosuid,nodev,remount,bind" in line]
        self.assertEqual(len(writable), 8)
        self.assertTrue(all(str(self.root) in line for line in writable))
        self.assertFalse(any(".codex" in line or ".agents" in line or ".env" in line for line in writable))
        masks = [line for line in rendered.splitlines() if "/bindfile" in line]
        self.assertEqual(len(masks), 8)
        self.assertTrue(all('/bindfile' + '[A-Za-z0-9]' * 6 + ' -> "' in line for line in masks))
        self.assertTrue(all('/newroot' + str(self.root) + '/' in line and line.endswith('.env",') for line in masks))

    def test_retains_default_denials_and_finite_runtime_mounts(self):
        rendered = POLICY.render_policy(self.root)
        for denial in ("deny network alg,", "deny @{PROC}/* w,", "deny @{PROC}/sysrq-trigger rwklx,",
                       "deny @{PROC}/kcore rwklx,", "deny /sys/firmware/** rwklx,",
                       "deny /sys/devices/virtual/powercap/** rwklx,", "deny /sys/kernel/security/** rwklx,"):
            self.assertIn(denial, rendered)
        self.assertIn('profile "symphony-codex" flags=(attach_disconnected,mediate_deleted)', rendered)
        self.assertNotIn("flags=(complain", rendered)
        self.assertNotIn("flags=(unconfined", rendered)
        self.assertIn("pivot_root oldroot=/tmp/oldroot/ /tmp/,", rendered)
        self.assertIn("pivot_root oldroot=/newroot/ /newroot/,", rendered)
        # Outside the configured task root, every bind source/destination is
        # literal and finite. Namespace setup does not expose another host tree.
        fixed = [line for line in rendered.splitlines()
                 if line.strip().startswith("mount ") and str(self.root) not in line
                 and "/codex-home/tmp/arg0/codex-arg0" not in line]
        self.assertTrue(all(not re.search(r"[?*\[\]{}]", line) for line in fixed))

    def test_helper_alias_directory_does_not_admit_codex_home_or_other_runtime_state(self):
        rendered = POLICY.render_policy(self.root)
        helper = "/codex-home/tmp/arg0/codex-arg0" + "[A-Za-z0-9]" * 6 + "/"
        home_mounts = [line.strip() for line in rendered.splitlines()
                       if line.strip().startswith("mount ") and "/codex-home" in line]
        self.assertEqual(home_mounts, [
            f"mount options=(rw,rbind) /oldroot{helper} -> /newroot{helper},",
            f"mount options=(ro,nosuid,nodev,remount,bind,silent,relatime) -> /newroot{helper},",
        ])
        self.assertTrue(all("*" not in line and "?" not in line for line in home_mounts))
        self.assertNotIn("/codex-home/auth.json", rendered)
        self.assertNotIn("/codex-home/config.toml", rendered)
        self.assertNotIn("/codex-home/AGENTS.md", rendered)
        self.assertNotIn("/codex-home/stage-state", rendered)

    def test_render_is_deterministic_and_cli_has_no_write_or_install_action(self):
        before = sorted(str(path) for path in self.parent.rglob("*"))
        expected = POLICY.render_policy(self.root)
        result = subprocess.run([sys.executable, str(ROOT / "tools/worker_policy.py"),
                                 "--workspace-root", str(self.root)], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, expected)
        self.assertEqual(before, sorted(str(path) for path in self.parent.rglob("*")))
        self.assertNotIn("@@WORKSPACE_RULES@@", expected)
        result = subprocess.run([sys.executable, str(ROOT / "tools/worker_policy.py"), "--install"],
                                capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
