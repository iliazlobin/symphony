"""Operational canaries must select the service boundary without host secrets."""
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("probe_runtime", ROOT / "tools/probe_runtime.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
IMAGE = "sha256:" + "a" * 64


class OperationalProbeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.workspaces = self.root / "workspaces"
        self.workspaces.mkdir()
        self.seccomp = self.root / "seccomp.json"
        self.seccomp.write_text('{"defaultAction":"SCMP_ACT_ERRNO","syscalls":[]}')
        self.config = {"worker_image_id": IMAGE, "workspace_root": str(self.workspaces),
                       "_token": "never-forward-this", "codex_home": "/private/real-auth"}
        self.options = ["--seccomp-policy", str(self.seccomp), "--apparmor-profile", "symphony-codex"]
        self.profile = SimpleNamespace(load_config=Mock(return_value=self.config),
                                       container_launch_options=Mock(return_value=self.options))

    def operational(self, **kwargs):
        return probe.resolve_runtime(self.profile, ROOT, operator_config="/private/operator.json", **kwargs)

    def test_uses_service_selector_and_pinned_image_without_forwarding_config(self):
        runtime = self.operational()
        self.profile.load_config.assert_called_once_with("/private/operator.json")
        self.profile.container_launch_options.assert_called_once_with(self.config)
        self.assertEqual(runtime["options"], self.options)
        self.assertEqual(runtime["image"], IMAGE)
        self.assertEqual(runtime["parent"], self.workspaces)
        self.assertTrue(runtime["operational"])
        self.assertNotIn("never-forward-this", repr(runtime))
        self.assertNotIn("/private/real-auth", repr(runtime))

    def test_manual_overrides_cannot_bypass_operational_selection(self):
        for name, value in (("image", IMAGE), ("seccomp_policy", str(self.seccomp)),
                            ("apparmor_profile", "unconfined")):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "cannot override"):
                self.operational(**{name: value})
        self.profile.container_launch_options.assert_not_called()

    def test_operational_fixtures_reject_escape_and_symlink_paths(self):
        child = self.workspaces / "probe-parent"
        child.mkdir()
        self.assertEqual(self.operational(fixture_parent=str(child))["parent"], child)
        with self.assertRaisesRegex(ValueError, "inside the configured"):
            self.operational(fixture_parent=str(self.root))
        link = self.workspaces / "outside-link"
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "canonical"):
            self.operational(fixture_parent=str(link))
        self.assertFalse((child / "symphony-sandbox-canary").exists())

    def test_missing_or_different_policy_selection_fails_closed(self):
        for options in (None, [], ["--apparmor-profile", "symphony-codex"],
                        ["--seccomp-policy", str(self.seccomp), "--apparmor-profile", "unconfined"]):
            self.profile.container_launch_options.return_value = options
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.operational()
        self.profile.container_launch_options.side_effect = ValueError("changed policy hash")
        with self.assertRaisesRegex(ValueError, "changed policy hash"):
            self.operational()
        self.profile.container_launch_options = None
        with self.assertRaisesRegex(ValueError, "selector is unavailable"):
            self.operational()

    def test_native_and_diagnostic_modes_remain_separate(self):
        native = probe.resolve_runtime(self.profile, ROOT)
        self.assertIsNone(native["parent"])
        self.assertIsNone(native["image"])
        diagnostic = probe.resolve_runtime(self.profile, ROOT, image=IMAGE,
                                           seccomp_policy=str(self.seccomp), apparmor_profile="symphony-codex",
                                           fixture_parent=str(self.workspaces))
        self.assertEqual(diagnostic["options"], self.options)
        self.profile.load_config.assert_not_called()
        self.profile.container_launch_options.assert_not_called()
        with self.assertRaisesRegex(ValueError, "immutable"):
            probe.resolve_runtime(self.profile, ROOT, image="worker:latest")
        with self.assertRaisesRegex(ValueError, "require"):
            probe.resolve_runtime(self.profile, ROOT, fixture_parent=str(self.workspaces))

    def test_docker_inspection_must_match_actual_selected_image_and_policies(self):
        runtime = self.operational()
        info = {"Image": IMAGE, "AppArmorProfile": "symphony-codex", "HostConfig": {
            "SecurityOpt": ["no-new-privileges", "apparmor=symphony-codex", "seccomp=" + self.seccomp.read_text()]}}
        probe.verify_container_policy(info, runtime)
        for changed in ({**info, "Image": "sha256:" + "b" * 64},
                        {**info, "AppArmorProfile": "docker-default"},
                        {**info, "HostConfig": {"SecurityOpt": ["apparmor=symphony-codex", "seccomp=unconfined"]}},
                        {**info, "HostConfig": {"SecurityOpt": ["apparmor=symphony-codex"]}},
                        {**info, "HostConfig": {"SecurityOpt": ["apparmor=symphony-codex", 'seccomp={"defaultAction":"SCMP_ACT_ALLOW"}']}}):
            with self.subTest(info=changed), self.assertRaises(RuntimeError):
                probe.verify_container_policy(changed, runtime)


if __name__ == "__main__":
    unittest.main()
