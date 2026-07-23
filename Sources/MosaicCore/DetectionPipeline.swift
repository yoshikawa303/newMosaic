import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import OSLog
import Vision

private let detectionLogger = Logger(subsystem: "com.yoshikawa.newMosaic", category: "Detection")

/// 人物1名分の検出結果。マスクは人物シルエット表示用（取得できない場合はnil）。
public struct PersonDetection {
    public var bounds: NormalizedRect
    public var maskImage: CGImage?

    public init(bounds: NormalizedRect, maskImage: CGImage? = nil) {
        self.bounds = bounds
        self.maskImage = maskImage
    }
}

public protocol PersonDetecting {
    func detectPersons(in image: CGImage) throws -> [PersonDetection]
}

public protocol PoseEstimating {
    func estimatePose(in image: CGImage, persons: [PersonDetection]) throws -> [PoseHint]
}

public protocol ROIGenerating {
    func generateROIs(from poseHints: [PoseHint], imageSize: CGSize) -> [MosaicROI]
}

public protocol CandidateDetecting {
    func refineCandidates(_ rois: [MosaicROI], image: CGImage) throws -> [MosaicROI]
}

/// Vision人物インスタンスマスク（最大4人）による実位置検出。
/// 5人以上や失敗時は人物矩形検出へフォールバックする。
public final class VisionPersonDetector: PersonDetecting {
    private struct InstanceMaskResult {
        var persons: [PersonDetection]
        var reachedInstanceLimit: Bool
    }

    private let context = CIContext(options: [.cacheIntermediates: false])

    public init() {}

    public func detectPersons(in image: CGImage) throws -> [PersonDetection] {
        let instanceResult: InstanceMaskResult?
        do {
            instanceResult = try detectWithInstanceMasks(in: image)
        } catch {
            detectionLogger.error("Person instance-mask detection failed: \(error.localizedDescription, privacy: .public)")
            instanceResult = nil
        }
        if let result = instanceResult, !result.persons.isEmpty {
            guard result.reachedInstanceLimit else { return result.persons }
            let rectangles: [PersonDetection]
            do {
                rectangles = try detectWithHumanRectangles(in: image)
            } catch {
                detectionLogger.error("Human rectangle supplement failed: \(error.localizedDescription, privacy: .public)")
                rectangles = []
            }
            return Self.mergePersonDetections(instancePersons: result.persons, rectanglePersons: rectangles)
        }
        // 漫画・イラスト等では実写学習のVisionが人物を検出できないことがあるが、
        // 検出していないのに固定比率の偽矩形を返すことはしない（正確な検知内容の表示を優先。
        // ユーザー方針 2026-07-22）。0件時はUI側で手動ROI追加を案内する。
        return try detectWithHumanRectangles(in: image)
    }

    private func detectWithInstanceMasks(in image: CGImage) throws -> InstanceMaskResult {
        let request = VNGeneratePersonInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else {
            return InstanceMaskResult(persons: [], reachedInstanceLimit: false)
        }

        var persons: [PersonDetection] = []
        for instance in observation.allInstances.sorted() {
            let maskBuffer: CVPixelBuffer
            do {
                maskBuffer = try observation.generateScaledMaskForImage(
                    forInstances: IndexSet(integer: instance),
                    from: handler
                )
            } catch {
                detectionLogger.error("Scaled person mask generation failed for instance \(instance): \(error.localizedDescription, privacy: .public)")
                continue
            }
            guard let maskImage = cgImage(from: maskBuffer),
                  let bounds = Self.maskBounds(in: maskImage) else { continue }
            persons.append(PersonDetection(bounds: bounds, maskImage: maskImage))
        }
        return InstanceMaskResult(
            persons: persons,
            reachedInstanceLimit: observation.allInstances.count >= 4
        )
    }

