# GitLab issues and merge requests as collect sources

When the project config says `"forge": "gitlab"`, the `github` and `prs` sources keep their names,
fingerprints and candidate shapes but read GitLab through `scripts/collect_gitlab.py`, which calls
`.claude/bin/super-board-gitlab-read.py` (`glab api` only, bounded retries). Host and project come
from the config's `forge_host` and `gitlab.project`.

| Source | Fetch on GitLab | Shape |
|---|---|---|
| `github` | `python3 $S/collect_gitlab.py issues [--max 300]` | `{"source":"github","forge":"gitlab","truncated",issues:[{number,title,body,labels:[{name}],url}]}`: the same fields as the GitHub issues source (`number,title,body,labels,url`). `number` is the issue IID. |
| `prs` | `python3 $S/collect_gitlab.py mrs --since <w> [--max 200]` | the `collect_prs.py` shape: `prs:[{number,title,url,mergedAt,author:{login,bot},comments,reviews,threads}]`. General MR notes are `comments`; diff discussions are `threads` (`path`, `resolved`); system notes are dropped; `reviews` is empty because GitLab approvals have no text. |

Everything after the fetch is unchanged: filter out issues already on the board and `source:*`
labels, adopt real work with `--adopt <n>`, and file recurring MR findings as `prs|<boundary>|<cause>`.

A read failure prints `{"status":"unavailable","error":…}` and exits 2. Collect runs outside the
board, so these reads use a private halt file: an unreachable GitLab never halts a board run.
