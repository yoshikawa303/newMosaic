import CoreGraphics
import Foundation

/// ライブラリのアノテーション（元画像+保存済みROI）をYOLO形式の学習データセットとして書き出す。
/// 完全ローカル処理。DETECTION_IMPROVEMENT_PLAN.md §6.1 B（自前ファインチューニング）の準備で、
/// 普段のモザイク作業の成果物をそのまま漫画・アニメ・実写の教師データにする。
public enum YOLODatasetExporter {
    public struct ExportResult: Sendable {
        public let imageCount: Int
        public let roiCount: Int
    }

    /// - Parameters:
    ///   - items: エクスポート対象のライブラリアイテム（ROIが空のものはスキップ）
    ///   - libraryEngine: 元画像PNGの取得元
    ///   - destination: 出力先フォルダ。`images/` `labels/` `classes.txt` `dataset.yaml` を作成する
    @discardableResult
    public static func export(
        items: [MosaicLibraryItem],
        libraryEngine: LibraryEngine,
        to destination: URL
    ) throws -> ExportResult {
        let imagesURL = destination.appendingPathComponent("images")
        let labelsURL = destination.appendingPathComponent("labels")
        try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: labelsURL, withIntermediateDirectories: true)

        let classNames = MosaicTargetCategory.allCases.map(\.rawValue)
        var imageCount = 0
        var roiCount = 0

        for item in items where !item.rois.isEmpty {
            let sourceURL = libraryEngine.originalURL(for: item)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }

            var lines: [String] = []
            for roi in item.rois {
                let rect = roi.rect.clamped()
                guard rect.width > 0, rect.height > 0,
                      let classIndex = MosaicTargetCategory.allCases.firstIndex(of: roi.category) else { continue }
                // YOLO形式: class cx cy w h（画像正規化・左上原点基準の中心座標）
                let centerX = rect.x + rect.width / 2
                let centerY = rect.y + rect.height / 2
                lines.append(String(format: "%d %.6f %.6f %.6f %.6f", classIndex, centerX, centerY, rect.width, rect.height))
            }
            guard !lines.isEmpty else { continue }

            let baseName = item.id.uuidString
            let imageDestination = imagesURL.appendingPathComponent("\(baseName).png")
            if FileManager.default.fileExists(atPath: imageDestination.path) {
                try FileManager.default.removeItem(at: imageDestination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: imageDestination)
            try lines.joined(separator: "\n").write(
                to: labelsURL.appendingPathComponent("\(baseName).txt"),
                atomically: true,
                encoding: .utf8
            )
            imageCount += 1
            roiCount += lines.count
        }

        try classNames.joined(separator: "\n").write(
            to: destination.appendingPathComponent("classes.txt"),
            atomically: true,
            encoding: .utf8
        )
        let yaml = """
        # newMosaic YOLOデータセット（ローカル学習用）
        # images/: 元画像PNG, labels/: 1行= class cx cy w h（正規化座標）
        path: .
        train: images
        val: images
        names:
        \(classNames.enumerated().map { "  \($0.offset): \($0.element)" }.joined(separator: "\n"))
        """
        try yaml.write(to: destination.appendingPathComponent("dataset.yaml"), atomically: true, encoding: .utf8)

        return ExportResult(imageCount: imageCount, roiCount: roiCount)
    }
}
