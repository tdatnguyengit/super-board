#!/usr/bin/env bash
# Tests the GitLab rate-limit path (#6): the `quota` verb reading RateLimit-* headers,
# the worker guard sleeping on a low per-minute window, the throttle narrowing the next
# wave on a 429, and the usage check pausing a GitLab wave. No network: `glab` is
# tests/fixtures/glab/fake_glab.py; with `--include` the route body carries the header
# block, a blank line and the JSON, as glab prints them.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
# Python is a native program on Windows: hand it a Windows path to the fake, since
# sb_glab_api turns Git Bash's own path conversion off for glab's arguments.
FAKE_GLAB_PY=$(cygpath -m "$KIT/tests/fixtures/glab/fake_glab.py" 2>/dev/null || echo "$KIT/tests/fixtures/glab/fake_glab.py")
FORGE="$KIT/scripts/super-board-forge.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
N=0; ok() { N=$((N + 1)); }

mkdir -p "$T/bin" "$T/glab"
printf '#!/usr/bin/env bash\nexec python3 "%s" "$@"\n' "$FAKE_GLAB_PY" > "$T/bin/glab"
chmod +x "$T/bin/glab"
export PATH="$T/bin:$PATH" FAKE_GLAB_DIR="$T/glab" SB_GLAB_BACKOFF=0
unset SB_FORGE SB_CONFIG SB_FORGE_HOST SB_GL_GUARD_MIN_REMAINING
echo '{"forge":"gitlab","forge_host":"gitlab.example.com","max_workers":3,"gitlab":{"project":"g/app"}}' > "$T/cfg.json"
NOW=$(date +%s)

# route <status> <header lines…> — GET /user answers with these headers and a user body.
route() {
  local status="$1"; shift
  python3 - "$T/glab/routes.json" "$status" "$@" <<'PY'
import json, sys
p, status, hdrs = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
line = 'HTTP/2.0 429 Too Many Requests' if status else 'HTTP/2.0 200 OK'
body = '\r\n'.join([line] + hdrs) + '\r\n\r\n' + ('{"message":"429 Too Many Requests"}' if status else '{"id":1,"username":"bot"}')
json.dump({'GET /user': {'status': status, 'body': body}}, open(p, 'w'))
PY
  rm -f "$T/glab/calls.log" "$T/glab/.served.json"
}
quota() { RC=0; OUT=$(bash "$FORGE" --config "$T/cfg.json" quota 2>"$T/err") || RC=$?; }

# 1 — headers present: their numbers, kind rest, one call to /user on the config's host.
route 0 "RateLimit-Limit: 2000" "RateLimit-Remaining: 1990" "RateLimit-Reset: $((NOW + 40))"
quota
[ "$RC" -eq 0 ] || fail "quota exit $RC: $(cat "$T/err")"
echo "$OUT" | jq -e --argjson r $((NOW + 40)) '.remaining == 1990 and .limit == 2000 and .resetAt == $r and .kind == "rest"' >/dev/null || fail "headers: $OUT"
[ "$(wc -l < "$T/glab/calls.log" | tr -d ' ')" = 1 ] || fail "quota must make exactly one call"
jq -e '.path == "/user" and .host == "gitlab.example.com" and .method == "GET"' "$T/glab/calls.log" >/dev/null || fail "call: $(cat "$T/glab/calls.log")"
ok

# 2 — header names are case-insensitive (HTTP/2 lowercases them).
route 0 "ratelimit-limit: 600" "ratelimit-remaining: 7" "ratelimit-reset: $((NOW + 5))"
quota
echo "$OUT" | jq -e '.remaining == 7 and .limit == 600' >/dev/null || fail "lowercase headers: $OUT"
ok

# 3 — no headers (self-managed without limits): large remaining, limit null.
route 0 "Content-Type: application/json"
quota
[ "$RC" -eq 0 ] || fail "no-header quota exit $RC"
echo "$OUT" | jq -e '.remaining >= 1000000 and .limit == null and .kind == "rest"' >/dev/null || fail "no headers: $OUT"
ok

# 4 — a 429: remaining 0, resetAt honours Retry-After, exit 0.
route 1 "RateLimit-Limit: 2000" "Retry-After: 30"
quota
[ "$RC" -eq 0 ] || fail "429 quota exit $RC: $(cat "$T/err")"
echo "$OUT" | jq -e --argjson n "$NOW" '.remaining == 0 and .limit == 2000 and .resetAt >= ($n + 30) and .resetAt <= ($n + 40)' >/dev/null || fail "429: $OUT"
ok

