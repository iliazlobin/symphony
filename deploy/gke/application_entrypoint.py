#!/usr/bin/env python3
"""Start the complete application from an explicit, mounted operator workflow.

This is a conservative pilot boundary, not a workflow generator or scheduler.
The normal OTP application owns journal locks, chat persistence and execution.
"""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import sys
from urllib.parse import urlsplit

import yaml


APPLICATION = "/opt/symphony/symphony"
CHAT_EXECUTABLE = "/opt/symphony/bin/codex"
GUARDRAILS_ACK = "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
MAX_CONFIG_BYTES = 1_048_576


class ConfigurationError(ValueError):
    """An operator configuration cannot safely start this application package."""


class UniqueLoader(yaml.SafeLoader):
    pass


def unique_mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if not isinstance(key, str) or key in result:
            raise ConfigurationError("Workflow keys must be unique strings")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)


def resolve_value(value, environment):
    if isinstance(value, str) and re.fullmatch(r"\$[A-Za-z_][A-Za-z0-9_]*", value):
        return environment.get(value[1:])
    return value


def canonical_path(value, label, environment):
    value = resolve_value(value, environment)
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ConfigurationError(f"{label} must be an explicit absolute path")
    path = Path(value)
    if not path.is_absolute() or str(path) != value or path.resolve() != path:
        raise ConfigurationError(f"{label} must be absolute, canonical and free of symlinks")
    return path


def bounded_file(path, label):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_CONFIG_BYTES:
        raise ConfigurationError(f"{label} must be a bounded regular file")
    return path.read_text(encoding="utf-8")


def mapping(config, key):
    value = config.get(key)
    if not isinstance(value, dict):
        raise ConfigurationError(f"Workflow requires an explicit {key} mapping")
    return value


def contains(parent, child):
    return child == parent or parent in child.parents


def validate_browser_binding(config, environment):
    """A remote listener requires the application's signed IAP identity boundary."""
    server = mapping(config, "server")
    if server.get("host") in ("127.0.0.1", "::1"):
        return
    browser = mapping(config, "browser_auth")
    origin = resolve_value(browser.get("public_origin"), environment)
    audience = resolve_value(browser.get("audience"), environment)
    emails = browser.get("allowed_emails")
    if server.get("host") != "0.0.0.0" or browser.get("provider") != "iap":
        raise ConfigurationError("Remote binding requires explicit IAP browser authentication")
    if not isinstance(origin, str):
        raise ConfigurationError("IAP requires an explicit HTTPS public origin")
    public = urlsplit(origin)
    try:
        valid_origin = (
            public.scheme == "https" and bool(public.hostname)
            and public.hostname not in ("localhost", "127.0.0.1", "::1")
            and public.username is None and public.password is None
            and public.path == "" and not public.query and not public.fragment
            and public.port in (None, 443) and origin == "https://" + public.hostname
        )
    except ValueError:
        valid_origin = False
    if not valid_origin:
        raise ConfigurationError("IAP requires a canonical bare HTTPS public origin")
    if not isinstance(audience, str) or not re.fullmatch(r"/projects/[0-9]+/global/backendServices/[0-9]+", audience):
        raise ConfigurationError("IAP requires the exact numeric backend service audience")
    if (
        not isinstance(emails, list) or not 1 <= len(emails) <= 20
        or any(not isinstance(email, str) or not re.fullmatch(r"[^\s@]+@[^\s@]+", email) for email in emails)
        or len(set(email.lower() for email in emails)) != len(emails)
    ):
        raise ConfigurationError("IAP requires a nonempty unique email allowlist")


