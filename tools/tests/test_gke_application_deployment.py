import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import yaml


ROOT = Path(__file__).resolve().parents[2]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


renderer = load_module("gke_application_deployment", ROOT / "deploy/gke/application/render.py")
entrypoint = load_module("gke_application_deployment_entrypoint", ROOT / "deploy/gke/application_entrypoint.py")


class ApplicationDeploymentTests(unittest.TestCase):
    def setUp(self):
        self.common = {
            "hostname": "symphony.iliazlobin.com", "project_number": "123456789012",
            "iap_client_id": "123456789012-testpublicclient.apps.googleusercontent.com",
        }
        self.activation = {
            **self.common,
            "image": renderer.IMAGE_PREFIX + hashlib.sha256(b"test-reviewed-image").hexdigest(),
            "source_revision": hashlib.sha1(b"test-reviewed-source").hexdigest(),
            "iap_audience": "/projects/123456789012/global/backendServices/9876543210987654321",
        }

    def objects(self, stage="activate", **changes):
        parameters = dict(self.common if stage == "bootstrap" else self.activation)
        parameters.update(changes)
        return renderer.render(stage, **parameters)["items"]

    def one(self, kind, stage="activate"):
        matches = [item for item in self.objects(stage) if item["kind"] == kind]
        self.assertEqual(len(matches), 1)
        return matches[0]

    def workflow_config(self):
        text = self.one("ConfigMap")["data"]["WORKFLOW.md"]
        return yaml.safe_load(text.split("---\n")[1])

    def test_bootstrap_creates_no_endpoints_workloads_state_or_credentials(self):
        items = self.objects("bootstrap")
        self.assertEqual({item["kind"] for item in items},
                         {"Service", "Gateway", "HTTPRoute", "GCPBackendPolicy", "GCPGatewayPolicy", "HealthCheckPolicy"})
        self.assertEqual(len(items), 6)
        service = self.one("Service", "bootstrap")["spec"]
        self.assertEqual(service["type"], "ClusterIP")
        self.assertEqual(service["selector"], renderer.POD_SELECTOR)
        self.assertNotIn("externalIPs", service)
        self.assertNotIn("nodePort", service["ports"][0])
        self.assertNotIn("image", json.dumps(items))

    def test_both_stages_bind_exact_https_host_certificate_iap_and_health_to_one_service(self):
        for stage in ("bootstrap", "activate"):
            with self.subTest(stage=stage):
                gateway = self.one("Gateway", stage)
                self.assertEqual(gateway["metadata"]["annotations"],
                                 {"networking.gke.io/certmap": "symphony-web-cert-map"})
                self.assertEqual(gateway["spec"]["gatewayClassName"], "gke-l7-global-external-managed")
                self.assertEqual(gateway["spec"]["addresses"], [{"type": "NamedAddress", "value": "symphony-web-ip"}])
                listeners = gateway["spec"]["listeners"]
                self.assertEqual(len(listeners), 1)
                self.assertEqual((listeners[0]["protocol"], listeners[0]["port"], listeners[0]["hostname"]),
                                 ("HTTPS", 443, self.common["hostname"]))
                self.assertNotIn("tls", listeners[0])
                self.assertEqual(listeners[0]["allowedRoutes"]["namespaces"], {"from": "Same"})
                frontend = self.one("GCPGatewayPolicy", stage)["spec"]
                self.assertEqual(frontend["default"], {"sslPolicy": "symphony-web-tls"})
                self.assertEqual(frontend["targetRef"], {"group": "gateway.networking.k8s.io",
                                 "kind": "Gateway", "name": renderer.APPLICATION})
                route = self.one("HTTPRoute", stage)["spec"]
                self.assertEqual(route["parentRefs"], [{"name": renderer.APPLICATION, "sectionName": "https"}])
                self.assertEqual(route["hostnames"], [self.common["hostname"]])
                self.assertEqual(route["rules"][0]["backendRefs"], [{"name": renderer.APPLICATION, "port": 80}])
                self.assertNotIn("filters", route["rules"][0])
                backend = self.one("GCPBackendPolicy", stage)["spec"]
                self.assertEqual(backend["default"]["iap"], {
                    "enabled": True, "clientID": self.common["iap_client_id"],
                    "oauth2ClientSecret": {"name": "symphony-iap-oauth"},
                })
                health = self.one("HealthCheckPolicy", stage)["spec"]
                self.assertEqual(backend["targetRef"], health["targetRef"])
                self.assertEqual(health["targetRef"], {"group": "", "kind": "Service", "name": renderer.APPLICATION})
                check = health["default"]["config"]["httpHealthCheck"]
                self.assertEqual((check["port"], check["requestPath"], check["response"], check["host"]),
                                 (8080, "/healthz", "ok", self.common["hostname"]))

    def test_activation_rejects_missing_tagged_wrong_registry_or_placeholder_images(self):
        invalid = [None, "", "application:latest", renderer.IMAGE_PREFIX.replace("@sha256:", ":latest"),
                   renderer.IMAGE_PREFIX + "0" * 64, renderer.IMAGE_PREFIX + "G" * 64,
                   self.activation["image"].replace("/application@", "/worker@"),
                   self.activation["image"].replace("iz27-platform-dev", "another-project")]
        for image in invalid:
            with self.subTest(image=image), self.assertRaises(renderer.ConfigurationError):
                self.objects(image=image)

    def test_activation_rejects_audience_with_wrong_project_names_region_or_unresolved_environment(self):
        invalid = [None, "", "$IAP_AUDIENCE", "/projects/999/global/backendServices/123",
                   "/projects/123456789012/global/backendServices/name", "/projects/123456789012/regions/us-west1/backendServices/123",
                   "/projects/123456789012/global/backendServices/0", self.activation["iap_audience"] + "/",
                   self.activation["iap_audience"] + "\n"]
        for audience in invalid:
            with self.subTest(audience=audience), self.assertRaises(renderer.ConfigurationError):
                self.objects(iap_audience=audience)

    def test_activation_requires_reviewable_revision(self):
        for revision in (None, "", "main", "0" * 40, "a" * 39, "A" * 40, "a" * 40 + "\n"):
            with self.subTest(revision=revision), self.assertRaises(renderer.ConfigurationError):
                self.objects(source_revision=revision)

    def test_bootstrap_rejects_any_activation_parameters(self):
        for name in ("image", "source_revision", "iap_audience"):
            with self.subTest(name=name), self.assertRaises(renderer.ConfigurationError):
                self.objects("bootstrap", **{name: self.activation[name]})

    def test_public_parameter_validation_rejects_wildcard_host_urls_secrets_and_project_names(self):
        invalid = {
            "hostname": ["*.iliazlobin.com", "other.iliazlobin.com", "https://symphony.iliazlobin.com", "localhost",
                         "symphony.iliazlobin.com:443", "symphony.iliazlobin.com\n"],
            "project_number": [None, 123, "iz27-platform-dev", "0123", "0", "123\n"],
            "iap_client_id": [None, "client-secret", "123-test.apps.googleusercontent.com\n", "$OAUTH_CLIENT_ID"],
        }
        for name, values in invalid.items():
            for value in values:
                with self.subTest(name=name, value=value), self.assertRaises(renderer.ConfigurationError):
                    self.objects("bootstrap", **{name: value})

    def test_all_resources_are_application_scoped_and_do_not_adopt_pilot_state(self):
        items = self.objects()
        identities = [(item["kind"], item["metadata"]["name"]) for item in items]
        self.assertEqual(len(identities), len(set(identities)))
        for item in items:
            self.assertEqual(item["metadata"]["namespace"], "symphony")
            self.assertTrue(item["metadata"]["name"].startswith(renderer.APPLICATION))
        self.assertFalse({"Namespace", "ServiceAccount", "Role", "RoleBinding", "Secret", "Job"} & {kind for kind, _ in identities})
        self.assertNotIn("symphony-journal", json.dumps(items))
        claim = self.one("PersistentVolumeClaim")["spec"]
        self.assertEqual(claim, {"accessModes": ["ReadWriteOncePod"], "storageClassName": "shared-retain",
                                 "resources": {"requests": {"storage": "10Gi"}}})

    def test_single_writer_recreate_pod_runs_packaged_application_without_privileged_identity(self):
        deployment = self.one("Deployment")["spec"]
        self.assertEqual(deployment["replicas"], 1)
        self.assertEqual(deployment["strategy"], {"type": "Recreate"})
        pod = deployment["template"]["spec"]
        self.assertEqual(pod["nodeSelector"], {"cloud.google.com/gke-nodepool": "shared-dev"})
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertFalse(pod["enableServiceLinks"])
        self.assertNotIn("serviceAccountName", pod)
        self.assertEqual(pod["securityContext"], {
            "runAsNonRoot": True, "runAsUser": 10001, "runAsGroup": 10001, "fsGroup": 10001,
            "fsGroupChangePolicy": "OnRootMismatch", "seccompProfile": {"type": "RuntimeDefault"},
        })
        self.assertEqual(len(pod["containers"]), 1)
        self.assertNotIn("initContainers", pod)
        container = pod["containers"][0]
        self.assertEqual(container["image"], self.activation["image"])
        self.assertNotIn("command", container)
        self.assertEqual(container["args"], ["serve", "--workflow", "/config/WORKFLOW.md", "--state-root", renderer.STATE_ROOT])
        self.assertEqual(container["securityContext"], {"allowPrivilegeEscalation": False,
                         "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}})
        volumes = pod["volumes"]
        self.assertEqual(volumes[0]["persistentVolumeClaim"]["claimName"], "symphony-application-state")
        self.assertEqual(volumes[1]["emptyDir"], {"sizeLimit": "1Gi"})
        self.assertNotIn("hostPath", json.dumps(volumes))
        self.assertEqual(container["resources"]["limits"]["memory"], "1Gi")

    def test_credentials_are_only_explicit_private_secret_references(self):
        container = self.one("Deployment")["spec"]["template"]["spec"]["containers"][0]
        self.assertNotIn("envFrom", container)
        references = {item["name"]: item["valueFrom"]["secretKeyRef"] for item in container["env"] if "valueFrom" in item}
        self.assertEqual(references, {
            "GITHUB_TOKEN": {"name": "symphony-application-secrets", "key": "github-token"},
            "SYMPHONY_CONTROL_TOKEN": {"name": "symphony-application-secrets", "key": "control-token"},
            "SYMPHONY_WORKSPACE_SECRET": {"name": "symphony-application-secrets", "key": "workspace-secret"},
        })
        self.assertNotIn("OPENAI_API_KEY", json.dumps(self.objects()))
        self.assertNotIn("CODEX_API_KEY", json.dumps(self.objects()))
        self.assertNotIn("client_secret", self.one("ConfigMap")["data"]["WORKFLOW.md"])

    def test_workflow_is_immutable_regular_file_and_changes_recreate_pod(self):
        first = self.one("ConfigMap")
        self.assertTrue(first["immutable"])
        second_items = self.objects(iap_audience="/projects/123456789012/global/backendServices/987654321")
        second = next(item for item in second_items if item["kind"] == "ConfigMap")
        self.assertNotEqual(first["metadata"]["name"], second["metadata"]["name"])
        pod = self.one("Deployment")["spec"]["template"]
        checksum = hashlib.sha256(first["data"]["WORKFLOW.md"].encode()).hexdigest()
        self.assertEqual(pod["metadata"]["annotations"]["symphony.dev/workflow-sha256"], checksum)
        self.assertEqual(pod["spec"]["volumes"][2]["configMap"]["name"], first["metadata"]["name"])
        mount = pod["spec"]["containers"][0]["volumeMounts"][2]
        self.assertEqual(mount, {"name": "workflow", "mountPath": "/config/WORKFLOW.md", "subPath": "WORKFLOW.md", "readOnly": True})

    def test_workflow_keeps_fresh_cloud_paths_paused_execution_and_single_user_iap(self):
        config = self.workflow_config()
        self.assertEqual(config["control"]["initial_mode"], "paused")
        self.assertTrue(config["control"]["enabled"])
        self.assertEqual(config["control"]["base_sha"], self.activation["source_revision"])
        self.assertEqual(config["codex"], {"command": "/bin/false"})
        self.assertEqual(config["hooks"], {})
        self.assertEqual(config["worker"]["ssh_hosts"], [])
        self.assertEqual(config["chat"]["max_concurrent"], 1)
        self.assertFalse(config["chat"]["auto_create_backlog"])
        self.assertEqual(config["browser_auth"], {
            "provider": "iap", "public_origin": "https://" + self.common["hostname"],
            "audience": self.activation["iap_audience"], "allowed_emails": ["iliazlobin91@gmail.com"],
        })
        paths = [config["control"]["state_path"], config["chat"]["state_path"],
                 config["chat"]["codex_home"], config["workspace"]["root"]]
        self.assertEqual(len(set(paths)), 4)
        self.assertTrue(all(path.startswith(renderer.STATE_ROOT + "/") for path in paths))
        self.assertNotIn("/Users/", json.dumps(config))

    def test_generated_workflow_passes_real_entrypoint_boundary_without_imported_state(self):
        config = copy.deepcopy(self.workflow_config())
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            state = directory / "state"
            state.mkdir()
            for mapping, key in (("control", "state_path"), ("workspace", "root"),
                                 ("chat", "state_path"), ("chat", "codex_home")):
                config[mapping][key] = config[mapping][key].replace(renderer.STATE_ROOT, str(state), 1)
            workflow = directory / "WORKFLOW.md"
            workflow.write_text("---\n" + yaml.safe_dump(config) + "---\nCloud test workflow.\n")
            with mock.patch.object(entrypoint.os.path, "ismount", return_value=True):
                _, _, paths = entrypoint.validate(str(workflow), str(state), {"GITHUB_TOKEN": "test-only"})
            self.assertFalse(paths["journal"].exists())
            self.assertFalse(paths["chat"].exists())
            self.assertFalse(paths["authentication"].exists())

    def test_policies_allow_only_app_lb_health_dns_and_public_https(self):
        policies = {item["metadata"]["name"]: item["spec"] for item in self.objects() if item["kind"] == "NetworkPolicy"}
        self.assertEqual(len(policies), 3)
        for policy in policies.values():
            self.assertEqual(policy["podSelector"], {"matchLabels": renderer.POD_SELECTOR})
        self.assertNotIn("ingress", policies[renderer.APPLICATION + "-deny"])
        self.assertNotIn("egress", policies[renderer.APPLICATION + "-deny"])
        ingress = policies[renderer.APPLICATION + "-ingress"]["ingress"]
        self.assertEqual(ingress, [{"from": [{"ipBlock": {"cidr": "35.191.0.0/16"}},
                                            {"ipBlock": {"cidr": "130.211.0.0/22"}}],
                                     "ports": [{"protocol": "TCP", "port": 8080}]}])
        dns, https = policies[renderer.APPLICATION + "-egress"]["egress"]
        self.assertEqual(dns["ports"], [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}])
        self.assertEqual(https["ports"], [{"protocol": "TCP", "port": 443}])
        exclusion = https["to"][0]["ipBlock"]["except"]
        for blocked in ("10.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16"):
            self.assertIn(blocked, exclusion)
        self.assertEqual(dns["to"][2:], [{"ipBlock": {"cidr": "10.48.0.10/32"}},
                                         {"ipBlock": {"cidr": "169.254.20.10/32"}}])

    def test_probes_return_only_health_check_path_and_exact_host(self):
        container = self.one("Deployment")["spec"]["template"]["spec"]["containers"][0]
        for name in ("startupProbe", "readinessProbe", "livenessProbe"):
            self.assertEqual(container[name]["httpGet"], {"path": "/healthz", "port": "http",
                             "httpHeaders": [{"name": "Host", "value": self.common["hostname"]}]})

    def test_cli_failure_outputs_no_partial_manifest_and_accepts_no_secret_argument(self):
        argv = ["activate", "--hostname", self.common["hostname"], "--project-number", self.common["project_number"],
                "--iap-client-id", self.common["iap_client_id"]]
        for additional in ([], ["--iap-client-secret", "test-only"]):
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                renderer.main(argv + additional)
            self.assertEqual(error.exception.code, 2)
            self.assertEqual(stdout.getvalue(), "")

    def test_cli_outputs_deterministic_kubernetes_list(self):
        output = io.StringIO()
        argv = ["bootstrap", "--hostname", self.common["hostname"], "--project-number", self.common["project_number"],
                "--iap-client-id", self.common["iap_client_id"]]
        with contextlib.redirect_stdout(output):
            renderer.main(argv)
        self.assertTrue(output.getvalue().endswith("\n"))
        self.assertEqual(json.loads(output.getvalue()), renderer.render("bootstrap", **self.common))


if __name__ == "__main__":
    unittest.main()
