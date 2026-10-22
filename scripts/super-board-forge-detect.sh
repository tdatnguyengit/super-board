#!/usr/bin/env bash
# super-board-forge-detect.sh — which forge a remote lives on, for onboarding.
#
# Usage: super-board-forge-detect.sh [--remote <url>] [--root <dir>] [--assume github|gitlab]
#
# Reads `git remote get-url origin` in --root (default: CWD) unless --remote is given.
# Prints one JSON document on stdout:
#   {"forge": "github"|"gitlab"|null, "forge_host": "<host>"|null, "project": "<path>"|null}
#
#   github.com (or ssh.github.com)          → github, project "owner/repo"
#   gitlab.com, or any host with "gitlab"   → gitlab, project = full path with subgroups
#   in its name, or --assume gitlab            ("group/sub/app")
#   anything else                           → forge null: onboarding asks (exit 3)
#
# Understands https://[user[:pw]@]host[:port]/path, ssh://[user@]host[:port]/path,
# git://host/path and scp-style [user@]host:path, with or without a trailing ".git".
# Credentials in the URL are dropped and never printed. An https port is kept in
# forge_host (it is the web host); an ssh port is not (it is only the ssh daemon's).
# docs/forge-contract.md → Config has the keys onboarding writes from this.
#
# Exit: 0 detected · 3 unknown host (forge null, forge_host set) · 64 usage
#       66 no origin remote, or the URL has no host (local path)
set -euo pipefail

REMOTE="" ROOT="." ASSUME="" HAVE_REMOTE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --remote) REMOTE="${2:-}"; HAVE_REMOTE=1; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    --assume) ASSUME="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
case "$ASSUME" in ""|github|gitlab) ;; *) echo "--assume must be github or gitlab" >&2; exit 64 ;; esac

jstr() {  # JSON string or null
  if [ -z "$1" ]; then printf 'null'; return; fi
  local s=${1//\\/\\\\}; s=${s//\"/\\\"}
  printf '"%s"' "$s"
}
emit() { printf '{"forge": %s, "forge_host": %s, "project": %s}\n' "$(jstr "$1")" "$(jstr "$2")" "$(jstr "$3")"; }

if [ "$HAVE_REMOTE" -eq 0 ]; then
  REMOTE=$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)
fi
if [ -z "$REMOTE" ]; then
  echo "no origin remote — add one, or pass --remote <url>" >&2
  emit "" "" ""; exit 66
fi

url=$REMOTE host="" path=""
case "$url" in
  http://*|https://*|ssh://*|git://*|git+ssh://*|ssh+git://*)
    scheme=${url%%://*}
    rest=${url#*://}
    auth=${rest%%/*}; path=${rest#"$auth"}
    auth=${auth##*@}                       # drop user[:password]@
    host=$auth
    if [[ "$host" == \[*\]* ]]; then       # [ipv6]:port
      port=${host##*\]}; host=${host%%\]*}; host="${host}]"; port=${port#:}
    else
      port=""; [[ "$host" == *:* ]] && { port=${host##*:}; host=${host%%:*}; }
    fi
    case "$scheme" in http|https) [ -n "$port" ] && host="$host:$port" ;; esac
    ;;
  file://*|/*|./*|../*) host="" ;;
  *:*)                                     # scp-style [user@]host:path
    hp=${url%%:*}; path=${url#*:}
    host=${hp##*@}
    [[ "$hp" == */* || ${#host} -le 1 ]] && host=""   # "dir/x:y", "C:\\x" are local paths
    ;;
esac
host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
if [ -z "$host" ]; then
  echo "remote has no host (local path?): cannot tell the forge" >&2
  emit "" "" ""; exit 66
fi
path=${path#/}; path=${path%/}; path=${path%.git}; path=${path%/}

forge=$ASSUME
if [ -z "$forge" ]; then
  bare=${host%%:*}
  case "$bare" in
    github.com|www.github.com|ssh.github.com) forge=github; host=github.com ;;
    gitlab.com|www.gitlab.com|altssh.gitlab.com) forge=gitlab; host=gitlab.com ;;
    *gitlab*) forge=gitlab ;;
  esac
fi

if [ -z "$forge" ]; then
  echo "unknown forge host: $host — ask whether it is GitHub or GitLab" >&2
  emit "" "$host" "$path"; exit 3
fi
emit "$forge" "$host" "$path"
