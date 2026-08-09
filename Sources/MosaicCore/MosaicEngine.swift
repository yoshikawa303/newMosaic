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
            return "パターン画像が見つかりません\(detail)。画像を選択し直してください"
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
    /// ボーダー（縦/横/ランダムを`MosaicStyle.stripeVertical`/`stripeRandom`で切替える統合パターン）。
    case border
    case clouds
    case flash
    case customImage
    case overlayImage

    public var displayName: String {
        switch self {
        case .pixelate: return "モザイク"
        case .noise: return "ノイズ"
        case .blur: return "ボケ"
        case .edgeBlur: return "線・エッジぼかし"
        case .unsharpEdges: return "アンシャープ（エッジ強調）"
        case .border: return "ボーダー"
        case .clouds: return "トーン"
        case .flash: return "フラッシュ"
        case .customImage: return "パターン画像"
        case .overlayImage: return "マスク画像（マスク・メガネ等）"
        }
    }

    /// 画像の指定が必要なパターンか（任意パターン/かぶせ画像）。
    public var requiresPatternImage: Bool {
        self == .customImage || self == .overlayImage
    }

    /// ボーダー系（帯太さ・間隔パラメータを使う）パターンか。
    public var isStripes: Bool {
        self == .border
    }
}

/// モザイク描画のスタイル設定。塗りつぶしパターン（②）と共通パラメータ（①）の組み合わせ。
// CGImageは不変（一度生成した内容が変化しない）値のため、参照型でもスレッド間の共有は安全。
// Swift 6の並行性チェック向けに@unchecked Sendableを明示する（コードレビューで指摘）。
public struct MosaicStyle: @unchecked Sendable {
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
    /// ボーダー: 縦帯/横帯（`stripeRandom`がtrueのときは無視される）
    public var stripeVertical: Bool
    /// ボーダー: 帯幅・間隔を揺らしたランダム斜めボーダーにするか
    public var stripeRandom: Bool
    /// ボーダー: 帯を網点（漫画トーン風）で塗るか
    /// すべてのパターン共通の網点（漫画トーン風）ON/OFF。
    public var patternTone: Bool = false
    public var stripeTone: Bool
    /// ボーダー: 並行揺れ（0〜1）。各線を線の中央を軸にランダムで左右へ傾ける度合い
    /// （`stripeRandom`のON/OFFに関わらず有効）
    public var stripeWobble: Double
    /// 雲（トーン）: 密度（0〜1。大きいほど塗り部分が多い）。フラッシュでは放射線の密度を兼ねる
    public var cloudDensity: Double
    /// 雲（トーン）: 漫画のトーンパターン化（網点変換）ON/OFF。フラッシュのトーン化も兼ねる
    public var cloudTone: Bool
    /// フラッシュ: 放射の中心位置（ROIのローカル正規化座標、0〜1・左上原点）。nilはROI中心。
    public var flashCenter: NormalizedPoint?
    /// フラッシュ: 種別（集中線/ベタフラッシュ/ウニフラッシュ）
    public var flashKind: MosaicFlashKind
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
        stripeVertical: Bool = true,
        stripeRandom: Bool = false,
        patternTone: Bool = false,
        stripeTone: Bool = false,
        stripeWobble: Double = 0,
        cloudDensity: Double = 0.5,
        cloudTone: Bool = false,
        flashCenter: NormalizedPoint? = nil,
        flashKind: MosaicFlashKind = .line,
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
        self.stripeVertical = stripeVertical
        self.stripeRandom = stripeRandom
        self.patternTone = patternTone
        self.stripeTone = stripeTone
        self.stripeWobble = stripeWobble
        self.cloudDensity = cloudDensity
        self.cloudTone = cloudTone
        self.flashCenter = flashCenter
        self.flashKind = flashKind
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
            stripeVertical: stripeVertical,
            stripeRandom: stripeRandom,
            patternTone: patternTone,
            stripeTone: stripeTone,
            stripeWobble: stripeWobble,
            cloudDensity: cloudDensity,
            cloudTone: cloudTone,
            flashCenter: flashCenter,
            flashKind: flashKind,
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
            stripeVertical: roiStyle.stripeVertical,
            stripeRandom: roiStyle.stripeRandom,
            patternTone: roiStyle.patternTone,
            stripeTone: roiStyle.stripeTone,
            stripeWobble: roiStyle.stripeWobble,
            cloudDensity: roiStyle.cloudDensity,
            cloudTone: roiStyle.cloudTone,
            flashCenter: roiStyle.flashCenter,
            flashKind: roiStyle.flashKind,
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

