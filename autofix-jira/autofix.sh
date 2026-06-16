#!/usr/bin/env bash
#
# autofix-jira — Autonomous Jira -> Claude Code -> Bitbucket draft-PR tool
#
# One self-contained script. A developer runs `./autofix.sh setup` once, then
# `./autofix.sh run <TICKET>` to have Claude Code implement a Jira ticket and
# open a DRAFT pull request in Bitbucket. Safe by design: it only ever creates
# DRAFT PRs and never merges or deploys.
#
# Supported OS: macOS / Linux (and Windows via WSL or Git Bash).
# Requires: git, curl, jq, and the Claude Code CLI (`claude`).
#
# License: MIT. Share freely.
#
set -euo pipefail

VERSION="1.1.0"
AUTOFIX_HOME="${AUTOFIX_HOME:-$HOME/.config/autofix-jira}"
CONFIG_FILE="$AUTOFIX_HOME/config.env"
RUNS_DIR="$AUTOFIX_HOME/runs"
WORKSPACES_DIR="$AUTOFIX_HOME/workspaces"
DAEMON_LOG="$AUTOFIX_HOME/daemon.log"
DAEMON_LABEL="com.autofix-jira.daemon"
DAEMON_PLIST="$HOME/Library/LaunchAgents/$DAEMON_LABEL.plist"
RUNALL_LOCK="$AUTOFIX_HOME/run-all.lock"
SHELLRC="$AUTOFIX_HOME/shellrc.sh"
# Login-item launcher: opens a visible Terminal at login and runs the foreground watcher.
LOGIN_CMD="$AUTOFIX_HOME/AutoBotDraft.command"
LOGIN_ITEM_NAME="AutoBotDraft"
# Absolute path to the REAL script, following symlinks (macOS readlink lacks -f).
# Must resolve the symlink so we never relink a PATH symlink to point at itself.
_resolve_self() {
  local p="$1" d
  while [ -L "$p" ]; do
    d="$(cd "$(dirname "$p")" 2>/dev/null && pwd)"
    p="$(readlink "$p")"
    case "$p" in /*) ;; *) p="$d/$p" ;; esac
  done
  printf '%s' "$(cd "$(dirname "$p")" 2>/dev/null && pwd)/$(basename "$p")"
}
SELF="$(_resolve_self "${BASH_SOURCE[0]}")"

# ---------- pretty output ----------
_c() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
info()  { printf '%s %s\n' "$(_c 36 '›')" "$*"; }
ok()    { printf '%s %s\n' "$(_c 32 '✓')" "$*"; }
warn()  { printf '%s %s\n' "$(_c 33 '!')" "$*" >&2; }
err()   { printf '%s %s\n' "$(_c 31 '✗')" "$*" >&2; }
die()   { err "$*"; exit 1; }
hr()    { printf '%s\n' "$(_c 90 '────────────────────────────────────────────────────────')"; }

# ---------- config ----------
load_config() {
  [ -f "$CONFIG_FILE" ] || die "Not configured. Run: $0 setup"
  set -a; # shellcheck disable=SC1090
  . "$CONFIG_FILE"; set +a
  : "${JIRA_BASE_URL:?missing in config}" "${JIRA_EMAIL:?}" "${JIRA_API_TOKEN:?}" "${BITBUCKET_WORKSPACE:?}"
  BASE_BRANCH="${BASE_BRANCH:-develop}"
  AI_LABELS="${AI_LABELS:-AI,ai-task,auto-fix,ai-fix}"
  AI_TEXT="${AI_TEXT:-ai}"
  BITBUCKET_GIT_USER="${BITBUCKET_GIT_USER:-$JIRA_EMAIL}"
  # Bitbucket REST needs its own single-app scoped token (Atlassian tokens are
  # per-product; one token can't carry both Jira and Bitbucket scopes). Fall back
  # to the Jira token for backward compatibility with older configs.
  BITBUCKET_API_TOKEN="${BITBUCKET_API_TOKEN:-$JIRA_API_TOKEN}"
  REPO_MAP="${REPO_MAP:-}"
}

prompt_value() { # prompt_value VAR "Question" "default"
  local __var="$1" __q="$2" __def="${3:-}" __ans
  if [ -n "$__def" ]; then read -r -p "$__q [$__def]: " __ans; __ans="${__ans:-$__def}"
  else read -r -p "$__q: " __ans; fi
  printf -v "$__var" '%s' "$__ans"
}
prompt_secret() { local __var="$1" __q="$2" __ans; read -r -s -p "$__q: " __ans; echo; printf -v "$__var" '%s' "$__ans"; }

# ---------- jira REST (API v2 = plain-text bodies, no ADF gymnastics) ----------
jira() { # jira METHOD PATH [data]
  local method="$1" path="$2" data="${3:-}"
  local args=(-sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" -X "$method" "$JIRA_BASE_URL/rest/api/2$path")
  [ -n "$data" ] && args+=(-H "Content-Type: application/json" -d "$data")
  curl "${args[@]}"
}
jira_search() { # jira_search JQL  -> issues json
  # Uses the current endpoint /rest/api/3/search/jql. The old /rest/api/2/search
  # (and /rest/api/3/search) were deprecated May 2025 and removed (HTTP 410) by late
  # 2025, so this MUST target /search/jql. Response still exposes .issues[].
  local jql; jql="$(jq -rn --arg x "$1" '$x|@uri')"
  curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
    "$JIRA_BASE_URL/rest/api/3/search/jql?jql=$jql&maxResults=50&fields=summary,status,assignee,labels,updated"
}

# ---------- bitbucket REST ----------
bb() { # bb METHOD PATH [data]
  local method="$1" path="$2" data="${3:-}"
  local args=(-sS -w '\n__HTTP__%{http_code}' -u "$JIRA_EMAIL:$BITBUCKET_API_TOKEN" -H "Accept: application/json" -X "$method" "https://api.bitbucket.org/2.0$path")
  [ -n "$data" ] && args+=(-H "Content-Type: application/json" -d "$data")
  curl "${args[@]}"
}
http_code() { printf '%s' "$1" | sed -n 's/.*__HTTP__//p'; }
http_body() { printf '%s' "$1" | sed 's/__HTTP__[0-9]*$//'; }

# ---------- git over HTTPS to Bitbucket ----------
# Percent-encode a string for safe use in a URL userinfo field (so an email's '@'
# and a token's '=', '+', '/' don't corrupt the URL).
urlenc() {
  local s="$1" out="" c i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}
# git with interactive prompts disabled (auth comes from the credentialed remote URL).
git_bb() { GIT_TERMINAL_PROMPT=0 git "$@"; }
# Build the authenticated Bitbucket remote URL. NOTE: git over HTTPS with an Atlassian
# API token requires the STATIC username `x-bitbucket-api-token-auth` (the email works
# for the REST API but NOT for git). App passwords are gone (June 2026), so the API
# token is the way. The token is URL-encoded; the static username needs no encoding.
bb_remote() { printf 'https://x-bitbucket-api-token-auth:%s@bitbucket.org/%s/%s.git' \
  "$(urlenc "$BITBUCKET_API_TOKEN")" "$BITBUCKET_WORKSPACE" "$1"; }

# ---------- repo mapping ----------
resolve_repo() { # resolve_repo JIRA_PROJECT_KEY -> repo slug (or empty)
  local proj="$1" pair k v
  IFS=',' read -ra _pairs <<< "$REPO_MAP"
  for pair in "${_pairs[@]:-}"; do
    [ -z "$pair" ] && continue
    k="${pair%%=*}"; v="${pair#*=}"
    [ "$k" = "$proj" ] && { printf '%s' "$v"; return 0; }
  done
  return 1
}

# =======================================================================
# setup
# =======================================================================
cmd_setup() {
  hr; info "autofix-jira setup (v$VERSION)"; hr
  # Load any existing config so we can pre-fill prompts AND preserve settings that
  # setup doesn't ask about (REPO_MAP, AI_LABELS, AI_TEXT) instead of wiping them.
  [ -f "$CONFIG_FILE" ] && { set -a; # shellcheck disable=SC1090
    . "$CONFIG_FILE"; set +a; }
  local base email token bbtoken ws gituser baseb
  prompt_value base  "Jira base URL (e.g. https://your-team.atlassian.net)" "${JIRA_BASE_URL:-}"
  prompt_value email "Atlassian account email" "${JIRA_EMAIL:-}"
  echo
  echo "Atlassian API tokens are per-product — one token CANNOT hold both Jira and"
  echo "Bitbucket scopes — so you need TWO tokens. Create both at:"
  echo "  https://id.atlassian.com/manage-profile/security/api-tokens"
  echo
  echo "  1) JIRA token:  'Create API token with scopes' -> app 'Jira' -> scopes:"
  echo "       read:jira-user, read:jira-work, write:jira-work"
  echo "     (an unscoped 'Create API token' also works for Jira)"
  echo "  2) BITBUCKET token: 'Create API token with scopes' -> app 'Bitbucket' -> scopes:"
  echo "       read:account, read:workspace:bitbucket,"
  echo "       read:repository:bitbucket, write:repository:bitbucket,"
  echo "       read:pullrequest:bitbucket, write:pullrequest:bitbucket"
  echo
  prompt_secret token   "Jira API token (hidden)"
  prompt_secret bbtoken "Bitbucket API token (hidden)"
  prompt_value ws    "Bitbucket workspace key (e.g. my-workspace)" "${BITBUCKET_WORKSPACE:-}"
  prompt_value gituser "Bitbucket git push username (for the HTTPS remote)" "${BITBUCKET_GIT_USER:-$email}"
  prompt_value baseb "Default base branch to branch off / target" "${BASE_BRANCH:-develop}"

  info "Validating Jira credentials..."
  local who; who="$(curl -sS -u "$email:$token" "$base/rest/api/2/myself" || true)"
  echo "$who" | jq -e '.accountId' >/dev/null 2>&1 \
    && ok "Jira OK — authenticated as $(echo "$who" | jq -r '.displayName')" \
    || die "Jira auth failed. Check the Jira email / token / scopes (needs read:jira-user)."

  info "Validating Bitbucket access to workspace '$ws'..."
  local bbcode; bbcode="$(curl -sS -o /dev/null -w '%{http_code}' -u "$email:$bbtoken" "https://api.bitbucket.org/2.0/workspaces/$ws" || true)"
  if [ "$bbcode" = "200" ]; then
    ok "Bitbucket OK (workspace reachable)"
  else
    err "Bitbucket auth failed (HTTP $bbcode). The DRAFT-PR step ('autofix run') WILL fail until this is fixed."
    err "Your Bitbucket token is missing scopes or is the wrong token. It needs a Bitbucket-app"
    err "token with: read:account, read/write:repository:bitbucket, read/write:pullrequest:bitbucket."
    err "Note: a Jira token (or unscoped token) does NOT work for Bitbucket. Re-run 'autofix setup' with a Bitbucket token."
  fi

  mkdir -p "$AUTOFIX_HOME"
  umask 177
  cat > "$CONFIG_FILE" <<EOF
# autofix-jira config — chmod 600. Do NOT commit this file.
JIRA_BASE_URL="$base"
JIRA_EMAIL="$email"
JIRA_API_TOKEN="$token"
BITBUCKET_API_TOKEN="$bbtoken"
BITBUCKET_WORKSPACE="$ws"
BITBUCKET_GIT_USER="$gituser"
BASE_BRANCH="$baseb"
# Eligibility: ticket assigned to you AND (has one of these labels OR text matches AI_TEXT)
AI_LABELS="${AI_LABELS:-AI,ai-task,auto-fix,ai-fix}"
AI_TEXT="${AI_TEXT:-ai}"
# Jira project key -> Bitbucket repo slug, comma-separated. e.g. PROJ=my-repo,PROJ2=my-other-repo
REPO_MAP="${REPO_MAP:-}"
EOF
  chmod 600 "$CONFIG_FILE"
  hr; ok "Saved $CONFIG_FILE"
  info "Next: map your Jira projects to repos, e.g.  $0 map PROJ=my-repo"
  info "Then:  $0 list   and   $0 run <TICKET-KEY>"
}

# =======================================================================
# quickstart — one continuous, guided setup: deps → PATH → config →
# project mapping → verify → (optional) auto-start at login → watch now.
# =======================================================================
ensure_symlinks() {
  local bin="${BIN_DIR:-$HOME/.local/bin}"
  mkdir -p "$bin"
  chmod +x "$SELF" 2>/dev/null || true
  local name link
  for name in autofix autoBotDraft; do
    link="$bin/$name"
    # Never link a symlink to itself (would create a loop). Skip if SELF *is* this link.
    if [ "$SELF" = "$link" ]; then
      warn "Skipping $link — could not resolve the real script path. Re-run via the real autofix.sh."
      continue
    fi
    ln -sf "$SELF" "$link"
  done
  ok "Linked 'autofix' and 'autoBotDraft' into $bin → $SELF"
  case ":$PATH:" in
    *":$bin:"*) : ;;
    *) warn "$bin is not on your PATH. Add this to your shell profile, then reopen the terminal:"
       printf '      export PATH="%s:$PATH"\n' "$bin" ;;
  esac
}

ask_yes_no() { # ask_yes_no "Question" default(y/n) -> returns 0 for yes
  local q="$1" def="${2:-y}" ans hint
  case "$def" in y) hint="Y/n" ;; *) hint="y/N" ;; esac
  read -r -p "$q [$hint]: " ans; ans="${ans:-$def}"
  case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

cmd_quickstart() {
  hr; info "autofix-jira — complete guided setup (v$VERSION)"; hr
  info "This walks you through everything in one go: tools → credentials → repo mapping → verify → auto-start."
  echo

  # 1. Dependencies
  info "Step 1/6 — checking dependencies..."
  local miss=0
  for d in git curl jq; do command -v "$d" >/dev/null 2>&1 && ok "found $d" || { err "missing: $d"; miss=1; }; done
  if command -v claude >/dev/null 2>&1; then ok "found claude (Claude Code CLI)"; else
    warn "Claude Code CLI ('claude') not found — needed for 'run'. Install: https://claude.com/claude-code"
  fi
  [ "$miss" = 0 ] || die "Install the missing dependencies above, then re-run: $0 quickstart"
  echo

  # 2. PATH symlinks
  info "Step 2/6 — putting 'autofix' / 'autoBotDraft' on your PATH..."
  ensure_symlinks
  echo

  # 3. Credentials / config
  info "Step 3/6 — credentials..."
  if [ -f "$CONFIG_FILE" ]; then
    if ask_yes_no "A config already exists. Reconfigure it?" n; then cmd_setup; else ok "Keeping existing config."; fi
  else
    cmd_setup
  fi
  load_config
  echo

  # 4. Project -> repo mapping (loop until the user is done)
  info "Step 4/6 — map Jira project keys to Bitbucket repo slugs (e.g. PROJ=my-repo)."
  info "Current mapping: ${REPO_MAP:-(empty)}"
  while ask_yes_no "Add a project mapping now?" "$([ -z "$REPO_MAP" ] && echo y || echo n)"; do
    local pair
    prompt_value pair "  Enter KEY=repo (blank to cancel)" ""
    [ -z "$pair" ] && continue
    case "$pair" in *=*) cmd_map "$pair"; load_config ;; *) warn "Format must be KEY=repo (e.g. PROJ=my-repo)." ;; esac
  done
  [ -z "$REPO_MAP" ] && warn "No repo mapping set — 'run' will skip tickets until you add one with: $0 map KEY=repo"
  echo

  # 5. Verify everything authenticates
  info "Step 5/6 — verifying credentials..."
  cmd_doctor || warn "Some checks failed above — fix them before relying on automatic runs."
  echo

  # 6. Auto-start at login + run now
  info "Step 6/6 — running continuously."
  local mins=5
  if [ "$(uname -s)" = "Darwin" ]; then
    if ask_yes_no "Auto-open a Terminal watching Jira at every login?" y; then
      prompt_value mins "  Poll interval in minutes" "5"
      cmd_install_login "$mins"
    fi
  else
    info "(Auto-start at login is macOS-only. On Linux, add '$SELF start 5' to your Startup Applications, or use '$0 install-daemon 5'.)"
  fi
  echo
  hr; ok "Setup complete. You're ready."
  hr
  if ask_yes_no "Start watching now (foreground; Ctrl-C to stop)?" y; then
    start_watch "$mins"
  else
    info "Start anytime with:  autoBotDraft        (or '$0 start')"
    info "Verify anytime with: $0 doctor"
  fi
}

# =======================================================================
# doctor
# =======================================================================
cmd_doctor() {
  hr; info "autofix-jira doctor"; hr
  local fail=0
  for d in git curl jq claude; do command -v "$d" >/dev/null 2>&1 && ok "dep $d" || { err "missing dep: $d"; fail=1; }; done
  [ -f "$CONFIG_FILE" ] && ok "config present" || { err "no config (run setup)"; return 1; }
  load_config
  echo "$(curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" "$JIRA_BASE_URL/rest/api/2/myself")" | jq -e '.accountId' >/dev/null 2>&1 \
    && ok "Jira auth" || { err "Jira auth failed (token needs read:jira-user)"; fail=1; }
  local bbcode; bbcode="$(curl -sS -o /dev/null -w '%{http_code}' -u "$JIRA_EMAIL:$BITBUCKET_API_TOKEN" "https://api.bitbucket.org/2.0/workspaces/$BITBUCKET_WORKSPACE" || true)"
  [ "$bbcode" = "200" ] \
    && ok "Bitbucket auth (workspace '$BITBUCKET_WORKSPACE' reachable)" \
    || { err "Bitbucket auth failed (HTTP $bbcode) — 'autofix run' draft-PR step will fail. Token needs a Bitbucket-app token with read/write:pullrequest:bitbucket. Re-run setup."; fail=1; }
  info "git push auth is validated per-repo on first run (uses your local git credential helper)."
  [ "$fail" = 0 ] && ok "All good." || die "Some checks failed."
}

# =======================================================================
# map
# =======================================================================
cmd_map() { # map THER=thermometer_ios [PROJ=repo ...]
  load_config
  [ "$#" -gt 0 ] || { info "Current REPO_MAP: ${REPO_MAP:-(empty)}"; return 0; }
  local newmap="$REPO_MAP" pair k
  for pair in "$@"; do
    k="${pair%%=*}"
    # Drop any prior entry for this key, then append. `|| true` so an empty map (no
    # matching line → grep exits 1) doesn't abort the script under `set -e`/pipefail.
    newmap="$(printf '%s' "$newmap" | tr ',' '\n' | grep -v "^$k=" | paste -sd, - || true)"
    newmap="${newmap:+$newmap,}$pair"
  done
  # rewrite REPO_MAP line in config
  local tmp; tmp="$(mktemp)"
  grep -v '^REPO_MAP=' "$CONFIG_FILE" > "$tmp" || true
  printf 'REPO_MAP="%s"\n' "$newmap" >> "$tmp"
  mv "$tmp" "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"
  ok "REPO_MAP = $newmap"
}

# =======================================================================
# list
# =======================================================================
build_jql() {
  local labels_csv; labels_csv="$(printf '"%s",' ${AI_LABELS//,/ } | sed 's/,$//')"
  printf 'assignee = currentUser() AND statusCategory != Done AND (labels in (%s) OR summary ~ "%s" OR description ~ "%s") ORDER BY updated DESC' \
    "$labels_csv" "$AI_TEXT" "$AI_TEXT"
}
cmd_list() {
  load_config
  local jql; jql="$(build_jql)"
  info "JQL: $jql"
  local res; res="$(jira_search "$jql")"
  echo "$res" | jq -e '.issues' >/dev/null 2>&1 || die "Jira search failed: $(echo "$res" | jq -r '.errorMessages? // .' 2>/dev/null)"
  local n; n="$(echo "$res" | jq '.issues | length')"
  hr; [ "$n" = 0 ] && { warn "No eligible tickets assigned to you."; return 0; }
  ok "$n eligible ticket(s):"
  echo "$res" | jq -r '.issues[] | "  \(.key)\t[\(.fields.status.name)]\t\(.fields.summary)"'
  hr; info "Run one with:  $0 run <KEY>"
}

# =======================================================================
# run  <TICKET-KEY>
# =======================================================================
cmd_run() {
  load_config
  local key="${1:-}"; [ -n "$key" ] || die "Usage: $0 run <TICKET-KEY>"
  local proj="${key%%-*}"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local runlog_dir="$RUNS_DIR/$key-$stamp"; mkdir -p "$runlog_dir"

  hr; info "Resolving $key ..."
  local issue; issue="$(jira GET "/issue/$key?fields=summary,description,status")"
  echo "$issue" | jq -e '.key' >/dev/null 2>&1 || die "Cannot fetch $key: $(echo "$issue" | jq -r '.errorMessages? // .' 2>/dev/null)"
  local summary desc
  summary="$(echo "$issue" | jq -r '.fields.summary // ""')"
  desc="$(echo "$issue" | jq -r '.fields.description // ""')"
  ok "$key — $summary"
  printf '%s' "$issue" > "$runlog_dir/ticket.json"

  # resolve repo
  local repo; repo="$(resolve_repo "$proj" || true)"
  if [ -z "$repo" ]; then
    if [ "${BATCH:-0}" = 1 ]; then
      warn "Skipping $key — no repo mapping for '$proj'. Add one with: $0 map $proj=<repo>"
      return 0
    fi
    warn "No repo mapping for project '$proj'."
    prompt_value repo "Bitbucket repo slug for $proj" ""
    [ -n "$repo" ] || die "Repo required."
    cmd_map "$proj=$repo" >/dev/null
  fi
  info "Repo: $BITBUCKET_WORKSPACE/$repo"

  # Clean remote URL — no credentials embedded (git_bb supplies auth via header).
  # Authenticated remote for git ops; clean URL only for display in messages.
  local remote remote_clean
  remote="$(bb_remote "$repo")"
  remote_clean="https://bitbucket.org/$BITBUCKET_WORKSPACE/$repo.git"

  # dedup #1: an OPEN pull request already exists for this ticket's branch (incl.
  # drafts) — don't clone/fix/re-open. PRs in any open state (drafts have state OPEN).
  local prq prresp prn prurl
  prq="$(jq -rn --arg b "feature/$key" '("state=\"OPEN\" AND source.branch.name=\"" + $b + "\"")|@uri')"
  prresp="$(bb GET "/repositories/$BITBUCKET_WORKSPACE/$repo/pullrequests?q=$prq&fields=values.id,values.draft,values.links.html.href")"
  if [ "$(http_code "$prresp")" = "200" ]; then
    prn="$(http_body "$prresp" | jq -r '.values | length' 2>/dev/null || echo 0)"
    if [ "${prn:-0}" -gt 0 ]; then
      prurl="$(http_body "$prresp" | jq -r '.values[0].links.html.href // empty' 2>/dev/null)"
      ok "$key already has an open pull request${prurl:+ — $prurl} — skipping (won't re-fix or re-draft)."
      return 0
    fi
  fi

  # dedup #2: if the ticket's branch already exists on the remote, it was handled — skip
  if git_bb ls-remote --heads "$remote" "feature/$key" 2>/dev/null | grep -q "feature/$key"; then
    info "$key already has branch feature/$key on remote — skipping (already processed)."
    return 0
  fi

  local base="$BASE_BRANCH"
  if ! git_bb ls-remote --heads "$remote" "$base" 2>/dev/null | grep -q "$base"; then
    local mainb; mainb="$(http_body "$(bb GET "/repositories/$BITBUCKET_WORKSPACE/$repo")" | jq -r '.mainbranch.name // "main"')"
    warn "Base branch '$base' not found; using repo default '$mainb'."
    base="$mainb"
  fi

  # workspace prep (isolated clone, never the dev's working copy)
  mkdir -p "$WORKSPACES_DIR"
  local wt="$WORKSPACES_DIR/$repo"
  if [ -d "$wt/.git" ]; then
    info "Updating existing workspace clone..."
    ( cd "$wt" && git remote set-url origin "$remote" && git_bb fetch --depth 1 origin "$base" && git checkout -q -B "$base" "origin/$base" )
  else
    info "Cloning $base ..."
    git_bb clone --depth 1 --branch "$base" "$remote" "$wt" \
      || die "Clone failed. Check 'autofix doctor' (Bitbucket auth) and that repo '$BITBUCKET_WORKSPACE/$repo' exists (manual test: git clone $remote_clean)."
  fi

  local branch="feature/$key"
  ( cd "$wt" && git checkout -q -B "$branch" )
  ok "Branch $branch off $base"

  # ---- Claude Code does the code change (no git remote access) ----
  local before; before="$(cd "$wt" && git rev-parse HEAD)"
  local prompt; prompt="$(cat <<EOF
You are an autonomous engineer resolving Jira ticket $key in this repository.

TICKET TITLE: $summary
TICKET DESCRIPTION:
$desc

Rules:
- Make the MINIMAL change needed to satisfy the ticket. Follow the repo's existing
  conventions, file layout, naming, and lint rules (check .editorconfig / linters).
- Preserve backward compatibility. Do not refactor unrelated code.
- If the repo has linters/tests for the touched area, run them and fix what you broke.
- Commit your work with: git commit -m "fix($key): <one-line summary>"
- DO NOT push, DO NOT create a branch, DO NOT touch the git remote, DO NOT open a PR.
  The harness handles branching, pushing, and the draft PR. Just edit + commit locally.
- If the ticket is too ambiguous or risky to do safely, make NO commit and explain why.
EOF
)"
  printf '%s' "$prompt" > "$runlog_dir/prompt.txt"
  hr; info "Invoking Claude Code (this may take a few minutes)..."
  ( cd "$wt" && claude -p "$prompt" \
      --permission-mode acceptEdits \
      --allowedTools "Read,Edit,Write,Grep,Glob,Bash" \
      2>&1 | tee "$runlog_dir/claude.log" ) || warn "Claude Code exited non-zero (see log)."

  local after; after="$(cd "$wt" && git rev-parse HEAD)"
  if [ "$before" = "$after" ]; then
    err "No commit was produced — Claude made no change (ambiguous/risky ticket?). See $runlog_dir/claude.log"
    jira_comment "$key" "🤖 autofix-jira could not safely resolve this ticket automatically (no change committed). Needs human review."
    die "Aborted: nothing to push."
  fi
  ( cd "$wt" && git --no-pager diff "$before..$after" --stat | tee "$runlog_dir/diff.stat"; git --no-pager diff "$before..$after" > "$runlog_dir/change.diff" )
  ok "Commit produced."

  # ---- push ----
  info "Pushing $branch ..."
  ( cd "$wt" && git_bb push -u origin "$branch" 2>&1 | tee "$runlog_dir/push.log" ) \
    || die "Push failed (check 'autofix doctor' Bitbucket auth). Branch committed locally at $wt."

  # ---- draft PR (REST; the only reliable way to set draft:true) ----
  info "Opening DRAFT pull request ..."
  local prbody prdata resp code
  prbody="$(printf '### Jira\n[%s](%s/browse/%s) — %s\n\n%s\n\n---\n🤖 Generated by autofix-jira. **Draft PR — review required. No merge/deploy performed.**' \
    "$key" "$JIRA_BASE_URL" "$key" "$summary" "$(cat "$runlog_dir/diff.stat" 2>/dev/null)")"
  prdata="$(jq -n --arg t "$key: $summary" --arg s "$branch" --arg d "$base" --arg body "$prbody" \
    '{title:$t, source:{branch:{name:$s}}, destination:{branch:{name:$d}}, description:$body, draft:true, close_source_branch:false}')"
  resp="$(bb POST "/repositories/$BITBUCKET_WORKSPACE/$repo/pullrequests" "$prdata")"
  code="$(http_code "$resp")"
  local prurl="" prid=""
  if [ "$code" = "201" ] || [ "$code" = "200" ]; then
    prid="$(http_body "$resp" | jq -r '.id')"
    prurl="$(http_body "$resp" | jq -r '.links.html.href')"
    ok "Draft PR #$prid → $prurl"
  else
    warn "PR API returned HTTP $code. Branch is pushed; open the PR manually."
    warn "$(http_body "$resp" | jq -r '.error.message? // .' 2>/dev/null | head -c 300)"
  fi

  # ---- jira write-back ----
  jira_comment "$key" "🤖 autofix-jira opened a DRAFT pull request.${prurl:+

PR: $prurl}
Branch: \`$branch\` (off \`$base\`)
$(cat "$runlog_dir/diff.stat" 2>/dev/null)

Draft only — awaiting human review."
  jira_progress "$key" || true

  hr; ok "Done. $key → draft PR. Telemetry: $runlog_dir"
}

jira_comment() { # jira_comment KEY TEXT
  local key="$1" text="$2" data
  data="$(jq -n --arg b "$text" '{body:$b}')"
  jira POST "/issue/$key/comment" "$data" >/dev/null 2>&1 && ok "Jira comment added" || warn "Jira comment failed"
}
jira_progress() { # move ticket to first In-Progress transition
  local key="$1" trs tid
  trs="$(jira GET "/issue/$key/transitions")"
  tid="$(echo "$trs" | jq -r '.transitions[] | select(.to.statusCategory.key=="indeterminate") | .id' | head -1 || true)"
  [ -n "$tid" ] || { warn "No In-Progress transition available"; return 1; }
  jira POST "/issue/$key/transitions" "$(jq -n --arg id "$tid" '{transition:{id:$id}}')" >/dev/null 2>&1 \
    && ok "Jira moved to In Progress" || warn "Jira transition failed"
}

# =======================================================================
# run-all [--watch MINUTES]
# =======================================================================
cmd_run_all() {
  load_config
  local watch=0
  if [ "${1:-}" = "--watch" ]; then
    watch="${2:-5}"
    case "$watch" in ''|*[!0-9]*) die "--watch needs a whole number of minutes (e.g. --watch 5)." ;; esac
    [ "$watch" -ge 1 ] || die "--watch interval must be at least 1 minute."
  fi

  # prevent overlapping batches (e.g. a slow run still going when the next tick fires)
  if ! mkdir "$RUNALL_LOCK" 2>/dev/null; then
    warn "Another run-all is already in progress (lock: $RUNALL_LOCK). Exiting."
    exit 0
  fi
  trap 'rmdir "$RUNALL_LOCK" 2>/dev/null || true' EXIT

  run_batch_once() {
    local jql res keys total done_n skip_n fail_n
    jql="$(build_jql)"
    res="$(jira_search "$jql")"
    echo "$res" | jq -e '.issues' >/dev/null 2>&1 || { err "Jira search failed"; return 1; }
    keys="$(echo "$res" | jq -r '.issues[].key')"
    total="$(printf '%s\n' "$keys" | grep -c . || true)"
    hr; info "Batch: $total eligible ticket(s) assigned to you"
    [ "$total" -eq 0 ] && { ok "Nothing to do."; return 0; }
    done_n=0; skip_n=0; fail_n=0
    local key
    while IFS= read -r key; do
      [ -z "$key" ] && continue
      hr; info "▶ $key"
      if ( BATCH=1; cmd_run "$key" ); then done_n=$((done_n+1)); else fail_n=$((fail_n+1)); warn "$key did not complete (see telemetry)."; fi
    done <<< "$keys"
    hr; ok "Batch complete: $done_n processed, $fail_n failed/needs-review of $total."
  }

  if [ "$watch" != 0 ]; then
    info "Daemon mode: re-checking every ${watch} min. Ctrl-C to stop."
    while true; do
      run_batch_once || warn "Batch errored; will retry next cycle."
      info "Sleeping ${watch} min..."; sleep "$(( watch * 60 ))"
    done
  else
    run_batch_once
  fi
}

# =======================================================================
# background daemon: install-daemon / uninstall-daemon / logs / status
# =======================================================================
install_shell_hook() {
  cat > "$SHELLRC" <<EOF
# autofix-jira shell hook — shows recent daemon activity when a terminal opens
command -v autofix >/dev/null 2>&1 && autofix status --brief 2>/dev/null || true
EOF
  local prof
  case "${SHELL:-}" in
    */zsh)  prof="$HOME/.zshrc" ;;
    */bash) prof="$HOME/.bashrc" ;;
    *)      prof="$HOME/.profile" ;;
  esac
  if grep -q '# >>> autofix-jira >>>' "$prof" 2>/dev/null; then
    info "Shell hook already present in $prof"
  else
    {
      echo ""
      echo "# >>> autofix-jira >>>"
      echo "[ -f \"$SHELLRC\" ] && . \"$SHELLRC\""
      echo "# <<< autofix-jira <<<"
    } >> "$prof"
    ok "Shell hook added to $prof — new terminals will show recent activity."
  fi
}
remove_shell_hook() {
  local prof tmp
  for prof in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
    [ -f "$prof" ] || continue
    if grep -q '# >>> autofix-jira >>>' "$prof"; then
      tmp="$(mktemp)"
      sed '/# >>> autofix-jira >>>/,/# <<< autofix-jira <<</d' "$prof" > "$tmp" && mv "$tmp" "$prof"
      ok "Shell hook removed from $prof"
    fi
  done
  rm -f "$SHELLRC"
}

