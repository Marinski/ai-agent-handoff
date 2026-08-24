# Changelog

All notable changes to the ai-agent-handoff project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- OpenCode → Claude (and Claude → OpenCode) handoff, reading OpenCode's real
  session store: a SQLite database at `~/.local/share/opencode/opencode.db`
  (`session`/`message`/`part` tables), not JSONL files
- `tools/` directory: one backend script per source tool (`claude.sh`,
  `opencode.sh`), each exposing a `<tool>_locate` / `<tool>_extract` pair;
  `ai-handoff` is now a thin runner that dispatches to whichever backend
  `--from` names and renders the shared markdown template
- Working `--from <tool>`, `--to <tool>`, `--out <dir>` flags, plus `--help`

### Fixed
- `--to`/`--from` were documented in the README but never actually parsed —
  the script read them positionally (`$2`/`$3`), so
  `ai-handoff <id> --to opencode --from claude` silently set the target tool
  to the literal string `--to`. Both are now real flags.
- The OpenCode source branch was an unimplemented stub: matched on the
  misspelled tool name `encode`, and looked for `~/.opencode/sessions/*.jsonl`,
  a path OpenCode has never written to.

### Added (carried over from initial release)
- User message extraction from Claude JSONL sessions
- Assistant message extraction with Claude UI noise filtering
- Structured markdown handoff generation
- Last 12 user messages summary
- Last 250 lines of assistant reasoning
- Continuation prompt for new agent

## [0.1.0] - 2026-08-24

### Added
- Initial release
- Core handoff script (`ai-handoff`)
- README with usage examples
- CONTRIBUTING.md guidelines
- CHANGELOG.md setup