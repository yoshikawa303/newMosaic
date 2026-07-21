import AppKit
import CoreGraphics
import Foundation

public enum MosaicLibraryError: Error, LocalizedError {
    case pngEncodingFailed
    case itemNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .pngEncodingFailed:
            return "PNG画像を保存できませんでした"
        case .itemNotFound(let id):
            return "ライブラリアイテムが見つかりません: \(id.uuidString)"
        }
    }
}

public struct MosaicLibraryItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var sourceName: String
    public var originalRelativePath: String
    public var processedRelativePath: String?
    public var imagePixelWidth: Int
    public var imagePixelHeight: Int
    public var rois: [MosaicROI]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourceName: String,
        originalRelativePath: String,
        processedRelativePath: String? = nil,
        imagePixelWidth: Int,
        imagePixelHeight: Int,
        rois: [MosaicROI] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceName = sourceName
        self.originalRelativePath = originalRelativePath
        self.processedRelativePath = processedRelativePath
        self.imagePixelWidth = imagePixelWidth
        self.imagePixelHeight = imagePixelHeight
        self.rois = rois
    }
}

public final class LibraryEngine {
    public let rootURL: URL
    private let indexURL: URL
    private let originalsURL: URL
    private let processedURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootURL: URL) {
        self.rootURL = rootURL
        self.indexURL = rootURL.appendingPathComponent("index.json")
        self.originalsURL = rootURL.appendingPathComponent("Originals")
        self.processedURL = rootURL.appendingPathComponent("Processed")
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultLibrary() throws -> LibraryEngine {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return LibraryEngine(rootURL: support.appendingPathComponent("newMosaic/Library"))
    }

    public func loadItems() throws -> [MosaicLibraryItem] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        let data = try Data(contentsOf: indexURL)
        return try decoder.decode([MosaicLibraryItem].self, from: data)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func importOriginal(_ image: CGImage, sourceName: String) throws -> MosaicLibraryItem {
        try ensureDirectories()
        var items = try loadItems()
        let id = UUID()
        let relative = "Originals/\(id.uuidString)_original.png"
        try savePNG(image, to: rootURL.appendingPathComponent(relative))
        let item = MosaicLibraryItem(
            id: id,
            sourceName: sourceName,
            originalRelativePath: relative,
            imagePixelWidth: image.width,
            imagePixelHeight: image.height
        )
        items.insert(item, at: 0)
        try saveItems(items)
        return item
    }

    public func saveProcessedImage(_ image: CGImage, rois: [MosaicROI], for itemID: UUID) throws -> MosaicLibraryItem {
        try ensureDirectories()
        var items = try loadItems()
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            throw MosaicLibraryError.itemNotFound(itemID)
        }
        let relative = "Processed/\(itemID.uuidString)_processed.png"
        try savePNG(image, to: rootURL.appendingPathComponent(relative))
        items[index].processedRelativePath = relative
        items[index].updatedAt = Date()
        items[index].rois = rois
        try saveItems(items)
        return items[index]
    }

    public func originalURL(for item: MosaicLibraryItem) -> URL {
        rootURL.appendingPathComponent(item.originalRelativePath)
    }

    public func processedURL(for item: MosaicLibraryItem) -> URL? {
        item.processedRelativePath.map { rootURL.appendingPathComponent($0) }
    }

    private func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: originalsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: processedURL, withIntermediateDirectories: true)
    }

    private func saveItems(_ items: [MosaicLibraryItem]) throws {
        try ensureDirectories()
        let sorted = items.sorted { $0.updatedAt > $1.updatedAt }
        let data = try encoder.encode(sorted)
        try data.write(to: indexURL, options: .atomic)
    }

    private func savePNG(_ image: CGImage, to url: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw MosaicLibraryError.pngEncodingFailed
        }
        try data.write(to: url, options: .atomic)
    }
}
