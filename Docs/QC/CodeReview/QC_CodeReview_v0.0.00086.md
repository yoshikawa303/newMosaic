# newMosaic コードレビュー記録 v0.0.00086

## 対象

- ブランチ: `main`
- 実施日: 2026-07-27
- 指示内容:
  1. アプリ終了・起動時のUIレイアウト等の保存/復元の問題、およびその他の状態保存系の問題を、
     すべて洗い出されるまで複数回コードレビューする。
  2. サイドツールパネル内の各詳細設定UIについて、レイアウト可変時の崩れ、実装方法の揺れ、
     マージン処理の問題をコードレビューで確認する。
- 対象範囲: `Sources/NewMosaicApp/main.swift`（全7800行超・全文）、`Sources/MosaicCore/LibraryEngine.swift`

## レビュー体制

- レビューA（状態保存・復元）／レビューB（サイドパネルUI統一性）を独立した2エージェント（Claude、`general-purpose`）で並列実施。
  各レビューはパス1（全体走査）→パス2（疑わしい箇所の再読）→パス3（各指摘の実コード再確認による誤検出排除）の3パス構成。
- 主担当（本エージェント）が全指摘を該当行の再読で裏取りしてから修正を実施。

## 指摘・修正一覧

| 回 | 優先度 | 問題点 | 該当箇所 | 修正内容 | 状態 |
|---:|:---:|---|---|---|:---:|
| A-1 | P2 | ウィンドウ枠が「ズーム（緑ボタン/タイトルバーのダブルクリック）」では保存されない。`windowDidEndLiveResize`はドラッグ操作でしか発火せず、終了時の明示保存も無かった（分割位置はv0.0.00084で明示保存化済みだが、ウィンドウ枠は取り残されていた） | `main.swift` `NSWindowDelegate`拡張 / `applicationShouldTerminate` | `windowDidResize`でも保存し、さらに終了直前に現在のフレームを明示保存する | 修正済み |
| A-2 | P2 | 保存されたウィンドウ枠を復元する際に画面外クランプが無い。外部ディスプレイを外す・解像度変更後の起動でウィンドウが画面外に開き、UIから戻す手段が無い | `main.swift` `applicationDidFinishLaunching` | `frameClampedToVisibleScreen`を新設し、重なり面積が最大の画面の可視領域へサイズ・位置をクランプ。どの画面とも重ならない場合は既定位置へフォールバック | 修正済み |
| A-3 | P2 | 「自動候補生成」「自動保存」チェックが永続化されておらず、再起動で既定へ戻る（他の全ユーザー設定は永続化されている中でこの2つだけ） | `main.swift` `autoGenerateCheckbox`/`autoSaveCheckbox` | `Workflow.autoGenerate`/`Workflow.autoSave`として保存・復元（`workflowOptionChanged`/`loadWorkflowOptions`） | 修正済み |
| B-1 | P1 | 候補カテゴリの`NSGridView`に幅上限が無く、サイドパネルを広げるとチェックボックス列の間隔が広がる（`styleGrid`では同じ問題を対策済みだが、こちらは未対策で再発） | `main.swift` `makeInspectorPanel`の`categories` | `styleGrid`と同じ`widthAnchor`上限（362pt）を追加 | 修正済み |
| B-2 | P1 | レイヤ/ライブラリパネルのタイトルだけ左右マージン12pt、他の子ビューは8ptで4ptずれる | `main.swift` `makeLayerPanel`/`makeLibraryPanel` | タイトルの定数を多数派の8ptへ統一 | 修正済み |
| B-3 | P1 | インスペクタを含むペインの最小幅（160pt）が、パターンプレビュータイル（44pt×4＋ラベル列）の必須制約が要求する幅より狭く、狭めると制約違反・はみ出しが起きうる | `main.swift` `splitView(_:constrainMinCoordinate:...)` | `minimumWidth(forPane:)`を新設し、インスペクタを含むペインのみ最小幅340ptへ引き上げ | 修正済み |
| B-4 | P2 | 「候補カテゴリ」「表示レイヤ生成」の2見出しだけ生の`NSTextField`で、見出しスタイルが適用されず、テキストサイズ変更にも追従しない | `main.swift` `makeInspectorPanel`のcontent配列 | `inspectorHeading(_:)`経由へ統一 | 修正済み |
| B-5 | P2 | テキストサイズ変更時の値ラベル再適用リストから「並行揺れ」「形状しきい値」の2つが漏れ、サイズ変更後に他の数値ラベルと大きさが揃わない | `main.swift` `textSizeChanged` | 漏れていた2ラベルを配列へ追加 | 修正済み |
| B-6 | P2 | 数値スライダー8個にツールチップが無く、設定行によってホバーヘルプが出たり出なかったりする | `main.swift` `configureMosaicStyleControls` | 全数値スライダーへ説明文つきツールチップを一括設定 | 修正済み |
| B-7 | P2 | VoiceOverラベルがツールバーアイコンにしか設定されておらず、スライダー等は「スライダー、値50%」としか読まれない | `main.swift` `inspectorRow` / `configureMosaicStyleControls` | `inspectorRow`が行ラベルをコントロールのVoiceOverラベルへ自動反映。スタイル系スライダー・カラーウェルにも設定 | 修正済み |
| A-4 | P3(参考記録) | パネルを左右へ移動した直後にクラッシュ/強制終了した場合のみ、そのペインの高さ配分が失われる（正常終了時は`saveSplitPositionsNow`で自己修復するため実害なし） | `main.swift` `restoreSplitPositions` | 未対応（異常終了時の未保存状態は許容範囲と判断） | 未対応 |
| A-5 | P3(参考記録) | 旧UserDefaultsからの移行キー一覧に`Layout.`等が含まれない（移行期は既に経過済みで現行ユーザーへの影響なし） | `main.swift` `migratedKeyPrefixes` | 未対応 | 未対応 |
| B-8 | P3(参考記録) | 行ラベルのスタイルが3系統（見出し/設定行ラベル/レイヤパネルの「表示:」）に分裂、セグメントコントロールの基準フォントが11/12/13ptでばらつく、スライダー幅の定数がコピペで二重管理 | `main.swift`（複数箇所） | 未対応（機能影響なし。推奨統一ルールを本記録へ残し、今後の新規実装で適用） | 未対応 |

