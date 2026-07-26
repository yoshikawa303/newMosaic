import Foundation
import CoreGraphics
import Testing
@testable import MosaicCore

private func makeMask(width: Int, height: Int, whiteRowRange: Range<Int>, whiteColRange: Range<Int>) -> CGImage? {
    var pixels = [UInt8](repeating: 0, count: width * height)
    for y in whiteRowRange {
        for x in whiteColRange { pixels[y * width + x] = 255 }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                   bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

private func pixelValue(_ image: CGImage, x: Int, y: Int) -> UInt8 {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height)
    pixels.withUnsafeMutableBytes { ptr in
        guard let ctx = CGContext(data: ptr.baseAddress, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return pixels[y * width + x]
}

// personMaskが「上原点正規化boundsの位置をそのまま保ち、bounds外を黒くする」ことの回帰テスト。
// 人物マスクの上下反転報告（v80/v81）の切り分けで、マスク合成ロジック自体は正しいことを
// 実測確定した際のテストを恒久化したもの（真因は表示側のrespectFlipped未指定だった）。
@Test func personMaskKeepsContentInPlaceAndRestrictsToBounds() throws {
    // fullMask: 100x100、白領域は「上端」（raster行0〜19、列0〜19）
    let fullMask = try #require(makeMask(width: 100, height: 100, whiteRowRange: 0..<20, whiteColRange: 0..<20))
    // 上端白が正しく上端にあるか確認（前提確認）
    #expect(pixelValue(fullMask, x: 10, y: 10) > 200)
    #expect(pixelValue(fullMask, x: 10, y: 90) < 50)

    // 人物boundsも「上端」（top-left正規化 y=0..0.2）
    let boundsTop = NormalizedRect(x: 0, y: 0, width: 0.2, height: 0.2)
    let masked = try #require(AnimeSegmenter.personMask(
        fullMask: fullMask, bounds: boundsTop, imageSize: CGSize(width: 100, height: 100)))
    #expect(pixelValue(masked, x: 10, y: 10) > 200)
    #expect(pixelValue(masked, x: 10, y: 90) < 50)

    // 人物boundsが「下端」（y=0.8..1.0）の場合、白は含まれないはず（白は上端のみのため）
    let boundsBottom = NormalizedRect(x: 0, y: 0.8, width: 0.2, height: 0.2)
    let maskedBottom = try #require(AnimeSegmenter.personMask(
        fullMask: fullMask, bounds: boundsBottom, imageSize: CGSize(width: 100, height: 100)))
    #expect(pixelValue(maskedBottom, x: 10, y: 10) < 50)
    #expect(pixelValue(maskedBottom, x: 10, y: 90) < 50)
}
