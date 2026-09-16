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


if __name__ == "__main__":
    unittest.main()
