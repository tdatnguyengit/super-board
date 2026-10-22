# GitLab

super-board runs on GitLab as well as GitHub. Every board, issue and merge-request call
goes through `super-board-forge.sh`, and the config key `forge` picks the backend. The
verbs, JSON shapes and exit codes are in [the forge contract](forge-contract.md); this page
covers what is different on GitLab.

## Setup

1. Install [`glab`](https://gitlab.com/gitlab-org/cli), the official GitLab CLI. Any recent
   release works: super-board needs `glab api` with `--hostname`, `--paginate` and
   `--include` (`glab api --help` lists them). The GitLab backend calls nothing else.
2. Sign in once per host:

   ```bash
   glab auth login --hostname gitlab.com            # or your self-managed host
   ```

3. Use a personal (or project/group) access token with the **`api`** scope. `read_api` is
   not enough: workers move cards, comment, open and merge merge requests.
4. `jq`, bash 3.2+ and Python 3.9+ are needed, as on GitHub. `gh` is not.

`super-board-forge.sh auth-check` exits 0 when `glab` can reach the host, or 69 with the
exact fix command on stderr.

## Config

In `.claude/super-board/configs/<slug>.json`:

```jsonc
"forge": "gitlab",
"forge_host": null,                 // null → gitlab.com; self-managed: "gitlab.example.com"
"gitlab": {
  "project": "group/sub/app",       // full project path; required
  "column_label_prefix": "sb::",    // column labels: sb::Backlog, sb::Ready, …
  "board_id": null,                 // filled by onboarding; informational
  "require_pipeline": true          // false: an MR with no pipeline merges on verify_commands alone
}
```

`project.owner` and `project.number` are GitHub-only and ignored here. `SB_FORGE=gitlab`
overrides the config (tests use it).

### Self-managed GitLab

Set `forge_host` to the host name only (no scheme, no path) and sign `glab` in to that
host. Every API call passes `--hostname <forge_host>`, so one machine can work GitLab.com
and a self-managed instance side by side.

## Board and labels

GitLab boards are label lists, so a column is a label:

| Column | On GitLab |
|---|---|
| Backlog, Ready, Building, QA, Review, Blocked | exactly one label `<prefix><Column>`, e.g. `sb::Ready` |
| Done | the issue is **closed** (its column label is removed) |

Moving a card swaps the label in one edit. Issue numbers are GitLab `iid`s, the number you
see in the UI. Claims use the issue's assignee, as on GitHub.

## Free vs Premium

super-board needs only GitLab Free.

- **Scoped labels** (`sb::…` being mutually exclusive) are Premium. On Free, `sb::Ready` is
  an ordinary label whose name contains `::`; super-board keeps one column label per
  issue itself, so nothing breaks. Change `column_label_prefix` if you prefer plain names.
- **Blocking issue links** ("blocks" / "is blocked by") are Premium. super-board does not
  use them: blocked cards sit in the Blocked column and name their blocker in the body.
- **Multiple boards, swimlanes, WIP limits** are not used.

## Rate limits

GitLab reports its limits per minute, in response headers on every call. The `quota`
verb reads them with one `glab api --include /user` call:

| Header | Meaning |
|---|---|
| `RateLimit-Limit` | requests allowed in the window |
| `RateLimit-Remaining` | requests left |
| `RateLimit-Reset` | epoch seconds when the window resets |
| `Retry-After` | seconds to wait, sent with a `429 Too Many Requests` |

`quota` prints `{remaining, limit, resetAt, kind:"rest"}`. A 429 reads as `remaining: 0`
with `resetAt` at the later of `RateLimit-Reset` and now + `Retry-After`. A self-managed
instance with no limits configured sends no headers: `remaining: 1000000, limit: null`.
GitLab.com allows 2000 authenticated API requests per minute per user; self-managed
admins set their own.

The guards use these numbers instead of GitHub's hourly GraphQL bucket:

| Guard | GitLab behaviour | Default |
|---|---|---|
| Worker guard `sb_gh_guard_check` (`super-board-gh-guard.sh`) | sleeps until `resetAt` + 2s when remaining is under the threshold | threshold 10% of `RateLimit-Limit` (200 on GitLab.com), floor 10; sleep clamped to 5–120s. `SB_GL_GUARD_MIN_REMAINING=N` sets the threshold. The GitHub argument (`200`) is ignored. |
| Wave gate `super-board-usage.sh check` | pauses the next wave (exit 10, `window: "gitlab"`, `resets_at`) under the same threshold, before the Claude usage reading | same threshold |
| Throttle `super-board-throttle.sh` | a hit narrows `max_workers` one step (unlimited → 3 → 2 → 1) | hit = `remaining` 0 (a 429), or a lane result naming a 429, "Too Many Requests" or `Retry-After` |

The guard finds the forge from `SB_FORGE`, then the `forge` key of `$SB_CONFIG`, then the
repo's only board config, else GitHub. Each reading costs one request from the window.

## Merge requests and the merge gate

Pull-request verbs (`pr-*`) map to merge requests; `<pr>` is the MR `iid`.
`pr-merge <pr> --sha <oid>` sends GitLab's `sha` merge parameter, so GitLab refuses the
merge when the source branch moved after review; the verb exits 4, as on GitHub, and the
merge gate re-reviews. `checks` reads the pipeline of the MR's current head commit (an older commit's run
counts as no pipeline). `closingIssues` comes from GitLab's "closes issues" list for the
MR (`Closes #N` in the description).

The gate always runs `verify_commands` locally against the base first. On GitLab it then
also needs the head pipeline to be green, because GitLab Free merges a red pipeline unless
the project turns on "Pipelines must succeed": a failed pipeline exits 2 (back to Build), a
running or missing one exits 4 (the next wave retries). A draft MR is marked ready before
the merge, and a merge into a non-default base closes the linked issues itself.

### Without a runner

The pipeline is an extra check, not a requirement. With no runner — or on GitLab.com before
the account is verified, where every pipeline fails with "user not verified" — turn CI/CD off
for the project (Settings → General → Visibility → CI/CD, or delete `.gitlab-ci.yml`) and set
`"require_pipeline": false`. Merge requests then have no pipeline, and the gate merges on the
local `verify_commands` alone. Leaving CI on with no runner is the one setup that never
merges: the pipeline either fails or waits forever.

## Known gaps

- No GitLab GraphQL: everything is REST v4 through `glab api`.
- Card order inside a board list is not managed; super-board ranks by its own rules.
- Reopening a closed (Done) issue leaves it with no column until a card move.
- Draft issues (GitHub Project drafts) have no GitLab equivalent.
- The quota reading spends one request per check; on very low self-managed limits,
  set `SB_GL_GUARD_MIN_REMAINING` above the number of workers.
- `glab` must already be signed in to `forge_host`; super-board never stores a token.
