#!/usr/bin/env bash
# End-to-end verification of ai-agent-handoff's secure extraction pipeline.
#
# Drives the real `ai-handoff` binary against synthetic session fixtures inside
# a sandboxed HOME/TMPDIR and asserts the four security properties of the
# extraction flow:
#
#   1. Input validation blocks path traversal (tool name, session id)
#   2. Extraction scratch/temp files are private (created under a 0700 dir,
#      removed on exit)
#   3. The generated handoff file is owner-only (0600)
#   4. Credential patterns (API_KEY=..., Bearer <token>, sk-..., ghp_...,
#      user:password@host URLs, ...) are redacted from the handoff
#   5. The source point refuses any backend whose resolved path escapes
#      tools/ (path_is_within_dir gate before `source`)
#
# Everything runs inside a sandbox under $TMPDIR; nothing touches the real
# $HOME, the real ~/.claude store, or a shared temp namespace. Synthetic
# data only — no real session content, no PII.
#
# Usage: bash tests/verify_security.sh
# Requires the tool's own runtime dependencies: bash, sed, jq, python3, stat,
# mktemp, grep.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
BIN="$ROOT/ai-handoff"
TOOLS="$ROOT/tools"
LIB="$ROOT/lib"

FAILURES=0

check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'ok:   %s\n' "$desc"
    else
        printf 'FAIL: %s\n' "$desc" >&2
        FAILURES=$((FAILURES + 1))
    fi
}

# Asserts a command exits non-zero AND emits the expected message on stderr.
assert_fails_with() {
    local desc="$1" expected="$2"
    shift 2
    local err
    err="$("$@" 2>&1 >/dev/null)" || true
    if [[ -z "$err" ]]; then
        printf 'FAIL: %s (command unexpectedly succeeded)\n' "$desc" >&2
        FAILURES=$((FAILURES + 1))
    elif [[ "$err" != *"$expected"* ]]; then
        printf 'FAIL: %s (expected message containing "%s"; got: %s)\n' \
            "$desc" "$expected" "$err" >&2
        FAILURES=$((FAILURES + 1))
    else
        printf 'ok:   %s\n' "$desc"
    fi
}

# Portable permission string (e.g. 700, 600): GNU stat on Linux, BSD stat on macOS.
mode_of() {
    local p="$1"
    if stat -c '%a' "$p" >/dev/null 2>&1; then
        stat -c '%a' "$p"
    else
        stat -f '%Lp' "$p"
    fi
}

for dep in bash sed jq python3 stat mktemp grep; do
    command -v "$dep" >/dev/null 2>&1 || {
        echo "verify_security: missing required dependency: $dep" >&2
        exit 1
    }
done
if [[ ! -f "$BIN" || ! -d "$TOOLS" || ! -d "$LIB" ]]; then
    echo "verify_security: cannot find ai-handoff, tools/, or lib/ under $ROOT" >&2
    exit 1
fi

# -- Sandbox everything ------------------------------------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ai-handoff-verify.XXXXXX")"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

FAKE_HOME="$SANDBOX/home"
TEST_TMP="$SANDBOX/tmp"
OUT="$SANDBOX/out"
PROBE_TREE="$SANDBOX/probe"
PROBE_OUT="$SANDBOX/probe-out"
PROBE_REPORT="$PROBE_OUT/report.txt"
mkdir -p "$FAKE_HOME/.claude/projects/verify" "$TEST_TMP" "$OUT" "$PROBE_TREE" "$PROBE_OUT"

# Every binary run below keeps HOME/TMPDIR inside the sandbox so nothing can
# reach a real session store or leave scratch files in a shared temp dir.
run_bin() { env HOME="$FAKE_HOME" TMPDIR="$TEST_TMP" bash "$BIN" "$@"; }

# ---------------------------------------------------------------------------
# 1. Input validation blocks traversal
# ---------------------------------------------------------------------------
echo "== 1. input validation blocks traversal =="

assert_fails_with 'rejects path traversal in source tool name (--from ../evil)' \
    'invalid tool name' \
    run_bin 'dummy-session' --from '../evil'

assert_fails_with 'rejects path traversal in source tool name (--from a/b)' \
    'invalid tool name' \
    run_bin 'dummy-session' --from 'a/b'

assert_fails_with 'rejects path traversal in session id (../../etc/passwd)' \
    'invalid session id' \
    run_bin '../../etc/passwd' --from claude

assert_fails_with 'rejects absolute path in session id (/tmp/x)' \
    'invalid session id' \
    run_bin '/tmp/x' --from claude

