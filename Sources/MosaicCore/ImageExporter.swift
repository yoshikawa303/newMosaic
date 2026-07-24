import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageExportError: Error, LocalizedError {
    case unsupportedFormat
    case destinationCreationFailed
    case encodingFailed
    case invalidImage

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "この形式には対応していません"
        case .destinationCreationFailed: return "出力先を作成できませんでした"
        case .encodingFailed: return "画像のエンコードに失敗しました"
        case .invalidImage: return "画像データが不正です"
        }
    }
}

/// 画像出力に対応する形式。
/// jpg/png/bmp/gif/tiff/heic/pdf は macOS標準 ImageIO/CoreGraphics で完全対応。
/// psd は自前実装のPhotoshop File Format互換ライター（Adobe公開仕様準拠、圧縮なしRAWエンコード）。
/// ai/eps はベクター編集用の実体ではなく、Illustrator・印刷ワークフローが直接開けるラスター埋め込み
/// コンテナとして出力する（本アプリはベクターパスを持たないため、真の意味でのベクターAI/EPSは生成できない）。
/// CLIP/SAI/MDP（CLIP STUDIO PAINT/SAI/MediBang Paint）は仕様非公開の独自形式のため非対応（ユーザー確認済み）。
public enum ImageExportFormat: String, CaseIterable, Sendable {
    case jpg, png, bmp, gif, tiff, heic, pdf, psd, ai, eps

    public var displayName: String {
        switch self {
        case .jpg: return "JPEG (.jpg)"
        case .png: return "PNG (.png)"
        case .bmp: return "BMP (.bmp)"
        case .gif: return "GIF (.gif)"
        case .tiff: return "TIFF (.tif)"
        case .heic: return "HEIC (.heic)"
        case .pdf: return "PDF (.pdf)"
        case .psd: return "Photoshop (.psd)"
        case .ai: return "Illustrator互換 (.ai)"
        case .eps: return "EPS (.eps)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpg: return "jpg"
        case .png: return "png"
        case .bmp: return "bmp"
        case .gif: return "gif"
        case .tiff: return "tif"
        case .heic: return "heic"
        case .pdf: return "pdf"
        case .psd: return "psd"
        case .ai: return "ai"
        case .eps: return "eps"
        }
    }

    /// ImageIOの圧縮率（0.0〜1.0）に対応する形式か。
    public var supportsQuality: Bool { self == .jpg || self == .heic }

    /// 「元画像」を別レイヤとして含められる形式か（本アプリが持つ2状態=元画像/モザイク適用結果を活かせる）。
    public var supportsLayers: Bool { self == .psd }

    /// ImageIOの UTType（jpg/png/bmp/gif/tiff/heicのみ）。
    public var utType: UTType? {
        switch self {
        case .jpg: return .jpeg
        case .png: return .png
        case .bmp: return .bmp
        case .gif: return .gif
        case .tiff: return .tiff
        case .heic: return .heic
        default: return nil
        }
    }
}

/// 画像出力時の詳細設定（印刷・イラストレーター向けの一般的な項目）。
public struct ImageExportOptions: Sendable {
    /// JPEG/HEICの圧縮品質（0.0〜1.0。1.0が最高品質）。
    public var quality: Double
    /// 出力解像度（DPI）。印刷用メタデータとして埋め込む。
    public var dpi: Double
    /// PSD出力時、元画像を非表示レイヤとして含めるか（レタッチ後の比較用）。
    public var includeOriginalLayer: Bool
    /// PNG等の可逆圧縮フォーマットで透明背景を維持するか（falseなら不透明合成）。
    public var preserveTransparency: Bool

    public init(
        quality: Double = 0.92,
        dpi: Double = 350,
        includeOriginalLayer: Bool = true,
        preserveTransparency: Bool = true
    ) {
        self.quality = quality
        self.dpi = dpi
        self.includeOriginalLayer = includeOriginalLayer
        self.preserveTransparency = preserveTransparency
    }
}

/// 各形式への画像書き出しを一元管理する。完全ローカル処理（外部送信なし）。
public enum ImageExporter {
    public static func export(
        image: CGImage,
        originalImage: CGImage?,
        format: ImageExportFormat,
        options: ImageExportOptions,
        to url: URL
    ) throws {
        switch format {
        case .jpg, .png, .bmp, .gif, .tiff, .heic:
            try exportViaImageIO(image: image, format: format, options: options, to: url)
        case .pdf, .ai:
            try exportPDF(image: image, options: options, to: url)
        case .eps:
            try EPSWriter.write(image: image, options: options, to: url)
        case .psd:
            try PSDWriter.write(
                composite: image,
                original: options.includeOriginalLayer ? originalImage : nil,
                options: options,
                to: url
            )
        }
    }

    private static func exportViaImageIO(
        image: CGImage,
        format: ImageExportFormat,
        options: ImageExportOptions,
        to url: URL
    ) throws {
        guard let utType = format.utType else { throw ImageExportError.unsupportedFormat }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            utType.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageExportError.destinationCreationFailed
        }
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: options.dpi,
            kCGImagePropertyDPIHeight: options.dpi
        ]
        if format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageExportError.encodingFailed
        }
    }

    /// PDF/AI（Illustrator互換コンテナ）: 画像をDPI換算のポイントサイズで1ページへ配置する。
    static func exportPDF(image: CGImage, options: ImageExportOptions, to url: URL) throws {
        let widthPoints = CGFloat(image.width) * 72.0 / CGFloat(max(1, options.dpi))
        let heightPoints = CGFloat(image.height) * 72.0 / CGFloat(max(1, options.dpi))
        var mediaBox = CGRect(x: 0, y: 0, width: widthPoints, height: heightPoints)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ImageExportError.destinationCreationFailed
        }
        context.beginPDFPage(nil)
        context.draw(image, in: CGRect(x: 0, y: 0, width: widthPoints, height: heightPoints))
        context.endPDFPage()
        context.closePDF()
    }
}
