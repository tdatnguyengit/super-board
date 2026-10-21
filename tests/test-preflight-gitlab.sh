#!/usr/bin/env bash
# super-board-preflight.sh on GitLab merge requests. No network: `glab` is the shared
# fake and serves REST v4 MRs, MR diffs and issues.
#
# Preflight still reads through super-board-github-read.py (`--kind prs-merged|prs-open|
# issues-closed|issue`). super-board-gitlab-read.py serves those same kinds for MRs, so
# this runs a copy of preflight next to a stand-in github-read that forwards each kind
# to gitlab-read. It pins: a card closed by a merged MR (`Closes #N` in the MR
# description) is held as done; an open MR from another branch holds it as in
# progress; an open MR touching the same files sequences it.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/scripts"
printf '#!/bin/sh\nexec python3 "%s" "$@"\n' "$ROOT/tests/fixtures/glab/fake_glab.py" > "$TMP/bin/glab"
chmod +x "$TMP/bin/glab"
cp "$ROOT/scripts/super-board-preflight.sh" "$TMP/scripts/"
cat > "$TMP/scripts/super-board-github-read.py" <<PY
#!/usr/bin/env python3
# Stand-in: forward preflight's github-read kinds to the GitLab reader.
import os, sys
a = sys.argv[1:]
kind = a[a.index('--kind') + 1]
cmd = a[a.index('--') + 1:]
extra = ['--iid', cmd[2]] if cmd[:2] == ['issue', 'view'] else []
os.execvp('python3', ['python3', '$ROOT/scripts/super-board-gitlab-read.py', '--kind', kind, *extra])
PY
export PATH="$TMP/bin:$PATH" FAKE_GLAB_DIR="$TMP" SB_GITLAB_PROJECT="grp/app" \
       SB_GITLAB_HALT_FILE="$TMP/halt.json" SB_GITLAB_RETRY_DELAY=0

python3 - "$TMP/routes.json" <<'PY'
import json, sys
P = 'projects/grp%2Fapp'
AC = '## Acceptance Criteria\n- [ ] it works'
def issue(iid, title, body=AC, state='opened'):
    return {'id': 100 + iid, 'iid': iid, 'title': title, 'description': body, 'state': state,
            'labels': [], 'assignees': [], 'web_url': f'https://gl/i/{iid}'}
def mr(iid, title, body, state, branch):
    return {'id': 500 + iid, 'iid': iid, 'title': title, 'description': body, 'state': state,
            'web_url': f'https://gl/mr/{iid}', 'source_branch': branch, 'labels': []}
def diff(path):
    return {'old_path': path, 'new_path': path, 'new_file': False, 'renamed_file': False,
            'deleted_file': False, 'diff': '@@ -1 +1 @@\n-a\n+b\n'}
page = '&per_page=100&page=1'
routes = {
  f'GET {P}/merge_requests?state=merged&order_by=updated_at&sort=desc{page}':
      {'body': [mr(31, 'CSV export', 'Implements it.\n\nCloses #20', 'merged', 'issue-20-csv')]},
  f'GET {P}/merge_requests?state=opened&order_by=updated_at&sort=desc{page}':
      {'body': [mr(40, 'Dark mode', 'Closes #21', 'opened', 'someone-else'),
                mr(41, 'Refactor auth', 'Closes #50', 'opened', 'issue-50-auth')]},
  f'GET {P}/merge_requests/40/diffs?per_page=100&page=1': {'body': [diff('src/theme.ts')]},
  f'GET {P}/merge_requests/41/diffs?per_page=100&page=1': {'body': [diff('src/auth/login.ts')]},
  f'GET {P}/issues?state=closed&order_by=updated_at&sort=desc{page}': {'body': []},
  f'GET {P}/issues/20': {'body': issue(20, 'Export invoices as CSV')},
  f'GET {P}/issues/21': {'body': issue(21, 'Dark mode toggle in settings')},
  f'GET {P}/issues/22': {'body': issue(22, 'Rate limit login', 'Touches `src/auth/login.ts`.\n' + AC)},
  f'GET {P}/issues/23': {'body': issue(23, 'Weekly digest email')},
}
json.dump(routes, open(sys.argv[1], 'w'))
PY

OUT=$(bash "$TMP/scripts/super-board-preflight.sh" --repo grp/app --issues 20,21,22,23) || fail "preflight exited $?"
get() { echo "$OUT" | jq -e ".[\"$1\"] | $2" >/dev/null || fail "#$1: $2 — $(echo "$OUT" | jq -c ".[\"$1\"]")"; }

get 20 '.verdict == "hold" and .tag == "done"'
get 20 '.evidence[0] | test("PR #31 merged and closes #20")'
get 21 '.verdict == "hold" and .tag == "in-progress"'
get 22 '.verdict == "sequence" and .blockedBy == [50] and .conflictWith == [41]'
get 23 '.verdict == "proceed"'

echo "PASS: test-preflight-gitlab.sh (merged MR closes a card; open MR in progress; file overlap)"
