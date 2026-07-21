# Claude Code / Codex 運用ルール

`CLAUDE.md` は newMosaic の全AI共通の主入口とする。`AGENTS.md` / `GEMINI.md` / `SYSTEM_PROMPT_TEMPLATE.md` は、この文書と `Mosaic/ARCHITECTURE.md` に収束する入口として維持する。

## 1. 毎回の参照順

1. `CLAUDE.md`
2. `Mosaic/ARCHITECTURE.md`
3. `Mosaic/DEBUG_LOG_INVENTORY.md`
4. `CHANGELOG.md`
5. `Mosaic/QUALITY_STATS.md`

- コード修正前に上記を確認する。
- 仕様が衝突した場合は `Mosaic/ARCHITECTURE.md` を正とする。

## 2. 更新義務

- 機能追加・バグ修正後は、`Mosaic/ARCHITECTURE.md` と `Mosaic/QUALITY_STATS.md` を必要に応じて更新する。
- ログ経路・ログ運用を変更した場合は `Mosaic/DEBUG_LOG_INVENTORY.md` を更新する。
- バージョン更新時は `CHANGELOG.md` を更新する。
- コード修正を行うたびに `CURRENT_PROJECT_VERSION` 相当の Build 番号をインクリメントする。
- 明示的なリリースアップ指示がない修正では `MARKETING_VERSION` は維持し、表示リリース番号は `v<MARKETING_VERSION> (beta Build <CURRENT_PROJECT_VERSION>)` とする。
- ローカル build 生成物や一時生成物はソース管理へ残置しない。CLI ビルド成果物は原則 `.build/` または `/Volumes/DATA/XCode_DerivedData/newMosaic/...` に限定する。

## 2.1 チャット作業履歴の記録

- Codex / Claude Code などの AI は、ユーザーから明示されなくても毎回の依頼と対応結果を Markdown で記録する。
- main ブランチでは `Docs/CHAT_WORK_LOG_<YYMMDD>.md` へ追記する。`<YYMMDD>` は週の月曜日の日付とする。
- 1依頼または1作業イベントを1つの `###` 見出しとして時系列に追記する。
- 見出し形式は `### YYYY-MM-DD HH:mm JST - Codex GPT-5 - 種別: <種別> - <見出し>` とする。
- 種別は `依頼内容` / `作業結果` / `経過` / `中断` / `再開` を使う。
- `種別: 依頼内容` はユーザープロンプトを原則そのまま fenced code block に記録する。
- `種別: 作業結果` / `経過` / `中断` / `再開` は、チャット上で返信した内容を Markdown のまま保存する。
- 完了時は最終返信前に `種別: 作業結果` と概算 `作業時間` を記録する。

## 2.2 仕様変更の事前確認

- ユーザー向けの検出対象、マスク範囲、保存形式、AIモデル選択、データ保持方針、UI導線を削除・統合・格下げ・名称変更する場合は、バグ修正中でも実装前に確認を取る。
- 画像・動画・学習履歴などプライバシーに関わる処理は、ローカル処理を既定とし、外部送信を追加する場合は事前確認を必須とする。

## 2.3 コードレビュー結果の品質管理記録

- コードレビューを実施した場合、チャット作業履歴とは別に `Docs/QC/CodeReview/` へ記録する。
- ファイル名は `QC_CodeReview_<リリース番号>.md` とする。
- レビュー対象、バージョン、ブランチ、指示内容、結果、問題点、確認コマンドを記載する。

## 3. バージョン / リリースアップ

- バージョン形式は `0.0.00000` とする。
- 「バージョンアップ」「リリースアップ」は同一手順として扱う。
- 種別指定なしはパッチ値のみインクリメントする。
- リリースアップ依頼時は以下を1タスクとして扱う。
  1. `MARKETING_VERSION` と `CURRENT_PROJECT_VERSION` を更新する。
  2. `CHANGELOG.md` と運用文書を同期する。
  3. テストと品質ゲートを実行する。
  4. 日本語本文のリリースコミットを作成する。
  5. `v<MARKETING_VERSION>` タグを付与する。
  6. `git push origin main --tags` でブランチとタグを同時に push する。
  7. `git show --no-patch --decorate --oneline v<MARKETING_VERSION>` と `git ls-remote --tags origin v<MARKETING_VERSION>` でタグ一致を確認する。

## 4. テスト / 品質ゲート

- Swift コアロジック変更時は `swift test` を実行する。
- macOS アプリ導線変更時は `swift build` とアプリ起動確認を実行する。
- リリース前は `scripts/ci/agent_governance_guard.sh` と `scripts/ci/local_quality_gate.sh` を実行する。
- FAIL がある場合は修正完了として報告しない。

## 5. AI / 画像処理の設計基準

- UI と AI / 画像処理は分離する。
- 初期MVPは静止画を対象にし、動画・SAM2・ONNX Runtime・CoreML は交換可能な境界を維持して段階導入する。
- 完全自動ではなく、人が数秒で確認・修正できる半自動処理を目標とする。
- 画像はローカルで処理し、修正履歴もローカル保存を既定とする。