cmd_install_daemon() {
  load_config
  local min="${1:-5}" interval; interval=$(( min * 60 ))
  [ "$interval" -ge 60 ] || die "Interval must be >= 1 minute."
  if [ "$(uname -s)" = "Darwin" ]; then
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$DAEMON_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$DAEMON_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SELF</string>
    <string>run-all</string>
  </array>
  <key>StartInterval</key><integer>$interval</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$DAEMON_LOG</string>
  <key>StandardErrorPath</key><string>$DAEMON_LOG</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
EOF
    launchctl unload "$DAEMON_PLIST" 2>/dev/null || true
    launchctl load "$DAEMON_PLIST" || die "launchctl load failed."
    ok "launchd agent loaded — runs 'run-all' every ${min} min ($DAEMON_LABEL)."
  else
    command -v crontab >/dev/null 2>&1 || die "crontab not found; install cron or schedule manually."
    local line="*/$min * * * * /bin/bash $SELF run-all >> $DAEMON_LOG 2>&1 # autofix-jira"
    ( crontab -l 2>/dev/null | grep -v '# autofix-jira'; echo "$line" ) | crontab -
    ok "cron job installed — runs 'run-all' every ${min} min."
  fi
  install_shell_hook
  hr; ok "Background autofix is live. Log: $DAEMON_LOG"
  info "Watch it work:  $0 logs -f      Stop it:  $0 uninstall-daemon"
}

