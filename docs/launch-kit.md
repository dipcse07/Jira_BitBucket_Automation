# AutoBotDraft — Launch & Visibility Kit

Copy-paste assets to make `github.com/dipcse07/Jira_BitBucket_Automation` discoverable
on GitHub, Google, and live AI search. Do them top-to-bottom; #1–#3 are the highest ROI.

---

## 1. GitHub "About" panel  (Settings ▸ top-right "About" gear)

**Description** (paste verbatim):
```
Autonomous Jira → Claude Code → Bitbucket draft-PR bot. Polls Jira for AI-tagged tickets, fixes them with Claude Code on an isolated branch, and opens a draft pull request — draft-only, never merges. Pure shell CLI.
```

**Website:** leave blank, or point to a dev.to article once published.

**Topics** (add each — GitHub allows 20; these are the searched terms):
```
jira  bitbucket  claude  claude-code  anthropic  ai-agent  agentic-ai
automation  devops  cli  bash  shell  pull-request  pull-request-automation
jira-automation  atlassian  llm  ai-developer-tools  bug-fixing  code-automation
```

---

## 2. README — first 3 lines (SEO: GitHub + Google index the top of the README hardest)

Replace the opening so the keywords people actually search appear immediately:

```markdown
# Jira → Bitbucket Automation (AutoBotDraft)

**Automatically fix AI-tagged Jira tickets and open Bitbucket draft pull requests using Claude Code.**
A pure-shell CLI bot that polls Jira for tickets assigned to you, resolves them with an AI agent on an
isolated branch, pushes, and opens a *draft* PR — safe by default (never merges, never deploys).

> Keywords: Jira automation · Bitbucket draft PR bot · Claude Code agent · AI pull request · autonomous bug-fixing · DevOps automation CLI
```

Add a short **"Why"** and an **animated demo GIF** near the top (a terminal recording of
`autoBotDraft` running). A GIF dramatically lifts star-conversion — record with
`asciinema` + `agg`, or QuickTime.

---

## 3. Show HN  (news.ycombinator.com/submit — highest single-shot reach for dev tools)

**Title** (Show HN titles must start with "Show HN:", keep ≤ 80 chars):
```
Show HN: A bot that fixes AI-tagged Jira tickets and opens Bitbucket draft PRs
```

**URL:** `https://github.com/dipcse07/Jira_BitBucket_Automation`

**First comment** (post immediately after submitting — HN expects the author to explain):
```
Author here. I kept seeing small, well-specified Jira tickets that were basically
"change this string / fix this null check" and wanted them to fix themselves.

AutoBotDraft is a ~700-line shell CLI that:
- polls Jira every N minutes for tickets assigned to you that are labeled AI / ai-task
  (or whose text mentions "ai"),
- spins up an isolated clone, branches off the latest develop,
- runs headless Claude Code (`claude -p`) to plan + apply the fix,
- pushes and opens a DRAFT pull request in Bitbucket (draft-only is a hard gate — it
  never merges or deploys),
- comments the PR link back on the ticket.

Design choices I'd love feedback on:
- Draft-PR-only as the safety boundary instead of trying to auto-merge.
- Per-developer credentials (`assignee = currentUser()`) so each person only sees
  their own tickets.
- Why Bitbucket needs a direct REST call for `draft:true` (the community MCP can't set it).

It's MIT, macOS/Linux, zero runtime deps beyond bash + git + curl. Not trying to replace
a human reviewer — the whole point is it stops at "here's a draft, take a look."
```

Post **Tue–Thu, ~8–10am US Eastern** for best visibility.

---

## 4. dev.to / Hashnode article  (ranks on Google → feeds AI search crawlers)

**Title:** `I built a bot that turns Jira tickets into Bitbucket draft PRs with Claude Code`

**Tags:** `claude`, `devops`, `automation`, `showdev`

**Outline** (write ~800–1200 words):
1. The problem — the backlog of tiny, well-specified tickets.
2. The flow diagram (Jira → poll → isolated clone → Claude Code → push → draft PR → ticket comment).
3. The one interesting technical bit — draft-PR-only safety gate + why the Bitbucket REST `draft:true` workaround.
4. How to install (`./install.sh` → `autoBotDraft setup`).
5. Limitations + what's next. Link the repo.

