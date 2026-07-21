# newMosaic アーキテクチャ

## 1. 目的

newMosaic は、画像・動画のモザイク作業を完全自動化ではなく半自動化し、人間の作業時間を80%以上削減することを目標とする。

## 2. MVP 範囲

- 対象: 実写静止画
- 優先OS: macOS
- 将来対応: Windows、動画、CoreML、Android、iPhone
- 方針: UI と AI / 画像処理を完全分離し、モデル交換可能な境界を維持する。

## 3. パイプライン

1. `ImageLoader`: 画像読み込み
2. `PersonDetector`: 人物領域抽出
3. `PoseEstimator`: 骨格または姿勢ヒント抽出
4. `ROIGenerator`: 腰・脚・姿勢情報から探索範囲生成
5. `CandidateDetector`: ROI 内の詳細候補生成
6. `SegmentEngine`: 候補範囲からマスク生成
7. `MosaicEngine`: モザイク描画
8. `HistoryEngine`: ユーザー修正履歴保存

## 4. 初期実装方針

- 初期MVPは外部モデルを必須にしない。
- macOS 標準の Vision / CoreImage / AppKit で動作する最小構成を先に成立させる。
- `PersonDetector` / `PoseEstimator` / `SegmentEngine` はプロトコルで抽象化し、後続で MediaPipe、ONNX Runtime、SAM2、CoreML へ差し替え可能にする。
- 自動ROIは補助候補であり、ユーザーの手動矩形追加・削除を必ず可能にする。

## 5. プライバシー

- 画像、生成マスク、修正履歴はローカル処理・ローカル保存を既定とする。
- 外部API送信、クラウド学習、遠隔ログ送信は明示承認なしに追加しない。

## 5.1 検証ライブラリ

- ブラウザ等からコピーした画像は、macOS ペーストボード経由でインポートできる。
- インポート画像は `Application Support/newMosaic/Library/Originals/` へ PNG として保存する。
- モザイク適用後の検証画像は `Application Support/newMosaic/Library/Processed/` へ PNG として保存する。
- ライブラリ索引は `Application Support/newMosaic/Library/index.json` を正とし、元画像、加工後画像、ROI、画像サイズ、更新日時を管理する。
- ライブラリ保存は検証・再確認用途であり、外部送信は行わない。

## 6. 品質基準

- 静止画処理時間の目標は3秒以内。
- 保存結果が元画像と同じキャンバスサイズで出力されること。
- 自動候補が不十分な場合でも、手動ROIで作業を完了できること。
- ペーストボードから取り込んだ画像は、元画像と加工後画像がライブラリに残ること。
- テスト対象は、ROI生成、マスク生成、モザイク処理、履歴保存を最優先とする。

## 7. リリース運用

- バージョン形式は `0.0.00000`。
- Build 番号はコード変更ごとに増やす。
- リリースコミットには `CHANGELOG.md` と品質ゲート結果を含める。
- リリースタグは `v<MARKETING_VERSION>`。
- リリース前に `swift test`、`swift build`、`scripts/ci/local_quality_gate.sh`、`scripts/ci/agent_governance_guard.sh` を実行する。

## 8. Markdown 文書配置

- ルート直下の Markdown は AI / CI 入口文書と `CHANGELOG.md` に限定する。
- 実装準拠の主要仕様、品質台帳、ログ台帳は `Mosaic/` 配下で管理する。
- チャット作業履歴と品質レビューは `Docs/` 配下で管理する。
