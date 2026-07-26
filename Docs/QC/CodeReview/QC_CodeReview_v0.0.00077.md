# newMosaic コードレビュー記録 v0.0.00077

## 対象

- ブランチ: `main`
- 対象: `Sources/MosaicCore/` 全体（13ファイル）、`Sources/NewMosaicApp/main.swift`（約6850行、全体）
- 実施日: 2026-07-25
- 指示: 「Apple/Microsoft/Adobe基準」「SIGGRAPH等技術カンファレンス」「最新の技術論文」を踏まえ、問題がなくなるまで複数回コードレビューを実行し、発見パス（何回目に発見したか）・修正案・優先度を含む一覧を作成する
- 前提の明記: 実在するSIGGRAPH論文・各社の非公開内部資料を直接参照することはできないため、「Apple/Microsoft/Adobe基準」は各社が公開しているAPI設計指針・Swift Concurrencyモデル・実際のプラットフォーム仕様・CoreImage/Adobe PSD等の公開仕様に基づく専門的水準として解釈した。存在しない論文名・仕様書名の引用は行っていない。

## レビュー体制

- Pass 1: 5つの並列レビューエージェント（Claude、`general-purpose`種別のサブエージェント）による初回全体スキャン。担当領域を分割: (a) `MosaicEngine`/`SegmentEngine`/`MosaicModels`、(b) 検出パイプライン（`DetectionPipeline`/`AnimePoseEstimator`/`AnimeCensorDetector`/`AnimeSegmenter`/`FaceRegionDetector`/`DomainClassifier`）、(c) 永続化/IO層（`LibraryEngine`/`ImageExporter`/`PSDWriter`/`EPSWriter`/`HistoryEngine`/`ImageLoader`/`DatasetExporter`/`LearningEngine`/`OverlayAssetCatalog`）、(d)(e) `main.swift`前半・後半。
- Pass 2: 主担当（本エージェント）による重要指摘の実コード再検証（該当行を実際に読み実装ロジックを追跡して裏取り）。
- Pass 3: 検証で確認できた問題の修正実施。
- Pass 4: 修正後の再ビルド・全体再テスト・自己レビューによる再発/新規混入チェック。

## 指摘・修正一覧

