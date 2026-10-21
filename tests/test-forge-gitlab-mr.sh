#!/usr/bin/env bash
# Tests the GitLab merge-request verbs of super-board-forge.sh against the fake
# glab (tests/fixtures/glab/fake_glab.py). No network.
#
# What matters most is the merge: it is pinned to the tested sha, a moved head
# is exit 4 (never a merge), a refused merge is 69, and the PUT is never retried.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD/.."
FORGE="$ROOT/scripts/super-board-forge.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ✅ $1"; }

mkdir -p "$TMP/bin" "$TMP/fake"
cat > "$TMP/bin/glab" <<EOF
#!/usr/bin/env bash
exec python3 "$ROOT/tests/fixtures/glab/fake_glab.py" "\$@"
EOF
chmod +x "$TMP/bin/glab"
export PATH="$TMP/bin:$PATH" FAKE_GLAB_DIR="$TMP/fake" SB_GLAB_BACKOFF=0
unset SB_FORGE SB_FORGE_HOST SB_GITLAB_PROJECT SB_GITLAB_PREFIX SB_CONFIG SB_GL_PER_PAGE
cat > "$TMP/cfg.json" <<'EOF'
{"forge": "gitlab", "forge_host": "gitlab.example.com", "gitlab": {"project": "grp/sub/app"}}
EOF
P='projects/grp%2Fsub%2Fapp'
MR="$P/merge_requests"
PG='per_page=100&page=1'

forge() { bash "$FORGE" --config "$TMP/cfg.json" "$@"; }
# routes '<json object>' — replaces the fake's routes and clears its log.
routes() { printf '%s' "$1" > "$TMP/fake/routes.json"; : > "$TMP/fake/calls.log"; rm -f "$TMP/fake/.served.json"; }
calls() { grep -c "\"method\": \"$1\", \"path\": \"$2\"" "$TMP/fake/calls.log" || true; }
field() { jq -rs --arg m "$1" --arg p "$2" --arg k "$3" \
  '[.[] | select(.method == $m and .path == $p)] | last | .fields[$k] // "<absent>"' "$TMP/fake/calls.log"; }

# ── pr-create: draft by title prefix, body carries Closes #N ─────────────
printf 'Closes #12\n\n- evidence: tests green\n' > "$TMP/body.md"
routes "{\"POST $MR\": {\"body\": {\"iid\": 7, \"web_url\": \"https://gitlab.example.com/grp/sub/app/-/merge_requests/7\"}}}"
OUT=$(forge pr-create --head sb/issue-12 --base develop --title '✨ [feat] x: y' --body-file "$TMP/body.md" --draft)
[ "$OUT" = '{"number":7,"url":"https://gitlab.example.com/grp/sub/app/-/merge_requests/7"}' ] || fail "pr-create output: $OUT"
[ "$(field POST "$MR" title)" = 'Draft: ✨ [feat] x: y' ] || fail "draft title: $(cat "$TMP/fake/calls.log")"
[ "$(field POST "$MR" source_branch)" = sb/issue-12 ] || fail "source_branch"
[ "$(field POST "$MR" target_branch)" = develop ] || fail "non-default target branch not honoured"
field POST "$MR" description | grep -qx 'Closes #12' || fail "description lost Closes #12"
grep -q '"host": "gitlab.example.com"' "$TMP/fake/calls.log" || fail "forge_host not passed to glab"
ok "pr-create: draft MR via 'Draft: ' prefix, target branch and Closes #N body"

# ── pr-ready ─────────────────────────────────────────────────────────────
routes "{\"GET $MR/7\": {\"body\": {\"iid\": 7, \"title\": \"Draft: ✨ [feat] x: y\", \"draft\": true}},
         \"PUT $MR/7\": {\"body\": {\"iid\": 7}}}"
