import AppKit
import CoreGraphics
import Foundation

/// ユーザーのモザイク範囲選択1件分の学習サンプル。
/// 画像全体は保存せず、ROI矩形・人物相対位置・知覚ハッシュ・小型パッチ画像のみをローカル保存する。
public struct ROITrainingSample: Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var category: MosaicTargetCategory
    public var shape: ROIShape
    public var rect: NormalizedRect
    public var personRelativeRect: NormalizedRect?
    public var patchHash: UInt64
    public var patchFileName: String?
    public var isPositive: Bool
    public var source: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        category: MosaicTargetCategory,
        shape: ROIShape,
        rect: NormalizedRect,
        personRelativeRect: NormalizedRect?,
        patchHash: UInt64,
        patchFileName: String? = nil,
        isPositive: Bool,
        source: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.category = category
        self.shape = shape
        self.rect = rect
        self.personRelativeRect = personRelativeRect
        self.patchHash = patchHash
        self.patchFileName = patchFileName
        self.isPositive = isPositive
        self.source = source
    }
}

public struct LearningCategoryStats: Codable, Equatable, Sendable {
    public var sampleCount: Int
    public var personGrid: [Int]
    public var imageGrid: [Int]
    public var meanWidth: Double
    public var meanHeight: Double

    static func empty(gridCells: Int) -> LearningCategoryStats {
        LearningCategoryStats(
            sampleCount: 0,
            personGrid: Array(repeating: 0, count: gridCells),
            imageGrid: Array(repeating: 0, count: gridCells),
            meanWidth: 0,
            meanHeight: 0
        )
    }
}

public struct LearningStats: Codable, Equatable, Sendable {
    public var categories: [String: LearningCategoryStats]
    public var updatedAt: Date
}

/// モザイク範囲選択のローカル学習エンジン（DETECTION_IMPROVEMENT_PLAN.md Phase 4）。
///
/// 収集: 保存時に採用ROI（正例）と、自動候補のうちユーザーが削除したROI（負例）を記録する。
/// 学習: カテゴリごとに (1) 人物相対/画像相対の選択位置頻度グリッド、(2) 平均サイズ、
///       (3) パッチの知覚ハッシュ（dHash 64bit）を蓄積する。
/// 推論: 候補生成時に位置頻度と近似ハッシュ参照で信頼度を加減点し、
///       高頻度位置に候補が無ければ記憶サイズでROIを追加提案する。
/// 処理負荷: 集計は保存時のみO(全サンプル)、推論時はグリッド参照+ハッシュ線形走査（数千件で1ms級）。
/// プライバシー: すべてローカル保存・外部送信なし。パッチ画像は最大256pxに縮小して保存する。
public final class LearningEngine {
    public static let gridSize = 8
    private static let gridCells = gridSize * gridSize

    public let rootURL: URL
    private let samplesURL: URL
    private let statsURL: URL
    private let patchesURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedSamples: [ROITrainingSample]?
    private var cachedStats: LearningStats?

