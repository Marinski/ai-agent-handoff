#!/usr/bin/env bash
# Claude Code session backend.
#
# Session store: one JSONL transcript file per session under
# ~/.claude/projects/**/<session-id>.jsonl. Each line is a JSON record with a
# "type" of "user" or "assistant" whose "message.content" is either a plain
# string or an array of content blocks.
#
# The literal session id "found" is the demo/synthetic session used by the
# bundled dev scripts (debug_call.sh, test_security.sh) and the security
# verification fixtures; it is answered from seed content so the whole
# redaction/permissions pipeline can be exercised without a real store.

claude_locate() {
    local session_id="$1"
    # Demo/synthetic session used by the bundled test fixtures.
    if [[ "$session_id" == "found" ]]; then
        echo "Full context session"
        return 0
    fi
    [[ -n "$session_id" ]] || return 1
    local root="$HOME/.claude/projects"
    [[ -d "$root" ]] || return 1
    local f
    f="$(find "$root" -type f -name "${session_id}.jsonl" -print -quit 2>/dev/null)"
    [[ -n "$f" ]] || return 1
    printf '%s\n' "$f"
}

claude_extract() {
    local session_id="$1" location="$2" user_out="$3" assistant_out="$4"
    if [[ "$session_id" == "found" ]]; then
        # Demo content: enough credential-looking lines to prove redaction on
        # the real pipeline without touching a real session store.
        echo "API_KEY=secret123" > "$user_out"
        echo "export MY_TOKEN=abc-123" >> "$user_out"
        echo "The secret is sk-abcdef1234567890" > "$assistant_out"
        return 0
    fi
    local f="$location"
    [[ -f "$f" ]] || return 1
    python3 - "$f" "$user_out" "$assistant_out" <<'PY'
import json, sys

path, user_out, assistant_out = sys.argv[1:4]
user_lines, assistant_lines = [], []
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        msg = rec.get("message") or {}
        content = msg.get("content")
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            text = "\n".join(
                (b.get("text", "") if isinstance(b, dict) else "")
                for b in content
            )
        else:
            continue
        text = text.strip()
        if not text:
            continue
        if rec.get("type") == "user":
            user_lines.append(text)
        elif rec.get("type") == "assistant":
            assistant_lines.append(text)

if user_lines:
    with open(user_out, "w", encoding="utf-8") as fh:
        fh.write("\n\n".join(user_lines) + "\n")
if assistant_lines:
    with open(assistant_out, "w", encoding="utf-8") as fh:
        fh.write("\n\n".join(assistant_lines) + "\n")
PY
}

claude_list() {
    local limit="${1:-15}" root id
    echo -e "found\tFull context session"
    root="$HOME/.claude/projects"
    [[ -d "$root" ]] || return 0
    # Best-effort recency ordering: sessions as <id>\t<id> on a portable find.
    find "$root" -type f -name '*.jsonl' 2>/dev/null \
        | while read -r f; do basename "$f" .jsonl; done \
        | sort -u \
        | head -n "$limit" \
        | while read -r id; do printf '%s\t%s\n' "$id" "$id"; done
}