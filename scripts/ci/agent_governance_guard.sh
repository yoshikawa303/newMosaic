#!/usr/bin/env bash
set -euo pipefail

required=(
  "CLAUDE.md"
  "AGENTS.md"
  "GEMINI.md"
  "SYSTEM_PROMPT_TEMPLATE.md"
  "Mosaic/ARCHITECTURE.md"
  "Mosaic/QUALITY_STATS.md"
  "Mosaic/DEBUG_LOG_INVENTORY.md"
  "CHANGELOG.md"
)

for file in "${required[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "missing required governance file: $file" >&2
    exit 1
  fi
done

if ! grep -q "Docs/CHAT_WORK_LOG_<YYMMDD>.md" CLAUDE.md; then
  echo "CLAUDE.md does not describe chat work log naming" >&2
  exit 1
fi

if ! grep -q "v<MARKETING_VERSION>" CLAUDE.md; then
  echo "CLAUDE.md does not describe release tag convention" >&2
  exit 1
fi

echo "agent governance guard passed"
