# Onboard step 2 on GitLab

Follow this instead of onboard step 2 (🔑 GITHUB) when the project lives on GitLab:
gitlab.com or a self-managed instance. Every other step of `onboard.md` stays the same,
except step 3's board work, which the GitLab board setup does (below).
Config keys: `config-schema.json` → `forge`, `forge_host`, `gitlab`; contract:
`docs/forge-contract.md` → Config. `SB` is the scripts folder, as in `onboard.md`.

The screen title stays `2 of 8 · 🔑 Sign in`, with `GitLab` in place of `GitHub` in its lines.

```
2. 🔑 GITLAB
   ├─ bash $SB/super-board-forge-detect.sh        (reads `git remote get-url origin`)
   │    exit 0, forge gitlab  → {forge, forge_host, project}; go to Confirm.
   │    exit 0, forge github  → back to onboard.md step 2 (this file is not for it).
   │    exit 3 (unknown host) → AskUserQuestion, header "Forge":
   │         "<forge_host> isn't github.com or gitlab.com. Where does this project live?"
   │           • GitLab (self-managed) (Recommended when the host serves GitLab)
   │           • GitHub Enterprise — not supported yet; stop here
   │         GitLab → re-run with --assume gitlab and use its output.
   │    exit 66 (no origin)   → AskUserQuestion "This project has no remote yet. Its GitLab
   │         project URL?" Then: git remote add origin <url>, and detect again.
   ├─ Confirm — one AskUserQuestion, header "GitLab":
   │      Forge:   GitLab
   │      Host:    <forge_host>
   │      Project: <project>          (full path, subgroups included)
   │    "Is this the project the board should drive?"
   │      • Yes (Recommended)
   │      • Another project or host → ask for the project URL, then
   │        bash $SB/super-board-forge-detect.sh --remote <url> --assume gitlab
   ├─ CLI and sign-in — bash $SB/super-board-env-check.sh --cli --forge gitlab --host <forge_host>
   │    `glab auth ok <host>` (exit 0) → `✓ GitLab connected (<host>).`; continue below.
   │    Otherwise STOP onboarding on the line it printed, as one 🛑 line plus the command:
   │      glab missing — install: <cmd>     → 🛑 GitLab needs the glab CLI. Run: <cmd>
   │      glab too old <v> (need <min>)     → 🛑 glab <v> is too old. Run: <cmd>
   │      glab auth missing <host> — fix: … → 🛑 glab isn't signed in to <host>. Run:
   │                                           glab auth login --hostname <host>
   │    The token needs the `api` scope (glab's login asks; a personal access token must
   │    have it). Self-managed: the same command; GITLAB_HOST=<host> also works for glab.
   │    Run the fix with Bash only when the user says so — the permission prompt asks;
   │    then run the check again. Never write, read or echo a token.
   │    Do NOT run `gh auth status` and do not ask for gh: a GitLab project never needs it.
   ├─ No second-account question: GitLab has no GraphQL points budget like GitHub's.
   └─ bot_identity: the signed-in GitLab username (`glab api user`, field `username`).
      Stage `notifications.bot_identity` for step 8.
```

## Config keys (staged for step 8, written there with everything else)

```jsonc
"forge": "gitlab",
"forge_host": null,                  // null when the host is gitlab.com, else the detected host
"gitlab": {
  "project": "<project>",            // the confirmed full path
  "column_label_prefix": "sb::",
  "board_id": null                   // the board setup fills it
},
"repo": { "path": ".", "remote": "<origin url, credentials removed>" }
```

Leave `project.owner` / `project.number` out: they are GitHub-only. Save the answers under
`answers.gitlab` = `{"host": "<forge_host>", "project": "<project>", "login": "<username>"}`
in the answers file, so a re-run skips the questions already answered.

## Then: the board (step 3)

Then run the GitLab board setup (super-board-gitlab-board-setup.sh). It finds or creates
the issue board, its column labels and lists, and writes `gitlab.board_id`. Step 3's
`board-rank` / `board-migrate` are GitHub-only; do not run them on a GitLab project.
Steps 4 onward run as written in `onboard.md`.
