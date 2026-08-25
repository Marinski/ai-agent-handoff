#!/usr/bin/env bash
# VS Code (Chat panel) session backend.
#
# `.vscode-server/` holds several session-shaped stores (an `agentSessionData`
# per-session SQLite DB, a per-project History dir, GitHub Copilot Chat's own
# per-workspace storage) but only one holds actual transcript text across all
# chat participants regardless of which model answered: a single global
# SQLite database owned by the `github.copilot-chat` extension, which is also
# what backs VS Code's native Chat panel for BYOK providers (this machine
# also runs sessions through the LiteLLM chat extension, routed through the
# same store). `sessions` holds one row per chat, `turns` one row per
# request/response pair, already as plain rendered text — no per-tool UI
# noise observed in it, unlike Claude Code's JSONL.
#
# Queries go through python3's sqlite3 module with bound parameters, same as
# tools/opencode.sh, so a session id can never reach the database as SQL.

VSCODE_CHAT_DB="${VSCODE_CHAT_DB:-$HOME/.vscode-server/data/User/globalStorage/github.copilot-chat/session-store.db}"

vscode_locate() {
    local session_id="$1"
    [[ -f "$VSCODE_CHAT_DB" ]] || return 1
    python3 - "$VSCODE_CHAT_DB" "$session_id" <<'PY'
import sys, sqlite3

db, sid = sys.argv[1], sys.argv[2]
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
row = con.execute(
    "SELECT summary, repository, cwd FROM sessions WHERE id = ?", (sid,)
).fetchone()
con.close()
if not row:
    sys.exit(1)
summary, repository, cwd = row
where = repository or cwd or "unknown location"
print(f"{db} (session {sid}: \"{summary or sid}\" in {where})")
PY
}

vscode_extract() {
    local session_id="$1" location="$2" user_out="$3" assistant_out="$4"
    python3 - "$VSCODE_CHAT_DB" "$session_id" "$user_out" "$assistant_out" <<'PY'
import sqlite3, sys

db, sid, user_out, assistant_out = sys.argv[1:5]
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)

rows = con.execute("""
    SELECT user_message, assistant_response
    FROM turns
    WHERE session_id = ?
    ORDER BY turn_index
""", (sid,)).fetchall()
con.close()

user_lines = [u.strip() for u, _ in rows if u and u.strip()]
assistant_lines = [a.strip() for _, a in rows if a and a.strip()]

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

vscode_list() {
    local limit="${1:-15}"
    [[ -f "$VSCODE_CHAT_DB" ]] || return 1
    python3 - "$VSCODE_CHAT_DB" "$limit" <<'PY'
import sys, sqlite3

db, limit = sys.argv[1], int(sys.argv[2])
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
rows = con.execute(
    "SELECT id, summary, updated_at FROM sessions ORDER BY updated_at DESC LIMIT ?",
    (limit,),
).fetchall()
con.close()

for id_, summary, updated_at in rows:
    when = (updated_at or "?")[:16].replace("T", " ")
    label = (summary or id_).replace("\t", " ").replace("\n", " ").strip()
    print(f"{id_}\t{when} — {label}")
PY
}
