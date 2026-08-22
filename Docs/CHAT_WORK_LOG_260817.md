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

### 2026-08-21 21:20 JST - Codex GPT-5 - 種別: 依頼内容 - ツールバーのフォルダ一括登録アイコン移動

```text
☆ツールバー＞フォルダ一括登録アイコンを「開く」アイコンの右に移動。
```

### 2026-08-21 21:20 JST - Codex GPT-5 - 種別: 作業結果 - v0.0.00139 ツールバー配置調整

- 作業AIモデル: Codex GPT-5（定型的なUI配置変更だが、実行中モデルを実際には切替不可のため同モデルで実施）
- メインツールバーのファイル系アイコン順を `開く` → `フォルダを一括登録` → `貼り付け` に変更。
- `CHANGELOG.md`、`Mosaic/ARCHITECTURE.md`、`scripts/package_macos_app.sh` を v0.0.00139 / Build 139 として同期。
- 検証: `swift build` PASS、`git diff --check` PASS、`bash scripts/package_macos_app.sh` PASS、`codesign --verify --deep --strict --verbose=2 dist/newMosaic.app` PASS、`PlistBuddy` で `0.0.00139` / `139` を確認、`open -n dist/newMosaic.app` で起動確認。
- 作業時間: 約15分。

### 2026-08-21 22:35 JST - Codex GPT-5 - 種別: 依頼内容 - 動画ダブルクリック/解析導線/外部アプリ動画リアルタイム処理確認

```text
☆バグ：ライブラリから動画をダブルクリックした際エラーになる。再生アイコンをクリックするとプレビューウィンドウでは表示。
☆バグ：動画解析できない。動画解析の操作手順を教えて。
☆質問：動画をライブラリにインポート後の解析の他に、Chromeなどの別アプリ内の動画コントロールに表示された無修正動画をリアルタイムにモザイク処理可能？
```

### 2026-08-21 22:35 JST - Codex GPT-5 - 種別: 作業結果 - v0.0.00140 動画編集導線修正

- 作業AIモデル: Codex GPT-5（動画ダブルクリック分岐、動画解析手順メッセージ、保存導線修正、文書同期を同モデルで実施。実行中モデル自体は切替不可）
- ライブラリの動画ダブルクリック/「元画像/動画を開く」操作を、静止画ローダーではなく動画キーフレーム編集モードへ分岐。
- 動画登録直後も、確認用プレビューではなくキャンバス下部タイムライン付き編集モードへ入るよう変更。プレビュー再生はライブラリの再生アイコンに限定。
- 動画追跡/書き出しで手順不足のとき、`自動候補生成→ROI修正→キーフレーム追加→時刻移動→追跡確認→書き出し` の流れが分かるステータスを表示。
- 動画編集中の未保存確認で「保存」を選んだ場合、静止画の加工済み画像ではなく現在時刻の動画キーフレームとして保存するよう修正。
- Chrome等の別アプリ上の動画リアルタイム処理は現行未対応。将来対応する場合は ScreenCaptureKit 等の画面/ウィンドウ取得、ローカル推論、処理済みビュー/オーバーレイ/仮想カメラ出力の別アーキテクチャが必要。DRM/HDCP保護コンテンツは取得・処理できない可能性がある。
- 検証: `swift build` PASS、`swift test` 162件 PASS、`git diff --check` PASS、`scripts/ci/agent_governance_guard.sh` PASS、`scripts/ci/local_quality_gate.sh` PASS。
- パッケージ: `scripts/package_macos_app.sh` PASS。`dist/newMosaic.app` は `CFBundleShortVersionString=0.0.00140` / `CFBundleVersion=140`。
- 署名/起動: `codesign --verify --deep --strict --verbose=2 dist/newMosaic.app` PASS、`open -n dist/newMosaic.app` で `NewMosaicApp` プロセス起動を確認。

### 2026-08-22 00:00 JST - Codex GPT-5 - 種別: 依頼内容 - 動画追跡確認バグ/動画自動処理/動画編集パネル

```text
☆動画
・バグ：ヘルプの通りの操作を行っても、追跡の確認を行っても何も処理されない。
・改善：動画＞自動モザイク処理（指定カテゴリで動画モザイク処理の一覧の操作を自動化、一括処理）
・改善：動画＞動画編集パネル追加
　ー動画関連の編集、コントロールボタンをパネル内に移動
　ーキーフレーム編集(選択／すべて 一括削除）
　ーキーフレーム数
　ー 動画下は、シークバーとシークバー上にキーフレーム位置を表示する。
　ーキーフレームリスト（No、時刻、ROI）
```

