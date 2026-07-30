import CoreGraphics
import CoreImage
import Foundation
import OSLog
import Vision

/// マスク生成の診断ログ（ヘルプ＞デバッグ＞デバッグログで確認できる）。
/// 「対象形状」がどの経路（前景抽出／顕著領域／図形フォールバック）を通ったかを、
/// 画像内容を一切含めない数値のみで記録する（精度問題の切り分け用）。
let segmentLogger = Logger(subsystem: "com.yoshikawa.newMosaic", category: "SegmentMask")

public extension CIImage {
    /// CVPixelBuffer 由来の CIImage を CGImage ラスタ（行0=上）系の他画像と合成・表示するための垂直反転補正。
    /// Vision のマスク出力をそのまま使うと最終表示・モザイクマスクが上下反転する（GUI確認で判明）。
    func verticallyFlippedForRaster() -> CIImage {
        transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -extent.height))
    }
}

/// マスク生成方式の識別子。UIの設定でユーザーが切替えるために使う。
public enum SegmentEngineKind: String, Codable, Sendable, CaseIterable {
    case shape
    case visionPersonSegmentation
    case foregroundObjects
    case regionForeground
    /// 学習済み部位セグメンテーションモデル（YOLO-seg）による形状抽出。モデル導入時のみ有効。
    case learnedShape
    /// MobileSAM（同梱）による形状抽出。検出枠をプロンプトに、枠内の対象の形状を直接得る。
    case samShape

    public var displayName: String {
        switch self {
        case .shape: return "図形（矩形/楕円）"
        case .visionPersonSegmentation: return "人物の輪郭（AI自動認識）"
        case .foregroundObjects: return "物体の輪郭（自動抽出）"
        case .regionForeground: return "対象形状"
        case .learnedShape: return "学習モデル形状"
        case .samShape: return "対象形状（SAM）"
        }
    }
}

public protocol Segmenting {
    /// `rois` と同じ順序・同じ件数のマスクを返す。
    func createMasks(for rois: [MosaicROI], in image: CGImage, extent: CGRect) throws -> [CIImage]
}

/// ROIの `shape`（矩形/楕円）に基づき、画像内容を参照しない幾何学的マスクを生成する。
/// 従来 `MosaicEngine` に内蔵されていたマスク生成ロジックをここへ移設したもの。
public final class ShapeSegmentEngine: Segmenting {
    public init() {}

    public func createMasks(for rois: [MosaicROI], in image: CGImage, extent: CGRect) throws -> [CIImage] {
        rois.map { Self.shapeMask(for: $0, extent: extent) }
    }

    /// ROIの形状（矩形/楕円）と回転角から幾何学的マスクを生成する。
    /// 他のSegmentEngineがROI範囲へマスクを制限する用途でも共用する（回転・楕円形状を正しく反映するため）。
    static func shapeMask(for roi: MosaicROI, extent: CGRect) -> CIImage {
        let rect = roi.rect.cgRect(imageSize: extent.size, origin: .bottomLeft)
        switch roi.shape {
        case .rectangle:
            return rectangleMask(rect: rect, extent: extent, rotation: roi.rotation)
        case .ellipse:
            return ellipseMask(rect: rect, extent: extent, rotation: roi.rotation)
        case .polygon:
            return polygonMask(for: roi, rect: rect, extent: extent)
        }
    }

