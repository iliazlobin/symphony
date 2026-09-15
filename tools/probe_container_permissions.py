#!/usr/bin/env python3
"""No-model Linux role canaries in the exact disposable AppArmor fixture.

No real authentication is loaded. A trusted outer-container control proves fake
secrets and a network listener are accessible before the inner policy denies them.
The reviewer policy is also tested with a writable outer checkout mount.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import textwrap
import time

from probe_cancellation import Connection, disposable_root

ROOT = Path(__file__).resolve().parents[1]


def verify_profile(response, role):
    expected = "symphony-" + role
    if (not response.get("thread", {}).get("id")
            or response.get("activePermissionProfile") != {"id": expected, "extends": ":workspace"}):
        raise RuntimeError("Named permission profile was not verified: " + expected)


def verify_outer(observed, mount_role):
    expected = {"auth_read": True, "env_read": True, "host_input_read": True,
                "runtime_read": True, "network": True, "workspace_write": mount_role == "builder"}
    if observed != expected:
        raise RuntimeError("Outer namespace controls did not establish the expected boundary")


def verify_inner(observed, role):
    expected = {"workspace_read": True, "workspace_write": role == "builder",
                "env_read": False, "auth_read": False, "host_input_read": False,
                "runtime_read": False, "tmp_write": False, "network": False,
                "python": True, "node": True, "uv": True, "git_diff": True,
                "handoff_write": role == "builder", "git_commit": role == "builder"}
    if observed != expected:
        raise RuntimeError(f"{role} permission mismatch: {observed}; expected {expected}")


def probe(image=None, seccomp_policy=None, apparmor_profile=None, fixture_parent=None, operator_config=None):
    spec = importlib.util.spec_from_file_location("profile", ROOT / "profiles/events-concierge/profile.py")
    profile = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(profile)
    from probe_runtime import resolve_runtime, verify_container_policy
    if operator_config is None and apparmor_profile is None:
        apparmor_profile = "symphony-codex"
    runtime = resolve_runtime(profile, ROOT, image, seccomp_policy, apparmor_profile,
                              fixture_parent, operator_config)
    image = runtime["image"]
    if image is None:
        raise ValueError("Linux permission probes require a container image or operator configuration")
    source = (ROOT / "elixir/lib/symphony_elixir/process_group.ex").read_text()
    guardian = textwrap.dedent(re.search(r'@guardian ~S"""\n(.*?)\n  """', source, re.S).group(1))
    results = {}
    for role, mount_role in (("builder", "builder"), ("reviewer", "builder"), ("reviewer", "reviewer")):
        with disposable_root(runtime["parent"], fixed=True) as root:
            workspace, home = root / "pipe", root / "codex"
            workspace.mkdir()
            home.mkdir()
            (workspace / "read-canary").write_text("disposable")
            (workspace / ".env").write_text("FAKE_TEST_VALUE=disposable")
            (home / "auth.json").write_text('{}')
            (home / "AGENTS.md").write_text("Disposable fixture. No model turns are started.\n")
            (home / "config.toml").write_text(profile.permission_config().replace(
                'default_permissions = "symphony-builder"', f'default_permissions = "symphony-{role}"'))
            git_env = {"PATH": profile.WORKER_PATH, "HOME": str(home),
                       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                       "GIT_CONFIG_COUNT": "0"}
            subprocess.run(["git", "init", "--quiet", "--template=", str(workspace)],
                           env=git_env, check=True, timeout=5)
            for args in (["add", "read-canary"], ["-c", "user.name=Symphony Canary",
                         "-c", "user.email=canary@invalid", "commit", "--quiet", "-m", "Disposable fixture"]):
                subprocess.run(["git", *args], cwd=workspace, env=git_env, check=True, timeout=5)
            env = {"PATH": profile.WORKER_PATH, "HOME": str(Path.home()), "CODEX_HOME": str(home),
                   "SYMPHONY_WORKER_ROLE": mount_role}
            command = ["/opt/homebrew/bin/python3", "-I", str(ROOT / "tools/container_worker.py"),
                       "--workspace", str(workspace), "--codex-home", str(home), "--image", image] + runtime["options"]
            process = subprocess.Popen(["/opt/homebrew/bin/python3", "-I", "-u", "-c", guardian,
                                        str(root / "permission.lock")] + command,
                                       cwd=workspace, env=env, stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            connection = Connection(process)
            listener = None
            try:
                connection.send({"id": 1, "method": "initialize", "params": {
                    "clientInfo": {"name": "symphony-linux-permission-probe", "version": "1"},
                    "capabilities": {"experimentalApi": True}}})
                connection.response(1)
                connection.send({"method": "initialized", "params": {}})
                cidfiles = list(root.glob("permission.lock.*.cid"))
                if len(cidfiles) != 1:
                    raise RuntimeError("Missing exact guardian container identity")
                cid = cidfiles[0].read_text().strip()
                endpoint = json.loads(Path(str(cidfiles[0]) + ".intent").read_text())["docker_host"]
                docker = ["docker", "--host", endpoint]
                docker_env = {k: v for k, v in os.environ.items() if k not in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG")}
                listen_code = "import socket,time; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); print(s.getsockname()[1],flush=True); time.sleep(60)"
                listener = subprocess.Popen(docker + ["exec", cid, "/usr/local/bin/python3", "-c", listen_code],
                                            env=docker_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                import selectors
                with selectors.DefaultSelector() as selector:
                    selector.register(listener.stdout, selectors.EVENT_READ)
                    if not selector.select(5):
                        raise RuntimeError("Outer namespace network control did not start")
                    port = int(listener.stdout.readline())
                baseline = """import json,pathlib,socket
