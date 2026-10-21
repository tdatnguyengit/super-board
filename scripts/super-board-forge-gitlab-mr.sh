# super-board-forge-gitlab-mr.sh — sourced by super-board-forge-gitlab.sh.
# Defines gl_<verb> functions; see docs/forge-contract.md. Uses sb_glab_api, gl_pid,
# GL_PREFIX and GL_COLUMNS from the parent script. Not executable on its own.
#
# Merge-request verbs over GitLab REST v4 (Free tier only):
#   pr-create pr-view pr-list pr-diff pr-files pr-comments pr-comment pr-ready
#   pr-merge checks default-branch auth-check
#
# Draft is the title prefix `Draft: `. Every GitLab version understands it on
# create and update; the `draft` parameter is newer and a failed write cannot be
# safely retried with the fallback (its outcome is unknown), so the prefix is the
# only path.
#
# pr-merge never retries the PUT (sb_glab_api never retries writes). GitLab
# answers 409 when `sha` is no longer the source branch HEAD → exit 4.

# ── helpers ─────────────────────────────────────────────────────────────

# Every MR verb but auth-check needs the project; fail before any call.
case "${VERB:-}" in
  pr-*|checks|default-branch)
    [ -n "$GL_PROJECT" ] || { echo "gitlab.project is not set in the config" >&2; exit 66; } ;;
esac

gl__usage() { echo "usage: super-board-forge.sh $*" >&2; exit 64; }

gl__num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; }

# gl__paged <path-with-optional-query> [max]
# GETs every page (per_page = SB_GL_PER_PAGE or 100) and prints one JSON array.
# Stops at a short page or once max items are collected.
gl__paged() {
  local path=$1 max=${2:-0} per=${SB_GL_PER_PAGE:-100} page=1 sep='?' out n all='[]'
  case "$path" in *\?*) sep='&' ;; esac
  while :; do
    out=$(sb_glab_api "${path}${sep}per_page=${per}&page=${page}") || return $?
    n=$(printf '%s' "$out" | jq 'length') || { echo "unexpected GitLab response for $path" >&2; return 69; }
    all=$(printf '%s' "$out" | jq -c --argjson a "$all" '$a + .')
    [ "$n" -lt "$per" ] && break
    if [ "$max" -gt 0 ] && [ "$(jq length <<<"$all")" -ge "$max" ]; then break; fi
    page=$((page + 1))
    [ "$page" -gt 1000 ] && break
  done
  if [ "$max" -gt 0 ]; then jq -c --argjson m "$max" '.[:$m]' <<<"$all"; else printf '%s\n' "$all"; fi
}

gl__mr_path() { echo "projects/$(gl_pid)/merge_requests/$1"; }

