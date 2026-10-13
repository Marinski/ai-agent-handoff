#!/usr/bin/env bash
# pi coding-agent session backend.
#
# A session is a JSONL file under
# ~/.pi/agent/sessions/<slugified-cwd>/<timestamp>_<uuid>.jsonl, one JSON
# object per line. The first line is `{"type":"session",...,"id":<uuid>,
# "cwd":<dir>}`. Every later transcript line is `{"type":"message",
# "message":{...}}`, where `message.role` is one of "user", "assistant",
# "system" or "toolResult" and `message.content` is an array of parts
# ({"type":"text","text":...}, {"type":"thinking",...}, {"type":"toolCall",
# ...}). Only the "text" parts of "user"/"assistant" messages are worth
# keeping; tool calls, tool results and the system preamble are not.
#
# Parsing goes through python3's json module so a session id can never reach
# the shell as anything but an argument.

PI_SESSIONS_DIR="${PI_SESSIONS_DIR:-$HOME/.pi/agent/sessions}"

# Resolve a session id to its JSONL path on stdout, or return 1. Shared by
# pi_locate (which adds a description) and pi_extract (which needs the bare
# path, because the location ai-handoff hands it is the decorated string).
pi_file() {
    local session_id="$1"
    [[ -d "$PI_SESSIONS_DIR" ]] || return 1
    python3 - "$PI_SESSIONS_DIR" "$session_id" <<'PY'
import glob, json, os, sys

root, sid = sys.argv[1], sys.argv[2]
for path in glob.glob(os.path.join(root, "*", "*.jsonl")):
    if os.path.basename(path).endswith(f"_{sid}.jsonl"):
        print(path)
        sys.exit(0)
    try:
        with open(path) as fh:
            head = json.loads(fh.readline())
    except (OSError, ValueError):
        continue
    if head.get("id") == sid:
        print(path)
        sys.exit(0)
sys.exit(1)
PY
}

pi_locate() {
    local session_id="$1" file cwd
    file="$(pi_file "$session_id")" || return 1
    cwd="$(python3 - "$file" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        print(json.loads(fh.readline()).get("cwd") or "")
except (OSError, ValueError):
    print("")
PY
)"
    printf '%s (session %s in %s)\n' "$file" "$session_id" "${cwd:-unknown cwd}"
}

pi_extract() {
    local session_id="$1" location="$2" user_out="$3" assistant_out="$4"
    local file
    file="$(pi_file "$session_id")" || return 1
    python3 - "$file" "$user_out" "$assistant_out" <<'PY'
import json, sys

location, user_out, assistant_out = sys.argv[1:4]
user_lines, assistant_lines = [], []

with open(location) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("type") != "message":
            continue
        msg = event.get("message") or {}
        role = msg.get("role")
        if role not in ("user", "assistant"):
            continue
        content = msg.get("content")
        if isinstance(content, str):
            parts = [content]
        elif isinstance(content, list):
            parts = [
                p.get("text") for p in content
                if isinstance(p, dict) and p.get("type") == "text"
            ]
        else:
            parts = []
        for text in parts:
            text = (text or "").strip()
            if text:
                (user_lines if role == "user" else assistant_lines).append(text)

def write(path, lines):
    with open(path, "w") as fh:
        fh.write("\n\n".join(lines))
        if lines:
            fh.write("\n")

write(user_out, user_lines)
write(assistant_out, assistant_lines)
PY
}

pi_list() {
    local limit="${1:-15}"
    [[ -d "$PI_SESSIONS_DIR" ]] || return 1
    python3 - "$PI_SESSIONS_DIR" "$limit" <<'PY'
import datetime, glob, json, os, sys

root, limit = sys.argv[1], int(sys.argv[2])
files = sorted(
    glob.glob(os.path.join(root, "*", "*.jsonl")),
    key=os.path.getmtime, reverse=True,
)[:limit]

for path in files:
    sid = label = cwd = ""
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                event = json.loads(line)
                if event.get("type") == "session":
                    sid = event.get("id", "") or sid
                    cwd = event.get("cwd", "") or cwd
                elif event.get("type") == "message":
                    msg = event.get("message") or {}
                    if msg.get("role") != "user":
                        continue
                    content = msg.get("content")
                    if isinstance(content, str):
                        text = content
                    elif isinstance(content, list):
                        text = " ".join(
                            p.get("text", "") for p in content
                            if isinstance(p, dict) and p.get("type") == "text"
                        )
                    else:
                        text = ""
                    text = " ".join(text.split())
                    if text:
                        label = text
                        break
    except (OSError, ValueError):
        continue
    if not sid:
        name = os.path.basename(path)
        sid = name[:-len(".jsonl")].split("_", 1)[-1] or name
    if not label:
        label = cwd or sid
    when = datetime.datetime.fromtimestamp(
        os.path.getmtime(path)
    ).strftime("%Y-%m-%d %H:%M")
    label = label.replace("\t", " ").replace("\n", " ").strip()
    print(f"{sid}\t{when} — {label}")
PY
}
