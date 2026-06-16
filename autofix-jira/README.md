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

`./install.sh` runs **one continuous guided setup** (`autofix quickstart`): it checks
dependencies, links `autofix`/`autoBotDraft` onto your `PATH` (`~/.local/bin`), collects both API
tokens, maps your Jira projects to repos, verifies Jira **and** Bitbucket auth, optionally
registers an auto-start-at-login watcher, and can start watching immediately — all in one flow.

Re-run the whole guided setup anytime with `autofix quickstart`. The individual steps
(`setup`, `map`, `doctor`, `list`, `run`) are still available if you prefer to do it piecemeal.

### What setup asks for
| Prompt | Example |
|---|---|
| Jira base URL | `https://your-team.atlassian.net` |
| Atlassian email | `you@company.com` |
| **Jira API token** | create at https://id.atlassian.com/manage-profile/security/api-tokens → **"Create API token with scopes"** → app **Jira** → scopes `read:jira-user`, `read:jira-work`, `write:jira-work` (a plain unscoped token also works for Jira) |
| **Bitbucket API token** | a **second** token → **"Create API token with scopes"** → app **Bitbucket** → scopes `read:account`, `read:workspace:bitbucket`, `read:repository:bitbucket`, `write:repository:bitbucket`, `read:pullrequest:bitbucket`, `write:pullrequest:bitbucket` |
| Bitbucket workspace | `your-workspace` |
| Git push username | the username your existing Bitbucket HTTPS remote uses |
| Base branch | `develop` (or `main`) |

> **Why two tokens?** Atlassian API tokens are per-product — a single token can't
> hold both Jira and Bitbucket scopes — so you create one for each. (Bitbucket app
> passwords were retired June 9, 2026, so a scoped API token is now the only option.)

Config is saved to `~/.config/autofix-jira/config.env` (`chmod 600`). **Never commit it.**

## Usage

```bash
autofix doctor                      # verify deps + credentials
autofix map PROJ=my-repo            # map a Jira project key -> Bitbucket repo slug
autofix list                        # AI-eligible tickets assigned to you
autofix run PROJ-123                # resolve one ticket -> draft PR
autofix run-all                     # process every eligible ticket once
autofix run-all --watch 5           # foreground loop: re-check & process every 5 minutes
autofix install-daemon 5            # headless background job (launchd/cron), survives reboot
autofix install-login 5             # macOS: auto-open a Terminal at login, foreground watcher inside
```

`run-all` skips any ticket whose Jira project isn't in `REPO_MAP` (prints how to map it) and
isolates failures, so one bad ticket never stops the batch.

**Auto-start at login (macOS).** `autofix install-login [MIN]` registers a Login Item that opens
a visible Terminal window at every login and runs the foreground watcher in it. Since it runs in
the foreground, **closing the window or pressing Ctrl-C stops it** — and it re-opens at the next
login. Remove it with `autofix uninstall-login`. Start it now without rebooting:
`open ~/.config/autofix-jira/AutoBotDraft.command`. (For a windowless background service that runs
regardless of login, use `install-daemon` instead.)

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
| `JIRA_EMAIL` | Atlassian account email (Basic-auth username for both Jira and Bitbucket) |
| `JIRA_API_TOKEN` | Jira-scoped (or unscoped) API token — used for Jira REST |
| `BITBUCKET_API_TOKEN` | Bitbucket-scoped API token — used for Bitbucket REST (draft PR). Falls back to `JIRA_API_TOKEN` if unset, but that will 401 unless the Jira token happens to carry Bitbucket scopes |
| `BITBUCKET_WORKSPACE` | Bitbucket workspace key |
| `BITBUCKET_GIT_USER` | Username pinned into the HTTPS git remote for clone/push |
| `BASE_BRANCH` | Branch to base work on and target the PR at (default `develop`) |
| `AI_LABELS` | Comma list of eligibility labels |
| `AI_TEXT` | Text the summary/description must match to be eligible |
| `REPO_MAP` | `PROJ=repo,PROJ2=repo2` — Jira project key → Bitbucket repo slug |

## Troubleshooting

- **Clone/push fails:** the tool uses your existing git credential helper. Run a manual
  `git clone https://<user>@bitbucket.org/<workspace>/<repo>.git` once to confirm/store creds.
  Bitbucket app passwords were retired June 9, 2026 — use a scoped **API token** (or a
  repository/workspace **Access Token**) in your credential helper.
- **PR API returns 401/404 / `autofix run` fails at the PR step:** your `BITBUCKET_API_TOKEN`
  is missing Bitbucket scopes or is the wrong token. Remember Jira and Bitbucket need **separate**
  tokens — a Jira (or unscoped) token will 401 against Bitbucket. Re-run `autofix setup` with a
  Bitbucket-app token that has `read/write:pullrequest:bitbucket`. The Basic-auth username must be
  your **email**. Run `autofix doctor` to confirm both Jira and Bitbucket auth pass.
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
