"""Host publication tests; all GitHub writes are fake API calls."""
from __future__ import annotations

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import urllib.parse

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from symphony_publish import Broker, CandidateRepository, ControlError, REPOSITORY, low_risk, publication_lock

BASE = "a" * 40
HEAD = "b" * 40
MERGED = "c" * 40


class FakeGitHub:
    token = "host-only-test-token"

    def __init__(self):
        self.calls = []
        self.issue = {"state": "open", "title": "Improve a guide", "labels": [{"name": "symphony:ready"}, {"name": "symphony:auto-merge"}]}
        self.base = {"commit": {"sha": BASE}, "protected": True}
        self.protection = {"required_status_checks": {"strict": True, "contexts": ["unit"],
                                                     "checks": [{"context": "unit", "app_id": 42}]},
                           "enforce_admins": {"enabled": True}}
        self.runs = [{"name": "unit", "app": {"id": 42}, "head_sha": HEAD, "status": "completed", "conclusion": "success"}]
        self.ref = None
        self.pr = None
        self.before = None

    def request(self, method, path, body=None, *, missing=False):
        self.calls.append((method, path, copy.deepcopy(body)))
        if self.before:
            self.before(method, path, body)
        endpoint = urllib.parse.urlsplit(path).path.removeprefix("/repos/" + REPOSITORY)
        if method == "GET" and endpoint == "":
            result = {"full_name": REPOSITORY, "private": True}
        elif method == "GET" and endpoint == "/issues/7":
            result = self.issue
        elif method == "GET" and endpoint == "/branches/main":
            result = self.base
        elif method == "GET" and endpoint == "/branches/main/protection":
            result = self.protection
        elif method == "GET" and endpoint.startswith("/git/ref/heads/"):
            result = {"object": {"sha": self.ref}} if self.ref else None
        elif method == "GET" and endpoint == "/pulls":
            result = [self.pr] if self.pr and self.pr["state"] == "open" else []
        elif method == "GET" and endpoint == "/pulls/11":
            result = self.pr
        elif method == "GET" and endpoint.endswith("/check-runs"):
            result = {"check_runs": self.runs, "total_count": len(self.runs)}
        elif method == "POST" and endpoint == "/pulls":
            assert self.pr is None
            self.pr = {"number": 11, "node_id": "PR_TEST", "html_url": "https://github.com/" + REPOSITORY + "/pull/11",
                       "body": body["body"], "state": "open", "draft": body["draft"], "merged": False,
                       "head": {"ref": body["head"], "sha": self.ref, "repo": {"full_name": REPOSITORY}},
                       "base": {"ref": body["base"], "sha": self.base["commit"]["sha"], "repo": {"full_name": REPOSITORY}},
                       "mergeable": True, "mergeable_state": "clean"}
            result = self.pr
        elif method == "PATCH" and endpoint == "/pulls/11":
            self.pr.update(body)
            result = self.pr
        elif method == "POST" and path == "/graphql":
            assert body["variables"] == {"id": "PR_TEST"}
            self.pr["draft"] = False
            result = {"data": {"markPullRequestReadyForReview": {"pullRequest": {"id": "PR_TEST", "isDraft": False}}}}
        elif method == "PUT" and endpoint == "/pulls/11/merge":
            assert body["sha"] == self.ref
            self.pr.update(state="closed", merged=True, merge_commit_sha=MERGED)
            self.base["commit"]["sha"] = MERGED
            result = {"merged": True, "sha": MERGED}
        else:
            raise AssertionError((method, path, body))
        return copy.deepcopy(result)


class PublishTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        state = Path(self.temp.name).resolve()
        self.config = {"repository": REPOSITORY, "base_sha": BASE, "integration_branch": "main",
                       "state_dir": str(state), "workspace_root": str(state / "workspaces"),
                       "auto_merge": {"enabled": False, "allowed_paths": ["docs/**/*.md"], "denied_paths": [],
                                      "max_changed_lines": 80, "required_checks": ["unit"]}}
        self.candidate = {"run_id": "native-run-123456789", "base_sha": BASE, "candidate_sha": HEAD,
                          "branch": "codex/gh-7", "summary": "Clarify the guide", "checks": [], "limitations": [],
                          "workspace_path": str(state / "workspaces/GH-7"),
                          "review_workspace_path": str(state / "workspaces/GH-7-review-1234567890abcdef"),
                          "builder_session_id": "builder", "reviewer_session_id": "reviewer",
                          "review": {"candidate_sha": HEAD, "verdict": "approve", "findings": []}}
        self.snapshot = {"enabled": True, "fault": None, "mode": "running", "revision": 3,
                         "issues": {"7": {"hold": "owner_review", "active": None, "handoff": self.candidate}}}
        self.api = FakeGitHub()
        self.pushes = []
        self.changes = [{"path": "docs/guide.md", "added": 4, "deleted": 2, "mode": "100644"}]
        outer = self

        class Repository:
            def __init__(self, _config, _issue_id, candidate):
                self.candidate = candidate

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return None

            def changes(self):
                return outer.changes

            def push(self, token, expected):
                assert token == outer.api.token
                assert outer.api.ref == expected
                outer.pushes.append((self.candidate["candidate_sha"], expected))
                outer.api.ref = self.candidate["candidate_sha"]
                if outer.api.pr:
                    outer.api.pr["head"]["sha"] = outer.api.ref

        self.broker = Broker(self.config, self.api, lambda: copy.deepcopy(self.snapshot), Repository)

    def writes(self):
        return [call for call in self.api.calls if call[0] != "GET"]

    def ready_pr(self):
        self.broker.publish("7")
        self.api.pr["draft"] = False
        self.config["auto_merge"]["enabled"] = True
        self.api.calls.clear()

    def test_publication_is_draft_and_idempotent_with_private_receipt(self):
        first = self.broker.publish("7")
        second = self.broker.publish("7")
        self.assertEqual(first, second)
        self.assertEqual(first["status"], "draft_pr")
        self.assertEqual(len(self.pushes), 1)
        self.assertEqual(len(self.writes()), 1)
        self.assertTrue(self.writes()[0][2]["draft"])
        path = Path(self.config["state_dir"]) / "receipts/publication-7.json"
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(self.api.token, path.read_text())

    def test_only_native_run_fenced_independent_approval_is_accepted(self):
        changes = [lambda: self.snapshot.update(fault="disk failure"),
                   lambda: self.snapshot["issues"]["7"].update(active={"run_id": "other"}),
                   lambda: self.snapshot["issues"]["7"].update(hold="cancelled"),
                   lambda: self.candidate.update(run_id=""),
                   lambda: self.candidate.update(base_sha="d" * 40),
                   lambda: self.candidate.update(branch="main"),
                   lambda: self.candidate.update(reviewer_session_id="builder"),
                   lambda: self.candidate["review"].update(candidate_sha=BASE),
                   lambda: self.candidate["review"].update(verdict="request_changes"),
                   lambda: self.candidate["review"].update(findings=[{"severity": "high"}])]
        original = copy.deepcopy(self.snapshot)
        for change in changes:
            self.snapshot = copy.deepcopy(original)
            self.candidate = self.snapshot["issues"]["7"]["handoff"]
            change()
            with self.assertRaises(ControlError):
                self.broker.publish("7")
        self.assertFalse(self.writes())
        self.assertFalse(self.pushes)

    def test_label_withdrawal_changed_base_and_unowned_branch_do_not_push(self):
        for mutation in (lambda: self.api.issue.update(labels=[]),
                         lambda: self.api.base["commit"].update(sha="d" * 40),
                         lambda: setattr(self.api, "ref", "e" * 40)):
            self.api = FakeGitHub()
            self.broker.api = self.api
            mutation()
            with self.assertRaises(ControlError):
                self.broker.publish("7")
            self.assertFalse(self.writes())
        self.assertFalse(self.pushes)

    def test_native_run_change_before_push_blocks_publication(self):
        reads = 0

        def snapshot():
            nonlocal reads
            reads += 1
            result = copy.deepcopy(self.snapshot)
            if reads > 1:
                result["issues"]["7"]["handoff"]["run_id"] = "replacement-run-123"
            return result

        self.broker.snapshot_reader = snapshot
        with self.assertRaises(ControlError):
            self.broker.publish("7")
        self.assertFalse(self.pushes)
        self.assertFalse(self.writes())

    def test_builder_prose_cannot_add_closing_directives_or_mentions(self):
        self.candidate["summary"] = "Closes #99 @someone ![image](https://invalid.example)"
        body = self.broker.pr_body("7", self.candidate)
        self.assertNotIn("Closes #99", body)
        self.assertNotIn("@someone", body)
        self.assertNotIn("![image]", body)
        self.assertIn("Refs #7", body)

    def test_builder_evidence_keeps_results_and_limitations_in_handoff_context(self):
        self.candidate["checks"] = [
            {"name": "Unit tests", "result": "failed", "details": "Two assertions failed."},
            {"name": "Integration tests", "result": "not_run", "details": "Database unavailable."},
            {"name": "Formatting", "result": "passed", "details": "No formatting errors."},
        ]
        self.candidate["limitations"] = ["Independent review is pending.", "Candidate has not been pushed."]
        original = copy.deepcopy(self.candidate)
        body = self.broker.pr_body("7", self.candidate)
        self.assertIn("before independent host review and publication", body)
        self.assertIn("Independent reviewer approved this exact commit with no findings.", body)
        for check in original["checks"]:
            self.assertIn(check["name"] + ": **" + check["result"] + "** — " + check["details"], body)
        for limitation in original["limitations"]:
            self.assertIn(limitation, body)
        self.assertEqual(self.candidate, original)

    def test_low_risk_allowlist_rejects_controls_binary_symlinks_and_large_changes(self):
        self.config["auto_merge"]["enabled"] = True
        low_risk(self.config, self.changes)
        for path in ("AGENTS.md", "WORKFLOW.md", "docs/security.md", "docs/production-operations.md",
                     "docs/authentication.md", "docs/secrets-explained.md", "docs/google-sign-in.md",
                     "docs/deploy.md", "docs/example/runbook.md", "docs/../README.md", ".github/example.md", "src/main.py"):
            with self.subTest(path=path), self.assertRaises(ControlError):
                low_risk(self.config, [dict(self.changes[0], path=path)])
        for change in ({"mode": "120000"}, {"mode": "deleted"}, {"added": None}, {"added": 81}, {"added": -1}):
            with self.subTest(change=change), self.assertRaises(ControlError):
                low_risk(self.config, [dict(self.changes[0], **change)])

    def test_merge_requires_explicit_host_enablement_and_issue_label(self):
        self.broker.publish("7")
        with self.assertRaises(ControlError):
            self.broker.merge("7")
        self.config["auto_merge"]["enabled"] = True
        self.api.issue["labels"] = [{"name": "symphony:ready"}]
        self.api.calls.clear()
        with self.assertRaises(ControlError):
            self.broker.merge("7")
        self.assertFalse(self.writes())

    def test_merge_uses_exact_sha_guard_and_safe_squash_message(self):
        self.ready_pr()
        result = self.broker.merge("7")
        self.assertEqual(result["status"], "merged")
        mutation = self.writes()[0]
        self.assertEqual(mutation[0], "PUT")
        self.assertEqual(mutation[2]["sha"], HEAD)
        self.assertEqual(mutation[2]["merge_method"], "squash")
        self.assertEqual(result["merge_sha"], MERGED)
        self.assertNotIn("Closes", mutation[2]["commit_message"])
        self.assertEqual(self.broker.publish("7")["status"], "merged")

    def test_draft_requires_a_separate_fresh_pass_after_readiness(self):
        self.broker.publish("7")
        self.config["auto_merge"]["enabled"] = True
        self.api.calls.clear()
        self.assertEqual(self.broker.merge("7")["status"], "ready")
        self.assertEqual([call[0] for call in self.writes()], ["POST"])
        self.api.runs[0]["status"] = "in_progress"
        with self.assertRaises(ControlError):
            self.broker.merge("7")
        self.assertNotIn("PUT", [call[0] for call in self.writes()])

    def test_required_checks_reject_incomplete_or_malformed_pages(self):
        self.ready_pr()
        original = self.api.request
        for payload in ({"check_runs": self.api.runs, "total_count": 2},
                        {"check_runs": self.api.runs, "total_count": True},
                        {"check_runs": self.api.runs},
                        {"check_runs": [None], "total_count": 1}):
            def request(method, path, body=None, *, missing=False):
                if "/check-runs?" in path:
                    return payload
                return original(method, path, body, missing=missing)
            self.api.request = request
            with self.subTest(payload=payload), self.assertRaises(ControlError):
                self.broker.merge("7")
        self.assertFalse(self.writes())

    def test_required_checks_fail_closed_for_pending_failed_skipped_wrong_sha_or_app(self):
        self.ready_pr()
        original = copy.deepcopy(self.api.runs[0])
        for overrides in ({"status": "in_progress"}, {"conclusion": "failure"}, {"conclusion": "skipped"},
                          {"head_sha": BASE}, {"app": {"id": 43}}):
            self.api.runs = [dict(original, **overrides)]
            with self.subTest(overrides=overrides), self.assertRaises(ControlError):
                self.broker.merge("7")
        self.api.runs = [original, original]
        with self.assertRaises(ControlError):
            self.broker.merge("7")
        self.assertFalse(self.writes())

    def test_unknown_unprotected_or_unpinned_branch_policy_blocks_merge(self):
        self.ready_pr()
        for mutation in (lambda: self.api.base.update(protected=False),
                         lambda: self.api.protection["required_status_checks"].update(strict=False),
                         lambda: self.api.protection["required_status_checks"]["checks"][0].update(app_id=-1),
                         lambda: self.config["auto_merge"].update(required_checks=[])):
            saved_api, saved_policy = copy.deepcopy(self.api.__dict__), copy.deepcopy(self.config["auto_merge"])
            mutation()
            with self.assertRaises(ControlError):
                self.broker.merge("7")
            self.api.__dict__ = saved_api
            self.config["auto_merge"] = saved_policy
        self.assertFalse(self.writes())

    def test_head_changed_after_check_verification_cannot_merge(self):
        self.ready_pr()
        reads = 0

        def change_after_first(method, path, _body):
            nonlocal reads
            if method == "GET" and path.endswith("/pulls/11"):
                reads += 1
                if reads == 2:
                    self.api.pr["head"]["sha"] = "d" * 40

        self.api.before = change_after_first
        with self.assertRaises(ControlError):
            self.broker.merge("7")
        self.assertFalse(self.writes())

    def test_github_errors_do_not_publish_or_merge(self):
        original = self.api.request

        def unavailable(method, path, body=None, **kwargs):
            if path.endswith("/issues/7"):
                raise ControlError("GitHub result is unknown")
            return original(method, path, body, **kwargs)

        self.api.request = unavailable
        with self.assertRaises(ControlError):
            self.broker.publish("7")
        self.assertFalse(self.pushes)
        self.assertFalse(self.writes())

    def test_lost_merge_acknowledgement_recovers_from_remote_state_without_second_merge(self):
        self.ready_pr()
        original = self.api.request

        def lose_ack(method, path, body=None, **kwargs):
            result = original(method, path, body, **kwargs)
            if method == "PUT":
                raise ControlError("GitHub result is unknown")
            return result

        self.api.request = lose_ack
        with self.assertRaises(ControlError):
            self.broker.merge("7")
        self.api.request = original
        result = self.broker.reconcile()
        self.assertEqual(result["results"][0]["status"], "merged")
        self.assertEqual(len([call for call in self.writes() if call[0] == "PUT"]), 1)

    def test_failed_local_check_cannot_be_ignored_by_green_ci(self):
        self.ready_pr()
        self.candidate["checks"] = [{"name": "docs validation", "result": "failed", "details": "broken example"}]
        with self.assertRaises(ControlError):
            self.broker.merge("7")
        self.assertFalse(self.writes())

    def test_pause_observed_during_reconcile_blocks_before_push(self):
        reads = 0

        def pause():
            nonlocal reads
            reads += 1
            result = copy.deepcopy(self.snapshot)
            if reads > 1:
                result["mode"] = "paused"
            return result

        self.broker.snapshot_reader = pause
        self.assertEqual(self.broker.reconcile()["results"][0]["status"], "blocked")
        self.assertFalse(self.pushes)
        self.assertFalse(self.writes())

    def test_reconcile_respects_pause_and_publication_lock(self):
        self.snapshot["mode"] = "paused"
        self.assertEqual(self.broker.reconcile(), {"mode": "paused", "results": []})
        self.assertFalse(self.api.calls)
        with publication_lock(self.config):
            with self.assertRaises(ControlError):
                with publication_lock(self.config):
                    self.fail("second broker acquired the same lock")

    def test_bounded_reconcile_publishes_once_and_reports_failures(self):
        self.assertEqual(self.broker.reconcile()["results"][0]["status"], "draft_pr")
        self.broker.reconcile()
        self.assertEqual(len(self.pushes), 1)
        self.assertEqual(len(self.writes()), 1)
        self.api.issue["state"] = "closed"
        self.assertEqual(self.broker.reconcile()["results"][0]["status"], "blocked")


