import CoreGraphics
import CoreImage
import Foundation
@preconcurrency import OnnxRuntimeBindings

/// MobileSAM（Segment Anything の軽量版）で、検出枠の内部から対象の形状マスクを直接得るエンジン。
///
/// Visionの前景抽出は「被写体と背景」を分けるため、被写体内部の部位（性器・乳首）は
/// 原理的に分離できない（ARCHITECTURE §5.40/§5.41 の実測）。SAMは「枠（プロンプト）を
/// 与えると、その中の物体の形状を返す」モデルであり、まさにこの欠落を埋める。
/// 検出モデルが出したROI枠をそのままプロンプトに使うため、**追加の手作業は一切ない**。
///
/// - モデル: MobileSAM（Apache-2.0）のONNX変換版（Acly/MobileSAM, MIT）を同梱。完全ローカル実行。
/// - エンコーダ入力は `(H, W, 3)` float32 RGB 0〜255（正規化・パディングはモデル内部で行う）。
///   ただし**リサイズはモデル内部で行わない**ため、呼び出し側で長辺を1024へ揃える（実測で
///   確認済み。省略すると座標系がずれ、マスクが対象の一部にしか付かない）。
/// - デコーダは枠を「左上点(label=2)+右下点(label=3)」として受け取り、元画像サイズの
///   マスクlogitsを返す（>0 が対象）。
/// - 失敗時・マスクがほぼ空の場合は `ShapeSegmentEngine` へフォールバックし、検閲漏れを作らない。
public final class SAMSegmentEngine: Segmenting {
    /// SAM標準の入力解像度（長辺）。
    static let inputLongSide = 1024
    /// 採用するマスクの最小被覆率（ROI矩形内）。これ未満は「ほぼ空」でフォールバックする。
    static let minimumUsableCoverage = 0.02

    private let fallback = ShapeSegmentEngine()
    private let measureContext = CIContext(options: [.cacheIntermediates: false])

    /// ORTセッションの共有コンテナ。ONNX RuntimeのSessionはスレッドセーフだが
    /// Sendable注釈が無いため、イミュータブルなコンテナで包んで共有する。
    private final class Sessions: @unchecked Sendable {
        let env: ORTEnv
        let encoder: ORTSession
        let decoder: ORTSession
        init(env: ORTEnv, encoder: ORTSession, decoder: ORTSession) {
            self.env = env
            self.encoder = encoder
            self.decoder = decoder
        }
    }

    /// エンコーダ・デコーダのセッションはモデル読み込みが重いため、プロセス内で共有する。
    private static let sharedSessions: Sessions? = {
        do {
            let encoderURL = try YOLOONNXModel.cachedModelURL(resourceName: "sam_encoder")
            let decoderURL = try YOLOONNXModel.cachedModelURL(resourceName: "sam_decoder")
            let env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            let encoder = try ORTSession(env: env, modelPath: encoderURL.path, sessionOptions: options)
            let decoder = try ORTSession(env: env, modelPath: decoderURL.path, sessionOptions: options)
            return Sessions(env: env, encoder: encoder, decoder: decoder)
        } catch {
            segmentLogger.error("samShape sessionInitFailed")
            return nil
        }
    }()

