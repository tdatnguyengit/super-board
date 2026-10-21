#!/usr/bin/env bash
# Tests super-board-forge.sh → super-board-forge-github.sh against a fake gh. No network.
#
# Pins the contract in docs/forge-contract.md for the GitHub backend: each verb's
# JSON keys, and the exit codes callers route on (claim lost 2, head moved 4,
# usage 64, unknown forge 66, write failed 69, reads halted 79).
set -euo pipefail
cd "$(dirname "$0")"
FORGE="$PWD/../scripts/super-board-forge.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ✅ $1"; }

SHA=0123456789abcdef0123456789abcdef01234567
OTHER=fedcba9876543210fedcba9876543210fedcba98
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Fake gh: logs every call, answers by "<cmd> <sub>". Switches:
#   FAKE_ASSIGNEES  logins the REST assignee add answers with (space separated)
#   FAKE_MERGE      ok | moved | fail
#   FAKE_CHECKS     pass | fail | pending | none
#   FAKE_FAIL       a "<cmd> <sub>" (CLI) or "<METHOD> <last path segment>" (REST) that exits 1
printf '%s\n' "$*" >> "$FAKE_LOG"
[ "${FAKE_FAIL:-}" != "$1 ${2:-}" ] || { echo "HTTP 502: boom" >&2; exit 1; }
q=""; for a in "$@"; do case "$a" in query=*) q="${a#query=}" ;; esac; done
# REST: "<METHOD> <path>" (POST when a field is passed, like gh).
if [ "$1" = api ]; then
  path=""; method=GET
  for a in "$@"; do case "$a" in repos/*) path="$a" ;; -f|-F) [ "$method" = GET ] && method=POST ;; esac; done
  prev=""; for a in "$@"; do [ "$prev" = -X ] && method="$a"; prev="$a"; done
  if [ -n "$path" ]; then
    [ "${FAKE_FAIL:-}" != "$method ${path##*/}" ] || { echo "HTTP 502: boom" >&2; exit 1; }
    case "$method $path" in
      "GET repos/acme/app/issues/5") echo '{"number":5,"title":"Five","body":null,"state":"open","labels":[{"name":"bug","id":1}],"assignees":[{"login":"robot"}],"html_url":"https://github.com/acme/app/issues/5"}' ;;
      "GET repos/acme/app/issues/"*/comments) echo '[[{"id":1,"user":{"login":"ann","type":"User"},"body":"first","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}],[{"id":2,"user":{"login":"bob","type":"User"},"body":"second","created_at":"2026-01-02T00:00:00Z","updated_at":"2026-01-02T00:00:00Z"}]]' ;;
      "GET repos/acme/app/collaborators/ann/permission") echo '{"permission":"write"}' ;;
      "GET repos/acme/app/pulls/78/files") echo '[[{"filename":"a.txt","additions":1},{"filename":"b/c.md","additions":2}]]' ;;
      "POST repos/acme/app/issues/"*/comments) echo '{"id":1,"html_url":"https://github.com/acme/app/issues/5#issuecomment-1"}' ;;
      "POST repos/acme/app/issues/5/assignees")
        a=""; for l in ${FAKE_ASSIGNEES:-robot}; do a="$a{\"login\":\"$l\"},"; done
        echo "{\"number\":5,\"assignees\":[${a%,}]}" ;;
      "DELETE repos/acme/app/issues/5/labels/"*) [ "${path##*/}" != gone ] || { echo "gh: Label does not exist (HTTP 404)" >&2; exit 1; } ;;
      "POST repos/acme/app/issues/5/labels"|"DELETE repos/acme/app/issues/5/assignees"|"PATCH repos/acme/app/issues/5") echo '{}' ;;
      *) echo "unexpected REST call: $method $path" >&2; exit 1 ;;
    esac
    exit 0
  fi