class RealGitIsolationTest(unittest.TestCase):
    def test_host_clone_ignores_source_hooks_and_diff_drivers(self):
        self.clone_candidate()

    def test_work_clone_is_scoped_to_the_exact_work_and_independent_review(self):
        self.clone_candidate("1" * 32)

    def clone_candidate(self, work_id=None):
        workspace_key = "GH-7" + ("-" + work_id if work_id else "")
        branch = "codex/gh-7" + ("-" + work_id if work_id else "")
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary).resolve()
            source = state / "workspaces" / workspace_key
            source.mkdir(parents=True)

            def git(*args):
                return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                                                "-C", str(source), *args], text=True).strip()

            git("init", "-b", branch)
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            (source / "docs").mkdir()
            (source / "docs/guide.md").write_text("First line\n")
            git("add", ".")
            git("commit", "-m", "Fixture base")
            base = git("rev-parse", "HEAD")
            (source / "docs/guide.md").write_text("First line\nSecond line\n")
            git("add", ".")
            git("commit", "-m", "Fixture change")
            head = git("rev-parse", "HEAD")
            review = source.parent / (workspace_key + "-review-1234567890abcdef")
            subprocess.run(["git", "clone", "--local", "--no-hardlinks", "--quiet", str(source), str(review)], check=True)
            marker = state / "must-not-run"
            hook = state / "hostile-hook"
            hook.write_text("#!/bin/sh\ntouch '" + str(marker) + "'\n")
            hook.chmod(0o755)
            git("config", "core.fsmonitor", str(hook))
            git("config", "diff.external", str(hook))
            git("config", "core.hooksPath", str(state))
            config = {"state_dir": str(state), "workspace_root": str(source.parent)}
            candidate = {"workspace_path": str(source), "review_workspace_path": str(review),
                         "candidate_sha": head, "base_sha": base, "branch": branch}
            if work_id:
                candidate["work_id"] = work_id
            with CandidateRepository(config, "7", candidate) as repository:
                self.assertEqual(repository.changes(), [{"path": "docs/guide.md", "added": 1, "deleted": 0, "mode": "100644"}])
            self.assertFalse(marker.exists())


