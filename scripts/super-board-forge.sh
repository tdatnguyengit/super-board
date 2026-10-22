#!/usr/bin/env bash
# super-board-forge.sh — one entry point for board, issue and PR/MR operations.
#
# Usage: super-board-forge.sh [--config <cfg.json>] <verb> [args…]
# Verbs, output shapes and exit codes: docs/forge-contract.md.
#
# Picks the backend from SB_FORGE, else the config's `forge` key, else "github",
# and execs super-board-forge-<forge>.sh with the same arguments.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

CONFIG="${SB_CONFIG:-}"
VERB=""; skip=0
i=1
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0
  elif [ "$a" = --config ]; then j=$((i + 1)); CONFIG="${!j:-}"; skip=1
  elif [ -z "$VERB" ]; then VERB="$a"; fi
  i=$((i + 1))
done

verbs() {
  cat <<'HELP'
usage: super-board-forge.sh [--config <cfg.json>] <verb> [args…]   (JSON on stdout)
board   items · move <issue> <Column> · status <issue> · claim <issue> <login|@me>
        release <issue> <login|@me> · whoami · permission <login>
issues  issue-view <N> · issue-list [--state open|closed|all] [--label L]… [--search S] [--limit N]
        issue-comments <N> · issue-comment <N> <body-file>
        issue-create --title T --body-file F [--label L]…
        issue-edit <N> [--add-label L]… [--remove-label L]… [--body-file F]
        issue-close <N> [--reason completed|not_planned]
PRs     pr-create --head B --base B --title T --body-file F [--draft] · pr-view <N>
        pr-list [--state open|closed|merged|all] [--head B] [--search S] [--limit N]
        pr-diff <N> · pr-files <N> · pr-comments <N> · pr-comment <N> <body-file>
        pr-ready <N> · checks <N> · pr-merge (merge gate only)
repo    default-branch · auth-check · quota
exit    0 ok · 2 claim lost · 3 not on board · 4 head moved · 64 usage · 66 config
        69 forge read/write failed · 79 reads halted
HELP
}
case "$VERB" in
  "") verbs >&2; exit 64 ;;
  help|--help|-h) verbs; exit 0 ;;
esac

# Merging is the merge gate's job (policy, verification, head pin). A lane allowed
# to run this script must not be able to merge around the gate, so pr-merge needs
# SB_MERGE_GATE=1 — set by super-board-merge-gate.sh, never by an allowlist rule.
if [ "$VERB" = pr-merge ] && [ "${SB_MERGE_GATE:-}" != 1 ]; then
  echo "pr-merge runs only through super-board-merge-gate.sh" >&2; exit 64
fi

FORGE="${SB_FORGE:-}"
if [ -z "$FORGE" ] && [ -n "$CONFIG" ]; then
  [ -r "$CONFIG" ] || { echo "config not found: $CONFIG" >&2; exit 66; }
  FORGE=$(jq -r '.forge // "github"' "$CONFIG" 2>/dev/null) || { echo "config is not JSON: $CONFIG" >&2; exit 66; }
fi
FORGE="${FORGE:-github}"

case "$FORGE" in
  github|gitlab) ;;
  *) echo "unknown forge: $FORGE (expected github or gitlab)" >&2; exit 66 ;;
esac
BACKEND="$HERE/super-board-forge-$FORGE.sh"
[ -f "$BACKEND" ] || { echo "forge backend missing: $BACKEND" >&2; exit 66; }
exec bash "$BACKEND" "$@"
