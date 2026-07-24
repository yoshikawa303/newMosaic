import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// EPS（Encapsulated PostScript）ライター。
/// 本アプリはベクターパスを持たないため、真のベクターEPSではなく、
/// JPEG圧縮した画像をPostScript Level 2の DCTDecode フィルタで埋め込む
/// 標準的な「ラスター画像入りEPS」を生成する（印刷・DTPワークフローで広く使われる形式）。
/// 完全ローカル生成、外部ライブラリ不要（ASCII85エンコードを自前実装）。
enum EPSWriter {
    static func write(image: CGImage, options: ImageExportOptions, to url: URL) throws {
        let jpegData = try Self.jpegData(from: image, quality: options.quality)
        let widthPoints = Double(image.width) * 72.0 / max(1, options.dpi)
        let heightPoints = Double(image.height) * 72.0 / max(1, options.dpi)
        let boundingWidth = Int(widthPoints.rounded(.up))
        let boundingHeight = Int(heightPoints.rounded(.up))

        var text = """
        %!PS-Adobe-3.0 EPSF-3.0
        %%BoundingBox: 0 0 \(boundingWidth) \(boundingHeight)
        %%HiResBoundingBox: 0 0 \(String(format: "%.4f", widthPoints)) \(String(format: "%.4f", heightPoints))
        %%Creator: newMosaic
        %%Title: newMosaic export
        %%Pages: 1
        %%LanguageLevel: 2
        %%DocumentData: Clean7Bit
        %%EndComments
        %%BeginProlog
        %%EndProlog
        %%Page: 1 1
        gsave
        \(String(format: "%.4f", widthPoints)) \(String(format: "%.4f", heightPoints)) scale
        /DeviceRGB setcolorspace
        <<
          /ImageType 1
          /Width \(image.width)
          /Height \(image.height)
          /BitsPerComponent 8
          /Decode [0 1 0 1 0 1]
          /ImageMatrix [\(String(format: "%.10f", 1.0 / Double(image.width))) 0 0 \(String(format: "%.10f", -1.0 / Double(image.height))) 0 1]
          /DataSource currentfile /ASCII85Decode filter /DCTDecode filter
        >> image

        """
        text += Self.ascii85Encode(jpegData)
        text += "\ngrestore\nshowpage\n%%EOF\n"

        guard let data = text.data(using: .isoLatin1) else {
            throw ImageExportError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
    }

    private static func jpegData(from image: CGImage, quality: Double) throws -> Data {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageExportError.destinationCreationFailed
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageExportError.encodingFailed
        }
        return mutableData as Data
    }

    /// ASCII85（Adobe版, 末尾 `~>` 終端）エンコード。PostScript/PDFで標準的に使われる方式。
    static func ascii85Encode(_ data: Data) -> String {
        var output = ""
        output.reserveCapacity(data.count * 5 / 4 + 8)
        let bytes = [UInt8](data)
        var index = 0
        var lineLength = 0

        func appendChar(_ char: Character) {
            output.append(char)
            lineLength += 1
            if lineLength >= 76 {
                output.append("\n")
                lineLength = 0
            }
        }

        while index < bytes.count {
            let remaining = bytes.count - index
            let chunkSize = min(4, remaining)
            var value: UInt32 = 0
            for offset in 0..<4 {
                value <<= 8
                if offset < chunkSize {
                    value |= UInt32(bytes[index + offset])
                }
            }
            if chunkSize == 4 && value == 0 {
                appendChar("z")
            } else {
                var encoded = [UInt8](repeating: 0, count: 5)
                var remainderValue = value
                for position in stride(from: 4, through: 0, by: -1) {
                    encoded[position] = UInt8(remainderValue % 85) + 33
                    remainderValue /= 85
                }
                let usedCount = chunkSize + 1
                for position in 0..<usedCount {
                    appendChar(Character(UnicodeScalar(encoded[position])))
                }
            }
            index += chunkSize
        }
        output.append("~>")
        return output
    }
}