# 5 — any other failure is not a quota reading: 79 after the bounded read retries.
echo '{}' > "$T/glab/routes.json"
quota
[ "$RC" -eq 79 ] || fail "404 should exit 79, got $RC"
[ -z "$OUT" ] || fail "a failed read must print no JSON: $OUT"
ok

# ── guard ───────────────────────────────────────────────────────────────
GUARD="$KIT/scripts/super-board-gh-guard.sh"
# guard [env…] — sources the guard with sleep stubbed; prints the slept seconds or "none".
guard() {
  env "$@" bash -c '. "$1"; F="$2.slept"; sleep() { echo "$1" > "$F"; }; rm -f "$F"
    sb_gh_guard_check 200 2>/dev/null; rc=$?
    if [ -f "$F" ]; then echo "$(cat "$F") $rc"; else echo "none $rc"; fi' _ "$GUARD" "$T/g"
}

# 6 — low remaining (7 < 10% of 2000): sleeps until reset (+2s), no gh call needed.
route 0 "RateLimit-Limit: 2000" "RateLimit-Remaining: 7" "RateLimit-Reset: $((NOW + 30))"
read -r S RC < <(guard SB_CONFIG="$T/cfg.json")
[ "$RC" = 0 ] || fail "guard exit $RC"
[ "$S" != none ] && [ "$S" -ge 25 ] && [ "$S" -le 33 ] || fail "low remaining should sleep ~32s, slept $S"
ok

# 7 — healthy window: no sleep.
route 0 "RateLimit-Limit: 2000" "RateLimit-Remaining: 1500" "RateLimit-Reset: $((NOW + 30))"
read -r S RC < <(guard SB_CONFIG="$T/cfg.json")
[ "$S" = none ] && [ "$RC" = 0 ] || fail "healthy window must not sleep: $S $RC"
ok

# 8 — 429: sleeps for Retry-After; the floor of 5s applies to an almost-reset window.
route 1 "Retry-After: 45"
read -r S RC < <(guard SB_CONFIG="$T/cfg.json")
[ "$S" != none ] && [ "$S" -ge 44 ] && [ "$S" -le 48 ] || fail "429 should sleep ~47s, slept $S"
route 0 "RateLimit-Limit: 2000" "RateLimit-Remaining: 0" "RateLimit-Reset: $NOW"
read -r S RC < <(guard SB_CONFIG="$T/cfg.json")
[ "$S" = 5 ] || fail "sleep floor 5s, slept $S"
ok

# 9 — SB_GL_GUARD_MIN_REMAINING overrides the 10% default; the config is found from the
#     repo's single board config when SB_CONFIG is unset; SB_FORGE alone also works.
route 0 "RateLimit-Limit: 2000" "RateLimit-Remaining: 300" "RateLimit-Reset: $((NOW + 20))"
read -r S RC < <(guard SB_CONFIG="$T/cfg.json")
[ "$S" = none ] || fail "300 left is above 10% of 2000"
read -r S RC < <(guard SB_CONFIG="$T/cfg.json" SB_GL_GUARD_MIN_REMAINING=500)
[ "$S" != none ] || fail "SB_GL_GUARD_MIN_REMAINING=500 should sleep at 300"
mkdir -p "$T/repo/.claude/super-board/configs"; cp "$T/cfg.json" "$T/repo/.claude/super-board/configs/app.json"
git -C "$T/repo" init -q
read -r S RC < <(cd "$T/repo" && guard SB_GL_GUARD_MIN_REMAINING=500)
[ "$S" != none ] || fail "guard must find the repo's single gitlab config"
read -r S RC < <(cd "$T" && guard SB_FORGE=gitlab SB_GL_GUARD_MIN_REMAINING=500)
[ "$S" != none ] || fail "SB_FORGE=gitlab must select the GitLab guard"
ok

# 10 — an unreadable GitLab quota never means a full allowance: the guard fails.
echo '{}' > "$T/glab/routes.json"
read -r S RC < <(guard SB_CONFIG="$T/cfg.json")
[ "$RC" = 79 ] && [ "$S" = none ] || fail "unreadable quota should return 79 without sleeping: $S $RC"
ok

# 11 — summary line names the GitLab window.
route 0 "RateLimit-Limit: 2000" "RateLimit-Remaining: 1234" "RateLimit-Reset: $((NOW + 20))"
SUM=$(SB_CONFIG="$T/cfg.json" bash -c '. "$1"; sb_gh_guard_summary' _ "$GUARD")
[ "$SUM" = "[gh-guard] gitlab=1234/2000" ] || fail "summary: $SUM"
ok

