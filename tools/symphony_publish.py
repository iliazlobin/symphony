#!/usr/bin/env python3
"""Host-only publication of native Symphony review evidence. Never schedules agents."""
from __future__ import annotations

import argparse
import base64
import contextlib
import datetime as dt
import fcntl
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

from symphony_control import ControlError, NoRedirect, load_config, read_private, request_json

REPOSITORY = "iliazlobin/events-concierge"
REMOTE = "https://github.com/" + REPOSITORY + ".git"
SHA = re.compile(r"[0-9a-f]{40}")
ISSUE = re.compile(r"[1-9][0-9]*")
WORK = re.compile(r"[0-9a-f]{32}")
MAX_RESPONSE = 8 * 1024 * 1024
FORBIDDEN = re.compile(
    r"(^|[/_.-])(agents?|claude|workflow|security|auth|permissions?|polic(?:y|ies)|"
    r"deploy(?:ment)?|operations?|runbooks?|recovery|backups?|migration|architecture|"
    r"infrastructure|provision|release|incident|sre)([/_.-]|$)", re.I)
SENSITIVE_NAMES = ("auth", "security", "secret", "credential", "permission", "policy", "runbook",
                   "deployment", "recovery", "backup", "migration", "workflow", "architecture",
                   "operations", "infrastructure", "sign-in", "signin", "oidc", "csrf", "access")


class GitHub:
    def __init__(self, token: str):
        if not token or any(c.isspace() for c in token):
            raise ControlError("A valid host GitHub credential is required")
        self.token = token
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, method: str, path: str, body=None, *, missing=False):
        if not (path == "/repos/" + REPOSITORY or path.startswith("/repos/" + REPOSITORY + "/")
                or path == "/graphql") or ".." in path:
            raise ControlError("GitHub request escaped the approved repository API")
        request = urllib.request.Request(
            "https://api.github.com" + path, method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={"Authorization": "Bearer " + self.token,
                     "Accept": "application/vnd.github+json", "Content-Type": "application/json",
                     "X-GitHub-Api-Version": "2022-11-28"})
        try:
            with self.opener.open(request, timeout=30) as response:
                raw = response.read(MAX_RESPONSE + 1)
                if len(raw) > MAX_RESPONSE:
                    raise ControlError("GitHub response exceeded the size limit")
                result = json.loads(raw)
                if isinstance(result, dict) and result.get("errors"):
                    raise ControlError("GitHub GraphQL rejected the request")
                return result
        except urllib.error.HTTPError as exc:
            if missing and exc.code == 404:
                return None
            raise ControlError(f"GitHub rejected {method} request ({exc.code}); state must be rechecked") from exc
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise ControlError("GitHub result is unknown; reconcile before retrying a mutation") from exc


def host_token() -> str:
    if os.environ.get("GITHUB_TOKEN"):
        return os.environ["GITHUB_TOKEN"]
    result = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise ControlError("Host GitHub authentication is unavailable")
    return result.stdout.strip()


def private_directory(path: Path) -> Path:
    if path.is_symlink() or path != path.resolve():
        raise ControlError("Host publication state may not be a symlink")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ControlError("Host publication state must be private to its owner")
    return path


