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

@Test func roiGeneratorProducesNoCandidatesWithoutJoints() {
    // 関節が取れないヒントからは候補を生成しない（精度の低い固定比率フォールバックは
    // 肩付近への巨大な誤ROIを生むため廃止。「検出していないものは表示しない」方針）。
    let generator = SensitiveROIGenerator()
    let hint = PoseHint(
        bodyBounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
        lowerBodyBounds: NormalizedRect(x: 0.2, y: 0.5, width: 0.6, height: 0.3)
    )

    let rois = generator.generateROIs(from: [hint], imageSize: CGSize(width: 640, height: 480))

    #expect(rois.isEmpty)
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
        #expect(abs(centerY - (0.30 + 0.30 * 0.42)) < 0.05)
    }
    if let groin = rois.first(where: { $0.source == "pose-groin" }) {
        let centerX = groin.rect.x + groin.rect.width / 2
        #expect(abs(centerX - 0.5) < 0.03)
    }
}

@Test func roiGeneratorGroinPositionRatioShiftsROIDownward() {
    let joints = [
        PoseJoint(name: .leftHip, x: 0.42, y: 0.50, confidence: 0.9),
        PoseJoint(name: .rightHip, x: 0.58, y: 0.50, confidence: 0.9),
        PoseJoint(name: .leftKnee, x: 0.42, y: 0.80, confidence: 0.9),
        PoseJoint(name: .rightKnee, x: 0.58, y: 0.80, confidence: 0.9)
    ]
    let hint = PoseHint(
        bodyBounds: NormalizedRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8),
        lowerBodyBounds: NormalizedRect(x: 0.3, y: 0.5, width: 0.4, height: 0.3),
        joints: joints
    )
    let imageSize = CGSize(width: 800, height: 1200)

    let upper = SensitiveROIGenerator(groinPositionRatio: 0.3)
        .generateROIs(from: [hint], imageSize: imageSize)
        .first { $0.source == "pose-groin" }
    let lower = SensitiveROIGenerator(groinPositionRatio: 0.6)
        .generateROIs(from: [hint], imageSize: imageSize)
        .first { $0.source == "pose-groin" }

    let upperCenterY = (upper?.rect.y ?? 0) + (upper?.rect.height ?? 0) / 2
    let lowerCenterY = (lower?.rect.y ?? 0) + (lower?.rect.height ?? 0) / 2
    #expect(lowerCenterY > upperCenterY)
    // ratio 0.6: 腰y0.5 + (膝0.8-腰0.5)*0.6 = 0.68
    #expect(abs(lowerCenterY - 0.68) < 0.01)
}

@Test func personMaskSamplerDetectsInsideRegion() throws {
    // 左半分=白（人物）、右半分=黒（背景）のマスクで内外判定を検証する
    let size = 100
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { throw CocoaError(.coderInvalidValue) }
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size / 2, height: size))
    let mask = try #require(context.makeImage())

    let sampler = try #require(PersonMaskSampler(maskImage: mask))

    #expect(sampler.contains(x: 0.25, y: 0.5))
    #expect(!sampler.contains(x: 0.75, y: 0.5))
    #expect(!sampler.contains(x: 1.5, y: 0.5))
    // 緩衝付き判定: 境界(x=0.5)のすぐ外側は許容し、遠く離れた点は拒否する
    #expect(sampler.containsNear(x: 0.52, y: 0.5))
    #expect(!sampler.containsNear(x: 0.9, y: 0.5))
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

@Test func mosaicEngineSupportsAllFillPatterns() throws {
    // 全パターン+共通パラメータ（透明度・色・細かさ・輪郭ぼかし・帯設定）で出力サイズが保たれることを検証する
    let image = try makePatternImage(width: 100, height: 80)
    let patternTile = try makeSolidImage(width: 16, height: 16)
    let roi = MosaicROI(
        rect: NormalizedRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
        confidence: 1,
        source: "manual",
        shape: .rectangle
    )
    let engine = MosaicEngine()

    for pattern in MosaicFillPattern.allCases {
        var style = MosaicStyle()
        style.pattern = pattern
        style.opacity = 0.7
        style.tintColor = (red: 1.0, green: 0.4, blue: 0.7)
        style.blockScale = 16
        style.edgeFeather = 4
        style.stripeWidth = 8
        style.stripeSpacing = 6
        style.patternImage = patternTile

        let output = try engine.applyMosaic(to: image, rois: [roi], style: style)

        #expect(output.width == 100, "パターン \(pattern.rawValue) で幅が変化")
        #expect(output.height == 80, "パターン \(pattern.rawValue) で高さが変化")
    }
}