forge pr-ready 7
[ "$(field PUT "$MR/7" title)" = '✨ [feat] x: y' ] || fail "pr-ready title: $(cat "$TMP/fake/calls.log")"
routes "{\"GET $MR/7\": {\"body\": {\"iid\": 7, \"title\": \"x\", \"draft\": false}}}"
forge pr-ready 7
[ "$(calls PUT "$MR/7")" = 0 ] || fail "pr-ready rewrote a ready MR"
ok "pr-ready strips the draft prefix; no-op when already ready"

# ── pr-view mapping ──────────────────────────────────────────────────────
mr_json() { # iid state draft-key draft detailed
  printf '{"iid":%s,"project_id":5,"title":"t%s","description":"d","state":"%s","%s":%s,"source_branch":"sb/issue-%s","target_branch":"main","sha":"abc%s","web_url":"u%s","detailed_merge_status":"%s"}' \
    "$1" "$1" "$2" "$3" "$4" "$1" "$1" "$1" "$5"
}
routes "{
  \"GET $MR/1\": {\"body\": $(mr_json 1 opened draft true conflict)},
  \"GET $MR/1/closes_issues?$PG\": {\"body\": [{\"iid\": 12, \"project_id\": 5}, {\"iid\": 3, \"project_id\": 99}, {\"iid\": 4, \"project_id\": 5}]},
  \"GET $MR/2\": {\"body\": $(mr_json 2 merged work_in_progress false not_open)},
  \"GET $MR/2/closes_issues?$PG\": {\"body\": []},
  \"GET $MR/3\": {\"body\": $(mr_json 3 closed draft false mergeable)},
  \"GET $MR/3/closes_issues?$PG\": {\"body\": []},
  \"GET $MR/4\": {\"body\": $(mr_json 4 locked draft false need_rebase)},
  \"GET $MR/4/closes_issues?$PG\": {\"body\": []},
  \"GET $MR/5\": {\"body\": $(mr_json 5 opened draft false mergeable)},
  \"GET $MR/5/closes_issues?$PG\": {\"body\": []},
  \"GET $MR/6\": {\"body\": $(mr_json 6 opened draft false ci_still_running)},
  \"GET $MR/6/closes_issues?$PG\": {\"body\": []}
}"
OUT=$(forge pr-view 1)
[ "$OUT" = '{"number":1,"title":"t1","body":"d","state":"OPEN","isDraft":true,"headRefName":"sb/issue-1","baseRefName":"main","headRefOid":"abc1","url":"u1","mergeable":"CONFLICTING","closingIssues":[4,12]}' ] \
  || fail "pr-view 1: $OUT"
[ "$(forge pr-view 2 | jq -r '[.state, .isDraft, .mergeable] | join(" ")')" = 'MERGED false UNKNOWN' ] || fail "pr-view merged"
[ "$(forge pr-view 3 | jq -r '[.state, .mergeable] | join(" ")')" = 'CLOSED MERGEABLE' ] || fail "pr-view closed"
[ "$(forge pr-view 4 | jq -r '[.state, .mergeable] | join(" ")')" = 'CLOSED CONFLICTING' ] || fail "pr-view locked"
[ "$(forge pr-view 5 | jq -r '[.state, .isDraft, .mergeable] | join(" ")')" = 'OPEN false MERGEABLE' ] || fail "pr-view mergeable"
[ "$(forge pr-view 6 | jq -r .mergeable)" = UNKNOWN ] || fail "pr-view unknown status"
ok "pr-view: states, draft, head sha, mergeable, closingIssues (this project only)"

