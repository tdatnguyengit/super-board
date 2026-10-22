#!/usr/bin/env bash
# Tests super-board-forge-detect.sh (origin URL → forge, host, project) and the
# forge-specific CLI checks: super-board-env-check.sh --cli, and super-board-setup.py
# check needing gh only for github and glab (installed, new enough, signed in) only
# for gitlab. Offline: glab is tests/fixtures/glab/fake_glab.py behind a tiny wrapper.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
# Python is a native program on Windows: hand it a Windows path to the fake, since
# sb_glab_api turns Git Bash's own path conversion off for glab's arguments.
FAKE_GLAB_PY=$(cygpath -m "$ROOT/tests/fixtures/glab/fake_glab.py" 2>/dev/null || echo "$ROOT/tests/fixtures/glab/fake_glab.py")
DETECT="$ROOT/scripts/super-board-forge-detect.sh"
EC="$ROOT/scripts/super-board-env-check.sh"
SETUP="$ROOT/scripts/super-board-setup.py"
fail() { echo "FAIL: $1" >&2; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
n=0

# 1 — the URL table. "want" is forge|host|project, exit code last.
while IFS='|' read -r url forge host project code; do
  [ -n "$url" ] || continue
  rc=0; out=$(bash "$DETECT" --remote "$url" 2>/dev/null) || rc=$?
  got="$(echo "$out" | jq -r '[.forge, .forge_host, .project] | map(. // "null") | join("|")')|$rc"
  [ "$got" = "$forge|$host|$project|$code" ] || fail "$url → $got, want $forge|$host|$project|$code"
  n=$((n + 1))
done <<'TABLE'
https://github.com/erictech/ledgerly.git|github|github.com|erictech/ledgerly|0
https://github.com/erictech/ledgerly|github|github.com|erictech/ledgerly|0
git@github.com:erictech/ledgerly.git|github|github.com|erictech/ledgerly|0
ssh://git@ssh.github.com:443/erictech/ledgerly.git|github|github.com|erictech/ledgerly|0
https://gitlab.com/acme/app.git|gitlab|gitlab.com|acme/app|0
https://gitlab.com/acme/platform/web/app.git|gitlab|gitlab.com|acme/platform/web/app|0
git@gitlab.com:acme/platform/app.git|gitlab|gitlab.com|acme/platform/app|0
https://oauth2:glpat-SECRET@gitlab.com/acme/app.git|gitlab|gitlab.com|acme/app|0
https://gitlab.example.com/group/sub/app.git|gitlab|gitlab.example.com|group/sub/app|0
https://GitLab.Example.com/group/app/|gitlab|gitlab.example.com|group/app|0
https://gitlab.corp.io:8443/team/app.git|gitlab|gitlab.corp.io:8443|team/app|0
git@gitlab.example.com:group/sub/app.git|gitlab|gitlab.example.com|group/sub/app|0
ssh://git@gitlab.example.com:2222/group/sub/app.git|gitlab|gitlab.example.com|group/sub/app|0
ssh://gitlab.example.com/group/app|gitlab|gitlab.example.com|group/app|0
https://code.acme.io/team/app.git|null|code.acme.io|team/app|3
git@git.corp.local:team/app.git|null|git.corp.local|team/app|3
/srv/repos/app.git|null|null|null|66
file:///srv/repos/app.git|null|null|null|66
TABLE

# 2 — credentials in the URL never reach stdout or stderr.
OUT=$(bash "$DETECT" --remote "https://oauth2:glpat-SECRET@gitlab.com/acme/app.git" 2>&1)
case "$OUT" in *SECRET*|*oauth2*) fail "a credential leaked: $OUT" ;; esac
n=$((n + 1))

# 3 — --assume gitlab claims an unknown self-managed host; bad --assume is usage.
bash "$DETECT" --remote https://code.acme.io/team/sub/app.git --assume gitlab \
  | jq -e '.forge == "gitlab" and .forge_host == "code.acme.io" and .project == "team/sub/app"' >/dev/null \
  || fail "--assume gitlab should claim the host"
