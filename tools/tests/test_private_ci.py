"""Prevent CI routing changes from granting job access to cluster or app state."""

import ipaddress
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
CI = ROOT / "deploy/ci"


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
        self.assertEqual(spec["nodeSelector"], {"node-restriction.kubernetes.io/workload": "symphony-ci"})
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

    def test_control_and_job_namespaces_have_distinct_privileges(self):
        self.assertEqual(self.controller["flags"]["watchSingleNamespace"], "symphony-ci-runners")
        self.assertEqual(self.runner["controllerServiceAccount"], {"namespace": "symphony-ci-system", "name": "symphony-ci-controller"})
        self.assertEqual(self.runner["githubConfigSecret"], "symphony-ci-github-app")
        self.assertEqual(self.runner["githubConfigUrl"], "https://github.com/iliazlobin/symphony")
        for trusted in (self.controller, self.runner["listenerTemplate"]["spec"]):
            self.assertEqual(trusted["nodeSelector"], {"node-restriction.kubernetes.io/workload": "symphony-services"})
            self.assertEqual(trusted["tolerations"], [{"key": "workload", "operator": "Equal", "value": "symphony-services", "effect": "NoSchedule"}])
            self.assertNotIn("runtimeClassName", trusted)
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
            self.assertEqual(job["runs-on"], "symphony-ci")
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
                self.assertEqual(job["runs-on"], "${{ (" + predicate + ") && 'symphony-ci' || 'ubuntu-latest' }}")
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
        for policy, api_status, permits_gke in cases:
            with self.subTest(policy=policy, api_status=api_status), tempfile.TemporaryDirectory() as root:
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
                result = subprocess.run([str(CI / "install.sh"), image], env=env,
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

    def test_image_version_guards_reject_process_failure_after_matching_output(self):
        dockerfile = (CI / "Dockerfile").read_text()
        # Execute the real shell guards with disposable commands that can emit
        # the expected version before failing; grep alone masks that failure.
        guard = "node_version=" + dockerfile.split("&& node_version=", 1)[1].split("&& erl -noshell", 1)[0]
        guard = guard.replace("\\\n", " ").strip().removesuffix("&&").strip()
        for node_exit, elixir_exit in ((0, 0), (139, 0), (0, 139)):
            with self.subTest(node_exit=node_exit, elixir_exit=elixir_exit), tempfile.TemporaryDirectory() as root:
                root = Path(root)
                for name, version, status in (("node", "v22.14.0", node_exit),
                                               ("elixir", "Elixir 1.19.5", elixir_exit)):
                    executable = root / name
                    executable.write_text(f"#!/bin/sh\nprintf '%s\\n' '{version}'\nexit {status}\n")
                    executable.chmod(0o700)
                env = {"PATH": str(root) + os.pathsep + os.defpath, "LANG": "C"}
                result = subprocess.run(["/bin/sh", "-c", guard], env=env,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, node_exit == elixir_exit == 0)


if __name__ == "__main__":
    unittest.main()
