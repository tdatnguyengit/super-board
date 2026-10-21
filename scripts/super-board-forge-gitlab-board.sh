# super-board-forge-gitlab-board.sh — sourced by super-board-forge-gitlab.sh.
# Defines gl_<verb> functions; see docs/forge-contract.md. Uses sb_glab_api, gl_pid,
# GL_PREFIX and GL_COLUMNS from the parent script. Not executable on its own.
#
# The board on GitLab Free (no Status field, no exclusive scoped labels):
#   - every column except Done is exactly one plain label <prefix><Column>
#     (sb::Backlog … sb::Blocked);
#   - Done is a closed issue. A Done card keeps the column label it had, so it stays
#     findable by label; GitLab shows closed issues only in its Closed list anyway.
#   - `move` is one PUT: add the new column label, remove every other one, and
#     close (Done) or reopen (out of Done) in the same request.
#   - A card with two column labels (hand-edited in the UI) reads as the one latest
#     in board order (Blocked beats Review beats QA …), with a warning on stderr;
#     super-board-gitlab-board-setup.sh verify --fix repairs it to that one.
#
# Also defines gl_board_setup / gl_board_verify, run through
# super-board-gitlab-board-setup.sh (onboarding and the verifier), not lanes.

GL_PER_PAGE="${SB_GLAB_PER_PAGE:-100}"
GL_MAX_PAGES="${SB_GLAB_MAX_PAGES:-200}"
GL_CLAIM_SETTLE="${SB_GLAB_CLAIM_SETTLE:-1}"
GL_BOARD_NAME="${SB_GLAB_BOARD_NAME:-super-board}"

# ── helpers ─────────────────────────────────────────────────────────────
gl_uri() { jq -rn --arg v "$1" '$v | @uri'; }

