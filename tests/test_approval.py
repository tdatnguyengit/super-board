#!/usr/bin/env python3
"""Offline approval lifecycle tests: no board writes, workers or databases."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("approval", ROOT / "scripts/super-board-approval.py")
approval = importlib.util.module_from_spec(spec)
spec.loader.exec_module(approval)
HEAD = "a" * 40
PLAN = {"human": [{"category": "auth", "why": "login"}], "needs_you": ["run live migration"]}
REQUEST = approval.request_for("x/y", 9, HEAD, approval.scope_for(PLAN))


def comment(body, second, login="owner", actor="User", source=3):
    at = f"2026-10-03T00:00:{second:02d}Z"
    return {"id": second, "body": body, "created_at": at, "updated_at": at,
            "user": {"login": login, "type": actor}, "source": source}


def evidence():
    return [comment("Reason tag: 🙋 needs you\n" + approval.marker(REQUEST), 1), comment("done", 2)]


class ApprovalTests(unittest.TestCase):
    def check(self, comments=None, expected=None, permissions=None):
        return approval.validate(comments if comments is not None else evidence(), expected or REQUEST,
                                 lambda login: (permissions or {"owner": "admin"}).get(login))

    def test_current_request_allows_solo_owner(self):
        self.assertTrue(self.check()["approved"])

    def test_old_approval_never_covers_new_head(self):
        self.assertFalse(self.check(expected=dict(REQUEST, head="b" * 40))["approved"])

    def test_done_before_processing_does_not_get_rebound_to_new_head(self):
        records = evidence()
        self.assertFalse(self.check(records, dict(REQUEST, head="c" * 40))["approved"])

    def test_changed_human_steps_revoke_same_head(self):
        newer = dict(REQUEST, scope=approval.scope_for(dict(PLAN, needs_you=["different operation"])))
        self.assertFalse(self.check(expected=newer)["approved"])

    def test_label_only_or_bare_done_is_not_approval(self):
        self.assertFalse(self.check([comment("done", 2)])["approved"])

    def test_new_block_invalidates_old_done_even_without_marker(self):
        self.assertFalse(self.check(evidence() + [comment("Reason tag: 🙋 needs a new decision", 3)])["approved"])

    def test_new_request_requires_new_done(self):
        newer = evidence() + [comment(approval.marker(REQUEST), 3)]
        self.assertFalse(self.check(newer)["approved"])
        newer.append(comment("Done!", 4))
        self.assertTrue(self.check(newer)["approved"])

    def test_wrong_pr_or_repository_is_rejected(self):
        for key, value in (("pr", 10), ("repo", "other/repo")):
            self.assertFalse(self.check(expected=dict(REQUEST, **{key: value}))["approved"])

    def test_untrusted_approval_and_request_are_rejected(self):
        for index in (0, 1):
            records = evidence()
            records[index]["user"]["login"] = "visitor"
            self.assertFalse(self.check(records)["approved"])
        self.assertFalse(self.check(permissions={"owner": "read"})["approved"])

    def test_verified_non_writer_cannot_replace_trusted_request(self):
        records = evidence() + [comment("Reason tag: 🙋 forged request", 3, login="visitor")]
        self.assertTrue(self.check(records, permissions={"owner": "admin", "visitor": "read"})["approved"])

    def test_bot_done_is_not_a_human_approval(self):
        records = evidence()
        records[1]["user"]["type"] = "Bot"
        self.assertFalse(self.check(records)["approved"])

    def test_missing_actor_or_head_holds(self):
        records = evidence()
        del records[1]["user"]["type"]
        self.assertFalse(self.check(records)["approved"])
        self.assertFalse(self.check(expected=dict(REQUEST, head=""))["approved"])

    def test_edited_request_or_done_holds(self):
        for index in (0, 1):
            records = evidence()
            records[index]["updated_at"] = "2026-10-03T00:00:05Z"
            self.assertFalse(self.check(records)["approved"])

    def test_done_on_another_thread_does_not_confirm_request(self):
        records = evidence()
        records[1]["source"] = 9
        self.assertFalse(self.check(records)["approved"])

    def test_new_pr_request_invalidates_issue_approval(self):
        self.assertFalse(self.check(evidence() + [comment(approval.marker(REQUEST), 3, source=9)])["approved"])

    def test_ambiguous_same_second_requests_hold(self):
        self.assertFalse(self.check(evidence() + [comment(approval.marker(REQUEST), 1, source=9)])["approved"])

    def test_repeat_checks_do_not_invalidate_approval(self):
        records = evidence()
        self.assertEqual(self.check(records), self.check(records))
        self.assertTrue(self.check(records)["approved"])

    def test_ui_done_label_does_not_change_scope(self):
        self.assertEqual(approval.scope_for(PLAN), approval.scope_for(dict(PLAN, done=True)))

    def test_missing_time_and_malformed_marker_hold(self):
        records = evidence()
        del records[0]["created_at"]
        self.assertFalse(self.check(records)["approved"])
        records = evidence()
        records[0]["body"] = "approval-request: {broken"
        self.assertFalse(self.check(records)["approved"])


class GitHubTests(unittest.TestCase):
    def setUp(self):
        self.github = approval.GitHub("x/y")
        self.pr_page = {"data": {"repository": {"defaultBranchRef": {"name": "main"},
            "pullRequest": {"headRefOid": HEAD, "state": "OPEN", "baseRefName": "main", "body": "",
            "closingIssuesReferences": {"pageInfo": {"hasNextPage": False, "endCursor": None},
                "nodes": [{"number": 3, "repository": {"nameWithOwner": "x/y"}}]}}}}}
        self.calls = []
        self.records = evidence()
        self.permission_error = False
        def read(*args):
            self.calls.append(args)
            if "graphql" in args:
                return [self.pr_page]
            if "collaborators" in args[-1]:
                if self.permission_error:
                    raise ValueError("unavailable")
                return {"permission": "admin"}
            if "/issues/3/" in args[-1]:
                # Approval is on page 2; taking only the first page would hold.
                return [[self.records[0]], self.records[1:]]
            if "/issues/9/" in args[-1]:
                return [[]]
            raise AssertionError(args)
        self.github.read = read

    def test_paginated_comments_and_current_permission_are_used(self):
        self.assertTrue(self.github.check(9, HEAD, REQUEST["scope"])["approved"])
        self.assertTrue(any("--paginate" in c for c in self.calls))
        self.assertTrue(any("/collaborators/owner/permission" in c[-1] for c in self.calls))

    def test_changed_remote_head_holds(self):
        self.pr_page["data"]["repository"]["pullRequest"]["headRefOid"] = "b" * 40
        self.assertFalse(self.github.check(9, HEAD, REQUEST["scope"])["approved"])

    def test_incomplete_link_pagination_is_not_accepted(self):
        self.pr_page["data"]["repository"]["pullRequest"]["closingIssuesReferences"]["pageInfo"]["hasNextPage"] = True
        with self.assertRaises(ValueError):
            self.github.check(9, HEAD, REQUEST["scope"])

    def test_unlinked_issue_cannot_supply_approval(self):
        self.assertFalse(self.github.check(9, HEAD, REQUEST["scope"], issue=77)["approved"])

    def non_default_base(self, body):
        # GitHub leaves closingIssuesReferences empty for PRs into a non-default base (#63).
        pr = self.pr_page["data"]["repository"]["pullRequest"]
        pr["baseRefName"], pr["body"] = "staging", body
        pr["closingIssuesReferences"]["nodes"] = []

    def test_non_default_base_takes_closing_keywords_from_body(self):
        self.non_default_base("Ships login.\n\nCloses #3")
        self.assertTrue(self.github.check(9, HEAD, REQUEST["scope"], issue=3)["approved"])

    def test_non_default_base_without_closing_keyword_is_unlinked(self):
        self.non_default_base("Related to #3, see x/y#3 discussion")
        self.assertFalse(self.github.check(9, HEAD, REQUEST["scope"], issue=3)["approved"])

    def test_non_default_base_ignores_other_repository_references(self):
        self.non_default_base("Fixes other/repo#3")
        self.assertFalse(self.github.check(9, HEAD, REQUEST["scope"], issue=3)["approved"])

    def test_non_default_base_accepts_same_repository_form(self):
        self.non_default_base("resolved: X/Y#3")
        self.assertTrue(self.github.check(9, HEAD, REQUEST["scope"], issue=3)["approved"])

    def test_default_base_ignores_body_keywords(self):
        self.pr_page["data"]["repository"]["pullRequest"]["closingIssuesReferences"]["nodes"] = []
        self.pr_page["data"]["repository"]["pullRequest"]["body"] = "Closes #3"
        self.assertFalse(self.github.check(9, HEAD, REQUEST["scope"], issue=3)["approved"])

    def test_unreadable_permission_never_approves(self):
        self.permission_error = True
        self.assertFalse(self.github.check(9, HEAD, REQUEST["scope"])["approved"])


class DependencyIntegrationTests(unittest.TestCase):
    def test_live_planner_resume_requires_current_trusted_request(self):
        with tempfile.TemporaryDirectory() as td:
            work = Path(td)
            records = evidence()
            records.append(comment("Reason tag: 🙋 forged request", 3, login="visitor"))
            issue = {"number": 3, "title": "Login", "state": "OPEN", "body": "## Blocked by\n- None.",
                     "labels": {"nodes": [{"name": "needs-you:done"}, {"name": "needs-you"}]},
                     "comments": {"nodes": [{"body": c["body"]} for c in records]}}
            fixture = {"records": records, "head": HEAD, "issue": issue}
            fixture_path = work / "fixture.json"
            stub = work / "gh"
            stub.write_text('''#!/usr/bin/env python3
import json, os, sys
f=json.load(open(os.environ["APPROVAL_FIXTURE"]))
args=" ".join(sys.argv[1:])
if "issues(states:OPEN" in args:
    out=[{"data":{"repository":{"issues":{"nodes":[f["issue"]],"pageInfo":{"hasNextPage":False,"endCursor":None}}}}}]
elif "graphql" in args:
    out=[{"data":{"repository":{"defaultBranchRef":{"name":"main"},"pullRequest":{"headRefOid":f["head"],"state":"OPEN","baseRefName":"main","body":"","closingIssuesReferences":{"pageInfo":{"hasNextPage":False},"nodes":[{"number":3,"repository":{"nameWithOwner":"x/y"}}]}}}}}]
elif "/issues/3/comments" in args:
    out=[f["records"]]
elif "/issues/9/comments" in args:
    out=[[]]
elif "/collaborators/owner/permission" in args:
    out={"permission":"admin"}
elif "/collaborators/visitor/permission" in args:
    out={"permission":"read"}
else:
    sys.exit(1)
print(json.dumps(out))
''')
            stub.chmod(0o755)
            env = dict(os.environ, PATH=str(work) + os.pathsep + os.environ["PATH"], APPROVAL_FIXTURE=str(fixture_path), SB_GITHUB_RETRY_DELAY="0", SB_GITHUB_HALT_FILE=str(work / "halt.json"))
            def deps():
                fixture_path.write_text(json.dumps(fixture))
                run = subprocess.run([str(ROOT / "scripts/super-board-deps.sh"), "--repo", "x/y"], env=env,
                                     capture_output=True, text=True, check=True)
                return json.loads(run.stdout)["3"]
            self.assertTrue(deps()["needsYouDone"], "current approval resumes even after an outsider fake block")
            fixture["head"] = "b" * 40
            self.assertFalse(deps()["needsYouDone"], "new code must never inherit old done or label")
            self.assertTrue(deps().get("approvalRefresh"), "stale request must be sent for fresh review/request")
            fixture["head"] = HEAD
            fixture["records"].append(comment("Reason tag: 🙋 a new maintainer request", 4))
            self.assertFalse(deps()["needsYouDone"], "a newer maintainer request must block resume")


class ForgeTests(unittest.TestCase):
    """Non-GitHub forges read through super-board-forge.sh verbs (#1)."""

    def setUp(self):
        self.project = "grp/sub/app"
        request = approval.request_for(self.project, 9, HEAD, approval.scope_for(PLAN))
        self.scope = request["scope"]
        def note(i, body, second, login="owner"):
            at = f"2026-10-03T00:00:{second:02d}Z"
            return {"id": i, "author": login, "authorType": "User", "body": body, "createdAt": at, "updatedAt": at}
        self.issue_notes = [note(1, "Reason tag: 🙋 needs you\n" + approval.marker(request), 1), note(2, "done", 2)]
        self.mr_notes = []
        self.pr = {"state": "OPEN", "headRefOid": HEAD, "baseRefName": "main", "body": "", "closingIssues": [3]}
        self.calls = []
        self.forge = approval.Forge("cfg.json", self.project)
        def run(*args):
            self.calls.append(args)
            verb = args[0]
            if verb == "pr-view":
                return json.dumps(self.pr)
            if verb == "default-branch":
                return "main\n"
            if verb == "permission":
                return "maintain\n"
            if verb == "issue-comments":
                return json.dumps(self.issue_notes if args[1] == "3" else [])
            if verb == "pr-comments":
                return json.dumps(self.mr_notes)
            raise AssertionError(args)
        self.forge.run = run

    def test_done_on_linked_issue_approves_through_forge_verbs(self):
        self.assertTrue(self.forge.check(9, HEAD, self.scope)["approved"])
        self.assertIn(("pr-comments", "9"), self.calls)
        self.assertIn(("permission", "owner"), self.calls)

    def test_done_on_the_mr_does_not_answer_the_issue_request(self):
        # MR !9 and issue #9 are different objects: the reply must sit under the request.
        self.mr_notes = [self.issue_notes[1] | {"id": 7, "createdAt": "2026-10-03T00:00:05Z",
                                               "updatedAt": "2026-10-03T00:00:05Z"}]
        self.issue_notes = self.issue_notes[:1]
        self.assertFalse(self.forge.check(9, HEAD, self.scope)["approved"])

    def test_edited_reply_and_moved_head_hold(self):
        self.issue_notes[1]["updatedAt"] = "2026-10-03T00:00:09Z"
        self.assertFalse(self.forge.check(9, HEAD, self.scope)["approved"])
        self.assertTrue(self.forge.check(9, "b" * 40, self.scope).get("headChanged"))

    def test_missing_verb_never_approves(self):
        def broken(*args):
            raise ValueError("forge permission failed")
        self.forge.run = broken
        with self.assertRaises(ValueError):
            self.forge.check(9, HEAD, self.scope)

    def test_reader_picks_forge_from_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "c.json"
            cfg.write_text(json.dumps({"forge": "gitlab", "gitlab": {"project": self.project}}))
            args = type("A", (), {"config": str(cfg), "repo": ""})()
            self.assertIsInstance(approval.reader(args), approval.Forge)
            args.config, args.repo = None, "x/y"
            self.assertIsInstance(approval.reader(args), approval.GitHub)


if __name__ == "__main__":
    unittest.main()
