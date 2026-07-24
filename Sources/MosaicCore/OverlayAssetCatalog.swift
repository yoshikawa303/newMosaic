import CoreGraphics
import Foundation
import ImageIO

/// 同梱のかぶせ画像素材（SNS向けアクセサリ）。
public struct OverlayAsset: Sendable {
    /// パターン画像識別子（`builtin:` プレフィックス付き。ROIスタイルへ保存される）
    public let identifier: String
    public let resourceName: String
    public let displayName: String
    /// 想定する貼り付け先カテゴリ（目元/眼窩下）
    public let suggestedCategory: MosaicTargetCategory
}

/// 同梱かぶせ画像素材のカタログ。素材はすべてCoreGraphicsベクター描画による自前生成
/// （scripts/generate_overlay_assets.swift。外部素材の取り込みなし）。
/// リムーバブルボリューム許可ダイアログを避けるため、モデルと同様に初回のみ内蔵ディスクへキャッシュする。
public enum OverlayAssetCatalog {
    public static let identifierPrefix = "builtin:"

    public static let assets: [OverlayAsset] = [
        OverlayAsset(
            identifier: "builtin:sunglasses_black",
            resourceName: "sunglasses_black",
            displayName: "サングラス（黒）",
            suggestedCategory: .eyes
        ),
        OverlayAsset(
            identifier: "builtin:sunglasses_heart",
            resourceName: "sunglasses_heart",
            displayName: "ハートサングラス",
            suggestedCategory: .eyes
        ),
        OverlayAsset(
            identifier: "builtin:party_mask",
            resourceName: "party_mask",
            displayName: "パーティーマスク",
            suggestedCategory: .eyes
        ),
        OverlayAsset(
            identifier: "builtin:medical_mask",
            resourceName: "medical_mask",
            displayName: "医療マスク",
            suggestedCategory: .lowerFace
        ),
        OverlayAsset(
            identifier: "builtin:gas_mask",
            resourceName: "gas_mask",
            displayName: "ガスマスク",
            suggestedCategory: .lowerFace
        ),
        OverlayAsset(
            identifier: "builtin:dog_nose",
            resourceName: "dog_nose",
            displayName: "犬の鼻口",
            suggestedCategory: .lowerFace
        )
    ]

    /// `builtin:` 識別子から素材画像を読み込む（該当なしはnil）。
    public static func image(for identifier: String) -> CGImage? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        let name = String(identifier.dropFirst(identifierPrefix.count))
        guard assets.contains(where: { $0.resourceName == name }),
              let url = try? cachedAssetURL(resourceName: name),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image
    }

    /// 同梱素材を内蔵ディスク（Application Support/newMosaic/Overlays）へ初回のみコピーしてURLを返す。
    /// アプリ本体がリムーバブルボリューム上にある場合の許可ダイアログ対策（モデルキャッシュと同方式）。
    static func cachedAssetURL(resourceName: String) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("newMosaic/Overlays")
        let cached = directory.appendingPathComponent("\(resourceName).png")
        let markerKey = "OverlayAssetCache.\(resourceName).v1"

        if UserDefaults.standard.bool(forKey: markerKey), FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        guard let bundled = Bundle.module.url(
            forResource: resourceName,
            withExtension: "png",
            subdirectory: "Overlays"
        ) else {
            if FileManager.default.fileExists(atPath: cached.path) {
                return cached
            }
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "同梱素材（\(resourceName).png）が見つかりません"
            ])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: cached.path) {
            try FileManager.default.removeItem(at: cached)
        }
        try FileManager.default.copyItem(at: bundled, to: cached)
        UserDefaults.standard.set(true, forKey: markerKey)
        return cached
    }
}
