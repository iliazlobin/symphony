#!/usr/bin/env python3
"""Typed local Symphony operator client and stdio MCP adapter. No scheduler."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

MAX_MESSAGE = 1_048_576
ACTIONS = ("pause", "drain", "resume", "cancel", "retry")
DEFAULT_CONFIG = Path.home() / "Library/Application Support/Symphony/events-concierge/config.json"


class ControlError(Exception):
    """An operator request failed without implying any runtime state."""


def read_private(path: Path) -> str:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise ControlError("Private configuration must be a regular file")
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "r") as stream:
        opened = os.fstat(stream.fileno())
        if (not stat.S_ISREG(opened.st_mode) or opened.st_ino != info.st_ino or opened.st_dev != info.st_dev
                or opened.st_uid != os.getuid() or stat.S_IMODE(opened.st_mode) & 0o077):
            raise ControlError("Private configuration must be owned by this user with mode 0600")
        content = stream.read(MAX_MESSAGE + 1)
        if len(content) > MAX_MESSAGE:
            raise ControlError("Private configuration exceeded the size limit")
        return content


def load_config(path: str | Path | None = None) -> dict:
    target = Path(path or os.environ.get("SYMPHONY_OPERATOR_CONFIG", DEFAULT_CONFIG)).expanduser()
    config = json.loads(read_private(target))
    parsed = urllib.parse.urlsplit(config["api_url"])
    if (parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "::1")
            or parsed.username or parsed.password or parsed.query or parsed.fragment
            or parsed.path not in ("", "/")):
        raise ControlError("The Mac control client only connects to an explicit loopback HTTP address")
    if parsed.port is None:
        raise ControlError("An explicit control API port is required")
    token_path = Path(config["token_file"]).expanduser()
    if token_path.parent.resolve() != target.parent.resolve():
        raise ControlError("Control token must live beside the operator configuration")
    config["_token"] = read_private(token_path).strip()
    if len(config["_token"]) < 32:
        raise ControlError("Control token is missing or too short")
    config["_config_path"] = str(target)
    return config


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ControlError("Control API redirects are forbidden")


def request_json(config: dict, path: str, payload: dict | None = None) -> dict:
    if not path.startswith("/api/v1/") or ".." in path:
        raise ControlError("Invalid control API path")
    body = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(
        config["api_url"].rstrip("/") + path, data=body,
        headers={"Authorization": "Bearer " + config["_token"],
                 "Accept": "application/json", "Content-Type": "application/json"},
        method="GET" if payload is None else "POST",
    )
    # Do not route localhost credentials through ambient proxy configuration.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(request, timeout=15) as response:
            data = response.read(MAX_MESSAGE + 1)
            if len(data) > MAX_MESSAGE:
                raise ControlError("Control response exceeded the size limit")
            result = json.loads(data)
            if not isinstance(result, dict) or result.get("error"):
                raise ControlError("Symphony returned an unavailable snapshot; worker state is unknown")
            return result
    except urllib.error.HTTPError as exc:
        detail = exc.read(4096).decode(errors="replace")
        raise ControlError(f"Control API rejected request ({exc.code}): {detail}") from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise ControlError("Symphony is unavailable or returned invalid data; worker state is unknown") from exc


def status(config: dict) -> dict:
    result = {
        "observed_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "project": config["repository"],
        "control": request_json(config, "/api/v1/control"),
        "runtime": request_json(config, "/api/v1/state"),
    }
    result["publication"] = []
    if config.get("state_dir"):
        receipts = Path(config["state_dir"]) / "receipts"
        fields = {"issue_id", "candidate_sha", "status", "pr_url", "updated_at", "merge_sha", "last_error"}
        for receipt in sorted(receipts.glob("publication-*.json"))[:1000]:
            value = json.loads(read_private(receipt))
            result["publication"].append({key: value[key] for key in fields if key in value})
        result["worker_launch_enabled"] = config.get("worker_launch_enabled", False)
        result["auto_merge_enabled"] = config.get("auto_merge", {}).get("enabled", False)
        result["integration_branch"] = config.get("integration_branch")
    return result


def control(config: dict, action: str, expected_revision: int,
            command_id: str, issue_id: str | None = None) -> dict:
    if action not in ACTIONS:
        raise ControlError("Unsupported control action")
    if type(expected_revision) is not int or expected_revision < 0:
        raise ControlError("expected_revision must be a nonnegative integer")
    if not isinstance(command_id, str) or not 1 <= len(command_id) <= 128:
        raise ControlError("A bounded command_id is required")
    if action in ("cancel", "retry") and not issue_id:
        raise ControlError("This action requires an issue_id")
    if issue_id is not None and (not isinstance(issue_id, str) or len(issue_id) > 256):
        raise ControlError("Invalid issue_id")
    payload = dict(action=action, expected_revision=expected_revision, command_id=command_id)
    if issue_id is not None:
        payload["issue_id"] = issue_id
    return request_json(config, "/api/v1/control", payload)


TOOLS = [
    {
        "name": "symphony_status",
        "description": "Read live Symphony execution and durable control state, including the current revision. Unavailability is an error, not an idle result.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"readOnlyHint": True, "openWorldHint": False},
    },
    {
        "name": "symphony_issue",
        "description": "Read runtime details for an issue identifier. GitHub remains the task and PR record.",
        "inputSchema": {"type": "object", "properties": {"issue_identifier": {"type": "string", "maxLength": 256}},
                        "required": ["issue_identifier"], "additionalProperties": False},
        "annotations": {"readOnlyHint": True, "openWorldHint": False},
    },
    {
        "name": "symphony_control",
        "description": "Request an authorized pause, drain, resume, issue cancellation or retry. Read status first and pass its control revision. Reuse command_id on an uncertain retry. This grants no merge, deployment or broader permissions.",
        "inputSchema": {"type": "object", "properties": {
            "action": {"type": "string", "enum": list(ACTIONS)},
            "expected_revision": {"type": "integer", "minimum": 0},
            "command_id": {"type": "string", "minLength": 1, "maxLength": 128},
            "issue_id": {"type": "string", "maxLength": 256},
        }, "required": ["action", "expected_revision", "command_id"], "additionalProperties": False},
        "annotations": {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": True, "openWorldHint": False},
    },
]


def call_tool(config: dict, name: str, arguments: dict) -> dict:
    if not isinstance(arguments, dict):
        raise ControlError("Tool arguments must be an object")
    if name == "symphony_status" and not arguments:
        result = status(config)
    elif name == "symphony_issue" and set(arguments) == {"issue_identifier"}:
        issue = arguments["issue_identifier"]
        if not isinstance(issue, str) or not 1 <= len(issue) <= 256:
            raise ControlError("Invalid issue identifier")
        result = request_json(config, "/api/v1/" + urllib.parse.quote(issue, safe=""))
    elif name == "symphony_control" and set(arguments) <= {"action", "expected_revision", "command_id", "issue_id"}:
        result = control(config, **arguments)
    else:
        raise ControlError("Unknown tool or invalid arguments")
    return {"content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False)}],
            "isError": False}


def mcp(config: dict, incoming=sys.stdin, outgoing=sys.stdout) -> None:
    # Pin the initially validated path, then validate its current contents for
    # every call. A long-lived MCP process must not retain obsolete gates/tokens.
    config_path = config.get("_config_path")
    config_path = Path(config_path).absolute() if config_path is not None else None
    initialized = False
    while True:
        line = incoming.readline(MAX_MESSAGE + 1)
        if not line:
            return
        if len(line) > MAX_MESSAGE:
            raise ControlError("MCP message exceeded the size limit")
        request = None
        try:
            request = json.loads(line)
            if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
                raise ValueError("Expected a JSON-RPC 2.0 object")
            if "id" not in request:
                continue
            method = request.get("method")
            params = request.get("params") or {}
            if not isinstance(params, dict):
                raise ValueError("JSON-RPC params must be an object")
            if method == "initialize":
                if initialized:
                    raise ValueError("Already initialized")
                version = params.get("protocolVersion")
                supported = ("2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25")
                result = {"protocolVersion": version if version in supported else "2025-11-25",
                          "capabilities": {"tools": {"listChanged": False}},
                          "serverInfo": {"name": "symphony-control", "version": "0.1.0"}}
                initialized = True
            elif method == "ping":
                result = {}
            elif not initialized:
                raise ValueError("Initialize the MCP connection first")
            elif method == "tools/list":
                result = {"tools": TOOLS}
            elif method == "tools/call":
                try:
                    current_config = load_config(config_path) if config_path is not None else config
                    result = call_tool(current_config, params["name"], params.get("arguments", {}))
                except (ControlError, OSError, ValueError, TypeError, KeyError) as exc:
                    result = {"content": [{"type": "text", "text": str(exc)}], "isError": True}
            else:
                response = {"jsonrpc": "2.0", "id": request["id"],
                            "error": {"code": -32601, "message": "Method not found"}}
                outgoing.write(json.dumps(response) + "\n")
                outgoing.flush()
                continue
            response = {"jsonrpc": "2.0", "id": request["id"], "result": result}
        except (json.JSONDecodeError, ValueError, KeyError, TypeError) as exc:
            response = {"jsonrpc": "2.0", "id": request.get("id") if isinstance(request, dict) else None,
                        "error": {"code": -32600, "message": str(exc)}}
        outgoing.write(json.dumps(response, ensure_ascii=False) + "\n")
        outgoing.flush()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    sub.add_parser("mcp")
    issue = sub.add_parser("issue")
    issue.add_argument("identifier")
    for action in ACTIONS:
        p = sub.add_parser(action)
        p.add_argument("--revision", type=int, required=True)
        p.add_argument("--command-id", default=None)
        if action in ("cancel", "retry"):
            p.add_argument("issue_id")
    args = parser.parse_args()
    try:
        config = load_config(args.config)
        if args.command == "mcp":
            mcp(config)
            return 0
        if args.command == "status":
            result = status(config)
        elif args.command == "issue":
            result = request_json(config, "/api/v1/" + urllib.parse.quote(args.identifier, safe=""))
        else:
            result = control(config, args.command, args.revision,
                             args.command_id or str(uuid.uuid4()), getattr(args, "issue_id", None))
        print(json.dumps(result, indent=2))
        return 0
    except (ControlError, OSError, KeyError, json.JSONDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
