# super-board-forge-gitlab-quota.sh — sourced by super-board-forge-gitlab.sh.
# Defines gl_quota; see docs/forge-contract.md (`quota`) and docs/gitlab.md (Rate limits).
# Uses sb_glab_api from the parent script. Not executable on its own.
#
# GitLab has no rate-limit endpoint: limits come back as response headers on any call.
# `glab api --include /user` is the cheapest authenticated read; its headers say
#   RateLimit-Limit      requests allowed in the current window (per minute on gitlab.com)
#   RateLimit-Remaining  requests left in it
#   RateLimit-Reset      epoch seconds when the window resets
# and, on a 429, Retry-After (seconds).
#
# Output: {remaining, limit, resetAt, kind:"rest"}.
#   - headers present  → their numbers (resetAt falls back to now+60 when Reset is absent)
#   - headers absent   → self-managed without limits: remaining 1000000, limit null, resetAt null
#   - 429 Too Many Requests → remaining 0, resetAt = later of RateLimit-Reset and now+Retry-After
#     (Retry-After defaults to 60). Exit 0: the reading itself succeeded.
# Any other failure keeps sb_glab_api's exit code (69, or 79 when reads kept failing).

# _gl_header <name> <text> — value of the first "Name: value" line, case-insensitive.
_gl_header() {
  printf '%s\n' "$2" | tr -d '\r' | awk -v k="$1" '
    BEGIN { k = tolower(k) }
    { i = index($0, ":")
      if (i > 1 && tolower(substr($0, 1, i - 1)) == k) {
        v = substr($0, i + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit } }'
}

_gl_int() { case "$1" in ''|*[!0-9]*) echo "" ;; *) echo "$1" ;; esac; }

gl_quota() {
  [ $# -eq 0 ] || { echo "usage: super-board-forge.sh quota" >&2; return 64; }
  local out rc=0 now lim rem reset ra limited=0
  out=$(sb_glab_api --include /user 2>&1) || rc=$?
  now=$(date +%s)
  if [ "$rc" -ne 0 ]; then
    if printf '%s' "$out" | grep -Eqi '(^|[^0-9])429([^0-9]|$)|too many requests'; then
      limited=1
    else
      printf '%s\n' "$out" >&2
      return "$rc"
    fi
  fi
  lim=$(_gl_int "$(_gl_header RateLimit-Limit "$out")")
  rem=$(_gl_int "$(_gl_header RateLimit-Remaining "$out")")
  reset=$(_gl_int "$(_gl_header RateLimit-Reset "$out")")
  ra=$(_gl_int "$(_gl_header Retry-After "$out")")

  if [ "$limited" -eq 1 ]; then
    local wake=$((now + ${ra:-60}))
    [ -n "$reset" ] && [ "$reset" -gt "$wake" ] && wake=$reset
    jq -nc --arg l "$lim" --argjson r "$wake" \
      '{remaining: 0, limit: (if $l == "" then null else ($l | tonumber) end), resetAt: $r, kind: "rest"}'
  elif [ -z "$rem" ]; then
    jq -nc '{remaining: 1000000, limit: null, resetAt: null, kind: "rest"}'
  else
    jq -nc --argjson rem "$rem" --arg l "$lim" --argjson r "${reset:-$((now + 60))}" \
      '{remaining: $rem, limit: (if $l == "" then null else ($l | tonumber) end), resetAt: $r, kind: "rest"}'
  fi
}
