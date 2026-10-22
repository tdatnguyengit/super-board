#!/usr/bin/env bash
# Tests docs/gitlab.md (#6): it exists, covers what a GitLab user needs, and README links
# it right next to the supported-hosts link; the CI workflow runs the GitLab suites on
# all three OSes.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $1" >&2; exit 1; }
DOC=docs/gitlab.md
[ -f "$DOC" ] || fail "$DOC is missing"
for h in '## Setup' '## Config' '### Self-managed GitLab' '## Board and labels' '## Free vs Premium' \
         '## Rate limits' '## Merge requests and the merge gate' '## Known gaps'; do
  grep -qxF "$h" "$DOC" || fail "$DOC has no '$h' section"
done
for s in 'glab auth login --hostname' '`api`' 'forge_host' 'column_label_prefix' 'RateLimit-Remaining' \
         'Retry-After' 'SB_GL_GUARD_MIN_REMAINING' '--sha'; do
  grep -qF -- "$s" "$DOC" || fail "$DOC does not mention $s"
done
grep -qF '(forge-contract.md)' "$DOC" || fail "$DOC must link the forge contract"

# README: the GitLab link sits on the line after the supported-hosts link.
grep -A1 -F '(docs/hosts.md)' README.md | grep -qF '(docs/gitlab.md)' \
  || fail "README must link docs/gitlab.md next to the supported-hosts link"

# CI: a job runs the GitLab suites on ubuntu, macos and windows.
WF=.github/workflows/cross-platform.yml
JOB=$(awk '/^  gitlab:/{on=1; print; next} on && /^  [a-z]/{on=0} on' "$WF")
[ -n "$JOB" ] || fail "$WF has no gitlab job"
for os in ubuntu-latest macos-latest windows-latest; do
  echo "$JOB" | grep -q "$os" || fail "gitlab job does not run on $os"
done
echo "$JOB" | grep -qF 'tests/test-forge-*.sh' || fail "gitlab job must run tests/test-forge-*.sh"
echo "$JOB" | grep -qF 'tests/test_gitlab_*.py' || fail "gitlab job must run tests/test_gitlab_*.py"
echo "PASS: test-forge-gitlab-docs.sh"
