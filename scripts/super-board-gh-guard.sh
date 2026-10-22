#!/usr/bin/env bash
# super-board-gh-guard.sh — worker-side rate-limit etiquette.
#
# Sourced by super-board workers (Builder / Tester / Reviewer) before any
# burst of gh calls. The dispatcher's gh_rate_guard only protects the
# dispatcher's own ticks; workers run as independent claude -p sessions and
# share the same gh-auth bucket. Without this guard, a single Reviewer in
# adversarial mode can drain the 5000/hr GraphQL bucket and the next tick
# of the dispatcher (and every other worker on the same machine) opens to
# "0 remaining".
#
# Usage from a worker:
#   source scripts/super-board-gh-guard.sh
#   sb_gh_guard_check 200     # sleep until reset if GraphQL remaining < 200
#   sb_gh_budget_spend 5      # decrement worker-local call budget; halt if 0
#   sb_gh_guard_summary       # log remaining quota; safe to call frequently
#
# Constants
SB_GH_GUARD_MIN_REMAINING_DEFAULT=200
SB_GH_GUARD_REST_MIN_REMAINING=500
SB_GH_GUARD_BUDGET_DEFAULT=150     # per-worker soft cap on gh calls
SB_GH_GUARD_SUBAGENT_BUDGET=50     # per adversarial-mode sub-agent cap
SB_GH_GUARD_STATE_FILE="${SB_GH_GUARD_STATE_FILE:-${TMPDIR:-/tmp}/super-board-gh-budget-$$}"

# This file's own path: BASH_SOURCE under bash, the %x prompt escape under zsh.
if [ -n "${BASH_SOURCE[0]:-}" ]; then _sb_guard_src="${BASH_SOURCE[0]}"; else eval '_sb_guard_src="${(%):-%x}"'; fi
SB_GITHUB_READ="$(cd "$(dirname "$_sb_guard_src")" && pwd)/super-board-github-read.py"; unset _sb_guard_src
SB_FORGE_SH="$(dirname "$SB_GITHUB_READ")/super-board-forge.sh"
sb_gh_required_read() { local kind="$1"; shift; python3 "$SB_GITHUB_READ" --kind "$kind" -- "$@"; }
sb_gh_halt_check() { python3 "$SB_GITHUB_READ" --check; }

# `gh api rate_limit` (REST) misreports the GraphQL bucket. Measured 2026-10-04,
# back to back on one token: REST said graphql used=2 remaining=4998 while
# GraphQL's own rateLimit said used=930 — and an hour earlier REST said 4999
# while the board was stalled at 0. So the GraphQL numbers come from GraphQL's
# rateLimit object (a rateLimit-only query is not charged), the core numbers
# from REST. Arg 1: the REST payload; prints it with .resources.graphql replaced
# when the GraphQL read succeeds, unchanged when it does not.
sb_gh_quota_merge() {
  local rest="$1" gql
  gql=$(gh api graphql -f query='query{rateLimit{limit remaining used resetAt}}' 2>/dev/null) || { echo "$rest"; return 0; }
  echo "$rest" | jq --argjson g "$gql" '
    ($g.data.rateLimit // null) as $r
    | if $r == null then . else
        .resources.graphql = { limit: $r.limit, remaining: $r.remaining, used: $r.used,
                               reset: ($r.resetAt | fromdateiso8601) } end' 2>/dev/null || echo "$rest"
}

# ── GitLab ──────────────────────────────────────────────────────────────
# GitLab limits are per MINUTE and come back in response headers; the forge's
# `quota` verb reads them ({remaining, limit, resetAt, kind:"rest"}, see
# super-board-forge-gitlab-quota.sh). Thresholds (docs/gitlab.md → Rate limits):
#   pause when remaining < SB_GL_GUARD_MIN_REMAINING, default 10% of RateLimit-Limit
#   (gitlab.com's 2000/min authenticated API limit → 200), never below 10;
#   sleep until resetAt + 2s, clamped to 5..120s (a GitLab window is one minute;
#   a 429's Retry-After is folded into resetAt by the quota verb).
# The GitHub threshold argument callers pass (200 of an hourly bucket) does not
# apply to a per-minute window and is ignored on GitLab.
SB_GL_GUARD_FLOOR=10
SB_GL_GUARD_PCT=10
SB_GL_GUARD_SLEEP_MIN=5
SB_GL_GUARD_SLEEP_MAX=120

# sb_forge_config — the board config to read `forge` from: $SB_CONFIG, else the only
# config under <repo>/.claude/super-board/configs/. Prints nothing when there is none.
sb_forge_config() {
  if [ -n "${SB_CONFIG:-}" ]; then echo "$SB_CONFIG"; return 0; fi
  local top dir found
  top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$PWD
  dir="$top/.claude/super-board/configs"
  [ -d "$dir" ] || return 0
  found=$(find "$dir" -maxdepth 1 -type f -name '*.json' 2>/dev/null)
  [ -n "$found" ] && [ "$(printf '%s\n' "$found" | wc -l | tr -d ' ')" = 1 ] && echo "$found"
  return 0
}

# sb_forge_name — "github" or "gitlab": $SB_FORGE, else the config's `forge`, else github.
sb_forge_name() {
  local f="${SB_FORGE:-}" c
  if [ -z "$f" ]; then
    c=$(sb_forge_config)
    if [ -n "$c" ] && [ -r "$c" ]; then f=$(jq -r '.forge // "github"' "$c" 2>/dev/null || true); fi
  fi
  echo "${f:-github}"
}

# sb_forge_quota — the forge `quota` verb's JSON; non-zero when it cannot be read.
sb_forge_quota() {
  local c f
  c=$(sb_forge_config); f=$(sb_forge_name)
  if [ -n "$c" ]; then
    SB_FORGE="$f" bash "$SB_FORGE_SH" --config "$c" quota
  else
    SB_FORGE="$f" bash "$SB_FORGE_SH" quota
  fi
}

# sb_gl_threshold <limit|null> — the GitLab minimum-remaining threshold.
sb_gl_threshold() {
  local lim="${1:-null}" t
  if [ -n "${SB_GL_GUARD_MIN_REMAINING:-}" ]; then echo "$SB_GL_GUARD_MIN_REMAINING"; return 0; fi
  case "$lim" in ''|null|*[!0-9]*) echo "$SB_GL_GUARD_FLOOR"; return 0 ;; esac
  t=$((lim * SB_GL_GUARD_PCT / 100))
  [ "$t" -lt "$SB_GL_GUARD_FLOOR" ] && t=$SB_GL_GUARD_FLOOR
  echo "$t"
}

