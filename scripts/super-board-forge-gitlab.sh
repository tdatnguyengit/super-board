#!/usr/bin/env bash
# super-board-forge-gitlab.sh — GitLab backend for super-board-forge.sh.
#
# Verbs and shapes: docs/forge-contract.md. Board/issue verbs live in
# super-board-forge-gitlab-board.sh, merge-request verbs in
# super-board-forge-gitlab-mr.sh; both are sourced here and define
# `gl_<verb>` functions (dashes become underscores: issue-view → gl_issue_view).
#
# GitLab is reached ONLY through sb_glab_api, so tests fake one command.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

CONFIG="${SB_CONFIG:-}"
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}
VERB="${1:-}"; [ -n "$VERB" ] || { echo "usage: super-board-forge.sh <verb> …" >&2; exit 64; }
shift

# ── config ──────────────────────────────────────────────────────────────
CJ='{}'
if [ -n "$CONFIG" ]; then
  [ -r "$CONFIG" ] || { echo "config not found: $CONFIG" >&2; exit 66; }
  CJ=$(cat "$CONFIG")
fi
FORGE_HOST="${SB_FORGE_HOST:-$(echo "$CJ" | jq -r '.forge_host // empty')}"
FORGE_HOST="${FORGE_HOST:-gitlab.com}"
GL_PROJECT="${SB_GITLAB_PROJECT:-$(echo "$CJ" | jq -r '.gitlab.project // empty')}"
GL_PREFIX="${SB_GITLAB_PREFIX:-$(echo "$CJ" | jq -r '.gitlab.column_label_prefix // "sb::"')}"
GL_COLUMNS="Backlog Ready Building QA Review Blocked Done"

# URL-encoded project path for /projects/:id routes.
gl_pid() {
  [ -n "$GL_PROJECT" ] || { echo "gitlab.project is not set in the config" >&2; return 66; }
  jq -rn --arg p "$GL_PROJECT" '$p | @uri'
}

# ── API helper ──────────────────────────────────────────────────────────
# sb_glab_api [-X METHOD] [--paginate] <path> [-f key=value]… [-F key=value]…
# Prints the response body. Retries 3 times on a failed read (GET) with 2s/4s
# backoff; a failed write is never retried (its outcome is unknown).
# Exit 69 on failure, 79 when reads keep failing.
sb_glab_api() {
  local method=GET a
  for a in "$@"; do case "$a" in -X) method=next ;; *) [ "$method" = next ] && method="$a" ;; esac; done
  local attempt out rc
  for attempt in 1 2 3; do
    rc=0
    out=$(glab api --hostname "$FORGE_HOST" "$@" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then printf '%s\n' "$out"; return 0; fi
    if [ "$method" != GET ]; then echo "$out" >&2; return 69; fi
    [ "$attempt" -lt 3 ] && sleep "${SB_GLAB_BACKOFF:-$((attempt * 2))}"
  done
  echo "$out" >&2
  return 79
}

# ── verbs ───────────────────────────────────────────────────────────────
[ -f "$HERE/super-board-forge-gitlab-board.sh" ] && . "$HERE/super-board-forge-gitlab-board.sh"
[ -f "$HERE/super-board-forge-gitlab-mr.sh" ] && . "$HERE/super-board-forge-gitlab-mr.sh"

FN="gl_${VERB//-/_}"
if declare -F "$FN" >/dev/null; then
  "$FN" "$@"
else
  echo "not supported on gitlab: $VERB" >&2
  exit 64
fi
