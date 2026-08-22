import Foundation
import MosaicCore

// MARK: - 動画編集状態の保存（プラグイン境界）
//
// 動画のキーフレームROIは、静止画用の `MosaicCore.LibraryEngine`（index.json）へ
// 埋め込まず、ライブラリ配下の別ファイル（サイドカーJSON）として本モジュールが管理する。
// これにより、既存の静止画ライブラリのスキーマ・読み書き経路へ一切影響を与えずに
// 動画編集状態を追加できる（既存JSONは無変更で読める）。

/// キーフレームの生成経路。手動追加・追跡結果・自動解析結果を一覧で区別する。
public enum VideoKeyframeTrackingStatus: String, Codable, Equatable, Sendable {
    case manual
    case tracked
    case autoDetected

    public var displayText: String {
        switch self {
        case .manual: return "手動"
        case .tracked: return "済"
        case .autoDetected: return "自動"
        }
    }
}

/// 1つのキーフレーム（ある時刻に人が確認・確定したROI群）。
public struct VideoKeyframe: Codable, Equatable, Sendable {
    /// 動画先頭からの時刻（秒）。
    public var timeSeconds: Double
    /// その時刻に適用するROI群（静止画と同じ `MosaicROI` をそのまま使う）。
    public var rois: [MosaicROI]
    /// このキーフレームが追跡・自動解析由来かをUIへ表示するための状態。
    public var trackingStatus: VideoKeyframeTrackingStatus

    public init(
        timeSeconds: Double,
        rois: [MosaicROI],
        trackingStatus: VideoKeyframeTrackingStatus = .manual
    ) {
        self.timeSeconds = timeSeconds
        self.rois = rois
        self.trackingStatus = trackingStatus
    }

    private enum CodingKeys: String, CodingKey {
        case timeSeconds, rois, trackingStatus
    }

    /// 既存のサイドカーJSONには`trackingStatus`が無いため、欠落時は手動扱いで読む。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timeSeconds = try container.decode(Double.self, forKey: .timeSeconds)
        rois = try container.decodeIfPresent([MosaicROI].self, forKey: .rois) ?? []
        trackingStatus = try container.decodeIfPresent(
            VideoKeyframeTrackingStatus.self,
            forKey: .trackingStatus
        ) ?? .manual
    }

    /// ROIが画面全体のモザイク設定を継承している場合、保存時点の設定をROIへ固定する。
    ///
    /// 動画は後から別フレームを開き直しても同じ見た目で再現できる必要があるため、
    /// nilのまま保存せず、キーフレーム確定時の設定を埋め込む。
    public func resolvingInheritedStyle(_ inheritedStyle: MosaicROIStyle) -> VideoKeyframe {
        resolvingInheritedSettings(
            inheritedStyle: inheritedStyle,
            maskEngineRawValue: nil,
            maskThreshold: nil
        )
    }

    /// ROIが画面全体のモザイク/マスク設定を継承している場合、保存時点の設定をROIへ固定する。
    ///
    /// 動画の自動解析・追跡はバックグラウンドで後から同じROIを再利用するため、`nil` のまま
    /// 保存すると、再生・書き出し時に当時とは違う全体設定で描画される。未設定項目だけを埋め、
    /// ROI個別設定は上書きしない。
    public func resolvingInheritedSettings(
        inheritedStyle: MosaicROIStyle,
        maskEngineRawValue: String?,
        maskThreshold: Double?
    ) -> VideoKeyframe {
        VideoKeyframe(
            timeSeconds: timeSeconds,
            rois: rois.map { roi in
                var persisted = roi
                if persisted.style == nil {
                    persisted.style = inheritedStyle
                }
                if persisted.maskEngine == nil {
                    persisted.maskEngine = maskEngineRawValue
                }
                if persisted.maskThreshold == nil {
                    persisted.maskThreshold = maskThreshold
                }
                return persisted
            },
            trackingStatus: trackingStatus
        )
    }
}

/// 1本の動画に対する編集状態。動画本体は再エンコードせず、この情報だけを保存する。
public struct VideoEditState: Codable, Equatable, Sendable {
    /// 時刻昇順のキーフレーム。
    public var keyframes: [VideoKeyframe]
    /// 自動検出をやり直すフレーム間隔（書き出し時の既定値）。
    public var keyframeInterval: Int
    /// マスク生成方式の識別子（`MosaicCore.SegmentEngineKind.rawValue`）。
    public var maskEngineRawValue: String?

