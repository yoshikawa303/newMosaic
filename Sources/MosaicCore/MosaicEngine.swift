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

    public func applyMosaic(to image: CGImage, rois: [MosaicROI], scale: Double = 28) throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var output = CIImage(cgImage: image)
        let pixelated = output
            .clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: max(4, scale)
            ])
            .cropped(to: extent)

        for roi in rois {
            let rect = roi.rect.cgRect(imageSize: extent.size, origin: .bottomLeft)
            guard rect.width > 1, rect.height > 1 else { continue }
            let mask = ellipseMask(rect: rect, extent: extent)
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

    private func ellipseMask(rect: CGRect, extent: CGRect) -> CIImage {
        let radial = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: rect.midX, y: rect.midY),
            "inputRadius0": min(rect.width, rect.height) * 0.44,
            "inputRadius1": min(rect.width, rect.height) * 0.50,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.black
        ])?.outputImage ?? CIImage(color: .white)

        let scaleX = rect.width / max(1, min(rect.width, rect.height))
        let scaleY = rect.height / max(1, min(rect.width, rect.height))
        let transformed = radial
            .transformed(by: CGAffineTransform(translationX: -rect.midX, y: -rect.midY))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: rect.midX, y: rect.midY))

        return transformed.cropped(to: extent)
    }
}
