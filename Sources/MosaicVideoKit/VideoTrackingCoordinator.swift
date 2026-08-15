import CoreGraphics
import Foundation
import MosaicCore

/// キーフレーム起点の追跡に「定期的な自動再検出」「シーンカット検出」「見失い時の安全側膨張」を
/// 束ねて、フレーム単位のROIを解決する。
///
/// 従来（v0.0.00135まで）は書き出し時に `VideoROITracker` を直接回すだけで、
/// 次の穴があった。
/// - キーフレーム間で新しく画面へ入ってきた対象は一切モザイクされない（検出の機会が無い）。
/// - 追跡がじわじわズレても補正されない（キーフレームまでズレたまま）。
/// - カットを跨ぐと追跡は必ず破綻するが、破綻を検知する手段が無い。
/// - 見失っても直前位置を保持するだけなので、対象が動いていればそのまま露出する。
///
/// 本コーディネータはこの4点を、書き出しと追跡プレビューの双方から使える形で埋める。
/// **判断は常に「覆い過ぎ」側へ倒す**（検閲漏れよりも過剰なモザイクを選ぶ）。
public final class VideoTrackingCoordinator {
    public struct Options: Sendable {
        /// 一定間隔で検出をやり直すか（A: 新規登場の拾い上げ＋追跡ズレの補正）。
        public var autoRedetectEnabled: Bool
        /// 何フレームごとに検出し直すか（1以上）。小さいほど正確だが書き出しは遅くなる。
        public var redetectIntervalFrames: Int
        /// シーンカットを検出したフレームで強制的に検出をやり直すか（D）。
        public var sceneCutRedetectEnabled: Bool
        /// シーンカット判定のしきい値（`SceneCutDetector.threshold`）。
        public var sceneCutThreshold: Double
        /// 見失っているROIをフレームごとに少しずつ広げるか（C: 安全側）。
        public var lostExpansionEnabled: Bool
        /// 見失い1フレームあたりの拡大量（正規化座標。各辺へこの値ずつ足す）。
        public var lostExpansionPerFrame: Double
        /// 見失いによる拡大量の上限（正規化座標。各辺への合計）。
        public var lostExpansionMax: Double

        public init(
            autoRedetectEnabled: Bool = true,
            redetectIntervalFrames: Int = 30,
            sceneCutRedetectEnabled: Bool = true,
            sceneCutThreshold: Double = 0.18,
            lostExpansionEnabled: Bool = true,
            lostExpansionPerFrame: Double = 0.002,
            lostExpansionMax: Double = 0.08
        ) {
            self.autoRedetectEnabled = autoRedetectEnabled
            self.redetectIntervalFrames = max(1, redetectIntervalFrames)
            self.sceneCutRedetectEnabled = sceneCutRedetectEnabled
            self.sceneCutThreshold = sceneCutThreshold
            self.lostExpansionEnabled = lostExpansionEnabled
            self.lostExpansionPerFrame = max(0, lostExpansionPerFrame)
            self.lostExpansionMax = max(0, lostExpansionMax)
        }
    }

    /// 1フレーム分の解決結果。
    public struct FrameOutcome {
        public let rois: [MosaicROI]
        /// このフレームで追跡を見失っているROIのID。
        public let lostIDs: Set<UUID>
        /// このフレームで検出をやり直したか。
        public let didRedetect: Bool
        /// このフレームでシーンカットを検出したか。
        public let didDetectSceneCut: Bool
        /// このフレームの再検出で新規に追加したROI数。
        public let addedROICount: Int
    }

    /// 自動再検出で「同じ対象」とみなすIoUのしきい値。
    /// 低くしすぎると別の対象へ吸着し、高くしすぎると同じ対象が二重登録される。
    public static let redetectMatchIoU = 0.30

    private let editState: VideoEditState
    private let frameRate: Double
    private let options: Options

    private let tracker = VideoROITracker()
    private var sceneCutDetector: SceneCutDetector
    private var activeKeyframeTime: Double = .infinity
    private var currentROIs: [MosaicROI] = []
    /// 見失いが継続しているROIの累積拡大量（正規化座標）。
    private var lostExpansion: [UUID: Double] = [:]
    private var framesSinceRedetect = 0

    /// 追跡を見失っていたフレーム番号（B: 書き出し後の「要確認の時間帯」提示用）。
    public private(set) var lostFrameIndices: [Int] = []
    /// 自動再検出でROIを追加したフレーム番号（同上）。
    public private(set) var addedFrameIndices: [Int] = []
    /// シーンカットを検出したフレーム番号。
    public private(set) var sceneCutFrameIndices: [Int] = []

