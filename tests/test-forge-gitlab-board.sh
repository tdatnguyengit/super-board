#!/usr/bin/env bash
# Tests the GitLab board backend (super-board-forge-gitlab-board.sh) and
# super-board-gitlab-board-setup.sh against the fake glab. No network.
#
# The board on GitLab Free is one plain label per column and Done = closed, so
# the point here is exclusivity: every move is ONE PUT that adds the new column
# label and removes all others, and a card never ends up with two.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
FORGE="$ROOT/scripts/super-board-forge.sh"
SETUP="$ROOT/scripts/super-board-gitlab-board-setup.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ✅ $1"; }

mkdir -p "$TMP/bin" "$TMP/glab"
cat > "$TMP/bin/glab" <<EOF
#!/usr/bin/env bash
exec python3 "$ROOT/tests/fixtures/glab/fake_glab.py" "\$@"
EOF
chmod +x "$TMP/bin/glab"
export PATH="$TMP/bin:$PATH" FAKE_GLAB_DIR="$TMP/glab" SB_GLAB_BACKOFF=0 SB_GLAB_CLAIM_SETTLE=0 SB_GLAB_PER_PAGE=100
unset SB_FORGE SB_CONFIG SB_FORGE_HOST SB_GITLAB_PROJECT SB_GITLAB_PREFIX 2>/dev/null || true
CFG="$TMP/cfg.json"
echo '{"forge":"gitlab","gitlab":{"project":"acme/app","column_label_prefix":"sb::"}}' > "$CFG"