def write_receipt(path: Path, receipt: dict) -> None:
    private_directory(path.parent)
    if path.is_symlink():
        raise ControlError("Publication receipt may not be a symlink")
    fd, temporary = tempfile.mkstemp(prefix=".receipt-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(receipt, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def owned_workspace(config: dict, value: str, expected: str) -> Path:
    root = Path(config["workspace_root"])
    path = Path(value)
    if (not path.is_absolute() or path != path.resolve() or root != root.resolve()
            or path.parent != root or path.name != expected or not path.is_dir()
            or not (path / ".git").is_dir() or (path / ".git").is_symlink()):
        raise ControlError("Candidate workspace ownership could not be established")
    if (path / ".git/objects/info/alternates").exists():
        raise ControlError("Shared Git object stores are not admitted for publication")
    return path


class CandidateRepository:
    """Copy immutable Git objects before introducing any network credential."""

    def __init__(self, config: dict, issue_id: str, candidate: dict):
        self.config, self.candidate = config, candidate
        workspace_key = "GH-" + issue_id
        if candidate.get("work_id") is not None:
            if not WORK.fullmatch(candidate["work_id"]):
                raise ControlError("Invalid PR work identity")
            workspace_key += "-" + candidate["work_id"]
        self.workspace = owned_workspace(config, candidate["workspace_path"], workspace_key)
        review_name = Path(candidate["review_workspace_path"]).name
        if not re.fullmatch(re.escape(workspace_key) + r"-review-[0-9a-f]{16}", review_name):
            raise ControlError("Unexpected independent review workspace")
        self.review = owned_workspace(config, candidate["review_workspace_path"], review_name)

    def __enter__(self):
        parent = private_directory(Path(self.config["state_dir"]) / "publication")
        self.temporary = tempfile.TemporaryDirectory(prefix="candidate-", dir=parent)
        self.root = Path(self.temporary.name)
        self.repository = self.root / "candidate.git"
        try:
            for source, destination in ((self.workspace, self.repository), (self.review, self.root / "review.git")):
                self.git("clone", "--local", "--no-hardlinks", "--bare", "--", str(source), str(destination))
                if self.git("rev-parse", "--verify", "HEAD", cwd=destination).strip() != self.candidate["candidate_sha"]:
                    raise ControlError("Candidate or review HEAD changed after native review")
            if self.git("symbolic-ref", "--short", "HEAD", cwd=self.repository).strip() != self.candidate["branch"]:
                raise ControlError("Candidate branch changed after native review")
            self.git("merge-base", "--is-ancestor", self.candidate["base_sha"], self.candidate["candidate_sha"], cwd=self.repository)
            if self.candidate.get("expected_head_sha"):
                self.git("merge-base", "--is-ancestor", self.candidate["expected_head_sha"], self.candidate["candidate_sha"], cwd=self.repository)
            return self
        except BaseException:
            self.temporary.cleanup()
            raise

    def __exit__(self, *_):
        self.temporary.cleanup()

    def git(self, *args, cwd=None, token=None):
        env = {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": str(self.root),
               "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
               "GIT_TERMINAL_PROMPT": "0", "GIT_NO_REPLACE_OBJECTS": "1", "GIT_ATTR_NOSYSTEM": "1"}
        if token:
            credential = base64.b64encode(("x-access-token:" + token).encode()).decode()
            env.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="http.https://github.com/.extraHeader",
                       GIT_CONFIG_VALUE_0="Authorization: Basic " + credential)
        command = ["git", "--no-replace-objects", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                   "-c", "credential.helper=", "-c", "http.followRedirects=false", "-c", "http.sslVerify=true",
                   "-c", "core.attributesFile=/dev/null", *args]
        result = subprocess.run(command, cwd=cwd or self.root, env=env, capture_output=True, timeout=120)
        if result.returncode:
            raise ControlError("Trusted Git operation failed; remote state must be rechecked")
        return result.stdout.decode("utf-8", errors="strict")

    def changes(self) -> list[dict]:
        candidate = self.candidate
        output = self.git("diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--numstat", "-z",
                          candidate["base_sha"], candidate["candidate_sha"], "--", cwd=self.repository)
        changes = []
        for entry in output.split("\0"):
            if not entry:
                continue
            added, deleted, path = entry.split("\t", 2)
            tree = self.git("ls-tree", candidate["candidate_sha"], "--", path, cwd=self.repository)
            mode = tree.split(" ", 1)[0] if tree else "deleted"
            changes.append({"path": path, "added": int(added) if added.isdigit() else None,
                            "deleted": int(deleted) if deleted.isdigit() else None, "mode": mode})
        return changes

    def push(self, token: str, expected: str | None):
        candidate = self.candidate
        if expected:
            self.git("merge-base", "--is-ancestor", expected, candidate["candidate_sha"], cwd=self.repository)
        ref = "refs/heads/" + candidate["branch"]
        self.git("push", "--porcelain", "--force-with-lease=" + ref + ":" + (expected or ""),
                 REMOTE, candidate["candidate_sha"] + ":" + ref, cwd=self.repository, token=token)


