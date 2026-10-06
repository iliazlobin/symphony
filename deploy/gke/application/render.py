#!/usr/bin/env python3
"""Render the reviewed Symphony application boundary; never contact the cluster.

Bootstrap contains no application workload. Activation requires the numeric IAP
backend audience and an immutable image from the Symphony Artifact Registry.
Secret values are delivered separately and cannot be supplied to this renderer.
"""

import argparse
import hashlib
import json
import re
import sys


NAMESPACE = "symphony"
APPLICATION = "symphony-application"
HOSTNAME = "symphony.iliazlobin.com"
ADDRESS = "symphony-web-ip"
CERTIFICATE_MAP = "symphony-web-cert-map"
SSL_POLICY = "symphony-web-tls"
STATE_ROOT = "/var/lib/symphony"
ALLOWED_EMAIL = "iliazlobin91@gmail.com"
LABELS = {"app.kubernetes.io/name": APPLICATION, "app.kubernetes.io/part-of": "symphony"}
POD_SELECTOR = {"app.kubernetes.io/name": APPLICATION}
IMAGE_PREFIX = "us-west1-docker.pkg.dev/iz27-platform-dev/symphony/application@sha256:"
PRIVATE_RANGES = [
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
    "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4", "240.0.0.0/4",
]


class ConfigurationError(ValueError):
    """Rendering would weaken or misbind the approved deployment boundary."""


def metadata(name):
    return {"name": name, "namespace": NAMESPACE, "labels": dict(LABELS)}


def resource(api_version, kind, name, spec):
    return {"apiVersion": api_version, "kind": kind, "metadata": metadata(name), "spec": spec}


def validate(stage, hostname, project_number, iap_client_id, image, source_revision, iap_audience):
    if stage not in ("bootstrap", "activate"):
        raise ConfigurationError("Stage must be bootstrap or activate")
    if hostname != HOSTNAME:
        raise ConfigurationError("Hostname must be the exact approved Symphony hostname")
    if not isinstance(project_number, str) or not re.fullmatch(r"[1-9][0-9]{0,19}", project_number):
        raise ConfigurationError("Project number must be an explicit positive numeric project ID")
    if not isinstance(iap_client_id, str) or not re.fullmatch(
        r"[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com", iap_client_id
    ):
        raise ConfigurationError("Supply the public custom OAuth client ID, never its secret")
    if stage == "bootstrap":
        if any(value is not None for value in (image, source_revision, iap_audience)):
            raise ConfigurationError("Bootstrap must not contain activation parameters")
        return
    if not isinstance(image, str) or not re.fullmatch(re.escape(IMAGE_PREFIX) + r"[0-9a-f]{64}", image):
        raise ConfigurationError("Activate requires an immutable Symphony application image digest")
    if image.endswith("0" * 64):
        raise ConfigurationError("An image placeholder cannot be activated")
    if not isinstance(source_revision, str) or not re.fullmatch(r"[0-9a-f]{40}", source_revision) or source_revision == "0" * 40:
        raise ConfigurationError("Activate requires the reviewed lowercase source revision")
    audience_pattern = rf"/projects/{re.escape(project_number)}/global/backendServices/[1-9][0-9]{{0,19}}"
    if not isinstance(iap_audience, str) or not re.fullmatch(audience_pattern, iap_audience):
        raise ConfigurationError("Activate requires the exact numeric backend audience in this project")


