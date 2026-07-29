import CoreGraphics
import Foundation
import OnnxRuntimeBindings

/// YOLOv8/YOLO11 セグメンテーション（`-seg`）ONNX出力のデコード（純ロジック。単体テスト可能）。
///
/// 検出専用モデル（`YOLODecoder`）との違いは出力が2本あること:
/// - `output0`: `(1, 4 + クラス数 + マスク係数, アンカー数)` — 枠・クラススコアに加えマスク係数を持つ
/// - `output1`: `(1, マスク係数, protoH, protoW)` — マスクのプロトタイプ（基底画像）
///
/// 各検出のマスクは `sigmoid(Σ 係数ᵢ × プロトタイプᵢ)` で合成し、検出枠の内側だけを残す。
public enum YOLOSegDecoder {
    /// YOLOv8/YOLO11-seg の既定のマスク係数（プロトタイプ）数。
    public static let defaultMaskCount = 32

    public struct Detection: Equatable, Sendable {
        /// モデル入力空間（レターボックス済み）の正規化rect・左上原点
        public let rect: NormalizedRect
        public let score: Double
        public let classIndex: Int
        public let maskCoefficients: [Float]

        public init(rect: NormalizedRect, score: Double, classIndex: Int, maskCoefficients: [Float]) {
            self.rect = rect
            self.score = score
            self.classIndex = classIndex
            self.maskCoefficients = maskCoefficients
        }
    }