    /// 多角形マスク: 頂点（rectローカル正規化座標）をCI画素座標へ変換してグレースケール描画する。
    static func polygonMask(for roi: MosaicROI, rect: CGRect, extent: CGRect) -> CIImage {
        let points = roi.polygonPoints ?? MosaicROI.defaultPolygonPoints
        guard points.count >= 3 else {
            return rectangleMask(rect: rect, extent: extent, rotation: roi.rotation)
        }
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
        ) else {
            return rectangleMask(rect: rect, extent: extent, rotation: roi.rotation)
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        if abs(roi.rotation) > 0.01 {
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: CGFloat(-roi.rotation * .pi / 180))
            context.translateBy(x: -rect.midX, y: -rect.midY)
        }
        context.beginPath()
        for (index, point) in points.enumerated() {
            // ローカル座標（左上原点）→ CI画素座標（左下原点）
            let x = rect.minX + point.x * rect.width
            let y = rect.minY + (1 - point.y) * rect.height
            if index == 0 {
                context.move(to: CGPoint(x: x, y: y))
            } else {
                context.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.closePath()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        guard let image = context.makeImage() else {
            return rectangleMask(rect: rect, extent: extent, rotation: roi.rotation)
        }
        return CIImage(cgImage: image).cropped(to: extent)
    }

    /// ビュー座標（上原点・時計回り）の回転角を、CI座標（下原点）の回転変換へ変換する。
    static func ciRotation(around center: CGPoint, degrees: Double) -> CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: -degrees * .pi / 180)
            .translatedBy(x: -center.x, y: -center.y)
    }

    public static func rectangleMask(rect: CGRect, extent: CGRect, rotation: Double = 0) -> CIImage {
        var white = CIImage(color: .white).cropped(to: rect)
        if abs(rotation) > 0.01 {
            white = white.transformed(by: ciRotation(around: CGPoint(x: rect.midX, y: rect.midY), degrees: rotation))
        }
        let black = CIImage(color: .black).cropped(to: extent)
        return white.composited(over: black).cropped(to: extent)
    }

    static func ellipseMask(rect: CGRect, extent: CGRect, rotation: Double = 0) -> CIImage {
        let radial = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: rect.midX, y: rect.midY),
            "inputRadius0": min(rect.width, rect.height) * 0.44,
            "inputRadius1": min(rect.width, rect.height) * 0.50,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.black
        ])?.outputImage ?? CIImage(color: .white)

        let scaleX = rect.width / max(1, min(rect.width, rect.height))
        let scaleY = rect.height / max(1, min(rect.width, rect.height))
        var transformed = radial
            .transformed(by: CGAffineTransform(translationX: -rect.midX, y: -rect.midY))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: rect.midX, y: rect.midY))
        if abs(rotation) > 0.01 {
            transformed = transformed.transformed(by: ciRotation(around: CGPoint(x: rect.midX, y: rect.midY), degrees: rotation))
        }
        return transformed.cropped(to: extent)
    }

    /// ROIの形状（矩形/楕円/多角形+回転）の**二値**マスク。
    ///
    /// `shapeMask` の楕円は放射グラデーション（縁へ向かって黒くなる）のため、輪郭が取れている
    /// マスクへ乗算すると輪郭が縁で薄まってしまう（§5.41）。輪郭マスクを「表示されているROIの
    /// 形状」で切り取る用途にはこちらを使う。
    public static func hardShapeMask(for roi: MosaicROI, extent: CGRect) -> CIImage {
        let rect = roi.rect.cgRect(imageSize: extent.size, origin: .bottomLeft)
        switch roi.shape {
        case .rectangle:
            return rectangleMask(rect: rect, extent: extent, rotation: roi.rotation)
        case .polygon:
            return polygonMask(for: roi, rect: rect, extent: extent)
        case .ellipse:
            return hardEllipseMask(rect: rect, extent: extent, rotation: roi.rotation)
        }
    }

    /// 縁がぼけない二値の楕円マスク（CGContextで塗る）。
    static func hardEllipseMask(rect: CGRect, extent: CGRect, rotation: Double) -> CIImage {
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
        ) else {
            return rectangleMask(rect: rect, extent: extent, rotation: rotation)
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        if abs(rotation) > 0.01 {
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: CGFloat(-rotation * .pi / 180))
            context.translateBy(x: -rect.midX, y: -rect.midY)
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: rect)
        guard let image = context.makeImage() else {
            return rectangleMask(rect: rect, extent: extent, rotation: rotation)
        }
        return CIImage(cgImage: image).cropped(to: extent)
    }

    /// 全面マスクをROIの形状マスク（矩形/楕円+回転）へ制限する。
    /// 従来の矩形クロップと異なり、楕円ROI・回転ROIでも形状どおりに制限される。
    static func restrict(_ mask: CIImage, to roi: MosaicROI, extent: CGRect) -> CIImage {
        let shape = shapeMask(for: roi, extent: extent)
        return mask.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: shape
        ]).cropped(to: extent)
    }
}

