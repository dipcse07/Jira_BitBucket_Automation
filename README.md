# AutoBotDraft

> Autonomous **Jira → Claude Code → Bitbucket draft-PR** automation.

AutoBotDraft watches Jira for AI-eligible tickets **assigned to you**, hands each one to
headless **Claude Code** to resolve on an isolated branch, pushes the result, and opens a
**DRAFT pull request** in Bitbucket — then comments the PR link back on the ticket and moves
it to *In Progress*.

> ### 🔒 Safe by design
> It **only ever opens draft PRs**. It never merges, never deploys, and never touches your
> existing local checkouts (it clones into an isolated workspace). You review and merge — always.

> ### 👤 Per-developer
> Each teammate installs it with their own Atlassian account. `list` / `run` always act on
> tickets assigned to **whoever runs them** (`assignee = currentUser()`), so you only ever see
> and touch your own work.

---

## Table of contents

- [What you get](#what-you-get)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Everyday commands](#everyday-commands)
- [Running it continuously](#running-it-continuously)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [Security](#security)
- [Repository layout](#repository-layout)

---

## What you get

A single CLI, `autofix` (plus the `autoBotDraft` watcher alias), that turns a Jira ticket
into a reviewable draft PR with zero manual coding for well-scoped changes.

- **One ticket:** `autofix run [Ticket Titel]`
- **Every eligible ticket once:** `autofix run-all`
- **Forever, every N minutes:** `autoBotDraft 5` (foreground) or `autofix install-daemon` (background, survives reboot)

## How it works

```
Jira ticket ─▶ autofix (curl REST)
                 │  fetch title/description, resolve repo from REPO_MAP
                 ▼
            isolated clone ─▶ branch feature/<KEY> off your base branch
                 │
                 ▼
            claude -p  ── implements the change, runs local linters/tests, commits
                 │
                 ▼
            git push ─▶ Bitbucket
                 │
                 ▼
            REST POST /pullrequests  {draft:true}  ─▶ DRAFT PR
                 │
                 ▼
            Jira: comment PR link + transition to In Progress
```

Every run logs the prompt, ticket JSON, diff, Claude output, and push/PR results to
`~/.config/autofix-jira/runs/<KEY>-<timestamp>/` for audit and rollback.

## Requirements

- macOS or Linux (Windows: use **WSL** or **Git Bash**)
- `git`, `curl`, `jq`
- **Claude Code CLI** (`claude`) — https://claude.com/claude-code
- Working Bitbucket git credentials (if you can `git clone` / `git push` your repos today, you're set)

## Quick start

**One command does everything** — `./install.sh` (or `autofix quickstart` if already on your
PATH) runs a single continuous, guided setup: it checks dependencies, links `autofix` onto your
PATH, collects your two API tokens, maps your Jira projects to repos, verifies that Jira **and**
Bitbucket authenticate, offers to auto-start a watcher at login, and can begin watching right
away. No separate steps to remember.

```bash
# 1. Clone this repo
git clone git@github.com:dipcse07/Jira_BitBucket_Automation.git
cd Jira_BitBucket_Automation/autofix-jira

# 2. Run the complete guided setup — that's it.
./install.sh
```

Already installed and just want to (re)configure end-to-end? Run:

```bash
autofix quickstart
```

Prefer to do it piecemeal? The individual commands still exist: `autofix setup`,
`autofix map PROJ=my-repo`, `autofix doctor`, `autofix list`, `autofix run PROJ-123`.

### What the setup wizard asks for

| Prompt | Example |
|---|---|
| Jira base URL | `https://your-team.atlassian.net` |
| Atlassian email | `you@company.com` |
| **Jira API token** | create at https://id.atlassian.com/manage-profile/security/api-tokens → **"Create API token with scopes"** → app **Jira** → `read:jira-user`, `read:jira-work`, `write:jira-work` (a plain unscoped token also works for Jira) |
| **Bitbucket API token** | a **second** token → app **Bitbucket** → `read:account`, `read:workspace:bitbucket`, `read:repository:bitbucket`, `write:repository:bitbucket`, `read:pullrequest:bitbucket`, `write:pullrequest:bitbucket` |
| Bitbucket workspace | `your-workspace` |
| Git push username | the username your existing Bitbucket HTTPS remote uses |
| Base branch | `develop` (or `main`) |

> **Two tokens are required.** Atlassian API tokens are per-product, so one token can't carry
> both Jira and Bitbucket scopes. Bitbucket app passwords were retired June 9, 2026 — a scoped
> API token is now the only way to authenticate Bitbucket's REST API.

Config is saved to `~/.config/autofix-jira/config.env` (`chmod 600`). **Never commit it.**

## Everyday commands

```bash
autofix doctor                      # verify deps + credentials
autofix map PROJ=my-repo            # map a Jira project key -> Bitbucket repo slug
autofix list                        # AI-eligible tickets assigned to you
autofix run PROJ-123                # resolve one ticket -> draft PR
autofix run-all                     # process every eligible ticket once
autofix status                      # show daemon / config state
autofix logs -f                     # follow the run log
```

`run-all` skips any ticket whose Jira project isn't in `REPO_MAP` (and prints how to map it)
and isolates failures, so one bad ticket never stops the batch.

## Running it continuously

```bash
autoBotDraft                # foreground watcher, polls every 5 min, Ctrl-C to stop
autoBotDraft 10            # ...every 10 min
autofix run-all --watch 5  # same as above, explicit form

autofix install-daemon 5   # background via launchd, survives reboot
autofix uninstall-daemon   # stop the background daemon

autofix install-login 5    # macOS: auto-open a Terminal at every login, watching in the foreground
autofix uninstall-login    # remove that login launcher
```

**Two ways to "always run":**

- `install-daemon` — headless background job (launchd/cron). No window, survives reboot, runs whether or not you're logged in to a Terminal. Stop with `uninstall-daemon`.
- `install-login` — *(macOS)* opens a **visible Terminal window at login** and runs the foreground watcher inside it, so you can see each step live. Because it runs in the foreground, it stops the moment you **close the window** or press **Ctrl-C** — and re-opens automatically next login. The first time, macOS asks permission for Terminal to control "System Events"; click OK. Start it immediately without rebooting with `open ~/.config/autofix-jira/AutoBotDraft.command`.

## Configuration

Stored in `~/.config/autofix-jira/config.env` (mode `600`).

| Key | Meaning |
|---|---|
| `JIRA_BASE_URL` | Your Jira Cloud base URL |
| `JIRA_EMAIL` | Atlassian account email (Basic-auth username for both Jira and Bitbucket) |
| `JIRA_API_TOKEN` | Jira-scoped (or unscoped) API token — used for Jira REST |
| `BITBUCKET_API_TOKEN` | Bitbucket-scoped API token — used for Bitbucket REST (draft PR). Falls back to `JIRA_API_TOKEN` if unset |
| `BITBUCKET_WORKSPACE` | Bitbucket workspace key |
| `BITBUCKET_GIT_USER` | Username pinned into the HTTPS git remote for clone/push |
| `BASE_BRANCH` | Branch to base work on and target the PR at (default `develop`) |
| `AI_LABELS` | Comma list of eligibility labels |
| `AI_TEXT` | Text the summary/description must match to be eligible |
| `REPO_MAP` | `PROJ=repo,PROJ2=repo2` — Jira project key → Bitbucket repo slug |

**Eligibility** (the `list` filter):

> assigned to **you** (`currentUser()`) **AND** not Done **AND** ( has a label in `AI_LABELS` **OR** summary/description matches `AI_TEXT` )

## Troubleshooting

- **`autofix: command not found`** — add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile and reopen the terminal.
- **Clone / push fails** — the tool uses your existing git credential helper. Run a manual
  `git clone https://<user>@bitbucket.org/<workspace>/<repo>.git` once to confirm/store creds.
  Bitbucket app passwords were retired June 9, 2026 — use a scoped **API token** (or a
  repository/workspace **Access Token**) in your credential helper.
- **PR API returns 401 / 404 (or `autofix run` fails at the PR step)** — `BITBUCKET_API_TOKEN`
  is missing Bitbucket scopes or is the wrong token. Jira and Bitbucket need **separate** tokens;
  a Jira/unscoped token will 401 against Bitbucket. Re-run `autofix setup` with a Bitbucket-app
  token that has `read/write:pullrequest:bitbucket`, and confirm with `autofix doctor` (it now
  checks Bitbucket auth too). The Basic-auth username must be your **email**.
- **Daemon run blocked by GateGuard** — run with `ECC_GATEGUARD=off`.

## Security

- The Atlassian token lives **only** in `~/.config/autofix-jira/config.env` (mode `600`) on your machine.
- The tool never writes secrets to logs and never commits the config.
- **Draft-only:** review every PR before marking it ready or merging.

## Repository layout

```
AutoBotDraft/
├── README.md            ← this guide
├── CLAUDE.md            ← context for Claude Code sessions
├── autofix-jira/        ← the tool (self-contained)
│   ├── autofix.sh       ← all logic
│   ├── install.sh       ← deps check → PATH symlinks → setup wizard
│   └── README.md        ← detailed tool reference
└── docs/                ← development history
```

For the full command reference and internals, see [`autofix-jira/README.md`](autofix-jira/README.md).

---

MIT licensed. Built with [Claude Code](https://claude.com/claude-code).
