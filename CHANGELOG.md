# Changelog

## v0.0.00001 - Build 2 - 2026-07-22

■更新履歴（Readme / ChangeLog 用）

- ブラウザ等でコピーした画像を、macOS ペーストボードから直接インポートできるようにした。
- 検証用ライブラリを追加し、元画像とモザイク加工後画像をローカル保存・一覧管理できるようにした。

■更新履歴

- `LibraryEngine` を追加し、`Application Support/newMosaic/Library` 配下に `Originals` / `Processed` / `index.json` を保存する構成にした。
- メイン画面に「画像を貼り付け」「ライブラリ更新」「Finder表示」とライブラリ一覧を追加した。

■更新履歴（画面・機能別）

- macOS: `command + V` または「画像を貼り付け」でクリップボード画像をインポート。
- macOS: ライブラリ一覧から元画像・加工後画像を再表示可能。
- Core: 元画像保存、加工後画像保存、ROI付き索引管理を追加。

■既知の問題（未修正・継続観測）

- ブラウザ側が画像ではなくURL文字列のみをコピーした場合は、現時点では画像として取り込まれない。

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
