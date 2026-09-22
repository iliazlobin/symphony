#!/usr/bin/env python3
"""Events Concierge host setup and trusted workspace hooks for Symphony."""
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

REPOSITORY = "iliazlobin/events-concierge"
REMOTE = "https://github.com/" + REPOSITORY + ".git"
SHA = re.compile(r"[0-9a-f]{40}")
WORKER_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
COMMAND_PATH = "/usr/local/bin:/usr/bin:/bin"


def run(*args: str, cwd: Path | None = None, env: dict | None = None) -> str:
    if args[0] == "git":
        args = ("git", "--no-replace-objects", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", *args[1:])
        env = dict(os.environ if env is None else env, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
    result = subprocess.run(list(args), cwd=cwd, env=env, capture_output=True, text=True, timeout=120)
    if result.returncode:
        # Commands never include credentials; avoid echoing environments or token outputs.
        raise ControlError(f"{args[0]} failed: {result.stderr.strip()[:1500]}")
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


def validate_workflow(workflow: str) -> None:
    pieces = workflow.split("---\n", 2)
    if len(pieces) != 3 or pieces[0].strip():
        raise ControlError("Workflow must start with YAML front matter")
    try:
        settings = yaml.safe_load(pieces[1])
        tracker, controls = settings["tracker"], settings["control"]
        concurrency = settings["agent"]["max_concurrent_agents"]
        valid = (tracker["kind"] == "github" and tracker["provider"]["repo"] == REPOSITORY
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


def initialize(args) -> dict:
    state = Path(args.state_dir).expanduser().resolve()
    source = Path(args.source).expanduser().resolve()
    base = args.base_sha
    if not SHA.fullmatch(base):
        raise ControlError("The source baseline must be a full lowercase commit SHA")
    if run("git", "rev-parse", "--verify", base + "^{commit}", cwd=source) != base:
        raise ControlError("Source baseline does not resolve")
    origin = run("git", "config", "--get", "remote.origin.url", cwd=source)
    if origin not in (REMOTE, REMOTE[:-4], "git@github.com:" + REPOSITORY + ".git"):
        raise ControlError("Unexpected Events Concierge source repository")
    if args.integration_branch and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", args.integration_branch):
        raise ControlError("Invalid integration branch")
    workflow = run("git", "show", base + ":WORKFLOW.md", cwd=source) + "\n"
    validate_workflow(workflow)
    config_file = state / "config.json"
    if config_file.exists():
        raise ControlError("Operator configuration already exists; review changes explicitly")
    private_directory(state)
    for directory in ("workspaces", "logs", "worker-home", "codex", "bin", "receipts"):
        private_directory(state / directory)
    config = {
        "repository": REPOSITORY, "source_path": str(source), "base_sha": base,
        "integration_branch": args.integration_branch, "state_dir": str(state),
        "workflow_path": str(state / "WORKFLOW.md"), "workspace_root": str(state / "workspaces"),
        "codex_home": str(state / "codex"), "worker_home": str(state / "worker-home"),
        "api_url": "http://127.0.0.1:" + str(args.port),
        "token_file": str(state / "control.token"),
        "profile_bin": str(Path(__file__).resolve()),
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
    write_private(state / "WORKFLOW.md", workflow)
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
    run("git", "remote", "set-url", "origin", REMOTE, cwd=current, env=env)
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
    if run("git", "remote", "get-url", "origin", cwd=current) != REMOTE:
        raise ControlError("Unexpected source remote")
    run("git", "merge-base", "--is-ancestor", config["base_sha"], "HEAD", cwd=current)
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
    policy = Path(config["state_dir"]) / "worker-apparmor"
    seccomp = ROOT / "profiles/events-concierge/seccomp-codex.json"
    if (sandbox.get("apparmor_profile") != "symphony-codex"
            or sandbox.get("workspace_root") != str(root)):
        raise ControlError("Reviewed workspace-scoped worker sandbox configuration is missing")
    content = read_private(policy)
    if content != render_policy(root):
        raise ControlError("Worker AppArmor source does not match the configured workspace root")
    for name, data in (("apparmor_sha256", content.encode()), ("seccomp_sha256", seccomp.read_bytes())):
        if sandbox.get(name) != hashlib.sha256(data).hexdigest():
            raise ControlError("Worker sandbox policy changed; review and reinstall it before launch")
    return ["--seccomp-policy", str(seccomp), "--apparmor-profile", "symphony-codex"]


def codex_server(config: dict) -> None:
    if config.get("worker_launch_enabled") is not True:
        raise ControlError("Live workers are disabled until isolation, cancellation, authentication and pilot acceptance are verified")
    home = Path(config["codex_home"])
    if not (home / "auth.json").is_file():
        raise ControlError("Dedicated worker Codex login is missing; run profile.py login")
    rules = Path(config["state_dir"]) / "bin/codex-rules"
    if not rules.is_file():
        raise ControlError("Managed worker rules are not installed; run profile.py install-rules")
    image = config.get("worker_image_id", "")
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", image):
        raise ControlError("Verified immutable worker image ID is missing")
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
                             "--codex-home", config["codex_home"], "--image", image, *launch_options], env)


def install_rules(config: dict) -> dict:
    env = dict(os.environ, CODEX_HOME=config["codex_home"])
    run(sys.executable, config["rules_source"], "install",
        "--real-codex", config["codex_binary"], "--bin-dir", str(Path(config["state_dir"]) / "bin"), env=env)
    return {"installed": True, "codex_home": config["codex_home"]}


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


def start_service(config: dict) -> None:
    validate_workflow(read_private(Path(config["workflow_path"])))
    binary = ROOT / "elixir/bin/symphony"
    if not binary.is_file():
        raise ControlError("Build Symphony first: cd elixir && mix build")
    env = dict(os.environ)
    env.update(google_oauth_environment(config))
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
    pinned_bin = ROOT / ".runtime/elixir-1.19.5/bin"
    if pinned_bin.is_dir():
        env["PATH"] = str(pinned_bin) + ":/opt/homebrew/opt/erlang@28/bin:" + env.get("PATH", WORKER_PATH)
    port = config["api_url"].rsplit(":", 1)[1]
    os.chdir(ROOT / "elixir")
    os.execve(str(binary), [str(binary), config["workflow_path"], "--port", port,
                           "--logs-root", str(Path(config["state_dir"]) / "logs"),
                           "--i-understand-that-this-will-be-running-without-the-usual-guardrails"], env)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config")
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init")
    init.add_argument("--state-dir", default=str(DEFAULT_CONFIG.parent))
    init.add_argument("--source", required=True)
    init.add_argument("--base-sha", required=True)
    init.add_argument("--integration-branch", help="Leave unset while the owner selects the target; publication stays blocked")
    init.add_argument("--port", type=int, default=8777)
    for action in ("workspace-create", "before-run", "codex-server", "run", "install-rules", "login", "doctor"):
        sub.add_parser(action)
    args = parser.parse_args()
    try:
        if args.command == "init":
            result = initialize(args)
        else:
            config = load_config(args.config)
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
                env = dict(os.environ, CODEX_HOME=config["codex_home"])
                os.execve(config["codex_binary"], [config["codex_binary"], "login", "--device-auth"], env)
            elif args.command == "doctor":
                try:
                    container_launch_options(config)
                    sandbox_source_verified = True
                except (ControlError, OSError, ValueError):
                    sandbox_source_verified = False
                result = {
                    "repository": config["repository"], "base_sha": config["base_sha"],
                    "integration_branch": config["integration_branch"],
                    "worker_auth_present": (Path(config["codex_home"]) / "auth.json").is_file(),
                    "managed_rules_present": (Path(config["state_dir"]) / "bin/codex-managed").is_file(),
                    "compiled_service_present": (ROOT / "elixir/bin/symphony").is_file(),
                    "auto_merge_enabled": config["auto_merge"]["enabled"],
                    "worker_launch_enabled": config.get("worker_launch_enabled", False),
                    "worker_sandbox_source_verified": sandbox_source_verified,
                }
        print(json.dumps(result, indent=2))
        return 0
    except (ControlError, OSError, KeyError, ValueError, subprocess.TimeoutExpired) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
