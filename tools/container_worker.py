#!/usr/bin/env python3
"""Run one Codex app-server in its guardian-owned local Docker PID namespace."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from container_auth import AuthLease, AuthLeaseBusy, AuthLeaseError, prepare_marker

OWNER_LABEL = "com.openai.symphony.owner"
AUTH_UNAVAILABLE_EXIT = 78
AUTH_BUSY_EXIT = 79


def stage_path(codex_home, owner, role, work_id=None):
    if work_id is not None:
        if role != "builder" or not isinstance(work_id, str) or not re.fullmatch(r"[a-f0-9]{32}", work_id):
            raise ValueError("Retained PR state requires an identified builder work record")
        return Path(codex_home).parent / "pr-work-state" / work_id / "builder"
    return Path(codex_home).parent / "stage-state" / owner / role


def private_directory(path, *, create=False):
    if create:
        path.mkdir(mode=0o700, exist_ok=True)
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) & 0o077 or path.resolve(strict=True) != path):
        raise ValueError("Worker session state must be a private owned directory without symlinks")


def prepare_stage_home(workspace, codex_home, owner, role, work_id=None, *, resume=False):
    home = Path(codex_home).resolve(strict=True)
    stage = stage_path(home, owner, role, work_id)
    if work_id is None:
        if resume:
            raise ValueError("Resume requires a retained PR work identity")
        stage.mkdir(parents=True, mode=0o700, exist_ok=False)
        return stage
    state_root = stage.parent.parent
    private_directory(state_root, create=not resume)
    private_directory(stage.parent, create=not resume)
    marker = stage.parent / "scope.json"
    expected = {"version": 1, "work_id": work_id, "workspace": str(Path(workspace).resolve(strict=True)), "codex_home": str(home)}
    if resume:
        info = marker.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1 or info.st_size > 4096):
            raise ValueError("Retained work scope marker is invalid")
        if json.loads(marker.read_text()) != expected:
            raise ValueError("Retained work scope does not match this workspace")
        private_directory(stage)
    else:
        # An ambiguous first startup is retained for operator recovery, never overwritten.
        stage.mkdir(mode=0o700, exist_ok=False)
        with open(os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
            json.dump(expected, stream)
            stream.flush()
            os.fsync(stream.fileno())
        for directory in (stage.parent, state_root, home.parent):
            descriptor = os.open(directory, os.O_RDONLY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
    return stage


def create_command(workspace, codex_home, image, role, cidfile, owner, docker, seccomp_policy=None, apparmor_profile=None, work_id=None):
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

    stage_home = stage_path(codex_home, owner, role, work_id)
    stage_mounts = ["--mount", f"type=bind,src={stage_home},dst=/codex-home"]
    # Authentication moves into the writable stage directory under one durable
    # guardian claim. A read-only auth leaf loses Codex-managed token refresh.
    for filename in ("config.toml", "AGENTS.md"):
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
        if apparmor_profile not in ("symphony-codex", "symphony-self-codex") or seccomp_policy is None:
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
        work_id=os.environ.get("SYMPHONY_PR_WORK_ID"),
    )
    resume = os.environ.get("SYMPHONY_PR_WORK_RESUME")
    if resume not in (None, "true"):
        raise ValueError("Invalid retained session resume flag")
    owner = os.environ["SYMPHONY_CONTAINER_OWNER"]
    role = os.environ.get("SYMPHONY_WORKER_ROLE", "builder")
    stage = prepare_stage_home(args.workspace, args.codex_home, owner, role,
                               os.environ.get("SYMPHONY_PR_WORK_ID"), resume=resume == "true")
    docker_env = {key: value for key, value in os.environ.items() if key not in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG")}
    context = subprocess.run([docker, "context", "inspect", "colima", "--format", "{{.Endpoints.docker.Host}}"], env=docker_env, capture_output=True, text=True, timeout=10, check=True)
    endpoint = context.stdout.strip()
    if not endpoint.startswith("unix:///") or any(c in endpoint for c in ("\n", "\r", "\0")):
        raise ValueError("Only an explicitly identified local Docker socket is supported")
    cidfile = Path(os.environ["SYMPHONY_CONTAINER_CIDFILE"])
    # The host-only marker precedes the claim. Before Docker intent exists,
    # guardian cleanup can safely retire a cancelled wait or unstarted stage.
    prepare_marker(cidfile, owner, Path(args.codex_home).resolve(strict=True), stage)
    AuthLease(Path(args.codex_home).resolve(strict=True)).wait_claim(owner, stage, cidfile, role)
    command[1:1] = ["--host", endpoint]
    intent = os.environ["SYMPHONY_CONTAINER_CIDFILE"] + ".intent"
    with open(os.open(intent, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as marker:
        json.dump({"owner": os.environ["SYMPHONY_CONTAINER_OWNER"], "docker_host": endpoint}, marker)
        marker.flush()
        os.fsync(marker.fileno())
    directory = os.open(Path(intent).parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    result = subprocess.run(command, env=docker_env, text=True, capture_output=True, timeout=60)
    if result.returncode != 0:
        raise RuntimeError("Worker container creation failed: " + result.stderr[-2000:])
    cid = Path(os.environ["SYMPHONY_CONTAINER_CIDFILE"]).read_text().strip()
    if not re.fullmatch(r"[a-f0-9]{64}", cid) or result.stdout.strip() != cid:
        raise RuntimeError("Docker returned inconsistent container identity")
    # The guardian owns removal. Creating before attaching means no app-server
    # process can run before the CID has been recorded outside the checkout.
    os.execve(docker, [docker, "--host", endpoint, "start", "--attach", "--interactive", cid], docker_env)


def entrypoint():
    try:
        main()
        return 0
    except AuthLeaseBusy:
        print("Worker sign-in is busy; no model turn was started", file=sys.stderr)
        return AUTH_BUSY_EXIT
    except AuthLeaseError:
        print("Dedicated worker sign-in needs recovery; no model turn was started", file=sys.stderr)
        return AUTH_UNAVAILABLE_EXIT


if __name__ == "__main__":
    raise SystemExit(entrypoint())
