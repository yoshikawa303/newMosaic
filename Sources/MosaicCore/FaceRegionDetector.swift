import CoreGraphics
import Foundation
import Vision

/// 顔領域（目元・眼窩下〜オトガイ）の共通構築ロジック。
/// 実写（Visionランドマーク）とアニメ（DWPose顔キーポイント）の両検出器から共用する。
public enum FaceRegionBuilder {
    /// 目元領域: 両目（+眉があれば眉上端）を含む横長の帯。
    public static func eyesRect(
        eyePoints: [(x: Double, y: Double)],
        browPoints: [(x: Double, y: Double)]
    ) -> NormalizedRect? {
        guard !eyePoints.isEmpty else { return nil }
        let allPoints = eyePoints + browPoints
        guard let minX = allPoints.map(\.x).min(),
              let maxX = allPoints.map(\.x).max(),
              let eyeBottom = eyePoints.map(\.y).max() else { return nil }
        let topSource = browPoints.isEmpty ? eyePoints : browPoints
        guard let top = topSource.map(\.y).min() else { return nil }
        let width = maxX - minX
        guard width > 0.01 else { return nil }
        let height = max(0.015, eyeBottom - top)
        let padX = width * 0.15
        let padY = height * 0.4
        return NormalizedRect(
            x: minX - padX,
            y: top - padY * 0.5,
            width: width + padX * 2,
            height: height + padY * 1.5
        ).clamped()
    }

    /// 眼窩下〜オトガイ領域: 上端=目の下端（眼窩）、下端=あご先、幅=顔輪郭の幅。
    public static func lowerFaceRect(
        eyePoints: [(x: Double, y: Double)],
        contourPoints: [(x: Double, y: Double)]
    ) -> NormalizedRect? {
        guard let eyeBottom = eyePoints.map(\.y).max(),
              let chin = contourPoints.map(\.y).max(),
              let minX = contourPoints.map(\.x).min(),
              let maxX = contourPoints.map(\.x).max(),
              chin > eyeBottom, maxX - minX > 0.01 else { return nil }
        let height = chin - eyeBottom
        return NormalizedRect(
            x: minX,
            y: eyeBottom,
            width: maxX - minX,
            height: height * 1.06
        ).clamped()
    }
}

/// 実写向けの顔領域検出器。`VNDetectFaceLandmarksRequest` のランドマーク
/// （目・眉・顔輪郭）から「目元」「眼窩下〜あご」のカテゴリ付きROIを顔ごとに生成する。
/// 完全ローカル実行。
public final class FaceRegionDetector {
    public init() {}

    public func detectRegions(in image: CGImage) throws -> [MosaicROI] {
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var rois: [MosaicROI] = []
        for face in request.results ?? [] {
            guard let landmarks = face.landmarks else { continue }
            let boundingBox = face.boundingBox

            // ランドマーク（顔矩形内正規化・左下原点）→ 画像全体正規化（上原点）へ変換
            func imagePoints(_ region: VNFaceLandmarkRegion2D?) -> [(x: Double, y: Double)] {
                guard let region else { return [] }
                return region.normalizedPoints.map { point in
                    (
                        x: Double(boundingBox.origin.x) + Double(point.x) * Double(boundingBox.width),
                        y: 1 - (Double(boundingBox.origin.y) + Double(point.y) * Double(boundingBox.height))
                    )
                }
            }

            let eyePoints = imagePoints(landmarks.leftEye) + imagePoints(landmarks.rightEye)
            let browPoints = imagePoints(landmarks.leftEyebrow) + imagePoints(landmarks.rightEyebrow)
            let contourPoints = imagePoints(landmarks.faceContour)
            let confidence = Double(face.confidence)

            if let rect = FaceRegionBuilder.eyesRect(eyePoints: eyePoints, browPoints: browPoints) {
                rois.append(MosaicROI(
                    rect: rect,
                    confidence: confidence,
                    source: "face-region",
                    shape: .rectangle,
                    category: .eyes
                ))
            }
            if let rect = FaceRegionBuilder.lowerFaceRect(eyePoints: eyePoints, contourPoints: contourPoints) {
                rois.append(MosaicROI(
                    rect: rect,
                    confidence: confidence,
                    source: "face-region",
                    shape: .rectangle,
                    category: .lowerFace
                ))
            }
        }
        return rois
    }
}
