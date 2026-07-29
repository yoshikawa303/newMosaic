import ImageIO
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


/// ライブラリのアノテーションを **YOLOセグメンテーション（-seg）形式** の学習データとして書き出す。
///
/// 検出（枠）用の `YOLODatasetExporter` と違い、1行が多角形の輪郭になる:
/// `class x1 y1 x2 y2 ... xn yn`（画像正規化・左上原点）。
///
/// 形状モデルを学習させる目的なので、**既定では手で頂点を編集した多角形ROIだけ**を書き出す。
/// 楕円・矩形ROIをそのまま輪郭として与えると「楕円を出力するモデル」が育ってしまい、
/// 形状抽出という目的を達成できないため（`includeApproximatedShapes`で明示的に有効化できる）。
public enum YOLOSegDatasetExporter {
    public struct ExportResult: Sendable {
        public let imageCount: Int
        /// 手描き多角形から書き出した輪郭の数（形状学習に有効なデータ）
        public let polygonCount: Int
        /// 楕円・矩形から近似した輪郭の数（`includeApproximatedShapes`が真のときのみ）
        public let approximatedCount: Int
        /// 形状が無いため除外したROIの数
        public let skippedCount: Int

        public init(imageCount: Int, polygonCount: Int, approximatedCount: Int, skippedCount: Int) {
            self.imageCount = imageCount
            self.polygonCount = polygonCount
            self.approximatedCount = approximatedCount
            self.skippedCount = skippedCount
        }
    }

    /// 楕円を近似する多角形の頂点数。
    static let ellipseApproximationVertices = 24

    @discardableResult
    public static func export(
        items: [MosaicLibraryItem],
        libraryEngine: LibraryEngine,
        to destination: URL,
        includeApproximatedShapes: Bool = false
    ) throws -> ExportResult {
        let imagesURL = destination.appendingPathComponent("images")
        let labelsURL = destination.appendingPathComponent("labels")
        try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: labelsURL, withIntermediateDirectories: true)

        // クラス順はアプリ実行側（`PartSegmentationDetector.classCategories`）と一致させる。
        // ここがずれると学習済みモデルのカテゴリが入れ替わる。
        let classCategories = PartSegmentationDetector.classCategories
        var imageCount = 0
        var polygonCount = 0
        var approximatedCount = 0
        var skippedCount = 0

        for item in items where !item.rois.isEmpty {
            let sourceURL = libraryEngine.originalURL(for: item)
            guard FileManager.default.fileExists(atPath: sourceURL.path),
                  let imageSize = pixelSize(of: sourceURL) else { continue }

            var lines: [String] = []
            for roi in item.rois {
                guard let classIndex = classCategories.firstIndex(of: roi.category) else {
                    skippedCount += 1
                    continue
                }
                let isHandDrawn = roi.shape == .polygon && roi.polygonPoints != nil
                guard isHandDrawn || includeApproximatedShapes else {
                    skippedCount += 1
                    continue
                }
                let points = outlinePoints(for: roi, imageSize: imageSize)
                guard points.count >= 3 else {
                    skippedCount += 1
                    continue
                }
                let coordinates = points
                    .map { String(format: "%.6f %.6f", $0.x, $0.y) }
                    .joined(separator: " ")
                lines.append("\(classIndex) \(coordinates)")
                if isHandDrawn { polygonCount += 1 } else { approximatedCount += 1 }
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
        }

        let classNames = classCategories.map(\.rawValue)
        try classNames.joined(separator: "\n").write(
            to: destination.appendingPathComponent("classes.txt"),
            atomically: true,
            encoding: .utf8
        )
        let yaml = """
        # newMosaic YOLOセグメンテーションデータセット（ローカル学習用）
        # images/: 元画像PNG, labels/: 1行= class x1 y1 x2 y2 ...（正規化・左上原点の多角形）
        path: .
        train: images
        val: images
        names:
        \(classNames.enumerated().map { "  \($0.offset): \($0.element)" }.joined(separator: "\n"))
        """
        try yaml.write(to: destination.appendingPathComponent("dataset.yaml"), atomically: true, encoding: .utf8)

        return ExportResult(
            imageCount: imageCount,
            polygonCount: polygonCount,
            approximatedCount: approximatedCount,
            skippedCount: skippedCount
        )
    }

    /// ROIの輪郭を画像正規化座標（左上原点）の多角形として返す。回転も反映する。
    static func outlinePoints(for roi: MosaicROI, imageSize: CGSize) -> [NormalizedPoint] {
        let rect = roi.rect.clamped()
        guard rect.width > 0, rect.height > 0 else { return [] }

        // ROIローカル座標（0〜1・左上原点）の輪郭を作る
        let local: [NormalizedPoint]
        switch roi.shape {
        case .polygon:
            local = roi.polygonPoints ?? MosaicROI.defaultPolygonPoints
        case .rectangle:
            local = [
                NormalizedPoint(x: 0, y: 0), NormalizedPoint(x: 1, y: 0),
                NormalizedPoint(x: 1, y: 1), NormalizedPoint(x: 0, y: 1)
            ]
        case .ellipse:
            local = (0..<ellipseApproximationVertices).map { index in
                let angle = Double(index) / Double(ellipseApproximationVertices) * 2 * .pi
                return NormalizedPoint(x: 0.5 + 0.5 * cos(angle), y: 0.5 + 0.5 * sin(angle))
            }
        }

        // 画素空間で回転させる（正規化空間のまま回すと、画像のアスペクト比の分だけ形が歪む）
        let centerX = (rect.x + rect.width / 2) * imageSize.width
        let centerY = (rect.y + rect.height / 2) * imageSize.height
        let radians = roi.rotation * .pi / 180
        let cosA = cos(radians)
        let sinA = sin(radians)

        return local.map { point in
            let pixelX = (rect.x + point.x * rect.width) * imageSize.width
            let pixelY = (rect.y + point.y * rect.height) * imageSize.height
            let dx = pixelX - centerX
            let dy = pixelY - centerY
            // 画面座標（y下向き）での時計回り回転
            let rotatedX = centerX + dx * cosA - dy * sinA
            let rotatedY = centerY + dx * sinA + dy * cosA
            return NormalizedPoint(
                x: min(max(rotatedX / imageSize.width, 0), 1),
                y: min(max(rotatedY / imageSize.height, 0), 1)
            )
        }
    }

    /// 画像ヘッダだけを読んで画素サイズを取得する（全画素の展開を避ける）。
    static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}
