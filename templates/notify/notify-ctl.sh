#!/usr/bin/env bash
# Toggle claude-wsl notifications without removing Claude Code hooks.
# Usage: notify-ctl.sh [on|off|toggle|status]
set -euo pipefail

# Always the installed hook dir — not this script's path (may be a symlink in ~/.local/bin).
INSTALL_DIR="${CLAUDE_WSL_HOME:-$HOME/.local/share/claude-wsl}"
FLAG="$INSTALL_DIR/disabled"
cmd="${1:-status}"

on() {
  rm -f "$FLAG"
  echo "通知已开启（Windows toast + 标签指示）"
}

off() {
  mkdir -p "$INSTALL_DIR"
  touch "$FLAG"
  echo "通知已关闭（hooks 仍在，但不再弹窗/改标签）"
}

case "$cmd" in
  on|enable|1) on ;;
  off|disable|0) off ;;
  toggle)
    if [[ -f "$FLAG" ]]; then on; else off; fi
    ;;
  status)
    if [[ -f "$FLAG" ]]; then
      echo "通知当前：关"
    else
      echo "通知当前：开"
    fi
    ;;
  *)
    echo "用法: /wsl-notify on|off|toggle|status" >&2
    echo "  或: wsl-notify on|off|toggle|status" >&2
    exit 1
    ;;
esac
