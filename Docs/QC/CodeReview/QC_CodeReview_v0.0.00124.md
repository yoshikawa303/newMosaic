# newMosaic コードレビュー記録 v0.0.00124

## 対象

- ブランチ: `main`
- 対象: v0.0.00122・v0.0.00123（前回レビュー `QC_CodeReview_v0.0.00122.md` 以降、未レビューだった
  「残務」分。コミット `b8777bd`〈v0.0.00122〉・`469e9b2`〈v0.0.00123〉の差分）
- 実施日: 2026-08-04
- 指示: 「★残務の全コードレビューして」「★再開して」（前ターンで「全コードの複数回レビュー」が
  依頼されていたが、`v0.0.00123` 作業ではプッシュのみ対応し未着手のまま持ち越されていた）。

## AIモデル

- 実施: Claude Sonnet 5（本セッションはモデル切替の仕組みを持たないため単一モデルで対応）

## 実施方法

1. `git show` による対象2コミットの全差分読解（Swift本体・テスト・運用文書の4面）。
2. v0.0.00122のレビュー記録（`QC_CodeReview_v0.0.00122.md`）に記載された5件の修正が、実際の
   コードに正しく反映されているかを個別に追跡（呼び出し元・呼び出し先の両方を確認）。
3. v0.0.00123（SAMのしきい値較正）について、変更の妥当性とスコープ（他カテゴリへの影響有無）を
   コードとテストの両方から検証。
4. 運用文書（`ARCHITECTURE.md` / `QUALITY_STATS.md` / `CHANGELOG.md`）とコードの整合性を確認。
5. `swift test` と両品質ゲートを実行し、現状態が壊れていないことを確認。

GUIでの目視確認は実施していない（ツールを持たないため。前回レビューと同様の制約）。

## 指摘・修正一覧

| 優先度 | 問題点 | 改善案 | 状態 |
|:---:|---|---|:---:|
| P2 | `Mosaic/ARCHITECTURE.md` に `## 5.65` の見出しが2つ存在していた（v0.0.00122の
「複数回コードレビューで検出した整合性問題」と、v0.0.00123の「SAMの部分的な検閲漏れ...」が
同じ章番号）。相互参照が不能瞭になる | v0.0.00123側を `5.66` へ改番し、配下の `5.65.1`〜`5.65.4` も
`5.66.1`〜`5.66.4` へ揃える | 修正済み |
| P2 | 同ファイル §5.58.3（マスク手描き補正の操作説明）が、v0.0.00119でツールバーを
「マスク追加ペン」「マスク消しゴム」の2モード（4セグメント構成）へ分割した後も、旧仕様
（単一の「マスク修正モード」・3セグメント目・「マスク修正モードのときだけ表示」という
インスペクタ文言）のまま残っていた。実装（`main.swift` の `canvasModeControl` は4セグメント、
`InteractionMode` は `edit`/`marqueeSelect`/`maskPaint`/`maskErase`）および §5.61 の記述と矛盾する。
`ARCHITECTURE.md` は仕様衝突時の正とする文書であるため、古い記述が残ると今後の実装判断を誤らせる
おそれがある | §5.58.3を現状（2モードへ分割済み、§5.61参照）に合わせて修正する | 修正済み |
| P3 | `SAMSegmentEngine.minimumUsableCoverage`（v0.0.00123で0.02→0.40へ較正）はクラス共通の
定数で、性器（男性器・女性器）だけでなく乳首・乳輪ROIにSAMを使う場合にも同じ値が適用される。
しかしv0.0.00123の実測（§5.66.3）と回帰テスト（`reportWhetherGenitalExpansionStillChangesTheMask`
`samProducesTheSameMaskRegardlessOfROIShape`）はいずれも性器カテゴリのみへ`filter`しており、
サンプル画像に含まれる乳首・乳輪ROI（同じ5枚に計10件確認）は一度もこの新しいしきい値で
検証されていない。フォールバックは矩形全体を塗る安全側の動作なので検閲漏れにはならないが、
乳首マスクが不要に矩形化される「品質の低下」が起きても検知できない状態 | 乳首・乳輪ROIも含めて
`minimumUsableCoverage=0.40`適用後の被覆率を実測し、問題があればカテゴリ別のしきい値分離を
検討する。対応は保留（情報共有として`ARCHITECTURE.md`§5.66.3に記録） | 情報共有・対応保留 |
| P4 | `Mosaic/QUALITY_STATS.md` のテスト件数表記が「147件PASS（v0.0.00122）」のままで、
`CHANGELOG.md`・実際の`swift test`結果（v0.0.00123で148件）と食い違っていた | 148件の行を追加し、
CHANGELOG記載と同期する | 修正済み |
| - | v0.0.00123のコミットタイトルが「...`maximumUsableCoverage`を較正」となっているが、実際に
変更した定数は`minimumUsableCoverage`（`maximumUsableCoverage`は`PersonSilhouetteProvider`側に
別途存在し、今回変更していない）。コミットメッセージの文言のみの食い違いでコードへの影響は無い | 対応不要（過去コミットの文言は変更しない） | 記録のみ |

## v0.0.00122の5件修正の再検証結果

前回レビューで「修正済み」とされた5件について、実装・呼び出し元を個別に追跡し、いずれも
意図通りに機能していることを確認した（新規の問題は検出せず）。

1. `DetectedROIRefiner.recalculateMaskShapeScale` が `shapeControlChanged`（形状変更）・
   `onCategoryChangeRequest`（カテゴリ変更）の両ハンドラから正しく呼ばれている。他に
   `roi.shape` / `roi.category` を書き換える経路がコード内に無いことも確認済み（この2箇所が全て）。
2. `toggleMosaicPreview` / `resumeMosaicPreviewIfNeeded` / 元に戻す時の再描画 / ライブラリ復元の
   4箇所すべてが `renderMosaicOutput(for:)` 経由に統一されており、`hiddenROIIDs` を一貫して尊重する。
3. `addLayerForMaskPaint` がレイヤ追加前に1回だけUndoスナップショットを積み、
   `applyMaskStroke(isNewLayer:)` は `isNewLayer == true` のときだけ追加のスナップショットを
   積まない実装になっている（1回のUndoで両方戻る）。
4-5. ツールチップ・コード内コメントの旧ラベル名残存は解消済み。ただし運用文書
   （`ARCHITECTURE.md`）側の同種の残存は今回新たに検出した（上表 P2参照）。

## 修正後の検証

- `swift test`: 148件 PASS（変更なし。文書修正のみのため）
- `scripts/ci/agent_governance_guard.sh`: PASS
- `scripts/ci/local_quality_gate.sh`: PASS

## 確認コマンド

```bash
swift test
bash scripts/ci/agent_governance_guard.sh
bash scripts/ci/local_quality_gate.sh
```