    /// `output0` をデコードして検出とマスク係数を取り出す。
    public static func decode(
        output: [Float],
        classCount: Int,
        maskCount: Int = defaultMaskCount,
        confidenceThreshold: Double = 0.3,
        iouThreshold: Double = 0.7,
        inputSize: Int = 640
    ) -> [Detection] {
        let attributes = 4 + classCount + maskCount
        guard classCount > 0, maskCount > 0, inputSize > 0,
              output.count >= attributes, output.count % attributes == 0 else { return [] }
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
            let coefficientBase = 4 + classCount
            var coefficients = [Float](repeating: 0, count: maskCount)
            for index in 0..<maskCount {
                coefficients[index] = output[(coefficientBase + index) * anchors + anchor]
            }
            raw.append(Detection(
                rect: NormalizedRect(
                    x: centerX - width / 2,
                    y: centerY - height / 2,
                    width: width,
                    height: height
                ).clamped(),
                score: Double(bestScore),
                classIndex: bestClass,
                maskCoefficients: coefficients
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

    /// マスク係数とプロトタイプから、プロトタイプ解像度の二値マスク（0/255）を合成する。
    ///
    /// 検出枠の外は0にする（ultralyticsの`crop_mask`と同じ扱い。プロトタイプの合成結果は
    /// 画像全体に及ぶため、枠外を残すと他の部位のマスクが混ざる）。
    /// - Parameters:
    ///   - prototypes: `output1` を平坦化した配列（`maskCount × height × width`）
    ///   - rect: モデル入力空間の正規化rect（`Detection.rect`）
    public static func maskPixels(
        coefficients: [Float],
        prototypes: [Float],
        maskCount: Int,
        width: Int,
        height: Int,
        rect: NormalizedRect,
        threshold: Double = 0.5
    ) -> [UInt8]? {
        let plane = width * height
        guard width > 0, height > 0, maskCount > 0,
              coefficients.count >= maskCount,
              prototypes.count >= maskCount * plane else { return nil }

        // 枠をプロトタイプ座標へ変換する（正規化rectはモデル入力空間・左上原点）
        let clamped = rect.clamped()
        let minX = Int((clamped.x * Double(width)).rounded(.down))
        let maxX = Int(((clamped.x + clamped.width) * Double(width)).rounded(.up))
        let minY = Int((clamped.y * Double(height)).rounded(.down))
        let maxY = Int(((clamped.y + clamped.height) * Double(height)).rounded(.up))

        var pixels = [UInt8](repeating: 0, count: plane)
        for y in max(0, minY)..<min(height, maxY) {
            for x in max(0, minX)..<min(width, maxX) {
                var sum: Float = 0
                for index in 0..<maskCount {
                    sum += coefficients[index] * prototypes[index * plane + y * width + x]
                }
                // sigmoid
                let value = 1 / (1 + exp(-Double(sum)))
                pixels[y * width + x] = value >= threshold ? 255 : 0
            }
        }
        return pixels
    }
}

/// 学習済み部位セグメンテーションモデルによる検出結果（マスク付き）。
public struct PartSegmentationResult: Sendable {
    /// 元画像の正規化rect（左上原点）
    public let rect: NormalizedRect
    public let category: MosaicTargetCategory
    public let score: Double
    /// 元画像と同じ画素数の8bitグレースケールマスク（白=対象）
    public let mask: CGImage

    public init(rect: NormalizedRect, category: MosaicTargetCategory, score: Double, mask: CGImage) {
        self.rect = rect
        self.category = category
        self.score = score
        self.mask = mask
    }
}

/// 部位の**形状**を出力する学習済みモデル（YOLOv8/YOLO11-seg のONNX）を実行する。
///
/// 同梱の検出モデル（`censor_detect.onnx` 等）は枠しか出力しないため、形状は画像処理で
/// 近似するしかなかった。本クラスはユーザーが導入した形状モデルを使い、部位の輪郭を
/// 直接得るための経路である。
///
/// モデルは**同梱しない**（学習データの都合およびライセンスのため）。
/// `~/Library/Application Support/newMosaic/Models/part_seg.onnx` に置かれていれば有効になる。
/// 未導入の場合は `available` が false になり、呼び出し側は従来方式へフォールバックする。
/// 推論は完全ローカルで行い、画像・検出結果の外部送信は一切しない。
public final class PartSegmentationDetector {
    /// 学習時のクラス順。同梱検出モデル（deepghs/anime_censor_detection）と同じ並びに揃えることで、
    /// 既存の学習データ書き出し（`DatasetExporter`）をそのまま流用できるようにしている。
    public static let classCategories: [MosaicTargetCategory] = [.nipple, .maleGenital, .femaleGenital]
    public static let modelFileName = "part_seg.onnx"

    private let env: ORTEnv
    private let session: ORTSession
    private let inputName: String
    private let boxOutputName: String
    private let maskOutputName: String
    private let inputSize: Int

    /// 導入済みモデルのURL（未導入ならnil）。
    public static func installedModelURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        let url = support
            .appendingPathComponent("newMosaic/Models")
            .appendingPathComponent(modelFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// モデルが導入されているか。UIの選択肢の有効/無効判定に使う。
    public static var isAvailable: Bool { installedModelURL() != nil }

    /// - Throws: モデル未導入、または読み込めない場合。
    public init(inputSize: Int = 640) throws {
        guard let modelURL = Self.installedModelURL() else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey:
                    "形状モデル（\(Self.modelFileName)）が未導入です。Docs/FINETUNE_GUIDE.md の手順で作成し、"
                    + "Application Support/newMosaic/Models へ配置してください"
            ])
        }
        self.inputSize = inputSize
        env = try ORTEnv(loggingLevel: .warning)
        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: try ORTSessionOptions())
        inputName = try session.inputNames().first ?? "images"
        let outputs = try session.outputNames()
        guard outputs.count >= 2 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey:
                    "形状モデルの出力が\(outputs.count)本です。セグメンテーション（-seg）モデルは"
                    + "出力が2本必要です。検出専用モデルを配置していないか確認してください"
            ])
        }
        // ultralyticsのONNX書き出しは output0=枠+係数, output1=プロトタイプ の順
        boxOutputName = outputs[0]
        maskOutputName = outputs[1]
    }

    /// 画像から部位の形状マスクを検出する。
    public func detect(in image: CGImage, confidenceThreshold: Double = 0.3) throws -> [PartSegmentationResult] {
        var (tensor, letterbox) = YOLOONNXModel.preprocess(image, inputSize: inputSize)
        let data = NSMutableData(bytes: &tensor, length: tensor.count * MemoryLayout<Float>.size)
        let inputValue = try ORTValue(
            tensorData: data,
            elementType: .float,
            shape: [1, 3, NSNumber(value: inputSize), NSNumber(value: inputSize)]
        )
        let outputs = try session.run(
            withInputs: [inputName: inputValue],
            outputNames: [boxOutputName, maskOutputName],
            runOptions: nil
        )
        guard let boxOutput = outputs[boxOutputName], let maskOutput = outputs[maskOutputName] else { return [] }

        let boxFloats = (try boxOutput.tensorData() as Data)
            .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let protoFloats = (try maskOutput.tensorData() as Data)
            .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        // プロトタイプの解像度はモデル入力の1/4（ultralytics標準）
        let maskCount = YOLOSegDecoder.defaultMaskCount
        let protoSide = inputSize / 4
        guard protoSide > 0, protoFloats.count >= maskCount * protoSide * protoSide else { return [] }

        let detections = YOLOSegDecoder.decode(
            output: boxFloats,
            classCount: Self.classCategories.count,
            maskCount: maskCount,
            confidenceThreshold: confidenceThreshold,
            inputSize: inputSize
        )

        return detections.compactMap { detection in
            guard detection.classIndex < Self.classCategories.count,
                  let pixels = YOLOSegDecoder.maskPixels(
                      coefficients: detection.maskCoefficients,
                      prototypes: protoFloats,
                      maskCount: maskCount,
                      width: protoSide,
                      height: protoSide,
                      rect: detection.rect
                  ),
                  let mask = Self.imageSpaceMask(
                      protoPixels: pixels,
                      protoSide: protoSide,
                      letterbox: letterbox,
                      inputSize: inputSize,
                      imageWidth: image.width,
                      imageHeight: image.height
                  ) else { return nil }
            return PartSegmentationResult(
                rect: letterbox.imageRect(from: detection.rect, inputSize: inputSize),
                category: Self.classCategories[detection.classIndex],
                score: detection.score,
                mask: mask
            )
        }
    }

    /// プロトタイプ空間のマスクから、レターボックスのパディングを取り除いて元画像サイズのマスクを作る。
    static func imageSpaceMask(
        protoPixels: [UInt8],
        protoSide: Int,
        letterbox: LetterboxTransform,
        inputSize: Int,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGImage? {
        guard protoSide > 0, inputSize > 0, imageWidth > 0, imageHeight > 0,
              protoPixels.count == protoSide * protoSide,
              letterbox.contentWidth > 0, letterbox.contentHeight > 0 else { return nil }

        guard let provider = CGDataProvider(data: Data(protoPixels) as CFData),
              let protoImage = CGImage(
                  width: protoSide,
                  height: protoSide,
                  bitsPerComponent: 8,
                  bitsPerPixel: 8,
                  bytesPerRow: protoSide,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }

        // レターボックスの中身（パディングを除いた領域）だけを切り出すと、元画像全体へ1:1で対応する
        let scale = Double(protoSide) / Double(inputSize)
        let contentRect = CGRect(
            x: letterbox.padX * scale,
            y: letterbox.padY * scale,
            width: letterbox.contentWidth * scale,
            height: letterbox.contentHeight * scale
        ).integral
        let cropped = protoImage.cropping(to: contentRect) ?? protoImage

        guard let context = CGContext(
            data: nil,
            width: imageWidth,
            height: imageHeight,
            bitsPerComponent: 8,
            bytesPerRow: imageWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        return context.makeImage()
    }
}
