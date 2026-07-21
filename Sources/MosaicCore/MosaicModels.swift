import CoreGraphics
import Foundation

public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect, imageSize: CGSize) {
        self.x = rect.minX / imageSize.width
        self.y = rect.minY / imageSize.height
        self.width = rect.width / imageSize.width
        self.height = rect.height / imageSize.height
    }

    public func clamped() -> NormalizedRect {
        let minX = max(0, min(1, x))
        let minY = max(0, min(1, y))
        let maxX = max(minX, min(1, x + width))
        let maxY = max(minY, min(1, y + height))
        return NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public func cgRect(imageSize: CGSize, origin: CoordinateOrigin = .topLeft) -> CGRect {
        let rect = clamped()
        let width = rect.width * imageSize.width
        let height = rect.height * imageSize.height
        let x = rect.x * imageSize.width
        let y: Double
        switch origin {
        case .topLeft:
            y = rect.y * imageSize.height
        case .bottomLeft:
            y = (1 - rect.y - rect.height) * imageSize.height
        }
        return CGRect(x: x, y: y, width: width, height: height).integral
    }
}

public enum CoordinateOrigin: Sendable {
    case topLeft
    case bottomLeft
}

public struct MosaicROI: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var rect: NormalizedRect
    public var confidence: Double
    public var source: String

    public init(id: UUID = UUID(), rect: NormalizedRect, confidence: Double, source: String) {
        self.id = id
        self.rect = rect.clamped()
        self.confidence = confidence
        self.source = source
    }
}

public struct PoseHint: Codable, Equatable, Sendable {
    public var bodyBounds: NormalizedRect
    public var lowerBodyBounds: NormalizedRect

    public init(bodyBounds: NormalizedRect, lowerBodyBounds: NormalizedRect) {
        self.bodyBounds = bodyBounds
        self.lowerBodyBounds = lowerBodyBounds
    }
}

public struct MosaicHistoryEntry: Codable, Equatable, Sendable {
    public var createdAt: Date
    public var imageName: String
    public var imagePixelWidth: Int
    public var imagePixelHeight: Int
    public var rois: [MosaicROI]
    public var algorithmVersion: String

    public init(
        createdAt: Date = Date(),
        imageName: String,
        imagePixelWidth: Int,
        imagePixelHeight: Int,
        rois: [MosaicROI],
        algorithmVersion: String = "mvp-heuristic-1"
    ) {
        self.createdAt = createdAt
        self.imageName = imageName
        self.imagePixelWidth = imagePixelWidth
        self.imagePixelHeight = imagePixelHeight
        self.rois = rois
        self.algorithmVersion = algorithmVersion
    }
}
