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
            var rois = try detector.detect(in: image, personBounds: personBounds)
            rois = DetectedROIRefiner.dropOversizedGenitalROIs(from: rois, persons: personBounds)
            rois = DetectedROIRefiner.splitNippleAndAreola(rois)

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
            var worst = 0.0
            for (index, person) in persons.enumerated() {
                guard let mask = (try? segmenter.personMaskByCrop(in: image, bounds: person.bounds)) ?? nil else {
                    print("[\(url.lastPathComponent)] 人物\(index + 1): クロップ推論が失敗（全体推論へフォールバック）")
                    worst = max(worst, 1.0)
                    continue
                }
                let coverage = AnimeSegmenter.coverageRatio(of: mask)
                worst = max(worst, coverage)
                print(String(
                    format: "[%@] 人物%d: マスク被覆率 %.2f",
                    url.lastPathComponent, index + 1, coverage
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
}
