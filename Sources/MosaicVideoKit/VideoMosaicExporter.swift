import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import MosaicCore

public enum VideoMosaicExporterError: Error, LocalizedError {
    case noVideoTrack
    case writerCreationFailed(String)
    case pixelBufferPoolUnavailable
    case pixelBufferCreationFailed
    case renderFailed
    case appendFailed
    case writingFailed(Error?)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "動画ファイルに映像トラックが見つかりません"
        case .writerCreationFailed(let detail):
            return "動画書き出しの準備に失敗しました: \(detail)"
        case .pixelBufferPoolUnavailable:
            return "書き出し用のフレームバッファを確保できませんでした"
        case .writingFailed(let underlying):
            let detail = underlying.map { "（\($0.localizedDescription)）" } ?? ""
            return "動画の書き出しが完了しませんでした\(detail)"
        case .pixelBufferCreationFailed:
            return "フレームバッファの生成に失敗しました"
        case .renderFailed:
            return "モザイク適用後のフレーム描画に失敗しました"
        case .appendFailed:
            return "フレームの書き出しに失敗しました"
        case .cancelled:
            return "書き出しをキャンセルしました"
        }
    }
}

/// 動画へのモザイク一括適用（再エンコード書き出し）。
///
/// プラグイン境界: フレーム毎のモザイク描画そのものは`MosaicCore.MosaicEngine.applyMosaic`を
/// そのまま呼び出すだけであり、本モジュールが担うのは「動画を1フレームずつCGImageとして取り出し
/// →ROI適用→CVPixelBufferへ描き戻して再エンコードする」という動画特有の配管のみ。
/// モザイクの描画アルゴリズム自体（パターン・スタイル・マスク生成）は静止画と完全に共通であり、
/// `MosaicCore`側の実装・改善がそのまま動画にも反映される。
///
/// - Important: 第一段階の実装であり、以下の制約がある。
///   - 音声トラックは書き出し対象に含めない（映像のみを再エンコードする）。
///     入力に音声トラックがあっても出力からは失われる。
///   - 出力コーデックはH.264固定。解像度・各フレームの提示時刻（フレームレート相当）は
///     入力動画のものをそのまま保持する。
///   - 可変フレームレート入力でも提示時刻をそのまま引き継ぐため、実質的な再生速度は変化しない。
/// 音声トラックを再エンコードせず複製する（V4）。
/// モザイク処理は映像のみが対象のため、音声は`passthrough`（出力設定nil）で
/// サンプルバッファをそのまま書き写す。
private final class AudioPassthrough {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let input: AVAssetWriterInput

    init(asset: AVAsset, track: AVAssetTrack, writer: AVAssetWriter) throws {
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw VideoMosaicExporterError.writerCreationFailed("音声リーダーの作成に失敗: \(error.localizedDescription)")
        }
        // outputSettings: nil で無変換（パススルー）読み出しになる
        output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else {
            throw VideoMosaicExporterError.writerCreationFailed("音声出力を追加できません")
        }
        reader.add(output)

        input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw VideoMosaicExporterError.writerCreationFailed("音声入力を追加できません")
        }
        writer.add(input)
    }

    /// 音声サンプルを全て書き写す。待機は全てタイムアウト付き（無期限待機はハングの原因）。
    func transfer(isCancelled: () -> Bool) throws {
        guard reader.startReading() else {
            throw VideoMosaicExporterError.writerCreationFailed(
                reader.error?.localizedDescription ?? "音声の読み出しを開始できません"
            )
        }
        while let sample = output.copyNextSampleBuffer() {
            if isCancelled() { throw VideoMosaicExporterError.cancelled }
            let deadline = Date().addingTimeInterval(30)
            while !input.isReadyForMoreMediaData {
                if Date() >= deadline { throw VideoMosaicExporterError.writingFailed(nil) }
                if isCancelled() { throw VideoMosaicExporterError.cancelled }
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard input.append(sample) else {
                throw VideoMosaicExporterError.appendFailed
            }
        }
        reader.cancelReading()
        input.markAsFinished()
    }
}

public final class VideoMosaicExporter {
    /// 別スレッドから書き出しを中断させるためのフラグ。`export`実行中に`isCancelled`を
    /// `true`にすると、次のフレーム処理タイミングで中断し、出力ファイルは削除される。
    public final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        public init() {}

