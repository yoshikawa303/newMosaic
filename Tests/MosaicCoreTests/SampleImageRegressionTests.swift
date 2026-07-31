import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MosaicCore

/// 実画像による検出・人物マスクの回帰テスト。
///
/// `Tests/SampleImages/` へ画像を置くと自動で読み込み、検出結果と人物マスクの品質を測定する。
/// 画像はGit管理外（`.gitignore`）なので、置き方は同フォルダの README.md を参照。
/// 画像が1枚も無い場合は何も測定せず成功する（CIを壊さないため）。
///
/// 目的は「GUIで見つけた問題を、次から数値で再現・追跡できるようにする」こと。
/// 推測でしきい値を動かす作業を繰り返さないための基盤。
@Suite(.serialized) struct SampleImageRegressionTests {
    // MARK: - 期待値ファイルの書式

    struct ExpectedROI: Decodable {
        let category: String
        let rect: Rect
        struct Rect: Decodable {
            let x: Double
            let y: Double
            let width: Double
            let height: Double
            var normalized: NormalizedRect {
                NormalizedRect(x: x, y: y, width: width, height: height)
            }
        }
    }

    struct Expectation: Decodable {
        let note: String?
        let minimumRecall: Double?
        let maximumFalsePositives: Int?
        let maximumPersonMaskCoverage: Double?
        let expected: [ExpectedROI]
    }

    /// 期待値と検出結果の対応付けに使う最小IoU。位置がおおむね合っていれば同一とみなす。
    static let matchIoU = 0.3

    // MARK: - サンプルの探索