cmd_uninstall_daemon() {
  if [ "$(uname -s)" = "Darwin" ]; then
    launchctl unload "$DAEMON_PLIST" 2>/dev/null || true
    rm -f "$DAEMON_PLIST"
    ok "launchd agent removed."
  else
    crontab -l 2>/dev/null | grep -v '# autofix-jira' | crontab - || true
    ok "cron job removed."
  fi
  remove_shell_hook
  rmdir "$RUNALL_LOCK" 2>/dev/null || true
}

# =======================================================================
# login launcher: auto-OPEN a visible Terminal at login and run the
# FOREGROUND watcher inside it. Unlike the daemon, it is NOT supervised —
# closing the Terminal window, Ctrl-C, or the watcher exiting all stop it.
# =======================================================================
cmd_install_login() {
  load_config
  local min="${1:-5}"
  [ "$min" -ge 1 ] 2>/dev/null || die "Interval must be a whole number of minutes (>= 1)."
  [ "$(uname -s)" = "Darwin" ] || die "install-login is macOS-only (uses Terminal + Login Items). On Linux, add '$SELF start $min' to your desktop's Startup Applications, or use '$0 install-daemon $min' for a headless background run."

  # A double-clickable .command that runs the foreground watcher. `exec` so the
  # watcher owns the Terminal session: closing the window or Ctrl-C ends it cleanly.
  mkdir -p "$AUTOFIX_HOME"
  cat > "$LOGIN_CMD" <<EOF
#!/bin/bash
# autofix-jira startup launcher — opens at login and watches Jira in the foreground.
# Close this window (or press Ctrl-C) to stop. Re-open it from Login Items to restart.
exec "$SELF" start $min
EOF
  chmod +x "$LOGIN_CMD"

  # Register as a macOS Login Item (replace any existing one first to avoid dupes).
  # Match by PATH so uninstall is reliable regardless of how macOS names the item.
  osascript -e "tell application \"System Events\" to delete (every login item whose path is \"$LOGIN_CMD\")" >/dev/null 2>&1 || true
  osascript -e "tell application \"System Events\" to make login item at end with properties {name:\"$LOGIN_ITEM_NAME\", path:\"$LOGIN_CMD\", hidden:false}" >/dev/null 2>&1 \
    || die "Could not register the Login Item. macOS may have blocked Automation — allow Terminal to control 'System Events' in System Settings ▸ Privacy & Security ▸ Automation, then re-run '$0 install-login $min'."

  hr; ok "Login launcher installed — a Terminal will open at every login and run 'autoBotDraft' ($min-min polls)."
  info "Launcher script: $LOGIN_CMD"
  info "It runs in the FOREGROUND: close the window or press Ctrl-C to stop it."
  info "Remove it with:  $0 uninstall-login"
  warn "First time only: macOS may ask permission for Terminal to control 'System Events' — click OK."
  info "Start it now without rebooting:  open \"$LOGIN_CMD\""
}

