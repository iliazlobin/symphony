#!/usr/bin/env python3
"""Run the read-only web board bound to one existing local operator profile.

The profile supplies the GitHub repository and existing controller address. This
launcher starts only the standalone Phoenix entrypoint, never another scheduler,
coding worker, publisher or owner of the controller's durable ledger. The board's
server-side upstream token is not installed as a browser operator token.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.parse

from symphony_control import ControlError, load_config, read_private

ROOT = Path(__file__).resolve().parents[1]
PINNED_ELIXIR = "elixir-1.19.5"


def tracker_scope(config: dict) -> dict:
    """Read only the GitHub intake scope, excluding worker hooks and credentials."""
    try:
        import yaml
    except ImportError:
        raise ControlError("PyYAML is required; use a Python environment with PyYAML installed") from None

    content = read_private(Path(config["workflow_path"]).expanduser())
    front = re.match(r"\A---\r?\n(.*?)\r?\n---(?:\r?\n|\Z)", content, re.DOTALL)
    if not front:
        raise ControlError("The configured workflow requires YAML front matter")
    try:
        workflow = yaml.safe_load(front.group(1))
    except yaml.YAMLError:
        raise ControlError("The configured workflow has invalid YAML front matter") from None

    tracker = workflow.get("tracker") if isinstance(workflow, dict) else None
    provider = tracker.get("provider") if isinstance(tracker, dict) else None
    repo = config.get("repository")
    if (not isinstance(repo, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo)
            or not isinstance(provider, dict) or tracker.get("kind") != "github"
            or provider.get("repo") != repo):
        raise ControlError("Workflow GitHub repository must match the operator profile repository")
    if provider.get("api_url", "https://api.github.com") != "https://api.github.com":
        raise ControlError("This local board launcher supports github.com profiles only")
    labels = tracker.get("required_labels", [])
    if not isinstance(labels, list) or any(not isinstance(label, str) or not label.strip() for label in labels):
        raise ControlError("Workflow required_labels must be a list of nonempty labels")
    return {"kind": "github", "provider": {"repo": repo, "api_url": "https://api.github.com", "token": "$GITHUB_TOKEN"},
            "required_labels": labels, "active_states": ["open"], "terminal_states": ["closed"]}


def runtime_directory(repository: Path) -> Path:
    """Find the existing pinned runtime in this checkout or its Git common root."""
    local = repository / ".runtime"
    if runtime_ready(local):
        return local
    try:
        common = subprocess.run(
            ["git", "-C", str(repository), "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True, timeout=10, check=False,
        )
        if common.returncode == 0:
            candidate = Path(common.stdout.strip()).resolve().parent / ".runtime"
            if runtime_ready(candidate):
                return candidate
    except (OSError, subprocess.TimeoutExpired):
        pass
    raise ControlError("Pinned Elixir 1.19.5 and mix-1.19 runtime not found in checkout/common-root .runtime; follow the profile setup guide")


def runtime_ready(candidate: Path) -> bool:
    mix = candidate / PINNED_ELIXIR / "bin/mix"
    return mix.is_file() and os.access(mix, os.X_OK) and (candidate / "mix-1.19").is_dir()


def github_token(environment: dict) -> str:
    token = environment.get("GITHUB_TOKEN", "").strip()
    if not token:
        try:
            result = subprocess.run(
                ["gh", "auth", "token", "--hostname", "github.com"],
                capture_output=True, text=True, timeout=15, check=False, env=environment,
            )
        except (OSError, subprocess.TimeoutExpired):
            raise ControlError("GitHub authentication unavailable; sign in with gh auth login --hostname github.com") from None
        if result.returncode != 0:
            raise ControlError("GitHub authentication unavailable; sign in with gh auth login --hostname github.com")
        token = result.stdout.strip()
    if not token or len(token) > 4096 or any(character.isspace() for character in token):
        raise ControlError("GitHub returned an invalid authentication token")
    return token


def child_environment(config: dict, runtime: Path, environment: dict) -> dict:
    env = dict(environment)
    token = github_token(env)
    # The standalone VM must not inherit browser authority or worker launch wiring.
    for name in list(env):
        if name.startswith("SYMPHONY_") or name in ["ERL_AFLAGS", "ERL_ZFLAGS", "ELIXIR_ERL_OPTIONS"]:
            env.pop(name)
    env.update({
        "GITHUB_TOKEN": token,
        "SYMPHONY_BOARD_API_URL": config["api_url"],
        "SYMPHONY_BOARD_CONTROL_TOKEN": config["_token"],
        "MIX_HOME": str(runtime / "mix-1.19"),
        "MIX_ENV": "dev",
        "ERL_FLAGS": "+S 4:4",
        "PATH": str(runtime / PINNED_ELIXIR / "bin") + ":/opt/homebrew/opt/erlang@28/bin:" + env.get("PATH", os.defpath),
    })
    return env


def write_workflow(root: Path, tracker: dict) -> Path:
    workspace = root / "workspaces"
    workspace.mkdir(mode=0o700)
    config = {
        "tracker": tracker,
        "control": {"enabled": True, "state_path": str(root / "control.json"), "initial_mode": "paused"},
        "chat": {"enabled": False},
        "server": {"port": None, "host": "127.0.0.1"},
        "observability": {"dashboard_enabled": False},
        "workspace": {"root": str(workspace)},
    }
    workflow = root / "WORKFLOW.md"
    fd = os.open(workflow, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write("---\n" + json.dumps(config, indent=2) + "\n---\nRead-only board; no worker execution.\n")
    return workflow


def group_exists(pid: int) -> bool:
    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False


def signal_group(pid: int, signum: int) -> None:
    try:
        os.killpg(pid, signum)
    except ProcessLookupError:
        pass


def stop_child(child: subprocess.Popen, timeout: float = 5) -> None:
    """Stop the owned group, including descendants after its direct child exits."""
    signal_group(child.pid, signal.SIGTERM)
    try:
        child.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        signal_group(child.pid, signal.SIGKILL)
        child.wait(timeout=timeout)
    if group_exists(child.pid):
        signal_group(child.pid, signal.SIGKILL)
        deadline = time.monotonic() + timeout
        while group_exists(child.pid):
            if time.monotonic() >= deadline:
                raise ControlError("Read-only web process group did not finish stopping")
            time.sleep(0.05)


def launch(config: dict, port: int, repository: Path = ROOT) -> int:
    upstream_port = urllib.parse.urlsplit(config["api_url"]).port
    if type(port) is not int or not 1 <= port <= 65535 or port == upstream_port:
        raise ControlError("Choose a port from 1 to 65535 different from the existing controller port")
    tracker = tracker_scope(config)
    runtime = runtime_directory(repository)
    environment = child_environment(config, runtime, os.environ)
    entrypoint = repository / "elixir/tools/read_only_board.exs"
    if not entrypoint.is_file():
        raise ControlError("Standalone board entrypoint is missing; use the reviewed Symphony checkout")

    root = Path(tempfile.mkdtemp(prefix="symphony-read-only-web-"))
    child = None
    interrupted = [None]
    handlers = {}

    def request_stop(signum, _frame):
        interrupted[0] = signum

    try:
        workflow = write_workflow(root, tracker)
        for signum in [signal.SIGINT, signal.SIGTERM]:
            handlers[signum] = signal.signal(signum, request_stop)
        command = [str(runtime / PINNED_ELIXIR / "bin/mix"), "run", "--no-start", str(entrypoint), str(workflow), str(port)]
        child = subprocess.Popen(command, cwd=repository / "elixir", env=environment, start_new_session=True)
        while interrupted[0] is None:
            try:
                return child.wait(timeout=0.25)
            except subprocess.TimeoutExpired:
                pass
        return 128 + interrupted[0]
    finally:
        try:
            if child is not None:
                stop_child(child)
        except (ControlError, OSError, subprocess.TimeoutExpired):
            raise ControlError("Web process cleanup is uncertain; retained private temporary configuration at " + str(root)) from None
        else:
            shutil.rmtree(root)
        finally:
            for signum, previous in handlers.items():
                signal.signal(signum, previous)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", help="Existing private Symphony operator config.json")
    parser.add_argument("--port", type=int, default=8778)
    args = parser.parse_args(argv)
    try:
        return launch(load_config(args.config), args.port)
    except (ControlError, OSError, KeyError, ValueError, subprocess.TimeoutExpired) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
