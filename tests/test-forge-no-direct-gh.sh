#!/usr/bin/env bash
# No script, lane prompt or workflow calls `gh issue|pr|project` directly (#1).
#
# Every board, issue and PR operation goes through scripts/super-board-forge.sh
# (docs/forge-contract.md), so a second forge plugs in at one place. The GitHub
# backend and super-board-card.sh are the only homes of those commands. Comment
# lines in code (`#`, `//`) are history, not calls, and are skipped.
#
# ALLOW: "<path>@@<ERE the line must match>@@<reason>". A hit is allowed only when
# both the path and the line pattern match, so an allowlisted file cannot grow a
# new direct call unnoticed.
set -euo pipefail
cd "$(dirname "$0")/.."

OWNERS='^scripts/super-board-(forge-github|card)\.sh$'
ALLOW=(
  "scripts/super-qa-file-bug.sh@@gh project item-(add|edit)@@adds the new issue to the QA board found by title and sets a fallback Status alias; no contract verb adds a card to a board"
  "scripts/super-review-file-refactor.sh@@gh project item-(add|edit)@@adds the new issue to the board and picks a holding-column alias from field-list; no contract verb adds a card"
  "skills/super-collect/scripts/super-collect-file.sh@@gh project (item-add|item-edit|view)@@places a collected issue in the board's holding column; no contract verb adds a card"
  "skills/super-board/references/rate-limit-etiquette.md@@gh (issue|pr|project) [a-z-]+.*\\|@@GraphQL price list of raw gh commands: documents what card.sh and the forge avoid"
  "skills/super-board/references/rate-limit-etiquette.md@@gh project item-list@@names the cost the board helpers replace, not a call"
  "skills/super-board/references/status.md@@gh (issue|pr|project)@@status verb's read-only guard lists the gh mutations it must never run and the reads it is built on"
  "skills/super-board/references/run-workflow.md@@Bash\\(gh (issue|pr|project)@@permission rule text, not a call"
  "skills/super-board/references/run-workflow.md@@Allowlist .gh pr merge@@permission rule text, not a call"
  "skills/super-board/references/onboard.md@@Bash\\(gh (issue|pr|project)@@permission rule text, not a call"
  "skills/super-board/references/onboard.md@@gh project (create|field-list)@@onboarding creates and inspects the GitHub board before any forge config exists"
  "skills/super-board/references/onboard.md@@gh issue, gh pr and gh project GraphQL@@explains which gh calls share the user's GraphQL bucket"
  "skills/super-board/references/second-account.md@@gh (issue|pr|project)@@GitHub-only guide to a second gh account; covers gh itself"
  "skills/super-board/references/config-schema.json@@gh (project|pr merge)@@owned by #2; comment and permission rule text, not calls"
  "skills/super-review/SKILL.md@@gh pr view <PR> --json comments@@prior-report lookup needs the comment url to edit the report in place (gh api PATCH); pr-comments has no url and there is no edit-comment verb"
  "skills/super-board/references/run.md@@gh pr view <PR> --json comments@@same prior-report lookup as super-review: needs the comment url for the in-place edit"
  "skills/super-qa/references/iteration-preamble.md@@^ *gh pr create \\\\\$@@the QA fix PR carries routing labels (auto-merge-candidate / needs-human-review); pr-create takes no --label"
  "skills/super-build/SKILL.md@@gh project list@@auto-discovery before a config exists; no forge verb lists projects"
  "skills/super-qa/SKILL.md@@gh project list@@QA board resolution by title (GitHub only); no forge verb lists projects"
)

hits=$(grep -rnE '(^|[^A-Za-z0-9_-])gh (issue|pr|project)([^A-Za-z0-9_-]|$)' scripts skills workflows 2>/dev/null || true)
bad=()
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  path=${hit%%:*}; rest=${hit#*:}; line=${rest#*:}
  [[ "$path" =~ $OWNERS ]] && continue
  case "$path" in
    *.sh|*.py|*.js) [[ "$line" =~ ^[[:space:]]*(#|//) ]] && continue ;;
  esac
  allowed=0
  for entry in "${ALLOW[@]}"; do
    a_path=${entry%%@@*}; a_rest=${entry#*@@}; a_re=${a_rest%%@@*}
    if [ "$path" = "$a_path" ] && printf '%s\n' "$line" | grep -qE "$a_re"; then allowed=1; break; fi
  done
  [ "$allowed" = 1 ] || bad+=("$hit")
done <<< "$hits"

# Every allowlist entry still earns its place.
for entry in "${ALLOW[@]}"; do
  a_path=${entry%%@@*}; a_rest=${entry#*@@}; a_re=${a_rest%%@@*}; reason=${a_rest#*@@}
  [ -n "$reason" ] && [ "$reason" != "$a_rest" ] || { echo "FAIL: allowlist entry without a reason: $entry" >&2; exit 1; }
  [ -f "$a_path" ] || { echo "FAIL: allowlisted file is gone: $a_path" >&2; exit 1; }
done

if [ "${#bad[@]}" -gt 0 ]; then
  echo "FAIL: direct gh issue|pr|project calls outside the GitHub forge backend:" >&2
  printf '  %s\n' "${bad[@]}" | cut -c1-220 >&2
  echo "Call .claude/bin/super-board-forge.sh <verb> (docs/forge-contract.md), or allowlist with a reason." >&2
  exit 1
fi
echo "PASS: test-forge-no-direct-gh.sh (no direct gh issue|pr|project outside the forge)"