        public var isCancelled: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return flag
            }
            set {
                lock.lock()
                flag = newValue
                lock.unlock()
            }
        }
    }

    private let engine: MosaicEngine
    private let style: MosaicStyle
    private let segmentEngine: Segmenting
    private let patternImageProvider: ((String) -> CGImage?)?

    public init(
        style: MosaicStyle,
        engine: MosaicEngine = MosaicEngine(),
        segmentEngine: Segmenting = ShapeSegmentEngine(),
        patternImageProvider: ((String) -> CGImage?)? = nil
    ) {
        self.style = style
        self.engine = engine
        self.segmentEngine = segmentEngine
        self.patternImageProvider = patternImageProvider
    }

    /// 動画全体へモザイクを適用して再エンコードする（同期・ブロッキング処理）。
    ///
    /// - Parameters:
    ///   - inputURL: 入力動画（mp4/mov等、AVFoundationが読める形式）。
    ///   - outputURL: 出力先（既に存在する場合は上書きのため削除する）。
    ///   - roiProvider: フレーム番号（0始まり）とそのフレーム画像を受け取り、そのフレームへ
    ///     適用するROI群を返すクロージャ。呼び出し側が検出結果・追跡結果（`VideoROITracker`等）
    ///     をここへ差し込む。空配列を返すとそのフレームは無加工のまま書き出す。
    ///   - includeAudio: 入力の音声トラックを再エンコードせずそのまま複製するか（既定true）。
    ///   - cancellation: 途中キャンセル用フラグ。
    ///   - progress: 進捗（0.0〜1.0）を都度通知するコールバック。
    /// - Throws: `VideoMosaicExporterError`、または`roiProvider`/`MosaicEngine.applyMosaic`が
    ///   投げたエラー。
    public func export(
        from inputURL: URL,
        to outputURL: URL,
        roiProvider: @escaping (_ frameIndex: Int, _ frame: CGImage) throws -> [MosaicROI],
        includeAudio: Bool = true,
        cancellation: CancellationFlag? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws {
        let reader = VideoFrameReader(url: inputURL)
        let info = try reader.loadInfo()

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw VideoMosaicExporterError.writerCreationFailed(error.localizedDescription)
        }

        let width = max(2, Int(info.naturalSize.width))
        let height = max(2, Int(info.naturalSize.height))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.canAdd(input) else {
            throw VideoMosaicExporterError.writerCreationFailed("映像入力を追加できません")
        }
        writer.add(input)

        // 音声はモザイク処理の対象外のため、デコード/再エンコードせずそのまま複製する
        // （パススルー）。音声トラックが無い動画では何もしない。
        let audioAsset = AVURLAsset(url: inputURL)
        var audioTransfer: AudioPassthrough?
        if includeAudio, let audioTrack = audioAsset.tracks(withMediaType: .audio).first {
            audioTransfer = try AudioPassthrough(asset: audioAsset, track: audioTrack, writer: writer)
        }

        guard writer.startWriting() else {
            throw VideoMosaicExporterError.writerCreationFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let estimatedTotalFrames = max(1, info.frameCount)
        var processedCount = 0

        func isCancelled() -> Bool { cancellation?.isCancelled == true }

        do {
            try reader.readFrames(shouldContinue: { !isCancelled() }) { index, cgImage, presentationTime in
                if isCancelled() { throw VideoMosaicExporterError.cancelled }

                let rois = try roiProvider(index, cgImage)
                let outputImage: CGImage
                if rois.isEmpty {
                    outputImage = cgImage
                } else {
                    outputImage = try self.engine.applyMosaic(
                        to: cgImage,
                        rois: rois,
                        style: self.style,
                        segmentEngine: self.segmentEngine,
                        patternImageProvider: self.patternImageProvider
                    )
                }

                let readyDeadline = Date().addingTimeInterval(30)
                while !input.isReadyForMoreMediaData {
                    if Date() >= readyDeadline || writer.status != .writing {
                        throw VideoMosaicExporterError.writingFailed(writer.error)
                    }
                    if isCancelled() { throw VideoMosaicExporterError.cancelled }
                    Thread.sleep(forTimeInterval: 0.005)
                }

                guard let pool = adaptor.pixelBufferPool else {
                    throw VideoMosaicExporterError.pixelBufferPoolUnavailable
                }
                var pixelBufferOut: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
                guard let pixelBuffer = pixelBufferOut else {
                    throw VideoMosaicExporterError.pixelBufferCreationFailed
                }
                guard Self.render(outputImage, into: pixelBuffer) else {
                    throw VideoMosaicExporterError.renderFailed
                }
                guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                    throw VideoMosaicExporterError.appendFailed
                }

                processedCount += 1
                progress?(min(1.0, Double(processedCount) / Double(estimatedTotalFrames)))
            }
        } catch {
            input.markAsFinished()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        // 無期限waitは呼び出しスレッドを塞ぎハングの原因になるため、タイムアウト付きで待つ
        guard semaphore.wait(timeout: .now() + 60) == .success else {
            throw VideoMosaicExporterError.writingFailed(writer.error)
        }

        if writer.status == .failed {
            throw VideoMosaicExporterError.writerCreationFailed(writer.error?.localizedDescription ?? "unknown")
        }
        progress?(1.0)
    }

    /// モザイク適用後のCGImageをBGRAのCVPixelBufferへ描画する。
    private static func render(_ image: CGImage, into pixelBuffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
}
