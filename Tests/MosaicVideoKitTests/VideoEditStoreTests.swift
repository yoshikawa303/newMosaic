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

@Test func videoEditStateInterpolatesMatchingROIsForSmoothPlayback() throws {
    var start = makeROI(x: 0.1)
    start.rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.1, height: 0.2)
    start.rotation = 350
    var end = makeROI(x: 0.5)
    end.id = start.id
    end.rect = NormalizedRect(x: 0.5, y: 0.4, width: 0.3, height: 0.4)
    end.rotation = 10
    let newlyAppearing = makeROI(x: 0.8)

    var state = VideoEditState()
    state.upsertKeyframe(VideoKeyframe(timeSeconds: 0, rois: [start]))
    state.upsertKeyframe(VideoKeyframe(timeSeconds: 10, rois: [end, newlyAppearing]))

    let halfway = try #require(state.interpolatedKeyframe(at: 5))
    #expect(halfway.timeSeconds == 5)
    #expect(halfway.rois.count == 1)
    #expect(abs(halfway.rois[0].rect.x - 0.3) < 0.0001)
    #expect(abs(halfway.rois[0].rect.y - 0.3) < 0.0001)
    #expect(abs(halfway.rois[0].rect.width - 0.2) < 0.0001)
    #expect(abs(halfway.rois[0].rotation - 360) < 0.0001)
    #expect(state.interpolatedKeyframe(at: 10)?.rois.count == 2)
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

@Test func manualFrameCorrectionPersistsAndPropagatesToNearbyTrackedKeyframes() throws {
    var base = makeROI(x: 0.2)
    base.rect = NormalizedRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1)
    var state = VideoEditState()
    for time in stride(from: 0.0, through: 2.0, by: 0.25) {
        var roi = base
        roi.rect.x += time * 0.05
        state.upsertKeyframe(
            VideoKeyframe(timeSeconds: time, rois: [roi], trackingStatus: .tracked)
        )
    }

    var corrected = try #require(state.interpolatedKeyframe(at: 1)?.rois.first)
    corrected.rect.x += 0.2
    corrected.rect.width += 0.04
    let propagated = state.applyManualCorrection(
        VideoKeyframe(timeSeconds: 1, rois: [corrected]),
        propagationDuration: 1
    )

    let exact = try #require(state.keyframes.first { abs($0.timeSeconds - 1) < 0.001 })
    #expect(exact.trackingStatus == .manual)
    #expect(abs(exact.rois[0].rect.x - corrected.rect.x) < 0.0001)
    #expect(propagated == 6)
    // 近い自動キーフレームほど強く補正され、伝播範囲端は変更されない。
    #expect(state.keyframes.first { abs($0.timeSeconds - 0.75) < 0.001 }!.rois[0].rect.x > 0.3)
    #expect(abs(state.keyframes.first { abs($0.timeSeconds - 0) < 0.001 }!.rois[0].rect.x - 0.2) < 0.0001)
    #expect(abs(state.keyframes.first { abs($0.timeSeconds - 2) < 0.001 }!.rois[0].rect.x - 0.3) < 0.0001)
}

@Test func manualFrameCorrectionNeverOverwritesNeighboringManualAnchors() throws {
    var roi = makeROI(x: 0.2)
    let id = roi.id
    var state = VideoEditState()
    state.upsertKeyframe(VideoKeyframe(timeSeconds: 0, rois: [roi], trackingStatus: .manual))
    roi.rect.x = 0.3
    state.upsertKeyframe(VideoKeyframe(timeSeconds: 0.5, rois: [roi], trackingStatus: .tracked))
    roi.rect.x = 0.4
    state.upsertKeyframe(VideoKeyframe(timeSeconds: 2, rois: [roi], trackingStatus: .manual))

    var corrected = try #require(state.interpolatedKeyframe(at: 1)?.rois.first { $0.id == id })
    corrected.rect.x += 0.2
    _ = state.applyManualCorrection(
        VideoKeyframe(timeSeconds: 1, rois: [corrected]),
        propagationDuration: 2
    )

    #expect(abs(state.keyframes.first { $0.timeSeconds == 0 }!.rois[0].rect.x - 0.2) < 0.0001)
    #expect(abs(state.keyframes.first { $0.timeSeconds == 2 }!.rois[0].rect.x - 0.4) < 0.0001)
}

