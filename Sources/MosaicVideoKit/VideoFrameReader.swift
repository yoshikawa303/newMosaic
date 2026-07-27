import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation

// MARK: - MosaicVideoKit プラグイン境界
//
// このモジュールは既存の `Sources/NewMosaicApp`（アプリUI）・`Sources/MosaicCore`
// （静止画のAI/画像処理コア）を一切変更せず、動画対応を独立した追加ターゲットとして
// 提供する「土台」である。`MosaicCore` にのみ依存し、逆方向の依存は発生しない。
//
// 静止画パイプラインはCGImage単位で完結しているため、本モジュールの役目は
// 「動画をCGImageの並びへ変換するアダプタ」に徹すること。呼び出し側（将来のUI・
// 上位パイプライン）はCGImageだけを見ればよく、AVFoundation固有のAPIを意識せずに
// 既存の `MosaicEngine` / `Segmenting` 等をそのまま再利用できる。
// UIとの結線（動画インポート導線・タイムライン表示等）は本モジュールの範囲外とし、
// 別途行う想定。

/// 動画の基本情報（尺・フレームレート・解像度・推定総フレーム数）。
public struct VideoInfo: Sendable, Equatable {
    public let durationSeconds: Double
    public let frameRate: Double
    public let naturalSize: CGSize
    /// `durationSeconds * frameRate` からの推定値（コンテナのフレーム数メタデータではない）。
    /// 実際のフレーム数は`VideoFrameReader.readFrames`で数え上げた値を正とする。
    public let frameCount: Int

    public init(durationSeconds: Double, frameRate: Double, naturalSize: CGSize, frameCount: Int) {
        self.durationSeconds = durationSeconds
        self.frameRate = frameRate
        self.naturalSize = naturalSize
        self.frameCount = frameCount
    }
}

public enum VideoFrameReaderError: Error, LocalizedError {
    case noVideoTrack
    case readerCreationFailed(String)
    case pixelBufferConversionFailed
    case imageGenerationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "動画ファイルに映像トラックが見つかりません"
        case .readerCreationFailed(let detail):
            return "動画リーダーの作成に失敗しました: \(detail)"
        case .pixelBufferConversionFailed:
            return "フレーム画像への変換に失敗しました"
        case .imageGenerationFailed(let detail):
            return "フレーム画像の生成に失敗しました: \(detail)"
        }
    }
}

/// AVFoundationベースの動画フレーム読み出し。
///
/// - シーケンシャル読み出し（`readFrames`）: `AVAssetReader`によるデコード順の一括走査。
///   動画全体へモザイクを適用する書き出し処理（`VideoMosaicExporter`）や、キーフレーム
///   検出＋追跡パイプライン（`VideoDetectionPipeline`）が使う想定。
/// - ランダムアクセス（`frame(at:)`）: `AVAssetImageGenerator`による任意時刻の1枚取得。
///   プレビュー表示や再生UIのシークバー操作など、都度1枚だけ欲しい用途向け。
///
/// いずれも同期・ブロッキングAPIである。ローカルファイルであれば通常は高速だが、
/// 呼び出し側はメインスレッドから直接呼ばず、バックグラウンドスレッド
/// （`DispatchQueue`や`Task.detached`等）から利用すること。
public final class VideoFrameReader {
    public let url: URL
    private let asset: AVURLAsset
    private let ciContext: CIContext

    public init(url: URL, ciContext: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.url = url
        self.asset = AVURLAsset(url: url)
        self.ciContext = ciContext
    }

    /// `AVAssetReaderTrackOutput`はブロッキングAPIのため、映像トラックの取得も
    /// 同期版（非推奨だがローカルファイルでは即時に返る）を使い、`readFrames`全体を
    /// 単一の同期関数として提供できるようにしている。
    private func videoTrack() throws -> AVAssetTrack {
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw VideoFrameReaderError.noVideoTrack
        }
        return track
    }

    /// 尺・フレームレート・解像度を取得する。解像度は`preferredTransform`（回転等）を
    /// 適用した実表示サイズ（常に正の幅・高さ）で返す。
    public func loadInfo() throws -> VideoInfo {
        let track = try videoTrack()
        let durationSeconds = CMTimeGetSeconds(asset.duration)
        let rawFrameRate = Double(track.nominalFrameRate)
        let frameRate = rawFrameRate > 0 ? rawFrameRate : 30
        let transformedSize = track.naturalSize.applying(track.preferredTransform)
        let naturalSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
        let estimatedFrameCount = max(0, Int((durationSeconds * frameRate).rounded()))
        return VideoInfo(
            durationSeconds: durationSeconds,
            frameRate: frameRate,
            naturalSize: naturalSize,
            frameCount: estimatedFrameCount
        )
    }

    /// 先頭から末尾まで順にフレームを読み出し、フレーム毎にハンドラを呼ぶ（シーケンシャルアクセス）。
    ///
    /// - Parameters:
    ///   - shouldContinue: 各フレーム読み出し前に呼ばれる継続判定。falseを返すと途中で
    ///     打ち切る（`VideoMosaicExporter`のキャンセル処理から利用）。
    ///   - handler: フレーム番号（0始まり）・画像・提示時刻（`CMTime`）を受け取る。
    ///     ここで投げた例外はそのまま`readFrames`の呼び出し元へ伝播する。
    /// - Returns: 実際に読み出したフレーム数。
    @discardableResult
    public func readFrames(
        shouldContinue: () -> Bool = { true },
        handler: (_ index: Int, _ image: CGImage, _ presentationTime: CMTime) throws -> Void
    ) throws -> Int {
        let track = try videoTrack()
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw VideoFrameReaderError.readerCreationFailed(error.localizedDescription)
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw VideoFrameReaderError.readerCreationFailed("トラック出力を追加できません")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw VideoFrameReaderError.readerCreationFailed(reader.error?.localizedDescription ?? "unknown")
        }

        var index = 0
        while shouldContinue(), let sampleBuffer = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard let cgImage = Self.cgImage(from: pixelBuffer, context: ciContext) else {
                reader.cancelReading()
                throw VideoFrameReaderError.pixelBufferConversionFailed
            }
            do {
                try handler(index, cgImage, presentationTime)
            } catch {
                reader.cancelReading()
                throw error
            }
            index += 1
        }
        if reader.status == .failed {
            throw VideoFrameReaderError.readerCreationFailed(reader.error?.localizedDescription ?? "unknown")
        }
        reader.cancelReading()
        return index
    }

    /// 指定時刻の1枚だけをランダムアクセスで取得する（プレビュー/再生UI向け）。
    public func frame(at time: CMTime) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            return try generator.copyCGImage(at: time, actualTime: nil)
        } catch {
            throw VideoFrameReaderError.imageGenerationFailed(error.localizedDescription)
        }
    }

    /// CVPixelBuffer（BGRA・デコード後の動画フレーム）をCGImageへ変換する。
    static func cgImage(from pixelBuffer: CVPixelBuffer, context: CIContext) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}
