#!/usr/bin/env bash
# Claude Code session backend.
#
# A session is a JSONL file under ~/.claude/projects/**/<session-id>.jsonl,
# one JSON object per line, with `.type` of "user" or "assistant" and
# `.message.content` holding either a plain string or an array of parts.

claude_locate() {
    local session_id="$1"
    local file
    file="$(find "$HOME/.claude/projects" \
        -type f \
        -name "${session_id}.jsonl" \
        -print -quit)"
    [[ -n "$file" ]] || return 1
    printf '%s\n' "$file"
}

claude_extract() {
    local session_id="$1" location="$2" user_out="$3" assistant_out="$4"

    jq -r '
        select(.type=="user")
        | .message.content
        | if type=="string" then .
          elif type=="array" then
              .[]?
              | select(.type=="text")
              | .text
          else empty
          end
    ' "$location" |
    # Strip pasted shell-prompt lines that leak into user messages when a
    # terminal transcript is copied into the chat.
    sed \
        -e '/^monster@.*[$#]$/d' \
        -e '/^local-command/d' \
        > "$user_out"

    jq -r '
        select(.type=="assistant")
        | .message.content
        | if type=="string" then .
          elif type=="array" then
              .[]?
              | select(.type=="text")
              | .text
          else empty
          end
    ' "$location" |
    # Claude Code UI/tool noise: task notifications, local-command echoes,
    # tool-call metadata. None of it is useful context for another agent.
    sed \
        -e '/^<task-notification>/,/^<\/task-notification>$/d' \
        -e '/^<local-command-caveat>/d' \
        -e '/^<\/local-command-caveat>/d' \
        -e '/^<command-name>/d' \
        -e '/^<\/command-name>/d' \
        -e '/^<command-message>/d' \
        -e '/^<\/command-message>/d' \
        -e '/^<command-args>/d' \
        -e '/^<\/command-args>/d' \
        -e '/^<local-command-stdout>/d' \
        -e '/^<\/local-command-stdout>/d' \
        -e '/^<tool-use-id>/d' \
        -e '/^<\/tool-use-id>/d' \
        -e '/^<task-id>/d' \
        -e '/^<\/task-id>/d' \
        -e '/^<output-file>/d' \
        -e '/^<\/output-file>/d' \
        -e '/^<status>/d' \
        -e '/^<\/status>/d' \
        > "$assistant_out"
}
