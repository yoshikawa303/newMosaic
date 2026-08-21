import Foundation
import Testing
@testable import MosaicCore
@testable import MosaicVideoKit

private func makeROI(x: Double) -> MosaicROI {
    MosaicROI(
        rect: NormalizedRect(x: x, y: 0.2, width: 0.1, height: 0.1),
        confidence: 1,
        source: "manual",
        shape: .rectangle,
        category: .nipple
    )
}

@Test func videoEditStateSelectsNearestPrecedingKeyframe() {
    var state = VideoEditState()
    state.upsertKeyframe(VideoKeyframe(timeSeconds: 0, rois: [makeROI(x: 0.1)]))
    state.upsertKeyframe(VideoKeyframe(timeSeconds: 10, rois: [makeROI(x: 0.5)]))

    // 時刻以前で最も近いキーフレームが選ばれる
    #expect(state.keyframe(at: 0)?.timeSeconds == 0)
    #expect(state.keyframe(at: 9.9)?.timeSeconds == 0)
    #expect(state.keyframe(at: 10)?.timeSeconds == 10)
    #expect(state.keyframe(at: 99)?.timeSeconds == 10)
    // 先頭より前の時刻でも先頭キーフレームへフォールバックする
    #expect(state.keyframe(at: -5)?.timeSeconds == 0)
}

@Test func videoEditStateSelectsStrictPreviousKeyframeForTracking() {
    var state = VideoEditState()
    state.upsertKeyframe(VideoKeyframe(timeSeconds: 0, rois: [makeROI(x: 0.1)]))
    state.upsertKeyframe(VideoKeyframe(timeSeconds: 10, rois: [makeROI(x: 0.5)]))

    #expect(state.keyframe(before: 10, requiringROIs: true)?.timeSeconds == 0)
    #expect(state.keyframe(before: 10.5, requiringROIs: true)?.timeSeconds == 10)
    #expect(state.keyframe(before: 0, requiringROIs: true) == nil)
}

@Test func videoEditStateUpsertReplacesSameTimeAndKeepsSorted() {
    var state = VideoEditState()
    state.upsertKeyframe(VideoKeyframe(timeSeconds: 5, rois: [makeROI(x: 0.1)]))
    state.upsertKeyframe(VideoKeyframe(timeSeconds: 1, rois: [makeROI(x: 0.2)]))
    // 同一時刻（±0.01秒）は丸ごと置き換えられ、件数が増えない（時刻も新しい値になる）
    state.upsertKeyframe(VideoKeyframe(timeSeconds: 5.005, rois: [makeROI(x: 0.9), makeROI(x: 0.8)]))

    #expect(state.keyframes.count == 2)
    #expect(state.keyframes.map(\.timeSeconds) == [1, 5.005])
    #expect(state.keyframes[1].rois.count == 2)

    state.removeKeyframe(atTime: 1)
    #expect(state.keyframes.count == 1)
}

@Test func videoEditStoreRoundTripsThroughDisk() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("newMosaicVideoEditStoreTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let store = VideoEditStore(libraryRootURL: root)
    let itemID = UUID()
    #expect(store.load(for: itemID) == nil)

    var state = VideoEditState(keyframeInterval: 15, maskEngineRawValue: "regionForeground")
    state.upsertKeyframe(VideoKeyframe(timeSeconds: 2.5, rois: [makeROI(x: 0.3)], trackingStatus: .tracked))
    try store.save(state, for: itemID)

    let loaded = try #require(store.load(for: itemID))
    #expect(loaded.keyframeInterval == 15)
    #expect(loaded.maskEngineRawValue == "regionForeground")
    #expect(loaded.keyframes.count == 1)
    #expect(loaded.keyframes[0].rois[0].category == .nipple)
    #expect(loaded.keyframes[0].trackingStatus == .tracked)

    store.delete(for: itemID)
    #expect(store.load(for: itemID) == nil)
}

@Test func videoEditStateDecodesMinimalJSONForForwardCompatibility() throws {
    // 将来フィールド追加・欠落があっても既定値で読めること（後方互換の担保）
    let json = "{}".data(using: .utf8)!
    let state = try JSONDecoder().decode(VideoEditState.self, from: json)
    #expect(state.keyframes.isEmpty)
    #expect(state.keyframeInterval == 30)
    #expect(state.maskEngineRawValue == nil)
}

@Test func videoKeyframeDecodesMissingTrackingStatusAsManual() throws {
    let roi = makeROI(x: 0.4)
    let data = try JSONEncoder().encode(VideoKeyframe(timeSeconds: 1, rois: [roi]))
    let raw = String(decoding: data, as: UTF8.self)
        .replacingOccurrences(of: #","trackingStatus":"manual""#, with: "")
    let decoded = try JSONDecoder().decode(VideoKeyframe.self, from: Data(raw.utf8))
    #expect(decoded.trackingStatus == .manual)
}

@Test func videoThumbnailProviderIdentifiesVideoExtensions() {
    #expect(VideoThumbnailProvider.isVideoFile(URL(fileURLWithPath: "/tmp/a.mp4")))
    #expect(VideoThumbnailProvider.isVideoFile(URL(fileURLWithPath: "/tmp/a.MOV")))
    #expect(!VideoThumbnailProvider.isVideoFile(URL(fileURLWithPath: "/tmp/a.png")))
}