fi
case "$1 ${2:-}" in
  "api user") echo "robot" ;;
  "api rate_limit") echo '{"resources":{"core":{"limit":5000,"remaining":4900,"reset":1700000000},"graphql":{"limit":5000,"remaining":4999,"reset":1700000000}}}' ;;
  "api graphql")
    case "$q" in
      *rateLimit*) echo '{"data":{"rateLimit":{"limit":5000,"remaining":1234,"used":3766,"resetAt":"2023-11-14T22:13:20Z"}}}' ;;
      *'items(first:100'*) echo '[{"data":{"repositoryOwner":{"projectV2":{"items":{"totalCount":2,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
        {"id":"PVTI_1","fieldValueByName":{"name":"Ready"},"content":{"__typename":"Issue","number":5,"title":"Five","url":"https://github.com/acme/app/issues/5","repository":{"nameWithOwner":"acme/app"},"labels":{"nodes":[{"name":"bug"}]}}},
        {"id":"PVTI_2","fieldValueByName":null,"content":{"__typename":"DraftIssue","title":"Draft"}}]}}}}}]' ;;
      *issueOrPullRequest*) echo '{"data":{"repository":{"issueOrPullRequest":{"projectItems":{"nodes":[{"id":"PVTI_1","project":{"number":15,"owner":{"login":"acme"}},"fieldValueByName":{"name":"Ready"}}]}}}}}' ;;
      *'field(name:"Status")'*) echo '{"data":{"repositoryOwner":{"projectV2":{"id":"PVT_1","field":{"id":"F_1","options":[{"id":"o_r","name":"Ready"},{"id":"o_q","name":"QA"}]}}}}}' ;;
      *mutation*) echo '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_1"}}}}' ;;
      *) exit 1 ;;
    esac ;;
  "issue list") echo '[{"number":5,"title":"Five","body":"b","state":"OPEN","labels":[],"assignees":[],"url":"u"}]' ;;
  "issue create") echo "https://github.com/acme/app/issues/77" ;;
  "pr ready") exit 0 ;;
  "pr create") echo "https://github.com/acme/app/pull/78" ;;
  "pr view")
    case "$*" in
      *closingIssuesReferences*) echo "{\"number\":78,\"title\":\"T\",\"body\":\"B\",\"state\":\"OPEN\",\"isDraft\":true,\"headRefName\":\"loop/issue-5\",\"baseRefName\":\"main\",\"headRefOid\":\"$FAKE_SHA\",\"url\":\"u\",\"mergeable\":\"\",\"closingIssuesReferences\":[{\"number\":5}],\"labels\":[{\"name\":\"bug\"}],\"additions\":3,\"deletions\":1,\"changedFiles\":2}" ;;
      *headRefOid*) if [ "${FAKE_MERGE:-ok}" = moved ]; then echo "$FAKE_OTHER"; else echo "$FAKE_SHA"; fi ;;
      *) exit 1 ;;
    esac ;;
  "pr list") echo "[{\"number\":78,\"title\":\"T\",\"state\":\"OPEN\",\"isDraft\":false,\"headRefName\":\"h\",\"baseRefName\":\"main\",\"headRefOid\":\"$FAKE_SHA\",\"url\":\"u\",\"mergeable\":\"MERGEABLE\",\"closingIssuesReferences\":[]}]" ;;
  "pr diff") printf 'diff --git a/a.txt b/a.txt\n' ;;
  "pr merge")
    case "${FAKE_MERGE:-ok}" in
      ok) exit 0 ;;
      moved) echo "GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)" >&2; exit 1 ;;
      *) echo "GraphQL: Pull request is not mergeable" >&2; exit 1 ;;
    esac ;;
  "pr checks")
    case "${FAKE_CHECKS:-pass}" in
      pass) echo '[{"name":"ci","bucket":"pass","link":"https://ci/1"},{"name":"lint","bucket":"skipping","link":""}]' ;;
      fail) echo '[{"name":"ci","bucket":"fail","link":"https://ci/1"},{"name":"lint","bucket":"pending","link":""}]'; exit 1 ;;
      pending) echo '[{"name":"ci","bucket":"pending","link":"https://ci/1"}]'; exit 8 ;;
      none) echo "no checks reported on the 'loop/issue-5' branch" >&2; exit 1 ;;
    esac ;;
  "repo view") echo "main" ;;
  "auth status") echo "  - Token scopes: 'gist', 'project', 'repo'" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
