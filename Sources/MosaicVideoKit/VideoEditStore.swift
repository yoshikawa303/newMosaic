import Foundation
import MosaicCore

// MARK: - 動画編集状態の保存（プラグイン境界）
//
// 動画のキーフレームROIは、静止画用の `MosaicCore.LibraryEngine`（index.json）へ
// 埋め込まず、ライブラリ配下の別ファイル（サイドカーJSON）として本モジュールが管理する。
// これにより、既存の静止画ライブラリのスキーマ・読み書き経路へ一切影響を与えずに
// 動画編集状態を追加できる（既存JSONは無変更で読める）。

/// 1つのキーフレーム（ある時刻に人が確認・確定したROI群）。
public struct VideoKeyframe: Codable, Equatable, Sendable {
    /// 動画先頭からの時刻（秒）。
    public var timeSeconds: Double
    /// その時刻に適用するROI群（静止画と同じ `MosaicROI` をそのまま使う）。
    public var rois: [MosaicROI]

    public init(timeSeconds: Double, rois: [MosaicROI]) {
        self.timeSeconds = timeSeconds
        self.rois = rois
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

    /// キーフレームを追加/更新する。時刻昇順で保持する。
    /// 既存キーフレームと±0.01秒以内の場合は「同じ時刻の編集」とみなして丸ごと置き換える
    /// （時刻も新しい値になる。ユーザーが再生位置を微調整して編集し直したケースを想定）。
    public mutating func upsertKeyframe(_ keyframe: VideoKeyframe) {
        if let index = keyframes.firstIndex(where: { abs($0.timeSeconds - keyframe.timeSeconds) < 0.01 }) {
            keyframes[index] = keyframe
        } else {
            keyframes.append(keyframe)
        }
        keyframes.sort { $0.timeSeconds < $1.timeSeconds }
    }

    /// 指定時刻のキーフレームを削除する（±0.01秒）。
    public mutating func removeKeyframe(atTime timeSeconds: Double) {
        keyframes.removeAll { abs($0.timeSeconds - timeSeconds) < 0.01 }
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
