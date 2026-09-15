#!/usr/bin/env python3
"""Run one Codex app-server in its guardian-owned local Docker PID namespace."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

OWNER_LABEL = "com.openai.symphony.owner"


def create_command(workspace, codex_home, image, role, cidfile, owner, docker, seccomp_policy=None, apparmor_profile=None):
    workspace = Path(workspace).resolve(strict=True)
    codex_home = Path(codex_home).resolve(strict=True)
    cidfile = Path(cidfile).resolve()
    if not workspace.is_dir() or not codex_home.is_dir():
        raise ValueError("Workspace and dedicated Codex home must be directories")
    if codex_home == Path.home() / ".codex":
        raise ValueError("The personal Codex home must not be mounted into a worker")
    if codex_home == workspace or workspace in codex_home.parents or codex_home in workspace.parents:
        raise ValueError("Workspace and Codex home must be separate trees")
    if workspace == cidfile or workspace in cidfile.parents or cidfile.exists():
        raise ValueError("Guardian CID path must be private, outside the checkout, and unused")
    if not re.fullmatch(r"[a-f0-9]{32}", owner):
        raise ValueError("Missing guardian ownership nonce")
    if role not in ("builder", "reviewer"):
        raise ValueError("Unknown worker role")
    for path in (workspace, codex_home, cidfile):
        if any(character in str(path) for character in (",", "\n", "\r", "\0")):
            raise ValueError("Unsupported container mount path")
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", image):
        raise ValueError("Worker image must be the verified immutable local image ID")
    if not (codex_home / "config.toml").is_file():
        raise ValueError("Reviewed worker config is missing")

    stage_home = codex_home.parent / "stage-state" / owner / role
    stage_mounts = ["--mount", f"type=bind,src={stage_home},dst=/codex-home"]
    for filename in ("config.toml", "AGENTS.md", "auth.json"):
        source = codex_home / filename
        if source.exists():
            if source.is_symlink() or not source.is_file():
                raise ValueError("Worker runtime inputs must be regular files")
            stage_mounts += ["--mount", f"type=bind,src={source},dst=/codex-home/{filename},readonly"]

    source_mount = f"type=bind,src={workspace},dst={workspace}"
    if role == "reviewer":
        source_mount += ",readonly"
    compatibility = []
    if seccomp_policy is not None:
        policy = Path(seccomp_policy).resolve(strict=True)
        expected = Path(__file__).resolve().parents[1] / "profiles/events-concierge/seccomp-codex.json"
        if policy != expected or not policy.is_file():
            raise ValueError("Only the reviewed repository seccomp compatibility candidate is supported")
        compatibility = ["--security-opt", "seccomp=" + str(policy)]
    if apparmor_profile is not None:
        if apparmor_profile != "symphony-codex" or seccomp_policy is None:
            raise ValueError("Only the reviewed worker AppArmor profile is supported")
        compatibility += ["--security-opt", "apparmor=" + apparmor_profile]
    return [
        docker, "create", "--name", "symphony-" + owner,
        "--label", OWNER_LABEL + "=" + owner, "--cidfile", str(cidfile),
        "--init", "--interactive", "--read-only", "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges", "--pids-limit", "256",
        "--memory", "4g", "--cpus", "2", "--user", f"{os.getuid()}:{os.getgid()}",
        "--mount", source_mount,
    ] + stage_mounts + compatibility + [
        "--tmpfs", f"/tmp:rw,mode=1777,size=536870912,uid={os.getuid()},gid={os.getgid()}",
        "--env", "CODEX_HOME=/codex-home", "--env", "HOME=/tmp/worker-home",
        "--env", "GIT_CONFIG_NOSYSTEM=1", "--env", "GIT_TERMINAL_PROMPT=0",
        "--workdir", str(workspace), image,
        "/bin/sh", "-c", 'mkdir -p "$HOME"; exec codex app-server',
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--codex-home", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--seccomp-policy", help="Reviewed repository policy for Codex's inner Linux sandbox")
    parser.add_argument("--apparmor-profile", help="Explicit worker-only AppArmor compatibility profile")
    args = parser.parse_args()
    docker = shutil.which("docker")
    if not docker:
        raise RuntimeError("Docker CLI unavailable")
    command = create_command(
        args.workspace, args.codex_home, args.image,
        os.environ.get("SYMPHONY_WORKER_ROLE", "builder"),
        os.environ["SYMPHONY_CONTAINER_CIDFILE"],
        os.environ["SYMPHONY_CONTAINER_OWNER"], docker, args.seccomp_policy, args.apparmor_profile,
    )
    stage_home = Path(args.codex_home).resolve().parent / "stage-state" / os.environ["SYMPHONY_CONTAINER_OWNER"] / os.environ.get("SYMPHONY_WORKER_ROLE", "builder")
    stage_home.mkdir(parents=True, mode=0o700, exist_ok=False)
    docker_env = {key: value for key, value in os.environ.items() if key not in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG")}
    context = subprocess.run([docker, "context", "inspect", "colima", "--format", "{{.Endpoints.docker.Host}}"], env=docker_env, capture_output=True, text=True, timeout=10, check=True)
    endpoint = context.stdout.strip()
    if not endpoint.startswith("unix:///") or any(c in endpoint for c in ("\n", "\r", "\0")):
        raise ValueError("Only an explicitly identified local Docker socket is supported")
    command[1:1] = ["--host", endpoint]
    intent = os.environ["SYMPHONY_CONTAINER_CIDFILE"] + ".intent"
    with open(os.open(intent, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as marker:
        json.dump({"owner": os.environ["SYMPHONY_CONTAINER_OWNER"], "docker_host": endpoint}, marker)
    result = subprocess.run(command, env=docker_env, text=True, capture_output=True, timeout=60)
    if result.returncode != 0:
        raise RuntimeError("Worker container creation failed: " + result.stderr[-2000:])
    cid = Path(os.environ["SYMPHONY_CONTAINER_CIDFILE"]).read_text().strip()
    if not re.fullmatch(r"[a-f0-9]{64}", cid) or result.stdout.strip() != cid:
        raise RuntimeError("Docker returned inconsistent container identity")
    # The guardian owns removal. Creating before attaching means no app-server
    # process can run before the CID has been recorded outside the checkout.
    os.execve(docker, [docker, "--host", endpoint, "start", "--attach", "--interactive", cid], docker_env)


if __name__ == "__main__":
    main()
