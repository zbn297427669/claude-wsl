#!/usr/bin/env bash
# Display-only notify lamp for Claude Code's statusLine.
# Optional inner command (your existing status line):
#   CLAUDE_STATUSLINE_INNER, or one line in $INSTALL_DIR/statusline-inner
set -u

INSTALL_DIR="${CLAUDE_WSL_HOME:-$HOME/.local/share/claude-wsl}"
DIM=$'\033[38;5;238m'
RST=$'\033[0m'
SEP="${DIM} │ ${RST}"

inner="${CLAUDE_STATUSLINE_INNER:-}"
if [[ -z "$inner" && -f "$INSTALL_DIR/statusline-inner" ]]; then
  inner=$(head -n 1 "$INSTALL_DIR/statusline-inner")
fi

# Snapshot stdin once so the inner status line still gets the JSON payload.
payload=$(mktemp)
trap 'rm -f "$payload"' EXIT
cat > "$payload"

out=""
if [[ -n "$inner" ]]; then
  out=$(bash -c "$inner" < "$payload") || true
fi

if [[ -f "$INSTALL_DIR/disabled" ]]; then
  bell="${DIM}🔕${RST}"
else
  bell=$'\033[1;38;5;220m🔔'"${RST}"
fi

if [[ -z "$out" ]]; then
  printf '%s\n' "$bell"
  exit 0
fi

printf '%s%s%s\n' "$out" "$SEP" "$bell"
