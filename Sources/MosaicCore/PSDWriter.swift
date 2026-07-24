import CoreGraphics
import Foundation

/// Photoshop（.psd）ファイルの自前ライター。
/// Adobe公開仕様「Photoshop File Formats Specification」準拠の最小実装（RGB 8bit・非圧縮RAWエンコード）。
/// `original` を渡した場合、「元画像」（非表示）+「モザイク適用」（表示）の2レイヤ構成で書き出し、
/// Photoshop側でレイヤーの表示切替による比較・追加レタッチができるようにする（本アプリのレイヤ機能を
/// 最大限再現）。`original` が nil の場合は単一レイヤ（フラット画像）として書き出す。
/// 完全ローカル生成、外部ライブラリ不要。
enum PSDWriter {
    private static let maxDimension = 30000

    static func write(
        composite: CGImage,
        original: CGImage?,
        options: ImageExportOptions,
        to url: URL
    ) throws {
        guard composite.width > 0, composite.height > 0,
              composite.width <= maxDimension, composite.height <= maxDimension else {
            throw ImageExportError.invalidImage
        }
        let width = composite.width
        let height = composite.height
        let compositePlanes = try rgbPlanes(from: composite, width: width, height: height)

        var layers: [(name: String, planes: RGBPlanes, visible: Bool)] = []
        if let original, original.width == width, original.height == height {
            let originalPlanes = try rgbPlanes(from: original, width: width, height: height)
            layers.append((name: "元画像", planes: originalPlanes, visible: false))
        }
        layers.append((name: "モザイク適用", planes: compositePlanes, visible: true))

        var data = Data()

        // 1. File Header Section
        data.append(ascii: "8BPS")
        data.appendUInt16BE(1) // version = 1 (PSD)
        data.append(contentsOf: [UInt8](repeating: 0, count: 6)) // reserved
        data.appendUInt16BE(3) // channels（RGB。レイヤ側チャンネル数とは独立の値だがR/G/Bの3を設定）
        data.appendUInt32BE(UInt32(height))
        data.appendUInt32BE(UInt32(width))
        data.appendUInt16BE(8) // depth
        data.appendUInt16BE(3) // color mode = RGB

        // 2. Color Mode Data Section（RGBは空）
        data.appendUInt32BE(0)

        // 3. Image Resources Section（省略。解像度メタデータ等は必須ではない）
        data.appendUInt32BE(0)

        // 4. Layer and Mask Information Section
        let layerAndMaskInfo = makeLayerAndMaskInfo(layers: layers, width: width, height: height)
        data.appendUInt32BE(UInt32(layerAndMaskInfo.count))
        data.append(layerAndMaskInfo)

        // 5. Image Data Section（統合/表示用の最終合成画像。圧縮方式0=RAW、R/G/Bの順にプレーン格納）
        data.appendUInt16BE(0)
        data.append(compositePlanes.red)
        data.append(compositePlanes.green)
        data.append(compositePlanes.blue)

        try data.write(to: url, options: .atomic)
    }

    private struct RGBPlanes {
        var red: Data
        var green: Data
        var blue: Data
    }

    private static func rgbPlanes(from image: CGImage, width: Int, height: Int) throws -> RGBPlanes {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageExportError.encodingFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var red = [UInt8](repeating: 0, count: width * height)
        var green = [UInt8](repeating: 0, count: width * height)
        var blue = [UInt8](repeating: 0, count: width * height)
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            red[pixel] = rgba[offset]
            green[pixel] = rgba[offset + 1]
            blue[pixel] = rgba[offset + 2]
        }
        return RGBPlanes(red: Data(red), green: Data(green), blue: Data(blue))
    }

    private static func makeLayerAndMaskInfo(
        layers: [(name: String, planes: RGBPlanes, visible: Bool)],
        width: Int,
        height: Int
    ) -> Data {
        var layerInfo = Data()
        layerInfo.appendInt16BE(Int16(layers.count))

        let channelDataLength = UInt32(2 + width * height) // 2byte圧縮方式(RAW=0) + 生データ

        // レイヤレコード（背面から前面の順）
        for layer in layers {
            layerInfo.appendInt32BE(0) // top
            layerInfo.appendInt32BE(0) // left
            layerInfo.appendInt32BE(Int32(height)) // bottom
            layerInfo.appendInt32BE(Int32(width)) // right
            layerInfo.appendUInt16BE(3) // channel count (R,G,B)
            for channelID: Int16 in [0, 1, 2] {
                layerInfo.appendInt16BE(channelID)
                layerInfo.appendUInt32BE(channelDataLength)
            }
            layerInfo.append(ascii: "8BIM")
            layerInfo.append(ascii: "norm") // blend mode: Normal
            layerInfo.append(255) // opacity
            layerInfo.append(0) // clipping = base
            // flags: bit0=透明保護なし, bit1=非表示（セットで非表示。多くの実装で採用される慣例）
            layerInfo.append(layer.visible ? 0x00 : 0x02)
            layerInfo.append(0) // filler

            var extra = Data()
            extra.appendUInt32BE(0) // layer mask data: なし
            extra.appendUInt32BE(0) // layer blending ranges: なし
            extra.append(pascalString: layer.name)
            layerInfo.appendUInt32BE(UInt32(extra.count))
            layerInfo.append(extra)
        }

        // チャンネル画像データ（レイヤレコードと同じ順）
        for layer in layers {
            for plane in [layer.planes.red, layer.planes.green, layer.planes.blue] {
                layerInfo.appendUInt16BE(0) // compression = raw
                layerInfo.append(plane)
            }
        }

        var layerInfoSection = Data()
        // レイヤ情報セクションは偶数長にパディングする（仕様上の要件）
        let padding = layerInfo.count % 2 == 0 ? 0 : 1
        layerInfoSection.appendUInt32BE(UInt32(layerInfo.count + padding))
        layerInfoSection.append(layerInfo)
        if padding > 0 { layerInfoSection.append(0) }

        var result = Data()
        result.append(layerInfoSection)
        result.appendUInt32BE(0) // global layer mask info: なし
        return result
    }
}

private extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendInt16BE(_ value: Int16) {
        appendUInt16BE(UInt16(bitPattern: value))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendInt32BE(_ value: Int32) {
        appendUInt32BE(UInt32(bitPattern: value))
    }

    mutating func append(ascii string: String) {
        append(contentsOf: Array(string.utf8))
    }

    /// Pascal文字列（1バイト長+本体）。全体（長さバイト込み）が4の倍数になるようパディングする。
    mutating func append(pascalString string: String) {
        let bytes = Array(string.utf8.prefix(255))
        append(UInt8(bytes.count))
        append(contentsOf: bytes)
        let total = 1 + bytes.count
        let remainder = total % 4
        if remainder != 0 {
            append(contentsOf: [UInt8](repeating: 0, count: 4 - remainder))
        }
    }
}