    /// リポジトリ内の `Tests/SampleImages` を、このソースファイルの位置から辿る。
    /// （テストはビルド生成物の中で実行されるため、Bundleからは辿れない）
    static var sampleDirectory: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/MosaicCoreTests/SampleImageRegressionTests.swift
            .deletingLastPathComponent()          // .../Tests/MosaicCoreTests
            .deletingLastPathComponent()          // .../Tests
            .appendingPathComponent("SampleImages")
    }

    static func sampleImageURLs() -> [URL] {
        let extensions: Set<String> = ["png", "jpg", "jpeg"]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: sampleDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func loadExpectation(for imageURL: URL) -> Expectation? {
        let sidecar = imageURL
            .deletingPathExtension()
            .appendingPathExtension("expected.json")
        guard let data = try? Data(contentsOf: sidecar) else { return nil }
        return try? JSONDecoder().decode(Expectation.self, from: data)
    }

    // MARK: - 測定

    struct DetectionScore {
        var matched: [String] = []
        var missed: [String] = []
        var falsePositives: [(category: String, rect: NormalizedRect)] = []
        var recall: Double {
            let total = matched.count + missed.count
            return total == 0 ? 1 : Double(matched.count) / Double(total)
        }
    }

    /// 期待値と検出結果を、同カテゴリ・IoU 0.3以上で対応付ける。
    static func score(detected: [MosaicROI], against expected: [ExpectedROI]) -> DetectionScore {
        var result = DetectionScore()
        var unmatched = detected
        for item in expected {
            let target = item.rect.normalized
            let index = unmatched.firstIndex { roi in
                roi.category.rawValue == item.category && roi.rect.iou(with: target) >= matchIoU
            }
            if let index {
                result.matched.append(item.category)
                unmatched.remove(at: index)
            } else {
                result.missed.append(item.category)
            }
        }
        result.falsePositives = unmatched.map { ($0.category.rawValue, $0.rect) }
        return result
    }

    /// マスクのうち、指定した枠の内側で白（対象）になっている画素の割合。
    /// `AnimeSegmenter.coverageRatio` は画像全体に対する比率なので、
    /// 「人物枠を塗り潰しているか」の判定には使えない。
    static func whiteRatio(of mask: CGImage, within bounds: NormalizedRect) -> Double {
        let rect = bounds.clamped().cgRect(
            imageSize: CGSize(width: mask.width, height: mask.height),
            origin: .topLeft
        )
        guard rect.width >= 1, rect.height >= 1,
              let crop = mask.cropping(to: rect) else { return 0 }
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
        let white = pixels.reduce(0) { $0 + ($1 > 127 ? 1 : 0) }
        return Double(white) / Double(pixels.count)
    }

    // MARK: - テスト本体

    /// サンプル画像に対して検出パイプラインを実行し、期待値と突き合わせる。
    @Test func detectionMatchesExpectationsOnSampleImages() throws {
        let urls = Self.sampleImageURLs()
        guard !urls.isEmpty else {
            print("""
                [SampleImageRegressionTests] サンプル画像がありません（測定をスキップしました）。
                置き場所: \(Self.sampleDirectory.path)
                置き方は同フォルダの README.md を参照してください。
                """)
            return
        }
        guard let detector = try? AnimeCensorDetector(),
              let personDetector = try? AnimePersonDetector() else {
            print("[SampleImageRegressionTests] 検出モデルを読み込めないため測定をスキップしました。")
            return
        }

        for url in urls {
            guard let image = Self.loadImage(url) else {
                Issue.record("画像を読み込めません: \(url.lastPathComponent)")
                continue
            }
            let personBounds = ((try? personDetector.detectPersons(in: image)) ?? []).map(\.bounds)
            let rois = DetectedROIRefiner.splitNippleAndAreola(
                try detector.detect(in: image, personBounds: personBounds)
            )

            let summary = rois
                .map { "\($0.category.rawValue)(\(String(format: "%.2f", $0.confidence)))" }
                .joined(separator: ", ")
            print("[\(url.lastPathComponent)] 人物\(personBounds.count)件 / 検出\(rois.count)件: \(summary)")

            guard let expectation = Self.loadExpectation(for: url) else {
                print("  期待値ファイルが無いため合否判定はしません（測定のみ）")
                continue
            }
            if let note = expectation.note { print("  メモ: \(note)") }

            let score = Self.score(detected: rois, against: expectation.expected)
            print(String(
                format: "  再現率 %.2f（一致%d / 見逃し%d） 誤検出%d件",
                score.recall, score.matched.count, score.missed.count, score.falsePositives.count
            ))
            for missed in score.missed { print("  見逃し: \(missed)") }
            for positive in score.falsePositives {
                print(String(
                    format: "  誤検出: %@ at (%.3f, %.3f) %.3fx%.3f",
                    positive.category, positive.rect.x, positive.rect.y,
                    positive.rect.width, positive.rect.height
                ))
            }

            if let minimumRecall = expectation.minimumRecall {
                #expect(
                    score.recall >= minimumRecall,
                    "\(url.lastPathComponent): 再現率 \(score.recall) が下限 \(minimumRecall) を下回りました"
                )
            }
            if let maximumFalsePositives = expectation.maximumFalsePositives {
                #expect(
                    score.falsePositives.count <= maximumFalsePositives,
                    "\(url.lastPathComponent): 誤検出 \(score.falsePositives.count)件が上限 \(maximumFalsePositives)件を超えました"
                )
            }
        }
    }

    /// 人物マスクが人物枠のどれだけを占めているかを測る。
    /// 1.0に近い値は「人物の形に沿わず背景まで塗っている」状態を意味する
    /// （GUI報告: 下段コマでベッドや別人の足まで人物範囲として選択される）。
    @Test func personMaskDoesNotCoverWholeBoundsOnSampleImages() throws {
        let urls = Self.sampleImageURLs()
        guard !urls.isEmpty else { return }
        guard let personDetector = try? AnimePersonDetector(),
              let segmenter = try? AnimeSegmenter() else {
            print("[SampleImageRegressionTests] 人物モデルを読み込めないため測定をスキップしました。")
            return
        }

        for url in urls {
            guard let image = Self.loadImage(url) else { continue }
            let persons = (try? personDetector.detectPersons(in: image)) ?? []
            // アプリと同じ経路（クロップ推論→SAM→全体画像推論）で測る
            let provider = PersonSilhouetteProvider(segmenter: segmenter)
            var worst = 0.0
            for (index, person) in persons.enumerated() {
                let result = provider.silhouette(in: image, bounds: person.bounds)
                worst = max(worst, result.coverage)
                print(String(
                    format: "[%@] 人物%d: 被覆率 %.2f（経路: %@）",
                    url.lastPathComponent, index + 1, result.coverage, result.source.rawValue
                ))
            }
            if let limit = Self.loadExpectation(for: url)?.maximumPersonMaskCoverage {
                #expect(
                    worst <= limit,
                    "\(url.lastPathComponent): 人物マスクの被覆率 \(worst) が上限 \(limit) を超えました（背景まで塗っている疑い）"
                )
            }
        }
    }

    /// 検出しきい値を変えたときの検出内訳を表で出す（測定のみ。合否判定はしない）。
    /// 「誤検出を消すためにしきい値を上げる」判断が、見逃しを増やさないかを数値で確認するため。
    @Test func reportDetectionAcrossConfidenceThresholds() throws {
        let urls = Self.sampleImageURLs()
        guard !urls.isEmpty else { return }
        guard let detector = try? AnimeCensorDetector(),
              let personDetector = try? AnimePersonDetector() else { return }

        let thresholds = [0.20, 0.30, 0.40, 0.50]
        for url in urls {
            guard let image = Self.loadImage(url) else { continue }
            let personBounds = ((try? personDetector.detectPersons(in: image)) ?? []).map(\.bounds)
            print("=== \(url.lastPathComponent)（人物\(personBounds.count)件）===")
            for threshold in thresholds {
                let rois = ((try? detector.detect(
                    in: image, personBounds: personBounds, confidenceThreshold: threshold
                )) ?? [])
                let byCategory = Dictionary(grouping: rois, by: { $0.category.rawValue })
                    .map { "\($0.key)×\($0.value.count)" }
                    .sorted()
                    .joined(separator: " ")
                let scores = rois
                    .map { String(format: "%.2f", $0.confidence) }
                    .sorted(by: >)
                    .joined(separator: ",")
                print(String(format: "  しきい値 %.2f: 計%2d件  %@  [%@]",
                             threshold, rois.count, byCategory, scores))
                // 期待値ファイル（expected.json）を書き起こすための座標を出す
                if abs(threshold - AnimeCensorDetector.defaultConfidenceThreshold) < 0.001
                    || abs(threshold - 0.30) < 0.001 {
                    for roi in rois.sorted(by: { $0.confidence > $1.confidence }) {
                        print(String(
                            format: "    { \"category\": \"%@\", \"rect\": { \"x\": %.4f, \"y\": %.4f, \"width\": %.4f, \"height\": %.4f } },  // score %.2f",
                            roi.category.rawValue, roi.rect.x, roi.rect.y,
                            roi.rect.width, roi.rect.height, roi.confidence
                        ))
                    }
                }
            }
        }
    }

    /// 小さいROIで、SAMの全体推論と切り出し推論のどちらが形状を捉えられているかを実測する。
    ///
    /// 被覆率が1.0付近＝枠を塗り潰しており形状を分離できていない、0付近＝空振り。
    /// その中間にあることが「対象の輪郭を取れている」目安になる
    /// （`SAMSegmentEngine.shapeConformCoverage` = 0.85 が既存の判定基準）。
    @Test func compareSAMWholeImageAndCropForSmallROIs() throws {
        let urls = Self.sampleImageURLs()
        guard !urls.isEmpty else { return }
        guard let detector = try? AnimeCensorDetector() else {
            print("[SampleImageRegressionTests] 検出モデルが無いため測定をスキップしました。")
            return
        }
        for url in urls {
            guard let image = Self.loadImage(url) else { continue }
            let rois = (try? detector.detect(in: image)) ?? []
            guard !rois.isEmpty else { continue }
            let longSide = Double(max(image.width, image.height))
            let scale = Double(SAMSegmentEngine.inputLongSide) / longSide
            print("=== \(url.lastPathComponent)（\(image.width)x\(image.height)）===")
            for roi in rois.sorted(by: { $0.rect.area < $1.rect.area }) {
                let px = roi.rect.cgRect(
                    imageSize: CGSize(width: image.width, height: image.height)
                )
                let sideInInput = max(px.width, px.height) * scale
                let full = SAMSegmentEngine.measureCoverage(in: image, box: roi.rect, useCrop: false)
                let crop = SAMSegmentEngine.measureCoverage(in: image, box: roi.rect, useCrop: true)
                print(String(
                    format: "  %-14@ 枠%4dx%4dpx（入力換算%3d） 全体=%@ 切出=%@",
                    roi.category.rawValue, Int(px.width), Int(px.height), Int(sideInInput),
                    full.map { String(format: "%.2f", $0) } ?? "  --",
                    crop.map { String(format: "%.2f", $0) } ?? "  --"
                ))
            }
        }
    }

    /// アプリと同じ合成経路（骨格プライア＋顔領域＋検出器＋各種除去）を再現し、
    /// 最終的に画面へ出るROIをすべて出力する。
    ///
    /// GUI報告（2026-07-31）の切り分け用。報告された誤ROIが検出器由来か、骨格・顔由来かを
    /// 推測せず特定するために使う。アプリ側（main.swift）の合成順序と一致させること。
    @Test func reportFinalROIsAsAssembledByApp() throws {
        let urls = Self.sampleImageURLs()
        guard !urls.isEmpty else { return }
        guard let personDetector = try? AnimePersonDetector(),
              let censorDetector = try? AnimeCensorDetector() else {
            print("[SampleImageRegressionTests] モデルが無いため測定をスキップしました。")
            return
        }
        let poseEstimator = try? AnimePoseEstimator()

        for url in urls {
            guard let image = Self.loadImage(url) else { continue }
            let persons = ((try? personDetector.detectPersons(in: image)) ?? [])
                .map { PersonDetection(bounds: $0.bounds, maskImage: nil) }
            let hints: [PoseHint]
            if let poseEstimator, let estimated = try? poseEstimator.estimatePose(in: image, persons: persons) {
                hints = estimated
            } else {
                hints = persons.map { PoseHint(bodyBounds: $0.bounds, lowerBodyBounds: $0.bounds, joints: []) }
            }
            var rois = SensitiveROIGenerator().generateROIs(
                from: hints, imageSize: CGSize(width: image.width, height: image.height)
            )
            if let poseEstimator {
                rois.append(contentsOf: (try? poseEstimator.faceRegionROIs(in: image, persons: persons)) ?? [])
            }
            let detected = (try? censorDetector.detect(
                in: image, personBounds: persons.map(\.bounds)
            )) ?? []
            // main.swift の mergeCandidates と同じ規則（IoU 0.5超の非manualを置き換える）
            for roi in detected {
                rois.removeAll { $0.source != "manual" && $0.rect.iou(with: roi.rect) > 0.5 }
                rois.append(roi)
            }
            rois = PoseDerivedROIFilter.dropChestPriors(from: rois, ifDetectorFound: detected)
            rois = PoseDerivedROIFilter.dropGroinPriors(from: rois, ifDetectorFound: detected)
            rois = DetectedROIRefiner.splitNippleAndAreola(rois)

            print("=== \(url.lastPathComponent) 最終ROI \(rois.count)件（検出器 \(detected.count)件）===")
            for roi in rois.sorted(by: { $0.rect.y < $1.rect.y }) {
                print(String(
                    format: "  %-13@ src=%-12@ 中心(%.3f, %.3f) 大きさ %.3fx%.3f 回転%4d 信頼度%.2f",
                    roi.category.rawValue, roi.source,
                    roi.rect.x + roi.rect.width / 2, roi.rect.y + roi.rect.height / 2,
                    roi.rect.width, roi.rect.height, Int(roi.rotation), roi.confidence
                ))
            }
        }
    }
}