# ── pr-diff: unified diff rebuilt from paged /diffs ──────────────────────
routes "{
  \"GET $MR/9/diffs?per_page=2&page=1\": {\"body\": [
    {\"old_path\": \"src/a.txt\", \"new_path\": \"src/a.txt\", \"a_mode\": \"100644\", \"b_mode\": \"100644\", \"new_file\": false, \"renamed_file\": false, \"deleted_file\": false,
     \"diff\": \"@@ -1,2 +1,2 @@\\n one\\n-two\\n+TWO\\n\"},
    {\"old_path\": \"new.txt\", \"new_path\": \"new.txt\", \"a_mode\": \"0\", \"b_mode\": \"100644\", \"new_file\": true, \"renamed_file\": false, \"deleted_file\": false,
     \"diff\": \"@@ -0,0 +1 @@\\n+hello\"}]},
  \"GET $MR/9/diffs?per_page=2&page=2\": {\"body\": [
    {\"old_path\": \"gone.txt\", \"new_path\": \"gone.txt\", \"a_mode\": \"100644\", \"b_mode\": \"0\", \"new_file\": false, \"renamed_file\": false, \"deleted_file\": true,
     \"diff\": \"@@ -1 +0,0 @@\\n-bye\\n\"},
    {\"old_path\": \"old/name.txt\", \"new_path\": \"new/name.txt\", \"a_mode\": \"100644\", \"b_mode\": \"100644\", \"new_file\": false, \"renamed_file\": true, \"deleted_file\": false,
     \"diff\": \"\"}]},
  \"GET $MR/9/diffs?per_page=2&page=3\": {\"body\": [
    {\"old_path\": \"r1.txt\", \"new_path\": \"r2.txt\", \"a_mode\": \"100644\", \"b_mode\": \"100755\", \"new_file\": false, \"renamed_file\": true, \"deleted_file\": false,
     \"diff\": \"@@ -1 +1 @@\\n-x\\n+y\\n\"}]}
}"
SB_GL_PER_PAGE=2 forge pr-diff 9 > "$TMP/got.diff"
cat > "$TMP/want.diff" <<'EOF'
diff --git a/src/a.txt b/src/a.txt
--- a/src/a.txt
+++ b/src/a.txt
@@ -1,2 +1,2 @@
 one
-two
+TWO
diff --git a/new.txt b/new.txt
new file mode 100644
--- /dev/null
+++ b/new.txt
@@ -0,0 +1 @@
+hello
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
--- a/gone.txt
+++ /dev/null
@@ -1 +0,0 @@
-bye
diff --git a/old/name.txt b/new/name.txt
rename from old/name.txt
rename to new/name.txt
diff --git a/r1.txt b/r2.txt
old mode 100644
new mode 100755
rename from r1.txt
rename to r2.txt
--- a/r1.txt
+++ b/r2.txt
@@ -1 +1 @@
-x
+y
EOF
diff -u "$TMP/want.diff" "$TMP/got.diff" >&2 || fail "pr-diff text"
[ "$(calls GET "$MR/9/diffs?per_page=2&page=3")" = 1 ] || fail "pr-diff did not page"
# git itself must parse it the way it parses `gh pr diff`.
# Outside the repo: inside a subdirectory git apply skips paths outside it.
NUM=$(cd "$TMP" && git apply --numstat got.diff | tr '\t' ' ')
printf '%s\n' "$NUM" | grep -qx '1 1 src/a.txt' || fail "git numstat modified: $NUM"
printf '%s\n' "$NUM" | grep -qx '1 0 new.txt' || fail "git numstat new: $NUM"
printf '%s\n' "$NUM" | grep -qx '0 1 gone.txt' || fail "git numstat deleted: $NUM"
printf '%s\n' "$NUM" | grep -q 'new/name.txt' || fail "git numstat rename: $NUM"
ok "pr-diff: modified/new/deleted/renamed/mode-change across pages, git-parseable"

OUT=$(SB_GL_PER_PAGE=2 forge pr-files 9)
[ "$OUT" = '["src/a.txt","new.txt","gone.txt","new/name.txt","r2.txt"]' ] || fail "pr-files: $OUT"
ok "pr-files lists every path"

# ── checks ───────────────────────────────────────────────────────────────
routes "{
  \"GET $MR/1\": {\"body\": {\"iid\": 1, \"head_pipeline\": {\"id\": 55, \"status\": \"failed\"}}},
  \"GET $P/pipelines/55/jobs?$PG\": {\"body\": [
     {\"name\": \"test\", \"status\": \"failed\", \"allow_failure\": false, \"web_url\": \"j1\"},
     {\"name\": \"lint\", \"status\": \"success\", \"allow_failure\": false, \"web_url\": \"j2\"},
     {\"name\": \"flaky\", \"status\": \"failed\", \"allow_failure\": true, \"web_url\": \"j3\"},
     {\"name\": \"deploy\", \"status\": \"manual\", \"allow_failure\": false, \"web_url\": \"j4\"}]},
  \"GET $MR/2\": {\"body\": {\"iid\": 2, \"head_pipeline\": null}},
  \"GET $MR/3\": {\"body\": {\"iid\": 3, \"head_pipeline\": {\"id\": 56, \"status\": \"running\"}}},
  \"GET $P/pipelines/56/jobs?$PG\": {\"body\": [{\"name\": \"test\", \"status\": \"pending\", \"web_url\": \"j5\"}]},
  \"GET $MR/4\": {\"body\": {\"iid\": 4, \"head_pipeline\": {\"id\": 57, \"status\": \"success\"}}},
  \"GET $P/pipelines/57/jobs?$PG\": {\"body\": [{\"name\": \"test\", \"status\": \"success\", \"web_url\": \"j6\"}]},
  \"GET $MR/5\": {\"body\": {\"iid\": 5, \"head_pipeline\": {\"id\": 58, \"status\": \"canceled\"}}},
  \"GET $P/pipelines/58/jobs?$PG\": {\"body\": []}
}"
OUT=$(forge checks 1)
[ "$OUT" = '{"state":"FAILURE","checks":[{"name":"test","state":"FAILURE","url":"j1"},{"name":"lint","state":"SUCCESS","url":"j2"},{"name":"flaky","state":"NEUTRAL","url":"j3"},{"name":"deploy","state":"PENDING","url":"j4"}]}' ] \
  || fail "checks failed pipeline: $OUT"
[ "$(forge checks 2)" = '{"state":"NONE","checks":[]}' ] || fail "checks none"
[ "$(forge checks 3 | jq -r '.state + " " + .checks[0].state')" = 'PENDING PENDING' ] || fail "checks running"
[ "$(forge checks 4 | jq -r .state)" = SUCCESS ] || fail "checks success"
[ "$(forge checks 5 | jq -r .state)" = FAILURE ] || fail "checks canceled"
ok "checks: head pipeline success/failed/canceled/running/none, jobs as checks"

# ── pr-merge ─────────────────────────────────────────────────────────────
SHA=0123456789abcdef0123456789abcdef01234567
printf 'Closes #12\n' > "$TMP/msg.md"
routes "{\"GET $MR/7\": {\"body\": {\"iid\": 7, \"sha\": \"$SHA\", \"state\": \"opened\"}},
         \"PUT $MR/7/merge\": {\"body\": {\"iid\": 7, \"state\": \"merged\"}}}"
forge pr-merge 7 --sha 0123456 --squash --delete-branch --subject '✨ [feat] x: y' --body-file "$TMP/msg.md"
[ "$(field PUT "$MR/7/merge" sha)" = "$SHA" ] || fail "merge sha: $(cat "$TMP/fake/calls.log")"
[ "$(field PUT "$MR/7/merge" squash)" = true ] || fail "merge squash"
[ "$(field PUT "$MR/7/merge" should_remove_source_branch)" = true ] || fail "merge delete-branch"
[ "$(field PUT "$MR/7/merge" squash_commit_message)" = "$(printf '✨ [feat] x: y\n\nCloses #12')" ] || fail "squash message"
[ "$(calls PUT "$MR/7/merge")" = 1 ] || fail "merge PUT count"
ok "pr-merge: PUT pinned to the full sha with squash, delete-branch and message"

forge pr-merge 7 --sha "$SHA" --merge
[ "$(field PUT "$MR/7/merge" squash)" = false ] || fail "--merge should send squash=false"
[ "$(field PUT "$MR/7/merge" should_remove_source_branch)" = '<absent>' ] || fail "delete-branch sent unasked"
ok "pr-merge --merge: squash=false, branch kept"

: > "$TMP/fake/calls.log"
rc=0; forge pr-merge 7 --sha fedcba9876 --squash 2>"$TMP/err" || rc=$?
[ "$rc" = 4 ] || fail "moved head before PUT should exit 4, got $rc"
[ "$(calls PUT "$MR/7/merge")" = 0 ] || fail "merged although head moved"
ok "pr-merge: head already moved → exit 4, no PUT"

routes "{\"GET $MR/7\": {\"body\": {\"iid\": 7, \"sha\": \"$SHA\"}},
         \"PUT $MR/7/merge\": {\"status\": 1, \"body\": {\"message\": \"409 Conflict: SHA does not match HEAD of source branch: ffff\"}}}"
rc=0; forge pr-merge 7 --sha "$SHA" --squash 2>"$TMP/err" || rc=$?
[ "$rc" = 4 ] || fail "409 should exit 4, got $rc: $(cat "$TMP/err")"
[ "$(calls PUT "$MR/7/merge")" = 1 ] || fail "409 merge PUT was retried"
ok "pr-merge: 409 (pushed during the gate) → exit 4, PUT not retried"

routes "{\"GET $MR/7\": {\"body\": {\"iid\": 7, \"sha\": \"$SHA\"}},
         \"PUT $MR/7/merge\": {\"status\": 1, \"body\": {\"message\": \"405 Method Not Allowed: pipeline must succeed\"}}}"
rc=0; forge pr-merge 7 --sha "$SHA" --squash 2>"$TMP/err" || rc=$?
[ "$rc" = 69 ] || fail "405 should exit 69, got $rc"
grep -q 'pipeline must succeed' "$TMP/err" || fail "405 message not shown: $(cat "$TMP/err")"
[ "$(calls PUT "$MR/7/merge")" = 1 ] || fail "405 merge PUT was retried"
ok "pr-merge: 405 (not mergeable) → exit 69 with GitLab's message, PUT not retried"

routes "{\"GET $MR/7\": {\"body\": {\"iid\": 7, \"sha\": \"$SHA\"}},
         \"PUT $MR/7/merge\": {\"status\": 1, \"body\": {\"message\": \"422 Unprocessable: Branch cannot be merged\"}}}"
rc=0; forge pr-merge 7 --sha "$SHA" 2>/dev/null || rc=$?
[ "$rc" = 69 ] && [ "$(calls PUT "$MR/7/merge")" = 1 ] || fail "422 should exit 69 once, got $rc"
routes "{\"GET $MR/7\": {\"body\": {\"iid\": 7, \"sha\": \"$SHA\"}},
         \"PUT $MR/7/merge\": {\"body\": {\"iid\": 7, \"state\": \"opened\"}}}"
rc=0; forge pr-merge 7 --sha "$SHA" 2>/dev/null || rc=$?
[ "$rc" = 69 ] || fail "200 without merged state must not count as merged, got $rc"
ok "pr-merge: 422 → 69; a response that is not 'merged' → 69"

rc=0; forge pr-merge 7 --sha "$SHA" --rebase 2>/dev/null || rc=$?
[ "$rc" = 64 ] || fail "--rebase should be 64, got $rc"
rc=0; forge pr-merge 7 --squash 2>/dev/null || rc=$?
[ "$rc" = 64 ] || fail "missing --sha should be 64, got $rc"
ok "pr-merge: --rebase unsupported and --sha required (exit 64)"

# ── auth-check ───────────────────────────────────────────────────────────
routes '{}'
forge auth-check || fail "auth-check should pass when logged in"
touch "$TMP/fake/auth-fail"
rc=0; forge auth-check 2>"$TMP/err" || rc=$?
rm -f "$TMP/fake/auth-fail"
[ "$rc" = 69 ] || fail "auth-check fail should be 69, got $rc"
grep -q 'glab auth login --hostname gitlab.example.com' "$TMP/err" || fail "auth-check fix text: $(cat "$TMP/err")"
ok "auth-check: 69 with 'glab auth login --hostname <host>'"

# ── pr-list ──────────────────────────────────────────────────────────────
routes "{\"GET $MR?state=merged&source_branch=sb%2Fissue-12&search=fix%20x&$PG\": {\"body\": [
   {\"iid\": 8, \"title\": \"t\", \"description\": \"Fixes #12, closes #13 and refs #14\", \"state\": \"merged\", \"draft\": false,
    \"source_branch\": \"sb/issue-12\", \"target_branch\": \"main\", \"sha\": \"s\", \"web_url\": \"u\", \"detailed_merge_status\": \"not_open\"}]},
  \"GET $MR?state=opened&per_page=2&page=1\": {\"body\": [{\"iid\": 1}, {\"iid\": 2}]},
  \"GET $MR?state=opened&per_page=2&page=2\": {\"body\": [{\"iid\": 3}, {\"iid\": 4}]}}"
OUT=$(forge pr-list --state merged --head sb/issue-12 --search 'fix x')
[ "$OUT" = '[{"number":8,"title":"t","state":"MERGED","isDraft":false,"headRefName":"sb/issue-12","baseRefName":"main","headRefOid":"s","url":"u","mergeable":"UNKNOWN","closingIssues":[12,13]}]' ] \
  || fail "pr-list: $OUT"
[ "$(SB_GL_PER_PAGE=2 forge pr-list --limit 3 | jq -c '[.[].number]')" = '[1,2,3]' ] || fail "pr-list limit"
ok "pr-list: state/head/search filters, no body, --limit across pages"

# ── comments, default branch ─────────────────────────────────────────────
routes "{\"GET $MR/7/notes?sort=asc&order_by=created_at&$PG\": {\"body\": [
   {\"id\": 1, \"system\": true, \"body\": \"marked as ready\", \"author\": {\"username\": \"bot\"}, \"created_at\": \"2026-01-01T00:00:00Z\"},
   {\"id\": 2, \"system\": false, \"body\": \"done\", \"author\": {\"username\": \"owner\"}, \"created_at\": \"2026-01-02T00:00:00Z\"}]},
  \"GET $MR/7\": {\"body\": {\"iid\": 7, \"web_url\": \"https://g/mr/7\"}},
  \"POST $MR/7/notes\": {\"body\": {\"id\": 99}},
  \"GET $P\": {\"body\": {\"default_branch\": \"trunk\"}}}"
[ "$(forge pr-comments 7)" = '[{"author":"owner","body":"done","createdAt":"2026-01-02T00:00:00Z"}]' ] || fail "pr-comments"
printf 'hello\n' > "$TMP/c.md"
[ "$(forge pr-comment 7 "$TMP/c.md")" = '{"url":"https://g/mr/7#note_99"}' ] || fail "pr-comment"
[ "$(field POST "$MR/7/notes" body)" = hello ] || fail "pr-comment body"
[ "$(forge default-branch)" = trunk ] || fail "default-branch"
ok "pr-comments (no system notes), pr-comment, default-branch"

# ── only sb_glab_api / glab auth status talk to GitLab ───────────────────
if grep -nE '(^|[;&|(]|\$\(|then|do|!)[[:space:]]*glab ' "$ROOT/scripts/super-board-forge-gitlab-mr.sh" \
     | grep -v 'glab auth status' >&2; then
  fail "MR verbs call glab directly instead of sb_glab_api"
fi
ok "MR verbs reach GitLab only through sb_glab_api"

echo "PASS: $pass GitLab MR forge checks"
