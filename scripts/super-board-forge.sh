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
i=1
for a in "$@"; do
  if [ "$a" = --config ]; then j=$((i + 1)); CONFIG="${!j:-}"; break; fi
  i=$((i + 1))
done

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
