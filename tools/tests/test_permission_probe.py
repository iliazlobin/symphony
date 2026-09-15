"""Reject canary results that do not establish the intended permission boundary."""
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("probe_container_permissions", TOOLS / "probe_container_permissions.py")
probe = importlib.util.module_from_spec(spec)
with patch.object(sys, "path", [str(TOOLS), *sys.path]):
    spec.loader.exec_module(probe)


class PermissionProbeTests(unittest.TestCase):
    def test_profile_metadata_must_confirm_selected_role(self):
        for role in ("builder", "reviewer"):
            response = {"thread": {"id": "canary"}, "activePermissionProfile": {"id": "symphony-" + role, "extends": ":workspace"}}
            probe.verify_profile(response, role)
            for active in (None, {}, "invalid", {"id": ":workspace"}, {"id": "symphony-" + ("reviewer" if role == "builder" else "builder"), "extends": ":workspace"}):
                with self.assertRaises(RuntimeError):
                    probe.verify_profile({**response, "activePermissionProfile": active}, role)
            with self.assertRaises(RuntimeError):
                probe.verify_profile({**response, "thread": {}}, role)

    def test_unreachable_controls_cannot_establish_secret_or_network_denial(self):
        controls = {"auth_read": True, "env_read": True, "host_input_read": True,
                    "runtime_read": True, "network": True, "workspace_write": True, "ambient_environment": True}
        probe.verify_outer(controls, "builder")
        for key in controls:
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                probe.verify_outer({**controls, key: False}, "builder")
        probe.verify_outer({**controls, "workspace_write": False}, "reviewer")

    def test_reviewer_denial_cannot_be_masked_by_readonly_outer_mount(self):
        controls = {"auth_read": True, "env_read": True, "host_input_read": True,
                    "runtime_read": True, "network": True, "workspace_write": False, "ambient_environment": True}
        with self.assertRaises(RuntimeError):
            probe.verify_outer(controls, "builder")
        with self.assertRaises(RuntimeError):
            probe.verify_inner(self.valid("builder"), "reviewer")

    def test_role_canaries_require_tools_and_reject_secret_or_network_access(self):
        for role in ("builder", "reviewer"):
            valid = self.valid(role)
            probe.verify_inner(valid, role)
            for key in valid:
                with self.subTest(role=role, key=key), self.assertRaises(RuntimeError):
                    probe.verify_inner({**valid, key: not valid[key]}, role)
            with self.assertRaises(RuntimeError):
                probe.verify_inner({key: value for key, value in valid.items() if key != "auth_read"}, role)

    @staticmethod
    def valid(role):
        return {"workspace_read": True, "workspace_write": role == "builder",
                "env_read": False, "auth_read": False, "host_input_read": False,
                "runtime_read": False, "tmp_write": False, "network": False,
                "python": True, "node": True, "uv": True, "git_diff": True, "cat": True,
                "command_path": True, "ambient_environment": False,
                "handoff_write": role == "builder", "git_commit": role == "builder"}