    public init(rootURL: URL) {
        self.rootURL = rootURL
        self.samplesURL = rootURL.appendingPathComponent("samples.jsonl")
        self.statsURL = rootURL.appendingPathComponent("stats.json")
        self.patchesURL = rootURL.appendingPathComponent("Patches")
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultStore() throws -> LearningEngine {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return LearningEngine(rootURL: support.appendingPathComponent("newMosaic/Learning"))
    }

    // MARK: - 収集

    @discardableResult
    public func record(
        acceptedROIs: [MosaicROI],
        rejectedROIs: [MosaicROI],
        persons: [NormalizedRect],
        image: CGImage
    ) throws -> Int {
        var newSamples: [ROITrainingSample] = []
        for roi in acceptedROIs {
            newSamples.append(try makeSample(from: roi, isPositive: true, persons: persons, image: image))
        }
        for roi in rejectedROIs {
            newSamples.append(try makeSample(from: roi, isPositive: false, persons: persons, image: image))
        }
        guard !newSamples.isEmpty else { return 0 }

        let existing = try loadSamples()
        try appendToFile(newSamples)
        cachedSamples = existing + newSamples
        try rebuildStats()
        return newSamples.count
    }

    private func makeSample(
        from roi: MosaicROI,
        isPositive: Bool,
        persons: [NormalizedRect],
        image: CGImage
    ) throws -> ROITrainingSample {
        let id = UUID()
        let patchFileName = try? savePatch(of: image, in: roi.rect, id: id, isPositive: isPositive)
        return ROITrainingSample(
            id: id,
            category: roi.category,
            shape: roi.shape,
            rect: roi.rect,
            personRelativeRect: Self.personRelativeRect(of: roi.rect, persons: persons),
            patchHash: Self.dHash(of: image, in: roi.rect) ?? 0,
            patchFileName: patchFileName,
            isPositive: isPositive,
            source: roi.source
        )
    }

    static func personRelativeRect(of rect: NormalizedRect, persons: [NormalizedRect]) -> NormalizedRect? {
        var best: (person: NormalizedRect, overlap: Double)?
        for person in persons where person.width > 0.01 && person.height > 0.01 {
            let overlap = rect.intersection(person)?.area ?? 0
            if overlap > 0, best == nil || overlap > best!.overlap {
                best = (person, overlap)
            }
        }
        guard let person = best?.person else { return nil }
        return NormalizedRect(
            x: (rect.x - person.x) / person.width,
            y: (rect.y - person.y) / person.height,
            width: rect.width / person.width,
            height: rect.height / person.height
        )
    }

    private func appendToFile(_ samples: [ROITrainingSample]) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var lines = Data()
        for sample in samples {
            lines.append(try encoder.encode(sample))
            lines.append(Data("\n".utf8))
        }
        if !FileManager.default.fileExists(atPath: samplesURL.path) {
            FileManager.default.createFile(atPath: samplesURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: samplesURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: lines)
    }

    /// ROIパッチを最大256pxへ縮小しPNGで保存する（Phase 2の学習データ整備を兼ねる。ローカル保存のみ）。
    private func savePatch(of image: CGImage, in rect: NormalizedRect, id: UUID, isPositive: Bool) throws -> String {
        let imageSize = CGSize(width: image.width, height: image.height)
        let pixelRect = rect.clamped().cgRect(imageSize: imageSize, origin: .topLeft)
        guard pixelRect.width >= 1, pixelRect.height >= 1, let crop = image.cropping(to: pixelRect) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let directory = patchesURL.appendingPathComponent(isPositive ? "Positives" : "Negatives")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let maxDimension: CGFloat = 256
        let scale = min(1, maxDimension / max(pixelRect.width, pixelRect.height))
        let targetSize = NSSize(width: max(1, pixelRect.width * scale), height: max(1, pixelRect.height * scale))
        let scaled = NSImage(size: targetSize)
        scaled.lockFocus()
        NSImage(cgImage: crop, size: .zero).draw(in: NSRect(origin: .zero, size: targetSize))
        scaled.unlockFocus()
        guard let tiff = scaled.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let fileName = "\(id.uuidString).png"
        try png.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        return (isPositive ? "Positives/" : "Negatives/") + fileName
    }

    // MARK: - 統計

    private func rebuildStats() throws {
        let samples = try loadSamples()
        var categories: [String: LearningCategoryStats] = [:]
        for sample in samples where sample.isPositive {
            var stats = categories[sample.category.rawValue] ?? .empty(gridCells: Self.gridCells)
            let count = Double(stats.sampleCount)
            stats.meanWidth = (stats.meanWidth * count + sample.rect.width) / (count + 1)
            stats.meanHeight = (stats.meanHeight * count + sample.rect.height) / (count + 1)
            stats.sampleCount += 1
            stats.imageGrid[Self.gridIndex(
                x: sample.rect.x + sample.rect.width / 2,
                y: sample.rect.y + sample.rect.height / 2
            )] += 1
            if let relative = sample.personRelativeRect {
                stats.personGrid[Self.gridIndex(
                    x: relative.x + relative.width / 2,
                    y: relative.y + relative.height / 2
                )] += 1
            }
            categories[sample.category.rawValue] = stats
        }
        let stats = LearningStats(categories: categories, updatedAt: Date())
        cachedStats = stats
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try encoder.encode(stats).write(to: statsURL, options: .atomic)
    }

    public func loadSamples() throws -> [ROITrainingSample] {
        if let cachedSamples { return cachedSamples }
        guard FileManager.default.fileExists(atPath: samplesURL.path) else {
            cachedSamples = []
            return []
        }
        let content = try String(contentsOf: samplesURL, encoding: .utf8)
        let samples = content.split(separator: "\n").compactMap {
            try? decoder.decode(ROITrainingSample.self, from: Data($0.utf8))
        }
        cachedSamples = samples
        return samples
    }

    public func loadStats() -> LearningStats? {
        if let cachedStats { return cachedStats }
        guard let data = try? Data(contentsOf: statsURL) else { return nil }
        cachedStats = try? decoder.decode(LearningStats.self, from: data)
        return cachedStats
    }

    // MARK: - 推論（候補の信頼度調整と追加提案）

    public func refineCandidates(
        _ rois: [MosaicROI],
        persons: [NormalizedRect],
        image: CGImage
    ) -> [MosaicROI] {
        guard let stats = loadStats(), !stats.categories.isEmpty else { return rois }
        let samples = (try? loadSamples()) ?? []
        let positives = Dictionary(grouping: samples.filter { $0.isPositive && $0.patchHash != 0 }, by: \.category)
        let negatives = Dictionary(grouping: samples.filter { !$0.isPositive && $0.patchHash != 0 }, by: \.category)

        var result = rois.map { roi -> MosaicROI in
            guard roi.source != "manual" else { return roi }
            var updated = roi

            // 1) 選択位置頻度によるブースト（人物相対を優先、人物が無ければ画像相対）
            if let categoryStats = stats.categories[roi.category.rawValue], categoryStats.sampleCount >= 3 {
                let frequency: Double
                if let relative = Self.personRelativeRect(of: roi.rect, persons: persons) {
                    let cell = Self.gridIndex(
                        x: relative.x + relative.width / 2,
                        y: relative.y + relative.height / 2
                    )
                    frequency = Double(categoryStats.personGrid[cell]) / Double(categoryStats.sampleCount)
                } else {
                    let cell = Self.gridIndex(
                        x: roi.rect.x + roi.rect.width / 2,
                        y: roi.rect.y + roi.rect.height / 2
                    )
                    frequency = Double(categoryStats.imageGrid[cell]) / Double(categoryStats.sampleCount)
                }
                updated.confidence = min(1, updated.confidence + min(0.3, frequency * 0.6))
            }

            // 2) 近似画像参照（知覚ハッシュのハミング距離）によるブースト/ペナルティ
            if let hash = Self.dHash(of: image, in: roi.rect), hash != 0 {
                if positives[roi.category]?.contains(where: { Self.hammingDistance($0.patchHash, hash) <= 10 }) == true {
                    updated.confidence = min(1, updated.confidence + 0.2)
                }
                if negatives[roi.category]?.contains(where: { Self.hammingDistance($0.patchHash, hash) <= 6 }) == true {
                    updated.confidence = max(0.05, updated.confidence - 0.25)
                }
            }
            return updated
        }

        result += learnedProposals(existing: result, stats: stats, persons: persons)
        return result
    }

    /// 学習した高頻度セルに既存候補が無い場合、記憶した平均サイズでROIを追加提案する。
    private func learnedProposals(
        existing: [MosaicROI],
        stats: LearningStats,
        persons: [NormalizedRect]
    ) -> [MosaicROI] {
        var proposals: [MosaicROI] = []
        var occupied = existing

        for (categoryKey, categoryStats) in stats.categories.sorted(by: { $0.key < $1.key }) {
            guard let category = MosaicTargetCategory(rawValue: categoryKey),
                  categoryStats.sampleCount >= 5,
                  categoryStats.meanWidth > 0.001, categoryStats.meanHeight > 0.001 else { continue }

            let grid = persons.isEmpty ? categoryStats.imageGrid : categoryStats.personGrid
            let anchors: [NormalizedRect] = persons.isEmpty
                ? [NormalizedRect(x: 0, y: 0, width: 1, height: 1)]
                : persons

            for (cell, count) in grid.enumerated() where count >= 3 {
                let frequency = Double(count) / Double(categoryStats.sampleCount)
                guard frequency >= 0.3 else { continue }
                let cellCenter = Self.cellCenter(cell)
                for anchor in anchors {
                    guard proposals.count < 8 else { return proposals }
                    let center = CGPoint(
                        x: anchor.x + cellCenter.x * anchor.width,
                        y: anchor.y + cellCenter.y * anchor.height
                    )
                    let rect = NormalizedRect(
                        x: center.x - categoryStats.meanWidth / 2,
                        y: center.y - categoryStats.meanHeight / 2,
                        width: categoryStats.meanWidth,
                        height: categoryStats.meanHeight
                    ).clamped()
                    let overlapsExisting = occupied.contains {
                        $0.category == category && $0.rect.intersection(rect) != nil
                    }
                    guard !overlapsExisting else { continue }
                    let proposal = MosaicROI(
                        rect: rect,
                        confidence: 0.35,
                        source: "learned-prior",
                        shape: .ellipse,
                        category: category
                    )
                    proposals.append(proposal)
                    occupied.append(proposal)
                }
            }
        }
        return proposals
    }

    // MARK: - ユーティリティ

    static func gridIndex(x: Double, y: Double) -> Int {
        let clampedX = min(max(x, 0), 0.999)
        let clampedY = min(max(y, 0), 0.999)
        let col = Int(clampedX * Double(gridSize))
        let row = Int(clampedY * Double(gridSize))
        return row * gridSize + col
    }

    static func cellCenter(_ index: Int) -> CGPoint {
        let row = index / gridSize
        let col = index % gridSize
        return CGPoint(
            x: (Double(col) + 0.5) / Double(gridSize),
            y: (Double(row) + 0.5) / Double(gridSize)
        )
    }

    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// ROIパッチの知覚ハッシュ（dHash 64bit）。9x8グレースケールへ縮小し隣接画素比較でビット列を作る。
    public static func dHash(of image: CGImage, in rect: NormalizedRect) -> UInt64? {
        let imageSize = CGSize(width: image.width, height: image.height)
        let pixelRect = rect.clamped().cgRect(imageSize: imageSize, origin: .topLeft)
        guard pixelRect.width >= 1, pixelRect.height >= 1, let crop = image.cropping(to: pixelRect) else { return nil }

        let width = 9
        let height = 8
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }

        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                if pixels[y * width + x] > pixels[y * width + x + 1] {
                    hash |= (1 << bit)
                }
                bit += 1
            }
        }
        return hash
    }
}
