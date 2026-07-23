import CoreGraphics
import CoreImage
import Foundation

public enum MosaicEngineError: Error, LocalizedError {
    case outputCreationFailed
    case customPatternImageMissing(String?)

    public var errorDescription: String? {
        switch self {
        case .outputCreationFailed:
            return "モザイク画像を生成できませんでした"
        case .customPatternImageMissing(let identifier):
            let detail = identifier.map { "（ID: \($0)）" } ?? ""
            return "任意パターン画像が見つかりません\(detail)。パターン画像を選択し直してください"
        }
    }
}

/// 塗りつぶしパターンの種類。
public enum MosaicFillPattern: String, Codable, CaseIterable, Hashable, Sendable {
    case pixelate
    case noise
    case blur
    case edgeBlur
    case unsharpEdges
    case stripesVertical
    case stripesHorizontal
    case stripesRandom
    case clouds
    case customImage

    public var displayName: String {
        switch self {
        case .pixelate: return "モザイク"
        case .noise: return "ノイズ"
        case .blur: return "ボケ"
        case .edgeBlur: return "線・エッジぼかし"
        case .unsharpEdges: return "アンシャープ（エッジ強調）"
        case .stripesVertical: return "ボーダー（縦）"
        case .stripesHorizontal: return "ボーダー（横）"
        case .stripesRandom: return "ボーダーランダム"
        case .clouds: return "雲"
        case .customImage: return "任意パターン画像"
        }
    }

