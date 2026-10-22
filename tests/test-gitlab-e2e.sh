#!/usr/bin/env bash
# End-to-end: the board scripts on top of the REAL GitLab forge backends
# (super-board-forge-gitlab*.sh, super-board-gitlab-read.py), with only `glab`
# faked (tests/fixtures/glab/fake_glab.py). No network.
#
# The other GitLab tests pin each backend verb on its own, or a board script
# against a stand-in forge. This one runs them together, the way a wave does:
#   1. wave-plan builds a wave from a GitLab board (labels → columns, deps graph)
#   2. deps --config reads GitLab issues: a closed blocker frees, an open one blocks
#   3. preflight --config: a merged MR saying `Closes #N` holds card N as done
#   4. merge-gate against a real git origin: green merge pinned to the sha, failed
#      pipeline, head moved (409 → 6), draft readied first, non-default base closes
#   5. a card's whole life through the forge: claim → Building → QA → Review → Done
#
# The fake is made stateful by a wrapper (world.py below): issues live in
# $FAKE_GLAB_DIR/issues.json and every route that reads them is regenerated after
# each successful PUT to an issue, so a `move` is visible to the next read.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
# Python is a native program on Windows: hand it a Windows path to the fake, since
# sb_glab_api turns Git Bash's own path conversion off for glab's arguments.
FAKE_GLAB_PY=$(cygpath -m "$ROOT/tests/fixtures/glab/fake_glab.py" 2>/dev/null || echo "$ROOT/tests/fixtures/glab/fake_glab.py")
S="$ROOT/scripts"
fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ✅ $1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
F="$TMP/fake"
mkdir -p "$TMP/bin" "$F"
P='projects/grp%2Fapp'
MR="$P/merge_requests"
PG='per_page=100&page=1'

# ── the stateful world around fake_glab ──────────────────────────────────
cat > "$TMP/world.py" <<'PY'
"""world.py sync | apply <glab-rc> — keeps fake_glab's routes.json in step with issues.json.

issues.json: [GitLab issue]; notes.json: {iid: [note]}; extra.json: other routes;
after-merge.json (optional): routes laid over extra.json once an MR merge PUT is
logged (a head that moved, a merged MR). `apply` reads the last calls.log line.
"""
import json, os, sys, urllib.parse
D = os.environ['FAKE_GLAB_DIR']
P = 'projects/grp%2Fapp'
PG = 'per_page=100&page=1'
COLS = ['Backlog', 'Ready', 'Building', 'QA', 'Review', 'Blocked']
USERS = {42: 'lane-bot', 7: 'other-lane'}

def load(name, default):
    path = os.path.join(D, name)
    return json.load(open(path)) if os.path.exists(path) else default

def save(name, value):
    json.dump(value, open(os.path.join(D, name), 'w'))

def sync():
    issues = load('issues.json', [])
    notes = load('notes.json', {})
    routes = {'GET user': {'body': {'id': 42, 'username': 'lane-bot'}}}
    for uid, name in USERS.items():
        routes[f'GET users?username={name}'] = {'body': [{'id': uid, 'username': name}]}
    for i in issues:
        n = i['iid']
        routes[f'GET {P}/issues/{n}'] = {'body': i}
        routes[f'PUT {P}/issues/{n}'] = {'body': i}
        ns = notes.get(str(n), [])
        routes[f'GET {P}/issues/{n}/notes?sort=desc&order_by=created_at&per_page=20'] = {'body': ns[::-1]}
        routes[f'GET {P}/issues/{n}/notes?sort=asc&order_by=created_at&{PG}'] = {'body': ns}
    by = lambda key, rev: sorted(issues, key=lambda i: i['iid'], reverse=rev)
    for state in ('opened', 'closed', 'all'):
        pick = [i for i in issues if state == 'all' or i['state'] == state]
        for order, sort in (('created_at', 'asc'), ('created_at', 'desc'), ('updated_at', 'desc')):
            rows = sorted(pick, key=lambda i: i['iid'], reverse=(sort == 'desc'))
            routes[f'GET {P}/issues?state={state}&order_by={order}&sort={sort}&{PG}'] = {'body': rows}
    for c in COLS:
        lab = urllib.parse.quote('sb::' + c, safe='')
        rows = [i for i in issues if 'sb::' + c in i['labels']]
        routes[f'GET {P}/issues?labels={lab}&state=all&order_by=created_at&sort=asc&{PG}'] = {'body': rows}
    routes.update(load('extra.json', {}))
    if load('merged', None):
        routes.update(load('after-merge.json', {}))
    save('routes.json', routes)

