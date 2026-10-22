#!/usr/bin/env bash
# super-board-gitlab-board-setup.sh — create and check the GitLab issue board.
#
# Usage:
#   super-board-gitlab-board-setup.sh --config <cfg.json> setup
#       Creates the column labels <prefix>Backlog … <prefix>Blocked when missing,
#       finds or creates the issue board (config gitlab.board_id, else one named
#       "super-board"), adds one list per label in board order. Idempotent.
#       Prints {board_id, labels:[…]}; onboarding saves board_id as gitlab.board_id.
#   super-board-gitlab-board-setup.sh --config <cfg.json> verify [--fix]
#       Prints {ok, board_id, missing_labels, missing_lists, doubles:[{number, labels, keep}], fixed}.
#       A card with two or more column labels is a "double"; --fix keeps the one
#       `super-board-forge.sh status` reports (latest in board order) and removes the rest.
#
# Done is a closed issue, so it has no label and no list (GitLab's Closed list).
# GitLab is reached only through sb_glab_api: this runs the GitLab backend with
# its internal board-setup / board-verify verbs.
#
# Exit: 0 ok · 3 verify found problems (not fixed) · 64 usage · 66 config ·
#       69 GitLab read/write failed · 79 reads halted.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

CONFIG="${SB_CONFIG:-}"
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}
[ -n "$CONFIG" ] || { echo "usage: super-board-gitlab-board-setup.sh --config <cfg.json> setup|verify [--fix]" >&2; exit 64; }
VERB="${1:-}"; shift || true
case "$VERB" in
  setup)  exec bash "$HERE/super-board-forge-gitlab.sh" --config "$CONFIG" board-setup "$@" ;;
  verify) exec bash "$HERE/super-board-forge-gitlab.sh" --config "$CONFIG" board-verify "$@" ;;
  *) echo "usage: super-board-gitlab-board-setup.sh --config <cfg.json> setup|verify [--fix]" >&2; exit 64 ;;
esac
