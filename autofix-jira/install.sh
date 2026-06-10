#!/usr/bin/env bash
#
# autofix-jira installer — makes `autofix` available on your PATH, then runs setup.
# Usage:  ./install.sh
#
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SRC_DIR/autofix.sh"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
LINK="$BIN_DIR/autofix"

c() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }

c 36 "autofix-jira installer"
[ -f "$SCRIPT" ] || { c 31 "✗ autofix.sh not found next to installer"; exit 1; }

# 1. dependency check
missing=0
for d in git curl jq; do command -v "$d" >/dev/null 2>&1 || { c 31 "✗ missing dependency: $d"; missing=1; }; done
if ! command -v claude >/dev/null 2>&1; then
  c 33 "! Claude Code CLI ('claude') not found."
  c 33 "  Install it from https://claude.com/claude-code then re-run this installer."
  missing=1
fi
[ "$missing" = 0 ] || { c 31 "Install the missing dependencies and re-run."; exit 1; }

# 2. install on PATH
chmod +x "$SCRIPT"
mkdir -p "$BIN_DIR"
ln -sf "$SCRIPT" "$LINK"
ln -sf "$SCRIPT" "$BIN_DIR/autoBotDraft"
c 32 "✓ Linked $LINK and $BIN_DIR/autoBotDraft -> $SCRIPT"
c 36 "  Run 'autoBotDraft' to start watching (Ctrl-C to stop), or 'autofix <cmd>' for subcommands."

case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *) c 33 "! $BIN_DIR is not on your PATH. Add this to your shell profile:"
     c 33 "    export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

# 3. run configuration wizard
c 36 "Launching configuration..."
"$SCRIPT" setup

c 32 "✓ Installed. Try:  autofix list"
