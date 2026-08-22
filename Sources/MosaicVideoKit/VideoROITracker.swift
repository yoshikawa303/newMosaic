import CoreGraphics
import Foundation
import MosaicCore
import Vision

/// フレーム間でROI（`MosaicCore.MosaicROI`）の位置を追跡する。
///
/// プラグイン境界: `MosaicCore`はROIの生成・保存・描画を静止画単位で完結させる設計のため、
/// 「同一ROIを次のフレームでも追い続ける」責務はあえて`MosaicCore`へ持ち込まず、本モジュール
/// （動画専用）側に置く。追跡結果は`MosaicROI`のまま返すため、呼び出し側は
/// `MosaicEngine.applyMosaic`など既存のAPIへそのまま渡せる。
///
/// 内部実装はVisionの`VNTrackObjectRequest`を使い、ROI 1件につき独立した
/// `VNSequenceRequestHandler`を割り当てる（複数ROIの追跡状態が互いに干渉しないようにするため）。
public final class VideoROITracker {
    /// Vision矩形（正規化・左下原点）↔`MosaicROI.rect`（正規化・左上原点）の変換ヘルパー。
    /// `MosaicCore.DetectionPipeline`の`normalizedRect(fromVisionRect:)`と同じ変換規則。
    private enum CoordinateConversion {
        static func toVisionRect(_ rect: MosaicCore.NormalizedRect) -> CGRect {
            CGRect(x: rect.x, y: 1 - rect.y - rect.height, width: rect.width, height: rect.height)
        }

        static func toNormalizedRect(_ visionRect: CGRect) -> MosaicCore.NormalizedRect {
            MosaicCore.NormalizedRect(
                x: visionRect.minX,
                y: 1 - visionRect.minY - visionRect.height,
                width: visionRect.width,
                height: visionRect.height
            )
        }
    }

    /// ROI 1件分の追跡状態。クラス（参照型）にして`inputObservation`の更新を
    /// 辞書へ都度書き戻さずに済むようにする。
    private final class TrackState {
        let request: VNTrackObjectRequest
        let handler = VNSequenceRequestHandler()
        var lastVisionRect: CGRect
        /// 元ROIが追跡用の周辺コンテキスト矩形内で占める相対位置。
        let roiWithinTrackingRect: CGRect
        var isLost = false

        init(initialObservation: VNDetectedObjectObservation, roiVisionRect: CGRect) {
            let request = VNTrackObjectRequest(detectedObjectObservation: initialObservation)
            request.trackingLevel = .accurate
            self.request = request
            self.lastVisionRect = initialObservation.boundingBox
            let trackingRect = initialObservation.boundingBox
            self.roiWithinTrackingRect = CGRect(
                x: (roiVisionRect.minX - trackingRect.minX) / max(0.0001, trackingRect.width),
                y: (roiVisionRect.minY - trackingRect.minY) / max(0.0001, trackingRect.height),
                width: roiVisionRect.width / max(0.0001, trackingRect.width),
                height: roiVisionRect.height / max(0.0001, trackingRect.height)
            )
        }

        func roiVisionRect() -> CGRect {
            CGRect(
                x: lastVisionRect.minX + roiWithinTrackingRect.minX * lastVisionRect.width,
                y: lastVisionRect.minY + roiWithinTrackingRect.minY * lastVisionRect.height,
                width: roiWithinTrackingRect.width * lastVisionRect.width,
                height: roiWithinTrackingRect.height * lastVisionRect.height
            )
        }
    }

    /// 追跡信頼度がこの値未満になったフレームでは、そのROIの追跡を「見失った」とみなす。
    /// 見失った直後のフレームでは直前の既知位置を保持し続ける（要件どおり座標は変えない）。
    public static let lossConfidenceThreshold: Float = 0.3

    private var states: [UUID: TrackState] = [:]
    private var currentROIs: [MosaicROI] = []

    /// 直近の`track(next:)`呼び出しで追跡を見失った（confidence未満、または結果が取れなかった）
    /// ROIのID集合。`start(with:on:)`直後は空。
    public private(set) var lostIDs: Set<UUID> = []

    public init() {}

    /// 小さな対象部位そのものだけではフレーム間で特徴量が不足しやすいため、追跡には
    /// 周辺の肌・衣服を含むコンテキスト矩形を使う。出力ROIは元の相対位置へ戻すので、
    /// モザイク範囲そのものがこの倍率で広がることはない。
    static func trackingRect(for roi: MosaicROI) -> MosaicCore.NormalizedRect {
        let isGenital = roi.category == .maleGenital || roi.category == .femaleGenital
        return roi.rect.expanded(scale: isGenital ? 1.8 : 1.45)
    }

    /// キーフレーム上の初期ROI群から追跡を開始する。以後`track(next:)`を順番に呼び出す。
    public func start(with rois: [MosaicROI], on frame: CGImage) throws {
        states.removeAll()
        lostIDs.removeAll()
        currentROIs = rois
        for roi in rois {
            let roiVisionRect = CoordinateConversion.toVisionRect(roi.rect)
            let trackingVisionRect = CoordinateConversion.toVisionRect(Self.trackingRect(for: roi))
            let observation = VNDetectedObjectObservation(boundingBox: trackingVisionRect)
            states[roi.id] = TrackState(initialObservation: observation, roiVisionRect: roiVisionRect)
        }
    }

    /// 次のフレームへ追跡を1ステップ進め、更新後のROI群を返す。
    ///
    /// 各ROIの`id`・`category`・`style`・`rotation`・`shape`等は元のROIから引き継ぎ、
    /// `rect`のみ追跡結果で更新する。信頼度が`lossConfidenceThreshold`未満、または
    /// Visionが結果を返さなかった場合は直前の既知の`rect`を保持したまま`lostIDs`へ加える
    /// （ROIの座標を勝手に消したり画面外へ飛ばしたりしない）。
    @discardableResult
    public func track(next frame: CGImage) -> [MosaicROI] {
        var updatedROIs: [MosaicROI] = []
        var newLostIDs: Set<UUID> = []

        for roi in currentROIs {
            guard let state = states[roi.id] else {
                updatedROIs.append(roi)
                continue
            }

            var trackingSucceeded = false
            do {
                try state.handler.perform([state.request], on: frame)
                if let observation = state.request.results?.first as? VNDetectedObjectObservation {
                    if observation.confidence >= Self.lossConfidenceThreshold {
                        state.lastVisionRect = observation.boundingBox
                        // 次フレームの追跡精度を保つため、成功した観測結果を入力へ引き継ぐ
                        // （Visionのトラッキング要求は自動更新されないため手動で書き戻す必要がある）。
                        state.request.inputObservation = observation
                        trackingSucceeded = true
                    }
                }
            } catch {
                trackingSucceeded = false
            }

            state.isLost = !trackingSucceeded
            if !trackingSucceeded {
                newLostIDs.insert(roi.id)
            }

            var updated = roi
            updated.rect = CoordinateConversion.toNormalizedRect(state.roiVisionRect()).clamped()
            updatedROIs.append(updated)
        }

        currentROIs = updatedROIs
        lostIDs = newLostIDs
        return updatedROIs
    }
}
