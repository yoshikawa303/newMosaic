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

# NSWindow の過剰解放チェック
#
# `isReleasedWhenClosed` は既定が `true` で、閉じるとAppKitがreleaseする。
# アプリ側で `var ...Window: NSWindow?` として強参照していると過剰解放になり、
# 次に参照した時点で解放済みメモリを触って落ちる。
# 2026-08-02 に2度この原因でクラッシュ報告が出たため、機械的に検出する。
# 生成箇所の後ろ40行以内に `isReleasedWhenClosed` が無ければFAILとする。
window_sites=$(grep -n "= NSWindow(" Sources/NewMosaicApp/main.swift | cut -d: -f1 || true)
missing_release_setting=0
for line in $window_sites; do
  end=$((line + 40))
  if ! sed -n "${line},${end}p" Sources/NewMosaicApp/main.swift | grep -q "isReleasedWhenClosed"; then
    echo "NSWindow at main.swift:${line} does not set isReleasedWhenClosed" >&2
    echo "  既定の true のままだと、強参照しているウィンドウが閉じた時点で過剰解放になります。" >&2
    missing_release_setting=1
  fi
done
if [[ $missing_release_setting -ne 0 ]]; then
  exit 1
fi

echo "agent governance guard passed"
