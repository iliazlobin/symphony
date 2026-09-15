"""Canary authority boundaries and generated-code regressions; no cluster calls."""

import ast
import copy
import importlib.util
import inspect
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "probe_kubernetes_permissions", Path(__file__).resolve().parents[1] / "probe_kubernetes_permissions.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)
IMAGE = "us-west1-docker.pkg.dev/iz27-platform-dev/symphony/worker@sha256:" + "1" * 64


def admitted_fixture(expected):
    """Only the GKE defaults observed on the pilot; no copied runtime records."""
    actual = copy.deepcopy(expected)
    actual["metadata"]["uid"] = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    spec = actual["spec"]
    spec.update(dnsPolicy="ClusterFirst", schedulerName="default-scheduler",
                serviceAccount="default", serviceAccountName="default", priority=0,
                preemptionPolicy="PreemptLowerPriority", nodeName="gke-worker-test")
    spec["nodeSelector"]["sandbox.gke.io/runtime"] = "gvisor"
    spec["tolerations"].extend([
        {"effect": "NoExecute", "key": "node.kubernetes.io/not-ready",
         "operator": "Exists", "tolerationSeconds": 300},
        {"effect": "NoExecute", "key": "node.kubernetes.io/unreachable",
         "operator": "Exists", "tolerationSeconds": 300},
        {"effect": "NoSchedule", "key": "sandbox.gke.io/runtime",
         "operator": "Equal", "value": "gvisor"},
    ])
    container = spec["containers"][0]
    container.update(terminationMessagePath="/dev/termination-log", terminationMessagePolicy="File")
    container["readinessProbe"].update(failureThreshold=3, successThreshold=1, timeoutSeconds=1)
    actual["status"] = {
        "phase": "Running",
        "containerStatuses": [{"name": PROBE.CONTAINER, "restartCount": 0, "ready": True,
                               "state": {"running": {"startedAt": "2026-09-15T00:00:00Z"}},
                               "containerID": "containerd://fake-canary",
                               "imageID": IMAGE}],
    }
    return actual


class KubernetesPermissionBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.expected = PROBE.manifest("symphony-workers", "permission-canary", IMAGE)
        self.actual = admitted_fixture(self.expected)

    def test_observed_gke_defaults_preserve_the_fake_only_fixture(self):
        before = copy.deepcopy(self.actual)
        PROBE.validate_pod(self.actual, self.expected)
        self.assertEqual(self.actual, before, "Validation must not normalize the API evidence in place")
        self.assertTrue(all(set(volume) == {"name", "emptyDir"}
                            for volume in self.expected["spec"]["volumes"]))

    def test_real_credential_storage_and_environment_cannot_enter_canary(self):
        def secret_volume(pod):
            pod["spec"]["volumes"].append({"name": "injected", "secret": {"secretName": "real-auth"}})
            pod["spec"]["containers"][0]["volumeMounts"].append({"name": "injected", "mountPath": "/secret"})

        def retained_auth(pod):
            pod["spec"]["volumes"][0] = {"name": "workspace", "persistentVolumeClaim": {"claimName": "retained-data"}}

        def secret_environment(pod):
            pod["spec"]["containers"][0]["envFrom"] = [{"secretRef": {"name": "real-auth"}}]

        for mutation in (secret_volume, retained_auth, secret_environment):
            changed = copy.deepcopy(self.actual)
            mutation(changed)
            with self.subTest(mutation=mutation.__name__), self.assertRaises(ValueError):
                PROBE.validate_pod(changed, self.expected)

    def test_host_namespaces_or_container_identity_override_are_rejected(self):
        for field in ("hostPID", "hostIPC", "hostNetwork"):
            changed = copy.deepcopy(self.actual)
            changed["spec"][field] = True
            with self.subTest(field=field), self.assertRaises(ValueError):
                PROBE.validate_pod(changed, self.expected)
        for field, value in (("runAsUser", 0), ("procMount", "Unmasked")):
            changed = copy.deepcopy(self.actual)
            changed["spec"]["containers"][0]["securityContext"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                PROBE.validate_pod(changed, self.expected)

    def test_runtime_defaults_do_not_admit_broad_scheduling_tolerations(self):
        changed = copy.deepcopy(self.actual)
        changed["spec"]["tolerations"].append({"operator": "Exists"})
        with self.assertRaisesRegex(ValueError, "tolerations"):
            PROBE.validate_pod(changed, self.expected)
        changed = copy.deepcopy(self.actual)
        changed["spec"]["nodeSelector"].pop("node-restriction.kubernetes.io/workload")
        with self.assertRaisesRegex(ValueError, "selection"):
            PROBE.validate_pod(changed, self.expected)

    def test_running_digest_must_match_requested_immutable_image(self):
        changed = copy.deepcopy(self.actual)
        changed["status"]["containerStatuses"][0]["imageID"] = "sha256:" + "2" * 64
        with self.assertRaisesRegex(ValueError, "digest"):
            PROBE.validate_pod(changed, self.expected)
        changed["spec"]["containers"][0]["image"] = IMAGE.replace("1" * 64, "2" * 64)
        with self.assertRaises(ValueError):
            PROBE.validate_pod(changed, self.expected)
        with self.assertRaisesRegex(ValueError, "digest"):
            PROBE.manifest("symphony-workers", "permission-canary", "worker:latest")

    def test_changed_fixture_or_restarted_container_cannot_be_probed(self):
        changed = copy.deepcopy(self.actual)
        changed["metadata"]["annotations"]["symphony.openai.com/fixture-sha256"] = "2" * 64
        with self.assertRaisesRegex(ValueError, "annotation"):
            PROBE.validate_pod(changed, self.expected)
        changed = copy.deepcopy(self.actual)
        changed["status"]["containerStatuses"][0]["restartCount"] = 1
        with self.assertRaisesRegex(ValueError, "fresh"):
            PROBE.validate_pod(changed, self.expected)

    def test_embedded_fixture_probe_and_inner_script_compile_without_running(self):
        fixture_source = PROBE.fixture_source()
        compile(fixture_source, "<embedded-fixture>", "exec")
        # Compile precisely the source assembled for kubectl exec; imports and
        # absolute path accesses are not executed by this test.
        probe_source = inspect.getsource(PROBE.in_pod_probe_main)
        assembled = probe_source + "\nin_pod_probe_main(" + repr(PROBE.permission_config()) + ")\n"
        compile(assembled, "<embedded-probe>", "exec")
        tree = ast.parse(probe_source)
        templates = [node.value for node in ast.walk(tree)
                     if isinstance(node, ast.Constant) and isinstance(node.value, str)
                     and "__PATHS__" in node.value and "__PORT__" in node.value]
        self.assertEqual(len(templates), 1, "Locate the embedded shell-command script explicitly")
        inner = templates[0].replace("__PATHS__", repr({"auth_read": "/fake/auth.json"})).replace("__PORT__", "12345")
        compile(inner, "<embedded-sandbox-command>", "exec")
        self.assertIn("/var/lib/symphony-auth/slot-01", inner)
        self.assertNotIn('"turn/start"', probe_source)
        self.assertNotIn('"account/login/start"', probe_source)

    def test_exec_stream_timeout_does_not_inherit_short_api_read_timeout(self):
        args = SimpleNamespace(kubectl="/test/kubectl", kubeconfig="/private/config", context="test")
        with patch.object(PROBE.subprocess, "run", return_value=SimpleNamespace(stdout="{}")) as run:
            PROBE.kubectl(args, ["exec", "fake-pod", "--", "true"], timeout=270)
            self.assertIn("--request-timeout=240s", run.call_args.args[0])
            self.assertEqual(run.call_args.kwargs["timeout"], 270)
            PROBE.kubectl(args, ["get", "pod", "fake-pod"])
            self.assertIn("--request-timeout=20s", run.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
