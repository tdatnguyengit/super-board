# Forge contract

Every board, issue and pull/merge-request operation goes through one entry point:

```bash
super-board-forge.sh [--config <cfg.json>] <verb> [args…]
```

The config key `forge` picks the backend: `"github"` (default, also when the key is absent)
or `"gitlab"`. `SB_FORGE` overrides the config for tests. The entry point resolves the
backend and `exec`s it with the same arguments, so a backend sees `--config` too.

| Backend | Script | Talks to |
|---|---|---|
| github | `super-board-forge-github.sh` | `gh` (board verbs via `super-board-card.sh`) |
| gitlab | `super-board-forge-gitlab.sh` → `super-board-forge-gitlab-board.sh`, `super-board-forge-gitlab-mr.sh` | `glab api` only (REST v4) |

The GitLab backend calls GitLab **only** through `sb_glab_api` (in
`super-board-forge-gitlab.sh`), which wraps `glab api --hostname "$FORGE_HOST"`. Nothing else
runs `glab`, so tests fake one command (`tests/fixtures/glab/fake_glab.py`).

## Config

```jsonc
"forge": "github",                 // "github" | "gitlab"
"forge_host": null,                // null → github.com / gitlab.com; self-managed: "gitlab.example.com"
"gitlab": {
  "project": "group/sub/app",      // full project path; required when forge is gitlab
  "column_label_prefix": "sb::",   // column labels: sb::Backlog, sb::Ready, … (plain labels on Free)
  "board_id": null                 // filled by onboarding (#3); informational
}
```

`project.owner` / `project.number` stay GitHub-only. On GitLab, Done is a **closed issue**;
every other column is exactly one label `<prefix><Column>`.

## Exit codes (all verbs)

| Code | Meaning |
|---|---|
| 0 | ok |
| 2 | claim lost: issue already assigned to someone else (assignee printed on stdout) |
| 3 | issue not on this board, or column missing |
| 4 | `pr-merge`: head moved, it is no longer `--sha` |
| 64 | usage |
| 66 | config missing or incomplete |
| 69 | forge read or write failed |
| 79 | reads halted (bounded-retry helper gave up) |

## Verbs

Column names are the board's: `Backlog Ready Building QA Review Blocked Done`.
`<issue>` and `<pr>` are numbers (GitHub `number`, GitLab `iid`). All JSON is on stdout,
one document, no trailing text. Errors go to stderr.

### Board and issues

| Verb | Output |
|---|---|
| `items` | `{items:[{id, status, labels:[name], title, content:{type:"Issue"\|"PullRequest"\|"DraftIssue", number, title, url, repository}}], totalCount}` — `status` and `labels` omitted when empty (same as `super-board-card.sh items`) |
| `move <issue> <Column>` | `moved #N → Column` |
| `status <issue>` | column name, or empty line when the card has none |
| `claim <issue> <login\|@me>` | exit 0 when the issue is now assigned to that login (already ours counts); exit 2 and the other login when someone else holds it |
| `release <issue> <login\|@me>` | removes that assignee; exit 0 when not assigned |
| `whoami` | login of the authenticated user |
| `issue-view <issue>` | `{number, title, body, state:"OPEN"\|"CLOSED", labels:[name], assignees:[login], url}` |
| `issue-list [--state open\|closed\|all] [--label L]… [--search S] [--limit N]` | `[issue-view]`, default `--state open --limit 200` |
| `issue-comments <issue>` | `[{author, body, createdAt}]` oldest first |
| `issue-comment <issue> <body-file>` | `{url}` |
| `issue-create --title T --body-file F [--label L]…` | `{number, url}` |
| `issue-edit <issue> [--add-label L]… [--remove-label L]… [--body-file F]` | nothing |
| `issue-close <issue> [--reason completed\|not_planned]` | nothing |

### Pull / merge requests

| Verb | Output |
|---|---|
| `pr-create --head B --base B --title T --body-file F [--draft]` | `{number, url}` |
| `pr-view <pr>` | `{number, title, body, state:"OPEN"\|"CLOSED"\|"MERGED", isDraft, headRefName, baseRefName, headRefOid, url, mergeable:"MERGEABLE"\|"CONFLICTING"\|"UNKNOWN", closingIssues:[N]}` |
| `pr-list [--state open\|closed\|merged\|all] [--head B] [--search S] [--limit N]` | `[pr-view]` without `body` |
| `pr-diff <pr>` | unified diff text (not JSON) |
| `pr-files <pr>` | `[path]` |
| `pr-comments <pr>` | `[{author, body, createdAt}]` oldest first |
| `pr-comment <pr> <body-file>` | `{url}` |
| `pr-ready <pr>` | nothing (draft → ready) |
| `pr-merge <pr> --sha <oid> [--squash\|--merge\|--rebase] [--delete-branch]` | nothing; exit 4 when head ≠ `--sha` |
| `checks <pr>` | `{state:"SUCCESS"\|"FAILURE"\|"PENDING"\|"NONE", checks:[{name, state, url}]}` |

### Repo and quota

| Verb | Output |
|---|---|
| `default-branch` | branch name |
| `auth-check` | exit 0, or 69 with the exact fix command on stderr |
| `quota` | `{remaining, limit, resetAt, kind}` — `resetAt` epoch seconds; `kind` `"graphql"` (GitHub) or `"rest"` (GitLab) |

## Rules for callers

- Scripts and lane prompts call `super-board-forge.sh`, never `gh issue|pr|project` directly.
  The GitHub backend and `super-board-card.sh` are the only places those commands live
  (`tests/test-forge-no-direct-gh.sh` enforces it, with a short allowlist).
- `gh api rate_limit` / GraphQL `rateLimit` reads move behind `quota`.
- A verb a backend does not support exits 64 with `not supported on <forge>: <verb>`.
