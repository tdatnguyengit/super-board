#!/usr/bin/env bash
# super-board-deps.sh on GitLab-shaped data. No network: `glab` is the shared fake
# (tests/fixtures/glab/fake_glab.py) and serves REST v4 issues and notes.
#
# deps.sh does not read the forge itself yet (it calls github-read's GraphQL query),
# so two paths are pinned here:
#   A. super-board-gitlab-read.py --kind deps-issues → deps.sh --from: works today.
#   B. the forge contract shapes (`issue-list` + `issue-comments`, from a stand-in
#      super-board-forge.sh on PATH that answers through gitlab-read) → the
#      normalisation deps.sh needs before its parser (labels:[name] → labels.nodes,
#      comments:[…] → comments.nodes). deps' jq indexes `.labels.nodes`, which errors
#      on the contract's plain arrays, so the forge migration (#1) must normalise.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
DEPS="$ROOT/scripts/super-board-deps.sh"
READ="$ROOT/scripts/super-board-gitlab-read.py"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexec python3 "%s" "$@"\n' "$ROOT/tests/fixtures/glab/fake_glab.py" > "$TMP/bin/glab"
chmod +x "$TMP/bin/glab"
export PATH="$TMP/bin:$PATH" FAKE_GLAB_DIR="$TMP" SB_GITLAB_PROJECT="grp/app" \
       SB_GITLAB_HALT_FILE="$TMP/halt.json" SB_GITLAB_RETRY_DELAY=0

# Open issues: #10 waits on #9 (closed → absent from the open set → frees it),
# #11 waits on open #10, #12 is parked by a Block note `blocked-by: -`, #13 has a
# body that says None but a newer Block note naming #10, and a SYSTEM note on #10
# that would read as a blocker if system notes were not skipped.
python3 - "$TMP/routes.json" <<'PY'
import json, sys
P = 'projects/grp%2Fapp'
def issue(iid, body, labels=()):
    return {'id': 100 + iid, 'iid': iid, 'title': f'card {iid}', 'description': body, 'state': 'opened',
            'labels': list(labels), 'assignees': [], 'web_url': f'https://gl/i/{iid}'}
def note(nid, body, system=False):
    return {'id': nid, 'body': body, 'system': system, 'author': {'username': 'lane'},
            'created_at': f'2026-10-0{nid}T00:00:00Z'}
issues = [issue(10, '## What\nx\n\n## Blocked by\n\n- #9 — the schema\n'),
          issue(11, '## Blocked by\n\n- #10 — needs card 10\n'),
          issue(12, None, ['needs-you']),
          issue(13, '## Blocked by\n\n- None.\n')]
notes = {10: [note(1, 'blocked-by: 11', system=True)], 11: [], 12: [note(2, '🛡 BLOCKED\nblocked-by: -')],
         13: [note(3, 'old'), note(4, '🛡 BLOCKED\nblocked-by: 10')]}
routes = {f'GET {P}/issues?state=opened&order_by=created_at&sort=asc&per_page=100&page=1': {'body': issues},
          f'GET {P}/issues?state=opened&order_by=updated_at&sort=desc&per_page=100&page=1': {'body': issues}}
for iid, ns in notes.items():
    routes[f'GET {P}/issues/{iid}/notes?sort=desc&order_by=created_at&per_page=20'] = {'body': ns[::-1]}
    routes[f'GET {P}/issues/{iid}/notes?sort=asc&order_by=created_at&per_page=100&page=1'] = {'body': ns}
json.dump(routes, open(sys.argv[1], 'w'))
PY

check() {  # check <label> <deps output> <jq assertion>…
  local label="$1" out="$2"; shift 2
  for a in "$@"; do echo "$out" | jq -e "$a" >/dev/null || fail "$label: $a — $(echo "$out" | jq -c .)"; done
}

assert_graph() {
  check "$1" "$2" \
    '.["10"].blockers == [9] and .["10"].openBlockers == [] and .["10"].runnable == true' \
    '.["11"].openBlockers == [10] and .["11"].runnable == false' \
    '.["12"].humanGated == true and .["12"].runnable == false and .["12"].needsYou == true' \
    '.["13"].blockers == [10] and .["13"].runnable == false' \
    '.["10"].humanGated == false'
}

# ---- A: gitlab-read deps-issues payload ------------------------------------
python3 "$READ" --kind deps-issues > "$TMP/deps.json" || fail "deps-issues read failed"
jq -e 'map(.comments.nodes | map(.body)) | flatten | index("blocked-by: 11") == null' "$TMP/deps.json" >/dev/null \
  || fail "system notes must not reach deps"
assert_graph "A (deps-issues)" "$("$DEPS" --from "$TMP/deps.json")"

# ---- B: forge contract shapes ---------------------------------------------
# A stand-in for the GitLab forge verbs (#3/#4), answering the two reads deps needs
# in the contract's shapes. The real ones live in super-board-forge-gitlab-board.sh.
cat > "$TMP/bin/super-board-forge.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
  issue-list)     exec python3 "$READ" --kind issues --state opened ;;
  issue-comments) exec python3 "$READ" --kind comments --iid "\$2" ;;
  *) echo "not in this stub: \$1" >&2; exit 64 ;;
esac
SH
chmod +x "$TMP/bin/super-board-forge.sh"

LIST=$(super-board-forge.sh issue-list)
echo "$LIST" | jq -e 'all(.[]; (.labels | type) == "array" and .state == "OPEN")' >/dev/null || fail "issue-list contract shape"
PAYLOAD=$(echo "$LIST" | jq -c '.[]' | while read -r one; do
  n=$(echo "$one" | jq .number)
  c=$(super-board-forge.sh issue-comments "$n")
  echo "$c" | jq -e 'all(.[]; has("author") and has("body") and has("createdAt"))' >/dev/null || fail "issue-comments contract shape"
  # The normalisation deps.sh needs from the contract shapes (see header).
  jq -n --argjson i "$one" --argjson c "$c" \
    '$i + {labels: {nodes: [$i.labels[] | {name: .}]}, comments: {nodes: [$c[-8:][] | {body}]}}'
done | jq -s .)
echo "$PAYLOAD" > "$TMP/contract.json"
assert_graph "B (contract shapes)" "$("$DEPS" --from "$TMP/contract.json")"

echo "PASS: test-deps-gitlab.sh (deps on GitLab issues and notes, closed blocker frees the card)"