def gateway_resources(hostname, iap_client_id):
    service = resource("v1", "Service", APPLICATION, {
        "type": "ClusterIP", "selector": dict(POD_SELECTOR),
        "ports": [{"name": "http", "port": 80, "targetPort": "http", "protocol": "TCP"}],
    })
    backend = resource("networking.gke.io/v1", "GCPBackendPolicy", APPLICATION, {
        "default": {
            "timeoutSec": 3600,
            "iap": {"enabled": True, "oauth2ClientSecret": {"name": "symphony-iap-oauth"}, "clientID": iap_client_id},
        },
        "targetRef": {"group": "", "kind": "Service", "name": APPLICATION},
    })
    health = resource("networking.gke.io/v1", "HealthCheckPolicy", APPLICATION, {
        "default": {
            "checkIntervalSec": 10, "timeoutSec": 5, "healthyThreshold": 2, "unhealthyThreshold": 2,
            "logConfig": {"enabled": True},
            "config": {"type": "HTTP", "httpHealthCheck": {
                "portSpecification": "USE_FIXED_PORT", "port": 8080, "host": hostname,
                "requestPath": "/healthz", "response": "ok",
            }},
        },
        "targetRef": {"group": "", "kind": "Service", "name": APPLICATION},
    })
    gateway = resource("gateway.networking.k8s.io/v1", "Gateway", APPLICATION, {
        "gatewayClassName": "gke-l7-global-external-managed",
        "addresses": [{"type": "NamedAddress", "value": ADDRESS}],
        "listeners": [{
            "name": "https", "hostname": hostname, "protocol": "HTTPS", "port": 443,
            "allowedRoutes": {"namespaces": {"from": "Same"}, "kinds": [{"kind": "HTTPRoute"}]},
        }],
    })
    gateway["metadata"]["annotations"] = {"networking.gke.io/certmap": CERTIFICATE_MAP}
    frontend = resource("networking.gke.io/v1", "GCPGatewayPolicy", APPLICATION, {
        "default": {"sslPolicy": SSL_POLICY},
        "targetRef": {"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": APPLICATION},
    })
    route = resource("gateway.networking.k8s.io/v1", "HTTPRoute", APPLICATION, {
        "parentRefs": [{"name": APPLICATION, "sectionName": "https"}], "hostnames": [hostname],
        "rules": [{"matches": [{"path": {"type": "PathPrefix", "value": "/"}}],
                   "backendRefs": [{"name": APPLICATION, "port": 80}]}],
    })
    return [service, backend, health, gateway, frontend, route]


def workflow(hostname, source_revision, iap_audience):
    config = {
        "tracker": {
            "kind": "github", "provider": {"repo": "iliazlobin/symphony", "token": "$GITHUB_TOKEN", "api_url": "https://api.github.com"},
            "required_labels": ["symphony:ready"], "active_states": ["open"], "terminal_states": ["closed"],
        },
        "polling": {"interval_ms": 30000}, "observability": {"dashboard_enabled": False},
        "control": {
            "enabled": True, "initial_mode": "paused", "state_path": STATE_ROOT + "/control.json", "base_sha": source_revision,
            "max_attempts": 2, "max_total_runtime_ms": 3600000, "max_total_tokens": 1000000,
        },
        "workspace": {"root": STATE_ROOT + "/workspaces"}, "hooks": {}, "worker": {"ssh_hosts": []},
        "agent": {"max_concurrent_agents": 1, "max_turns": 1}, "codex": {"command": "/bin/false"},
        "chat": {
            "enabled": True, "max_concurrent": 1, "timeout_ms": 300000,
            "state_path": STATE_ROOT + "/chat", "codex_home": STATE_ROOT + "/chat-codex",
            "executable": "/opt/symphony/bin/codex", "auto_create_backlog": False,
        },
        "server": {"host": "0.0.0.0", "port": 8080, "session_cookie": "_symphony_gcp_key"},
        "browser_auth": {
            "provider": "iap", "public_origin": "https://" + hostname,
            "audience": iap_audience, "allowed_emails": [ALLOWED_EMAIL],
        },
    }
    # JSON is a YAML subset; fixed serialization keeps this ConfigMap dependency-free.
    return "---\n" + json.dumps(config, indent=2, sort_keys=True) + "\n---\n\nCloud coding task execution and publication remain disabled.\n"


def network_resources():
    def policy(name, directions, **rules):
        return resource("networking.k8s.io/v1", "NetworkPolicy", name, {
            "podSelector": {"matchLabels": dict(POD_SELECTOR)}, "policyTypes": directions, **rules,
        })

    dns_targets = [{
        "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
        "podSelector": {"matchLabels": {"k8s-app": name}},
    } for name in ("kube-dns", "node-local-dns")]
    dns_targets += [{"ipBlock": {"cidr": ip}} for ip in ("10.48.0.10/32", "169.254.20.10/32")]
    return [
        policy(APPLICATION + "-deny", ["Ingress", "Egress"]),
        policy(APPLICATION + "-ingress", ["Ingress"], ingress=[{
            "from": [{"ipBlock": {"cidr": cidr}} for cidr in ("35.191.0.0/16", "130.211.0.0/22")],
            "ports": [{"protocol": "TCP", "port": 8080}],
        }]),
        policy(APPLICATION + "-egress", ["Egress"], egress=[
            {"to": dns_targets, "ports": [{"protocol": protocol, "port": 53} for protocol in ("UDP", "TCP")]},
            {"to": [{"ipBlock": {"cidr": "0.0.0.0/0", "except": list(PRIVATE_RANGES)}}],
             "ports": [{"protocol": "TCP", "port": 443}]},
        ]),
    ]