# ── throttle ────────────────────────────────────────────────────────────
TH="$KIT/scripts/super-board-throttle.sh"
cfgw() { jq --argjson n "$1" '.max_workers = $n' "$T/cfg.json" > "$T/c2" && mv "$T/c2" "$T/cfg.json"; }

# 12 — a 429 reading narrows the next wave 3 → 2 and writes it.
cfgw 3; route 1 "Retry-After: 30"
OUT=$(bash "$TH" --config "$T/cfg.json")
echo "$OUT" | jq -e '.hit and .why == "gitlab remaining 0" and .from == 3 and .to == 2 and .wrote' >/dev/null || fail "throttle 429: $OUT"
[ "$(jq .max_workers "$T/cfg.json")" = 2 ] || fail "throttle must write max_workers 2"
ok

# 13 — healthy reading, clean results: no hit. A lane that failed with a GitLab 429 is a hit.
route 0 "RateLimit-Limit: 2000" "RateLimit-Remaining: 1900" "RateLimit-Reset: $((NOW + 20))"
echo '[{"number":429,"detail":"merged #429"}]' > "$T/results.json"
OUT=$(bash "$TH" --config "$T/cfg.json" --results "$T/results.json")
echo "$OUT" | jq -e '.hit == false and .to == 2' >/dev/null || fail "clean gitlab results (issue #429 is not a 429): $OUT"
for msg in 'glab: HTTP 429 Too Many Requests' 'POST /issues: 429 Too Many Requests' 'Retry-After: 60' 'status 429'; do
  cfgw 2
  jq -n --arg d "$msg" '[{number:7, detail:$d}]' > "$T/results.json"
  OUT=$(bash "$TH" --config "$T/cfg.json" --results "$T/results.json")
  echo "$OUT" | jq -e '.hit and (.why | test("GitLab")) and .to == 1' >/dev/null || fail "lane 429 ($msg): $OUT"
done
ok

# 14 — --rate takes the quota verb's JSON on GitLab; --dry-run writes nothing.
cfgw 2
echo '{"remaining":0,"limit":2000,"resetAt":1,"kind":"rest"}' > "$T/rate.json"
OUT=$(bash "$TH" --config "$T/cfg.json" --rate "$T/rate.json" --dry-run)
echo "$OUT" | jq -e '.hit and .to == 1 and .wrote == false' >/dev/null || fail "gitlab --rate: $OUT"
[ "$(jq .max_workers "$T/cfg.json")" = 2 ] || fail "dry-run must not write"
ok

# ── usage ───────────────────────────────────────────────────────────────
U="$KIT/scripts/super-board-usage.sh"
export SB_USAGE_FILE="$T/usage.json"

# 15 — GitLab window low: the wave pauses (10) until resetAt, window "gitlab".
route 0 "RateLimit-Limit: 2000" "RateLimit-Remaining: 50" "RateLimit-Reset: $((NOW + 30))"
RC=0; OUT=$(bash "$U" check --config "$T/cfg.json") || RC=$?
[ "$RC" -eq 10 ] || fail "low gitlab quota should pause, got $RC: $OUT"
echo "$OUT" | jq -e --argjson r $((NOW + 30)) '.state == "pause" and .window == "gitlab" and .resets_at == $r' >/dev/null || fail "usage pause: $OUT"
ok

# 16 — healthy GitLab window: falls through to the Claude snapshot (none here → 3).
route 0 "RateLimit-Limit: 2000" "RateLimit-Remaining: 1900" "RateLimit-Reset: $((NOW + 30))"
RC=0; OUT=$(bash "$U" check --config "$T/cfg.json") || RC=$?
[ "$RC" -eq 3 ] || fail "healthy gitlab quota should defer to the Claude reading, got $RC: $OUT"
ok

# 17 — a GitHub config never reads GitLab.
echo '{"max_workers":2}' > "$T/gh.json"; rm -f "$T/glab/calls.log"
RC=0; bash "$U" check --config "$T/gh.json" >/dev/null || RC=$?
[ "$RC" -eq 3 ] && [ ! -f "$T/glab/calls.log" ] || fail "github config must not call glab (rc $RC)"
ok

echo "PASS: test-forge-gitlab-quota.sh ($N groups: quota verb, guard, throttle, usage)"
