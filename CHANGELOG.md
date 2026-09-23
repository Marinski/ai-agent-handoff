# Changelog

All notable changes to the ai-agent-handoff project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Tool discovery (`available_tools_arr`) now filters `tools/*.sh` by backend
  validity instead of globbing every file: a file is collected as an
  available tool only when its basename matches `^[a-z][a-z0-9_-]*$` and it
  defines the required `<tool>_locate` / `<tool>_extract` functions, so
  stray scripts dropped in `tools/` (scratch files, partial backends,
  renamed copies of an existing backend) no longer show up in the guided
  picker or `--help`'s "Available tools:" line. Detection is a static grep
  over the file — unvalidated files are never sourced during discovery.
- Shared helper scripts (`lib/validate.sh`, `lib/redact.sh`) moved out of
  `tools/` into a new `lib/` directory, so the `tools/*.sh` glob only matches
  tool backend scripts. `ai-handoff` (and the security test suite) now load
  the helpers from `lib/`; the per-tool exclusion hack in the picker is gone.
- The closing "first prompt" block now includes the handoff file's absolute
  path, so it's directly copy-pasteable into the target tool without also
  having to scroll up and copy the path from the "Handoff:" line separately.
  `OUTPUT_DIR` is resolved to an absolute path right after `mkdir -p`, so
  this is correct even when `--out` was a relative path.

### Added
- Guided mode: running `ai-handoff` with no session id from a terminal walks
  through picking a source tool, a session from that tool's recent sessions
  (numbered, dated, labeled with title/summary/first message — not just a
  raw id), and a target tool, in that order. Any part already given via
  `--from`/`--to` is skipped. Backed by a new optional `<tool>_list [limit]`
  function in each backend (`claude_list`, `opencode_list`, `vscode_list`),
  returning `id\tdate — label` lines; a tool without one falls back to
  asking for an id directly. Only triggers when the session id is omitted
  and stdin/stdout are both a tty — a script or pipe with a missing id still
  just fails with the usage message, never hangs on a prompt.

### Fixed
- `tools/claude.sh`'s noise filter (task notifications, command echoes,
  tool-call metadata) was only ever applied to assistant messages, never to
  user messages — but task notifications and command echoes are recorded as
  user-role turns too, so every Claude-sourced handoff's "ORIGINAL USER
  CONTEXT" section carried this noise unfiltered. Found via the new
  `claude_list`, whose session labels were literal tag soup
  (`<command-message>model</command-message>`) instead of real text.
  Two more bugs in the same filter, fixed alongside it: several tags
  (`<command-message>`, `<command-args>`) are indented by Claude Code and the
  `^<tag` anchors missed them; `<local-command-stdout>` can span many lines
  (compaction hook output, JSON dumps) but was only ever deleted as two
  independent single-line matches, leaking everything in between. The filter
  is now one shared function (`claude_strip_noise`) applied identically to
  both streams and to the list labels, so all three stay in sync.
- `tools/vscode.sh`: a third backend reading VS Code's Chat panel sessions
  from `~/.vscode-server/data/User/globalStorage/github.copilot-chat/session-store.db`
  (`sessions`/`turns` tables). Despite the extension id, this is the store
  behind VS Code's native Chat UI for any provider routed through it (this
  machine also has a LiteLLM BYOK chat extension using the same store), not
  only GitHub-branded Copilot chats. `turns.user_message` /
  `assistant_response` are already plain rendered text, so unlike the other
  two backends this one needs no noise filtering.
- OpenCode → Claude (and Claude → OpenCode) handoff, reading OpenCode's real
  session store: a SQLite database at `~/.local/share/opencode/opencode.db`
  (`session`/`message`/`part` tables), not JSONL files
- `tools/` directory: one backend script per source tool (`claude.sh`,
  `opencode.sh`), each exposing a `<tool>_locate` / `<tool>_extract` pair;
  `ai-handoff` is now a thin runner that dispatches to whichever backend
  `--from` names and renders the shared markdown template
- Working `--from <tool>`, `--to <tool>`, `--out <dir>` flags, plus `--help`