cmd_uninstall_login() {
  [ "$(uname -s)" = "Darwin" ] || { warn "install-login is macOS-only; nothing to remove."; return 0; }
  osascript -e "tell application \"System Events\" to delete (every login item whose path is \"$LOGIN_CMD\")" >/dev/null 2>&1 \
    && ok "Login Item removed." || warn "Could not remove the Login Item (it may already be gone)."
  rm -f "$LOGIN_CMD" && ok "Launcher script removed."
  info "Already-open watcher windows keep running until you close them or press Ctrl-C."
}

cmd_logs() {
  [ -f "$DAEMON_LOG" ] || { warn "No log yet at $DAEMON_LOG (daemon hasn't run)."; return 0; }
  case "${1:-}" in
    -f|--follow) info "Following $DAEMON_LOG (Ctrl-C to stop)"; tail -n 40 -f "$DAEMON_LOG" ;;
    ''|*[!0-9]*) tail -n 200 "$DAEMON_LOG" ;;
    *) tail -n "$1" "$DAEMON_LOG" ;;
  esac
}

cmd_status() {
  local brief=0; [ "${1:-}" = "--brief" ] && brief=1
  local state="not installed"
  if [ "$(uname -s)" = "Darwin" ]; then
    if launchctl list 2>/dev/null | grep -q "$DAEMON_LABEL"; then state="running (launchd)"
    elif [ -f "$DAEMON_PLIST" ]; then state="installed (not loaded)"; fi
  else
    crontab -l 2>/dev/null | grep -q '# autofix-jira' && state="scheduled (cron)"
  fi
  if [ "$brief" = 1 ]; then
    printf '%s autofix-jira daemon: %s\n' "$(_c 36 '›')" "$state"
    [ -f "$DAEMON_LOG" ] && { echo "  recent activity:"; tail -n 6 "$DAEMON_LOG" | sed 's/^/  /'; echo "  (full live log: autofix logs -f)"; }
    return 0
  fi
  hr; info "autofix-jira status"; hr
  echo "Daemon: $state"
  echo "Plist:  $DAEMON_PLIST"
  echo "Log:    $DAEMON_LOG"
  [ -f "$DAEMON_LOG" ] && { echo; echo "--- last 20 log lines ---"; tail -n 20 "$DAEMON_LOG"; }
  echo; info "Follow live: $0 logs -f"
}