assert_fails_with 'rejects whitespace in session id' \
    'invalid session id' \
    run_bin 'a b' --from claude

# ---------------------------------------------------------------------------
# Source-path containment gate (path_is_within_dir, from lib/validate.sh).
# Unit-level checks for the gate that makes `source` refuse any backend
# whose fully-resolved location is outside tools/. These cover the boundary
# cases a tool-name regex cannot see: sibling directory names, `..`
# escapes, absolute paths, and symlinks that point outside the designated
# directory.
# ---------------------------------------------------------------------------
# shellcheck source=../lib/validate.sh
source "$LIB/validate.sh"

mkdir -p "$SANDBOX/outside" "$SANDBOX/tools" "$SANDBOX/tools-evil"
printf '#!/usr/bin/env bash\n' > "$SANDBOX/outside/evil.sh"
printf '#!/usr/bin/env bash\n' > "$SANDBOX/tools-evil/fake.sh"

check 'gate: backend inside tools/ is accepted' \
    path_is_within_dir "$TOOLS/claude.sh" "$TOOLS"

check 'gate: any file inside tools/ is accepted (trust decided elsewhere)' \
    path_is_within_dir "$TOOLS/SHA256SUMS" "$TOOLS"

cp "$TOOLS/claude.sh" "$SANDBOX/tools/real-backend.sh"
ln -s real-backend.sh "$SANDBOX/tools/linked-in.sh"
check 'gate: symlink whose target stays inside tools/ is accepted' \
    path_is_within_dir "$SANDBOX/tools/linked-in.sh" "$SANDBOX/tools"

assert_fails_with 'gate: refuses a `..` escape to a real outside file' \
    'resolves outside' \
    path_is_within_dir "$SANDBOX/tools/../outside/evil.sh" "$SANDBOX/tools"

assert_fails_with 'gate: refuses an absolute path outside the dir' \
    'resolves outside' \
    path_is_within_dir /etc/passwd "$SANDBOX/tools"

assert_fails_with 'gate: sibling dir name (tools-evil) cannot pass for tools' \
    'resolves outside' \
    path_is_within_dir "$SANDBOX/tools-evil/fake.sh" "$SANDBOX/tools"

ln -s "$SANDBOX/outside/evil.sh" "$SANDBOX/tools/sneaky-abs.sh"
assert_fails_with 'gate: a tools/ entry that is an absolute symlink outside is refused' \
    'resolves outside' \
    path_is_within_dir "$SANDBOX/tools/sneaky-abs.sh" "$SANDBOX/tools"

ln -s ../outside/evil.sh "$SANDBOX/tools/sneaky-rel.sh"
assert_fails_with 'gate: a tools/ entry that is a relative symlink outside is refused' \
    'resolves outside' \
    path_is_within_dir "$SANDBOX/tools/sneaky-rel.sh" "$SANDBOX/tools"

ln -sf loop-b.sh "$SANDBOX/tools/loop-a.sh"
ln -sf loop-a.sh "$SANDBOX/tools/loop-b.sh"
assert_fails_with 'gate: a symlink loop is refused (fails closed)' \
    'too many symlinks' \
    path_is_within_dir "$SANDBOX/tools/loop-a.sh" "$SANDBOX/tools"

# ---------------------------------------------------------------------------
# Build a synthetic claude session carrying secrets.
# ---------------------------------------------------------------------------
SESSION_ID='verify-9f3c-session'
SESSION_FILE="$FAKE_HOME/.claude/projects/verify/$SESSION_ID.jsonl"
cat > "$SESSION_FILE" <<'JSONL'
{"type":"user","message":{"content":"set API_KEY=verify-alpha-9f3c and launch"}}
{"type":"assistant","message":{"content":"export TOKEN=verify-bravo-9f3c"}}
{"type":"user","message":{"content":"call with Bearer verifycharlie9f3c0123456789 header"}}
{"type":"assistant","message":{"content":"sk-verifydelta9f3c0123456789abcdef ghp_verifyecho9f3c0123456789"}}
{"type":"user","message":{"content":"postgres://alice:verifyfoxtrot9f3c@db.example.com/app"}}
JSONL

# ---------------------------------------------------------------------------
# 3. Final handoff file is 0600  (and the extraction run succeeds end-to-end)
# ---------------------------------------------------------------------------
echo "== 2. end-to-end extraction writes a 0600 handoff =="

