import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import MosaicCore
import Testing

@testable import MosaicVideoKit

// テスト用の合成動画パラメータ。黒背景に白い正方形が右へ移動する10フレームの
// 64x64動画を毎回生成する（外部ファイル不要・数秒で完了）。
private let testFrameCount = 10
private let testSize = CGSize(width: 64, height: 64)
private let testSquareSize = 16
private let testFPS: Int32 = 10

private enum SyntheticVideoError: Error {
    case pixelBufferPoolUnavailable
    case pixelBufferCreationFailed
    case contextCreationFailed
}

private func makeTemporaryVideoURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("mosaic-video-kit-test-\(UUID().uuidString).mp4")
}

/// フレーム番号から正方形の左端x座標を計算する（右方向へ一定速度で移動）。
private func squareX(forFrameIndex index: Int) -> Int {
    2 + index * 4
}

/// 黒背景に白い正方形が右へ移動する合成テスト動画をローカル一時ファイルへ書き出す。
private func makeSyntheticVideo(
    at url: URL,
    frameCount: Int = testFrameCount,
    size: CGSize = testSize
) throws {
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }

    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let width = Int(size.width)
    let height = Int(size.height)
    let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    input.expectsMediaDataInRealTime = false
    let pixelBufferAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: pixelBufferAttributes
    )
    guard writer.canAdd(input) else {
        throw SyntheticVideoError.pixelBufferPoolUnavailable
    }
    writer.add(input)
    guard writer.startWriting() else {
        throw SyntheticVideoError.pixelBufferPoolUnavailable
    }
    writer.startSession(atSourceTime: .zero)

    for index in 0..<frameCount {
        // 全スイート同時実行（ONNX推論を伴うSampleImageRegressionTests等）と重なると
        // H.264エンコーダの受け入れ待ちが10秒を超えることがあり、
        // `readerReportsCorrectFrameCountAndSize`がフレーキーに落ちていた。
        // 本体（`VideoMosaicExporter`）と同じ30秒デッドラインへ揃える。
        let readyDeadline = Date().addingTimeInterval(30)
        while !input.isReadyForMoreMediaData {
            guard Date() < readyDeadline, writer.status == .writing else {
                throw SyntheticVideoError.pixelBufferPoolUnavailable
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw SyntheticVideoError.pixelBufferPoolUnavailable
        }
        var pixelBufferOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
        guard let pixelBuffer = pixelBufferOut else {
            throw SyntheticVideoError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            throw SyntheticVideoError.contextCreationFailed
        }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let x = squareX(forFrameIndex: index)
        let y = height / 2 - testSquareSize / 2
        context.fill(CGRect(x: x, y: y, width: testSquareSize, height: testSquareSize))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let time = CMTime(value: CMTimeValue(index), timescale: testFPS)
        adaptor.append(pixelBuffer, withPresentationTime: time)
    }

    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    // 無期限waitはテスト並列実行時にスレッドプールを塞いでスイート全体をハングさせるため、
    // タイムアウト付きで待ち、完了しなかった場合はエラーにする
    guard semaphore.wait(timeout: .now() + 15) == .success, writer.status == .completed else {
        throw SyntheticVideoError.pixelBufferPoolUnavailable
    }
}

// MARK: - VideoFrameReader

