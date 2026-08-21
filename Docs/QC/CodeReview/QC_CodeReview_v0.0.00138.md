# QC Code Review - v0.0.00138

- 日時: 2026-08-21 20:55 JST
- ブランチ: main
- 対象: 画像出力ウィンドウ余白、動画ファイル/フォルダ取込、ライブラリ種別/形式フィルタ、種別列、マスク編集カーソル、タブレット入力レスポンス、関連テスト/文書
- 作業AIモデル: Codex GPT-5（実行中モデルの実切替不可）

## レビュー結果一覧

| 優先度 | レビュー回 | 箇所 | 問題 | 修正案/対応 | 状態 |
| --- | --- | --- | --- | --- | --- |
| P1 | 1回目 | `Sources/NewMosaicApp/main.swift` `registerFolderAsLinks()` | 動画の尺・解像度取得をメインスレッドで複数ファイル分実行すると、動画フォルダ登録時にUIが固まる可能性がある。 | フォルダ内メディア列挙後、登録処理を `DispatchQueue.global(qos: .userInitiated)` へ移動。バックグラウンド側で `LibraryEngine(rootURL:)` を再生成し、完了後にメインスレッドで一覧更新・ステータス表示。 | 修正済み |
| P2 | 1回目 | `libraryFileFormat(for:)` | コピー取り込み画像はライブラリ内部でPNG化されるため、内部保存パスを見ると元JPG等もPNGとしてフィルタ表示される。ユーザーが見ているファイル形式とずれる。 | `sourceName` の拡張子を優先し、無い場合のみリンク先/内部パスを参照するよう変更。 | 修正済み |
| - | 2回目 | 差分全体 | P0/P1/P2の新規指摘なし。`swift build` のSendable警告は既存動画書き出し/動画単体取込経路の既知警告のみ。今回追加したバックグラウンドフォルダ登録由来のactor隔離警告は解消済み。 | 追加対応なし。 | 指摘なし |
| P1 | 3回目 | `ImageCanvasView.applyHoverCursor` | ROI上のヒット判定が操作モードより優先され、マスク追加ペン/消しゴムでもopenHandカーソルになる。ユーザーが現在の編集モードを誤認する。 | 画像内かつ `interactionMode.editsMask` の場合は、ROI/人物/骨格レイヤのヒット判定より先にペン/消しゴムカーソルを設定する。Option反転も同じ判定で反映。 | 修正済み |
| P2 | 3回目 | `ImageCanvasView` マスクストローク入力 | タブレットペンの高頻度drag入力で全点を保持し、キャンバス全体再描画に近い更新になると筆跡反応が悪化する。 | ドラッグ中は軽量な筆跡プレビューを描画し、dirty rectを筆跡周辺に限定。画面上1.25pt未満の連続点を間引き、確定時だけ `ManualMaskStroke` として保存。 | 修正済み |
| - | 4回目 | 差分全体 | P0/P1/P2の新規指摘なし。カーソル/ストローク処理の追加後も新規コンパイル警告なし。 | 追加対応なし。 | 指摘なし |

## 確認コマンド

- `swift build` PASS
- `swift test --filter libraryEngineImportsLinkedVideoWithKindAndDuration` PASS
- `swift test` PASS（162 tests）
- `bash scripts/ci/local_quality_gate.sh` PASS
- `swift build -c release` PASS
- `bash scripts/package_macos_app.sh` PASS（`dist/newMosaic.app`）
- `codesign --verify --deep --strict --verbose=2 dist/newMosaic.app` PASS
- `PlistBuddy` で `CFBundleShortVersionString=0.0.00138` / `CFBundleVersion=138` を確認
- `open -n dist/newMosaic.app` 後、`pgrep -fl 'NewMosaicApp|newMosaic'` でプロセス起動確認
- `git diff --check` PASS

## 残リスク

- 添付画像と同一環境での「画像出力」ウィンドウ目視確認、Finder Open Panel上でのiCloud未ダウンロード動画の選択可否はGUI実操作で最終確認が必要。コード上は動画UTTypeの許可範囲を拡張済み。
