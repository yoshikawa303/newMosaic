import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import MosaicCore

/// メモリ使用量の実測レポート。
///
/// 「アプリのメモリが6GBを超える」報告（2026-07-31）の切り分け用。
/// AIモデル常駐分（避けられない固定費）と、画像保持分（設計で減らせる）を分けて測る。
/// 判定はせず数値を出すだけ（環境差で落とさないため）。
///
///     swift test --filter MemoryFootprintTests
@Suite(.serialized)
struct MemoryFootprintTests {
    /// OSがアプリのメモリとして数える値（アクティビティモニタの「メモリ」に相当）。
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    static func report(_ label: String, from baseline: Double) -> Double {
        let now = footprintMB()
        print(String(format: "  %-28@ %7.1f MB（増分 %+7.1f MB）", label, now, now - baseline))
        return now
    }

    @Test func reportModelResidentFootprint() throws {
        var mark = Self.footprintMB()
        print(String(format: "=== モデル常駐分の実測 ===\n  %-28@ %7.1f MB", "起点", mark))

        let detector = try? AnimeCensorDetector()
        mark = Self.report("検出モデル", from: mark)
        let segmenter = try? AnimeSegmenter()
        mark = Self.report("キャラクター分離モデル", from: mark)
        let pose = try? AnimePoseEstimator()
        mark = Self.report("骨格モデル", from: mark)

        // SAMはセッションが static lazy なので、読み込みと推論を分けて測る
        SAMSegmentEngine.warmUpSessionsForMeasurement()
        mark = Self.report("SAM（読込のみ）", from: mark)
        // 同一画像（埋め込みキャッシュが効く）で反復
        let same = Self.makeImage(width: 1024, height: 1024)
        for iteration in 1...5 {
            _ = SAMSegmentEngine().instanceMask(
                in: same, box: NormalizedRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)
            )
            mark = Self.report("SAM 同一画像 \(iteration)回目", from: mark)
        }
        // 別画像（毎回エンコーダを回す＝実運用に近い）で反復
        for iteration in 1...5 {
            _ = SAMSegmentEngine().instanceMask(
                in: Self.makeImage(width: 1024, height: 1024),
                box: NormalizedRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
            )
            mark = Self.report("SAM 別画像 \(iteration)回目", from: mark)
        }

        withExtendedLifetime((detector, segmenter, pose)) {}
        print(String(format: "  合計 %.1f MB", mark))
    }

    static func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        if let data = context.data {
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            var seed: UInt64 = 0x9E3779B97F4A7C15
            for index in 0..<(width * height * 4) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                bytes[index] = UInt8(truncatingIfNeeded: seed >> 33)
            }
        }
        return context.makeImage()!
    }
}
