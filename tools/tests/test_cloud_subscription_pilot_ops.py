import copy
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("pilot_ops", Path(__file__).parents[1] / "cloud_subscription_pilot_ops.py")
OPS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OPS)
OWNER = "a" * 32
NS_UID = "11111111-1111-1111-1111-111111111111"
PVC_UID = "22222222-2222-2222-2222-222222222222"
JOB_UID = "33333333-3333-3333-3333-333333333333"
POD_UID = "44444444-4444-4444-4444-444444444444"
IMAGE = "us-west1-docker.pkg.dev/iz27-platform-dev/symphony/worker@sha256:" + "b" * 64


def snapshots():
    manifest = OPS.job_manifest(IMAGE, OWNER, "task", 2, 1600, now=1000)
    ns = {"kind": "Namespace", "metadata": {"name": OPS.NAMESPACE, "uid": NS_UID, "resourceVersion": "10"}}
    pvc = OPS.foundation()["items"][0]
    pvc["metadata"].update(uid=PVC_UID, resourceVersion="11")
    pvc["spec"]["volumeName"] = "pvc-" + PVC_UID
    pvc["status"] = {"phase": "Bound"}
    job = copy.deepcopy(manifest)
    job["metadata"].update(uid=JOB_UID, resourceVersion="12")
    job["spec"].update(manualSelector=False, completionMode="NonIndexed",
                          selector={"matchLabels": {"batch.kubernetes.io/controller-uid": JOB_UID}})
    pod = {"apiVersion": "v1", "kind": "Pod", "metadata": {
        "name": "symphony-pilot-test", "namespace": OPS.NAMESPACE, "uid": POD_UID, "resourceVersion": "13",
        "labels": {"app": OPS.APP, OPS.OWNER: OWNER, "batch.kubernetes.io/controller-uid": JOB_UID},
        "ownerReferences": [{"kind": "Job", "uid": JOB_UID, "name": job["metadata"]["name"], "controller": True}]},
        "spec": copy.deepcopy(manifest["spec"]["template"]["spec"]),
        "status": {"phase": "Running", "containerStatuses": [{"name": "worker", "restartCount": 0,
            "containerID": "containerd://bounded", "imageID": "docker-pullable://" + IMAGE, "ready": True,
            "state": {"running": {"startedAt": "2026-09-15T00:00:00Z"}}}]}}
    pods = {"apiVersion": "v1", "kind": "PodList", "metadata": {"resourceVersion": "14"}, "items": [pod]}
    return dict(manifest=manifest, namespace=ns, pvc=pvc, job=job, pods=pods,
                namespace_uid=NS_UID, pvc_uid=PVC_UID, job_uid=JOB_UID)


def recovery_snapshots():
    values = snapshots()
    admission = OPS.validate(**values)
    job = values["job"]
    job["metadata"]["creationTimestamp"] = "2026-09-15T00:00:00Z"
    job["status"] = {"failed": 1, "active": 0, "terminating": 0, "uncountedTerminatedPods": {},
                     "conditions": [{"type": "Failed", "status": "True", "lastTransitionTime": "2026-09-15T00:01:02Z"}]}
    pod = values["pods"]["items"].pop()
    pod["@type"] = "core.k8s.io/v1.Pod"
    pod["metadata"]["creationTimestamp"] = "2026-09-15T00:00:01Z"
    pod["status"]["phase"] = "Failed"
    state = pod["status"]["containerStatuses"][0]
    state.update(ready=False, started=False, lastState={}, state={"terminated": {
        "exitCode": 1, "reason": "Error", "containerID": state["containerID"],
        "startedAt": "2026-09-15T00:00:02Z", "finishedAt": "2026-09-15T00:01:00Z"}})
    entry = {"insertId": "native-entry", "timestamp": "2026-09-15T00:01:01Z", "receiveTimestamp": "2026-09-15T00:01:03.630019736Z",
             "logName": "projects/iz27-platform-dev/logs/cloudaudit.googleapis.com%2Factivity",
             "resource": {"type": "k8s_cluster", "labels": {
                 "project_id": "iz27-platform-dev", "cluster_name": "platform-dev", "location": "us-west1-a"}},
             "protoPayload": {"@type": "type.googleapis.com/google.cloud.audit.AuditLog", "serviceName": "k8s.io",
                 "methodName": "io.k8s.core.v1.pods.patch", "status": {"code": 0},
                 "resourceName": f"core/v1/namespaces/{OPS.NAMESPACE}/pods/{pod['metadata']['name']}", "response": pod}}
    return {**values, "audit": [entry], "admission": admission}