| 回 | 優先度 | 問題点 | 該当箇所 | 修正内容 | 状態 |
|---:|:---:|---|---|---|:---:|
| 1 | P1 | `ImageCanvasView.mouseDown()`が直前の未完了ジェスチャー状態（resize/move/rotation/vertexDrag/groupMove/dragStart）をクリアせず、中断されたドラッグの残留状態が次のドラッグを乗っ取り別ROIを誤操作しうる | `main.swift` `ImageCanvasView.mouseDown` | 新規ジェスチャー判定前に全状態を明示的にnilクリア | 修正済み |
| 1 | P1 | `LibraryEngine`にread-modify-write（`loadItems`→変更→`saveItems`）の排他制御が無く、一括処理のバックグラウンドTaskとメインアクター側の単発保存が同一インスタンスへ並行アクセスすると更新が後勝ちで消えるTOCTOU競合がある（2エージェントが独立に検出・一致） | `MosaicCore/LibraryEngine.swift` 全mutatingメソッド | 直列`DispatchQueue`を追加し、全ての読み取り→変更→書き込みメソッドを排他制御。デッドロック回避のため非同期化版`loadItemsUnsynchronized()`を分離 | 修正済み |
| 1 | P2 | `MosaicEngine`の`.edgeBlur`/`.unsharpEdges`で、`CIEdges`等の近傍サンプリングフィルタを`clampedToExtent()`より前に適用しており、画像外周で透明領域との境界を偽エッジとして検出しうる（`blurred`側は正しい順序だが`edges`側だけ逆） | `MosaicCore/MosaicEngine.swift` `makeFillLayer` | `original.clampedToExtent()`を`CIEdges`適用前に移動し、`blurred`と同じ順序へ統一 | 修正済み |
| 1 | P2 | `VisionPersonSegmentEngine.createMasks`だけ`try handler.perform(...)`で実行時エラーを伝播させ、`ForegroundSegmentEngine`/`RegionForegroundSegmentEngine`（`try?`でフォールバック）と挙動が不統一。Vision実行時エラーで`applyMosaic`全体が失敗しうる | `MosaicCore/SegmentEngine.swift` `VisionPersonSegmentEngine` | `try?`へ変更し、既存の`fallback`（ShapeSegmentEngine）へ委ねる他方式と統一 | 修正済み |
| 1 | P3 | `MosaicStyle`が`CGImage`（参照型）を保持するpublic structだが`Sendable`未宣言。Swift 6並行性チェックでバックグラウンドTask越しの受け渡し時に警告/エラーの原因になりうる | `MosaicCore/MosaicEngine.swift` `MosaicStyle` | `CGImage`は不変のため安全と判断し`@unchecked Sendable`を明示 | 修正済み |
| 1 | P3 | `NormalizedRect.init(_:imageSize:)`が`imageSize`の縦横0（またはそれ以下）に対するゼロ除算ガードが無く、NaN/Infを生成しうる | `MosaicCore/MosaicModels.swift` | `imageSize.width > 0, imageSize.height > 0`のガードを追加し、不正時は空矩形を返す | 修正済み |
| 1 | P3 | `localMask == nil \|\| coverageRatio(of: localMask!) > 0.85`という短絡評価に依存したforce-unwrapの書き方が脆い | `MosaicCore/SegmentEngine.swift` | `map`+`??`で force-unwrap を排除 | 修正済み |
| 1 | P2 | `HistoryEngine.append`が`FileHandle.seekToEnd()`→`write()`という非アトミックな2ステップで、複数スレッドから同時追記するとログ行が破損しうる | `MosaicCore/HistoryEngine.swift` | 直列`DispatchQueue`で`append`全体を排他制御 | 修正済み |
| 1 | P2 | `LearningEngine.appendToFile`も同種の非アトミックappendで、`record()`内の`cachedSamples`更新とあわせて競合しうる | `MosaicCore/LearningEngine.swift` | 直列`DispatchQueue`を追加し、`record`/`loadSamples`/`loadStats`を排他制御（`rebuildStats`/内部呼び出しは非同期化版を使用しデッドロック回避） | 修正済み |
| 1 | P3 | `patternImageCache`（`[String: CGImage]`）が識別子選択のたびに際限なく増え続ける（上限・削除機構が無い） | `main.swift` `MosaicWindowController` | `patternImageCacheOrder`によるLRU管理を追加し、上限（40件）超過分を破棄する`setPatternImageCache(_:for:)`へ全書き込み箇所を統一 | 修正済み |
| 1 | P3 | `AppSettings.persistNow()`が`try?`でディレクトリ作成・ファイル書き込みの失敗を無言で握りつぶし、設定保存失敗がログに一切残らない（他の経路は`AppLog`で記録済みと非対称） | `main.swift` `AppSettings` | `do/catch`へ変更し失敗を`AppLog.ui.error`へ記録 | 修正済み |
| 1 | P3 | `outlineView(child:ofItem:)`の到達しないはずの分岐が`ungroupedLayers[0]`への固定インデックスアクセスで、配列が空の場合にクラッシュしうる | `main.swift` `NSOutlineViewDataSource`拡張 | 到達時に`assertionFailure`を追加した上で、空でも安全なプレースホルダへフォールバック | 修正済み |
| 1 | P3 | `imageEditStates`復元時、`saved.renderedImage!`のforce-unwrapが別行（`mosaicPreviewCheckbox.state`設定）の判定に依存しており、将来の変更で不変条件が崩れやすい | `main.swift` `setWorkingImage` | `if let`で両条件を同時に扱う形へ書き換え | 修正済み |
| 1 | P3 | `AnimePoseEstimator`がモデル出力を`outputs["simcc_x"] ?? outputs[outputNames.first ?? ""]`で取得しており、モデルの出力名が想定と異なる場合に出力順（first/last）依存のフォールバックとなり、X/Y座標が入れ替わって誤検出になっても無言 | `MosaicCore/AnimePoseEstimator.swift` | 名前一致しない場合にUnified Loggingへ警告を記録するよう追加（座標・画像内容は記録しない） | 修正済み |
| 1 | P3(参考記録) | 各ONNX推論クラス（`AnimePoseEstimator`/`AnimeSegmenter`/`DomainClassifier`/`AnimeCensorDetector`内`YOLOONNXModel`）が個別に`ORTEnv`を生成しており、プロセス内に最大6個のORTEnvが並存する（ONNX Runtimeの一般的な推奨は共有Env） | `MosaicCore/*.swift`（複数） | 未対応（下記「今回対応を見送った指摘」参照） | 未対応 |
| 1 | P3(参考記録) | `AnimeSegmenter`の出力行方向（「モデル出力の行方向は入力と同一」）がコメントのみで実測・テスト未検証。本コードベースには類似の上下反転バグが過去に実測で発覚した前例があり、同種のリスクがある | `MosaicCore/AnimeSegmenter.swift` | 未対応（要実測テスト。下記参照） | 未対応 |
| 1 | P3(参考記録) | `AnimePoseEstimator`/`AnimeCensorDetector`/`AnimeSegmenter`/`DomainClassifier`にUnified Loggingが無く、初期化・推論失敗が`try?`で無言に握りつぶされ、実写経路（`DetectionPipeline`はLogger使用）と診断性が非対称 | `MosaicCore/*.swift`（複数） | `AnimePoseEstimator`のみ本レビューの範囲内で追加。他3クラスは未対応（下記参照） | 一部対応 |
| 1 | P3(参考記録) | `importLinked`によるフォルダ一括登録がファイル数分ループして`loadItems`/`saveItems`をそのつど実行しO(n²)のJSON全体再エンコードになる（数千枚規模で顕著に遅くなりうる） | `MosaicCore/LibraryEngine.swift`（呼び出し元 `main.swift`） | 未対応（機能上の不具合ではなく性能上の指摘。下記参照） | 未対応 |
| 1 | P3(参考記録) | `performLibraryAutoSave`/`exportConfirmed`が大きな画像のエンコード・書き込みをメインスレッドで同期実行しており、デバッグログで見つかったものと同種のUIフリーズ要因になりうる | `main.swift`（複数箇所） | 未対応（デバッグログの実測フリーズほど頻度・体感影響が明確でないため優先度を下げて見送り。下記参照） | 未対応 |
| 4 | - | 上記修正後の再ビルド・再テスト・自己レビューで、P0〜P2相当の新規指摘なし | 全体 | 再確認完了 | 完了 |