P='projects/acme%2Fapp'
COLS='["Backlog","Ready","Building","QA","Review","Blocked"]'
forge() { "$FORGE" --config "$CFG" "$@"; }
reset() { echo '{}' > "$TMP/glab/routes.json"; : > "$TMP/glab/calls.log"; rm -f "$TMP/glab/.served.json"; }
route() {  # route "METHOD path" <body-json> [status] — appends to a served-in-order list when repeated
  local key="$1" body="$2" st="${3:-0}"
  jq --arg k "$key" --argjson b "$body" --argjson s "$st" '
    .[$k] = (if .[$k] == null then {status:$s, body:$b}
             elif (.[$k] | type) == "array" then .[$k] + [{status:$s, body:$b}]
             else [.[$k], {status:$s, body:$b}] end)' "$TMP/glab/routes.json" > "$TMP/r" && mv "$TMP/r" "$TMP/glab/routes.json"
}
calls() { jq -c --arg m "$1" 'select(.method == $m)' "$TMP/glab/calls.log"; }
ncalls() { calls "$1" | wc -l | tr -d ' '; }
issue() {  # issue <iid> <state> <labels-json> [assignees-json]
  jq -cn --argjson i "$1" --arg s "$2" --argjson l "$3" --argjson a "${4:-[]}" \
    '{id: (1000 + $i), iid: $i, title: "Issue \($i)", description: "body \($i)", state: $s,
      labels: $l, assignees: $a, web_url: "https://gitlab.com/acme/app/-/issues/\($i)"}'
}
# Column labels after applying a PUT's add_labels / remove_labels to <labels-json>.
apply_put() {
  jq -cn --argjson l "$1" --argjson put "$2" '
    ($put.fields.remove_labels // "" | split(",") | map(select(length > 0))) as $rm
    | ($put.fields.add_labels // "" | split(",") | map(select(length > 0))) as $add
    | ([ $l[] | select(IN($rm[]) | not) ] + $add) | unique'
}
colcount() { jq -n --argjson l "$1" --argjson c "$COLS" '[ $l[] | select(startswith("sb::")) | ltrimstr("sb::") | select(IN($c[])) ] | length'; }

# 1 — Ready → Building → QA → Review → Done: one PUT each, always one column label.
LABELS='["sb::Ready","bug"]'; STATE=opened
for COL in Building QA Review Done; do
  reset
  route "GET $P/issues/5" "$(issue 5 "$STATE" "$LABELS")"
  route "PUT $P/issues/5" '{}'
  OUT=$(forge move 5 "$COL")
  [ "$OUT" = "moved #5 → $COL" ] || fail "move $COL output: $OUT"
  [ "$(ncalls PUT)" = 1 ] || fail "move $COL should be one PUT: $(cat "$TMP/glab/calls.log")"
  PUT=$(calls PUT)
  if [ "$COL" = Done ]; then
    echo "$PUT" | jq -e '.fields.state_event == "close" and (.fields | has("add_labels") | not)' >/dev/null || fail "Done must close: $PUT"
    echo "$PUT" | jq -e '.fields.remove_labels | split(",") | (index("sb::Review") == null) and length == 5' >/dev/null \
      || fail "Done keeps the last column label, drops the other 5: $PUT"
    STATE=closed
  else
    echo "$PUT" | jq -e --arg c "sb::$COL" '.fields.add_labels == $c and (.fields | has("state_event") | not)' >/dev/null || fail "move $COL add: $PUT"
    echo "$PUT" | jq -e --arg c "sb::$COL" '.fields.remove_labels | split(",") | (index($c) == null) and length == 5' >/dev/null \
      || fail "move $COL must remove every other column label: $PUT"
  fi
  LABELS=$(apply_put "$LABELS" "$PUT")
  [ "$(colcount "$LABELS")" = 1 ] || fail "after $COL the card carries $(colcount "$LABELS") column labels: $LABELS"
  echo "$LABELS" | jq -e 'index("bug") != null' >/dev/null || fail "non-column label lost: $LABELS"
done
ok "Ready → Building → QA → Review → Done: one PUT each, exactly one column label, Done closes"

# 2 — out of Done reopens in the same PUT.
reset
route "GET $P/issues/5" "$(issue 5 closed '["sb::Review"]')"
route "PUT $P/issues/5" '{}'
forge move 5 Building >/dev/null
calls PUT | jq -e '.fields.state_event == "reopen" and .fields.add_labels == "sb::Building"' >/dev/null || fail "move out of Done must reopen: $(calls PUT)"
ok "moving a closed card out of Done reopens it"

# 3 — unknown column → 3, nothing written.
reset
RC=0; forge move 5 Shipping >/dev/null 2>&1 || RC=$?
[ "$RC" = 3 ] || fail "unknown column should exit 3 (rc=$RC)"
[ "$(ncalls PUT)" = 0 ] || fail "unknown column must not write"
ok "unknown column → 3"

# 4 — status: label, Done = closed, none = empty line, double = latest + warning.
reset
route "GET $P/issues/1" "$(issue 1 opened '["sb::QA","x"]')"
route "GET $P/issues/2" "$(issue 2 closed '["sb::Review"]')"
route "GET $P/issues/3" "$(issue 3 opened '["x"]')"
route "GET $P/issues/4" "$(issue 4 opened '["sb::Blocked","sb::Ready"]')"
[ "$(forge status 1)" = QA ] || fail "status QA"
[ "$(forge status 2)" = Done ] || fail "status closed → Done"
OUT=$(forge status 3); [ -z "$OUT" ] || fail "no column → empty: '$OUT'"
OUT=$(forge status 4 2>"$TMP/err"); [ "$OUT" = Blocked ] || fail "double → latest in board order: $OUT"
grep -q 'column labels' "$TMP/err" || fail "double must warn on stderr"
ok "status: label, closed = Done, none = empty, double = latest + warning"

# 5 — items: paged per column label, deduped, same item shape as super-board-card.sh.
reset
export SB_GLAB_PER_PAGE=2
q() { echo "GET $P/issues?labels=$(jq -rn --arg v "sb::$1" '$v|@uri')&state=all&order_by=created_at&sort=asc&per_page=2&page=$2"; }
route "$(q Ready 1)" "[$(issue 12 opened '["sb::Ready","qa"]'),$(issue 13 opened '["sb::Ready","sb::Blocked"]')]"
route "$(q Ready 2)" "[$(issue 14 opened '["sb::Ready"]')]"
route "$(q Blocked 1)" "[$(issue 13 opened '["sb::Ready","sb::Blocked"]')]"
route "$(q Review 1)" "[$(issue 20 closed '["sb::Review"]')]"
for c in Backlog Building QA; do route "$(q "$c" 1)" '[]'; done
OUT=$(forge items)
export SB_GLAB_PER_PAGE=100
echo "$OUT" | jq -e '.totalCount == 4 and (.items | length) == 4' >/dev/null || fail "items count (dedup + 2 pages): $OUT"
echo "$OUT" | jq -e '[.items[].content.number] == [12,13,14,20]' >/dev/null || fail "items order/dedupe: $OUT"
echo "$OUT" | jq -e '.items[0] == {id:"1012",title:"Issue 12",status:"Ready",labels:["sb::Ready","qa"],
  content:{type:"Issue",title:"Issue 12",number:12,url:"https://gitlab.com/acme/app/-/issues/12",repository:"acme/app"}}' >/dev/null \
  || fail "item shape: $(echo "$OUT" | jq -c '.items[0]')"
echo "$OUT" | jq -e '.items[1].status == "Blocked" and .items[3].status == "Done"' >/dev/null || fail "items status: $OUT"
grep -q 'per_page=2&page=2' "$TMP/glab/calls.log" || fail "second page not read"
grep -q 'labels=sb%3A%3AReady&state=all.*page=3' "$TMP/glab/calls.log" && fail "read past a short page"
ok "items: paged, deduped, Done = closed"

# 5b — same cards on a GitHub board give the same items (super-board-card.sh).
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
cat "$FAKE_GH_ITEMS"
EOF
chmod +x "$TMP/bin/gh"
jq -n '[{data:{repositoryOwner:{projectV2:{items:{totalCount:1,pageInfo:{hasNextPage:false,endCursor:null},nodes:[
  {id:"PVTI_12",fieldValueByName:{name:"Ready"},content:{__typename:"Issue",number:12,title:"Issue 12",
   url:"https://gitlab.com/acme/app/-/issues/12",repository:{nameWithOwner:"acme/app"},labels:{nodes:[{name:"sb::Ready"},{name:"qa"}]}}}]}}}}}]' > "$TMP/gh-items.json"