### 2026-08-22 00:00 JST - Codex GPT-5 - 種別: 作業結果 - v0.0.00141 動画追跡/編集パネル改善

- 作業AIモデル: Codex GPT-5（追跡起点修正、AppKit動画編集パネル、キーフレーム一覧、シークバーマーカー、動画自動処理、回帰テスト、文書同期を同モデルで実施。実行中モデル自体は切替不可）
- 追跡確認の起点を「現在時刻より前のROI付きキーフレーム」へ修正。2つ目以降のキーフレーム上で追跡確認しても、現在キーフレーム自身を起点にして0秒区間で止まる問題を解消。
- `Video` ログカテゴリを追加し、追跡確認の開始/中止/完了と動画自動処理の開始/完了/失敗を記録。
- 右サイドパネルに「動画編集」パネルを追加。キーフレーム移動、追加/削除、追跡確認、書き出し、動画自動モザイク処理、選択/全キーフレーム削除を集約。
- 動画下部はシークバーと時刻表示のみに整理し、シークバー上へキーフレーム位置マーカーを表示。
- キーフレーム一覧（No、時刻、ROI）を追加し、ダブルクリックで該当時刻へ移動できるようにした。
- 「動画自動モザイク処理」を追加。現在の候補カテゴリ/検出設定で動画全体を一定間隔で解析し、ROIが検出された時刻だけキーフレームを作成。
- 回帰テスト `videoEditStateSelectsStrictPreviousKeyframeForTracking` を追加。
- 検証: `swift build` PASS、`swift test --filter videoEditStateSelectsStrictPreviousKeyframeForTracking` PASS、`swift test` 163件 PASS、`git diff --check` PASS、`scripts/ci/agent_governance_guard.sh` PASS、`scripts/ci/local_quality_gate.sh` PASS、`bash scripts/package_macos_app.sh` PASS、`codesign --verify --deep --strict --verbose=2 dist/newMosaic.app` PASS、`PlistBuddy` で `0.0.00141` / `141` を確認、`open -n dist/newMosaic.app` で起動確認。

### 2026-08-22 00:28 JST - Codex GPT-5 - 種別: 依頼内容 - ライブラリサイドパネル非表示

```text
☆バグ：ライブラリサイドツールパネルがなくなった。設定を初期化しても表示されず。※現在の表示は添付画像参照
```

### 2026-08-22 00:28 JST - Codex GPT-5 - 種別: 作業結果 - v0.0.00142 サイドパネル高さ復元修正

- 作業AIモデル: Codex GPT-5（AppKitサイドパネル復元ロジックの原因調査、修正、文書同期を同モデルで実施。実行中モデル自体は切替不可）
- ライブラリサイドパネルが消えたように見える原因を、動画編集パネル追加後にサイド内高さ配分が現在のパネル数へ更新されず、先頭のライブラリが0px近くまで潰れるレイアウト復元回帰と判断。
- `restoreSplitPositions()` の結果を、幅復元と左右ペイン内高さ復元に分離。幅だけ復元できた場合でも、高さが復元できなかった側は現在のパネル構成に合わせて再配分するよう修正。
- パネルを左右へ移動した直後も、移動元/移動先のサイド内高さを再配分し、ライブラリ/レイヤ/動画編集/インスペクタが見える状態を維持するよう修正。
- 追加確認で、実設定に `Layout.rightPaneHeights = [0, 0, 819]` が残っていることを確認。潰れた高さを保存しない保険と、起動後1ターン遅延での高さ再確認を追加。
- 検証: `swift build` PASS、`git diff --check` PASS、`scripts/ci/agent_governance_guard.sh` PASS、`scripts/ci/local_quality_gate.sh` PASS、`bash scripts/package_macos_app.sh` PASS、`codesign --verify --deep --strict --verbose=2 dist/newMosaic.app` PASS、`PlistBuddy` で `0.0.00142` / `142` を確認、`Layout.rightPaneHeights = [0, 0, 819]` を持つ設定から再起動して `[280, 119, 420]` へ復旧することを確認、スクリーンショット `/tmp/newmosaic-v00142-layout-single.png` でライブラリパネル表示を目視確認。

