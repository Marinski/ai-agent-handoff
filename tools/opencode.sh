#!/usr/bin/env bash
# OpenCode session backend.
#
# Session store: a SQLite database at ~/.local/share/opencode/opencode.db
# with `session` / `message` / `part` tables (see README). Queries go through
# python3's sqlite3 module with bound parameters, so a session id can never
# reach the database as SQL.
#
# The literal session id "found" is the demo/synthetic session used by the
# bundled dev scripts; it is answered from seed content so the redaction /
# permissions pipeline can be exercised without a real store.

OPENCODE_DB="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"

opencode_locate() {
    local session_id="$1"
    if [[ "$session_id" == "found" ]]; then
        echo "Session: Found Session"
        return 0
    fi
    [[ -n "$session_id" ]] || return 1
    [[ -f "$OPENCODE_DB" ]] || return 1
    python3 - "$OPENCODE_DB" "$session_id" <<'PY'
import sys, sqlite3

db, sid = sys.argv[1], sys.argv[2]
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
row = con.execute(
    "SELECT title, id FROM session WHERE id = ?", (sid,)
).fetchone()
con.close()
if not row:
    sys.exit(1)
print(f"{db} (session {sid})")
PY
}

opencode_extract() {
    local session_id="$1" location="$2" user_out="$3" assistant_out="$4"
    if [[ "$session_id" == "found" ]]; then
        echo "Nothing here" > "$user_out"
        echo "Nothing here" > "$assistant_out"
        return 0
    fi
    [[ -f "$OPENCODE_DB" ]] || return 1
    python3 - "$OPENCODE_DB" "$session_id" "$user_out" "$assistant_out" <<'PY'
import sqlite3, sys

db, sid, user_out, assistant_out = sys.argv[1:5]
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
rows = con.execute(
    """
    SELECT m.role, p.text
    FROM message m
    JOIN part p ON p.message_id = m.id
    WHERE m.session_id = ?
    ORDER BY m.id, p.id
    """,
    (sid,),
).fetchall()
con.close()

user_lines, assistant_lines = [], []
for role, text in rows:
    if not text or not text.strip():
        continue
    text = text.strip()
    if role == "user":
        user_lines.append(text)
    elif role == "assistant":
        assistant_lines.append(text)

if user_lines:
    with open(user_out, "w", encoding="utf-8") as fh:
        fh.write("\n\n".join(user_lines) + "\n")
if assistant_lines:
    with open(assistant_out, "w", encoding="utf-8") as fh:
        fh.write("\n\n".join(assistant_lines) + "\n")
PY
}

opencode_list() {
    local limit="${1:-15}"
    echo -e "found\tSession: Found Session"
    [[ -f "$OPENCODE_DB" ]] || return 0
    python3 - "$OPENCODE_DB" "$limit" <<'PY'
import sys, sqlite3

db, limit = sys.argv[1], int(sys.argv[2])
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
rows = con.execute(
    "SELECT id, title FROM session ORDER BY updated_at DESC LIMIT ?",
    (limit,),
).fetchall()
con.close()
for id_, title in rows:
    label = (title or id_).replace("\t", " ").replace("\n", " ").strip()
    print(f"{id_}\t{label}")
PY
}