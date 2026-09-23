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
if [[ ! -f "$BIN" || ! -d "$TOOLS" ]]; then
    echo "verify_security: cannot find ai-handoff or tools/ under $ROOT" >&2
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
echo
if (( FAILURES > 0 )); then
    echo "verify_security: $FAILURES check(s) FAILED" >&2
    exit 1
fi
echo 'verify_security: all security checks passed'