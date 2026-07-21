import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

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
    private let context = CIContext(options: [.cacheIntermediates: false])

    public init() {}

    public func detectPersons(in image: CGImage) throws -> [PersonDetection] {
        if let persons = try? detectWithInstanceMasks(in: image), !persons.isEmpty {
            return persons
        }
        // 漫画・イラスト等では実写学習のVisionが人物を検出できないことがあるが、
        // 検出していないのに固定比率の偽矩形を返すことはしない（正確な検知内容の表示を優先。
        // ユーザー方針 2026-07-22）。0件時はUI側で手動ROI追加を案内する。
        return try detectWithHumanRectangles(in: image)
    }

    private func detectWithInstanceMasks(in image: CGImage) throws -> [PersonDetection] {
        let request = VNGeneratePersonInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { return [] }

        var persons: [PersonDetection] = []
        for instance in observation.allInstances.sorted() {
            guard let bounds = Self.instanceBounds(in: observation.instanceMask, instance: instance) else { continue }
            let maskBuffer = try? observation.generateScaledMaskForImage(
                forInstances: IndexSet(integer: instance),
                from: handler
            )
            let maskImage = maskBuffer.flatMap { cgImage(from: $0) }
            persons.append(PersonDetection(bounds: bounds, maskImage: maskImage))
        }
        return persons
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

    private func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        // CVPixelBuffer→CIImage→CGImage の経路は最終表示で上下反転する（GUI確認で判明）ため垂直反転で補正する。
        let ciImage = CIImage(cvPixelBuffer: buffer).verticallyFlippedForRaster()
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}

/// Vision複数人物骨格検出。人物ごとに最も近い骨格を対応付け、関節を `PoseJoint` として保持する。
/// 骨格が得られない人物には従来の固定比率フォールバックを適用する。
public final class VisionPoseEstimator: PoseEstimating {
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
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        var observations = request.results ?? []

        return persons.map { person in
            if let index = Self.bestObservationIndex(for: person.bounds, in: observations) {
                let observation = observations.remove(at: index)
                if let hint = Self.hint(from: observation, bodyBounds: person.bounds) {
                    return hint
                }
            }
            return HeuristicPoseEstimator.fallbackHint(for: person.bounds)
        }
    }

    private static func bestObservationIndex(
        for bounds: NormalizedRect,
        in observations: [VNHumanBodyPoseObservation]
    ) -> Int? {
        let centerX = bounds.x + bounds.width / 2
        let centerY = bounds.y + bounds.height / 2
        var best: (index: Int, score: Double)?
        for (index, observation) in observations.enumerated() {
            guard let torso = torsoCenter(of: observation) else { continue }
            let inside = torso.x >= bounds.x && torso.x <= bounds.x + bounds.width
                && torso.y >= bounds.y && torso.y <= bounds.y + bounds.height
            let score = hypot(torso.x - centerX, torso.y - centerY) + (inside ? 0 : 1)
            if best == nil || score < best!.score {
                best = (index, score)
            }
        }
        return best?.index
    }

    private static func torsoCenter(of observation: VNHumanBodyPoseObservation) -> CGPoint? {
        let names: [VNHumanBodyPoseObservation.JointName] = [.root, .neck, .leftHip, .rightHip, .leftShoulder, .rightShoulder]
        var xs: [Double] = []
        var ys: [Double] = []
        for name in names {
            guard let point = try? observation.recognizedPoint(name), point.confidence > 0.1 else { continue }
            xs.append(point.location.x)
            ys.append(1 - point.location.y)
        }
        guard !xs.isEmpty else { return nil }
        return CGPoint(x: xs.reduce(0, +) / Double(xs.count), y: ys.reduce(0, +) / Double(ys.count))
    }

    private static func hint(from observation: VNHumanBodyPoseObservation, bodyBounds: NormalizedRect) -> PoseHint? {
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
        guard joints.count >= 4 else { return nil }
        let lower = lowerBodyBounds(joints: joints) ?? HeuristicPoseEstimator.lowerBody(for: bodyBounds)
        return PoseHint(bodyBounds: bodyBounds, lowerBodyBounds: lower, joints: joints)
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