### 2026-08-22 00:50 JST - Codex GPT-5 - 種別: 依頼内容 - 動画自動モザイク処理クラッシュ

```text
☆バグ：動画自動処理ボタンを押すとアプリが強制終了する。
```

### 2026-08-22 00:50 JST - Codex GPT-5 - 種別: 作業結果 - v0.0.00143 動画自動処理クラッシュ修正

- 作業AIモデル: Codex GPT-5（クラッシュログ解析、Swift Concurrency隔離修正、動画自動処理/追跡/書き出しの共通検出器境界整理、文書同期を同モデルで実施。実行中モデル自体は切替不可）
- 添付クラッシュログの `MosaicWindowController.makeVideoFrameDetector()` → `Array.filter` → `_swift_task_checkIsolatedSwift` から、動画自動モザイク処理がバックグラウンドキューでメインアクター隔離された検出クロージャを呼んでいることを原因と判断。
- 動画フレーム検出器を `@Sendable` な `VideoFrameDetector` として明示し、UI状態を `VideoFrameDetectionConfiguration` へスナップショット化。`nonisolated` static helper で検出クロージャを生成し、フレーム処理中にAppKitオブジェクトへ触れないよう修正。
- 同じ検出器を使う動画書き出し時の自動再検出、追跡確認時の自動再検出も `@Sendable` 境界に合わせて修正。
- リリースアップ: `scripts/package_macos_app.sh` を `0.0.00143` / `143` へ更新し、`CHANGELOG.md`、`Mosaic/ARCHITECTURE.md`、`Mosaic/QUALITY_STATS.md` を同期。
- 検証: `swift build` PASS、`swift test` 163件 PASS、`git diff --check` PASS、`scripts/ci/agent_governance_guard.sh` PASS、`scripts/ci/local_quality_gate.sh` PASS、`bash scripts/package_macos_app.sh` PASS、`codesign --verify --deep --strict --verbose=2 dist/newMosaic.app` PASS、`PlistBuddy` で `0.0.00143` / `143` を確認、`open -n dist/newMosaic.app` で起動確認。

### 2026-08-22 01:50 JST - Codex Codex CLI - 種別: 依頼内容 - 動画編集UI/追跡ROI/自動解析停止改善

- 内容:

  ```text
  ☆バグ：動画のシーク左に再生、一時停止、停止などのコントロールがない。
  ☆バグ：動画追跡した後、ROIのモザイク設定が解除される。
  ☆デグレ：サイドツールパネル内のアイコンが重なって表示される。
  ☆改善：静止画・動画＞自動解析中に画面下のステータス表示の欄に、停止ボタンを表示し、途中で停止可能にする。停止した場合は、停止したところまでのデータを表示。
  ☆改善：動画＞動画編集パネルのキーフレームリストに、「追跡」処理状態を表示「済」など。
  ☆改善：ライブラリ・動画編集サイドツールパネル＞ツールバーのアイコンを改行せず、なるべく１行で表示する。幅が足りない場合に改行し、種別毎にセパレータで分ける
  ☆改善：
  ・動画編集パネル＞キーフレーム数表示は、キーフレーム下に表示。
  ・キーフレーム移動ボタン時、キーフレームリスト上で移動先をアクティブにする。
  ・キーフレームリスト内でキーフレームダブルクリックした際も、キーフレーム移動後、表示キーフレームをリスト上でアクティブにする。
  ・レイヤ：グループ解除の右に、ゴミ箱アイコンを追加し、選択レイヤの削除可能にする。
  ・動画編集＞キーフレーム削除アイコンをゴミ箱にする。（他の同様の操作アイコンと同じイメージ）
  ・全キーフレーム削除アイコンは、修正前のキーフレーム削除アイコンと同じものにする。
  画像添付あり。
  ```

### 2026-08-22 01:50 JST - Codex Codex CLI - 種別: 経過 - モデル/Effort計画

- 内容:

  | 実装内容 | 使用AIモデル | バージョン | Effort | 切替・コスパ判断 |
  |---|---|---|---|---|
  | 動画シーク再生/一時停止/停止UI追加 | OpenAI Codex CLI 現セッションモデル | モデルID非公開 | Medium | 既存動画状態との整合が必要なため現モデルで実施 |
  | 追跡後ROIモザイク保持修正 | OpenAI Codex CLI 現セッションモデル | モデルID非公開 | High | ROI/追跡/保存データのデグレ領域のため現モデルで実施 |