class PilotOpsTests(unittest.TestCase):
    def test_foundation_retains_rwop_without_scoping_other_workers(self):
        pvc, policy = OPS.foundation()["items"]
        self.assertEqual(pvc["spec"]["storageClassName"], "shared-retain")
        self.assertEqual(pvc["spec"]["accessModes"], ["ReadWriteOncePod"])
        self.assertEqual(pvc["spec"]["resources"]["requests"]["storage"], "1Gi")
        self.assertEqual(policy["spec"]["podSelector"], {"matchLabels": {"app": OPS.APP}})
        dns, https = policy["spec"]["egress"]
        self.assertEqual(dns["to"][0]["namespaceSelector"]["matchLabels"], {"kubernetes.io/metadata.name": "kube-system"})
        self.assertEqual(dns["to"][0]["podSelector"]["matchLabels"], {"k8s-app": "kube-dns"})
        self.assertEqual(dns["to"][1], {
            "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
            "podSelector": {"matchLabels": {"k8s-app": "node-local-dns"}}})
        self.assertEqual(dns["ports"], [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}])
        self.assertEqual(len(dns["to"]), 2)
        self.assertTrue(all("ipBlock" not in peer for peer in dns["to"]))
        self.assertEqual(https["ports"], [{"protocol": "TCP", "port": 443}])
        excluded = [ipaddress.ip_network(item) for item in https["to"][0]["ipBlock"]["except"]]
        for ip in ("127.0.0.1", "10.4.0.1", "172.20.0.1", "192.168.1.1", "169.254.169.254", "100.100.1.1"):
            self.assertTrue(any(ipaddress.ip_address(ip) in item for item in excluded))
        self.assertFalse(any(ipaddress.ip_address("8.8.8.8") in item for item in excluded))

    def test_manifest_bounds_and_whole_auth_mount(self):
        manifest = snapshots()["manifest"]
        pod = manifest["spec"]["template"]["spec"]
        self.assertEqual(pod["runtimeClassName"], "gvisor")
        self.assertEqual(pod["securityContext"]["fsGroupChangePolicy"], "OnRootMismatch")
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertEqual(manifest["spec"]["backoffLimit"], 0)
        self.assertNotIn("ttlSecondsAfterFinished", manifest["spec"])
        self.assertEqual(pod["volumes"][1]["persistentVolumeClaim"], {"claimName": OPS.PVC})
        self.assertNotIn("subPath", pod["containers"][0]["volumeMounts"][1])

    def test_rejects_tags_excess_deadlines_and_bad_generations(self):
        for overrides in ({"image": IMAGE.split("@")[0] + ":latest"}, {"expires_at": 1901},
                          {"expires_at": 1000}, {"generation": True}, {"owner": "../bad"}):
            args = dict(image=IMAGE, owner=OWNER, stage="task", generation=2, expires_at=1600, now=1000)
            args.update(overrides)
            with self.subTest(overrides=overrides), self.assertRaises(OPS.OpsError):
                OPS.job_manifest(**args)

    def test_admission_and_known_api_defaults(self):
        values = snapshots()
        for spec in (values["job"]["spec"]["template"]["spec"], values["pods"]["items"][0]["spec"]):
            for key in ("hostNetwork", "hostIPC", "hostPID", "shareProcessNamespace"):
                spec.pop(key)
            spec.update(dnsPolicy="ClusterFirst", schedulerName="default-scheduler")
            spec["containers"][0].pop("stdin")
            spec["containers"][0].pop("stdinOnce")
            spec["containers"][0]["terminationMessagePath"] = "/dev/termination-log"
        result = OPS.validate(**values)
        self.assertEqual(result["pod_uid"], POD_UID)
        self.assertEqual(result["image"], IMAGE)

    def test_rejects_wrong_image_or_added_container_authority(self):
        for mutate in (
            lambda p: p["spec"].update(hostNetwork=True),
            lambda p: p["spec"].update(runtimeClassName="runc"),
            lambda p: p["spec"].update(automountServiceAccountToken=True),
            lambda p: p["spec"]["securityContext"].update(fsGroupChangePolicy="Always"),
            lambda p: p["spec"]["containers"][0]["securityContext"].update(privileged=True),
            lambda p: p["spec"]["containers"][0]["volumeMounts"][1].update(subPath="auth.json"),
            lambda p: p["spec"]["volumes"].append({"name": "host", "hostPath": {"path": "/"}}),
            lambda p: p["status"]["containerStatuses"][0].update(imageID="sha256:" + "c" * 64),
            lambda p: p["status"]["containerStatuses"][0].update(restartCount=1),
        ):
            values = snapshots()
            mutate(values["pods"]["items"][0])
            with self.assertRaises(OPS.OpsError):
                OPS.validate(**values)

    def test_rejects_replaced_namespace_pvc_job_pod_owner(self):
        for key in ("namespace", "pvc", "job"):
            values = snapshots()
            values[key]["metadata"]["uid"] = POD_UID
            with self.subTest(key=key), self.assertRaises(OPS.OpsError):
                OPS.validate(**values)
        values = snapshots()
        values["pods"]["items"][0]["metadata"]["ownerReferences"][0]["uid"] = PVC_UID
        with self.assertRaises(OPS.OpsError):
            OPS.validate(**values)

    def test_rejects_pagination_missing_and_replacement_pods(self):
        for mutate in (lambda p: p["metadata"].update({"continue": "next"}),
                       lambda p: p.update(items=[]), lambda p: p["items"].append(copy.deepcopy(p["items"][0]))):
            values = snapshots()
            mutate(values["pods"])
            with self.assertRaises(OPS.OpsError):
                OPS.validate(**values)

    def test_rejects_kubectl_list_wrapper_and_missing_collection_revision(self):
        for kind, revision in (("List", "14"), ("List", ""), ("PodList", "")):
            values = snapshots()
            values["pods"]["kind"] = kind
            values["pods"]["metadata"]["resourceVersion"] = revision
            with self.subTest(kind=kind, revision=revision), self.assertRaises(OPS.OpsError):
                OPS.validate(**values)

    def test_native_typed_pod_list_items_may_omit_type_metadata(self):
        values = snapshots()
        pod = values["pods"]["items"][0]
        pod.pop("kind")
        pod.pop("apiVersion")
        self.assertEqual(OPS.validate(**values)["pod_uid"], POD_UID)
        pod["kind"] = "Secret"
        with self.assertRaises(OPS.OpsError):
            OPS.validate(**values)
        pod.pop("kind")
        pod["metadata"].pop("resourceVersion")
        with self.assertRaises(OPS.OpsError):
            OPS.validate(**values)

    def test_terminal_receipt_requires_job_and_all_container_termination(self):
        values = snapshots()
        with self.assertRaises(OPS.AUTH.AuthSlotError):
            OPS.receipt(**values, pod_uid=POD_UID)
        values["job"]["status"] = {"active": 0, "conditions": [{"type": "Complete", "status": "True"}]}
        pod = values["pods"]["items"][0]
        pod["status"]["phase"] = "Succeeded"
        pod["status"]["containerStatuses"][0]["state"] = {"terminated": {"exitCode": 0, "finishedAt": "2026-09-15T00:01:00Z"}}
        result = OPS.receipt(**values, pod_uid=POD_UID)
        self.assertEqual(set(result), {"job", "pods", "selector"})
        with self.assertRaises(OPS.OpsError):
            OPS.receipt(**values, pod_uid=PVC_UID)
        pod["metadata"]["deletionTimestamp"] = "2026-09-15T00:01:01Z"
        with self.assertRaises(OPS.OpsError):
            OPS.receipt(**values, pod_uid=POD_UID)

    def test_rejects_job_ttl_or_extra_retry_authority(self):
        for key, value in (("ttlSecondsAfterFinished", 60), ("backoffLimit", 1), ("parallelism", 2)):
            values = snapshots()
            values["job"]["spec"][key] = value
            with self.subTest(key=key), self.assertRaises(OPS.OpsError):
                OPS.validate(**values)

    def test_saved_manifest_cannot_redefine_security_contract(self):
        values = snapshots()
        values["manifest"]["spec"]["template"]["spec"]["hostNetwork"] = True
        values["job"]["spec"]["template"]["spec"]["hostNetwork"] = True
        values["pods"]["items"][0]["spec"]["hostNetwork"] = True
        with self.assertRaises(OPS.OpsError):
            OPS.validate(**values)
        values = snapshots()
        values["manifest"]["spec"]["parallelism"] = True
        with self.assertRaises(OPS.OpsError):
            OPS.validate(**values)

    def test_snapshots_private_and_not_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "snapshot.json"
            path.write_text('{"safe":true}')
            path.chmod(0o600)
            self.assertEqual(OPS.read_json(path), {"safe": True})
            path.chmod(0o644)
            with self.assertRaises(OPS.OpsError):
                OPS.read_json(path)
            link = Path(directory) / "link.json"
            link.symlink_to(path)
            with self.assertRaises(OSError):
                OPS.read_json(link)

    def test_audit_receipt_preserves_original_response_and_empty_native_inventory(self):
        values = recovery_snapshots()
        before = copy.deepcopy(values)
        result = OPS.audit_receipt(**values)
        self.assertEqual(values, before)
        self.assertIs(result["pods"], values["pods"])
        self.assertEqual(result["pods"]["items"], [])
        self.assertIs(result["archived_terminal_pod"], values["audit"][0]["protoPayload"]["response"])
        self.assertNotIn("audit", result)
        # The same empty inventory without archive evidence still fails closed.
        with self.assertRaises(OPS.AUTH.AuthSlotError):
            OPS.AUTH.terminal_job_evidence({k: v for k, v in result.items() if k != "archived_terminal_pod"},
                                          {"job_uid": JOB_UID, "pod_uid": POD_UID})

    def test_audit_provenance_cannot_be_substituted(self):
        mutations = [
            lambda e: e.update(logName="projects/other/logs/cloudaudit.googleapis.com%2Factivity"),
            lambda e: e["resource"].update(type="gce_instance"),
            lambda e: e["resource"]["labels"].update(project_id="other"),
            lambda e: e["resource"]["labels"].update(cluster_name="other"),
            lambda e: e["resource"]["labels"].update(location="us-east1-b"),
            lambda e: e["protoPayload"].update(serviceName="other"),
            lambda e: e["protoPayload"].update(methodName="io.k8s.core.v1.pods.delete"),
            lambda e: e["protoPayload"].update(resourceName="core/v1/namespaces/other/pods/symphony-pilot-test"),
            lambda e: e["protoPayload"].update(status={"code": 7}),
            lambda e: e["protoPayload"].update(status={}),
            lambda e: e["protoPayload"]["response"].pop("@type"),
            lambda e: e["protoPayload"].update(response={"kind": "Patch"}),
        ]
        for mutate in mutations:
            values = recovery_snapshots()
            mutate(values["audit"][0])
            with self.subTest(mutate=mutate), self.assertRaises(OPS.OpsError):
                OPS.audit_receipt(**values)

    def test_audit_recovery_requires_exact_prior_admission(self):
        for key in ("container_id", "pod_uid", "pod_name", "image", "container", "namespace", "namespace_uid", "pvc_uid", "job_uid"):
            values = recovery_snapshots()
            values["admission"][key] = "changed"
            with self.subTest(key=key), self.assertRaises(OPS.OpsError):
                OPS.audit_receipt(**values)

    def test_archive_cannot_hide_current_or_unlisted_pods(self):
        for mutate in (
            lambda v: v["pods"]["items"].append(copy.deepcopy(v["audit"][0]["protoPayload"]["response"])),
            lambda v: v["pods"]["metadata"].update({"continue": "next"}),
            lambda v: v["pods"]["metadata"].pop("resourceVersion"),
            lambda v: v["pods"].update(kind="List"),
            lambda v: v.update(audit=[]),
            lambda v: v["audit"].append(copy.deepcopy(v["audit"][0])),
        ):
            values = recovery_snapshots()
            mutate(values)
            with self.assertRaises(OPS.OpsError):
                OPS.audit_receipt(**values)

    def test_archive_rejects_modified_container_or_incomplete_stop(self):
        for mutate in (
            lambda p: p["metadata"].update(uid=PVC_UID),
            lambda p: p["metadata"].update(deletionTimestamp="2026-09-15T00:01:01Z"),
            lambda p: p["spec"].update(hostNetwork=True),
            lambda p: p["status"].update(phase="Unknown"),
            lambda p: p["status"].update(reason="NodeLost"),
            lambda p: p["status"]["containerStatuses"][0].update(restartCount=1),
            lambda p: p["status"]["containerStatuses"][0].update(containerID="containerd://replacement"),
            lambda p: p["status"]["containerStatuses"][0].update(imageID="sha256:" + "c" * 64),
            lambda p: p["status"]["containerStatuses"][0]["state"]["terminated"].update(reason="ContainerStatusUnknown"),
            lambda p: p["status"]["containerStatuses"][0]["state"]["terminated"].pop("finishedAt"),
        ):
            values = recovery_snapshots()
            mutate(values["audit"][0]["protoPayload"]["response"])
            with self.assertRaises((OPS.OpsError, OPS.AUTH.AuthSlotError)):
                OPS.audit_receipt(**values)

    def test_archive_rejects_retry_and_terminal_accounting_uncertainty(self):
        for mutate in (
            lambda j: j["spec"].update(backoffLimit=1),
            lambda j: j["spec"].update(parallelism=2),
            lambda j: j["spec"].update(completions=2),
            lambda j: j["spec"].update(podReplacementPolicy="TerminatingOrFailed"),
            lambda j: j["status"].update(active=1),
            lambda j: j["status"].update(terminating=1),
            lambda j: j["status"].update(failed=2),
            lambda j: j["status"].update(succeeded=1),
            lambda j: j["status"].update(uncountedTerminatedPods={"failed": [POD_UID]}),
            lambda j: j["status"].update(conditions=[]),
        ):
            values = recovery_snapshots()
            mutate(values["job"])
            with self.assertRaises((OPS.OpsError, OPS.AUTH.AuthSlotError)):
                OPS.audit_receipt(**values)

    def test_archive_timestamps_must_describe_actual_past_termination(self):
        for mutate in (
            lambda v: v["audit"][0].update(timestamp="2026-09-15T00:00:59Z"),
            lambda v: v["audit"][0].update(receiveTimestamp="2026-09-15T00:00:59Z"),
            lambda v: v["audit"][0].update(timestamp="2099-01-01T00:00:00Z"),
            lambda v: v["audit"][0].update(timestamp="invalid"),
            lambda v: v["job"]["status"]["conditions"][0].update(lastTransitionTime="2026-09-15T00:00:59Z"),
            lambda v: v["audit"][0]["protoPayload"]["response"]["status"]["containerStatuses"][0]["state"]["terminated"].update(startedAt="1970-01-01T00:00:00Z"),
        ):
            values = recovery_snapshots()
            mutate(values)
            with self.assertRaises((OPS.OpsError, OPS.AUTH.AuthSlotError)):
                OPS.audit_receipt(**values)


if __name__ == "__main__":
    unittest.main()
