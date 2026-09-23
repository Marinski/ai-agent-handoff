#!/usr/bin/env bash
# Verification that tool discovery only collects valid backend scripts.
#
# available_tools_arr() must list a tools/<name>.sh file only when its
# basename matches the tool-name convention (^[a-z][a-z0-9_-]*$) AND the file
# is registered in the trusted manifest (tools/SHA256SUMS) with a matching
# sha256 AND it defines that tool's two required functions (<name>_locate
# and <name>_extract). Stray *.sh files — scratch notes, partial backends,
# renamed copies of an existing backend, uppercase names, and even otherwise
# valid backends that were never registered in the manifest — must never
# surface in the guided picker or the "Available:" hints. A synthetic backend
# that IS registered in the sandbox manifest must still be picked up
# (positive control: discovery cannot just be a hardcoded inventory), while
# an identical but UNREGISTERED backend must be ignored (negative control:
# the manifest integrity gate, not just the name/function checks, decides
# what is collectable).
#
# Drives a private copy of the tree with extra junk backends injected, so
# the real tools/ directory is never touched. Uses `ai-handoff --help`,
# which renders "Available tools: ..." before any backend is sourced or any
# session store is touched.
#
# Usage: bash tests/verify_discovery.sh
# Requires: bash, grep, sed, mktemp.

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

for dep in bash grep sed mktemp; do
    command -v "$dep" >/dev/null 2>&1 || {
        echo "verify_discovery: missing required dependency: $dep" >&2
        exit 1
    }
done
if [[ ! -f "$BIN" || ! -d "$TOOLS" || ! -d "$LIB" ]]; then
    echo "verify_discovery: cannot find ai-handoff, tools/, or lib/ under $ROOT" >&2
    exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ai-handoff-discovery.XXXXXX")"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

TREE="$SANDBOX/tree"
mkdir -p "$TREE"
cp "$BIN" "$TREE/"
cp -r "$TOOLS" "$TREE/tools/"
cp -r "$LIB" "$TREE/lib/"

# Inject non-backend *.sh files alongside the real claude/opencode/vscode
# backends, plus two valid synthetic backends. Each junk file trips exactly
# one of the two discovery filters. cursor.sh is a *registered* synthetic
# backend (matching name + its own required functions + a sandbox-manifest
# entry, added just below) and must be collected — without it, a regression
# that hardcodes the known inventory would pass every check. whale.sh has an
# equally valid name and functions but is deliberately NOT registered in the
# sandbox manifest, so only the manifest gate keeps it out — it must be
# excluded, exactly like an attacker dropping a script into tools/ who has
# not (and cannot) add a trusted manifest entry.
cat > "$TREE/tools/scratch.sh" <<'EOF'
# scratch notes with no backend functions at all
EOF
cat > "$TREE/tools/Backup.sh" <<'EOF'
#!/usr/bin/env bash
Backup_locate() { :; }
Backup_extract() { :; }
EOF
cat > "$TREE/tools/notes.sh" <<'EOF'
#!/usr/bin/env bash
# a renamed copy of an existing backend: it defines the ORIGINAL tool's
# functions, not notes_locate / notes_extract
claude_locate() { :; }
claude_extract() { :; }
EOF
cat > "$TREE/tools/partial.sh" <<'EOF'
#!/usr/bin/env bash
partial_locate() { :; }
# partial_extract is missing
EOF
cat > "$TREE/tools/cursor.sh" <<'EOF'
#!/usr/bin/env bash
cursor_locate() { :; }
cursor_extract() { :; }
EOF
cat > "$TREE/tools/whale.sh" <<'EOF'
#!/usr/bin/env bash
whale_locate() { :; }
whale_extract() { :; }
EOF