HANDOFF="$OUT/ai-handoff-$SESSION_ID.md"
if run_bin "$SESSION_ID" "$OUT" --from claude --to opencode >/dev/null 2>&1; then
    :
else
    echo "FAIL: extraction run exited non-zero" >&2
    FAILURES=$((FAILURES + 1))
fi

check 'handoff file exists' test -f "$HANDOFF"
check 'handoff file is owner-only (0600)' test "$(mode_of "$HANDOFF")" = '600'

# ---------------------------------------------------------------------------
# 4. Secrets are redacted from the handoff
# ---------------------------------------------------------------------------
echo "== 3. secrets are redacted from the handoff =="

check 'redaction markers present ([REDACTED])' grep -Fq '[REDACTED]' "$HANDOFF"
check 'variable name kept, value redacted (API_KEY=[REDACTED])' \
    grep -Fq 'API_KEY=[REDACTED]' "$HANDOFF"

# Every raw secret value injected into the fixture must be gone from the
# handoff, while the surrounding text survives.
LEAKS=(verify-alpha-9f3c verify-bravo-9f3c verifycharlie9f3c0123456789 \
       verifydelta9f3c0123456789abcdef verifyecho9f3c0123456789 \
       verifyfoxtrot9f3c)
for tok in "${LEAKS[@]}"; do
    check "no raw secret leaked ($tok)" \
        bash -c '! grep -Fq "$1" "$2"' _ "$tok" "$HANDOFF"
done

check 'surrounding text preserved (variable context kept)' \
    grep -Fq 'postgres://alice:[REDACTED]@db.example.com/app' "$HANDOFF"

# ---------------------------------------------------------------------------
# 2. Extraction scratch/temp files are private
#
# Deterministic runtime probe: run the real binary from a private copy of the
# tree with an extra probe backend that records, *during* extraction, the
# permissions of the scratch directory and files it is handed. Asserting from
# inside the run avoids any race with the exit-time cleanup.
# ---------------------------------------------------------------------------
echo "== 4. extraction scratch files are private =="

mkdir -p "$PROBE_TREE"
cp "$BIN" "$PROBE_TREE/"
cp -r "$TOOLS" "$PROBE_TREE/tools/"
cp -r "$LIB" "$PROBE_TREE/lib/"
cat > "$PROBE_TREE/tools/securityprobe.sh" <<'PROBE'
#!/usr/bin/env bash
securityprobe_locate() {
    printf 'in-memory probe session\n'
}
securityprobe_extract() {
    local session_id="$1" location="$2" user_out="$3" assistant_out="$4"
    local user_dir assistant_dir
    user_dir="$(dirname "$user_out")"
    assistant_dir="$(dirname "$assistant_out")"
    {
        printf 'TMPDIR=%s\n' "$TMPDIR"
        printf 'USER_DIR=%s\n' "$user_dir"
        printf 'USER_DIR_MODE=%s\n' "$(probe_mode "$user_dir")"
        printf 'USER_FILE_MODE=%s\n' "$(probe_mode "$user_out")"
        printf 'ASSISTANT_DIR=%s\n' "$assistant_dir"
        printf 'ASSISTANT_DIR_MODE=%s\n' "$(probe_mode "$assistant_dir")"
        printf 'ASSISTANT_FILE_MODE=%s\n' "$(probe_mode "$assistant_out")"
    } > "${PROBE_REPORT:?}"
    printf 'API_KEY=verify-probe-9f3c\n' > "$user_out"
    printf 'Bearer verifyprobejwt9f3c0123456789\n' > "$assistant_out"
}
probe_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then
        stat -c '%a' "$1"
    else
        stat -f '%Lp' "$1"
    fi
}
PROBE

if env HOME="$FAKE_HOME" TMPDIR="$TEST_TMP" PROBE_REPORT="$PROBE_REPORT" \
        bash "$PROBE_TREE/ai-handoff" 'probe-session' "$PROBE_OUT" \
        --from securityprobe --to claude >/dev/null 2>&1; then
    :
else
    echo "FAIL: probe extraction run exited non-zero" >&2
    FAILURES=$((FAILURES + 1))
fi

check 'scratch files live under the private TMPDIR' \
    grep -Fq "TMPDIR=$TEST_TMP/ai-handoff." "$PROBE_REPORT"
check 'user scratch dir is private (0700)' \
    grep -Fq '^USER_DIR_MODE=700$' "$PROBE_REPORT"
check 'assistant scratch dir is private (0700)' \
    grep -Fq '^ASSISTANT_DIR_MODE=700$' "$PROBE_REPORT"
