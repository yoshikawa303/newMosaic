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

/// レターボックス前処理（アスペクト比維持+パディング）の変換情報。
/// モデル入力空間（640x640）の正規化座標を元画像の正規化座標へ逆変換する。
public struct LetterboxTransform: Equatable, Sendable {
    public let padX: Double
    public let padY: Double
    public let contentWidth: Double
    public let contentHeight: Double

    public init(padX: Double, padY: Double, contentWidth: Double, contentHeight: Double) {
        self.padX = padX
        self.padY = padY
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
    }

    /// モデル入力空間の正規化rect → 元画像の正規化rect
    public func imageRect(from rect: NormalizedRect, inputSize: Int) -> NormalizedRect {
        guard contentWidth > 0, contentHeight > 0 else { return rect }
        let size = Double(inputSize)
        return NormalizedRect(
            x: (rect.x * size - padX) / contentWidth,
            y: (rect.y * size - padY) / contentHeight,
            width: rect.width * size / contentWidth,
            height: rect.height * size / contentHeight
        ).clamped()
    }
}

/// 同梱YOLOv8系ONNXモデルの共通実行ヘルパー（前処理→ONNX Runtime推論→デコード）。
/// 完全ローカル実行。画像・検出結果の外部送信は行わない。
final class YOLOONNXModel {
    /// モデルの入力解像度（censor_detect/person_detect=640, photo_censor_detect=320）
    let inputSize: Int

    private let env: ORTEnv
    private let session: ORTSession
    private let inputName: String
    private let outputName: String

    init(resourceName: String, inputSize: Int = 640) throws {
        self.inputSize = inputSize
        let modelURL = try Self.cachedModelURL(resourceName: resourceName)
        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        inputName = try session.inputNames().first ?? "images"
        outputName = try session.outputNames().first ?? "output0"
    }

    /// 同梱モデルを内蔵ディスク（Application Support/newMosaic/Models）へ初回のみコピーし、そのURLを返す。
    /// アプリ本体がリムーバブルボリューム上にある場合、バンドル内モデルの直接読み込みが
    /// macOSのリムーバブルボリューム許可ダイアログを誘発する（adhoc署名はビルドごとに別アプリ扱いになり
    /// 毎ビルド再表示される）ため、コピー済みマーカーがあればバンドルへ一切触れない。
    static func cachedModelURL(resourceName: String) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let modelsDirectory = support.appendingPathComponent("newMosaic/Models")
        let cached = modelsDirectory.appendingPathComponent("\(resourceName).onnx")
        let markerKey = "ModelCache.\(resourceName).v1"

        if UserDefaults.standard.bool(forKey: markerKey), FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        guard let bundled = Bundle.module.url(forResource: resourceName, withExtension: "onnx") else {
            if FileManager.default.fileExists(atPath: cached.path) {
                return cached
            }
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "検出モデル（\(resourceName).onnx）が見つかりません"
            ])
        }
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: cached.path) {
            try FileManager.default.removeItem(at: cached)
        }
        try FileManager.default.copyItem(at: bundled, to: cached)
        UserDefaults.standard.set(true, forKey: markerKey)
        return cached
    }

    func detect(
        in image: CGImage,
        classCount: Int,
        confidenceThreshold: Double
    ) throws -> [YOLODecoder.Detection] {
        var (tensor, letterbox) = Self.preprocess(image, inputSize: inputSize)
        let data = NSMutableData(
            bytes: &tensor,
            length: tensor.count * MemoryLayout<Float>.size
        )
        let inputValue = try ORTValue(
            tensorData: data,
            elementType: .float,
            shape: [1, 3, NSNumber(value: inputSize), NSNumber(value: inputSize)]
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
            classCount: classCount,
            confidenceThreshold: confidenceThreshold,
            inputSize: inputSize
        ).map { detection in
            YOLODecoder.Detection(
                rect: letterbox.imageRect(from: detection.rect, inputSize: inputSize),
                score: detection.score,
                classIndex: detection.classIndex
            )
        }
    }

    /// レターボックス方式（アスペクト比維持リサイズ+中央配置+グレー114パディング。学習時のultralytics標準と
    /// 同条件）で inputSize四方 RGB（0-1正規化）CHW配列へ変換する。単純リサイズでは縦長の漫画ページ等で
    /// 検出位置が微妙にずれるため（学習条件との不一致）、本方式へ変更した。
    static func preprocess(_ image: CGImage, inputSize: Int = 640) -> (tensor: [Float], letterbox: LetterboxTransform) {
        let size = inputSize
        let imageWidth = Double(image.width)
        let imageHeight = Double(image.height)
        let scale = min(Double(size) / max(1, imageWidth), Double(size) / max(1, imageHeight))
        let contentWidth = imageWidth * scale
        let contentHeight = imageHeight * scale
        let padX = (Double(size) - contentWidth) / 2
        let padY = (Double(size) - contentHeight) / 2

        var rgba = [UInt8](repeating: 114, count: size * size * 4)
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
            // 中央配置（上下パディングが対称のためCG座標系の上下反転の影響を受けない）
            context.draw(image, in: CGRect(x: padX, y: padY, width: contentWidth, height: contentHeight))
        }

        let plane = size * size
        var tensor = [Float](repeating: 0, count: 3 * plane)
        for index in 0..<plane {
            let offset = index * 4
            tensor[index] = Float(rgba[offset]) / 255.0
            tensor[plane + index] = Float(rgba[offset + 1]) / 255.0
            tensor[2 * plane + index] = Float(rgba[offset + 2]) / 255.0
        }
        return (
            tensor,
            LetterboxTransform(padX: padX, padY: padY, contentWidth: contentWidth, contentHeight: contentHeight)
        )
    }
}

