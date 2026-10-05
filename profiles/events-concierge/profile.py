#!/usr/bin/env python3
"""Shared Mac host setup and trusted workspace hooks for registered Symphony projects."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import stat
import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from symphony_control import ControlError, DEFAULT_CONFIG, load_config, read_private
from container_auth import AuthLease, AuthLeaseError
from local_codex_auth import LocalCodexAuthError, _paths, cached_status

REPOSITORY = "iliazlobin/events-concierge"
REMOTE = "https://github.com/" + REPOSITORY + ".git"
SHA = re.compile(r"[0-9a-f]{40}")
WORKER_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
COMMAND_PATH = "/usr/local/bin:/usr/bin:/bin"
PROJECTS = {
    "iliazlobin/events-concierge": {"slug": "events-concierge", "port": 8778, "policy": "symphony-codex"},
    "iliazlobin/symphony": {"slug": "symphony", "port": 8779, "policy": "symphony-self-codex"},
}
WORKSPACE_BASELINE_CHANGED_EXIT = 78
WORKSPACE_BASELINE_CHANGED_MARKER = "SYMPHONY_WORKSPACE_BASELINE_CHANGED"


class CommandError(ControlError):
    def __init__(self, message: str, returncode: int):
        super().__init__(message)
        self.returncode = returncode


class WorkspaceBaselineChanged(ControlError):
    """A retained checkout cannot run from the currently approved source baseline."""


def project_settings(repository: str) -> dict:
    if not isinstance(repository, str) or repository not in PROJECTS:
        raise ControlError("No reviewed Mac profile exists for this repository")
    return PROJECTS[repository]


def repository_remote(config: dict) -> str:
    repository = config.get("repository", REPOSITORY)
    project_settings(repository)
    return "https://github.com/" + repository + ".git"


def run(*args: str, cwd: Path | None = None, env: dict | None = None) -> str:
    if args[0] == "git":
        args = ("git", "--no-replace-objects", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", *args[1:])
        env = dict(os.environ if env is None else env, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
    result = subprocess.run(list(args), cwd=cwd, env=env, capture_output=True, text=True, timeout=120)
    if result.returncode:
        # Commands never include credentials; avoid echoing environments or token outputs.
        raise CommandError(f"{args[0]} failed: {result.stderr.strip()[:1500]}", result.returncode)
    return result.stdout.strip()


def write_private(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.exists() or path.is_symlink():
        raise ControlError(f"Refusing to overwrite existing state: {path}")
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write(value)


def private_directory(path: Path) -> None:
    if path.is_symlink():
        raise ControlError("Private state directory must not be a symlink")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ControlError("Private state directory must be owned by this user with mode 0700")


def validate_workflow(workflow: str, repository: str = REPOSITORY) -> None:
    project_settings(repository)
    pieces = workflow.split("---\n", 2)
    if len(pieces) != 3 or pieces[0].strip():
        raise ControlError("Workflow must start with YAML front matter")
    try:
        settings = yaml.safe_load(pieces[1])
        tracker, controls = settings["tracker"], settings["control"]
        concurrency = settings["agent"]["max_concurrent_agents"]
        valid = (tracker["kind"] == "github" and tracker["provider"]["repo"] == repository
                 and tracker["required_labels"] == ["symphony:ready"]
                 and tracker["active_states"] == ["open"] and tracker["terminal_states"] == ["closed"]
                 and controls["enabled"] is True and controls["initial_mode"] == "paused"
                 and controls["base_sha"] == "$SYMPHONY_BASE_SHA"
                 and type(concurrency) is int and 1 <= concurrency <= 5)
        if not valid:
            raise ControlError("Workflow must enforce the approved paused GitHub profile with one to five task slots")
    except (KeyError, TypeError, yaml.YAMLError) as exc:
        raise ControlError("Workflow front matter is missing or invalid") from exc


def permission_config() -> str:
    sections = [
        'model = "gpt-6-astra"',
        'model_reasoning_effort = "medium"',
        'cli_auth_credentials_store = "file"',
        'forced_login_method = "chatgpt"',
        'approval_policy = "on-request"',
        'approvals_reviewer = "user"',
        'default_permissions = "symphony-builder"',
        '[shell_environment_policy]',
        'inherit = "none"',
        # Resolve image toolchain/system binaries without inheriting host variables.
        '[shell_environment_policy.set]',
        f'PATH = "{COMMAND_PATH}"',
        '[features]',
        'multi_agent = false',
        # Apps use the signed-in account outside the command network sandbox.
        'apps = false',
    ]
    for name, access in (("symphony-builder", "write"), ("symphony-reviewer", "read")):
        sections += [
            f'[permissions.{name}]', 'extends = ":workspace"',
            f'[permissions.{name}.filesystem]',
            '":root" = "deny"', '":minimal" = "read"',
            '":tmpdir" = "deny"', '":slash_tmp" = "deny"',
            # macOS tools use these installations; no user home is admitted.
            '"/opt/homebrew" = "read"',
            '"/Library/Developer/CommandLineTools" = "read"',
            f'[permissions.{name}.filesystem.":workspace_roots"]',
            f'"." = "{access}"', f'".git" = "{access}"',
            '".codex" = "read"', '".agents" = "read"', '"**/*.env" = "deny"',
            f'[permissions.{name}.network]', 'enabled = false',
        ]
    return "\n".join(sections) + "\n"


def worker_workflow(workflow: str) -> str:
    """Generated dedicated-container workflows always verify provider auth."""
    pieces = workflow.split("---\n", 2)
    settings = yaml.safe_load(pieces[1])
    codex = settings.setdefault("codex", {})
    if not isinstance(codex, dict):
        raise ControlError("Worker workflow Codex configuration must be an object")
    codex["auth_preflight"] = True
    # One enrolled credential is one serialized worker stream. Concurrency
    # needs an explicit pool of independently enrolled credentials first.
    settings["agent"]["max_concurrent_agents"] = 1
    return "---\n" + yaml.safe_dump(settings, sort_keys=False) + "---\n" + pieces[2]


def initialize(args, repository: str = REPOSITORY, profile_bin: Path | None = None) -> dict:
    project_settings(repository)
    remote = "https://github.com/" + repository + ".git"
    state = Path(args.state_dir).expanduser().resolve()
    source = Path(args.source).expanduser().resolve()
    base = args.base_sha
    if type(args.port) is not int or not 1024 <= args.port <= 65535:
        raise ControlError("Use a dedicated unprivileged controller port")
    if not SHA.fullmatch(base):
        raise ControlError("The source baseline must be a full lowercase commit SHA")
    if run("git", "rev-parse", "--verify", base + "^{commit}", cwd=source) != base:
        raise ControlError("Source baseline does not resolve")
    origin = run("git", "config", "--get", "remote.origin.url", cwd=source)
    if origin not in (remote, remote[:-4], "git@github.com:" + repository + ".git"):
        raise ControlError("Source repository does not match the selected project")
    if args.integration_branch and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", args.integration_branch):
        raise ControlError("Invalid integration branch")
    workflow = run("git", "show", base + ":WORKFLOW.md", cwd=source) + "\n"
    validate_workflow(workflow, repository)
    config_file = state / "config.json"
    if config_file.exists():
        raise ControlError("Operator configuration already exists; review changes explicitly")
    private_directory(state)
    for directory in ("workspaces", "logs", "worker-home", "codex", "bin", "receipts"):
        private_directory(state / directory)
    if repository == "iliazlobin/symphony":
        for directory in ("chat", "management-codex"):
            private_directory(state / directory)
    config = {
        "repository": repository, "source_path": str(source), "base_sha": base,
        "integration_branch": args.integration_branch, "state_dir": str(state),
        "workflow_path": str(state / "WORKFLOW.md"), "workspace_root": str(state / "workspaces"),
        "codex_home": str(state / "codex"), "worker_home": str(state / "worker-home"),
        "api_url": "http://127.0.0.1:" + str(args.port),
        "token_file": str(state / "control.token"),
        "profile_bin": str((profile_bin or Path(__file__)).resolve()),
        "codex_binary": shutil.which("codex") or "/opt/homebrew/bin/codex",
        "worker_launch_enabled": False,
        "rules_source": str(Path.home() / "Workspace/dotfiles/codex/codex_rules.py"),
        "auto_merge": {
            "enabled": False, "allowed_paths": ["docs/**/*.md"],
            "denied_paths": ["docs/production-operations.md", "docs/security*", "docs/*runbook*",
                             "docs/*deployment*", "docs/*recovery*", "**/AGENTS.md", "**/WORKFLOW.md"],
            "max_changed_lines": 80, "required_checks": [],
        },
    }
    write_private(state / "control.token", secrets.token_urlsafe(48) + "\n")
    write_private(state / "WORKFLOW.md", worker_workflow(workflow))
    write_private(state / "codex/config.toml", permission_config())
    write_private(config_file, json.dumps(config, indent=2) + "\n")
    return {"config": str(config_file), "mode": "paused", "source_revision": base,
            "next": "Install managed rules, authenticate this dedicated Codex home, build Symphony, then run doctor."}


def workspace(config: dict) -> Path:
    current = Path.cwd().resolve()
    parent = Path(config["workspace_root"]).resolve()
    if current.parent != parent or not re.fullmatch(r"[A-Za-z0-9_.-]{1,180}", current.name):
        raise ControlError("Hooks may only operate on a direct task workspace")
    if Path.cwd().is_symlink():
        raise ControlError("Workspace may not be a symlink")
    return current


def task_branch(current: Path) -> str:
    return "codex/" + current.name.lower().replace("_", "-")[:120]


def workspace_create(config: dict) -> dict:
    current = workspace(config)
    if any(current.iterdir()):
        raise ControlError("A new task workspace must be empty")
    env = {"PATH": WORKER_PATH, "HOME": config["worker_home"], "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_TERMINAL_PROMPT": "0"}
    run("git", "clone", "--no-hardlinks", "--no-checkout", config["source_path"], ".", cwd=current, env=env)
    run("git", "checkout", "-b", task_branch(current), config["base_sha"], cwd=current, env=env)
    run("git", "remote", "set-url", "origin", repository_remote(config), cwd=current, env=env)
    run("git", "remote", "set-url", "--push", "origin", "disabled://host-publishes-candidates", cwd=current, env=env)
    run("git", "config", "credential.helper", "", cwd=current, env=env)
    run("git", "config", "core.hooksPath", "/dev/null", cwd=current, env=env)
    run("git", "config", "user.name", "Symphony Worker", cwd=current, env=env)
    run("git", "config", "user.email", "symphony@localhost", cwd=current, env=env)
    # Worker evidence is runtime data and must not pollute the candidate commit.
    with (current / ".git/info/exclude").open("a") as stream:
        stream.write("\n.symphony/\n")
    (current / ".symphony").mkdir(mode=0o700)
    return {"workspace": str(current), "branch": task_branch(current), "base_sha": config["base_sha"]}


def before_run(config: dict) -> dict:
    current = workspace(config)
    if run("git", "rev-parse", "--show-toplevel", cwd=current) != str(current):
        raise ControlError("Unexpected repository boundary")
    branch = run("git", "branch", "--show-current", cwd=current)
    if branch != task_branch(current):
        raise ControlError("Unexpected task branch")
    if run("git", "remote", "get-url", "origin", cwd=current) != repository_remote(config):
        raise ControlError("Unexpected source remote")
    try:
        run("git", "cat-file", "-e", config["base_sha"] + "^{commit}", cwd=current)
    except CommandError:
        # A retained clone may predate the pin. Verify the exact approved commit in
        # its trusted source without fetching into or altering retained evidence.
        run("git", "cat-file", "-e", config["base_sha"] + "^{commit}", cwd=Path(config["source_path"]))
        raise WorkspaceBaselineChanged("Workspace baseline needs recovery") from None
    try:
        run("git", "merge-base", "--is-ancestor", config["base_sha"], "HEAD", cwd=current)
    except CommandError as exc:
        # Git status 1 means a valid non-ancestor, not an unavailable/corrupt object.
        # The trusted before-run hook reserves a fixed outcome for this prerequisite.
        if exc.returncode == 1:
            raise WorkspaceBaselineChanged("Workspace baseline needs recovery") from None
        raise
    if (current / ".env").exists():
        raise ControlError("Application credentials are not permitted in task workspaces")
    return {"workspace": str(current), "branch": branch, "resuming": True}


def worker_env(config: dict) -> dict:
    return {
        "PATH": WORKER_PATH, "HOME": str(Path.home()), "CODEX_HOME": config["codex_home"],
        "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
    }


def container_launch_options(config: dict) -> list[str]:
    """Select the reviewed, workspace-scoped policies for every worker stage."""
    from worker_policy import render_policy

    sandbox = config.get("worker_sandbox", {})
    if not isinstance(sandbox, dict):
        raise ControlError("Worker sandbox configuration must be an object")
    root = Path(config["workspace_root"])
    policy_name = project_settings(config.get("repository", REPOSITORY))["policy"]
    policy = Path(config["state_dir"]) / "worker-apparmor"
    seccomp = ROOT / "profiles/events-concierge/seccomp-codex.json"
    if (sandbox.get("apparmor_profile") != policy_name
            or sandbox.get("workspace_root") != str(root)):
        raise ControlError("Reviewed workspace-scoped worker sandbox configuration is missing")
    content = read_private(policy)
    if content != render_policy(root, policy_name):
        raise ControlError("Worker AppArmor source does not match the configured workspace root")
    for name, data in (("apparmor_sha256", content.encode()), ("seccomp_sha256", seccomp.read_bytes())):
        if sandbox.get(name) != hashlib.sha256(data).hexdigest():
            raise ControlError("Worker sandbox policy changed; review and reinstall it before launch")
    return ["--seccomp-policy", str(seccomp), "--apparmor-profile", policy_name]


def worker_auth_options(config: dict) -> list[str]:
    """Select authentication explicitly, without mounting or copying local state."""
    source = config.get("worker_auth_source", "dedicated")
    fields = ("local_codex_binary", "local_codex_home")
    if source == "dedicated":
        if any(field in config for field in fields):
            raise ControlError("Local Codex paths require the explicit local_codex authentication source")
        return []
    if source != "local_codex":
        raise ControlError("Unknown worker authentication source")
    try:
        binary, home, cwd = _paths(config["local_codex_binary"], config["local_codex_home"], config["worker_home"])
        runtime_home = Path(config["codex_home"]).resolve(strict=True)
        if runtime_home == home or home in runtime_home.parents:
            raise ValueError("Personal configuration cannot be mounted into workers")
        forbidden = [runtime_home, runtime_home.parent / "stage-state", runtime_home.parent / "pr-work-state", cwd]
        for field in ("workspace_root", "source_path"):
            if field in config:
                root = Path(config[field]).resolve(strict=True)
                if cwd == root or root in cwd.parents or cwd in root.parents:
                    raise ValueError("Authentication client cannot run in a source tree")
                forbidden.append(root)
        if any(binary == root or root in binary.parents for root in forbidden):
            raise ValueError("Authentication executable cannot be supplied by worker storage")
    except (LocalCodexAuthError, OSError, ValueError, TypeError, KeyError):
        raise ControlError("Local Codex authentication requires its original home, an executable CLI, and an isolated private client directory") from None
    options = ["--auth-source", "local_codex", "--local-codex-binary", str(binary),
               "--local-codex-home", str(home), "--auth-cwd", str(cwd)]
    if "source_path" in config:
        options += ["--auth-source-path", str(Path(config["source_path"]).resolve(strict=True))]
    return options


def codex_server(config: dict) -> None:
    if config.get("worker_launch_enabled") is not True:
        raise ControlError("Live workers are disabled until isolation, cancellation, authentication and pilot acceptance are verified")
    # The sole credential can currently belong to another stage. The wrapper
    # waits for its durable lease; checking only the master file loses that fact.
    rules = Path(config["state_dir"]) / "bin/codex-rules"
    if not rules.is_file():
        raise ControlError("Managed worker rules are not installed; run profile.py install-rules")
    image = config.get("worker_image_id", "")
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", image):
        raise ControlError("Verified immutable worker image ID is missing")
    auth_options = worker_auth_options(config)
    launch_options = container_launch_options(config)
    # Rule synchronization runs on the host. The worker sees only its dedicated
    # Codex home and its own checkout mounted into a separate PID namespace.
    run(str(rules), "sync", env=dict(os.environ, CODEX_HOME=config["codex_home"]))
    env = worker_env(config)
    for key in ("SYMPHONY_CONTAINER_CIDFILE", "SYMPHONY_CONTAINER_OWNER", "SYMPHONY_WORKER_ROLE"):
        if not os.environ.get(key):
            raise ControlError("Worker must be launched by the process guardian: " + key)
        env[key] = os.environ[key]
    retained_id = os.environ.get("SYMPHONY_PR_WORK_ID")
    resume = os.environ.get("SYMPHONY_PR_WORK_RESUME")
    if retained_id is not None:
        if (env["SYMPHONY_WORKER_ROLE"] != "builder" or not re.fullmatch(r"[a-f0-9]{32}", retained_id)
                or resume not in (None, "true")):
            raise ControlError("Invalid retained builder identity")
        env["SYMPHONY_PR_WORK_ID"] = retained_id
        if resume:
            env["SYMPHONY_PR_WORK_RESUME"] = resume
    elif resume is not None:
        raise ControlError("Retained builder resume requires a work identity")
    wrapper = ROOT / "tools/container_worker.py"
    os.execve(sys.executable, [sys.executable, "-I", str(wrapper), "--workspace", str(Path.cwd()),
                             "--codex-home", config["codex_home"], "--image", image,
                             *auth_options, *launch_options], env)


def install_rules(config: dict) -> dict:
    env = dict(os.environ, CODEX_HOME=config["codex_home"])
    run(sys.executable, config["rules_source"], "install",
        "--real-codex", config["codex_binary"], "--bin-dir", str(Path(config["state_dir"]) / "bin"), env=env)
    return {"installed": True, "codex_home": config["codex_home"]}


def worker_auth_status(config: dict) -> dict:
    source = config.get("worker_auth_source", "dedicated")
    if source == "local_codex":
        try:
            worker_auth_options(config)
            return cached_status(binary=config["local_codex_binary"], home=config["local_codex_home"], cwd=config["worker_home"])
        except (ControlError, OSError, ValueError):
            return {"state": "recovery", "source": source, "credential_present": False,
                    "sign_in_required": True, "provider_verified": False}
    if source != "dedicated":
        return {"state": "recovery", "source": "invalid", "credential_present": False,
                "sign_in_required": True, "provider_verified": False}
    try:
        worker_auth_options(config)
        return dict(AuthLease(config["codex_home"]).status(), source=source)
    except (AuthLeaseError, ControlError, OSError, ValueError):
        return {"state": "recovery", "source": source, "credential_present": False,
                "sign_in_required": True, "provider_verified": False}


def worker_login(config: dict) -> None:
    worker_auth_options(config)
    if config.get("worker_auth_source", "dedicated") == "local_codex":
        raise ControlError("Local Codex authentication uses the original CLI sign-in; this profile does not enroll or copy credentials")
    try:
        with AuthLease(config["codex_home"]).enrollment() as home:
            env = worker_env(config)
            env["CODEX_HOME"] = str(home)
            try:
                status = subprocess.run([config["codex_binary"], "login", "--device-auth"], env=env).returncode
            except (FileNotFoundError, PermissionError):
                # Popen reports these only after its failed exec child is
                # settled. Other interruptions retain the durable claim.
                status = 127
        if status:
            raise ControlError("Dedicated worker sign-in did not complete")
    except (AuthLeaseError, OSError) as exc:
        raise ControlError("Dedicated worker sign-in is in use or unavailable; reconcile its ownership first") from exc


def google_oauth_environment(config: dict) -> dict:
    """Load only a configured Google web client's credentials for the controller."""
    if "google_oauth_client_file" not in config:
        return {}
    try:
        location = config["google_oauth_client_file"]
        if not isinstance(location, str) or not Path(location).is_absolute():
            raise ValueError("Invalid credential path")
        path = Path(location)
        if stat.S_IMODE(path.lstat().st_mode) != 0o600:
            raise ValueError("Invalid credential permissions")
        document = json.loads(read_private(path))
        client = document["web"]
        client_id, secret = client["client_id"], client["client_secret"]
        if (not isinstance(client_id, str) or len(client_id) > 512
                or not re.fullmatch(r"[A-Za-z0-9._-]+\.apps\.googleusercontent\.com", client_id)
                or not isinstance(secret, str) or not 1 <= len(secret) <= 4096
                or any(char.isspace() or ord(char) < 32 or ord(char) > 126 for char in secret)):
            raise ValueError("Invalid web client")
    except (OSError, ValueError, TypeError, KeyError, ControlError):
        # No JSON contents, paths or underlying exception text enter diagnostics.
        raise ControlError("Google OAuth client file must be an owned regular mode-0600 file containing a valid web client") from None
    return {"SYMPHONY_GOOGLE_CLIENT_ID": client_id, "SYMPHONY_GOOGLE_CLIENT_SECRET": secret}


