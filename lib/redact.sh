#!/usr/bin/env bash
# Secret redaction helpers.
# Source this file — do not execute directly.

# Redact common credential patterns from stdin to stdout, before conversation
# text is rendered into the handoff file:
#
#   - KEY=value assignments whose variable name signals a credential
#     (API_KEY=..., SECRET=..., export TOKEN=..., PASSWORD=..., ...). The
#     variable name (and a leading `export` etc.) is preserved so the handoff
#     still shows which secret was set; only the value is replaced with
#     [REDACTED]. Matching is case-insensitive and the keyword must be a
#     name-final component (API_KEY, my_token, ClientSecret all match;
#     SECRETARY=, PASSWORD_HASH= do not).
#   - Well-known bearer/API token formats as bare words: sk-... (OpenAI),
#     ghp_... / github_pat_... (GitHub), AKIA... (AWS access key ID),
#     xox*-... (Slack), AIza... (Google), glpat-... (GitLab), and
#     "Bearer <token>" headers (JWTs, opaque tokens). Tokens are replaced
#     wholesale.
#   - URL connection strings with embedded credentials
#     (scheme://user:password@host) where the password part is replaced.
#
# A word-substring over-match (e.g. `hockey=...` containing "key") is an
# accepted trade-off: preserving the encoded secret is worth more than
# keeping an unusual variable name that merely contains a keyword.
# Line-oriented: a multi-line quoted value (`API_KEY="secret` spanning two
# lines) only has its assignment line redacted.
redact_secrets() {
    sed -E \
        -e 's/(^|[^A-Za-z0-9_])([A-Za-z0-9_]*[_-]?(API[_-]?KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|KEY))[[:space:]]*=[[:space:]]*[^[:space:]].*/\1\2=[REDACTED]/Ig' \
        -e 's/(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{16,}([^A-Za-z0-9_-]|$)/\1[REDACTED]\2/g' \
        -e 's/(^|[^A-Za-z0-9_-])ghp_[A-Za-z0-9]{20,}([^A-Za-z0-9_-]|$)/\1[REDACTED]\2/g' \
        -e 's/(^|[^A-Za-z0-9_-])github_pat_[A-Za-z0-9_]{20,}([^A-Za-z0-9_-]|$)/\1[REDACTED]\2/g' \
        -e 's/(^|[^A-Za-z0-9_-])AKIA[0-9A-Z]{16}([^A-Za-z0-9_-]|$)/\1[REDACTED]\2/g' \
        -e 's/(^|[^A-Za-z0-9_-])xox[abeprs]-[A-Za-z0-9-]{10,}([^A-Za-z0-9_-]|$)/\1[REDACTED]\2/g' \
        -e 's/(^|[^A-Za-z0-9_-])AIza[0-9A-Za-z_-]{30,}([^A-Za-z0-9_-]|$)/\1[REDACTED]\2/g' \
        -e 's/(^|[^A-Za-z0-9_-])glpat-[A-Za-z0-9_-]{16,}([^A-Za-z0-9_-]|$)/\1[REDACTED]\2/g' \
        -e 's/(^|[^A-Za-z0-9_-])(Bearer[[:space:]]+)[A-Za-z0-9._~+/=-]{10,}([^A-Za-z0-9_-]|$)/\1\2[REDACTED]\3/gI' \
        -e 's#([a-zA-Z][a-zA-Z0-9+.-]*://[^/@[:space:]]*:)[^/[:space:]]+@#\1[REDACTED]@#gI'
}

# In-place redaction of one extracted plain-text file. Writes through a temp
# file and renames it, so a partial failure can never leave a truncated file.
redact_file() {
    local f="$1" tmp
    tmp="$(mktemp)"
    redact_secrets < "$f" > "$tmp"
    mv "$tmp" "$f"
}