    /// マスクのキャッシュ。
    ///
    /// マスク生成は「対象形状（SAM）」ならROIごとにONNX推論が走る。`applyMosaic` は
    /// モザイクの見た目を変えるたびに呼ばれるため、毎回作り直すとUIが固まる
    /// （GUI報告 2026-08-02「モザイク対象の1つのモザイクを編集する毎にアプリが一時ハングする」）。
    /// マスクはROIの形状・位置・生成方式・手描き補正だけで決まりスタイルには依存しないので、
    /// それらを鍵にして使い回す。
    private struct MaskCacheKey: Hashable {
        let image: ObjectIdentifier
        let extent: String
        let engine: String
        let roi: String
    }
    private var maskCache: [MaskCacheKey: CIImage] = [:]
    /// 保持する上限。1画像あたりのROI数を超える程度あればよい。
    private static let maskCacheCapacity = 256

    public init(context: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.context = context
    }

    /// マスクのキャッシュを捨てる。画像やマスク生成方式を切り替えたときに呼ぶ。
    public func invalidateMaskCache() {
        maskCache.removeAll()
    }

    /// キャッシュを見てからマスクを作る。
    private func cachedMasks(
        for rois: [MosaicROI],
        in image: CGImage,
        extent: CGRect,
        segmentEngine: Segmenting
    ) throws -> [CIImage] {
        // エンジンの種類が変わったらキャッシュは無効。型名で識別する
        // （同じ型なら同じ生成規則。しきい値等はROI側の`maskIdentity`に含まれる）。
        let engineName = String(describing: type(of: segmentEngine))
        let extentKey = "\(Int(extent.width))x\(Int(extent.height))"
        var results = [CIImage?](repeating: nil, count: rois.count)
        var missingIndices: [Int] = []
        for (index, roi) in rois.enumerated() {
            let key = MaskCacheKey(
                image: ObjectIdentifier(image), extent: extentKey,
                engine: engineName, roi: roi.maskIdentity
            )
            if let cached = maskCache[key] {
                results[index] = cached
            } else {
                missingIndices.append(index)
            }
        }
        if !missingIndices.isEmpty {
            let missingROIs = missingIndices.map { rois[$0] }
            let generated = try Self.createMasks(
                for: missingROIs, in: image, extent: extent, segmentEngine: segmentEngine
            )
            if maskCache.count + generated.count > Self.maskCacheCapacity {
                maskCache.removeAll()
            }
            for (offset, index) in missingIndices.enumerated() {
                let mask = generated[offset]
                results[index] = mask
                maskCache[MaskCacheKey(
                    image: ObjectIdentifier(image), extent: extentKey,
                    engine: engineName, roi: rois[index].maskIdentity
                )] = mask
            }
        }
        return results.map { $0 ?? CIImage(color: .black).cropped(to: extent) }
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
        patternImageProvider: ((String) -> CGImage?)? = nil,
        skipIncompletePatterns: Bool = false
    ) throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var output = CIImage(cgImage: image)
        let original = output
        var layerCache: [MosaicROIStyle: (fill: CIImage, stripeAlpha: CIImage?)] = [:]

        let masks = try cachedMasks(for: rois, in: image, extent: extent, segmentEngine: segmentEngine)
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
            if resolvedStyle.pattern.requiresPatternImage, resolvedStyle.patternImage == nil {
                // skipIncompletePatterns=true（ライブプレビュー用途）では、画像未選択のROI1件のために
                // 他の全ROIの表示まで失敗させず、そのROIだけ元画像のまま（未加工）でスキップする。
                // 「モザイクを適用」等の最終書き出しでは従来通り例外を投げ、未設定のまま保存させない。
                if skipIncompletePatterns { continue }
                throw MosaicEngineError.customPatternImageMissing(resolvedStyle.patternImageIdentifier)
            }