GH=$(FAKE_GH_ITEMS="$TMP/gh-items.json" SB_CARD_CACHE_DIR="$TMP/cache" SB_GITHUB_HALT_FILE="$TMP/halt.json" SB_GITHUB_RETRY_DELAY=0 \
  "$ROOT/scripts/super-board-card.sh" --owner acme --number 1 --repo acme/app items)
GL_ITEM=$(echo "$OUT" | jq -c '.items[0] | del(.id)')
GH_ITEM=$(echo "$GH" | jq -c '.items[0] | del(.id)')
[ "$GL_ITEM" = "$GH_ITEM" ] || fail "GitLab item differs from GitHub item:
 gl $GL_ITEM
 gh $GH_ITEM"
[ "$(echo "$OUT" | jq -c 'keys')" = "$(echo "$GH" | jq -c 'keys')" ] || fail "top-level keys differ"
ok "items match super-board-card.sh for the same card"

# 6 — claim: free → assign + re-read; race lost → 2 + winner; held → 2; ours → 0.
ME='{"id":7,"username":"alice"}'
reset
route "GET user" "$ME"
route "GET $P/issues/5" "$(issue 5 opened '[]' '[]')"
route "GET $P/issues/5" "$(issue 5 opened '[]' '[{"id":7,"username":"alice"}]')"
route "PUT $P/issues/5" '{}'
forge claim 5 @me || fail "free claim should win"
calls PUT | jq -e '.fields.assignee_ids == "7"' >/dev/null || fail "claim PUT: $(calls PUT)"
[ "$(ncalls GET | tr -d ' ')" -ge 3 ] || fail "claim must re-read after writing"
ok "claim of a free issue assigns and confirms"

reset
route "GET user" "$ME"
route "GET $P/issues/5" "$(issue 5 opened '[]' '[]')"
route "GET $P/issues/5" "$(issue 5 opened '[]' '[{"id":9,"username":"bob"}]')"
route "PUT $P/issues/5" '{}'
RC=0; OUT=$(forge claim 5 @me) || RC=$?
[ "$RC" = 2 ] && [ "$OUT" = bob ] || fail "lost race should exit 2 with the winner (rc=$RC out=$OUT)"
ok "claim race lost → exit 2 + winner"