rc=0; bash "$DETECT" --remote x --assume bitbucket >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 64 ] || fail "--assume bitbucket should exit 64, got $rc"
n=$((n + 1))

# 4 — default reads origin in --root; no origin exits 66.
R="$W/repo"; mkdir -p "$R"; git -C "$R" init -q
rc=0; bash "$DETECT" --root "$R" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 66 ] || fail "no origin should exit 66, got $rc"
git -C "$R" remote add origin git@gitlab.example.com:group/sub/app.git
bash "$DETECT" --root "$R" | jq -e '.forge == "gitlab" and .project == "group/sub/app"' >/dev/null \
  || fail "origin should be read from --root"
n=$((n + 1))

# ── CLI checks. A curated PATH: no real gh or glab can leak in from the machine.
BASE="$W/base"; mkdir -p "$BASE"
PY=$(python3 -c 'import sys; print(sys.executable)')
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    # Git Bash's `ln -s` copies, and a copied bash.exe loses its DLLs: use the tools' own
    # directories instead, after checking none of them carries a gh or glab.
    BASE=""
    for p in "$(command -v bash)" "$(command -v jq)" "$PY"; do
      d=$(dirname "$p")
      case ":$BASE:" in *":$d:"*) ;; *) BASE="${BASE:+$BASE:}$d" ;; esac
    done
    IFS=: read -r -a base_dirs <<<"$BASE"
    for d in "${base_dirs[@]}"; do
      for x in gh gh.exe glab glab.exe; do [ ! -e "$d/$x" ] || fail "curated PATH dir $d has $x"; done
    done ;;
  *)
    for t in bash git jq uname grep sort head sed tr dirname cat env apt-get dnf; do
      p=$(command -v "$t" || true); [ -n "$p" ] && ln -sf "$p" "$BASE/$t"
    done
    ln -sf "$PY" "$BASE/python3" ;;
esac
GLAB="$W/glab-bin"; mkdir -p "$GLAB"
cat > "$GLAB/glab" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = version ] && [ -n "\${FAKE_GLAB_VERSION:-}" ]; then echo "glab \$FAKE_GLAB_VERSION (2024-05-01)"; exit 0; fi
exec "$PY" "$FAKE_GLAB_PY" "\$@"
EOF
GH="$W/gh-bin"; mkdir -p "$GH"; printf '#!/bin/sh\nexit 0\n' > "$GH/gh"; chmod +x "$GLAB/glab" "$GH/gh"
# setup.py runs glab from Python, which on Windows starts only .exe/.cmd files: add a .cmd twin.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*)
  {
    printf '@echo off\r\n'
    printf 'if not "%%~1"=="version" goto run\r\n'
    printf 'if "%%FAKE_GLAB_VERSION%%"=="" goto run\r\n'
    printf 'echo glab %%FAKE_GLAB_VERSION%% ^(2024-05-01^)\r\n'
    printf 'exit /b 0\r\n'
    printf ':run\r\n'
    printf '"%s" "%s" %%*\r\n' "$(cygpath -w "$PY")" "$(cygpath -w "$FAKE_GLAB_PY")"
  } > "$GLAB/glab.cmd" ;;
esac
export FAKE_GLAB_DIR="$W/fake"; mkdir -p "$FAKE_GLAB_DIR"; echo '{}' > "$FAKE_GLAB_DIR/routes.json"
cli() { PATH="$1" bash "$EC" --cli "${@:2}"; }

# 5 — github needs gh only: present → ok; absent → the install command, exit 1. No glab asked.
cli "$BASE:$GH" --forge github | grep -qx "gh present" || fail "gh present should pass"
rc=0; OUT=$(cli "$BASE" --forge github) || rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -q "^gh missing — install: " || fail "missing gh: rc=$rc $OUT"
case "$(uname)" in Darwin) echo "$OUT" | grep -q "brew install gh" || fail "mac should brew: $OUT" ;; esac
cli "$BASE:$GH" | grep -qx "gh present" || fail "no forge should mean github"
n=$((n + 1))