def workload_resources(hostname, image, source_revision, iap_audience):
    text = workflow(hostname, source_revision, iap_audience)
    checksum = hashlib.sha256(text.encode("utf-8")).hexdigest()
    config_name = APPLICATION + "-config-" + checksum[:12]
    config = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": metadata(config_name),
              "immutable": True, "data": {"WORKFLOW.md": text}}
    claim = resource("v1", "PersistentVolumeClaim", APPLICATION + "-state", {
        "accessModes": ["ReadWriteOncePod"], "storageClassName": "shared-retain",
        "resources": {"requests": {"storage": "10Gi"}},
    })
    def probe(delay=None):
        result = {"httpGet": {"path": "/healthz", "port": "http", "httpHeaders": [{"name": "Host", "value": hostname}]},
                  "periodSeconds": 10, "timeoutSeconds": 3, "failureThreshold": 3}
        if delay is not None:
            result["initialDelaySeconds"] = delay
        return result

    startup = probe()
    startup["failureThreshold"] = 18
    container = {
        "name": "application", "image": image, "imagePullPolicy": "IfNotPresent",
        "args": ["serve", "--workflow", "/config/WORKFLOW.md", "--state-root", STATE_ROOT],
        "ports": [{"name": "http", "containerPort": 8080, "protocol": "TCP"}],
        "env": [{"name": "ERL_FLAGS", "value": "+S 2:2 +SDcpu 1 +SDio 1"}] + [
            {"name": name, "valueFrom": {"secretKeyRef": {"name": "symphony-application-secrets", "key": key}}}
            for name, key in (("GITHUB_TOKEN", "github-token"), ("SYMPHONY_CONTROL_TOKEN", "control-token"),
                              ("SYMPHONY_WORKSPACE_SECRET", "workspace-secret"))
        ],
        "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                            "capabilities": {"drop": ["ALL"]}},
        "resources": {"requests": {"cpu": "250m", "memory": "512Mi", "ephemeral-storage": "256Mi"},
                      "limits": {"cpu": "1", "memory": "1Gi", "ephemeral-storage": "1Gi"}},
        "startupProbe": startup, "readinessProbe": probe(), "livenessProbe": probe(10),
        "volumeMounts": [
            {"name": "state", "mountPath": STATE_ROOT}, {"name": "tmp", "mountPath": "/tmp"},
            {"name": "workflow", "mountPath": "/config/WORKFLOW.md", "subPath": "WORKFLOW.md", "readOnly": True},
        ],
    }
    deployment = resource("apps/v1", "Deployment", APPLICATION, {
        "replicas": 1, "strategy": {"type": "Recreate"}, "revisionHistoryLimit": 2,
        "selector": {"matchLabels": dict(POD_SELECTOR)},
        "template": {
            "metadata": {"labels": dict(LABELS), "annotations": {
                "symphony.dev/source-revision": source_revision, "symphony.dev/workflow-sha256": checksum,
            }},
            "spec": {
                "nodeSelector": {"cloud.google.com/gke-nodepool": "shared-dev"},
                "automountServiceAccountToken": False, "enableServiceLinks": False,
                "securityContext": {"runAsNonRoot": True, "runAsUser": 10001, "runAsGroup": 10001,
                                    "fsGroup": 10001, "fsGroupChangePolicy": "OnRootMismatch",
                                    "seccompProfile": {"type": "RuntimeDefault"}},
                "terminationGracePeriodSeconds": 60, "containers": [container],
                "volumes": [
                    {"name": "state", "persistentVolumeClaim": {"claimName": APPLICATION + "-state"}},
                    {"name": "tmp", "emptyDir": {"sizeLimit": "1Gi"}},
                    {"name": "workflow", "configMap": {"name": config_name, "defaultMode": 0o444,
                                                       "items": [{"key": "WORKFLOW.md", "path": "WORKFLOW.md"}]}},
                ],
            },
        },
    })
    return [claim, config, *network_resources(), deployment]


def render(stage, *, hostname, project_number, iap_client_id, image=None, source_revision=None, iap_audience=None):
    validate(stage, hostname, project_number, iap_client_id, image, source_revision, iap_audience)
    items = gateway_resources(hostname, iap_client_id)
    if stage == "activate":
        items += workload_resources(hostname, image, source_revision, iap_audience)
    return {"apiVersion": "v1", "kind": "List", "items": items}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("bootstrap", "activate"))
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--project-number", required=True)
    parser.add_argument("--iap-client-id", required=True)
    parser.add_argument("--image")
    parser.add_argument("--source-revision")
    parser.add_argument("--iap-audience")
    options = vars(parser.parse_args(argv))
    try:
        manifest = render(**options)
    except ConfigurationError as exc:
        parser.error(str(exc))
    json.dump(manifest, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
