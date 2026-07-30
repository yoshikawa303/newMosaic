import CoreGraphics
import Foundation
import OnnxRuntimeBindings
import OSLog

/// アニメ・イラスト向けの骨格（姿勢）検出器。
/// モデル: yzd-v/DWPose dw-ll_ucoco_384.onnx（Apache-2.0, RTMPose系SimCC, 入力288x384,
/// COCO-WholeBody 133キーポイント）。DWPoseはアニメ画像でも比較的頑健に動作することが
/// ControlNet系ワークフローで知られており、イラスト/漫画の骨格レイヤ未対応（残件）の解消に採用。
/// 人物ごとにクロップして推論するトップダウン方式。完全ローカル実行。
public final class AnimePoseEstimator {
    /// DetectionPipeline.swiftのVision検出診断と同一subsystemに統一（画像内容・座標は記録しない）。
    static let logger = Logger(subsystem: "com.yoshikawa.newMosaic", category: "AnimePose")
    static let inputWidth = 288
    static let inputHeight = 384
    static let keypointCount = 133
    /// SimCCのビン分割比（座標ビン数 = 入力画素数 x 2）
    static let simccSplitRatio = 2.0
    /// 採用する関節スコアのしきい値
    static let scoreThreshold = 0.3

    /// COCO体幹17点のうち本アプリの正準関節へ対応付ける添字（COCO-WholeBodyの先頭17点）。
    static let jointMapping: [(index: Int, name: PoseJointName)] = [
        (0, .nose),
        (5, .leftShoulder), (6, .rightShoulder),
        (7, .leftElbow), (8, .rightElbow),
        (9, .leftWrist), (10, .rightWrist),
        (11, .leftHip), (12, .rightHip),
        (13, .leftKnee), (14, .rightKnee),
        (15, .leftAnkle), (16, .rightAnkle)
    ]

    private let env: ORTEnv
    private let session: ORTSession
    private let inputName: String
    private let outputNames: [String]

    public init() throws {
        let modelURL = try YOLOONNXModel.cachedModelURL(resourceName: "anime_pose")
        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        inputName = try session.inputNames().first ?? "input"
        let names = try session.outputNames()
        outputNames = names.isEmpty ? ["simcc_x", "simcc_y"] : names
    }

    /// 人物ごとに骨格を推定してPoseHintを返す（骨格が取れない人物は関節なしのフォールバックヒント）。
    public func estimatePose(in image: CGImage, persons: [PersonDetection]) throws -> [PoseHint] {
        let imageSize = CGSize(width: image.width, height: image.height)
        return persons.map { person in
            poseHint(for: person, in: image, imageSize: imageSize)
                ?? HeuristicPoseEstimator.fallbackHint(for: person.bounds)
        }
    }

    private func poseHint(for person: PersonDetection, in image: CGImage, imageSize: CGSize) -> PoseHint? {
        // mmposeトップダウン標準の1.25倍拡張クロップ
        let region = person.bounds.expanded(scale: 1.25).clamped()
        let cropRect = region.cgRect(imageSize: imageSize, origin: .topLeft)
        guard cropRect.width >= 32, cropRect.height >= 32,
              region.width > 0, region.height > 0,
              let crop = image.cropping(to: cropRect) else { return nil }

        guard let decoded = try? runModel(on: crop) else { return nil }

        // クロップ内正規化座標 → 画像全体の正規化座標へ変換し、正準関節を構築
        var joints: [PoseJoint] = []
        var byName: [PoseJointName: PoseJoint] = [:]
        for mapping in Self.jointMapping {
            guard let keypoint = decoded.first(where: { $0.index == mapping.index }),
                  keypoint.score >= Self.scoreThreshold else { continue }
            let joint = PoseJoint(
                name: mapping.name,
                x: region.x + keypoint.x * region.width,
                y: region.y + keypoint.y * region.height,
                confidence: min(1.0, keypoint.score)
            )
            joints.append(joint)
            byName[mapping.name] = joint
        }
        // COCOに無い neck / root を肩・腰の中点から合成する（ボーン接続定義が両者を参照するため）
        if let left = byName[.leftShoulder], let right = byName[.rightShoulder] {
            joints.append(PoseJoint(
                name: .neck,
                x: (left.x + right.x) / 2,
                y: (left.y + right.y) / 2,
                confidence: min(left.confidence, right.confidence)
            ))
        }
        if let left = byName[.leftHip], let right = byName[.rightHip] {
            joints.append(PoseJoint(
                name: .root,
                x: (left.x + right.x) / 2,
                y: (left.y + right.y) / 2,
                confidence: min(left.confidence, right.confidence)
            ))
        }

        // シルエットマスクがあればマスク内へ限定（実写経路と同じ「検出していないものは表示しない」方針）
        if let maskImage = person.maskImage, let sampler = PersonMaskSampler(maskImage: maskImage) {
            let inside = joints.filter { sampler.containsNear(x: $0.x, y: $0.y) }
            guard !inside.isEmpty else { return nil }
            joints = inside
        } else {
            joints = joints.filter { region.contains(x: $0.x, y: $0.y) }
        }
        guard joints.count >= 4 else { return nil }

        let lower = Self.lowerBodyBounds(joints: joints) ?? HeuristicPoseEstimator.lowerBody(for: person.bounds)
        return PoseHint(bodyBounds: person.bounds, lowerBodyBounds: lower, joints: joints)
    }

