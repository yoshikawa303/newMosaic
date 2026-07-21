import CoreGraphics
import Foundation

public struct MosaicMask: Equatable, Sendable {
    public var roi: MosaicROI
    public var imageRect: CGRect

    public init(roi: MosaicROI, imageSize: CGSize) {
        self.roi = roi
        self.imageRect = roi.rect.cgRect(imageSize: imageSize, origin: .bottomLeft)
    }
}

public protocol Segmenting {
    func createMasks(for rois: [MosaicROI], imageSize: CGSize) -> [MosaicMask]
}

public final class EllipseSegmentEngine: Segmenting {
    public init() {}

    public func createMasks(for rois: [MosaicROI], imageSize: CGSize) -> [MosaicMask] {
        rois.map { MosaicMask(roi: $0, imageSize: imageSize) }
    }
}
