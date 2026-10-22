#!/usr/bin/env python3
"""super-collect's GitLab source (collect_gitlab.py) end to end through the real
super-board-gitlab-read.py and the shared fake glab. No network.

    python3 tests/test_collect_gitlab.py
"""
from __future__ import annotations

import contextlib
import datetime as dt
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'skills/super-collect/scripts'))
import collect_gitlab as cg  # noqa: E402

FAKE = ROOT / 'tests/fixtures/glab/fake_glab.py'
P = 'projects/grp%2Fapp'
UTC = dt.timezone.utc


def note(nid, body, user='rev', system=False, **extra):
    return {'id': nid, 'body': body, 'system': system, 'author': {'username': user},
            'created_at': f'2026-10-0{nid % 9 + 1}T00:00:00Z', **extra}


def mr(iid, merged_at):
    return {'id': 900 + iid, 'iid': iid, 'title': f'mr {iid}', 'description': '', 'state': 'merged',
            'web_url': f'https://gl/mr/{iid}', 'source_branch': f'b{iid}', 'merged_at': merged_at,
            'author': {'username': 'dev'}, 'labels': []}


class CollectGitLab(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / 'bin').mkdir()
        shim = self.root / 'bin/glab'
        shim.write_text(f'#!/bin/sh\nexec python3 "{FAKE}" "$@"\n')
        shim.chmod(0o755)
        self.cfg = self.root / 'cfg.json'
        self.cfg.write_text(json.dumps({'forge': 'gitlab', 'forge_host': 'gl.example.com',
                                        'gitlab': {'project': 'grp/app'}}))
        self.patch = {'PATH': f'{self.root / "bin"}{os.pathsep}{os.environ["PATH"]}', 'FAKE_GLAB_DIR': str(self.root),
                      'SB_GLAB_CMD': json.dumps([sys.executable, str(FAKE)]),
                      'SB_GITLAB_RETRY_DELAY': '0', 'SB_GITLAB_READ': str(ROOT / 'scripts/super-board-gitlab-read.py')}
        self.saved = {k: os.environ.get(k) for k in [*self.patch, 'SB_GITLAB_PROJECT']}
        os.environ.update(self.patch)
        os.environ.pop('SB_GITLAB_PROJECT', None)

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.temp.cleanup()

    def routes(self, routes):
        (self.root / 'routes.json').write_text(json.dumps(routes))

    def run_main(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = cg.main(['--config', str(self.cfg), *argv])
        return rc, json.loads(out.getvalue())

    def test_issues_have_gh_issue_list_shape(self):
        issues = [{'id': 1, 'iid': 3, 'title': 'Crash on save', 'description': None, 'state': 'opened',
                   'labels': ['bug'], 'assignees': [], 'web_url': 'https://gl/i/3'}]
        self.routes({f'GET {P}/issues?state=opened&order_by=updated_at&sort=desc&per_page=100&page=1': {'body': issues}})
        rc, out = self.run_main('issues')
        self.assertEqual(rc, 0, out)
        self.assertEqual((out['source'], out['forge'], out['truncated']), ('github', 'gitlab', False))
        self.assertEqual(out['issues'], [{'number': 3, 'title': 'Crash on save', 'body': '',
                                          'labels': [{'name': 'bug'}], 'url': 'https://gl/i/3'}])
        calls = [json.loads(l) for l in (self.root / 'calls.log').read_text().splitlines()]
        self.assertEqual(calls[0]['host'], 'gl.example.com')

    def test_issues_cap_is_reported_truncated(self):
        issues = [{'id': i, 'iid': i, 'title': f't{i}', 'description': '', 'state': 'opened', 'labels': [],
                   'assignees': [], 'web_url': 'u'} for i in range(1, 6)]
        self.routes({f'GET {P}/issues?state=opened&order_by=updated_at&sort=desc&per_page=100&page=1': {'body': issues}})
        rc, out = self.run_main('issues', '--max', '3')
        self.assertEqual((rc, len(out['issues']), out['truncated']), (0, 3, True))

    def test_mrs_have_collect_prs_shape(self):
        since = '2026-09-20T00:00:00+00:00'
        q = f'{P}/merge_requests?state=merged&order_by=updated_at&sort=desc&updated_after=2026-09-20T00%3A00%3A00%2B00%3A00'
        self.routes({
            f'GET {q}&per_page=100&page=1': {'body': [mr(7, '2026-09-25T10:00:00.000Z'), mr(6, '2026-09-01T00:00:00Z')]},
            f'GET {P}/merge_requests/7/discussions?per_page=100&page=1': {'body': [
                {'id': 'a', 'notes': [note(1, '<!-- super-review:report -->\nfindings')]},
                {'id': 'b', 'notes': [note(2, 'merged', system=True)]},
                {'id': 'c', 'notes': [note(3, 'null check missing', position={'new_path': 'src/x.py'},
                                           resolvable=True, resolved=True),
                                      note(4, 'fixed', user='renovate-bot')]}]},
        })
        rc, out = self.run_main('mrs', '--since', since)
        self.assertEqual(rc, 0, out)
        self.assertEqual((out['source'], out['repo'], out['superReviewReports']), ('prs', 'grp/app', 1))
        self.assertEqual(len(out['prs']), 1, 'MR merged before the window is dropped')
        pr = out['prs'][0]
        self.assertEqual(set(pr), {'number', 'title', 'url', 'mergedAt', 'author', 'comments', 'reviews', 'threads'})
        self.assertEqual(pr['author'], {'login': 'dev', 'bot': False})
        self.assertEqual(len(pr['comments']), 1)
        self.assertTrue(pr['comments'][0]['superReview'])
        self.assertEqual(pr['threads'][0]['path'], 'src/x.py')
        self.assertTrue(pr['threads'][0]['resolved'])
        self.assertEqual(pr['threads'][0]['comments'][1]['author'], {'login': 'renovate-bot', 'bot': True})

    def test_unreachable_gitlab_is_unavailable_and_never_halts_the_board(self):
        self.routes({})  # every read 404s
        board_halt = self.root / 'board-halt.json'
        os.environ['SB_GITHUB_HALT_FILE'] = str(board_halt)
        try:
            rc, out = self.run_main('issues')
        finally:
            os.environ.pop('SB_GITHUB_HALT_FILE')
        self.assertEqual((rc, out['status']), (2, 'unavailable'))
        self.assertFalse(board_halt.exists())

    def test_missing_project_is_unavailable(self):
        self.cfg.write_text(json.dumps({'forge': 'gitlab'}))
        rc, out = self.run_main('mrs')
        self.assertEqual((rc, out['status']), (2, 'unavailable'))


if __name__ == '__main__':
    unittest.main()
