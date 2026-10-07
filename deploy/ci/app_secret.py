#!/usr/bin/env python3
"""Initial Symphony App storage/delivery; credential bytes use memory and stdin only."""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.request
import uuid

import preflight


PROJECT = "iz27-platform-dev"
PROJECT_NUMBER = "612182574147"
SECRET = "symphony-ci-github-app"
NAMESPACE = "symphony-ci-runners"
REPOSITORY = "iliazlobin/symphony"
REPOSITORY_ID = "1370642365"
APP_SLUG = "iz27-symphony-ci"
FIELDS = {"github_app_id", "github_app_installation_id", "github_app_private_key"}
PERMISSIONS = {"administration": "write", "metadata": "read"}
MAX_INPUT = 65536
KUBECTL = ["kubectl", "--context=" + preflight.CONTEXT, "--request-timeout=30s"]
SCOPE = ["--secret=" + SECRET, "--project=" + PROJECT,
         "--account=iliazlobin27@gmail.com"]
ERROR = "Symphony App delivery stopped; reconcile metadata privately before retrying."


def command(args, payload=None, *, pass_fds=()):
    env = None
    if args[0] == "gcloud":
        # Override inherited debugging without changing the operator configuration.
        env = {**os.environ, "CLOUDSDK_CORE_DISABLE_FILE_LOGGING": "true",
               "CLOUDSDK_CORE_LOG_HTTP": "false", "CLOUDSDK_CORE_VERBOSITY": "none"}
    result = subprocess.run(args, input=payload, capture_output=True, timeout=90,
                            pass_fds=pass_fds, env=env)
    if result.returncode or len(result.stdout) > 1048576:
        raise ValueError("Private operator command failed")
    return result.stdout


