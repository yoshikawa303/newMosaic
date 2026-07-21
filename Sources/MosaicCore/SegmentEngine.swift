import CoreGraphics
import CoreImage
import Foundation
import Vision

/// マスク生成方式の識別子。UIの設定でユーザーが切替えるために使う。
public enum SegmentEngineKind: String, Codable, Sendable, CaseIterable {
    case shape
    case visionPersonSegmentation
    case foregroundObjects

    public var displayName: String {
        switch self {
        case .shape: return "図形ベース（矩形/楕円）"
        case .visionPersonSegmentation: return "Vision人物セグメンテーション"
        case .foregroundObjects: return "前景オブジェクト"
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
        rois.map { roi in
            let rect = roi.rect.cgRect(imageSize: extent.size, origin: .bottomLeft)
            switch roi.shape {
            case .rectangle:
                return Self.rectangleMask(rect: rect, extent: extent)
            case .ellipse:
                return Self.ellipseMask(rect: rect, extent: extent)
            }
        }
    }

    static func rectangleMask(rect: CGRect, extent: CGRect) -> CIImage {
        let white = CIImage(color: .white).cropped(to: rect)
        let black = CIImage(color: .black).cropped(to: extent)
        return white.composited(over: black)
    }

    static func ellipseMask(rect: CGRect, extent: CGRect) -> CIImage {
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

        let rawMask = CIImage(cvPixelBuffer: buffer)
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
            let rect = roi.rect.cgRect(imageSize: extent.size, origin: .bottomLeft)
            return fullFrameMask.cropped(to: rect).composited(over: black)
        }
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

        let rawMask = CIImage(cvPixelBuffer: observation.pixelBuffer)
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
            let rect = roi.rect.cgRect(imageSize: extent.size, origin: .bottomLeft)
            return fullFrameMask.cropped(to: rect).composited(over: black)
        }
    }
}
