#!/bin/bash
# Cross-platform helpers shared by notify.sh / notify-ctl.sh / test-workflow.sh.
#
# Two hosts are supported:
#   WSL     -> wslpath, /dev/pts, /proc
#   Git Bash (MSYS/MINGW, native Windows Claude Code) -> cygpath, no /dev/pts
#
# Never fail the caller: every function returns 0/1 and stays quiet on stderr.

# POSIX path -> Windows path. Prints nothing on failure.
claude_wsl_winpath() {
    [ -n "$1" ] || return 1
    if command -v wslpath >/dev/null 2>&1; then
        wslpath -w "$1" 2>/dev/null && return 0
    fi
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1" 2>/dev/null && return 0
    fi
    return 1
}

# True when a Windows PowerShell host is reachable from this shell.
claude_wsl_have_powershell() {
    command -v powershell.exe >/dev/null 2>&1
}

# Run a .ps1 with the host's execution policy left alone.
#
# No -ExecutionPolicy Bypass: installed copies live on local NTFS with no
# Zone.Identifier stream, so the default RemoteSigned policy already runs them.
# Bypass would only be needed if someone downloaded the files, and weakening
# the policy for that case is not worth it.
#
#   claude_wsl_ps script.ps1 -Title x -Message y
#
# CLAUDE_WSL_DRY_RUN=1 prints the command instead of running it. Tests set it
# so a unit test never pops a real toast on someone's desktop.
claude_wsl_ps() {
    local script="$1"
    shift
    [ -f "$script" ] || return 1
    local win
    win=$(claude_wsl_winpath "$script") || return 1
    [ -n "$win" ] || return 1
    if [ "${CLAUDE_WSL_DRY_RUN:-0}" = "1" ]; then
        printf 'dry-run: powershell.exe -File %s %s\n' "$win" "$*"
        return 0
    fi
    claude_wsl_have_powershell || return 1
    powershell.exe -NoProfile -WindowStyle Hidden -File "$win" "$@" 2>/dev/null
}

# True on Git Bash / MSYS (native Windows), false under WSL.
claude_wsl_is_msys() {
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
    esac
    return 1
}

# Run a .ps1 under a time limit.
#
# `timeout` is an external program: it can only execute a file, never a shell
# function. `timeout 3 claude_wsl_ps ...` therefore fails with "No such file or
# directory" and the script silently never runs. So the Windows path is
# resolved first, and the time limit wraps powershell.exe itself.
#
# CLAUDE_WSL_DRY_RUN=1 prints the command instead of running it.
#
#   claude_wsl_ps_timeout 3 capture-hwnd.ps1 -SessionId x
claude_wsl_ps_timeout() {
    local limit="$1" script="$2"
    shift 2
    [ -f "$script" ] || return 1
    local win
    win=$(claude_wsl_winpath "$script") || return 1
    [ -n "$win" ] || return 1
    if [ "${CLAUDE_WSL_DRY_RUN:-0}" = "1" ]; then
        printf 'dry-run: timeout %s powershell.exe -File %s %s\n' "$limit" "$win" "$*"
        return 0
    fi
    claude_wsl_have_powershell || return 1
    # 124 is timeout's "killed" status; the caller only cares that it finished.
    timeout "$limit" powershell.exe -NoProfile -WindowStyle Hidden -File "$win" "$@" \
        2>/dev/null
    local rc=$?
    [ "$rc" = "124" ] && return 124
    return $rc
}

# Name of the terminal application hosting this shell, or empty if unknown.
#
# Some terminals already announce agent completion themselves (Orca today,
# VS Code forks and others over time). Without a name the hook cannot tell
# which of them it is running under, so it could not stay quiet for just one.
#
# TERM_PROGRAM is the standard signal; the per-app variables cover emulators
# that predate it or run embedded in another app.
claude_wsl_terminal_app() {
    local app="${TERM_PROGRAM:-}"
    case "$app" in
        unknown|Unknown) app="" ;;
        vscode) app="VS Code" ;;
    esac
    if [ -z "$app" ]; then
        if [ -n "${ORCA_TERMINAL_HANDLE:-}" ] || [ -n "${ORCA_TAB_ID:-}" ]; then
            app="Orca"
        elif [ -n "${WT_SESSION:-}" ]; then
            app="Windows Terminal"
        elif [ -n "${WEZTERM_PANE:-}" ]; then
            app="WezTerm"
        elif [ -n "${ALACRITTY_WINDOW_ID:-}" ]; then
            app="Alacritty"
        elif [ -n "${KITTY_WINDOW_ID:-}" ]; then
            app="kitty"
        elif [ -n "${TABBY_CONFIG_DIRECTORY:-}" ]; then
            app="Tabby"
        elif [ -n "${CURSOR_TRACE_ID:-}" ]; then
            app="Cursor"
        elif [ -n "${VSCODE_INJECTION:-}" ] || [ -n "${VSCODE_PID:-}" ]; then
            app="VS Code"
        elif [ -n "${LC_TERMINAL:-}" ]; then
            app="$LC_TERMINAL"
        fi
    fi
    [ -n "$app" ] || return 1
    printf '%s' "$app"
}

# Path to the per-user mute list. Overridable so a test keeps its own.
claude_wsl_mute_file() {
    printf '%s' "${CLAUDE_WSL_HOME:-$HOME/.local/share/claude-wsl}/mute-apps"
}

# True (0) when the app named $1 is on the mute list.
#
# The list is one app name per line; blank lines and #-comments are ignored and
# the comparison is case-insensitive, so "Orca" and "orca" are the same entry.
# A mute means "this terminal notifies on its own": the hook stays out of the
# way entirely instead of showing a second notification for the same turn.
claude_wsl_app_muted() {
    local app="$1" file line
    [ -n "$app" ] || return 1
    file=$(claude_wsl_mute_file)
    [ -f "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        # Trim surrounding whitespace without a fork.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue
        [ "${line,,}" = "${app,,}" ] && return 0
    done < "$file"
    return 1
}

# Emit a hook JSON reply carrying a terminal escape sequence for Claude Code to
# write on this hook's behalf. Hook stdout is piped, so writing the sequence to
# our own stdout would go nowhere; Claude Code emits this one for us.
#
# Only OSC 0/1/2/9/99/777 and BEL pass Claude Code's allowlist, and an OSC 9
# body may not start with a digit unless it is the 9;4 progress form.
#
#   claude_wsl_emit_osc '9;4;3;0'     -> spinner
#   claude_wsl_emit_osc '0;my-title'  -> tab title
claude_wsl_emit_osc() {
    local body="$1"
    [ -n "$body" ] || return 0
    # \u001b = ESC, \u0007 = BEL. The body itself is plain ASCII by contract.
    printf '{"terminalSequence":"\\u001b]%s\\u0007"}\n' "$body"
}

# Same, but terminating with ST (ESC \) as the OSC spec prefers for OSC 0/2.
claude_wsl_emit_osc_st() {
    local body="$1"
    [ -n "$body" ] || return 0
    printf '{"terminalSequence":"\\u001b]%s\\u001b\\\\"}\n' "$body"
}