    public init(editState: VideoEditState, frameRate: Double, options: Options = Options()) {
        self.editState = editState
        self.frameRate = max(1, frameRate)
        self.options = options
        self.sceneCutDetector = SceneCutDetector(threshold: options.sceneCutThreshold)
    }

    /// 指定フレームへ適用するROI群を返す。
    ///
    /// - Parameters:
    ///   - index: フレーム番号（0始まり）。
    ///   - image: そのフレームの画像。
    ///   - detector: 再検出に使う検出器。`nil`なら再検出は行わない（追跡のみ）。
    ///     呼び出し側の既存検出器（アニメ/実写）をそのまま渡す想定。
    public func rois(
        forFrame index: Int,
        image: CGImage,
        detector: ((CGImage) throws -> [MosaicROI])? = nil
    ) throws -> FrameOutcome {
        guard let keyframe = editState.keyframe(at: Double(index) / frameRate) else {
            return FrameOutcome(rois: [], lostIDs: [], didRedetect: false,
                                didDetectSceneCut: false, addedROICount: 0)
        }

        // 新しいキーフレーム区間に入ったら、そのROIで追跡を張り直す（キーフレーム＝追跡の起点）
        if keyframe.timeSeconds != activeKeyframeTime {
            activeKeyframeTime = keyframe.timeSeconds
            currentROIs = keyframe.rois
            lostExpansion.removeAll()
            framesSinceRedetect = 0
            try tracker.start(with: keyframe.rois, on: image)
            sceneCutDetector.reset(with: image)
            return FrameOutcome(rois: currentROIs, lostIDs: [], didRedetect: false,
                                didDetectSceneCut: false, addedROICount: 0)
        }

        let isSceneCut = options.sceneCutRedetectEnabled && sceneCutDetector.isSceneCut(image)
        if isSceneCut { sceneCutFrameIndices.append(index) }

        framesSinceRedetect += 1
        let intervalReached = options.autoRedetectEnabled
            && framesSinceRedetect >= options.redetectIntervalFrames
        // カットは「追跡が必ず破綻する」瞬間なので、自動再検出OFFでも検出器があればやり直す
        let shouldRedetect = detector != nil && (intervalReached || isSceneCut)

        var tracked = tracker.track(next: image)
        var lostIDs = tracker.lostIDs
        var addedCount = 0
        var didRedetect = false

        if shouldRedetect, let detector {
            let detected = try detector(image)
            let merged = Self.merge(tracked: tracked, detected: detected)
            tracked = merged.rois
            addedCount = merged.addedCount
            didRedetect = true
            framesSinceRedetect = 0
            // 再検出後は補正・追加後の矩形を起点に追跡を張り直す（ズレたまま追い続けない）
            try tracker.start(with: tracked, on: image)
            sceneCutDetector.reset(with: image)
            // 再検出で位置が取れたROIは見失い状態を解消する
            for roi in merged.reanchoredIDs {
                lostIDs.remove(roi)
                lostExpansion[roi] = nil
            }
            if addedCount > 0 { addedFrameIndices.append(index) }
        }

        if !lostIDs.isEmpty { lostFrameIndices.append(index) }

        currentROIs = tracked
        let output = options.lostExpansionEnabled
            ? applyLostExpansion(to: tracked, lostIDs: lostIDs)
            : tracked

        return FrameOutcome(rois: output, lostIDs: lostIDs, didRedetect: didRedetect,
                            didDetectSceneCut: isSceneCut, addedROICount: addedCount)
    }

    /// 見失っているROIをフレームごとに少しずつ広げる（C）。
    ///
    /// 見失い＝「対象がどこへ動いたか分からない」状態のため、直前位置を保持するだけでは
    /// 対象が動いた分だけ露出する。時間の経過とともに不確かさが増すことに合わせて
    /// 覆う範囲を広げ、上限で頭打ちにする。追跡を取り戻したフレームで拡大量は0へ戻す。
    /// **`currentROIs`側は広げない**（拡大は表示・描画のためだけで、次フレームの追跡起点は
    /// 素の追跡結果のままにする。広げた矩形を起点にすると際限なく膨らむため）。
    private func applyLostExpansion(to rois: [MosaicROI], lostIDs: Set<UUID>) -> [MosaicROI] {
        rois.map { roi in
            guard lostIDs.contains(roi.id) else {
                lostExpansion[roi.id] = nil
                return roi
            }
            let grown = min(options.lostExpansionMax,
                            (lostExpansion[roi.id] ?? 0) + options.lostExpansionPerFrame)
            lostExpansion[roi.id] = grown
            guard grown > 0 else { return roi }
            var expanded = roi
            expanded.rect = NormalizedRect(
                x: roi.rect.x - grown,
                y: roi.rect.y - grown,
                width: roi.rect.width + grown * 2,
                height: roi.rect.height + grown * 2
            ).clamped()
            return expanded
        }
    }

