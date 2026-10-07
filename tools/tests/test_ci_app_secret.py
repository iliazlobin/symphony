"""Exercise initial credential refusal, target checks and redaction without real credentials."""
import base64
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch


CI = Path(__file__).resolve().parents[2] / "deploy/ci"
spec = importlib.util.spec_from_file_location("symphony_app_secret", CI / "app_secret.py")
secret = importlib.util.module_from_spec(spec)
import sys
sys.path.insert(0, str(CI))
spec.loader.exec_module(secret)
sys.path.pop(0)

DATA = {"github_app_id": "123", "github_app_installation_id": "456",
        "github_app_private_key": "-----BEGIN RSA PRIVATE KEY-----\nSYNTHETIC-TEST-ONLY\n"}


class AppSecretTests(unittest.TestCase):
    def app_responses(self):
        return [{"id": 123, "slug": secret.APP_SLUG, "owner": {"login": "iliazlobin"},
                 "permissions": secret.PERMISSIONS, "events": []},
                {"id": 456, "app_id": 123, "account": {"login": "iliazlobin"},
                 "target_type": "User", "repository_selection": "selected", "suspended_at": None,
                 "permissions": secret.PERMISSIONS}, {"id": 456, "app_id": 123}]

    def test_bad_fields_bounds_and_duplicate_keys_stop_before_crypto(self):
        cases = [json.dumps({**DATA, "extra": "forbidden"}).encode(), b"x" * 65537,
                 b'{"github_app_id":"123","github_app_id":"999"}',
                 json.dumps({**DATA, "github_app_id": "0"}).encode(),
                 json.dumps({**DATA, "github_app_id": "\u0661\u0662\u0663"}).encode(),
                 json.dumps({**DATA, "github_app_installation_id": 456}).encode(),
                 json.dumps({**DATA, "github_app_private_key": "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\n"}).encode(),
                 json.dumps({**DATA, "github_app_private_key": "not a key"}).encode()]
        for raw in cases:
            with self.subTest(raw_size=len(raw)), patch.object(secret, "command") as command:
                with self.assertRaises(ValueError):
                    secret.credentials(raw)
                command.assert_not_called()

    @unittest.skipUnless(shutil.which("openssl"), "OpenSSL required for disposable native crypto")
    def test_disposable_rsa_signature_and_ec_refusal_without_private_key_files(self):
        generated = subprocess.run(["openssl", "genrsa", "2048"], capture_output=True, check=True).stdout
        data = {**DATA, "github_app_private_key": generated.decode()}
        with patch.object(secret, "command", wraps=secret.command) as command:
            self.assertEqual(secret.credentials(json.dumps(data).encode()), data)
            token = secret.app_jwt(data)
        for call in command.call_args_list:
            self.assertNotIn(generated.decode(), repr(call.args[0]))
            self.assertNotIn("env", call.kwargs)
        header, claims, signature = token.split(".")
        self.assertEqual(json.loads(base64.urlsafe_b64decode(header + "=="))["alg"], "RS256")
        body = json.loads(base64.urlsafe_b64decode(claims + "=="))
        self.assertEqual(body["iss"], "123")
        self.assertLessEqual(body["exp"] - body["iat"], 600)
        public = subprocess.run(["openssl", "pkey", "-pubout"], input=generated,
                                capture_output=True, check=True).stdout
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            (root / "public.pem").write_bytes(public)
            (root / "signature").write_bytes(base64.urlsafe_b64decode(signature + "=="))
            subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(root / "public.pem"),
                            "-signature", str(root / "signature")], input=(header + "." + claims).encode(),
                           capture_output=True, check=True)
            self.assertEqual({p.name for p in root.iterdir()}, {"public.pem", "signature"})
        ec = subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt",
                             "ec_paramgen_curve:P-256"], capture_output=True, check=True).stdout
        with self.assertRaises(ValueError):
            secret.credentials(json.dumps({**DATA, "github_app_private_key": ec.decode()}).encode())

    def test_app_identity_permissions_scope_and_coverage_are_refused(self):
        cases = [(0, "id", 999), (0, "slug", "foundation-app"),
                 (0, "permissions", {**secret.PERMISSIONS, "contents": "read"}),
                 (0, "events", ["push"]), (1, "repository_selection", "all"),
                 (1, "suspended_at", "2026-01-01"), (1, "app_id", 999),
                 (1, "target_type", "Organization"), (2, "id", 999)]
        for index, field, value in cases:
            responses = copy.deepcopy(self.app_responses())
            responses[index][field] = value
            with self.subTest(field=field), patch.object(secret, "app_jwt", return_value="synthetic-jwt"), \
                    patch.object(secret, "github", side_effect=responses), self.assertRaises(ValueError):
                secret.verify_app(DATA)
        with patch.object(secret, "app_jwt", return_value="synthetic-jwt"), \
                patch.object(secret, "github", side_effect=self.app_responses()) as github:
            secret.verify_app(DATA)
        self.assertEqual([call.args[0] for call in github.call_args_list],
                         ["/app", "/app/installations/456", "/repos/iliazlobin/symphony/installation"])
        with self.assertRaises(ValueError):
            secret.NoRedirect().redirect_request(None, None, None, None, None, None)

    def test_missing_ui_scope_and_invalid_version_stop_before_operator_or_payload(self):
        for args in (["store"], ["deliver", "--app-scope-confirmed"],
                     ["deliver", "--version", "0", "--app-scope-confirmed"],
                     ["store", "--version", "1", "--app-scope-confirmed"]):
            with self.subTest(args=args), patch.object(secret, "verify_operator") as operator:
                with self.assertRaises(ValueError):
                    secret.main(args)
                operator.assert_not_called()

    def test_wrong_fork_policy_or_private_target_prevents_helper_commands(self):
        with patch.object(secret.preflight, "command", return_value="first_time_contributors"), \
                patch.object(secret.preflight, "main") as preflight, patch.object(secret, "command") as command:
            with self.assertRaises(ValueError):
                secret.verify_operator()
            preflight.assert_not_called()
            command.assert_not_called()
        with patch.object(secret.preflight, "command", return_value="all_external_contributors"), \
                patch.object(secret.preflight, "main", side_effect=ValueError("wrong private target")), \
                patch.object(secret, "command") as command:
            with self.assertRaises(ValueError):
                secret.verify_operator()
            command.assert_not_called()

    def test_existing_version_and_secret_refuse_before_reading_credentials(self):
        with patch.object(secret, "verify_operator"), patch.object(secret, "command", return_value=b"exists"), \
                patch.object(secret, "credentials") as credentials, patch.object(secret, "read_version") as read:
            for args in (["store", "--app-scope-confirmed"],
                         ["deliver", "--version", "1", "--app-scope-confirmed"]):
                with self.assertRaises(ValueError):
                    secret.main(args)
            credentials.assert_not_called()
            read.assert_not_called()

    def test_disabled_or_wrong_version_prevents_payload_access(self):
        for name, state in ((secret.version_name(2), "ENABLED"), (secret.version_name(1), "DISABLED")):
            with patch.object(secret, "command", return_value=json.dumps({"name": name, "state": state}).encode()) as command:
                with self.assertRaises(ValueError):
                    secret.read_version(1)
                self.assertEqual(command.call_count, 1)
                self.assertIn("describe", command.call_args.args[0])

    def test_store_readback_and_stdin_only_write(self):
        stdin = Mock(buffer=io.BytesIO(json.dumps(DATA).encode()))
        with patch.object(secret, "verify_operator"), patch.object(secret, "credentials", return_value=DATA), \
                patch.object(secret, "verify_app"), patch.object(secret, "read_version", return_value=DATA), \
                patch.object(secret.sys, "stdin", stdin), \
                patch.object(secret, "command", side_effect=[b"", secret.version_name(1).encode()]) as command:
            result = secret.main(["store", "--app-scope-confirmed"])
        self.assertEqual(result, {"stored_version": secret.version_name(1), "verified": True})
        args, payload = command.call_args.args
        self.assertIn("--data-file=-", args)
        self.assertNotIn(DATA["github_app_private_key"], repr(args))
        self.assertEqual(json.loads(payload), DATA)

    def delivered(self, field_change=None):
        calls = []
        created = {}
        def command(args, payload=None):
            calls.append((args, payload))
            if "create" in args:
                created.update(json.loads(payload))
                return b"created"
            if "--ignore-not-found" in args:
                return b""
            value = copy.deepcopy(created)
            value["metadata"]["uid"] = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            if field_change:
                field_change(value)
            return json.dumps(value).encode()
        with patch.object(secret, "verify_operator"), patch.object(secret, "read_version", return_value=DATA), \
                patch.object(secret, "verify_app"), patch.object(secret, "command", side_effect=command):
            result = secret.main(["deliver", "--version", "1", "--app-scope-confirmed"])
        return result, calls

    def test_delivery_private_equality_and_metadata_output(self):
        result, calls = self.delivered()
        self.assertEqual(result["source_version"], secret.version_name(1))
        self.assertNotIn(DATA["github_app_private_key"], json.dumps(result))
        create = next(call for call in calls if "create" in call[0])
        self.assertEqual(create[0][-3:], ["create", "-f", "-"])
        self.assertEqual(json.loads(create[1])["data"],
                         {key: base64.b64encode(value.encode()).decode() for key, value in DATA.items()})
        for mutate in (lambda obj: obj["data"].update(extra="Zm9yYmlkZGVu"),
                       lambda obj: obj["metadata"]["annotations"].update({"symphony-ci-repository-id": "wrong"}),
                       lambda obj: obj["metadata"].update(namespace="foundation-ci-runners")):
            with self.assertRaises(ValueError):
                self.delivered(mutate)

    def test_cli_redacts_input_api_process_errors_and_tracebacks(self):
        marker = "SYNTHETIC-BEARER-OR-KEY-MARKER"
        for args in (["deliver", "--version", marker], ["store", "--app-scope-confirmed"]):
            stdout, stderr = io.StringIO(), io.StringIO()
            with patch.object(secret, "verify_operator", side_effect=RuntimeError(marker)), \
                    contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                self.assertEqual(secret.cli(args), 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertEqual(stderr.getvalue(), secret.ERROR + "\n")
            self.assertNotIn(marker, stdout.getvalue() + stderr.getvalue())
        with patch.object(secret.subprocess, "run", return_value=Mock(returncode=1, stdout=marker.encode(), stderr=marker.encode())):
            with self.assertRaisesRegex(ValueError, "^Private operator command failed$"):
                secret.command(["gcloud", "placeholder"])

    def test_gcloud_inherited_http_debugging_cannot_write_credential_logs(self):
        with patch.dict(os.environ, {"CLOUDSDK_CORE_LOG_HTTP": "true",
                                     "CLOUDSDK_CORE_VERBOSITY": "debug"}), \
                patch.object(secret.subprocess, "run", return_value=Mock(returncode=0, stdout=b"ok")) as run:
            secret.command(["gcloud", "placeholder"], b"synthetic-private-payload")
        env = run.call_args.kwargs["env"]
        self.assertEqual(env["CLOUDSDK_CORE_DISABLE_FILE_LOGGING"], "true")
        self.assertEqual(env["CLOUDSDK_CORE_LOG_HTTP"], "false")
        self.assertEqual(env["CLOUDSDK_CORE_VERBOSITY"], "none")
        self.assertNotIn("synthetic-private-payload", repr(env))


class HelmDiagnosticsTests(unittest.TestCase):
    def install(self, fail):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixtures = {
                "gh": "#!/bin/sh\nprintf all_external_contributors\n",
                "python3": "#!/bin/sh\ncase \"$*\" in *arc_version*) printf 0.15.0;; esac\n",
                "kubectl": "#!/bin/sh\ncase \"$*\" in\n*current-context*) printf gke_iz27-platform-dev_us-west1-a_platform-dev;;\n*'get service kubernetes'*) printf 10.48.0.1;;\n*'get service kube-dns'*) printf 10.48.0.10;;\n*'get secret symphony-ci-github-app'*) printf symphony-ci-github-app;;\nesac\n",
                "helm": "#!/bin/sh\nif [ \"$1\" = upgrade ] && [ \"$FIXTURE_FAIL\" = yes ]; then printf SYNTHETIC-PRIVATE-DIAGNOSTIC >&2; exit 1; fi\n",
            }
            for name, source in fixtures.items():
                path = root / name
                path.write_text(source)
                path.chmod(0o700)
            env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                   "TMPDIR": str(root), "FIXTURE_FAIL": "yes" if fail else "no"}
            result = subprocess.run(["sh", str(CI / "install.sh"),
                "us-west1-docker.pkg.dev/iz27-platform-dev/foundation-ci/symphony-ci-runner@sha256:" + "a" * 64],
                env=env, capture_output=True, text=True)
            self.assertNotIn("SYNTHETIC-PRIVATE-DIAGNOSTIC", result.stdout + result.stderr)
            retained = list(root.glob("symphony-ci-install.*"))
            if fail:
                self.assertEqual(result.returncode, 1)
                self.assertEqual(len(retained), 1)
                self.assertIn(str(retained[0]), result.stderr)
                self.assertEqual(stat.S_IMODE(retained[0].stat().st_mode), 0o700)
                errors = retained[0] / "helm-errors"
                self.assertEqual(stat.S_IMODE(errors.stat().st_mode), 0o600)
                self.assertEqual(errors.read_text(), "SYNTHETIC-PRIVATE-DIAGNOSTIC")
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(retained, [])

    def test_failed_helm_retains_private_diagnostics(self):
        self.install(True)

    def test_success_removes_transient_diagnostics(self):
        self.install(False)
