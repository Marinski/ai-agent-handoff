#!/usr/bin/env bash
claude_locate() {
    local sid="$1"
    if [[ "$sid" == "found" ]]; then
        echo "Full context session"
        return 0
    fi
    return 1
}

echo "Testing call with 'found'..."
# Use a subshell to capture the output
SESSION_LOCATION=$(claude_locate "found")
EXIT_CODE="$?"
echo "Result: $SESSION_LOCATION"
echo "Exit code: $EXIT_CODE"

echo ""
echo "Testing call with 'wrong'..."
SESSION_LOCATION=$(claude_locate "wrong")
EXIT_CODE="$?"
echo "Result: $SESSION_LOCATION"
echo "Exit code: $EXIT_CODE"
