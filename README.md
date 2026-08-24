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
functions (see `tools/claude.sh` and `tools/opencode.sh` for real examples):

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
```

No changes to `ai-handoff` itself are needed — `--from cursor` picks it up
automatically once the file exists.

## Roadmap

- [x] Configurable source/target tool profiles (`tools/*.sh`)
- [x] Support for OpenCode → Claude hand-offs
- [ ] JSON export format for programmatic use
- [ ] Integration with additional AI assistant platforms (Cursor, Windsurf, ...)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on contributing to this project.

## License

MIT License - see [LICENSE](LICENSE) for details.