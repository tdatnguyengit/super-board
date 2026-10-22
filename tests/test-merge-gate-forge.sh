#!/usr/bin/env bash
# Tests super-board-merge-gate.sh on a non-GitHub forge (SB_FORGE=gitlab), with a
# fake backend standing in for super-board-forge-gitlab.sh. No network, no glab.
#
# Pins what the gate must do itself on GitLab: refuse a red, running or missing
# pipeline (GitLab merges those unless the project requires green), mark a draft
# ready (GitLab refuses to merge one), turn the forge's pr-merge exit 4 (head
# moved) into the gate's 6 — never its own 4 — and close the linked issues after
# a merge into a base that is not the default branch.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ✅ $1"; }

setup() {
  TMP=$(mktemp -d)
  export SB_GITHUB_HALT_FILE="$TMP/halt.json" SB_GITHUB_RETRY_DELAY=0 SB_FORGE=gitlab FORGE_LOG="$TMP/forge.log"
  : > "$FORGE_LOG"
  # The kit as installed, with the GitLab backend replaced by a fake.
  mkdir -p "$TMP/kit" "$TMP/bin"
  cp "$ROOT"/scripts/super-board-*.sh "$ROOT"/scripts/super-board-*.py "$TMP/kit/"
  cat > "$TMP/kit/super-board-forge-gitlab.sh" <<'FAKE'
#!/usr/bin/env bash
# Fake GitLab backend. FAKE_PIPELINE, FAKE_DRAFT, FAKE_MERGE (ok|moved), FAKE_HEAD, FAKE_DEFAULT.
args=(); while [ $# -gt 0 ]; do [ "$1" = --config ] && { shift 2; continue; }; args+=("$1"); shift; done
set -- "${args[@]}"
printf '%s\n' "$*" >> "$FORGE_LOG"
head="$FAKE_HEAD"; state=OPEN; merged=null
if grep -q '^pr-merge' "$FORGE_LOG"; then
  case "${FAKE_MERGE:-ok}" in ok) state=MERGED; merged="\"$FAKE_HEAD\"" ;; moved) head=cafef00dcafef00dcafef00dcafef00dcafef00d ;; esac
fi
case "$1" in
  pr-view) printf '{"number":7,"title":"T","body":"Closes #3","state":"%s","isDraft":%s,"headRefName":"feat","baseRefName":"staging","headRefOid":"%s","url":"u","mergeable":"MERGEABLE","mergeCommit":%s,"closingIssues":[5],"labels":[],"additions":0,"deletions":0,"changedFiles":0}\n' \
             "$state" "${FAKE_DRAFT:-false}" "$head" "$merged" ;;
  pr-files) echo '[]' ;;
  pr-diff) : ;;
  checks) printf '{"state":"%s","checks":[]}\n' "${FAKE_PIPELINE:-SUCCESS}" ;;
  pr-ready|issue-close) : ;;
  pr-merge) case "${FAKE_MERGE:-ok}" in ok) : ;; moved) echo "head moved" >&2; exit 4 ;; esac ;;
  default-branch) echo "${FAKE_DEFAULT:-main}" ;;
  *) echo "unexpected forge call: $*" >&2; exit 64 ;;
