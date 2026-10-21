#!/usr/bin/env bash
# super-board-forge-github.sh — GitHub backend for super-board-forge.sh.
# Verbs and shapes: docs/forge-contract.md. Board verbs delegate to super-board-card.sh.
#
# Usage: super-board-forge-github.sh [--config <cfg.json>] <verb> [args…]
#
# The repository is SB_FORGE_REPO (owner/name), else the config's repo.remote,
# else whatever gh resolves from the current checkout. Board owner/number come
# from the config's project block, else $BUILD_LOOP_OWNER / $BUILD_LOOP_PROJECT
# (super-board-card.sh's own rules).
#
# Comments, labels, assignees, close and issue/file reads use REST (0 GraphQL
# points, rate-limit-etiquette.md → "Price list"); the rest is the gh CLI.
#
# Reads with a fixed shape go through super-board-github-read.py, so they share
# the run's bounded retries and halt file (exit 79). Mutations call gh once and
# never retry: a failed write exits 69 and the caller decides.
#
# Exit: 0 ok · 2 claim lost · 3 not on board · 4 pr-merge head moved · 64 usage ·
#       66 config · 69 GitHub read/write failed · 79 reads halted.
set -euo pipefail
# Every read command here is fixed, so a malformed payload is GitHub's: halt (#32).
export SB_GITHUB_READ_STRICT=1
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GITHUB_READ="$HERE/super-board-github-read.py"

CONFIG="${SB_CONFIG:-}"
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="${2:-}"; shift 2 || { echo "--config needs a path" >&2; exit 64; } ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}
VERB="${1:-}"
[ -n "$VERB" ] || { echo "usage: super-board-forge.sh [--config <cfg>] <verb> [args…] (docs/forge-contract.md)" >&2; exit 64; }
shift

REPO="${SB_FORGE_REPO:-}"
if [ -n "$CONFIG" ]; then
  [ -r "$CONFIG" ] || { echo "config not found: $CONFIG" >&2; exit 66; }
  [ -n "$REPO" ] || REPO=$(jq -r '.repo.remote // ""' "$CONFIG" 2>/dev/null) || { echo "config is not JSON: $CONFIG" >&2; exit 66; }
fi
REPO=$(printf '%s' "$REPO" | sed -E 's#^(https?://github\.com/|git@github\.com:)##; s#\.git$##; s#/+$##')
RFLAG=(); [ -z "$REPO" ] || RFLAG=(-R "$REPO")
# REST path prefix; gh fills {owner}/{repo} from the checkout when REPO is unknown.
if [ -n "$REPO" ]; then API="repos/$REPO"; else API='repos/{owner}/{repo}'; fi

usage() { echo "usage: $1" >&2; exit 64; }
need_num() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || usage "$2"; }

# A fixed-shape read: bounded retries, shared halt file. 79 passes through.
# SB_FORGE_BEST_EFFORT=1 (super-board-stop.sh) reads once with plain gh, so a
# shutdown never trips the run's halt file.
read_json() {
  local rc=0 out
  if [ "${SB_FORGE_BEST_EFFORT:-}" = 1 ]; then out=$(gh "$@") || rc=$?
  else out=$(python3 "$GITHUB_READ" --kind json -- "$@") || rc=$?; fi
  [ "$rc" -eq 0 ] || { [ "$rc" -eq 79 ] && exit 79; exit 69; }
  printf '%s\n' "$out"
}
# A mutation: one attempt, stderr kept, 69 on failure.
write() { gh "$@" || { echo "gh $1 $2 failed" >&2; exit 69; }; }

login_of() {  # resolves @me to the authenticated login
  if [ "$1" = "@me" ]; then gh api user --jq .login || { echo "could not read the signed-in login" >&2; exit 69; }
  else printf '%s\n' "$1"; fi
}

card() { exec bash "$HERE/super-board-card.sh" ${CONFIG:+--config "$CONFIG"} ${REPO:+--repo "$REPO"} "$@"; }

ISSUE_FIELDS=number,title,body,state,labels,assignees,url
ISSUE_SHAPE='{number, title, body, state, labels: [.labels[]?.name], assignees: [.assignees[]?.login], url}'
PR_FIELDS=number,title,body,state,isDraft,headRefName,baseRefName,headRefOid,url,mergeable,mergeCommit,closingIssuesReferences,labels,additions,deletions,changedFiles
PR_SHAPE='{number, title, body, state, isDraft, headRefName, baseRefName, headRefOid, url,
           mergeable: (if .mergeable == "MERGEABLE" or .mergeable == "CONFLICTING" then .mergeable else "UNKNOWN" end),
           mergeCommit: (.mergeCommit.oid // null),
           closingIssues: [.closingIssuesReferences[]?.number],
           labels: [.labels[]?.name], additions, deletions, changedFiles}'