            // かぶせ画像: マスク合成ではなく、画像をROI矩形へ引き伸ばして重ねる
            //（PNGの透明部分はそのまま透過。マスク・メガネ・医療マスク等のアクセサリ重ね用途）
            if resolvedStyle.pattern == .overlayImage, let overlay = resolvedStyle.patternImage {
                output = Self.compositeOverlay(
                    overlay,
                    over: output,
                    roi: roi,
                    rect: rect,
                    opacity: resolvedStyle.opacity,
                    extent: extent
                )
                continue
            }
            let styleKey = resolvedStyle.persistentStyle()
            let layers: (fill: CIImage, stripeAlpha: CIImage?)
            // フラッシュは中心位置がROIごとの矩形に依存するため、他パターンと違い
            // スタイル内容だけでキャッシュを共有できない（同じスタイル設定でも
            // ROIが異なれば中心の実座標が変わる）。ROI単位で毎回生成する。
            if resolvedStyle.pattern != .flash, let cached = layerCache[styleKey] {
                layers = cached
            } else {
                layers = (
                    Self.makeFillLayer(style: resolvedStyle, original: original, extent: extent, roi: roi),
                    Self.stripePatternMask(style: resolvedStyle, extent: extent)
                )
                if resolvedStyle.pattern != .flash {
                    layerCache[styleKey] = layers
                }
            }