| 自動解析停止と途中結果表示 | OpenAI Codex CLI 現セッションモデル | モデルID非公開 | High | 非同期解析キャンセルと部分結果保持が絡むため現モデルで実施 |
| サイドツール/キーフレームUI整理 | OpenAI Codex CLI 現セッションモデル | モデルID非公開 | Medium | 複数UI部品の一貫性修正のため現モデルで実施 |
| Build/文書/ログ同期 | OpenAI Codex CLI 現セッションモデル | モデルID非公開 | Low | 定型作業だが差分整合のため現セッション内で実施 |

### 2026-08-22 02:11 JST - Codex Codex CLI - 種別: 作業結果 - 動画編集UI/追跡ROI/自動解析停止改善

- 内容:

  **対応完了**
  - `/Volumes/DATA/XCode_Project/newMosaic/Sources/NewMosaicApp/main.swift:449` に折返し対応ツールバーを追加し、サイドパネルのアイコン重なりを修正。
  - `/Volumes/DATA/XCode_Project/newMosaic/Sources/NewMosaicApp/main.swift:3216` で動画編集パネルを整理し、追跡列、削除アイコン変更、キーフレーム件数の下配置を実装。
  - `/Volumes/DATA/XCode_Project/newMosaic/Sources/NewMosaicApp/main.swift:5418` と `/Volumes/DATA/XCode_Project/newMosaic/Sources/NewMosaicApp/main.swift:5618` で動画の再生/一時停止/停止コントロールを追加。
  - `/Volumes/DATA/XCode_Project/newMosaic/Sources/NewMosaicApp/main.swift:5572` と `/Volumes/DATA/XCode_Project/newMosaic/Sources/NewMosaicApp/main.swift:5847` で追跡後もROIモザイク設定を保持。
  - `/Volumes/DATA/XCode_Project/newMosaic/Sources/NewMosaicApp/main.swift:5731` と `/Volumes/DATA/XCode_Project/newMosaic/Sources/NewMosaicApp/main.swift:6113` で動画/静止画解析の停止ボタンを追加。
  - `/Volumes/DATA/XCode_Project/newMosaic/Sources/MosaicVideoKit/VideoEditStore.swift:12` と `/Volumes/DATA/XCode_Project/newMosaic/Tests/MosaicVideoKitTests/VideoEditStoreTests.swift:88` でキーフレーム追跡状態の保存と旧データ互換テストを追加。

  **モデル/Effort実績**
  | 実装内容 | 実際に使用したAIモデル | バージョン | 実績Effort | 切替履歴 | 結果 |
  |---|---|---|---|---|---|
  | 動画シーク再生/一時停止/停止UI追加 | OpenAI Codex CLI 現セッションモデル | モデルID非公開 | Medium | 委譲なし | 完了 |
  | 追跡後ROIモザイク保持修正 | OpenAI Codex CLI 現セッションモデル | モデルID非公開 | High | 委譲なし | 完了 |
  | 自動解析停止と途中結果表示 | OpenAI Codex CLI 現セッションモデル | モデルID非公開 | High | 委譲なし | 完了 |
  | サイドツール/キーフレームUI整理 | OpenAI Codex CLI 現セッションモデル | モデルID非公開 | Medium | 委譲なし | 完了 |
  | Build/文書/ログ同期 | OpenAI Codex CLI 現セッションモデル | モデルID非公開 | Low | 委譲なし | 完了 |

  **検証**
  - `swift build` PASS
  - `swift test` PASS（164 tests）
  - `scripts/ci/agent_governance_guard.sh` PASS
  - `scripts/ci/local_quality_gate.sh` PASS
  - `bash scripts/package_macos_app.sh` PASS、codesign PASS、Info `0.0.00144` / `144`

  **注意**
  - 上位指示によりコミット/プッシュは未実行。未コミット差分があります。
  - AppKit UIの実画面目視は未実施。

- 作業時間: 約25分

### 2026-08-22 02:25 JST - Codex GPT-5 - 種別: 依頼内容 - v0.0.00144 リリース確定

