import AppKit
import CoreGraphics
import Testing
@testable import MosaicCore

@Test func normalizedRectClampsAndConvertsToBottomLeft() {
    let rect = NormalizedRect(x: -0.2, y: 0.2, width: 0.7, height: 0.5)
    let cgRect = rect.cgRect(imageSize: CGSize(width: 100, height: 200), origin: .bottomLeft)

    #expect(cgRect.origin.x == 0)
    #expect(cgRect.origin.y == 60)
    #expect(cgRect.width == 50)
    #expect(cgRect.height == 100)
}

@Test func roiGeneratorProducesClampedCandidate() {
    let generator = SensitiveROIGenerator()
    let hint = PoseHint(
        bodyBounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
        lowerBodyBounds: NormalizedRect(x: 0.2, y: 0.5, width: 0.6, height: 0.3)
    )

    let rois = generator.generateROIs(from: [hint], imageSize: CGSize(width: 640, height: 480))

    #expect(rois.count == 1)
    #expect(rois[0].rect.x >= 0)
    #expect(rois[0].rect.y >= 0)
    #expect(rois[0].rect.x + rois[0].rect.width <= 1)
    #expect(rois[0].source == "heuristic-lower-body")
}

@Test func mosaicEnginePreservesImageSize() throws {
    let image = try makeSolidImage(width: 80, height: 60)
    let roi = MosaicROI(
        rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
        confidence: 1,
        source: "test"
    )

    let output = try MosaicEngine().applyMosaic(to: image, rois: [roi], scale: 12)

    #expect(output.width == 80)
    #expect(output.height == 60)
}

@Test func historyEngineRoundTripsJsonLines() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("history.jsonl")
    let engine = HistoryEngine()
    let entry = MosaicHistoryEntry(
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        imageName: "sample.png",
        imagePixelWidth: 100,
        imagePixelHeight: 80,
        rois: [MosaicROI(rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), confidence: 0.5, source: "test")]
    )

    try engine.append(entry, to: url)
    let entries = try engine.readEntries(from: url)

    #expect(entries == [entry])
}

private func makeSolidImage(width: Int, height: Int) throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw CocoaError(.coderInvalidValue)
    }
    context.setFillColor(NSColor.systemRed.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        throw CocoaError(.coderInvalidValue)
    }
    return image
}
