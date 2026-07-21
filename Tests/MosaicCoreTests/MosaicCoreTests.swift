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

@Test func mosaicEngineSupportsRectangleShape() throws {
    let image = try makeSolidImage(width: 80, height: 60)
    let roi = MosaicROI(
        rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
        confidence: 1,
        source: "manual",
        shape: .rectangle
    )

    let output = try MosaicEngine().applyMosaic(to: image, rois: [roi], scale: 12)

    #expect(output.width == 80)
    #expect(output.height == 60)
}

@Test func mosaicROIDecodesMissingShapeAsEllipse() throws {
    let json = """
    {"id":"\(UUID().uuidString)","rect":{"x":0.1,"y":0.2,"width":0.3,"height":0.4},"confidence":0.5,"source":"test"}
    """
    let roi = try JSONDecoder().decode(MosaicROI.self, from: Data(json.utf8))

    #expect(roi.shape == .ellipse)
    #expect(roi.category == .other)
}

@Test func roiGeneratorUsesPoseJointsForChestAndGroin() {
    let joints = [
        PoseJoint(name: .leftShoulder, x: 0.35, y: 0.30, confidence: 0.9),
        PoseJoint(name: .rightShoulder, x: 0.65, y: 0.30, confidence: 0.9),
        PoseJoint(name: .leftHip, x: 0.42, y: 0.60, confidence: 0.9),
        PoseJoint(name: .rightHip, x: 0.58, y: 0.60, confidence: 0.9),
        PoseJoint(name: .leftKnee, x: 0.42, y: 0.80, confidence: 0.9),
        PoseJoint(name: .rightKnee, x: 0.58, y: 0.80, confidence: 0.9)
    ]
    let hint = PoseHint(
        bodyBounds: NormalizedRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8),
        lowerBodyBounds: NormalizedRect(x: 0.3, y: 0.5, width: 0.4, height: 0.3),
        joints: joints
    )

    let rois = SensitiveROIGenerator().generateROIs(from: [hint], imageSize: CGSize(width: 800, height: 1200))

    let nipples = rois.filter { $0.category == .nipple }
    #expect(nipples.count == 2)
    #expect(rois.contains { $0.source == "pose-groin" })
    for roi in nipples {
        let centerY = roi.rect.y + roi.rect.height / 2
        #expect(abs(centerY - (0.30 + 0.30 * 0.32)) < 0.05)
    }
    if let groin = rois.first(where: { $0.source == "pose-groin" }) {
        let centerX = groin.rect.x + groin.rect.width / 2
        #expect(abs(centerX - 0.5) < 0.03)
    }
}

@Test func poseHintDecodesLegacyJSONWithoutJoints() throws {
    let json = """
    {"bodyBounds":{"x":0.1,"y":0.1,"width":0.5,"height":0.5},"lowerBodyBounds":{"x":0.2,"y":0.4,"width":0.3,"height":0.2}}
    """
    let hint = try JSONDecoder().decode(PoseHint.self, from: Data(json.utf8))

    #expect(hint.joints.isEmpty)
}

@Test func instanceBoundsFindsLabeledRegion() throws {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 10, 10, kCVPixelFormatType_OneComponent8, nil, &pixelBuffer)
    guard let pixelBuffer else { throw CocoaError(.coderInvalidValue) }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for y in 0..<10 {
        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for x in 0..<10 { row[x] = 0 }
    }
    for y in 2...5 {
        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for x in 3...6 { row[x] = 1 }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    let bounds = try #require(VisionPersonDetector.instanceBounds(in: pixelBuffer, instance: 1))

    #expect(abs(bounds.x - 0.3) < 0.001)
    #expect(abs(bounds.y - 0.2) < 0.001)
    #expect(abs(bounds.width - 0.4) < 0.001)
    #expect(abs(bounds.height - 0.4) < 0.001)
}

@Test func personDetectorReturnsEmptyWhenNoPersonFound() throws {
    // 単色画像（人物なし）では偽の固定矩形を返さず0件となることを検証する。
    // 「検出していない枠線を表示しない＝正確な検知内容の表示」というユーザー方針（2026-07-22）。
    let image = try makeSolidImage(width: 100, height: 100)

    let persons = try VisionPersonDetector().detectPersons(in: image)

    #expect(persons.isEmpty)
}

@Test func pipelineProducesNoCandidatesWithoutPersons() throws {
    // 人物検出0件のときパイプライン全体としても候補0件（偽候補を作らない）ことを検証する。
    let image = try makeSolidImage(width: 200, height: 200)

    let rois = try StaticImageMosaicPipeline().generateCandidates(for: image)

    #expect(rois.isEmpty)
}

@Test func normalizedRectExpandedAndIntersection() {
    let rect = NormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)

    let expanded = rect.expanded(scale: 2)
    #expect(abs(expanded.x - 0.3) < 0.001)
    #expect(abs(expanded.width - 0.4) < 0.001)

    let other = NormalizedRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3)
    let overlap = rect.intersection(other)
    #expect(overlap != nil)
    #expect(abs((overlap?.area ?? 0) - 0.01) < 0.001)

    let far = NormalizedRect(x: 0.9, y: 0.9, width: 0.05, height: 0.05)
    #expect(rect.intersection(far) == nil)
}

@Test func saliencyCandidateDetectorKeepsROIsOnPlainImage() throws {
    // 単色画像には顕著領域が無いため、精密化されず元のROIがそのまま返る経路を検証する。
    let image = try makeSolidImage(width: 200, height: 200)
    let roi = MosaicROI(
        rect: NormalizedRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3),
        confidence: 0.5,
        source: "pose-groin"
    )

    let refined = try SaliencyCandidateDetector().refineCandidates([roi], image: image)

    #expect(refined.count == 1)
    #expect(refined[0].id == roi.id)
}