# Board columns other than Done, as a JSON array (board order).
gl_cols_json() {
  local c out=()
  for c in $GL_COLUMNS; do [ "$c" = Done ] || out+=("$c"); done
  printf '%s\n' "${out[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

gl_is_column() { local c; for c in $GL_COLUMNS; do [ "$c" = "$1" ] && return 0; done; return 1; }

# jq definitions shared by every reader. $p = label prefix, $cols = columns w/o Done.
GL_JQ_DEFS='
  def colset: [ (.labels // [])[] | select(startswith($p)) | ltrimstr($p) | select(IN($cols[])) ];
  def latest: colset as $c | ([ $cols[] | select(IN($c[])) ] | last) // "";
  def status: if .state == "closed" then "Done" else latest end;
  def view: { number: .iid, title, body: (.description // ""),
              state: (if .state == "closed" then "CLOSED" else "OPEN" end),
              labels: (.labels // []), assignees: [ (.assignees // [])[].username ],
              url: .web_url };'

gl_jq() {  # gl_jq [jq flags…] <filter> — with $p and $cols bound
  local filter="${*: -1}"
  local n=$(($# - 1))
  jq "${@:1:$n}" --arg p "$GL_PREFIX" --argjson cols "$(gl_cols_json)" "$GL_JQ_DEFS $filter"
}

# GET every page of a list endpoint; prints one merged JSON array.
# $1 = path (query allowed); $2 = optional stop after this many elements.
gl_get_all() {
  local base="$1" limit="${2:-0}" sep='?' page=1 out n tmp total=0 rc
  case "$base" in *\?*) sep='&' ;; esac
  tmp=$(mktemp "${TMPDIR:-/tmp}/sb-glab.XXXXXX")
  while :; do
    rc=0; out=$(sb_glab_api "${base}${sep}per_page=${GL_PER_PAGE}&page=${page}") || rc=$?
    [ "$rc" -eq 0 ] || { rm -f "$tmp"; return "$rc"; }
    n=$(printf '%s' "$out" | jq 'if type == "array" then length else error("not a list") end' 2>/dev/null) \
      || { echo "GitLab returned a non-list for $base" >&2; rm -f "$tmp"; return 69; }
    printf '%s\n' "$out" >> "$tmp"
    total=$((total + n))
    [ "$n" -lt "$GL_PER_PAGE" ] && break
    [ "$limit" -gt 0 ] && [ "$total" -ge "$limit" ] && break
    page=$((page + 1))
    [ "$page" -le "$GL_MAX_PAGES" ] || { echo "stopped after $GL_MAX_PAGES pages of $base" >&2; break; }
  done
  jq -cs 'add // []' "$tmp"
  rm -f "$tmp"
}

gl_issue_get() {  # $1 = iid → issue JSON
  local pid; pid=$(gl_pid) || return $?
  sb_glab_api "projects/$pid/issues/$1"
}

gl_body_from_file() {  # $1 = file → contents on stdout
  [ -r "$1" ] || { echo "body file not readable: $1" >&2; return 64; }
  cat "$1"
}

# $1 = login or @me → prints "<id> <username>"
gl_resolve_user() {
  local u
  if [ "$1" = "@me" ]; then
    u=$(sb_glab_api user) || return $?
  else
    u=$(sb_glab_api "users?username=$(gl_uri "$1")") || return $?
    u=$(printf '%s' "$u" | jq -c '.[0] // empty')
    [ -n "$u" ] || { echo "no GitLab user named $1" >&2; return 69; }
  fi
  printf '%s' "$u" | jq -r '"\(.id) \(.username)"'
}

# Every issue carrying a column label (open and closed), deduped by iid, sorted.
gl_board_issues() {
  local pid col tmp all rc
  pid=$(gl_pid) || return $?
  tmp=$(mktemp "${TMPDIR:-/tmp}/sb-glab-board.XXXXXX")
  for col in $GL_COLUMNS; do
    [ "$col" = Done ] && continue
    rc=0; all=$(gl_get_all "projects/$pid/issues?labels=$(gl_uri "$GL_PREFIX$col")&state=all&order_by=created_at&sort=asc") || rc=$?
    [ "$rc" -eq 0 ] || { rm -f "$tmp"; return "$rc"; }
    printf '%s\n' "$all" >> "$tmp"
  done
  jq -cs 'add // [] | unique_by(.iid)' "$tmp"
  rm -f "$tmp"
}

# ── board verbs ─────────────────────────────────────────────────────────
gl_items() {
  [ $# -eq 0 ] || { echo "usage: items" >&2; return 64; }
  local issues
  issues=$(gl_board_issues) || return $?
  printf '%s' "$issues" | gl_jq -c --arg repo "$GL_PROJECT" '
    [ .[] | { id: (.id | tostring), title,
              content: { type: "Issue", title, number: .iid, url: .web_url, repository: $repo } }
            + (status as $s | if $s != "" then { status: $s } else {} end)
            + (if ((.labels // []) | length) > 0 then { labels: .labels } else {} end) ]
    | { items: ., totalCount: length }'
}

gl_status() {
  [ $# -eq 1 ] || { echo "usage: status <issue>" >&2; return 64; }
  local issue n
  issue=$(gl_issue_get "$1") || return $?
  n=$(printf '%s' "$issue" | gl_jq -r 'colset | length')
  if [ "$n" -gt 1 ]; then
    echo "warning: #$1 carries $n column labels ($(printf '%s' "$issue" | gl_jq -r 'colset | join(", ")')); reading the latest in board order — run super-board-gitlab-board-setup.sh verify --fix" >&2
  fi
  printf '%s' "$issue" | gl_jq -r 'status'
}

gl_move() {
  [ $# -eq 2 ] || { echo "usage: move <issue> <Column>" >&2; return 64; }
  local iid="$1" col="$2" pid issue state keep remove args
  gl_is_column "$col" || { echo "column '$col' is not on this board ($GL_COLUMNS)" >&2; return 3; }
  pid=$(gl_pid) || return $?
  issue=$(gl_issue_get "$iid") || return $?
  state=$(printf '%s' "$issue" | jq -r .state)
  args=(-X PUT "projects/$pid/issues/$iid")
  if [ "$col" = Done ]; then
    # Keep the one column label the card shows now; drop any others; close.
    keep=$(printf '%s' "$issue" | gl_jq -r 'latest')
    remove=$(gl_jq -rn --arg k "$keep" '[ $cols[] | select(. != $k) | $p + . ] | join(",")')
    args+=(-f "remove_labels=$remove")
    [ "$state" = closed ] || args+=(-f state_event=close)
  else
    remove=$(gl_jq -rn --arg k "$col" '[ $cols[] | select(. != $k) | $p + . ] | join(",")')
    args+=(-f "add_labels=$GL_PREFIX$col" -f "remove_labels=$remove")
    [ "$state" = closed ] && args+=(-f state_event=reopen)
  fi
  sb_glab_api "${args[@]}" >/dev/null || return $?
  echo "moved #$iid → $col"
}

gl_whoami() {
  [ $# -eq 0 ] || { echo "usage: whoami" >&2; return 64; }
  local u; u=$(sb_glab_api user) || return $?
  printf '%s' "$u" | jq -r '.username'
}

gl_claim() {
  [ $# -eq 2 ] || { echo "usage: claim <issue> <login|@me>" >&2; return 64; }
  local iid="$1" pid me id login issue holder
  pid=$(gl_pid) || return $?
  me=$(gl_resolve_user "$2") || return $?
  id="${me%% *}"; login="${me#* }"
  issue=$(gl_issue_get "$iid") || return $?
  holder=$(printf '%s' "$issue" | jq -r --arg me "$login" '
    [ (.assignees // [])[].username ] as $a
    | if ($a | index($me)) then "" elif ($a | length) > 0 then $a[0] else "-" end')
  [ -z "$holder" ] && return 0              # already ours
  if [ "$holder" != "-" ]; then echo "$holder"; return 2; fi
  sb_glab_api -X PUT "projects/$pid/issues/$iid" -f "assignee_ids=$id" >/dev/null || return $?
  # Two lanes can both see it free and both write; the last write holds. Re-read
  # after a moment so the earlier writer sees it lost.
  [ "$GL_CLAIM_SETTLE" = 0 ] || sleep "$GL_CLAIM_SETTLE"
  issue=$(gl_issue_get "$iid") || return $?
  holder=$(printf '%s' "$issue" | jq -r '(.assignees // [])[0].username // ""')
  [ "$holder" = "$login" ] && return 0
  echo "${holder:-unassigned}"
  return 2
}

gl_release() {
  [ $# -eq 2 ] || { echo "usage: release <issue> <login|@me>" >&2; return 64; }
  local iid="$1" pid me login issue rest
  pid=$(gl_pid) || return $?
  me=$(gl_resolve_user "$2") || return $?
  login="${me#* }"
  issue=$(gl_issue_get "$iid") || return $?
  rest=$(printf '%s' "$issue" | jq -r --arg me "$login" '
    [ (.assignees // [])[] ] as $a
    | if ([ $a[].username ] | index($me)) == null then "-"
      else ([ $a[] | select(.username != $me) | .id | tostring ] | join(",")) end')
  [ "$rest" = "-" ] && return 0              # not assigned to them
  sb_glab_api -X PUT "projects/$pid/issues/$iid" -f "assignee_ids=${rest:-0}" >/dev/null || return $?
}

# ── issue verbs ─────────────────────────────────────────────────────────
gl_issue_view() {
  [ $# -eq 1 ] || { echo "usage: issue-view <issue>" >&2; return 64; }
  local issue; issue=$(gl_issue_get "$1") || return $?
  printf '%s' "$issue" | gl_jq -c 'view'
}

gl_issue_list() {
  local state=opened search="" limit=200 labels=() q pid all
  while [ $# -gt 0 ]; do
    case "$1" in
      --state)
        case "${2:-}" in open) state=opened ;; closed) state=closed ;; all) state=all ;;
          *) echo "--state open|closed|all" >&2; return 64 ;; esac; shift 2 ;;
      --label)  labels+=("$2"); shift 2 ;;
      --search) search="$2"; shift 2 ;;
      --limit)  limit="$2"; shift 2 ;;
      *) echo "usage: issue-list [--state open|closed|all] [--label L]… [--search S] [--limit N]" >&2; return 64 ;;
    esac
  done
  case "$limit" in ''|*[!0-9]*) echo "--limit takes a number" >&2; return 64 ;; esac
  pid=$(gl_pid) || return $?
  q="state=$state&order_by=created_at&sort=desc"
  if [ "${#labels[@]}" -gt 0 ]; then
    q="$q&labels=$(gl_uri "$(IFS=,; echo "${labels[*]}")")"
  fi
  [ -n "$search" ] && q="$q&search=$(gl_uri "$search")"
  all=$(gl_get_all "projects/$pid/issues?$q" "$limit") || return $?
  printf '%s' "$all" | gl_jq -c --argjson n "$limit" '[ .[:$n][] | view ]'
}

gl_issue_comments() {
  [ $# -eq 1 ] || { echo "usage: issue-comments <issue>" >&2; return 64; }
  local pid all
  pid=$(gl_pid) || return $?
  all=$(gl_get_all "projects/$pid/issues/$1/notes?sort=asc&order_by=created_at") || return $?
  printf '%s' "$all" | jq -c '[ .[] | select((.system // false) | not)
                                | { author: .author.username, body, createdAt: .created_at } ]'
}

gl_issue_comment() {
  [ $# -eq 2 ] || { echo "usage: issue-comment <issue> <body-file>" >&2; return 64; }
  local pid body note
  pid=$(gl_pid) || return $?
  body=$(gl_body_from_file "$2") || return $?
  note=$(sb_glab_api -X POST "projects/$pid/issues/$1/notes" -f "body=$body") || return $?
  printf '%s' "$note" | jq -c --arg u "https://$FORGE_HOST/$GL_PROJECT/-/issues/$1" '{ url: "\($u)#note_\(.id)" }'
}

gl_issue_create() {
  local title="" bodyf="" labels=() pid body args out
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --body-file) bodyf="$2"; shift 2 ;;
      --label) labels+=("$2"); shift 2 ;;
      *) echo "usage: issue-create --title T --body-file F [--label L]…" >&2; return 64 ;;
    esac
  done
  [ -n "$title" ] && [ -n "$bodyf" ] || { echo "usage: issue-create --title T --body-file F [--label L]…" >&2; return 64; }
  pid=$(gl_pid) || return $?
  body=$(gl_body_from_file "$bodyf") || return $?
  args=(-X POST "projects/$pid/issues" -f "title=$title" -f "description=$body")
  [ "${#labels[@]}" -gt 0 ] && args+=(-f "labels=$(IFS=,; echo "${labels[*]}")")
  out=$(sb_glab_api "${args[@]}") || return $?
  printf '%s' "$out" | jq -c '{ number: .iid, url: .web_url }'
}

gl_issue_edit() {
  [ $# -ge 1 ] || { echo "usage: issue-edit <issue> [--add-label L]… [--remove-label L]… [--body-file F]" >&2; return 64; }
  local iid="$1" add=() rml=() bodyf="" pid body args
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --add-label) add+=("$2"); shift 2 ;;
      --remove-label) rml+=("$2"); shift 2 ;;
      --body-file) bodyf="$2"; shift 2 ;;
      *) echo "usage: issue-edit <issue> [--add-label L]… [--remove-label L]… [--body-file F]" >&2; return 64 ;;
    esac
  done
  pid=$(gl_pid) || return $?
  args=(-X PUT "projects/$pid/issues/$iid")
  [ "${#add[@]}" -gt 0 ] && args+=(-f "add_labels=$(IFS=,; echo "${add[*]}")")
  [ "${#rml[@]}" -gt 0 ] && args+=(-f "remove_labels=$(IFS=,; echo "${rml[*]}")")
  if [ -n "$bodyf" ]; then body=$(gl_body_from_file "$bodyf") || return $?; args+=(-f "description=$body"); fi
  [ "${#args[@]}" -gt 3 ] || return 0       # nothing to change
  sb_glab_api "${args[@]}" >/dev/null || return $?
}

gl_issue_close() {
  [ $# -ge 1 ] || { echo "usage: issue-close <issue> [--reason completed|not_planned]" >&2; return 64; }
  local iid="$1" pid
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) case "${2:-}" in completed|not_planned) ;; *) echo "--reason completed|not_planned" >&2; return 64 ;; esac; shift 2 ;;
      *) echo "usage: issue-close <issue> [--reason completed|not_planned]" >&2; return 64 ;;
    esac
  done
  # GitLab Free has no close reason; both close the issue.
  pid=$(gl_pid) || return $?
  sb_glab_api -X PUT "projects/$pid/issues/$iid" -f state_event=close >/dev/null || return $?
}

# ── onboarding and verifier (super-board-gitlab-board-setup.sh) ─────────
gl_label_color() {
  case "$1" in
    Backlog) echo '#828282' ;; Ready) echo '#1f75cb' ;; Building) echo '#e9be74' ;;
    QA) echo '#9370db' ;; Review) echo '#6699cc' ;; Blocked) echo '#dd2b0e' ;; *) echo '#cccccc' ;;
  esac
}