# Register cursor.sh in the sandbox manifest using the same checksum
# fallback as the binary (GNU sha256sum, BSD/macOS shasum), so a full valid
# backend added through the documented route is discovered. whale.sh stays
# unregistered.
if command -v sha256sum >/dev/null 2>&1; then
    CURSOR_HASH="$(sha256sum "$TREE/tools/cursor.sh" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
    CURSOR_HASH="$(shasum -a 256 "$TREE/tools/cursor.sh" | cut -d' ' -f1)"
else
    CURSOR_HASH=""
fi
if [[ -z "$CURSOR_HASH" ]]; then
    echo "verify_discovery: need sha256sum or shasum to register cursor.sh in the sandbox manifest" >&2
    FAILURES=$((FAILURES + 1))
else
    printf '%s  cursor.sh\n' "$CURSOR_HASH" >> "$TREE/tools/SHA256SUMS"
fi

echo "== tool discovery only collects valid backends =="

# --help prints "Available tools: <comma-joined list>" on stdout and exits 0
# without sourcing a backend or touching a session store. The `||` guard
# keeps a failure on this pipeline inside the FAILURES accounting instead of
# letting `set -euo pipefail` abort the script mid-run.
AVAIL="$(bash "$TREE/ai-handoff" --help | sed -n 's/^Available tools: //p')" || {
    echo 'FAIL: --help failed to produce an "Available tools:" line' >&2
    FAILURES=$((FAILURES + 1))
    AVAIL=""
}

check 'valid backend discovered (claude)' \
    bash -c '[[ "$1" == *claude* ]]' _ "$AVAIL"
check 'valid backend discovered (opencode)' \
    bash -c '[[ "$1" == *opencode* ]]' _ "$AVAIL"
check 'valid backend discovered (vscode)' \
    bash -c '[[ "$1" == *vscode* ]]' _ "$AVAIL"
check 'valid synthetic backend discovered (cursor)' \
    bash -c '[[ "$1" == *cursor* ]]' _ "$AVAIL"
check 'scratch file with no functions is excluded' \
    bash -c '[[ "$1" != *scratch* ]]' _ "$AVAIL"
check 'uppercase name (fails naming convention) is excluded' \
    bash -c '[[ "$1" != *Backup* ]]' _ "$AVAIL"
check 'renamed copy lacking its own functions is excluded' \
    bash -c '[[ "$1" != *notes* ]]' _ "$AVAIL"
check 'partial backend missing _extract is excluded' \
    bash -c '[[ "$1" != *partial* ]]' _ "$AVAIL"
check 'unregistered backend (whale) is excluded by the manifest gate' \
    bash -c '[[ "$1" != *whale* ]]' _ "$AVAIL"

# The available list is the real tools/ inventory plus the registered
# synthetic backend, and nothing else. Derived (and order-normalized) rather
# than hardcoded so adding a real backend later doesn't turn into a
# misleading tripwire that fails while filtering is perfectly fine.
# whale.sh is intentionally absent: it was never registered in the sandbox
# manifest. Note no file named underscore/glob/etc. can appear here from
# junk, because the manifest gate excludes every unregistered .sh.
EXPECTED="$(
    for f in "$TOOLS"/*.sh; do
        [[ -e "$f" ]] || continue
        basename "$f" .sh
    done
    printf '%s\n' cursor
)"
EXPECTED="$(printf '%s\n' "$EXPECTED" | sort | paste -sd, -)"
ACTUAL="$(printf '%s\n' "$AVAIL" | tr ',' '\n' | sort | paste -sd, -)"
if [[ "$ACTUAL" == "$EXPECTED" ]]; then
    echo 'ok:   available list is exactly the valid backends (real + cursor)'
else
    printf 'FAIL: expected "%s"; got "%s"\n' "$EXPECTED" "$AVAIL" >&2
    FAILURES=$((FAILURES + 1))
fi

echo
if (( FAILURES > 0 )); then
    echo "verify_discovery: $FAILURES check(s) FAILED" >&2
    exit 1
fi
echo 'verify_discovery: all discovery checks passed'