"""Prevent CI routing changes from granting job access to cluster or app state."""

import copy
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
CI = ROOT / "deploy/ci"
spec = importlib.util.spec_from_file_location("verify_arc_crds", CI / "verify_arc_crds.py")
crds = importlib.util.module_from_spec(spec)
spec.loader.exec_module(crds)
spec = importlib.util.spec_from_file_location("render_controller", CI / "render_controller.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


def crd_fixture():
    return {"apiVersion": "v1", "kind": "List", "items": [
        {"apiVersion": "apiextensions.k8s.io/v1", "kind": "CustomResourceDefinition",
         "metadata": {"name": name},
         "spec": {"group": "actions.github.com", "scope": "Namespaced",
                  "names": {"plural": name.split(".")[0], "kind": "Example"},
                  "versions": [{"name": "v1alpha1", "served": True, "storage": True,
                                "schema": {"openAPIV3Schema": {"type": "object"}}}]},
         "status": {"storedVersions": ["v1alpha1"], "conditions": [
             {"type": "Established", "status": "True"},
             {"type": "NamesAccepted", "status": "True"}]}}
        for name in sorted(crds.CRD_NAMES)]}


class PrivateCITests(unittest.TestCase):
    def setUp(self):
        self.runner = yaml.safe_load((CI / "runner-values.yaml").read_text())
        self.controller = yaml.safe_load((CI / "controller-values.yaml").read_text())
        self.resources = list(yaml.safe_load_all((CI / "foundation.yaml").read_text()))

    def test_job_has_no_cluster_identity_or_persistent_mounts(self):
        spec = self.runner["template"]["spec"]
        self.assertFalse(spec["automountServiceAccountToken"])
        self.assertEqual(spec["serviceAccountName"], "symphony-ci-job")
        self.assertEqual(spec["runtimeClassName"], "gvisor")
        self.assertNotIn("containerMode", self.runner)
        self.assertEqual(spec["nodeSelector"], {"node-restriction.kubernetes.io/workload": "platform-ci"})
        self.assertIn({"key": "workload", "operator": "Equal", "value": "platform-ci", "effect": "NoSchedule"}, spec["tolerations"])
        self.assertFalse(any(spec.get(key) for key in ("hostPID", "hostIPC", "hostNetwork")))
        self.assertLessEqual(spec["activeDeadlineSeconds"], 3600)
        self.assertTrue(all(set(volume) == {"name", "emptyDir"} for volume in spec["volumes"]))
        sa = next(r for r in self.resources if r["kind"] == "ServiceAccount")
        self.assertFalse(sa["automountServiceAccountToken"])
        self.assertFalse(sa["metadata"].get("annotations"))
        self.assertFalse(any(r["kind"] in ("RoleBinding", "ClusterRoleBinding", "PersistentVolumeClaim", "Secret") for r in self.resources))
        for container in spec["initContainers"] + spec["containers"]:
            security = container["securityContext"]
            self.assertFalse(security["allowPrivilegeEscalation"])
            self.assertTrue(security["readOnlyRootFilesystem"])
            self.assertEqual(security["capabilities"], {"drop": ["ALL"]})
            self.assertFalse(security.get("privileged"))
            self.assertFalse(container.get("envFrom"))
            self.assertFalse(any("valueFrom" in e for e in container.get("env", [])))
        self.assertEqual(spec["containers"][0]["resources"]["requests"]["cpu"], "2")
        self.assertEqual(spec["containers"][0]["resources"]["requests"]["memory"], "6Gi")

    def test_control_and_job_namespaces_have_distinct_privileges(self):
        self.assertEqual(self.controller["flags"]["watchSingleNamespace"], "symphony-ci-runners")
        self.assertEqual(self.runner["controllerServiceAccount"], {"namespace": "symphony-ci-system", "name": "symphony-ci-controller"})
        self.assertEqual(self.runner["githubConfigSecret"], "symphony-ci-github-app")
        self.assertEqual(self.runner["githubConfigUrl"], "https://github.com/iliazlobin/symphony")
        self.assertEqual(self.runner["runnerScaleSetName"], "symphony-linux")
        self.assertEqual(self.runner["listenerTemplate"]["spec"]["nodeSelector"], {"cloud.google.com/gke-nodepool": "shared-dev"})
        for namespace in (r for r in self.resources if r["kind"] == "Namespace"):
            self.assertEqual(namespace["metadata"]["labels"]["pod-security.kubernetes.io/enforce"], "restricted")

    def test_public_https_never_allows_private_or_metadata_destinations(self):
        policies = [r for r in self.resources if r["kind"] == "NetworkPolicy" and r["metadata"]["namespace"] == "symphony-ci-runners"]
        # Policies are additive; another allow rule could undo the intended boundary.
        self.assertEqual({p["metadata"]["name"] for p in policies},
                         {"default-deny", "dns-and-public-https"})
        self.assertEqual(len(policies), 2)
        deny = next(p for p in policies if p["metadata"]["name"] == "default-deny")
        self.assertEqual(set(deny["spec"]["policyTypes"]), {"Ingress", "Egress"})
        self.assertFalse(any(p["spec"].get("ingress") for p in policies))
        allow = next(p for p in policies if p["metadata"]["name"] == "dns-and-public-https")
        self.assertEqual(allow["spec"]["podSelector"], {"matchLabels": {"symphony-ci-role": "runner"}})
        for destination in ("10.48.0.1", "10.40.0.2", "169.254.169.254", "172.16.0.1", "192.168.1.1", "100.64.0.1"):
            address = ipaddress.ip_address(destination)
            for rule in allow["spec"]["egress"]:
                for port in rule["ports"]:
                    if port["port"] == 53:
                        continue
                    self.assertEqual(port, {"protocol": "TCP", "port": 443})
                    for peer in rule["to"]:
                        block = peer["ipBlock"]
                        permitted = address in ipaddress.ip_network(block["cidr"]) and not any(address in ipaddress.ip_network(excluded) for excluded in block.get("except", []))
                        self.assertFalse(permitted, destination)

    def test_concurrency_and_storage_are_bounded(self):
        self.assertEqual((self.runner["minRunners"], self.runner["maxRunners"]), (0, 1))
        quota = next(r for r in self.resources if r["kind"] == "ResourceQuota")["spec"]["hard"]
        self.assertEqual(quota["pods"], "1")
        self.assertEqual(quota["persistentvolumeclaims"], "0")
        self.assertEqual(quota["services.loadbalancers"], "0")
        self.assertEqual(quota["services.nodeports"], "0")

    def test_pilot_is_opt_in_and_required_coverage_is_preserved(self):
        pilot = yaml.safe_load((ROOT / ".github/workflows/private-ci-smoke.yml").read_text())
        # PyYAML's YAML 1.1 loader interprets the GitHub `on` key as True.
        self.assertEqual(pilot.get("on", pilot.get(True)), {"workflow_dispatch": None})
        self.assertEqual(pilot["permissions"], {"contents": "read"})
        self.assertEqual(pilot["jobs"]["clean-replacement"]["needs"], "isolated-runner")
        for job in pilot["jobs"].values():
            self.assertEqual(job["runs-on"], "symphony-linux")
            self.assertNotIn("container", job)
            self.assertNotIn("services", job)
            checkout = next(s for s in job["steps"] if s.get("uses", "").startswith("actions/checkout@"))
            self.assertFalse(checkout["with"]["persist-credentials"])
        for filename, name in (("make-all.yml", "make-all"), ("pr-description-lint.yml", "validate-pr-description")):
            workflow = yaml.safe_load((ROOT / ".github/workflows" / filename).read_text())
            job = workflow["jobs"][name]
            # Bootstrap is hosted. A later routing change must retain a hosted
            # path for forks and Dependabot; unconditional private routing fails.
            if job["runs-on"] != "ubuntu-latest":
                same_repo = ("github.event_name == 'pull_request' && "
                             "github.event.pull_request.head.repo.full_name == github.repository && "
                             "github.actor != 'dependabot[bot]' && "
                             "github.event.pull_request.user.login != 'dependabot[bot]'")
                predicate = ("(github.event_name == 'push' && github.ref == 'refs/heads/main') || (" + same_repo + ")"
                             if filename == "make-all.yml" else same_repo)
                self.assertEqual(job["runs-on"], "${{ (" + predicate + ") && 'symphony-linux' || 'ubuntu-latest' }}")
                mise = next(s for s in job["steps"] if s.get("uses", "").startswith("jdx/mise-action@"))
                self.assertEqual(mise["if"], "runner.environment == 'github-hosted'")
                probe = next(s for s in job["steps"] if s.get("run") == "python3 deploy/ci/probe_runner.py")
                self.assertEqual(probe["if"], "runner.environment == 'self-hosted'")
            self.assertNotIn("container", job)
            self.assertNotIn("services", job)
        make = (ROOT / ".github/workflows/make-all.yml").read_text()
        for command in ("make all", "npm ci --ignore-scripts", "npm run check", "unittest discover -s tools/tests -v"):
            self.assertIn(command, make)
        release = yaml.safe_load((ROOT / ".github/workflows/burrito-release.yml").read_text())
        targets = {m["target"] for m in release["jobs"]["smoke"]["strategy"]["matrix"]["include"]}
        self.assertEqual(targets, {"linux_x86_64", "linux_arm64", "macos_x86_64", "macos_arm64"})

    def test_install_rejects_weaker_or_unverifiable_fork_approval_before_gke(self):
        image = "us-west1-docker.pkg.dev/iz27-platform-dev/symphony/ci-runner@sha256:" + "a" * 64
        cases = (("first_time_contributors", 0, False),
                 ("first_time_contributors_new_to_github", 0, False),
                 ("", 0, False), ("all_external_contributors", 1, False),
                 ("all_external_contributors", 0, True))
        for mode, (policy, api_status, permits_gke) in ((mode, case) for mode in ("--prepare", image) for case in cases):
            with self.subTest(mode=mode, policy=policy, api_status=api_status), tempfile.TemporaryDirectory() as root:
                root = Path(root)
                trace = root / "commands"
                # These fixtures cannot invoke GitHub, Helm or the cluster.
                gh = root / "gh"
                gh.write_text("#!/bin/sh\nprintf 'gh\\n' >> \"$CI_PREFLIGHT_TRACE\"\n"
                              "printf '%s\\n' \"$@\" > \"$CI_PREFLIGHT_ARGS\"\n"
                              "printf '%s\\n' \"$CI_PREFLIGHT_POLICY\"\n"
                              "exit \"$CI_PREFLIGHT_API_STATUS\"\n")
                gh.chmod(0o700)
                for command in ("kubectl", "helm"):
                    fixture = root / command
                    fixture.write_text(f"#!/bin/sh\nprintf '{command}\\n' >> \"$CI_PREFLIGHT_TRACE\"\nexit 90\n")
                    fixture.chmod(0o700)
                args_path = root / "gh-args"
                env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                       "CI_PREFLIGHT_TRACE": str(trace), "CI_PREFLIGHT_ARGS": str(args_path),
                       "CI_PREFLIGHT_POLICY": policy, "CI_PREFLIGHT_API_STATUS": str(api_status)}
                result = subprocess.run([str(CI / "install.sh"), mode], env=env,
                                        capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(trace.read_text().splitlines(), ["gh", "kubectl"] if permits_gke else ["gh"])
                self.assertEqual(args_path.read_text().splitlines(),
                                 ["api", "--hostname", "github.com",
                                  "repos/iliazlobin/symphony/actions/permissions/fork-pr-contributor-approval",
                                  "--jq", ".approval_policy"])
                if not permits_gke:
                    self.assertIn("approval", result.stderr)

    def test_build_and_chart_inputs_have_immutable_pins(self):
        versions = json.loads((CI / "versions.json").read_text())
        dockerfile = (CI / "Dockerfile").read_text()
        for key in ("runner_archive_sha256", "node_archive_sha256"):
            self.assertIn("ADD --checksum=sha256:" + versions[key], dockerfile)
        self.assertIn("@sha256:", dockerfile)
        self.assertIn("USER 1001:1001", dockerfile)
        self.assertNotIn("COPY ", dockerfile)
        self.assertIn("sha256:", self.controller["image"]["tag"])
        for chart in versions["charts"].values():
            self.assertRegex(chart["oci_digest"], r"^sha256:[0-9a-f]{64}$")
            self.assertRegex(chart["archive_sha256"], r"^[0-9a-f]{64}$")
        install = (CI / "install.sh").read_text()
        self.assertIn("hashlib.sha256", install)
        self.assertNotIn("--from-literal", install)
        self.assertNotIn("--from-file", install)

    def test_shared_crd_verification_accepts_only_api_defaults(self):
        expected = crd_fixture()
        live = copy.deepcopy(expected)
        for item in live["items"]:
            item["spec"].update(conversion={"strategy": "None"}, preserveUnknownFields=False)
            item["metadata"].update(resourceVersion="123", annotations={"owner": "foundation"})
        crds.verify(expected, live)
        for change in ("schema", "served", "storage", "conversion", "unknown", "stored", "unhealthy", "deleting", "missing", "duplicate"):
            with self.subTest(change=change):
                bad = copy.deepcopy(live)
                item = bad["items"][0]
                if change == "schema":
                    item["spec"]["versions"][0]["schema"]["openAPIV3Schema"]["type"] = "string"
                elif change in ("served", "storage"):
                    item["spec"]["versions"][0][change] = False
                elif change == "conversion":
                    item["spec"]["conversion"] = {"strategy": "Webhook"}
                elif change == "unknown":
                    item["spec"]["preserveUnknownFields"] = True
                elif change == "stored":
                    item["status"]["storedVersions"].append("v1alpha2")
                elif change == "unhealthy":
                    item["status"]["conditions"][0]["status"] = "False"
                elif change == "deleting":
                    item["metadata"]["deletionTimestamp"] = "2026-10-05T00:00:00Z"
                elif change == "missing":
                    bad["items"].pop()
                elif change == "duplicate":
                    bad["items"].append(copy.deepcopy(item))
                with self.assertRaises(ValueError):
                    crds.verify(expected, bad)

    def test_shared_crd_reader_handles_kubectl_stream_and_list(self):
        document = crd_fixture()
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "crds.json"
            for content in (json.dumps(document), "\n".join(json.dumps(item, indent=2) for item in document["items"])):
                path.write_text(content)
                crds.verify(document, crds.read_document(path))
            for content in ("", "null", "{", json.dumps({"items": None}),
                            json.dumps(document) + json.dumps(document["items"][0])):
                path.write_text(content)
                with self.assertRaises(ValueError):
                    crds.verify(document, crds.read_document(path))

    def test_controller_render_avoids_surge_and_preserves_other_objects(self):
        deployment = {"apiVersion": "apps/v1", "kind": "Deployment",
                      "metadata": {"name": "symphony-ci-controller", "namespace": "symphony-ci-system"},
                      "spec": {"replicas": 1, "strategy": {"type": "RollingUpdate", "rollingUpdate": {"maxSurge": "25%"}},
                               "template": {"spec": {"containers": [{"name": "manager", "resources": {"requests": {"cpu": "100m"}}}]}}}}
        role = {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "Role",
                "metadata": {"name": "scoped", "namespace": "symphony-ci-runners"}, "rules": [{"verbs": ["get"]}]}
        for content in (json.dumps({"items": [deployment, role]}), json.dumps(deployment) + "\n" + json.dumps(role)):
            rendered = list(yaml.safe_load_all(renderer.render(content, "symphony-ci-controller", "symphony-ci-system")))
            self.assertEqual(rendered[0]["spec"]["strategy"], {"type": "Recreate"})
            self.assertEqual(rendered[0]["spec"]["template"], deployment["spec"]["template"])
            self.assertEqual(rendered[1], role)
        for documents in ([], [role], [deployment, deployment], [dict(deployment, metadata={"name": "other", "namespace": "symphony-ci-system"})]):
            with self.assertRaises(ValueError):
                renderer.render(json.dumps({"items": documents}), "symphony-ci-controller", "symphony-ci-system")
        install = (CI / "install.sh").read_text()
        self.assertIn('--post-renderer "$ci_dir/controller-post-renderer.sh"', install)
        self.assertIn('--post-renderer-args symphony-ci-controller --post-renderer-args symphony-ci-system', install)

    def test_controller_renderer_stops_on_failed_client_decode(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixture = root / "kubectl"
            fixture.write_text("#!/bin/sh\ncat >/dev/null\nexit 60\n")
            fixture.chmod(0o700)
            result = subprocess.run([str(CI / "controller-post-renderer.sh"), "symphony-ci-controller", "symphony-ci-system"],
                                    input="unparsed Helm output", capture_output=True, text=True, timeout=10,
                                    env={**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"]})
            self.assertEqual(result.returncode, 60)
            self.assertEqual(result.stdout, "")

    def test_shared_crd_mismatch_stops_install_before_mutations(self):
        image = "us-west1-docker.pkg.dev/iz27-platform-dev/symphony/ci-runner@sha256:" + "a" * 64
        for mode, matches in ((mode, matches) for mode in ("--prepare", image) for matches in (False, True)):
            with self.subTest(mode=mode, matches=matches), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                package = root / "ci"
                shutil.copytree(CI, package)
                chart = root / "chart.tgz"
                chart.write_bytes(b"offline test chart")
                versions = json.loads((package / "versions.json").read_text())
                for values in versions["charts"].values():
                    values["archive_sha256"] = hashlib.sha256(chart.read_bytes()).hexdigest()
                (package / "versions.json").write_text(json.dumps(versions))
                expected = crd_fixture()
                live = copy.deepcopy(expected)
                if not matches:
                    live["items"][0]["spec"]["versions"][0]["served"] = False
                (root / "expected.json").write_text(json.dumps(expected))
                (root / "live.json").write_text(json.dumps(live))
                fixtures = {
                    "gh": "printf 'all_external_contributors\\n'\n",
                    "helm": "case \"$1\" in\n"
                            "pull) for destination do :; done; name=${2##*/}; cp \"$CI_TEST_ROOT/chart.tgz\" \"$destination/$name-0.15.0.tgz\";;\n"
                            "show) printf '# fixture CRDs\\n';;\n"
                            "upgrade) printf 'upgrade %s\\n' \"$*\" >> \"$CI_TEST_ROOT/mutations\";;\n"
                            "*) exit 91;; esac\n",
                    "kubectl": "case \"$*\" in\n"
                               "'config current-context') printf 'gke_iz27-platform-dev_us-west1-a_platform-dev';;\n"
                               "'-n default get service kubernetes'*) printf '10.48.0.1';;\n"
                               "'-n kube-system get service kube-dns'*) printf '10.48.0.10';;\n"
                               "'create --dry-run=client --validate=false'*) cat \"$CI_TEST_ROOT/expected.json\";;\n"
                               "'get -f'*) cat \"$CI_TEST_ROOT/live.json\";;\n"
                               "'apply -f'*) printf 'apply\\n' >> \"$CI_TEST_ROOT/mutations\";;\n"
                               "'-n symphony-ci-runners get secret symphony-ci-github-app'*) printf 'secret-read\\n' >> \"$CI_TEST_ROOT/secret-queries\"; printf 'symphony-ci-github-app';;\n"
                               "'-n symphony-ci-system get deployments,pods'|'-n symphony-ci-runners get autoscalingrunnersets,pods') :;;\n"
                               "*) exit 92;; esac\n",
                }
                for name, content in fixtures.items():
                    path = root / name
                    path.write_text("#!/bin/sh\nset -eu\n" + content)
                    path.chmod(0o700)
                env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"], "CI_TEST_ROOT": str(root)}
                result = subprocess.run([str(package / "install.sh"), mode], env=env,
                                        capture_output=True, text=True, timeout=10)
                mutation = root / "mutations"
                if matches:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    changes = mutation.read_text().splitlines()
                    self.assertEqual(changes[0], "apply")
                    if mode == "--prepare":
                        self.assertEqual(changes, ["apply"])
                        self.assertFalse((root / "secret-queries").exists())
                    else:
                        self.assertEqual(len(changes), 3)
                        self.assertTrue(all("--skip-crds" in line for line in changes[1:]))
                        self.assertIn("--post-renderer", changes[1])
                        self.assertIn("--install symphony-linux", changes[2])
                        self.assertEqual((root / "secret-queries").read_text(), "secret-read\n")
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Shared ARC CRD", result.stderr)
                    self.assertFalse(mutation.exists())


if __name__ == "__main__":
    unittest.main()
