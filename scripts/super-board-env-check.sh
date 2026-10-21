#!/usr/bin/env bash
# super-board-env-check.sh — say which env keys exist, never what they hold.
#
# Onboarding needs to know whether SENTRY_AUTH_TOKEN, POSTHOG_PERSONAL_API_KEY
# or a migration DB URL is set. The guard-secrets hook (rightly) denies `grep`,
# `cat` or `source` on a dotenv file, so the old `grep -c '^NAME=' .env` check
# was blocked on every install that had the guard. This script reads the file
# itself and prints one word per key — present, empty or missing — so no value
# ever reaches stdout, stderr or the transcript. guard-secrets allows a plain
# call to it (see hooks/guard-secrets.py → ENV_CHECK).
#
# Usage:
#   super-board-env-check.sh [--file <dotenv>] KEY [KEY ...]
#
# --file defaults to the first that exists of .env.local, .env (in the CWD).
# Accepts `KEY=…` and `export KEY=…`; a commented line does not count.
#
# Stdout, one line per key:   KEY present | KEY empty | KEY missing
# Exit: 0 every key present · 1 at least one empty or missing · 64 usage
#
# Forge CLI mode (onboarding's sign-in step; no env file is read):
#   super-board-env-check.sh --cli [--config <cfg.json>] [--forge github|gitlab] [--host <h>]
# Forge: --forge, else the config's `forge`, else github. Host: --host, else
# `forge_host`, else github.com / gitlab.com. github needs only `gh`; gitlab needs only
# `glab`, at least SB_GLAB_MIN (default 1.36.0) when `glab version` names one, signed
# in to the host (`glab auth status --hostname <host>`). Stdout, one line each:
#   gh present | gh missing — install: <cmd>
#   glab present [<version>] | glab missing — install: <cmd>
#   glab too old <v> (need <min>) — upgrade: <cmd>
#   glab auth ok <host> | glab auth missing <host> — fix: glab auth login --hostname <host>
# Exit: 0 ready · 1 a CLI is missing, too old or not signed in · 64 usage · 66 bad config
set -euo pipefail

cli_hint() {  # install command for $1 on this OS (same table as super-board-setup.py TOOLS)
  local verb=${2:-install} fam=apt
  case "$(uname -s)" in
    Darwin) fam=mac ;; MINGW*|MSYS*|CYGWIN*) fam=win ;;
    *) command -v apt-get >/dev/null 2>&1 || { command -v dnf >/dev/null 2>&1 && fam=dnf; } ;;
  esac
  case "$1:$fam" in
    gh:mac) echo "brew $verb gh" ;; gh:dnf) echo "sudo dnf $verb -y gh" ;;
    gh:win) echo "winget $verb --id GitHub.cli -e" ;; gh:*) echo "sudo apt-get $verb -y gh" ;;
    glab:mac) echo "brew $verb glab" ;; glab:dnf) echo "sudo dnf $verb -y glab" ;;
    glab:win) echo "winget $verb --id GLab.GLab -e" ;; glab:*) echo "sudo apt-get $verb -y glab" ;;
  esac
}

if [ "${1:-}" = --cli ]; then
  shift
  FORGE="" HOST="" CFG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --config) CFG="${2:-}"; shift 2 ;;
      --forge) FORGE="${2:-}"; shift 2 ;;
      --host) HOST="${2:-}"; shift 2 ;;
      *) echo "unknown option for --cli: $1" >&2; exit 64 ;;
    esac
  done
  if [ -n "$CFG" ]; then
    [ -r "$CFG" ] || { echo "config not found: $CFG" >&2; exit 66; }
    command -v jq >/dev/null || { echo "jq is needed to read $CFG" >&2; exit 66; }
    [ -n "$FORGE" ] || FORGE=$(jq -r '.forge // empty' "$CFG" 2>/dev/null) || { echo "config is not JSON: $CFG" >&2; exit 66; }
    [ -n "$HOST" ] || HOST=$(jq -r '.forge_host // empty' "$CFG" 2>/dev/null || true)
  fi
  FORGE=${FORGE:-github}
  case "$FORGE" in
    github) HOST=${HOST:-github.com} ;;
    gitlab) HOST=${HOST:-gitlab.com} ;;
    *) echo "unknown forge: $FORGE (expected github or gitlab)" >&2; exit 64 ;;
  esac
  case "$HOST" in *[!A-Za-z0-9.:-]*) echo "invalid host: $HOST" >&2; exit 64 ;; esac
  if [ "$FORGE" = github ]; then
    command -v gh >/dev/null 2>&1 || { echo "gh missing — install: $(cli_hint gh)"; exit 1; }
    echo "gh present"; exit 0
  fi
  command -v glab >/dev/null 2>&1 || { echo "glab missing — install: $(cli_hint glab)"; exit 1; }
  MIN=${SB_GLAB_MIN:-1.36.0}
  V=$(glab version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
  if [ -n "$V" ]; then
    lowest=$(printf '%s\n%s\n' "$V" "$MIN" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)
    if [ "$lowest" != "$MIN" ]; then
      echo "glab too old $V (need $MIN) — upgrade: $(cli_hint glab upgrade)"; exit 1
    fi
    echo "glab present $V"
  else
    echo "glab present"
  fi
  if glab auth status --hostname "$HOST" >/dev/null 2>&1; then
    echo "glab auth ok $HOST"; exit 0
  fi
  echo "glab auth missing $HOST — fix: glab auth login --hostname $HOST"
  exit 1
fi

FILE=""
KEYS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 64 ;;
    *) KEYS+=("$1"); shift ;;
  esac
done
[ "${#KEYS[@]}" -gt 0 ] || { echo "usage: $0 [--file <dotenv>] KEY [KEY ...]" >&2; exit 64; }

if [ -z "$FILE" ]; then
  for f in .env.local .env; do [ -f "$f" ] && { FILE="$f"; break; }; done
fi

rc=0
for k in "${KEYS[@]}"; do
  case "$k" in
    *[!A-Za-z0-9_]*|"") echo "invalid key name: $k" >&2; exit 64 ;;
  esac
  state=missing
  if [ -n "$FILE" ] && [ -f "$FILE" ]; then
    # awk prints a single word and nothing from the value itself.
    state=$(awk -v k="$k" '
      { sub(/^[ \t]+/, ""); sub(/^export[ \t]+/, "") }
      index($0, k "=") == 1 {
        v = substr($0, length(k) + 2); gsub(/^["'\'' \t]+|["'\'' \t\r]+$/, "", v)
        s = (v == "") ? "empty" : "present"
      }
      END { print (s == "" ? "missing" : s) }' "$FILE")
  fi
  echo "$k $state"
  [ "$state" = present ] || rc=1
done
exit "$rc"