```text
☆下記の他チャットでの実装ありがとう。コミット、リリースアップして。
```

### 2026-08-22 02:25 JST - Codex GPT-5 - 種別: 作業結果 - v0.0.00144 リリース確定

- 作業AIモデル: Codex GPT-5（他チャット未コミット差分の確認、リリース検証、コミット、タグ、pushを同モデルで実施。実行中モデル自体は切替不可）
- 他チャット実装済みの動画編集UI/追跡ROI/自動解析停止改善差分を確認し、`v0.0.00144` / `144` のリリースとして確定する方針にした。
- 検証: `swift build` PASS、`swift test` 164件 PASS、`git diff --check` PASS、`scripts/ci/agent_governance_guard.sh` PASS、`scripts/ci/local_quality_gate.sh` PASS、`bash scripts/package_macos_app.sh` PASS、`codesign --verify --deep --strict --verbose=2 dist/newMosaic.app` PASS、`PlistBuddy` で `0.0.00144` / `144` を確認、`open -n dist/newMosaic.app` で起動確認。
- このエントリを含めてリリースコミットを作成し、`v0.0.00144`タグを付与して `git push origin main --tags` で反映する。

### 2026-08-22 12:01 JST - Codex GPT-5 - 種別: 依頼内容 - サイドパネル操作アイコン間隔圧縮

```text
☆改善：添付画像のツールバーと同様のサイズのアイコンの左右、行間などの間隔が広すぎる。最低限のマージンのみにして。
☆改善：ライブラリリスト下のツールアイコンも動画編集のアイコンと同様に１行表示にする。
```

### 2026-08-22 12:01 JST - Codex GPT-5 - 種別: 作業結果 - v0.0.00145 サイドパネル操作アイコン間隔圧縮

- 作業AIモデル: Codex GPT-5（UIレイアウト調整、版数/文書同期、検証を同モデルで実施。実行中モデル自体は切替不可のため、サブエージェント委譲なし）
- `/Volumes/DATA/XCode_Project/newMosaic/Sources/NewMosaicApp/main.swift` の `WrappingToolbarView` を2pt間隔/18ptセパレータへ圧縮し、幅変更時に高さを再計算するよう変更。
- サイドパネル内のライブラリ/動画編集操作ボタンに32ptのコンパクト枠を適用し、メインツールバーのアイコンサイズ設定とは分けて通常幅で1行に収まるよう調整。
- `scripts/package_macos_app.sh` を `0.0.00145` / `145` へ更新し、`CHANGELOG.md`、`Mosaic/ARCHITECTURE.md`、`Mosaic/QUALITY_STATS.md` を同期。
- 検証: `swift build` PASS（既存のdeprecated/Sendable警告のみ）。追加の品質ゲート、パッケージ、codesignはこの後に実施予定。

### 2026-08-22 12:07 JST - Codex GPT-5 - 種別: 検証結果 - v0.0.00145 サイドパネル操作アイコン間隔圧縮

- 検証: `swift build` PASS（既存のdeprecated/Sendable警告のみ）、`swift test` 164件 PASS、`git diff --check` PASS、`scripts/ci/agent_governance_guard.sh` PASS、`scripts/ci/local_quality_gate.sh` PASS。
- パッケージ: `bash scripts/package_macos_app.sh` PASS、`codesign --verify --deep --strict --verbose=2 dist/newMosaic.app` PASS、`PlistBuddy` で `CFBundleShortVersionString=0.0.00145` / `CFBundleVersion=145` を確認。
- 起動確認: `open -n dist/newMosaic.app` 実行後、画面目視でライブラリ一覧下の8操作アイコンが1行表示、動画編集アイコンも横詰め表示されることを確認。

### 2026-08-22 12:50 JST - Codex GPT-5 - 種別: 依頼内容 - レイヤ表示/詳細チェックボックス重なり修正

```text
☆レイヤの表示、詳細 チェックボックスが、ウィンドウ縮小時重なる。添付画像参照
```

### 2026-08-22 12:50 JST - Codex GPT-5 - 種別: 作業結果 - v0.0.00146 レイヤ表示/詳細チェックボックス重なり修正

