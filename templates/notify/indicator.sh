#!/bin/bash
# Tab/indicator signalling that works on WSL and native Windows alike.
#
# Two paths, tried in order:
#
#   PTY   (WSL)          Write the escape sequence straight to the shell's
#                        /dev/pts/N. Works because the hook can reach it.
#
#   OSC   (everywhere)   Ask Claude Code to emit the sequence for us by
#                        returning {"terminalSequence": ...} on stdout. Hook
#                        stdout is piped and hooks spawn with windowsHide, so
#                        writing to our own stdout would go nowhere -- Claude
#                        Code is the only writer that reaches the terminal.
#
# Callers source this file. Every function is side-effect free except for the
# files it is told to write, and never returns non-zero on a best-effort miss.

# Full OSC bodies, ready to put after "ESC ]" and before BEL.
# OSC 9;4 is the progress form: 9 = ConEmu/Windows Terminal progress,
# 4 = "set progress", then <state>;<percent>.
# States: 0 = clear, 1 = normal, 2 = error, 3 = indeterminate (spinner),
# 4 = warning/orange.
claude_wsl_indicator_state() {
    # $1 = hook event name, $2 = session-end reason
    case "${1:-}" in
        UserPromptSubmit) printf '9;4;3;0' ;;   # spinner while Claude works
        Stop)             printf '9;4;4;100' ;; # orange circle: response ready
        SessionStart)     printf '9;4;4;100' ;;
        SessionEnd)
            if [ "${2:-}" = "other" ]; then
                printf '9;4;2;100'    # error / timeout
            else
                printf '9;4;0;0'      # user exited: hide
            fi
            ;;
        *)                printf '9;4;4;100' ;;
    esac
}

# True when the terminal is known to ignore OSC 9;4 in favour of its own
# protocol. Emitting the ignored sequence would be noise, so callers skip it.
#
# Today this only covers ELYTerminal, which documents the redirect in its own
# binary: "status: OSC 9;4 passed by, a program reports through OSC 7501".
# Detecting a private protocol reliably is not possible, so this is a denylist
# by environment, not a probe.
claude_wsl_indicator_unsupported() {
    [ -n "${ELYTERMINAL_SESSION:-}" ] && return 0
    [ -n "${ELY_TERMINAL:-}" ] && return 0
    # A terminal that announces itself in TERM_PROGRAM is trusted unless it is
    # one we know drops progress reports.
    [ "${TERM_PROGRAM:-}" = "elyterminal" ] && return 0
    return 1
}

# Write an OSC body to a PTY (WSL path). Returns non-zero if it did not happen.
claude_wsl_indicator_pty() {
    local pty="$1" body="$2"
    [ -n "$pty" ] && [ -w "$pty" ] 2>/dev/null || return 1
    printf '\033]%s\007' "$body" > "$pty" 2>/dev/null || return 1
    return 0
}

# Emit the terminalSequence JSON that Claude Code will write on our behalf.
#
# The escape bytes must stay as the literal text \u001b / \u0007: this is a JSON
# string, and shell printf would otherwise turn them into a real ESC/BEL inside
# the JSON, which is invalid. So no printf builtin here -- cat the composed
# string instead.
claude_wsl_indicator_emit() {
    local body="$1"
    [ -n "$body" ] || return 1
    printf '%s' '{"terminalSequence":"\u001b]'"$body"'\u0007"}'
    printf '\n'
}

# Set the tab title. Same two paths.
#
#   claude_wsl_set_title <title> <pty-or-empty>
claude_wsl_set_title() {
    local title="$1" pty="${2:-}" body
    # Control characters in a title would terminate the OSC early.
    body="0;$(printf '%s' "$title" | tr -d '\000-\037\177')"
    if [ -n "$pty" ]; then
        printf '\033]%s\033\\' "$body" > "$pty" 2>/dev/null && return 0
    fi
    claude_wsl_indicator_emit "$body"
}

# Both sequences in one reply, so the hook prints a single JSON line.
#
#   claude_wsl_emit_indicator_and_title <indicator-body> <title>
claude_wsl_emit_indicator_and_title() {
    local indicator="$1" title="$2" title_part=""
    title=$(printf '%s' "$title" | tr -d '\\\000-\037\177')
    [ -n "$title" ] && title_part='\u001b]0;'"$title"'\u0007'
    printf '%s' '{"terminalSequence":"\u001b]'"$indicator"'\u0007'"$title_part"'"}'
    printf '\n'
}