/// Vision の前景オブジェクトセグメンテーション（SAM系のローカル代替）。
/// 被写体（人物・物体）の画素マスクをROIごとに切り出して使う。
/// DETECTION_IMPROVEMENT_PLAN.md Phase 3 の実装。SAM/MobileSAM等の外部モデル同梱を避け、
/// macOS標準の `VNGenerateForegroundInstanceMaskRequest` を採用（追加コスト0・完全ローカル）。
/// 前景が得られない場合は `ShapeSegmentEngine` にフォールバックする。
public final class ForegroundSegmentEngine: Segmenting {
    private let fallback = ShapeSegmentEngine()

    public init() {}

    public func createMasks(for rois: [MosaicROI], in image: CGImage, extent: CGRect) throws -> [CIImage] {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty,
              let buffer = try? observation.generateScaledMaskForImage(
                  forInstances: observation.allInstances,
                  from: handler
              ) else {
            return try fallback.createMasks(for: rois, in: image, extent: extent)
        }

        let rawMask = CIImage(cvPixelBuffer: buffer).verticallyFlippedForRaster()
        guard rawMask.extent.width > 0, rawMask.extent.height > 0 else {
            return try fallback.createMasks(for: rois, in: image, extent: extent)
        }
        let scaleX = extent.width / rawMask.extent.width
        let scaleY = extent.height / rawMask.extent.height
        let black = CIImage(color: .black).cropped(to: extent)
        let fullFrameMask = rawMask
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .composited(over: black)

        return rois.map { roi in
            Self.restrictToROI(fullFrameMask, roi: roi, extent: extent)
        }
    }

    static func restrictToROI(_ mask: CIImage, roi: MosaicROI, extent: CGRect) -> CIImage {
        ShapeSegmentEngine.restrict(mask, to: roi, extent: extent)
    }
}

/// ROIごとに周辺をクロップして前景抽出を実行し、**検出範囲内の対象物の実形状**に沿ったマスクを生成する。
/// 「矩形・楕円ではなく対象（性器等）の形どおりにモザイクしたい」という要望への対応。
/// クロップにより対象物が主要被写体として大きく写るため、画像全体への前景抽出より対象の形を取りやすい。
///
/// Build 41での修正（GUI報告に基づく）:
/// - クロップ経路の前景マスクへ上下反転補正を適用していたため対象形状が上下反転していた → 補正を除去。
/// - 人物が枠いっぱいに写るクロップでは前景抽出が「人物全体」を返し、複数ROIへ同じような
///   マスクが適用されて見えた → 前景がクロップほぼ全面を覆う場合は顕著領域（オブジェクトネス）
///   マスクへ切替え、ROIごとの対象物の形状を取る。
/// 前景・顕著領域とも得られないROIは図形ベース（矩形/楕円）へフォールバックする。
public final class RegionForegroundSegmentEngine: Segmenting {
    private let fallback = ShapeSegmentEngine()
    private let measureContext = CIContext(options: [.cacheIntermediates: false])
    /// マスク検出しきい値（0=無効）。0より大きい場合、得られたマスクをこの値で二値化して
    /// 「なんとなくの塊」を締める。自動一発の結果が広すぎる画像向けの補助設定（UIのスライダーから指定）。
    public var maskThreshold: Double

    public init(maskThreshold: Double = 0) {
        self.maskThreshold = maskThreshold
    }

    public func createMasks(for rois: [MosaicROI], in image: CGImage, extent: CGRect) throws -> [CIImage] {
        let imageSize = CGSize(width: image.width, height: image.height)
        var results: [CIImage] = []
        for roi in rois {
            if let mask = regionMask(for: roi, in: image, imageSize: imageSize, extent: extent) {
                results.append(mask)
            } else {
                let fallbackMasks = try fallback.createMasks(for: [roi], in: image, extent: extent)
                results.append(fallbackMasks[0])
            }
        }
        return results
    }

