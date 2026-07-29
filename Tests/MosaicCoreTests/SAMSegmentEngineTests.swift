import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import MosaicCore

/// 同梱MobileSAMによる形状抽出の実機検証。実際のONNXモデルで推論まで通す。
/// AVFoundation系と同様、重い推論を含むため直列実行にする。
@Suite(.serialized) struct SAMSegmentEngineTests {
    /// 漫画の作画慣行を模した合成画像:
    /// 白地+輪郭線で囲まれた有機的な形（内部はほぼ白・軽い陰影線）、周囲に効果線・しずくのクラッタ。
    /// Python(onnxruntime)での事前検証と同条件（IoU 0.99が出た構図）。
    private func makeMangaLikeImage(size: Int = 640) throws -> (image: CGImage, targetPath: CGPath) {
        let context = try #require(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // CGContextは下原点のため、Python版（上原点）とはy軸が反転するが、検証には影響しない
        context.setFillColor(CGColor(red: 0.98, green: 0.97, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setStrokeColor(CGColor(gray: 0.15, alpha: 1))
        context.setLineWidth(2)
        // クラッタ: 効果線としずく
        for x in stride(from: 30, to: 200, by: 12) {
            context.beginPath()
            context.move(to: CGPoint(x: x, y: size - 30))
            context.addLine(to: CGPoint(x: x - 15, y: size - 140))
            context.strokePath()
        }
        for center in [CGPoint(x: 520, y: size - 80), CGPoint(x: 560, y: size - 130)] {
            context.strokeEllipse(in: CGRect(x: center.x - 8, y: center.y - 12, width: 16, height: 24))
        }
        // 肌領域（対象より広い薄い色）
        context.setFillColor(CGColor(red: 0.96, green: 0.94, blue: 0.92, alpha: 1))
        context.fill(CGRect(x: 200, y: size - 470, width: 260, height: 290))
        // 対象: 輪郭線で囲まれた有機的な形（Python版と同じ頂点。yは下原点へ変換）
        let bodyTopLeft: [(Double, Double)] = [
            (300, 200), (340, 210), (360, 260), (355, 330), (365, 400),
            (330, 440), (300, 445), (280, 400), (285, 320), (275, 260)
        ]
        let path = CGMutablePath()
        for (index, point) in bodyTopLeft.enumerated() {
            let converted = CGPoint(x: point.0, y: Double(size) - point.1)
            if index == 0 { path.move(to: converted) } else { path.addLine(to: converted) }
        }
        path.closeSubpath()
        context.setFillColor(CGColor(red: 0.93, green: 0.89, blue: 0.87, alpha: 1))
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(CGColor(gray: 0.12, alpha: 1))
        context.setLineWidth(3)
        context.addPath(path)
        context.strokePath()
        // 内部の軽い陰影線
        context.setStrokeColor(CGColor(gray: 0.55, alpha: 1))
        context.setLineWidth(1)
        for y in stride(from: 260, to: 420, by: 18) {
            context.beginPath()
            context.move(to: CGPoint(x: 292, y: Double(size) - Double(y)))
            context.addLine(to: CGPoint(x: 350, y: Double(size) - Double(y) - 6))
            context.strokePath()
        }
        return (try #require(context.makeImage()), path)
    }

    /// 検出枠（少し大きめ・ずれあり=現実の検出誤差想定）から、対象の形状に沿うマスクが出ること。
    /// 枠を塗るだけの現状方式より大幅に良い（Python事前検証: SAM 0.989 vs 枠塗り 0.556）。
    @Test func samMaskFollowsOutlinedShapeFromDetectionBox() throws {
        let (image, targetPath) = try makeMangaLikeImage()
        let size = 640
        // ROI: 対象(x 275-365, y_topLeft 200-445)より大きめ+ずらした枠
        let roi = MosaicROI(
            rect: NormalizedRect(x: 265.0 / 640, y: 190.0 / 640, width: 115.0 / 640, height: 265.0 / 640),
            confidence: 0.9,
            source: "anime-censor",
            shape: .ellipse,
            category: .maleGenital
        )
        let extent = CGRect(x: 0, y: 0, width: size, height: size)
        let engine = SAMSegmentEngine()
        let masks = try engine.createMasks(for: [roi], in: image, extent: extent)
        #expect(masks.count == 1)

        // マスクをラスタ化して、対象形状とのIoUを実測する
        let ciContext = CIContext(options: [.cacheIntermediates: false])
        let rendered = try #require(ciContext.createCGImage(masks[0], from: extent))
        var maskPixels = [UInt8](repeating: 0, count: size * size)
        let grayContext = try #require(CGContext(
            data: &maskPixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        grayContext.draw(rendered, in: extent)

        // 正解形状をラスタ化（同じ下原点座標系で描画してあるため、そのまま比較できる）
        var gtPixels = [UInt8](repeating: 0, count: size * size)
        let gtContext = try #require(CGContext(
            data: &gtPixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        gtContext.setFillColor(CGColor(gray: 1, alpha: 1))
        gtContext.addPath(targetPath)
        gtContext.fillPath()

        var intersection = 0
        var union = 0
        var maskArea = 0
        for index in 0..<maskPixels.count {
            let inMask = maskPixels[index] > 127
            let inTarget = gtPixels[index] > 127
            if inMask { maskArea += 1 }
            if inMask && inTarget { intersection += 1 }
            if inMask || inTarget { union += 1 }
        }
        let iou = union > 0 ? Double(intersection) / Double(union) : 0
        // 枠塗り（0.556）を大きく超え、形状に沿っていること
        #expect(iou > 0.8, "IoU=\(iou) maskArea=\(maskArea)")
    }

    /// 埋め込みキャッシュ: 同じ画像での2回目のマスク生成が大幅に速いこと（エンコーダ再実行なし）。
    @Test func embeddingCacheAvoidsReencoding() throws {
        let (image, _) = try makeMangaLikeImage()
        let roi = MosaicROI(
            rect: NormalizedRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4),
            confidence: 0.9, source: "test", category: .femaleGenital
        )
        let extent = CGRect(x: 0, y: 0, width: 640, height: 640)
        let engine = SAMSegmentEngine()
        let start1 = Date()
        _ = try engine.createMasks(for: [roi], in: image, extent: extent)
        let first = Date().timeIntervalSince(start1)
        let start2 = Date()
        _ = try engine.createMasks(for: [roi], in: image, extent: extent)
        let second = Date().timeIntervalSince(start2)
        // 2回目はエンコーダ（支配的コスト）を飛ばすため、初回より十分速い
        #expect(second < first * 0.7, "first=\(first)s second=\(second)s")
    }
}
