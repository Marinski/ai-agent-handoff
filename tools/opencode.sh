#!/usr/bin/env bash
# OpenCode session backend.
#
# Unlike Claude Code, OpenCode does not write one JSONL file per session:
# every session lives in a single SQLite database. Two message layouts exist:
#
#   v1  `message` (data: JSON with `role`) joined to `part` (data: JSON with
#       `type`; the `text` parts carry the text).
#   v2  `session_message` (an event-sourced projection: `type`, `seq`,
#       `data` JSON), which newer builds write and `message`/`part` no longer
#       receive. `session_message` is created by migration 20260427172553 and
#       gains `seq` in 20260603040000.
#
# The `session` table (id, slug, title, directory, time_created) is shared by
# both, so locate/list need no branching. extract reads whichever table the
# session actually has rows in, so the same backend works on an old and a new
# database.
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


def has_rows(table):
    try:
        return con.execute(
            f"SELECT 1 FROM {table} WHERE session_id = ? LIMIT 1", (sid,)
        ).fetchone() is not None
    except sqlite3.OperationalError:
        return False


def role_of(obj):
    """The message role of a v2 projected entity, unwrapping a wrapper row."""
    if not isinstance(obj, dict):
        return None
    r = obj.get("role")
    if r in ("user", "assistant"):
        return r
    if obj.get("type") in ("user", "assistant"):
        return obj["type"]
    for key in ("message", "data"):
        inner = obj.get(key)
        if isinstance(inner, dict):
            r = role_of(inner)
            if r:
                return r
    return None


def text_of(obj):
    """The kept text of an entity: its own text part, or the text parts it carries."""
    if not isinstance(obj, dict):
        return ""
    out = []
    if obj.get("type") == "text" and isinstance(obj.get("text"), str):
        out.append(obj["text"])
    parts = obj.get("parts")
    if isinstance(parts, list):
        for p in parts:
            if isinstance(p, dict) and p.get("type") == "text" and isinstance(p.get("text"), str):
                out.append(p["text"])
    inner = obj.get("data") if isinstance(obj.get("data"), dict) else obj.get("message")
    if isinstance(inner, dict):
        out.append(text_of(inner))
    return "\n".join(t for t in out if t and t.strip()).strip()


user_lines, assistant_lines = [], []

if has_rows("session_message"):
    # v2: one projected row per message/part, ordered by `seq` when present.
    cols = [r[1] for r in con.execute("PRAGMA table_info(session_message)")]
    order = "seq" if "seq" in cols else "time_created, id"
    raw_rows = [r[0] for r in con.execute(
        f"SELECT data FROM session_message WHERE session_id = ? ORDER BY {order}",
        (sid,),
    )]
    last_role = None
    for raw in raw_rows:
        if not raw:
            continue
        try:
            obj = json.loads(raw)
        except (TypeError, ValueError):
            continue
        role = role_of(obj) or last_role
        if role_of(obj):
            last_role = role_of(obj)
        text = text_of(obj)
        if not text or role not in ("user", "assistant"):
            continue
        (user_lines if role == "user" else assistant_lines).append(text)
else:
    # v1: message rows joined to their text parts.
    rows = con.execute("""
        SELECT m.data AS mdata, pt.data AS pdata
        FROM message m
        LEFT JOIN part pt ON pt.message_id = m.id
        WHERE m.session_id = ?
        ORDER BY m.time_created, m.id, pt.id
    """, (sid,)).fetchall()
    for r in rows:
        try:
            role = json.loads(r["mdata"]).get("role")
        except (TypeError, ValueError):
            continue
        if role not in ("user", "assistant") or not r["pdata"]:
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
        (user_lines if role == "user" else assistant_lines).append(text)

con.close()

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
