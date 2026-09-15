import base64
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("kubernetes_runner", Path(__file__).parents[1] / "kubernetes_runner.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)

OWNER = "a" * 32
JOB_UID = "11111111-1111-1111-1111-111111111111"
POD_UID = "22222222-2222-2222-2222-222222222222"
OTHER_UID = "33333333-3333-3333-3333-333333333333"
WORKSPACE = "/var/lib/symphony/workspaces/task-1"


def config(directory):
    cli = Path(directory) / "kubectl"
    cli.write_text("#!/bin/sh\nexit 0\n")
    cli.chmod(0o700)
    kubeconfig = Path(directory) / "kubeconfig"
    kubeconfig.write_text("private fixture\n")
    kubeconfig.chmod(0o600)
    return {"version": 1, "kubectl": str(cli), "kubeconfig": str(kubeconfig),
            "context": RUNNER.CONTEXT, "server": "https://127.0.0.1:18444",
            "ca_sha256": hashlib.sha256(b"fixture-ca").hexdigest(),
            "namespace": "symphony-workers", "namespace_uid": OTHER_UID,
            "image": RUNNER.IMAGE_PREFIX + "b" * 64,
            "workspace_pvc": {"name": "symphony-task-1", "uid": JOB_UID},
            "auth_pvc": {"name": "symphony-auth-1", "uid": POD_UID}}


class Clock:
    def __init__(self):
        self.time = 0

    def __call__(self):
        return self.time

    def sleep(self, seconds):
        self.time += seconds


class Attached:
    def __init__(self, api, code=0, finishes=True):
        self.api = api
        self.code = code
        self.finishes = finishes
        self.returncode = None

    def handshake(self, expected, timeout):
        assert expected == {"owner": OWNER, "generation": 1, "job_uid": JOB_UID, "pod_uid": POD_UID}

    def start_io(self):
        pass

    def finish_io(self):
        pass

    def poll(self):
        if self.finishes:
            self.returncode = self.code
        return self.returncode

    def terminate(self):
        self.returncode = -15

    def kill(self):
        self.returncode = -9

    def wait(self, timeout):
        return self.returncode


class Cluster:
    """Stateful API model: suspension, Pods, identity, and deadline reconciliation."""

    def __init__(self):
        self.job = None
        self.inventory = []
        self.operations = []
        self.attachments = 0
        self.creation_loses_ack = False
        self.wrong_job_uid = False
        self.duplicate = False
        self.mutate_pod = None
        self.mutate_job = None
        self.stuck = False
        self.disappear_after_attach = False
        self.attach_code = 0
        self.attach_finishes = True
        self.pending_polls = 0

    def preflight(self, volumes=True):
        self.operations.append(("preflight", volumes))

    def create(self, manifest):
        self.operations.append(("create",))
        self.job = copy.deepcopy(manifest)
        self.job["metadata"].update(uid=JOB_UID, resourceVersion="1")
        self.job["status"] = {"active": 0}
        if self.mutate_job:
            self.mutate_job(self.job)
        if self.creation_loses_ack:
            raise RUNNER.RunnerError("creation acknowledgement lost")
        return copy.deepcopy(self.job)

    def _start(self):
        pod = {"apiVersion": "v1", "kind": "Pod", "metadata": {
            "name": self.job["metadata"]["name"] + "-pod", "namespace": "symphony-workers",
            "uid": POD_UID, "resourceVersion": "2", "labels": {
                RUNNER.OWNER_LABEL: OWNER, "batch.kubernetes.io/controller-uid": JOB_UID},
            "ownerReferences": [{"apiVersion": "batch/v1", "kind": "Job", "name": self.job["metadata"]["name"],
                                 "uid": JOB_UID, "controller": True}]},
            "spec": copy.deepcopy(self.job["spec"]["template"]["spec"]),
            "status": {"phase": "Running", "containerStatuses": [{"name": "worker", "restartCount": 0,
                         "containerID": "containerd://fixture", "state": {"running": {"startedAt": "2026-09-15T00:00:00Z"}}}]}}
        if self.mutate_pod:
            self.mutate_pod(pod)
        self.inventory = [pod]
        if self.duplicate:
            second = copy.deepcopy(pod)
            second["metadata"].update(uid=OTHER_UID, name=pod["metadata"]["name"] + "-second")
            self.inventory.append(second)
        self.job["status"] = {"active": len(self.inventory)}

    def _finish(self):
        if self.stuck:
            return
        for pod in self.inventory:
            pod["status"] = {"phase": "Failed", "containerStatuses": [{"name": "worker", "restartCount": 0,
                              "containerID": "containerd://fixture", "state": {"terminated": {
                                  "finishedAt": "2026-09-15T00:01:00Z", "exitCode": 0}}}]}
        self.job["status"] = {"active": 0, "terminating": 0, "conditions": [{"type": "Failed", "status": "True"}]}

    def get(self, kind, name):
        assert kind == "job"
        result = copy.deepcopy(self.job)
        if self.wrong_job_uid:
            result["metadata"]["uid"] = OTHER_UID
        return result

    def pods(self, uid):
        assert uid == JOB_UID
        pods = copy.deepcopy(self.inventory)
        if self.attachments and self.disappear_after_attach:
            pods = []
        if self.pending_polls:
            self.pending_polls -= 1
            for pod in pods:
                pod["status"]["phase"] = "Pending"
        return {"apiVersion": "v1", "kind": "PodList", "metadata": {"resourceVersion": "10"}, "items": pods}

    def patch(self, kind, obj, path, value):
        self.operations.append(("patch", kind, obj["metadata"]["uid"], path, value))
        if kind == "job":
            assert obj["metadata"]["uid"] == JOB_UID
            self.job["spec"][path.rsplit("/", 1)[1]] = value
            if path == "/spec/suspend":
                self._start()
            elif path == "/spec/activeDeadlineSeconds":
                self._finish()
        else:
            target = next(pod for pod in self.inventory if pod["metadata"]["uid"] == obj["metadata"]["uid"])
            target["spec"]["activeDeadlineSeconds"] = value
            self._finish()
        return copy.deepcopy(self.job if kind == "job" else target)

    def attach(self, pod):
        self.operations.append(("attach", pod["metadata"]["uid"]))
        self.attachments += 1
        return Attached(self, self.attach_code, self.attach_finishes)


class KubernetesRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        self.config = config(self.root)
        self.intent = RUNNER.Intent(self.root / "launch.json")
        self.cluster = Cluster()
        self.clock = Clock()
        self.runner = RUNNER.Runner(self.config, self.intent, self.cluster, self.clock, self.clock.sleep)

    def tearDown(self):
        self.intent.close()
        self.temporary.cleanup()

    def launch(self, deadline=30):
        return self.runner.launch(WORKSPACE, OWNER, "builder", 1, deadline)

    def test_manifest_uses_digest_gvisor_exclusive_volumes_and_independent_deadlines(self):
        manifest = RUNNER.job_manifest(self.config, WORKSPACE, OWNER, "reviewer", 2, 120, 1800000000)
        spec = manifest["spec"]
        pod = spec["template"]["spec"]
        container = pod["containers"][0]
        self.assertEqual((spec["parallelism"], spec["completions"], spec["backoffLimit"]), (1, 1, 0))
        self.assertEqual(spec["podReplacementPolicy"], "Failed")
        self.assertTrue(spec["suspend"])
        self.assertEqual((spec["activeDeadlineSeconds"], pod["activeDeadlineSeconds"]), (120, 120))
        self.assertEqual(container["args"][-2:], ["--expires-at", "1800000000"])
        self.assertEqual(pod["runtimeClassName"], "gvisor")
        self.assertEqual(pod["restartPolicy"], "Never")
        self.assertTrue(container["stdinOnce"])
        self.assertFalse(container["tty"])
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertTrue(container["volumeMounts"][0]["readOnly"])
        self.assertEqual(container["volumeMounts"][1]["mountPath"], "/var/lib/symphony-auth")
        self.assertNotIn("subPath", container["volumeMounts"][1])
        self.assertNotIn("seccompProfile", pod["securityContext"])
        self.assertNotIn("allowPrivilegeEscalation", container["securityContext"])
        encoded = json.dumps(manifest)
        self.assertNotIn("hostPath", encoded)
        self.assertNotIn("secretKeyRef", encoded)
        self.assertNotIn("imagePullSecrets", encoded)

    def test_config_rejects_mutable_images_public_targets_and_shared_volumes(self):
        self.assertEqual(RUNNER.validate_config(self.config), self.config)
        for field, value in (("image", "worker:latest"), ("server", "https://8.8.8.8"),
                             ("server", "https://127.0.0.1/path"), ("context", "other"),
                             ("namespace", "symphony"), ("ca_sha256", "unknown"),
                             ("auth_pvc", self.config["workspace_pvc"])):
            altered = copy.deepcopy(self.config)
            altered[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(RUNNER.RunnerError):
                RUNNER.validate_config(altered)

    def test_launch_persists_exact_ownership_and_terminal_receipt(self):
        self.assertEqual(self.launch(), 0)
        saved = json.loads(self.intent.path.read_text())
        self.assertEqual(saved["state"], "terminated")
        self.assertEqual(saved["job_uid"], JOB_UID)
        self.assertEqual(saved["pod_uid"], POD_UID)
        self.assertTrue(saved["attachment_attempted"])
        self.assertEqual(saved["termination"]["receipt"]["selector"], "batch.kubernetes.io/controller-uid=" + JOB_UID)
        self.assertEqual(self.intent.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.cluster.attachments, 1)
        self.assertFalse(any(operation[0] == "delete" for operation in self.cluster.operations))
        auth_spec = importlib.util.spec_from_file_location("kubernetes_auth_receipt", Path(__file__).parents[1] / "kubernetes_auth.py")
        auth = importlib.util.module_from_spec(auth_spec)
        auth_spec.loader.exec_module(auth)
        auth.terminal_job_evidence(saved["termination"]["receipt"], {"job_uid": JOB_UID, "pod_uid": POD_UID})

    def test_existing_intent_never_relaunches_even_after_success(self):
        self.launch()
        before = self.intent.path.read_bytes()
        with self.assertRaises(FileExistsError):
            self.launch()
        self.assertEqual(self.intent.path.read_bytes(), before)
        self.assertEqual(sum(operation[0] == "create" for operation in self.cluster.operations), 1)

    def test_lost_creation_acknowledgement_does_not_adopt_or_retry_job(self):
        self.cluster.creation_loses_ack = True
        with self.assertRaisesRegex(RUNNER.RunnerError, "acknowledgement lost"):
            self.launch()
        self.assertIsNotNone(self.cluster.job)
        self.assertEqual(self.intent.data["state"], "uncertain")
        self.assertIsNone(self.intent.data["job_uid"])
        self.assertEqual(self.cluster.attachments, 0)
        self.assertFalse(any(op[0] == "patch" for op in self.cluster.operations))
        with self.assertRaisesRegex(RUNNER.RunnerError, "acknowledgement was lost"):
            self.runner.cancel()

    def test_job_replacement_never_mutates_or_attaches_replacement(self):
        self.cluster.wrong_job_uid = True
        with self.assertRaisesRegex(RUNNER.RunnerError, "ownership"):
            self.launch()
        self.assertEqual(self.cluster.attachments, 0)
        self.assertFalse(any(op[0] == "patch" for op in self.cluster.operations))
        self.assertEqual(self.intent.data["state"], "uncertain")

    def test_duplicate_pods_never_receive_protocol_and_all_must_terminate(self):
        self.cluster.duplicate = True
        with self.assertRaisesRegex(RUNNER.RunnerError, "Duplicate Pods"):
            self.launch()
        self.assertEqual(self.cluster.attachments, 0)
        self.assertEqual(set(self.intent.data["observed_pods"]), {POD_UID, OTHER_UID})
        self.assertEqual(len(self.intent.data["termination"]["receipt"]["pods"]["items"]), 2)

    def test_sidecar_admission_is_rejected_before_attachment(self):
        self.cluster.mutate_pod = lambda pod: pod["spec"]["containers"].append({"name": "injected"})
        with self.assertRaisesRegex(RUNNER.RunnerError, "Admitted Pod differs"):
            self.launch()
        self.assertEqual(self.cluster.attachments, 0)
        self.assertEqual(self.intent.data["state"], "uncertain")

    def test_admission_cannot_inject_hooks_or_elevated_capabilities(self):
        def hook(pod):
            pod["spec"]["containers"][0]["lifecycle"] = {"postStart": {"exec": {"command": ["unreviewed"]}}}
        self.cluster.mutate_pod = hook
        with self.assertRaisesRegex(RUNNER.RunnerError, "Admitted Pod differs"):
            self.launch()
        self.assertEqual(self.cluster.attachments, 0)

    def test_mutated_suspended_job_is_never_started(self):
        self.cluster.mutate_job = lambda job: job["spec"]["template"]["spec"]["containers"][0].update(
            lifecycle={"postStart": {"exec": {"command": ["unreviewed"]}}})
        with self.assertRaisesRegex(RUNNER.RunnerError, "Job template differs"):
            self.launch()
        self.assertTrue(self.cluster.job["spec"]["suspend"])
        self.assertEqual(self.cluster.attachments, 0)
        self.assertFalse(any(op[0] == "patch" for op in self.cluster.operations))

    def test_authority_fields_are_rejected_but_exact_gke_defaults_are_accepted(self):
        expected = RUNNER.job_manifest(self.config, WORKSPACE, OWNER, "builder", 1, 30)["spec"]["template"]["spec"]
        actual = copy.deepcopy(expected)
        actual.update(dnsPolicy="ClusterFirst", schedulerName="default-scheduler", priority=0,
                      preemptionPolicy="PreemptLowerPriority", serviceAccount="symphony-worker",
                      nodeName="gke-platform-dev-symphony-workers-fixture")
        actual["nodeSelector"]["sandbox.gke.io/runtime"] = "gvisor"
        actual["tolerations"] += [
            {"key": "node.kubernetes.io/not-ready", "operator": "Exists", "effect": "NoExecute", "tolerationSeconds": 300},
            {"key": "node.kubernetes.io/unreachable", "operator": "Exists", "effect": "NoExecute", "tolerationSeconds": 300},
            {"key": "sandbox.gke.io/runtime", "operator": "Equal", "value": "gvisor", "effect": "NoSchedule"}]
        for key in ("hostNetwork", "hostPID", "hostIPC"):
            actual.pop(key)
        actual["containers"][0].pop("tty")
        actual["containers"][0]["volumeMounts"][0].pop("readOnly")
        actual["containers"][0]["terminationMessagePath"] = "/dev/termination-log"
        for env in actual["containers"][0]["env"]:
            if "valueFrom" in env:
                env["valueFrom"]["fieldRef"]["apiVersion"] = "v1"
        self.assertTrue(RUNNER.constrained_pod(expected, actual))
        mutators = [
            lambda pod: pod["containers"][0]["securityContext"].update(procMount="Unmasked"),
            lambda pod: pod["containers"][0]["securityContext"].update(runAsUser=0, runAsNonRoot=False),
            lambda pod: pod["containers"][0]["securityContext"].update(runAsGroup=0),
            lambda pod: pod["containers"][0]["resources"].update(claims=[{"name": "unreviewed"}]),
            lambda pod: pod["containers"][0].update(ports=[{"containerPort": 8080}]),
            lambda pod: pod["containers"][0].update(volumeDevices=[{"name": "device", "devicePath": "/dev/raw"}]),
            lambda pod: pod["containers"][0]["volumeMounts"][0].update(subPath="other"),
            lambda pod: pod["containers"][0]["volumeMounts"][0].update(mountPropagation="Bidirectional"),
            lambda pod: pod["volumes"][0].update(hostPath={"path": "/"}),
            lambda pod: pod["securityContext"].update(sysctls=[{"name": "unreviewed", "value": "1"}]),
            lambda pod: pod.update(hostAliases=[{"ip": "10.0.0.1", "hostnames": ["auth.openai.com"]}]),
        ]
        for index, mutate in enumerate(mutators):
            changed = copy.deepcopy(actual)
            mutate(changed)
            with self.subTest(mutation=index):
                self.assertFalse(RUNNER.constrained_pod(expected, changed))

    def test_partial_pod_list_cannot_become_termination_evidence(self):
        original = self.cluster.pods
        def partial(uid):
            inventory = original(uid)
            inventory["metadata"]["continue"] = "unread-page"
            return inventory
        self.cluster.pods = partial
        with self.assertRaisesRegex(RUNNER.RunnerError, "inventory"):
            self.launch()
        self.assertEqual(self.intent.data["state"], "uncertain")
        self.assertNotIn("termination", self.intent.data)

    def test_container_replacement_during_attachment_is_not_adopted(self):
        original = self.cluster.pods
        def replaced(uid):
            inventory = original(uid)
            if self.cluster.attachments:
                inventory["items"][0]["status"]["containerStatuses"][0]["containerID"] = "containerd://replacement"
            return inventory
        self.cluster.pods = replaced
        with self.assertRaisesRegex(RUNNER.RunnerError, "container identity changed"):
            self.launch()
        self.assertEqual(self.intent.data["state"], "uncertain")
        self.assertEqual(self.intent.data["container_id"], "containerd://fixture")

    def test_preflight_time_consumes_budget_without_creating_an_expired_job(self):
        self.cluster.preflight = lambda volumes=True: self.clock.sleep(10)
        with self.assertRaisesRegex(RUNNER.RunnerError, "expired before resource creation"):
            self.launch(deadline=5)
        self.assertIsNone(self.cluster.job)
        self.assertFalse(self.intent.path.exists())

    def test_lost_pod_object_is_not_proof_of_stopped_process(self):
        self.cluster.disappear_after_attach = True
        with self.assertRaisesRegex(RUNNER.RunnerError, "disappeared"):
            self.launch()
        self.assertEqual(self.intent.data["state"], "uncertain")
        self.assertNotIn("termination", self.intent.data)

    def test_transport_loss_cancels_without_reconnecting(self):
        self.cluster.attach_code = 1
        with self.assertRaisesRegex(RUNNER.RunnerError, "reconnection is forbidden"):
            self.launch()
        self.assertEqual(self.cluster.attachments, 1)
        self.assertEqual(self.intent.data["state"], "terminated")

    def test_node_loss_keeps_auth_and_workspace_blocked_after_cancel_timeout(self):
        self.cluster.stuck = True
        with self.assertRaisesRegex(RUNNER.RunnerError, "termination was not verified"):
            self.launch()
        self.assertEqual(self.intent.data["state"], "uncertain")
        self.assertNotIn("termination", self.intent.data)
        self.assertLessEqual(self.clock(), 46)

    def test_cold_start_consumes_same_deadline_as_attached_execution(self):
        self.cluster.pending_polls = 8  # Four seconds of scheduling/image pull.
        self.cluster.attach_finishes = False
        with self.assertRaisesRegex(RUNNER.RunnerError, "exceeded its bound"):
            self.launch(deadline=5)
        self.assertEqual(self.clock(), 5)
        self.assertEqual(self.cluster.attachments, 1)

    def test_stale_configuration_cannot_cancel_another_target(self):
        self.launch()
        self.config["namespace_uid"] = JOB_UID
        with self.assertRaisesRegex(RUNNER.RunnerError, "configuration differs"):
            self.runner.cancel()

    def test_intent_lock_and_checkout_boundary_are_enforced(self):
        with self.assertRaisesRegex(RUNNER.RunnerError, "Launcher is active"):
            RUNNER.Intent(self.intent.path)
        workspace = self.root / "checkout"
        workspace.mkdir(mode=0o700)
        with self.assertRaisesRegex(RUNNER.RunnerError, "outside the checkout"):
            RUNNER.Intent(workspace / "intent.json", workspace)

    def test_interrupted_atomic_write_is_retained_without_overwriting_evidence(self):
        self.intent.create({"version": 1, "state": "launch_intent"})
        pending = self.intent.path.with_name(self.intent.path.name + ".pending")
        pending.write_text("interrupted write evidence")
        before = self.intent.path.read_bytes()
        with self.assertRaises(FileExistsError):
            self.intent.update(state="erased")
        self.assertEqual(pending.read_text(), "interrupted write evidence")
        self.assertEqual(self.intent.path.read_bytes(), before)

    def test_terminal_phase_without_container_shutdown_is_not_evidence(self):
        self.cluster.create(RUNNER.job_manifest(self.config, WORKSPACE, OWNER, "builder", 1, 30))
        self.cluster._start()
        pod = self.cluster.inventory[0]
        pod["status"]["phase"] = "Failed"
        self.assertIsNone(RUNNER.terminal_evidence(pod))
        self.cluster._finish()
        self.assertIsNotNone(RUNNER.terminal_evidence(pod))
        pod["status"]["containerStatuses"][0]["restartCount"] = 1
        self.assertIsNone(RUNNER.terminal_evidence(pod))


class KubectlBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.config = config(Path(self.temporary.name).resolve())
        self.api = RUNNER.Kubectl(self.config)

    def tearDown(self):
        self.temporary.cleanup()

    def test_mutations_use_uid_and_resource_version_preconditions(self):
        obj = {"metadata": {"name": "owned", "uid": POD_UID, "resourceVersion": "42"}}
        with patch.object(self.api, "command", return_value=obj) as command:
            self.api.patch("pod", obj, "/spec/activeDeadlineSeconds", 1)
        args = command.call_args.args[0]
        payload = json.loads(args[args.index("-p") + 1])
        self.assertEqual(payload[:2], [{"op": "test", "path": "/metadata/uid", "value": POD_UID},
                                      {"op": "test", "path": "/metadata/resourceVersion", "value": "42"}])
        self.assertNotIn("delete", args)

    def test_attach_is_exact_pod_non_tty_and_never_shell_interpolated(self):
        with patch.object(RUNNER.subprocess, "Popen") as popen:
            self.api.attach({"metadata": {"name": "owned-pod", "uid": POD_UID}})
        args = popen.call_args.args[0]
        self.assertIn("--stdin", args)
        self.assertIn("--tty=false", args)
        self.assertIn("--quiet", args)
        self.assertIn("--container=worker", args)
        self.assertIn("owned-pod", args)
        self.assertNotIn("shell", popen.call_args.kwargs)
        self.assertNotIn("-t", args)
        self.assertEqual(popen.call_args.kwargs["stderr"], subprocess.DEVNULL)
        self.assertEqual(popen.call_args.kwargs["stdin"], subprocess.PIPE)

    def test_wrong_identity_receives_no_stdin_before_handshake_failure(self):
        expected = {"owner": OWNER, "generation": 1, "job_uid": JOB_UID, "pod_uid": POD_UID}
        script = "import json,sys; print(json.dumps({'symphony_worker':{'pod_uid':'replacement'}}),flush=True); data=sys.stdin.buffer.read(1); sys.exit(4 if data else 0)"
        attached = RUNNER.StdioAttachment([sys.executable, "-u", "-c", script])
        try:
            with self.assertRaisesRegex(RUNNER.RunnerError, "differs from the owned Pod"):
                attached.handshake(expected, timeout=2)
            self.assertIsNone(attached.poll())
            attached.process.stdin.close()
            self.assertEqual(attached.wait(timeout=2), 0)
        finally:
            if attached.poll() is None:
                attached.kill()
                attached.wait(timeout=2)
            attached.process.stdout.close()

    def test_identity_handshake_does_not_consume_first_protocol_response(self):
        expected = {"owner": OWNER, "generation": 1, "job_uid": JOB_UID, "pod_uid": POD_UID}
        payload = json.dumps({"symphony_worker": expected}) + "\n" + '{"id":1,"result":{}}\n'
        attached = RUNNER.StdioAttachment([sys.executable, "-u", "-c", "import sys; sys.stdout.write(" + repr(payload) + "); sys.stdout.flush()"])
        try:
            attached.handshake(expected, timeout=2)
            self.assertEqual(attached.process.stdout.readline(), b'{"id":1,"result":{}}\n')
            self.assertEqual(attached.wait(timeout=2), 0)
        finally:
            attached.process.stdin.close()
            attached.process.stdout.close()

    def test_preflight_checks_private_cluster_ca_namespace_and_rwop_claim_uids(self):
        cluster = {"server": self.config["server"], "certificate-authority-data": base64.b64encode(b"fixture-ca").decode()}
        namespace = {"metadata": {"uid": OTHER_UID}}
        pvcs = [{"metadata": {"uid": uid}, "spec": {"accessModes": ["ReadWriteOncePod"]}} for uid in (JOB_UID, POD_UID)]
        with patch.object(self.api, "command", side_effect=[cluster, namespace] + pvcs):
            self.api.preflight()
        for changed in ({"server": "https://10.0.0.9", "certificate-authority-data": cluster["certificate-authority-data"]},
                        {**cluster, "insecure-skip-tls-verify": True},
                        {**cluster, "certificate-authority-data": base64.b64encode(b"different-ca").decode()}):
            with self.subTest(changed=changed), patch.object(self.api, "command", return_value=changed):
                with self.assertRaises(RUNNER.RunnerError):
                    self.api.preflight()
        pvcs[1]["spec"]["accessModes"] = ["ReadWriteOnce"]
        with patch.object(self.api, "command", side_effect=[cluster, namespace] + pvcs):
            with self.assertRaisesRegex(RUNNER.RunnerError, "exclusive access"):
                self.api.preflight()

    def test_command_failure_does_not_leak_credential_plugin_output(self):
        result = subprocess.CompletedProcess([], 1, b"", b"sensitive credential plugin error")
        with patch.object(RUNNER.subprocess, "run", return_value=result):
            with self.assertRaises(RUNNER.RunnerError) as caught:
                self.api.get("job", "owned")
        self.assertNotIn("sensitive", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
