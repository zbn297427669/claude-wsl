#!/bin/bash
# Claude Code Notification Wrapper
# Source this file in your .bashrc or .zshrc to enable automatic notifications

# CRITICAL ERROR HANDLING: Never crash the shell
set +e  # Don't exit on errors
set +u  # Don't exit on undefined variables

# Safe directory determination with fallback
if [ -n "${BASH_SOURCE[0]}" ] 2>/dev/null; then
    NOTIFIER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || NOTIFIER_DIR=""
else
    NOTIFIER_DIR=""
fi

# Validate NOTIFIER_DIR before use
if [ -z "$NOTIFIER_DIR" ] || [ ! -d "$NOTIFIER_DIR" ] 2>/dev/null; then
    # Silent failure - don't pollute shell output
    return 0 2>/dev/null || exit 0
fi

MONITOR_SCRIPT="$NOTIFIER_DIR/monitor-claude.sh"

# Configuration with safe defaults
export CLAUDE_NOTIFY_ENABLED="${CLAUDE_NOTIFY_ENABLED:-1}"
export CLAUDE_NOTIFY_ON_OUTPUT="${CLAUDE_NOTIFY_ON_OUTPUT:-1}"
export CLAUDE_NOTIFY_TAB_ICON="${CLAUDE_NOTIFY_TAB_ICON:-1}"

# === Terminal Directory Tracking ===
# Emit OSC 9;9 on every prompt for new tab/duplicate tab directory inheritance.
# Needs a Windows path, which wslpath gives under WSL and cygpath under Git Bash.
if [ -n "$WT_SESSION" ] 2>/dev/null; then
    _wt_osc99() {
        local win="$PWD"
        if command -v wslpath >/dev/null 2>&1; then
            win=$(wslpath -w "$PWD" 2>/dev/null) || win="$PWD"
        elif command -v cygpath >/dev/null 2>&1; then
            win=$(cygpath -w "$PWD" 2>/dev/null) || win="$PWD"
        fi
        printf '\e]9;9;%s\e\\' "$win"
    }
    # Add to PROMPT_COMMAND if not already there
    if [[ ! "$PROMPT_COMMAND" =~ _wt_osc99 ]] 2>/dev/null; then
        PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }_wt_osc99"
    fi
fi

# Directory tracking file for new tabs - with error handling
LAST_DIR_FILE="${HOME}/.cache/claude-last-dir"
if [ -n "$HOME" ] 2>/dev/null; then
    mkdir -p "$(dirname "$LAST_DIR_FILE")" 2>/dev/null || true
fi

# Initialize session ID with error handling
# Priority: 1) Use Claude Code's session ID if available, 2) Generate our own
if [ -z "$CLAUDE_SESSION_ID" ] 2>/dev/null; then
    # Try to get Claude Code's session ID from the most recent project file
    if [ "$CLAUDECODE" = "1" ] 2>/dev/null; then
        LATEST_PROJECT=$(find ~/.claude/projects -name "*.jsonl" -type f -mmin -5 2>/dev/null | xargs ls -t 2>/dev/null | head -1) || LATEST_PROJECT=""
        if [ -n "$LATEST_PROJECT" ] 2>/dev/null; then
            # Extract session ID from the filename (format: session-id.jsonl)
            CLAUDE_CODE_SESSION_ID=$(basename "$LATEST_PROJECT" .jsonl 2>/dev/null) || CLAUDE_CODE_SESSION_ID=""
            if [ -n "$CLAUDE_CODE_SESSION_ID" ]; then
                export CLAUDE_SESSION_ID="$CLAUDE_CODE_SESSION_ID"
            else
                export CLAUDE_SESSION_ID="$(date +%s 2>/dev/null || echo "fallback")-$$"
            fi
        else
            export CLAUDE_SESSION_ID="$(date +%s 2>/dev/null || echo "fallback")-$$"
        fi
    else
        export CLAUDE_SESSION_ID="$(date +%s 2>/dev/null || echo "fallback")-$$"
    fi
