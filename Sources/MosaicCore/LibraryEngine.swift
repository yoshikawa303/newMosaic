import AppKit
import CoreGraphics
import Foundation
import ImageIO

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
    /// フォルダ一括登録された参照リンク元の絶対パス（nil=従来のコピー取り込み）。
    /// リンク登録では元画像をライブラリへコピーせず、参照先をそのまま読み込む。
    /// ROI・レイヤ情報は従来どおりアプリ側（索引）で管理する。
    public var linkedOriginalPath: String?
    public var imagePixelWidth: Int
    public var imagePixelHeight: Int
    public var rois: [MosaicROI]

    /// リンク登録されたアイテムか。
    public var isLinked: Bool { linkedOriginalPath != nil }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourceName: String,
        originalRelativePath: String,
        processedRelativePath: String? = nil,
        linkedOriginalPath: String? = nil,
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
        self.linkedOriginalPath = linkedOriginalPath
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
    private let patternsURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// index.jsonへの読み取り→変更→書き込みを排他制御するための直列キュー。
    /// このクラス自体には元々同期機構が無く、メインアクター側の単発保存（ROI保存・削除等）と
    /// 一括処理のバックグラウンドTaskが同一インスタンスへ並行アクセスすると、
    /// 後勝ちのsaveItemsで一方の更新が消えるTOCTOU競合があった（コードレビューで検出）。
    private let syncQueue = DispatchQueue(label: "jp.yoshikawa303.newMosaic.LibraryEngine.sync")

    public init(rootURL: URL) {
        self.rootURL = rootURL
        self.indexURL = rootURL.appendingPathComponent("index.json")
        self.originalsURL = rootURL.appendingPathComponent("Originals")
        self.processedURL = rootURL.appendingPathComponent("Processed")
        self.patternsURL = rootURL.appendingPathComponent("Patterns")
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
        try syncQueue.sync { try loadItemsUnsynchronized() }
    }

    /// `syncQueue`内からのみ呼ぶこと（read-modify-writeの一部として使うための非同期化なし版）。
    private func loadItemsUnsynchronized() throws -> [MosaicLibraryItem] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        let data = try Data(contentsOf: indexURL)
        return try decoder.decode([MosaicLibraryItem].self, from: data)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func importOriginal(_ image: CGImage, sourceName: String) throws -> MosaicLibraryItem {
        try syncQueue.sync {
            try ensureDirectories()
            var items = try loadItemsUnsynchronized()
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
    }

    public func saveProcessedImage(_ image: CGImage, rois: [MosaicROI], for itemID: UUID) throws -> MosaicLibraryItem {
        try syncQueue.sync {
            try ensureDirectories()
            var items = try loadItemsUnsynchronized()
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
    }

    /// 指定IDのアイテムをライブラリから削除する（索引・元画像PNG・加工後PNGすべて）。
    /// 存在しないIDは無視する。ファイル削除に失敗しても索引からは取り除く。
    public func deleteItems(ids: [UUID]) throws {
        try syncQueue.sync {
            let idSet = Set(ids)
            var items = try loadItemsUnsynchronized()
            let targets = items.filter { idSet.contains($0.id) }
            guard !targets.isEmpty else { return }
            for item in targets {
                // リンク登録アイテムの参照先（ユーザーの元ファイル）は削除しない
                if !item.isLinked {
                    try? FileManager.default.removeItem(at: originalURL(for: item))
                }
                if let processedURL = processedURL(for: item) {
                    try? FileManager.default.removeItem(at: processedURL)
                }
            }
            items.removeAll { idSet.contains($0.id) }
            try saveItems(items)
        }
    }

    public func originalURL(for item: MosaicLibraryItem) -> URL {
        if let linked = item.linkedOriginalPath {
            return URL(fileURLWithPath: linked)
        }
        return rootURL.appendingPathComponent(item.originalRelativePath)
    }

    // MARK: - リンク登録（フォルダ一括登録）

    /// 外部画像ファイルをコピーせずリンクとしてライブラリへ登録する。
    /// 同一パスが登録済みの場合は既存アイテムを返す（重複登録しない）。
    public func importLinked(url: URL) throws -> MosaicLibraryItem {
        try syncQueue.sync {
            try ensureDirectories()
            var items = try loadItemsUnsynchronized()
            if let existing = items.first(where: { $0.linkedOriginalPath == url.path }) {
                return existing
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "画像を読み込めません: \(url.lastPathComponent)"
                ])
            }
            let item = MosaicLibraryItem(
                sourceName: url.lastPathComponent,
                originalRelativePath: "",
                linkedOriginalPath: url.path,
                imagePixelWidth: width,
                imagePixelHeight: height
            )
            items.insert(item, at: 0)
            try saveItems(items)
            return item
        }
    }

    /// リンク切れ（参照先ファイルが存在しない）か。コピー取り込みアイテムは常にfalse。
    public func isLinkBroken(_ item: MosaicLibraryItem) -> Bool {
        guard let linked = item.linkedOriginalPath else { return false }
        return !FileManager.default.fileExists(atPath: linked)
    }

    /// リンク切れのアイテム一覧。
    public func brokenLinkedItems() throws -> [MosaicLibraryItem] {
        try loadItems().filter { isLinkBroken($0) }
    }

    /// リンク先を新しいファイルへ張り替える（画像単位のリンク切れ修正）。
    @discardableResult
    public func relink(id: UUID, to url: URL) throws -> MosaicLibraryItem {
        try syncQueue.sync {
            var items = try loadItemsUnsynchronized()
            guard let index = items.firstIndex(where: { $0.id == id }) else {
                throw MosaicLibraryError.itemNotFound(id)
            }
            items[index].linkedOriginalPath = url.path
            items[index].sourceName = url.lastPathComponent
            items[index].updatedAt = Date()
            try saveItems(items)
            return items[index]
        }
    }

    /// フォルダ内からファイル名一致で参照先を探し、リンク切れを一括修正する。修正できた件数を返す。
    public func repairBrokenLinks(searchFolder: URL) throws -> Int {
        try syncQueue.sync {
        var items = try loadItemsUnsynchronized()
        let manager = FileManager.default
        var candidates: [String: URL] = [:]
        if let enumerator = manager.enumerator(at: searchFolder, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                candidates[fileURL.lastPathComponent] = fileURL
            }
        }
        var repaired = 0
        for index in items.indices {
            guard let linked = items[index].linkedOriginalPath,
                  !manager.fileExists(atPath: linked),
                  let replacement = candidates[items[index].sourceName] else { continue }
            items[index].linkedOriginalPath = replacement.path
            items[index].updatedAt = Date()
            repaired += 1
        }
        if repaired > 0 {
            try saveItems(items)
        }
        return repaired
        }
    }

    public func processedURL(for item: MosaicLibraryItem) -> URL? {
        item.processedRelativePath.map { rootURL.appendingPathComponent($0) }
    }

    /// ROI別の任意パターン画像をライブラリと一緒に移行できる場所へ保存する。
    @discardableResult
    public func savePatternImage(_ image: CGImage, identifier: String) throws -> URL {
        try ensureDirectories()
        let url = patternURL(identifier: identifier)
        try savePNG(image, to: url)
        return url
    }

    public func patternURL(identifier: String) -> URL {
        let safeIdentifier = identifier.replacingOccurrences(of: "/", with: "_")
        return patternsURL.appendingPathComponent("\(safeIdentifier).png")
    }

    private func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: originalsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: processedURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: patternsURL, withIntermediateDirectories: true)
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
