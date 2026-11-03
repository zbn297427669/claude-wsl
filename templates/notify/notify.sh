#!/bin/bash
# Claude Code Notification Hook
# Called by Claude Code global settings when Claude responds
# Receives JSON via stdin with: {"cwd": "/path/to/project", "session_id": "...", ...}

# CRITICAL ERROR HANDLING: Never crash or fail the hook
set +e  # Don't exit on errors
set +u  # Don't exit on undefined variables

# Safe directory determination with fallback
if [ -n "${BASH_SOURCE[0]}" ] 2>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="/tmp"
else
    SCRIPT_DIR="/tmp"
fi

# Cross-platform helpers (cygpath on Git Bash, wslpath on WSL).
# shellcheck source=platform.sh
[ -r "$SCRIPT_DIR/platform.sh" ] && . "$SCRIPT_DIR/platform.sh" 2>/dev/null || true
# shellcheck source=indicator.sh
[ -r "$SCRIPT_DIR/indicator.sh" ] && . "$SCRIPT_DIR/indicator.sh" 2>/dev/null || true

# Debug log. Overridable so tests do not write into the shared /tmp used by
# other sessions; CLAUDE_WSL_DEBUG=0 turns it off for a quiet run.
LOG_FILE="${CLAUDE_WSL_LOG:-/tmp/claude-notify-debug.log}"

# Enable logging for debugging
DEBUG="${CLAUDE_WSL_DEBUG:-1}"

# basename without the fork: this runs on every hook and Git Bash pays ~25ms
# per external command. Handles POSIX, forward-slash Windows and backslash
# paths, which are the three shapes the hook's cwd arrives in.
_basename() {
    local p="${1%/}"
    p="${p##*/}"
    printf '%s' "${p##*\\}"
}

# epoch seconds without the fork
_now() {
    local t=0
    printf -v t '%(%s)T' -1 2>/dev/null || t=0
    printf '%s' "$t"
}

log() {
    # Wrap logging in error handling - never fail
    {
        if [ "$DEBUG" = "1" ] 2>/dev/null && [ -n "$LOG_FILE" ] 2>/dev/null; then
            # bash's own clock, not `date`: this runs ~18 times per hook and a
            # fork costs ~25ms on Git Bash, which is most of the hook's latency.
            local _ts="??:??:??"
            printf -v _ts '%(%H:%M:%S)T' -1 2>/dev/null || _ts="??:??:??"
            printf '[%s] %s\n' "$_ts" "$*" >> "$LOG_FILE" 2>/dev/null || true
        fi
    } 2>/dev/null || true
}

# Runtime toggle (notify-ctl.sh / /wsl-notify). Drain stdin so Claude Code does not hang.
_NOTIFY_HOME="${CLAUDE_WSL_HOME:-$HOME/.local/share/claude-wsl}"
if [ -f "$_NOTIFY_HOME/disabled" ] 2>/dev/null || [ -f "$SCRIPT_DIR/disabled" ] 2>/dev/null; then
    log "=== notify.sh skipped (disabled) ==="
    if [ ! -t 0 ]; then
        timeout 1 cat >/dev/null 2>&1 || true
    fi
    exit 0
fi

# Per-app mute list. Terminals that announce agent completion themselves
# (Orca today, IDE panes next) would otherwise get a second, competing toast
# for the same turn. Muted means: no toast, no bell marker, no OSC 9;4 --
# the terminal's own notification is the only one. The global `disabled` flag
# above still wins, and `/wsl-notify unmute <app>` brings this back.
TERMINAL_APP=""
if type claude_wsl_terminal_app >/dev/null 2>&1; then
    TERMINAL_APP=$(claude_wsl_terminal_app 2>/dev/null)
fi
if [ -n "$TERMINAL_APP" ] && type claude_wsl_app_muted >/dev/null 2>&1 \
        && claude_wsl_app_muted "$TERMINAL_APP" 2>/dev/null; then
    log "=== notify.sh skipped (app muted: $TERMINAL_APP) ==="
    if [ ! -t 0 ]; then
        timeout 1 cat >/dev/null 2>&1 || true
    fi
    exit 0
fi

log "=== notify.sh called ==="
log "PWD: $PWD"
log "CLAUDE_WORKING_DIRECTORY: ${CLAUDE_WORKING_DIRECTORY:-not set}"
log "Terminal app: ${TERMINAL_APP:-unknown}"
log "WT_SESSION from environment: ${WT_SESSION:-not set}"