@Test func mosaicStyleStripeMaskAlternatesBands() {
    // 帯8px+間隔4pxの縦ボーダーで、縞マスクが生成されることを検証する
    var style = MosaicStyle()
    style.pattern = .stripesVertical
    style.stripeWidth = 8
    style.stripeSpacing = 4

    let mask = MosaicEngine.stripePatternMask(style: style, extent: CGRect(x: 0, y: 0, width: 64, height: 64))

    #expect(mask != nil)
    #expect(MosaicEngine.stripePatternMask(
        style: MosaicStyle(),
        extent: CGRect(x: 0, y: 0, width: 64, height: 64)
    ) == nil)
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

@Test func libraryEngineDeletesItemsAndFiles() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("Library")
    let engine = LibraryEngine(rootURL: root)
    let image = try makeSolidImage(width: 32, height: 24)

    let itemA = try engine.importOriginal(image, sourceName: "a.png")
    let itemB = try engine.importOriginal(image, sourceName: "b.png")
    _ = try engine.saveProcessedImage(image, rois: [], for: itemA.id)
    let processedURLA = engine.processedURL(for: try #require(engine.loadItems().first { $0.id == itemA.id }))

    try engine.deleteItems(ids: [itemA.id])

    let remaining = try engine.loadItems()
    #expect(remaining.count == 1)
    #expect(remaining[0].id == itemB.id)
    #expect(!FileManager.default.fileExists(atPath: engine.originalURL(for: itemA).path))
    if let processedURLA {
        #expect(!FileManager.default.fileExists(atPath: processedURLA.path))
    }
}

@Test func yoloDecoderDecodesAttributeMajorOutput() {
    // アンカー2・クラス3の属性メジャー配列（4+3=7行 × 2列）を合成してデコードを検証する。
    // アンカー0: cx=320,cy=320,w=64,h=64, スコア(0.9, 0.1, 0.05) → class0
    // アンカー1: 低信頼（全クラス0.1）→ 閾値0.3で除外
    let output: [Float] = [
        320, 100,   // cx
        320, 100,   // cy
        64, 32,     // w
        64, 32,     // h
        0.9, 0.1,   // class0
        0.1, 0.1,   // class1
        0.05, 0.1   // class2
    ]

    let detections = YOLODecoder.decode(output: output, classCount: 3, confidenceThreshold: 0.3)

    #expect(detections.count == 1)
    let detection = detections[0]
    #expect(detection.classIndex == 0)
    #expect(abs(detection.score - 0.9) < 0.001)
    #expect(abs(detection.rect.x - (0.5 - 0.05)) < 0.001)
    #expect(abs(detection.rect.width - 0.1) < 0.001)
}

@Test func yoloDecoderNMSKeepsHighestScorePerOverlap() {
    let a = YOLODecoder.Detection(
        rect: NormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), score: 0.9, classIndex: 0)
    let b = YOLODecoder.Detection(
        rect: NormalizedRect(x: 0.41, y: 0.41, width: 0.2, height: 0.2), score: 0.6, classIndex: 0)
    let c = YOLODecoder.Detection(
        rect: NormalizedRect(x: 0.41, y: 0.41, width: 0.2, height: 0.2), score: 0.5, classIndex: 1)

    let kept = YOLODecoder.nonMaxSuppression([a, b, c], iouThreshold: 0.7)

    // 同クラスの重複bは抑制、別クラスcは残る
    #expect(kept.count == 2)
    #expect(kept.contains { $0.classIndex == 0 && $0.score == 0.9 })
    #expect(kept.contains { $0.classIndex == 1 })
}

@Test func letterboxTransformMapsCoordinatesBackToImage() {
    // 縦長画像（幅320x高さ640相当）: scale=1.0, contentW=320, padX=160, padY=0 のレターボックスを想定
    let letterbox = LetterboxTransform(padX: 160, padY: 0, contentWidth: 320, contentHeight: 640)
    // モデル空間の中央 (320,320) を中心とする 64x64 の矩形
    let modelRect = NormalizedRect(x: (320.0 - 32) / 640, y: (320.0 - 32) / 640, width: 64.0 / 640, height: 64.0 / 640)

    let imageRect = letterbox.imageRect(from: modelRect, inputSize: 640)

    // 画像空間では中央 (0.5, 0.5)、幅 64/320=0.2、高さ 64/640=0.1
    #expect(abs((imageRect.x + imageRect.width / 2) - 0.5) < 0.001)
    #expect(abs((imageRect.y + imageRect.height / 2) - 0.5) < 0.001)
    #expect(abs(imageRect.width - 0.2) < 0.001)
    #expect(abs(imageRect.height - 0.1) < 0.001)
}