    private func regionMask(
        for roi: MosaicROI,
        in image: CGImage,
        imageSize: CGSize,
        extent: CGRect
    ) -> CIImage? {
        // クロップ範囲は実装当初（Build 41）の計算と完全に一致させる（当初は輪郭の一致精度が
        // 高かったため、Vision前景抽出への入力を当時と同じに保つ。v82で行った384px拡大入力は
        // 当時うまく動いていた経路への入力を変えてしまう精度低下要因だったため廃止）。
        // 回転ROIのみ、無回転rectでは対象物がクロップ外へ出るため回転後の外接矩形を基準にする。
        let baseNormalized: NormalizedRect
        if abs(roi.rotation) > 0.01 {
            let baseRectPixels = roi.rect.cgRect(imageSize: imageSize, origin: .topLeft)
            let rotatedBoundsPixels = Self.rotatedBoundingBox(of: baseRectPixels, rotationDegrees: roi.rotation)
            baseNormalized = NormalizedRect(rotatedBoundsPixels, imageSize: imageSize)
        } else {
            baseNormalized = roi.rect
        }
        let expanded = baseNormalized.expanded(scale: 1.15).clamped()
        let cropRect = expanded.cgRect(imageSize: imageSize, origin: .topLeft)
        guard cropRect.width >= 16, cropRect.height >= 16,
              let crop = image.cropping(to: cropRect) else {
            segmentLogger.info("""
                regionMask fallback=shape reason=cropTooSmall \
                crop=\(Int(cropRect.width))x\(Int(cropRect.height)) \
                category=\(roi.category.rawValue, privacy: .public)
                """)
            return nil
        }

        // マスク候補を順に試し、被覆率が有効帯に入る最初のものを採用する。
        // 「空に近い（何も取れていない）」「全面に近い（分離できていない）」マスクは、
        // どちらもROI全体を塗るのと同じ結果になるため採用しない（実測で0.00や0.80前後が頻出）。
        func coverageOf(_ mask: CIImage?) -> Double? { mask.map { coverageRatio(of: $0) } }
        func isUsable(_ coverage: Double?) -> Bool {
            guard let coverage else { return false }
            return coverage >= Self.minimumUsableCoverage && coverage <= Self.maximumUsableCoverage
        }

        // 候補を優先順に評価し、有効帯に入る最初のものを採る。
        // 漫画・イラストでは「輪郭線で囲まれた領域」が意味的に最も正しいため最優先とする。
        // 写真では輪郭線が閉じず領域が外へ漏れる（被覆率が跳ね上がる）ため有効帯で自然に外れ、
        // 従来のVision前景抽出が採用される。
        let bounded = Self.inkBoundedRegionMask(in: crop)
        let boundedCoverage = coverageOf(bounded)
        let foreground = Self.foregroundMask(in: crop)
        let foregroundCoverage = coverageOf(foreground)
        let ink = Self.inkDensityMask(in: crop)
        let inkCoverage = coverageOf(ink)
        let saliency = Self.saliencyMask(in: crop)
        let saliencyCoverage = coverageOf(saliency)

        let candidates: [(name: String, mask: CIImage?, coverage: Double?)] = [
            ("inkBounded", bounded, boundedCoverage),
            ("foreground", foreground, foregroundCoverage),
            ("inkDensity", ink, inkCoverage),
            ("saliency", saliency, saliencyCoverage)
        ]
        let best = candidates.first { isUsable($0.coverage) }
        let localMask = best?.mask
        let source = best?.name ?? "none"

        segmentLogger.info("""
            regionMask category=\(roi.category.rawValue, privacy: .public) \
            crop=\(Int(cropRect.width))x\(Int(cropRect.height)) \
            rotation=\(Int(roi.rotation)) \
            boundedCoverage=\(boundedCoverage.map { String(format: "%.2f", $0) } ?? "-", privacy: .public) \
            fgCoverage=\(foregroundCoverage.map { String(format: "%.2f", $0) } ?? "-", privacy: .public) \
            inkCoverage=\(inkCoverage.map { String(format: "%.2f", $0) } ?? "-", privacy: .public) \
            salCoverage=\(saliencyCoverage.map { String(format: "%.2f", $0) } ?? "-", privacy: .public) \
            selected=\(source, privacy: .public)
            """)
        guard var mask = localMask, mask.extent.width > 0, mask.extent.height > 0 else {
            // どの候補も使えない場合は図形ベースへフォールバックする。
            // ROIが必ず塗られるため、モザイクが掛からない（検閲漏れ）事態は起きない。
            segmentLogger.info("regionMask fallback=shape reason=noUsableMask category=\(roi.category.rawValue, privacy: .public)")
            return nil
        }

        // 補助設定: しきい値が指定されている場合のみ二値化してマスクを締める（既定は無効=当初挙動）
        if maskThreshold > 0.01 {
            mask = mask
                .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": min(maskThreshold, 0.95)])
                .cropped(to: mask.extent)
        }

        // クロップ実サイズへスケールし、CI座標（下原点）でクロップ位置に配置する
        let scaleX = cropRect.width / mask.extent.width
        let scaleY = cropRect.height / mask.extent.height
        let cropRectCI = expanded.cgRect(imageSize: imageSize, origin: .bottomLeft)
        mask = mask
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: cropRectCI.minX, y: cropRectCI.minY))

        let black = CIImage(color: .black).cropped(to: extent)
        // 制限はROIの形状（矩形/楕円+回転）で行う。矩形のみの制限だと、Visionがクロップ全面に
        // 近い塊しか返せなかった場合に楕円ROIの外（回転した矩形の四隅）までモザイクが広がって
        // しまう（「不要な部分までマスクが広がる」GUI報告）。輪郭が取れている場合は楕円内の
        // 輪郭形状がそのまま残るため、スピル防止を優先して形状制限へ戻す。
        return ShapeSegmentEngine.restrict(mask.composited(over: black), to: roi, extent: extent)
    }

    /// 漫画・イラスト（線画）向けの「輪郭線で囲まれた領域」マスク。
    ///
    /// 漫画では対象部位が輪郭線（濃い線）で囲まれて描かれる。この性質を使い、ROI中心から
    /// 線を越えない範囲で領域を広げる（塗りつぶす）ことで、描かれた形そのものを取り出す。
    /// 描き込み密度方式と違い、周囲の陰影・しずくのような「線は多いが別物」の領域を巻き込まない。
    ///
    /// - 線の判定はクロップ内の明暗レンジに対する相対しきい値で行う（紙の白さに依存しない）。
    /// - 輪郭が途切れて外へ漏れた場合は被覆率が跳ね上がるため、呼び出し側の有効帯で弾かれる。
    /// - 写真では輪郭線が存在せず領域が全面へ広がるため、同様に有効帯で自然に外れる。
    static func inkBoundedRegionMask(in crop: CGImage) -> CIImage? {
        let width = crop.width
        let height = crop.height
        guard width >= 8, height >= 8 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(
                data: pointer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // 線のしきい値はクロップ内の明暗レンジから決める（紙の白さ・トーンの濃さに依存しない）
        let minValue = Int(pixels.min() ?? 0)
        let maxValue = Int(pixels.max() ?? 255)
        // 明暗差が小さい＝線が無い領域は対象外（写真の平坦部などで誤って全面を塗らないため）
        guard maxValue - minValue > 24 else { return nil }
        let inkThreshold = UInt8(minValue + Int(Double(maxValue - minValue) * 0.45))

        // ROI中心を種として、線を越えない範囲へ広げる（4近傍。斜めを含めると線の隙間から漏れやすい）
        var filled = [Bool](repeating: false, count: width * height)
        var queue: [Int] = []
        let centerIndex = (height / 2) * width + (width / 2)
        if pixels[centerIndex] > inkThreshold {
            filled[centerIndex] = true
            queue.append(centerIndex)
        } else {
            // 中心が線の上に乗っていた場合は、近傍から線でない画素を種にする
            let radius = max(2, min(width, height) / 10)
            var found = false
            for dy in -radius...radius where !found {
                for dx in -radius...radius where !found {
                    let x = width / 2 + dx
                    let y = height / 2 + dy
                    guard x >= 0, x < width, y >= 0, y < height else { continue }
                    let index = y * width + x
                    if pixels[index] > inkThreshold {
                        filled[index] = true
                        queue.append(index)
                        found = true
                    }
                }
            }
            guard found else { return nil }
        }

        var head = 0
        while head < queue.count {
            let index = queue[head]
            head += 1
            let x = index % width
            let y = index / width
            let neighbors = [
                x > 0 ? index - 1 : -1,
                x < width - 1 ? index + 1 : -1,
                y > 0 ? index - width : -1,
                y < height - 1 ? index + width : -1
            ]
            for neighbor in neighbors where neighbor >= 0 {
                guard !filled[neighbor], pixels[neighbor] > inkThreshold else { continue }
                filled[neighbor] = true
                queue.append(neighbor)
            }
        }

        // 塗りつぶした領域を1画素太らせ、囲っていた輪郭線自体もモザイク対象へ含める
        var mask = [UInt8](repeating: 0, count: width * height)
        for index in 0..<filled.count where filled[index] {
            mask[index] = 255
        }
        var dilated = mask
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] == 255 {
                if x > 0 { dilated[y * width + x - 1] = 255 }
                if x < width - 1 { dilated[y * width + x + 1] = 255 }
                if y > 0 { dilated[(y - 1) * width + x] = 255 }
                if y < height - 1 { dilated[(y + 1) * width + x] = 255 }
            }
        }

        guard let provider = CGDataProvider(data: Data(dilated) as CFData),
              let image = CGImage(
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
        return CIImage(cgImage: image)
    }

    /// 矩形を中心周りに回転させた場合の軸並行外接矩形。ROIのクロップ範囲が回転後の
    /// 選択範囲を確実に含むようにするために使う（回転していない場合は元の矩形のまま）。
    private static func rotatedBoundingBox(of rect: CGRect, rotationDegrees: Double) -> CGRect {
        guard abs(rotationDegrees) > 0.01 else { return rect }
        let radians = rotationDegrees * .pi / 180
        let cosA = abs(cos(radians))
        let sinA = abs(sin(radians))
        let newWidth = rect.width * cosA + rect.height * sinA
        let newHeight = rect.width * sinA + rect.height * cosA
        return CGRect(
            x: rect.midX - newWidth / 2,
            y: rect.midY - newHeight / 2,
            width: newWidth,
            height: newHeight
        )
    }

    /// クロップ画像の前景マスク（クロップ画素座標系）。
    /// クロップ経路ではバッファの行方向が画像と一致するため上下反転補正は行わない
    /// （補正を入れると対象形状が上下反転して表示される — GUI報告により確定）。
    static func foregroundMask(in crop: CGImage) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty,
              let buffer = try? observation.generateScaledMaskForImage(
                  forInstances: observation.allInstances,
                  from: handler
              ) else {
            return nil
        }
        return CIImage(cvPixelBuffer: buffer)
    }

    /// マスクとして使える被覆率の下限。これ未満は「何も取れていない」とみなす。
    /// 空マスクをそのまま採用するとモザイクが一切掛からない（検閲漏れ）ため、必ず弾く。
    static let minimumUsableCoverage = 0.03
    /// マスクとして使える被覆率の上限。これを超えるものは「クロップのほぼ全部が対象」で
    /// 輪郭を分離できていないため使わない（ROIを丸ごと塗るのと変わらず、意味がない）。
    ///
    /// クロップはROIの1.15倍（面積で約1.32倍）のため、マスクがROIとぴったり一致する場合の
    /// 被覆率は約0.76になる。その85%（＝ROI面積の85%以下しか覆わないマスク）を上限とし、
    /// 「ROIをほぼ丸ごと塗るだけ」のマスクを弾く。
    static let maximumUsableCoverage = 0.64

    /// 漫画・イラスト（線画）向けの「描き込み密度」マスク。
    ///
    /// Visionの前景抽出・顕著領域は写真の「被写体 vs 背景」を想定しており、体の内部にある
    /// 部位（性器・乳首）は背景が無いため分離できない（実測で被覆率0.8前後＝クロップのほぼ全面）。
    /// 一方、漫画では対象部位は周囲の平坦な肌よりも線・網点の描き込みが密という性質があるため、
    /// エッジ強度を面に広げて密度の高い塊を取り出すことで輪郭を得る。
    static func inkDensityMask(in crop: CGImage) -> CIImage? {
        let image = CIImage(cgImage: crop)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let shortSide = Double(min(crop.width, crop.height))
        // 線を面へ広げる半径。小さすぎると線のまま、大きすぎると全面が潰れるため短辺基準で決める。
        let spreadRadius = max(2.0, shortSide / 20)

        let gray = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let edges = gray
            .clampedToExtent()
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 6])
            .cropped(to: extent)
        let spread = edges
            .clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: spreadRadius])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: spreadRadius])
            .cropped(to: extent)
        // 密度の高い塊だけを残す（中間調を残すと縁がぼやけて輪郭が甘くなる）
        return spread
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.22])
            .cropped(to: extent)
    }

    /// クロップ画像の顕著領域（オブジェクトネス）マスク。ヒートマップを強調して軟マスク化する。
    /// 実装当初（Build 41）のパラメータを維持する（v82で試したしきい値二値化は、当初の
    /// ソフトなマスクを角張った塊に変えてしまう精度低下要因だったため廃止）。
    static func saliencyMask(in crop: CGImage) -> CIImage? {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
        guard let observation = request.results?.first else { return nil }
        let heat = CIImage(cvPixelBuffer: observation.pixelBuffer)
        guard heat.extent.width > 0, heat.extent.height > 0 else { return nil }
        return heat
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 2.2,
                kCIInputBrightnessKey: -0.05
            ])
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5])
            .cropped(to: heat.extent)
    }

    /// マスクの白領域被覆率（0〜1）。前景抽出が対象物を分離できているかの判定に使う。
    func coverageRatio(of mask: CIImage) -> Double {
        let average = mask.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: mask.extent)
        ])
        var pixel = [UInt8](repeating: 0, count: 4)
        // sRGB（ガンマあり）で読み出すと、平均値がガンマ補正されて実際の面積比より
        // 大幅に大きく出る（白60%の二値マスクが0.80と読めてしまう）。しきい値判定が
        // 意図した面積比で働かなくなるため、リニア色空間で読み出して面積比そのものを得る。
        let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        measureContext.render(
            average,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: linearSpace
        )
        return Double(pixel[0]) / 255.0
    }
}


