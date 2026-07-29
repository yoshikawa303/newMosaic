import CoreGraphics
import Foundation
import Testing
@testable import MosaicCore

/// 学習済み部位セグメンテーションモデル（YOLO-seg）の出力デコードを、
/// 既知の合成テンソルで検証する。モデル本体が無くてもデコード経路の正しさを固定できる。
@Suite struct PartSegmentationTests {
    /// `output0` を属性メジャー `(4 + クラス数 + マスク係数, アンカー数)` で組み立てる
    private func makeBoxOutput(
        classCount: Int,
        maskCount: Int,
        anchors: [(cx: Float, cy: Float, w: Float, h: Float, cls: Int, score: Float, coefficients: [Float])],
        inputSize: Int
    ) -> [Float] {
        let attributes = 4 + classCount + maskCount
        var output = [Float](repeating: 0, count: attributes * anchors.count)
        for (index, anchor) in anchors.enumerated() {
            output[0 * anchors.count + index] = anchor.cx * Float(inputSize)
            output[1 * anchors.count + index] = anchor.cy * Float(inputSize)
            output[2 * anchors.count + index] = anchor.w * Float(inputSize)
            output[3 * anchors.count + index] = anchor.h * Float(inputSize)
            output[(4 + anchor.cls) * anchors.count + index] = anchor.score
            for (offset, value) in anchor.coefficients.enumerated() {
                output[(4 + classCount + offset) * anchors.count + index] = value
            }
        }
        return output
    }

    @Test func decodeExtractsBoxScoreClassAndMaskCoefficients() throws {
        let classCount = 3
        let maskCount = 4
        let inputSize = 640
        let coefficients: [Float] = [0.5, -0.25, 1.0, 0.0]
        let output = makeBoxOutput(
            classCount: classCount,
            maskCount: maskCount,
            anchors: [(cx: 0.5, cy: 0.25, w: 0.2, h: 0.1, cls: 1, score: 0.9, coefficients: coefficients)],
            inputSize: inputSize
        )

        let detections = YOLOSegDecoder.decode(
            output: output,
            classCount: classCount,
            maskCount: maskCount,
            confidenceThreshold: 0.3,
            inputSize: inputSize
        )
        #expect(detections.count == 1)
        let detection = try #require(detections.first)
        #expect(detection.classIndex == 1)
        #expect(abs(detection.score - 0.9) < 0.001)
        #expect(abs(detection.rect.x - 0.4) < 0.001)
        #expect(abs(detection.rect.y - 0.2) < 0.001)
        #expect(abs(detection.rect.width - 0.2) < 0.001)
        #expect(abs(detection.rect.height - 0.1) < 0.001)
        #expect(detection.maskCoefficients == coefficients)
    }