GL_CONFIG_BOARD_ID="$(printf '%s' "${CJ:-}" | jq -r '.gitlab.board_id // empty' 2>/dev/null || true)"

# Prints the board JSON (with .lists) to use: config board_id, else one named
# $GL_BOARD_NAME, else the one whose lists cover the most column labels. Empty if none.
gl_find_board() {
  local pid boards
  pid=$(gl_pid) || return $?
  boards=$(sb_glab_api "projects/$pid/boards") || return $?
  printf '%s' "$boards" | gl_jq -c --arg id "$GL_CONFIG_BOARD_ID" --arg name "$GL_BOARD_NAME" '
    def covered: [ (.lists // [])[].label.name ] as $n | [ $cols[] | $p + . | select(IN($n[])) ] | length;
    ( [ .[] | select(($id != "") and ((.id | tostring) == $id)) ][0] )
    // ( [ .[] | select(.name == $name) ][0] )
    // ( [ .[] | select(covered > 0) ] | sort_by(covered) | last )
    // empty'
}

gl_board_setup() {
  [ $# -eq 0 ] || { echo "usage: super-board-gitlab-board-setup.sh --config <cfg> setup" >&2; return 64; }
  local pid labels col name id board bid lists pos lid cur
  pid=$(gl_pid) || return $?
  labels=$(gl_get_all "projects/$pid/labels") || return $?
  for col in $GL_COLUMNS; do
    [ "$col" = Done ] && continue
    name="$GL_PREFIX$col"
    if ! printf '%s' "$labels" | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null; then
      sb_glab_api -X POST "projects/$pid/labels" -f "name=$name" -f "color=$(gl_label_color "$col")" \
        -f "description=super-board column: $col" >/dev/null || return $?
      echo "created label $name" >&2
    fi
  done
  labels=$(gl_get_all "projects/$pid/labels") || return $?

  board=$(gl_find_board) || return $?
  if [ -z "$board" ]; then
    board=$(sb_glab_api -X POST "projects/$pid/boards" -f "name=$GL_BOARD_NAME") || return $?
    echo "created board $GL_BOARD_NAME" >&2
  fi
  bid=$(printf '%s' "$board" | jq -r .id)
  lists=$(sb_glab_api "projects/$pid/boards/$bid/lists") || return $?

  pos=0
  for col in $GL_COLUMNS; do
    [ "$col" = Done ] && continue
    name="$GL_PREFIX$col"
    id=$(printf '%s' "$labels" | jq -r --arg n "$name" 'first(.[] | select(.name == $n) | .id) // empty')
    [ -n "$id" ] || { echo "label $name missing after create" >&2; return 69; }
    lid=$(printf '%s' "$lists" | jq -r --arg n "$name" 'first(.[] | select(.label.name? == $n) | .id) // empty')
    if [ -z "$lid" ]; then
      sb_glab_api -X POST "projects/$pid/boards/$bid/lists" -f "label_id=$id" >/dev/null || return $?
      echo "added list $name" >&2
      lists=$(sb_glab_api "projects/$pid/boards/$bid/lists") || return $?
      lid=$(printf '%s' "$lists" | jq -r --arg n "$name" 'first(.[] | select(.label.name? == $n) | .id) // empty')
    fi
    cur=$(printf '%s' "$lists" | jq -r --arg n "$name" 'first(.[] | select(.label.name? == $n) | .position) // empty')
    if [ -n "$lid" ] && [ "$cur" != "$pos" ]; then
      sb_glab_api -X PUT "projects/$pid/boards/$bid/lists/$lid" -f "position=$pos" >/dev/null || return $?
    fi
    pos=$((pos + 1))
  done
  gl_jq -cn --argjson b "$bid" '{ board_id: $b, labels: [ $cols[] | $p + . ] }'
}

# verify [--fix]: column labels exist, a board lists them, no card has two.
# Exit 0 when clean (or every double was fixed), 3 otherwise.
gl_board_verify() {
  local fix=0 pid labels missing board bid lists_missing issues doubles n iid keep remove
  while [ $# -gt 0 ]; do
    case "$1" in --fix) fix=1; shift ;; *) echo "usage: super-board-gitlab-board-setup.sh --config <cfg> verify [--fix]" >&2; return 64 ;; esac
  done
  pid=$(gl_pid) || return $?
  labels=$(gl_get_all "projects/$pid/labels") || return $?
  missing=$(printf '%s' "$labels" | gl_jq -c '[ .[].name ] as $have | [ $cols[] | $p + . | select(IN($have[]) | not) ]')
  board=$(gl_find_board) || return $?
  if [ -n "$board" ]; then
    bid=$(printf '%s' "$board" | jq -r .id)
    lists_missing=$(printf '%s' "$board" | gl_jq -c '[ (.lists // [])[].label.name ] as $n | [ $cols[] | $p + . | select(IN($n[]) | not) ]')
  else
    bid=null; lists_missing=$(gl_jq -cn '[ $cols[] | $p + . ]')
  fi
  issues=$(gl_board_issues) || return $?
  doubles=$(printf '%s' "$issues" | gl_jq -c '[ .[] | select((colset | length) > 1)
                                               | { number: .iid, labels: [ colset[] | $p + . ], keep: ($p + latest) } ]')
  if [ "$fix" = 1 ]; then
    n=$(printf '%s' "$doubles" | jq length)
    while [ "$n" -gt 0 ]; do
      n=$((n - 1))
      iid=$(printf '%s' "$doubles" | jq -r ".[$n].number")
      keep=$(printf '%s' "$doubles" | jq -r ".[$n].keep")
      remove=$(gl_jq -rn --arg k "$keep" '[ $cols[] | $p + . | select(. != $k) ] | join(",")')
      sb_glab_api -X PUT "projects/$pid/issues/$iid" -f "remove_labels=$remove" >/dev/null || return $?
      echo "fixed #$iid → kept $keep" >&2
    done
  fi
  local report
  report=$(jq -cn --argjson m "$missing" --argjson b "$bid" --argjson lm "$lists_missing" --argjson d "$doubles" --argjson f "$fix" '
    { ok: (($m | length) == 0 and $b != null and ($lm | length) == 0 and (($d | length) == 0 or $f == 1)),
      board_id: $b, missing_labels: $m, missing_lists: $lm, doubles: $d, fixed: ($f == 1) }')
  echo "$report"
  [ "$(printf '%s' "$report" | jq -r .ok)" = true ] || return 3
}