    /// 画像埋め込みのキャッシュ（直近1枚）。モザイクプレビューの再生成のたびに
    /// エンコーダ（重い方）を回さないため。CGImageの同一性で判定する。
    private final class EmbeddingCache: @unchecked Sendable {
        private var entry: (image: CGImage, value: ORTValue)?
        private let lock = NSLock()
        func value(for image: CGImage) -> ORTValue? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry, entry.image === image else { return nil }
            return entry.value
        }
        func store(image: CGImage, value: ORTValue) {
            lock.lock()
            defer { lock.unlock() }
            entry = (image, value)
        }
    }
    private static let embeddingCache = EmbeddingCache()

    public init() {}

    public func createMasks(for rois: [MosaicROI], in image: CGImage, extent: CGRect) throws -> [CIImage] {
        guard let sessions = Self.sharedSessions else {
            segmentLogger.info("samShape unavailable fallback=shape")
            return try fallback.createMasks(for: rois, in: image, extent: extent)
        }
        let embedding: ORTValue
        do {
            embedding = try Self.imageEmbedding(for: image, encoder: sessions.encoder)
        } catch {
            segmentLogger.info("samShape encodeFailed fallback=shape")
            return try fallback.createMasks(for: rois, in: image, extent: extent)
        }

        var masks: [CIImage] = []
        for roi in rois {
            if let mask = try? samMask(
                for: roi,
                embedding: embedding,
                decoder: sessions.decoder,
                image: image,
                extent: extent
            ) {
                masks.append(mask)
            } else {
                masks.append(try fallback.createMasks(for: [roi], in: image, extent: extent)[0])
            }
        }
        return masks
    }

    // MARK: - エンコード

    private static func imageEmbedding(for image: CGImage, encoder: ORTSession) throws -> ORTValue {
        if let cached = embeddingCache.value(for: image) {
            return cached
        }

        // 長辺を1024へリサイズ（アスペクト比維持。パディング・正規化はモデル内部で行う）
        let scale = Double(inputLongSide) / Double(max(image.width, image.height))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var tensor = try rgbTensorHWC(image: image, width: width, height: height)

        let data = NSMutableData(bytes: &tensor, length: tensor.count * MemoryLayout<Float>.size)
        let inputValue = try ORTValue(
            tensorData: data,
            elementType: .float,
            shape: [NSNumber(value: height), NSNumber(value: width), 3]
        )
        let inputName = try encoder.inputNames().first ?? "input_image"
        let outputName = try encoder.outputNames().first ?? "image_embeddings"
        let outputs = try encoder.run(
            withInputs: [inputName: inputValue],
            outputNames: [outputName],
            runOptions: nil
        )
        guard let value = outputs[outputName] else {
            throw CocoaError(.fileReadUnknown)
        }
        embeddingCache.store(image: image, value: value)
        return value
    }

    /// CGImage → `(height, width, 3)` float32 RGB 0〜255 のHWCテンソル。
    static func rgbTensorHWC(image: CGImage, width: Int, height: Int) throws -> [Float] {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(
                data: pointer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw CocoaError(.fileReadUnknown) }
        var tensor = [Float](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            tensor[pixel * 3 + 0] = Float(rgba[pixel * 4 + 0])
            tensor[pixel * 3 + 1] = Float(rgba[pixel * 4 + 1])
            tensor[pixel * 3 + 2] = Float(rgba[pixel * 4 + 2])
        }
        return tensor
    }

    // MARK: - デコード（ROIごと）

    private func samMask(
        for roi: MosaicROI,
        embedding: ORTValue,
        decoder: ORTSession,
        image: CGImage,
        extent: CGRect
    ) throws -> CIImage? {
        let imageSize = CGSize(width: image.width, height: image.height)
        // プロンプト枠: ROIの画素座標（左上原点）。回転ROIは回転後の外接矩形を使う
        var box = roi.rect.cgRect(imageSize: imageSize, origin: .topLeft)
        if abs(roi.rotation) > 0.01 {
            box = Self.rotatedBoundingBox(of: box, rotationDegrees: roi.rotation)
        }
        let scale = Double(Self.inputLongSide) / Double(max(image.width, image.height))

        // 枠 = 左上点(label 2) + 右下点(label 3)。座標はリサイズ後（長辺1024）空間
        var coords: [Float] = [
            Float(box.minX * scale), Float(box.minY * scale),
            Float(box.maxX * scale), Float(box.maxY * scale)
        ]
        var labels: [Float] = [2, 3]
        var maskInput = [Float](repeating: 0, count: 256 * 256)
        var hasMask: [Float] = [0]
        var origSize: [Float] = [Float(image.height), Float(image.width)]

        func value(_ array: inout [Float], shape: [NSNumber]) throws -> ORTValue {
            let data = NSMutableData(bytes: &array, length: array.count * MemoryLayout<Float>.size)
            return try ORTValue(tensorData: data, elementType: .float, shape: shape)
        }
        let inputs: [String: ORTValue] = [
            "image_embeddings": embedding,
            "point_coords": try value(&coords, shape: [1, 2, 2]),
            "point_labels": try value(&labels, shape: [1, 2]),
            "mask_input": try value(&maskInput, shape: [1, 1, 256, 256]),
            "has_mask_input": try value(&hasMask, shape: [1]),
            "orig_im_size": try value(&origSize, shape: [2])
        ]
        let outputs = try decoder.run(withInputs: inputs, outputNames: ["masks"], runOptions: nil)
        guard let masksValue = outputs["masks"] else { return nil }
        let floats = (try masksValue.tensorData() as Data)
            .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard floats.count >= image.width * image.height else { return nil }

        // logits > 0 が対象。8bitグレースケールの二値マスクへ変換する
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        for index in 0..<pixels.count where floats[index] > 0 {
            pixels[index] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let maskImage = CGImage(
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 8,
                  bytesPerRow: image.width,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }

        var mask = CIImage(cgImage: maskImage)
        if mask.extent.width != extent.width || mask.extent.height != extent.height {
            mask = mask.transformed(by: CGAffineTransform(
                scaleX: extent.width / mask.extent.width,
                y: extent.height / mask.extent.height
            ))
        }

        // 画面に表示されているROIの形状（矩形/楕円/多角形）の**二値**マスクで制限する。
        // 矩形で制限すると、SAMのマスクがROI全体を覆ったとき「楕円のROIなのに四角いモザイク」に
        // なってしまう（GUI報告）。二値なので、§5.41の「縁で輪郭が薄まる」問題も起きない。
        let black = CIImage(color: .black).cropped(to: extent)
        let roiRect = roi.rect.cgRect(imageSize: extent.size, origin: .bottomLeft)
        let boundsMask = ShapeSegmentEngine.hardShapeMask(for: roi, extent: extent)
        let restricted = mask.composited(over: black).applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: boundsMask
        ]).cropped(to: extent)

        let coverage = coverageRatio(of: restricted, in: roiRect)
        segmentLogger.info("""
            samShape category=\(roi.category.rawValue, privacy: .public) \
            rotation=\(Int(roi.rotation)) \
            coverage=\(String(format: "%.2f", coverage), privacy: .public)
            """)
        // ほぼ空のマスクは検閲漏れになるため採用せず、図形フォールバックへ倒す
        guard coverage >= Self.minimumUsableCoverage else { return nil }
        return restricted
    }

    /// ROI矩形内での白領域の割合（リニア測定。§5.41のガンマ問題を避ける）。
    private func coverageRatio(of mask: CIImage, in rect: CGRect) -> Double {
        guard rect.width > 0, rect.height > 0 else { return 0 }
        let average = mask.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: rect)
        ])
        var pixel = [UInt8](repeating: 0, count: 4)
        let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        measureContext.render(
            average,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: linearSpace
        )
        return Double(pixel[0]) / 255.0
    }

    private static func rotatedBoundingBox(of rect: CGRect, rotationDegrees: Double) -> CGRect {
        guard abs(rotationDegrees) > 0.01 else { return rect }
        let radians = rotationDegrees * .pi / 180
        let cosA = abs(cos(radians))
        let sinA = abs(sin(radians))
        let newWidth = rect.width * cosA + rect.height * sinA
        let newHeight = rect.width * sinA + rect.height * cosA
        return CGRect(
            x: rect.midX - newWidth / 2,
            y: rect.midY - newHeight / 2,
            width: newWidth,
            height: newHeight
        )
    }
}
