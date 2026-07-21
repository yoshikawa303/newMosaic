import AppKit
import CoreGraphics
import Foundation

public enum ImageLoaderError: Error, LocalizedError {
    case cannotLoad(URL)
    case cannotCreateCGImage(URL)

    public var errorDescription: String? {
        switch self {
        case .cannotLoad(let url):
            return "画像を読み込めません: \(url.path)"
        case .cannotCreateCGImage(let url):
            return "CGImageを作成できません: \(url.path)"
        }
    }
}

public struct LoadedImage: Sendable {
    public var url: URL
    public var cgImage: CGImage
    public var pixelSize: CGSize

    public init(url: URL, cgImage: CGImage) {
        self.url = url
        self.cgImage = cgImage
        self.pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
    }
}

public final class ImageLoader {
    public init() {}

    public func loadImage(from url: URL) throws -> LoadedImage {
        guard let image = NSImage(contentsOf: url) else {
            throw ImageLoaderError.cannotLoad(url)
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageLoaderError.cannotCreateCGImage(url)
        }
        return LoadedImage(url: url, cgImage: cgImage)
    }
}