# =======================================================================
usage() {
  cat <<EOF
autofix-jira v$VERSION — autonomous Jira → Claude Code → Bitbucket draft PRs

Usage:
  $0 quickstart            ★ Complete guided setup, end to end (deps → config → map → verify → auto-start → watch)
  $0 setup                 Interactive one-time configuration (just the credentials step)
  $0 doctor                Verify deps + credentials
  $0 map KEY=repo [...]    Map a Jira project key to a Bitbucket repo slug
  $0 list                  List AI-eligible tickets assigned to you
  $0 run <TICKET-KEY>      Resolve one ticket → branch → commit → push → DRAFT PR
  $0 run-all [--watch MIN] Process every eligible ticket; --watch loops every MIN minutes (foreground)
  $0 start [MIN]           Foreground watcher (same as running 'autoBotDraft'); Ctrl-C to stop
  autoBotDraft [MIN]       Shortcut command: start watching now, Ctrl-C to stop (like 'claude')
  $0 install-daemon [MIN]  Run in the BACKGROUND every MIN min (default 5) via launchd/cron; no terminal needed
  $0 uninstall-daemon      Stop and remove the background daemon + shell hook
  $0 install-login [MIN]   macOS: auto-OPEN a Terminal at login running the foreground watcher (close window / Ctrl-C to stop)
  $0 uninstall-login       Remove the login launcher (Login Item + script)
  $0 logs [-f|N]           Show daemon log (last N lines, or -f to follow live)
  $0 status [--brief]      Show daemon state + recent activity
  $0 version

Eligibility = assigned to you AND not Done AND (label in AI_LABELS OR text matches AI_TEXT).
Config: $CONFIG_FILE   Safety: only ever creates DRAFT PRs; never merges or deploys.
EOF
}