    /// COCO-WholeBody顔キーポイント（添字23〜90が68点の顔ランドマーク）から
    /// 「目元」「眼窩下〜あご」のカテゴリ付きROIを人物ごとに生成する。
    /// 68点の内訳（顔68点内の添字）: 輪郭0〜16→全体23〜39、眉17〜26→40〜49、目36〜47→59〜70。
    public func faceRegionROIs(in image: CGImage, persons: [PersonDetection]) throws -> [MosaicROI] {
        let imageSize = CGSize(width: image.width, height: image.height)
        var rois: [MosaicROI] = []
        for person in persons {
            let region = person.bounds.expanded(scale: 1.25).clamped()
            let cropRect = region.cgRect(imageSize: imageSize, origin: .topLeft)
            guard cropRect.width >= 32, cropRect.height >= 32,
                  region.width > 0, region.height > 0,
                  let crop = image.cropping(to: cropRect),
                  let decoded = try? runModel(on: crop) else { continue }

            func fullPoints(_ range: ClosedRange<Int>) -> [(x: Double, y: Double)] {
                decoded
                    .filter { range.contains($0.index) && $0.score >= Self.scoreThreshold }
                    .map { (x: region.x + $0.x * region.width, y: region.y + $0.y * region.height) }
            }
            let eyePoints = fullPoints(59...70)
            let browPoints = fullPoints(40...49)
            let contourPoints = fullPoints(23...39)
            guard eyePoints.count >= 4 else { continue }

            if let rect = FaceRegionBuilder.eyesRect(eyePoints: eyePoints, browPoints: browPoints) {
                rois.append(MosaicROI(
                    rect: rect,
                    confidence: 0.8,
                    source: "face-region",
                    shape: .rectangle,
                    category: .eyes
                ))
            }
            if contourPoints.count >= 5,
               let rect = FaceRegionBuilder.lowerFaceRect(eyePoints: eyePoints, contourPoints: contourPoints) {
                rois.append(MosaicROI(
                    rect: rect,
                    confidence: 0.8,
                    source: "face-region",
                    shape: .rectangle,
                    category: .lowerFace
                ))
            }
        }
        return rois
    }

    /// クロップへDWPose推論を実行し、クロップ内正規化座標のキーポイントを返す。
    private func runModel(on crop: CGImage) throws -> [(index: Int, x: Double, y: Double, score: Double)] {
        var (tensor, letterbox) = Self.preprocess(crop)
        let data = NSMutableData(bytes: &tensor, length: tensor.count * MemoryLayout<Float>.size)
        let inputValue = try ORTValue(
            tensorData: data,
            elementType: .float,
            shape: [1, 3, NSNumber(value: Self.inputHeight), NSNumber(value: Self.inputWidth)]
        )
        let outputs = try session.run(
            withInputs: [inputName: inputValue],
            outputNames: Set(outputNames),
            runOptions: ORTMemory.shrinkingRunOptions
        )
        // モデル出力名が"simcc_x"/"simcc_y"と一致しない場合、出力順（first/last）へ暗黙依存した
        // フォールバックとなり、出力順が入れ替わっているとX/Yが交換され全キーポイントが誤検出に
        // なりうる（コードレビューで検出）。既知の名前と一致しない場合はログを残す。
        if outputs["simcc_x"] == nil || outputs["simcc_y"] == nil {
            AnimePoseEstimator.logger.error(
                "simcc_x/simcc_y という名前の出力が見つからず、出力順（first/last）に依存したフォールバックを使用しています。モデルの出力順が変更されているとX/Y座標が入れ替わる可能性があります。"
            )
        }
        guard let xValue = outputs["simcc_x"] ?? outputs[outputNames.first ?? ""],
              let yValue = outputs["simcc_y"] ?? outputs[outputNames.last ?? ""] else { return [] }
        let xData = try xValue.tensorData() as Data
        let yData = try yValue.tensorData() as Data
        let simccX = xData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let simccY = yData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        let decoded = Self.decodeSimCC(
            simccX: simccX,
            simccY: simccY,
            keypointCount: Self.keypointCount
        )
        // 入力画素座標 → レターボックス除去 → クロップ内正規化座標
        return decoded.compactMap { keypoint in
            let normX = (keypoint.x - letterbox.padX) / max(1, letterbox.contentWidth)
            let normY = (keypoint.y - letterbox.padY) / max(1, letterbox.contentHeight)
            guard normX >= -0.05, normX <= 1.05, normY >= -0.05, normY <= 1.05 else { return nil }
            return (keypoint.index, min(max(normX, 0), 1), min(max(normY, 0), 1), keypoint.score)
        }
    }

