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
│   ├── autofix.sh                  ← all logic: setup·doctor·map·list·run·run-all·start·install-daemon·logs·status
│   ├── install.sh                  ← deps check → PATH symlinks → setup wizard
│   ├── README.md                   ← install + usage + troubleshooting
│   └── .gitignore
├── autofix-jira.zip                ← distributable for teammates
└── docs/
    └── chat-history-2026-06-08.md  ← full dev history (Atlassian tokens REDACTED)
```

## Commands (live on PATH via ~/.local/bin symlinks → autofix-jira/autofix.sh)
- `autoBotDraft [MIN]` — foreground watcher, polls every MIN min (default 5), Ctrl-C to stop ("like claude")
- `autofix setup` — one-time: Jira URL, email, API token, workspace
- `autofix map THER=thermometer_ios` — map Jira project key → Bitbucket repo
- `autofix list` — AI-eligible tickets assigned to you
- `autofix run <KEY>` — resolve one ticket → branch → push → DRAFT PR → Jira write-back
- `autofix run-all [--watch MIN]` — batch every eligible ticket
- `autofix install-daemon [MIN]` / `uninstall-daemon` — background via launchd (survives reboot)
- `autofix status` / `autofix logs [-f]`

## Key facts / decisions (from the build)
- **Auth:** Atlassian **API token** via Basic auth, using **email as username**
  (`mdsazidhasan.dip@unifa-e.com`). App passwords were the fallback, not used.
- **Bitbucket target:** workspace `lookme`, repo `thermometer_ios`, default branch `develop`.
- **Branch strategy:** NEVER work on `develop`. Branch per ticket (`feature/<KEY>`) off latest `develop`.
- **Draft PR via REST:** the community Bitbucket MCP can't force `draft:true`, so PR creation
  uses a direct Bitbucket REST call with `draft:true`.
- **Eligibility:** `assignee = currentUser()` AND not Done AND (label in AI_LABELS OR text matches AI_TEXT) — so each developer only sees their own tickets.
- **ECC GateGuard** fact-forces every Bash/Write; a headless daemon run needs `ECC_GATEGUARD=off`.
- Proven live once: ticket **THER-203 → draft PR #70**.

## Status (as of 2026-06-08)
- ✅ Tool built, syntax-clean, all commands wired, symlinks on PATH, smoke-tested.
- ⏸️ **Not configured yet** — `~/.config/autofix-jira/config.env` is empty.
  First real run needs `autoBotDraft setup` (user's Atlassian API token; Claude can't enter it).
- 🔴 The 3 Atlassian tokens pasted during the build were live — **revoke/rotate** them
  (https://id.atlassian.com/manage-profile/security/api-tokens). The transcript copy here is redacted.

## To continue
1. `autoBotDraft setup` → enter Jira URL, email, fresh API token, workspace.
2. `autofix map THER=thermometer_ios`
3. `autofix run THER-XXX` on one ticket to verify end-to-end, then `autoBotDraft` to watch.

## Related Claude memory (auto-loaded, not in this folder)
`~/.claude/projects/-Users-mdsazidhasan-dip/memory/` — `autofix-bugticket-project.md`,
`autofix-bugticket-branch-strategy.md`, `bitbucket-mcp-auth.md`.