reset
route "GET users?username=alice" "[$ME]"
route "GET $P/issues/5" "$(issue 5 opened '[]' '[{"id":9,"username":"bob"}]')"
RC=0; OUT=$(forge claim 5 alice) || RC=$?
[ "$RC" = 2 ] && [ "$OUT" = bob ] || fail "held claim should exit 2 (rc=$RC out=$OUT)"
[ "$(ncalls PUT)" = 0 ] || fail "held claim must not write"
reset
route "GET user" "$ME"
route "GET $P/issues/5" "$(issue 5 opened '[]' '[{"id":7,"username":"alice"}]')"
forge claim 5 @me || fail "already ours should be 0"
[ "$(ncalls PUT)" = 0 ] || fail "already ours must not write"
ok "claim: held by another → 2, already ours → 0, no writes"

# 7 — release.
reset
route "GET user" "$ME"
route "GET $P/issues/5" "$(issue 5 opened '[]' '[{"id":7,"username":"alice"}]')"
route "PUT $P/issues/5" '{}'
forge release 5 @me
calls PUT | jq -e '.fields.assignee_ids == "0"' >/dev/null || fail "release PUT: $(calls PUT)"
reset
route "GET user" "$ME"
route "GET $P/issues/5" "$(issue 5 opened '[]' '[{"id":9,"username":"bob"}]')"
forge release 5 @me
[ "$(ncalls PUT)" = 0 ] || fail "release when not assigned must not write"
ok "release unassigns; not assigned → 0, no write"

# 8 — whoami, issue-view, issue-list.
reset
route "GET user" "$ME"
route "GET $P/issues/5" "$(issue 5 closed '["sb::Review"]' '[{"id":7,"username":"alice"}]')"
[ "$(forge whoami)" = alice ] || fail whoami
OUT=$(forge issue-view 5)
echo "$OUT" | jq -e '. == {number:5,title:"Issue 5",body:"body 5",state:"CLOSED",labels:["sb::Review"],assignees:["alice"],url:"https://gitlab.com/acme/app/-/issues/5"}' >/dev/null \
  || fail "issue-view: $OUT"
export SB_GLAB_PER_PAGE=2
L="GET $P/issues?state=all&order_by=created_at&sort=desc&labels=$(jq -rn '"a b,c"|@uri')&search=fix"
route "$L&per_page=2&page=1" "[$(issue 9 opened '["a b","c"]'),$(issue 8 opened '["a b","c"]')]"
route "$L&per_page=2&page=2" "[$(issue 7 opened '["a b","c"]'),$(issue 6 opened '["a b","c"]')]"
OUT=$(forge issue-list --state all --label 'a b' --label c --search fix --limit 3)
export SB_GLAB_PER_PAGE=100
echo "$OUT" | jq -e '[.[].number] == [9,8,7] and (.[0] | keys) == (["assignees","body","labels","number","state","title","url"])' >/dev/null || fail "issue-list: $OUT"
grep -q 'page=3' "$TMP/glab/calls.log" && fail "issue-list read past --limit"
ok "whoami, issue-view, issue-list (labels ANDed, paged, limited)"

# 9 — comments: non-system notes only, oldest first; comment returns a note url.
reset
NOTES='[{"id":1,"system":true,"body":"added ~sb::Ready","author":{"username":"bot"},"created_at":"2026-10-01T00:00:00Z"},
        {"id":2,"system":false,"body":"hello","author":{"username":"alice"},"created_at":"2026-10-02T00:00:00Z"},
        {"id":3,"body":"again","author":{"username":"bob"},"created_at":"2026-10-03T00:00:00Z"}]'
route "GET $P/issues/5/notes?sort=asc&order_by=created_at&per_page=100&page=1" "$NOTES"
OUT=$(forge issue-comments 5)
echo "$OUT" | jq -e '. == [{id:"2",author:"alice",authorType:"User",body:"hello",createdAt:"2026-10-02T00:00:00Z",updatedAt:"2026-10-02T00:00:00Z"},{id:"3",author:"bob",authorType:"User",body:"again",createdAt:"2026-10-03T00:00:00Z",updatedAt:"2026-10-03T00:00:00Z"}]' >/dev/null \
  || fail "issue-comments: $OUT"