    /// 追跡中のROIと再検出結果を統合する。
    ///
    /// - 同じカテゴリでIoUがしきい値以上のペアは「同じ対象」とみなし、追跡側の矩形を
    ///   検出結果へ張り直す（ドリフト補正）。ID・スタイル・グループ名は追跡側を維持する。
    /// - **手描き（`source == "manual"`）は張り直さない**。ユーザーが意図して置いた範囲を
    ///   検出器が上書きするのは望ましくないため、追跡結果のまま残す。
    /// - どの追跡ROIとも対応しない検出結果は新規対象として追加する。
    /// - 検出されなかった追跡ROIは**消さずに残す**（消すと検閲漏れになるため）。
    static func merge(
        tracked: [MosaicROI],
        detected: [MosaicROI]
    ) -> (rois: [MosaicROI], addedCount: Int, reanchoredIDs: Set<UUID>) {
        var result = tracked
        var usedDetectionIndices = Set<Int>()
        var reanchored = Set<UUID>()

        for (resultIndex, roi) in result.enumerated() {
            var bestIndex: Int?
            var bestIoU = redetectMatchIoU
            for (index, candidate) in detected.enumerated()
            where !usedDetectionIndices.contains(index) && candidate.category == roi.category {
                let iou = intersectionOverUnion(roi.rect, candidate.rect)
                if iou >= bestIoU {
                    bestIoU = iou
                    bestIndex = index
                }
            }
            guard let bestIndex else { continue }
            usedDetectionIndices.insert(bestIndex)
            guard roi.source != "manual" else { continue }
            result[resultIndex].rect = detected[bestIndex].rect
            reanchored.insert(roi.id)
        }

        var added = 0
        for (index, candidate) in detected.enumerated() where !usedDetectionIndices.contains(index) {
            var fresh = candidate
            fresh.id = UUID()
            result.append(fresh)
            added += 1
        }
        return (result, added, reanchored)
    }

    static func intersectionOverUnion(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Double {
        let minX = max(lhs.x, rhs.x)
        let minY = max(lhs.y, rhs.y)
        let maxX = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let maxY = min(lhs.y + lhs.height, rhs.y + rhs.height)
        guard maxX > minX, maxY > minY else { return 0 }
        let intersection = (maxX - minX) * (maxY - minY)
        let union = lhs.area + rhs.area - intersection
        guard union > 0 else { return 0 }
        return intersection / union
    }

    /// 見失いフレーム番号を連続区間へまとめ、時間範囲（秒）の一覧にする（B）。
    /// `gapTolerance`フレーム以内の途切れは同じ区間として扱う（1フレームだけ復帰して
    /// また見失う、という細切れの区間が大量に並ぶのを防ぐ）。
    public func lostTimeRanges(gapTolerance: Int = 5) -> [ClosedRange<Double>] {
        Self.timeRanges(from: lostFrameIndices, frameRate: frameRate, gapTolerance: gapTolerance)
    }

    /// 新規ROIを追加したフレームの時間範囲（B）。
    public func addedTimeRanges(gapTolerance: Int = 5) -> [ClosedRange<Double>] {
        Self.timeRanges(from: addedFrameIndices, frameRate: frameRate, gapTolerance: gapTolerance)
    }

    static func timeRanges(
        from indices: [Int],
        frameRate: Double,
        gapTolerance: Int
    ) -> [ClosedRange<Double>] {
        guard !indices.isEmpty else { return [] }
        let rate = max(1, frameRate)
        let sorted = indices.sorted()
        var ranges: [ClosedRange<Double>] = []
        var start = sorted[0]
        var previous = sorted[0]
        for index in sorted.dropFirst() {
            if index - previous > max(0, gapTolerance) {
                ranges.append((Double(start) / rate)...(Double(previous) / rate))
                start = index
            }
            previous = index
        }
        ranges.append((Double(start) / rate)...(Double(previous) / rate))
        return ranges
    }
}