/// Vision の人物セグメンテーション結果（画素単位マスク）をROIごとに切り出して使う。
/// `ShapeSegmentEngine` と機能が重複するため、UI側でどちらを使うか切替えられるようにしている。
/// 対象範囲内に人物マスクが得られない場合（macOS 14未満、Vision結果なし等）は `ShapeSegmentEngine` にフォールバックする。
public final class VisionPersonSegmentEngine: Segmenting {
    private let fallback = ShapeSegmentEngine()

    public init() {}

    public func createMasks(for rois: [MosaicROI], in image: CGImage, extent: CGRect) throws -> [CIImage] {
        guard #available(macOS 14.0, *) else {
            return try fallback.createMasks(for: rois, in: image, extent: extent)
        }

        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        // Vision実行時エラーもshape基準へフォールバックする（ForegroundSegmentEngine/
        // RegionForegroundSegmentEngineと同じ挙動に統一。従来はここだけtryで例外を伝播させ、
        // applyMosaic全体が失敗していた）。
        try? handler.perform([request])

        guard let observation = request.results?.first else {
            return try fallback.createMasks(for: rois, in: image, extent: extent)
        }

        let rawMask = CIImage(cvPixelBuffer: observation.pixelBuffer).verticallyFlippedForRaster()
        guard rawMask.extent.width > 0, rawMask.extent.height > 0 else {
            return try fallback.createMasks(for: rois, in: image, extent: extent)
        }
        let scaleX = extent.width / rawMask.extent.width
        let scaleY = extent.height / rawMask.extent.height
        let black = CIImage(color: .black).cropped(to: extent)
        let fullFrameMask = rawMask
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .composited(over: black)

