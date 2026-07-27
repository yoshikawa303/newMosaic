import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

// MARK: - 動画サムネイル（プラグイン境界）
//
// ライブラリ一覧へ動画を静止画と同じ見た目で並べるためのサムネイル生成。
// 生成した画像はメモリキャッシュのみで、ディスクへは書き出さない
// （動画本体はリンク登録が基本のため、ライブラリ配下へ内容を複製しない方針）。

/// 動画の代表フレームをサムネイルとして取り出す。
public final class VideoThumbnailProvider {
    /// 既定のサムネイル取得時刻（秒）。先頭は黒フレーム/フェードインのことがあるため少し進めた位置を使う。
    public static let defaultCaptureSeconds: Double = 0.5

    private let queue = DispatchQueue(label: "jp.yoshikawa303.newMosaic.VideoThumbnailProvider.sync")
    private var cache: [String: CGImage] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit: Int

    public init(cacheLimit: Int = 60) {
        self.cacheLimit = max(1, cacheLimit)
    }

    /// 動画のサムネイルを返す（キャッシュ付き）。取得できない場合はnil。
    ///
    /// 尺が`defaultCaptureSeconds`より短い動画は先頭フレームを使う。
    /// - Note: デコードを伴う同期処理のため、メインスレッドから直接呼ばないこと。
    public func thumbnail(for url: URL) -> CGImage? {
        let key = cacheKey(for: url)
        if let cached = queue.sync(execute: { cache[key] }) { return cached }

        let asset = AVURLAsset(url: url)
        let durationSeconds = CMTimeGetSeconds(asset.duration)
        let captureSeconds = durationSeconds > Self.defaultCaptureSeconds
            ? Self.defaultCaptureSeconds
            : max(0, durationSeconds / 2)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // サムネイルは正確な時刻である必要がないため、tolerance既定のまま高速に取得する
        guard let image = try? generator.copyCGImage(
            at: CMTime(seconds: captureSeconds, preferredTimescale: 600),
            actualTime: nil
        ) else { return nil }

        queue.sync {
            cache[key] = image
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            while cacheOrder.count > cacheLimit {
                let oldest = cacheOrder.removeFirst()
                cache.removeValue(forKey: oldest)
            }
        }
        return image
    }

    /// キャッシュを破棄する（ライブラリ更新時などに使う）。
    public func clearCache() {
        queue.sync {
            cache.removeAll()
            cacheOrder.removeAll()
        }
    }

    /// ファイルの更新日時込みのキー（差し替えられた動画を古いサムネイルで表示しないため）。
    private func cacheKey(for url: URL) -> String {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            .flatMap { $0 }?.timeIntervalSince1970 ?? 0
        return "\(url.path)#\(Int(modified))"
    }

    /// 拡張子から動画ファイルかどうかを判定する（ライブラリ登録時の振り分け用）。
    public static func isVideoFile(_ url: URL) -> Bool {
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
        return videoExtensions.contains(url.pathExtension.lowercased())
    }
}
