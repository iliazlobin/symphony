#!/usr/bin/env python3
"""Serialize a dedicated Mac Codex credential without reading or copying tokens.

Codex owns refresh. A durable claim moves the sole file into its writable stage
directory. Only the host guardian, after verified container removal, returns the
latest file and retires the claim. Timeouts never permit ownership takeover.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time
import uuid


class AuthLeaseError(RuntimeError):
    """Safe operator error; never includes credentials or provider responses."""


class AuthLeaseBusy(AuthLeaseError):
    pass


def private(path, *, directory=False):
    info = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if (not kind(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) & 0o077
            or (not directory and info.st_nlink != 1)
            or path.resolve(strict=True) != path):
        raise AuthLeaseError("Worker authentication paths must be private, owned and without links")
    return info


def sync(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix=".auth-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        sync(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def credential(path):
    # Inspect only file metadata, never token values. Provider verification is
    # performed by the Codex app-server before it starts any model turn.
    try:
        info = private(path)
    except FileNotFoundError as exc:
        raise AuthLeaseError("Dedicated worker sign-in is missing; independent sign-in is required") from exc
    if not 1 <= info.st_size <= 1_048_576:
        raise AuthLeaseError("Worker authentication is incomplete; independent sign-in is required")


def read_json(path):
    info = private(path)
    if info.st_size > 16384:
        raise AuthLeaseError("Worker authentication ownership is unreadable; retain it for recovery")
    try:
        return json.loads(path.read_text())
    except (ValueError, UnicodeError) as exc:
        raise AuthLeaseError("Worker authentication ownership is unreadable; retain it for recovery") from exc


def canonical(value):
    path = Path(value)
    if not path.is_absolute() or path.resolve() != path:
        raise AuthLeaseError("Worker authentication scope must use canonical absolute paths")
    return path


def owner_id(owner):
    if not isinstance(owner, str) or not re.fullmatch(r"[a-f0-9]{32}", owner):
        raise AuthLeaseError("Worker authentication ownership is invalid")


class AuthLease:
    def __init__(self, home):
        self.home = canonical(home)
        if self.home == (Path.home() / ".codex").resolve():
            raise AuthLeaseError("The personal Codex home is not a worker credential")
        private(self.home, directory=True)
        self.root = self.home / ".symphony-auth"

    @contextmanager
    def lock(self):
        self.root.mkdir(mode=0o700, exist_ok=True)
        private(self.root, directory=True)
        fd = os.open(self.root / "lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            private(self.root / "lock")
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise AuthLeaseBusy("Another trusted process owns worker sign-in; wait for cleanup") from exc
            yield
        finally:
            os.close(fd)

    def load(self):
        path = self.root / "owner.json"
        if not path.exists() and not path.is_symlink():
            return {"version": 1, "phase": "idle", "claim": None, "last_owner": None}
        state = read_json(path)
        if (not isinstance(state, dict) or set(state) != {"version", "phase", "claim", "last_owner"}
                or state["version"] != 1 or state["phase"] not in ("idle", "claiming", "active", "returning")
                or ((state["phase"] == "idle") != (state["claim"] is None))):
            raise AuthLeaseError("Worker authentication ownership is invalid; retain it for recovery")
        if state["last_owner"] is not None:
            owner_id(state["last_owner"])
        claim = state["claim"]
        if claim is not None:
            if not isinstance(claim, dict) or set(claim) != {"owner", "stage_home", "cidfile", "role"}:
                raise AuthLeaseError("Worker authentication ownership is invalid; retain it for recovery")
            owner_id(claim["owner"])
            stage = canonical(claim["stage_home"])
            private(stage, directory=True)
            if claim["role"] == "enrollment":
                if stage != self.home or claim["cidfile"] is not None or state["phase"] != "active":
                    raise AuthLeaseError("Worker authentication enrollment ownership is invalid")
            elif claim["role"] in ("builder", "reviewer"):
                self.stage_scope(stage, claim["owner"], claim["role"])
                canonical(claim["cidfile"])
            else:
                raise AuthLeaseError("Worker authentication role is invalid")
        return state

    def save(self, state):
        write_json(self.root / "owner.json", state)

    def stage_scope(self, stage, owner, role):
        if role not in ("builder", "reviewer"):
            raise AuthLeaseError("Worker authentication role is invalid")
        relative = stage.relative_to(self.home.parent).parts if self.home.parent in stage.parents else ()
        fresh = relative == ("stage-state", owner, role)
        retained = (role == "builder" and len(relative) == 3 and relative[0] == "pr-work-state"
                    and re.fullmatch(r"[a-f0-9]{32}", relative[1]) and relative[2] == "builder")
        if not (fresh or retained):
            raise AuthLeaseError("Worker authentication stage does not match its dedicated scope")
        private(stage, directory=True)

    def finish_move(self, state):
        phase = state["phase"]
        if phase not in ("claiming", "returning"):
            return
        stage = Path(state["claim"]["stage_home"])
        source, target = ((self.home / "auth.json", stage / "auth.json") if phase == "claiming"
                          else (stage / "auth.json", self.home / "auth.json"))
        source_exists = source.exists() or source.is_symlink()
        target_exists = target.exists() or target.is_symlink()
        if source_exists == target_exists:
            raise AuthLeaseError("Worker authentication location is uncertain; retain it for recovery")
        if source_exists:
            credential(source)
            os.replace(source, target)
            sync(source.parent)
            sync(target.parent)
        credential(target)
        if phase == "returning":
            state.update(phase="idle", last_owner=state["claim"]["owner"], claim=None)
        else:
            state["phase"] = "active"
        self.save(state)

    def claim(self, owner, stage, cidfile, role):
        owner_id(owner)
        stage, cidfile = canonical(stage), canonical(cidfile)
        self.stage_scope(stage, owner, role)
        with self.lock():
            state = self.load()
            self.finish_move(state)
            if state["claim"] is not None:
                raise AuthLeaseBusy("Another worker owns this sign-in; waiting for verified cleanup")
            if (stage / "auth.json").exists() or (stage / "auth.json").is_symlink():
                raise AuthLeaseError("A prior stage credential remains; retain it for recovery")
            credential(self.home / "auth.json")
            state.update(phase="claiming", claim={"owner": owner, "stage_home": str(stage),
                         "cidfile": str(cidfile), "role": role})
            self.save(state)
            self.finish_move(state)

    def wait_claim(self, owner, stage, cidfile, role, *, timeout=1, clock=time.monotonic, sleep=time.sleep):
        deadline = clock() + timeout
        while True:
            try:
                self.claim(owner, stage, cidfile, role)
                return
            except AuthLeaseBusy:
                if clock() >= deadline:
                    raise AuthLeaseBusy("Worker sign-in remains busy; no model turn was started")
                sleep(0.1)

    def retire(self, owner, stage, cidfile):
        owner_id(owner)
        stage, cidfile = canonical(stage), canonical(cidfile)
        with self.lock():
            state = self.load()
            self.finish_move(state)
            claim = state["claim"]
            if claim is None:
                return  # Unclaimed waiter, or a previously completed retirement.
            if claim["owner"] != owner:
                return  # This cancelled waiter never acquired the other owner's lease.
            if claim["stage_home"] != str(stage) or claim["cidfile"] != str(cidfile) or claim["role"] == "enrollment":
                raise AuthLeaseError("Stale worker authentication cleanup; retain ownership")
            state["phase"] = "returning"
            self.save(state)
            self.finish_move(state)

    def status(self):
        # The journal is replaced atomically. Reading status does not create or
        # repair state and never waits for an interactive enrollment's lock.
        if self.root.exists():
            private(self.root, directory=True)
        state = self.load()
        claim = state["claim"]
        current = self.home if claim is None else Path(claim["stage_home"])
        present = (current / "auth.json").exists()
        if present:
            credential(current / "auth.json")
        status = "idle" if claim is None else "active" if state["phase"] == "active" else "recovery"
        return {"state": status, "credential_present": present,
                "sign_in_required": not present, "provider_verified": False}

    @contextmanager
    def enrollment(self):
        # Keep the OS lock for the whole login process. A durable enrollment
        # claim remains if its host process crashes; never replace active auth.
        with self.lock():
            state = self.load()
            if state["claim"] is not None:
                raise AuthLeaseError("Worker sign-in is in use or needs recovery; stop and reconcile it before login")
            state.update(phase="active", claim={"owner": uuid.uuid4().hex, "stage_home": str(self.home),
                                                "cidfile": None, "role": "enrollment"})
            self.save(state)
            yield self.home
            state.update(phase="idle", last_owner=state["claim"]["owner"], claim=None)
            self.save(state)


def prepare_marker(cidfile, owner, home, stage):
    owner_id(owner)
    cidfile, home, stage = canonical(cidfile), canonical(home), canonical(stage)
    private(cidfile.parent, directory=True)
    marker = Path(str(cidfile) + ".auth")
    if marker.exists() or marker.is_symlink():
        raise AuthLeaseError("Worker authentication cleanup marker already exists")
    value = {"version": 1, "owner": owner, "codex_home": str(home), "stage_home": str(stage),
             "cidfile": str(cidfile), "helper": str(Path(__file__).resolve())}
    write_json(marker, value)
    return marker


def retire_marker(marker, owner, cidfile):
    marker, cidfile = canonical(marker), canonical(cidfile)
    owner_id(owner)
    value = read_json(marker)
    if (not isinstance(value, dict) or set(value) != {"version", "owner", "codex_home", "stage_home", "cidfile", "helper"}
            or value["version"] != 1 or value["owner"] != owner or value["cidfile"] != str(cidfile)
            or marker != Path(str(cidfile) + ".auth") or value["helper"] != str(Path(__file__).resolve())):
        raise AuthLeaseError("Worker authentication cleanup identity is invalid")
    AuthLease(value["codex_home"]).retire(owner, value["stage_home"], cidfile)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("retire", "status"))
    parser.add_argument("--marker")
    parser.add_argument("--owner")
    parser.add_argument("--cidfile")
    parser.add_argument("--home")
    args = parser.parse_args()
    try:
        if args.action == "retire":
            retire_marker(args.marker, args.owner, args.cidfile)
        else:
            print(json.dumps(AuthLease(args.home).status(), sort_keys=True))
        return 0
    except (AuthLeaseError, OSError, ValueError, TypeError):
        print("Worker authentication is unavailable; retain state and use the trusted sign-in recovery", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