def glob_matches(path: str, pattern: str) -> bool:
    expression = re.escape(pattern).replace(r"\*\*/", "(?:.*/)?").replace(r"\*\*", ".*")
    expression = expression.replace(r"\*", "[^/]*").replace(r"\?", "[^/]")
    return re.fullmatch(expression, path, re.I) is not None


def low_risk(config: dict, changes: list[dict]) -> None:
    policy = config.get("auto_merge", {})
    if policy.get("enabled") is not True:
        raise ControlError("Automatic merge is disabled in host configuration")
    allowed, denied = policy.get("allowed_paths"), policy.get("denied_paths", [])
    limit = policy.get("max_changed_lines", 80)
    if not allowed or type(limit) is not int or not 0 < limit <= 80 or not changes:
        raise ControlError("Low-risk merge policy is incomplete or the candidate has no changes")
    total = 0
    for change in changes:
        path = change["path"]
        if (not isinstance(path, str) or not re.fullmatch(r"[A-Za-z0-9_./ -]+\.md", path)
                or any(piece in ("", ".", "..") for piece in path.split("/"))
                or not (path.startswith("docs/") or path == "README.md")
                or path in ("PROJECT.md", "CONTEXT.md", "SYSTEM.md") or FORBIDDEN.search(path)
                or any(word in path.lower() for word in SENSITIVE_NAMES)
                or change["mode"] != "100644"
                or not any(glob_matches(path, pattern) for pattern in allowed)
                or any(glob_matches(path, pattern) for pattern in denied)
                or type(change["added"]) is not int or type(change["deleted"]) is not int
                or change["added"] < 0 or change["deleted"] < 0):
            raise ControlError("Candidate is outside the host documentation-only merge allowlist")
        total += change["added"] + change["deleted"]
    if total > limit:
        raise ControlError("Candidate exceeds the host changed-line limit")


