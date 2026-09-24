#!/usr/bin/env bash
test_tool_locate() {
    echo "test session location"
    return 0
}
test_tool_extract() {
    local sid="$1"
    local loc="$2"
    local user="$3"
    local ass="$4"
    echo "user: test user message" > "$user"
    echo "assistant: test assistant response" > "$ass"
}