    private func detectWithHumanRectangles(in image: CGImage) throws -> [PersonDetection] {
        let request = VNDetectHumanRectanglesRequest()
        // upperBodyOnly=false（全身矩形）はrevision 2でのみ有効なため明示指定する。
        request.revision = VNDetectHumanRectanglesRequestRevision2
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).map {
            PersonDetection(bounds: Self.normalizedRect(fromVisionRect: $0.boundingBox))
        }
    }

    /// インスタンスラベルマップ（画素値=インスタンス番号）から該当インスタンスの外接矩形を求める。
    static func instanceBounds(in labelMap: CVPixelBuffer, instance: Int) -> NormalizedRect? {
        CVPixelBufferLockBaseAddress(labelMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labelMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(labelMap) else { return nil }
        let width = CVPixelBufferGetWidth(labelMap)
        let height = CVPixelBufferGetHeight(labelMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(labelMap)
        guard width > 0, height > 0, instance >= 0, instance <= UInt8.max else { return nil }

        let target = UInt8(instance)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width where row[x] == target {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return NormalizedRect(
            x: Double(minX) / Double(width),
            y: Double(minY) / Double(height),
            width: Double(maxX - minX + 1) / Double(width),
            height: Double(maxY - minY + 1) / Double(height)
        )
    }

    static func normalizedRect(fromVisionRect rect: CGRect) -> NormalizedRect {
        NormalizedRect(x: rect.minX, y: 1 - rect.minY - rect.height, width: rect.width, height: rect.height)
    }

    /// 原画像サイズへ復元済みの表示用マスクから人物外接矩形を算出する。
    static func maskBounds(in maskImage: CGImage, threshold: UInt8 = 127) -> NormalizedRect? {
        let width = maskImage.width
        let height = maskImage.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(
                data: pointer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(maskImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        return normalizedBounds(in: pixels, width: width, height: height, threshold: threshold)
    }

    static func normalizedBounds(
        in pixels: [UInt8],
        width: Int,
        height: Int,
        threshold: UInt8 = 127
    ) -> NormalizedRect? {
        guard width > 0, height > 0, pixels.count >= width * height else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] > threshold {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return NormalizedRect(
            x: Double(minX) / Double(width),
            y: Double(minY) / Double(height),
            width: Double(maxX - minX + 1) / Double(width),
            height: Double(maxY - minY + 1) / Double(height)
        )
    }

    static func mergePersonDetections(
        instancePersons: [PersonDetection],
        rectanglePersons: [PersonDetection],
        duplicateIoU: Double = 0.35
    ) -> [PersonDetection] {
        struct Match {
            var instanceIndex: Int
            var rectangleIndex: Int
            var iou: Double
        }

        let matches = instancePersons.indices.flatMap { instanceIndex in
            rectanglePersons.indices.compactMap { rectangleIndex -> Match? in
                let iou = instancePersons[instanceIndex].bounds.iou(
                    with: rectanglePersons[rectangleIndex].bounds
                )
                let containedOverlap = Self.overlapOfSmaller(
                    instancePersons[instanceIndex].bounds,
                    rectanglePersons[rectangleIndex].bounds
                )
                return iou >= duplicateIoU || containedOverlap >= 0.65
                    ? Match(instanceIndex: instanceIndex, rectangleIndex: rectangleIndex, iou: max(iou, containedOverlap))
                    : nil
            }
        }
        .sorted { $0.iou > $1.iou }

        var matchedInstances = Set<Int>()
        var matchedRectangles = Set<Int>()
        for match in matches
        where !matchedInstances.contains(match.instanceIndex)
            && !matchedRectangles.contains(match.rectangleIndex) {
            matchedInstances.insert(match.instanceIndex)
            matchedRectangles.insert(match.rectangleIndex)
        }

        var merged = instancePersons
        for index in rectanglePersons.indices where !matchedRectangles.contains(index) {
            let rectangle = rectanglePersons[index]
            let isDuplicate = merged.contains {
                $0.bounds.iou(with: rectangle.bounds) >= duplicateIoU
                    || Self.overlapOfSmaller($0.bounds, rectangle.bounds) >= 0.65
            }
            if !isDuplicate {
                merged.append(rectangle)
            }
        }
        return merged
    }

    static func overlapOfSmaller(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Double {
        guard let overlap = lhs.intersection(rhs) else { return 0 }
        let smallerArea = min(lhs.area, rhs.area)
        guard smallerArea > 0 else { return 0 }
        return overlap.area / smallerArea
    }

    private func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        // CVPixelBuffer→CIImage→CGImage の経路は最終表示で上下反転する（GUI確認で判明）ため垂直反転で補正する。
        let ciImage = CIImage(cvPixelBuffer: buffer).verticallyFlippedForRaster()
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}

/// 人物シルエットマスクを縮小サンプリングし、正規化座標（左上原点）が人物領域内かを高速判定する。
/// 骨格と人物の対応付け（関節の内包カウント）に使う。
struct PersonMaskSampler {
    private let width: Int
    private let height: Int
    private let data: [UInt8]

    init?(maskImage: CGImage, sampleSize: Int = 128) {
        var buffer = [UInt8](repeating: 0, count: sampleSize * sampleSize)
        let drawn = buffer.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(
                data: pointer.baseAddress,
                width: sampleSize,
                height: sampleSize,
                bitsPerComponent: 8,
                bytesPerRow: sampleSize,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(maskImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
            return true
        }
        guard drawn else { return nil }
        self.width = sampleSize
        self.height = sampleSize
        self.data = buffer
    }

    func contains(x: Double, y: Double) -> Bool {
        guard x >= 0, x < 1, y >= 0, y < 1 else { return false }
        let pixelX = Int(x * Double(width))
        let pixelY = Int(y * Double(height))
        return data[pixelY * width + pixelX] > 127
    }

    /// 指定点の周辺（正規化半径 radius）まで含めた緩衝付きの内包判定。
    /// 輪郭ぎりぎりの関節（髪・衣服で隠れた部位など）を誤って除外しないために使う。
    func containsNear(x: Double, y: Double, radius: Double = 0.03) -> Bool {
        if contains(x: x, y: y) { return true }
        let offsets: [(Double, Double)] = [
            (-radius, 0), (radius, 0), (0, -radius), (0, radius),
            (-radius, -radius), (radius, radius), (-radius, radius), (radius, -radius)
        ]
        return offsets.contains { contains(x: x + $0.0, y: y + $0.1) }
    }
}

enum PoseCropRotation: CaseIterable {
    case none
    case clockwise
    case counterClockwise
}

struct PoseCandidateEvaluation: Equatable {
    var score: Double
    var centerScore: Double
    var rectangleInsideRatio: Double
    var maskNearRatio: Double
    var meanConfidence: Double
    var jointCompleteness: Double
}

enum PoseDetectionMath {
    static func actualRegion(for cropRect: CGRect, imageSize: CGSize) -> NormalizedRect {
        NormalizedRect(cropRect, imageSize: imageSize).clamped()
    }

    static func cropRotations(for bounds: NormalizedRect) -> [PoseCropRotation] {
        bounds.width > bounds.height * 1.15 ? PoseCropRotation.allCases : [.none]
    }

    static func restoreJoints(
        _ joints: [PoseJoint],
        from region: NormalizedRect,
        rotation: PoseCropRotation
    ) -> [PoseJoint] {
        joints.map { joint in
            let local: CGPoint
            switch rotation {
            case .none:
                local = CGPoint(x: joint.x, y: joint.y)
            case .clockwise:
                local = CGPoint(x: joint.y, y: 1 - joint.x)
            case .counterClockwise:
                local = CGPoint(x: 1 - joint.y, y: joint.x)
            }
            return PoseJoint(
                name: joint.name,
                x: region.x + local.x * region.width,
                y: region.y + local.y * region.height,
                confidence: joint.confidence
            )
        }
    }

    static func evaluate(
        joints: [PoseJoint],
        personBounds: NormalizedRect,
        maskNearMatches: [Bool]? = nil
    ) -> PoseCandidateEvaluation {
        guard !joints.isEmpty else {
            return PoseCandidateEvaluation(
                score: 0,
                centerScore: 0,
                rectangleInsideRatio: 0,
                maskNearRatio: 0,
                meanConfidence: 0,
                jointCompleteness: 0
            )
        }
        let expandedBounds = personBounds.expanded(scale: 1.10).clamped()
        let insideCount = joints.filter { expandedBounds.contains(x: $0.x, y: $0.y) }.count
        let rectangleInsideRatio = Double(insideCount) / Double(joints.count)
        let maskNearRatio: Double
        if let maskNearMatches, maskNearMatches.count == joints.count {
            maskNearRatio = Double(maskNearMatches.filter { $0 }.count) / Double(joints.count)
        } else {
            maskNearRatio = rectangleInsideRatio
        }

        let centerX = joints.map(\.x).reduce(0, +) / Double(joints.count)
        let centerY = joints.map(\.y).reduce(0, +) / Double(joints.count)
        let personCenterX = personBounds.x + personBounds.width / 2
        let personCenterY = personBounds.y + personBounds.height / 2
        let diagonal = max(0.05, hypot(personBounds.width, personBounds.height))
        let centerDistance = hypot(centerX - personCenterX, centerY - personCenterY) / diagonal
        let centerScore = max(0, 1 - min(1, centerDistance))
        let meanConfidence = joints.map(\.confidence).reduce(0, +) / Double(joints.count)
        let jointCompleteness = min(1, Double(joints.count) / 15.0)
        let score = centerScore * 0.25
            + rectangleInsideRatio * 0.30
            + maskNearRatio * 0.20
            + meanConfidence * 0.15
            + jointCompleteness * 0.10
        return PoseCandidateEvaluation(
            score: score,
            centerScore: centerScore,
            rectangleInsideRatio: rectangleInsideRatio,
            maskNearRatio: maskNearRatio,
            meanConfidence: meanConfidence,
            jointCompleteness: jointCompleteness
        )
    }

    static func isAssociatedWithPerson(
        _ evaluation: PoseCandidateEvaluation,
        hasMask: Bool
    ) -> Bool {
        evaluation.rectangleInsideRatio >= 0.60
            && (!hasMask || evaluation.maskNearRatio >= 0.60)
    }

    static func areDuplicatePoses(
        _ lhs: [PoseJoint],
        lhsBounds: NormalizedRect,
        _ rhs: [PoseJoint],
        rhsBounds: NormalizedRect
    ) -> Bool {
        let rhsByName = Dictionary(uniqueKeysWithValues: rhs.map { ($0.name, $0) })
        let distances = lhs.compactMap { left -> Double? in
            guard let right = rhsByName[left.name] else { return nil }
            return hypot(left.x - right.x, left.y - right.y)
        }
        guard distances.count >= 4 else { return false }
        let scale = max(
            0.05,
            min(
                hypot(lhsBounds.width, lhsBounds.height),
                hypot(rhsBounds.width, rhsBounds.height)
            )
        )
        let meanDistance = distances.reduce(0, +) / Double(distances.count)
        return meanDistance / scale <= 0.12
    }

    static func faceGuidedRegions(
        face: NormalizedRect,
        personBounds: NormalizedRect
    ) -> [NormalizedRect] {
        guard personBounds.width > personBounds.height * 1.15 else {
            return [NormalizedRect(
                x: face.x + face.width / 2 - face.width * 2.25,
                y: face.y - face.height * 0.5,
                width: face.width * 4.5,
                height: face.height * 8.5
            ).clamped()]
        }

        let bodyWidth = max(personBounds.width * 1.20, face.height * 8.5)
        let bodyHeight = max(personBounds.height * 1.20, face.width * 4.5)
        let faceCenterX = face.x + face.width / 2
        let faceCenterY = face.y + face.height / 2
        return [
            clampedPreservingSize(personBounds.expanded(scale: 1.20)),
            clampedPreservingSize(NormalizedRect(
                x: faceCenterX - face.width,
                y: faceCenterY - bodyHeight / 2,
                width: bodyWidth,
                height: bodyHeight
            )),
            clampedPreservingSize(NormalizedRect(
                x: faceCenterX - bodyWidth + face.width,
                y: faceCenterY - bodyHeight / 2,
                width: bodyWidth,
                height: bodyHeight
            ))
        ]
    }

    static func clampedPreservingSize(_ rect: NormalizedRect) -> NormalizedRect {
        let width = min(1, max(0, rect.width))
        let height = min(1, max(0, rect.height))
        let x = min(max(0, rect.x), 1 - width)
        let y = min(max(0, rect.y), 1 - height)
        return NormalizedRect(x: x, y: y, width: width, height: height)
    }
}

/// Vision骨格検出。人物ごとのクロップで候補を生成し、人物矩形・マスク近傍・
/// 中心距離・confidence・関節数を複合評価する。選択後の関節はシルエット外でも保持する。
public final class VisionPoseEstimator: PoseEstimating {
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    private struct PoseCandidate {
        var joints: [PoseJoint]
        var evaluation: PoseCandidateEvaluation
    }

    private struct SelectedPose {
        var joints: [PoseJoint]
        var personBounds: NormalizedRect
    }

    private static let jointMapping: [(VNHumanBodyPoseObservation.JointName, PoseJointName)] = [
        (.nose, .nose), (.neck, .neck),
        (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
        (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
        (.root, .root),
        (.leftHip, .leftHip), (.rightHip, .rightHip),
        (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
        (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)
    ]

    public init() {}

    public func estimatePose(in image: CGImage, persons: [PersonDetection]) throws -> [PoseHint] {
        let imageSize = CGSize(width: image.width, height: image.height)
        var selectedPoses: [SelectedPose] = []
        return persons.map { person in
            guard let hint = estimatePoseInPersonRegion(
                image: image,
                imageSize: imageSize,
                person: person,
                selectedPoses: selectedPoses
            ) else {
                return HeuristicPoseEstimator.fallbackHint(for: person.bounds)
            }
            selectedPoses.append(SelectedPose(joints: hint.joints, personBounds: person.bounds))
            return hint
        }
    }

    private func estimatePoseInPersonRegion(
        image: CGImage,
        imageSize: CGSize,
        person: PersonDetection,
        selectedPoses: [SelectedPose]
    ) -> PoseHint? {
        let region = person.bounds.expanded(scale: 1.15).clamped()
        let cropRect = region.cgRect(imageSize: imageSize, origin: .topLeft)
        guard cropRect.width >= 8, cropRect.height >= 8,
              region.width > 0, region.height > 0,
              let crop = image.cropping(to: cropRect) else { return nil }
        let actualRegion = PoseDetectionMath.actualRegion(for: cropRect, imageSize: imageSize)
        let preparedCrop = Self.preparedForDetection(crop)

        let directCandidates = detectPoseCandidates(in: preparedCrop, region: actualRegion, person: person)
        if let candidate = bestCandidate(
            from: directCandidates,
            person: person,
            excluding: selectedPoses
        ) {
            return hint(from: candidate, person: person)
        }
        let fallbackCandidates = faceGuidedPoseCandidates(
            image: image,
            imageSize: imageSize,
            person: person,
            personCrop: preparedCrop,
            cropRegion: actualRegion
        )
        guard let candidate = bestCandidate(
            from: fallbackCandidates,
            person: person,
            excluding: selectedPoses
        ) else { return nil }
        return hint(from: candidate, person: person)
    }

    private func detectPoseCandidates(
        in crop: CGImage,
        region: NormalizedRect,
        person: PersonDetection
    ) -> [PoseCandidate] {
        let sampler = person.maskImage.flatMap { PersonMaskSampler(maskImage: $0) }
        var candidates: [PoseCandidate] = []
        for rotation in PoseDetectionMath.cropRotations(for: person.bounds) {
            guard let detectionImage = rotated(crop, rotation: rotation) else { continue }
            let request = VNDetectHumanBodyPoseRequest()
            do {
                try VNImageRequestHandler(cgImage: detectionImage, options: [:]).perform([request])
            } catch {
                detectionLogger.error("Body pose detection failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
            for observation in request.results ?? [] {
                let localJoints = Self.joints(from: observation)
                guard localJoints.count >= 4 else { continue }
                let fullJoints = PoseDetectionMath.restoreJoints(
                    localJoints,
                    from: region,
                    rotation: rotation
                )
                let maskMatches = sampler.map { sampler in
                    fullJoints.map { sampler.containsNear(x: $0.x, y: $0.y) }
                }
                let evaluation = PoseDetectionMath.evaluate(
                    joints: fullJoints,
                    personBounds: person.bounds,
                    maskNearMatches: maskMatches
                )
                guard PoseDetectionMath.isAssociatedWithPerson(
                    evaluation,
                    hasMask: sampler != nil
                ) else { continue }
                candidates.append(PoseCandidate(joints: fullJoints, evaluation: evaluation))
            }
        }
        return candidates.sorted { $0.evaluation.score > $1.evaluation.score }
    }

    private func faceGuidedPoseCandidates(
        image: CGImage,
        imageSize: CGSize,
        person: PersonDetection,
        personCrop: CGImage,
        cropRegion: NormalizedRect
    ) -> [PoseCandidate] {
        let faceRequest = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: personCrop, options: [:]).perform([faceRequest])
        } catch {
            detectionLogger.error("Face-guided pose fallback failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let sampler = person.maskImage.flatMap { PersonMaskSampler(maskImage: $0) }
        let faces = (faceRequest.results ?? []).compactMap { face -> (NormalizedRect, Float)? in
            let bb = face.boundingBox
            let full = NormalizedRect(
                x: cropRegion.x + bb.origin.x * cropRegion.width,
                y: cropRegion.y + (1 - bb.origin.y - bb.height) * cropRegion.height,
                width: bb.width * cropRegion.width,
                height: bb.height * cropRegion.height
            )
            let centerX = full.x + full.width / 2
            let centerY = full.y + full.height / 2
            let belongsToPerson = sampler?.containsNear(x: centerX, y: centerY)
                ?? person.bounds.expanded(scale: 1.10).clamped().contains(x: centerX, y: centerY)
            return belongsToPerson ? (full, face.confidence) : nil
        }
        .sorted { $0.1 > $1.1 }

        var candidates: [PoseCandidate] = []
        for (face, _) in faces.prefix(2) {
            for bodyRegion in PoseDetectionMath.faceGuidedRegions(face: face, personBounds: person.bounds) {
                let bodyRect = bodyRegion.cgRect(imageSize: imageSize, origin: .topLeft)
                guard bodyRect.width >= 8, bodyRect.height >= 8,
                      let bodyCrop = image.cropping(to: bodyRect) else { continue }
                let actualBodyRegion = PoseDetectionMath.actualRegion(for: bodyRect, imageSize: imageSize)
                candidates.append(contentsOf: detectPoseCandidates(
                    in: Self.preparedForDetection(bodyCrop),
                    region: actualBodyRegion,
                    person: person
                ))
            }
        }
        return candidates.sorted { $0.evaluation.score > $1.evaluation.score }
    }

    private func bestCandidate(
        from candidates: [PoseCandidate],
        person: PersonDetection,
        excluding selectedPoses: [SelectedPose]
    ) -> PoseCandidate? {
        candidates.first { candidate in
            candidate.evaluation.score >= 0.35 && !selectedPoses.contains { selected in
                PoseDetectionMath.areDuplicatePoses(
                    candidate.joints,
                    lhsBounds: person.bounds,
                    selected.joints,
                    rhsBounds: selected.personBounds
                )
            }
        }
    }

    private func hint(from candidate: PoseCandidate, person: PersonDetection) -> PoseHint {
        let lower = Self.lowerBodyBounds(joints: candidate.joints)
            ?? HeuristicPoseEstimator.lowerBody(for: person.bounds)
        return PoseHint(bodyBounds: person.bounds, lowerBodyBounds: lower, joints: candidate.joints)
    }

    private static func preparedForDetection(_ image: CGImage) -> CGImage {
        let longestSide = max(image.width, image.height)
        guard longestSide < 480 else { return image }
        let scale = min(4, max(2, Int(ceil(480.0 / Double(longestSide)))))
        return upscaled(image, scale: scale) ?? image
    }

    private func rotated(_ image: CGImage, rotation: PoseCropRotation) -> CGImage? {
        guard rotation != .none else { return image }
        let orientation: CGImagePropertyOrientation = rotation == .clockwise ? .right : .left
        let rotated = CIImage(cgImage: image).oriented(orientation)
        return imageContext.createCGImage(rotated, from: rotated.extent)
    }

    /// 骨格検出前の低解像度クロップ拡大（正規化座標のマッピングには影響しない）。
    private static func upscaled(_ image: CGImage, scale: Int) -> CGImage? {
        let width = image.width * scale
        let height = image.height * scale
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func joints(from observation: VNHumanBodyPoseObservation) -> [PoseJoint] {
        var joints: [PoseJoint] = []
        for (visionName, name) in jointMapping {
            guard let point = try? observation.recognizedPoint(visionName), point.confidence > 0.1 else { continue }
            joints.append(PoseJoint(
                name: name,
                x: point.location.x,
                y: 1 - point.location.y,
                confidence: Double(point.confidence)
            ))
        }
        return joints
    }

    private static func lowerBodyBounds(joints: [PoseJoint]) -> NormalizedRect? {
        let hips = joints.filter { $0.name == .leftHip || $0.name == .rightHip }
        guard !hips.isEmpty else { return nil }
        let hipY = hips.map(\.y).reduce(0, +) / Double(hips.count)
        let hipXs = hips.map(\.x)
        let centerX = hipXs.reduce(0, +) / Double(hipXs.count)
        let hipWidth = hips.count == 2 ? abs(hipXs[0] - hipXs[1]) : 0.15
        let knees = joints.filter { $0.name == .leftKnee || $0.name == .rightKnee }
        let bottomY = knees.isEmpty
            ? hipY + max(0.05, hipWidth * 1.5)
            : knees.map(\.y).reduce(0, +) / Double(knees.count)
        let width = max(0.05, hipWidth * 2)
        return NormalizedRect(
            x: centerX - width / 2,
            y: hipY,
            width: width,
            height: max(0.03, bottomY - hipY)
        ).clamped()
    }
}

/// 骨格が使えない場合の固定比率フォールバック。
public final class HeuristicPoseEstimator: PoseEstimating {
    public init() {}

    public func estimatePose(in image: CGImage, persons: [PersonDetection]) throws -> [PoseHint] {
        persons.map { Self.fallbackHint(for: $0.bounds) }
    }

    static func lowerBody(for bounds: NormalizedRect) -> NormalizedRect {
        NormalizedRect(
            x: bounds.x + bounds.width * 0.18,
            y: bounds.y + bounds.height * 0.48,
            width: bounds.width * 0.64,
            height: bounds.height * 0.36
        )
    }

    static func fallbackHint(for bounds: NormalizedRect) -> PoseHint {
        PoseHint(bodyBounds: bounds, lowerBodyBounds: lowerBody(for: bounds))
    }
}

/// 骨格関節からの解剖学的プライアで、カテゴリ付きROI（胸部=乳首、鼠径部）を人物ごとに生成する。
/// 性別分類器が未導入のため、鼠径部ROIのカテゴリは `.other` に留める（Phase 2で分類予定）。
public final class SensitiveROIGenerator: ROIGenerating {
    /// 鼠径部ROIの中心位置。腰関節(0.0)から膝関節(1.0)へ向かう線分上の比率。
    /// 実画像でのフィードバック（従来0.3では性器位置より上）を受け、既定を0.45とした。
    /// UIのスライダーから事前補正できる（次回の候補生成から適用）。
    public var groinPositionRatio: Double

    /// 乳首ROIの縦位置。肩(0.0)から腰(1.0)へ向かう胴体上の比率。
    /// 実画像フィードバック「上過ぎる」を受け 0.32→0.42 へ下方修正。
    public var chestPositionRatio: Double

    public init(groinPositionRatio: Double = 0.45, chestPositionRatio: Double = 0.42) {
        self.groinPositionRatio = groinPositionRatio
        self.chestPositionRatio = chestPositionRatio
    }

    public func generateROIs(from poseHints: [PoseHint], imageSize: CGSize) -> [MosaicROI] {
        poseHints.flatMap { hint in
            var rois = chestROIs(for: hint)
            if let groin = groinROI(for: hint) {
                rois.append(groin)
            }
            return rois
        }
    }

    private func chestROIs(for hint: PoseHint) -> [MosaicROI] {
        guard let left = hint.joint(.leftShoulder), let right = hint.joint(.rightShoulder) else { return [] }
        let shoulderWidth = abs(left.x - right.x)
        guard shoulderWidth > 0.01 else { return [] }
        let centerX = (left.x + right.x) / 2
        let shoulderY = (left.y + right.y) / 2
        let hipY = hipCenter(for: hint)?.y ?? (shoulderY + shoulderWidth * 1.4)
        let torsoHeight = max(0.02, hipY - shoulderY)
        // 実画像フィードバック（上過ぎ・大き過ぎ・幅広過ぎで手や他部位を覆う）を受け、
        // 位置0.32→chestPositionRatio(0.42)、サイズ0.24→0.14、横オフセット0.27→0.22へ調整。
        let nippleY = shoulderY + torsoHeight * min(max(chestPositionRatio, 0.1), 0.9)
        let size = max(0.015, shoulderWidth * 0.14)
        let confidence = Double(min(left.confidence, right.confidence))
        return [-1.0, 1.0].map { side in
            let centerXOffset = centerX + side * shoulderWidth * 0.22
            return MosaicROI(
                rect: NormalizedRect(x: centerXOffset - size / 2, y: nippleY - size / 2, width: size, height: size),
                confidence: confidence,
                source: "pose-chest",
                shape: .ellipse,
                category: .nipple
            )
        }
    }

    /// 鼠径部ROI。左右の腰関節が両方検出できた場合のみ生成する。
    /// root関節のみ・関節なしの推定（旧 heuristic-lower-body フォールバック）は位置精度が低く、
    /// 肩付近へ巨大な誤ROIが出る事例があったため廃止した（「検出していないものは表示しない」方針）。
    private func groinROI(for hint: PoseHint) -> MosaicROI? {
        guard let leftHip = hint.joint(.leftHip), let rightHip = hint.joint(.rightHip) else { return nil }
        let hip = CGPoint(x: (leftHip.x + rightHip.x) / 2, y: (leftHip.y + rightHip.y) / 2)
        let hipWidth = max(0.02, abs(leftHip.x - rightHip.x))
        let ratio = min(max(groinPositionRatio, 0.05), 0.95)
        let drop = kneeCenterY(for: hint).map { max(0.01, ($0 - hip.y) * ratio) } ?? hipWidth * ratio * 1.6
        let width = hipWidth * 0.9
        let height = hipWidth * 0.7
        return MosaicROI(
            rect: NormalizedRect(x: hip.x - width / 2, y: hip.y + drop - height / 2, width: width, height: height),
            confidence: Double(min(leftHip.confidence, rightHip.confidence)),
            source: "pose-groin",
            shape: .ellipse,
            category: .other
        )
    }

    private func hipCenter(for hint: PoseHint) -> CGPoint? {
        if let left = hint.joint(.leftHip), let right = hint.joint(.rightHip) {
            return CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        }
        if let root = hint.joint(.root) {
            return CGPoint(x: root.x, y: root.y)
        }
        return nil
    }

    private func kneeCenterY(for hint: PoseHint) -> Double? {
        let knees = [hint.joint(.leftKnee), hint.joint(.rightKnee)].compactMap { $0?.y }
        guard !knees.isEmpty else { return nil }
        return knees.reduce(0, +) / Double(knees.count)
    }
}

public final class PassThroughCandidateDetector: CandidateDetecting {
    public init() {}

    public func refineCandidates(_ rois: [MosaicROI], image: CGImage) throws -> [MosaicROI] {
        rois
    }
}

public struct DetectionSnapshot {
    public var persons: [PersonDetection]
    public var poseHints: [PoseHint]
    public var rois: [MosaicROI]

    public var personBounds: [NormalizedRect] { persons.map(\.bounds) }

    public init(persons: [PersonDetection], poseHints: [PoseHint], rois: [MosaicROI]) {
        self.persons = persons
        self.poseHints = poseHints
        self.rois = rois
    }
}

public final class StaticImageMosaicPipeline {
    private let personDetector: PersonDetecting
    private let poseEstimator: PoseEstimating
    private let roiGenerator: ROIGenerating
    private let candidateDetector: CandidateDetecting

    public init(
        personDetector: PersonDetecting = VisionPersonDetector(),
        poseEstimator: PoseEstimating = VisionPoseEstimator(),
        roiGenerator: ROIGenerating = SensitiveROIGenerator(),
        candidateDetector: CandidateDetecting = SaliencyCandidateDetector()
    ) {
        self.personDetector = personDetector
        self.poseEstimator = poseEstimator
        self.roiGenerator = roiGenerator
        self.candidateDetector = candidateDetector
    }

    public func generateCandidates(for image: CGImage) throws -> [MosaicROI] {
        try generateDetailedCandidates(for: image).rois
    }

    public func generateDetailedCandidates(for image: CGImage) throws -> DetectionSnapshot {
        let persons = try personDetector.detectPersons(in: image)
        let hints = try poseEstimator.estimatePose(in: image, persons: persons)
        let rois = roiGenerator.generateROIs(
            from: hints,
            imageSize: CGSize(width: image.width, height: image.height)
        )
        let refined = try candidateDetector.refineCandidates(rois, image: image)
        return DetectionSnapshot(persons: persons, poseHints: hints, rois: refined)
    }
}
