import CoreGraphics
import Foundation
import OnnxRuntimeBindings

/// YOLOv8系ONNX出力のデコード（純ロジック。単体テスト可能）。
public enum YOLODecoder {
    public struct Detection: Equatable, Sendable {
        public let rect: NormalizedRect
        public let score: Double
        public let classIndex: Int

        public init(rect: NormalizedRect, score: Double, classIndex: Int) {
            self.rect = rect
            self.score = score
            self.classIndex = classIndex
        }
    }

    /// YOLOv8 ONNXの出力 `(1, 4+classCount, anchors)`（属性メジャー配列）をデコードする。
    /// 座標は入力サイズで割った正規化（左上原点）で返す。
    public static func decode(
        output: [Float],
        classCount: Int,
        confidenceThreshold: Double = 0.3,
        iouThreshold: Double = 0.7,
        inputSize: Int = 640
    ) -> [Detection] {
        let attributes = 4 + classCount
        guard classCount > 0, output.count >= attributes, output.count % attributes == 0 else { return [] }
        let anchors = output.count / attributes

        var raw: [Detection] = []
        for anchor in 0..<anchors {
            var bestScore: Float = 0
            var bestClass = 0
            for classIndex in 0..<classCount {
                let score = output[(4 + classIndex) * anchors + anchor]
                if score > bestScore {
                    bestScore = score
                    bestClass = classIndex
                }
            }
            guard Double(bestScore) >= confidenceThreshold else { continue }
            let size = Double(inputSize)
            let centerX = Double(output[0 * anchors + anchor]) / size
            let centerY = Double(output[1 * anchors + anchor]) / size
            let width = Double(output[2 * anchors + anchor]) / size
            let height = Double(output[3 * anchors + anchor]) / size
            guard width > 0, height > 0 else { continue }
            raw.append(Detection(
                rect: NormalizedRect(
                    x: centerX - width / 2,
                    y: centerY - height / 2,
                    width: width,
                    height: height
                ).clamped(),
                score: Double(bestScore),
                classIndex: bestClass
            ))
        }
        return nonMaxSuppression(raw, iouThreshold: iouThreshold)
    }

    static func nonMaxSuppression(_ detections: [Detection], iouThreshold: Double) -> [Detection] {
        var remaining = detections.sorted { $0.score > $1.score }
        var kept: [Detection] = []
        while !remaining.isEmpty {
            let best = remaining.removeFirst()
            kept.append(best)
            remaining.removeAll { other in
                other.classIndex == best.classIndex && best.rect.iou(with: other.rect) > iouThreshold
            }
        }
        return kept
    }
}

/// アニメ・イラスト向けのNSFW部位検出器（内容ベース検出）。
/// モデル: deepghs/anime_censor_detection censor_detect_v1.0_s（MITライセンス, YOLOv8系ONNX,
/// クラス: nipple_f / penis / pussy）。ONNX Runtimeで完全ローカル実行し、画像の外部送信は行わない。
/// DETECTION_IMPROVEMENT_PLAN.md §6.1 A / §6.2 の実装。
public final class AnimeCensorDetector {
    public static let inputSize = 640
    /// labels.json の順序（nipple_f, penis, pussy）に対応するアプリ内カテゴリ。
    static let classCategories: [MosaicTargetCategory] = [.nipple, .maleGenital, .femaleGenital]

    private let env: ORTEnv
    private let session: ORTSession
    private let inputName: String
    private let outputName: String

    public init() throws {
        guard let modelURL = Bundle.module.url(forResource: "censor_detect", withExtension: "onnx") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "アニメ部位検出モデル（censor_detect.onnx）が見つかりません"
            ])
        }
        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        inputName = try session.inputNames().first ?? "images"
        outputName = try session.outputNames().first ?? "output0"
    }

    /// 画像からNSFW部位を検出し、カテゴリ付きROIとして返す。
    public func detect(in image: CGImage, confidenceThreshold: Double = 0.3) throws -> [MosaicROI] {
        var tensor = Self.preprocess(image)
        let data = NSMutableData(
            bytes: &tensor,
            length: tensor.count * MemoryLayout<Float>.size
        )
        let inputValue = try ORTValue(
            tensorData: data,
            elementType: .float,
            shape: [1, 3, NSNumber(value: Self.inputSize), NSNumber(value: Self.inputSize)]
        )
        let outputs = try session.run(
            withInputs: [inputName: inputValue],
            outputNames: [outputName],
            runOptions: nil
        )
        guard let output = outputs[outputName] else { return [] }
        let outputData = try output.tensorData() as Data
        let floats = outputData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        return YOLODecoder.decode(
            output: floats,
            classCount: Self.classCategories.count,
            confidenceThreshold: confidenceThreshold,
            inputSize: Self.inputSize
        ).map { detection in
            MosaicROI(
                rect: detection.rect,
                confidence: detection.score,
                source: "anime-censor",
                shape: .ellipse,
                category: Self.classCategories[detection.classIndex]
            )
        }
    }

    /// 640x640 RGB（0-1正規化）のCHW配列へ変換する（アスペクト比は無視して単純リサイズ）。
    static func preprocess(_ image: CGImage) -> [Float] {
        let size = inputSize
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        rgba.withUnsafeMutableBytes { pointer in
            guard let context = CGContext(
                data: pointer.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        }

        let plane = size * size
        var tensor = [Float](repeating: 0, count: 3 * plane)
        for index in 0..<plane {
            let offset = index * 4
            tensor[index] = Float(rgba[offset]) / 255.0
            tensor[plane + index] = Float(rgba[offset + 1]) / 255.0
            tensor[2 * plane + index] = Float(rgba[offset + 2]) / 255.0
        }
        return tensor
    }
}
