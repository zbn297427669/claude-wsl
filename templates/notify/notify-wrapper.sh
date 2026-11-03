#!/bin/bash
# Wrapper around notify.sh.
#
# notify.sh's stdout is the hook's reply channel: a {"terminalSequence": ...}
# object tells Claude Code which escape sequence to write, because the hook
# itself cannot reach the terminal. So stdout must be forwarded -- but only
# when it really is that JSON reply. Anything else notify.sh prints (a stray
# echo, a warning) would be parsed as hook output and shown to the user, so
# those lines are dropped.
#
# CRITICAL: Always exit 0 - never fail the hook even if notify.sh fails.

set +e  # Don't exit on errors
set +u  # Don't exit on undefined variables

# Safe directory determination with fallback
if [ -n "${BASH_SOURCE[0]}" ] 2>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="/tmp"
else
    SCRIPT_DIR="/tmp"
fi

if [ -f "$SCRIPT_DIR/notify.sh" ] 2>/dev/null && [ -r "$SCRIPT_DIR/notify.sh" ] 2>/dev/null; then
    # Stdin passes straight through: notify.sh reads the hook's JSON payload.
    OUT=$("$SCRIPT_DIR/notify.sh" 2>/dev/null)
    # Forward only JSON objects that carry a terminalSequence. Everything else
    # is diagnostic noise that must not reach Claude Code's output parser.
    if [ -n "$OUT" ]; then
        printf '%s\n' "$OUT" | while IFS= read -r line; do
            case "$line" in
                *'"terminalSequence"'*) printf '%s\n' "$line" ;;
            esac
        done
    fi
fi

# ALWAYS exit successfully - hook must never fail
exit 0
