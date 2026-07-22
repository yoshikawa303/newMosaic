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

    public var displayName: String {
        switch self {
        case .shape: return "図形ベース（矩形/楕円）"
        case .visionPersonSegmentation: return "Vision人物セグメンテーション"
        case .foregroundObjects: return "前景オブジェクト"
        case .regionForeground: return "対象の形状（ROI内前景）"
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
        }
    }

    /// ビュー座標（上原点・時計回り）の回転角を、CI座標（下原点）の回転変換へ変換する。
    static func ciRotation(around center: CGPoint, degrees: Double) -> CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: -degrees * .pi / 180)
            .translatedBy(x: -center.x, y: -center.y)
    }

    static func rectangleMask(rect: CGRect, extent: CGRect, rotation: Double = 0) -> CIImage {
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

    public init() {}

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
        let expanded = roi.rect.expanded(scale: 1.15).clamped()
        let cropRect = expanded.cgRect(imageSize: imageSize, origin: .topLeft)
        guard cropRect.width >= 16, cropRect.height >= 16,
              let crop = image.cropping(to: cropRect) else { return nil }

        var localMask = Self.foregroundMask(in: crop)
        // 前景がクロップのほぼ全面を覆う場合（ROI周辺が人物で埋まっていて対象物を分離できていない）
        // や前景が得られない場合は、顕著領域マスクでROI内の対象物の形状を取る
        if localMask == nil || coverageRatio(of: localMask!) > 0.85 {
            localMask = Self.saliencyMask(in: crop) ?? localMask
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
        // 前景マスクをROIの形状範囲（矩形/楕円+回転）に制限して返す（ROI外へモザイクが漏れないようにする）
        return ShapeSegmentEngine.restrict(mask.composited(over: black), to: roi, extent: extent)
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
        try handler.perform([request])

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
