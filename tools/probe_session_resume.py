#!/usr/bin/env python3
"""Check real native thread resume in a disposable, credential-free Codex home.

Starts no model turn, task command, production worker, or account connection. This verifies the
App Server protocol and persistence only; it does not certify container isolation.

Some Codex versions do not persist an empty thread until its first turn. For
those versions this probe intentionally fails on resume with "no rollout found";
it must not be reported as proof that a completed coding session can resume.
The owner must retain that interrupted record for explicit recovery instead of
silently replacing its checkpointed thread ID.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import textwrap

from probe_cancellation import Connection, disposable_root
from probe_runtime import resolve_runtime


@contextmanager
def app_server(command, root, workspace, environment, guardian, label):
    process = subprocess.Popen(
        ["/opt/homebrew/bin/python3", "-I", "-u", "-c", guardian,
         str(root / (label + ".lock"))] + command,
        cwd=workspace, env=environment, stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    connection = Connection(process)
    try:
        connection.send({"id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "symphony-resume-probe", "version": "1"},
            "capabilities": {"experimentalApi": True},
        }})
        connection.response(1, timeout=30)
        connection.send({"method": "initialized", "params": {}})
        yield connection
    finally:
        connection.selector.close()
        process.stdin.close()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            # This exact owned handle, never a discovered process ID.
            process.terminate()
            process.wait(timeout=5)
        process.stdout.close()


def verify_thread(response, workspace, expected_id=None):
    thread = response.get("thread", {})
    thread_id = thread.get("id")
    if not isinstance(thread_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", thread_id):
        raise RuntimeError("Native thread ID is unavailable or invalid")
    if expected_id is not None and thread_id != expected_id:
        raise RuntimeError("Native thread identity changed on resume")
    if response.get("cwd") != str(workspace) or response.get("approvalPolicy") != "never":
        raise RuntimeError("Native thread cwd or approval policy does not match")
    if response.get("activePermissionProfile", {}).get("id") != "symphony-builder":
        raise RuntimeError("Named builder permission profile was not activated")
    return thread_id


def probe(binary, container_image=None, fixture_parent=None, seccomp_policy=None, apparmor_profile=None,
          operator_config=None):
    repository = Path(__file__).resolve().parents[1]
    source = (repository / "elixir/lib/symphony_elixir/process_group.ex").read_text()
    matched = re.search(r'@guardian ~S"""\n(.*?)\n  """', source, re.S)
    if matched is None:
        raise RuntimeError("Cannot locate production process guardian")
    guardian = textwrap.dedent(matched.group(1))
    spec = importlib.util.spec_from_file_location("profile", repository / "profiles/events-concierge/profile.py")
    profile = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(profile)

    runtime = resolve_runtime(profile, repository, container_image, seccomp_policy,
                              apparmor_profile, fixture_parent, operator_config)
    container_image = runtime["image"]
    with disposable_root(runtime["parent"] or "/private/tmp", fixed=runtime["operational"]) as root:
        # Operational policies reserve this exact disposable command-canary cwd.
        home, workspace = root / "codex", root / ("pipe" if runtime["operational"] else "workspace")
        home.mkdir(mode=0o700)
        workspace.mkdir(mode=0o700)
        (home / "config.toml").write_text('cli_auth_credentials_store = "file"\n' + profile.permission_config())
        environment = {"PATH": profile.WORKER_PATH,
                       "HOME": str(Path.home() if container_image else home), "CODEX_HOME": str(home)}
        command = [binary, "app-server"]
        version = None
        if container_image:
            inspected = subprocess.run(
                ["docker", "--context", "colima", "image", "inspect", container_image, "--format", "{{.Id}}"],
                env=environment, capture_output=True, text=True, timeout=10, check=True,
            )
            if inspected.stdout.strip() != container_image:
                raise RuntimeError("The exact requested immutable image is not cached")
            # The exact production wrapper, with a retained builder home scoped
            # only to this freshly generated disposable PR-work identity.
            environment.update(SYMPHONY_WORKER_ROLE="builder", SYMPHONY_PR_WORK_ID=os.urandom(16).hex())
            command = ["/opt/homebrew/bin/python3", "-I", str(repository / "tools/container_worker.py"),
                       "--workspace", str(workspace), "--codex-home", str(home), "--image", container_image]
            command += runtime["options"]
        else:
            version = subprocess.run([binary, "--version"], env=environment, cwd=workspace,
                                     capture_output=True, text=True, timeout=10, check=True).stdout.strip()
        parameters = {
            "approvalPolicy": "never", "cwd": str(workspace), "dynamicTools": [],
            "model": "gpt-6-astra",
            "config": {"model_reasoning_effort": "medium", "default_permissions": "symphony-builder"},
        }
        with app_server(command, root, workspace, environment, guardian, "start") as connection:
            connection.send({"id": 2, "method": "thread/start", "params": {
                **parameters, "ephemeral": False,
            }})
            thread_id = verify_thread(connection.response(2, timeout=30), workspace)

        if container_image:
            environment["SYMPHONY_PR_WORK_RESUME"] = "true"
        with app_server(command, root, workspace, environment, guardian, "resume") as connection:
            connection.send({"id": 2, "method": "thread/resume", "params": {
                **parameters, "threadId": thread_id,
            }})
            verify_thread(connection.response(2, timeout=30), workspace, thread_id)

        if any(root.rglob("auth.json")):
            raise RuntimeError("Unexpected authentication file in disposable probe home")
        return {"binary_version": version, "container_image": container_image, "native_thread_resumed": True,
                "same_thread_id": True, "same_cwd": True, "named_builder_profile": True,
                "approval_policy": "never", "model_turn_started": False,
                "authentication_present": False, "container_isolation_verified": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default="/opt/homebrew/bin/codex")
    parser.add_argument("--container-image", help="Already cached immutable image ID; never downloads")
    parser.add_argument("--fixture-parent", help="Canonical existing host directory shared with the Docker VM")
    parser.add_argument("--seccomp-policy", help="Checked-in worker-only compatibility policy")
    parser.add_argument("--apparmor-profile", help="Existing worker-only AppArmor profile")
    parser.add_argument("--operator-config", help="Select the existing image/policies and exclusive canary path; never loads auth")
    arguments = parser.parse_args()
    print(json.dumps(probe(arguments.codex, arguments.container_image, arguments.fixture_parent,
                           arguments.seccomp_policy, arguments.apparmor_profile, arguments.operator_config), indent=2))
