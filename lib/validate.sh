#!/usr/bin/env bash
# Input validation helpers for tool names and session IDs.
# Source this file — do not execute directly.

validate_tool_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-z][a-z0-9_-]*$ ]]; then
        printf 'validate_tool_name: invalid tool name "%s" (must match ^[a-z][a-z0-9_-]*$)\n' \
            "$name" >&2
        return 1
    fi
}

validate_session_id() {
    local id="$1"
    if [[ ! "$id" =~ ^[A-Za-z0-9._-]+$ ]]; then
        printf 'validate_session_id: invalid session id "%s" (must match ^[A-Za-z0-9._-]+$)\n' \
            "$id" >&2
        return 1
    fi
    if (( ${#id} > 200 )); then
        printf 'validate_session_id: session id too long (%d chars, max 200)\n' \
            "${#id}" >&2
        return 1
    fi
}

# Fail unless <file>'s fully-resolved path (every symlink followed, down to
# the final component) is located inside <dir>, which is likewise resolved to
# its real location. Ran immediately before a path derived from input is
# handed to `source`, so it compares actual locations rather than literal
# strings: a <file> that escapes via `..`, an absolute path, a
# sibling-directory lookalike, or a symlink pointing out of <dir> is refused
# even when its container entry looks correct. Fails closed — an empty
# argument, a missing file, or an unresolvable directory is a refusal, never
# a pass.
path_is_within_dir() {
    local file="${1:-}" dir="${2:-}"
    local resolved_dir resolved_file d base target hops
    [[ -n "$file" && -n "$dir" ]] || {
        printf 'path_is_within_dir: requires <file> <dir>\n' >&2
        return 1
    }
    resolved_dir="$(cd -P "$dir" 2>/dev/null && pwd)" || {
        printf 'path_is_within_dir: cannot resolve directory "%s"\n' "$dir" >&2
        return 1
    }
    # Follow every symlink in <file> (parent components and the file itself).
    # A symlink loop is a refusal, not an infinite loop.
    resolved_file="$file"
    hops=0
    while [[ -L "$resolved_file" ]]; do
        (( hops += 1 ))
        if (( hops > 40 )); then
            printf 'path_is_within_dir: too many symlinks resolving "%s"\n' "$file" >&2
            return 1
        fi
        d="$(cd -P "$(dirname "$resolved_file")" 2>/dev/null && pwd)" || {
            printf 'path_is_within_dir: cannot resolve "%s"\n' "$resolved_file" >&2
            return 1
        }
        base="$(basename "$resolved_file")"
        target="$(readlink "$d/$base")" || {
            printf 'path_is_within_dir: cannot read symlink "%s"\n' "$resolved_file" >&2
            return 1
        }
        [[ "$target" == /* ]] || target="$d/$target"
        resolved_file="$target"
    done
    [[ -e "$resolved_file" ]] || {
        printf 'path_is_within_dir: "%s" does not exist\n' "$file" >&2
        return 1
    }
    d="$(cd -P "$(dirname "$resolved_file")" 2>/dev/null && pwd)" || {
        printf 'path_is_within_dir: cannot resolve "%s"\n' "$resolved_file" >&2
        return 1
    }
    resolved_file="$d/$(basename "$resolved_file")"
    if [[ "$resolved_file" == "$resolved_dir"/* ]]; then
        return 0
    fi
    printf 'path_is_within_dir: "%s" resolves outside "%s"\n' "$file" "$dir" >&2
    return 1
}