def apply():
    lines = open(os.path.join(D, 'calls.log')).read().splitlines()
    if not lines:
        return
    call = json.loads(lines[-1])
    path, f = call['path'] or '', call['fields']
    # Any merge attempt, refused or not, switches to the after-merge routes.
    if call['method'] == 'PUT' and path.startswith(P + '/merge_requests/') and path.endswith('/merge'):
        save('merged', True); sync(); return
    if sys.argv[2] != '0' or call['method'] != 'PUT' or not path.startswith(P + '/issues/'):
        return
    n = int(path.rsplit('/', 1)[1])
    issues = load('issues.json', [])
    for i in issues:
        if i['iid'] != n:
            continue
        split = lambda v: [x for x in (v or '').split(',') if x]
        i['labels'] = [l for l in i['labels'] if l not in split(f.get('remove_labels'))]
        i['labels'] += [l for l in split(f.get('add_labels')) if l not in i['labels']]
        if f.get('state_event') == 'close': i['state'] = 'closed'
        if f.get('state_event') == 'reopen': i['state'] = 'opened'
        if 'assignee_ids' in f:
            i['assignees'] = [{'id': int(x), 'username': USERS[int(x)]} for x in split(f['assignee_ids']) if int(x)]
    save('issues.json', issues); sync()

{'sync': sync, 'apply': apply}[sys.argv[1]]()
PY
cat > "$TMP/bin/glab" <<EOF
#!/usr/bin/env bash
rc=0; python3 "$FAKE_GLAB_PY" "\$@" || rc=\$?
python3 "$TMP/world.py" apply "\$rc"
exit "\$rc"
EOF
# gh must never be reached on a GitLab board.
printf '#!/usr/bin/env bash\necho "gh called on GitLab: $*" >> "%s/gh.log"\nexit 1\n' "$TMP" > "$TMP/bin/gh"
chmod +x "$TMP/bin/glab" "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" FAKE_GLAB_DIR="$F" SB_GLAB_BACKOFF=0 SB_GLAB_CLAIM_SETTLE=0 \
       SB_GITHUB_HALT_FILE="$TMP/halt.json" SB_GITLAB_RETRY_DELAY=0 SB_GITHUB_RETRY_DELAY=0
unset SB_FORGE SB_FORGE_HOST SB_GITLAB_PROJECT SB_GITLAB_PREFIX SB_CONFIG SB_GL_PER_PAGE SB_GLAB_PER_PAGE \
      SB_GITLAB_HALT_FILE SB_MERGE_GATE

CFG="$TMP/cfg.json"
cat > "$CFG" <<'EOF'
{"forge": "gitlab", "forge_host": "gitlab.example.com", "gitlab": {"project": "grp/app"},
 "verify_commands": ["true"]}
EOF

