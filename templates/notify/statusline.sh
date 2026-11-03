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
  app=""
  if [[ -r "$INSTALL_DIR/platform.sh" ]]; then
    # shellcheck disable=SC1091
    . "$INSTALL_DIR/platform.sh" 2>/dev/null || true
  fi
  if type claude_wsl_terminal_app >/dev/null 2>&1; then
    app=$(claude_wsl_terminal_app 2>/dev/null || true)
  fi
  # A muted app notifies on its own, so the lamp shows no toast rather than
  # claiming one this hook will never send.
  if [[ -n "$app" ]] && type claude_wsl_app_muted >/dev/null 2>&1 \
      && claude_wsl_app_muted "$app" 2>/dev/null; then
    bell="${DIM}🔕${RST}"
  else
    bell=$'\033[1;38;5;220m🔔'"${RST}"
  fi
fi

if [[ -z "$out" ]]; then
  printf '%s\n' "$bell"
  exit 0
fi

printf '%s%s%s\n' "$out" "$SEP" "$bell"
