import CoreGraphics
import CoreImage
import Foundation

/// マスク形状の手描き補正1ストローク。
///
/// 自動生成したマスクが対象からずれたとき、ユーザーがペンで塗って直せるようにするためのもの
/// （ユーザー要望 2026-08-02）。
///
/// **ビットマップではなくストローク（点列）で保持する。** 理由:
/// - 保存データが小さい（ライブラリのJSONへそのまま入れられる）
/// - 座標をROIローカル（0〜1）で持つため、ROIを移動・リサイズしても補正が追従する
/// - 1ストローク単位で取り消せる
public struct ManualMaskStroke: Codable, Equatable, Sendable {
    /// ROIローカル座標（0〜1、左上原点）の点列。
    public var points: [NormalizedPoint]
    /// 筆の太さ。ROIの短辺に対する割合（0〜1）。
    public var width: Double
    /// true=塗る（マスクへ追加）、false=消す（マスクから削る）。
    public var isAdditive: Bool

    public init(points: [NormalizedPoint], width: Double, isAdditive: Bool) {
        self.points = points
        self.width = width
        self.isAdditive = isAdditive
    }
}

/// 手描き補正をマスクへ反映する。
public enum ManualMaskPainter {
    /// 筆の太さの下限・上限（ROI短辺に対する割合）。
    /// 下限が小さすぎると点が描けず、上限が大きすぎると1ストロークでROI全体が埋まる。
    public static let minimumWidth = 0.01
    public static let maximumWidth = 1.0

    /// 生成済みマスクへストロークを反映した結果を返す。
    ///
    /// - Parameters:
    ///   - base: 生成済みのマスク（白=対象）。画像全体サイズ。
    ///   - strokes: ROIローカル座標のストローク
    ///   - roi: 対象のROI（`rect` が描画位置を決める）
    ///   - extent: 画像全体の範囲
    public static func apply(
        strokes: [ManualMaskStroke],
        to base: CIImage,
        roi: MosaicROI,
        extent: CGRect
    ) -> CIImage {
        guard !strokes.isEmpty else { return base }
        let additive = strokes.filter(\.isAdditive)
        let erasing = strokes.filter { !$0.isAdditive }

        var result = base
        // 塗り: 生成マスクとの明るい方を採る（塗った所は必ず対象になる）
        if !additive.isEmpty, let layer = render(strokes: additive, roi: roi, extent: extent) {
            result = layer.applyingFilter("CIMaximumCompositing", parameters: [
                kCIInputBackgroundImageKey: result
            ]).cropped(to: extent)
        }
        // 消し: 消し層を反転して掛ける（消した所は必ず対象外になる）
        if !erasing.isEmpty, let layer = render(strokes: erasing, roi: roi, extent: extent) {
            let inverted = layer.applyingFilter("CIColorInvert", parameters: [:])
            result = result.applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: inverted
            ]).cropped(to: extent)
        }
        return result
    }

    /// ストローク群を、画像全体サイズの白黒レイヤ（白=ストローク）として描く。
    static func render(strokes: [ManualMaskStroke], roi: MosaicROI, extent: CGRect) -> CIImage? {
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0, !strokes.isEmpty else { return nil }
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // ROIローカル(0〜1・左上原点) → 画像座標(CGContextは下原点)
        let rect = roi.rect.clamped().cgRect(imageSize: extent.size, origin: .bottomLeft)
        let shortSide = min(rect.width, rect.height)
        context.setStrokeColor(gray: 1, alpha: 1)
        // 1点ストロークは`fillEllipse`で描くため、塗り色も白にしておく
        // （背景を黒で塗ったときの設定が残っていると何も描かれない）。
        context.setFillColor(gray: 1, alpha: 1)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for stroke in strokes where !stroke.points.isEmpty {
            let lineWidth = max(1, shortSide * min(max(stroke.width, minimumWidth), maximumWidth))
            context.setLineWidth(lineWidth)
            let points = stroke.points.map { point in
                CGPoint(
                    x: rect.minX + point.x * rect.width,
                    // ROIローカルは左上原点、CGContextは下原点なので上下を入れ替える
                    y: rect.minY + (1 - point.y) * rect.height
                )
            }
            if points.count == 1 {
                // 1点だけのストロークは丸を塗る（クリックで点を打てるようにする）
                let radius = lineWidth / 2
                context.fillEllipse(in: CGRect(
                    x: points[0].x - radius, y: points[0].y - radius,
                    width: lineWidth, height: lineWidth
                ))
            } else {
                context.beginPath()
                context.addLines(between: points)
                context.strokePath()
            }
        }
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image).cropped(to: extent)
    }
}