cat > "$TMP/c.json" <<'EOF'
{"project":{"owner":"acme","number":15},"repo":{"path":".","remote":"https://github.com/acme/app"}}
EOF
echo "body" > "$TMP/body.md"
export PATH="$TMP/bin:$PATH" FAKE_LOG="$TMP/log" FAKE_SHA="$SHA" FAKE_OTHER="$OTHER" \
       SB_CARD_CACHE_DIR="$TMP/cache" SB_GITHUB_HALT_FILE="$TMP/halt.json" SB_GITHUB_RETRY_DELAY=0
unset SB_FORGE SB_CONFIG SB_FORGE_REPO
f() { "$FORGE" --config "$TMP/c.json" "$@"; }
rc() { local r=0; "$@" >"$TMP/out" 2>"$TMP/err" || r=$?; echo "$r"; }
keys() { jq -c "$1" "$TMP/out"; }
reset_log() { : > "$TMP/log"; }

# ── entry point
[ "$(SB_FORGE=svn rc f whoami)" = 66 ] || fail "unknown forge (SB_FORGE) should exit 66"
echo '{"forge":"bitbucket"}' > "$TMP/bad.json"
[ "$(rc "$FORGE" --config "$TMP/bad.json" whoami)" = 66 ] || fail "unknown forge (config) should exit 66"
[ "$(rc "$FORGE" --config "$TMP/nope.json" whoami)" = 66 ] || fail "missing config should exit 66"
[ "$(rc f)" = 64 ] || fail "no verb should exit 64"
[ "$(rc f frobnicate)" = 64 ] || fail "unknown verb should exit 64"
[ "$(rc f issue-view abc)" = 64 ] || fail "non-numeric issue should exit 64"
ok "entry point: unknown forge 66, usage 64"

# ── board verbs delegate to super-board-card.sh (same GraphQL cost)
[ "$(rc f items)" = 0 ] || fail "items: $(cat "$TMP/err")"
[ "$(keys '[.totalCount, (.items|length), (.items[0]|keys), (.items[0].content|keys), (.items[1]|has("status"))]')" = \
  '[2,2,["content","id","labels","status","title"],["number","repository","title","type","url"],false]' ] || fail "items shape: $(cat "$TMP/out")"
ok "items: {items:[{id,status,labels,title,content}],totalCount}"
reset_log
[ "$(rc f move 5 QA)" = 0 ] && [ "$(cat "$TMP/out")" = "moved #5 → QA" ] || fail "move: $(cat "$TMP/out" "$TMP/err")"
[ "$(grep -c '^api graphql' "$TMP/log")" = 3 ] || fail "cold move must stay 2 reads + 1 mutation: $(cat "$TMP/log")"
reset_log; f move 5 Ready >/dev/null
[ "$(grep -c '^api graphql' "$TMP/log")" = 1 ] || fail "warm move must stay 1 mutation: $(cat "$TMP/log")"
ok "move: same call count as super-board-card.sh"
[ "$(rc f status 5)" = 0 ] && [ "$(cat "$TMP/out")" = Ready ] || fail "status: $(cat "$TMP/out")"
[ "$(rc f move 5 Shipping)" = 3 ] || fail "missing column should exit 3"
ok "status prints the column; missing column exits 3"

# ── claim / release / whoami
[ "$(rc f whoami)" = 0 ] && [ "$(cat "$TMP/out")" = robot ] || fail "whoami"
reset_log
[ "$(FAKE_ASSIGNEES=robot rc f claim 5 @me)" = 0 ] || fail "claim of a free issue should exit 0: $(cat "$TMP/err")"
grep -q -- '^api repos/acme/app/issues/5/assignees -f assignees\[\]=robot' "$TMP/log" || fail "claim must add the resolved login over REST: $(cat "$TMP/log")"
[ "$(grep -c '^api graphql' "$TMP/log")" = 0 ] || fail "claim must cost no GraphQL points"
[ "$(FAKE_ASSIGNEES="Robot[bot]" rc f claim 5 robot)" = 0 ] || fail "our own [bot] login counts as ours"
reset_log
[ "$(FAKE_ASSIGNEES="robot alice" rc f claim 5 robot)" = 2 ] || fail "claim held by someone else should exit 2"
[ "$(cat "$TMP/out")" = alice ] || fail "lost claim prints the holder, got $(cat "$TMP/out")"
grep -q -- '-X DELETE repos/acme/app/issues/5/assignees -f assignees\[\]=robot' "$TMP/log" || fail "a lost claim undoes our add: $(cat "$TMP/log")"
[ "$(FAKE_ASSIGNEES="alice" rc f claim 5 robot)" = 69 ] || fail "an assignment GitHub silently dropped is a failed write (69)"
[ "$(rc f release 5 robot)" = 0 ] || fail "release"
ok "claim 0 / lost 2 with holder; release; whoami"

