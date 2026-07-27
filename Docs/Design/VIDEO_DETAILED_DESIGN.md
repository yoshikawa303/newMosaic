# newMosaic 動画対応機能 詳細設計書

- 作成日: 2026-07-27
- 対象バージョン: v0.0.00085（V1基盤実装済み）〜
- 関連文書: `Docs/Design/VIDEO_BASIC_DESIGN.md`（基本設計）
- 状態表記: ✅=実装済み ／ 🔜=未実装

## 1. モジュール構成（V1・実装済み ✅）

`Sources/MosaicVideoKit/`（`MosaicCore` のみに依存。既存ソース無変更）

| ファイル | 責務 |
|---|---|
| `VideoFrameReader.swift` | フレーム読出し（シーケンシャル/ランダムアクセス）・動画情報取得 |
| `VideoROITracker.swift` | ROIのフレーム間追跡（Vision物体追跡） |
| `VideoDetectionPipeline.swift` | キーフレーム検出＋中間フレーム追跡の駆動 |
| `VideoMosaicExporter.swift` | モザイク適用付き再エンコード |

テスト: `Tests/MosaicVideoKitTests/VideoKitTests.swift`（合成動画による5件。§6参照）

## 2. 実装済みAPI仕様 ✅

### 2.1 VideoFrameReader

```swift
public struct VideoInfo: Sendable, Equatable {
    let durationSeconds: Double   // 尺（秒）
    let frameRate: Double         // nominalFrameRate（0時は30へフォールバック）
    let naturalSize: CGSize       // preferredTransform適用済みの実表示サイズ（常に正値）
    let frameCount: Int           // 推定値（duration×fps）。実数はreadFramesの戻り値を正とする
}

public final class VideoFrameReader {
    init(url: URL, ciContext: CIContext = ...)
    func loadInfo() throws -> VideoInfo
    @discardableResult
    func readFrames(shouldContinue: () -> Bool = { true },
                    handler: (_ index: Int, _ image: CGImage, _ presentationTime: CMTime) throws -> Void) throws -> Int
    func frame(at time: CMTime) throws -> CGImage   // ランダムアクセス（プレビュー/再生UI向け）
}
```

- 読出しは `AVAssetReader`（BGRA出力）→ `CIContext.createCGImage` でCGImage化。
- `frame(at:)` は `AVAssetImageGenerator`（tolerance=0、回転補正あり）。
- **スレッド制約**: 同期・ブロッキングAPI。メインスレッドから直接呼ばない。
- エラー: `VideoFrameReaderError`（noVideoTrack / readerCreationFailed /
  pixelBufferConversionFailed / imageGenerationFailed）。

### 2.2 VideoROITracker

```swift
public final class VideoROITracker {
    static let lossConfidenceThreshold: Float = 0.3
    private(set) var lostIDs: Set<UUID>
    func start(with rois: [MosaicROI], on frame: CGImage) throws
    @discardableResult
    func track(next frame: CGImage) -> [MosaicROI]
}
```

- ROI 1件につき独立した `VNTrackObjectRequest` + `VNSequenceRequestHandler`
  （複数ROIの追跡状態が干渉しないようにするため）。`trackingLevel = .accurate`。
- 座標系: Vision矩形（正規化・左下原点）↔ `MosaicROI.rect`（正規化・左上原点）を
  内部で相互変換（`MosaicCore.DetectionPipeline` と同一の変換規則）。
- 戻り値のROIは `id`/`category`/`style`/`rotation`/`shape` を元から引き継ぎ、
  `rect` のみ更新。追跡成功時は観測結果を `inputObservation` へ手動で書き戻す
  （Visionは自動更新しないため）。
- **ロスト時の挙動**: confidence < 0.3 または結果なし → 直前の既知位置を保持したまま
  `lostIDs` へ追加（座標を消さない・飛ばさない）。

### 2.3 VideoDetectionPipeline

```swift
public final class VideoDetectionPipeline {
    struct FrameResult { index, image, rois, lostIDs, isKeyframe }
    func process(url: URL,
                 keyframeInterval: Int,                      // 1以上。1=毎フレーム検出
                 detector: (CGImage) throws -> [MosaicROI],  // 既存検出器を注入
                 shouldContinue: () -> Bool = { true },
                 onFrame: (FrameResult) throws -> Void) throws
}
```

- `index % keyframeInterval == 0` のフレームで `detector` を実行し
  `tracker.start`、それ以外は `tracker.track` で追随。

### 2.4 VideoMosaicExporter

```swift
public final class VideoMosaicExporter {
    final class CancellationFlag: @unchecked Sendable { var isCancelled: Bool }  // NSLock保護
    init(style: MosaicStyle, engine: MosaicEngine = ..., segmentEngine: Segmenting = ...,
         patternImageProvider: ((String) -> CGImage?)? = nil)
    func export(from inputURL: URL, to outputURL: URL,
                roiProvider: @escaping (_ frameIndex: Int, _ frame: CGImage) throws -> [MosaicROI],
                cancellation: CancellationFlag? = nil,
                progress: ((Double) -> Void)? = nil) throws
}
```

- 出力: mp4（H.264）・元解像度・元フレームレート・**音声なし（V1制約。V4で解消）**。
- `roiProvider` が空配列を返したフレームは無加工のまま書き出す（再圧縮のみ）。
- キャンセル時は出力ファイルを削除して `cancelled` エラー。
- **タイムアウト設計（必須原則）**:
  - `isReadyForMoreMediaData` スピン待ち: 30秒デッドライン＋writer状態チェック
  - `finishWriting` 完了待ち: 60秒タイムアウト付きセマフォ
  - 超過時は `writingFailed(Error?)` としてエラー化（無期限待機は全体ハングの実績があり禁止）