printf 'line one\nline two\n' > "$TMP/body.md"
route "POST $P/issues/5/notes" '{"id":42}'
OUT=$(forge issue-comment 5 "$TMP/body.md")
[ "$OUT" = '{"url":"https://gitlab.com/acme/app/-/issues/5#note_42"}' ] || fail "issue-comment: $OUT"
calls POST | jq -e '.fields.body == "line one\nline two"' >/dev/null || fail "comment body: $(calls POST)"
ok "issue-comments skip system notes; issue-comment posts the file"

# 10 — create / edit / close.
reset
route "POST $P/issues" '{"iid":77,"web_url":"https://gitlab.com/acme/app/-/issues/77"}'
OUT=$(forge issue-create --title "New thing" --body-file "$TMP/body.md" --label bug --label sb::Backlog)
[ "$OUT" = '{"number":77,"url":"https://gitlab.com/acme/app/-/issues/77"}' ] || fail "issue-create: $OUT"
calls POST | jq -e '.fields == {title:"New thing",description:"line one\nline two",labels:"bug,sb::Backlog"}' >/dev/null || fail "create fields: $(calls POST)"
route "PUT $P/issues/77" '{}'
OUT=$(forge issue-edit 77 --add-label x --add-label y --remove-label z --body-file "$TMP/body.md")
[ -z "$OUT" ] || fail "issue-edit prints nothing: $OUT"
calls PUT | jq -e '.fields == {add_labels:"x,y",remove_labels:"z",description:"line one\nline two"}' >/dev/null || fail "edit fields: $(calls PUT)"
: > "$TMP/glab/calls.log"
forge issue-close 77 --reason not_planned
calls PUT | jq -e '.fields == {state_event:"close"}' >/dev/null || fail "close fields: $(calls PUT)"
RC=0; forge issue-create --title x >/dev/null 2>&1 || RC=$?; [ "$RC" = 64 ] || fail "issue-create without body → 64 (rc=$RC)"
ok "issue-create / issue-edit / issue-close"

# 11 — setup: creates missing labels, board, lists in order; second run writes nothing.
reset
route "GET $P/labels?per_page=100&page=1" '[{"id":1,"name":"sb::Backlog"},{"id":9,"name":"bug"}]'
ALL_LABELS='[{"id":1,"name":"sb::Backlog"},{"id":2,"name":"sb::Ready"},{"id":3,"name":"sb::Building"},{"id":4,"name":"sb::QA"},{"id":5,"name":"sb::Review"},{"id":6,"name":"sb::Blocked"},{"id":9,"name":"bug"}]'
route "GET $P/labels?per_page=100&page=1" "$ALL_LABELS"
route "POST $P/labels" '{}'
route "GET $P/boards" '[]'
route "POST $P/boards" '{"id":31,"name":"super-board","lists":[]}'
LISTS='[]'
route "GET $P/boards/31/lists" "$LISTS"
for i in 1 2 3 4 5 6; do
  LISTS=$(jq -c --argjson i "$i" --argjson al "$ALL_LABELS" '. + [{id: (100 + $i), position: ($i - 1), label: ($al[] | select(.id == $i))}]' <<<"$LISTS")
  route "GET $P/boards/31/lists" "$LISTS"
done
route "POST $P/boards/31/lists" '{}'
OUT=$("$SETUP" --config "$CFG" setup 2>/dev/null)
echo "$OUT" | jq -e '. == {board_id:31,labels:["sb::Backlog","sb::Ready","sb::Building","sb::QA","sb::Review","sb::Blocked"]}' >/dev/null || fail "setup output: $OUT"
[ "$(calls POST | jq -r 'select(.path | endswith("/labels")) | .fields.name' | tr '\n' ' ')" = "sb::Ready sb::Building sb::QA sb::Review sb::Blocked " ] \
  || fail "setup should create only the 5 missing labels: $(calls POST)"
calls POST | jq -e 'select(.path | endswith("/labels")) | .fields.color | test("^#[0-9a-f]{6}$")' >/dev/null || fail "label colors"
[ "$(calls POST | jq -r 'select(.path | endswith("/lists")) | .fields.label_id' | tr '\n' ' ')" = "1 2 3 4 5 6 " ] || fail "lists in board order: $(calls POST)"
[ "$(ncalls PUT)" = 0 ] || fail "fresh lists need no reorder"
ok "setup creates missing labels, the board and its lists in board order"

