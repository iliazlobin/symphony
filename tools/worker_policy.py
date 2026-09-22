#!/usr/bin/env python3
"""Render the reviewed local worker AppArmor policy; never install or load it.

The fixed template retains Docker's default file/capability permissions and
proc/sys denials. Its mount exceptions only construct Codex's private namespace.
The outer Docker mount boundary and named Codex permissions remain mandatory.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import stat
import sys


ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "profiles/events-concierge/apparmor-codex.template"
PROFILE_NAME = "symphony-codex"
_MARKER = "@@WORKSPACE_RULES@@"
_READ_ONLY = "ro,nosuid,nodev,remount,bind,silent,relatime"
_READ_WRITE = "rw,nosuid,nodev,remount,bind,silent,relatime"
_MASK_SOURCE = "/bindfile" + "[A-Za-z0-9]" * 6


def validate_workspace_root(value: str | Path) -> Path:
    """Accept literal, canonical, existing private roots from host configuration."""
    raw = os.fspath(value)
    if (not isinstance(raw, str) or not re.fullmatch(r"/[A-Za-z0-9_. /-]+", raw)
            or "//" in raw or raw.endswith("/")
            or any(part in ("", ".", "..") for part in raw.split("/")[1:])):
        raise ValueError("Workspace root must be an absolute literal path without policy metacharacters")
    root = Path(raw)
    if root.name != "workspaces" or len(root.parts) < 4:
        raise ValueError("Workspace root must be the dedicated workspaces directory")
    if root.resolve(strict=True) != root:
        raise ValueError("Workspace root and its ancestors must not be symlinks")
    info = root.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) & 0o077):
        raise ValueError("Workspace root must be a private directory owned by the operator")
    return root


def _quoted(path: str) -> str:
    # Caller input is literal-validated before adding these fixed AARE patterns.
    return '"' + path + '"'


def _remount(target: str, options: str) -> str:
    return f"  mount options=({options}) -> {_quoted('/newroot' + target)},"


def _bind(path: str) -> str:
    return f"  mount options=(rw,rbind) {_quoted('/oldroot' + path)} -> {_quoted('/newroot' + path)},"


def _workspace_rules(workspace: str) -> list[str]:
    directory = workspace + "/"
    rules = [_bind(directory), _remount(directory, _READ_ONLY), _remount(directory, _READ_WRITE)]
    # .git is explicitly admitted by the named builder profile. .codex/.agents
    # stay read-only: missing directories are masked with private empty tmpfs.
    for name in (".git", ".codex", ".agents"):
        path = directory + name + "/"
        rules.extend([_bind(path), _remount(path, _READ_ONLY)])
        if name == ".git":
            rules.append(_remount(path, _READ_WRITE))
        else:
            rules.append(f"  mount fstype=tmpfs options=(rw,nosuid,nodev) tmpfs -> {_quoted('/newroot' + path)},")
    # Only private empty-file masks may be bound over denied .env files. These
    # destination-only recursive patterns never admit recursive oldroot reads.
    for suffix in ("/*.env", "/**/*.env"):
        target = workspace + suffix
        rules.extend([
            f"  mount options=(rw,rbind) {_MASK_SOURCE} -> {_quoted('/newroot' + target)},",
            _remount(target, _READ_ONLY),
        ])
    return rules


def render_policy(workspace_root: str | Path, profile_name: str = PROFILE_NAME) -> str:
    if profile_name not in (PROFILE_NAME, "symphony-self-codex"):
        raise ValueError("Unknown reviewed worker profile name")
    root = validate_workspace_root(workspace_root)
    template = TEMPLATE.read_text(encoding="utf-8")
    if template.count(_MARKER) != 1:
        raise ValueError("Reviewed worker policy template has an invalid insertion point")
    # AppArmor '*' cannot cross '/': task and reviewer binds remain direct
    # children. The host guardian independently validates each exact checkout.
    workspaces = [str(root) + "/GH-[0-9]*"]
    workspaces += [str(root / "symphony-sandbox-canary" / mode)
                   for mode in ("pipe", "pty", "detached_child")]
    rules = ["  # Configured task root: " + str(root),
             "  # Direct task/reviewer checkouts and exact disposable canary paths only."]
    for workspace in workspaces:
        rules.extend(_workspace_rules(workspace))
    return template.replace('profile "' + PROFILE_NAME + '"', 'profile "' + profile_name + '"').replace(_MARKER, "\n".join(rules))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace-root", required=True)
    parser.add_argument("--profile-name", choices=(PROFILE_NAME, "symphony-self-codex"), default=PROFILE_NAME)
    args = parser.parse_args()
    try:
        sys.stdout.write(render_policy(args.workspace_root, args.profile_name))
        return 0
    except (OSError, ValueError, TypeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