# world <issues-json> [notes-json] [extra-routes-json] — resets the fake.
world() {
  rm -f "$F"/*.json "$F/merged" "$F/.served.json"
  printf '%s' "$1" > "$F/issues.json"
  local empty='{}'
  printf '%s' "${2:-$empty}" > "$F/notes.json"
  printf '%s' "${3:-$empty}" > "$F/extra.json"
  : > "$F/calls.log"
  python3 "$TMP/world.py" sync
}
# issue <iid> <state> <labels-json> <body> [assignees-json]
issue() {
  jq -cn --argjson n "$1" --arg s "$2" --argjson l "$3" --arg b "$4" --argjson a "${5:-[]}" \
    '{id: (1000 + $n), iid: $n, title: "card \($n)", description: $b, state: $s, labels: $l,
      assignees: $a, web_url: "https://gitlab.example.com/grp/app/-/issues/\($n)"}'
}
calls() { grep -c "\"method\": \"$1\", \"path\": \"$2\"" "$F/calls.log" || true; }
field() { jq -rs --arg m "$1" --arg p "$2" --arg k "$3" \
  '[.[] | select(.method == $m and .path == $p)] | last | .fields[$k] // "<absent>"' "$F/calls.log"; }
no_gh() { [ ! -s "$TMP/gh.log" ] || fail "gh was called on GitLab: $(cat "$TMP/gh.log")"; }
forge() { bash "$S/super-board-forge.sh" --config "$CFG" "$@"; }

NONE=$'## Blocked by\n\n- None.\n'
by() { printf '## Blocked by\n\n- #%s — needs it first\n' "$1"; }

# ── 1+2. wave-plan and deps on one GitLab board ─────────────────────────
#  #1 Ready, free            #2 Ready, blocked by open #3     #3 Backlog
#  #4 Review                 #5 Ready, blocked by closed #6   #6 Done (closed)
#  #7 Blocked by closed #6   #8 Ready, labelled qa            #10 Building
world "[$(issue 1 opened '["sb::Ready"]' "$NONE"),
        $(issue 2 opened '["sb::Ready"]' "$(by 3)"),
        $(issue 3 opened '["sb::Backlog"]' "$NONE"),
        $(issue 4 opened '["sb::Review"]' "$NONE"),
        $(issue 5 opened '["sb::Ready","feature"]' "$(by 6)"),
        $(issue 6 closed '["sb::Review"]' "$NONE"),
        $(issue 7 opened '["sb::Blocked"]' "$(by 6)"),
        $(issue 8 opened '["sb::Ready","qa"]' "$NONE"),
        $(issue 10 opened '["sb::Building"]' "$NONE")]"

DEPS=$(bash "$S/super-board-deps.sh" --config "$CFG") || fail "deps --config on GitLab exited $?"
chk() { echo "$1" | jq -e "$2" >/dev/null || fail "$3: $2 — $(echo "$1" | jq -c .)"; }
chk "$DEPS" '.["2"].openBlockers == [3] and .["2"].runnable == false' deps
chk "$DEPS" '.["5"].blockers == [6] and .["5"].openBlockers == [] and .["5"].runnable == true' deps
chk "$DEPS" '.["1"].runnable == true and (has("6") | not)' deps
[ "$(calls GET "$P/issues?state=opened&order_by=created_at&sort=asc&$PG")" = 1 ] || fail "deps did not read open issues from GitLab"
grep -q '"host": "gitlab.example.com"' "$F/calls.log" || fail "deps ignored forge_host"
no_gh
ok "deps --config on GitLab: closed blocker frees #5, open #3 blocks #2"

PLAN=$(bash "$S/super-board-wave-plan.sh" --config "$CFG") || fail "wave-plan on GitLab exited $?"
chk "$PLAN" '[.cards[].number] == [4, 1, 5, 8]' wave-plan
chk "$PLAN" '.cards[0].lane == "review" and .cards[0].status == "Review"' wave-plan
chk "$PLAN" '(.cards[] | select(.number == 8) | .lane) == "qa"' wave-plan
chk "$PLAN" '(.cards[] | select(.number == 1) | .lane) == "build"' wave-plan
chk "$PLAN" '.sweep == [{"number": 7, "title": "card 7", "clearedBy": [6]}]' wave-plan
chk "$PLAN" '.stranded == [{"number": 10, "title": "card 10"}] and .flag == []' wave-plan
[ "$(calls GET "$P/issues?labels=sb%3A%3AReady&state=all&order_by=created_at&sort=asc&$PG")" = 1 ] \
  || fail "wave-plan did not read the board through the GitLab column labels"
no_gh
ok "wave-plan from a GitLab board: free Ready + Review/QA lanes, blocked #2 left out, #7 swept, #10 stranded"

# ── 3. preflight: a merged MR closes the card ───────────────────────────
AC=$'## Acceptance Criteria\n- [ ] it works\n'
mrj() { # iid state branch body
  jq -cn --argjson n "$1" --arg s "$2" --arg b "$3" --arg d "$4" \
    '{id: (500 + $n), iid: $n, title: "MR \($n) does a thing", description: $d, state: $s,
      web_url: "https://gitlab.example.com/grp/app/-/merge_requests/\($n)", source_branch: $b, labels: []}'
}
world "[$(issue 20 opened '["sb::Ready"]' "$AC"), $(issue 23 opened '["sb::Ready"]' "$AC")]" '{}' "{
  \"GET $MR?state=merged&order_by=updated_at&sort=desc&$PG\": {\"body\": [$(mrj 31 merged issue-20-x $'Implements it.\n\nCloses #20')]},
  \"GET $MR?state=opened&order_by=updated_at&sort=desc&$PG\": {\"body\": []}}"
PRE=$(bash "$S/super-board-preflight.sh" --config "$CFG" --issues 20,23) || fail "preflight on GitLab exited $?"
chk "$PRE" '.["20"].verdict == "hold" and .["20"].tag == "done"' preflight
chk "$PRE" '.["20"].evidence[0] | test("PR #31 merged and closes #20")' preflight
chk "$PRE" '.["23"].verdict == "proceed"' preflight
no_gh
ok "preflight --config on GitLab: merged MR with 'Closes #20' holds #20 as done, #23 proceeds"

# ── 4. merge gate on GitLab, real git origin ────────────────────────────
REPO="$TMP/repo"; ORIGIN="$TMP/origin.git"
git init -q --bare "$ORIGIN"
git init -q "$REPO"; git -C "$REPO" checkout -q -b staging
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$REPO" remote add origin "$ORIGIN"; git -C "$REPO" push -q origin staging
git -C "$REPO" checkout -q -b feat
echo hello > "$REPO/README.md"; git -C "$REPO" add README.md
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m feat
git -C "$REPO" push -q origin feat; git -C "$REPO" checkout -q staging
SHA=$(git -C "$REPO" rev-parse feat)
MOVED=cafef00dcafef00dcafef00dcafef00dcafef00d
GCFG="$TMP/gate.json"
jq -n --arg p "$REPO" '{forge: "gitlab", forge_host: "gitlab.example.com", gitlab: {project: "grp/app"},
  base_branch: "staging", repo: {path: $p}, verify_commands: ["test -f README.md"]}' > "$GCFG"

# gate_world <pipeline-status> <draft> <default-branch> [merge-PUT-route] [sha-after-merge]
gate_world() {
  local mr; mr=$(jq -cn --arg sha "$SHA" --arg st "$1" --argjson d "$2" '{
    id: 507, iid: 7, project_id: 5, title: ((if $d then "Draft: " else "" end) + "✨ [feat] x: y"),
    description: "Closes #3", state: "opened", draft: $d, source_branch: "feat", target_branch: "staging",
    sha: $sha, web_url: "https://gitlab.example.com/grp/app/-/merge_requests/7",
    detailed_merge_status: "mergeable", labels: [], head_pipeline: {id: 900, status: $st}}')
  # After the merge PUT: merged, or (head moved) still open at another sha.
  local after merge='{"body": {"state": "merged"}}'
  if [ -n "${5:-}" ]; then after=$(jq -c --arg s "$5" '.sha = $s' <<<"$mr")
  else after=$(jq -c '.state = "merged" | .merge_commit_sha = .sha' <<<"$mr"); fi
  world "[$(issue 3 opened '["sb::Review"]' "$NONE"), $(issue 5 opened '["sb::Review"]' "$NONE")]" '{}' "{
    \"GET $MR/7\": {\"body\": $mr},
    \"PUT $MR/7\": {\"body\": $mr},
    \"GET $MR/7/closes_issues?$PG\": {\"body\": [{\"iid\": 5, \"project_id\": 5}]},
    \"GET $MR/7/diffs?$PG\": {\"body\": [{\"old_path\": \"README.md\", \"new_path\": \"README.md\", \"a_mode\": \"0\", \"b_mode\": \"100644\",
       \"new_file\": true, \"renamed_file\": false, \"deleted_file\": false, \"diff\": \"@@ -0,0 +1 @@\\n+hello\\n\"}]},
    \"GET projects/grp%2Fapp/pipelines/900/jobs?$PG\": {\"body\": [{\"name\": \"test\", \"status\": \"$1\", \"web_url\": \"j\"}]},
    \"GET $P\": {\"body\": {\"default_branch\": \"$3\"}},
    \"PUT $MR/7/merge\": ${4:-$merge}}"
  printf '{"GET %s/7": {"body": %s}}' "$MR" "$after" > "$F/after-merge.json"
  rm -rf "$REPO/.claude/super-board/inflight/merge.lock"
}
gate() { bash "$S/super-board-merge-gate.sh" --config "$GCFG" --pr 7 --lock-timeout 6 --expect-head "$SHA" "$@"; }

# (a) green pipeline, base is the default branch: merged at the tested sha, nothing closed.
gate_world success false staging
printf -- '- adds the README\n\nCloses #3\n' > "$TMP/msg.md"
RC=0; gate --subject '✨ [feat] x: y' --body-file "$TMP/msg.md" >"$TMP/gate.out" 2>&1 || RC=$?
[ "$RC" = 0 ] || fail "green MR should merge, got $RC: $(cat "$TMP/gate.out")"
field PUT "$MR/7/merge" squash_commit_message | head -1 | grep -qx '✨ \[feat\] x: y' \
  || fail "squash commit subject: $(field PUT "$MR/7/merge" squash_commit_message)"
field PUT "$MR/7/merge" squash_commit_message | grep -qx 'Closes #3' || fail "squash commit body lost"
[ "$(calls PUT "$MR/7/merge")" = 1 ] || fail "exactly one merge PUT expected: $(cat "$F/calls.log")"
[ "$(field PUT "$MR/7/merge" sha)" = "$SHA" ] || fail "merge PUT not pinned to the tested sha: $(field PUT "$MR/7/merge" sha)"
[ "$(field PUT "$MR/7/merge" squash)" = true ] || fail "merge PUT should squash"
[ "$(field PUT "$MR/7/merge" should_remove_source_branch)" = true ] || fail "merge PUT should delete the branch"
grep -q '"state_event": "close"' "$F/calls.log" && fail "default-branch merge must leave closing to GitLab"
[ "$(calls PUT "$MR/7")" = 0 ] || fail "a ready MR must not be rewritten"
[ ! -d "$REPO/.claude/super-board/inflight/merge.lock" ] || fail "lock not released"
no_gh
ok "merge gate (a): green pipeline → one merge PUT with sha=$SHA, squash, delete branch"

# (b) failed pipeline: exit 2, no merge PUT.
gate_world failed false staging
RC=0; gate >"$TMP/gate.out" 2>&1 || RC=$?
[ "$RC" = 2 ] || fail "failed pipeline should exit 2, got $RC: $(cat "$TMP/gate.out")"
[ "$(calls PUT "$MR/7/merge")" = 0 ] || fail "no merge PUT on a failed pipeline"
ok "merge gate (b): failed pipeline → exit 2, no merge PUT"

# (c) head moved between the pre-check and the PUT: GitLab answers 409 → gate exit 6.
gate_world success false staging \
  '{"status": 1, "body": "glab: 409 Conflict {\"message\":\"SHA does not match HEAD of source branch\"}"}' "$MOVED"
RC=0; gate >"$TMP/gate.out" 2>&1 || RC=$?
[ "$RC" = 6 ] || fail "409 head moved should exit 6, got $RC: $(cat "$TMP/gate.out")"
[ "$(calls PUT "$MR/7/merge")" = 1 ] || fail "a refused merge PUT must not be retried"
[ ! -f "$TMP/halt.json" ] || fail "a moved head is not a halt"
ok "merge gate (c): GitLab 409 on the merge PUT → exit 6 (back to Review), no retry"

# (d) draft MR: pr-ready PUT (title without 'Draft: ') happens before the merge PUT.
gate_world success true staging
RC=0; gate >"$TMP/gate.out" 2>&1 || RC=$?
[ "$RC" = 0 ] || fail "draft MR should be readied and merged, got $RC: $(cat "$TMP/gate.out")"
[ "$(field PUT "$MR/7" title)" = '✨ [feat] x: y' ] || fail "pr-ready title: $(field PUT "$MR/7" title)"
READY_AT=$(grep -n "\"method\": \"PUT\", \"path\": \"$MR/7\"," "$F/calls.log" | head -1 | cut -d: -f1)
MERGE_AT=$(grep -n "\"method\": \"PUT\", \"path\": \"$MR/7/merge\"" "$F/calls.log" | head -1 | cut -d: -f1)
[ -n "$READY_AT" ] && [ -n "$MERGE_AT" ] && [ "$READY_AT" -lt "$MERGE_AT" ] || fail "pr-ready must precede the merge PUT"
ok "merge gate (d): draft MR → pr-ready PUT, then merge PUT"

# (e) merge into staging while the default is main: closes_issues (#5) and body `Closes #3` closed.
gate_world success false main
RC=0; gate >"$TMP/gate.out" 2>&1 || RC=$?
[ "$RC" = 0 ] || fail "non-default base merge should pass, got $RC: $(cat "$TMP/gate.out")"
[ "$(field PUT "$P/issues/5" state_event)" = close ] || fail "linked #5 not closed: $(cat "$F/calls.log")"
[ "$(field PUT "$P/issues/3" state_event)" = close ] || fail "body-linked #3 not closed"
MERGE_AT=$(grep -n "\"path\": \"$MR/7/merge\"" "$F/calls.log" | cut -d: -f1)
CLOSE_AT=$(grep -n "\"path\": \"$P/issues/5\"" "$F/calls.log" | cut -d: -f1)
[ "$CLOSE_AT" -gt "$MERGE_AT" ] || fail "issues are closed only after the merge"
[ "$(jq -r '.[] | select(.iid == 5) | .state' "$F/issues.json")" = closed ] || fail "#5 should now read closed"
no_gh
ok "merge gate (e): non-default base → state_event=close PUT for #5 and #3 after the merge"

# ── 5. card flow through the forge ──────────────────────────────────────
world "[$(issue 12 opened '["sb::Ready","feature"]' "$NONE"), $(issue 13 opened '["sb::Ready"]' "$NONE" '[{"id":7,"username":"other-lane"}]')]"
colset() { jq -c --argjson n "$1" '[.[] | select(.iid == $n) | .labels[] | select(startswith("sb::"))]' "$F/issues.json"; }
forge claim 12 @me || fail "claim of a free card failed"
[ "$(field PUT "$P/issues/12" assignee_ids)" = 42 ] || fail "claim did not assign @me"
[ "$(forge issue-view 12 | jq -c .assignees)" = '["lane-bot"]' ] || fail "claim not visible"
RC=0; OUT=$(forge claim 13 @me) || RC=$?
[ "$RC" = 2 ] && [ "$OUT" = other-lane ] || fail "claim of a held card: rc $RC out $OUT"
forge claim 12 @me || fail "re-claiming our own card must succeed"
for col in Building QA Review; do
  [ "$(forge move 12 "$col")" = "moved #12 → $col" ] || fail "move $col output"
  [ "$(colset 12)" = "[\"sb::$col\"]" ] || fail "after move $col: column labels $(colset 12)"
  [ "$(forge status 12)" = "$col" ] || fail "status after $col: $(forge status 12)"
  [ "$(forge items | jq -r '.items[] | select(.content.number == 12) | .status')" = "$col" ] || fail "items after $col"
done
jq -e '.[] | select(.iid == 12) | .labels | index("feature")' "$F/issues.json" >/dev/null || fail "moves dropped a non-column label"
forge release 12 @me
[ "$(forge issue-view 12 | jq -c .assignees)" = '[]' ] || fail "release did not unassign"
[ "$(forge move 12 Done)" = "moved #12 → Done" ] || fail "move Done output"
[ "$(colset 12)" = '["sb::Review"]' ] || fail "Done keeps exactly one column label: $(colset 12)"
[ "$(forge status 12)" = Done ] && [ "$(forge issue-view 12 | jq -r .state)" = CLOSED ] || fail "Done is a closed issue"
[ "$(forge items | jq -r '.items[] | select(.content.number == 12) | .status')" = Done ] || fail "items after Done"
forge move 12 Ready >/dev/null
[ "$(colset 12)" = '["sb::Ready"]' ] && [ "$(forge status 12)" = Ready ] || fail "reopen to Ready: $(colset 12)"
no_gh
ok "card flow: claim (lost on a held card) → Building → QA → Review → Done (closed) → reopened, one column label each step"

echo "PASS: test-gitlab-e2e.sh ($pass scenarios: real GitLab backends + board scripts over fake glab)"
