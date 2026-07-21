import CoreGraphics
import Foundation

public enum ImageDomain: String, Sendable {
    case photo
    case illustration

    public var displayName: String {
        switch self {
        case .photo: return "実写"
        case .illustration: return "イラスト/漫画"
        }
    }
}

/// 実写かイラスト/漫画かを画像統計で簡易判定する軽量分類器。
/// - 白黒漫画: 彩度がほぼゼロ+紙白（高輝度）の割合が高い+テクスチャ的な中間差分が少ない
/// - カラーイラスト: 平坦な塗りが多く（隣接差ほぼ0）、実写特有の中間差分が少ない
/// DETECTION_IMPROVEMENT_PLAN.md §6.1 C の実装。判定ミスはUIの「画像種別」手動指定で上書きできる。
/// 将来アニメ判定モデル（deepghs系等）へ置き換え/併用できるよう独立させている。
public enum DomainClassifier {
    struct Features {
        let flatRatio: Double       // 隣接輝度差<=4 の割合（平坦な塗り・背景）
        let midDiffRatio: Double    // 隣接輝度差8〜32 の割合（実写のテクスチャ・ノイズ帯）
        let whiteRatio: Double      // 輝度>=235 の割合（漫画の紙白）
        let saturationMean: Double  // 彩度平均（max(R,G,B)-min(R,G,B)）
    }

    public static func classify(_ image: CGImage) -> ImageDomain {
        guard let features = features(of: image) else { return .photo }

        // 実質グレースケール（白黒漫画の可能性）: 紙白が多くテクスチャが少なければ漫画。
        // スクリーントーンは縮小で平均化されるため中間差分は輪郭部に限られる。
        if features.saturationMean < 8 {
            if features.whiteRatio >= 0.15 && features.midDiffRatio <= 0.35 {
                return .illustration
            }
        }
        // カラー: 平坦な塗りが支配的で実写テクスチャ帯が少なければイラスト
        if features.flatRatio >= 0.6 && features.midDiffRatio <= 0.25 {
            return .illustration
        }
        return .photo
    }

    static func features(of image: CGImage) -> Features? {
        let size = 64
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = rgba.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(
                data: pointer.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }

        var luma = [Int](repeating: 0, count: size * size)
        var saturationSum = 0
        var whiteCount = 0
        for index in 0..<(size * size) {
            let offset = index * 4
            let red = Int(rgba[offset])
            let green = Int(rgba[offset + 1])
            let blue = Int(rgba[offset + 2])
            let brightness = (red * 299 + green * 587 + blue * 114) / 1000
            luma[index] = brightness
            saturationSum += max(red, max(green, blue)) - min(red, min(green, blue))
            if brightness >= 235 {
                whiteCount += 1
            }
        }

        var flatCount = 0
        var midCount = 0
        var diffTotal = 0
        for y in 0..<size {
            for x in 0..<(size - 1) {
                let difference = abs(luma[y * size + x] - luma[y * size + x + 1])
                if difference <= 4 {
                    flatCount += 1
                } else if difference >= 8 && difference <= 32 {
                    midCount += 1
                }
                diffTotal += 1
            }
        }
        guard diffTotal > 0 else { return nil }
        let pixelCount = Double(size * size)
        return Features(
            flatRatio: Double(flatCount) / Double(diffTotal),
            midDiffRatio: Double(midCount) / Double(diffTotal),
            whiteRatio: Double(whiteCount) / pixelCount,
            saturationMean: Double(saturationSum) / pixelCount
        )
    }
}