# ── issues
[ "$(rc f issue-view 5)" = 0 ] || fail "issue-view"
[ "$(keys '[keys, .labels, .assignees, .state, .body]')" = '[["assignees","body","labels","number","state","title","url"],["bug"],["robot"],"OPEN",""]' ] || fail "issue-view shape: $(cat "$TMP/out")"
[ "$(rc f issue-list --label bug --state all)" = 0 ] || fail "issue-list"
[ "$(keys '.[0] | keys')" = '["assignees","body","labels","number","state","title","url"]' ] || fail "issue-list shape"
grep -q -- '--state all --limit 200 --label bug' "$TMP/log" || fail "issue-list flags: $(tail -1 "$TMP/log")"
[ "$(rc f issue-list --state bogus)" = 64 ] || fail "issue-list bad state is usage"
[ "$(rc f issue-comments 5)" = 0 ] && [ "$(keys '[(.[0] | keys), .[0].author, .[1].body, .[0].authorType]')" = '[["author","authorType","body","createdAt","id","updatedAt"],"ann","second","User"]' ] || fail "issue-comments shape: $(cat "$TMP/out")"
[ "$(rc f issue-comment 5 "$TMP/body.md")" = 0 ] && [ "$(keys 'keys')" = '["url"]' ] || fail "issue-comment shape"
[ "$(rc f issue-create --title T --body-file "$TMP/body.md" --label bug)" = 0 ] || fail "issue-create"
[ "$(keys '[keys, .number]')" = '[["number","url"],77]' ] || fail "issue-create shape: $(cat "$TMP/out")"
reset_log
[ "$(rc f issue-edit 5 --add-label a --remove-label 'b c' --remove-label gone --body-file "$TMP/body.md")" = 0 ] && [ ! -s "$TMP/out" ] || fail "issue-edit prints nothing: $(cat "$TMP/err")"
grep -q -- '-X DELETE repos/acme/app/issues/5/labels/b%20c' "$TMP/log" || fail "label names are URL-encoded: $(cat "$TMP/log")"
[ "$(grep -c '^api graphql' "$TMP/log")" = 0 ] || fail "issue-edit must cost no GraphQL points"
reset_log
[ "$(rc f issue-close 5 --reason not_planned)" = 0 ] || fail "issue-close"
grep -q -- 'state_reason=not_planned' "$TMP/log" || fail "issue-close passes the reason: $(cat "$TMP/log")"
[ "$(FAKE_FAIL="POST comments" rc f issue-comment 5 "$TMP/body.md")" = 69 ] || fail "a failed write exits 69"
[ "$(rc f permission ann)" = 0 ] && [ "$(cat "$TMP/out")" = write ] || fail "permission: $(cat "$TMP/out" "$TMP/err")"
ok "issue verbs: shapes pinned, permission, write failure 69"

# ── pull requests
[ "$(rc f pr-create --head h --base main --title T --body-file "$TMP/body.md" --draft)" = 0 ] || fail "pr-create"
[ "$(keys '[keys, .number]')" = '[["number","url"],78]' ] || fail "pr-create shape"
[ "$(rc f pr-view 78)" = 0 ] || fail "pr-view: $(cat "$TMP/err")"
[ "$(keys '[keys, .mergeable, .closingIssues, .labels, .changedFiles]')" = \
  '[["additions","baseRefName","body","changedFiles","closingIssues","deletions","headRefName","headRefOid","isDraft","labels","mergeCommit","mergeable","number","state","title","url"],"UNKNOWN",[5],["bug"],2]' ] || fail "pr-view shape: $(cat "$TMP/out")"