This article is the asset AI search engines are most likely to cite — a prose explanation
with the repo linked beats the bare repo for crawlability.

---

## 5. Reddit  (link + genuine context — most subs ban bare self-promo)

**r/devops** — title:
```
I made an open-source bot that auto-drafts Bitbucket PRs from AI-tagged Jira tickets
```
**r/ClaudeAI** — title:
```
Used headless Claude Code to build a Jira→Bitbucket draft-PR automation (open source)
```
**r/atlassian** — title:
```
Open-source CLI: auto-resolve AI-labeled Jira tickets into Bitbucket draft PRs
```
Body for each: 2–3 sentences on what it does + the draft-only safety angle + repo link.
Read each sub's rules first; some require a [Project]/[OC] flair.

---

## 6. LinkedIn post

```
I got tired of small, well-specified Jira tickets sitting in the backlog — so I built a bot
that fixes them itself.

AutoBotDraft polls Jira for AI-tagged tickets assigned to you, resolves them with Claude
Code on an isolated branch, and opens a Bitbucket DRAFT pull request — then comments the
link back on the ticket. Draft-only by design: it never merges or deploys. The human always
makes the final call.

Pure shell, MIT-licensed, runs on macOS/Linux.

→ github.com/dipcse07/Jira_BitBucket_Automation

#DevOps #AI #ClaudeCode #Automation #Jira #Bitbucket #OpenSource
```

---

## 7. X / Twitter thread

```
1/ I built a bot that fixes AI-tagged Jira tickets and opens Bitbucket draft PRs by itself.

Open source, pure shell, MIT. 🧵

2/ The flow:
Jira poll → isolated clone → branch off develop → Claude Code fixes it → push → DRAFT PR
→ comment the PR link back on the ticket.

3/ The safety boundary is simple: it ONLY ever creates draft PRs. Never merges, never
deploys. A human always reviews. The bot just removes the typing.

4/ Per-developer: it uses `assignee = currentUser()`, so each teammate only ever sees and
fixes their own tickets with their own credentials.

5/ Try it (macOS/Linux):
github.com/dipcse07/Jira_BitBucket_Automation
Feedback welcome 🙏
```

---

## 8. Awesome-list PRs  (permanent high-authority backlinks → discovery + ranking)

Reusable entry line (awesome-lint compliant):
```markdown
- [Jira_BitBucket_Automation](https://github.com/dipcse07/Jira_BitBucket_Automation) - Watches Jira for AI-tagged tickets, fixes them with Claude Code, and opens a Bitbucket draft PR.
```
Targets (one PR each, alphabetized, run `npx awesome-lint` first):
- hesreallyhim/awesome-claude-code  ← best fit
- e2b-dev/awesome-ai-agents
- agarrharr/awesome-cli-apps
- alebcay/awesome-shell
- awesome-atlassian / DevOps lists

---

## 9. Get it crawled by Google (so live AI search can surface it)
- A merged awesome-list PR + a dev.to article + an HN/Reddit post = enough backlinks for
  Google to index within days.
- Optional: enable **GitHub Pages** (Settings ▸ Pages) on a simple landing page → another
  indexable URL.
- Add a **`CITATION.cff`** and a clear LICENSE (already MIT ✓) — signals a "real" project.

---

## Reality check
- **Trained-in** AI knowledge (a model "just knowing" your repo) = next training cycle, months out. Nothing accelerates that.
- **Live AI search** (Perplexity, ChatGPT-search, Claude web) = days-to-weeks after you earn backlinks. The list above is exactly how you earn them.
- **Stars** follow distribution (#3–#7), not waiting. Expect a slow first week, then momentum if one post lands.

## Suggested order & cadence
- Day 1: #1 + #2 (GitHub About/topics/README) — 15 min, do now.
- Day 1: record demo GIF, add to README.
- Day 2: publish dev.to article (#4).
- Day 2–3: Show HN (#3) + link the article. Same day: LinkedIn (#6) + X (#7).
- Day 3–5: Reddit (#5) one sub at a time. Open awesome-list PRs (#8), one per day.
