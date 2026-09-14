#!/usr/bin/env python3
"""Install and inspect the two local Symphony launch agents; no task scheduler."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys

from symphony_control import ControlError, load_config, read_private

ROOT = Path(__file__).resolve().parents[1]
LABEL = "com.iliazlobin.symphony.events-concierge"


def definitions(config):
    state = Path(config["state_dir"])
    commands = {
        LABEL: [sys.executable, str(ROOT / "profiles/events-concierge/profile.py"), "--config", config["_config_path"], "run"],
        LABEL + ".publication": [sys.executable, str(ROOT / "tools/symphony_publish.py"), "--config", config["_config_path"], "watch"],
    }
    return {label: {
        "Label": label, "ProgramArguments": command, "WorkingDirectory": str(ROOT),
        "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 30, "Umask": 0o077,
        "EnvironmentVariables": {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"},
        "StandardOutPath": str(state / "logs" / (label + ".out.log")),
        "StandardErrorPath": str(state / "logs" / (label + ".err.log")),
    } for label, command in commands.items()}


def launchctl(*args, check=True):
    result = subprocess.run(["launchctl", *args], capture_output=True, text=True, timeout=15)
    if check and result.returncode:
        raise ControlError("launchctl failed: " + result.stderr.strip()[:1500])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config")
    parser.add_argument("command", choices=("install", "start", "stop", "status"))
    args = parser.parse_args()
    config = load_config(args.config)
    if sys.platform != "darwin":
        raise ControlError("Launch agents are available only on macOS")
    directory = Path.home() / "Library/LaunchAgents"
    domain = "gui/" + str(os.getuid())
    if args.command == "stop":
        errors = []
        for label in reversed(list(definitions(config))):
            existing = launchctl("print", domain + "/" + label, check=False)
            if not existing.returncode:
                result = launchctl("bootout", domain + "/" + label, check=False)
                if result.returncode:
                    errors.append(label + ": " + result.stderr.strip()[:500])
                    continue
            print("Unloaded " + label)
        if errors:
            raise ControlError("Some services could not be stopped: " + "; ".join(errors))
        return
    for label, definition in definitions(config).items():
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
