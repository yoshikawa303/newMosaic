import CoreGraphics
import Foundation
import Vision

/// Visionのオブジェクトネス（顕著領域）検出で自動候補ROIの位置・サイズを精密化する。
/// 学習済み部位検出モデル（DETECTION_IMPROVEMENT_PLAN.md Phase 2本命、データセット待ち）までの
/// 追加コスト0・完全ローカルの暫定精密化として導入。
/// 顕著領域が見つからない・元ROIと整合しない場合は元のROIをそのまま返す（再現率優先）。
public final class SaliencyCandidateDetector: CandidateDetecting {
    private let autoSources: Set<String> = ["pose-chest", "pose-groin", "heuristic-lower-body"]

    public init() {}

    public func refineCandidates(_ rois: [MosaicROI], image: CGImage) throws -> [MosaicROI] {
        rois.map { roi in
            guard autoSources.contains(roi.source) else { return roi }
            return refined(roi, image: image) ?? roi
        }
    }

    private func refined(_ roi: MosaicROI, image: CGImage) -> MosaicROI? {
        let imageSize = CGSize(width: image.width, height: image.height)
        let searchArea = roi.rect.expanded(scale: 1.8).clamped()
        let cropRect = searchArea.cgRect(imageSize: imageSize, origin: .topLeft)
        guard cropRect.width >= 16, cropRect.height >= 16, let crop = image.cropping(to: cropRect) else { return nil }

        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
        guard let salientObjects = request.results?.first?.salientObjects, !salientObjects.isEmpty else { return nil }

        var best: (rect: NormalizedRect, score: Double, confidence: Double)?
        for object in salientObjects {
            // boundingBox はクロップ内正規化・左下原点。画像全体の左上原点正規化へ変換する。
            let box = object.boundingBox
            let inImage = NormalizedRect(
                x: searchArea.x + box.minX * searchArea.width,
                y: searchArea.y + (1 - box.minY - box.height) * searchArea.height,
                width: box.width * searchArea.width,
                height: box.height * searchArea.height
            ).clamped()
            guard let overlap = inImage.intersection(roi.rect) else { continue }
            let score = overlap.area / max(roi.rect.area, 1e-6)
            if best == nil || score > best!.score {
                best = (inImage, score, Double(object.confidence))
            }
        }
        guard let best, best.score >= 0.2, best.rect.area <= roi.rect.area * 4 else { return nil }

        var refined = roi
        refined.rect = best.rect
        refined.confidence = min(1, max(roi.confidence, best.confidence * 0.8))
        refined.source = roi.source + "+saliency"
        return refined
    }
}
