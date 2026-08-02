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
    /// 「SAMが対象を分離できている」とみなす被覆率の上限（診断・測定の目安）。
    /// これを超える＝枠を塗り潰しており対象の輪郭を取れていない。
    /// v0.0.00111 以降、マスクは常に選択範囲の形状で切るため切り方の分岐には使わない。
    static let shapeConformCoverage = 0.85

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

    /// 画像埋め込みのキャッシュ。モザイクプレビューの再生成のたびにエンコーダ（重い方）を
    /// 回さないため。小さいROIは周辺を切り出して個別にエンコードするので、
    /// 「元画像1枚 ＋ その画像から切り出した窓」を同時に保持する。
    /// 元画像が変わった時点で全て捨てる（CGImageの同一性で判定）。
    private final class EmbeddingCache: @unchecked Sendable {
        /// 1埋め込みは 1x256x64x64 float32 = 4MB。1画像あたりの小さいROIは通常10件未満なので
        /// 8件あれば足りる（超えた分は再エンコードするだけで、動作は変わらない）。
        private static let capacity = 8
        private var source: CGImage?
        private var entries: [String: ORTValue] = [:]
        private let lock = NSLock()
        /// エンコーダを実際に走らせた回数（＝キャッシュに入れた回数）。
        /// キャッシュの効きをテストで確認するための計測用。実行時間の比較は機械の負荷で
        /// 揺れて不安定なため、回数で判定する。
        private var storeCount = 0

        func value(source: CGImage, key: String) -> ORTValue? {
            lock.lock()
            defer { lock.unlock() }
            guard self.source === source else { return nil }
            return entries[key]
        }

        func store(source: CGImage, key: String, value: ORTValue) {
            lock.lock()
            defer { lock.unlock() }
            if self.source !== source {
                self.source = source
                entries.removeAll()
            }
            if entries.count >= Self.capacity { entries.removeAll() }
            entries[key] = value
            storeCount += 1
        }

        var encoderRunCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return storeCount
        }
    }
    private static let embeddingCache = EmbeddingCache()

    public init() {}

    /// エンコーダを実際に走らせた累計回数（テストでキャッシュの効きを確認するための計測）。
    static var encoderRunCountForMeasurement: Int { embeddingCache.encoderRunCount }

    /// メモリ実測用にセッションだけ先に読み込む（テスト専用）。
    static func warmUpSessionsForMeasurement() {
        _ = sharedSessions
    }

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
        try imageEmbedding(of: image, source: image, cacheKey: "full", encoder: encoder)
    }

    /// `target` をエンコードする。`source`/`cacheKey` はキャッシュの同一性判定にのみ使う
    /// （切り出し窓の埋め込みを、元画像の埋め込みと共存させるため）。
    private static func imageEmbedding(
        of target: CGImage,
        source: CGImage,
        cacheKey: String,
        encoder: ORTSession
    ) throws -> ORTValue {
        if let cached = embeddingCache.value(source: source, key: cacheKey) {
            return cached
        }
        let image = target

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
            runOptions: ORTMemory.shrinkingRunOptions
        )
        guard let value = outputs[outputName] else {
            throw CocoaError(.fileReadUnknown)
        }
        embeddingCache.store(source: source, key: cacheKey, value: value)
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


    /// SAMのデコーダを枠プロンプトで実行し、元画像サイズの二値マスク（白=対象）を返す。
    /// デコーダ出力はマスクのlogitsで、>0 が対象。
    private static func binaryMask(
        box: CGRect,
        embedding: ORTValue,
        decoder: ORTSession,
        image: CGImage
    ) throws -> CGImage? {
        let scale = Double(inputLongSide) / Double(max(image.width, image.height))
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
        let outputs = try decoder.run(withInputs: inputs, outputNames: ["masks"], runOptions: ORTMemory.shrinkingRunOptions)
        guard let masksValue = outputs["masks"] else { return nil }
        let floats = (try masksValue.tensorData() as Data)
            .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard floats.count >= image.width * image.height else { return nil }

        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        for index in 0..<pixels.count where floats[index] > 0 {
            pixels[index] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
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
        )
    }

    // MARK: - 小さいROI向けの切り出し推論

    /// SAM入力（長辺1024）空間でのROI長辺がこれ未満なら、周辺を切り出してから推論する。
    ///
    /// SAMは画像全体を長辺1024へ縮小し、デコーダは256×256のマスクlogitsを生成する。
    /// 元画像のROIは最終的に「長辺1024換算のさらに1/4」の格子でしか表現されないため、
    /// 小さいROIは形状が潰れる（GUI報告: 小さい男性器はSAMより「対象形状」の方が正しい）。
    ///
    /// 値は実サンプル3枚のROI13件での実測による（ROI矩形内の被覆率、全体推論→切り出し推論）。
    /// 被覆率が1.0付近＝枠を塗り潰しており対象を分離できていない、という意味になる。
    ///
    ///     入力換算17〜59: 0.89〜0.97 → 0.72〜0.82（切り出しで明確に分離できる）
    ///     入力換算61     : 0.76      → 0.71
    ///     入力換算130〜255: 0.36〜0.70 → 0.36〜0.66（差はノイズ程度。切り出しの利点なし）
    ///
    /// 効果のある側（〜61）と無い側（130〜）の間を取って96とする。
    /// 切り出しは窓ごとにエンコーダを回すため、利点の無い大きなROIには使わない。
    /// 再測定は `swift test --filter compareSAMWholeImageAndCropForSmallROIs` で行う。
    static let minimumBoxSideInInput = 96.0
    /// 切り出す窓の大きさ（ROI長辺の倍率）。SAMは周辺の文脈がないと対象を切り出せないため、
    /// ROIちょうどではなく周囲を含める。
    static let cropContextScale = 3.0

    /// ROIを中心に周辺を含めた正方形の切り出し窓（画像内へ収める）。
    static func contextWindow(around box: CGRect, imageSize: CGSize) -> CGRect? {
        guard box.width > 0, box.height > 0, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let side = min(
            max(box.width, box.height) * cropContextScale,
            min(imageSize.width, imageSize.height)
        )
        var origin = CGPoint(x: box.midX - side / 2, y: box.midY - side / 2)
        origin.x = min(max(0, origin.x), imageSize.width - side)
        origin.y = min(max(0, origin.y), imageSize.height - side)
        let window = CGRect(x: origin.x, y: origin.y, width: side, height: side).integral
        let bounds = CGRect(origin: .zero, size: imageSize)
        let clipped = window.intersection(bounds)
        // 窓がROIを含まなくなるほど小さい場合は切り出さない（全体推論に任せる）
        guard clipped.contains(box.intersection(bounds)) else { return nil }
        return clipped
    }

    /// 小さいROI向けに、周辺を切り出してからSAMを実行し、結果を元画像座標のマスクへ戻す。
    private static func binaryMaskViaCrop(
        box: CGRect,
        encoder: ORTSession,
        decoder: ORTSession,
        image: CGImage
    ) throws -> CGImage? {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard let window = contextWindow(around: box, imageSize: imageSize),
              let cropped = image.cropping(to: window) else { return nil }
        let key = "crop:\(Int(window.minX)),\(Int(window.minY)),\(Int(window.width)),\(Int(window.height))"
        let embedding = try imageEmbedding(of: cropped, source: image, cacheKey: key, encoder: encoder)
        let localBox = box.offsetBy(dx: -window.minX, dy: -window.minY)
        guard let localMask = try binaryMask(
            box: localBox, embedding: embedding, decoder: decoder, image: cropped
        ) else { return nil }
        return place(localMask, at: window, inImageOfSize: imageSize)
    }

    /// 切り出し窓のマスクを、元画像サイズの黒背景マスクへ貼り戻す。
    static func place(_ mask: CGImage, at window: CGRect, inImageOfSize size: CGSize) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        // CGContextは下原点、windowは上原点なので上下を入れ替える
        context.draw(mask, in: CGRect(
            x: window.minX, y: size.height - window.maxY,
            width: window.width, height: window.height
        ))
        return context.makeImage()
    }

    // MARK: - デコード（ROIごと）

    /// 枠（プロンプト）を与えて、その中の対象の二値マスクを元画像サイズで得る。
    ///
    /// 人物シルエット用にも使う。`anime_seg.onnx` は「キャラクターか背景か」の二値分類であり、
    /// 人物が重なった場面や寝具の多い場面では対象を分離できず枠全体を塗ってしまう
    /// （GUI報告: 下段コマでベッドや別人の足まで人物範囲になる）。
    /// SAMは枠で指定したインスタンスを取るため、こうした場面での分離に向く。
    /// モデル未導入・推論失敗時は nil を返す（呼び出し側で従来経路へフォールバックする）。
    public func instanceMask(in image: CGImage, box bounds: NormalizedRect) -> CGImage? {
        guard let sessions = Self.sharedSessions,
              let embedding = try? Self.imageEmbedding(for: image, encoder: sessions.encoder) else {
            return nil
        }
        let imageSize = CGSize(width: image.width, height: image.height)
        let box = bounds.clamped().cgRect(imageSize: imageSize, origin: .topLeft)
        return try? Self.binaryMask(
            box: box, embedding: embedding, decoder: sessions.decoder, image: image
        )
    }

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
        // 小さいROIは全体推論だと形状が潰れるため、周辺を切り出してから推論する
        let scale = Double(Self.inputLongSide) / Double(max(image.width, image.height))
        let boxSideInInput = max(box.width, box.height) * scale
        let usesCrop = boxSideInInput < Self.minimumBoxSideInInput
        let maskImage: CGImage?
        if usesCrop, let encoder = Self.sharedSessions?.encoder {
            maskImage = try Self.binaryMaskViaCrop(
                box: box, encoder: encoder, decoder: decoder, image: image
            ) ?? Self.binaryMask(box: box, embedding: embedding, decoder: decoder, image: image)
        } else {
            maskImage = try Self.binaryMask(
                box: box, embedding: embedding, decoder: decoder, image: image
            )
        }
        guard let maskImage else { return nil }


        var mask = CIImage(cgImage: maskImage)
        if mask.extent.width != extent.width || mask.extent.height != extent.height {
            mask = mask.transformed(by: CGAffineTransform(
                scaleX: extent.width / mask.extent.width,
                y: extent.height / mask.extent.height
            ))
        }

        // マスクは常に**選択範囲の形状**で切る。
        //
        // 以前は「SAMが対象を分離できていれば矩形だけで切る」としていた（§5.46）。
        // 楕円で切ると対象の一部が外れて検閲漏れになるためだったが、その結果
        // 「楕円・多角形を選んでいるのにマスクが範囲の外へはみ出す」状態になっていた
        // （GUI報告 2026-07-31）。
        //
        // 現在は `DetectedROIRefiner.expandGenitalROIsToCoverShape` が、選択した形状が
        // 元の検出枠を包み込む大きさまでROIを広げている。したがって形状で切っても
        // 対象は欠けない。表示している範囲とマスクが一致する方が動作として正しい。
        let black = CIImage(color: .black).cropped(to: extent)
        let roiRect = roi.rect.cgRect(imageSize: extent.size, origin: .bottomLeft)
        let opaque = mask.composited(over: black)
        let shapeMask = ShapeSegmentEngine.hardShapeMask(for: roi, extent: extent)
        let restricted = opaque.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: shapeMask
        ]).cropped(to: extent)
        let rectCoverage = coverageRatio(of: restricted, in: roiRect)

        let coverage = coverageRatio(of: restricted, in: roiRect)
        segmentLogger.info("""
            samShape category=\(roi.category.rawValue, privacy: .public) \
            rotation=\(Int(roi.rotation)) \
            path=\(usesCrop ? "crop" : "full", privacy: .public) \
            boxSideInInput=\(Int(boxSideInInput)) \
            rectCoverage=\(String(format: "%.2f", rectCoverage), privacy: .public) \
            clip=shape \
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

    /// 全体推論と切り出し推論を同じROIで比較測定するための入口（テスト専用）。
    /// 返す値はROI矩形内での白画素の割合。
    static func measureCoverage(
        in image: CGImage,
        box: NormalizedRect,
        useCrop: Bool
    ) -> Double? {
        guard let sessions = sharedSessions else { return nil }
        let imageSize = CGSize(width: image.width, height: image.height)
        let rect = box.clamped().cgRect(imageSize: imageSize, origin: .topLeft)
        let mask: CGImage?
        if useCrop {
            mask = try? binaryMaskViaCrop(
                box: rect, encoder: sessions.encoder, decoder: sessions.decoder, image: image
            )
        } else {
            guard let embedding = try? imageEmbedding(for: image, encoder: sessions.encoder) else {
                return nil
            }
            mask = try? binaryMask(
                box: rect, embedding: embedding, decoder: sessions.decoder, image: image
            )
        }
        guard let mask else { return nil }
        return PersonSilhouetteProvider.coverage(of: mask, within: box)
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