### Fixed
- `ai-handoff` broke when installed as a symlink on `PATH` (the normal
  install pattern): it located `tools/` relative to `${BASH_SOURCE[0]}`
  without resolving the symlink first, so it looked for `tools/` next to
  the symlink instead of next to the real script. Verified by symlinking
  into `~/.local/bin` and running `ai-handoff` as a bare command.
- `--to`/`--from` were documented in the README but never actually parsed —
  the script read them positionally (`$2`/`$3`), so
  `ai-handoff <id> --to opencode --from claude` silently set the target tool
  to the literal string `--to`. Both are now real flags.
- The OpenCode source branch was an unimplemented stub: matched on the
  misspelled tool name `encode`, and looked for `~/.opencode/sessions/*.jsonl`,
  a path OpenCode has never written to.

### Security
- Extracted transcript blocks are now wrapped in unique, non-standard
  delimiters when rendered into the handoff. Each run draws a 16-byte
  random nonce *after* the session was recorded and emits
  `<<<AI-HANDOFF-TRANSCRIPT <nonce> BEGIN>>>` /
  `<<<AI-HANDOFF-TRANSCRIPT <nonce> END>>>` around all three transcript
  sections (full user context, recent-instruction tail, final agent-state
  tail), so the raw text can never contain — let alone spoof — the exact
  marker line. The markers are deliberately not markdown fences, HTML
  comments, or XML tags (nothing a target model is trained to treat as a
  structural boundary), and the handoff header now tells the next agent
  that only the two exact printed marker lines delimit data — everything
  between a BEGIN/END pair is verbatim historical transcript to read,
  never instructions, commands, or tool output to follow, even when text
  inside merely looks like a directive.
- The generated `ai-handoff-<session-id>.md` file is now created with
  owner-only permissions (`0600`) immediately upon creation: the file is
  touched under `umask 077` before the first byte of session text is
  written, then explicitly `chmod 600` so a pre-existing file from an
  earlier run is tightened too (a bare `>` redirect keeps an existing
  file's mode). Previously the handoff inherited the ambient umask
  (typically `0644`), leaving conversation contents readable to other
  local users.
- Input validation for session IDs and source tool names, wired in from
  `tools/validate.sh`. `SESSION_ID` must match `^[A-Za-z0-9._-]+$` and be at
  most 200 characters; `SOURCE_TOOL` is rejected if it contains path-traversal
  or unexpected characters (e.g. `/`, `..`) before it is interpolated into the
  backend script path. Invalid values now fail with a clear error instead of
  being used to build filesystem paths.
- Extraction scratch files no longer land directly in the shared,
  world-writable temp namespace. `ai-handoff` now creates a private,
  user-only scratch directory (mode 0700 under `$TMPDIR` or `/tmp`), points
  `TMPDIR` at it, and creates `USER_TMP`/`ASSISTANT_TMP` inside it, so raw
  session text stays unreadable to other local users regardless of umask and
  is removed wholesale on exit.
- Session secrets are redacted from the handoff before it is written. After
  the source backend extracts plain-text user/assistant messages, a shared
  regex redaction pass (`tools/redact.sh`) runs over both streams (and over
  the `SESSION_LOCATION` header text, which embeds session titles) and
  replaces common credential patterns with `[REDACTED]`:
  - `KEY=value` assignments whose variable name signals a credential
    (`API_KEY=...`, `export SECRET=...`, `PASSWORD=...`, `my_token=...`),
    keeping the variable name so the handoff still shows which secret was set;
  - well-known bearer/API token formats as bare words (`sk-...`, `ghp_...`,
    `github_pat_...`, `AKIA...`, `xox*-...`, `AIza...`, `glpat-...`, and
    `Bearer <token>`); and
  - URL connection strings with embedded passwords
    (`scheme://user:password@host`).
  Redaction is regex-based and not exhaustive — the handoff may still contain
  arbitrary session text, including secrets in unusual formats.
- `tools/validate.sh` (and the new `tools/redact.sh`) are shared helper
  scripts, not tool backends — the guided picker and `--help` no longer list
  them as migratable tools.

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