    /// ボーダー系（帯太さ・間隔パラメータを使う）パターンか。
    public var isStripes: Bool {
        self == .stripesVertical || self == .stripesHorizontal || self == .stripesRandom
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
    /// 雲: 密度（0〜1。大きいほど雲=塗り部分が多い）
    public var cloudDensity: Double
    /// 雲: 漫画のトーンパターン化（網点変換）ON/OFF
    public var cloudTone: Bool
    /// 任意パターン画像（customImage時。タイル状に敷き詰める）
    public var patternImage: CGImage?
    /// 永続化された任意パターン画像を解決するための識別子。
    public var patternImageIdentifier: String?

    public init(
        pattern: MosaicFillPattern = .pixelate,
        opacity: Double = 1.0,
        tintColor: (red: Double, green: Double, blue: Double)? = nil,
        blockScale: Double = 28,
        edgeFeather: Double = 0,
        stripeWidth: Double = 12,
        stripeSpacing: Double = 12,
        cloudDensity: Double = 0.5,
        cloudTone: Bool = false,
        patternImage: CGImage? = nil,
        patternImageIdentifier: String? = nil
    ) {
        self.pattern = pattern
        self.opacity = opacity
        self.tintColor = tintColor
        self.blockScale = blockScale
        self.edgeFeather = edgeFeather
        self.stripeWidth = stripeWidth
        self.stripeSpacing = stripeSpacing
        self.cloudDensity = cloudDensity
        self.cloudTone = cloudTone
        self.patternImage = patternImage
        self.patternImageIdentifier = patternImageIdentifier
    }

    /// ROIへ保存するためのCGImageを除いた設定を返す。
    public func persistentStyle() -> MosaicROIStyle {
        MosaicROIStyle(
            pattern: pattern,
            opacity: opacity,
            tint: tintColor.map { MosaicROIStyle.Tint(red: $0.red, green: $0.green, blue: $0.blue) },
            blockScale: blockScale,
            edgeFeather: edgeFeather,
            stripeWidth: stripeWidth,
            stripeSpacing: stripeSpacing,
            cloudDensity: cloudDensity,
            cloudTone: cloudTone,
            patternImageIdentifier: patternImageIdentifier
        )
    }

    /// ROIの永続化設定から描画用スタイルを復元する。
    /// 任意パターン画像だけは保存せず、UIが実行時に渡す。
    public init(roiStyle: MosaicROIStyle, patternImage: CGImage? = nil) {
        self.init(
            pattern: roiStyle.pattern,
            opacity: roiStyle.opacity,
            tintColor: roiStyle.tint.map { (red: $0.red, green: $0.green, blue: $0.blue) },
            blockScale: roiStyle.blockScale,
            edgeFeather: roiStyle.edgeFeather,
            stripeWidth: roiStyle.stripeWidth,
            stripeSpacing: roiStyle.stripeSpacing,
            cloudDensity: roiStyle.cloudDensity,
            cloudTone: roiStyle.cloudTone,
            patternImage: patternImage,
            patternImageIdentifier: roiStyle.patternImageIdentifier
        )
    }
}

/// 乱数パターンの再現性のためのシード付き乱数生成器（SplitMix64）。
/// ボーダーランダムのプレビューが再レンダリングのたびに変わらないよう固定シードで使う。
struct SeededRandomGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
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
        segmentEngine: Segmenting = ShapeSegmentEngine(),
        patternImageProvider: ((String) -> CGImage?)? = nil
    ) throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var output = CIImage(cgImage: image)
        let original = output
        var layerCache: [MosaicROIStyle: (fill: CIImage, stripeAlpha: CIImage?)] = [:]

        let masks = try segmentEngine.createMasks(for: rois, in: image, extent: extent)
        for (roi, baseMask) in zip(rois, masks) {
            let rect = roi.rect.cgRect(imageSize: extent.size, origin: .bottomLeft)
            guard rect.width > 1, rect.height > 1 else { continue }

            // ROI設定があれば、そのROIだけグローバル設定を完全に置き換える。
            // 任意パターン画像は永続化しないため、呼び出し側の実行時画像を引き継ぐ。
            var resolvedStyle = roi.style.map { MosaicStyle(roiStyle: $0) } ?? style
            if let identifier = resolvedStyle.patternImageIdentifier {
                resolvedStyle.patternImage = patternImageProvider?(identifier)
            } else if resolvedStyle.patternImage == nil {
                resolvedStyle.patternImage = style.patternImage
            }
            if resolvedStyle.pattern == .customImage, resolvedStyle.patternImage == nil {
                throw MosaicEngineError.customPatternImageMissing(resolvedStyle.patternImageIdentifier)
            }
            let styleKey = resolvedStyle.persistentStyle()
            let layers: (fill: CIImage, stripeAlpha: CIImage?)
            if let cached = layerCache[styleKey] {
                layers = cached
            } else {
                layers = (
                    Self.makeFillLayer(style: resolvedStyle, original: original, extent: extent),
                    Self.stripePatternMask(style: resolvedStyle, extent: extent)
                )
                layerCache[styleKey] = layers
            }

            var mask = baseMask
            // ボーダー: 縞のアルファ（帯=不透過、間隔=透明）をROIマスクへ乗算
            if let stripeAlpha = layers.stripeAlpha {
                mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [
                    kCIInputBackgroundImageKey: stripeAlpha
                ])
            }
            // 範囲輪郭のぼかし
            if resolvedStyle.edgeFeather > 0.5 {
                mask = mask
                    .clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: resolvedStyle.edgeFeather])
                    .cropped(to: extent)
            }
            // 透明度（マスク輝度へ乗算）
            if resolvedStyle.opacity < 0.999 {
                let alpha = max(0.05, resolvedStyle.opacity)
                mask = mask.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0)
                ])
            }

            // フェザー分だけ塗りパッチを広げる（輪郭ぼかしがROI境界で途切れないように）。
            // 回転ROIは軸平行矩形からはみ出すため、外接円を覆う正方形まで拡張する
            var expandedRect = rect.insetBy(dx: -resolvedStyle.edgeFeather * 2, dy: -resolvedStyle.edgeFeather * 2)
            if abs(roi.rotation) > 0.01 {
                let radius = sqrt(rect.width * rect.width + rect.height * rect.height) / 2 + resolvedStyle.edgeFeather * 2
                expandedRect = CGRect(
                    x: rect.midX - radius,
                    y: rect.midY - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            }
            expandedRect = expandedRect.intersection(extent)
            let patch = layers.fill
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
        case .unsharpEdges:
            // 範囲内の描画線・輪郭・内部模様のエッジのみをアンシャープ（強調）する。エッジ以外は元画像を保つ
            let sharpened = original
                .clampedToExtent()
                .applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: max(1, style.blockScale / 2),
                    kCIInputIntensityKey: 2.5
                ])
                .cropped(to: extent)
            let edges = original
                .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 10])
                .clampedToExtent()
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(1, style.blockScale / 8)])
                .cropped(to: extent)
            fill = sharpened.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: original,
                kCIInputMaskImageKey: edges
            ]).cropped(to: extent)
        case .clouds:
            fill = Self.cloudLayer(style: style, extent: extent)
        case .stripesVertical, .stripesHorizontal, .stripesRandom:
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
        if let tint = style.tintColor, !style.pattern.isStripes {
            fill = fill.applyingFilter("CIColorMonochrome", parameters: [
                kCIInputColorKey: CIColor(red: tint.red, green: tint.green, blue: tint.blue),
                kCIInputIntensityKey: 1.0
            ]).cropped(to: extent)
        }
        return fill
    }

    /// ボーダー用の縞アルファマスク（帯=白、間隔=黒=透明）。ボーダー以外はnil。
    static func stripePatternMask(style: MosaicStyle, extent: CGRect) -> CIImage? {
        switch style.pattern {
        case .stripesVertical, .stripesHorizontal:
            return regularStripeMask(style: style, extent: extent)
        case .stripesRandom:
            return randomStripeMask(style: style, extent: extent)
        default:
            return nil
        }
    }

    private static func regularStripeMask(style: MosaicStyle, extent: CGRect) -> CIImage? {
        let vertical = style.pattern == .stripesVertical
        let band = max(1, Int(style.stripeWidth.rounded()))
        let gap = max(0, Int(style.stripeSpacing.rounded()))
        let period = band + gap

        var buffer = [UInt8](repeating: 0, count: period)
        for index in 0..<band { buffer[index] = 255 }
        guard let tile = makeGrayTile(
            buffer: buffer,
            width: vertical ? period : 1,
            height: vertical ? 1 : period
        ) else { return nil }
        return CIImage(cgImage: tile)
            .applyingFilter("CIAffineTile", parameters: [:])
            .cropped(to: extent)
    }

    /// ボーダーランダム: 帯幅・間隔を±40%揺らした帯パターンを斜め回転で敷き詰め、
    /// ノイズ変位で角度にも揺れを出す。シード固定で再レンダリングしても同じ模様になる。
    private static func randomStripeMask(style: MosaicStyle, extent: CGRect) -> CIImage? {
        let band = max(1.0, style.stripeWidth)
        let gap = max(0.0, style.stripeSpacing)
        var rng = SeededRandomGenerator(seed: 0x6D6F_7A61)

        let length = 512
        var buffer = [UInt8](repeating: 0, count: length)
        var pos = 0
        while pos < length {
            let bandLen = max(1, Int((band * Double.random(in: 0.6...1.4, using: &rng)).rounded()))
            let gapLen = max(0, Int((gap * Double.random(in: 0.6...1.4, using: &rng)).rounded()))
            for index in pos..<min(length, pos + bandLen) { buffer[index] = 255 }
            pos += max(1, bandLen + gapLen)
        }
        guard let tile = makeGrayTile(buffer: buffer, width: length, height: 1) else { return nil }

        // 斜め回転（約20°±9°）で敷き詰める
        let angle = 0.35 + Double.random(in: -0.15...0.15, using: &rng)
        let rotation = NSAffineTransform()
        rotation.rotate(byRadians: CGFloat(angle))
        var mask = CIImage(cgImage: tile)
            .applyingFilter("CIAffineTile", parameters: ["inputTransform": rotation])
            .cropped(to: extent)

        // なめらかなノイズで帯を変位させ、間隔・角度の揺れを出す
        let wobbleScale = max(8, band * 4)
        let wobble = (CIFilter(name: "CIRandomGenerator")?.outputImage ?? CIImage(color: .gray))
            .transformed(by: CGAffineTransform(scaleX: wobbleScale, y: wobbleScale))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: wobbleScale / 2])
            .cropped(to: extent)
        mask = mask
            .clampedToExtent()
            .applyingFilter("CIDisplacementDistortion", parameters: [
                "inputDisplacementImage": wobble,
                kCIInputScaleKey: band * 0.8
            ])
            .cropped(to: extent)
        return mask
    }

    /// 雲パターン: 白ノイズを拡大+ぼかしした2オクターブ合成でPhotoshopの雲フィルタ風テクスチャを作る。
    /// 密度はガンマ補正で塗り部分の面積を調整し、トーン化ONでは網点（漫画トーン風）へ変換する。
    static func cloudLayer(style: MosaicStyle, extent: CGRect) -> CIImage {
        let noise = CIFilter(name: "CIRandomGenerator")?.outputImage ?? CIImage(color: .gray)
        let granularity = max(8, style.blockScale)

        // オクターブ1: 大きな雲の塊（ノイズ1画素→granularity画素へ拡大し、ぼかして滑らかに）
        let octave1 = noise
            .transformed(by: CGAffineTransform(scaleX: granularity * 2, y: granularity * 2))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: granularity])
        // オクターブ2: 細部（位置をずらした別サンプル）
        let octave2 = noise
            .transformed(by: CGAffineTransform(translationX: 137, y: 89))
            .transformed(by: CGAffineTransform(scaleX: granularity, y: granularity))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: granularity / 2])

        // 60% + 40% で合成し、グレースケール化
        let scaled1 = octave1.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.6, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.6, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.6, w: 0)
        ])
        let scaled2 = octave2.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.4, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.4, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.4, w: 0)
        ])
        var clouds = scaled1
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: scaled2])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1.6
            ])
            .cropped(to: extent)

        // 密度: ガンマで明部（雲）の面積を調整（密度大→塗り多い）
        let density = min(max(style.cloudDensity, 0.05), 1.0)
        clouds = clouds.applyingFilter("CIGammaAdjust", parameters: [
            "inputPower": 2.0 - density * 1.5
        ]).cropped(to: extent)

        // 漫画のトーンパターン化（網点変換）
        if style.cloudTone {
            clouds = clouds.applyingFilter("CIDotScreen", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputAngleKey: 0.3,
                kCIInputWidthKey: max(3, granularity / 4),
                kCIInputSharpnessKey: 0.7
            ]).cropped(to: extent)
        }
        return clouds
    }

    /// 8bitグレースケールのタイルCGImageを生成する（縞・帯パターン用）。
    private static func makeGrayTile(buffer: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
        return CGImage(
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
        )
    }
}
