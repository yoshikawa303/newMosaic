#!/usr/bin/env bash
# ONNXモデルを newMosaic の実行時参照先へ導入する。
#
# モデル（計451MB）はGitHubの100MBファイル上限に掛かるためGit管理外にしてある
# （2026-07-31）。本スクリプトで所定のフォルダへ配置する。
# 一覧・入手元・ライセンスは Docs/MODELS.md を参照。
#
# 使い方:
#   scripts/install_models.sh <モデルを置いたフォルダ>
#   scripts/install_models.sh --verify        # 導入状況の確認のみ
set -euo pipefail

DEST="$HOME/Library/Application Support/newMosaic/Models"
MODELS=(
  censor_detect
  person_detect
  photo_censor_detect
  domain_cls
  anime_seg
  anime_pose
  sam_encoder
  sam_decoder
)

verify() {
  local missing=0
  echo "配置先: $DEST"
  for name in "${MODELS[@]}"; do
    local file="$DEST/$name.onnx"
    if [[ -f "$file" ]]; then
      printf '  [OK]   %-22s %s\n' "$name.onnx" "$(du -h "$file" | cut -f1)"
    else
      printf '  [MISSING] %s\n' "$name.onnx"
      missing=$((missing + 1))
    fi
  done
  if [[ $missing -gt 0 ]]; then
    echo "未導入: ${missing}件。scripts/install_models.sh <フォルダ> で導入してください。"
    return 1
  fi
  echo "すべて導入済みです。"
}

if [[ $# -eq 0 ]]; then
  echo "使い方: $0 <モデルを置いたフォルダ>  または  $0 --verify" >&2
  exit 2
fi

if [[ "$1" == "--verify" ]]; then
  verify
  exit $?
fi

SOURCE="$1"
if [[ ! -d "$SOURCE" ]]; then
  echo "エラー: フォルダが見つかりません: $SOURCE" >&2
  exit 1
fi

mkdir -p "$DEST"
installed=0
for name in "${MODELS[@]}"; do
  src="$SOURCE/$name.onnx"
  if [[ -f "$src" ]]; then
    cp "$src" "$DEST/$name.onnx"
    printf '  導入: %-22s %s\n' "$name.onnx" "$(du -h "$src" | cut -f1)"
    installed=$((installed + 1))
  else
    printf '  スキップ（元ファイル無し）: %s\n' "$name.onnx"
  fi
done
echo "${installed}件を導入しました。"
echo
verify