def openrouter_environment(config: dict) -> dict:
    """Read only the explicitly configured OpenRouter key; never source an env file."""
    if "openrouter_env_file" not in config:
        return {}
    try:
        location = config["openrouter_env_file"]
        if not isinstance(location, str) or not Path(location).is_absolute():
            raise ValueError("Invalid credential path")
        matches = re.findall(r"^\s*(?:export\s+)?OPENROUTER_API_KEY\s*=\s*(.*?)\s*$",
                             read_private(Path(location)), re.MULTILINE)
        if len(matches) != 1:
            raise ValueError("Missing or duplicate key")
        key = matches[0]
        if len(key) >= 2 and key[0] in ('\"', "'") and key[-1] == key[0]:
            key = key[1:-1]
        if not re.fullmatch(r"[A-Za-z0-9_-]{16,4096}", key):
            raise ValueError("Invalid key")
    except (OSError, ValueError, TypeError, ControlError):
        raise ControlError("OpenRouter env file must be an owned private regular file with one valid OPENROUTER_API_KEY") from None
    return {"OPENROUTER_API_KEY": key}


def start_service(config: dict) -> None:
    validate_workflow(read_private(Path(config["workflow_path"])), config.get("repository", REPOSITORY))
    binary = ROOT / "elixir/bin/symphony"
    if not binary.is_file():
        raise ControlError("Build Symphony first: cd elixir && mix build")
    env = dict(os.environ)
    env.update(google_oauth_environment(config))
    env.update(openrouter_environment(config))
    # Host-owned auth is never serialized to workflow/config files.
    token = os.environ.get("GITHUB_TOKEN") or run("gh", "auth", "token")
    env.update({
        "GITHUB_TOKEN": token, "SYMPHONY_CONTROL_TOKEN": config["_token"],
        "SYMPHONY_BASE_SHA": config["base_sha"],
        "SYMPHONY_CONTROL_STATE": str(Path(config["state_dir"]) / "control.json"),
        "SYMPHONY_WORKSPACE_ROOT": config["workspace_root"],
        "SYMPHONY_PROFILE_BIN": config["profile_bin"],
        "SYMPHONY_PROFILE_PYTHON": sys.executable,
        "SYMPHONY_OPERATOR_CONFIG": config["_config_path"], "ERL_FLAGS": "+S 4:4",
    })
    if config.get("repository") == "iliazlobin/symphony":
        # Native task intake needs its own durable action store even before the
        # separately authenticated model runtime is configured.
        env.update({
            "SYMPHONY_CHAT_STATE": str(Path(config["state_dir"]) / "chat"),
            "SYMPHONY_CHAT_CODEX_HOME": str(Path(config["state_dir"]) / "management-codex"),
            "SYMPHONY_CHAT_CODEX_EXECUTABLE": config.get("management_codex_binary", ""),
        })
    pinned_bin = ROOT / ".runtime/elixir-1.19.5/bin"
    if pinned_bin.is_dir():
        env["PATH"] = str(pinned_bin) + ":/opt/homebrew/opt/erlang@28/bin:" + env.get("PATH", WORKER_PATH)
    from urllib.parse import urlsplit
    port = "0" if os.environ.get("SYMPHONY_WORKSPACE_ENGINE_SOCKET") else str(urlsplit(config["api_url"]).port)
    os.chdir(ROOT / "elixir")
    os.execve(str(binary), [str(binary), config["workflow_path"], "--port", port,
                           "--logs-root", str(Path(config["state_dir"]) / "logs"),
                           "--i-understand-that-this-will-be-running-without-the-usual-guardrails"], env)


