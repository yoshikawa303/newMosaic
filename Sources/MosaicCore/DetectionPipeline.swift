import CoreGraphics
import Foundation
import Vision

public protocol PersonDetecting {
    func detectPersonBounds(in image: CGImage) throws -> [NormalizedRect]
}

public protocol PoseEstimating {
    func estimatePose(in image: CGImage, personBounds: [NormalizedRect]) throws -> [PoseHint]
}

public protocol ROIGenerating {
    func generateROIs(from poseHints: [PoseHint], imageSize: CGSize) -> [MosaicROI]
}

public protocol CandidateDetecting {
    func refineCandidates(_ rois: [MosaicROI], image: CGImage) throws -> [MosaicROI]
}

public final class VisionPersonDetector: PersonDetecting {
    public init() {}

    public func detectPersonBounds(in image: CGImage) throws -> [NormalizedRect] {
        if #available(macOS 14.0, *) {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .balanced
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            if request.results?.isEmpty == false {
                return [NormalizedRect(x: 0.18, y: 0.08, width: 0.64, height: 0.84)]
            }
        }
        return [NormalizedRect(x: 0.24, y: 0.08, width: 0.52, height: 0.84)]
    }
}

public final class HeuristicPoseEstimator: PoseEstimating {
    public init() {}

    public func estimatePose(in image: CGImage, personBounds: [NormalizedRect]) throws -> [PoseHint] {
        personBounds.map { bounds in
            let lowerBody = NormalizedRect(
                x: bounds.x + bounds.width * 0.18,
                y: bounds.y + bounds.height * 0.48,
                width: bounds.width * 0.64,
                height: bounds.height * 0.36
            )
            return PoseHint(bodyBounds: bounds, lowerBodyBounds: lowerBody)
        }
    }
}

public final class SensitiveROIGenerator: ROIGenerating {
    public init() {}

    public func generateROIs(from poseHints: [PoseHint], imageSize: CGSize) -> [MosaicROI] {
        poseHints.map { hint in
            let lower = hint.lowerBodyBounds
            let focus = NormalizedRect(
                x: lower.x + lower.width * 0.18,
                y: lower.y + lower.height * 0.12,
                width: lower.width * 0.64,
                height: lower.height * 0.42
            )
            return MosaicROI(rect: focus, confidence: 0.42, source: "heuristic-lower-body")
        }
    }
}

public final class PassThroughCandidateDetector: CandidateDetecting {
    public init() {}

    public func refineCandidates(_ rois: [MosaicROI], image: CGImage) throws -> [MosaicROI] {
        rois
    }
}

public final class StaticImageMosaicPipeline {
    private let personDetector: PersonDetecting
    private let poseEstimator: PoseEstimating
    private let roiGenerator: ROIGenerating
    private let candidateDetector: CandidateDetecting

    public init(
        personDetector: PersonDetecting = VisionPersonDetector(),
        poseEstimator: PoseEstimating = HeuristicPoseEstimator(),
        roiGenerator: ROIGenerating = SensitiveROIGenerator(),
        candidateDetector: CandidateDetecting = PassThroughCandidateDetector()
    ) {
        self.personDetector = personDetector
        self.poseEstimator = poseEstimator
        self.roiGenerator = roiGenerator
        self.candidateDetector = candidateDetector
    }

    public func generateCandidates(for image: CGImage) throws -> [MosaicROI] {
        let bounds = try personDetector.detectPersonBounds(in: image)
        let hints = try poseEstimator.estimatePose(in: image, personBounds: bounds)
        let rois = roiGenerator.generateROIs(
            from: hints,
            imageSize: CGSize(width: image.width, height: image.height)
        )
        return try candidateDetector.refineCandidates(rois, image: image)
    }
}