# jq: GitLab MR → contract pr-view (closingIssues filled by the caller).
GL_JQ_MR='
  def st: if .state == "merged" then "MERGED"
          elif .state == "opened" then "OPEN"
          else "CLOSED" end;
  def mergeable:
    (.detailed_merge_status // "") as $d
    | if $d == "mergeable" then "MERGEABLE"
      elif ($d == "conflict" or $d == "broken_status" or $d == "need_rebase") then "CONFLICTING"
      elif $d != "" then "UNKNOWN"
      elif .has_conflicts == true or .merge_status == "cannot_be_merged" then "CONFLICTING"
      elif .merge_status == "can_be_merged" then "MERGEABLE"
      else "UNKNOWN" end;
  def mr: {number: .iid, title: .title, body: (.description // ""), state: st,
           isDraft: ((.draft // .work_in_progress // false) == true),
           headRefName: .source_branch, baseRefName: .target_branch,
           headRefOid: .sha, url: .web_url, mergeable: mergeable,
           labels: (.labels // []),
           mergeCommit: (if .state == "merged" then (.squash_commit_sha // .merge_commit_sha // .sha) else null end)};
'

# GitLab default closing pattern, applied to a description (list rows only;
# pr-view asks GitLab via closes_issues).
GL_JQ_CLOSES='
  def closes: [ (. // "")
    | scan("(?i)\\b(?:clos(?:e[sd]?|ing)|fix(?:e[sd]|ing)?|resolv(?:e[sd]?|ing)|implement(?:s|ed|ing)?):? +#([0-9]+)")
    | .[0] | tonumber ] | unique;
'

gl__mr_get() { sb_glab_api "$(gl__mr_path "$1")"; }

# ── verbs ───────────────────────────────────────────────────────────────

gl_pr_create() {
  local head="" base="" title="" body_file="" draft=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --head) head="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --body-file) body_file="$2"; shift 2 ;;
      --draft) draft=1; shift ;;
      *) gl__usage "pr-create --head B --base B --title T --body-file F [--draft]" ;;
    esac
  done
  [ -n "$head" ] && [ -n "$base" ] && [ -n "$title" ] && [ -n "$body_file" ] \
    || gl__usage "pr-create --head B --base B --title T --body-file F [--draft]"
  [ -r "$body_file" ] || { echo "body file not readable: $body_file" >&2; exit 66; }
  local pid out
  pid=$(gl_pid) || exit $?
  [ "$draft" -eq 1 ] && title="Draft: $title"
  out=$(sb_glab_api -X POST "projects/$pid/merge_requests" \
        -f "source_branch=$head" -f "target_branch=$base" \
        -f "title=$title" -f "description=$(cat "$body_file")") || exit $?
  jq -c '{number: .iid, url: .web_url}' <<<"$out"
}

# pr-view also carries the merge policy's size fields, counted from /diffs
# (GitLab's own changes_count is a string capped at "1000+").
gl_pr_view() {
  gl__num "${1:-}" || gl__usage "pr-view <pr>"
  local mr closes diffs
  mr=$(gl__mr_get "$1") || exit $?
  closes=$(gl__paged "$(gl__mr_path "$1")/closes_issues") || exit $?
  diffs=$(gl__paged "$(gl__mr_path "$1")/diffs") || exit $?
  jq -c --argjson c "$closes" --argjson d "$diffs" "$GL_JQ_MR"'
    def count($re): [ $d[] | (.diff // "") | split("\n")[] | select(test($re)) ] | length;
    .project_id as $p
    | mr + {closingIssues: ([$c[] | select((.project_id // $p) == $p) | .iid] | unique),
            additions: count("^\\+"), deletions: count("^-"), changedFiles: ($d | length)}' <<<"$mr"
}

gl_pr_list() {
  local state=open head="" search="" limit=100
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) state="$2"; shift 2 ;;
      --head) head="$2"; shift 2 ;;
      --search) search="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *) gl__usage "pr-list [--state open|closed|merged|all] [--head B] [--search S] [--limit N]" ;;
    esac
  done
  case "$state" in open) state=opened ;; closed|merged|all) ;; *) gl__usage "pr-list --state open|closed|merged|all" ;; esac
  gl__num "$limit" || gl__usage "pr-list --limit N"
  local pid q rows
  pid=$(gl_pid) || exit $?
  q="state=$state"
  [ -n "$head" ] && q="$q&source_branch=$(jq -rn --arg v "$head" '$v|@uri')"
  [ -n "$search" ] && q="$q&search=$(jq -rn --arg v "$search" '$v|@uri')"
  rows=$(gl__paged "projects/$pid/merge_requests?$q" "$limit") || exit $?
  jq -c "$GL_JQ_MR$GL_JQ_CLOSES"'[ .[] | (mr | del(.body)) + {closingIssues: (.description | closes)} ]' <<<"$rows"
}

gl__diffs() { gl__paged "$(gl__mr_path "$1")/diffs"; }

gl_pr_diff() {
  gl__num "${1:-}" || gl__usage "pr-diff <pr>"
  local d
  d=$(gl__diffs "$1") || exit $?
  # Rebuild `git diff` headers around GitLab's hunk-only `diff` field.
  jq -j '
    .[] |
    (.old_path // .new_path) as $o | (.new_path // .old_path) as $n |
    ("diff --git a/" + $o + " b/" + $n + "\n")
    + (if .new_file then "new file mode " + (.b_mode // "100644") + "\n"
       elif .deleted_file then "deleted file mode " + (.a_mode // "100644") + "\n"
       elif (.a_mode != null and .b_mode != null and .a_mode != .b_mode)
         then "old mode " + .a_mode + "\nnew mode " + .b_mode + "\n"
       else "" end)
    + (if .renamed_file then "rename from " + $o + "\nrename to " + $n + "\n" else "" end)
    + ((.diff // "") as $h |
       if $h == "" then ""
       else (if .new_file then "--- /dev/null\n" else "--- a/" + $o + "\n" end)
          + (if .deleted_file then "+++ /dev/null\n" else "+++ b/" + $n + "\n" end)
          + $h + (if ($h | endswith("\n")) then "" else "\n" end)
       end)
  ' <<<"$d"
}

gl_pr_files() {
  gl__num "${1:-}" || gl__usage "pr-files <pr>"
  local d
  d=$(gl__diffs "$1") || exit $?
  jq -c '[ .[] | (.new_path // .old_path) ]' <<<"$d"
}

gl_pr_comments() {
  gl__num "${1:-}" || gl__usage "pr-comments <pr>"
  local n
  n=$(gl__paged "$(gl__mr_path "$1")/notes?sort=asc&order_by=created_at") || exit $?
  jq -c '[ .[] | select(.system != true)
           | {id: (.id | tostring), author: .author.username, authorType: (if .author.bot == true then "Bot" else "User" end), body: .body, createdAt: .created_at, updatedAt: (.updated_at // .created_at)} ]
         | sort_by(.createdAt)' <<<"$n"
}

gl_pr_comment() {
  gl__num "${1:-}" && [ -n "${2:-}" ] || gl__usage "pr-comment <pr> <body-file>"
  [ -r "$2" ] || { echo "body file not readable: $2" >&2; exit 66; }
  local mr note
  mr=$(gl__mr_get "$1") || exit $?
  note=$(sb_glab_api -X POST "$(gl__mr_path "$1")/notes" -f "body=$(cat "$2")") || exit $?
  jq -c --argjson n "$note" '{url: (.web_url + "#note_" + ($n.id | tostring))}' <<<"$mr"
}

gl_pr_ready() {
  gl__num "${1:-}" || gl__usage "pr-ready <pr>"
  local mr title
  mr=$(gl__mr_get "$1") || exit $?
  [ "$(jq -r '(.draft // .work_in_progress // false)' <<<"$mr")" = true ] || return 0
  title=$(jq -r '.title | sub("^\\s*(\\[draft\\]|\\(draft\\)|draft:|draft -|wip:|\\[wip\\])\\s*"; ""; "i")' <<<"$mr")
  sb_glab_api -X PUT "$(gl__mr_path "$1")" -f "title=$title" >/dev/null || exit $?
}

# pr-merge <iid> --sha <oid> [--squash|--merge|--rebase] [--delete-branch]
#          [--subject S] [--body-file F]   (subject/body: the merge or squash commit message)
gl_pr_merge() {
  local iid="${1:-}"; shift || true
  local sha="" mode="" del=0 subject="" body_file=""
  local u="pr-merge <pr> --sha <oid> [--squash|--merge|--rebase] [--delete-branch] [--subject S] [--body-file F]"
  gl__num "$iid" || gl__usage "$u"
  while [ $# -gt 0 ]; do
    case "$1" in
      --sha) sha="$2"; shift 2 ;;
      --squash|--merge) mode="${1#--}"; shift ;;
      --rebase) echo "not supported on gitlab: pr-merge --rebase" >&2; exit 64 ;;
      --delete-branch) del=1; shift ;;
      --subject) subject="$2"; shift 2 ;;
      --body-file) body_file="$2"; shift 2 ;;
      *) gl__usage "$u" ;;
    esac
  done
  [ -n "$sha" ] || gl__usage "$u"
  [ -z "$body_file" ] || [ -r "$body_file" ] || { echo "body file not readable: $body_file" >&2; exit 66; }

  # Cheap pre-check; GitLab enforces `sha` again on the PUT itself.
  local mr now
  mr=$(gl__mr_get "$iid") || exit $?
  now=$(jq -r '.sha // ""' <<<"$mr")
  case "$now" in
    "$sha"*) [ "${#sha}" -ge 7 ] || { echo "--sha must be at least 7 characters" >&2; exit 64; }
             sha="$now" ;;
    *) echo "head moved: MR !$iid head is $now, not $sha" >&2; exit 4 ;;
  esac

  local args=(-X PUT "$(gl__mr_path "$iid")/merge" -f "sha=$sha")
  [ "$mode" = squash ] && args+=(-F "squash=true")
  [ "$mode" = merge ] && args+=(-F "squash=false")
  [ "$del" -eq 1 ] && args+=(-F "should_remove_source_branch=true")
  if [ -n "$subject" ] || [ -n "$body_file" ]; then
    local msg="$subject"
    [ -n "$body_file" ] && msg="${msg:+$msg

}$(cat "$body_file")"
    if [ "$mode" = squash ]; then args+=(-f "squash_commit_message=$msg")
    else args+=(-f "merge_commit_message=$msg"); fi
  fi

  # sb_glab_api prints the response on stdout when it succeeds, on stderr when
  # not, and never retries a PUT.
  local out err rc=0 tmp
  tmp=$(mktemp)
  out=$(sb_glab_api "${args[@]}" 2>"$tmp") || rc=$?
  err=$(cat "$tmp"); rm -f "$tmp"
  if [ "$rc" -ne 0 ]; then
    if grep -qiE 'HTTP 409|409 Conflict|"409|SHA does not match' <<<"$err"; then
      echo "head moved: GitLab refused the merge of !$iid at $sha (409)" >&2
      printf '%s\n' "$err" >&2
      exit 4
    fi
    echo "merge of !$iid refused by GitLab:" >&2
    printf '%s\n' "$err" >&2
    exit 69
  fi
  if [ "$(jq -r '.state // ""' <<<"$out" 2>/dev/null)" != merged ]; then
    echo "merge of !$iid did not complete (state: $(jq -r '.state // "?"' <<<"$out" 2>/dev/null || echo '?'))" >&2
    exit 69
  fi
}

gl_checks() {
  gl__num "${1:-}" || gl__usage "checks <pr>"
  local mr pl jobs
  mr=$(gl__mr_get "$1") || exit $?
  pl=$(jq -c '.head_pipeline // .pipeline // null' <<<"$mr")
  if [ "$pl" = null ]; then echo '{"state":"NONE","checks":[]}'; return 0; fi
  jobs=$(gl__paged "projects/$(gl_pid)/pipelines/$(jq -r .id <<<"$pl")/jobs") || exit $?
  jq -c --argjson p "$pl" '
    def map_state: if . == "success" then "SUCCESS"
      elif (. == "failed" or . == "canceled") then "FAILURE"
      elif . == "skipped" then "NONE"
      else "PENDING" end;
    def job_state: if (.status == "failed" and .allow_failure == true) then "NEUTRAL"
      elif (.status == "manual" and .allow_failure == true) then "SKIPPED"
      elif .status == "skipped" then "SKIPPED"
      else (.status | map_state) end;
    {state: ($p.status | map_state),
     checks: [ .[] | {name: .name, state: job_state, url: .web_url} ]}' <<<"$jobs"
}

gl_default_branch() {
  local pid p
  pid=$(gl_pid) || exit $?
  p=$(sb_glab_api "projects/$pid") || exit $?
  jq -er '.default_branch // empty' <<<"$p" || { echo "project $GL_PROJECT has no default branch" >&2; exit 69; }
}

# Not through sb_glab_api: `glab auth status` is not an API call.
gl_auth_check() {
  if ! command -v glab >/dev/null 2>&1; then
    echo "glab is not installed — install it, then run: glab auth login --hostname $FORGE_HOST" >&2
    exit 69
  fi
  glab auth status --hostname "$FORGE_HOST" >/dev/null 2>&1 || {
    echo "glab is not logged in to $FORGE_HOST — run: glab auth login --hostname $FORGE_HOST" >&2
    exit 69
  }
}
