#!/usr/bin/env bash
# Toggle claude-wsl notifications without removing Claude Code hooks.
# Usage: notify-ctl.sh [on|off|toggle|status|sound]
set -euo pipefail

# Always the installed hook dir — not this script's path (may be a symlink in ~/.local/bin).
INSTALL_DIR="${CLAUDE_WSL_HOME:-$HOME/.local/share/claude-wsl}"
FLAG="$INSTALL_DIR/disabled"
SOUND_FILE="$INSTALL_DIR/sound"
MUTE_FILE="$INSTALL_DIR/mute-apps"
cmd="${1:-status}"

# platform.sh owns app detection and the mute-file format; the hook and this
# command must agree on both, so neither reimplements them.
#
# Prefer the installed copy, but fall back to the one next to this script:
# running it straight from a checkout (as tests and a fresh install do) must
# still detect the app and read the list.
for _platform in "$INSTALL_DIR/platform.sh" \
                 "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/platform.sh"; do
  if [[ -r "$_platform" ]]; then
    # shellcheck disable=SC1090
    . "$_platform" 2>/dev/null || true
    break
  fi
done
unset _platform

# Canonical spelling for an app name entered by hand. Known terminals get the
# name claude_wsl_terminal_app reports, so `mute orca` and a detected "Orca"
# match; anything else keeps its own spelling.
canon_app() {
  local raw="${1:-}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  case "${raw,,}" in
    ""|terminal) printf '' ;;
    orca) printf 'Orca' ;;
    wt|windows\ terminal|windowsterminal) printf 'Windows Terminal' ;;
    vscode|vs\ code|code) printf 'VS Code' ;;
    wezterm) printf 'WezTerm' ;;
    alacritty) printf 'Alacritty' ;;
    kitty) printf 'kitty' ;;
    tabby) printf 'Tabby' ;;
    cursor) printf 'Cursor' ;;
    *) printf '%s' "$raw" ;;
  esac
}

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
  [[ -f "$ps" ]] || return 0
  # platform.sh gives us the path converter for this host (wslpath or cygpath).
  if [[ -r "$INSTALL_DIR/platform.sh" ]]; then
    # shellcheck disable=SC1091
    . "$INSTALL_DIR/platform.sh" 2>/dev/null || true
  fi
  if type claude_wsl_ps >/dev/null 2>&1; then
    claude_wsl_ps "$ps" -Title "claude-wsl" -Message "sound: $name" -Sound "$name" >/dev/null 2>&1 || true
    return 0
  fi
  # Fallback for an install that predates platform.sh.
  command -v powershell.exe >/dev/null 2>&1 || return 0
  local win=""
  if command -v wslpath >/dev/null 2>&1; then
    win=$(wslpath -w "$ps" 2>/dev/null) || return 0
  elif command -v cygpath >/dev/null 2>&1; then
    win=$(cygpath -w "$ps" 2>/dev/null) || return 0
  else
    return 0
  fi
  powershell.exe -NoProfile -WindowStyle Hidden \
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

# One app name per line, normalized so the file stays stable and readable.
muted_apps() {
  [[ -f "$MUTE_FILE" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] && printf '%s\n' "$line"
  done < "$MUTE_FILE"
}

is_muted() {
  local want="${1,,}" a
  [[ -n "$want" ]] || return 1
  while IFS= read -r a; do
    [[ "${a,,}" == "$want" ]] && return 0
  done < <(muted_apps)
  return 1
}

# Rewrite the file without the entries matching the given lower-case name(s).
without_apps() {
  local drop1="$1" drop2="${2:-}" a
  while IFS= read -r a; do
    [[ "${a,,}" == "$drop1" || ( -n "$drop2" && "${a,,}" == "$drop2" ) ]] && continue
    printf '%s\n' "$a"
  done < <(muted_apps)
}

mute_app() {
  local raw="${1:-}" app
  # No argument: mute whatever this shell is running under, which is what the
  # user means when they type /wsl-notify mute inside Orca.
  if [[ -z "$raw" ]]; then
    app=$(claude_wsl_terminal_app 2>/dev/null || true)
    if [[ -z "$app" ]]; then
      echo "无法识别当前终端应用。请指定名称：/wsl-notify mute Orca" >&2
      return 1
    fi
  else
    app=$(canon_app "$raw")
    if [[ -z "$app" ]]; then
      echo "未知应用：$raw" >&2
      return 1
    fi
  fi
  if is_muted "$app"; then
    echo "已静音：$app（无需重复添加）"
    return 0
  fi
  mkdir -p "$INSTALL_DIR"
  printf '%s\n' "$app" >> "$MUTE_FILE"
  echo "已静音：$app —— 在该应用里不再弹 toast、不显示铃铛/进度，由应用自己通知"
}

unmute_app() {
  local raw="${1:-}" app tmp
  if [[ -z "$raw" ]]; then
    app=$(claude_wsl_terminal_app 2>/dev/null || true)
    if [[ -z "$app" ]]; then
      echo "无法识别当前终端应用。请指定名称：/wsl-notify unmute Orca" >&2
      return 1
    fi
  else
    app=$(canon_app "$raw")
    [[ -n "$app" ]] || { echo "未知应用：$raw" >&2; return 1; }
  fi
  if ! is_muted "$app"; then
    echo "未静音：$app"
    return 0
  fi
  tmp="$MUTE_FILE.tmp.$$"
  # `terminal` means "whatever this shell runs under", so removing a concrete
  # app also clears that generic entry -- otherwise it would keep the silence.
  without_apps "${app,,}" terminal > "$tmp" 2>/dev/null || true
  if [[ -s "$tmp" ]]; then
    mv "$tmp" "$MUTE_FILE"
  else
    rm -f "$tmp" "$MUTE_FILE"
  fi
  echo "已取消静音：$app"
}

list_apps() {
  local here
  here=$(claude_wsl_terminal_app 2>/dev/null || true)
  echo "当前终端应用：${here:-未知}"
  echo "静音列表："
  local any=0 a
  while IFS= read -r a; do
    if [[ -n "$here" && "${a,,}" == "${here,,}" ]]; then
      echo "  - $a（当前）"
    else
      echo "  - $a"
    fi
    any=1
  done < <(muted_apps)
  [[ "$any" = "1" ]] || echo "  （空）"
  echo "静音=该应用自己发通知，claude-wsl 不再弹窗。"
  echo "用法：/wsl-notify mute [应用]   /wsl-notify unmute [应用]"
}

usage() {
  echo "用法: /wsl-notify on|off|toggle|status" >&2
  echo "      /wsl-notify sound [Default|IM|Mail|Reminder|SMS|silent]" >&2
  echo "      /wsl-notify mute [应用]     不再由 claude-wsl 通知该应用" >&2
  echo "      /wsl-notify unmute [应用]   恢复通知" >&2
  echo "      /wsl-notify apps            查看当前应用与静音列表" >&2
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
    echo "当前终端应用：$(claude_wsl_terminal_app 2>/dev/null || echo 未知)"
    ;;
  mute|muted|silence)
    mute_app "${2:-}"
    ;;
  unmute|unsilence)
    unmute_app "${2:-}"
    ;;
  apps|app|mutes)
    list_apps
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
