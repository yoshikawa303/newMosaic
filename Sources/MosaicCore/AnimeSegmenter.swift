import CoreGraphics
import Foundation
import OnnxRuntimeBindings

/// アニメ・イラスト向けのキャラクターセグメンテーション。
/// モデル: skytnt/anime-seg isnetis.onnx（Apache-2.0, ISNet系, 入力1024x1024, 出力1chマスク）。
/// イラスト/漫画で人物レイヤが矩形のみだった問題への対応（実写のVisionシルエット相当を提供する）。
/// 完全ローカル実行。画像・マスクの外部送信は行わない。
public final class AnimeSegmenter {
    static let inputSize = 1024

    private let env: ORTEnv
    private let session: ORTSession
    private let inputName: String
    private let outputName: String

    public init() throws {
        let modelURL = try YOLOONNXModel.cachedModelURL(resourceName: "anime_seg")
        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        inputName = try session.inputNames().first ?? "img"
        outputName = try session.outputNames().first ?? "mask"
    }

    /// 画像全体のキャラクターマスク（グレースケールCGImage、元画像と同サイズ）を返す。
    /// 前処理はSkyTNT公式実装と同条件（アスペクト維持リサイズ+中央ゼロパディング+/255正規化）。
    public func characterMask(in image: CGImage) throws -> CGImage? {
        let size = Self.inputSize
        let imageWidth = Double(image.width)
        let imageHeight = Double(image.height)
        guard imageWidth > 0, imageHeight > 0 else { return nil }
        let scale = min(Double(size) / imageWidth, Double(size) / imageHeight)
        let contentWidth = max(1, Int((imageWidth * scale).rounded()))
        let contentHeight = max(1, Int((imageHeight * scale).rounded()))
        let padX = (size - contentWidth) / 2
        let padY = (size - contentHeight) / 2

        // RGBA描画（ゼロパディング）→ /255 CHW
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

        let data = NSMutableData(bytes: &tensor, length: tensor.count * MemoryLayout<Float>.size)
        let inputValue = try ORTValue(
            tensorData: data,
            elementType: .float,
            shape: [1, 3, NSNumber(value: size), NSNumber(value: size)]
        )
        let outputs = try session.run(
            withInputs: [inputName: inputValue],
            outputNames: [outputName],
            runOptions: nil
        )
        guard let output = outputs[outputName] else { return nil }
        let outputData = try output.tensorData() as Data
        let mask = outputData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard mask.count >= size * size else { return nil }

        // パディングを除いたコンテンツ領域を8bitグレースケール化。
        // モデル出力の行方向は入力と逆（行0=下）であることがGUI実測で確定した
        // （「人物認識範囲が上下反転表示される」報告。コードレビューでも行方向未検証として
        // 指摘されていた項目）。上下を反転して取り出す。
        var gray = [UInt8](repeating: 0, count: contentWidth * contentHeight)
        for y in 0..<contentHeight {
            let sourceRow = (size - 1 - (y + padY)) * size + padX
            for x in 0..<contentWidth {
                let value = mask[sourceRow + x]
                gray[y * contentWidth + x] = UInt8(min(255, max(0, value * 255)))
            }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let contentMask = CGImage(
                  width: contentWidth,
                  height: contentHeight,
                  bitsPerComponent: 8,
                  bitsPerPixel: 8,
                  bytesPerRow: contentWidth,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else { return nil }

        // 元画像サイズへ拡大
        guard let outputContext = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        outputContext.interpolationQuality = .medium
        outputContext.draw(contentMask, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return outputContext.makeImage()
    }

    /// 全体キャラクターマスクを人物矩形内へ制限した per-person マスクを返す（矩形外は黒）。
    public static func personMask(
        fullMask: CGImage,
        bounds: NormalizedRect,
        imageSize: CGSize
    ) -> CGImage? {
        let rectTopLeft = bounds.cgRect(imageSize: imageSize, origin: .topLeft)
        guard rectTopLeft.width >= 2, rectTopLeft.height >= 2,
              let crop = fullMask.cropping(to: rectTopLeft),
              let context = CGContext(
                  data: nil,
                  width: Int(imageSize.width),
                  height: Int(imageSize.height),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: imageSize))
        // CGContextは下原点のため配置位置を変換して描画する
        let rectBottomLeft = bounds.cgRect(imageSize: imageSize, origin: .bottomLeft)
        context.draw(crop, in: rectBottomLeft)
        return context.makeImage()
    }
}
