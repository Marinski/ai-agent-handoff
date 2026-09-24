#!/usr/bin/env bash
# Claude Code session backend.
#
# A session is a JSONL file under ~/.claude/projects/**/<session-id>.jsonl,
# one JSON object per line, with `.type` of "user" or "assistant" and
# `.message.content` holding either a plain string or an array of parts.

claude_locate() {
    local session_id="$1"
    local target="${session_id}.jsonl"
    local file
    while IFS= read -r file; do
        [[ "$(basename "$file")" == "$target" ]] && {
            printf '%s\n' "$file"
            return 0
        }
    done < <(find "$HOME/.claude/projects" -type f -name '*.jsonl')
    return 1
}

# Claude Code UI/tool noise, filtered from stdin to stdout: task
# notifications, local-command echoes, tool-call metadata. None of it is
# useful context for another agent. This runs on BOTH user and assistant
# text — task notifications and command echoes are injected as user-role
# turns, not just assistant ones. Tags are matched with a leading `[[:space:]]*`
# because Claude Code indents some of them (e.g. `<command-message>`) but
# not others inconsistently.
#
# `<local-command-*>` boundary markers (`<local-command-caveat>` /
# `</local-command-caveat>`, `<local-command-stdout>` / `</local-command-stdout>`)
# are preserved rather than deleted: each matching line is kept with a
# `[local-command-echo] ` prefix, so a reader of the handoff can still see
# that a local command ran and where its echo began/ended.
#
# `<task-notification>`, `<local-command-stdout>` and `<cu_window_hints>`
# can span many lines (compaction hook output, JSON dumps), so they are
# handled as real ranges with an awk state machine rather than independent
# single-line deletes. Every range delete is capped: lines are only dropped
# inside a complete open/close pair, and an unterminated tag (a dangling
# `<local-command-stdout>` with no close before EOF, say) never causes a
# deletion to the end of the file — the buffered lines are flushed instead.
claude_strip_noise() {
    awk '
        function flush_buffered() {
            for (i = 0; i < buf_n; i++) print buf[i]
            buf_n = 0
        }
        BEGIN { buf_n = 0 }
        {
            if (in_stdout) {
                if ($0 ~ /<\/local-command-stdout>/) {
                    print "[local-command-echo] " $0
                    buf_n = 0
                    in_stdout = 0
                } else {
                    buf[buf_n++] = $0
                }
                next
            }
            if (in_task) {
                if ($0 ~ /^[[:space:]]*<\/task-notification>[[:space:]]*$/) {
                    buf_n = 0
                    in_task = 0
                } else {
                    buf[buf_n++] = $0
                }
                next
            }
            if (in_hints) {
                if ($0 ~ /<\/cu_window_hints>/) {
                    buf_n = 0
                    in_hints = 0
                } else {
                    buf[buf_n++] = $0
                }
                next
            }
            if ($0 ~ /^[[:space:]]*<local-command-stdout>/) {
                if ($0 ~ /<\/local-command-stdout>/) {
                    print "[local-command-echo] " $0
                    next
                }
                print "[local-command-echo] " $0
                in_stdout = 1
                buf_n = 0
                next
            }
            if ($0 ~ /^[[:space:]]*<task-notification>/) {
                buf[buf_n++] = $0
                in_task = 1
                next
            }
            if ($0 ~ /^[[:space:]]*<cu_window_hints>/) {
                if ($0 ~ /<\/cu_window_hints>/) next
                buf[buf_n++] = $0
                in_hints = 1
                next
            }
            if ($0 ~ /^[[:space:]]*<local-command-caveat>/) {
                print "[local-command-echo] " $0
                next
            }
            if ($0 ~ /^[[:space:]]*<\/local-command-caveat>/) {
                print "[local-command-echo] " $0
                next
            }
            if ($0 ~ /^[[:space:]]*<command-name>/) { next }
            if ($0 ~ /^[[:space:]]*<\/command-name>/) { next }
            if ($0 ~ /^[[:space:]]*<command-message>/) { next }
            if ($0 ~ /^[[:space:]]*<\/command-message>/) { next }
            if ($0 ~ /^[[:space:]]*<command-args>/) { next }
            if ($0 ~ /^[[:space:]]*<\/command-args>/) { next }
            if ($0 ~ /^[[:space:]]*<!-- attach -->[[:space:]]*$/) { next }
            if ($0 ~ /^[[:space:]]*<tool-use-id>/) { next }
            if ($0 ~ /^[[:space:]]*<\/tool-use-id>/) { next }
            if ($0 ~ /^[[:space:]]*<task-id>/) { next }
            if ($0 ~ /^[[:space:]]*<\/task-id>/) { next }
            if ($0 ~ /^[[:space:]]*<output-file>/) { next }
            if ($0 ~ /^[[:space:]]*<\/output-file>/) { next }
            if ($0 ~ /^[[:space:]]*<status>/) { next }
            if ($0 ~ /^[[:space:]]*<\/status>/) { next }
            if ($0 ~ /^monster@.*[$#]$/) { next }
            if ($0 ~ /^local-command/) { next }
            print
        }
        END {
            if (in_stdout || in_task || in_hints) flush_buffered()
        }
    '
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
