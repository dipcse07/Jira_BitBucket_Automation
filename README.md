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

- **One ticket:** `autofix run THER-203`
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

```bash
# 1. Clone this repo
git clone git@github.com:dipcse07/Jira_BitBucket_Automation.git
cd Jira_BitBucket_Automation/autofix-jira

# 2. Install — checks deps, links `autofix` onto your PATH, runs the setup wizard
./install.sh

# 3. Map your Jira project key → Bitbucket repo slug
autofix map THER=thermometer_ios

# 4. Verify everything is wired up
autofix doctor

# 5. List your AI-eligible tickets, then resolve one end-to-end
autofix list
autofix run THER-203
```

### What the setup wizard asks for

| Prompt | Example |
|---|---|
| Jira base URL | `https://your-team.atlassian.net` |
| Atlassian email | `you@company.com` |
| **API token** | create at https://id.atlassian.com/manage-profile/security/api-tokens → **"Create API token with scopes"** → select **Jira + Bitbucket** → read/write repository & pull requests |
| Bitbucket workspace | `lookme` |
| Git push username | the username your existing Bitbucket HTTPS remote uses |
| Base branch | `develop` (or `main`) |

Config is saved to `~/.config/autofix-jira/config.env` (`chmod 600`). **Never commit it.**

## Everyday commands

```bash
autofix doctor                      # verify deps + credentials
autofix map THER=thermometer_ios    # map a Jira project key -> Bitbucket repo slug
autofix list                        # AI-eligible tickets assigned to you
autofix run THER-203                # resolve one ticket -> draft PR
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
```

## Configuration

Stored in `~/.config/autofix-jira/config.env` (mode `600`).

| Key | Meaning |
|---|---|
| `JIRA_BASE_URL` | Your Jira Cloud base URL |
| `JIRA_EMAIL` / `JIRA_API_TOKEN` | Atlassian Basic-auth credentials (used for Jira **and** Bitbucket REST) |
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
  Bitbucket app passwords are retired — use a repository/workspace **Access Token** or API token in your credential helper.
- **PR API returns 401 / 404** — your API token lacks Bitbucket pull-request scopes, or the
  Basic-auth username must be your **email** (not the Bitbucket username). The branch is still
  pushed; open the PR manually.
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
