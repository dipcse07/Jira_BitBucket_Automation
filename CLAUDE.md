# AutoBotDraft — Project Context for Claude

> Read this first. It tells a fresh Claude session what this project is, where things
> live, what's done, and what's left. Full narrative history is in
> `docs/chat-history-2026-06-08.md`.

## What this is
An autonomous **Jira → Claude Code → Bitbucket draft-PR** tool. It polls Jira for
AI-eligible tickets assigned to the current user, has headless Claude Code resolve the
ticket on an isolated branch, pushes, and opens a **DRAFT pull request** in Bitbucket.
Safety rule: it **only ever creates DRAFT PRs** — never merges, never deploys.

## Folder layout
```
AutoBotDraft/
├── CLAUDE.md                       ← this file
├── autofix-jira/                   ← the tool (self-contained)
│   ├── autofix.sh                  ← all logic: quickstart·setup·doctor·map·list·run·run-all·start·install-daemon·install-login·logs·status
│   ├── install.sh                  ← deps check → PATH symlinks → runs `quickstart`
│   ├── README.md                   ← install + usage + troubleshooting
│   └── .gitignore
├── autofix-jira.zip                ← distributable for teammates
└── docs/
    └── chat-history-2026-06-08.md  ← full dev history (Atlassian tokens REDACTED)
```

## Commands (live on PATH via ~/.local/bin symlinks → autofix-jira/autofix.sh)
- `autofix quickstart` — ★ one continuous guided setup: deps → PATH → credentials → map → verify → auto-start → watch. `install.sh` runs this.
- `autoBotDraft [MIN]` — foreground watcher, polls every MIN min (default 5), Ctrl-C to stop ("like claude"). MIN must be numeric (validated).
- `autofix setup` — just the credentials step (Jira URL, email, two API tokens, workspace). Preserves existing REPO_MAP/AI_* on reconfigure.
- `autofix map THER=thermometer_ios` — map Jira project key → Bitbucket repo
- `autofix list` — AI-eligible tickets assigned to you
- `autofix run <KEY>` — resolve one ticket → branch → push → DRAFT PR → Jira write-back. Skips if an open/draft PR (or `feature/<KEY>` branch) already exists.
- `autofix run-all [--watch MIN]` — batch every eligible ticket
- `autofix install-daemon [MIN]` / `uninstall-daemon` — headless background via launchd (survives reboot)
- `autofix install-login [MIN]` / `uninstall-login` — macOS: auto-OPEN a Terminal at login running the foreground watcher (close window / Ctrl-C to stop)
- `autofix status` / `autofix logs [-f]`

## Key facts / decisions
- **TWO tokens, two different usernames (important!):** Atlassian API tokens are per-product, so
  `JIRA_API_TOKEN` (Jira scopes, or unscoped) and `BITBUCKET_API_TOKEN` (Bitbucket scopes incl.
  `read/write:pullrequest:bitbucket`) are separate — one token can't hold both, and you can't
  select both products in one scoped token. App passwords retired June 9, 2026.
  - **REST API** (`jira()`, `bb()`): Basic auth, username = **email**, password = the matching token.
  - **git over HTTPS** (`bb_remote()`): username = the literal **`x-bitbucket-api-token-auth`**,
    password = `BITBUCKET_API_TOKEN` (the email does NOT work for git). Token is URL-encoded; the
    remote URL carries the creds (credential helper not required).
- **Jira search:** uses `/rest/api/3/search/jql` (`jira_search()`). The old `/rest/api/2/search`
  was removed (HTTP 410) in 2025 — do NOT revert to it.
- **Dedup:** `run` skips a ticket if an OPEN/draft PR exists for `feature/<KEY>` (Bitbucket PR
  query) or that branch already exists on the remote — checked before any clone.
- **Bitbucket target:** workspace `lookme`, repo `thermometer_ios`, default branch `develop`.
- **Branch strategy:** NEVER work on `develop`. Branch per ticket (`feature/<KEY>`) off latest `develop`.
- **Draft PR via REST:** PR creation uses a direct Bitbucket REST call with `draft:true`.
- **Eligibility:** `assignee = currentUser()` AND not Done AND (label in AI_LABELS OR text matches AI_TEXT).
- **Robustness:** `set -euo pipefail` is on — guard `grep`/pipelines in command-substitutions with
  `|| true` (an empty-map `grep` once aborted setup). `$SELF` resolves symlinks so `ensure_symlinks`
  can't relink a PATH symlink to itself. Watcher interval is validated as numeric.
- **ECC GateGuard** fact-forces every Bash/Write; a headless daemon run needs `ECC_GATEGUARD=off`.
- Proven live: **THER-203 → draft PR #70** (now correctly skipped as a duplicate).

## Status (as of 2026-06-16) — v1.1.0
- ✅ Configured and working end-to-end: Jira auth, Bitbucket auth, search, git clone/push, draft PR,
  dedup, login auto-start, and the `quickstart` guided flow all verified.
- ✅ `~/.config/autofix-jira/config.env` is populated; `THER=thermometer_ios` mapped.
- ✅ Login launcher installed (Terminal auto-opens at login, 5-min polls).
- 🔴 Any Atlassian tokens pasted in chat/transcripts during setup are exposed — **revoke/rotate** at
  https://id.atlassian.com/manage-profile/security/api-tokens.

## To continue / extend
- Run more tickets: `autofix run <KEY>` or just let the watcher poll. New tickets without an open PR
  get a fresh draft PR; ones with an existing PR are skipped.
- Reconfigure end-to-end anytime: `autofix quickstart`. Re-verify: `autofix doctor`.

## Related Claude memory (auto-loaded, not in this folder)
`~/.claude/projects/-Users-mdsazidhasan-dip/memory/` — `autofix-bugticket-project.md`,
`autofix-bugticket-branch-strategy.md`, `bitbucket-mcp-auth.md`.