REST_ISSUE='{number, title, body: (.body // ""), state: (.state | ascii_upcase),
             labels: [.labels[]?.name], assignees: [.assignees[]?.login], url: .html_url}'
REST_COMMENTS='[.[][]? | {id, author: (.user.login // ""), authorType: (.user.type // "User"),
                          body: (.body // ""), createdAt: .created_at, updatedAt: .updated_at}]'
url_of() { jq -r '.html_url // ""' 2>/dev/null || true; }
others_than() {  # $1 = login; stdin = issue JSON; prints every other assignee
  jq -r --arg me "$1" 'def norm: ascii_downcase | sub("\\[bot\\]$"; "");
    [.assignees[]?.login | select(norm != ($me | norm))] | .[]'
}

case "$VERB" in
  # ── board ────────────────────────────────────────────────────────────
  items)  [ $# -eq 0 ] || usage "items"; card items ;;
  move)   [ $# -eq 2 ] || usage "move <issue> <Column>"; need_num "$1" "move <issue> <Column>"; card move "$1" "$2" ;;
  status) [ $# -eq 1 ] || usage "status <issue>"; need_num "$1" "status <issue>"; card status "$1" ;;

  claim)
    [ $# -eq 2 ] || usage "claim <issue> <login|@me>"; need_num "$1" "claim <issue> <login|@me>"
    N="$1"; ME=$(login_of "$2")
    # Adding an assignee never fails when someone else holds the issue (up to 10
    # assignees), so the add is followed by a re-read: the claim holds only when
    # the list is exactly us. Anything else is a lost race — undo our add.
    # The REST add answers with the issue as it stands after the write.
    AFTER=$(write api "$API/issues/$N/assignees" -f "assignees[]=$ME")
    printf '%s' "$AFTER" | jq -e '.assignees | type == "array"' >/dev/null 2>&1 \
      || AFTER=$(read_json api "$API/issues/$N")
    if ! printf '%s' "$AFTER" | jq -e --arg me "$ME" 'def norm: ascii_downcase | sub("\\[bot\\]$"; "");
         any(.assignees[]?.login; norm == ($me | norm))' >/dev/null; then
      echo "GitHub did not assign $ME to #$N (no access to the repo?)" >&2; exit 69
    fi
    OTHERS=$(printf '%s' "$AFTER" | others_than "$ME")
    if [ -n "$OTHERS" ]; then
      gh api -X DELETE "$API/issues/$N/assignees" -f "assignees[]=$ME" >/dev/null 2>&1 \
        || echo "warn: could not undo our assignee on #$N" >&2
      printf '%s\n' "$OTHERS" | head -1
      exit 2
    fi ;;

  release)
    [ $# -eq 2 ] || usage "release <issue> <login|@me>"; need_num "$1" "release <issue> <login|@me>"
    LOGIN=$(login_of "$2")
    write api -X DELETE "$API/issues/$1/assignees" -f "assignees[]=$LOGIN" >/dev/null ;;

  whoami) [ $# -eq 0 ] || usage "whoami"; login_of @me ;;

  permission)
    [ $# -eq 1 ] && [[ "$1" =~ ^[A-Za-z0-9_.-]+(\[bot\])?$ ]] || usage "permission <login>"
    rc=0; OUT=$(python3 "$GITHUB_READ" --kind permission -- api "$API/collaborators/$1/permission") || rc=$?
    [ "$rc" -eq 0 ] || { [ "$rc" -eq 79 ] && exit 79; exit 69; }
    printf '%s' "$OUT" | jq -r .permission ;;

  # ── issues ───────────────────────────────────────────────────────────
  issue-view)
    [ $# -eq 1 ] || usage "issue-view <issue>"; need_num "$1" "issue-view <issue>"
    read_json api "$API/issues/$1" | jq "$REST_ISSUE" ;;

  issue-list)
    STATE=open; LIMIT=200; EXTRA=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --state)  STATE="$2"; shift 2 ;;
        --label)  EXTRA+=(--label "$2"); shift 2 ;;
        --search) EXTRA+=(--search "$2"); shift 2 ;;
        --limit)  LIMIT="$2"; shift 2 ;;
        *) usage "issue-list [--state open|closed|all] [--label L]… [--search S] [--limit N]" ;;
      esac
    done
    case "$STATE" in open|closed|all) ;; *) usage "issue-list --state open|closed|all" ;; esac
    read_json issue list ${RFLAG[@]+"${RFLAG[@]}"} --state "$STATE" --limit "$LIMIT" ${EXTRA[@]+"${EXTRA[@]}"} \
      --json "$ISSUE_FIELDS" | jq "[.[] | $ISSUE_SHAPE]" ;;

  issue-comments)
    [ $# -eq 1 ] || usage "issue-comments <issue>"; need_num "$1" "issue-comments <issue>"
    read_json api "$API/issues/$1/comments" --paginate --slurp | jq "$REST_COMMENTS" ;;

  issue-comment)
    [ $# -eq 2 ] || usage "issue-comment <issue> <body-file>"; need_num "$1" "issue-comment <issue> <body-file>"
    [ -r "$2" ] || { echo "body file not readable: $2" >&2; exit 64; }
    OUT=$(write api "$API/issues/$1/comments" -F "body=@$2")
    jq -n --arg u "$(printf '%s' "$OUT" | url_of)" '{url: $u}' ;;

  issue-create)
    TITLE=""; BODY=""; EXTRA=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --title)     TITLE="$2"; shift 2 ;;
        --body-file) BODY="$2"; shift 2 ;;
        --label)     EXTRA+=(--label "$2"); shift 2 ;;
        *) usage "issue-create --title T --body-file F [--label L]…" ;;
      esac
    done
    [ -n "$TITLE" ] && [ -r "$BODY" ] || usage "issue-create --title T --body-file F [--label L]…"
    URL=$(write issue create ${RFLAG[@]+"${RFLAG[@]}"} --title "$TITLE" --body-file "$BODY" ${EXTRA[@]+"${EXTRA[@]}"} | tail -1)
    N="${URL##*/}"
    [[ "$N" =~ ^[1-9][0-9]*$ ]] || { echo "issue created but its URL was unreadable: $URL" >&2; exit 69; }
    jq -n --argjson n "$N" --arg u "$URL" '{number: $n, url: $u}' ;;

  issue-edit)
    [ $# -ge 1 ] || usage "issue-edit <issue> [--add-label L]… [--remove-label L]… [--body-file F]"
    N="$1"; shift; need_num "$N" "issue-edit <issue> …"; ADD=(); DEL=(); BODY=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --add-label)    ADD+=(-f "labels[]=$2"); shift 2 ;;
        --remove-label) DEL+=("$2"); shift 2 ;;
        --body-file) [ -r "$2" ] || { echo "body file not readable: $2" >&2; exit 64; }; BODY="$2"; shift 2 ;;
        *) usage "issue-edit <issue> [--add-label L]… [--remove-label L]… [--body-file F]" ;;
      esac
    done
    [ "${#ADD[@]}" -eq 0 ] || write api "$API/issues/$N/labels" "${ADD[@]}" >/dev/null
    for l in ${DEL[@]+"${DEL[@]}"}; do
      # Removing a label the issue does not carry is a 404: already the wanted state.
      if ! ERR=$(gh api -X DELETE "$API/issues/$N/labels/$(jq -rn --arg s "$l" '$s | @uri')" 2>&1 >/dev/null); then
        printf '%s' "$ERR" | grep -qiE 'HTTP 404|Label does not exist' || { printf '%s\n' "$ERR" >&2; exit 69; }
      fi
    done
    [ -z "$BODY" ] || write api -X PATCH "$API/issues/$N" -F "body=@$BODY" >/dev/null ;;

  issue-close)
    [ $# -ge 1 ] || usage "issue-close <issue> [--reason completed|not_planned]"
    N="$1"; shift; need_num "$N" "issue-close <issue> [--reason completed|not_planned]"; REASON=completed
    while [ $# -gt 0 ]; do
      case "$1" in --reason) REASON="$2"; shift 2 ;; *) usage "issue-close <issue> [--reason completed|not_planned]" ;; esac
    done
    case "$REASON" in completed|not_planned) ;; *) usage "issue-close --reason completed|not_planned" ;; esac
    write api -X PATCH "$API/issues/$N" -f state=closed -f state_reason="$REASON" >/dev/null ;;

  # ── pull requests ────────────────────────────────────────────────────
  pr-create)
    HEAD=""; BASE=""; TITLE=""; BODY=""; DRAFT=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --head) HEAD="$2"; shift 2 ;; --base) BASE="$2"; shift 2 ;;
        --title) TITLE="$2"; shift 2 ;; --body-file) BODY="$2"; shift 2 ;;
        --draft) DRAFT=(--draft); shift ;;
        *) usage "pr-create --head B --base B --title T --body-file F [--draft]" ;;
      esac
    done
    [ -n "$HEAD" ] && [ -n "$BASE" ] && [ -n "$TITLE" ] && [ -r "$BODY" ] || usage "pr-create --head B --base B --title T --body-file F [--draft]"
    URL=$(write pr create ${RFLAG[@]+"${RFLAG[@]}"} --head "$HEAD" --base "$BASE" --title "$TITLE" --body-file "$BODY" ${DRAFT[@]+"${DRAFT[@]}"} | tail -1)
    N="${URL##*/}"
    [[ "$N" =~ ^[1-9][0-9]*$ ]] || { echo "PR created but its URL was unreadable: $URL" >&2; exit 69; }
    jq -n --argjson n "$N" --arg u "$URL" '{number: $n, url: $u}' ;;

  pr-view)
    [ $# -eq 1 ] || usage "pr-view <pr>"; need_num "$1" "pr-view <pr>"
    read_json pr view "$1" ${RFLAG[@]+"${RFLAG[@]}"} --json "$PR_FIELDS" | jq "$PR_SHAPE" ;;

  pr-list)
    STATE=open; LIMIT=200; EXTRA=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --state)  STATE="$2"; shift 2 ;;
        --head)   EXTRA+=(--head "$2"); shift 2 ;;
        --search) EXTRA+=(--search "$2"); shift 2 ;;
        --limit)  LIMIT="$2"; shift 2 ;;
        *) usage "pr-list [--state open|closed|merged|all] [--head B] [--search S] [--limit N]" ;;
      esac
    done
    case "$STATE" in open|closed|merged|all) ;; *) usage "pr-list --state open|closed|merged|all" ;; esac
    read_json pr list ${RFLAG[@]+"${RFLAG[@]}"} --state "$STATE" --limit "$LIMIT" ${EXTRA[@]+"${EXTRA[@]}"} \
      --json "${PR_FIELDS/body,/}" | jq "[.[] | $PR_SHAPE | del(.body)]" ;;

  pr-diff)
    [ $# -eq 1 ] || usage "pr-diff <pr>"; need_num "$1" "pr-diff <pr>"
    python3 "$GITHUB_READ" --check || exit 79
    gh pr diff "$1" ${RFLAG[@]+"${RFLAG[@]}"} || { echo "gh pr diff failed" >&2; exit 69; } ;;

  pr-files)
    [ $# -eq 1 ] || usage "pr-files <pr>"; need_num "$1" "pr-files <pr>"
    read_json api "$API/pulls/$1/files" --paginate --slurp | jq '[.[][]?.filename]' ;;

  pr-comments)
    [ $# -eq 1 ] || usage "pr-comments <pr>"; need_num "$1" "pr-comments <pr>"
    read_json api "$API/issues/$1/comments" --paginate --slurp | jq "$REST_COMMENTS" ;;

  pr-comment)
    [ $# -eq 2 ] || usage "pr-comment <pr> <body-file>"; need_num "$1" "pr-comment <pr> <body-file>"
    [ -r "$2" ] || { echo "body file not readable: $2" >&2; exit 64; }
    OUT=$(write api "$API/issues/$1/comments" -F "body=@$2")
    jq -n --arg u "$(printf '%s' "$OUT" | url_of)" '{url: $u}' ;;

  pr-ready)
    [ $# -eq 1 ] || usage "pr-ready <pr>"; need_num "$1" "pr-ready <pr>"
    write pr ready "$1" ${RFLAG[@]+"${RFLAG[@]}"} >/dev/null ;;

  pr-merge)
    U="pr-merge <pr> --sha <oid> [--squash|--merge|--rebase] [--delete-branch] [--subject S] [--body-file F]"
    [ $# -ge 1 ] || usage "$U"
    N="$1"; shift; need_num "$N" "$U"; SHA=""; EXTRA=(); METHOD=(--squash)
    while [ $# -gt 0 ]; do
      case "$1" in
        --sha) SHA="$2"; shift 2 ;;
        --squash|--merge|--rebase) METHOD=("$1"); shift ;;
        --delete-branch) EXTRA+=(--delete-branch); shift ;;
        --subject) EXTRA+=(--subject "$2"); shift 2 ;;
        --body-file) [ -r "$2" ] || { echo "body file not readable: $2" >&2; exit 64; }; EXTRA+=(--body-file "$2"); shift 2 ;;
        *) usage "$U" ;;
      esac
    done
    [[ "$SHA" =~ ^[0-9a-f]{7,40}$ ]] || usage "$U"
    # --match-head-commit: GitHub refuses when anything was pushed after SHA.
    ERR=$(mktemp); trap 'rm -f "$ERR"' EXIT
    if gh pr merge "$N" ${RFLAG[@]+"${RFLAG[@]}"} "${METHOD[@]}" ${EXTRA[@]+"${EXTRA[@]}"} --match-head-commit "$SHA" 2>"$ERR" >/dev/null; then
      exit 0
    fi
    tail -3 "$ERR" >&2
    # Head moved? Ask GitHub for the head now (one plain read; never retried, never halts).
    NOW=$(gh pr view "$N" ${RFLAG[@]+"${RFLAG[@]}"} --json headRefOid --jq .headRefOid 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1 || true)
    if grep -qiE 'head branch was modified|expected head sha' "$ERR" \
       || { [ -n "$NOW" ] && [ "${NOW#"$SHA"}" = "$NOW" ]; }; then
      echo "head moved: expected $SHA, PR head is ${NOW:-unknown}" >&2
      exit 4
    fi
    exit 69 ;;

  checks)
    [ $# -eq 1 ] || usage "checks <pr>"; need_num "$1" "checks <pr>"
    python3 "$GITHUB_READ" --check || exit 79
    # gh exits 8 while checks are pending and 1 when one failed; the JSON is
    # still on stdout, so judge by the payload, not the exit code.
    ERR=$(mktemp); trap 'rm -f "$ERR"' EXIT
    OUT=$(gh pr checks "$1" ${RFLAG[@]+"${RFLAG[@]}"} --json name,bucket,link 2>"$ERR" || true)
    if ! printf '%s' "$OUT" | jq -e 'type == "array"' >/dev/null 2>&1; then
      if grep -qi 'no checks reported' "$ERR"; then OUT='[]'; else cat "$ERR" >&2; exit 69; fi
    fi
    printf '%s' "$OUT" | jq '
      def st: if . == "pass" or . == "skipping" then "SUCCESS"
              elif . == "fail" or . == "cancel" then "FAILURE" else "PENDING" end;
      [.[] | {name, state: (.bucket | st), url: (.link // "")}] as $c
      | {state: (if ($c | length) == 0 then "NONE"
                 elif any($c[]; .state == "FAILURE") then "FAILURE"
                 elif any($c[]; .state == "PENDING") then "PENDING" else "SUCCESS" end),
         checks: $c}' ;;

  # ── repo and quota ───────────────────────────────────────────────────
  default-branch)
    [ $# -eq 0 ] || usage "default-branch"
    if [ "${SB_FORGE_BEST_EFFORT:-}" = 1 ]; then
      rc=0; OUT=$(gh repo view ${REPO:+"$REPO"} --json defaultBranchRef --jq .defaultBranchRef.name) || rc=$?
    else
      rc=0; OUT=$(python3 "$GITHUB_READ" --kind scalar -- repo view ${REPO:+"$REPO"} --json defaultBranchRef --jq .defaultBranchRef.name) || rc=$?
    fi
    [ "$rc" -eq 0 ] || { [ "$rc" -eq 79 ] && exit 79; exit 69; }
    printf '%s\n' "$OUT" | head -1 ;;

  auth-check)
    [ $# -eq 0 ] || usage "auth-check"
    if ! STATUS=$(gh auth status 2>&1); then
      echo "GitHub is not signed in. Fix: gh auth login -s project,read:project,repo" >&2; exit 69
    fi
    if printf '%s' "$STATUS" | grep -qi 'token scopes' && ! printf '%s' "$STATUS" | grep -qiE "'project'|\"project\"|[[:space:],]project([,[:space:]]|$)"; then
      echo "GitHub token lacks the project scope. Fix: gh auth refresh -s project,read:project,repo" >&2; exit 69
    fi ;;

  quota)
    [ $# -eq 0 ] || usage "quota"
    # shellcheck source=super-board-gh-guard.sh
    . "$HERE/super-board-gh-guard.sh"
    rc=0; REST=$(python3 "$GITHUB_READ" --kind quota -- api rate_limit) || rc=$?
    [ "$rc" -eq 0 ] || { [ "$rc" -eq 79 ] && exit 79; exit 69; }
    sb_gh_quota_merge "$REST" | jq '.resources.graphql
      | {remaining, limit, resetAt: .reset, kind: "graphql"}' ;;

  *) echo "unknown verb: $VERB (docs/forge-contract.md)" >&2; exit 64 ;;
esac
