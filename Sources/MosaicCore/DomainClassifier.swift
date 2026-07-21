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
/// イラスト・漫画は平坦な塗り・白背景が多く「隣接画素差がほぼ0」の割合が高いのに対し、
/// 実写はテクスチャ・ノイズにより中間的な差分が多い性質を使う。
/// DETECTION_IMPROVEMENT_PLAN.md §6.1 C（ドメイン自動判定）の初期実装で、
/// 将来アニメ判定モデル（deepghs系等）へ置き換え/併用できるよう独立させている。
public enum DomainClassifier {
    /// 64x64グレースケールへ縮小し、水平方向の隣接画素差が4以下の「平坦画素」の割合で判定する。
    public static func classify(_ image: CGImage) -> ImageDomain {
        flatRatio(of: image).map { $0 >= 0.75 ? .illustration : .photo } ?? .photo
    }

    static func flatRatio(of image: CGImage) -> Double? {
        let size = 64
        var buffer = [UInt8](repeating: 0, count: size * size)
        let drawn = buffer.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(
                data: pointer.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }

        var flatCount = 0
        var total = 0
        for y in 0..<size {
            for x in 0..<(size - 1) {
                let difference = abs(Int(buffer[y * size + x]) - Int(buffer[y * size + x + 1]))
                if difference <= 4 {
                    flatCount += 1
                }
                total += 1
            }
        }
        guard total > 0 else { return nil }
        return Double(flatCount) / Double(total)
    }
}