check 'user scratch file is owner-only (0600)' \
    grep -Fq '^USER_FILE_MODE=600$' "$PROBE_REPORT"
check 'assistant scratch file is owner-only (0600)' \
    grep -Fq '^ASSISTANT_FILE_MODE=600$' "$PROBE_REPORT"
check 'probe handoff file is owner-only (0600)' \
    test "$(mode_of "$PROBE_OUT/ai-handoff-probe-session.md")" = '600'

# A '.'-containing session id (dots are legal in ids) must stay glued into a
# single filename component inside the output dir — it can never traverse out.
if env HOME="$FAKE_HOME" TMPDIR="$TEST_TMP" PROBE_REPORT="$PROBE_REPORT" \
        bash "$PROBE_TREE/ai-handoff" '..' "$PROBE_OUT" \
        --from securityprobe --to claude >/dev/null 2>&1; then
    :
else
    echo "FAIL: '..' probe run exited non-zero" >&2
    FAILURES=$((FAILURES + 1))
fi
check "session id '..' cannot escape the output dir (file is ai-handoff-...md)" \
    test -f "$PROBE_OUT/ai-handoff-...md"

# The private scratch dir (and everything in it) must be gone after each run.
if ls -d "$TEST_TMP"/ai-handoff.* >/dev/null 2>&1; then
    echo 'FAIL: private scratch dir leaked after exit' >&2
    FAILURES=$((FAILURES + 1))
else
    echo 'ok:   private scratch dir removed on exit (no leftovers)'
fi

# ---------------------------------------------------------------------------
# 5. The source point refuses any backend whose resolved path escapes tools/
#
# End-to-end: a private copy of the tree with a backend that is a symlink to
# a file OUTSIDE tools/, fully vouched for in the sandbox manifest (name
# regex passes, checksum matches the symlink target's actual content). The
# checksum gate alone would let this through — only the resolved-path
# containment gate (path_is_within_dir, wired in before `source`) can stop
# `ai-handoff` from sourcing the outside file.
# ---------------------------------------------------------------------------
echo "== 5. source never resolves outside tools/ =="

ESCAPE_TREE="$SANDBOX/escape"
mkdir -p "$ESCAPE_TREE"
cp "$BIN" "$ESCAPE_TREE/"
cp -r "$TOOLS" "$ESCAPE_TREE/tools/"
cp -r "$LIB" "$ESCAPE_TREE/lib/"
cat > "$SANDBOX/outside/escapetool.sh" <<'ESCAPE'
#!/usr/bin/env bash
escapetool_locate() { printf 'injected outside backend\n'; }
escapetool_extract() { printf 'injected\n' > "$3"; printf 'injected\n' > "$4"; }
ESCAPE
ln -s "$SANDBOX/outside/escapetool.sh" "$ESCAPE_TREE/tools/escapetool.sh"
# Vouch for the symlinked backend in the sandbox manifest using the OUTSIDE
# file's checksum: content verification alone would accept this backend.
# Same checksum fallback as the binary (GNU sha256sum, BSD/macOS shasum), so
# section 5 never hard-depends on GNU coreutils or aborts under `set -e`.
if command -v sha256sum >/dev/null 2>&1; then
    ESCAPE_HASH="$(sha256sum "$SANDBOX/outside/escapetool.sh" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
    ESCAPE_HASH="$(shasum -a 256 "$SANDBOX/outside/escapetool.sh" | cut -d' ' -f1)"
else
    ESCAPE_HASH=""
fi
if [[ -z "$ESCAPE_HASH" ]]; then
    echo "verify_security: need sha256sum or shasum to vouch the section-5 manifest entry" >&2
    FAILURES=$((FAILURES + 1))
else
    printf '\n%s  escapetool.sh\n' "$ESCAPE_HASH" >> "$ESCAPE_TREE/tools/SHA256SUMS"

    assert_fails_with 'source gate: symlinked backend escaping tools/ is refused end-to-end' \
        'resolves outside' \
        env HOME="$FAKE_HOME" TMPDIR="$TEST_TMP" \
        bash "$ESCAPE_TREE/ai-handoff" 'esc-session' "$OUT" --from escapetool --to claude

    check 'source gate: no handoff is written for the refused backend' \
        test ! -e "$OUT/ai-handoff-esc-session.md"
fi

echo
if (( FAILURES > 0 )); then
    echo "verify_security: $FAILURES check(s) FAILED" >&2
    exit 1
fi
echo 'verify_security: all security checks passed'