    /// マスク係数がクラススコアの領域とずれて読まれていないこと。
    /// （属性メジャー配列のオフセットを1つ間違えると、無関係な値がマスクへ入り形状が壊れる）
    @Test func decodeReadsCoefficientsAfterClassScores() throws {
        let classCount = 3
        let maskCount = 2
        // クラススコアは全て0.8、係数は識別しやすい値にする
        var anchors: [(cx: Float, cy: Float, w: Float, h: Float, cls: Int, score: Float, coefficients: [Float])] = []
        anchors.append((cx: 0.5, cy: 0.5, w: 0.4, h: 0.4, cls: 2, score: 0.8, coefficients: [7.0, -7.0]))
        let output = makeBoxOutput(classCount: classCount, maskCount: maskCount, anchors: anchors, inputSize: 640)

        let detection = try #require(YOLOSegDecoder.decode(
            output: output, classCount: classCount, maskCount: maskCount,
            confidenceThreshold: 0.3, inputSize: 640
        ).first)
        #expect(detection.classIndex == 2)
        #expect(detection.maskCoefficients == [7.0, -7.0])
    }

    /// 検出専用モデル（マスク係数なし）を誤って渡した場合、要素数が合わず空を返すこと。
    /// 実行時クラッシュではなくフォールバックへ倒すための担保。
    @Test func decodeReturnsEmptyWhenOutputShapeDoesNotMatch() {
        let output = [Float](repeating: 0.5, count: 7 * 100) // 4+3クラス（係数なし）
        let detections = YOLOSegDecoder.decode(
            output: output, classCount: 3, maskCount: 32,
            confidenceThreshold: 0.3, inputSize: 640
        )
        #expect(detections.isEmpty)
    }

    /// プロトタイプ合成が枠の内側だけを塗り、枠の外は0のままであること。
    /// （枠外を残すと他の部位のマスクが混ざる）
    @Test func maskPixelsFillOnlyInsideDetectionBox() throws {
        let side = 40
        let maskCount = 1
        // プロトタイプ全面を正の大きな値にする → sigmoid はどこでも1に近い
        let prototypes = [Float](repeating: 5.0, count: maskCount * side * side)
        let rect = NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

        let pixels = try #require(YOLOSegDecoder.maskPixels(
            coefficients: [1.0],
            prototypes: prototypes,
            maskCount: maskCount,
            width: side,
            height: side,
            rect: rect
        ))
        #expect(pixels.count == side * side)
        // 枠の中心は塗られる
        #expect(pixels[(side / 2) * side + (side / 2)] == 255)
        // 四隅（枠の外）は塗られない
        #expect(pixels[0] == 0)
        #expect(pixels[side - 1] == 0)
        #expect(pixels[(side - 1) * side] == 0)
        #expect(pixels[side * side - 1] == 0)
    }

    /// 係数が負なら sigmoid がしきい値未満になり、枠内でも塗られないこと。
    @Test func maskPixelsRespectSigmoidThreshold() throws {
        let side = 20
        let prototypes = [Float](repeating: 5.0, count: side * side)
        let pixels = try #require(YOLOSegDecoder.maskPixels(
            coefficients: [-1.0],
            prototypes: prototypes,
            maskCount: 1,
            width: side,
            height: side,
            rect: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        ))
        #expect(pixels.allSatisfy { $0 == 0 })
    }

    @Test func maskPixelsReturnsNilOnInsufficientPrototypeData() {
        #expect(YOLOSegDecoder.maskPixels(
            coefficients: [1.0],
            prototypes: [Float](repeating: 1, count: 10),
            maskCount: 1,
            width: 20,
            height: 20,
            rect: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        ) == nil)
    }

    /// レターボックスのパディングを取り除いて元画像サイズへ戻す変換。
    /// 横長画像では上下にパディングが入るため、その分を切り落とさないとマスクが縦にずれる。
    @Test func imageSpaceMaskRemovesLetterboxPadding() throws {
        let inputSize = 64
        let protoSide = inputSize / 4 // 16
        // 横長画像(200x100)を64x64へレターボックス → 内容は64x32、上下に16ずつパディング
        let letterbox = LetterboxTransform(padX: 0, padY: 16, contentWidth: 64, contentHeight: 32)

        // プロトタイプ空間で、内容領域の上半分だけを白にする
        var pixels = [UInt8](repeating: 0, count: protoSide * protoSide)
        let contentTop = 4      // padY(16) * 16/64
        let contentHeight = 8   // contentHeight(32) * 16/64
        for y in contentTop..<(contentTop + contentHeight / 2) {
            for x in 0..<protoSide { pixels[y * protoSide + x] = 255 }
        }

        let mask = try #require(PartSegmentationDetector.imageSpaceMask(
            protoPixels: pixels,
            protoSide: protoSide,
            letterbox: letterbox,
            inputSize: inputSize,
            imageWidth: 200,
            imageHeight: 100
        ))
        #expect(mask.width == 200)
        #expect(mask.height == 100)

        // 元画像座標で読み出す（CGImageは行0=上）
        var buffer = [UInt8](repeating: 0, count: 200 * 100)
        let context = try #require(CGContext(
            data: &buffer, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 200,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.draw(mask, in: CGRect(x: 0, y: 0, width: 200, height: 100))
        // 上部（内容領域の上半分）は白、下部は黒になる
        #expect(buffer[10 * 200 + 100] > 200)
        #expect(buffer[90 * 200 + 100] < 60)
    }

    /// モデル未導入時は例外を投げず、`ShapeSegmentEngine` へフォールバックすること。
    /// 既存の運用（モデルを入れていないユーザー）を壊さないための担保。
    @Test func learnedShapeEngineFallsBackWhenModelMissing() throws {
        // テスト環境にはモデルを置かないため未導入状態になる
        guard !PartSegmentationDetector.isAvailable else { return }
        let engine = LearnedShapeSegmentEngine()
        let context = try #require(CGContext(
            data: nil, width: 120, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        let image = try #require(context.makeImage())
        let roi = MosaicROI(
            rect: NormalizedRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4),
            confidence: 0.9,
            source: "test",
            shape: .ellipse,
            category: .maleGenital
        )
        let extent = CGRect(x: 0, y: 0, width: 120, height: 120)
        let masks = try engine.createMasks(for: [roi], in: image, extent: extent)
        #expect(masks.count == 1)
        #expect(masks[0].extent.width > 0)
    }

    /// 学習モデルのクラス順が同梱検出モデルと同じ並びであること。
    /// （学習データ書き出しを流用するため、ここがずれるとカテゴリが入れ替わる）
    @Test func learnedModelClassOrderMatchesBundledDetector() {
        #expect(PartSegmentationDetector.classCategories == [.nipple, .maleGenital, .femaleGenital])
    }
}