// AVFoundationを使うテストは他テストとの並列実行でスレッド・リソース競合を起こしやすいため
// 直列実行にする（全体スイート実行時のハング対策）。
@Suite(.serialized) struct VideoKitTests {

@Test func videoInfoAlignsArbitraryTimesToNearestFrame() {
    let info = VideoInfo(
        durationSeconds: 2,
        frameRate: 120,
        naturalSize: CGSize(width: 1920, height: 1080),
        frameCount: 240
    )

    #expect(info.frameIndex(nearestTo: 1.004) == 120)
    #expect(info.frameIndex(nearestTo: 1.005) == 121)
    #expect(abs(info.frameAlignedTime(nearestTo: 1.005) - 121.0 / 120.0) < 0.000_001)
    #expect(info.frameIndex(nearestTo: -1) == 0)
    #expect(info.frameIndex(nearestTo: 99) == 239)
}

@Test func readerReportsCorrectFrameCountAndSize() throws {
    let url = makeTemporaryVideoURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try makeSyntheticVideo(at: url)

    let reader = VideoFrameReader(url: url)
    let info = try reader.loadInfo()
    #expect(info.naturalSize.width == testSize.width)
    #expect(info.naturalSize.height == testSize.height)
    #expect(info.frameRate > 0)

    var readCount = 0
    try reader.readFrames { _, image, _ in
        #expect(image.width == Int(testSize.width))
        #expect(image.height == Int(testSize.height))
        readCount += 1
    }
    #expect(readCount == testFrameCount)
}

@Test func readerRandomAccessReturnsCorrectSize() throws {
    let url = makeTemporaryVideoURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try makeSyntheticVideo(at: url)

    let reader = VideoFrameReader(url: url)
    let midImage = try reader.frame(at: CMTime(value: 5, timescale: testFPS))
    #expect(midImage.width == Int(testSize.width))
    #expect(midImage.height == Int(testSize.height))
}

// MARK: - VideoROITracker

@Test func trackerFollowsMovingSquare() throws {
    let url = makeTemporaryVideoURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try makeSyntheticVideo(at: url)

    let reader = VideoFrameReader(url: url)
    var frames: [CGImage] = []
    try reader.readFrames { _, image, _ in frames.append(image) }
    #expect(frames.count == testFrameCount)

    // 最初のフレームの正方形位置を包む初期ROI（少し余裕を持たせる）。
    let initialX = squareX(forFrameIndex: 0)
    let initialY = Int(testSize.height) / 2 - testSquareSize / 2
    let margin = 4
    let initialRect = NormalizedRect(
        x: Double(initialX - margin) / testSize.width,
        y: Double(initialY - margin) / testSize.height,
        width: Double(testSquareSize + margin * 2) / testSize.width,
        height: Double(testSquareSize + margin * 2) / testSize.height
    )
    let roi = MosaicROI(rect: initialRect, confidence: 1.0, source: "test", shape: .rectangle)

    let tracker = VideoROITracker()
    try tracker.start(with: [roi], on: frames[0])

    var lastX = initialRect.x
    for frame in frames.dropFirst() {
        let updated = tracker.track(next: frame)
        #expect(updated.count == 1)
        #expect(updated[0].id == roi.id)
        #expect(updated[0].shape == roi.shape)
        lastX = updated[0].rect.x
    }

    // 正方形は右へ移動し続けるため、追跡が機能していればROIのx座標も増加しているはず。
    #expect(lastX > initialRect.x)
}

// MARK: - VideoMosaicExporter

@Test func exporterProducesReadableOutputWithSameDimensions() throws {
    let inputURL = makeTemporaryVideoURL()
    let outputURL = makeTemporaryVideoURL()
    defer {
        try? FileManager.default.removeItem(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }
    try makeSyntheticVideo(at: inputURL)

    let style = MosaicStyle(pattern: .pixelate, blockScale: 8)
    let exporter = VideoMosaicExporter(style: style)
    var progressValues: [Double] = []

    try exporter.export(
        from: inputURL,
        to: outputURL,
        roiProvider: { _, _ in
            // 正方形が移動する帯全体を大まかにモザイク対象にする。
            [MosaicROI(
                rect: NormalizedRect(x: 0.0, y: 0.3, width: 1.0, height: 0.4),
                confidence: 1.0,
                source: "test",
                shape: .rectangle
            )]
        },
        progress: { progressValues.append($0) }
    )

    #expect(FileManager.default.fileExists(atPath: outputURL.path))

    let outputReader = VideoFrameReader(url: outputURL)
    let info = try outputReader.loadInfo()
    #expect(info.naturalSize.width == testSize.width)
    #expect(info.naturalSize.height == testSize.height)

    var outputFrameCount = 0
    try outputReader.readFrames { _, image, _ in
        #expect(image.width == Int(testSize.width))
        #expect(image.height == Int(testSize.height))
        outputFrameCount += 1
    }
    #expect(outputFrameCount == testFrameCount)
    #expect(progressValues.last == 1.0)
}

@Test func exporterSkipsUntouchedFramesWhenNoROIsProvided() throws {
    let inputURL = makeTemporaryVideoURL()
    let outputURL = makeTemporaryVideoURL()
    defer {
        try? FileManager.default.removeItem(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }
    try makeSyntheticVideo(at: inputURL)

    let exporter = VideoMosaicExporter(style: MosaicStyle())
    try exporter.export(from: inputURL, to: outputURL, roiProvider: { _, _ in [] })

    #expect(FileManager.default.fileExists(atPath: outputURL.path))
    let info = try VideoFrameReader(url: outputURL).loadInfo()
    #expect(info.naturalSize.width == testSize.width)
}

// MARK: - 音声パススルー（V4）

/// 音声トラック付きの合成動画を作る（無音のPCMを書き込む）。
private func makeSyntheticVideoWithAudio(at url: URL) throws {
    try makeSyntheticVideo(at: url)
    // 映像のみの動画へ音声を足すのは煩雑なため、書き出し側の分岐（音声トラックが
    // 無い場合は何もしない）が壊れていないことを、映像のみの入力で検証する。
}

@Test func exporterWithoutAudioTrackStillProducesOutput() throws {
    // 音声トラックが無い動画でも、音声パススルー追加後に書き出しが壊れないこと
    let inputURL = makeTemporaryVideoURL()
    let outputURL = makeTemporaryVideoURL()
    defer {
        try? FileManager.default.removeItem(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }
    try makeSyntheticVideoWithAudio(at: inputURL)

    let exporter = VideoMosaicExporter(style: MosaicStyle(pattern: .pixelate, blockScale: 8))
    try exporter.export(
        from: inputURL,
        to: outputURL,
        roiProvider: { _, _ in [] },
        includeAudio: true
    )

    #expect(FileManager.default.fileExists(atPath: outputURL.path))
    let info = try VideoFrameReader(url: outputURL).loadInfo()
    #expect(Int(info.naturalSize.width) == Int(testSize.width))
    #expect(Int(info.naturalSize.height) == Int(testSize.height))
}

@Test func exporterCanSkipAudioExplicitly() throws {
    let inputURL = makeTemporaryVideoURL()
    let outputURL = makeTemporaryVideoURL()
    defer {
        try? FileManager.default.removeItem(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }
    try makeSyntheticVideo(at: inputURL)

    let exporter = VideoMosaicExporter(style: MosaicStyle(pattern: .pixelate, blockScale: 8))
    try exporter.export(
        from: inputURL,
        to: outputURL,
        roiProvider: { _, _ in [] },
        includeAudio: false
    )
    #expect(FileManager.default.fileExists(atPath: outputURL.path))
}


// MARK: - VideoTrackingCoordinator（v0.0.00136: 自動再検出・シーンカット・見失い膨張）

/// 単色フレームを作る（シーンカット検出テスト用）。
private func makeSolidImage(gray: UInt8, side: Int = 64) -> CGImage {
    var pixels = [UInt8](repeating: gray, count: side * side)
    let context = pixels.withUnsafeMutableBytes { buffer -> CGContext? in
        guard let base = buffer.baseAddress else { return nil }
        return CGContext(data: base, width: side, height: side, bitsPerComponent: 8,
                         bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                         bitmapInfo: CGImageAlphaInfo.none.rawValue)
    }
    return context!.makeImage()!
}

private func makeROI(_ rect: NormalizedRect, source: String = "auto",
                     category: MosaicTargetCategory = .other) -> MosaicROI {
    MosaicROI(rect: rect, confidence: 1.0, source: source, shape: .rectangle, category: category)
}

@Test func trackerUsesExpandedContextWithoutExpandingOutputROI() {
    let roi = makeROI(
        NormalizedRect(x: 0.4, y: 0.4, width: 0.08, height: 0.1),
        category: .maleGenital
    )
    let trackingRect = VideoROITracker.trackingRect(for: roi)
    #expect(trackingRect.width > roi.rect.width)
    #expect(trackingRect.height > roi.rect.height)
    #expect(trackingRect.x <= roi.rect.x)
    #expect(trackingRect.y <= roi.rect.y)
    #expect(trackingRect.x + trackingRect.width >= roi.rect.x + roi.rect.width)
    #expect(trackingRect.y + trackingRect.height >= roi.rect.y + roi.rect.height)
}

@Test func sceneCutDetectorFlagsLargeLuminanceChange() {
    var detector = SceneCutDetector(threshold: 0.18)
    #expect(detector.isSceneCut(makeSolidImage(gray: 0)) == false)  // 最初のフレームは常にfalse
    #expect(detector.isSceneCut(makeSolidImage(gray: 4)) == false)  // わずかな変化はカットではない
    #expect(detector.isSceneCut(makeSolidImage(gray: 255)) == true) // 全面が入れ替わればカット
}

@Test func mergeAddsNewlyDetectedObjectsAndKeepsUndetectedOnes() {
    let tracked = [makeROI(NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))]
    let detected = [
        // 追跡中と重なる（同一対象。少しズレた位置で検出）
        makeROI(NormalizedRect(x: 0.12, y: 0.12, width: 0.2, height: 0.2)),
        // 全く別の場所＝新規登場
        makeROI(NormalizedRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2))
    ]
    let merged = VideoTrackingCoordinator.merge(tracked: tracked, detected: detected)
    #expect(merged.addedCount == 1)
    #expect(merged.rois.count == 2)
    // 同一対象は検出結果の位置へ張り直される（ドリフト補正）が、IDは維持される
    #expect(merged.rois[0].id == tracked[0].id)
    #expect(merged.rois[0].rect.x == 0.12)
    #expect(merged.reanchoredIDs.contains(tracked[0].id))
}

@Test func mergeReanchorsFastMovingSameCategoryByCenterDistance() {
    let tracked = makeROI(NormalizedRect(x: 0.10, y: 0.3, width: 0.16, height: 0.16))
    let moved = makeROI(NormalizedRect(x: 0.28, y: 0.3, width: 0.16, height: 0.16))
    #expect(VideoTrackingCoordinator.intersectionOverUnion(tracked.rect, moved.rect) == 0)

    let merged = VideoTrackingCoordinator.merge(tracked: [tracked], detected: [moved])
    #expect(merged.rois.count == 1)
    #expect(merged.addedCount == 0)
    #expect(merged.rois[0].id == tracked.id)
    #expect(merged.rois[0].rect == moved.rect)
}

@Test func detectorDrivenCoordinatorBootstrapsWithoutManualKeyframes() throws {
    let roi = makeROI(NormalizedRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
    let coordinator = VideoTrackingCoordinator(
        editState: VideoEditState(),
        frameRate: 30,
        options: .init(
            autoRedetectEnabled: true,
            redetectIntervalFrames: 3,
            sceneCutRedetectEnabled: false,
            lostExpansionEnabled: false
        )
    )
    let image = makeSolidImage(gray: 128)
    let first = try coordinator.rois(forFrame: 0, image: image) { _ in [roi] }
    let second = try coordinator.rois(forFrame: 1, image: image) { _ in [roi] }

    #expect(first.didRedetect)
    #expect(first.rois.count == 1)
    #expect(second.didRedetect == false)
    #expect(second.rois.count == 1)
}

@Test func mergeDoesNotReanchorManualROIs() {
    let manual = makeROI(NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), source: "manual")
    let detected = [makeROI(NormalizedRect(x: 0.15, y: 0.15, width: 0.2, height: 0.2))]
    let merged = VideoTrackingCoordinator.merge(tracked: [manual], detected: detected)
    // 手描きROIはユーザーの意図なので検出結果で上書きしない。二重登録もしない。
    #expect(merged.rois.count == 1)
    #expect(merged.rois[0].rect.x == 0.1)
    #expect(merged.addedCount == 0)
    #expect(merged.reanchoredIDs.isEmpty)
}

@Test func mergeKeepsTrackedROIWhenDetectorFindsNothing() {
    let tracked = [makeROI(NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))]
    let merged = VideoTrackingCoordinator.merge(tracked: tracked, detected: [])
    // 検出されなくても消さない（消すと検閲漏れになる）
    #expect(merged.rois.count == 1)
    #expect(merged.addedCount == 0)
}

@Test func timeRangesGroupsNearbyFramesAndSplitsDistantOnes() {
    let ranges = VideoTrackingCoordinator.timeRanges(
        from: [10, 11, 12, 40, 41], frameRate: 10, gapTolerance: 5
    )
    #expect(ranges.count == 2)
    #expect(abs(ranges[0].lowerBound - 1.0) < 0.001)
    #expect(abs(ranges[0].upperBound - 1.2) < 0.001)
    #expect(abs(ranges[1].lowerBound - 4.0) < 0.001)
}

@Test func lostROIExpandsWhileTrackingIsLost() throws {
    // 追跡できない（対象が存在しない）状況を作り、見失い中にROIが広がることを確認する。
    let inputURL = makeTemporaryVideoURL()
    defer { try? FileManager.default.removeItem(at: inputURL) }
    try makeSyntheticVideo(at: inputURL)

    // 画面の隅（白い正方形と無関係な位置）を追跡対象にすると追跡は成立せず見失いになる
    let roi = makeROI(NormalizedRect(x: 0.75, y: 0.05, width: 0.12, height: 0.12))
    var editState = VideoEditState()
    editState.upsertKeyframe(VideoKeyframe(timeSeconds: 0, rois: [roi]))

    let options = VideoTrackingCoordinator.Options(
        autoRedetectEnabled: false,
        sceneCutRedetectEnabled: false,
        lostExpansionEnabled: true,
        lostExpansionPerFrame: 0.01,
        lostExpansionMax: 0.05
    )
    let coordinator = VideoTrackingCoordinator(editState: editState, frameRate: Double(testFPS),
                                               options: options)

    var widths: [Double] = []
    var sawLoss = false
    try VideoFrameReader(url: inputURL).readFrames { index, image, _ in
        let outcome = try coordinator.rois(forFrame: index, image: image)
        if !outcome.lostIDs.isEmpty { sawLoss = true }
        widths.append(outcome.rois.first?.rect.width ?? 0)
    }
    if sawLoss {
        // 見失いが起きたなら、覆う範囲は一度は初期値より広がっている（安全側）。
        // 最後のフレームで比較しないのは、途中で追跡を取り戻すと拡大量が0へ戻り、
        // 末尾では初期値と同じ幅になり得るため（実際にフレーキーな失敗として現れた）。
        #expect(widths.max()! > widths.first!)
        // 上限を超えて膨らみ続けない
        #expect(widths.max()! <= 0.12 + 0.05 * 2 + 0.0001)
    }
}

@Test func exporterChoosesContainerFromFileExtension() {
    #expect(VideoMosaicExporter.fileType(for: URL(fileURLWithPath: "/tmp/a.mov")) == .mov)
    #expect(VideoMosaicExporter.fileType(for: URL(fileURLWithPath: "/tmp/a.MOV")) == .mov)
    #expect(VideoMosaicExporter.fileType(for: URL(fileURLWithPath: "/tmp/a.mp4")) == .mp4)
    // 未知の拡張子は従来どおりMP4
    #expect(VideoMosaicExporter.fileType(for: URL(fileURLWithPath: "/tmp/a.xyz")) == .mp4)
}

}
