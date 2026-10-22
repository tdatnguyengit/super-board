#!/usr/bin/env python3
"""super-collect sources `github` and `prs` on GitLab (config `forge: gitlab`).

Same candidates as the GitHub side, read through super-board-gitlab-read.py
(`glab api` only, bounded retries):

    collect_gitlab.py issues [--max 300] [--project grp/app] [--config cfg.json]
        open issues with the GitHub issues source's fields (number,title,body,labels,url)
        give them: {"source":"github","forge":"gitlab","issues":[{number,title,body,labels:[{name}],url}]}
    collect_gitlab.py mrs [--since 14d|YYYY-MM-DD] [--max 200] [--project grp/app] [--config cfg.json]
        merged MRs in the window with every non-system note, in collect_prs.py's shape:
        {"source":"prs", "prs":[{number,title,url,mergedAt,author,comments,reviews,threads}]}
        General notes are `comments`; diff discussions are `threads` ({path, resolved,
        comments}); GitLab approvals carry no text, so `reviews` is empty.

A source that cannot be read prints {"status":"unavailable","error":…} and exits 2.
Collect is outside the board run, so the reader gets a private halt file here:
an unreachable GitLab makes this source unavailable, never halts the board.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import collect_common as cc  # noqa: E402
import collect_prs as cp  # noqa: E402

READER = "super-board-gitlab-read.py"


def reader_path():
    """The installed reader (.claude/bin), else this repo's scripts/ (development)."""
    if os.environ.get("SB_GITLAB_READ"):
        return os.environ["SB_GITLAB_READ"]
    found = cc._find_up(os.path.join(".claude", "bin", READER))
    if found:
        return found
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", "..", "..", "scripts", READER))


class Unavailable(RuntimeError):
    pass


def make_read(config=None, project=None, run=subprocess.run):
    halt_dir = tempfile.mkdtemp(prefix="sb-collect-gitlab-")

    def read(*args):
        cmd = [sys.executable, reader_path(), *args]
        if config:
            cmd += ["--config", config]
        if project:
            cmd += ["--project", project]
        env = dict(os.environ, SB_GITLAB_HALT_FILE=os.path.join(halt_dir, "halt.json"))
        r = run(cmd, capture_output=True, text=True, env=env)
        if r.returncode != 0:
            raise Unavailable(f"gitlab read {' '.join(args)} failed (exit {r.returncode}): {r.stderr.strip()[-300:]}")
        return json.loads(r.stdout)
    return read


def is_bot(login):
    login = str(login or "")
    return login.endswith("[bot]") or login.endswith("-bot") or "_bot_" in login or login.endswith("_bot")


def who(login):
    return {"login": login, "bot": is_bot(login)}


def comment(n):
    body = n.get("body") or ""
    return {"author": who(n.get("author")), "body": body[:cp.BODY_MAX], "superReview": cp.MARKER in body}


def list_issues(read, max_issues=300):
    issues = read("--kind", "issues", "--state", "opened", "--limit", str(max_issues + 1))
    shaped = [{"number": i["number"], "title": i["title"], "body": i["body"],
               "labels": [{"name": l} for l in i["labels"]], "url": i["url"]} for i in issues]
    return shaped[:max_issues], len(shaped) > max_issues


def list_mrs(read, since, max_prs=200):
    mrs = read("--kind", "mrs", "--state", "merged", "--since", since.isoformat(), "--limit", str(max_prs + 1))
    mrs = [m for m in mrs if m.get("mergedAt") and cc.since(m["mergedAt"]) >= since]
    truncated = len(mrs) > max_prs
    out = []
    for m in mrs[:max_prs]:
        comments, threads = [], []
        for d in read("--kind", "mr-discussions", "--iid", str(m["number"])):
            if d.get("path"):
                threads.append({"path": d["path"], "resolved": d.get("resolved"),
                                "comments": [comment(n) for n in d["notes"]]})
            else:
                comments += [comment(n) for n in d["notes"] if n.get("body")]
        out.append({"number": m["number"], "title": m["title"], "url": m["url"], "mergedAt": m["mergedAt"],
                    "author": who(m.get("author")), "comments": comments, "reviews": [], "threads": threads})
    return out, truncated


def project_of(cfg, override=None):
    return override or os.environ.get("SB_GITLAB_PROJECT") or ((cfg or {}).get("gitlab") or {}).get("project")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--config")
    sub = p.add_subparsers(dest="cmd", required=True)
    ip = sub.add_parser("issues")
    ip.add_argument("--max", type=int)
    ip.add_argument("--project")
    mp = sub.add_parser("mrs")
    mp.add_argument("--since")
    mp.add_argument("--max", type=int)
    mp.add_argument("--project")
    a = p.parse_args(argv)
    cfg, cfg_path = cc.active_config(a.config)
    source = "github" if a.cmd == "issues" else "prs"
    project = project_of(cfg, a.project)
    if not project:
        print(json.dumps({"source": source, "status": "unavailable", "error": "no gitlab.project in config; pass --project"}))
        return 2
    read = make_read(cfg_path, project)
    try:
        if a.cmd == "issues":
            max_issues = a.max or int(cc.collect_block(cfg, "github").get("max_issues", 300))
            issues, truncated = list_issues(read, max_issues)
            print(json.dumps({"source": "github", "forge": "gitlab", "project": project, "truncated": truncated,
                              "issues": issues}, indent=1))
            return 0
        since = cc.since(a.since, cc.window_days(cfg))
        max_prs = a.max or int(cc.collect_block(cfg, "prs").get("max_prs", 200))
        prs, truncated = list_mrs(read, since, max_prs)
    except (Unavailable, ValueError, KeyError, TypeError) as e:
        print(json.dumps({"source": source, "status": "unavailable", "error": str(e)}))
        return 2
    print(json.dumps({"source": "prs", "forge": "gitlab", "repo": project, "since": since.isoformat(),
                      "truncated": truncated,
                      "superReviewReports": sum(c["superReview"] for pr in prs for c in pr["comments"]),
                      "prs": prs}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
