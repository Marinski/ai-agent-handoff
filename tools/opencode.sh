#!/usr/bin/env bash
# OpenCode session backend.
#
# Unlike Claude Code, OpenCode does not write one JSONL file per session.
# Every session lives in a single SQLite database, in `session` /
# `message` / `part` tables: `message.data` is a JSON blob with a `role`,
# and each of its `part` rows is a JSON blob with a `type` ("text" is the
# only one worth keeping) and, for text parts, a `text` field.
#
# Queries go through python3's sqlite3 module with bound parameters rather
# than the sqlite3 CLI with interpolated strings, so a session id can never
# reach the database as SQL.

OPENCODE_DB="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"

opencode_locate() {
    local session_id="$1"
    [[ -f "$OPENCODE_DB" ]] || return 1
    python3 - "$OPENCODE_DB" "$session_id" <<'PY'
import sys, sqlite3

db, sid = sys.argv[1], sys.argv[2]
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
row = con.execute(
    "SELECT title, slug, directory FROM session WHERE id = ?", (sid,)
).fetchone()
con.close()
if not row:
    sys.exit(1)
title, slug, directory = row
print(f"{db} (session {sid}: \"{title or slug}\" in {directory})")
PY
}

opencode_extract() {
    local session_id="$1" location="$2" user_out="$3" assistant_out="$4"
    python3 - "$OPENCODE_DB" "$session_id" "$user_out" "$assistant_out" <<'PY'
import json, sqlite3, sys

db, sid, user_out, assistant_out = sys.argv[1:5]
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
con.row_factory = sqlite3.Row

rows = con.execute("""
    SELECT m.data AS mdata, pt.data AS pdata
    FROM message m
    LEFT JOIN part pt ON pt.message_id = m.id
    WHERE m.session_id = ?
    ORDER BY m.time_created, m.id, pt.id
""", (sid,)).fetchall()
con.close()

user_lines, assistant_lines = [], []
for r in rows:
    try:
        role = json.loads(r["mdata"]).get("role")
    except (TypeError, ValueError):
        continue
    if not r["pdata"]:
        continue
    try:
        part = json.loads(r["pdata"])
    except (TypeError, ValueError):
        continue
    if part.get("type") != "text":
        continue
    text = (part.get("text") or "").strip()
    if not text:
        continue
    if role == "user":
        user_lines.append(text)
    elif role == "assistant":
        assistant_lines.append(text)

with open(user_out, "w") as fh:
    fh.write("\n\n".join(user_lines))
    if user_lines:
        fh.write("\n")
with open(assistant_out, "w") as fh:
    fh.write("\n\n".join(assistant_lines))
    if assistant_lines:
        fh.write("\n")
PY
}

opencode_list() {
    local limit="${1:-15}"
    [[ -f "$OPENCODE_DB" ]] || return 1
    python3 - "$OPENCODE_DB" "$limit" <<'PY'
import sys, sqlite3, datetime

db, limit = sys.argv[1], int(sys.argv[2])
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
rows = con.execute(
    "SELECT id, title, slug, time_created FROM session ORDER BY time_created DESC LIMIT ?",
    (limit,),
).fetchall()
con.close()

for id_, title, slug, ts in rows:
    when = datetime.datetime.fromtimestamp(ts / 1000).strftime("%Y-%m-%d %H:%M") if ts else "?"
    label = (title or slug or id_).replace("\t", " ").replace("\n", " ").strip()
    print(f"{id_}\t{when} — {label}")
PY
}
