#!/usr/bin/env bash
# Toggle claude-wsl notifications without removing Claude Code hooks.
# Usage: notify-ctl.sh [on|off|toggle|status|sound]
set -euo pipefail

# Always the installed hook dir — not this script's path (may be a symlink in ~/.local/bin).
INSTALL_DIR="${CLAUDE_WSL_HOME:-$HOME/.local/share/claude-wsl}"
FLAG="$INSTALL_DIR/disabled"
SOUND_FILE="$INSTALL_DIR/sound"
cmd="${1:-status}"

# Short names stored in $SOUND_FILE. Default if missing.
SHORT_SOUNDS=(Default IM Mail Reminder SMS silent)
LOOP_SOUNDS=()
for n in Alarm Call; do
  LOOP_SOUNDS+=("$n")
  for i in $(seq 2 10); do LOOP_SOUNDS+=("${n}$i"); done
done

current_sound() {
  local s=""
  if [[ -f "$SOUND_FILE" ]]; then
    s=$(head -n 1 "$SOUND_FILE" | tr -d '\r')
  fi
  s="${s:-Default}"
  printf '%s' "$s"
}

normalize_sound() {
  local raw="${1:-}"
  raw="${raw// /}"
  raw="${raw#ms-winsoundevent:}"
  raw="${raw#Notification.Looping.}"
  raw="${raw#Notification.}"
  case "${raw,,}" in
    ""|default) printf 'Default' ;;
    im) printf 'IM' ;;
    mail) printf 'Mail' ;;
    reminder) printf 'Reminder' ;;
    sms) printf 'SMS' ;;
    silent|mute|none|off) printf 'silent' ;;
    alarm|alarm[2-9]|alarm10|call|call[2-9]|call10)
      # Canonicalize Alarm2 / call10
      local head="${raw:0:1}"
      local rest="${raw:1}"
      printf '%s%s' "${head^^}" "${rest,,}"
      ;;
    *) return 1 ;;
  esac
}

preview_sound() {
  local name="$1"
  local ps="$INSTALL_DIR/send-notification.ps1"
  command -v powershell.exe >/dev/null 2>&1 || return 0
  command -v wslpath >/dev/null 2>&1 || return 0
  [[ -f "$ps" ]] || return 0
  local win
  win=$(wslpath -w "$ps" 2>/dev/null) || return 0
  powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden \
    -File "$win" -Title "claude-wsl" -Message "sound: $name" -Sound "$name" \
    >/dev/null 2>&1 || true
}

on() {
  rm -f "$FLAG"
  echo "通知已开启（Windows toast + 标签指示）"
}

off() {
  mkdir -p "$INSTALL_DIR"
  touch "$FLAG"
  echo "通知已关闭（hooks 仍在，但不再弹窗/改标签）"
}

notify_state() {
  if [[ -f "$FLAG" ]]; then echo "关"; else echo "开"; fi
}

usage() {
  echo "用法: /wsl-notify on|off|toggle|status" >&2
  echo "      /wsl-notify sound [Default|IM|Mail|Reminder|SMS|silent]" >&2
  echo "  或: wsl-notify ..." >&2
}

case "$cmd" in
  on|enable|1) on ;;
  off|disable|0) off ;;
  toggle)
    if [[ -f "$FLAG" ]]; then on; else off; fi
    ;;
  status)
    echo "通知当前：$(notify_state)"
    echo "铃声：$(current_sound)"
    ;;
  sound|ringtone|bell)
    sub="${2:-}"
    if [[ -z "$sub" || "$sub" == "status" ]]; then
      echo "当前铃声：$(current_sound)"
      echo "可选：${SHORT_SOUNDS[*]}"
      exit 0
    fi
    if [[ "$sub" == "list" ]]; then
      echo "短提示：${SHORT_SOUNDS[*]}"
      echo "闹钟/来电：${LOOP_SOUNDS[*]}"
      exit 0
    fi
    canon=$(normalize_sound "$sub") || {
      echo "未知铃声：$sub" >&2
      echo "可选：${SHORT_SOUNDS[*]}" >&2
      echo "查看全部：/wsl-notify sound list" >&2
      exit 1
    }
    mkdir -p "$INSTALL_DIR"
    printf '%s\n' "$canon" > "$SOUND_FILE"
    echo "铃声已设为：$canon"
    preview_sound "$canon"
    ;;
  *)
    usage
    exit 1
    ;;
esac