        return rois.map { roi in
            ShapeSegmentEngine.restrict(fullFrameMask, to: roi, extent: extent)
        }
    }
}


/// 学習済み部位セグメンテーションモデル（YOLO-seg）で部位の輪郭を直接得るエンジン。
///
/// 同梱の検出モデルは枠しか出力しないため、従来の「対象形状」はVisionの汎用APIで形状を
/// 近似していた。Visionの前景抽出は被写体と背景を分ける目的であり、被写体**内部**にある
/// 性器・乳首は原理的に分離できない（ARCHITECTURE §5.40/§5.41 の実測結果）。
/// 本エンジンは形状そのものを学習したモデルを使うことで、この限界を回避する。
///
/// モデルが未導入・推論失敗・マスクが空のいずれの場合も `ShapeSegmentEngine` へフォールバックし、
/// 選択範囲が必ず塗られるようにする（検閲漏れを作らないため）。
public final class LearnedShapeSegmentEngine: Segmenting {
    /// 学習モデルのマスクをROIへ対応付ける際の最小IoU。これを下回るものは「別の部位」とみなす。
    static let minimumMatchIoU = 0.2
    /// 採用するマスクの最小被覆率。これ未満は「ほぼ空」で検閲漏れになるためフォールバックする。
    static let minimumUsableCoverage = 0.02

