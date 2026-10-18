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

LOG_FILE="/tmp/claude-notify-debug.log"

# Enable logging for debugging
DEBUG=1

log() {
    # Wrap logging in error handling - never fail
    {
        if [ "$DEBUG" = "1" ] 2>/dev/null && [ -n "$LOG_FILE" ] 2>/dev/null; then
            echo "[$(date '+%H:%M:%S' 2>/dev/null || echo "??:??:??")] $*" >> "$LOG_FILE" 2>/dev/null || true
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

log "=== notify.sh called ==="
log "PWD: $PWD"
log "CLAUDE_WORKING_DIRECTORY: ${CLAUDE_WORKING_DIRECTORY:-not set}"
log "WT_SESSION from environment: ${WT_SESSION:-not set}"

# Read JSON from stdin (Claude Code sends hook data)
# Use timeout to prevent hanging if stdin is not available
if [ -t 0 ]; then
    log "WARNING: No stdin data (terminal input)"
    HOOK_DATA=""
else
    # Read stdin with 1 second timeout to prevent hanging
    HOOK_DATA=$(timeout 1 cat 2>/dev/null || true)
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
FOLDER_NAME=$(basename "$WORKING_DIR")
log "Folder name: $FOLDER_NAME"

# Set session ID
if [ -n "$HOOK_SESSION_ID" ]; then
    export CLAUDE_SESSION_ID="$HOOK_SESSION_ID"
elif [ -z "$CLAUDE_SESSION_ID" ]; then
    export CLAUDE_SESSION_ID="$(date +%s)-$$"
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
if [ "$HOOK_EVENT" = "SessionStart" ] || [ "$HOOK_EVENT" = "UserPromptSubmit" ]; then
    if command -v powershell.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
        CAPTURE_SCRIPT=$(wslpath -w "$SCRIPT_DIR/capture-hwnd.ps1" 2>/dev/null) || CAPTURE_SCRIPT=""
        if [ -n "$CAPTURE_SCRIPT" ] && [ -n "$CLAUDE_SESSION_ID" ]; then
            timeout 2 powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden \
                -File "$CAPTURE_SCRIPT" -SessionId "$CLAUDE_SESSION_ID" >/dev/null 2>&1 || true
            log "Captured HWND for session $CLAUDE_SESSION_ID"
        fi
    fi
fi

# Activate bell icon - create signal file for shell to detect (with error handling)
# Use different files for permission requests vs completions so shell knows which state to return to
if [ "$HOOK_EVENT" = "Notification" ] 2>/dev/null; then
    BELL_SIGNAL_FILE="/tmp/claude-bell-permission-${HOOK_SESSION_ID:-default}"
else
    BELL_SIGNAL_FILE="/tmp/claude-bell-${HOOK_SESSION_ID:-default}"
fi
touch "$BELL_SIGNAL_FILE" 2>/dev/null || log "WARNING: Failed to create bell signal file"
log "Created bell signal file: $BELL_SIGNAL_FILE (Event: ${HOOK_EVENT:-unknown})"

# Find the correct PTY for this specific session
# Trace up the process tree to find the shell that spawned Claude Code

TARGET_PTY=""
TARGET_WT_SESSION=""

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

# Send OSC 9;4 sequence for progress/alert indicators (with comprehensive error handling)
# OSC 9;4 states: 0=hidden, 1=default/green, 2=error/red, 3=indeterminate/spinner, 4=warning/orange
# CRITICAL: Never fail even if PTY write fails - permissions or device issues should not crash
if [ -n "$TARGET_PTY" ] 2>/dev/null && [ -w "$TARGET_PTY" ] 2>/dev/null; then
    if [ "$HOOK_EVENT" = "Stop" ] 2>/dev/null; then
        # Stop spinner and show orange circle on completion (response ready or interrupted via Escape)
        { printf '\033]9;4;4;100\007' > "$TARGET_PTY"; } 2>/dev/null || log "WARNING: Failed to write orange circle to PTY"
        # Send BEL to trigger Windows Terminal's native bell indicator (outlined bell)
        { printf '\007' > "$TARGET_PTY"; } 2>/dev/null || log "WARNING: Failed to write BEL to PTY"
        # Update tab title to current folder name
        { printf '\033]0;%s\033\\' "$FOLDER_NAME" > "$TARGET_PTY"; } 2>/dev/null || log "WARNING: Failed to update tab title"
        log "Set ORANGE CIRCLE and sent BEL on $HOOK_EVENT: $FOLDER_NAME"
    elif [ "$HOOK_EVENT" = "SessionEnd" ] 2>/dev/null; then
        # SessionEnd reason: "clear", "logout", "prompt_input_exit", or "other"
        if [ "$SESSION_END_REASON" = "other" ]; then
            # Error or timeout - show RED error indicator
            { printf '\033]9;4;2;100\007' > "$TARGET_PTY"; } 2>/dev/null || log "WARNING: PTY write failed" 2>/dev/null
            log "Set RED ERROR indicator on SessionEnd (reason: ${SESSION_END_REASON:-unknown} - error/timeout): $FOLDER_NAME"
        else
            # User exited Claude Code (Ctrl+C, /clear, logout) - hide indicator, show Linux penguin
            { printf '\033]9;4;0;0\007' > "$TARGET_PTY"; } 2>/dev/null || log "WARNING: PTY write failed" 2>/dev/null
            log "HIDDEN indicator on SessionEnd (reason: ${SESSION_END_REASON:-unknown} - user exited, back to penguin): $FOLDER_NAME"
        fi
        # Send BEL to trigger Windows Terminal's native bell indicator (outlined bell)
        printf '\007' > "$TARGET_PTY" 2>/dev/null
        # Update tab title to current folder name
        { printf '\033]0;%s\033\\' "$FOLDER_NAME" > "$TARGET_PTY"; } 2>/dev/null || log "WARNING: Failed to update tab title"
    elif [ "$HOOK_EVENT" = "Notification" ]; then
        # Permission request - keep current indicator (spinner) and add BEL
        # Don't change the spinner to circle - user will give permission and it should stay as spinner
        printf '\007' > "$TARGET_PTY" 2>/dev/null
        # Update tab title to current folder name
        { printf '\033]0;%s\033\\' "$FOLDER_NAME" > "$TARGET_PTY"; } 2>/dev/null || log "WARNING: Failed to update tab title"
        log "Sent BEL for permission request (keeping spinner): $TARGET_PTY"
    elif [ "$HOOK_EVENT" = "UserPromptSubmit" ]; then
        # REQUIREMENT 2 & 4: Show ORANGE SPINNER when Claude starts computing (state 3 = indeterminate = spinner)
        { printf '\033]9;4;3;0\007' > "$TARGET_PTY"; } 2>/dev/null || log "WARNING: PTY write failed" 2>/dev/null
        # Update tab title to current folder name
        { printf '\033]0;%s\033\\' "$FOLDER_NAME" > "$TARGET_PTY"; } 2>/dev/null || log "WARNING: Failed to update tab title"
        log "Set ORANGE SPINNER on UserPromptSubmit: $TARGET_PTY"
    elif [ "$HOOK_EVENT" = "SessionStart" ]; then
        # REQUIREMENT 1: Show ORANGE CIRCLE OUTLINE when Claude Code session starts (state 4 = warning = orange/yellow circle)
        { printf '\033]9;4;4;100\007' > "$TARGET_PTY"; } 2>/dev/null || log "WARNING: PTY write failed" 2>/dev/null
        # Update tab title to current folder name
        { printf '\033]0;%s\033\\' "$FOLDER_NAME" > "$TARGET_PTY"; } 2>/dev/null || log "WARNING: Failed to update tab title"
        log "Set ORANGE CIRCLE on SessionStart: $TARGET_PTY"
    else
        # For other events, show orange circle (state 4 = warning = orange/yellow)
        { printf '\033]9;4;4;100\007' > "$TARGET_PTY"; } 2>/dev/null || log "WARNING: PTY write failed" 2>/dev/null
        # Update tab title to current folder name
        { printf '\033]0;%s\033\\' "$FOLDER_NAME" > "$TARGET_PTY"; } 2>/dev/null || log "WARNING: Failed to update tab title"
        log "Set orange circle indicator to: $TARGET_PTY (Event: ${HOOK_EVENT:-unknown})"
    fi
else
    log "WARNING: Could not find target PTY for $WORKING_DIR"
fi

# Send Windows toast notification on Stop event (when Claude finishes) OR Notification event (when Claude asks for permission)
SKIP_TOAST=0
if [ "$HOOK_EVENT" = "Stop" ] || [ "$HOOK_EVENT" = "Notification" ]; then
    TOAST_STAMP="/tmp/claude-wsl-last-toast-${CLAUDE_SESSION_ID}"
    NOW_TS=$(date +%s 2>/dev/null || echo 0)
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
        # Pass the WT_SESSION we found from process tracing - with comprehensive error handling
        {
            # Verify wslpath exists before using it
            if command -v wslpath >/dev/null 2>&1 && command -v powershell.exe >/dev/null 2>&1; then
                WINDOWS_SCRIPT=$(wslpath -w "$NOTIFICATION_SCRIPT" 2>/dev/null) || WINDOWS_SCRIPT=""
                if [ -n "$WINDOWS_SCRIPT" ]; then
                    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden \
                        -File "$WINDOWS_SCRIPT" \
                        -Title "$FOLDER_NAME" \
                        -Message "$NOTIFICATION_MESSAGE" \
                        -SessionId "${HOOK_SESSION_ID:-$CLAUDE_SESSION_ID}" \
                        -TabTitle "$FOLDER_NAME" \
                        -WtSession "${TARGET_WT_SESSION:-}" \
                        2>/dev/null &
                    log "Notification script called (PID: $!)"
                    log "Passed session to toast: ${HOOK_SESSION_ID:-$CLAUDE_SESSION_ID}"
                    date +%s > "$TOAST_STAMP" 2>/dev/null || true
                else
                    log "ERROR: Could not convert path to Windows format"
                fi
            else
                log "ERROR: wslpath or powershell.exe not available"
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
