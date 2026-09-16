import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from collections import deque
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location("cloud_subscription_pilot", Path(__file__).parents[1] / "cloud_subscription_pilot.py")
PILOT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PILOT)
JOB = "11111111-1111-1111-1111-111111111111"
POD = "22222222-2222-2222-2222-222222222222"
PREVIOUS_JOB = "33333333-3333-3333-3333-333333333333"
PREVIOUS_POD = "44444444-4444-4444-4444-444444444444"
OWNER = "a" * 32


def boot(stage="task", generation=2):
    return {"owner": OWNER, "stage": stage, "generation": generation,
            "created_at": 1000, "expires_at": 1500, "codex_version": "0.153.4",
            "job_uid": JOB, "pod_uid": POD}


def receipt():
    pod = {"metadata": {"uid": PREVIOUS_POD, "namespace": "symphony-workers",
                        "labels": {"batch.kubernetes.io/controller-uid": PREVIOUS_JOB},
                        "ownerReferences": [{"uid": PREVIOUS_JOB, "kind": "Job", "controller": True}]},
           "spec": {"containers": [{"name": "worker"}]},
           "status": {"phase": "Succeeded", "containerStatuses": [{"name": "worker", "state": {
               "terminated": {"exitCode": 0, "finishedAt": "2026-09-16T00:00:00Z"}}}]}}
    return {"selector": "batch.kubernetes.io/controller-uid=" + PREVIOUS_JOB,
            "job": {"apiVersion": "batch/v1", "kind": "Job", "metadata": {
                "uid": PREVIOUS_JOB, "namespace": "symphony-workers", "resourceVersion": "1"},
                "status": {"active": 0, "conditions": [{"type": "Complete", "status": "True"}]}},
            "pods": {"apiVersion": "v1", "kind": "PodList", "metadata": {"resourceVersion": "2"}, "items": [pod]}}


class CloudSubscriptionPilotTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {"SYMPHONY_JOB_UID": JOB, "SYMPHONY_POD_UID": POD}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_identity_and_absolute_deadline_fail_closed(self):
        self.assertEqual(PILOT.validate_boot(boot(), now=1100), boot())
        changes = [{"pod_uid": PREVIOUS_POD}, {"job_uid": PREVIOUS_JOB}, {"owner": "../bad"},
                   {"generation": True}, {"expires_at": 2000}, {"expires_at": 1100},
                   {"created_at": 1200}, {"stage": "live-dispatch"}, {"codex_version": "latest"}]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(PILOT.PilotError):
                PILOT.validate_boot({**boot(), **change}, now=1100)
        with patch.dict(os.environ, {"SYMPHONY_JOB_UID": "missing"}), self.assertRaises(PILOT.PilotError):
            PILOT.identity()

    def test_receipt_input_is_bounded_object_json(self):
        self.assertEqual(PILOT.read_receipt(io.BytesIO(b"{}")), {})
        for value in (b"", b"null", b"[]", b"secret", b"{" + b"x" * PILOT.MAX_JSON):
            with self.assertRaises(PILOT.PilotError) as caught:
                PILOT.read_receipt(io.BytesIO(value))
            self.assertNotIn("secret", str(caught.exception))

    def test_reviewed_config_keeps_auth_and_command_boundaries(self):
        config = PILOT.configuration()
        PILOT.AUTH._reviewed_config(config)
        parsed = PILOT.AUTH.tomllib.loads(config.decode())
        self.assertEqual(parsed["forced_login_method"], "chatgpt")
        self.assertEqual(parsed["cli_auth_credentials_store"], "file")
        self.assertFalse(parsed["features"]["apps"])
        self.assertFalse(parsed["permissions"]["symphony-builder"]["network"]["enabled"])
        self.assertEqual(parsed["permissions"]["symphony-builder"]["filesystem"][":root"], "deny")

    def test_retirement_uses_exact_terminal_evidence_before_next_claim(self):
        with tempfile.TemporaryDirectory() as directory:
            slot = PILOT.AUTH.AuthSlot(Path(directory).resolve() / "slot", clock=lambda: 1000)
            slot.initialize()
            slot.claim(OWNER, "enrollment", PREVIOUS_JOB, PREVIOUS_POD,
                       PILOT.configuration(), b"Reviewed pilot rules", enrollment=True)
            invalid = receipt()
            invalid["pods"]["items"][0]["status"]["phase"] = "Running"
            with self.assertRaises(PILOT.AUTH.AuthSlotError):
                PILOT.retire_previous(slot, invalid, boot())
            self.assertIsNotNone(slot.status()["claim"])
            PILOT.retire_previous(slot, receipt(), boot())
            self.assertIsNone(slot.status()["claim"])

    def test_missing_stale_and_self_retirement_are_rejected(self):
        slot = Mock()
        claim = {"owner": OWNER, "generation": 1, "job_uid": PREVIOUS_JOB, "pod_uid": PREVIOUS_POD}
        slot.status.return_value = {"generation": 1, "claim": claim}
        for evidence, state in (({}, boot()), (receipt(), boot(generation=3)),
                                (receipt(), {**boot(), "job_uid": PREVIOUS_JOB})):
            with self.assertRaises(PILOT.PilotError):
                PILOT.retire_previous(slot, evidence, state)
        slot.retire.assert_not_called()
        slot.status.return_value = {"generation": 1, "claim": None}
        with self.assertRaises(PILOT.PilotError):
            PILOT.retire_previous(slot, {}, boot(stage="retire", generation=1))

    def test_heartbeat_failure_or_deadline_stops_protocol(self):
        now, slot, pulse = [1000], Mock(), Mock()
        heartbeat = PILOT.Heartbeat(slot, {"owner": OWNER, "generation": 2}, 1020,
                                     clock=lambda: now[0], beat=pulse)
        heartbeat.tick()
        pulse.assert_called_once()
        now[0] = 1010
        heartbeat.tick()
        slot.renew.assert_called_once_with(OWNER, 2, ttl=60)
        now[0] = 1020
        with self.assertRaises(PILOT.PilotError):
            heartbeat.tick()
        slot.renew.side_effect = PILOT.AUTH.AuthSlotError("renewal lost")
        heartbeat.expires_at = 1040
        with self.assertRaises(PILOT.AUTH.AuthSlotError):
            heartbeat.tick()

    def test_pid1_watchdog_rejects_stale_or_replaced_exec_heartbeat(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run.lock"
            self.assertTrue(PILOT.healthy_watchdog(path, 1000))
            self.assertFalse(PILOT.healthy_watchdog(path, 1000, started=True))
            path.touch(mode=0o600)
            os.utime(path, (1000, 1000))
            self.assertTrue(PILOT.healthy_watchdog(path, 1020))
            self.assertFalse(PILOT.healthy_watchdog(path, 1031))
            self.assertFalse(PILOT.healthy_watchdog(path, 999))
            path.chmod(0o644)
            self.assertFalse(PILOT.healthy_watchdog(path, 1020))
            alias = path.with_name("alias")
            alias.symlink_to(path)
            self.assertFalse(PILOT.healthy_watchdog(alias, 1020))

    def test_protocol_timeout_and_server_requests_do_not_gain_approval(self):
        client = PILOT.AppServer.__new__(PILOT.AppServer)
        client.heartbeat = Mock()
        client.pending = b'{"id":99,"method":"item/commandExecution/requestApproval","params":{"secret":"PRIVATE"}}\n'
        with self.assertRaisesRegex(PILOT.PilotError, "Unexpected server request") as caught:
            client.message(PILOT.time.monotonic() + 5)
        self.assertNotIn("PRIVATE", str(caught.exception))
        client.pending = b""
        with self.assertRaisesRegex(PILOT.PilotError, "timed out"):
            client.message(PILOT.time.monotonic() - 1)

    def test_notification_auth_mode_is_saved_without_exposing_account(self):
        client = PILOT.AppServer.__new__(PILOT.AppServer)
        client.heartbeat = Mock()
        client.auth_mode = None
        client.pending = b'{"method":"account/updated","params":{"authMode":"chatgpt","planType":"private"}}\n'
        client.message(PILOT.time.monotonic() + 5)
        self.assertEqual(client.auth_mode, "chatgpt")

    def test_replacement_admission_does_not_require_unsolicited_account_update(self):
        update = {"method": "account/updated", "params": {"authMode": "chatgpt"}}
        response = {"id": 1, "result": {"account": {"type": "chatgpt"}, "requiresOpenaiAuth": True}}
        status = {"id": 2, "result": {"authMethod": "chatgpt", "authToken": None, "requiresOpenaiAuth": True}}
        limits = {"id": 3, "result": {"rateLimits": {"limitId": "codex"}}}
        for messages in ((update, response, status, limits), (response, update, status, limits), (response, status, limits)):
            client = PILOT.AppServer.__new__(PILOT.AppServer)
            client.heartbeat, client.send, client.next_id = Mock(), Mock(), 0
            client.auth_mode, client.notifications = None, deque(maxlen=64)
            client.pending = b"".join(json.dumps(value).encode() + b"\n" for value in messages)
            slot = Mock()
            PILOT.verify_subscription(client, slot, {"owner": OWNER, "generation": 2})
            slot.verify_account.assert_called_once_with(OWNER, 2, response["result"], "chatgpt")

    def test_exec_failure_marks_pid1_completion_without_raw_error(self):
        with tempfile.TemporaryDirectory() as directory:
            private = Path(directory).resolve()
            PILOT.private_write(private / "boot.json", boot())
            stdin = Mock(buffer=io.BytesIO(b"{}"))
            with patch.object(PILOT, "PRIVATE", private), patch.object(PILOT, "validate_boot", side_effect=lambda value: value), \
                    patch.object(PILOT.sys, "stdin", stdin), \
                    patch.object(PILOT, "run_stage", side_effect=PILOT.PilotError("Safe failure")):
                with self.assertRaisesRegex(PILOT.PilotError, "Safe failure"):
                    PILOT.run()
            self.assertEqual(PILOT.private_read(private / "complete.json"), {"success": False})

    def test_enrollment_only_exposes_device_fields_to_operator(self):
        client, emit = Mock(), Mock()
        client.rpc.return_value = {"type": "chatgptDeviceCode", "loginId": "private-login",
                                   "verificationUrl": "https://auth.openai.com/codex/device",
                                   "userCode": "ABCD-EFGH", "untrusted": "SECRET"}
        client.wait.return_value = {"success": True}
        PILOT.enroll(client, emit)
        emit.assert_called_once_with({"verification_url": "https://auth.openai.com/codex/device", "user_code": "ABCD-EFGH"})
        for url in ("https://attacker.test/", "https://auth.openai.com:444/codex/device",
                    "https://auth.openai.com/codex/device?token=private", "https://auth.openai.com/codex/device#secret",
                    "https://auth.openai.com/unexpected", "https://user@auth.openai.com/codex/device"):
            client.rpc.return_value["verificationUrl"] = url
            with self.assertRaises(PILOT.PilotError):
                PILOT.enroll(client, emit)
        self.assertEqual(emit.call_count, 1)

    def test_subscription_refresh_has_no_cached_or_api_key_fallback(self):
        client, slot = Mock(), Mock()
        account = {"account": {"type": "chatgpt"}, "requiresOpenaiAuth": True}
        client.rpc.side_effect = [account,
            {"authMethod": "chatgpt", "authToken": None, "requiresOpenaiAuth": True},
            {"rateLimits": {"limitId": "codex"}}]
        PILOT.verify_subscription(client, slot, {"owner": OWNER, "generation": 2})
        self.assertEqual(client.rpc.call_args_list[0].args, ("account/read", {"refreshToken": True}))
        self.assertEqual(client.rpc.call_args_list[1].args, ("getAuthStatus", {"includeToken": False, "refreshToken": False}))
        self.assertEqual(client.rpc.call_args_list[2].args, ("account/rateLimits/read", None))
        slot.verify_account.assert_called_once_with(OWNER, 2, account, "chatgpt")
        client.wait.assert_not_called()

    def test_cached_account_cannot_pass_without_provider_acceptance(self):
        client, slot = Mock(), Mock()
        client.rpc.side_effect = [
            {"account": {"type": "chatgpt"}, "requiresOpenaiAuth": True},
            {"authMethod": "chatgpt", "authToken": None, "requiresOpenaiAuth": True},
            PILOT.PilotError("Provider unavailable")]
        with self.assertRaisesRegex(PILOT.PilotError, "Provider unavailable"):
            PILOT.verify_subscription(client, slot, {"owner": OWNER, "generation": 2})
        slot.verify_account.assert_not_called()

    def test_auth_status_rejects_external_mode_tokens_or_billing_fallback(self):
        for status in ({"authMethod": "chatgptAuthTokens", "authToken": None, "requiresOpenaiAuth": True},
                       {"authMethod": "apikey", "authToken": None, "requiresOpenaiAuth": True},
                       {"authMethod": "chatgpt", "authToken": "PRIVATE TOKEN", "requiresOpenaiAuth": True},
                       {"authMethod": "chatgpt", "authToken": None, "requiresOpenaiAuth": False}):
            client, slot = Mock(), Mock()
            client.rpc.side_effect = [{"account": {"type": "chatgpt"}, "requiresOpenaiAuth": True}, status]
            with self.assertRaises(PILOT.PilotError) as caught:
                PILOT.verify_subscription(client, slot, {"owner": OWNER, "generation": 2})
            self.assertNotIn("PRIVATE", str(caught.exception))
            slot.verify_account.assert_not_called()
            self.assertEqual(client.rpc.call_count, 2)

    def test_rpc_diagnostics_are_allowlisted_without_raw_message_or_data(self):
        cases = [("failed to request device code: DNS lookup failed SECRET", "dns_failure"),
                 ("failed to request device code: certificate SECRET", "tls_failure"),
                 ("ChatGPT login is disabled. SECRET", "login_policy_denied"),
                 ("External auth is active. SECRET", "external_auth_forbidden"),
                 ("device code login is not enabled SECRET", "device_login_unavailable"),
                 ("failed to request device code: error sending request https://private", "transport_failure"),
                 ("device code request failed with status 403 Forbidden SECRET", "device_auth_http_error"),
                 ("PRIVATE UNKNOWN MESSAGE", "provider_error")]
        for message, category in cases:
            value = PILOT.rpc_error_summary({"code": -32603, "message": message, "data": "SECRET"})
            self.assertEqual(value["category"], category)
            self.assertNotIn("SECRET", json.dumps(value))
            self.assertNotIn("private", json.dumps(value))
            self.assertEqual(value["rpc_code"], -32603)
            if category == "device_auth_http_error":
                self.assertEqual(value["http_status"], 403)
        self.assertEqual(PILOT.rpc_error_summary({"code": "secret", "message": None}), {"category": "provider_error"})

    def client(self):
        client = Mock()
        client.rpc.side_effect = [
            {"thread": {"id": "thread-1"}, "activePermissionProfile": {"id": "symphony-builder", "extends": ":workspace"}},
            {"turn": {"id": "turn-1"}},
            {"exitCode": 0, "stdout": json.dumps({"passed": 3, "artifact_sha256": "a" * 64})}]
        client.wait.return_value = {"threadId": "thread-1", "turn": {"id": "turn-1", "status": "completed"}}
        return client

    def test_generated_source_is_only_verified_inside_named_command_sandbox(self):
        client = self.client()
        with patch.object(PILOT.subprocess, "run", side_effect=AssertionError("No outer code execution")):
            result = PILOT.task(client)
        self.assertTrue(result["model_turn_completed"])
        call = client.rpc.call_args_list[-1]
        self.assertEqual(call.args[0], "command/exec")
        self.assertEqual(call.args[1]["command"], ["/usr/local/bin/python3", "-I", "-c", PILOT.VERIFY])
        self.assertEqual(call.args[1]["timeoutMs"], 10000)
        self.assertEqual(client.rpc.call_args_list[1].args[1]["model"], "gpt-6-astra")
        self.assertLessEqual(client.wait.call_args.args[2], 180)

    def test_wrong_profile_failed_turn_and_bad_verifier_evidence_block_success(self):
        client = self.client()
        client.rpc.side_effect = [{"thread": {"id": "t"}, "activePermissionProfile": {"id": ":workspace"}}]
        with self.assertRaises(PILOT.PilotError):
            PILOT.task(client)
        client = self.client()
        client.wait.return_value = {"turn": {"status": "failed"}}
        with self.assertRaises(PILOT.PilotError):
            PILOT.task(client)
        self.assertEqual(client.rpc.call_count, 2)
        client = self.client()
        client.rpc.side_effect = [
            {"thread": {"id": "t"}, "activePermissionProfile": {"id": "symphony-builder", "extends": ":workspace"}},
            {"turn": {"id": "v"}}, {"exitCode": 1, "stdout": "PRIVATE SECRET"}]
        with self.assertRaises(PILOT.PilotError) as caught:
            PILOT.task(client)
        self.assertNotIn("SECRET", str(caught.exception))

    def test_private_state_rejects_symlink_and_permissive_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state"
            PILOT.private_write(path, {"safe": True})
            self.assertEqual(PILOT.private_read(path), {"safe": True})
            alias = path.with_name("alias")
            alias.symlink_to(path)
            with self.assertRaises(OSError):
                PILOT.private_read(alias)
            path.chmod(0o644)
            with self.assertRaises(PILOT.PilotError):
                PILOT.private_read(path)


if __name__ == "__main__":
    unittest.main()
