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

/// 塗りつぶしパターンの種類。
public enum MosaicFillPattern: String, Codable, CaseIterable, Sendable {
    case pixelate
    case noise
    case blur
    case edgeBlur
    case stripesVertical
    case stripesHorizontal
    case customImage

    public var displayName: String {
        switch self {
        case .pixelate: return "モザイク"
        case .noise: return "ノイズ"
        case .blur: return "ボケ"
        case .edgeBlur: return "線・エッジぼかし"
        case .stripesVertical: return "ボーダー（縦）"
        case .stripesHorizontal: return "ボーダー（横）"
        case .customImage: return "任意パターン画像"
        }
    }
}

/// モザイク描画のスタイル設定。塗りつぶしパターン（②）と共通パラメータ（①）の組み合わせ。
public struct MosaicStyle {
    public var pattern: MosaicFillPattern
    /// 透明度（0.05〜1.0。1.0で完全塗りつぶし、下げるほど元画像が透ける）
    public var opacity: Double
    /// 色付け（nil=元画像の色をそのまま使用。指定時は単色調へ。ボーダーでは帯の色）
    public var tintColor: (red: Double, green: Double, blue: Double)?
    /// パターンの細かさ（モザイクのブロックサイズ／ノイズ粒度／ボケ半径／パターン画像の拡縮基準）
    public var blockScale: Double
    /// 範囲輪郭のぼかし量（px。0で輪郭くっきり）
    public var edgeFeather: Double
    /// ボーダー: 各帯の太さ（px）
    public var stripeWidth: Double
    /// ボーダー: 帯の間隔（px。間隔部分は透明=元画像が見える）
    public var stripeSpacing: Double
    /// 任意パターン画像（customImage時。タイル状に敷き詰める）
    public var patternImage: CGImage?

    public init(
        pattern: MosaicFillPattern = .pixelate,
        opacity: Double = 1.0,
        tintColor: (red: Double, green: Double, blue: Double)? = nil,
        blockScale: Double = 28,
        edgeFeather: Double = 0,
        stripeWidth: Double = 12,
        stripeSpacing: Double = 12,
        patternImage: CGImage? = nil
    ) {
        self.pattern = pattern
        self.opacity = opacity
        self.tintColor = tintColor
        self.blockScale = blockScale
        self.edgeFeather = edgeFeather
        self.stripeWidth = stripeWidth
        self.stripeSpacing = stripeSpacing
        self.patternImage = patternImage
    }
}

public final class MosaicEngine {
    private let context: CIContext

    public init(context: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.context = context
    }

    /// 後方互換API（スタイル未指定はモザイク・不透明）。
    public func applyMosaic(
        to image: CGImage,
        rois: [MosaicROI],
        scale: Double = 28,
        segmentEngine: Segmenting = ShapeSegmentEngine()
    ) throws -> CGImage {
        var style = MosaicStyle()
        style.blockScale = scale
        return try applyMosaic(to: image, rois: rois, style: style, segmentEngine: segmentEngine)
    }

    public func applyMosaic(
        to image: CGImage,
        rois: [MosaicROI],
        style: MosaicStyle,
        segmentEngine: Segmenting = ShapeSegmentEngine()
    ) throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var output = CIImage(cgImage: image)
        let original = output

        let fill = Self.makeFillLayer(style: style, original: original, extent: extent)
        let stripeAlpha = Self.stripePatternMask(style: style, extent: extent)

