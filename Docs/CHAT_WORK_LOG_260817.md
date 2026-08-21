# Chat Work Log - 2026-08-17 Week

### 2026-08-21 20:50 JST - Codex GPT-5 - 種別: 依頼内容 - 画像出力ウィンドウ余白・動画取込・ライブラリフィルタ

```text
☆バグ：画像保存時のウィンドウで、ウィンドウ内のラベル、ボタンなどが、ウィンドウ境界間にマージンがない。
※添付画像参照
☆バグ：ファイルを追加時、動画選択できない。一括フォルダ選択時も、動画が除外される？
☆追加：
・ライブラリ＞テキスト検索ボックの左にファイル種別フィルタをボタンを追加。
　フィルタ項目：種別、ファイル形式
・ライブラリ＞サムネイル、テキスト表示時、表内の解像度の左に「種別」項目を追加し、動画、静止画種別を表示する。
☆バグ：画像上でレイヤ選択時など、マウスの編集モード毎に適切なアイコンカーソルになっていない。ペンツール、消しゴムツールでも、レイヤ範囲にマウス移動した際、手のひらカーソルになってしまう。
☆改善：レイヤ内のマスクをペンツール、消しゴムで修正する際、タブレットペンで書込みした際の反映レスポンスが悪い
```

### 2026-08-21 20:50 JST - Codex GPT-5 - 種別: 作業結果 - v0.0.00138 UI/動画取込/ライブラリフィルタ/マスク編集修正

- 作業AIモデル: Codex GPT-5（実行中モデルを実際には切替不可。UI制約修正、動画取込修正、ライブラリフィルタ実装、マスク編集カーソル/タブレット応答改善、文書同期を同モデルで実施）
- 画像出力ウィンドウの内容をウィンドウ境界から24pt離す明示制約へ変更し、ラベル・入力欄・ボタン・プレビューが端へ貼り付かないよう修正。
- ファイル選択の許可UTTypeを静止画/動画共通 `openableMediaTypes` へ集約し、MOV/MP4がOpen Panelでグレーアウトする環境差へ対策。
- フォルダ一括登録を静止画/動画混在対応へ変更。動画はバックグラウンドで `VideoFrameReader.loadInfo()` により解像度・尺を取得し、`LibraryEngine.importLinkedVideo` で動画項目として登録。
- コードレビュー中に「動画メタ情報取得をメインスレッドで複数回行うとUI停止し得る」P1リスクを確認し、同一作業内でバックグラウンド登録へ修正。
- 静止画用の一括処理は動画を対象外化し、動画項目が静止画パイプラインへ誤投入されないよう修正。
- ライブラリ検索欄左に種別/形式フィルタメニューボタンを追加。種別は「すべて/静止画/動画」、形式はライブラリ内の拡張子から生成。
- ライブラリのテキスト/サムネイル付きリストへ「種別」列を追加し、解像度列の左に「静止画」「動画」を表示。種別列ソートにも対応。
- マスク追加ペン/消しゴム中はROI・人物・骨格レイヤ上でも手のひらカーソルを出さず、ペン/消しゴムカーソルを優先するよう修正。
- タブレットペン入力の高頻度dragイベントに対し、描画中の筆跡プレビューを即時表示し、1.25pt未満の点を間引き、dirty rectを筆跡周辺へ限定して再描画負荷を軽減。
- 回帰テスト `libraryEngineImportsLinkedVideoWithKindAndDuration` を追加。
- 検証: `swift build` PASS、`swift test --filter libraryEngineImportsLinkedVideoWithKindAndDuration` PASS、`swift test` 162件 PASS、`git diff --check` PASS、`scripts/ci/agent_governance_guard.sh` PASS、`scripts/ci/local_quality_gate.sh` PASS、`swift build -c release` PASS。
- パッケージ: `scripts/package_macos_app.sh` PASS。`dist/newMosaic.app` は `CFBundleShortVersionString=0.0.00138` / `CFBundleVersion=138`。
- 署名/起動: `codesign --verify --deep --strict --verbose=2 dist/newMosaic.app` PASS、`open -n dist/newMosaic.app` で `NewMosaicApp` プロセス起動を確認。
- 作業時間: 約80分。