/// アニメ・イラスト向けのNSFW部位検出器（内容ベース検出）。
/// モデル: deepghs/anime_censor_detection censor_detect_v1.0_s（MITライセンス, YOLOv8系ONNX,
/// クラス: nipple_f / penis / pussy）。DETECTION_IMPROVEMENT_PLAN.md §6.1 A / §6.2 の実装。
public final class AnimeCensorDetector {
    /// labels.json の順序（nipple_f, penis, pussy）に対応するアプリ内カテゴリ。
    static let classCategories: [MosaicTargetCategory] = [.nipple, .maleGenital, .femaleGenital]

    private let model: YOLOONNXModel

    public init() throws {
        model = try YOLOONNXModel(resourceName: "censor_detect")
    }

    /// 画像からNSFW部位を検出し、カテゴリ付きROIとして返す。
    public func detect(in image: CGImage, confidenceThreshold: Double = 0.3) throws -> [MosaicROI] {
        try model.detect(
            in: image,
            classCount: Self.classCategories.count,
            confidenceThreshold: confidenceThreshold
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
}

/// アニメ・イラスト向けの人物検出器（バウンディングボックス）。
/// モデル: deepghs/anime_person_detection person_detect_v1.3_s（MITライセンス, YOLOv8系ONNX, クラス: person）。
/// 実写学習のVisionセグメンテーションがイラストで部分的にしか反応しない問題への対応（計画書§6.1 D）。
/// シルエットマスクは生成しない（矩形のみ。マスクは将来のアニメセグメンテーションモデルで対応）。
public final class AnimePersonDetector {
    private let model: YOLOONNXModel

    public init() throws {
        model = try YOLOONNXModel(resourceName: "person_detect")
    }

    public func detectPersons(in image: CGImage, confidenceThreshold: Double = 0.3) throws -> [PersonDetection] {
        try model.detect(in: image, classCount: 1, confidenceThreshold: confidenceThreshold)
            .map { PersonDetection(bounds: $0.rect) }
    }
}

/// 実写向けのNSFW部位検出器（内容ベース検出）。
/// モデル: deepghs/nudenet_onnx 320n（Apache-2.0ライセンス, NudeNet v3 YOLOv8n系ONNX, 入力320x320,
/// 18クラス）。実写でも性器・乳首を内容ベースで検出するための導入
/// （従来の実写経路は骨格からの位置推定のみで、性器の内容ベース検出が無かった）。
public final class PhotoCensorDetector {
    /// NudeNet v3 の18クラスのうち、モザイク対象として採用するクラスのカテゴリ対応。
    /// 3=FEMALE_BREAST_EXPOSED, 4=FEMALE_GENITALIA_EXPOSED, 6=ANUS_EXPOSED, 14=MALE_GENITALIA_EXPOSED。
    /// 顔・足・腹などの非対象クラスと着衣（COVERED）クラスは採用しない。
    static let classCategories: [Int: MosaicTargetCategory] = [
        3: .nipple,
        4: .femaleGenital,
        6: .other,
        14: .maleGenital
    ]
    static let classCount = 18

    private let model: YOLOONNXModel

    public init() throws {
        model = try YOLOONNXModel(resourceName: "photo_censor_detect", inputSize: 320)
    }

    /// 画像からNSFW部位を検出し、カテゴリ付きROIとして返す。
    public func detect(in image: CGImage, confidenceThreshold: Double = 0.25) throws -> [MosaicROI] {
        try model.detect(
            in: image,
            classCount: Self.classCount,
            confidenceThreshold: confidenceThreshold
        ).compactMap { detection in
            guard let category = Self.classCategories[detection.classIndex] else { return nil }
            return MosaicROI(
                rect: detection.rect,
                confidence: detection.score,
                source: "photo-censor",
                shape: .ellipse,
                category: category
            )
        }
    }
}
