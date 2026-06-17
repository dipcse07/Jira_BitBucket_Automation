---
title: I built a bot that turns Jira tickets into Bitbucket draft PRs with Claude Code
published: false
description: An open-source shell CLI that polls Jira for AI-tagged tickets, fixes them with headless Claude Code on an isolated branch, and opens a draft pull request — never merging, always leaving the final call to a human.
tags: claude, devops, automation, showdev
cover_image:
canonical_url:
---

Every backlog has a layer of sediment at the bottom: tickets that are small, well-specified, and boring. "Rename this label." "Guard against this null." "Bump the timeout from 5s to 15s." Each one is ten minutes of work and a context switch you resent. They pile up because nobody wants to stop what they're doing to fix them, and they're too trivial to feel good about.

I wanted those tickets to fix themselves — but I did **not** want a bot quietly merging code into a shared repo. So I built **AutoBotDraft**: a small open-source CLI that takes AI-tagged Jira tickets, resolves them with Claude Code, and opens a **draft** pull request in Bitbucket. It stops there, on purpose. A human always reviews.

It's MIT-licensed, ~700 lines of pure shell, and runs on macOS and Linux: **[github.com/dipcse07/Jira_BitBucket_Automation](https://github.com/dipcse07/Jira_BitBucket_Automation)**

## What it actually does

You run one command — `autoBotDraft` — and it watches Jira in the foreground, printing each step as it goes (Ctrl-C to stop, like the `claude` CLI). Every few minutes it asks Jira: *are there any tickets assigned to me that look AI-eligible?* For each one it finds, it runs this pipeline:

```
Jira poll (every N min)
   │  JQL: assignee = currentUser() AND statusCategory != Done
   │       AND (labels in (AI, ai-task, auto-fix) OR text ~ "ai")
   ▼
Isolated clone  ──►  branch off latest `develop`  (feature/<TICKET-KEY>)
   ▼
Headless Claude Code  ──►  reads the ticket, plans, edits the code
   ▼
Commit  ──►  push branch
   ▼
Bitbucket DRAFT pull request  (draft:true — hard gate)
   ▼
Comment the PR link back on the Jira ticket
```

A few decisions in there are load-bearing, so let me unpack the ones I'd actually defend in review.

## Decision 1: draft-only is the safety boundary

The entire trust model rests on one rule: **the bot can only ever create a draft PR.** It never merges, never pushes to a protected branch, never deploys. There's no config flag to turn that off.

This matters because "autonomous code-fixing agent" usually triggers a reasonable fear — what if it's confidently wrong? With a draft PR, "confidently wrong" costs you nothing. The diff sits there waiting for a human to read it. The bot's job is to remove the *typing*, not the *judgement*. That framing also makes the tool easy to adopt on a team: you're not asking anyone to trust AI with `main`, you're asking them to review a PR like any other.

## Decision 2: per-developer by construction

The JQL filter starts with `assignee = currentUser()`. There's no central service account, no shared bot identity. Each developer installs it with **their own** Atlassian API token, so the bot only ever sees and touches tickets assigned to *them*, and every commit and PR is authored as *them*.

That sidesteps a whole category of problems — noisy-neighbor tickets, "who is this bot user," audit confusion — and it means a team of ten can adopt it ten times independently with zero shared infrastructure.

## Decision 3: the Bitbucket `draft:true` workaround

Here's the gotcha that cost me the most time. I started by wiring up a community Bitbucket MCP server (Model Context Protocol) to create the PR. It worked — except it created **regular** PRs. The `create_pull_request` tool simply didn't expose the `draft` field, so my one non-negotiable safety rule was silently unenforceable through it.

The Bitbucket Cloud REST API *does* support it natively, so PR creation bypasses the MCP and calls REST directly:

```bash
curl -sS -u "$EMAIL:$API_TOKEN" \
  -X POST \
  "https://api.bitbucket.org/2.0/repositories/$WORKSPACE/$REPO/pullrequests" \
  -H "Content-Type: application/json" \
  -d "{
        \"title\": \"[AI][$KEY] $SUMMARY\",
        \"source\": { \"branch\": { \"name\": \"feature/$KEY\" } },
        \"destination\": { \"branch\": { \"name\": \"develop\" } },
        \"draft\": true
      }"
```

Two things worth knowing if you build on Bitbucket Cloud:
- **Auth is email + API token via Basic auth**, not username + app password (Atlassian is retiring app passwords). The email is the Basic-auth *username*.
- The `"draft": true` field is the whole ballgame. Verify any abstraction you put in front of it actually forwards it — mine didn't, and it failed *open*, which is the worst way to fail.

## Decision 4: isolated clones, never your working copy

The bot clones into a throwaway directory per run rather than touching whatever you have checked out. Your local branch, your uncommitted changes, your editor state — all untouched. A failed run leaves nothing behind but a remote branch and a draft PR you can delete. It also means one ticket's failure can't poison the next; each runs clean.

## Installing it

```bash
git clone https://github.com/dipcse07/Jira_BitBucket_Automation
cd Jira_BitBucket_Automation
./install.sh                       # checks deps, links the CLI onto your PATH, runs setup
autoBotDraft setup                 # one-time: Jira URL, email, API token, workspace
autofix map THER=thermometer_ios   # map a Jira project key → a Bitbucket repo
```

Then the daily use is just:

```bash
autofix list            # see eligible tickets assigned to you
autofix run THER-123    # resolve one ticket → branch → push → draft PR
autoBotDraft            # or: watch continuously, every 5 min, Ctrl-C to stop
```

If you'd rather it run in the background and survive reboots, there's `autofix install-daemon 5` (launchd on macOS, cron on Linux) instead of the foreground watcher. Only runtime dependencies are `bash`, `git`, `curl`, and the `claude` CLI.

## What it is *not*

I want to be clear about the limits, because over-claiming is how these tools lose trust:

- It is **not** a replacement for a reviewer. It writes a draft; you read it.
- It is best on **small, well-specified** tickets. Hand it a vague epic and you'll get a vague diff. Garbage in, garbage draft.
- There's **no test-gating in the MVP** — it doesn't (yet) refuse to open the PR if tests fail. On the roadmap is a validation loop that runs the project's tests and feeds failures back to Claude before drafting, capped at a few retries, marking the ticket "needs human review" if it can't get green.
- It currently targets **Bitbucket Cloud**. GitHub support would be a small adapter swap (the rest of the pipeline is host-agnostic).

## Why I think the draft-only framing matters beyond this tool

The interesting question with coding agents isn't "can it write the fix" — increasingly it can. It's "what's the blast radius when it's wrong, and who's accountable." Draft-only with per-developer authorship answers both: the radius is a reviewable diff, and the accountable person is whoever's name is on the PR. That's a boundary I'd want even if the model were perfect, because the *review* is where the team's knowledge actually lives.

If you try it, I'd genuinely like feedback on that boundary — especially whether the test-gating belongs before the draft PR or as a separate CI step on the PR itself.

**Repo:** [github.com/dipcse07/Jira_BitBucket_Automation](https://github.com/dipcse07/Jira_BitBucket_Automation) — stars and issues welcome.
