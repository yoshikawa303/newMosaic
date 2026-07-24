# newMosaic Debug Log Inventory

## 現在のログ方針

- アプリ独自の永続デバッグログファイルは無い。macOS Unified Logging（syslogの後継。`os.Logger`）へ出力し、
  アプリ内の「ヘルプ＞デバッグ＞デバッグログ」ウィンドウから直近分をその場で参照・書き出しできる（2026-07-25〜）。
- ユーザー修正履歴は `HistoryEngine` が JSON として保存する。
- 検証ライブラリは `~/Library/Application Support/newMosaic/Library/` に保存する。
  - `Originals/`: インポートした元画像PNG。
  - `Processed/`: モザイク適用後の検証画像PNG。
  - `index.json`: ライブラリ索引。元画像/加工後画像の相対パス、ROI、画像サイズ、日時を保持する。
- ログ経路を追加した場合は、保存先、個人情報の有無、削除方法を本ファイルへ追記する。

## Vision検出診断（Build 48〜）

- 経路: macOS Unified Logging（subsystem `com.yoshikawa.newMosaic`、category `Detection`）。
- 対象: 人物インスタンスマスク、補完人物矩形、人物別スケール済みマスク、骨格、顔起点フォールバックのVisionエラー。
- 内容: エラー種別とローカライズ済み説明。入力画像、画像パス、ROI座標、人物情報は記録しない。
- 確認例: `log show --predicate 'subsystem == "com.yoshikawa.newMosaic" AND category == "Detection"' --last 10m`
- 削除: アプリ独自ファイルは作成しない。OSのUnified Logging保持方針に従う。

## アプリ側イベントログ・デバッグログ画面（2026-07-25〜）

- 経路: macOS Unified Logging。`Sources/NewMosaicApp/main.swift` の `enum AppLog`（subsystem
  `com.yoshikawa.newMosaic` で上記Vision検出診断と統一。category は `UI`/`Library`/`Export`/`Project`）。
- 対象: アプリ起動、エラーダイアログ表示（`showError`）、プロジェクト読込成否、一括処理の完了件数、
  画像出力の成否・形式、設定初期化の実行。
- 内容: イベント種別・件数・エラーのローカライズ済み説明のみ。画像内容、ファイルパス（`.lastPathComponent`の
  ファイル名のみ許容）、ROI座標等の個人情報は記録しない。
- 参照: ヘルプ＞デバッグ＞デバッグログ（`MosaicWindowController.showDebugLogWindow()`）。
  `OSLogStore(scope: .currentProcessIdentifier)` で自プロセスの直近1時間分を取得し、上記4カテゴリと
  Vision検出診断（`Detection`）をまとめて時刻順に一覧表示する。「書き出し…」でテキストファイルへ保存できる
  （ユーザーからの不具合報告時にログを渡しやすくする目的）。
- 確認例（Terminal）: `log show --predicate 'subsystem == "com.yoshikawa.newMosaic"' --last 1h`
- 削除: アプリ独自ファイルは作成しない（書き出しを行った場合はそのテキストファイルをユーザーが管理）。
  OSのUnified Logging保持方針に従う。

## 検出モデルキャッシュ（Build 34〜）

- 保存先: `~/Library/Application Support/newMosaic/Models/`
  - `censor_detect.onnx` / `person_detect.onnx` / `photo_censor_detect.onnx` / `domain_cls.onnx` / `anime_seg.onnx` / `anime_pose.onnx`: アプリ同梱の検出・分類・セグメンテーション・骨格モデルの内蔵ディスクキャッシュ（初回のみコピー）。
- 目的: アプリ本体がリムーバブルボリューム上にある場合の、macOSリムーバブルボリューム許可ダイアログ（毎ビルド再表示）の回避。
- 個人情報: 含まない（モデルファイルのみ）。
- 削除方法: `Models/` フォルダを削除すれば次回起動時に再コピーされる。

## ローカル学習ストア（Phase 4, Build 13〜）

- 保存先: `~/Library/Application Support/newMosaic/Learning/`
  - `samples.jsonl`: 選択サンプル（ROI矩形・カテゴリ・形状・人物相対座標・知覚ハッシュ64bit・正負ラベル・日時・source）。1行1サンプルの追記型。
  - `stats.json`: カテゴリ別の位置頻度グリッド（8x8、人物相対/画像相対）と平均サイズの集計。保存時に再計算。
  - `Patches/Positives/` / `Patches/Negatives/`: ROIパッチ画像PNG（最大256pxに縮小）。将来の部位検出モデル学習データを兼ねる。
- 個人情報: モザイク対象範囲の画像断片を含む。**外部送信は一切行わない**（ARCHITECTURE §5 準拠）。
- 削除方法: `Learning/` フォルダを削除すれば学習データは完全に消去され、アプリは空の状態から再学習する。
