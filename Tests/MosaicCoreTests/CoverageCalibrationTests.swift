import CoreImage
import CoreGraphics
import Testing
@testable import MosaicCore

/// 被覆率の測定色空間としきい値の対応関係を実測で固定する。
///
/// 初期実装は被覆率をsRGB（ガンマあり）で読み、しきい値0.85で「前景が全面すぎる」と
/// 判定して顕著領域マスクへ切り替えていた。v0.0.00093でこの測定をリニアへ直したが、
/// しきい値0.85はsRGB基準のまま据え置かれたため、切り替えが起きる実面積比が
/// 0.69→0.85へ大きく上がってしまった。この差が「初期実装・比較用でも品質がおかしい」の
/// 原因であることを、数値として固定しておく。
@Suite struct CoverageCalibrationTests {
    /// 指定した面積比だけ白い二値マスクを作る（上からの行数で面積比を作る）
    private func mask(whiteRatio: Double, size: Int = 100) throws -> CIImage {
        let whiteRows = Int((Double(size) * whiteRatio).rounded())
        let context = try #require(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: whiteRows))
        return CIImage(cgImage: try #require(context.makeImage()))
    }

    /// sRGBで読み出した被覆率（初期実装の測定方法を再現する）
    private func srgbCoverage(of mask: CIImage) -> Double {
        let average = mask.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: mask.extent)
        ])
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.cacheIntermediates: false]).render(
            average, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return Double(pixel[0]) / 255.0
    }

    /// 実測ログに現れた面積比（0.80 / 0.83）は、初期実装のsRGB測定では
    /// しきい値0.85を超えて顕著領域マスクへ切り替わっていたことを示す。
    @Test func srgbCoverageExceedsLegacyThresholdWhereLinearDoesNot() throws {
        let engine = RegionForegroundSegmentEngine()
        for ratio in [0.80, 0.83] {
            let sample = try mask(whiteRatio: ratio)
            let linear = engine.coverageRatio(of: sample)
            let srgb = srgbCoverage(of: sample)
            // リニア測定は実面積比そのもの
            #expect(abs(linear - ratio) < 0.02)
            // 同じマスクがsRGB測定では0.85超に見える＝初期実装は顕著領域へ切り替えていた
            #expect(srgb > 0.85)
            #expect(srgb > linear)
        }
    }

    /// しきい値0.85（sRGB基準）に相当する実面積比はおよそ0.69である。
    /// リニア測定へ移行した際、この換算をしないと切替が起きる条件が大きく変わる。
    @Test func legacyThresholdCorrespondsToAboutSeventyPercentLinearArea() throws {
        let engine = RegionForegroundSegmentEngine()
        let justBelow = try mask(whiteRatio: 0.66)
        let justAbove = try mask(whiteRatio: 0.72)
        #expect(srgbCoverage(of: justBelow) < 0.85)
        #expect(srgbCoverage(of: justAbove) > 0.85)
        // リニア測定では両者とも0.85未満＝初期実装なら切り替わっていた領域が切り替わらない
        #expect(engine.coverageRatio(of: justBelow) < 0.85)
        #expect(engine.coverageRatio(of: justAbove) < 0.85)
    }
}
