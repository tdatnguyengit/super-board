#!/usr/bin/env python3
"""Bounded, read-only GitLab evidence. Exit 79 stops this repository's board run.

GitLab counterpart of super-board-github-read.py, with the same halting rules:
every GitLab request is a logical read with three total attempts; success resets
only its own sequence. Permanent errors (401/403/404, bad token, missing scope)
stop on the first attempt. 429 and 5xx are retried; a `Retry-After` seen in glab's
output is honoured (capped by SB_GITLAB_RETRY_AFTER_MAX, default 60s). The halt
file is the board's shared one (`.claude/super-board/github-halt.json` in the main
checkout, or SB_GITLAB_HALT_FILE / SB_GITHUB_HALT_FILE), so one stop halts every
lane whatever the forge. Only --resume clears it, after the saved read succeeds.

GitLab is reached only through `glab api --hostname <host> <path>`. Host and
project come from --host/--project, else SB_FORGE_HOST/SB_GITLAB_PROJECT, else
the --config keys `forge_host` and `gitlab.project` (host default gitlab.com).
Lists are read page by page (`per_page=100&page=N`) until a short page, so a
list is complete or the read fails; it is never silently partial.

Kinds (`<N>` is the issue or MR iid, given with --iid):
  issue          {number,title,body,state,labels,assignees,url}  (forge issue-view)
  comments       issue notes, non-system, oldest first: [{author,body,createdAt}]
  issues         [issue] by --state opened|closed|all, --limit (default 200)
  deps-issues    open issues with their last 8 non-system notes, in the payload shape
                 super-board-deps.sh --from reads: labels.nodes[].name, comments.nodes[].body
  links          issue links: [{number,state,linkType,project}]; `is_blocked_by` is
                 Premium, so 403/404 here prints [] instead of halting
  mr-diff        unified diff text built from /merge_requests/:iid/diffs, bounded by
                 --max-files/--max-bytes; a cut diff ends with a `\\ super-board: diff
                 truncated …` line (never silently short)
  mr-files       [path]
  metadata       {files:[{path,additions,deletions}],labels:[{name}],body,additions,
                 deletions,changedFiles} — the same shape github-read --kind metadata checks
  mr-notes       MR notes, non-system, oldest first: [{author,body,createdAt,path?,resolved?}]
  mr-discussions [{id,path,resolved,notes:[{author,body,createdAt}]}] non-system only
  mrs            [{number,title,body,url,state,headRefName,mergedAt,author}] by --state
                 opened|merged|closed|all, --since ISO (updated after), --limit
  prs-merged / prs-open / issues-closed
                 the shapes super-board-preflight.sh reads from github-read, for MRs
  json           raw passthrough: `-- <glab api args>` (GET only); output must be JSON.
                 With --paginate, concatenated pages are merged into one list.

Shape failures: for agent-facing kinds (FORMS) a payload that fails its shape on
every attempt exits 64 with the valid form; scripts set SB_GITLAB_READ_STRICT=1
(SB_GITHUB_READ_STRICT=1 also counts) to halt on it instead.
Exit: 0 ok · 64 usage/malformed read · 66 config missing · 79 reads halted.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.parse

HALTED = 79
PER_PAGE = 100
MAX_PAGES = 50
RECOVERING = False



def glab_command():
    """The glab to run. SB_GLAB_CMD (a JSON list, or a shell-quoted string) overrides it for
    tests; otherwise PATH is searched with PATHEXT, so Windows finds glab.exe or a .cmd shim
    where a bare 'glab' would fail to start."""
    override = os.environ.get('SB_GLAB_CMD')
    if override:
        try:
            cmd = json.loads(override)
        except ValueError:
            cmd = shlex.split(override)
        if isinstance(cmd, list) and cmd:
            return [str(c) for c in cmd]
    return [shutil.which('glab') or 'glab']

class ReadHalted(Exception):
    pass


class ConfigMissing(Exception):
    pass


class ShapeError(ValueError):
    pass


FORMS = {
    'issue': '--kind issue --iid <N>',
    'comments': '--kind comments --iid <N>',
    'json': '--kind json -- <glab api path> (GET only, JSON output)',
    'mr-diff': '--kind mr-diff --iid <N> [--max-files 300] [--max-bytes 1000000]',
    'mr-files': '--kind mr-files --iid <N>',
    'mr-notes': '--kind mr-notes --iid <N>',
    'mr-discussions': '--kind mr-discussions --iid <N>',
    'metadata': '--kind metadata --iid <N>',
    'links': '--kind links --iid <N>',
}
KINDS = ('issue', 'comments', 'issues', 'deps-issues', 'links', 'mr-diff', 'mr-files', 'metadata',
         'mr-notes', 'mr-discussions', 'mrs', 'prs-merged', 'prs-open', 'issues-closed', 'json')
NEEDS_IID = {'issue', 'comments', 'links', 'mr-diff', 'mr-files', 'metadata', 'mr-notes', 'mr-discussions'}


def env(*names, default=None):
    for name in names:
        if os.environ.get(name):
            return os.environ[name]
    return default


# ── halt file (shared with super-board-github-read.py) ─────────────────────
def halt_path():
    override = env('SB_GITLAB_HALT_FILE', 'SB_GITHUB_HALT_FILE')
    if override:
        return Path(override)
    cwd = Path(os.environ.get('SB_REPO_PATH') or Path.cwd())
    try:
        result = subprocess.run(['git', 'rev-parse', '--git-common-dir'], capture_output=True,
                                text=True, timeout=5, cwd=cwd)
        ok = result.returncode == 0
    except (OSError, subprocess.SubprocessError):
        ok = False
    root = (cwd / result.stdout.strip()).resolve().parent if ok else cwd
    return root / '.claude/super-board/github-halt.json'


def check_halt():
    if not RECOVERING and halt_path().exists():
        raise ReadHalted('forge reads are halted; inspect the saved reason and explicitly restart the run')


def halt(reason, attempts, operation=None):
    path = halt_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    # `operation` stays null so github-read --resume asks for manual reconciliation
    # instead of replaying GitLab arguments through gh; this script replays
    # `gitlab_operation`.
    record = {'reason': reason, 'attempts': attempts, 'at': int(time.time()),
              'operation': None, 'forge': 'gitlab', 'gitlab_operation': operation}
    try:
        with path.open('x') as stream:
            json.dump(record, stream)
    except FileExistsError:
        pass
    raise ReadHalted(reason)


# ── glab ───────────────────────────────────────────────────────────────────
def permanent_error(text):
    if re.search(r'\b429\b|too many requests|rate limit', text, re.I):
        return False
    return re.search(r'\b40[134]\b|Unauthorized|Forbidden|Not Found|invalid_token|insufficient_scope|'
                     r'not logged in|authentication (?:required|failed)|has not been authenticated',
                     text, re.I) is not None


def retry_after(text):
    m = re.search(r'retry-after:?\s*(\d+)', text, re.I)
    if not m:
        return None
    return min(float(m[1]), float(env('SB_GITLAB_RETRY_AFTER_MAX', default='60')))


class Reader:
    def __init__(self, host, project, operation, soft_missing=False):
        self.host, self.project, self.operation = host, project, operation
        self.soft_missing = soft_missing

    def pid(self):
        if not self.project:
            raise ConfigMissing('gitlab.project is not set (pass --project or --config)')
        return urllib.parse.quote(self.project, safe='')

    def glab(self, args):
        cmd = [*glab_command(), 'api', '--hostname', self.host, *args]
        result = subprocess.run(cmd, capture_output=True, timeout=30)
        return (result.returncode, result.stdout.decode('utf-8', 'replace'),
                result.stderr.decode('utf-8', 'replace'))

    def request(self, args, check, kind, parse=None):
        """One logical read: three attempts. Returns the parsed, shape-checked value."""
        check_halt()
        parse = parse or json.loads
        last = 'GitLab read failed'
        shape_only = True
        delay = float(env('SB_GITLAB_RETRY_DELAY', 'SB_GITHUB_RETRY_DELAY', default='1'))
        for attempt in range(1, 4):
            check_halt()
            wait = None
            try:
                rc, out, err = self.glab(args)
                if rc:
                    diagnostic = err + out
                    if permanent_error(diagnostic):
                        if self.soft_missing and re.search(r'\b40[34]\b|Forbidden|Not Found', diagnostic, re.I):
                            return None
                        halt('GitLab rejected a required read (authentication, permission or missing '
                             'resource); fix it before restarting', attempt, self.operation)
                    shape_only = False
                    status = re.search(r'\b[45][0-9]{2}\b', diagnostic)
                    last = 'GitLab required read failed' + (f' (HTTP {status[0]})' if status else '')
                    wait = retry_after(diagnostic)
                else:
                    try:
                        value = parse(out)
                        check(value)
                        check_halt()
                        return value
                    except (ValueError, KeyError, TypeError, AttributeError, IndexError) as error:
                        last = f'GitLab required read returned incomplete evidence: {error}'
            except (OSError, subprocess.SubprocessError):
                shape_only = False
                last = 'GitLab required read timed out or could not start'
            if attempt < 3:
                print(f'[gitlab-read] {last}; retry {attempt + 1}/3', file=sys.stderr)
                time.sleep(wait if wait is not None else max(0.0, delay) * attempt)
        strict = env('SB_GITLAB_READ_STRICT', 'SB_GITHUB_READ_STRICT')
        if shape_only and kind in FORMS and not strict:
            raise ShapeError(f'{last}; this call failed, the run continues. Valid form: {FORMS[kind]}')
        halt(f'{last}; stopped after 3 failed attempts', 3, self.operation)

    def get(self, path, check, kind):
        return self.request([path], check, kind)

    def pages(self, path, check_item, kind, limit=None):
        """Every item of a paged list (or the first `limit`). Short page = last page."""
        out, seen = [], set()
        sep = '&' if '?' in path else '?'
        for page in range(1, MAX_PAGES + 1):
            def check(value):
                require(isinstance(value, list), 'list page is not a JSON array')
                for item in value:
                    check_item(item)
            items = self.get(f'{path}{sep}per_page={PER_PAGE}&page={page}', check, kind)
            ids = [item.get('id') for item in items if isinstance(item, dict)]
            if any(i in seen for i in ids if i is not None):
                halt('GitLab pagination repeated a page; the list is not complete', 1, self.operation)
            seen.update(i for i in ids if i is not None)
            out += items
            if limit is not None and len(out) >= limit:
                return out[:limit]
            if len(items) < PER_PAGE:
                return out
        halt(f'GitLab list longer than {MAX_PAGES} pages; refusing a partial read', 1, self.operation)


# ── shapes ─────────────────────────────────────────────────────────────────
def require(condition, why):
    if not condition:
        raise ValueError(why)


def is_str(v):
    return isinstance(v, str)


def check_issue(v):
    require(isinstance(v, dict) and type(v.get('iid')) is int and v['iid'] > 0, 'issue iid missing')
    require(is_str(v.get('title')) and (v.get('description') is None or is_str(v['description'])), 'issue title/body missing')
    require(v.get('state') in ('opened', 'closed'), 'issue state missing')
    require(isinstance(v.get('labels'), list) and all(is_str(l) for l in v['labels']), 'issue labels missing')


def check_note(v):
    require(isinstance(v, dict) and type(v.get('id')) is int and is_str(v.get('body'))
            and isinstance(v.get('author'), dict) and is_str(v['author'].get('username'))
            and is_str(v.get('created_at')) and type(v.get('system')) is bool, 'note fields missing')


def check_mr(v):
    require(isinstance(v, dict) and type(v.get('iid')) is int and v['iid'] > 0, 'MR iid missing')
    require(is_str(v.get('title')) and (v.get('description') is None or is_str(v['description'])), 'MR title/body missing')
    require(v.get('state') in ('opened', 'closed', 'merged', 'locked'), 'MR state missing')
    require(is_str(v.get('web_url')) and is_str(v.get('source_branch')), 'MR URL/branch missing')


def check_diff(v):
    require(isinstance(v, dict) and is_str(v.get('new_path')) and is_str(v.get('old_path'))
            and is_str(v.get('diff')), 'diff entry fields missing')
    for flag in ('new_file', 'renamed_file', 'deleted_file'):
        require(type(v.get(flag)) is bool, 'diff entry flags missing')


def check_discussion(v):
    require(isinstance(v, dict) and is_str(v.get('id')) and isinstance(v.get('notes'), list), 'discussion fields missing')
    for n in v['notes']:
        check_note(n)


def check_link(v):
    require(isinstance(v, dict) and type(v.get('iid')) is int and v.get('state') in ('opened', 'closed')
            and is_str(v.get('link_type')), 'issue link fields missing')


# ── shaping ────────────────────────────────────────────────────────────────
def upper_state(s):
    return {'opened': 'OPEN', 'closed': 'CLOSED', 'merged': 'MERGED', 'locked': 'CLOSED'}[s]


def issue_view(i):
    return {'number': i['iid'], 'title': i['title'], 'body': i.get('description') or '',
            'state': upper_state(i['state']), 'labels': list(i['labels']),
            'assignees': [a.get('username') for a in i.get('assignees') or [] if isinstance(a, dict)],
            'url': i.get('web_url') or ''}


def note_view(n):
    out = {'author': n['author']['username'], 'body': n['body'], 'createdAt': n['created_at']}
    pos = n.get('position')
    if isinstance(pos, dict) and (pos.get('new_path') or pos.get('old_path')):
        out['path'] = pos.get('new_path') or pos.get('old_path')
    if n.get('resolvable'):
        out['resolved'] = bool(n.get('resolved'))
    return out


def oldest_first(notes):
    return sorted((n for n in notes if not n['system']), key=lambda n: (n['created_at'], n['id']))


def diff_text(d):
    old, new = d['old_path'], d['new_path']
    lines = [f'diff --git a/{old} b/{new}']
    if d['new_file']:
        lines.append(f'new file mode {d.get("b_mode") or "100644"}')
    elif d['deleted_file']:
        lines.append(f'deleted file mode {d.get("a_mode") or "100644"}')
    elif d.get('a_mode') and d.get('b_mode') and d['a_mode'] != d['b_mode']:
        lines += [f'old mode {d["a_mode"]}', f'new mode {d["b_mode"]}']
    if d['renamed_file']:
        lines += [f'rename from {old}', f'rename to {new}']
    body = d['diff']
    if body.startswith('Binary files'):
        return '\n'.join(lines) + '\n' + body.rstrip('\n') + '\n', False
    if not body:
        omitted = bool(d.get('too_large') or d.get('collapsed'))
        if omitted:
            lines.append(f'Binary files a/{old} and b/{new} differ')  # placeholder GitLab gave no text for
        return '\n'.join(lines) + '\n', omitted
    lines += ['--- /dev/null' if d['new_file'] else f'--- a/{old}',
              '+++ /dev/null' if d['deleted_file'] else f'+++ b/{new}']
    return '\n'.join(lines) + '\n' + (body if body.endswith('\n') else body + '\n'), False


def counts(d):
    add = rem = 0
    for line in d['diff'].split('\n'):
        if line.startswith('+') and not line.startswith('+++ '):
            add += 1
        elif line.startswith('-') and not line.startswith('--- '):
            rem += 1
    return add, rem


def diff_path(d):
    return d['old_path'] if d['deleted_file'] else d['new_path']


# ── kinds ──────────────────────────────────────────────────────────────────
def run_kind(r, a):
    kind = a.kind
    if kind in NEEDS_IID and not a.iid:
        raise ValueError(f'--kind {kind} needs --iid <N>')
    p = r.pid() if kind != 'json' else None
    iid = a.iid
    if kind == 'issue':
        return issue_view(r.get(f'projects/{p}/issues/{iid}', check_issue, kind))
    if kind == 'comments':
        notes = r.pages(f'projects/{p}/issues/{iid}/notes?sort=asc&order_by=created_at', check_note, kind)
        return [note_view(n) for n in oldest_first(notes)]
    if kind in ('issues', 'issues-closed'):
        state = 'closed' if kind == 'issues-closed' else (a.state or 'opened')
        require(state in ('opened', 'closed', 'all'), '--state must be opened, closed or all')
        q = f'projects/{p}/issues?state={state}&order_by=updated_at&sort=desc'
        if a.since:
            q += '&updated_after=' + urllib.parse.quote(a.since, safe='')
        issues = r.pages(q, check_issue, kind, limit=a.limit or (100 if kind == 'issues-closed' else 200))
        if kind == 'issues-closed':
            # GitLab has no close reason; null tells preflight "not known to be not-planned".
            return [{'number': i['iid'], 'title': i['title'], 'body': i.get('description') or '',
                     'stateReason': None} for i in issues]
        return [issue_view(i) for i in issues]
    if kind == 'deps-issues':
        issues = r.pages(f'projects/{p}/issues?state=opened&order_by=created_at&sort=asc', check_issue, kind)
        out = []
        for i in issues:
            notes = r.get(f'projects/{p}/issues/{i["iid"]}/notes?sort=desc&order_by=created_at&per_page=20',
                          lambda v: [check_note(n) for n in (v if isinstance(v, list) else [None])], kind)
            recent = oldest_first(notes)[-8:]
            out.append({'number': i['iid'], 'title': i['title'], 'body': i.get('description') or '',
                        'state': 'OPEN', 'labels': {'nodes': [{'name': l} for l in i['labels']]},
                        'comments': {'nodes': [{'body': n['body']} for n in recent]}})
        return out
    if kind == 'links':
        r.soft_missing = True
        links = r.get(f'projects/{p}/issues/{iid}/links',
                      lambda v: [check_link(x) for x in (v if isinstance(v, list) else [None])], kind)
        if links is None:
            print('[gitlab-read] issue links unavailable here (Premium or no access); treating as none', file=sys.stderr)
            return []
        out = []
        for link in links:
            ref = ((link.get('references') or {}).get('full') or '')
            out.append({'number': link['iid'], 'state': upper_state(link['state']), 'linkType': link['link_type'],
                        'project': ref.rsplit('#', 1)[0] if '#' in ref else None})
        return out
    if kind in ('mr-diff', 'mr-files', 'metadata'):
        diffs = r.pages(f'projects/{p}/merge_requests/{iid}/diffs', check_diff, kind)
        if kind == 'mr-files':
            return [diff_path(d) for d in diffs]
        if kind == 'metadata':
            mr = r.get(f'projects/{p}/merge_requests/{iid}', check_mr, kind)
            files = []
            for d in diffs:
                add, rem = counts(d)
                files.append({'path': diff_path(d), 'additions': add, 'deletions': rem})
            return {'files': files, 'labels': [{'name': l} for l in mr.get('labels') or []],
                    'body': mr.get('description') or '',
                    'additions': sum(f['additions'] for f in files),
                    'deletions': sum(f['deletions'] for f in files), 'changedFiles': len(files)}
        return render_diff(diffs, a.max_files, a.max_bytes)
    if kind == 'mr-notes':
        notes = r.pages(f'projects/{p}/merge_requests/{iid}/notes?sort=asc&order_by=created_at', check_note, kind)
        return [note_view(n) for n in oldest_first(notes)]
    if kind == 'mr-discussions':
        out = []
        for d in r.pages(f'projects/{p}/merge_requests/{iid}/discussions', check_discussion, kind):
            notes = [n for n in d['notes'] if not n['system']]
            if not notes:
                continue
            first = note_view(notes[0])
            out.append({'id': d['id'], 'path': first.get('path'),
                        'resolved': (all(n.get('resolved') for n in notes if n.get('resolvable'))
                                     if any(n.get('resolvable') for n in notes) else None),
                        'notes': [{'author': n['author']['username'], 'body': n['body'], 'createdAt': n['created_at']}
                                  for n in notes]})
        return out
    if kind in ('mrs', 'prs-merged', 'prs-open'):
        state = {'prs-merged': 'merged', 'prs-open': 'opened'}.get(kind) or a.state or 'merged'
        require(state in ('opened', 'merged', 'closed', 'all'), '--state must be opened, merged, closed or all')
        q = f'projects/{p}/merge_requests?state={state}&order_by=updated_at&sort=desc'
        if a.since:
            q += '&updated_after=' + urllib.parse.quote(a.since, safe='')
        mrs = r.pages(q, check_mr, kind, limit=a.limit or (100 if kind != 'mrs' else 200))
        if kind == 'prs-merged':
            return [{'number': m['iid'], 'title': m['title'], 'body': m.get('description') or '', 'url': m['web_url']}
                    for m in mrs]
        if kind == 'prs-open':
            out = []
            for m in mrs:
                diffs = r.pages(f'projects/{p}/merge_requests/{m["iid"]}/diffs', check_diff, kind)
                out.append({'number': m['iid'], 'title': m['title'], 'body': m.get('description') or '',
                            'url': m['web_url'], 'headRefName': m['source_branch'],
                            'files': [{'path': diff_path(d)} for d in diffs]})
            return out
        return [{'number': m['iid'], 'title': m['title'], 'body': m.get('description') or '', 'url': m['web_url'],
                 'state': upper_state(m['state']), 'headRefName': m['source_branch'], 'mergedAt': m.get('merged_at'),
                 'author': ((m.get('author') or {}).get('username'))} for m in mrs]
    if kind == 'json':
        return passthrough(r, a.command)
    raise ValueError(f'unknown kind {kind}')


def render_diff(diffs, max_files, max_bytes):
    parts, size, omitted = [], 0, []
    for index, d in enumerate(diffs):
        text, gitlab_cut = diff_text(d)
        if gitlab_cut:
            omitted.append(diff_path(d))
        if index >= max_files or size + len(text.encode()) > max_bytes:
            rest = [diff_path(x) for x in diffs[index:]]
            parts.append(f'\\ super-board: diff truncated: {index} of {len(diffs)} files shown '
                         f'(cap {max_files} files / {max_bytes} bytes); not shown: '
                         + ', '.join(rest[:50]) + (' …' if len(rest) > 50 else '') + '\n')
            print(f'[gitlab-read] diff truncated at {index} of {len(diffs)} files', file=sys.stderr)
            break
        parts.append(text)
        size += len(text.encode())
    if omitted:
        parts.append('\\ super-board: GitLab omitted the diff text of (too large or collapsed): '
                     + ', '.join(omitted[:50]) + '\n')
    return ''.join(parts)


def read_only(args):
    if not args:
        return False
    for i, arg in enumerate(args):
        if arg in ('-X', '--method') and (i + 1 == len(args) or args[i + 1].upper() != 'GET'):
            return False
        if arg.startswith('--method=') and arg.upper() != '--METHOD=GET':
            return False
        if arg.startswith('-X') and arg not in ('-X', '-XGET'):
            return False
        if arg in ('-f', '-F', '--field', '--raw-field', '--input') or arg.startswith(
                ('--field=', '--raw-field=', '--input=', '-f', '-F')):
            return False
        if arg in ('graphql',):
            return False
    return True


def concatenated(text):
    """`glab api --paginate` prints one JSON document per page; merge list pages."""
    decoder, docs, i = json.JSONDecoder(), [], 0
    text = text.strip()
    while i < len(text):
        doc, end = decoder.raw_decode(text, i)
        docs.append(doc)
        i = end
        while i < len(text) and text[i].isspace():
            i += 1
    require(bool(docs), 'empty response')
    if len(docs) == 1:
        return docs[0]
    require(all(isinstance(d, list) for d in docs), 'paginated pages are not all lists')
    return [x for d in docs for x in d]


def passthrough(r, command):
    if not read_only(command):
        raise ValueError('--kind json accepts read-only (GET) glab api arguments only')

    def check(value):
        require(isinstance(value, (dict, list)), 'response is not a JSON object or array')
        if isinstance(value, dict):
            require(not (value.get('error') or (set(value) == {'message'})), 'GitLab returned an error payload')
    return r.request(command, check, 'json', parse=concatenated)


# ── CLI ────────────────────────────────────────────────────────────────────
def target(a):
    cfg = {}
    if a.config:
        try:
            cfg = json.loads(Path(a.config).read_text())
        except OSError as error:
            raise ConfigMissing(f'config not found: {a.config}') from error
    host = a.host or env('SB_FORGE_HOST') or cfg.get('forge_host') or 'gitlab.com'
    project = a.project or env('SB_GITLAB_PROJECT') or (cfg.get('gitlab') or {}).get('project')
    return host, project


def parser():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--kind', choices=KINDS)
    p.add_argument('--config')
    p.add_argument('--host')
    p.add_argument('--project')
    p.add_argument('--iid', type=int)
    p.add_argument('--state')
    p.add_argument('--since')
    p.add_argument('--limit', type=int)
    p.add_argument('--max-files', type=int, default=int(env('SB_GITLAB_DIFF_MAX_FILES', default='300')))
    p.add_argument('--max-bytes', type=int, default=int(env('SB_GITLAB_DIFF_MAX_BYTES', default='1000000')))
    p.add_argument('--check', action='store_true')
    p.add_argument('--halt', help='record an unresolved mutation outcome and stop; never retry it')
    p.add_argument('--resume', action='store_true')
    p.add_argument('command', nargs=argparse.REMAINDER)
    return p


def execute(argv):
    a = parser().parse_args(argv)
    a.command = a.command[1:] if a.command[:1] == ['--'] else a.command
    if a.halt:
        halt(a.halt, 1)
    if a.check:
        check_halt()
        return None
    if not a.kind:
        raise ValueError('--kind is required')
    if a.command and a.kind != 'json':
        raise ValueError('glab api arguments are only accepted with --kind json')
    host, project = target(a)
    r = Reader(host, project, {'argv': argv})
    return run_kind(r, a)


def emit(value):
    sys.stdout.write(value if isinstance(value, str) else json.dumps(value) + '\n')


def main(argv=None):
    global RECOVERING
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        if '--resume' in argv and '--' not in argv[:argv.index('--resume')]:
            rest = [x for x in argv if x != '--resume']
            path = halt_path()
            if path.exists():
                record = json.loads(path.read_text())
                saved = record.get('gitlab_operation')
                if record.get('forge') != 'gitlab' or not isinstance(saved, dict) or not isinstance(saved.get('argv'), list):
                    raise ReadHalted('saved failure is not a GitLab read; resume it with the helper that wrote it, '
                                     'or reconcile the outcome by hand')
                if rest:
                    old = parser().parse_args(saved['argv']).kind
                    if parser().parse_args(rest).kind != old:
                        raise ValueError('replacement recovery read must validate the same evidence kind')
                RECOVERING = True
                execute(rest or saved['argv'])
                RECOVERING = False
                path.replace(path.with_name(f'github-halt-{time.time_ns()}.json'))
            return 0
        value = execute(argv)
        if value is not None:
            emit(value)
        return 0
    except ReadHalted as error:
        print(f'[gitlab-read] HALT: {error}. Saved at {halt_path()}', file=sys.stderr)
        return HALTED
    except ConfigMissing as error:
        print(f'[gitlab-read] {error}', file=sys.stderr)
        return 66
    except (ValueError, OSError) as error:
        print(f'[gitlab-read] {error}', file=sys.stderr)
        return 64


if __name__ == '__main__':
    sys.exit(main())