    public init(
        keyframes: [VideoKeyframe] = [],
        keyframeInterval: Int = 30,
        maskEngineRawValue: String? = nil
    ) {
        self.keyframes = keyframes
        self.keyframeInterval = keyframeInterval
        self.maskEngineRawValue = maskEngineRawValue
    }

    private enum CodingKeys: String, CodingKey {
        case keyframes, keyframeInterval, maskEngineRawValue
    }

    /// 将来フィールドを追加しても既存ファイルが読めるよう、全項目を`decodeIfPresent`で読む。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyframes = try container.decodeIfPresent([VideoKeyframe].self, forKey: .keyframes) ?? []
        keyframeInterval = try container.decodeIfPresent(Int.self, forKey: .keyframeInterval) ?? 30
        maskEngineRawValue = try container.decodeIfPresent(String.self, forKey: .maskEngineRawValue)
    }

    /// 指定時刻に適用すべきキーフレーム（その時刻以前で最も近いもの）。無ければ先頭。
    public func keyframe(at timeSeconds: Double) -> VideoKeyframe? {
        let sorted = keyframes.sorted { $0.timeSeconds < $1.timeSeconds }
        return sorted.last { $0.timeSeconds <= timeSeconds + 0.0001 } ?? sorted.first
    }

    /// 再生プレビュー用に、前後キーフレームで同じIDのROI位置を線形補間する。
    ///
    /// 保存済みキーフレーム自体は変更しない。新規登場/消失ROIは次キーフレームまで
    /// 先読み表示せず、両端に存在する同一ROIだけを滑らかに移動・拡縮する。
    public func interpolatedKeyframe(at timeSeconds: Double) -> VideoKeyframe? {
        let sorted = keyframes.sorted { $0.timeSeconds < $1.timeSeconds }
        guard let previous = sorted.last(where: { $0.timeSeconds <= timeSeconds + 0.0001 }) ?? sorted.first else {
            return nil
        }
        guard timeSeconds > previous.timeSeconds + 0.0001,
              let next = sorted.first(where: { $0.timeSeconds > timeSeconds + 0.0001 }),
              next.timeSeconds > previous.timeSeconds else {
            return previous
        }

        let progress = min(1, max(0, (timeSeconds - previous.timeSeconds)
            / (next.timeSeconds - previous.timeSeconds)))
        let nextByID = Dictionary(next.rois.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rois = previous.rois.map { roi -> MosaicROI in
            guard let destination = nextByID[roi.id] else { return roi }
            var interpolated = roi
            interpolated.rect = NormalizedRect(
                x: Self.interpolate(roi.rect.x, destination.rect.x, progress),
                y: Self.interpolate(roi.rect.y, destination.rect.y, progress),
                width: Self.interpolate(roi.rect.width, destination.rect.width, progress),
                height: Self.interpolate(roi.rect.height, destination.rect.height, progress)
            ).clamped()
            interpolated.rotation = Self.interpolateAngle(roi.rotation, destination.rotation, progress)
            interpolated.confidence = Self.interpolate(roi.confidence, destination.confidence, progress)
            return interpolated
        }
        return VideoKeyframe(timeSeconds: timeSeconds, rois: rois, trackingStatus: previous.trackingStatus)
    }

    private static func interpolate(_ start: Double, _ end: Double, _ progress: Double) -> Double {
        start + (end - start) * progress
    }

    private static func interpolateAngle(_ start: Double, _ end: Double, _ progress: Double) -> Double {
        var delta = (end - start).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return start + delta * progress
    }

    /// 指定時刻より前で最も近いキーフレームを返す。
    /// 追跡確認では、現在時刻がキーフレーム上でも「現在のキーフレーム」ではなく
    /// 直前のキーフレームを起点にする必要がある。
    public func keyframe(before timeSeconds: Double, requiringROIs: Bool = false) -> VideoKeyframe? {
        let sorted = keyframes.sorted { $0.timeSeconds < $1.timeSeconds }
        return sorted.last {
            $0.timeSeconds < timeSeconds - 0.001
                && (!requiringROIs || !$0.rois.isEmpty)
        }
    }

    /// キーフレームを追加/更新する。時刻昇順で保持する。
    /// 既存キーフレームと`matchingTolerance`未満の場合は「同じ時刻の編集」とみなして
    /// 丸ごと置き換える（時刻も新しい値になる）。既定は従来互換の0.01秒だが、
    /// 高fps動画の編集側はフレーム間隔の半分未満を渡す。
    public mutating func upsertKeyframe(
        _ keyframe: VideoKeyframe,
        matchingTolerance: Double = 0.01
    ) {
        let tolerance = max(0.000_001, matchingTolerance)
        if let index = keyframes.firstIndex(where: {
            abs($0.timeSeconds - keyframe.timeSeconds) < tolerance
        }) {
            keyframes[index] = keyframe
        } else {
            keyframes.append(keyframe)
        }
        keyframes.sort { $0.timeSeconds < $1.timeSeconds }
    }

    /// 現在フレームの手動修正を確定し、近傍の自動追跡キーフレームへ幾何差分を減衰伝播する。
    ///
    /// 手動修正を1点だけ保存すると、その直前・直後に密な自動キーフレームがある動画では
    /// 数フレームで元の誤った軌道へ戻ってしまう。修正前の補間位置との差（中心・サイズ・回転）を
    /// 前後へ伝播し、既存の手動キーフレームまたは`propagationDuration`で影響を0へ戻す。
    /// ユーザーが確認済みの別の手動キーフレームは変更しない。
    ///
    /// - Returns: 補正した近傍キーフレーム数（現在フレーム自身を含まない）。
    @discardableResult
    public mutating func applyManualCorrection(
        _ correction: VideoKeyframe,
        matchingTolerance: Double = 0.01,
        propagationDuration: Double = 1.0
    ) -> Int {
        let tolerance = max(0.000_001, matchingTolerance)
        let duration = max(tolerance, propagationDuration)
        let time = correction.timeSeconds
        let baselineROIs = interpolatedKeyframe(at: time)?.rois ?? []
        let baselineByID = Dictionary(
            baselineROIs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let correctedByID = Dictionary(
            correction.rois.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let deltas = correctedByID.compactMapValues { corrected -> GeometryCorrection? in
            guard let baseline = baselineByID[corrected.id] else { return nil }
            let delta = GeometryCorrection(from: baseline, to: corrected)
            return delta.isEffective ? delta : nil
        }

        let previousManualTime = keyframes
            .filter { $0.trackingStatus == .manual && $0.timeSeconds < time - tolerance }
            .map(\.timeSeconds)
            .max()
        let nextManualTime = keyframes
            .filter { $0.trackingStatus == .manual && $0.timeSeconds > time + tolerance }
            .map(\.timeSeconds)
            .min()
        let backwardSpan = min(duration, previousManualTime.map { time - $0 } ?? duration)
        let forwardSpan = min(duration, nextManualTime.map { $0 - time } ?? duration)

        var propagatedCount = 0
        if !deltas.isEmpty {
            for index in keyframes.indices {
                let keyframeTime = keyframes[index].timeSeconds
                let signedDistance = keyframeTime - time
                let distance = abs(signedDistance)
                guard distance >= tolerance,
                      keyframes[index].trackingStatus != .manual else { continue }
                let span = signedDistance < 0 ? backwardSpan : forwardSpan
                guard span > tolerance, distance < span else { continue }
                let weight = 1 - distance / span
                var changed = false
                keyframes[index].rois = keyframes[index].rois.map { roi in
                    guard let delta = deltas[roi.id] else { return roi }
                    changed = true
                    return delta.applying(to: roi, weight: weight)
                }
                if changed { propagatedCount += 1 }
            }
        }

        var manual = correction
        manual.trackingStatus = .manual
        upsertKeyframe(manual, matchingTolerance: tolerance)
        return propagatedCount
    }

    private struct GeometryCorrection {
        let centerX: Double
        let centerY: Double
        let width: Double
        let height: Double
        let rotation: Double

        var isEffective: Bool {
            abs(centerX) > 0.000_001
                || abs(centerY) > 0.000_001
                || abs(width) > 0.000_001
                || abs(height) > 0.000_001
                || abs(rotation) > 0.000_1
        }

        init(from baseline: MosaicROI, to corrected: MosaicROI) {
            centerX = (corrected.rect.x + corrected.rect.width / 2)
                - (baseline.rect.x + baseline.rect.width / 2)
            centerY = (corrected.rect.y + corrected.rect.height / 2)
                - (baseline.rect.y + baseline.rect.height / 2)
            width = corrected.rect.width - baseline.rect.width
            height = corrected.rect.height - baseline.rect.height
            var angle = (corrected.rotation - baseline.rotation).truncatingRemainder(dividingBy: 360)
            if angle > 180 { angle -= 360 }
            if angle < -180 { angle += 360 }
            rotation = angle
        }

        func applying(to roi: MosaicROI, weight: Double) -> MosaicROI {
            var corrected = roi
            let nextWidth = max(0.001, roi.rect.width + width * weight)
            let nextHeight = max(0.001, roi.rect.height + height * weight)
            let nextCenterX = roi.rect.x + roi.rect.width / 2 + centerX * weight
            let nextCenterY = roi.rect.y + roi.rect.height / 2 + centerY * weight
            corrected.rect = NormalizedRect(
                x: nextCenterX - nextWidth / 2,
                y: nextCenterY - nextHeight / 2,
                width: nextWidth,
                height: nextHeight
            ).clamped()
            var nextRotation = (roi.rotation + rotation * weight).truncatingRemainder(dividingBy: 360)
            if nextRotation < 0 { nextRotation += 360 }
            corrected.rotation = nextRotation
            return corrected
        }
    }

    /// 指定時刻と`matchingTolerance`未満のキーフレームを削除する。
    public mutating func removeKeyframe(
        atTime timeSeconds: Double,
        matchingTolerance: Double = 0.01
    ) {
        let tolerance = max(0.000_001, matchingTolerance)
        keyframes.removeAll { abs($0.timeSeconds - timeSeconds) < tolerance }
    }

    /// 全キーフレームの継承スタイルを保存時点のスタイルへ固定する。
    public func resolvingInheritedStyles(_ inheritedStyle: MosaicROIStyle) -> VideoEditState {
        resolvingInheritedSettings(
            inheritedStyle: inheritedStyle,
            maskEngineRawValue: nil,
            maskThreshold: nil
        )
    }

    /// 全キーフレームの継承スタイル/マスク設定を保存時点の設定へ固定する。
    public func resolvingInheritedSettings(
        inheritedStyle: MosaicROIStyle,
        maskEngineRawValue: String?,
        maskThreshold: Double?
    ) -> VideoEditState {
        VideoEditState(
            keyframes: keyframes.map {
                $0.resolvingInheritedSettings(
                    inheritedStyle: inheritedStyle,
                    maskEngineRawValue: maskEngineRawValue,
                    maskThreshold: maskThreshold
                )
            },
            keyframeInterval: keyframeInterval,
            maskEngineRawValue: maskEngineRawValue ?? self.maskEngineRawValue
        )
    }
}

/// 動画編集状態のファイル保存（ライブラリ配下 `VideoEdits/<itemID>.json`）。
///
/// 保存先はライブラリのルート配下に限定し、動画本体・フレーム画像は保存しない
/// （保存するのはROI矩形とカテゴリ等のメタデータのみ。完全ローカル）。
public final class VideoEditStore {
    private let directoryURL: URL
    private let queue = DispatchQueue(label: "jp.yoshikawa303.newMosaic.VideoEditStore.sync")

    /// - Parameter libraryRootURL: `LibraryEngine.rootURL`（`~/Library/Application Support/newMosaic/Library`）。
    public init(libraryRootURL: URL) {
        self.directoryURL = libraryRootURL.appendingPathComponent("VideoEdits", isDirectory: true)
    }

    private func fileURL(for itemID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(itemID.uuidString).json")
    }

    /// 保存済みの編集状態を読み込む（無ければnil）。
    public func load(for itemID: UUID) -> VideoEditState? {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL(for: itemID)) else { return nil }
            return try? JSONDecoder().decode(VideoEditState.self, from: data)
        }
    }

    /// 編集状態を保存する。
    public func save(_ state: VideoEditState, for itemID: UUID) throws {
        try queue.sync {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: fileURL(for: itemID), options: .atomic)
        }
    }

    /// 編集状態を削除する（ライブラリ項目の削除に追随させる用途）。
    public func delete(for itemID: UUID) {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL(for: itemID))
        }
    }
}
