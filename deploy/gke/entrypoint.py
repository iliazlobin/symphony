"""Fail-closed bootstrap launcher; the native controller remains the journal writer."""
import json
import os
from pathlib import Path
import stat
import sys
import urllib.request

STATE_PATH = Path("/var/lib/symphony/control.json")
MAX_STATE_BYTES = 10_000_000


def validate_state(path: Path, *, required: bool = False) -> None:
    """Accept a fresh or retained empty paused journal; never repair or reset one."""
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        if required:
            raise ValueError("controller journal is not initialized") from None
        return
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError("controller journal must be a regular file")
    with path.open("rb") as stream:
        data = json.loads(stream.read(MAX_STATE_BYTES + 1)) if metadata.st_size <= MAX_STATE_BYTES else None
    if not isinstance(data, dict) or type(data.get("version")) is not int or data["version"] != 1:
        raise ValueError("unsupported controller journal")
    if data.get("mode") != "paused" or data.get("issues") != {}:
        raise ValueError("bootstrap requires an empty, paused journal; preserve state for operator recovery")
    if type(data.get("revision")) is not int or data["revision"] < 0 or not isinstance(data.get("commands"), dict):
        raise ValueError("invalid controller journal")


def main(argv: list[str]) -> None:
    if argv not in (["serve"], ["check"]):
        raise ValueError("expected serve or check; custom workflow and command arguments are disabled")
    validate_state(STATE_PATH, required=argv == ["check"])
    if argv == ["check"]:
        # Ignore proxy environment variables: this is always the local controller.
        client = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with client.open("http://127.0.0.1:8080/", timeout=3) as response:
            if response.status != 200:
                raise ValueError("controller dashboard is unavailable")
        return
    Path("/tmp/home").mkdir(exist_ok=True)
    Path("/tmp/symphony-workspaces").mkdir(exist_ok=True)
    print("GKE bootstrap: paused, unconfigured tracker, worker execution disabled; logs: /var/lib/symphony/log/", flush=True)
    # No inherited credentials, control token, BEAM config or alternate tracker config.
    environment = {
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "HOME": "/tmp/home",
        "LANG": "C.UTF-8",
        "ERL_FLAGS": "+S 2:2",
        "ERL_CRASH_DUMP": "/tmp/erl_crash.dump",
    }
    os.execve("/opt/symphony/symphony", [
        "/opt/symphony/symphony",
        "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
        "--logs-root", "/var/lib/symphony", "/opt/symphony/WORKFLOW.md",
    ], environment)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, ValueError) as error:
        # Never print journal contents or environment values.
        print(f"GKE bootstrap refused startup/readiness: {type(error).__name__}: {error}", file=sys.stderr)
        sys.exit(1)