esac
FAKE
  printf '#!/usr/bin/env bash\necho "gh must not be called on GitLab: $*" >&2\nexit 1\n' > "$TMP/bin/gh"
  chmod +x "$TMP/kit/"* "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
  ORIGIN="$TMP/origin.git"; git init -q --bare "$ORIGIN"
  git -C "$TMP" init -q -b staging 2>/dev/null || { git -C "$TMP" init -q; git -C "$TMP" checkout -q -b staging; }
  git -C "$TMP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$TMP" remote add origin "$ORIGIN"; git -C "$TMP" push -q origin staging
  git -C "$TMP" checkout -q -b feat
  git -C "$TMP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m feat
  git -C "$TMP" push -q origin feat; git -C "$TMP" checkout -q staging
  export FAKE_HEAD; FAKE_HEAD=$(git -C "$TMP" rev-parse feat)
  mkdir -p "$TMP/.claude/super-board/inflight"
  printf '{"forge":"gitlab","gitlab":{"project":"grp/app"%s},"base_branch":"staging","repo":{"path":"%s","remote":"https://gitlab.com/grp/app"},"verify_commands":["git diff --check"]}' \
    "${1:-}" "$TMP" > "$TMP/c.json"
}
gate() { bash "$TMP/kit/super-board-merge-gate.sh" --config "$TMP/c.json" --pr 7 --lock-timeout 6 --expect-head "$FAKE_HEAD" "$@"; }
teardown() { rm -rf "$TMP"; unset FAKE_PIPELINE FAKE_DRAFT FAKE_MERGE FAKE_DEFAULT; }

# 1 — green pipeline, non-default base: merged through the forge, linked issues closed.
setup
RC=0; gate >/dev/null 2>&1 || RC=$?
[ "$RC" = 0 ] || fail "a green MR should merge, got $RC: $(cat "$FORGE_LOG")"
grep -q "^pr-merge 7 --sha $FAKE_HEAD --squash --delete-branch" "$FORGE_LOG" || fail "merge must pin the head: $(cat "$FORGE_LOG")"
grep -q '^issue-close 5 ' "$FORGE_LOG" && grep -q '^issue-close 3 ' "$FORGE_LOG" \
  || fail "a merge into a non-default base closes closingIssues and body keywords: $(cat "$FORGE_LOG")"
teardown
ok "green pipeline merges; linked issues closed off the default branch"

# 2 — merge into the default branch leaves closing to the forge.
setup; export FAKE_DEFAULT=staging
gate >/dev/null 2>&1 || fail "default-base merge should pass"
grep -q '^issue-close' "$FORGE_LOG" && fail "the forge closes issues itself on the default branch"
teardown
ok "default base: no explicit close"

# 3 — pipeline states: failed → 2 (Build), running → 4 (stay Review), none → 4 unless no CI.
for c in FAILURE:2 PENDING:4 NONE:4; do
  setup; export FAKE_PIPELINE="${c%%:*}"
  RC=0; gate >/dev/null 2>&1 || RC=$?
  [ "$RC" = "${c##*:}" ] || fail "pipeline ${c%%:*} should exit ${c##*:}, got $RC"
  grep -q '^pr-merge' "$FORGE_LOG" && fail "no merge on pipeline ${c%%:*}"
  teardown
done
setup ',"require_pipeline":false'; export FAKE_PIPELINE=NONE
gate >/dev/null 2>&1 || fail "no pipeline with require_pipeline:false should merge"
teardown
ok "pipeline FAILURE 2 · PENDING 4 · NONE 4 unless gitlab.require_pipeline is false"

# 4 — a draft MR is marked ready before the merge.
setup; export FAKE_DRAFT=true
gate >/dev/null 2>&1 || fail "a draft MR should be readied and merged"
[ "$(grep -n '^pr-ready 7' "$FORGE_LOG" | cut -d: -f1)" -lt "$(grep -n '^pr-merge' "$FORGE_LOG" | cut -d: -f1)" ] \
  || fail "pr-ready must come before pr-merge: $(cat "$FORGE_LOG")"
teardown
ok "draft → pr-ready, then merge"

# 5 — forge pr-merge exit 4 (head moved) is the gate's 6, never its lock-timeout 4.
setup; export FAKE_MERGE=moved
RC=0; gate >/dev/null 2>&1 || RC=$?
[ "$RC" = 6 ] || fail "a head that moved at merge time should exit 6, got $RC"
teardown
ok "forge exit 4 → gate 6"

echo "PASS: test-merge-gate-forge.sh ($pass scenarios)"