# 6 — gitlab: glab missing → install command; gh is never asked for.
rc=0; OUT=$(cli "$BASE:$GH" --forge gitlab --host gitlab.example.com) || rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -q "^glab missing — install: " || fail "missing glab: rc=$rc $OUT"
echo "$OUT" | grep -q "gh " && fail "gitlab should not mention gh: $OUT"
n=$((n + 1))

# 7 — gitlab: signed in → ok with the host; auth fails → the exact fix, exit 1.
OUT=$(cli "$BASE:$GLAB" --forge gitlab --host gitlab.example.com) || fail "signed-in glab should pass: $OUT"
echo "$OUT" | grep -qx "glab auth ok gitlab.example.com" || fail "auth ok line: $OUT"
touch "$FAKE_GLAB_DIR/auth-fail"
rc=0; OUT=$(cli "$BASE:$GLAB" --forge gitlab --host gitlab.example.com) || rc=$?
[ "$rc" -eq 1 ] || fail "unauthenticated glab should exit 1, got $rc"
echo "$OUT" | grep -qx "glab auth missing gitlab.example.com — fix: glab auth login --hostname gitlab.example.com" \
  || fail "auth fix line: $OUT"
rm "$FAKE_GLAB_DIR/auth-fail"
n=$((n + 1))

# 8 — glab version: too old → upgrade, exit 1; new enough → printed.
rc=0; OUT=$(FAKE_GLAB_VERSION=1.20.3 cli "$BASE:$GLAB" --forge gitlab) || rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -q "^glab too old 1.20.3 (need 1.36.0) — upgrade: " || fail "old glab: rc=$rc $OUT"
OUT=$(FAKE_GLAB_VERSION=1.46.1 cli "$BASE:$GLAB" --forge gitlab) || fail "new glab should pass: $OUT"
echo "$OUT" | grep -qx "glab present 1.46.1" || fail "new glab should print its version: $OUT"
n=$((n + 1))

# 9 — forge and host come from the config; gitlab.com is the default host.
C="$W/cfg.json"
echo '{"forge":"gitlab","forge_host":"git.corp.io","gitlab":{"project":"a/b"}}' > "$C"
cli "$BASE:$GLAB" --config "$C" | grep -qx "glab auth ok git.corp.io" || fail "config forge_host should be used"
echo '{"forge":"gitlab","forge_host":null}' > "$C"
cli "$BASE:$GLAB" --config "$C" | grep -qx "glab auth ok gitlab.com" || fail "null forge_host → gitlab.com"
echo '{"project":{"owner":"o","number":1}}' > "$C"
cli "$BASE:$GH" --config "$C" | grep -qx "gh present" || fail "a config without forge is github"
rc=0; cli "$BASE" --forge bitbucket >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 64 ] || fail "bad forge should exit 64"
rc=0; cli "$BASE" --forge gitlab --host 'a;b' >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 64 ] || fail "bad host should exit 64"
n=$((n + 1))

# ── setup.py check: needs per forge.
needs() { PATH="$1" "$PY" "$SETUP" check --root "$2" 2>/dev/null || true; }
proj() {  # $1 dir, $2 config json or "", $3 origin or ""
  mkdir -p "$1"; git -C "$1" init -q
  [ -n "$3" ] && git -C "$1" remote add origin "$3"
  if [ -n "$2" ]; then mkdir -p "$1/.claude/super-board/configs"; echo "$2" > "$1/.claude/super-board/configs/a.json"; fi
}