class WorkGitHub(FakeGitHub):
    """Distinct refs and PRs for two work sessions on the same issue."""
    def __init__(self):
        super().__init__()
        self.refs, self.prs = {}, {}
        self.selected_branch = None

    def request(self, method, path, body=None, *, missing=False):
        endpoint = urllib.parse.urlsplit(path).path.removeprefix("/repos/" + REPOSITORY)
        branch = None
        if endpoint.startswith("/git/ref/heads/"):
            branch = endpoint.removeprefix("/git/ref/heads/")
        elif endpoint == "/pulls" and method == "GET":
            branch = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)["head"][0].split(":", 1)[1]
        elif endpoint == "/pulls" and method == "POST":
            branch = body["head"]
        elif endpoint.startswith("/pulls/"):
            number = int(endpoint.split("/")[2])
            branch = next(key for key, pr in self.prs.items() if pr["number"] == number)
            path = path.replace("/pulls/" + str(number), "/pulls/11")
        if branch:
            self.selected_branch = branch
            self.ref, self.pr = self.refs.get(branch), self.prs.get(branch)
        result = super().request(method, path, body, missing=missing)
        if branch and self.pr:
            if method == "POST":
                self.pr["number"] = 11 + len(self.prs)
                self.pr["html_url"] = "https://github.com/" + REPOSITORY + "/pull/" + str(self.pr["number"])
                result = copy.deepcopy(self.pr)
            self.prs[branch] = self.pr
        return result


