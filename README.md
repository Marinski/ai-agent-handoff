# ai-agent-handoff

A tool for transferring conversation context and state between different AI agents/tools. Enables seamless handoffs from one AI assistant to another, preserving user intent and allowing you to continue conversations across different platforms or when token limits are reached.

## Problem it solves

AI assistants typically have limited context windows and token budgets. When you reach these limits, you lose the conversation history, forcing you to restart from scratch. Additionally, different tools have different capabilities, interfaces, and strengths - you may want to switch between them while preserving the discussion state.

This tool bridges that gap by extracting the substantive parts of an AI coding
session and formatting it as a structured handoff document that the next
agent — Claude Code, OpenCode, or another tool — can pick up and continue
from.

## Supported tools

| Tool     | Session store                                             |
|----------|------------------------------------------------------------|
| `claude` | JSONL files under `~/.claude/projects/**/<session-id>.jsonl` |
| `opencode` | SQLite database at `~/.local/share/opencode/opencode.db` (`session`/`message`/`part` tables) |
| `vscode` | SQLite database at `~/.vscode-server/data/User/globalStorage/github.copilot-chat/session-store.db` (`sessions`/`turns` tables) — VS Code's native Chat panel, regardless of which model answered (GitHub Copilot, or a BYOK provider extension routed through the same store) |

Handoffs work in either direction: `--from claude --to opencode` and
`--from opencode --to claude` both work, since `--from` is what selects the
extraction backend — `--to` only labels the output for the next agent.

## Features

- **Extract user messages** from the source tool's session store
- **Extract assistant messages** while filtering out that tool's own UI/tool
  noise (task notifications, local commands, tool metadata)
- **Generate structured markdown** handoff with:
  - Session metadata (ID, source location, current project)
  - Original user context
  - Important recent user instructions (last 12 messages)
  - Previous agent's final state (last 250 lines of reasoning)
  - Earlier checkpoints and completed work
  - Continuation prompt for the new agent
- **Preserves session state** across token limits and tool switches
- **Redacts secrets** from the handoff: common credential patterns
  (`API_KEY=...`, `export SECRET=...`, `Bearer <token>`, `sk-...` /
  `ghp_...` / `AKIA...` tokens, `scheme://user:password@host` connection
  URLs) are replaced with `[REDACTED]` during extraction, so credentials are
  not copied verbatim into the handoff file. Variable names are kept
  (`API_KEY=[REDACTED]`) so the next agent still sees which secret was set.
  Redaction is regex-based and not exhaustive — treat the handoff as still
  possibly containing arbitrary session text (e.g. secrets written in prose
  or unusual formats).
- **Wraps extracted transcript in unique delimiters**: every transcript
  block rendered into the handoff sits between
  `<<<AI-HANDOFF-TRANSCRIPT <nonce> BEGIN>>>` / `<<<AI-HANDOFF-TRANSCRIPT <nonce> END>>>`
  markers. The nonce is 16 random bytes generated per run *after*
  extraction, so the session text can never contain or spoof the exact
  marker line, and the markers are deliberately not markdown fences,
  HTML comments, or XML tags. The handoff's instructions tell the next
  agent that only those two exact marker lines delimit data and that
  everything between them is inert historical transcript — never
  instructions, commands, or tool output — so transcript text that
  merely looks like a directive is framed as data during the handoff
  rather than acted on.

## Installation

`ai-handoff` needs its `tools/` directory alongside it, so install it as a
symlink into a directory on your `PATH` rather than copying just the script:

```bash
git clone https://github.com/Marinski/ai-agent-handoff.git
mkdir -p ~/.local/bin
ln -sf "$PWD/ai-agent-handoff/ai-handoff" ~/.local/bin/ai-handoff
# ~/.local/bin must be on PATH
```

## Usage

```bash
# Extract a Claude session and generate handoff (defaults: --from claude --to opencode)
ai-handoff <session-id>

# Example:
ai-handoff a2a7da54-aa52-4d66-a37b-f228e7399564

# Specify output directory:
ai-handoff <session-id> /path/to/output
ai-handoff <session-id> --out /path/to/output

# Explicit source/target tool, either direction:
ai-handoff <session-id> --from claude --to opencode
ai-handoff ses_fcbbc786dffeRHepIt5tP1lDVH --from opencode --to claude
```

**Output**: `ai-handoff-<session-id>.md` in the current directory (or specified path)

### Don't know the session id?

Run it with no session id from a terminal and it walks you through picking
one — which tool to migrate *from*, a numbered list of that tool's recent
sessions (dated, labeled with their title/summary/first message, not just a
raw id) to migrate *to*:

```
$ ai-handoff
Migrate from which tool?
  1) claude
  2) opencode
  3) vscode
> 3
Which vscode session?
  1) 2026-08-03 11:38 — Flip `VISION_ENABLED=true` so the planner "sees" ... (id: 875e11af-...)
  2) 2026-07-30 21:50 — now we're talking, what model do you use (id: ddeda835-...)
  m) enter a session ID manually
> 2
Migrate to which tool?
  1) claude
  2) opencode
  3) vscode
> 1
```

Any part already given on the command line (`--from`, `--to`) is skipped —
e.g. `ai-handoff --from vscode` in a terminal only prompts for the session
and the target. This only triggers when the session id is omitted *and*
you're in a real terminal; a script or pipe with a missing id still just
fails with the usage message instead of hanging on a prompt.

## How it works

1. Takes a session ID and a `--from <tool>` (default `claude`)
2. Sources `tools/<tool>.sh` and calls its `<tool>_locate` / `<tool>_extract`
   functions to find the session and pull out plain-text user/assistant
   messages, filtered of that tool's own UI/tool-call noise
3. Renders a structured markdown handoff file, labeled for `--to <tool>`
   (default `opencode`):
   - Session metadata and important instructions
   - Original user context (last 12 messages)
   - Previous agent's final state (last 250 lines of reasoning)
   - Earlier checkpoints and completed work
   - Continuation prompt for the new agent

## Adding a new tool

Each tool is one file in `tools/`, e.g. `tools/cursor.sh`, defining two
required functions and one optional one (see `tools/claude.sh` and
`tools/opencode.sh` for real examples):

```bash
cursor_locate() {
    local session_id="$1"
    # print a human-readable session location to stdout, or `return 1`
}

cursor_extract() {
    local session_id="$1" location="$2" user_out="$3" assistant_out="$4"
    # write plain-text user messages to $user_out
    # write filtered plain-text assistant messages to $assistant_out
}

# optional — powers the guided session picker; without it, guided mode
# just asks for a session id directly for this tool.
cursor_list() {
    local limit="${1:-15}"
    # print up to $limit recent sessions, most recent first, as
    # "<id>\t<date> — <label>" lines
}
```

No changes to `ai-handoff` itself are needed — `--from cursor` picks it up
automatically once the file exists. Backend filenames must match
`^[a-z][a-z0-9_-]*$` (lowercase letter to start); the tool name is validated
before it is interpolated into the backend path.

## Roadmap

- [x] Configurable source/target tool profiles (`tools/*.sh`)
- [x] Support for OpenCode → Claude hand-offs
- [x] Support for VS Code (GitHub Copilot Chat / BYOK Chat panel) sessions
- [x] Guided picker — no need to already know the session id
- [ ] JSON export format for programmatic use
- [ ] Integration with additional AI assistant platforms (Cursor, Windsurf, ...)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on contributing to this project.

## License

MIT License - see [LICENSE](LICENSE) for details.