# 10 — a GitHub config without gh: gh in needs, glab not (v3.1.2 behaviour).
proj "$W/p-gh" '{"version":1,"project":{"owner":"o","number":1}}' ""
OUT=$(needs "$BASE" "$W/p-gh")
echo "$OUT" | jq -e '(.needs | map(.name) | index("gh")) and ((.needs | map(.name) | index("glab")) | not)' >/dev/null \
  || fail "github config: gh needed, glab not: $OUT"
n=$((n + 1))

# 11 — a GitLab config: gh never needed; glab missing → install; signed out → auth need.
proj "$W/p-gl" '{"version":1,"forge":"gitlab","forge_host":"gitlab.example.com","gitlab":{"project":"g/s/app"}}' ""
OUT=$(needs "$BASE" "$W/p-gl")
echo "$OUT" | jq -e '(.needs | map(.name) | index("gh") | not) and (.needs[] | select(.name == "glab") | .kind == "tool")' >/dev/null \
  || fail "gitlab config without glab: $OUT"
case "$(uname)" in Darwin) echo "$OUT" | jq -e '.needs[] | select(.name == "glab") | .command == "brew install glab"' >/dev/null \
  || fail "mac glab command should be brew: $OUT" ;; esac
OUT=$(needs "$BASE:$GLAB" "$W/p-gl")
echo "$OUT" | jq -e '.needs | map(.name) | index("glab") | not' >/dev/null || fail "signed-in glab needs nothing: $OUT"
touch "$FAKE_GLAB_DIR/auth-fail"
OUT=$(needs "$BASE:$GLAB" "$W/p-gl")
echo "$OUT" | jq -e '.needs[] | select(.kind == "auth") | .name == "glab" and .command == "glab auth login --hostname gitlab.example.com"' >/dev/null \
  || fail "unauthenticated glab should need glab auth login: $OUT"
TXT=$(PATH="$BASE:$GLAB" "$PY" "$SETUP" check --root "$W/p-gl" --text 2>/dev/null || true)
echo "$TXT" | grep -q "glab isn't signed in to gitlab.example.com" || fail "text should name the host: $TXT"
rm "$FAKE_GLAB_DIR/auth-fail"
OUT=$(FAKE_GLAB_VERSION=1.10.0 needs "$BASE:$GLAB" "$W/p-gl")
echo "$OUT" | jq -e '.needs[] | select(.name == "glab") | .message | test("older than")' >/dev/null || fail "old glab need: $OUT"
n=$((n + 1))

# 12 — no config yet: the origin remote decides.
proj "$W/p-new" "" "git@gitlab.example.com:group/app.git"
OUT=$(needs "$BASE" "$W/p-new")
echo "$OUT" | jq -e '(.needs | map(.name) | index("glab")) and (.needs | map(.name) | index("gh") | not)' >/dev/null \
  || fail "gitlab origin before onboarding should need glab, not gh: $OUT"
proj "$W/p-new-gh" "" "https://github.com/o/r.git"
needs "$BASE" "$W/p-new-gh" | jq -e '.needs | map(.name) | index("gh")' >/dev/null || fail "github origin should need gh"
n=$((n + 1))

# 13 — install.sh: a GitLab origin with glab signed out prints the exact fix;
#      a GitHub origin prints nothing about either CLI.
touch "$FAKE_GLAB_DIR/auth-fail"
OUT=$(PATH="$GLAB:$PATH" bash "$ROOT/install.sh" "$W/p-new" 2>&1) || fail "install should not fail on glab: $OUT"
echo "$OUT" | grep -qx "   ! glab auth missing gitlab.example.com — fix: glab auth login --hostname gitlab.example.com" \
  || fail "install should name the glab fix: $OUT"
rm "$FAKE_GLAB_DIR/auth-fail"
OUT=$(PATH="$GLAB:$PATH" bash "$ROOT/install.sh" "$W/p-new-gh" 2>&1) || fail "install github: $OUT"
echo "$OUT" | grep -qE "glab|GitLab" && fail "a GitHub install should not mention glab: $OUT"
n=$((n + 1))

echo "PASS: test-forge-detect.sh ($n scenarios)"