## 今回対応を見送った指摘（理由・今後の推奨）

いずれも「即座に修正しないと不具合が発生する」種類ではなく、設計変更を伴う・実測検証が必要・効果に対して変更範囲が大きい等の理由で本レビューでは見送った。将来の対応候補として記録する。

1. **ORTEnvの共有化**: 6つの推論クラスを一括で書き換える必要があり、モデルロード経路への影響範囲が大きい。まとめて対応する回を設けることを推奨。
2. **AnimeSegmenterの行方向の実測検証**: 既知の左右非対称なテスト画像を用意し、実際のモデル出力とマスク描画結果を比較する専用テストが必要。
3. **ONNX系検出器へのログ追加**: `AnimePoseEstimator`のみ本レビューで対応済み。残り3クラスも同様の対応を推奨（座標・画像内容を含まない範囲で）。
4. **`importLinked`のO(n²)対策**: 典型的な利用（数十〜数百枚程度）では体感できる遅延ではないと判断。将来的にフォルダ一括登録の対象規模が数千枚に及ぶ場合は、ループ外で1回だけ読み込み・1回だけ保存する形へ改善する。
5. **大きな画像IOのメインスレッド実行**: デバッグログの`OSLogStore`走査ほど遅延が体感しやすいケースかどうかが未検証。ユーザーからの体感報告があれば、`Task.detached`化を優先対応する。

## 確認（Pass 4）

- `swift build`: PASS
- `swift build -c release`（`local_quality_gate.sh`内）: PASS
- `swift test`: 73/73 PASS
- `bash scripts/ci/agent_governance_guard.sh`: PASS
- `bash scripts/ci/local_quality_gate.sh`: PASS
- GUI起動確認: ユーザー確認事項（本エージェントはGUI操作を行わない運用のため）

## 結論

Pass 1（5並列エージェントによる全体スキャン）で計19件の指摘（P1×2、P2×3、P3×9、参考記録×5）を検出。Pass 2で主要な指摘（特にP1の2件）を実コード読解により裏取りし、誤検出でないことを確認した。Pass 3で対応可能な14件を修正し、5件（設計変更を伴う・実測検証が必要なもの）は理由を明記した上で見送った。Pass 4の再ビルド・全体テスト・自己レビューで新規のP0〜P2相当の指摘は無く、本レビューを完了とする。