/// 形状モデル学習用データセット書き出し（YOLO-seg形式）の検証。
@Suite struct YOLOSegDatasetExportTests {
    /// 多角形ROIは頂点がそのまま輪郭になること。
    @Test func polygonROIExportsItsOwnVertices() {
        let roi = MosaicROI(
            rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            confidence: 1, source: "manual", shape: .polygon, category: .maleGenital,
            polygonPoints: [
                NormalizedPoint(x: 0, y: 0),
                NormalizedPoint(x: 1, y: 0),
                NormalizedPoint(x: 0.5, y: 1)
            ]
        )
        let points = YOLOSegDatasetExporter.outlinePoints(for: roi, imageSize: CGSize(width: 100, height: 100))
        #expect(points.count == 3)
        #expect(abs(points[0].x - 0.25) < 0.001)
        #expect(abs(points[0].y - 0.25) < 0.001)
        #expect(abs(points[1].x - 0.75) < 0.001)
        #expect(abs(points[2].x - 0.5) < 0.001)
        #expect(abs(points[2].y - 0.75) < 0.001)
    }

    /// 回転は画素空間で行うこと。正規化空間のまま回すと非正方形画像で形が歪む。
    @Test func rotationIsAppliedInPixelSpaceForNonSquareImages() {
        let roi = MosaicROI(
            rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            confidence: 1, source: "manual", shape: .rectangle, category: .nipple,
            rotation: 90
        )
        // 200x100の画像。ROIは画素空間で100x50の矩形 → 90度回転で50x100になる
        let points = YOLOSegDatasetExporter.outlinePoints(for: roi, imageSize: CGSize(width: 200, height: 100))
        let xs = points.map { $0.x * 200 }
        let ys = points.map { $0.y * 100 }
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        #expect(abs(width - 50) < 1.0)
        #expect(abs(height - 100) < 1.0)
    }

    /// 楕円ROIは多角形へ近似されること（既定では書き出し対象外だが、近似自体は正しく行う）。
    @Test func ellipseROIIsApproximatedByPolygon() {
        let roi = MosaicROI(
            rect: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            confidence: 1, source: "auto", shape: .ellipse, category: .femaleGenital
        )
        let points = YOLOSegDatasetExporter.outlinePoints(for: roi, imageSize: CGSize(width: 100, height: 100))
        #expect(points.count == YOLOSegDatasetExporter.ellipseApproximationVertices)
        // すべて単位円の内側（中心0.5・半径0.5）に乗る
        for point in points {
            let distance = ((point.x - 0.5) * (point.x - 0.5) + (point.y - 0.5) * (point.y - 0.5)).squareRoot()
            #expect(abs(distance - 0.5) < 0.01)
        }
    }

    /// 書き出しクラス順が実行側のモデルのクラス順と一致すること。
    /// ずれると学習済みモデルのカテゴリが入れ替わる。
    @Test func exportClassOrderMatchesRuntimeModel() {
        #expect(PartSegmentationDetector.classCategories == [.nipple, .maleGenital, .femaleGenital])
    }
}