- 作業AIモデル: Codex GPT-5（レイヤパネルのAppKitレイアウト修正、版数/文書同期、検証を同モデルで実施。実行中モデル自体は切替不可のため、サブエージェント委譲なし）
- `/Volumes/DATA/XCode_Project/newMosaic/Sources/NewMosaicApp/main.swift` に `WrappingControlRowView` を追加し、テキストラベル付きチェックボックス群を幅不足時にグループ単位で折り返すよう変更。
- レイヤパネルの「表示: ROI/モザイク/人物/骨格」「詳細: 輪郭/タグ」を固定横並びから折り返し行へ変更し、ウィンドウ縮小時の重なりを防止。
- `scripts/package_macos_app.sh` を `0.0.00146` / `146` へ更新し、`CHANGELOG.md`、`Mosaic/ARCHITECTURE.md`、`Mosaic/QUALITY_STATS.md` を同期。
- 検証: `swift build` PASS（既存のdeprecated/Sendable警告のみ）。

### 2026-08-22 12:56 JST - Codex GPT-5 - 種別: 検証結果 - v0.0.00146

- 検証: `swift test` 164件 PASS、`git diff --check` PASS、`bash scripts/ci/agent_governance_guard.sh` PASS、`bash scripts/ci/local_quality_gate.sh` PASS、`bash scripts/package_macos_app.sh` PASS、`codesign --verify --deep --strict --verbose=2 dist/newMosaic.app` PASS。
- `dist/newMosaic.app` の `Info.plist` で `CFBundleShortVersionString=0.0.00146`、`CFBundleVersion=146` を確認。
- `open -n dist/newMosaic.app` でGUI起動し、縮小したアプリ画面でレイヤパネルの「表示:」「詳細:」チェックボックス行が上下に分離し、重ならないことを目視確認。

### 2026-08-22 13:16 JST - Codex GPT-5 - 種別: 依頼内容 - レイヤトグル重なり再修正/動画モザイク適用修正

```text
☆バグ：「「表示:」「詳細:」チェックボックス行が重なる」改善なし。以前はラベルは重ならなかったが、ラベルも重なるようになる。
☆バグ：
・動画の自動設定で、ROI、キーフレーム等設定後、動画を再生しても、モザイク処理が設定され再生されない。全くモザイク処理されていない。
・動画：各キーフレームでモザイク適用しても、再度同じキーフレームを参照するとモザイク設定消えている。
```

### 2026-08-22 13:16 JST - Codex GPT-5 - 種別: 作業結果 - v0.0.00147 レイヤトグル/動画モザイク適用修正

- 作業AIモデル: Codex GPT-5（UIレイアウト再修正、動画モザイク状態保持/プレビュー経路の原因調査、回帰テスト、版数/文書同期を同モデルで実施。実行中モデル自体は切替不可のため、サブエージェント委譲なし）
- `WrappingControlRowView` に実測高さ制約を追加し、幅変更時に行数ぶんの高さを更新して後続行を押し下げるよう修正。チェックボックス/ラベルの内部折返しも抑止。
- 動画編集モードのシーク/再生で、該当キーフレームのROIがありモザイク表示ONの場合に現在フレームへモザイクを即時レンダリングするよう変更。
- 動画編集中の「モザイクを適用」を、静止画保存ではなく現在時刻の `VideoKeyframe` を `VideoEditStore` へ保存する処理へ分岐。
- `VideoKeyframe.resolvingInheritedStyle` / `VideoEditState.resolvingInheritedStyles` を追加し、未設定ROIへ保存時点のモザイク設定を固定する共通処理と回帰テストを追加。
- `scripts/package_macos_app.sh` を `0.0.00147` / `147` へ更新し、`CHANGELOG.md`、`Mosaic/ARCHITECTURE.md`、`Mosaic/QUALITY_STATS.md` を同期。
- 検証: `swift build` PASS（既存のdeprecated/Sendable警告のみ）、`swift test --filter VideoEditStoreTests` 8件 PASS、`swift test` 165件 PASS、`git diff --check` PASS、`agent_governance_guard` PASS、`local_quality_gate` PASS、`scripts/package_macos_app.sh` PASS、署名検証 PASS、`Info.plist` で `0.0.00147` / `147` を確認。
- GUI起動確認は実施したが、複数の既存 `NewMosaicApp` プロセスとmacOS権限ダイアログが前面化に干渉し、v0.0.00147ウィンドウとしての目視確定までは未完了。パッケージの版数と署名は確認済み。