@Test func shapeSegmentEngineProducesOneMaskPerROI() throws {
    let image = try makeSolidImage(width: 40, height: 40)
    let extent = CGRect(x: 0, y: 0, width: 40, height: 40)
    let rois = [
        MosaicROI(rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3), confidence: 1, source: "test", shape: .rectangle),
        MosaicROI(rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3), confidence: 1, source: "test", shape: .ellipse)
    ]

    let masks = try ShapeSegmentEngine().createMasks(for: rois, in: image, extent: extent)

    #expect(masks.count == 2)
}

@Test func visionPersonSegmentEngineFallsBackWithoutPerson() throws {
    // 単色画像には人物が存在しないため、Vision結果なし → ShapeSegmentEngineへフォールバックする経路を検証する。
    let image = try makeSolidImage(width: 80, height: 60)
    let roi = MosaicROI(
        rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
        confidence: 1,
        source: "test",
        shape: .ellipse
    )

    let output = try MosaicEngine().applyMosaic(
        to: image,
        rois: [roi],
        scale: 12,
        segmentEngine: VisionPersonSegmentEngine()
    )

    #expect(output.width == 80)
    #expect(output.height == 60)
}

@Test func foregroundSegmentEngineFallsBackOnPlainImage() throws {
    // 単色画像には前景オブジェクトが存在しないため、ShapeSegmentEngineへのフォールバック経路を検証する。
    let image = try makeSolidImage(width: 80, height: 60)
    let roi = MosaicROI(
        rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
        confidence: 1,
        source: "manual",
        shape: .rectangle
    )

    let output = try MosaicEngine().applyMosaic(
        to: image,
        rois: [roi],
        scale: 12,
        segmentEngine: ForegroundSegmentEngine()
    )

    #expect(output.width == 80)
    #expect(output.height == 60)
}

@Test func mosaicROIRoundTripsCategory() throws {
    let roi = MosaicROI(
        rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
        confidence: 1,
        source: "manual",
        shape: .rectangle,
        category: .nipple
    )

    let data = try JSONEncoder().encode(roi)
    let decoded = try JSONDecoder().decode(MosaicROI.self, from: data)

    #expect(decoded.category == .nipple)
    #expect(decoded.shape == .rectangle)
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

@Test func libraryEngineStoresOriginalAndProcessedImages() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("Library")
    let engine = LibraryEngine(rootURL: root)
    let image = try makeSolidImage(width: 32, height: 24)
    let roi = MosaicROI(
        rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
        confidence: 1,
        source: "test"
    )

    let imported = try engine.importOriginal(image, sourceName: "clipboard.png")
    let processed = try engine.saveProcessedImage(image, rois: [roi], for: imported.id)
    let items = try engine.loadItems()

    #expect(items.count == 1)
    #expect(items[0].id == imported.id)
    #expect(items[0].processedRelativePath == processed.processedRelativePath)
    #expect(FileManager.default.fileExists(atPath: engine.originalURL(for: processed).path))
    #expect(engine.processedURL(for: processed).map { FileManager.default.fileExists(atPath: $0.path) } == true)
    #expect(items[0].rois == [roi])
}

@Test func learningEngineDHashIsStableAndDiscriminative() throws {
    let image = try makePatternImage(width: 200, height: 200)
    let rectA = NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
    let rectB = NormalizedRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3)

    let hashA1 = try #require(LearningEngine.dHash(of: image, in: rectA))
    let hashA2 = try #require(LearningEngine.dHash(of: image, in: rectA))
    let hashB = try #require(LearningEngine.dHash(of: image, in: rectB))

    #expect(LearningEngine.hammingDistance(hashA1, hashA2) == 0)
    #expect(LearningEngine.hammingDistance(hashA1, hashB) > 4)
}

@Test func learningEngineBoostsFrequentPositionsAndProposesROIs() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("Learning")
    let engine = LearningEngine(rootURL: root)
    let image = try makePatternImage(width: 200, height: 200)
    let person = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    let roiRect = NormalizedRect(x: 0.45, y: 0.3, width: 0.1, height: 0.1)

    for _ in 0..<5 {
        let roi = MosaicROI(rect: roiRect, confidence: 1, source: "manual", shape: .ellipse, category: .nipple)
        try engine.record(acceptedROIs: [roi], rejectedROIs: [], persons: [person], image: image)
    }

    // 同位置の自動候補は信頼度がブーストされる
    let candidate = MosaicROI(rect: roiRect, confidence: 0.4, source: "pose-chest", shape: .ellipse, category: .nipple)
    let refined = engine.refineCandidates([candidate], persons: [person], image: image)
    let boosted = try #require(refined.first { $0.id == candidate.id })
    #expect(boosted.confidence > 0.4)

    // 候補ゼロでも高頻度セルからlearned-priorが提案される（別インスタンス=永続化の検証を兼ねる）
    let reloaded = LearningEngine(rootURL: root)
    let proposals = reloaded.refineCandidates([], persons: [person], image: image)
    #expect(proposals.contains { $0.source == "learned-prior" && $0.category == .nipple })

    // パッチPNGが正例フォルダへ収集されている
    let patches = try FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("Patches/Positives"),
        includingPropertiesForKeys: nil
    )
    #expect(patches.count == 5)
}

private func makePatternImage(width: Int, height: Int) throws -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ), let data = context.data else {
        throw CocoaError(.coderInvalidValue)
    }
    let pixels = data.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            pixels[y * width + x] = UInt8((x * 37 + y * 61) % 256)
        }
    }
    guard let image = context.makeImage() else {
        throw CocoaError(.coderInvalidValue)
    }
    return image
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