def main(repository: str = REPOSITORY, profile_bin: Path | None = None) -> int:
    project = project_settings(repository)
    default_config = DEFAULT_CONFIG.parent.parent / project["slug"] / "config.json"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config")
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init")
    init.add_argument("--state-dir", default=str(default_config.parent))
    init.add_argument("--source", required=True)
    init.add_argument("--base-sha", required=True)
    init.add_argument("--integration-branch", help="Leave unset while the owner selects the target; publication stays blocked")
    init.add_argument("--port", type=int, default=project["port"])
    for action in ("workspace-create", "before-run", "codex-server", "run", "install-rules", "login", "doctor"):
        sub.add_parser(action)
    args = parser.parse_args()
    try:
        if args.command == "init":
            result = initialize(args, repository, profile_bin)
        else:
            config = load_config(args.config or os.environ.get("SYMPHONY_OPERATOR_CONFIG", str(default_config)))
            if config.get("repository") != repository:
                raise ControlError("Operator configuration does not belong to this project profile")
            if args.command == "workspace-create":
                result = workspace_create(config)
            elif args.command == "before-run":
                result = before_run(config)
            elif args.command == "codex-server":
                codex_server(config)
            elif args.command == "run":
                start_service(config)
            elif args.command == "install-rules":
                result = install_rules(config)
            elif args.command == "login":
                worker_login(config)
                result = {"login_completed": True}
            elif args.command == "doctor":
                try:
                    container_launch_options(config)
                    sandbox_source_verified = True
                except (ControlError, OSError, ValueError):
                    sandbox_source_verified = False
                result = {
                    "repository": config["repository"], "base_sha": config["base_sha"],
                    "integration_branch": config["integration_branch"],
                    "worker_auth": worker_auth_status(config),
                    "managed_rules_present": (Path(config["state_dir"]) / "bin/codex-managed").is_file(),
                    "compiled_service_present": (ROOT / "elixir/bin/symphony").is_file(),
                    "auto_merge_enabled": config["auto_merge"]["enabled"],
                    "worker_launch_enabled": config.get("worker_launch_enabled", False),
                    "worker_sandbox_source_verified": sandbox_source_verified,
                }
        print(json.dumps(result, indent=2))
        return 0
    except WorkspaceBaselineChanged:
        print(WORKSPACE_BASELINE_CHANGED_MARKER, file=sys.stderr)
        return WORKSPACE_BASELINE_CHANGED_EXIT
    except (ControlError, OSError, KeyError, ValueError, subprocess.TimeoutExpired) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
