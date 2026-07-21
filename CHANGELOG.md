# Changelog

## v0.0.00001 - Build 1 - 2026-07-22

■更新履歴（Readme / ChangeLog 用）

- newMosaic macOS MVP の初期リリース。
- 静止画読み込み、ROI候補生成、手動ROI追加、モザイク適用、PNG保存の基盤を追加。

■更新履歴

- maruPlay 由来のAI共同開発、チャットログ、品質管理、リリース運用ルールを newMosaic 向けに移植。
- UI と画像処理を分離した Swift Package 構成を追加。

■更新履歴（画面・機能別）

- macOS: 画像を開く、候補生成、モザイク適用、保存。
- Core: ROI生成、マスク生成、モザイク生成、履歴保存。

■既知の問題（未修正・継続観測）

- MediaPipe、SAM2、ONNX Runtime は初期MVPでは未接続。
- 動画対応は未実装。
