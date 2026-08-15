import CoreGraphics
import Foundation

/// 連続フレームの輝度差からシーンカット（場面転換）を検出する。
///
/// プラグイン境界: 検出の実体は「縮小グレースケール化した2フレームの平均絶対差」だけで、
/// デコードもROIも扱わない純関数的な処理にしてある。`VideoTrackingCoordinator`から
/// 呼ばれるほか、単体でも使える。
///
/// カット検出が必要な理由: `VNTrackObjectRequest`は前フレームとの見た目の連続性を前提に
/// 追跡するため、カットを跨ぐと追跡は必ず破綻する。破綻しても信頼度が下がらない
/// （別の似た模様へ吸着する）ケースがあり、「見失い」として検出できないことがある。
/// そこで画像側でカットを検出し、その瞬間に検出をやり直して追跡を張り直す。
public struct SceneCutDetector {
    /// 縮小後の一辺（px）。小さいほど高速で、細部の動きに反応しにくくなる。
    public static let sampleSide = 32

    /// 平均絶対差（0.0〜1.0）がこの値を超えたフレームをカットとみなす。
    /// 0.18 は「画面の大部分が入れ替わった」水準で、パン・ズーム・人物の動き程度では
    /// 超えない値として選んでいる（小さすぎると通常の動きでカット誤判定が頻発する）。
    public var threshold: Double

    private var previousSample: [Double]?

    public init(threshold: Double = 0.18) {
        self.threshold = threshold
    }

    /// 直前フレームとの差からカットかどうかを判定する。最初のフレームは常に`false`。
    /// 縮小に失敗した場合も`false`（カット判定を落とす側＝追跡継続へ倒す）。
    public mutating func isSceneCut(_ image: CGImage) -> Bool {
        guard let sample = Self.luminanceSample(image) else { return false }
        defer { previousSample = sample }
        guard let previous = previousSample, previous.count == sample.count, !sample.isEmpty else {
            return false
        }
        var total = 0.0
        for index in sample.indices {
            total += abs(sample[index] - previous[index])
        }
        return (total / Double(sample.count)) > threshold
    }

    /// 追跡を張り直したときなど、比較の基準を明示的に入れ替える。
    public mutating func reset(with image: CGImage? = nil) {
        previousSample = image.flatMap { Self.luminanceSample($0) }
    }

    /// 画像を`sampleSide`四方のグレースケールへ縮小し、0.0〜1.0の輝度配列にする。
    static func luminanceSample(_ image: CGImage) -> [Double]? {
        let side = sampleSide
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = pixels.withUnsafeMutableBytes({ buffer -> CGContext? in
            guard let base = buffer.baseAddress else { return nil }
            return CGContext(
                data: base,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels.map { Double($0) / 255.0 }
    }
}