reset
route "GET $P/labels?per_page=100&page=1" "$ALL_LABELS"
route "GET $P/boards" "[{\"id\":31,\"name\":\"super-board\",\"lists\":$LISTS}]"
route "GET $P/boards/31/lists" "$LISTS"
OUT=$("$SETUP" --config "$CFG" setup 2>/dev/null)
echo "$OUT" | jq -e '.board_id == 31' >/dev/null || fail "setup rerun output: $OUT"
[ "$(ncalls POST)" = 0 ] && [ "$(ncalls PUT)" = 0 ] || fail "setup rerun must not write: $(cat "$TMP/glab/calls.log")"
ok "setup is idempotent"

# 12 — verify: reports a double; --fix keeps the latest column.
reset
route "GET $P/labels?per_page=100&page=1" "$ALL_LABELS"
route "GET $P/boards" "[{\"id\":31,\"name\":\"super-board\",\"lists\":$LISTS}]"
q() { echo "GET $P/issues?labels=$(jq -rn --arg v "sb::$1" '$v|@uri')&state=all&order_by=created_at&sort=asc&per_page=100&page=1"; }
route "$(q Ready)" "[$(issue 13 opened '["sb::Ready","sb::QA"]'),$(issue 14 opened '["sb::Ready"]')]"
route "$(q QA)" "[$(issue 13 opened '["sb::Ready","sb::QA"]')]"
for c in Backlog Building Review Blocked; do route "$(q "$c")" '[]'; done
route "PUT $P/issues/13" '{}'
RC=0; OUT=$("$SETUP" --config "$CFG" verify) || RC=$?
[ "$RC" = 3 ] || fail "verify with a double should exit 3 (rc=$RC)"
echo "$OUT" | jq -e '.ok == false and .board_id == 31 and .missing_labels == [] and .missing_lists == []
  and .doubles == [{number:13,labels:["sb::Ready","sb::QA"],keep:"sb::QA"}]' >/dev/null || fail "verify report: $OUT"
[ "$(ncalls PUT)" = 0 ] || fail "verify without --fix must not write"
OUT=$("$SETUP" --config "$CFG" verify --fix 2>/dev/null) || fail "verify --fix should exit 0"
calls PUT | jq -e '.path == "'"$P"'/issues/13" and (.fields.remove_labels | split(",") | index("sb::QA") == null and index("sb::Ready") != null and length == 5)' >/dev/null \
  || fail "verify --fix PUT: $(calls PUT)"
[ "$(ncalls PUT)" = 1 ] || fail "only the double is fixed"
ok "verify reports doubles; --fix keeps the one status reports"

reset
route "GET $P/labels?per_page=100&page=1" '[{"id":1,"name":"sb::Backlog"}]'
route "GET $P/boards" '[]'
for c in Backlog Ready Building QA Review Blocked; do route "$(q "$c")" '[]'; done
RC=0; OUT=$("$SETUP" --config "$CFG" verify) || RC=$?
[ "$RC" = 3 ] && echo "$OUT" | jq -e '.board_id == null and (.missing_labels | length) == 5' >/dev/null || fail "verify missing board/labels (rc=$RC): $OUT"
ok "verify reports missing labels and board"

# ── permission ──────────────────────────────────────────────────────────
route "GET users?username=dev" '[{"id":31,"username":"dev"}]'
route "GET $P/members/all/31" '{"id":31,"access_level":30}'
route "GET users?username=boss" '[{"id":41,"username":"boss"}]'
route "GET $P/members/all/41" '{"id":41,"access_level":40}'
route "GET users?username=guest" '[{"id":11,"username":"guest"}]'
route "GET $P/members/all/11" '{"id":11,"access_level":20}'
route "GET users?username=stranger" '[{"id":99,"username":"stranger"}]'
[ "$(forge permission dev)" = write ] || fail "permission developer"
[ "$(forge permission boss)" = maintain ] || fail "permission maintainer"
[ "$(forge permission guest)" = read ] || fail "permission reporter"
[ "$(SB_GLAB_BACKOFF=0 forge permission stranger)" = none ] || fail "permission non-member"
ok "permission: developer → write, maintainer → maintain, reporter → read, non-member → none"

echo "PASS: $pass gitlab board checks"