def validate(workflow_path, state_root, environment):
    """Validate without rewriting workflow, journal, authentication or permissions."""
    for name in ("OPENAI_API_KEY", "CODEX_API_KEY"):
        if environment.get(name):
            raise ConfigurationError("API-key authentication is not supported by this subscription package")

    root = canonical_path(state_root, "state root", environment)
    workflow = canonical_path(workflow_path, "workflow", environment)
    if not root.is_dir() or not os.path.ismount(root):
        raise ConfigurationError("State root must be an existing mounted directory")
    text = bounded_file(workflow, "Workflow")
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        raise ConfigurationError("Workflow must begin with YAML front matter")
    try:
        end = lines.index("---", 1)
    except ValueError as exc:
        raise ConfigurationError("Workflow front matter is not terminated") from exc
    config = yaml.load("\n".join(lines[1:end]), Loader=UniqueLoader)
    if not isinstance(config, dict):
        raise ConfigurationError("Workflow front matter must be a mapping")

    tracker = mapping(config, "tracker")
    provider = mapping(tracker, "provider")
    repository = resolve_value(provider.get("repo"), environment)
    token = resolve_value(provider.get("token"), environment)
    if tracker.get("kind") != "github" or not isinstance(repository, str) or not re.fullmatch(r"[^\s/]+/[^\s/]+", repository):
        raise ConfigurationError("Configure the real GitHub tracker and owner/repository explicitly")
    if not isinstance(token, str) or not token.strip():
        raise ConfigurationError("GitHub provider token must be supplied explicitly or by environment reference")
    api_url = provider.get("api_url", "https://api.github.com")
    if not isinstance(api_url, str):
        raise ConfigurationError("GitHub API URL must use explicit HTTPS")
    url = urlsplit(api_url)
    if url.scheme != "https" or not url.hostname or url.username is not None or url.password is not None or url.query or url.fragment:
        raise ConfigurationError("GitHub API URL must use explicit HTTPS without embedded credentials")
    control = mapping(config, "control")
    if control.get("enabled") is not True or control.get("initial_mode") != "paused":
        raise ConfigurationError("Cloud pilot requires enabled controls with initial_mode paused")
    if mapping(config, "codex").get("command") != "/bin/false":
        raise ConfigurationError("Cloud task execution is not integrated; codex.command must remain /bin/false")
    hooks = config.get("hooks", {})
    if not isinstance(hooks, dict) or any(value not in (None, "") for value in hooks.values()):
        raise ConfigurationError("Cloud pilot cannot run workspace hooks before worker integration")
    worker = config.get("worker", {})
    if not isinstance(worker, dict) or worker.get("ssh_hosts"):
        raise ConfigurationError("Cloud pilot cannot delegate tasks to SSH workers")
    chat = mapping(config, "chat")
    if chat.get("enabled") is not True or type(chat.get("max_concurrent")) is not int or chat["max_concurrent"] != 1:
        raise ConfigurationError("Cloud pilot requires enabled management chat with max_concurrent 1")
    executable = canonical_path(chat.get("executable"), "chat executable", environment)
    if str(executable) != CHAT_EXECUTABLE:
        raise ConfigurationError("Management chat must use the packaged native Codex executable")
    server = mapping(config, "server")
    validate_browser_binding(config, environment)
    if type(server.get("port")) is not int or not 1 <= server["port"] <= 65535:
        raise ConfigurationError("Configure an explicit valid server port")

    workspace = canonical_path(mapping(config, "workspace").get("root"), "workspace root", environment)
    paths = {
        "journal": canonical_path(control.get("state_path"), "control.state_path", environment),
        "chat": canonical_path(chat.get("state_path"), "chat.state_path", environment),
        "authentication": canonical_path(chat.get("codex_home"), "chat.codex_home", environment),
    }
    for label, path in paths.items():
        if path == root or not contains(root, path) or contains(workspace, path) or contains(path, workspace):
            raise ConfigurationError(f"{label} must be under retained state and separate from workspaces")
    for left, first in paths.items():
        for right, second in paths.items():
            if left != right and contains(first, second):
                raise ConfigurationError("Journal, conversation and authentication paths must be separate")

    journal = paths["journal"]
    if journal.exists():
        recorded = json.loads(bounded_file(journal, "Control journal"))
        if not isinstance(recorded, dict) or recorded.get("mode") != "paused":
            raise ConfigurationError("Existing journal is not paused; reconcile ownership before startup")
        if not isinstance(recorded.get("issues"), dict) or any(
            not isinstance(issue, dict) or issue.get("active") is not None
            for issue in recorded["issues"].values()
        ):
            raise ConfigurationError("Existing journal contains unresolved active ownership")

    home = paths["authentication"]
    forbidden = ("config.toml", "AGENTS.md", "AGENTS.override.md", "hooks.json", "plugins", ".agents")
    if any((home / name).exists() or (home / name).is_symlink() for name in forbidden):
        raise ConfigurationError("Management chat requires a dedicated home without imported configuration")
    auth = home / "auth.json"
    if auth.exists() or auth.is_symlink():
        record = json.loads(bounded_file(auth, "Authentication record"))
        if not isinstance(record, dict) or record.get("auth_mode") != "chatgpt" or record.get("OPENAI_API_KEY"):
            raise ConfigurationError("Management chat accepts only dedicated ChatGPT subscription authentication")
    return workflow, root, paths


def prepare_directories(root, paths):
    for path in (paths["journal"].parent, paths["chat"], paths["authentication"], root / "logs"):
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        if not path.is_dir() or not os.access(path, os.W_OK | os.X_OK):
            raise ConfigurationError("Mounted state directories must be writable by the application identity")
    for path in (paths["chat"], paths["authentication"]):
        if path.stat().st_uid != os.getuid() or stat.S_IMODE(path.stat().st_mode) & 0o077:
            raise ConfigurationError("Conversation and authentication directories must be owner-only")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("serve",))
    parser.add_argument("--workflow", required=True)
    parser.add_argument("--state-root", required=True)
    args = parser.parse_args(argv)
    try:
        workflow, root, paths = validate(args.workflow, args.state_root, os.environ)
        os.umask(0o077)
        prepare_directories(root, paths)
        os.execv(APPLICATION, [APPLICATION, GUARDRAILS_ACK, "--logs-root", str(root / "logs"), str(workflow)])
    except (ConfigurationError, OSError, UnicodeError, ValueError, yaml.YAMLError) as exc:
        # Do not include parser exceptions: they can quote mounted secret values.
        message = str(exc) if isinstance(exc, ConfigurationError) else "Configuration or mounted state could not be read"
        print(f"Symphony application startup rejected: {message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