class WorkPublishTest(unittest.TestCase):
    setUp = PublishTest.setUp
    writes = PublishTest.writes

    def configure_work(self, work_id="1" * 32):
        self.api = WorkGitHub()
        self.broker.api = self.api
        self.snapshot["tracker_fingerprint"] = "current-opaque-tracker-scope"
        self.snapshot["issues"]["7"]["pr_work"] = {}
        self.acks = []
        self.broker.publication_writer = self.acknowledge
        outer = self

        class Repository:
            def __init__(self, config, issue_id, candidate):
                self.candidate = candidate

            def __enter__(self):
                return self

            def __exit__(self, *_):
                pass

            def changes(self):
                return outer.changes

            def push(self, token, expected):
                branch = self.candidate["branch"]
                if outer.api.refs.get(branch) != expected:
                    raise ControlError("Remote compare-and-swap failed")
                head = self.candidate["candidate_sha"]
                outer.pushes.append((branch, head, expected))
                outer.api.refs[branch] = head
                if branch in outer.api.prs:
                    outer.api.prs[branch]["head"]["sha"] = head

        self.broker.repository_factory = Repository
        return self.add_work(work_id)

    def add_work(self, work_id):
        candidate = copy.deepcopy(self.candidate)
        candidate.update(work_id=work_id, expected_head_sha=None, branch="codex/gh-7-" + work_id,
                         workspace_path=self.config["workspace_root"] + "/GH-7-" + work_id,
                         review_workspace_path=self.config["workspace_root"] + "/GH-7-" + work_id + "-review-1234567890abcdef")
        work = {"id": work_id, "issue_id": "7", "tracker_fingerprint": self.snapshot["tracker_fingerprint"],
                "base_sha": BASE, "branch": candidate["branch"], "workspace_key": "GH-7-" + work_id,
                "head_sha": HEAD, "published_head_sha": None, "phase": "owner_review", "handoff": candidate,
                "publication": None}
        self.snapshot["issues"]["7"]["pr_work"][work_id] = work
        self.snapshot["issues"]["7"]["handoff"] = candidate
        return work

    def acknowledge(self, receipt):
        self.acks.append(copy.deepcopy(receipt))
        work = self.snapshot["issues"][receipt["issue_id"]]["pr_work"][receipt["work_id"]]
        work.update(publication=copy.deepcopy(receipt), published_head_sha=receipt["candidate_sha"])
        return {"ok": True}

    def advance(self, work, head="d" * 40):
        prior = work["head_sha"]
        work["head_sha"] = head
        work["handoff"].update(candidate_sha=head, expected_head_sha=prior, run_id="next-native-run-123456")
        work["handoff"]["review"]["candidate_sha"] = head

    def test_work_receipt_callback_is_durable_private_and_idempotent(self):
        work = self.configure_work()
        first = self.broker.publish("7", work["id"])
        second = self.broker.publish("7", work["id"])
        self.assertEqual(first, second)
        self.assertEqual(self.acks[0], self.acks[1])
        self.assertEqual(len(self.pushes), 1)
        self.assertEqual(len(self.writes()), 1)
        self.assertEqual(first["work_id"], work["id"])
        self.assertIsNone(first["expected_head_sha"])
        self.assertEqual(work["published_head_sha"], HEAD)
        path = self.broker.receipt_path("7", work["id"])
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertFalse(self.broker.receipt_path("7").exists())
        with self.assertRaises(ControlError):
            self.broker.publish("7")

    def test_multiple_work_sessions_keep_distinct_branches_prs_receipts_and_selectors(self):
        first = self.configure_work()
        second = self.add_work("2" * 32)
        result = self.broker.reconcile("7", first["id"])
        self.assertEqual([item["work_id"] for item in result["results"]], [first["id"]])
        self.assertFalse(self.broker.receipt("7", second["id"]))
        result = self.broker.reconcile("7")
        self.assertEqual(len(result["results"]), 2)
        receipts = [self.broker.receipt("7", work["id"]) for work in (first, second)]
        self.assertNotEqual(receipts[0]["pr_number"], receipts[1]["pr_number"])
        self.assertEqual(len(self.pushes), 2)
        self.assertTrue(all(item["status"] == "draft_pr" for item in receipts))
        with self.assertRaises(ControlError):
            self.broker.reconcile(work_id=first["id"])

    def test_older_work_publication_uses_its_own_handoff_when_another_work_is_selected(self):
        first = self.configure_work()
        second = self.add_work("2" * 32)
        self.advance(second)
        issue = self.snapshot["issues"]["7"]
        issue["selected_work_id"] = second["id"]
        self.assertEqual(issue["handoff"]["candidate_sha"], "d" * 40)
        result = self.broker.publish("7", first["id"])
        self.assertEqual(result["candidate_sha"], HEAD)
        self.assertEqual(self.acks[-1]["work_id"], first["id"])
        self.assertEqual(first["published_head_sha"], HEAD)
        self.assertIsNone(second["published_head_sha"])
        self.assertFalse(self.broker.receipt("7", second["id"]))

    def test_legacy_candidate_remains_publishable_and_reconcileable_alongside_native_work(self):
        legacy = copy.deepcopy(self.candidate)
        work = self.configure_work()
        self.advance(work)
        issue = self.snapshot["issues"]["7"]
        issue["legacy_handoff"] = legacy
        issue["selected_work_id"] = work["id"]
        self.assertEqual(self.broker.candidate("7"), legacy)
        result = self.broker.reconcile("7")
        self.assertEqual([item.get("work_id") for item in result["results"]], [None, work["id"]])
        legacy_receipt, work_receipt = self.broker.receipt("7"), self.broker.receipt("7", work["id"])
        self.assertEqual(legacy_receipt["candidate_sha"], HEAD)
        self.assertEqual(work_receipt["candidate_sha"], "d" * 40)
        self.assertNotEqual(legacy_receipt["pr_number"], work_receipt["pr_number"])
        self.assertEqual(len(self.acks), 1)
        issue["hold"] = "cancelled"
        self.assertEqual(self.broker.reconcile("7")["results"], [])
        with self.assertRaises(ControlError):
            self.broker.publish("7")

    def test_cancelled_reviewed_work_cannot_publish_before_owner_ack_rejects_it(self):
        work = self.configure_work()
        self.snapshot["issues"]["7"]["hold"] = "cancelled"
        with self.assertRaises(ControlError):
            self.broker.publish("7", work["id"])
        self.assertFalse(self.pushes)
        self.assertFalse(self.writes())
        self.assertFalse(self.acks)

    def test_merged_continuation_recovers_exact_local_receipt_when_native_ack_lags(self):
        work = self.configure_work()
        self.broker.publish("7", work["id"])
        self.advance(work)
        def unavailable(_receipt):
            raise ControlError("Owner acknowledgment unknown")
        self.broker.publication_writer = unavailable
        with self.assertRaises(ControlError):
            self.broker.publish("7", work["id"])
        self.assertEqual(work["published_head_sha"], HEAD)
        current = self.broker.receipt("7", work["id"])
        self.assertEqual(current["candidate_sha"], "d" * 40)
        self.api.prs[work["branch"]].update(state="closed", merged=True, merge_commit_sha=MERGED)
        self.api.base["commit"]["sha"] = MERGED
        self.broker.publication_writer = self.acknowledge
        before = len(self.pushes), len(self.writes())
        result = self.broker.publish("7", work["id"])
        self.assertEqual(result["status"], "merged")
        self.assertEqual(result["candidate_sha"], "d" * 40)
        self.assertEqual(work["published_head_sha"], "d" * 40)
        self.assertEqual(self.acks[-1]["merge_sha"], MERGED)
        self.assertEqual((len(self.pushes), len(self.writes())), before)

    def test_stale_or_foreign_host_receipt_cannot_adopt_merged_continuation(self):
        work = self.configure_work()
        self.broker.publish("7", work["id"])
        self.advance(work)
        def unavailable(_receipt):
            raise ControlError("Owner acknowledgment unknown")
        self.broker.publication_writer = unavailable
        with self.assertRaises(ControlError):
            self.broker.publish("7", work["id"])
        receipt = self.broker.receipt("7", work["id"])
        self.api.prs[work["branch"]].update(state="closed", merged=True, merge_commit_sha=MERGED)
        self.broker.publication_writer = self.acknowledge
        path = self.broker.receipt_path("7", work["id"])
        before = len(self.pushes), len(self.writes()), len(self.acks)
        for field, value in (("work_id", "2" * 32), ("issue_id", "8"), ("run_id", "stale-run"),
                             ("candidate_sha", HEAD), ("base_sha", "e" * 40), ("branch", "other"),
                             ("expected_head_sha", None), ("pr_number", 99), ("pr_url", "https://foreign.invalid"),
                             ("repository", "foreign/repo"), ("status", "blocked")):
            with self.subTest(field=field):
                altered = dict(receipt, **{field: value})
                path.write_text(json.dumps(altered))
                with self.assertRaises(ControlError):
                    self.broker.publish("7", work["id"])
        self.assertEqual((len(self.pushes), len(self.writes()), len(self.acks)), before)

    def test_continuation_updates_same_pr_only_from_acknowledged_remote_head(self):
        work = self.configure_work()
        original = self.broker.publish("7", work["id"])
        self.advance(work)
        updated = self.broker.publish("7", work["id"])
        self.assertEqual(updated["pr_number"], original["pr_number"])
        self.assertEqual(updated["expected_head_sha"], HEAD)
        self.assertEqual(self.pushes[-1], (work["branch"], "d" * 40, HEAD))
        self.assertEqual(work["published_head_sha"], "d" * 40)
        self.assertEqual(sum(method == "POST" for method, _, _ in self.writes()), 1)

    def test_unrelated_remote_head_or_deleted_branch_never_gets_replaced(self):
        for index, changed_head in enumerate(("e" * 40, None), 1):
            with self.subTest(head=changed_head):
                work = self.configure_work(str(index) * 32)
                self.broker.publish("7", work["id"])
                self.advance(work)
                self.api.refs[work["branch"]] = changed_head
                before = len(self.pushes), len(self.writes())
                with self.assertRaises(ControlError):
                    self.broker.publish("7", work["id"])
                self.assertEqual((len(self.pushes), len(self.writes())), before)

    def test_work_scope_branch_identity_and_exact_review_fail_before_mutation(self):
        work = self.configure_work()
        for key, value in (("id", "2" * 32), ("issue_id", "8"), ("tracker_fingerprint", "old-scope"),
                           ("branch", "codex/gh-7-unowned"), ("workspace_key", "GH-7"),
                           ("head_sha", "d" * 40), ("phase", "running")):
            previous = work[key]
            work[key] = value
            with self.subTest(key=key), self.assertRaises(ControlError):
                self.broker.publish("7", "1" * 32)
            work[key] = previous
        work["handoff"]["review"]["candidate_sha"] = BASE
        with self.assertRaises(ControlError):
            self.broker.publish("7", work["id"])
        self.assertFalse(self.pushes)
        self.assertFalse(self.writes())

    def test_missing_owner_ack_reconciles_existing_pr_without_second_mutation(self):
        work = self.configure_work()
        def unavailable(_receipt):
            self.assertTrue(self.broker.receipt("7", work["id"]))
            raise ControlError("Owner acknowledgment unknown")
        self.broker.publication_writer = unavailable
        with self.assertRaises(ControlError):
            self.broker.publish("7", work["id"])
        first = self.broker.receipt("7", work["id"])
        self.assertIsNone(work["published_head_sha"])
        self.broker.publication_writer = self.acknowledge
        self.assertEqual(self.broker.publish("7", work["id"]), first)
        self.assertEqual(work["published_head_sha"], HEAD)
        self.assertEqual(len(self.pushes), 1)
        self.assertEqual(len(self.writes()), 1)

    def test_lost_push_and_pr_creation_acknowledgments_recover_without_duplicate_work(self):
        for index, failure in enumerate(("push", "create"), 3):
            work = self.configure_work(str(index) * 32)
            factory, request = self.broker.repository_factory, self.api.request
            if failure == "push":
                class LostPushAck(factory):
                    def push(self, token, expected):
                        super().push(token, expected)
                        raise ControlError("Push acknowledgment unknown")
                self.broker.repository_factory = LostPushAck
            else:
                def lost_create(method, path, body=None, **kwargs):
                    result = request(method, path, body, **kwargs)
                    if method == "POST":
                        raise ControlError("PR creation acknowledgment unknown")
                    return result
                self.api.request = lost_create
            with self.subTest(failure=failure), self.assertRaises(ControlError):
                self.broker.publish("7", work["id"])
            self.assertFalse(self.broker.receipt("7", work["id"]))
            self.broker.repository_factory, self.api.request = factory, request
            result = self.broker.publish("7", work["id"])
            self.assertEqual(result["status"], "draft_pr")
            self.assertEqual(sum(branch == work["branch"] for branch, _, _ in self.pushes), 1)
            self.assertEqual(sum(method == "POST" for method, _, _ in self.writes()), 1)

    def test_owner_acceptance_with_lost_ack_replays_without_git_or_pr_mutation(self):
        work = self.configure_work()
        def lost_owner_ack(receipt):
            self.acknowledge(receipt)
            raise ControlError("Owner acknowledgment unknown")
        self.broker.publication_writer = lost_owner_ack
        with self.assertRaises(ControlError):
            self.broker.publish("7", work["id"])
        self.assertEqual(work["published_head_sha"], HEAD)
        self.broker.publication_writer = self.acknowledge
        self.broker.publish("7", work["id"])
        self.assertEqual(self.acks[0], self.acks[1])
        self.assertEqual(len(self.pushes), 1)
        self.assertEqual(len(self.writes()), 1)

    def test_work_selection_does_not_grant_merge_and_merge_receipts_remain_scoped(self):
        work = self.configure_work()
        self.broker.publish("7", work["id"])
        with self.assertRaises(ControlError):
            self.broker.merge("7", work["id"])
        self.config["auto_merge"]["enabled"] = True
        self.api.prs[work["branch"]]["draft"] = False
        result = self.broker.merge("7", work["id"])
        self.assertEqual(result["status"], "merged")
        self.assertEqual(result["work_id"], work["id"])
        self.assertEqual(self.acks[-1]["merge_sha"], MERGED)
        self.assertEqual(self.broker.publish("7", work["id"]), result)
        self.assertEqual(sum(method == "PUT" for method, _, _ in self.writes()), 1)

    def test_remote_head_race_is_rejected_by_compare_and_swap(self):
        work = self.configure_work()
        self.broker.publish("7", work["id"])
        self.advance(work)
        factory = self.broker.repository_factory
        outer = self
        class RemoteRace(factory):
            def push(self, token, expected):
                outer.api.refs[work["branch"]] = "e" * 40
                super().push(token, expected)
        self.broker.repository_factory = RemoteRace
        before = len(self.pushes), len(self.writes())
        with self.assertRaises(ControlError):
            self.broker.publish("7", work["id"])
        self.assertEqual((len(self.pushes), len(self.writes())), before)
        self.assertEqual(self.api.refs[work["branch"]], "e" * 40)

    def test_closed_or_rebound_work_pr_does_not_create_a_replacement(self):
        work = self.configure_work()
        self.broker.publish("7", work["id"])
        for values in ({"state": "closed"}, {"body": self.broker.marker("7", "2" * 32)}):
            pr = self.api.prs[work["branch"]]
            before = copy.deepcopy(pr)
            pr.update(values)
            count = len(self.writes())
            with self.assertRaises(ControlError):
                self.broker.publish("7", work["id"])
            self.assertEqual(len(self.writes()), count)
            self.api.prs[work["branch"]] = before


if __name__ == "__main__":
    unittest.main()