pathlib.Path('/codex-home/runtime-canary').write_text('disposable')
out={name:bool(pathlib.Path(path).read_text()) for name,path in [('auth_read','/codex-home/auth.json'),('env_read','.env'),('host_input_read','/codex-home/AGENTS.md'),('runtime_read','/codex-home/runtime-canary')]}
s=socket.socket();s.settimeout(1);s.connect(('127.0.0.1',%d));s.close();out['network']=True
try:
 p=pathlib.Path('.outer-write-control');p.write_text('disposable');p.unlink();out['workspace_write']=True
except OSError:out['workspace_write']=False
print(json.dumps(out))
""" % port
                outer = subprocess.run(docker + ["exec", "--workdir", str(workspace), cid,
                                                 "/usr/local/bin/python3", "-c", baseline],
                                       env=docker_env, capture_output=True, text=True, timeout=5, check=True)
                verify_outer(json.loads(outer.stdout), mount_role)
                connection.send({"id": 2, "method": "thread/start", "params": {
                    "cwd": str(workspace), "config": {"default_permissions": "symphony-" + role},
                    "approvalPolicy": "never", "ephemeral": True}})
                verify_profile(connection.response(2), role)
                script = '''import json,pathlib,socket,subprocess
out={}
for key,path,mode in [("workspace_read","read-canary","r"),("workspace_write","write-canary","w"),("env_read",".env","r"),("auth_read","/codex-home/auth.json","r"),("host_input_read","/codex-home/AGENTS.md","r"),("runtime_read","/codex-home/runtime-canary","r"),("tmp_write","/tmp/forbidden-write","w")]:
 try:
  with open(path,mode) as f:
   f.read() if mode=="r" else f.write("disposable")
  out[key]=True
 except OSError: out[key]=False
try:
 s=socket.socket(); s.settimeout(0.3); s.connect(("127.0.0.1",%d)); out["network"]=True; s.close()
except OSError: out["network"]=False
for key,command in (("python",["/usr/local/bin/python3","--version"]),("node",["/usr/local/bin/node","--version"]),("uv",["/usr/local/bin/uv","--version"]),("git_diff",["/usr/bin/git","diff","HEAD","--exit-code"])):
 out[key]=subprocess.run(command,capture_output=True).returncode==0
try:
 pathlib.Path('.symphony').mkdir(exist_ok=True)
 pathlib.Path('.symphony/handoff.json').write_text('{"canary":true}')
 out["handoff_write"]=True
except OSError: out["handoff_write"]=False
out["git_commit"]=subprocess.run(["/usr/bin/git","add","read-canary"],capture_output=True).returncode==0 and subprocess.run(["/usr/bin/git","-c","user.name=Symphony Canary","-c","user.email=canary@invalid","commit","--allow-empty","-m","Disposable permission canary"],capture_output=True).returncode==0
print(json.dumps(out))
''' % port
                connection.send({"id": 3, "method": "command/exec", "params": {
                    "command": ["/usr/local/bin/python3", "-I", "-c", script],
                    "cwd": str(workspace), "timeoutMs": 10000}})
                response = connection.response(3, timeout=15)
                if response.get("exitCode") != 0:
                    raise RuntimeError(f"{role}/{mount_role} command failed: {response}")
                observed = json.loads(response["stdout"])
                verify_inner(observed, role)
                inspect = subprocess.run(docker + ["inspect", cid], env=docker_env, capture_output=True,
                                         text=True, timeout=5, check=True)
                info = json.loads(inspect.stdout)[0]
                verify_container_policy(info, runtime)
                checkout = next(m for m in info["Mounts"] if m["Destination"] == str(workspace))
                host = info["HostConfig"]
                if (checkout["RW"] != (mount_role == "builder") or not host["ReadonlyRootfs"]
                        or host["CapDrop"] != ["ALL"] or host["CapAdd"] or host["Privileged"]
                        or "no-new-privileges" not in host["SecurityOpt"]):
                    raise RuntimeError("Outer container restrictions differ from the production wrapper")
                results[role + "_on_" + mount_role + "_mount"] = {
                    **observed, "active_permission_profile": "symphony-" + role,
                    "selected_container_policy_verified": True,
                    "operator_launch_selection": runtime["operational"],
                    "outer_secret_and_network_controls_verified": True,
                    "outer_checkout_writable": checkout["RW"], "outer_restrictions_verified": True}
            finally:
                connection.selector.close()
                if not process.stdin.closed:
                    process.stdin.close()
                process.wait(timeout=40)
                process.stdout.close()
                if listener:
                    listener.wait(timeout=5)
                    listener.stdout.close()
                    listener.stderr.close()
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container-image")
    parser.add_argument("--seccomp-policy")
    parser.add_argument("--apparmor-profile")
    parser.add_argument("--fixture-parent", help="Existing canonical directory for disposable fixtures; operational mode confines it to the configured workspace root")
    parser.add_argument("--operator-config", help="Use the service's pinned image and reviewed launch-policy selector without loading real authentication into a worker")
    args = parser.parse_args()
    print(json.dumps(probe(args.container_image, args.seccomp_policy, args.apparmor_profile,
                           args.fixture_parent, args.operator_config), indent=2))