### 誤検出として排除した指摘（パス3で確認）

- `AppSettings`の`set(Double)`↔`as? Int`等の型不一致: 実機のFoundationで`NSNumber`が両方向に寛容に橋渡しされ、実際に使用中の全キー・型の組み合わせで欠落・破損なしを確認。
- 分割ペイン高さ配列の件数不一致: 正常終了時は`saveSplitPositionsNow`が移動後の`arrangedSubviews`を基準に保存し直すため自己修復する（上記A-4として参考記録に格下げ）。
- 終了時にウィンドウが閉じてフレームが0になる懸念: Cmd+Qは`applicationShouldTerminate`へ直行し、ウィンドウは閉じられないため発生しない。
- `isRestoringSplitPositions`フラグ: 全呼び出し箇所で`wasRestoring`＋`defer`により正しく入れ子対応済み。
- `PerImageEditState`: 設計どおりセッション限りの高速切替用キャッシュ（永続化対象のROIは`LibraryEngine`側で保存済み）。

## 推奨統一ルール（今後の新規UI実装で適用）

1. 1設定行は必ず`inspectorRow(title:control:trailing:)`を経由する（生の`NSTextField`＋`NSStackView`で組まない）。
2. ラベル列は13pt・`.secondaryLabelColor`・最小幅78pt（固定幅にしない）。
3. 行内のラベル-コントロール間は8pt、セクション内の行間は7pt。
4. スライダーは「最小80／最大220（必須）／希望160（優先度400）」の3点セット。
5. 数値ラベルは幅48・左寄せ・等幅数字11pt。**かつ**`textSizeChanged`の再適用配列へ必ず登録する。
6. `NSGridView`を使う場合は必ず`widthAnchor`の上限を明示する（leading整列スタック内で伸長するため）。
7. パネル全体は「単一`NSStackView`＋`edgeInsets`」方式（`makeInspectorPanel`方式）に寄せ、手書きの個別制約でマージンを並べない。
8. 数値系コントロールにはツールチップを必ず設定する。VoiceOverラベルは`inspectorRow`が自動反映する。

## 確認

- `swift build`: PASS
- `swift test`: 84/84 PASS（既存79＋動画編集ストア5）
- `bash scripts/ci/agent_governance_guard.sh`: PASS
- `bash scripts/ci/local_quality_gate.sh`: PASS
- GUI確認: ユーザー確認事項（本エージェントはGUI操作を行わない運用のため）

## 結論

2レビュー（各3パス）で計13件を検出。うちP1×3・P2×7の10件を修正し、3件（異常終了時の未保存・移行期経過済みの historical 項目・機能影響のない実装揺れ）は理由を明記して見送った。
見送り分のうち実装揺れについては「推奨統一ルール」として本記録へ残し、今後の新規実装で適用する。
