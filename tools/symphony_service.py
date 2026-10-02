#!/usr/bin/env python3
"""Install and inspect project or unified workspace launch agents; no task scheduler."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time

from symphony_control import ControlError, load_config, read_private

ROOT = Path(__file__).resolve().parents[1]
PROJECTS = {
    "iliazlobin/events-concierge": "events-concierge",
    "iliazlobin/symphony": "symphony",
}


def definitions(config):
    slug = PROJECTS.get(config.get("repository"))
    if slug is None:
        raise ControlError("No reviewed service definition exists for this repository")
    label = "com.iliazlobin.symphony." + slug
    profile = ROOT / "profiles" / slug / "profile.py"
    if Path(config["profile_bin"]).resolve() != profile.resolve():
        raise ControlError("Profile entrypoint does not match the service's repository and release")
    state = Path(config["state_dir"])
    commands = {
        label: [sys.executable, str(profile), "--config", config["_config_path"], "run"],
        label + ".publication": [sys.executable, str(ROOT / "tools/symphony_publish.py"), "--config", config["_config_path"], "watch"],
    }
    return {label: {
        "Label": label, "ProgramArguments": command, "WorkingDirectory": str(ROOT),
        "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 30, "Umask": 0o077,
        "EnvironmentVariables": {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"},
        "StandardOutPath": str(state / "logs" / (label + ".out.log")),
        "StandardErrorPath": str(state / "logs" / (label + ".err.log")),
    } for label, command in commands.items()}


def workspace_definitions(path):
    from symphony_workspace import load_workspace
    config = load_workspace(path)
    for slug, project in config["projects"].items():
        expected = ROOT / "profiles" / slug / "profile.py"
        if Path(project["profile_bin"]).resolve() != expected.resolve():
            raise ControlError("Workspace project must use this release profile")
    label = "com.iliazlobin.symphony.workspace"
    state = Path(config["state_dir"])
    return {label: {
        "Label": label, "ProgramArguments": [sys.executable, str(ROOT / "tools/symphony_workspace.py"), "--config", str(Path(path).resolve()), "run"],
        "WorkingDirectory": str(ROOT), "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 30, "Umask": 0o077,
        "EnvironmentVariables": {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"},
        "StandardOutPath": str(state / "workspace.out.log"), "StandardErrorPath": str(state / "workspace.err.log"),
    }}


def launchctl(*args, check=True):
    result = subprocess.run(["launchctl", *args], capture_output=True, text=True, timeout=15)
    if check and result.returncode:
        raise ControlError("launchctl failed: " + result.stderr.strip()[:1500])
    return result


def wait_unloaded(domain, label):
    # bootout can return before launchd removes the job. A following start would
    # otherwise mistake the departing job for an already-running service.
    deadline = time.monotonic() + 10
    while not launchctl("print", domain + "/" + label, check=False).returncode:
        if time.monotonic() >= deadline:
            raise ControlError("Service has not finished unloading: " + label)
        time.sleep(0.1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config")
    parser.add_argument("--workspace-config")
    parser.add_argument("command", choices=("install", "start", "stop", "status"))
    args = parser.parse_args()
    if args.config and args.workspace_config:
        raise ControlError("Select one project or workspace service")
    service_definitions = workspace_definitions(args.workspace_config) if args.workspace_config else definitions(load_config(args.config))
    if sys.platform != "darwin":
        raise ControlError("Launch agents are available only on macOS")
    directory = Path.home() / "Library/LaunchAgents"
    domain = "gui/" + str(os.getuid())
    if args.command == "stop":
        if args.workspace_config:
            from symphony_workspace import load_workspace
            from symphony_control import request_json
            workspace = load_workspace(args.workspace_config)
            for project in workspace["projects"].values():
                snapshot = request_json(project, "/api/v1/state")
                if snapshot.get("running") != [] or snapshot.get("retrying") != []:
                    raise ControlError("Drain and settle active work before stopping the workspace")
        errors = []
        for label in reversed(list(service_definitions)):
            existing = launchctl("print", domain + "/" + label, check=False)
            if not existing.returncode:
                result = launchctl("bootout", domain + "/" + label, check=False)
                if result.returncode:
                    errors.append(label + ": " + result.stderr.strip()[:500])
                    continue
                try:
                    wait_unloaded(domain, label)
                except (ControlError, subprocess.TimeoutExpired) as exc:
                    errors.append(str(exc))
                    continue
            print("Unloaded " + label)
        if errors:
            raise ControlError("Some services could not be stopped: " + "; ".join(errors))
        return
    for label, definition in service_definitions.items():
        path = directory / (label + ".plist")
        if args.command == "install":
            directory.mkdir(exist_ok=True, parents=True)
            if path.exists() or path.is_symlink():
                if plistlib.loads(read_private(path).encode()) != definition:
                    raise ControlError("Existing launch agent differs; review it before replacement: " + str(path))
            else:
                descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(descriptor, "wb") as stream:
                    plistlib.dump(definition, stream)
            print("Installed " + label)
        elif args.command == "start":
            if plistlib.loads(read_private(path).encode()) != definition:
                raise ControlError("Launch agent does not match the reviewed service definition")
            existing = launchctl("print", domain + "/" + label, check=False)
            if existing.returncode:
                launchctl("bootstrap", domain, str(path))
            print("Loaded " + label)
        else:
            existing = launchctl("print", domain + "/" + label, check=False)
            lines = [line.strip() for line in existing.stdout.splitlines() if line.strip().startswith(("state =", "pid =", "last exit code ="))]
            print(label + ": " + ("; ".join(lines) if existing.returncode == 0 else "not loaded"))


if __name__ == "__main__":
    try:
        main()
    except (ControlError, OSError, ValueError, subprocess.TimeoutExpired) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
