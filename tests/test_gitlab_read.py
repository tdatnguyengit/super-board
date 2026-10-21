#!/usr/bin/env python3
"""Offline contract for super-board-gitlab-read.py, driven by tests/fixtures/glab/fake_glab.py.

Bounded retries then halt (79), 429 retried, pagination, diff bounding with a
truncation marker, system notes skipped, strict shapes, and the Reviewer evidence
shape: an MR's metadata and diff pass github-read's own `metadata` / `diff` checks.

    python3 tests/test_gitlab_read.py
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'scripts/super-board-gitlab-read.py'
FAKE = ROOT / 'tests/fixtures/glab/fake_glab.py'
P = 'projects/grp%2Fapp'

spec = importlib.util.spec_from_file_location('github_read', ROOT / 'scripts/super-board-github-read.py')
github_read = importlib.util.module_from_spec(spec)
spec.loader.exec_module(github_read)


def issue(iid, state='opened', body='', labels=()):
    return {'id': 1000 + iid, 'iid': iid, 'title': f'issue {iid}', 'description': body, 'state': state,
            'labels': list(labels), 'assignees': [{'username': 'ann'}], 'web_url': f'https://gl/grp/app/-/issues/{iid}'}


def note(nid, body, system=False, at=None, **extra):
    return {'id': nid, 'body': body, 'system': system, 'author': {'username': f'u{nid}'},
            'created_at': at or f'2026-10-0{nid % 9 + 1}T00:00:00Z', **extra}


def diff(path, text, **flags):
    d = {'old_path': path, 'new_path': path, 'a_mode': '100644', 'b_mode': '100644',
         'new_file': False, 'renamed_file': False, 'deleted_file': False, 'diff': text}
    d.update(flags)
    return d


def mr(iid, state='merged', body='', branch=None, labels=()):
    return {'id': 5000 + iid, 'iid': iid, 'title': f'mr {iid}', 'description': body, 'state': state,
            'web_url': f'https://gl/grp/app/-/merge_requests/{iid}', 'source_branch': branch or f'issue-{iid}-x',
            'labels': list(labels), 'merged_at': '2026-10-01T00:00:00Z', 'author': {'username': 'dev'}}


def page(path, n=1):
    sep = '&' if '?' in path else '?'
    return f'GET {path}{sep}per_page=100&page={n}'


class GitLabReadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.halt = self.root / 'halt.json'
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        shim = bin_dir / 'glab'
        shim.write_text(f'#!/bin/sh\nexec python3 "{FAKE}" "$@"\n')
        shim.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}', FAKE_GLAB_DIR=str(self.root),
                        SB_GITLAB_HALT_FILE=str(self.halt), SB_GITLAB_RETRY_DELAY='0',
                        SB_GITLAB_RETRY_AFTER_MAX='0', SB_GITLAB_PROJECT='grp/app')
        for k in ('SB_GITLAB_READ_STRICT', 'SB_GITHUB_READ_STRICT', 'SB_FORGE_HOST'):
            self.env.pop(k, None)

    def tearDown(self):
        self.temp.cleanup()

    def routes(self, routes):
        (self.root / 'routes.json').write_text(json.dumps(routes))
        for f in ('calls.log', '.served.json'):
            (self.root / f).unlink(missing_ok=True)

    def calls(self):
        log = self.root / 'calls.log'
        return [json.loads(l) for l in log.read_text().splitlines()] if log.exists() else []

    def read(self, *args):
        return subprocess.run(['python3', str(HELPER), *args], env=self.env, text=True,
                              capture_output=True, cwd=self.root)

    # ── halting ───────────────────────────────────────────────────────────
    def test_three_failed_attempts_halt_and_block_later_reads(self):
        self.routes({f'GET {P}/issues/5': {'status': 1, 'body': 'glab: 503 Service Unavailable (HTTP 503)'}})
        r = self.read('--kind', 'issue', '--iid', '5')
        self.assertEqual(r.returncode, 79, r.stderr)
        self.assertEqual(r.stdout, '')
        self.assertEqual(len(self.calls()), 3)
        record = json.loads(self.halt.read_text())
        self.assertEqual(record['attempts'], 3)
        self.assertEqual(record['forge'], 'gitlab')
        self.assertIsNone(record['operation'], 'github-read --resume must not replay GitLab args through gh')
        self.routes({f'GET {P}/issues/5': {'body': issue(5)}})
        again = self.read('--kind', 'issue', '--iid', '5')
        self.assertEqual(again.returncode, 79)
        self.assertEqual(self.calls(), [], 'a halted run must not read again')
        self.assertEqual(self.read('--check').returncode, 79)

    def test_resume_replays_saved_read_then_clears(self):
        self.routes({f'GET {P}/issues/5': {'status': 1, 'body': 'HTTP 502'}})
        self.assertEqual(self.read('--kind', 'issue', '--iid', '5').returncode, 79)
        self.routes({f'GET {P}/issues/5': {'status': 1, 'body': 'HTTP 502'}})
        self.assertEqual(self.read('--resume').returncode, 79, 'still failing: stays halted')
        self.assertTrue(self.halt.exists())
        self.routes({f'GET {P}/issues/5': {'body': issue(5)}})
        self.assertEqual(self.read('--resume').returncode, 0)
        self.assertFalse(self.halt.exists())
        self.assertEqual(len(list(self.root.glob('github-halt-*.json'))), 1)
        self.assertEqual(self.read('--check').returncode, 0)

    def test_resume_refuses_a_github_halt(self):
        self.halt.write_text(json.dumps({'reason': 'x', 'operation': {'args': ['api', 'rate_limit'], 'kind': 'quota'}}))
        self.assertEqual(self.read('--resume').returncode, 79)
        self.assertTrue(self.halt.exists())

    def test_recovery_resets_per_read(self):
        self.routes({f'GET {P}/issues/5': [{'status': 1, 'body': 'HTTP 500'}, {'body': issue(5)},
                                           {'status': 1, 'body': 'HTTP 500'}, {'status': 1, 'body': 'HTTP 500'},
                                           {'body': issue(5)}]})
        self.assertEqual(self.read('--kind', 'issue', '--iid', '5').returncode, 0)
        self.assertEqual(self.read('--kind', 'issue', '--iid', '5').returncode, 0)
        self.assertEqual(len(self.calls()), 5)
        self.assertFalse(self.halt.exists())

    def test_permanent_error_halts_on_first_attempt(self):
        self.routes({f'GET {P}/issues/5': {'status': 1, 'body': 'glab: 401 Unauthorized (HTTP 401)'}})
        r = self.read('--kind', 'issue', '--iid', '5')
        self.assertEqual(r.returncode, 79)
        self.assertEqual(len(self.calls()), 1)

    def test_429_is_retried_not_permanent(self):
        self.routes({f'GET {P}/issues/5': [{'status': 1, 'body': 'glab: 429 Too Many Requests (HTTP 429)\nRetry-After: 30'},
                                           {'body': issue(5, body='hello', labels=['sb::Ready'])}]})
        r = self.read('--kind', 'issue', '--iid', '5')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout), {'number': 5, 'title': 'issue 5', 'body': 'hello', 'state': 'OPEN',
                                                'labels': ['sb::Ready'], 'assignees': ['ann'],
                                                'url': 'https://gl/grp/app/-/issues/5'})
        self.assertEqual(len(self.calls()), 2)
        self.assertFalse(self.halt.exists())

    def test_host_and_project_from_config(self):
        cfg = self.root / 'cfg.json'
        cfg.write_text(json.dumps({'forge': 'gitlab', 'forge_host': 'gl.example.com', 'gitlab': {'project': 'a/b/c'}}))
        env = dict(self.env)
        env.pop('SB_GITLAB_PROJECT')
        self.routes({'GET projects/a%2Fb%2Fc/issues/1': {'body': issue(1)}})
        r = subprocess.run(['python3', str(HELPER), '--config', str(cfg), '--kind', 'issue', '--iid', '1'],
                           env=env, text=True, capture_output=True, cwd=self.root)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.calls()[0]['host'], 'gl.example.com')

    def test_missing_project_is_config_error(self):
        self.env.pop('SB_GITLAB_PROJECT')
        self.routes({})
        self.assertEqual(self.read('--kind', 'issue', '--iid', '1').returncode, 66)

    # ── shapes ────────────────────────────────────────────────────────────
    def test_shape_failure_exits_64_for_agents_and_79_when_strict(self):
        self.routes({f'GET {P}/issues/5': {'body': {'iid': 5}}})
        r = self.read('--kind', 'issue', '--iid', '5')
        self.assertEqual(r.returncode, 64, r.stderr)
        self.assertIn('Valid form', r.stderr)
        self.assertEqual(len(self.calls()), 3)
        self.assertFalse(self.halt.exists())
        self.env['SB_GITLAB_READ_STRICT'] = '1'
        self.routes({f'GET {P}/issues/5': {'body': {'iid': 5}}})
        self.assertEqual(self.read('--kind', 'issue', '--iid', '5').returncode, 79)
        self.assertTrue(self.halt.exists())

    def test_preflight_strict_env_also_counts(self):
        self.env['SB_GITHUB_READ_STRICT'] = '1'
        self.routes({page(f'{P}/merge_requests?state=merged&order_by=updated_at&sort=desc'): {'body': [{'iid': 'x'}]}})
        self.assertEqual(self.read('--kind', 'prs-merged').returncode, 79)

    def test_comments_skip_system_notes_oldest_first_across_pages(self):
        path = f'{P}/issues/7/notes?sort=asc&order_by=created_at'
        first = [note(i, f'n{i}', system=(i % 2 == 0), at=f'2026-10-01T00:{i // 60:02d}:{i % 60:02d}Z')
                 for i in range(1, 101)]
        second = [note(101, 'blocked-by: 3', at='2026-10-02T00:00:00Z')]
        self.routes({page(path, 1): {'body': first}, page(path, 2): {'body': second}})
        r = self.read('--kind', 'comments', '--iid', '7')
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertEqual(len(out), 51)
        self.assertEqual(out[0], {'author': 'u1', 'body': 'n1', 'createdAt': '2026-10-01T00:00:01Z'})
        self.assertEqual(out[-1]['body'], 'blocked-by: 3')
        self.assertFalse(any(o['body'] == 'n2' for o in out))
        self.assertEqual([c['path'] for c in self.calls()], [page(path, 1)[4:], page(path, 2)[4:]])

    def test_repeated_page_halts(self):
        path = f'{P}/issues?state=opened&order_by=updated_at&sort=desc'
        full = [issue(i) for i in range(1, 101)]
        self.routes({page(path, 1): {'body': full}, page(path, 2): {'body': full}})
        self.assertEqual(self.read('--kind', 'issues').returncode, 79)

    def test_json_passthrough_merges_paginate_output_and_refuses_writes(self):
        self.routes({f'GET {P}/labels': {'body': '[{"id":1}]\n[{"id":2}]'}})
        r = self.read('--kind', 'json', '--', '--paginate', f'{P}/labels')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout), [{'id': 1}, {'id': 2}])
        self.assertEqual(self.read('--kind', 'json', '--', '-X', 'POST', f'{P}/labels').returncode, 64)
        self.assertEqual(self.read('--kind', 'json', '--', f'{P}/labels', '-f', 'name=x').returncode, 64)
        self.routes({f'GET {P}/x': {'body': 'not json'}})
        self.assertEqual(self.read('--kind', 'json', '--', f'{P}/x').returncode, 64)

    def test_links_soft_when_premium_missing(self):
        self.routes({f'GET {P}/issues/4/links': {'status': 1, 'body': 'glab: 403 Forbidden'}})
        r = self.read('--kind', 'links', '--iid', '4')
        self.assertEqual((r.returncode, json.loads(r.stdout)), (0, []))
        self.assertFalse(self.halt.exists())
        self.routes({f'GET {P}/issues/4/links': {'body': [{'iid': 2, 'state': 'closed', 'link_type': 'is_blocked_by',
                                                           'references': {'full': 'grp/app#2'}}]}})
        r = self.read('--kind', 'links', '--iid', '4')
        self.assertEqual(json.loads(r.stdout), [{'number': 2, 'state': 'CLOSED', 'linkType': 'is_blocked_by', 'project': 'grp/app'}])

    # ── Reviewer evidence: same shape as a PR ──────────────────────────────
    def mr_routes(self, diffs):
        return {f'GET {P}/merge_requests/9': {'body': mr(9, body='Closes #3', labels=['bug'])},
                page(f'{P}/merge_requests/9/diffs'): {'body': diffs}}

    def test_metadata_and_diff_pass_github_reviewer_checks(self):
        diffs = [diff('src/a.py', '@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n'),
                 diff('src/new.py', '@@ -0,0 +1,2 @@\n+a\n+b\n', new_file=True, a_mode='0'),
                 diff('old/gone.py', '@@ -1 +0,0 @@\n-x\n', deleted_file=True, b_mode='0'),
                 diff('src/b.py', '@@ -3 +3 @@\n-p\n+q\n\\ No newline at end of file\n', old_path='src/old_b.py', renamed_file=True)]
        self.routes(self.mr_routes(diffs))
        meta = self.read('--kind', 'metadata', '--iid', '9')
        self.assertEqual(meta.returncode, 0, meta.stderr)
        value = github_read.validate(meta.stdout, 'metadata')
        self.assertEqual(value['changedFiles'], 4)
        self.assertEqual((value['additions'], value['deletions']), (4, 3))
        self.assertEqual(value['labels'], [{'name': 'bug'}])
        self.assertEqual(value['body'], 'Closes #3')
        self.assertEqual([f['path'] for f in value['files']], ['src/a.py', 'src/new.py', 'old/gone.py', 'src/b.py'])
        d = self.read('--kind', 'mr-diff', '--iid', '9')
        self.assertEqual(d.returncode, 0, d.stderr)
        github_read.validate(d.stdout, 'diff', value)
        self.assertIn('rename from src/old_b.py', d.stdout)
        self.assertIn('--- /dev/null', d.stdout)
        files = self.read('--kind', 'mr-files', '--iid', '9')
        self.assertEqual(json.loads(files.stdout), ['src/a.py', 'src/new.py', 'old/gone.py', 'src/b.py'])

    def test_diff_bounded_with_truncation_marker(self):
        diffs = [diff(f'f{i}.txt', '@@ -1 +1 @@\n-a\n+' + 'x' * 200 + '\n') for i in range(5)]
        self.routes(self.mr_routes(diffs))
        r = self.read('--kind', 'mr-diff', '--iid', '9', '--max-files', '2')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.count('diff --git '), 2)
        self.assertIn('\\ super-board: diff truncated: 2 of 5 files shown', r.stdout)
        self.assertIn('f4.txt', r.stdout.splitlines()[-1])
        r = self.read('--kind', 'mr-diff', '--iid', '9', '--max-bytes', '600')
        self.assertEqual(r.stdout.count('diff --git '), 2)
        self.assertIn('diff truncated', r.stdout)
        whole = self.read('--kind', 'mr-diff', '--iid', '9')
        self.assertNotIn('truncated', whole.stdout)

    def test_too_large_file_is_marked_not_silent(self):
        self.routes(self.mr_routes([diff('big.bin', '', too_large=True)]))
        r = self.read('--kind', 'mr-diff', '--iid', '9')
        self.assertIn('GitLab omitted the diff text', r.stdout)

    def test_mr_notes_and_discussions(self):
        notes = [note(1, 'looks good'), note(2, 'added commit', system=True),
                 note(3, 'off by one', position={'new_path': 'src/a.py'}, resolvable=True, resolved=False)]
        self.routes({page(f'{P}/merge_requests/9/notes?sort=asc&order_by=created_at'): {'body': notes},
                     page(f'{P}/merge_requests/9/discussions'): {'body': [
                         {'id': 'd1', 'notes': [notes[0]]}, {'id': 'd2', 'notes': [notes[1]]},
                         {'id': 'd3', 'notes': [notes[2]]}]}})
        r = self.read('--kind', 'mr-notes', '--iid', '9')
        out = json.loads(r.stdout)
        self.assertEqual([n['body'] for n in out], ['looks good', 'off by one'])
        self.assertEqual((out[1]['path'], out[1]['resolved']), ('src/a.py', False))
        disc = json.loads(self.read('--kind', 'mr-discussions', '--iid', '9').stdout)
        self.assertEqual([d['id'] for d in disc], ['d1', 'd3'])
        self.assertEqual((disc[1]['path'], disc[1]['resolved']), ('src/a.py', False))

    # ── preflight shapes ──────────────────────────────────────────────────
    def test_preflight_shapes_pass_github_read_checks(self):
        merged = f'{P}/merge_requests?state=merged&order_by=updated_at&sort=desc'
        opened = f'{P}/merge_requests?state=opened&order_by=updated_at&sort=desc'
        closed = f'{P}/issues?state=closed&order_by=updated_at&sort=desc'
        self.routes({page(merged): {'body': [mr(31, body='Closes #14')]},
                     page(opened): {'body': [mr(40, state='opened')]},
                     page(f'{P}/merge_requests/40/diffs'): {'body': [diff('src/a.py', '@@ -1 +1 @@\n-a\n+b\n')]},
                     page(closed): {'body': [issue(2, state='closed')]}})
        for kind in ('prs-merged', 'prs-open', 'issues-closed'):
            with self.subTest(kind=kind):
                r = self.read('--kind', kind)
                self.assertEqual(r.returncode, 0, r.stderr)
                github_read.validate(r.stdout, kind)
        self.assertEqual(json.loads(self.read('--kind', 'prs-open').stdout)[0]['files'], [{'path': 'src/a.py'}])


if __name__ == '__main__':
    unittest.main()