@Test func regionForegroundSegmentEngineFallsBackOnPlainImage() throws {
    // 単色画像には前景が無いため、図形ベースへのフォールバック経路を検証する
    let image = try makeSolidImage(width: 120, height: 90)
    let roi = MosaicROI(
        rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
        confidence: 1,
        source: "manual",
        shape: .ellipse
    )

    let output = try MosaicEngine().applyMosaic(
        to: image,
        rois: [roi],
        scale: 12,
        segmentEngine: RegionForegroundSegmentEngine()
    )

    #expect(output.width == 120)
    #expect(output.height == 90)
}

@Test func animeCensorDetectorLoadsModelAndRunsOnPlainImage() throws {
    // 同梱ONNXモデルのロードと推論実行のスモークテスト（単色画像では検出0件のはず）
    let detector = try AnimeCensorDetector()
    let image = try makeSolidImage(width: 320, height: 240)

    let rois = try detector.detect(in: image)

    #expect(rois.isEmpty)
}

@Test func animePersonDetectorLoadsModelAndRunsOnPlainImage() throws {
    // アニメ人物検出モデルのロードと推論実行のスモークテスト（単色画像では検出0件のはず）
    let detector = try AnimePersonDetector()
    let image = try makeSolidImage(width: 320, height: 240)

    let persons = try detector.detectPersons(in: image)

    #expect(persons.isEmpty)
}

@Test func domainClassifierSeparatesFlatAndTexturedImages() throws {
    // 単色（平坦=イラスト的）とテクスチャ（隣接差分が大きい=実写的）を判別できることを検証する
    let flat = try makeSolidImage(width: 200, height: 200)
    let textured = try makePatternImage(width: 200, height: 200)

    #expect(DomainClassifier.classify(flat) == .illustration)
    #expect(DomainClassifier.classify(textured) == .photo)
}

@Test func domainClassifierDetectsMonochromeManga() throws {
    // 白黒漫画風の合成画像（紙白背景+黒線+グレー塗り面）をイラスト/漫画と判定できることを検証する
    let size = 200
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CocoaError(.coderInvalidValue) }
    // 紙白背景
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    // グレーのトーン風塗り面
    context.setFillColor(CGColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 30, y: 30, width: 80, height: 100))
    // 黒い輪郭線
    context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.setLineWidth(3)
    context.stroke(CGRect(x: 20, y: 20, width: 150, height: 150))
    context.stroke(CGRect(x: 60, y: 90, width: 90, height: 60))
    let manga = try #require(context.makeImage())

    #expect(DomainClassifier.classify(manga) == .illustration)
}

@Test func yoloDatasetExporterWritesImagesAndLabels() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let libraryRoot = root.appendingPathComponent("Library")
    let exportRoot = root.appendingPathComponent("Dataset")
    let engine = LibraryEngine(rootURL: libraryRoot)
    let image = try makeSolidImage(width: 64, height: 48)

    let item = try engine.importOriginal(image, sourceName: "sample.png")
    let roi = MosaicROI(
        rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
        confidence: 1,
        source: "manual",
        shape: .ellipse,
        category: .nipple
    )
    _ = try engine.saveProcessedImage(image, rois: [roi], for: item.id)

    let result = try YOLODatasetExporter.export(items: try engine.loadItems(), libraryEngine: engine, to: exportRoot)

    #expect(result.imageCount == 1)
    #expect(result.roiCount == 1)
    let label = try String(
        contentsOf: exportRoot.appendingPathComponent("labels/\(item.id.uuidString).txt"),
        encoding: .utf8
    )
    let nippleIndex = MosaicTargetCategory.allCases.firstIndex(of: .nipple)!
    #expect(label.hasPrefix("\(nippleIndex) 0.500000 0.500000 0.500000 0.500000"))
    #expect(FileManager.default.fileExists(atPath: exportRoot.appendingPathComponent("images/\(item.id.uuidString).png").path))
    #expect(FileManager.default.fileExists(atPath: exportRoot.appendingPathComponent("classes.txt").path))
    #expect(FileManager.default.fileExists(atPath: exportRoot.appendingPathComponent("dataset.yaml").path))
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