## 3. 処理シーケンス（書き出しの全体フロー）

```
UI（V4） ──▶ バックグラウンドスレッド
  1. VideoDetectionPipeline.process(url, keyframeInterval, detector=既存検出器)
       ├ キーフレーム: detector(frame) → ROI検出 → tracker.start
       └ 中間フレーム: tracker.track → ROI追随（lostIDsをUIへ通知）
     ※V3ではここでユーザーが確認・修正（修正フレームを新キーフレーム化）
  2. VideoMosaicExporter.export(input, output, roiProvider: フレーム番号→確定ROI)
       ├ フレーム毎: MosaicEngine.applyMosaic（既存APIそのまま）
       ├ progress(0.0-1.0) → UIの進捗バー
       └ CancellationFlag → UIのキャンセルボタン
  3. 完了 → ライブラリProcessed/へ登録（V2データモデル）
```

## 4. V2〜V4 詳細設計 🔜

### 4.1 V2: ライブラリ統合

- **データモデル**（`MosaicCore.MosaicLibraryItem` 拡張。既存JSONと後方互換）:

```json
{
  "id": "...", "kind": "video",            // 省略時は "image"（既存項目の互換）
  "originalPath": "リンク先絶対パスまたはブックマーク",
  "processedPath": "Processed/xxx.mp4",
  "videoEdit": {                           // 動画編集状態（省略可）
    "keyframes": [
      { "timeSeconds": 0.0, "rois": [ /* MosaicROI配列（既存形式） */ ] },
      { "timeSeconds": 12.5, "rois": [ ... ] }
    ],
    "keyframeInterval": 30,
    "maskEngine": "regionForeground"
  }
}
```

- 動画はリンク登録のみ（コピーしない）。リンク切れは既存の修復導線を流用。
- サムネイル: `VideoFrameReader.frame(at: .zero)` を縮小キャッシュ。
- 一覧UI: 既存グリッド/リストへ種別バッジ（🎬）と尺表示を追加。
- プレビュー再生: ライブラリ選択時に `AVPlayerView`（AppKit標準）で再生・シーク。
  編集キャンバスとは分離し、既存の静止画表示へ影響しない。

### 4.2 V3: 編集UI

- 動画を開く → 先頭キーフレームを `ImageCanvasView` へ表示（既存の編集操作を全て流用）。
- タイムラインバー（キャンバス下部）: シーク・キーフレームマーカー表示・
  「◀前/次▶キーフレーム」ボタン・「このフレームをキーフレームに追加」。
- 追跡プレビュー: 現フレームのROIは「直前キーフレームからの追跡結果」を表示。
  `lostIDs` のROIは黄色警告枠で表示し、ドラッグ修正すると現フレームが
  新キーフレームとして `videoEdit.keyframes` へ追加される。
- 保存: 動画本体は再エンコードせず、`videoEdit`（キーフレームROI）のみ保存。

### 4.3 V4: 書き出しUI

- 書き出しダイアログ: 出力先・キーフレーム間隔・（将来）品質設定。
- 進捗シート: 進捗バー（`progress`コールバック）＋キャンセル（`CancellationFlag`）。
- 音声パススルー: `AVAssetReaderTrackOutput`（音声トラック）→
  `AVAssetWriterInput`（passthrough）を映像と並行して接続（V1制約の解消）。

## 5. エラー処理方針

- すべての動画APIエラーは `LocalizedError` で日本語メッセージを提供済み。
  UI側は既存の `showError` へそのまま渡す。
- 書き出し失敗・キャンセル時は中途半端な出力ファイルを残さない（削除済み）。
- 追跡ロストはエラーではなく通知（`lostIDs`）として扱い、処理は継続する。

## 6. テスト設計

### 実装済み ✅（5件・合成動画による）
- 合成動画生成: 64x64・10フレーム・黒背景に移動する白矩形（AVAssetWriterで生成、外部ファイル不使用）
- `readerReportsCorrectFrameCountAndSize` / `readerRandomAccessReturnsCorrectSize`: 読出しの枚数・サイズ
- `trackerFollowsMovingSquare`: 追跡が移動矩形へ追随（x座標の単調増加）
- `exporterProducesReadableOutputWithSameDimensions` / `exporterSkipsUntouchedFramesWhenNoROIsProvided`: 出力の可読性・同寸・無加工パス
- **実行規約**: AVFoundationを使うテストは `@Suite(.serialized)` で直列実行、
  待機は全てタイムアウト付き（並列実行ハングの再発防止。v0.0.00085で確立）

### V2〜V4で追加予定 🔜
- ライブラリJSONの動画項目・`videoEdit` の往復（後方互換含む）
- キーフレーム追加・修正→追跡再開始の状態遷移
- 音声パススルーの出力検証（音声トラック有無）

## 7. 既知の制約・将来拡張

| 項目 | 現状 | 将来 |
|---|---|---|
| 音声 | 出力に含まれない（V1） | V4でパススルー対応 |
| 出力コーデック | H.264/mp4固定 | HEVC・ProRes等の選択肢 |
| シーン切替検出 | なし（キーフレーム間隔で運用） | ヒストグラム差分等による自動キーフレーム挿入 |
| 追跡手法 | Vision物体追跡（矩形） | SAM2等のセグメンテーション追跡（`Segmenting` 境界で交換可能） |
| プレビュー中のモザイク再生 | なし（書き出し後に確認） | リアルタイムプレビュー（性能検証後） |