# Read JSON from stdin (Claude Code sends hook data)
# Use timeout to prevent hanging if stdin is not available
if [ -t 0 ]; then
    log "WARNING: No stdin data (terminal input)"
    HOOK_DATA=""
else
    # Read stdin with a 1 second timeout so a hook invoked without a payload
    # cannot hang the turn. Builtin `read` rather than `timeout cat`: it is
    # ~55ms faster on Git Bash and returns non-zero on timeout, which we ignore.
    HOOK_DATA=""
    IFS= read -r -d '' -t 1 HOOK_DATA 2>/dev/null || true
    if [ -n "$HOOK_DATA" ]; then
        log "Received stdin: $HOOK_DATA"
    else
        log "No stdin data received (timeout or empty)"
    fi
fi

# Parse JSON without jq (pure bash)
# Extract cwd field: "cwd": "/path/to/dir"
if [ -n "$HOOK_DATA" ]; then
    # Simple regex to extract cwd value
    if [[ "$HOOK_DATA" =~ \"cwd\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        ACTUAL_CWD="${BASH_REMATCH[1]}"
        log "Extracted cwd from JSON: $ACTUAL_CWD"
    else
        log "Could not extract cwd from JSON"
        ACTUAL_CWD=""
    fi

    # Extract session_id if present
    if [[ "$HOOK_DATA" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        HOOK_SESSION_ID="${BASH_REMATCH[1]}"
        log "Extracted session_id: $HOOK_SESSION_ID"
    fi

    # Extract wt_session if present (Windows Terminal session GUID)
    if [[ "$HOOK_DATA" =~ \"wt_session\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        HOOK_WT_SESSION="${BASH_REMATCH[1]}"
        log "Extracted wt_session: $HOOK_WT_SESSION"
    fi

    # Extract hook_event_name to determine what triggered this
    if [[ "$HOOK_DATA" =~ \"hook_event_name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        HOOK_EVENT="${BASH_REMATCH[1]}"
        log "Extracted hook_event_name: $HOOK_EVENT"
    fi

    # Extract notification_type (idle_prompt vs permission_prompt)
    if [[ "$HOOK_DATA" =~ \"notification_type\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        NOTIFICATION_TYPE="${BASH_REMATCH[1]}"
        log "Extracted notification_type: $NOTIFICATION_TYPE"
    fi

    # Extract message field (for permission requests, etc.)
    if [[ "$HOOK_DATA" =~ \"message\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        HOOK_MESSAGE="${BASH_REMATCH[1]}"
        log "Extracted message: $HOOK_MESSAGE"
    fi

    # Extract transcript_path for reading response content
    if [[ "$HOOK_DATA" =~ \"transcript_path\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        TRANSCRIPT_PATH="${BASH_REMATCH[1]}"
        log "Extracted transcript_path: $TRANSCRIPT_PATH"
    fi

    # Extract reason field (for SessionEnd events)
    if [[ "$HOOK_DATA" =~ \"reason\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        SESSION_END_REASON="${BASH_REMATCH[1]}"
        log "Extracted reason: $SESSION_END_REASON"
    fi
fi

# Determine the correct working directory
if [ -n "$ACTUAL_CWD" ] && [ -d "$ACTUAL_CWD" ]; then
    WORKING_DIR="$ACTUAL_CWD"
    log "Using cwd from JSON: $WORKING_DIR"
elif [ -n "$CLAUDE_WORKING_DIRECTORY" ] && [ -d "$CLAUDE_WORKING_DIRECTORY" ]; then
    WORKING_DIR="$CLAUDE_WORKING_DIRECTORY"
    log "Using CLAUDE_WORKING_DIRECTORY: $WORKING_DIR"
else
    WORKING_DIR="$PWD"
    log "Fallback to PWD: $WORKING_DIR"
fi

# Get just the folder name
FOLDER_NAME=$(_basename "$WORKING_DIR")
log "Folder name: $FOLDER_NAME"

# Set session ID
if [ -n "$HOOK_SESSION_ID" ]; then
    export CLAUDE_SESSION_ID="$HOOK_SESSION_ID"
elif [ -z "$CLAUDE_SESSION_ID" ]; then
    export CLAUDE_SESSION_ID="$(_now)-$$"
fi
log "Session ID: $CLAUDE_SESSION_ID"

# Claude fires Notification/idle_prompt ~60s after Stop ("waiting for your input").
# That is a second toast for the same turn — skip it. Real permission prompts still notify.
if [ "$HOOK_EVENT" = "Notification" ] 2>/dev/null; then
    case "${NOTIFICATION_TYPE:-}" in
        idle_prompt|idle)
            log "Skipping idle_prompt (already notified on Stop)"
            exit 0
            ;;
    esac
    if [[ "${HOOK_MESSAGE:-}" == *"waiting for your input"* ]]; then
        log "Skipping idle wait message (already notified on Stop)"
        exit 0
    fi
fi

# Record the foreground window NOW (user is still on this terminal).
# Must be synchronous: a detached helper often captures the wrong window.
# Costs ~550ms, so only the two events that precede a toast pay for it, and
# only when the stored HWND is missing or older than 2 hours.
if [ "$HOOK_EVENT" = "SessionStart" ] || [ "$HOOK_EVENT" = "UserPromptSubmit" ]; then
    if type claude_wsl_ps >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/capture-hwnd.ps1" ]; then
        HWND_STAMP_FILE="$_NOTIFY_HOME/hwnd-stamp-${CLAUDE_SESSION_ID}"
        HWND_STAMP=""
        if [ -n "$CLAUDE_SESSION_ID" ] && [ -f "$HWND_STAMP_FILE" ]; then
            HWND_STAMP=$(cat "$HWND_STAMP_FILE" 2>/dev/null)
        fi
        HWND_AGE=999999
        [ -n "$HWND_STAMP" ] && HWND_AGE=$(( $(_now) - HWND_STAMP ))
        if [ "$HWND_AGE" -gt 7200 ] 2>/dev/null || [ "$HWND_AGE" -lt 0 ] 2>/dev/null; then
            # claude_wsl_ps_timeout, not `timeout claude_wsl_ps`: timeout can
            # only exec a file, so wrapping the function made this silently
            # never run.
            if type claude_wsl_ps_timeout >/dev/null 2>&1 \
                    && claude_wsl_ps_timeout 3 "$SCRIPT_DIR/capture-hwnd.ps1" \
                        -SessionId "$CLAUDE_SESSION_ID" >/dev/null 2>&1; then
                mkdir -p "$_NOTIFY_HOME" 2>/dev/null
                _now > "$HWND_STAMP_FILE" 2>/dev/null || true
                log "Captured HWND for session $CLAUDE_SESSION_ID"
            fi
        else
            log "HWND capture skipped (${HWND_AGE}s old)"
        fi
    fi
fi

# Activate bell icon - create signal file for shell to detect (with error handling)
# Use different files for permission requests vs completions so shell knows which state to return to
# The scratch dir is overridable so a test run keeps its markers to itself.
CLAUDE_WSL_TMP="${CLAUDE_WSL_TMP:-/tmp}"
if [ "$HOOK_EVENT" = "Notification" ] 2>/dev/null; then
    BELL_SIGNAL_FILE="$CLAUDE_WSL_TMP/claude-bell-permission-${HOOK_SESSION_ID:-default}"
else
    BELL_SIGNAL_FILE="$CLAUDE_WSL_TMP/claude-bell-${HOOK_SESSION_ID:-default}"
fi
touch "$BELL_SIGNAL_FILE" 2>/dev/null || log "WARNING: Failed to create bell signal file"
log "Created bell signal file: $BELL_SIGNAL_FILE (Event: ${HOOK_EVENT:-unknown})"

# Find the correct PTY for this specific session
# Trace up the process tree to find the shell that spawned Claude Code

TARGET_PTY=""
TARGET_WT_SESSION=""

# The PTY path only exists on WSL, where /proc exposes every process' fds and
# the shell owns a /dev/pts node. Under Git Bash /proc knows only MSYS
# processes, never the native Claude Code process or its terminal, so the whole
# trace is a guaranteed miss that costs ~1.5s. Skip it there.
if type claude_wsl_is_msys >/dev/null 2>&1 && claude_wsl_is_msys; then
    log "MSYS host: no PTY to find, using terminalSequence instead"
else

# Method 1: Trace parent process tree
# This hook is spawned by Claude Code, which is spawned by bash/zsh
# We can trace up to find the correct shell
log "Tracing parent process tree from PID $$"

current_pid=$$
for i in {1..10}; do
    if [ -z "$current_pid" ] || [ "$current_pid" = "1" ]; then
        break
    fi

    # Get parent PID
    parent_pid=$(grep "^PPid:" "/proc/$current_pid/status" 2>/dev/null | awk '{print $2}')

    if [ -z "$parent_pid" ]; then
        break
    fi

    # Get process name
    proc_name=$(cat "/proc/$parent_pid/comm" 2>/dev/null)
    proc_cwd=$(readlink "/proc/$parent_pid/cwd" 2>/dev/null)

    log "  Level $i: PID $parent_pid, Name: $proc_name, CWD: $proc_cwd"

    # Check if this is a bash/zsh process
    if [[ "$proc_name" =~ ^(bash|zsh)$ ]]; then
        # Check if CWD matches exactly OR if WORKING_DIR is a subdirectory of proc_cwd
        # This handles cases where Claude was started in a parent directory
        if [ "$proc_cwd" = "$WORKING_DIR" ] || [[ "$WORKING_DIR" == "$proc_cwd"/* ]]; then
            # Check if this bash/zsh has a child process named "claude"
            # (CLAUDECODE env var is not exported to parent, so we check for child instead)
            has_claude_child=0
            for cpid in $(pgrep -P $parent_pid 2>/dev/null); do
                child_name=$(cat "/proc/$cpid/comm" 2>/dev/null)
                if [ "$child_name" = "claude" ]; then
                    has_claude_child=1
                    break
                fi
            done

            if [ "$has_claude_child" = "1" ]; then
                # Found it! Get the TTY and WT_SESSION
                TARGET_PTY=$(readlink "/proc/$parent_pid/fd/0" 2>/dev/null)
                TARGET_WT_SESSION=$(grep -z "^WT_SESSION=" "/proc/$parent_pid/environ" 2>/dev/null | cut -d= -f2 | tr -d '\0')

                if [[ "$TARGET_PTY" =~ ^/dev/pts/ ]]; then
                    log "Found target shell via process tree: PID $parent_pid, PTY: $TARGET_PTY, WT_SESSION: $TARGET_WT_SESSION"
                    log "  Shell CWD: $proc_cwd, Target CWD: $WORKING_DIR, Has claude child: yes"
                    break
                fi
            fi
        fi
    fi

    current_pid=$parent_pid
done

# Method 2: Fallback - search for Claude Code processes in this directory
if [ -z "$TARGET_PTY" ]; then
    log "Process tree trace failed, falling back to process search"

    for pid in $(pgrep -u "$USER" "bash|zsh" 2>/dev/null); do
        PROC_CWD=$(readlink "/proc/$pid/cwd" 2>/dev/null)

        # Check if CWD matches exactly OR if WORKING_DIR is a subdirectory
        if [ "$PROC_CWD" = "$WORKING_DIR" ] || [[ "$WORKING_DIR" == "$PROC_CWD"/* ]]; then
            # Check if this bash/zsh has a child process named "claude"
            has_claude_child=0
            for cpid in $(pgrep -P $pid 2>/dev/null); do
                child_name=$(cat "/proc/$cpid/comm" 2>/dev/null)
                if [ "$child_name" = "claude" ]; then
                    has_claude_child=1
                    break
                fi
            done

            if [ "$has_claude_child" = "1" ]; then
                PROC_TTY=$(readlink "/proc/$pid/fd/0" 2>/dev/null)
                if [[ "$PROC_TTY" =~ ^/dev/pts/ ]]; then
                    TARGET_PTY="$PROC_TTY"
                    TARGET_WT_SESSION=$(grep -z "^WT_SESSION=" "/proc/$pid/environ" 2>/dev/null | cut -d= -f2 | tr -d '\0')
                    log "Found target PTY via fallback search: $TARGET_PTY (PID: $pid)"
                    log "  Shell CWD: $PROC_CWD, Target CWD: $WORKING_DIR, Has claude child: yes"
                    break
                fi
            fi
        fi
    done
fi

fi  # end of the non-MSYS / WSL-only PTY search

# Signal the tab indicator. Two paths, tried in order:
#   - WSL: write the escape sequence straight to the shell's PTY.
#   - Everywhere else (native Windows included): hand Claude Code a
#     terminalSequence to emit for us. Hook stdout is piped and hooks spawn
#     hidden, so we cannot reach the terminal ourselves.
# CRITICAL: Never fail. A missing indicator is cosmetic; a failing hook is not.
INDICATOR_SEQ=""
if type claude_wsl_indicator_state >/dev/null 2>&1; then
    INDICATOR_SEQ=$(claude_wsl_indicator_state "$HOOK_EVENT" "${SESSION_END_REASON:-}")
fi

# Terminals that drop OSC 9;4 in favour of a private protocol get nothing from
# us: the sequence would be invisible, and speaking their private protocol is
# both out of scope and a duplicate of their own notification.
INDICATOR_SUPPORTED=1
if type claude_wsl_indicator_unsupported >/dev/null 2>&1; then
    claude_wsl_indicator_unsupported && INDICATOR_SUPPORTED=0
fi

INDICATOR_SENT=0
if [ -n "$TARGET_PTY" ] 2>/dev/null && [ -w "$TARGET_PTY" ] 2>/dev/null; then
    # WSL: the PTY write is immediate and needs no cooperation from Claude Code.
    if [ "$INDICATOR_SUPPORTED" = "1" ] && type claude_wsl_indicator_pty >/dev/null 2>&1; then
        claude_wsl_indicator_pty "$TARGET_PTY" "$INDICATOR_SEQ" && INDICATOR_SENT=1
    fi
    # The bell is what makes a background tab visible at all.
    case "${HOOK_EVENT:-}" in
        Stop|Notification|SessionEnd) printf '\007' > "$TARGET_PTY" 2>/dev/null || true ;;
    esac
    log "PTY indicator: event=${HOOK_EVENT:-unknown} seq=$INDICATOR_SEQ sent=$INDICATOR_SENT"
elif [ "$INDICATOR_SUPPORTED" = "1" ] && type claude_wsl_emit_indicator_and_title >/dev/null 2>&1; then
    # No PTY: native Windows, or the process trace failed. Claude Code writes
    # the sequence for us. Indicator and title go out as one JSON line.
    case "${HOOK_EVENT:-}" in
        Stop|Notification|UserPromptSubmit|SessionStart|SessionEnd)
            claude_wsl_emit_indicator_and_title "${INDICATOR_SEQ:-9;4;4;100}" "$FOLDER_NAME"
            INDICATOR_SENT=1
            ;;
    esac
    log "OSC indicator emitted: event=${HOOK_EVENT:-unknown} seq=$INDICATOR_SEQ"
else
    log "No indicator path (pty=${TARGET_PTY:-none} supported=$INDICATOR_SUPPORTED)"
fi

# Send Windows toast notification on Stop event (when Claude finishes) OR Notification event (when Claude asks for permission)
SKIP_TOAST=0
if [ "$HOOK_EVENT" = "Stop" ] || [ "$HOOK_EVENT" = "Notification" ]; then
    TOAST_STAMP="${CLAUDE_WSL_TMP:-/tmp}/claude-wsl-last-toast-${CLAUDE_SESSION_ID}"
    NOW_TS=$(_now)
    if [ -f "$TOAST_STAMP" ] 2>/dev/null; then
        LAST_TS=$(cat "$TOAST_STAMP" 2>/dev/null || echo 0)
        if [ "$NOW_TS" -gt 0 ] 2>/dev/null && [ "$LAST_TS" -gt 0 ] 2>/dev/null; then
            DELTA=$((NOW_TS - LAST_TS))
            if [ "$DELTA" -ge 0 ] && [ "$DELTA" -lt 8 ]; then
                log "Skipping duplicate toast (${DELTA}s since last)"
                SKIP_TOAST=1
            fi
        fi
    fi
fi
if [ "$SKIP_TOAST" != "1" ] && { [ "$HOOK_EVENT" = "Stop" ] || [ "$HOOK_EVENT" = "Notification" ]; }; then
    NOTIFICATION_SCRIPT="$SCRIPT_DIR/send-notification.ps1"
    if [ -f "$NOTIFICATION_SCRIPT" ]; then
        # Set message based on event type
        if [ "$HOOK_EVENT" = "Notification" ]; then
            # Use the actual permission message from hook data
            if [ -n "$HOOK_MESSAGE" ]; then
                NOTIFICATION_MESSAGE="$HOOK_MESSAGE"
            else
                NOTIFICATION_MESSAGE="Requires permission"
            fi
        else
            # For Stop event, extract preview from transcript
            NOTIFICATION_MESSAGE="Response ready"
            if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
                # Get last assistant message from transcript
                # The JSON structure is: {"message":{"content":[{"text":"..."}]}}
                # Use sed to extract everything between "text":" and the closing quote before the next field
                FULL_TEXT=$(tail -1 "$TRANSCRIPT_PATH" | sed -n 's/.*"text":"\([^"]*\).*/\1/p' | sed 's/\\n/ /g' | sed 's/\\t/ /g' | sed 's/\\"//g' | sed 's/\\//g')

                # If the simple extraction failed, try a more robust approach
                if [ -z "$FULL_TEXT" ]; then
                    # Extract using grep with Perl regex to handle escaped quotes
                    FULL_TEXT=$(tail -1 "$TRANSCRIPT_PATH" | grep -oP '"text":"\K[^"\\]*(?:\\.[^"\\]*)*' | head -1 | sed 's/\\n/ /g' | sed 's/\\t/ /g' | sed 's/\\"//g')
                fi

                if [ -n "$FULL_TEXT" ]; then
                    # Extract up to first punctuation (. ! ? ) but NOT comma since it's common in sentences
                    if [[ "$FULL_TEXT" =~ ^([^.!?]*[.!?]) ]]; then
                        FIRST_SENTENCE="${BASH_REMATCH[1]}"
                    else
                        # No punctuation found, use full text
                        FIRST_SENTENCE="$FULL_TEXT"
                    fi

                    # Trim to 250 chars if too long, abbreviate
                    if [ ${#FIRST_SENTENCE} -gt 250 ]; then
                        PREVIEW="${FIRST_SENTENCE:0:247}..."
                    else
                        PREVIEW="$FIRST_SENTENCE"
                    fi

                    NOTIFICATION_MESSAGE="$PREVIEW"
                    log "Using response preview: $PREVIEW"
                fi
            fi
        fi

        log "Calling send-notification.ps1 for $HOOK_EVENT event..."
        {
            # Path conversion comes from platform.sh: wslpath under WSL, cygpath
            # under Git Bash. Both are absent on a bare Windows shell, in which
            # case the toast is skipped rather than attempted with a bad path.
            if type claude_wsl_ps >/dev/null 2>&1; then
                NOTIFY_SOUND=""
                if [ -f "$_NOTIFY_HOME/sound" ]; then
                    NOTIFY_SOUND=$(head -n 1 "$_NOTIFY_HOME/sound" 2>/dev/null | tr -d '\r')
                elif [ -f "$SCRIPT_DIR/sound" ]; then
                    NOTIFY_SOUND=$(head -n 1 "$SCRIPT_DIR/sound" 2>/dev/null | tr -d '\r')
                fi
                NOTIFY_SOUND="${NOTIFY_SOUND:-Default}"
                # Background it: PowerShell startup is ~440ms and the hook should
                # not hold the turn open for it.
                claude_wsl_ps "$NOTIFICATION_SCRIPT" \
                    -Title "$FOLDER_NAME" \
                    -Message "$NOTIFICATION_MESSAGE" \
                    -SessionId "${HOOK_SESSION_ID:-$CLAUDE_SESSION_ID}" \
                    -TabTitle "$FOLDER_NAME" \
                    -WtSession "${TARGET_WT_SESSION:-}" \
                    -Sound "$NOTIFY_SOUND" \
                    >/dev/null 2>&1 &
                log "Notification script called (PID: $!)"
                log "Passed session to toast: ${HOOK_SESSION_ID:-$CLAUDE_SESSION_ID}"
                _now > "$TOAST_STAMP" 2>/dev/null || true
            else
                log "ERROR: no PowerShell host or path converter available"
            fi
        } 2>/dev/null || log "ERROR: Failed to call notification script"
    else
        log "ERROR: Notification script not found: $NOTIFICATION_SCRIPT"
    fi
elif [ "$SKIP_TOAST" != "1" ]; then
    log "Skipping notification (Event: ${HOOK_EVENT:-unknown}, not Stop or Notification)"
fi

log "=== notify.sh completed ==="

# Always exit successfully to avoid "Stop hook error" in Claude Code
exit 0