# sb_gl_guard_check — sleep until the GitLab window resets when remaining is low.
sb_gl_guard_check() {
  local q rc=0 remaining limit reset min now wait
  q=$(sb_forge_quota) || rc=$?
  if [ "$rc" -ne 0 ]; then echo "[gh-guard] GitLab quota unreadable (exit $rc)" >&2; return "$rc"; fi
  remaining=$(echo "$q" | jq -r '.remaining // 1000000')
  limit=$(echo "$q" | jq -r '.limit // "null"')
  reset=$(echo "$q" | jq -r '.resetAt // 0')
  min=$(sb_gl_threshold "$limit")
  if [ "$remaining" -lt "$min" ]; then
    now=$(date +%s)
    wait=$((reset - now + 2))
    [ "$wait" -lt "$SB_GL_GUARD_SLEEP_MIN" ] && wait=$SB_GL_GUARD_SLEEP_MIN
    [ "$wait" -gt "$SB_GL_GUARD_SLEEP_MAX" ] && wait=$SB_GL_GUARD_SLEEP_MAX
    echo "[gh-guard] GitLab low: ${remaining} left (<${min}); sleeping ${wait}s" >&2
    sleep "$wait"
  fi
  return 0
}

sb_gh_guard_check() {
  # Sleep until GraphQL quota recovers. Also checks REST.
  # Arg 1: optional minimum-remaining threshold (default 200).
  # On GitLab (sb_forge_name) the per-minute guard runs instead.
  if [ "$(sb_forge_name)" = gitlab ]; then sb_gl_guard_check; return $?; fi
  local min="${1:-$SB_GH_GUARD_MIN_REMAINING_DEFAULT}"
  local payload graphql_remaining graphql_reset rest_remaining now wait
  payload=$(sb_gh_required_read quota api rate_limit) || return $?
  payload=$(sb_gh_quota_merge "$payload")
  graphql_remaining=$(echo "$payload" | jq -r '.resources.graphql.remaining // 5000')
  rest_remaining=$(echo "$payload" | jq -r '.resources.core.remaining // 5000')

  if [ "$graphql_remaining" -lt "$min" ]; then
    graphql_reset=$(echo "$payload" | jq -r '.resources.graphql.reset // 0')
    now=$(date +%s)
    wait=$((graphql_reset - now + 10))
    [ "$wait" -lt 60 ] && wait=60
    [ "$wait" -gt 3600 ] && wait=3600
    echo "[gh-guard] GraphQL low: ${graphql_remaining} left (<${min}); sleeping ${wait}s" >&2
    sleep "$wait"
    return 0
  fi

  if [ "$rest_remaining" -lt "$SB_GH_GUARD_REST_MIN_REMAINING" ]; then
    echo "[gh-guard] REST low: ${rest_remaining} left — pausing 60s to let the token breathe" >&2
    sleep 60
  fi
}

sb_gh_guard_summary() {
  # One-line snapshot. Use in worker exit messages for trend tracking.
  local payload
  if [ "$(sb_forge_name)" = gitlab ]; then
    payload=$(sb_forge_quota 2>/dev/null || echo '{}')
    echo "[gh-guard] $(echo "$payload" | jq -r '"gitlab=\(.remaining // "?")/\(.limit // "?")"')"
    return 0
  fi
  payload=$(sb_gh_quota_merge "$(gh api rate_limit 2>/dev/null || echo '{}')")
  echo "[gh-guard] $(echo "$payload" | jq -r '"graphql=\(.resources.graphql.remaining // "?")/\(.resources.graphql.limit // "?") rest=\(.resources.core.remaining // "?")/\(.resources.core.limit // "?")"')"
}

sb_gh_budget_init() {
  # Initialize per-worker budget. Call once at worker start.
  local budget="${1:-$SB_GH_GUARD_BUDGET_DEFAULT}"
  echo "$budget" > "$SB_GH_GUARD_STATE_FILE"
}

sb_gh_budget_spend() {
  # Decrement budget by N (default 1). If exhausted, halt the worker.
  local cost="${1:-1}" remaining
  [ -f "$SB_GH_GUARD_STATE_FILE" ] || sb_gh_budget_init
  remaining=$(cat "$SB_GH_GUARD_STATE_FILE")
  remaining=$((remaining - cost))
  echo "$remaining" > "$SB_GH_GUARD_STATE_FILE"
  if [ "$remaining" -le 0 ]; then
    echo "[gh-guard] worker gh-call budget exhausted — halting to protect shared quota" >&2
    return 73
  fi
}

sb_gh_budget_remaining() {
  [ -f "$SB_GH_GUARD_STATE_FILE" ] || sb_gh_budget_init
  cat "$SB_GH_GUARD_STATE_FILE"
}