# Foreground watcher — run it, watch it work, Ctrl-C to stop (like `claude`).
start_watch() {
  local mins="${1:-5}"
  case "$mins" in
    ''|*[!0-9]*) die "Interval must be a whole number of minutes. Usage: autoBotDraft [MINUTES] (e.g. 'autoBotDraft 5'). For other actions use 'autofix <command>', e.g. 'autofix doctor'." ;;
  esac
  [ "$mins" -ge 1 ] || die "Interval must be at least 1 minute."
  hr
  info "autoBotDraft — watching Jira every ${mins} min for AI tickets assigned to you."
  info "Each step is printed live below. Press Ctrl-C to stop."
  hr
  trap 'echo; info "autoBotDraft stopped."; exit 0' INT
  cmd_run_all --watch "$mins"
}

main() {
  # If invoked as `autoBotDraft`, start the foreground watcher directly.
  if [ "$(basename "${0:-}")" = "autoBotDraft" ]; then
    start_watch "${1:-5}"; return
  fi
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    quickstart|onboard|init) cmd_quickstart "$@" ;;
    setup)   cmd_setup "$@" ;;
    doctor)  cmd_doctor "$@" ;;
    map)     cmd_map "$@" ;;
    list)    cmd_list "$@" ;;
    run)     cmd_run "$@" ;;
    run-all|run_all) cmd_run_all "$@" ;;
    start)   start_watch "${1:-5}" ;;
    install-daemon)   cmd_install_daemon "$@" ;;
    uninstall-daemon) cmd_uninstall_daemon "$@" ;;
    install-login)    cmd_install_login "$@" ;;
    uninstall-login)  cmd_uninstall_login "$@" ;;
    logs)             cmd_logs "$@" ;;
    status)           cmd_status "$@" ;;
    version|-v|--version) echo "autofix-jira v$VERSION" ;;
    ""|help|-h|--help) usage ;;
    *) err "Unknown command: $cmd"; usage; exit 1 ;;
  esac
}
main "$@"
