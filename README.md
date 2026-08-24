# ai-agent-handoff

A tool for transferring conversation context and state between different AI agents/tools. Enables seamless handoffs from one AI assistant to another, preserving user intent and allowing you to continue conversations across different platforms or when token limits are reached.

## Problem it solves

AI assistants typically have limited context windows and token budgets. When you reach these limits, you lose the conversation history, forcing you to restart from scratch. Additionally, different tools have different capabilities, interfaces, and strengths - you may want to switch between them while preserving the discussion state.

This tool bridges that gap by extracting the substantive parts of a Claude Code session and formatting them as a structured handoff document that can be consumed by OpenCode or other AI tools.

## Features

- **Extract user messages** from Claude Code JSONL session files
- **Extract assistant messages** while filtering out Claude UI noise (task notifications, local commands, tool metadata)
- **Generate structured markdown** handoff with:
  - Session metadata (ID, source file, current project)
  - Original user context
  - Important recent user instructions (last 12 messages)
  - Previous agent's final state (last 250 lines of reasoning)
  - Earlier checkpoints and completed work
  - Continuation prompt for the new agent
- **Configurable filtering** for different AI tool hand-offs
- **Preserves session state** across token limits and tool switches

## Usage

```bash
# Extract a Claude session and generate handoff
claude-to-opencode-handoff <claude-session-id>

# Example:
claude-to-opencode-handoff a2a7da54-aa52-4d66-a37b-f228e7399564
```

Output: `CLAUDE_HANDOFF.md` in current directory

## Extending for Other Tools

The script is designed to be extensible. To hand off to/from other AI tools:

1. Modify the `jq` filters to match the source tool's JSON format
2. Adjust the `sed` patterns to filter tool-specific UI noise
3. Customize the markdown output format for the target tool
4. Add configuration flags to specify source/target tool types

## Roadmap

- [ ] Configurable source/target tool profiles
- [ ] Support for OpenCode → Claude hand-offs
- [ ] JSON export format for programmatic use
- [ ] CLI flags for specifying session locations
- [ ] Integration with multiple AI assistant platforms