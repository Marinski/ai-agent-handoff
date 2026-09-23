#!/bin/bash
echo "API_KEY=secret123" | sed -E 's/(^|[^A-Za-z0-9_])([A-Za-z0-9_]*[_-]?(API[_-]?KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|KEY))[[:space:]]*=[[:space:]]*[^[:space:]].*/\1\2=[REDACTED]/Ig'
echo "export MY_TOKEN=abc-123" | sed -E 's/(^|[^A-Za-z0-9_])([A-Za-z0-9_]*[_-]?(API[_-]?KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|KEY))[[:space:]]*=[[:space:]]*[^[:space:]].*/\1\2=[REDACTED]/Ig'
echo "sk-abcdef1234567890" | sed -E 's/(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{16,}([^A-Za-z0-9_-]|$)/\1[REDACTED]\2/g'
