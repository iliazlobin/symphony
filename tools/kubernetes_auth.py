#!/usr/bin/env python3
"""Private, durable ChatGPT auth-slot journal for trusted Kubernetes launchers.

This module never reads, copies, logs or implements refresh of OAuth tokens. Codex
owns auth.json in a writable directory on the retained slot PVC. It moves that
single file between fresh stage homes only after the previous claim is retired.
Pinned Codex 0.153.4 truncates its file on refresh; it does not fsync/atomically
replace it. This wrapper cannot repair a crash in that write: unreadable auth
requires fresh independent enrollment, never an older token snapshot restore.

The journal is NOT a distributed fencing service. Expiration never frees a slot.
The controller must stop the old Job, retain fresh terminal Pod evidence, prevent
replacement Pods, and fence an uncertain node before supplying a retirement
receipt. The fixed runtime must stop Codex on renewal loss. RWOP is supplementary.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime
import fcntl
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time
try:
    import tomllib
except ModuleNotFoundError:  # Operator clients on Python 3.9/3.10.
    import tomli as tomllib


class AuthSlotError(RuntimeError):
    """A safe-to-display failure containing no credentials or upstream response."""


# Keep uncertain stage evidence instead of an automatic retention/deletion job.
# A trusted operator must inspect/remove spent, credential-free homes at this
# bounded limit. Generation numbers remain monotonic after that maintenance.
MAX_HOMES = 64


def _reviewed_config(content):
    try:
        config = tomllib.loads(content.decode("utf-8"))
    except (UnicodeError, ValueError) as exc:
        raise AuthSlotError("Reviewed auth configuration is invalid") from exc
    if (config.get("cli_auth_credentials_store") != "file"
            or config.get("forced_login_method") != "chatgpt"
            or config.get("model_provider", "openai") != "openai"
            or config.get("model_providers") or config.get("mcp_servers")):
        raise AuthSlotError("Only file-backed Codex-managed ChatGPT authentication is admitted")


def _identifier(value, pattern, message):
    if not isinstance(value, str) or not re.fullmatch(pattern, value):
        raise AuthSlotError(message)
    return value


def _private(path, directory=False):
    info = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if (not kind(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) & 0o077
            or (not directory and info.st_nlink != 1)):
        raise AuthSlotError("Auth-slot paths must be private, owned, regular and unlinked")


def _sync(directory):
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _write(path, content):
    fd, temporary = tempfile.mkstemp(prefix=".slot-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        _sync(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def subscription_account(response, auth_mode):
    """Validate account/read plus account/updated without returning account PII."""
    if (not isinstance(response, dict) or "error" in response
            or auth_mode != "chatgpt"):
        raise AuthSlotError("ChatGPT managed authentication is required; enrollment is blocked")
    result = response.get("result", response)
    account = result.get("account") if isinstance(result, dict) else None
    if (not isinstance(account, dict) or account.get("type") != "chatgpt"
            or result.get("requiresOpenaiAuth") is not True):
        raise AuthSlotError("ChatGPT managed authentication is unavailable; re-enrollment required")
    return {"auth_mode": "chatgpt"}


def terminal_pod_evidence(pod, claim):
    """Check a fresh trusted API receipt; a missing/force-deleted Pod is not proof.

    The caller separately owns Job cancellation and verifies there are no other
    Pods for its UID. This function cannot verify provenance or node fencing.
    """
    if not isinstance(pod, dict):
        raise AuthSlotError("Exact terminal Pod evidence is required")
    metadata, status, spec = (pod.get(key, {}) for key in ("metadata", "status", "spec"))
    owners = metadata.get("ownerReferences", [])
    if (metadata.get("uid") != claim["pod_uid"]
            or status.get("phase") not in ("Succeeded", "Failed")
            or not any(owner.get("uid") == claim["job_uid"]
                       and owner.get("kind") == "Job" and owner.get("controller") is True
                       for owner in owners)):
        raise AuthSlotError("Pod identity or termination is unverified; retain the auth claim")
    for declared, observed in (("containers", "containerStatuses"),
                               ("initContainers", "initContainerStatuses"),
                               ("ephemeralContainers", "ephemeralContainerStatuses")):
        names = {item.get("name") for item in spec.get(declared, [])}
        states = status.get(observed, [])
        if declared == "containers" and not names:
            raise AuthSlotError("Pod container inventory is missing")
        if names != {item.get("name") for item in states}:
            raise AuthSlotError("Pod container termination evidence is incomplete")
        for item in states:
            terminated = item.get("state", {}).get("terminated", {})
            if (not terminated.get("finishedAt")
                    or type(terminated.get("exitCode")) is not int):
                raise AuthSlotError("Pod still has unverified processes; retain the auth claim")


def evidence_timestamp(value):
    """Parse UTC API timestamps without accepting missing or synthetic zero times."""
    if not isinstance(value, str) or not re.fullmatch(
            r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z", value):
        raise AuthSlotError("Terminal evidence timestamp is invalid")
    try:
        # Python 3.9 accepts microseconds, but GCP exports nanosecond timestamps.
        normalized = value[:-1]
        if "." in normalized:
            seconds, fraction = normalized.split(".")
            normalized = seconds + "." + fraction[:6].ljust(6, "0")
        result = datetime.fromisoformat(normalized + "+00:00").timestamp()
    except ValueError as exc:
        raise AuthSlotError("Terminal evidence timestamp is invalid") from exc
    if result <= 0 or result > time.time() + 5:
        raise AuthSlotError("Terminal evidence timestamp is outside the observed lifetime")
    return result


def archived_terminal_evidence(pod, job, claim):
    """Narrow recovery for one counted, non-retrying pilot Pod archived by GKE.

    The trusted operator separately authenticates the audit response and matches
    it to its original admission. This does not turn deletion into termination.
    """
    terminal_pod_evidence(pod, claim)
    meta, status, spec = (pod.get(key, {}) for key in ("metadata", "status", "spec"))
    job_meta, job_status, job_spec = (job.get(key, {}) for key in ("metadata", "status", "spec"))
    counts = [job_status.get(key, 0) for key in ("failed", "succeeded")]
    terminal_type = "Complete" if status.get("phase") == "Succeeded" else "Failed"
    conditions = [c for c in job_status.get("conditions", [])
                  if c.get("type") in ("Complete", "Failed") and c.get("status") == "True"]
    if (pod.get("kind") != "Pod" or pod.get("apiVersion") != "v1"
            or not meta.get("name") or not meta.get("resourceVersion") or meta.get("deletionTimestamp")
            or meta.get("namespace") != job_meta.get("namespace")
            or meta.get("labels", {}).get("batch.kubernetes.io/controller-uid") != claim["job_uid"]
            or job_meta.get("deletionTimestamp")
            or any(type(job_spec.get(k)) is not int or job_spec[k] != v
                   for k, v in (("backoffLimit", 0), ("parallelism", 1), ("completions", 1)))
            or job_spec.get("podReplacementPolicy") != "Failed"
            or job_spec.get("template", {}).get("spec", {}).get("restartPolicy") != "Never"
            or spec.get("restartPolicy") != "Never"
            or any(type(job_status.get(k, 0)) is not int or job_status.get(k, 0) != 0
                   for k in ("active", "terminating"))
            or any(type(n) is not int or n < 0 for n in counts) or sum(counts) != 1
            or counts != ([0, 1] if terminal_type == "Complete" else [1, 0])
            or job_status.get("uncountedTerminatedPods", {}) not in ({}, {"failed": [], "succeeded": []},
                                                                   {"failed": []}, {"succeeded": []})
            or len(conditions) != 1 or conditions[0].get("type") != terminal_type
            or status.get("reason") in ("NodeLost", "Unknown", "ContainerStatusUnknown")):
        raise AuthSlotError("Archived Pod requires a terminal single-Pod Job without replacement uncertainty")
    created = evidence_timestamp(meta.get("creationTimestamp"))
    terminal_at = evidence_timestamp(conditions[0].get("lastTransitionTime"))
    if evidence_timestamp(job_meta.get("creationTimestamp")) > created:
        raise AuthSlotError("Archived Pod predates its Job")
    # Recovery is deliberately limited to the pilot's one outer worker process.
    states = status.get("containerStatuses", [])
    declared = spec.get("containers", [])
    if (len(declared) != 1 or declared[0].get("name") != "worker" or len(states) != 1
            or spec.get("initContainers") or spec.get("ephemeralContainers")
            or status.get("initContainerStatuses") or status.get("ephemeralContainerStatuses")):
        raise AuthSlotError("Archived pilot container inventory is unsupported")
    state = states[0]
    terminated = state.get("state", {}).get("terminated", {})
    if (type(state.get("restartCount")) is not int or state["restartCount"] != 0
            or state.get("ready") is not False or state.get("started", False) is not False
            or state.get("lastState") or set(state.get("state", {})) != {"terminated"}
            or terminated.get("reason") not in ("Completed", "Error", "OOMKilled")
            or not state.get("containerID") or terminated.get("containerID") != state["containerID"]
            or not state.get("imageID")
            or not any(o.get("name") == job_meta.get("name") and o.get("uid") == claim["job_uid"]
                       and o.get("kind") == "Job" and o.get("controller") is True
                       for o in meta.get("ownerReferences", []))):
        raise AuthSlotError("Archived container stop or identity is unverified")
    if not created <= evidence_timestamp(terminated.get("startedAt")) <= evidence_timestamp(
            terminated.get("finishedAt")) <= terminal_at:
        raise AuthSlotError("Archived container lifetime is inconsistent")


def terminal_job_evidence(receipt, claim):
    """Validate an operator-owned receipt from fresh Job/get and selected Pod/list.

    This is a structural/identity check, NOT receipt authentication. The trusted
    runner obtains fresh Job/PodList objects from the pinned cluster API, never
    model input, exhausting pagination after observing terminal Job status. The
    separate optional archived Pod must come from an authenticated original GKE
    audit response matched to prior admission by the trusted pilot operator.
    NotFound and force deletion alone cannot establish stopped processes.
    """
    if not isinstance(receipt, dict) or set(receipt) not in (
            {"job", "pods", "selector"}, {"job", "pods", "selector", "archived_terminal_pod"}):
        raise AuthSlotError("Terminal Job and exhaustive Pod-list evidence is required")
    job, pods = receipt["job"], receipt["pods"]
    if not isinstance(job, dict) or not isinstance(pods, dict):
        raise AuthSlotError("Terminal Job and exhaustive Pod-list evidence is required")
    metadata, status = job.get("metadata", {}), job.get("status", {})
    if (job.get("kind") != "Job" or job.get("apiVersion") != "batch/v1"
            or metadata.get("uid") != claim["job_uid"] or not metadata.get("resourceVersion")
            or not metadata.get("namespace")
            or status.get("active", 0) != 0 or status.get("terminating", 0) != 0
            or not any(item.get("type") in ("Complete", "Failed") and item.get("status") == "True"
                       for item in status.get("conditions", []))):
        raise AuthSlotError("Job can still produce workers or termination is unverified")
    if (receipt["selector"] != "batch.kubernetes.io/controller-uid=" + claim["job_uid"]
            or pods.get("kind") != "PodList" or pods.get("apiVersion") != "v1"
            or not pods.get("metadata", {}).get("resourceVersion")
            or pods.get("metadata", {}).get("continue")
            or not isinstance(pods.get("items"), list)):
        raise AuthSlotError("Exhaustive owned-Pod inventory is missing")
    if "archived_terminal_pod" in receipt:
        if pods["items"]:
            raise AuthSlotError("Archived recovery requires an empty current Pod inventory")
        archived_terminal_evidence(receipt["archived_terminal_pod"], job, claim)
        return
    if not pods["items"]:
        raise AuthSlotError("Exhaustive owned-Pod inventory is missing")
    seen = set()
    for pod in pods["items"]:
        pod_metadata = pod.get("metadata", {})
        uid = pod_metadata.get("uid")
        if (not uid or uid in seen or pod_metadata.get("namespace") != metadata["namespace"]
                or pod_metadata.get("labels", {}).get("batch.kubernetes.io/controller-uid") != claim["job_uid"]):
            raise AuthSlotError("Owned-Pod inventory identity is inconsistent")
        seen.add(uid)
        terminal_pod_evidence(pod, {**claim, "pod_uid": uid})
    if claim["pod_uid"] not in seen:
        raise AuthSlotError("Claimed Pod is absent; deletion is not termination evidence")


class AuthSlot:
    def __init__(self, root, clock=time.time):
        self.root = Path(root).absolute()
        self.clock = clock
        if self.root.resolve() != self.root:
            raise AuthSlotError("Auth-slot root must not contain symlinks")

    def initialize(self):
        self.root.mkdir(mode=0o700, parents=False, exist_ok=True)
        _private(self.root, directory=True)
        with self._lock():
            if (self.root / "slot.json").exists():
                raise AuthSlotError("Auth slot already exists; initialization never resets it")
            if any(path.name != "slot.lock" for path in self.root.iterdir()):
                raise AuthSlotError("Auth slot initialization requires an empty private directory")
            (self.root / "homes").mkdir(mode=0o700)
            self._save({"version": 1, "generation": 0, "home": None,
                        "claim": None, "transition": None, "blocked": "enrollment_required"})
        return self.status()

    @contextmanager
    def _lock(self):
        _private(self.root, directory=True)
        fd = os.open(self.root / "slot.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            _private(self.root / "slot.lock")
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield
        except BlockingIOError as exc:
            raise AuthSlotError("Another trusted process is updating the auth slot") from exc
        finally:
            os.close(fd)

    def _save(self, state):
        _write(self.root / "slot.json", json.dumps(state, sort_keys=True).encode())

    def _home(self, name):
        _identifier(name, r"[1-9][0-9]*-[a-f0-9]{32}", "Invalid auth home generation")
        _private(self.root / "homes", directory=True)
        path = self.root / "homes" / name
        _private(path, directory=True)
        return path

    def _load(self):
        path = self.root / "slot.json"
        _private(path)
        try:
            state = json.loads(path.read_text())
        except (ValueError, UnicodeError) as exc:
            raise AuthSlotError("Auth journal is unreadable; preserve it for recovery") from exc
        if (not isinstance(state, dict) or state.get("version") != 1
                or type(state.get("generation")) is not int or state["generation"] < 0
                or set(state) != {"version", "generation", "home", "claim", "transition", "blocked"}):
            raise AuthSlotError("Auth journal schema is invalid; preserve it for recovery")
        if state["blocked"] not in (None, "enrollment_required", "auth_lost", "auth_unavailable"):
            raise AuthSlotError("Auth journal block state is invalid")
        claim = state["claim"]
        if claim is not None:
            self._validate_claim(claim)
        if state["home"] is not None:
            self._home(state["home"])
            if not state["home"].startswith(str(state["generation"]) + "-"):
                raise AuthSlotError("Auth journal home generation is inconsistent")
        elif state["generation"] != 0:
            raise AuthSlotError("Auth journal has lost its current home")
        if claim is not None and (claim["generation"] != state["generation"]
                or state["home"] != f'{claim["generation"]}-{claim["owner"]}'):
            raise AuthSlotError("Auth claim and home generation are inconsistent")
        if state["transition"] is not None:
            self._finish_transition(state)
        return state

    @staticmethod
    def _validate_claim(claim):
        if (not isinstance(claim, dict)
                or set(claim) != {"owner", "generation", "role", "job_uid", "pod_uid", "deadline"}
                or type(claim["generation"]) is not int or claim["generation"] < 1
                or claim["role"] not in ("builder", "reviewer", "enrollment")
                or type(claim["deadline"]) not in (int, float) or not math.isfinite(claim["deadline"])):
            raise AuthSlotError("Auth ownership journal is invalid")
        _identifier(claim["owner"], r"[a-f0-9]{32}", "Invalid auth owner nonce")
        for key in ("job_uid", "pod_uid"):
            _identifier(claim[key], r"[a-zA-Z0-9-]{8,128}", "Invalid Kubernetes ownership UID")

    def _finish_transition(self, state):
        transition = state["transition"]
        if (not isinstance(transition, dict)
                or set(transition) != {"home", "old_home", "claim", "enrollment"}
                or type(transition["enrollment"]) is not bool or state["claim"] is not None):
            raise AuthSlotError("Auth transition journal is invalid")
        self._validate_claim(transition["claim"])
        if (transition["claim"]["generation"] != state["generation"] + 1
                or transition["old_home"] != state["home"]
                or transition["home"] != f'{state["generation"] + 1}-{transition["claim"]["owner"]}'):
            raise AuthSlotError("Auth transition identity is inconsistent")
        destination = self._home(transition["home"]) / "auth.json"
        if transition["old_home"] is not None:
            source = self._home(transition["old_home"]) / "auth.json"
            source_exists, destination_exists = source.exists(), destination.exists()
            if source_exists and destination_exists:
                raise AuthSlotError("Ambiguous auth migration; preserve both paths and block execution")
            if source_exists:
                _private(source)
                os.replace(source, destination)
                _sync(source.parent)
                _sync(destination.parent)
            elif not destination_exists and not transition["enrollment"]:
                raise AuthSlotError("Authentication was lost during transition; re-enrollment required")
        if destination.exists():
            _private(destination)
        state.update(generation=transition["claim"]["generation"], home=transition["home"],
                     claim=transition["claim"], transition=None)
        self._save(state)

    def claim(self, owner, role, job_uid, pod_uid, config, rules, *, enrollment=False, ttl=60):
        _identifier(owner, r"[a-f0-9]{32}", "Invalid auth owner nonce")
        for value in (job_uid, pod_uid):
            _identifier(value, r"[a-zA-Z0-9-]{8,128}", "Invalid Kubernetes ownership UID")
        if role not in ("builder", "reviewer", "enrollment") or (role == "enrollment") != enrollment:
            raise AuthSlotError("Invalid auth stage role")
        if not isinstance(config, bytes) or not isinstance(rules, bytes) or not config or not rules:
            raise AuthSlotError("Fresh reviewed config and rules are required")
        _reviewed_config(config)
        deadline = self._deadline(ttl)
        with self._lock():
            state = self._load()
            if state["claim"] is not None:
                raise AuthSlotError("Slot remains owned; expiry never authorizes takeover")
            if state["blocked"] and not enrollment:
                raise AuthSlotError("Authentication is blocked; independent enrollment required")
            _private(self.root / "homes", directory=True)
            if len(list((self.root / "homes").iterdir())) >= MAX_HOMES:
                raise AuthSlotError("Auth stage retention limit reached; trusted maintenance required")
            old_home = state["home"]
            if not enrollment and (old_home is None or not (self._home(old_home) / "auth.json").exists()):
                state["blocked"] = "auth_lost"
                self._save(state)
                raise AuthSlotError("Authentication is missing; independent enrollment required")
            generation = state["generation"] + 1
            name = f"{generation}-{owner}"
            home = self.root / "homes" / name
            home.mkdir(mode=0o700, exist_ok=False)
            _write(home / "config.toml", config)
            _write(home / "AGENTS.md", rules)
            claim = {"owner": owner, "generation": generation, "role": role,
                     "job_uid": job_uid, "pod_uid": pod_uid, "deadline": deadline}
            state["transition"] = {"home": name, "old_home": old_home,
                                   "claim": claim, "enrollment": enrollment}
            self._save(state)
            self._finish_transition(state)
            return {**claim, "codex_home": str(home)}

    def _deadline(self, ttl):
        now = self.clock()
        if (type(ttl) is not int or not 10 <= ttl <= 300
                or not isinstance(now, (int, float)) or not math.isfinite(now)):
            raise AuthSlotError("Invalid bounded auth heartbeat interval")
        return now + ttl

    @staticmethod
    def _owned(state, owner, generation):
        claim = state["claim"]
        if not claim or claim["owner"] != owner or claim["generation"] != generation:
            raise AuthSlotError("Stale auth-slot ownership; execution remains blocked")
        return claim

    def renew(self, owner, generation, ttl=60):
        deadline = self._deadline(ttl)
        with self._lock():
            state = self._load()
            claim = self._owned(state, owner, generation)
            if self.clock() >= claim["deadline"]:
                raise AuthSlotError("Auth heartbeat expired; stop runtime and reconcile ownership")
            if state["blocked"] and claim["role"] != "enrollment":
                raise AuthSlotError("Authentication is blocked; stop runtime")
            if claim["role"] != "enrollment":
                try:
                    _private(self._home(state["home"]) / "auth.json")
                except FileNotFoundError as exc:
                    state["blocked"] = "auth_lost"
                    self._save(state)
                    raise AuthSlotError("Authentication is missing; stop runtime") from exc
            claim["deadline"] = deadline
            self._save(state)
            return {"generation": generation, "deadline": deadline}

    def verify_account(self, owner, generation, response, auth_mode):
        """Admit a fresh account/read response after managed-token validation.

        The caller requests refreshToken=true at stage startup; a locally cached
        account response alone cannot establish provider acceptance or revocation.
        """
        with self._lock():
            state = self._load()
            claim = self._owned(state, owner, generation)
            if self.clock() >= claim["deadline"]:
                raise AuthSlotError("Auth heartbeat expired; stop runtime and reconcile ownership")
            if state["blocked"] and claim["role"] != "enrollment":
                raise AuthSlotError("Authentication remains blocked; retire worker before re-enrollment")
            try:
                subscription_account(response, auth_mode)
                _private(self._home(state["home"]) / "auth.json")
            except (AuthSlotError, FileNotFoundError) as exc:
                state["blocked"] = "auth_unavailable"
                self._save(state)
                raise AuthSlotError("Subscription authentication unavailable; stop and re-enroll") from exc
            state["blocked"] = None
            self._save(state)
            return {"auth_mode": "chatgpt", "generation": generation}

    def retire(self, owner, generation, terminal_receipt):
        with self._lock():
            state = self._load()
            claim = self._owned(state, owner, generation)
            terminal_job_evidence(terminal_receipt, claim)
            state["claim"] = None
            self._save(state)
            return {"generation": generation, "retired": True}

    def status(self):
        with self._lock():
            state = self._load()
            claim = state["claim"]
            return {"version": 1, "generation": state["generation"],
                    "blocked": state["blocked"], "claim": claim,
                    "expired": bool(claim and self.clock() >= claim["deadline"])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("action", choices=("initialize", "status"))
    args = parser.parse_args()
    try:
        result = getattr(AuthSlot(args.root), args.action)()
        print(json.dumps(result, sort_keys=True))
        return 0
    except (AuthSlotError, OSError, ValueError):
        print("Auth-slot operation failed; retain state and inspect with the trusted operator", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