    private let fallback = ShapeSegmentEngine()
    private let detector: PartSegmentationDetector?
    private let confidenceThreshold: Double
    private let measureContext = CIContext(options: [.cacheIntermediates: false])

    /// モデルが導入されているか（UIで選択肢を出すかの判定に使う）。
    public static var isAvailable: Bool { PartSegmentationDetector.isAvailable }

    public init(confidenceThreshold: Double = 0.3) {
        self.confidenceThreshold = confidenceThreshold
        // 未導入・読み込み失敗は例外にせず、フォールバック動作へ倒す（既存の運用を壊さないため）
        detector = try? PartSegmentationDetector()
        if detector == nil {
            segmentLogger.info("learnedShape unavailable=modelNotInstalled")
        }
    }

    public func createMasks(for rois: [MosaicROI], in image: CGImage, extent: CGRect) throws -> [CIImage] {
        guard let detector else {
            return try fallback.createMasks(for: rois, in: image, extent: extent)
        }
        let results: [PartSegmentationResult]
        do {
            results = try detector.detect(in: image, confidenceThreshold: confidenceThreshold)
        } catch {
            segmentLogger.info("learnedShape inferenceFailed fallback=shape")
            return try fallback.createMasks(for: rois, in: image, extent: extent)
        }
        segmentLogger.info("learnedShape detections=\(results.count)")

        var masks: [CIImage] = []
        for roi in rois {
            if let mask = learnedMask(for: roi, results: results, extent: extent) {
                masks.append(mask)
            } else {
                masks.append(try fallback.createMasks(for: [roi], in: image, extent: extent)[0])
            }
        }
        return masks
    }

