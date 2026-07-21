# newMosaic Debug Log Inventory

## 現在のログ方針

- 初期MVPではアプリ内の永続デバッグログは未導入。
- ユーザー修正履歴は `HistoryEngine` が JSON として保存する。
- 検証ライブラリは `~/Library/Application Support/newMosaic/Library/` に保存する。
  - `Originals/`: インポートした元画像PNG。
  - `Processed/`: モザイク適用後の検証画像PNG。
  - `index.json`: ライブラリ索引。元画像/加工後画像の相対パス、ROI、画像サイズ、日時を保持する。
- ログ経路を追加した場合は、保存先、個人情報の有無、削除方法を本ファイルへ追記する。