            var mask = baseMask
            // ボーダー: 縞のアルファ（帯=不透過、間隔=透明）をROIマスクへ乗算。
            // ROIが回転している場合は縞も選択範囲の角度基準で傾ける（GUI報告 2026-08-08:
            // 回転済みマスクで縦横が画像軸のままになる）。縞はスタイル単位でキャッシュ共有
            // しているため、回転はROI毎にここで適用する。回転規約は形状マスクと同じ
            // `ShapeSegmentEngine.ciRotation`（ROI中心軸）を使う。
            if var stripeAlpha = layers.stripeAlpha {
                if abs(roi.rotation) > 0.01 {
                    stripeAlpha = stripeAlpha
                        .clampedToExtent()
                        .transformed(by: ShapeSegmentEngine.ciRotation(
                            around: CGPoint(x: rect.midX, y: rect.midY), degrees: roi.rotation
                        ))
                        .cropped(to: extent)
                }
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

    /// かぶせ画像をROI矩形（回転対応）へ引き伸ばして元画像の上へ重ねる。
    /// 画像自身のアルファチャンネルで透過し、opacityで全体の不透明度を調整する。
    static func compositeOverlay(
        _ overlay: CGImage,
        over background: CIImage,
        roi: MosaicROI,
        rect: CGRect,
        opacity: Double,
        extent: CGRect
    ) -> CIImage {
        var image = CIImage(cgImage: overlay)
        let overlaySize = image.extent.size
        guard overlaySize.width > 0, overlaySize.height > 0 else { return background }
        image = image
            .transformed(by: CGAffineTransform(
                scaleX: rect.width / overlaySize.width,
                y: rect.height / overlaySize.height
            ))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        if abs(roi.rotation) > 0.01 {
            image = image.transformed(by: ShapeSegmentEngine.ciRotation(
                around: CGPoint(x: rect.midX, y: rect.midY),
                degrees: roi.rotation
            ))
        }
        if opacity < 0.999 {
            let alpha = max(0.05, opacity)
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
            ])
        }
        return image.composited(over: background).cropped(to: extent)
    }

    /// ROIごとにマスクを生成する。カテゴリが「目元」「眼窩下〜あご」のROIは、選択中の
    /// マスク生成方式（Vision人物セグメンテーション/前景オブジェクト/対象の形状）に関わらず、
    /// 常に図形ベース（矩形/楕円/多角形）の幾何学的マスクを使う。
    ///
    /// 理由: これらは顔にメガネ・マスク等のアクセサリを重ねる/隠す用途のROIであり、
    /// 前髪など細部にまたがる被写体の内容ベースマスク（Vision人物セグメンテーション等）は
    /// 髪の生え際で部分的な半透明値になりやすく、モザイクが「まだら」に適用されて
    /// 指定外の色調（地の肌色や毛髪色）が透けて見える不具合を招く（ユーザー報告により判明）。
    /// 対象の形状（顕著性マップ由来）も、目元のような質感の乏しい小領域では
    /// クリーンな輪郭を得られずノイズ状のマスクになりやすいため同様に除外する。
    static func createMasks(
        for rois: [MosaicROI],
        in image: CGImage,
        extent: CGRect,
        segmentEngine: Segmenting
    ) throws -> [CIImage] {
        // 手描き補正は「どの生成方式を使ったか」に関係なく最後に反映する
        let generated = try generatedMasks(
            for: rois, in: image, extent: extent, segmentEngine: segmentEngine
        )
        return zip(rois, generated).map { roi, mask in
            ManualMaskPainter.apply(strokes: roi.manualMaskStrokes, to: mask, roi: roi, extent: extent)
        }
    }

    private static func generatedMasks(
        for rois: [MosaicROI],
        in image: CGImage,
        extent: CGRect,
        segmentEngine: Segmenting
    ) throws -> [CIImage] {
        let forcedShapeCategories: Set<MosaicTargetCategory> = [.eyes, .lowerFace]
        guard rois.contains(where: { forcedShapeCategories.contains($0.category) }) else {
            return try segmentEngine.createMasks(for: rois, in: image, extent: extent)
        }

        var shapeIndices: [Int] = []
        var otherIndices: [Int] = []
        for (index, roi) in rois.enumerated() {
            if forcedShapeCategories.contains(roi.category) {
                shapeIndices.append(index)
            } else {
                otherIndices.append(index)
            }
        }

        let shapeROIs = shapeIndices.map { rois[$0] }
        let otherROIs = otherIndices.map { rois[$0] }
        let shapeMasks = try ShapeSegmentEngine().createMasks(for: shapeROIs, in: image, extent: extent)
        let otherMasks = otherROIs.isEmpty
            ? []
            : try segmentEngine.createMasks(for: otherROIs, in: image, extent: extent)

        var masks = [CIImage?](repeating: nil, count: rois.count)
        for (position, roiIndex) in shapeIndices.enumerated() {
            masks[roiIndex] = shapeMasks[position]
        }
        for (position, roiIndex) in otherIndices.enumerated() {
            masks[roiIndex] = otherMasks[position]
        }
        return masks.compactMap { $0 }
    }

    // MARK: - 塗りつぶしレイヤ生成

    static func makeFillLayer(style: MosaicStyle, original: CIImage, extent: CGRect, roi: MosaicROI) -> CIImage {
        var fill: CIImage
        switch style.pattern {
        case .pixelate:
            fill = original
                .clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(4, style.blockScale)])
                .cropped(to: extent)
        case .noise:
            // CIRandomGeneratorはRGB各chが独立乱数のためカラーノイズになる。
            // 彩度を0にしてモノクロノイズへ統一する。
            let noise = CIFilter(name: "CIRandomGenerator")?.outputImage ?? CIImage(color: .gray)
            let granularity = max(1, style.blockScale / 4)
            fill = noise
                .transformed(by: CGAffineTransform(scaleX: granularity, y: granularity))
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
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
            // CIEdges等の近傍サンプリングフィルタは、適用前にclampedToExtent()しておかないと
            // 画像外周で透明領域との境界を偽エッジとして検出してしまう（blurredと同じ順序に統一。
            // コードレビューで検出）。
            let edges = original
                .clampedToExtent()
                .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 10])
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
            // CIEdges等の近傍サンプリングフィルタは、適用前にclampedToExtent()しておかないと
            // 画像外周で透明領域との境界を偽エッジとして検出してしまう（blurredと同じ順序に統一。
            // コードレビューで検出）。
            let edges = original
                .clampedToExtent()
                .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 10])
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(1, style.blockScale / 8)])
                .cropped(to: extent)
            fill = sharpened.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: original,
                kCIInputMaskImageKey: edges
            ]).cropped(to: extent)
        case .clouds:
            fill = Self.cloudLayer(style: style, extent: extent)
        case .flash:
            fill = Self.flashLayer(style: style, roi: roi, extent: extent)
        case .border:
            if style.stripeTone {
                // トーン: 帯の塗りを元画像の網点変換（漫画トーン風）にする
                // （雲パターンのトーン化と同じCIDotScreenを、ノイズではなく元画像の輝度に適用）。
                fill = original
                    .clampedToExtent()
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                    .applyingFilter("CIDotScreen", parameters: [
                        kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                        kCIInputAngleKey: 0.3,
                        kCIInputWidthKey: max(3, style.stripeWidth / 3),
                        kCIInputSharpnessKey: 0.7
                    ])
                    .cropped(to: extent)
            } else {
                // 帯の色（既定は黒。tintColor指定時はその色）。間隔の透明はマスク側で表現する。
                let color = style.tintColor ?? (red: 0, green: 0, blue: 0)
                fill = CIImage(color: CIColor(red: color.red, green: color.green, blue: color.blue)).cropped(to: extent)
            }
        case .customImage, .overlayImage:
            // overlayImageはapplyMosaic側で特別処理される（ここへ来るのは全面フォールバック時のみ）
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

        // 全パターン共通のトーン（網点）。パターン固有のトーン（ボーダー・雲・フラッシュ）は
        // それぞれの生成側で処理済みなので、ここでは二重に掛けない。
        if style.patternTone, !style.pattern.isStripes, style.pattern != .clouds, style.pattern != .flash {
            fill = fill.applyingFilter("CIDotScreen", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputAngleKey: 0.3,
                kCIInputWidthKey: max(3, style.blockScale / 4),
                kCIInputSharpnessKey: 0.7
            ]).cropped(to: extent)
        }

        // 色付け（ボーダーは帯色として適用済みのため対象外。ただしトーンONは帯色を使わず
        // 元画像の網点変換を使うため、通常パターンと同様に色付けを適用できるようにする）
        let skipGenericTint = style.pattern.isStripes && !style.stripeTone
        if let tint = style.tintColor, !skipGenericTint {
            fill = fill.applyingFilter("CIColorMonochrome", parameters: [
                kCIInputColorKey: CIColor(red: tint.red, green: tint.green, blue: tint.blue),
                kCIInputIntensityKey: 1.0
            ]).cropped(to: extent)
        }
        return fill
    }

    /// ボーダー用の縞アルファマスク（帯=白、間隔=黒=透明）。ボーダー以外はnil。
    static func stripePatternMask(style: MosaicStyle, extent: CGRect) -> CIImage? {
        guard style.pattern == .border else { return nil }
        let wobble = min(max(style.stripeWobble, 0), 1)
        // 太さ・間隔のランダム化も並行揺れも無い場合だけ、軽量なタイル繰り返しで縞を作る。
        // どちらかが有効なら線ごとに形が変わるためCGContextへ1本ずつ描画する。
        guard style.stripeRandom || wobble > 0 else {
            return regularStripeMask(style: style, extent: extent)
        }
        return drawnStripeMask(style: style, extent: extent, jitter: style.stripeRandom, wobble: wobble)
    }

    private static func regularStripeMask(style: MosaicStyle, extent: CGRect) -> CIImage? {
        let vertical = style.stripeVertical
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

    /// ボーダーの縞を1本ずつCGContextへ描く。「方向」設定（縦/横）に従った帯を並べ、
    /// - `jitter`（＝「ランダム」ON）で各帯の太さ・間隔を±40%揺らす。
    /// - `wobble`（＝「並行揺れ」0〜1）が0より大きい場合、各線を線の中央を軸にランダムで
    ///   左右へ傾ける（値が大きいほど傾きも大きい。最大±25度）。
    /// 「ランダム」OFFでも並行揺れだけを効かせられる（GUI報告 2026-08-09: ランダムONを
    /// 前提にするとスライダーが無効のままで設定できない）。
    /// シード固定で再レンダリングしても同じ模様になる。
    /// 旧実装の斜め固定回転+ノイズ変位は廃止した（ランダム時も方向設定を維持する仕様変更）。
    private static func drawnStripeMask(
        style: MosaicStyle,
        extent: CGRect,
        jitter: Bool,
        wobble: Double
    ) -> CIImage? {
        let band = max(1.0, style.stripeWidth)
        let gap = max(0.0, style.stripeSpacing)
        var rng = SeededRandomGenerator(seed: 0x6D6F_7A61)
        let vertical = style.stripeVertical
        let width = max(1, Int(extent.width))
        let height = max(1, Int(extent.height))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.setFillColor(CGColor(gray: 1, alpha: 1))

        // 帯を並べる方向の長さ（縦帯なら横方向へ並ぶ）と、各線の長さ
        let acrossLength = vertical ? extent.width : extent.height
        let lineLength = vertical ? extent.height : extent.width
        let maxTiltRadians = min(max(wobble, 0), 1) * 25 * .pi / 180
        var pos: CGFloat = 0
        while pos < acrossLength {
            let bandLen = jitter ? max(1, band * CGFloat(Double.random(in: 0.6...1.4, using: &rng))) : band
            let gapLen = jitter ? max(0, gap * CGFloat(Double.random(in: 0.6...1.4, using: &rng))) : gap
            let tilt = maxTiltRadians > 0 ? CGFloat(Double.random(in: -1...1, using: &rng)) * maxTiltRadians : 0
            let centerAcross = pos + bandLen / 2
            // 線の中央を軸に傾ける。傾けても端が欠けないよう線を上下（左右）に25%ずつ延長する
            let center = vertical
                ? CGPoint(x: centerAcross, y: extent.height / 2)
                : CGPoint(x: extent.width / 2, y: centerAcross)
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: tilt)
            context.translateBy(x: -center.x, y: -center.y)
            if vertical {
                context.fill(CGRect(
                    x: centerAcross - bandLen / 2,
                    y: -lineLength * 0.25,
                    width: bandLen,
                    height: lineLength * 1.5
                ))
            } else {
                context.fill(CGRect(
                    x: -lineLength * 0.25,
                    y: centerAcross - bandLen / 2,
                    width: lineLength * 1.5,
                    height: bandLen
                ))
            }
            context.restoreGState()
            pos += bandLen + gapLen
        }
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image).cropped(to: extent)
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

    /// フラッシュパターン: 指定した中心点から放射状の線を描く。
    /// - 種別: 集中線（白地に黒の先細り線）/ ベタフラッシュ（黒地に白の放射）/
    ///   ウニフラッシュ（両端が尖った紡錘形の線をリング状に描く）。
    /// - 密度: `cloudDensity`（トーンの密度スライダーを兼用）で放射線の本数を調整。
    /// - トーン: `cloudTone` ONで結果を網点（漫画トーン風）へ変換する。
    /// - 乱数シードはROIのIDから導出し、レイヤ（ROI）ごとに異なる形の集中線になる
    ///   （同一ROIの再レンダリングでは同じ形を保つ）。
    static func flashLayer(style: MosaicStyle, roi: MosaicROI, extent: CGRect) -> CIImage {
        let rect = roi.rect.cgRect(imageSize: extent.size, origin: .bottomLeft)
        let local = style.flashCenter ?? NormalizedPoint(x: 0.5, y: 0.5)
        // ローカル座標は左上原点、CI座標は左下原点のためyを反転する。
        let center = CGPoint(
            x: rect.minX + local.x * rect.width,
            y: rect.minY + (1 - local.y) * rect.height
        )
        let beta = style.flashKind == .beta
        let background = CGColor(gray: beta ? 0 : 1, alpha: 1)
        let lineColor = CGColor(gray: beta ? 1 : 0, alpha: 1)
        let fallback = CIImage(color: CIColor(cgColor: background)).cropped(to: extent)
        let width = max(1, Int(extent.width))
        let height = max(1, Int(extent.height))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return fallback }

        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.setFillColor(lineColor)

        // ROIごとに異なる（かつ再レンダリングで安定した）シードをIDから導出する
        var seed: UInt64 = 0x466C_6173
        withUnsafeBytes(of: roi.id.uuid) { bytes in
            for byte in bytes { seed = (seed &* 31) &+ UInt64(byte) }
        }
        var rng = SeededRandomGenerator(seed: seed)
        let density = min(max(style.cloudDensity, 0.05), 1.0)
        let lineCount = Int(32 + density * 200)
        let maxRadius = hypot(extent.width, extent.height)
        let baseHalfWidth = max(0.8, style.blockScale / 8)

        if style.flashKind == .uni {
            // ウニフラッシュ: ROIサイズを基準にした半径帯に、両端が尖った紡錘形（ひし形）の
            // 線をリング状に並べる（漫画のウニフラ吹き出し風）。
            let roiRadius = hypot(rect.width, rect.height) / 2
            for index in 0..<lineCount {
                let baseAngle = (Double(index) / Double(lineCount)) * 2 * .pi
                let angle = baseAngle + Double.random(in: -0.5...0.5, using: &rng) * (2 * .pi / Double(lineCount))
                let halfWidth = baseHalfWidth * Double.random(in: 0.35...1.2, using: &rng)
                let innerRadius = roiRadius * Double.random(in: 0.30...0.50, using: &rng)
                let outerRadius = roiRadius * Double.random(in: 0.90...1.20, using: &rng)
                let dx = CGFloat(cos(angle))
                let dy = CGFloat(sin(angle))
                let inner = CGPoint(x: center.x + dx * innerRadius, y: center.y + dy * innerRadius)
                let outer = CGPoint(x: center.x + dx * outerRadius, y: center.y + dy * outerRadius)
                let mid = CGPoint(x: (inner.x + outer.x) / 2, y: (inner.y + outer.y) / 2)
                let perpX = -dy * CGFloat(halfWidth)
                let perpY = dx * CGFloat(halfWidth)
                context.beginPath()
                context.move(to: inner)
                context.addLine(to: CGPoint(x: mid.x + perpX, y: mid.y + perpY))
                context.addLine(to: outer)
                context.addLine(to: CGPoint(x: mid.x - perpX, y: mid.y - perpY))
                context.closePath()
                context.fillPath()
            }
        } else {
            // 集中線/ベタフラッシュ: 外周側が太く中心へ向かって尖る三角形の放射線
            for index in 0..<lineCount {
                let baseAngle = (Double(index) / Double(lineCount)) * 2 * .pi
                let angle = baseAngle + Double.random(in: -0.5...0.5, using: &rng) * (2 * .pi / Double(lineCount))
                let halfWidth = baseHalfWidth * Double.random(in: 0.35...1.3, using: &rng)
                let innerRadius = maxRadius * Double.random(in: 0.02...0.08, using: &rng)
                let dx = CGFloat(cos(angle))
                let dy = CGFloat(sin(angle))
                let apex = CGPoint(x: center.x + dx * innerRadius, y: center.y + dy * innerRadius)
                let baseCenter = CGPoint(x: center.x + dx * maxRadius, y: center.y + dy * maxRadius)
                let perpX = -dy * CGFloat(halfWidth)
                let perpY = dx * CGFloat(halfWidth)
                context.beginPath()
                context.move(to: apex)
                context.addLine(to: CGPoint(x: baseCenter.x + perpX, y: baseCenter.y + perpY))
                context.addLine(to: CGPoint(x: baseCenter.x - perpX, y: baseCenter.y - perpY))
                context.closePath()
                context.fillPath()
            }
        }
        guard let image = context.makeImage() else { return fallback }
        var result = CIImage(cgImage: image).cropped(to: extent)
        // トーンON: 集中線を網点（漫画トーン風）へ変換する（雲パターンのトーン化と同じ方式）
        if style.cloudTone {
            result = result.applyingFilter("CIDotScreen", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputAngleKey: 0.3,
                kCIInputWidthKey: max(3, style.blockScale / 4),
                kCIInputSharpnessKey: 0.7
            ]).cropped(to: extent)
        }
        return result
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
