# autofix-jira

Autonomous **Jira → Claude Code → Bitbucket** draft-PR tool.

Point it at a Jira ticket assigned to you whose text or labels mention **AI**, and it will:
clone the right repo → branch off your base branch → let **Claude Code** implement the change →
commit → push → open a **DRAFT pull request** → comment back on the Jira ticket and move it to *In Progress*.

> **Safe by design:** it only ever opens **draft** PRs. It never merges, never deploys, and never
> touches your existing local working copies (it clones into an isolated workspace).

> **Per-developer:** each teammate installs it with their own Atlassian account. `autofix list`/`run`
> always operate on tickets assigned to **whoever is running it** (`assignee = currentUser()`).

---

## Requirements

- macOS or Linux (Windows: use **WSL** or **Git Bash**)
- `git`, `curl`, `jq`
- **Claude Code CLI** (`claude`) — https://claude.com/claude-code
- Git credentials for Bitbucket already working on your machine (so `git push` succeeds).
  If you can `git clone`/`git push` your repos today, you're set.

## Install

```bash
# unzip / clone this folder, then:
cd autofix-jira
./install.sh
```

The installer checks dependencies, links `autofix` onto your `PATH` (`~/.local/bin/autofix`),
and runs the configuration wizard.

### What setup asks for
| Prompt | Example |
|---|---|
| Jira base URL | `https://your-team.atlassian.net` |
| Atlassian email | `you@company.com` |
| **API token** | create at https://id.atlassian.com/manage-profile/security/api-tokens → **"Create API token with scopes"** → select **Jira + Bitbucket** → read/write repository & pull requests |
| Bitbucket workspace | `lookme` |
| Git push username | the username your existing Bitbucket HTTPS remote uses |
| Base branch | `develop` (or `main`) |

Config is saved to `~/.config/autofix-jira/config.env` (`chmod 600`). **Never commit it.**

## Usage

```bash
autofix doctor                      # verify deps + credentials
autofix map THER=thermometer_ios    # map a Jira project key -> Bitbucket repo slug
autofix list                        # AI-eligible tickets assigned to you
autofix run THER-203                # resolve one ticket -> draft PR
autofix run-all                     # process every eligible ticket once
autofix run-all --watch 5           # daemon: re-check & process every 5 minutes
```

`run-all` skips any ticket whose Jira project isn't in `REPO_MAP` (prints how to map it) and
isolates failures, so one bad ticket never stops the batch.

**Eligibility** (the `list` filter, configurable in `config.env`):
> assigned to **you** (`currentUser()`) **AND** not Done **AND** ( has a label in `AI_LABELS` **OR** summary/description matches `AI_TEXT` )

## How it works

```
Jira ticket ─▶ autofix (curl REST)
                 │  fetch title/description, resolve repo from REPO_MAP
                 ▼
            isolated clone ─▶ branch feature/<KEY> off base
                 │
                 ▼
            claude -p  ── implements the change, runs linters/tests, commits locally
                 │            (no remote access — harness owns git/PR)
                 ▼
            git push ─▶ Bitbucket
                 │
                 ▼
            REST POST /pullrequests  {draft:true}  ─▶ DRAFT PR
                 │
                 ▼
            Jira: add comment (PR link) + transition to In Progress
```

Every run logs prompt, ticket JSON, diff, Claude output, and push/PR results to
`~/.config/autofix-jira/runs/<KEY>-<timestamp>/` for audit and rollback.

## Configuration reference (`config.env`)

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

## Troubleshooting

- **Clone/push fails:** the tool uses your existing git credential helper. Run a manual
  `git clone https://<user>@bitbucket.org/<workspace>/<repo>.git` once to confirm/store creds.
  Bitbucket app passwords are retired — use a repository/workspace **Access Token** or API token
  configured in your credential helper.
- **PR API returns 401/404:** your API token lacks Bitbucket pull-request scopes, or the
  Basic-auth username must be your **email** (not the Bitbucket username). The branch is still
  pushed; open the PR manually.
- **`autofix: command not found`:** add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile.

## Security notes

- Token lives only in `~/.config/autofix-jira/config.env` (mode 600) on your machine.
- The tool never writes secrets to logs and never commits the config.
- Draft-only: review every PR before marking it ready / merging.

## Limitations

- Builds that need a full toolchain (e.g. iOS/Xcode, Android SDK) are validated by **CI**, not by
  this tool — it runs whatever linters/tests are available locally and otherwise defers.
- One repo per Jira project (via `REPO_MAP`). Multi-repo tickets need a manual choice.

---
MIT licensed. Generated with Claude Code.
