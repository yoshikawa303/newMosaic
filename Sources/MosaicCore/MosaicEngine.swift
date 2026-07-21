import CoreGraphics
import CoreImage
import Foundation

public enum MosaicEngineError: Error, LocalizedError {
    case outputCreationFailed

    public var errorDescription: String? {
        switch self {
        case .outputCreationFailed:
            return "モザイク画像を生成できませんでした"
        }
    }
}

public final class MosaicEngine {
    private let context: CIContext

    public init(context: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.context = context
    }

    public func applyMosaic(
        to image: CGImage,
        rois: [MosaicROI],
        scale: Double = 28,
        segmentEngine: Segmenting = ShapeSegmentEngine()
    ) throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var output = CIImage(cgImage: image)
        let pixelated = output
            .clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: max(4, scale)
            ])
            .cropped(to: extent)

        let masks = try segmentEngine.createMasks(for: rois, in: image, extent: extent)
        for (roi, mask) in zip(rois, masks) {
            let rect = roi.rect.cgRect(imageSize: extent.size, origin: .bottomLeft)
            guard rect.width > 1, rect.height > 1 else { continue }
            let patch = pixelated
                .cropped(to: rect)
                .applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: output,
                    kCIInputMaskImageKey: mask
                ])
            output = patch.cropped(to: extent)
        }

        guard let cgImage = context.createCGImage(output, from: extent) else {
            throw MosaicEngineError.outputCreationFailed
        }
        return cgImage
    }
}
