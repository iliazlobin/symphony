import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("kubernetes_auth", Path(__file__).resolve().parents[1] / "kubernetes_auth.py")
AUTH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUTH)
CONFIG = b'cli_auth_credentials_store = "file"\nforced_login_method = "chatgpt"\n'
OWNER = "a" * 32
OTHER = "b" * 32
JOB = "11111111-1111-1111-1111-111111111111"
POD = "22222222-2222-2222-2222-222222222222"


def receipt(job_uid=JOB, pod_uid=POD):
    pod = {"apiVersion": "v1", "kind": "Pod",
           "metadata": {"uid": pod_uid, "namespace": "symphony-workers", "resourceVersion": "11",
                        "labels": {"batch.kubernetes.io/controller-uid": job_uid},
                        "ownerReferences": [{"uid": job_uid, "kind": "Job", "controller": True}]},
           "spec": {"containers": [{"name": "worker"}]},
           "status": {"phase": "Succeeded", "containerStatuses": [{"name": "worker", "state": {
               "terminated": {"exitCode": 0, "finishedAt": "2026-09-15T20:00:00Z"}}}]}}
    return {"selector": "batch.kubernetes.io/controller-uid=" + job_uid,
            "job": {"apiVersion": "batch/v1", "kind": "Job",
                    "metadata": {"uid": job_uid, "namespace": "symphony-workers", "resourceVersion": "10"},
                    "status": {"active": 0, "conditions": [{"type": "Complete", "status": "True"}]}},
            "pods": {"apiVersion": "v1", "kind": "PodList", "metadata": {"resourceVersion": "12"}, "items": [pod]}}


class KubernetesAuthTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve() / "slot-01"
        self.now = 1000
        self.slot = AUTH.AuthSlot(self.root, clock=lambda: self.now)
        self.slot.initialize()

    def claim(self, owner=OWNER, role="enrollment", **kwargs):
        return self.slot.claim(owner, role, JOB, POD, CONFIG, b"Reviewed rules.\n",
                               enrollment=role == "enrollment", **kwargs)

    def enrolled(self):
        claim = self.claim()
        auth = Path(claim["codex_home"]) / "auth.json"
        auth.write_text("FAKE SUBSCRIPTION TOKEN")
        auth.chmod(0o600)
        self.slot.verify_account(OWNER, claim["generation"], {
            "result": {"account": {"type": "chatgpt", "email": "private@example.test"},
                       "requiresOpenaiAuth": True}}, "chatgpt")
        return claim, auth

    def retire(self, claim):
        return self.slot.retire(claim["owner"], claim["generation"], receipt())

    def test_requires_independent_enrollment_and_never_resets_existing_slot(self):
        with self.assertRaisesRegex(AUTH.AuthSlotError, "enrollment"):
            self.claim(role="builder")
        with self.assertRaisesRegex(AUTH.AuthSlotError, "already exists"):
            self.slot.initialize()
        self.assertEqual(self.slot.status()["generation"], 0)

    def test_expired_claim_is_never_stolen_or_renewed(self):
        self.claim()
        self.now += 61
        self.assertTrue(self.slot.status()["expired"])
        with self.assertRaisesRegex(AUTH.AuthSlotError, "takeover"):
            self.claim(owner=OTHER)
        with self.assertRaisesRegex(AUTH.AuthSlotError, "expired"):
            self.slot.renew(OWNER, 1)
        self.assertEqual(self.slot.status()["claim"]["owner"], OWNER)

    def test_wrong_owner_or_generation_cannot_renew_or_retire(self):
        self.claim()
        for owner, generation in ((OTHER, 1), (OWNER, 2)):
            with self.assertRaisesRegex(AUTH.AuthSlotError, "Stale"):
                self.slot.renew(owner, generation)
            with self.assertRaisesRegex(AUTH.AuthSlotError, "Stale"):
                self.slot.retire(owner, generation, receipt())

    def test_renewal_preserves_rotated_auth_inode_without_reading_tokens(self):
        claim, auth = self.enrolled()
        replacement = auth.parent / "replacement"
        replacement.write_text("FAKE NEW REFRESH TOKEN")
        replacement.chmod(0o600)
        os.replace(replacement, auth)
        inode = auth.stat().st_ino
        self.now += 20
        with patch.object(Path, "read_bytes", side_effect=AssertionError("Do not read tokens")):
            result = self.slot.renew(OWNER, 1)
        self.assertEqual(result["deadline"], 1080)
        self.assertEqual(auth.stat().st_ino, inode)
        self.assertNotIn("TOKEN", json.dumps(self.slot.status()))

    def test_new_stage_moves_only_auth_to_fresh_home(self):
        first, auth = self.enrolled()
        inode = auth.stat().st_ino
        (auth.parent / "session.json").write_text("prior context")
        self.retire(first)
        second = self.claim(owner=OTHER, role="reviewer")
        new_home = Path(second["codex_home"])
        self.assertEqual(second["generation"], 2)
        self.assertEqual((new_home / "auth.json").stat().st_ino, inode)
        self.assertFalse(auth.exists())
        self.assertFalse((new_home / "session.json").exists())
        self.assertTrue((auth.parent / "session.json").exists())
        self.assertEqual({p.name for p in new_home.iterdir()}, {"auth.json", "config.toml", "AGENTS.md"})

    def test_crash_before_auth_move_recovers_without_releasing_claim(self):
        first, auth = self.enrolled()
        self.retire(first)
        original = os.replace

        def fail_auth(source, destination):
            if Path(source).name == "auth.json":
                raise OSError("injected failure before atomic move")
            return original(source, destination)

        with patch.object(AUTH.os, "replace", side_effect=fail_auth):
            with self.assertRaises(OSError):
                self.claim(owner=OTHER, role="builder")
        self.assertTrue(auth.exists())
        recovered = AUTH.AuthSlot(self.root, clock=lambda: self.now).status()
        self.assertEqual(recovered["claim"]["owner"], OTHER)
        self.assertEqual(recovered["generation"], 2)
        self.assertFalse(auth.exists())

    def test_crash_after_auth_move_uses_new_file_without_snapshot_restore(self):
        first, auth = self.enrolled()
        self.retire(first)
        original = self.slot._save

        def fail_commit(state):
            if state["generation"] == 2 and state["transition"] is None:
                raise OSError("injected failure after atomic move")
            return original(state)

        with patch.object(self.slot, "_save", side_effect=fail_commit):
            with self.assertRaises(OSError):
                self.claim(owner=OTHER, role="builder")
        self.assertFalse(auth.exists())
        new_auth = self.root / "homes" / f"2-{OTHER}" / "auth.json"
        self.assertTrue(new_auth.exists())
        recovered = AUTH.AuthSlot(self.root, clock=lambda: self.now).status()
        self.assertEqual(recovered["claim"]["owner"], OTHER)
        self.assertTrue(new_auth.exists())

    def test_auth_loss_blocks_worker_and_retains_ownership(self):
        first, auth = self.enrolled()
        self.retire(first)
        current = self.claim(owner=OTHER, role="builder")
        (Path(current["codex_home"]) / "auth.json").unlink()
        with self.assertRaisesRegex(AUTH.AuthSlotError, "missing"):
            self.slot.renew(OTHER, 2)
        self.assertEqual(self.slot.status()["blocked"], "auth_lost")
        self.assertIsNotNone(self.slot.status()["claim"])

    def test_api_key_external_tokens_and_revocation_fail_closed_without_pii(self):
        self.enrolled()
        cases = [(None, None), ({"type": "apiKey"}, "apikey"),
                 ({"type": "chatgpt"}, "chatgptAuthTokens"),
                 ({"type": "amazonBedrock"}, "bedrockApiKey")]
        for account, mode in cases:
            with self.assertRaises(AUTH.AuthSlotError) as caught:
                self.slot.verify_account(OWNER, 1, {"result": {"account": account,
                    "requiresOpenaiAuth": True}, "untrusted": "PRIVATE SECRET"}, mode)
            self.assertNotIn("PRIVATE", str(caught.exception))
            self.assertEqual(self.slot.status()["blocked"], "auth_unavailable")

    def test_corrupt_auth_refresh_error_does_not_restore_or_echo_tokens(self):
        first, auth = self.enrolled()
        self.retire(first)
        current = self.claim(owner=OTHER, role="builder")
        auth = Path(current["codex_home"]) / "auth.json"
        auth.write_text('{"tokens":')  # Crash during Codex's truncate/write.
        with self.assertRaises(AUTH.AuthSlotError) as caught:
            self.slot.verify_account(OTHER, 2, {"error": {"message": "PRIVATE TOKEN FRAGMENT"}}, "chatgpt")
        self.assertNotIn("PRIVATE", str(caught.exception))
        self.assertEqual(auth.read_text(), '{"tokens":')
        self.assertEqual(self.slot.status()["blocked"], "auth_unavailable")
        # A later cached response cannot turn a revoked/lost worker into an
        # enrollment session. It first needs terminal reconciliation.
        with self.assertRaisesRegex(AUTH.AuthSlotError, "retire worker"):
            self.slot.verify_account(OTHER, 2, {"account": {"type": "chatgpt"},
                                               "requiresOpenaiAuth": True}, "chatgpt")

    def test_terminal_job_and_all_pods_required_for_retirement(self):
        self.claim()
        mutations = [
            lambda r: r["job"]["status"].update(active=1),
            lambda r: r["job"]["status"].update(conditions=[]),
            lambda r: r["job"]["metadata"].update(uid="wrong-uid"),
            lambda r: r["pods"].update(items=[]),
            lambda r: r["pods"]["metadata"].update({"continue": "another-page"}),
            lambda r: r["pods"]["items"][0]["status"].update(phase="Running"),
            lambda r: r["pods"]["items"][0]["spec"].update(initContainers=[{"name": "still-running"}]),
            lambda r: r["pods"]["items"][0]["status"]["containerStatuses"][0].update(state={"running": {}}),
            lambda r: r["pods"]["items"][0]["metadata"].update(uid="wrong-uid"),
            lambda r: r["pods"]["items"][0]["metadata"].update(namespace="other-namespace"),
        ]
        for mutate in mutations:
            evidence = receipt()
            mutate(evidence)
            with self.assertRaises(AUTH.AuthSlotError):
                self.slot.retire(OWNER, 1, evidence)
            self.assertIsNotNone(self.slot.status()["claim"])
        self.assertTrue(self.slot.retire(OWNER, 1, receipt())["retired"])

    def test_duplicate_job_pod_must_also_be_terminal(self):
        self.claim()
        evidence = receipt()
        duplicate = copy.deepcopy(evidence["pods"]["items"][0])
        duplicate["metadata"]["uid"] = "duplicate-pod"
        duplicate["status"]["phase"] = "Running"
        evidence["pods"]["items"].append(duplicate)
        with self.assertRaises(AUTH.AuthSlotError):
            self.slot.retire(OWNER, 1, evidence)
        duplicate["status"]["phase"] = "Succeeded"
        self.assertTrue(self.slot.retire(OWNER, 1, evidence)["retired"])

    def test_file_alias_or_permissive_auth_is_never_admitted(self):
        claim, auth = self.enrolled()
        auth.chmod(0o644)
        with self.assertRaises(AUTH.AuthSlotError):
            self.slot.verify_account(OWNER, 1, {"account": {"type": "chatgpt"}, "requiresOpenaiAuth": True}, "chatgpt")
        auth.chmod(0o600)
        alias = auth.parent / "alias"
        os.link(auth, alias)
        with self.assertRaises(AUTH.AuthSlotError):
            self.slot.verify_account(OWNER, 1, {"account": {"type": "chatgpt"}, "requiresOpenaiAuth": True}, "chatgpt")

    def test_symlink_slot_and_tampered_journal_fail_closed(self):
        alias = self.root.parent / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(AUTH.AuthSlotError, "symlinks"):
            AUTH.AuthSlot(alias)
        journal = self.root / "slot.json"
        journal.write_text('{"version":2}')
        with self.assertRaisesRegex(AUTH.AuthSlotError, "schema"):
            self.slot.status()
        self.assertEqual(journal.read_text(), '{"version":2}')

    def test_symlink_homes_cannot_write_outside_slot(self):
        homes = self.root / "homes"
        homes.rmdir()
        outside = self.root.parent / "outside"
        outside.mkdir(mode=0o700)
        homes.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(AUTH.AuthSlotError):
            self.claim()
        self.assertEqual(list(outside.iterdir()), [])

    def test_config_cannot_fall_back_to_api_key_or_alternate_provider(self):
        for config in (b'cli_auth_credentials_store="auto"\nforced_login_method="chatgpt"',
                       CONFIG + b'model_provider="other"',
                       CONFIG + b'[model_providers.other]\nbase_url="https://example.test"',
                       CONFIG + b'[mcp_servers.any]\ncommand="anything"'):
            with self.assertRaises(AUTH.AuthSlotError):
                self.slot.claim(OWNER, "enrollment", JOB, POD, config, b"rules", enrollment=True)

    def test_retention_limit_preserves_state_instead_of_deleting_evidence(self):
        first, auth = self.enrolled()
        self.retire(first)
        with patch.object(AUTH, "MAX_HOMES", 1):
            with self.assertRaisesRegex(AUTH.AuthSlotError, "retention"):
                self.claim(owner=OTHER, role="builder")
        self.assertTrue(auth.exists())

    def test_concurrent_metadata_writer_cannot_take_lock(self):
        with self.slot._lock():
            with self.assertRaisesRegex(AUTH.AuthSlotError, "Another trusted process"):
                AUTH.AuthSlot(self.root).status()


if __name__ == "__main__":
    unittest.main()
