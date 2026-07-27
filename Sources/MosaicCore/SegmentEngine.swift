import CoreGraphics
import CoreImage
import Foundation
import Vision

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
    /// 「対象形状」のリリース初期（Build 41）実装。現行実装との精度比較用（デバッグ・検証目的）。
    case regionForegroundLegacy

    public var displayName: String {
        switch self {
        case .shape: return "図形（矩形/楕円）"
        case .visionPersonSegmentation: return "人物の輪郭（AI自動認識）"
        case .foregroundObjects: return "物体の輪郭（自動抽出）"
        case .regionForeground: return "対象形状"
        case .regionForegroundLegacy: return "対象形状（初期実装・比較用）"
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
              let crop = image.cropping(to: cropRect) else { return nil }

        var localMask = Self.foregroundMask(in: crop)
        // 前景がクロップのほぼ全面を覆う場合（ROI周辺が人物で埋まっていて対象物を分離できていない）
        // や前景が得られない場合は、顕著領域マスクでROI内の対象物の形状を取る
        if localMask.map({ coverageRatio(of: $0) > 0.85 }) ?? true {
            localMask = Self.saliencyMask(in: crop) ?? localMask
        }
        guard var mask = localMask, mask.extent.width > 0, mask.extent.height > 0 else { return nil }

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
        measureContext.render(
            average,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return Double(pixel[0]) / 255.0
    }
}


/// 「対象形状」のリリース初期（Build 41相当）実装。現行の`RegionForegroundSegmentEngine`との
/// 精度比較用に残す（マスク生成の選択肢からデバッグ目的で選べる）。
///
/// 現行実装との違いは最終段の制限方法のみ:
/// - 初期実装（本クラス）: 前景マスクをROIの**矩形**へクロップする。楕円ROIでも矩形で切るため、
///   取れた対象物の輪郭がそのまま残る。
/// - 現行実装: `ShapeSegmentEngine.restrict`でROIの**形状マスク**（楕円は放射グラデーション）を
///   乗算する。ROI外へのはみ出しは防げるが、楕円ROIでは境界へ向かってマスクが薄くなり、
///   対象物の輪郭が縁で欠けることがある。
///
/// クロップ範囲・前景抽出・顕著領域マスクの処理は現行と共通（v0.0.00083で当時と同一へ復元済み）。
public final class LegacyRegionForegroundSegmentEngine: Segmenting {
    private let fallback = ShapeSegmentEngine()
    private let core = RegionForegroundSegmentEngine()

    public init() {}

    public func createMasks(for rois: [MosaicROI], in image: CGImage, extent: CGRect) throws -> [CIImage] {
        let imageSize = CGSize(width: image.width, height: image.height)
        var results: [CIImage] = []
        for roi in rois {
            if let mask = legacyRegionMask(for: roi, in: image, imageSize: imageSize, extent: extent) {
                results.append(mask)
            } else {
                let fallbackMasks = try fallback.createMasks(for: [roi], in: image, extent: extent)
                results.append(fallbackMasks[0])
            }
        }
        return results
    }

    private func legacyRegionMask(
        for roi: MosaicROI,
        in image: CGImage,
        imageSize: CGSize,
        extent: CGRect
    ) -> CIImage? {
        // 当時（Build 41）は選択範囲の回転機能が無かったため、初期実装は`roi.rect`（無回転）
        // だけを見ていた。回転ROIへそのまま適用すると、クロップからも最終の切り取りからも
        // 実際の（傾いた）選択範囲が外れ、軸並行の四角いブロックになってしまう
        // （GUI報告の症状）。回転ROIでは回転後の外接矩形でクロップする。
        let baseNormalized: NormalizedRect
        if abs(roi.rotation) > 0.01 {
            let baseRectPixels = roi.rect.cgRect(imageSize: imageSize, origin: .topLeft)
            baseNormalized = NormalizedRect(
                Self.rotatedBoundingBox(of: baseRectPixels, rotationDegrees: roi.rotation),
                imageSize: imageSize
            )
        } else {
            baseNormalized = roi.rect
        }
        let expanded = baseNormalized.expanded(scale: 1.15).clamped()
        let cropRect = expanded.cgRect(imageSize: imageSize, origin: .topLeft)
        guard cropRect.width >= 16, cropRect.height >= 16,
              let crop = image.cropping(to: cropRect) else { return nil }

        var localMask = RegionForegroundSegmentEngine.foregroundMask(in: crop)
        // 前景がクロップのほぼ全面を覆う場合は顕著領域マスクへ切り替える（当時と同じ判定）
        if localMask.map({ core.coverageRatio(of: $0) > 0.85 }) ?? true {
            localMask = RegionForegroundSegmentEngine.saliencyMask(in: crop) ?? localMask
        }
        guard var mask = localMask, mask.extent.width > 0, mask.extent.height > 0 else { return nil }

        // クロップ実サイズへスケールし、CI座標（下原点）でクロップ位置に配置する
        let scaleX = cropRect.width / mask.extent.width
        let scaleY = cropRect.height / mask.extent.height
        let cropRectCI = expanded.cgRect(imageSize: imageSize, origin: .bottomLeft)
        mask = mask
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: cropRectCI.minX, y: cropRectCI.minY))

        let black = CIImage(color: .black).cropped(to: extent)
        // ★初期実装の要: ROIの「矩形」で制限する（形状マスクの乗算はしない）。
        // 矩形マスクは白/黒の二値のため、楕円マスク（放射グラデーション）のように
        // 縁へ向かってマスクが薄くならず、取れた対象物の輪郭がそのまま残る。
        // 当時の`cropped(to:)`と違い回転に対応させ、傾いた選択範囲でも正しく切り取る。
        let roiRect = roi.rect.cgRect(imageSize: extent.size, origin: .bottomLeft)
        let boundsMask = ShapeSegmentEngine.rectangleMask(
            rect: roiRect,
            extent: extent,
            rotation: roi.rotation
        )
        return mask.composited(over: black).applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: boundsMask
        ]).cropped(to: extent)
    }

    /// 矩形を中心周りに回転させた場合の軸並行外接矩形（現行エンジンと同じ計算）。
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
