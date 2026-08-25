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

# Claude Code UI/tool noise, filtered from stdin to stdout: task
# notifications, local-command echoes, tool-call metadata. None of it is
# useful context for another agent. This runs on BOTH user and assistant
# text — task notifications and command echoes are injected as user-role
# turns, not just assistant ones. Tags are matched with a leading `[[:space:]]*`
# because Claude Code indents some of them (e.g. `<command-message>`) but
# not others inconsistently. `<local-command-stdout>` and `<cu_window_hints>`
# use a real range delete (`/start/,/end/d`) rather than two independent
# single-line deletes, since their content can span many lines (compaction
# hook output, JSON dumps) — a same-line open+close still works, since sed's
# range delete matches the end pattern starting from the same line as the
# start.
claude_strip_noise() {
    sed \
        -e '/^[[:space:]]*<task-notification>/,/^[[:space:]]*<\/task-notification>[[:space:]]*$/d' \
        -e '/^[[:space:]]*<local-command-caveat>/d' \
        -e '/^[[:space:]]*<\/local-command-caveat>/d' \
        -e '/^[[:space:]]*<command-name>/d' \
        -e '/^[[:space:]]*<\/command-name>/d' \
        -e '/^[[:space:]]*<command-message>/d' \
        -e '/^[[:space:]]*<\/command-message>/d' \
        -e '/^[[:space:]]*<command-args>/d' \
        -e '/^[[:space:]]*<\/command-args>/d' \
        -e '/^[[:space:]]*<local-command-stdout>/,/<\/local-command-stdout>/d' \
        -e '/^[[:space:]]*<cu_window_hints>/,/<\/cu_window_hints>/d' \
        -e '/^[[:space:]]*<!-- attach -->[[:space:]]*$/d' \
        -e '/^[[:space:]]*<tool-use-id>/d' \
        -e '/^[[:space:]]*<\/tool-use-id>/d' \
        -e '/^[[:space:]]*<task-id>/d' \
        -e '/^[[:space:]]*<\/task-id>/d' \
        -e '/^[[:space:]]*<output-file>/d' \
        -e '/^[[:space:]]*<\/output-file>/d' \
        -e '/^[[:space:]]*<status>/d' \
        -e '/^[[:space:]]*<\/status>/d' \
        -e '/^monster@.*[$#]$/d' \
        -e '/^local-command/d'
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
    ' "$location" | claude_strip_noise > "$user_out"

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
    ' "$location" | claude_strip_noise > "$assistant_out"
}

claude_list() {
    local limit="${1:-15}" file id text
    while IFS= read -r file; do
        id="$(basename "$file" .jsonl)"
        text="$(jq -r '
            select(.type=="user")
            | .message.content
            | if type=="string" then .
              elif type=="array" then .[]? | select(.type=="text") | .text
              else empty end
        ' "$file" 2>/dev/null | claude_strip_noise | grep -Ev '^[[:space:]]*$' | head -1)"
        [[ -z "$text" ]] && text="(no user text found)"
        printf '%s\t%s — %s\n' "$id" "$(date -r "$file" '+%Y-%m-%d %H:%M' 2>/dev/null)" "$text"
    done < <(find "$HOME/.claude/projects" -type f -name "*.jsonl" -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -n "$limit" | cut -d' ' -f2-)
}