[ "$(rc f pr-list --head h)" = 0 ] || fail "pr-list"
[ "$(keys '[(.[0] | keys), (.[0] | has("body"))]')" = \
  '[["additions","baseRefName","changedFiles","closingIssues","deletions","headRefName","headRefOid","isDraft","labels","mergeCommit","mergeable","number","state","title","url"],false]' ] || fail "pr-list shape: $(cat "$TMP/out")"
[ "$(rc f pr-diff 78)" = 0 ] && grep -q '^diff --git' "$TMP/out" || fail "pr-diff is raw text"
[ "$(rc f pr-files 78)" = 0 ] && [ "$(keys '.')" = '["a.txt","b/c.md"]' ] || fail "pr-files shape"
[ "$(rc f pr-comments 78)" = 0 ] && [ "$(keys '[(.[0] | keys), length]')" = '[["author","authorType","body","createdAt","id","updatedAt"],2]' ] || fail "pr-comments shape"
[ "$(rc f pr-comment 78 "$TMP/body.md")" = 0 ] && [ "$(keys 'keys')" = '["url"]' ] || fail "pr-comment shape"
[ "$(rc f pr-ready 78)" = 0 ] || fail "pr-ready"
ok "pr verbs: shapes pinned"

[ "$(rc f pr-merge 78 --sha "$SHA")" = 64 ] || fail "pr-merge outside the merge gate must be refused (64)"
grep -q '^pr merge' "$TMP/log" && fail "a refused pr-merge must not reach gh"
export SB_MERGE_GATE=1
reset_log
[ "$(rc f pr-merge 78 --sha "$SHA" --squash --delete-branch --subject S --body-file "$TMP/body.md")" = 0 ] || fail "pr-merge ok"
grep -q -- "--match-head-commit $SHA" "$TMP/log" || fail "pr-merge must pin --match-head-commit: $(cat "$TMP/log")"
grep -q -- "--subject S" "$TMP/log" || fail "pr-merge passes --subject"
[ "$(FAKE_MERGE=moved rc f pr-merge 78 --sha "$SHA")" = 4 ] || fail "head moved should exit 4"
[ "$(FAKE_MERGE=refused rc f pr-merge 78 --sha "$SHA")" = 69 ] || fail "other merge refusal should exit 69"
[ "$(rc f pr-merge 78)" = 64 ] || fail "pr-merge without --sha is usage"
unset SB_MERGE_GATE
ok "pr-merge: gate-only, --match-head-commit, head moved 4, refused 69, no sha 64"

for c in pass:SUCCESS fail:FAILURE pending:PENDING none:NONE; do
  [ "$(FAKE_CHECKS="${c%%:*}" rc f checks 78)" = 0 ] || fail "checks ${c%%:*}: $(cat "$TMP/err")"
  [ "$(keys '.state')" = "\"${c##*:}\"" ] || fail "checks ${c%%:*} → ${c##*:}, got $(cat "$TMP/out")"
done
FAKE_CHECKS=pass f checks 78 > "$TMP/out"
[ "$(keys '[keys, (.checks[0] | keys)]')" = '[["checks","state"],["name","state","url"]]' ] || fail "checks shape"
ok "checks: {state, checks:[{name,state,url}]} for pass/fail/pending/none"

# ── repo and quota
[ "$(rc f default-branch)" = 0 ] && [ "$(cat "$TMP/out")" = main ] || fail "default-branch"
[ "$(rc f auth-check)" = 0 ] || fail "auth-check"
[ "$(rc f quota)" = 0 ] || fail "quota: $(cat "$TMP/err")"
[ "$(keys '[keys, .remaining, .kind, (.resetAt|type)]')" = '[["kind","limit","remaining","resetAt"],1234,"graphql","number"]' ] || fail "quota shape: $(cat "$TMP/out")"
ok "default-branch, auth-check, quota {remaining,limit,resetAt,kind}"

# ── reads halt with 79 once the run's halt file exists
echo '{"reason":"test"}' > "$TMP/halt.json"
[ "$(rc f issue-view 5)" = 79 ] || fail "a halted run's read should exit 79"
rm -f "$TMP/halt.json"
ok "reads halted → 79"

echo "PASS: $pass forge-github checks"
