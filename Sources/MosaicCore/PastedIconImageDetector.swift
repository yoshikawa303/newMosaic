import CoreGraphics
import Foundation

/// 「Finderでコピーしたファイルを貼り付けた結果、実体ではなく**ファイルアイコン**が
/// 静止画として取り込まれてしまった項目」を見つけるための判定。
///
/// v0.0.00135以前の`pasteImage()`はペーストボードの`NSImage`だけを見ていた。
/// FinderでファイルをコピーするとペーストボードにはファイルURLに加えてアイコン画像も載るため、
/// 動画やPDF等を貼り付けると1024×1024の汎用アイコンがライブラリへ登録されていた。
/// 貼り付け側は修正済みだが、**すでに登録されてしまった項目は残る**ため、
/// 後から見つけて整理できるようにする。
///
/// 判定は「消してよいか」をユーザーへ確認するための**候補の絞り込み**であり、
/// これ単独で削除の根拠にはしない（誤検出を完全には避けられないため）。
public enum PastedIconImageDetector {
    /// アイコンとして配られる代表的な正方形サイズ（px）。
    public static let iconSideCandidates: Set<Int> = [128, 256, 512, 1024]

    /// 貼り付け経由で取り込まれた項目の名前の接頭辞。
    public static let clipboardSourcePrefix = "clipboard_"

    /// 外周の一様性を見る幅（px）。
    static let borderInspectionWidth = 4

    /// 画像を読まずに判定できる範囲での事前絞り込み。
    /// 「貼り付け由来」かつ「アイコンサイズの正方形」の両方を満たすものだけを
    /// 画素検査の対象にする（ライブラリ全件をデコードしないため）。
    public static func isCandidateBySize(sourceName: String, pixelWidth: Int, pixelHeight: Int) -> Bool {
        guard sourceName.hasPrefix(clipboardSourcePrefix) else { return false }
        guard pixelWidth == pixelHeight else { return false }
        return iconCandidateSides.contains(pixelWidth)
    }

    private static var iconCandidateSides: Set<Int> { iconSideCandidates }

    /// 画素を見て「アイコンらしさ」を確定させる。
    ///
    /// アイコンは絵柄が中央に置かれ、外周が透明（または単色）の余白になっている。
    /// 写真・スクリーンショットで外周4pxが完全に一様になることはまれなため、
    /// この一様性を決め手にする。
    public static func hasUniformBorder(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width >= borderInspectionWidth * 3, height >= borderInspectionWidth * 3 else { return false }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { return false }

        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let offset = (y * width + x) * 4
            return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
        }

        let reference = pixel(0, 0)
        for y in 0..<height {
            let isBorderRow = y < borderInspectionWidth || y >= height - borderInspectionWidth
            for x in 0..<width {
                let isBorderColumn = x < borderInspectionWidth || x >= width - borderInspectionWidth
                guard isBorderRow || isBorderColumn else { continue }
                let sample = pixel(x, y)
                // 完全一致ではなく±2の許容を持たせる（PNG再エンコードの丸め対策）
                if abs(Int(sample.0) - Int(reference.0)) > 2
                    || abs(Int(sample.1) - Int(reference.1)) > 2
                    || abs(Int(sample.2) - Int(reference.2)) > 2
                    || abs(Int(sample.3) - Int(reference.3)) > 2 {
                    return false
                }
            }
        }
        return true
    }

    private static func CGColorSpaceDeviceRGB() -> CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }
}