class Broker:
    def __init__(self, config: dict, api, snapshot_reader=None, repository_factory=CandidateRepository, publication_writer=None):
        if config.get("repository") != REPOSITORY or not SHA.fullmatch(config.get("base_sha", "")):
            raise ControlError("Publication configuration does not identify the approved repository and baseline")
        branch = config.get("integration_branch", "")
        if not isinstance(branch, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", branch) or ".." in branch or branch.endswith("/"):
            raise ControlError("An explicit valid integration branch is required")
        self.config, self.api, self.repository_factory = config, api, repository_factory
        self.automatic = False
        self.snapshot_reader = snapshot_reader or (lambda: request_json(config, "/api/v1/control"))
        self.prefix = "/repos/" + REPOSITORY
        self.publication_writer = publication_writer or (lambda receipt: request_json(config, "/api/v1/pr-work/publication", receipt))

    @staticmethod
    def selector(issue_id: str, work_id: str | None = None):
        if not isinstance(issue_id, str) or not ISSUE.fullmatch(issue_id):
            raise ControlError("Issue ID must be a positive GitHub issue number")
        if work_id is not None and (not isinstance(work_id, str) or not WORK.fullmatch(work_id)):
            raise ControlError("Work ID must be an immutable 32-character hexadecimal identity")

    def candidate(self, issue_id: str, work_id: str | None = None):
        self.selector(issue_id, work_id)
        snapshot = self.snapshot_reader()
        if self.automatic and snapshot.get("mode") not in ("running", "draining"):
            raise ControlError("Native control paused publication")
        issue = snapshot.get("issues", {}).get(issue_id, {})
        work = issue.get("pr_work", {}).get(work_id) if work_id else None
        item = work.get("handoff") if isinstance(work, dict) else issue.get("handoff")
        settled = work.get("phase") == "owner_review" if isinstance(work, dict) else issue.get("hold") == "owner_review"
        if (snapshot.get("enabled") is not True or snapshot.get("fault") is not None
                or not settled or issue.get("active") is not None or not isinstance(item, dict)):
            raise ControlError("Native control ledger has no settled owner-review candidate")
        expected_branch = "codex/gh-" + issue_id + ("-" + work_id if work_id else "")
        review = item.get("review", {})
        if (not SHA.fullmatch(item.get("candidate_sha", "")) or item.get("base_sha") != self.config["base_sha"]
                or item.get("branch") != expected_branch or item.get("work_id") != work_id
                or not re.fullmatch(r"[A-Za-z0-9_-]{10,128}", item.get("run_id", ""))
                or review.get("candidate_sha") != item["candidate_sha"] or review.get("verdict") != "approve"
                or review.get("findings") != []
                or not item.get("builder_session_id") or not item.get("reviewer_session_id")
                or item["builder_session_id"] == item["reviewer_session_id"]):
            raise ControlError("Native candidate lacks a matching independent approval and trusted baseline")
        if work_id:
            fingerprint = snapshot.get("tracker_fingerprint")
            if (not isinstance(work, dict) or work.get("id") != work_id or work.get("issue_id") != issue_id
                    or not isinstance(fingerprint, str) or not fingerprint or work.get("tracker_fingerprint") != fingerprint
                    or work.get("branch") != expected_branch or work.get("base_sha") != item["base_sha"]
                    or work.get("workspace_key") != "GH-" + issue_id + "-" + work_id
                    or work.get("head_sha") != item["candidate_sha"]
                    or item.get("expected_head_sha") is not None and not SHA.fullmatch(item["expected_head_sha"])
                    or work.get("published_head_sha") is not None and not SHA.fullmatch(work["published_head_sha"])):
                raise ControlError("PR work ownership, tracker scope or candidate head changed")
            item = dict(item, published_head_sha=work.get("published_head_sha"), publication=work.get("publication"))
        return item

    def recheck(self, issue_id: str, candidate: dict):
        if self.candidate(issue_id, candidate.get("work_id")) != candidate:
            raise ControlError("Native candidate changed; publication must restart from fresh evidence")

    def receipt_path(self, issue_id: str, work_id: str | None = None) -> Path:
        self.selector(issue_id, work_id)
        suffix = issue_id + ("-" + work_id if work_id else "")
        return Path(self.config["state_dir"]) / "receipts" / ("publication-" + suffix + ".json")

    def receipt(self, issue_id: str, work_id: str | None = None) -> dict:
        path = self.receipt_path(issue_id, work_id)
        return json.loads(read_private(path)) if path.exists() else {}

    def acknowledge(self, receipt: dict):
        if receipt.get("work_id"):
            keys = ("issue_id", "work_id", "run_id", "candidate_sha", "expected_head_sha", "branch", "base_sha",
                    "pr_number", "pr_url", "status", "merge_sha")
            self.publication_writer({key: receipt[key] for key in keys if key in receipt})
        return receipt

    def record(self, issue_id: str, candidate: dict, pr: dict, status: str, **extra):
        result = {"version": 1, "issue_id": issue_id, "repository": REPOSITORY,
                  "run_id": candidate["run_id"], "candidate_sha": candidate["candidate_sha"],
                  "base_sha": candidate["base_sha"], "branch": candidate["branch"],
                  "pr_number": pr["number"], "pr_url": pr["html_url"], "status": status,
                  "updated_at": dt.datetime.now(dt.timezone.utc).isoformat(), **extra}
        if candidate.get("work_id"):
            result.update(work_id=candidate["work_id"], expected_head_sha=candidate.get("expected_head_sha"))
        write_receipt(self.receipt_path(issue_id, candidate.get("work_id")), result)
        return self.acknowledge(result)

    def record_error(self, issue_id: str, reason: str, work_id: str | None = None):
        previous = self.receipt(issue_id, work_id)
        if previous.get("last_error") == reason:
            return
        receipt = previous or {"version": 1, "issue_id": issue_id, "repository": REPOSITORY, "status": "blocked"}
        if work_id:
            receipt["work_id"] = work_id
        receipt.update(last_error=reason, updated_at=dt.datetime.now(dt.timezone.utc).isoformat())
        write_receipt(self.receipt_path(issue_id, work_id), receipt)

    def issue(self, issue_id: str, *, merging=False):
        issue = self.api.request("GET", self.prefix + "/issues/" + issue_id)
        labels = {label.get("name") for label in issue.get("labels", []) if isinstance(label, dict)}
        required = {"symphony:ready", "symphony:auto-merge"} if merging else {"symphony:ready"}
        if issue.get("state") != "open" or "pull_request" in issue or not required <= labels:
            raise ControlError("The issue is no longer open and explicitly routed for this action")
        return issue

    def base(self, candidate: dict):
        repository = self.api.request("GET", self.prefix)
        if repository.get("full_name") != REPOSITORY or repository.get("private") is not True:
            raise ControlError("Publication target is not the approved private repository")
        branch = self.api.request("GET", self.prefix + "/branches/" + urllib.parse.quote(self.config["integration_branch"], safe=""))
        if branch.get("commit", {}).get("sha") != candidate["base_sha"]:
            raise ControlError("Integration branch moved from the reviewed baseline; rebuild and review first")
        return branch

    @staticmethod
    def marker(issue_id: str, work_id: str | None = None) -> str:
        return "<!-- symphony issue=GH-" + issue_id + (" work=" + work_id if work_id else "") + " -->"

    def pr_body(self, issue_id: str, candidate: dict):
        def plain(value):
            # Builder prose must not create mentions, closing directives or embedded content.
            return html.escape(value).replace("#", "&#35;").replace("@", "&#64;").replace("[", "&#91;").replace("]", "&#93;")

        checks = "\n".join("- " + plain(check["name"]) + ": **" + check["result"] + "** — " + plain(check["details"])
                           for check in candidate.get("checks", [])) or "- No local checks reported."
        limits = "\n".join("- " + plain(value) for value in candidate.get("limitations", [])) or "- No additional limitations reported."
        return (self.marker(issue_id, candidate.get("work_id")) + "\n\n" + plain(candidate["summary"]) + "\n\nRefs #" + issue_id
                + "\n\nCandidate: `" + candidate["candidate_sha"] + "`. Base: `" + candidate["base_sha"]
                + "`.\nIndependent reviewer approved this exact commit with no findings.\n\n"
                + "The builder recorded the following checks and limitations before independent host review and publication.\n\n"
                + "Local checks at builder handoff:\n" + checks + "\n\nLimitations at builder handoff:\n"
                + limits + "\n\nDeployment is not part of this pull request.\n")

    def verify_pr(self, pr: dict, issue_id: str, candidate: dict, *, allow_old_head=False):
        if (pr.get("state") != "open" or self.marker(issue_id, candidate.get("work_id")) not in pr.get("body", "")
                or pr.get("head", {}).get("repo", {}).get("full_name") != REPOSITORY
                or pr.get("base", {}).get("repo", {}).get("full_name") != REPOSITORY
                or pr["head"].get("ref") != candidate["branch"]
                or pr["base"].get("ref") != self.config["integration_branch"]
                or pr["base"].get("sha") != candidate["base_sha"]
                or not allow_old_head and pr["head"].get("sha") != candidate["candidate_sha"]):
            raise ControlError("Remote PR ownership, head or base does not match the native candidate")

    def publish(self, issue_id: str, work_id: str | None = None):
        candidate = self.candidate(issue_id, work_id)
        previous = self.receipt(issue_id, work_id)
        binding = candidate.get("publication") or previous
        if previous.get("pr_number") and binding.get("pr_number") != previous["pr_number"]:
            raise ControlError("Host and native PR work receipts disagree")
        if binding.get("pr_number"):
            known_pr = self.api.request("GET", self.prefix + "/pulls/" + str(binding["pr_number"]))
            if known_pr.get("merged") is True:
                if (binding.get("candidate_sha") != candidate["candidate_sha"]
                        or known_pr.get("head", {}).get("sha") != candidate["candidate_sha"]
                        or known_pr.get("head", {}).get("ref") != candidate["branch"]
                        or known_pr.get("head", {}).get("repo", {}).get("full_name") != REPOSITORY
                        or known_pr.get("base", {}).get("ref") != self.config["integration_branch"]
                        or known_pr.get("base", {}).get("repo", {}).get("full_name") != REPOSITORY
                        or self.marker(issue_id, candidate.get("work_id")) not in known_pr.get("body", "")
                        or not SHA.fullmatch(known_pr.get("merge_commit_sha", ""))):
                    raise ControlError("Merged PR does not match the native candidate receipt")
                if previous.get("status") == "merged":
                    return self.acknowledge(previous)
                return self.record(issue_id, candidate, known_pr, "merged", merge_sha=known_pr["merge_commit_sha"])
            self.verify_pr(known_pr, issue_id, candidate, allow_old_head=True)
        issue = self.issue(issue_id)
        self.base(candidate)
        ref_path = self.prefix + "/git/ref/heads/" + urllib.parse.quote(candidate["branch"], safe="/")
        remote = self.api.request("GET", ref_path, missing=True)
        remote_sha = remote.get("object", {}).get("sha") if remote else None
        if remote_sha is not None and not SHA.fullmatch(remote_sha):
            raise ControlError("Remote task reference is malformed")
        if work_id and remote_sha not in (candidate["published_head_sha"], candidate["candidate_sha"]):
            raise ControlError("Remote PR work head changed from its last acknowledged publication")
        if remote_sha not in (None, candidate["candidate_sha"]):
            if (binding.get("candidate_sha") != remote_sha or binding.get("branch") != candidate["branch"]
                    or (not work_id and binding.get("repository") != REPOSITORY) or binding.get("issue_id") != issue_id):
                raise ControlError("Refusing to replace a task branch without a matching host publication receipt")
        query = urllib.parse.urlencode({"state": "open", "head": "iliazlobin:" + candidate["branch"],
                                        "base": self.config["integration_branch"], "per_page": 100})
        prs = self.api.request("GET", self.prefix + "/pulls?" + query)
        if not isinstance(prs, list) or len(prs) > 1:
            raise ControlError("Remote task PR is ambiguous")
        pr = self.api.request("GET", self.prefix + "/pulls/" + str(prs[0]["number"])) if prs else None
        if binding.get("pr_number") and (not pr or pr.get("number") != binding["pr_number"]):
            raise ControlError("The bound PR is no longer the open PR for this work session")
        if pr:
            self.verify_pr(pr, issue_id, candidate, allow_old_head=True)
            if pr["head"]["sha"] != remote_sha:
                raise ControlError("PR and remote task reference disagree")
        with self.repository_factory(self.config, issue_id, candidate) as repository:
            self.recheck(issue_id, candidate)
            if remote_sha != candidate["candidate_sha"]:
                repository.push(self.api.token, remote_sha)
        observed = self.api.request("GET", ref_path)
        if observed.get("object", {}).get("sha") != candidate["candidate_sha"]:
            raise ControlError("Published task reference does not match the candidate")
        self.recheck(issue_id, candidate)
        self.issue(issue_id)
        self.base(candidate)
        body = self.pr_body(issue_id, candidate)
        if pr is not None:
            pr = self.api.request("GET", self.prefix + "/pulls/" + str(pr["number"]))
            self.verify_pr(pr, issue_id, candidate)
        if pr is None:
            pr = self.api.request("POST", self.prefix + "/pulls", {
                "title": ("GH-" + issue_id + ": " + issue["title"].replace("\n", " ").replace("#", "＃").replace("@", "＠"))[:200], "head": candidate["branch"],
                "base": self.config["integration_branch"], "body": body, "draft": True})
        elif pr.get("body") != body:
            pr = self.api.request("PATCH", self.prefix + "/pulls/" + str(pr["number"]), {"body": body})
        pr = self.api.request("GET", self.prefix + "/pulls/" + str(pr["number"]))
        self.verify_pr(pr, issue_id, candidate)
        status = "draft_pr" if pr.get("draft") else "ready"
        if (previous.get("run_id") == candidate["run_id"] and previous.get("candidate_sha") == candidate["candidate_sha"]
                and previous.get("pr_number") == pr["number"] and previous.get("status") == status and "last_error" not in previous):
            return self.acknowledge(previous)
        return self.record(issue_id, candidate, pr, status)

    def required_checks(self, candidate: dict):
        expected = self.config.get("auto_merge", {}).get("required_checks")
        if not isinstance(expected, list) or not expected or any(not isinstance(name, str) or not name for name in expected):
            raise ControlError("Known required checks are not configured")
        path = self.prefix + "/branches/" + urllib.parse.quote(self.config["integration_branch"], safe="") + "/protection"
        protection = self.api.request("GET", path)
        required = protection.get("required_status_checks", {})
        pinned = {check.get("context"): check.get("app_id") for check in required.get("checks", [])}
        contexts = set(required.get("contexts", [])) | set(pinned)
        if (required.get("strict") is not True or protection.get("enforce_admins", {}).get("enabled") is not True
                or not contexts or contexts != set(expected)
                or any(type(pinned.get(name)) is not int or pinned[name] <= 0 for name in expected)):
            raise ControlError("Protected branch must enforce the exact known checks from pinned GitHub Apps")
        runs, total = [], None
        for page in range(1, 11):
            result = self.api.request("GET", self.prefix + "/commits/" + candidate["candidate_sha"]
                                      + "/check-runs?filter=latest&per_page=100&page=" + str(page))
            batch = result.get("check_runs")
            reported = result.get("total_count")
            if (not isinstance(batch, list) or len(batch) > 100
                    or type(reported) is not int or not 0 <= reported <= 1000
                    or total is not None and total != reported
                    or any(not isinstance(run, dict) or not isinstance(run.get("app"), dict) for run in batch)):
                raise ControlError("GitHub check evidence is malformed")
            total = reported
            runs += batch
            if len(runs) > total or len(batch) < 100 and len(runs) != total:
                raise ControlError("GitHub check evidence is incomplete or changed during pagination")
            if len(runs) == total:
                break
        else:
            raise ControlError("GitHub check evidence exceeded the bounded read limit")
        for name in expected:
            matching = [run for run in runs if run.get("name") == name and run.get("app", {}).get("id") == pinned[name]]
            if (len(matching) != 1 or matching[0].get("head_sha") != candidate["candidate_sha"]
                    or matching[0].get("status") != "completed" or matching[0].get("conclusion") != "success"):
                raise ControlError("Required checks are missing, ambiguous, pending or unsuccessful for this exact candidate")

    def merge(self, issue_id: str, work_id: str | None = None):
        if self.config.get("auto_merge", {}).get("enabled") is not True:
            raise ControlError("Automatic merge is disabled in host configuration")
        candidate = self.candidate(issue_id, work_id)
        if any(check.get("result") == "failed" for check in candidate.get("checks", [])):
            raise ControlError("Failed local checks must be resolved before automatic merge")
        self.issue(issue_id, merging=True)
        branch = self.base(candidate)
        if branch.get("protected") is not True:
            raise ControlError("Automatic merge requires verified branch protection")
        previous = self.receipt(issue_id, work_id)
        if previous.get("candidate_sha") != candidate["candidate_sha"] or not previous.get("pr_number"):
            raise ControlError("Publish this exact native candidate before merging")
        pr_path = self.prefix + "/pulls/" + str(previous["pr_number"])
        pr = self.api.request("GET", pr_path)
        self.verify_pr(pr, issue_id, candidate)
        with self.repository_factory(self.config, issue_id, candidate) as repository:
            low_risk(self.config, repository.changes())
        self.required_checks(candidate)
        self.recheck(issue_id, candidate)
        self.issue(issue_id, merging=True)
        self.base(candidate)
        pr = self.api.request("GET", pr_path)
        self.verify_pr(pr, issue_id, candidate)
        if pr.get("draft") is True:
            result = self.api.request("POST", "/graphql", {
                "query": "mutation($id:ID!){markPullRequestReadyForReview(input:{pullRequestId:$id}){pullRequest{id isDraft}}}",
                "variables": {"id": pr["node_id"]}})
            node = result.get("data", {}).get("markPullRequestReadyForReview", {}).get("pullRequest", {})
            if node.get("id") != pr["node_id"] or node.get("isDraft") is not False:
                raise ControlError("Draft transition is unknown; reconcile before attempting merge")
            return self.record(issue_id, candidate, pr, "ready", next="Recheck protection and CI in the next pass")
        if pr.get("draft") is not False or pr.get("mergeable") is not True or pr.get("mergeable_state") != "clean":
            raise ControlError("GitHub has not confirmed that this PR can merge cleanly")
        result = self.api.request("PUT", pr_path + "/merge", {
            "sha": candidate["candidate_sha"], "merge_method": "squash",
            "commit_title": "GH-" + issue_id + ": reviewed documentation update",
            "commit_message": "Reviewed candidate " + candidate["candidate_sha"] + ". Refs #" + issue_id + "."})
        if result.get("merged") is not True or not SHA.fullmatch(result.get("sha", "")):
            raise ControlError("GitHub did not confirm the merge; reconcile remote state")
        return self.record(issue_id, candidate, pr, "merged", merge_sha=result["sha"])

    def reconcile(self, issue_id: str | None = None, work_id: str | None = None):
        if issue_id is not None:
            self.selector(issue_id, work_id)
        elif work_id is not None:
            raise ControlError("A work selector requires an issue ID")
        snapshot = self.snapshot_reader()
        if snapshot.get("enabled") is not True or snapshot.get("fault") is not None:
            raise ControlError("Native control is unavailable; publication is stopped")
        if snapshot.get("mode") not in ("running", "draining"):
            return {"mode": snapshot.get("mode"), "results": []}
        self.automatic = True
        results = []
        try:
            for current_id, state in sorted(snapshot.get("issues", {}).items()):
                if issue_id is not None and issue_id != current_id or state.get("active") is not None:
                    continue
                works = state.get("pr_work", {})
                selected = [(key, work.get("handoff", {})) for key, work in sorted(works.items())
                            if work.get("phase") == "owner_review" and (work_id is None or key == work_id)]
                if not works and work_id is None and state.get("hold") == "owner_review":
                    selected = [(None, state.get("handoff", {}))]
                for selected_id, handoff in selected:
                    previous = self.receipt(current_id, selected_id)
                    if selected_id is None and previous.get("status") == "merged" and previous.get("candidate_sha") == handoff.get("candidate_sha"):
                        continue
                    identity = {"issue_id": current_id, **({"work_id": selected_id} if selected_id else {})}
                    try:
                        result = self.publish(current_id, selected_id)
                        if result["status"] != "merged" and self.config.get("auto_merge", {}).get("enabled") is True:
                            issue = self.issue(current_id)
                            if any(label.get("name") == "symphony:auto-merge" for label in issue.get("labels", []) if isinstance(label, dict)):
                                result = self.merge(current_id, selected_id)
                        results.append({**identity, "status": result["status"], "pr_url": result["pr_url"]})
                    except ControlError as exc:
                        self.record_error(current_id, str(exc), selected_id)
                        results.append({**identity, "status": "blocked", "reason": str(exc)})
        finally:
            self.automatic = False
        return {"mode": snapshot.get("mode"), "results": results}


@contextlib.contextmanager
def publication_lock(config: dict):
    state = private_directory(Path(config["state_dir"]))
    fd = os.open(state / "publication.lock", os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ControlError("Another host publication pass is active") from exc
        yield
    finally:
        os.close(fd)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config")
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("publish", "merge", "inspect"):
        action = sub.add_parser(command)
        action.add_argument("issue_id")
        action.add_argument("--work-id")
    reconcile = sub.add_parser("reconcile")
    reconcile.add_argument("--issue-id")
    reconcile.add_argument("--work-id")
    watch = sub.add_parser("watch")
    watch.add_argument("--interval", type=int, default=30)
    watch.add_argument("--issue-id")
    watch.add_argument("--work-id")
    args = parser.parse_args()
    try:
        config = load_config(args.config)
        if args.command == "inspect":
            broker = Broker(config, None)
            print(json.dumps(broker.candidate(args.issue_id, args.work_id), indent=2))
            return 0
        if args.command == "watch" and not 5 <= args.interval <= 300:
            raise ControlError("Watch interval must be between 5 and 300 seconds")
        api = GitHub(host_token())
        prior = None
        while True:
            try:
                config = load_config(args.config)
                broker = Broker(config, api)
                with publication_lock(config):
                    if args.command in ("reconcile", "watch"):
                        result = broker.reconcile(args.issue_id, args.work_id)
                    else:
                        result = getattr(broker, args.command)(args.issue_id, args.work_id)
            except ControlError as exc:
                if args.command != "watch":
                    raise
                result = {"status": "blocked", "reason": str(exc)}
            rendered = json.dumps(result, sort_keys=True)
            if rendered != prior:
                print(rendered, flush=True)
                prior = rendered
            if args.command != "watch":
                return 0
            time.sleep(args.interval)
    except (ControlError, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as exc:
        print("Publication stopped: " + str(exc), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
