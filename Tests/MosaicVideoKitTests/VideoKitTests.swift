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
        while !input.isReadyForMoreMediaData {
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
    semaphore.wait()
}

// MARK: - VideoFrameReader

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