fi

# Restore last directory for new tabs - with error handling
# Only restore if:
# 1. We're in a "default" location that needs directory restoration
# 2. Last dir file exists and contains a valid directory
# 3. We haven't already restored this session (check via marker file)
if [ ! -f "/tmp/claude-dir-restored-$$" ] 2>/dev/null; then
    if [ -f "$LAST_DIR_FILE" ] 2>/dev/null && [ -r "$LAST_DIR_FILE" ] 2>/dev/null; then
        LAST_DIR=$(cat "$LAST_DIR_FILE" 2>/dev/null) || LAST_DIR=""

        # Check if we need directory restoration with safe variable checks
        NEEDS_RESTORATION=0
        if [ -n "$HOME" ] && [ -n "$PWD" ] 2>/dev/null; then
            if [ "$PWD" = "$HOME" ] 2>/dev/null || [[ "$PWD" == /mnt/c/Users/* ]] 2>/dev/null; then
                # Launched from taskbar/start menu - restore to last known directory
                NEEDS_RESTORATION=1
            elif [[ "$PWD" == "$HOME/development" ]] 2>/dev/null && [[ "$LAST_DIR" == "$HOME/development"/* ]] 2>/dev/null && [ "$LAST_DIR" != "$PWD" ] 2>/dev/null; then
                # + tab opened in /development, but we were in a subdirectory - restore to subdirectory
                NEEDS_RESTORATION=1
            fi
        fi

        if [ "$NEEDS_RESTORATION" = "1" ] 2>/dev/null && [ -n "$LAST_DIR" ] && [ -d "$LAST_DIR" ] 2>/dev/null && [ "$LAST_DIR" != "$PWD" ] 2>/dev/null; then
            cd "$LAST_DIR" 2>/dev/null && touch "/tmp/claude-dir-restored-$$" 2>/dev/null || true
        fi
    fi
fi

# Set initial tab title with error handling
if [ -z "$TAB_TITLE" ] 2>/dev/null; then
    export TAB_TITLE="$(basename "$(pwd 2>/dev/null || echo "$HOME")" 2>/dev/null || echo "terminal")"
fi

# Track if bell icon is currently shown
export BELL_ICON_ACTIVE=0
# Track if bell was triggered by permission request (needs spinner after) vs completion (needs circle after)
export BELL_WAS_PERMISSION=0

# Function to hook into command execution - with error handling
claude_code_wrapper() {
    # Wrap entire function in error handling
    {
        local cmd="$1"
        shift

        # Check if this is a claude-code command
        if [[ "$cmd" == *"claude"* ]] 2>/dev/null || [[ "$cmd" == "claude-code" ]] 2>/dev/null; then
            # Set tab title
            export TAB_TITLE="Claude Code - $(basename "$(pwd 2>/dev/null || echo "$HOME")" 2>/dev/null || echo "terminal")"
            echo -ne "\033]0;$TAB_TITLE\007" 2>/dev/null || true

            # Start monitor in background if enabled
            if [ "$CLAUDE_NOTIFY_ENABLED" = "1" ] 2>/dev/null && [ -x "$MONITOR_SCRIPT" ] 2>/dev/null; then
                "$MONITOR_SCRIPT" --start-monitor 2>/dev/null || true
            fi
        fi

        # Execute the original command
        "$cmd" "$@"
        local exit_code=$?

        # Cleanup monitor if it was started
        if [[ "$cmd" == *"claude"* ]] 2>/dev/null && [ "$CLAUDE_NOTIFY_ENABLED" = "1" ] 2>/dev/null && [ -x "$MONITOR_SCRIPT" ] 2>/dev/null; then
            "$MONITOR_SCRIPT" --stop-monitor 2>/dev/null || true
        fi

        return $exit_code
    } 2>/dev/null || return 0
}

# Function to send manual notifications - with error handling
claude-notify() {
    {
        local title="${1:-Claude Code}"
        local message="${2:-Notification}"
        if [ -x "$MONITOR_SCRIPT" ] 2>/dev/null; then
            "$MONITOR_SCRIPT" --notify "$title" "$message" 2>/dev/null || true
        fi
    } 2>/dev/null || return 0
}

# Function to set tab title with optional notification bell - with error handling
claude-tab-title() {
    {
        local title="$1"
        local show_bell="${2:-0}"

        if [ "$show_bell" = "1" ] 2>/dev/null; then
            # Send BEL to trigger Windows Terminal bell indicator
            printf '\007' 2>/dev/null || true 2>/dev/null || true
        fi

        # Set title (no emoji - Windows Terminal shows its own bell indicator)
        printf "\033]0;%s\033\\" "$title" 2>/dev/null || true
        export TAB_TITLE="$title"
    } 2>/dev/null || return 0
}

# Hook for prompt to detect Claude Code activity
if [ -n "$BASH_VERSION" ]; then
    # Bash hook - wrapped in comprehensive error handling
    claude_prompt_hook() {
        # CRITICAL: Never let this function crash the shell
        {
            # Always update folder name to current directory
            local current_folder="$(basename "$PWD" 2>/dev/null || echo "terminal")"

            # Save current directory for new tabs (but NOT if we're in the notifier directory itself)
            if [ -n "$PWD" ] 2>/dev/null && [[ "$PWD" != "$NOTIFIER_DIR"* ]] 2>/dev/null; then
                echo "$PWD" > "$LAST_DIR_FILE" 2>/dev/null || true
            fi

        # Check for bell signal from notify.sh (notification triggered)
        # Check for permission request bell (needs spinner after clearing)
        if [ -f "/tmp/claude-bell-permission-$CLAUDE_SESSION_ID" ] 2>/dev/null; then
            BELL_ICON_ACTIVE=1
            BELL_WAS_PERMISSION=1
        # Check for regular completion bell (needs circle after clearing)
        elif [ -f "/tmp/claude-bell-$CLAUDE_SESSION_ID" ] 2>/dev/null; then
            BELL_ICON_ACTIVE=1
            BELL_WAS_PERMISSION=0
        fi

        # Check for focus signal from Windows (notification clicked or tab focused)
        if [ -f "/tmp/claude-focus-$CLAUDE_SESSION_ID" ] 2>/dev/null; then
            BELL_ICON_ACTIVE=0
            rm -f "/tmp/claude-focus-$CLAUDE_SESSION_ID" 2>/dev/null || true 2>/dev/null
            rm -f "/tmp/claude-bell-$CLAUDE_SESSION_ID" 2>/dev/null
            rm -f "/tmp/claude-bell-permission-$CLAUDE_SESSION_ID" 2>/dev/null
            # If Claude Code is still active, show appropriate indicator based on what triggered the bell
            if [ "$CLAUDECODE" = "1" ] 2>/dev/null; then
                if [ "$BELL_WAS_PERMISSION" = "1" ] 2>/dev/null; then
                    printf '\033]9;4;3;0\007' 2>/dev/null || true  # State 3 = spinner (permission given, Claude still computing)
                else
                    printf '\033]9;4;4;100\007' 2>/dev/null || true  # State 4 = orange circle (response done, session active)
                fi
            else
                printf '\033]9;4;0;0\007' 2>/dev/null || true  # Clear icon
            fi
            BELL_WAS_PERMISSION=0  # Reset flag
        elif [ "$BELL_ICON_ACTIVE" = "1" ] 2>/dev/null; then
            # Alert is active - trigger Windows Terminal's native bell indicator (NO red progress indicator)
            printf '\007' 2>/dev/null || true  # Send BEL to show outlined bell
            printf "\033]0;%s\033\\" "$current_folder"
            export TAB_TITLE="$current_folder"
            return  # Don't overwrite the bell indicator!
        elif [ "$CLAUDECODE" = "1" ] 2>/dev/null; then
            # Check if claude process is still actually running (not interrupted)
            if pgrep -x "claude" > /dev/null 2>&1; then
                # Claude Code is running - show orange circle (state 4 = warning = orange)
                printf '\033]9;4;4;100\007' 2>/dev/null || true
            else
                # Claude Code was interrupted - clear the icon
                printf '\033]9;4;0;0\007' 2>/dev/null || true
                # Unset CLAUDECODE since the process is no longer running
                unset CLAUDECODE 2>/dev/null || true
            fi
        fi

        # Update tab title (orange circle is shown via OSC 9;4, not title text)
        # Only update if changed to reduce escape sequence spam
        if [ "$TAB_TITLE" != "$current_folder" ] 2>/dev/null; then
            printf "\033]0;%s\033\\" "$current_folder"
            export TAB_TITLE="$current_folder"
        fi
        } 2>/dev/null || true
    }

    # Pre-command hook to detect user interaction (clears alert when user types)
    # This runs before each command is executed via DEBUG trap
    claude_preexec_hook_bash() {
        # Skip if we're in the prompt hook itself (avoid recursion)
        { [[ "$BASH_COMMAND" == *"claude_prompt_hook"* ]] && return 0; } 2>/dev/null || return 0
        { [[ "$BASH_COMMAND" == *"_force_title"* ]] && return 0; } 2>/dev/null || return 0

        # Check for pending bell signal files (alert hasn't been shown yet)
        # This prevents overriding the bell alert with other indicators
        if [ -f "/tmp/claude-bell-$CLAUDE_SESSION_ID" ] || \
           [ -f "/tmp/claude-bell-permission-$CLAUDE_SESSION_ID" ]; then
            # Bell file exists - don't emit anything, let PROMPT_COMMAND handle it
            return 0
        fi

        # When user executes any command, clear the alert (they're interacting with the tab)
        if [ "$BELL_ICON_ACTIVE" = "1" ] 2>/dev/null; then
            BELL_ICON_ACTIVE=0
            # Remove bell from title
            printf "\033]0;%s\033\\" "$(basename "$PWD" 2>/dev/null || echo "terminal")" 2>/dev/null || true
            rm -f "/tmp/claude-bell-$CLAUDE_SESSION_ID" 2>/dev/null
            rm -f "/tmp/claude-bell-permission-$CLAUDE_SESSION_ID" 2>/dev/null
            rm -f "/tmp/claude-focus-$CLAUDE_SESSION_ID" 2>/dev/null || true 2>/dev/null

            # If Claude Code is still active, show appropriate indicator based on what triggered the bell
            if [ "$CLAUDECODE" = "1" ] 2>/dev/null; then
                if [ "$BELL_WAS_PERMISSION" = "1" ] 2>/dev/null; then
                    printf '\033]9;4;3;0\007' 2>/dev/null || true  # State 3 = spinner (permission given, Claude still computing)
                else
                    printf '\033]9;4;4;100\007' 2>/dev/null || true  # State 4 = orange circle (response done, session active)
                fi
            else
                # Otherwise, clear the icon completely
                printf '\033]9;4;0;0\007' 2>/dev/null || true
            fi
            BELL_WAS_PERMISSION=0  # Reset flag
        elif [ "$CLAUDECODE" = "1" ] 2>/dev/null; then
            # REQUIREMENT 1: Claude Code session is active
            # The orange circle/spinner is managed by notify.sh hooks
            # We don't need to re-emit the indicator here, as the hooks handle it
            # Just ensure the process is still running
            if ! pgrep -x "claude" > /dev/null 2>&1; then
                # Claude Code was interrupted - clear the icon
                printf '\033]9;4;0;0\007' 2>/dev/null || true
                unset CLAUDECODE 2>/dev/null || true
            fi
        fi
        return 0
    }

    # Set DEBUG trap to call preexec hook before each command
    # Only set if not already set to avoid conflicts
    if [[ ! "$PROMPT_COMMAND" =~ claude_preexec_hook_bash ]]; then
        { trap 'claude_preexec_hook_bash' DEBUG; } 2>/dev/null || true
    fi

    # Add to PROMPT_COMMAND if not already there
    if [[ ! "$PROMPT_COMMAND" =~ claude_prompt_hook ]]; then
        PROMPT_COMMAND="claude_prompt_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}"  # Error handling: fails silently
    fi

    # Note: We don't need a separate _force_title function anymore
    # The claude_prompt_hook already handles title updates and runs last in PROMPT_COMMAND
elif [ -n "$ZSH_VERSION" ]; then
    # Zsh hook
    autoload -Uz add-zsh-hook 2>/dev/null || return 0
    claude_prompt_hook() {
        # Always update folder name to current directory
        local current_folder="$(basename "$PWD" 2>/dev/null || echo "terminal")"

        # Save current directory for new tabs (but NOT if we're in the notifier directory itself)
        if [[ "$PWD" != "$NOTIFIER_DIR"* ]]; then
            echo "$PWD" > "$LAST_DIR_FILE" 2>/dev/null
        fi

        # Check for bell signal from notify.sh (notification triggered)
        # Check for permission request bell (needs spinner after clearing)
        if [ -f "/tmp/claude-bell-permission-$CLAUDE_SESSION_ID" ] 2>/dev/null; then
            BELL_ICON_ACTIVE=1
            BELL_WAS_PERMISSION=1
        # Check for regular completion bell (needs circle after clearing)
        elif [ -f "/tmp/claude-bell-$CLAUDE_SESSION_ID" ] 2>/dev/null; then
            BELL_ICON_ACTIVE=1
            BELL_WAS_PERMISSION=0
        fi

        # Check for focus signal from Windows (notification clicked or tab focused)
        if [ -f "/tmp/claude-focus-$CLAUDE_SESSION_ID" ] 2>/dev/null; then
            BELL_ICON_ACTIVE=0
            rm -f "/tmp/claude-focus-$CLAUDE_SESSION_ID" 2>/dev/null || true 2>/dev/null
            rm -f "/tmp/claude-bell-$CLAUDE_SESSION_ID" 2>/dev/null
            rm -f "/tmp/claude-bell-permission-$CLAUDE_SESSION_ID" 2>/dev/null
            # If Claude Code is still active, show appropriate indicator based on what triggered the bell
            if [ "$CLAUDECODE" = "1" ] 2>/dev/null; then
                if [ "$BELL_WAS_PERMISSION" = "1" ] 2>/dev/null; then
                    printf '\033]9;4;3;0\007' 2>/dev/null || true  # State 3 = spinner (permission given, Claude still computing)
                else
                    printf '\033]9;4;4;100\007' 2>/dev/null || true  # State 4 = orange circle (response done, session active)
                fi
            else
                printf '\033]9;4;0;0\007' 2>/dev/null || true  # Clear icon
            fi
            BELL_WAS_PERMISSION=0  # Reset flag
        elif [ "$BELL_ICON_ACTIVE" = "1" ] 2>/dev/null; then
            # Alert is active - trigger Windows Terminal's native bell indicator (NO red progress indicator)
            printf '\007' 2>/dev/null || true  # Send BEL to show outlined bell
            printf "\033]0;%s\033\\" "$current_folder"
            export TAB_TITLE="$current_folder"
            return  # Don't overwrite the bell indicator!
        elif [ "$CLAUDECODE" = "1" ] 2>/dev/null; then
            # Check if claude process is still actually running (not interrupted)
            if pgrep -x "claude" > /dev/null 2>&1; then
                # Claude Code is running - show orange circle (state 4 = warning = orange)
                printf '\033]9;4;4;100\007' 2>/dev/null || true
            else
                # Claude Code was interrupted - clear the icon
                printf '\033]9;4;0;0\007' 2>/dev/null || true
                # Unset CLAUDECODE since the process is no longer running
                unset CLAUDECODE 2>/dev/null || true
            fi
        fi

        # Update tab title (orange circle is shown via OSC 9;4, not title text)
        # Only update if changed to reduce escape sequence spam
        if [ "$TAB_TITLE" != "$current_folder" ] 2>/dev/null; then
            printf "\033]0;%s\033\\" "$current_folder"
            export TAB_TITLE="$current_folder"
        fi
    }

    # Pre-command hook to detect user interaction (clears alert when user types)
    claude_preexec_hook() {
        # Check for pending bell signal files (alert hasn't been shown yet)
        # This prevents overriding the bell alert with other indicators
        if [ -f "/tmp/claude-bell-$CLAUDE_SESSION_ID" ] || \
           [ -f "/tmp/claude-bell-permission-$CLAUDE_SESSION_ID" ]; then
            # Bell file exists - don't emit anything, let precmd handle it
            return 0
        fi

        # When user executes any command, clear the alert (they're interacting with the tab)
        if [ "$BELL_ICON_ACTIVE" = "1" ] 2>/dev/null; then
            BELL_ICON_ACTIVE=0
            # Remove bell from title
            printf "\033]0;%s\033\\" "$(basename "$PWD" 2>/dev/null || echo "terminal")" 2>/dev/null || true
            rm -f "/tmp/claude-bell-$CLAUDE_SESSION_ID" 2>/dev/null
            rm -f "/tmp/claude-bell-permission-$CLAUDE_SESSION_ID" 2>/dev/null
            rm -f "/tmp/claude-focus-$CLAUDE_SESSION_ID" 2>/dev/null || true 2>/dev/null

            # If Claude Code is still active, show appropriate indicator based on what triggered the bell
            if [ "$CLAUDECODE" = "1" ] 2>/dev/null; then
                if [ "$BELL_WAS_PERMISSION" = "1" ] 2>/dev/null; then
                    printf '\033]9;4;3;0\007' 2>/dev/null || true  # State 3 = spinner (permission given, Claude still computing)
                else
                    printf '\033]9;4;4;100\007' 2>/dev/null || true  # State 4 = orange circle (response done, session active)
                fi
            else
                # Otherwise, clear the icon completely
                printf '\033]9;4;0;0\007' 2>/dev/null || true
            fi
            BELL_WAS_PERMISSION=0  # Reset flag
        elif [ "$CLAUDECODE" = "1" ] 2>/dev/null; then
            # REQUIREMENT 1: Claude Code session is active
            # The orange circle/spinner is managed by notify.sh hooks
            # We don't need to re-emit the indicator here, as the hooks handle it
            # Just ensure the process is still running
            if ! pgrep -x "claude" > /dev/null 2>&1; then
                # Claude Code was interrupted - clear the icon
                printf '\033]9;4;0;0\007' 2>/dev/null || true
                unset CLAUDECODE 2>/dev/null || true
            fi
        fi
    }

    add-zsh-hook precmd claude_prompt_hook 2>/dev/null || true
    add-zsh-hook preexec claude_preexec_hook 2>/dev/null || true

    # Note: We don't need a separate _force_title function anymore
    # The claude_prompt_hook already handles title updates
fi

# Export functions
export -f claude-notify 2>/dev/null || true
export -f claude-tab-title 2>/dev/null || true

# echo "Claude Code notifier loaded (Session: $CLAUDE_SESSION_ID)"
# echo "Mode: Event-driven (triggers on Claude activity)"
# echo "Commands:"
# echo "  claude-notify [title] [message]  - Send manual notification"
# echo "  claude-tab-title [title] [icon]  - Set tab title (icon: 0 or 1)"