def unique_object(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise ValueError("Duplicate input field")
        result[name] = value
    return result


def credentials(raw):
    if len(raw) > MAX_INPUT:
        raise ValueError("Bounded input exceeded")
    data = json.loads(raw, object_pairs_hook=unique_object)
    if not isinstance(data, dict) or set(data) != FIELDS:
        raise ValueError("Require exactly the three ARC App fields")
    for field in FIELDS - {"github_app_private_key"}:
        if not isinstance(data[field], str) or not re.fullmatch(r"[1-9][0-9]{0,19}", data[field]):
            raise ValueError("Require positive numeric identifiers as strings")
    key = data["github_app_private_key"]
    if (not isinstance(key, str) or len(key.encode()) > 16384 or
            "\nProc-Type:" in key or "\nDEK-Info:" in key or
            not key.startswith(("-----BEGIN RSA PRIVATE KEY-----\n", "-----BEGIN PRIVATE KEY-----\n"))):
        raise ValueError("Require the bounded RSA PEM private key")
    command(["openssl", "rsa", "-check", "-noout", "-passin", "pass:"], key.encode())
    return data


def b64url(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=")


def app_jwt(data):
    now = int(time.time())
    message = b".".join(b64url(json.dumps(value, separators=(",", ":")).encode())
                        for value in ({"alg": "RS256", "typ": "JWT"},
                                      {"iat": now - 60, "exp": now + 300,
                                       "iss": data["github_app_id"]}))
    key_reader, key_writer = os.pipe()
    failures = []

    def write_key():
        try:
            with os.fdopen(key_writer, "wb") as stream:
                stream.write(data["github_app_private_key"].encode())
        except Exception:
            failures.append(True)  # Never emit a thread traceback containing input.

    writer = threading.Thread(target=write_key, daemon=True)
    writer.start()
    try:
        signature = command(["openssl", "dgst", "-sha256", "-sign", f"/dev/fd/{key_reader}",
                             "-passin", "pass:", "-sigopt", "rsa_padding_mode:pkcs1"],
                            message, pass_fds=(key_reader,))
    finally:
        os.close(key_reader)
        writer.join(timeout=5)
    if writer.is_alive() or failures:
        raise ValueError("Private signing failed")
    return (message + b"." + b64url(signature)).decode()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError("GitHub API redirects are refused")


def github(path, token):
    request = urllib.request.Request("https://api.github.com" + path, headers={
        "Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2026-03-10", "User-Agent": "symphony-ci-app-delivery"})
    with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
        raw = response.read(1048577)
    if len(raw) > 1048576:
        raise ValueError("Bounded API response exceeded")
    return json.loads(raw)


def verify_app(data):
    token = app_jwt(data)
    app = github("/app", token)
    if (app.get("id") != int(data["github_app_id"]) or app.get("slug") != APP_SLUG or
            app.get("owner", {}).get("login") != "iliazlobin" or
            app.get("permissions") != PERMISSIONS or app.get("events") != []):
        raise ValueError("Unexpected App identity or permissions")
    installation = github("/app/installations/" + data["github_app_installation_id"], token)
    if (installation.get("id") != int(data["github_app_installation_id"]) or
            installation.get("app_id") != int(data["github_app_id"]) or
            installation.get("account", {}).get("login") != "iliazlobin" or
            installation.get("target_type") != "User" or
            installation.get("repository_selection") != "selected" or
            installation.get("suspended_at") is not None or
            installation.get("permissions") != PERMISSIONS):
        raise ValueError("Unexpected installation scope or permissions")
    repository_installation = github("/repos/" + REPOSITORY + "/installation", token)
    if (repository_installation.get("id") != installation["id"] or
            repository_installation.get("app_id") != app["id"]):
        raise ValueError("Installation does not cover Symphony")


def verify_operator():
    policy = preflight.command(["gh", "api", "repos/" + REPOSITORY +
                                "/actions/permissions/fork-pr-contributor-approval",
                                "--jq", ".approval_policy"]).strip()
    if policy != "all_external_contributors":
        raise ValueError("External workflow approval is required")
    preflight.main()  # Exact public repo ID, operator, private TLS/IAP, pools and capacity.
    for namespace, service, address in (("default", "kubernetes", "10.48.0.1"),
                                        ("kube-system", "kube-dns", "10.48.0.10")):
        if command(KUBECTL + ["-n", namespace, "get", "service", service,
                             "-o", "jsonpath={.spec.clusterIP}"]).decode().strip() != address:
            raise ValueError("Unexpected private service boundary")
    for namespace in ("symphony-ci-system", NAMESPACE):
        value = json.loads(command(KUBECTL + ["get", "namespace", namespace, "-o", "json"]))
        if (value.get("metadata", {}).get("name") != namespace or
                value["metadata"].get("labels", {}).get("pod-security.kubernetes.io/enforce") != "restricted"):
            raise ValueError("Require prepared restricted Symphony namespaces")
    metadata = json.loads(command(["gcloud", "secrets", "describe", SECRET,
        "--project=" + PROJECT, "--account=iliazlobin27@gmail.com", "--format=json(name,replication)"]))
    if (metadata.get("name") != f"projects/{PROJECT_NUMBER}/secrets/{SECRET}" or
            metadata.get("replication", {}).get("userManaged", {}).get("replicas") != [{"location": "us-west1"}]):
        raise ValueError("Require reviewed Symphony Secret Manager metadata")


def version_name(version):
    return f"projects/{PROJECT_NUMBER}/secrets/{SECRET}/versions/{version}"


def read_version(version):
    metadata = json.loads(command(["gcloud", "secrets", "versions", "describe", str(version),
                                   *SCOPE, "--format=json(name,state)"]))
    if metadata.get("name") != version_name(version) or metadata.get("state") != "ENABLED":
        raise ValueError("Require the approved enabled version")
    return credentials(command(["gcloud", "secrets", "versions", "access", str(version), *SCOPE]))


class SafeParser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError("Invalid initial-delivery arguments")


def main(argv=None):
    parser = SafeParser(description=__doc__)
    parser.add_argument("mode", choices=("store", "deliver"))
    parser.add_argument("--version", type=int)
    parser.add_argument("--app-scope-confirmed", action="store_true")
    args = parser.parse_args(argv)
    if (not args.app_scope_confirmed or
            args.mode == "deliver" and (args.version is None or args.version <= 0) or
            args.mode == "store" and args.version is not None):
        raise ValueError("Require prior App UI scope verification and a pinned delivery version")
    verify_operator()
    if args.mode == "store":
        if command(["gcloud", "secrets", "versions", "list", SECRET, "--project=" + PROJECT,
                    "--account=iliazlobin27@gmail.com", "--limit=1", "--format=value(name)"]).strip():
            raise ValueError("Existing versions require separate recovery or rotation")
        data = credentials(sys.stdin.buffer.read(MAX_INPUT + 1))
        verify_app(data)
        name = command(["gcloud", "secrets", "versions", "add", SECRET, "--project=" + PROJECT,
                        "--account=iliazlobin27@gmail.com", "--data-file=-", "--format=value(name)"],
                       json.dumps(data).encode()).decode().strip()
        if name != version_name(1) or read_version(1) != data:
            raise ValueError("Store readback differs; reconcile privately before retrying")
        return {"stored_version": name, "verified": True}
    existing = command(KUBECTL + ["-n", NAMESPACE, "get", "secret", SECRET, "--ignore-not-found",
                                 "-o", "jsonpath={.metadata.name}"]).strip()
    if existing:
        raise ValueError("Existing ARC Secret requires separate recovery or rotation")
    data = read_version(args.version)
    verify_app(data)
    secret = {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
              "metadata": {"name": SECRET, "namespace": NAMESPACE, "annotations": {
                  "symphony-ci-repository-id": REPOSITORY_ID,
                  "symphony-ci-secret-version": str(args.version)}},
              "data": {name: base64.b64encode(value.encode()).decode() for name, value in data.items()}}
    command(KUBECTL + ["create", "-f", "-"], json.dumps(secret).encode())
    actual = json.loads(command(KUBECTL + ["-n", NAMESPACE, "get", "secret", SECRET, "-o", "json"]))
    if (actual.get("type") != "Opaque" or actual.get("data") != secret["data"] or
            actual.get("metadata", {}).get("name") != SECRET or
            actual["metadata"].get("namespace") != NAMESPACE or
            actual["metadata"].get("annotations", {}).get("symphony-ci-repository-id") != REPOSITORY_ID or
            actual["metadata"].get("annotations", {}).get("symphony-ci-secret-version") != str(args.version)):
        raise ValueError("ARC field readback differs; reconcile privately before retrying")
    uid = str(uuid.UUID(actual["metadata"]["uid"]))
    return {"secret": NAMESPACE + "/" + SECRET, "uid": uid,
            "source_version": version_name(args.version), "verified": True}


def cli(argv=None):
    try:
        print(json.dumps(main(argv)))
        return 0
    except (Exception, KeyboardInterrupt):
        print(ERROR, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(cli())