@Test func frameAwareToleranceKeepsAdjacentHighFrameRateKeyframes() {
    var state = VideoEditState()
    let tolerance = 0.45 / 120.0
    state.upsertKeyframe(
        VideoKeyframe(timeSeconds: 1, rois: [makeROI(x: 0.1)]),
        matchingTolerance: tolerance
    )
    state.upsertKeyframe(
        VideoKeyframe(timeSeconds: 1 + 1.0 / 120.0, rois: [makeROI(x: 0.2)]),
        matchingTolerance: tolerance
    )

    #expect(state.keyframes.count == 2)
}

@Test func nonGeometryManualCorrectionDoesNotRewriteNeighboringKeyframes() {
    var roi = makeROI(x: 0.2)
    var state = VideoEditState()
    state.upsertKeyframe(VideoKeyframe(timeSeconds: 0, rois: [roi], trackingStatus: .tracked))
    roi.rect.x = 0.3
    state.upsertKeyframe(VideoKeyframe(timeSeconds: 1, rois: [roi], trackingStatus: .tracked))
    var styleOnly = roi
    styleOnly.style = MosaicROIStyle(pattern: .noise)

    let propagated = state.applyManualCorrection(
        VideoKeyframe(timeSeconds: 1, rois: [styleOnly]),
        propagationDuration: 1
    )

    #expect(propagated == 0)
    #expect(state.keyframes[0].rois[0].style == nil)
    #expect(state.keyframes[1].rois[0].style?.pattern == .noise)
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

@Test func videoEditStateResolvesInheritedSettingsWithoutOverwritingExistingROISettings() {
    let inheritedROI = makeROI(x: 0.1)
    var explicitROI = makeROI(x: 0.4)
    explicitROI.style = MosaicROIStyle(pattern: .border, blockScale: 12, stripeWidth: 3)
    explicitROI.maskEngine = "shape"
    explicitROI.maskThreshold = 0.1

    var state = VideoEditState()
    state.upsertKeyframe(
        VideoKeyframe(
            timeSeconds: 1,
            rois: [inheritedROI, explicitROI],
            trackingStatus: .tracked
        )
    )

    let inheritedStyle = MosaicROIStyle(pattern: .noise, opacity: 0.5, blockScale: 6)
    let resolved = state.resolvingInheritedSettings(
        inheritedStyle: inheritedStyle,
        maskEngineRawValue: "samShape",
        maskThreshold: 0.4
    )
    let keyframe = resolved.keyframes[0]

    #expect(keyframe.trackingStatus == .tracked)
    #expect(keyframe.rois[0].style == inheritedStyle)
    #expect(keyframe.rois[0].maskEngine == "samShape")
    #expect(keyframe.rois[0].maskThreshold == 0.4)
    #expect(keyframe.rois[1].style == explicitROI.style)
    #expect(keyframe.rois[1].maskEngine == "shape")
    #expect(keyframe.rois[1].maskThreshold == 0.1)
    #expect(resolved.maskEngineRawValue == "samShape")
}

@Test func videoThumbnailProviderIdentifiesVideoExtensions() {
    #expect(VideoThumbnailProvider.isVideoFile(URL(fileURLWithPath: "/tmp/a.mp4")))
    #expect(VideoThumbnailProvider.isVideoFile(URL(fileURLWithPath: "/tmp/a.MOV")))
    #expect(!VideoThumbnailProvider.isVideoFile(URL(fileURLWithPath: "/tmp/a.png")))
}

@Test func videoEditStateLegacyStyleResolverKeepsSavedMaskEngine() {
    let state = VideoEditState(
        keyframes: [VideoKeyframe(timeSeconds: 1, rois: [makeROI(x: 0.2)])],
        maskEngineRawValue: "samShape"
    )

    let resolved = state.resolvingInheritedStyles(MosaicROIStyle(pattern: .pixelate))

    #expect(resolved.maskEngineRawValue == "samShape")
}
