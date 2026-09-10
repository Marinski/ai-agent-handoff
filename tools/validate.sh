#!/usr/bin/env bash
# Input validation helpers for tool names and session IDs.
# Source this file — do not execute directly.

validate_tool_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-z][a-z0-9_-]*$ ]]; then
        printf 'validate_tool_name: invalid tool name "%s" (must match ^[a-z][a-z0-9_-]*$)\n' \
            "$name" >&2
        return 1
    fi
}

validate_session_id() {
    local id="$1"
    if [[ ! "$id" =~ ^[A-Za-z0-9._-]+$ ]]; then
        printf 'validate_session_id: invalid session id "%s" (must match ^[A-Za-z0-9._-]+$)\n' \
            "$id" >&2
        return 1
    fi
    if (( ${#id} > 200 )); then
        printf 'validate_session_id: session id too long (%d chars, max 200)\n' \
            "${#id}" >&2
        return 1
    fi
}
