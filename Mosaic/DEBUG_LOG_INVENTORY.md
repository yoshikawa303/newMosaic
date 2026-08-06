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

## アニメ骨格検出診断（v0.0.00077〜）

- 経路: macOS Unified Logging（subsystem `com.yoshikawa.newMosaic`、category `AnimePose`。上記と同一subsystem）。
- 対象: `AnimePoseEstimator`のモデル出力名（`simcc_x`/`simcc_y`）が想定と一致せず、出力順（first/last）依存のフォールバックを使った場合の警告のみ（コードレビューで検出した潜在的なX/Y座標入れ替わりリスクへの対応）。
- 内容: 警告メッセージのみ。座標・画像内容は記録しない。
- 確認例: `log show --predicate 'subsystem == "com.yoshikawa.newMosaic" AND category == "AnimePose"' --last 10m`
- 削除: アプリ独自ファイルは作成しない。OSのUnified Logging保持方針に従う。

## マスク生成診断（v0.0.00092〜）

- 経路: macOS Unified Logging（subsystem `com.yoshikawa.newMosaic`、category `SegmentMask`。他の診断と同一subsystem）。
- 対象: マスク生成「対象形状」および「対象形状（初期実装・比較用）」の分岐判断。
- 内容: ROIごとの `category`（カテゴリ名）／`crop`（切り出しピクセル寸法）／`rotation`（度）／
  `foreground`（前景抽出の成否）／`fgCoverage`（前景の被覆率）／`saliency`（顕著領域へ切り替えたか）／
  `finalCoverage`（最終マスクの被覆率）と、図形フォールバック時の理由（`noMask`／`cropTooSmall`）。
  **画像内容・ROI座標・ファイル名は記録しない**（数値と分岐名のみ）。
- 目的: 「輪郭が取れず選択範囲を丸ごと塗っている」のか「輪郭は取れているが制限方法で欠けている」のかを、
  推測ではなく実動作で切り分けるため。
- 確認例: `log show --predicate 'subsystem == "com.yoshikawa.newMosaic" AND category == "SegmentMask"' --last 10m`
- 削除: アプリ独自ファイルは作成しない。OSのUnified Logging保持方針に従う。

## 検出後処理診断（v0.0.00101〜）

- 経路: macOS Unified Logging（subsystem `com.yoshikawa.newMosaic`、category `Detection`）。
- 対象: `DetectedROIRefiner.dropOversizedGenitalROIs` の判定（`genitalSize` 行）。
- 記録項目: カテゴリ、検出スコア、ROIの正規化面積、体格基準にした人物領域の面積、面積比、しきい値、人物検出数、判定結果（keep/drop）。
- 目的: 性器の誤検出が残る／正しいROIが消える場合に、しきい値を推測で動かさず実測値で切り分ける。
- 画像内容・ファイルパス・個人情報は記録しない（数値のみ）。
- 確認例: `log show --predicate 'subsystem == "com.yoshikawa.newMosaic" AND category == "Detection"' --last 10m`
- 画面からは ヘルプ＞デバッグ＞デバッグログ で確認できる。

## アプリ側イベントログ・デバッグログ画面（2026-07-25〜）

- 経路: macOS Unified Logging。`Sources/NewMosaicApp/main.swift` の `enum AppLog`（subsystem
  `com.yoshikawa.newMosaic` で上記Vision検出診断と統一。category は `UI`/`Library`/`Export`/`Project`）。
- 対象: アプリ起動、エラーダイアログ表示（`showError`）、プロジェクト読込成否、一括処理の完了件数、
  画像出力の成否・形式、設定初期化の実行。
- 内容: イベント種別・件数・エラーのローカライズ済み説明のみ。画像内容、ファイルパス（`.lastPathComponent`の
  ファイル名のみ許容）、ROI座標等の個人情報は記録しない。
- 参照: ヘルプ＞デバッグ＞デバッグログ（`MosaicWindowController.showDebugLogWindow()`）。
  `OSLogStore(scope: .currentProcessIdentifier)` で自プロセスの直近10分・最大500件を取得し、上記4カテゴリと
  Vision検出診断（`Detection`）をまとめて時刻順に一覧表示する。「書き出し…」でテキストファイルへ保存できる
  （ユーザーからの不具合報告時にログを渡しやすくする目的）。
  `OSLogStore`のシステム全体スキャンによる取得処理はメインスレッドで実行すると数秒単位でUIが
  固まるため、`Task.detached`でバックグラウンド実行する（v0.0.00076〜。取得範囲も1時間→10分へ縮小）。
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

## 自動検出（解析）の診断記録（v0.0.00107〜）

- 目的: GUI報告の切り分けを推測ではなく事実で行う。「どの画像に対して・どの設定で・何が出たか」を1解析ごとに残す。
- 経路: macOS Unified Logging（subsystem `com.yoshikawa.newMosaic`、category `Detection`）。
- 実装: `AnalysisDiagnostics`（MosaicCore）＋ `MosaicWindowController.logAnalysisDiagnostics`。
- 内容:
  - ヘッダ1行: `analysis v=<アプリ版数> file=<ファイル名> md5=<MD5> size=<幅>x<高> domain=<画像種別> threshold=<検出しきい値> maskEngine=<マスク生成方式> categories=[<候補カテゴリ>]`
  - `roiCount=<件数>`
  - ROIごと1行: `roi[NN] <カテゴリ> src=<生成元> x= y= w= h= rot= conf= shape= maskEngine=<個別/inherit> maskThreshold=<個別/inherit>`
- **プライバシー方針の例外**: 本記録のみ、ユーザー要望（2026-07-31）により**ソース画像のファイル名とMD5**を残す。
  同一ファイルかどうかを照合するため。フルパス（フォルダ構成）と画像内容は残さない。
- 確認例: `log show --predicate 'subsystem == "com.yoshikawa.newMosaic" AND category == "Detection"' --last 10m | grep analysis`

## ログの永続化とローテーション（v0.0.00112〜）

- 保存先: `~/Library/Application Support/newMosaic/Logs/`
- 形式: `newMosaic.log`（最新）＋ `newMosaic.1.log` 〜 `newMosaic.4.log`（世代）
- 上限: 1ファイル1MB・最大5世代（`RotatingLogFile.defaultMaxBytes` / `defaultMaxFiles`）
- 退避タイミング: 起動直後・30秒ごと・アプリ終了時
- 経緯: `OSLogStore(scope: .currentProcessIdentifier)` はプロセス内のログしか読めず、
  再起動すると前回分が失われていた。報告は再起動後になることが多いためファイルへ残す。
- デバッグログ画面は「保存済み（前回起動分を含む）＋今回起動分」を連結して表示する。
- 完全ローカルのファイル操作で、外部へは送信しない。
- 削除: デバッグログウィンドウの「消去…」で、保存済みログを世代ファイルごと削除できる（v0.0.00118〜）。
  今回の起動分は `OSLogStore` から物理削除できないが、消去時刻（`debugLogClearedAt`）より前の
  エントリを読み出し側（`fetchCurrentProcessLogText()`）で除外するため、画面上・退避ファイル上は
  完全にクリアされる（v0.0.00126〜。旧方式は退避の復活だけを防いでおり表示に過去ログが残っていた）。
  システム側のUnified Log（Console.app等）には残る。