    /// SimCC出力（x/y各ビンの分類スコア）をargmaxで座標へ復号する。座標は入力画素単位。
    static func decodeSimCC(
        simccX: [Float],
        simccY: [Float],
        keypointCount: Int
    ) -> [(index: Int, x: Double, y: Double, score: Double)] {
        guard keypointCount > 0,
              simccX.count % keypointCount == 0,
              simccY.count % keypointCount == 0 else { return [] }
        let xBins = simccX.count / keypointCount
        let yBins = simccY.count / keypointCount
        guard xBins > 0, yBins > 0 else { return [] }

        var results: [(index: Int, x: Double, y: Double, score: Double)] = []
        for keypoint in 0..<keypointCount {
            var bestX = 0
            var maxX: Float = -.infinity
            let xOffset = keypoint * xBins
            for bin in 0..<xBins where simccX[xOffset + bin] > maxX {
                maxX = simccX[xOffset + bin]
                bestX = bin
            }
            var bestY = 0
            var maxY: Float = -.infinity
            let yOffset = keypoint * yBins
            for bin in 0..<yBins where simccY[yOffset + bin] > maxY {
                maxY = simccY[yOffset + bin]
                bestY = bin
            }
            results.append((
                index: keypoint,
                x: Double(bestX) / simccSplitRatio,
                y: Double(bestY) / simccSplitRatio,
                score: Double(maxX + maxY) / 2
            ))
        }
        return results
    }

    /// mmpose標準の前処理: レターボックス（アスペクト維持+グレー114パディング）で288x384へ変換し、
    /// ImageNet平均/分散（0-255スケール）で正規化したCHW配列を返す。
    static func preprocess(_ image: CGImage) -> (tensor: [Float], letterbox: LetterboxTransform) {
        let width = inputWidth
        let height = inputHeight
        let imageWidth = Double(image.width)
        let imageHeight = Double(image.height)
        let scale = min(Double(width) / max(1, imageWidth), Double(height) / max(1, imageHeight))
        let contentWidth = imageWidth * scale
        let contentHeight = imageHeight * scale
        let padX = (Double(width) - contentWidth) / 2
        let padY = (Double(height) - contentHeight) / 2

        var rgba = [UInt8](repeating: 114, count: width * height * 4)
        rgba.withUnsafeMutableBytes { pointer in
            guard let context = CGContext(
                data: pointer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: padX, y: padY, width: contentWidth, height: contentHeight))
        }

        let mean: [Float] = [123.675, 116.28, 103.53]
        let std: [Float] = [58.395, 57.12, 57.375]
        let plane = width * height
        var tensor = [Float](repeating: 0, count: 3 * plane)
        for index in 0..<plane {
            let offset = index * 4
            tensor[index] = (Float(rgba[offset]) - mean[0]) / std[0]
            tensor[plane + index] = (Float(rgba[offset + 1]) - mean[1]) / std[1]
            tensor[2 * plane + index] = (Float(rgba[offset + 2]) - mean[2]) / std[2]
        }
        return (
            tensor,
            LetterboxTransform(padX: padX, padY: padY, contentWidth: contentWidth, contentHeight: contentHeight)
        )
    }

    private static func lowerBodyBounds(joints: [PoseJoint]) -> NormalizedRect? {
        let hips = joints.filter { $0.name == .leftHip || $0.name == .rightHip }
        guard !hips.isEmpty else { return nil }
        let hipY = hips.map(\.y).reduce(0, +) / Double(hips.count)
        let hipXs = hips.map(\.x)
        let centerX = hipXs.reduce(0, +) / Double(hipXs.count)
        let hipWidth = hips.count == 2 ? abs(hipXs[0] - hipXs[1]) : 0.15
        let knees = joints.filter { $0.name == .leftKnee || $0.name == .rightKnee }
        let bottomY = knees.isEmpty ? min(1, hipY + 0.25) : knees.map(\.y).reduce(0, +) / Double(knees.count)
        let width = max(hipWidth * 2.2, 0.12)
        return NormalizedRect(
            x: centerX - width / 2,
            y: hipY - 0.02,
            width: width,
            height: max(0.05, bottomY - hipY + 0.05)
        ).clamped()
    }
}