        let masks = try segmentEngine.createMasks(for: rois, in: image, extent: extent)
        for (roi, baseMask) in zip(rois, masks) {
            let rect = roi.rect.cgRect(imageSize: extent.size, origin: .bottomLeft)
            guard rect.width > 1, rect.height > 1 else { continue }

            var mask = baseMask
            // ボーダー: 縞のアルファ（帯=不透過、間隔=透明）をROIマスクへ乗算
            if let stripeAlpha {
                mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [
                    kCIInputBackgroundImageKey: stripeAlpha
                ])
            }
            // 範囲輪郭のぼかし
            if style.edgeFeather > 0.5 {
                mask = mask
                    .clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: style.edgeFeather])
                    .cropped(to: extent)
            }
            // 透明度（マスク輝度へ乗算）
            if style.opacity < 0.999 {
                let alpha = max(0.05, style.opacity)
                mask = mask.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0)
                ])
            }

            // フェザー分だけ塗りパッチを広げる（輪郭ぼかしがROI境界で途切れないように）
            let expandedRect = rect
                .insetBy(dx: -style.edgeFeather * 2, dy: -style.edgeFeather * 2)
                .intersection(extent)
            let patch = fill
                .cropped(to: expandedRect)
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

    // MARK: - 塗りつぶしレイヤ生成

    static func makeFillLayer(style: MosaicStyle, original: CIImage, extent: CGRect) -> CIImage {
        var fill: CIImage
        switch style.pattern {
        case .pixelate:
            fill = original
                .clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(4, style.blockScale)])
                .cropped(to: extent)
        case .noise:
            let noise = CIFilter(name: "CIRandomGenerator")?.outputImage ?? CIImage(color: .gray)
            let granularity = max(1, style.blockScale / 4)
            fill = noise
                .transformed(by: CGAffineTransform(scaleX: granularity, y: granularity))
                .cropped(to: extent)
        case .blur:
            fill = original
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, style.blockScale)])
                .cropped(to: extent)
        case .edgeBlur:
            // 範囲内の描画線・エッジ輪郭のみをぼかす（エッジ以外は元画像を保つ）
            let blurred = original
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, style.blockScale / 2)])
                .cropped(to: extent)
            let edges = original
                .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 10])
                .clampedToExtent()
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(1, style.blockScale / 8)])
                .cropped(to: extent)
            fill = blurred.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: original,
                kCIInputMaskImageKey: edges
            ]).cropped(to: extent)
        case .stripesVertical, .stripesHorizontal:
            // 帯の色（既定は黒。tintColor指定時はその色）。間隔の透明はマスク側で表現する。
            let color = style.tintColor ?? (red: 0, green: 0, blue: 0)
            fill = CIImage(color: CIColor(red: color.red, green: color.green, blue: color.blue)).cropped(to: extent)
        case .customImage:
            if let pattern = style.patternImage {
                let tile = CIImage(cgImage: pattern)
                let scale = max(0.05, style.blockScale / 28)
                fill = tile
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .applyingFilter("CIAffineTile", parameters: [:])
                    .cropped(to: extent)
            } else {
                fill = original
                    .clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(4, style.blockScale)])
                    .cropped(to: extent)
            }
        }

        // 色付け（ボーダーは帯色として適用済みのため対象外）
        if let tint = style.tintColor,
           style.pattern != .stripesVertical, style.pattern != .stripesHorizontal {
            fill = fill.applyingFilter("CIColorMonochrome", parameters: [
                kCIInputColorKey: CIColor(red: tint.red, green: tint.green, blue: tint.blue),
                kCIInputIntensityKey: 1.0
            ]).cropped(to: extent)
        }
        return fill
    }

    /// ボーダー用の縞アルファマスク（帯=白、間隔=黒=透明）。ボーダー以外はnil。
    static func stripePatternMask(style: MosaicStyle, extent: CGRect) -> CIImage? {
        let vertical: Bool
        switch style.pattern {
        case .stripesVertical: vertical = true
        case .stripesHorizontal: vertical = false
        default: return nil
        }
        let band = max(1, Int(style.stripeWidth.rounded()))
        let gap = max(0, Int(style.stripeSpacing.rounded()))
        let period = band + gap

        let width = vertical ? period : 1
        let height = vertical ? 1 : period
        var buffer = [UInt8](repeating: 0, count: width * height)
        for index in 0..<period where index < band {
            if vertical {
                buffer[index] = 255
            } else {
                buffer[index] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(buffer) as CFData),
              let tile = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 8,
                  bytesPerRow: width,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }
        return CIImage(cgImage: tile)
            .applyingFilter("CIAffineTile", parameters: [:])
            .cropped(to: extent)
    }
}
