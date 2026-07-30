import CoreGraphics
import Foundation
import OSLog

/// 人物シルエット（人物レイヤの青い範囲・人物由来ROIのマスク）を得る経路をまとめたもの。
///
/// アプリとテストで同じ経路を通せるようにコア側へ集約している。
/// 以前はアプリ側（main.swift）に直接書かれており、実画像での品質を測定できなかった。
///
/// 経路は次の順で、得られたマスクが人物枠を塗り潰していないか毎回確認する:
/// 1. `AnimeSegmenter.personMaskByCrop`（人物枠をクロップして推論）
/// 2. `SAMSegmentEngine.instanceMask`（枠プロンプト。インスタンスを取れる）
/// 3. `AnimeSegmenter.characterMask` の全体画像推論を人物枠で切り出す
public final class PersonSilhouetteProvider {
    /// 採用できるマスクが人物枠内を占める割合の上限。
    ///
    /// `anime_seg.onnx` は「キャラクターか背景か」の二値分類でインスタンス分離をしないため、
    /// 寝具や小物の多いコマでは人物枠をほぼ塗り潰す（実サンプル実測で0.96/0.97）。
    /// この状態は「人物の形に沿っていない」ので、次の経路へ切り替える。
    ///
    /// 注意: 以前は `personMaskByCrop` 内でクロップ（枠の1.08倍）に対する割合を0.92で見ていたため、
    /// 枠に対して0.96でもクロップ比では0.82程度にしかならず、判定が働いていなかった。
    /// ここでは**人物枠に対する割合**で判定する。
    public static let maximumUsableCoverage = 0.90

    public enum Source: String, Sendable {
        case crop
        case sam
        case wholeImage
        case none
    }

    private let segmenter: AnimeSegmenter
    private let sam = SAMSegmentEngine()
    private let logger = Logger(subsystem: "com.yoshikawa.newMosaic", category: "Detection")
    /// 全体画像推論は重いので1枚につき1回だけ実行して使い回す（二重Optionalで「未計算」と「失敗」を区別）
    private var wholeImageMask: CGImage??

    public init(segmenter: AnimeSegmenter) {
        self.segmenter = segmenter
    }

    /// 人物枠に対応するシルエットマスク（元画像サイズ）と、どの経路で得たかを返す。
    @discardableResult
    public func silhouette(
        in image: CGImage,
        bounds: NormalizedRect
    ) -> (mask: CGImage?, source: Source, coverage: Double) {
        if let mask = (try? segmenter.personMaskByCrop(in: image, bounds: bounds)) ?? nil {
            let coverage = Self.coverage(of: mask, within: bounds)
            if coverage <= Self.maximumUsableCoverage {
                log(bounds: bounds, source: .crop, coverage: coverage)
                return (mask, .crop, coverage)
            }
            logger.info("personSilhouette rejected=crop coverage=\(String(format: "%.2f", coverage), privacy: .public)")
        }

        if let mask = sam.instanceMask(in: image, box: bounds) {
            let coverage = Self.coverage(of: mask, within: bounds)
            if coverage <= Self.maximumUsableCoverage {
                log(bounds: bounds, source: .sam, coverage: coverage)
                return (mask, .sam, coverage)
            }
            logger.info("personSilhouette rejected=sam coverage=\(String(format: "%.2f", coverage), privacy: .public)")
        }

        if wholeImageMask == nil {
            wholeImageMask = .some(try? segmenter.characterMask(in: image))
        }
        if let full = wholeImageMask ?? nil,
           let mask = AnimeSegmenter.personMask(
               fullMask: full,
               bounds: bounds,
               imageSize: CGSize(width: image.width, height: image.height)
           ) {
            let coverage = Self.coverage(of: mask, within: bounds)
            log(bounds: bounds, source: .wholeImage, coverage: coverage)
            return (mask, .wholeImage, coverage)
        }

        log(bounds: bounds, source: .none, coverage: 0)
        return (nil, .none, 0)
    }

    private func log(bounds: NormalizedRect, source: Source, coverage: Double) {
        logger.info("""
            personSilhouette source=\(source.rawValue, privacy: .public) \
            coverage=\(String(format: "%.2f", coverage), privacy: .public) \
            boundsArea=\(String(format: "%.4f", bounds.area), privacy: .public)
            """)
    }

    /// マスクのうち、人物枠の内側で白（対象）になっている画素の割合。
    /// `AnimeSegmenter.coverageRatio` は画像全体に対する比率なので、
    /// 「人物枠を塗り潰しているか」の判定には使えない。
    public static func coverage(of mask: CGImage, within bounds: NormalizedRect) -> Double {
        let rect = bounds.clamped().cgRect(
            imageSize: CGSize(width: mask.width, height: mask.height),
            origin: .topLeft
        )
        guard rect.width >= 1, rect.height >= 1, let crop = mask.cropping(to: rect) else { return 0 }
        let width = crop.width
        let height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(
                data: pointer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, !pixels.isEmpty else { return 0 }
        return Double(pixels.reduce(0) { $0 + ($1 > 127 ? 1 : 0) }) / Double(pixels.count)
    }
}