    private func learnedMask(
        for roi: MosaicROI,
        results: [PartSegmentationResult],
        extent: CGRect
    ) -> CIImage? {
        // 同カテゴリを優先し、重なりが最も大きい検出結果を選ぶ
        let candidates = results
            .map { (result: $0, iou: $0.rect.iou(with: roi.rect)) }
            .filter { $0.iou >= Self.minimumMatchIoU }
        guard !candidates.isEmpty else {
            segmentLogger.info("""
                learnedShape category=\(roi.category.rawValue, privacy: .public) match=none fallback=shape
                """)
            return nil
        }
        let sameCategory = candidates.filter { $0.result.category == roi.category }
        let best = (sameCategory.isEmpty ? candidates : sameCategory).max { $0.iou < $1.iou }
        guard let best else { return nil }

        var mask = CIImage(cgImage: best.result.mask)
        if mask.extent.width != extent.width || mask.extent.height != extent.height {
            guard mask.extent.width > 0, mask.extent.height > 0 else { return nil }
            mask = mask.transformed(by: CGAffineTransform(
                scaleX: extent.width / mask.extent.width,
                y: extent.height / mask.extent.height
            ))
        }

        // 選択範囲の外へ広がらないよう、ROIの矩形（回転対応）で制限する。
        // 楕円マスクではなく二値の矩形マスクを使う（楕円は放射グラデーションのため、
        // せっかく取れた輪郭が縁へ向かって薄まってしまう。ARCHITECTURE §5.41）。
        let black = CIImage(color: .black).cropped(to: extent)
        let boundsMask = ShapeSegmentEngine.rectangleMask(
            rect: roi.rect.cgRect(imageSize: extent.size, origin: .bottomLeft),
            extent: extent,
            rotation: roi.rotation
        )
        let restricted = mask.composited(over: black).applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: boundsMask
        ]).cropped(to: extent)

        // 空に近いマスクは検閲漏れになるため採用しない
        let coverage = coverageRatio(of: restricted, in: roi.rect.cgRect(imageSize: extent.size, origin: .bottomLeft))
        segmentLogger.info("""
            learnedShape category=\(roi.category.rawValue, privacy: .public) \
            matched=\(best.result.category.rawValue, privacy: .public) \
            iou=\(String(format: "%.2f", best.iou), privacy: .public) \
            coverage=\(String(format: "%.2f", coverage), privacy: .public)
            """)
        guard coverage >= Self.minimumUsableCoverage else { return nil }
        return restricted
    }

    /// ROI矩形内での白領域の割合（リニア測定。ガンマの影響を受けない実面積比）。
    private func coverageRatio(of mask: CIImage, in rect: CGRect) -> Double {
        guard rect.width > 0, rect.height > 0 else { return 0 }
        let average = mask.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: rect)
        ])
        var pixel = [UInt8](repeating: 0, count: 4)
        let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        measureContext.render(
            average,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: linearSpace
        )
        return Double(pixel[0]) / 255.0
    }
}
