import CoreGraphics
import Foundation
import MosaicCore

/// キーフレーム検出＋フレーム間追跡を組み合わせた動画ROI生成の簡易パイプライン。
///
/// プラグイン境界: 検出処理そのもの（`MosaicCore`のアニメ/実写検出器等）は呼び出し側が
/// クロージャとして注入する。本モジュールは「重い検出をNフレームに1回だけ実行し、
/// 間のフレームは`VideoROITracker`によるROI移動追随（軽量な追跡）で埋める」という
/// 動画特有の駆動ロジックのみを担う。これにより既存の静止画検出器（アニメ用/実写用の
/// いずれか）をそのまま動画へ流用できる。
public final class VideoDetectionPipeline {
    /// 1フレーム分の処理結果。
    public struct FrameResult {
        /// フレーム番号（0始まり）。
        public let index: Int
        /// そのフレームの画像。
        public let image: CGImage
        /// そのフレームに適用するROI群（キーフレームは検出結果、それ以外は追跡結果）。
        public let rois: [MosaicROI]
        /// そのフレームで追跡を見失ったROIのID（キーフレームでは常に空）。
        public let lostIDs: Set<UUID>
        /// このフレームがキーフレーム（検出器を実行したフレーム）かどうか。
        public let isKeyframe: Bool
    }

    private let tracker: VideoROITracker

    public init(tracker: VideoROITracker = VideoROITracker()) {
        self.tracker = tracker
    }

    /// 動画を先頭から走査し、`keyframeInterval`フレームごとに`detector`でROIを検出し直し、
    /// 間のフレームは追跡で補う。
    ///
    /// - Parameters:
    ///   - url: 入力動画のURL。
    ///   - keyframeInterval: 何フレームごとに検出をやり直すか（1以上）。1を指定すると
    ///     毎フレーム検出のみを行い追跡は使わない。
    ///   - detector: キーフレーム上でROIを検出するクロージャ（呼び出し側の既存検出器を渡す想定）。
    ///   - shouldContinue: 継続判定（`VideoFrameReader.readFrames`へそのまま渡す）。
    ///   - onFrame: 各フレームの処理結果を受け取るハンドラ。
    public func process(
        url: URL,
        keyframeInterval: Int,
        detector: (_ frame: CGImage) throws -> [MosaicROI],
        shouldContinue: () -> Bool = { true },
        onFrame: (_ result: FrameResult) throws -> Void
    ) throws {
        precondition(keyframeInterval > 0, "keyframeIntervalは1以上を指定してください")

        let reader = VideoFrameReader(url: url)
        try reader.readFrames(shouldContinue: shouldContinue) { index, image, _ in
            let isKeyframe = index % keyframeInterval == 0
            let rois: [MosaicROI]
            let lostIDs: Set<UUID>
            if isKeyframe {
                rois = try detector(image)
                try self.tracker.start(with: rois, on: image)
                lostIDs = []
            } else {
                rois = self.tracker.track(next: image)
                lostIDs = self.tracker.lostIDs
            }
            try onFrame(FrameResult(index: index, image: image, rois: rois, lostIDs: lostIDs, isKeyframe: isKeyframe))
        }
    }
}
