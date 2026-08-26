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

/// 1フレーム分の「ROI解決済み」データ。デコード＋ROI解決（producer）→
/// モザイク描画＋書き出し（consumer）へ受け渡す単位（v0.0.00155）。
private struct PipelineFrame: @unchecked Sendable {
    let index: Int
    let image: CGImage
    let rois: [MosaicROI]
    let presentationTime: CMTime
}

/// producer（デコード＋ROI解決）とconsumer（モザイク描画＋書き出し）の間の
/// 有界ブロッキングキュー（v0.0.00155: 動画書き出しの2段パイプライン化）。
///
/// - `push`はキューが満杯なら空くまで待つ（producerが先行しすぎてフレームを
///   メモリに溜め込み続けないようにする＝背圧）。
/// - `pop`は空ならproducerが次を入れるかfinishProducingを呼ぶまで待つ。
/// - `abort`はconsumer側の失敗や外部キャンセルを知らせ、push/pop双方を即座に
///   抜けさせる（バッファ内容は破棄。producer側は次の`isCancelled()`チェックで
///   自然に停止する設計のため、ここでは待たせているスレッドを起こすだけでよい）。
private final class VideoExportPipelineQueue<Element>: @unchecked Sendable {
    private var buffer: [Element] = []
    private let capacity: Int
    private let condition = NSCondition()
    private var producerDone = false
    private var aborted = false

    init(capacity: Int) { self.capacity = max(1, capacity) }

    func push(_ element: Element) {
        condition.lock()
        defer { condition.unlock() }
        while buffer.count >= capacity && !aborted {
            condition.wait()
        }
        guard !aborted else { return }
        buffer.append(element)
        condition.broadcast()
    }

    func pop() -> Element? {
        condition.lock()
        defer { condition.unlock() }
        while buffer.isEmpty && !producerDone && !aborted {
            condition.wait()
        }
        guard !aborted, !buffer.isEmpty else { return nil }
        let element = buffer.removeFirst()
        condition.broadcast()
        return element
    }

    func finishProducing() {
        condition.lock()
        producerDone = true
        condition.broadcast()
        condition.unlock()
    }

    func abort() {
        condition.lock()
        aborted = true
        condition.broadcast()
        condition.unlock()
    }
}

/// producer/consumer間で最初に発生したエラーだけを記録する箱（両スレッドから読み書きするためlock付き）。
private final class VideoExportFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        lock.lock(); defer { lock.unlock() }
        return storedError
    }

    /// 最初のエラーだけを記録する（2つ目以降は握りつぶす。producer/consumer
    /// どちらが先に失敗しても、最初の原因がユーザーへ伝わるようにするため）。
    func recordFirst(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if storedError == nil { storedError = error }
    }
}

public final class VideoMosaicExporter {
    /// 出力ファイルの拡張子から書き出しコンテナを決める。
    /// 読み込みはMP4/MOV両対応なのに書き出しがMP4固定という非対称を解消するために追加した
    /// （v0.0.00136）。未知の拡張子はMP4として扱う（従来の挙動を既定に保つ）。
    static func fileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mov", "qt": return .mov
        case "m4v": return .m4v
        default: return .mp4
        }
    }

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

    /// producer（デコード＋ROI解決）とconsumer（モザイク描画＋書き出し）の間で
    /// 溜め込むフレーム数の上限。大きいほど段差の吸収力は上がるがメモリを食う
    /// （1フレームがフルHDのBGRAで約8MB、4Kで約33MB）。2段パイプラインが目的（重い方の
    /// 処理と軽い方の処理を重ねて総時間を縮める）であり、大量に溜め込む設計ではないため
    /// 小さめの値にしてある。
    static let pipelineQueueCapacity = 2

    /// 動画全体へモザイクを適用して再エンコードする（同期・ブロッキング処理）。
    ///
    /// **2段パイプライン（v0.0.00155〜）**: 「デコード＋ROI解決（検出・追跡）」と
    /// 「モザイク描画＋書き出し」を別スレッドで重ねて実行する。前者は`roiProvider`が
    /// `VideoTrackingCoordinator`等のフレーム番号昇順の呼び出しを前提にした内部状態
    /// （Vision追跡・シーンカット比較・見失い蓄積）を持つため、**このステージ自体は
    /// 並列化しない**（フレームNの結果はフレームN-1の処理が終わった後でなければ求まらない）。
    /// 並列化するのは「重いROI解決」と「重いモザイク描画・書き出し」という**性質の異なる
    /// 2つの重い処理を同時に進める**ことで、従来の完全直列（1フレームずつ両方終えてから
    /// 次へ）より総時間を縮めることだけを狙っている。
    ///
    /// - Parameters:
    ///   - inputURL: 入力動画（mp4/mov等、AVFoundationが読める形式）。
    ///   - outputURL: 出力先（既に存在する場合は上書きのため削除する）。
    ///   - roiProvider: フレーム番号（0始まり）とそのフレーム画像を受け取り、そのフレームへ
    ///     適用するROI群を返すクロージャ。呼び出し側が検出結果・追跡結果（`VideoROITracker`等）
    ///     をここへ差し込む。空配列を返すとそのフレームは無加工のまま書き出す。
    ///     producer専用スレッドから、フレーム番号の昇順・一度に1回だけ呼ばれる
    ///     （従来と同じ呼び出し規約。並行呼び出しはされない）。
    ///   - includeAudio: 入力の音声トラックを再エンコードせずそのまま複製するか（既定true）。
    ///   - cancellation: 途中キャンセル用フラグ。
    ///   - progress: 進捗（0.0〜1.0）を都度通知するコールバック。書き出し（consumer）側の
    ///     スレッドから呼ばれる（従来と同じ）。
    /// - Throws: `VideoMosaicExporterError`、または`roiProvider`/`MosaicEngine.applyMosaic`が
    ///   投げたエラー。producer側・consumer側どちらが先に失敗しても、最初に発生した
    ///   エラーが呼び出し元へ伝わる。
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
            writer = try AVAssetWriter(outputURL: outputURL, fileType: Self.fileType(for: outputURL))
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

        let failure = VideoExportFailureBox()
        // producerスレッドとconsumer（呼び出し元）スレッドの双方から呼ぶため@Sendable。
        // `cancellation`（lock付き）・`failure`（lock付き）とも内部で同期しているため安全。
        let isCancelled: @Sendable () -> Bool = { cancellation?.isCancelled == true || failure.error != nil }

        // producer（デコード＋ROI解決）: 専用のバックグラウンドスレッドでフレーム番号の
        // 昇順に進める。consumer（下のwhileループ）とは`pipeline`経由でのみやり取りする。
        let pipeline = VideoExportPipelineQueue<PipelineFrame>(capacity: Self.pipelineQueueCapacity)
        let producerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try reader.readFrames(shouldContinue: { !isCancelled() }) { index, cgImage, presentationTime in
                    if isCancelled() { throw VideoMosaicExporterError.cancelled }
                    let rois = try roiProvider(index, cgImage)
                    pipeline.push(PipelineFrame(index: index, image: cgImage, rois: rois, presentationTime: presentationTime))
                }
            } catch {
                failure.recordFirst(error)
            }
            pipeline.finishProducing()
            producerFinished.signal()
        }

        // consumer（モザイク描画＋書き出し）: 呼び出し元スレッドで、pipelineから
        // 届いた順にフレームを処理する。書き出し（AVAssetWriterInput）は従来どおり
        // このスレッドからのみ触る（複数スレッドからの同時appendはしない）。
        do {
            while let frame = pipeline.pop() {
                if isCancelled() { throw failure.error ?? VideoMosaicExporterError.cancelled }

                let outputImage: CGImage
                if frame.rois.isEmpty {
                    outputImage = frame.image
                } else {
                    outputImage = try self.engine.applyMosaic(
                        to: frame.image,
                        rois: frame.rois,
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
                    if isCancelled() { throw failure.error ?? VideoMosaicExporterError.cancelled }
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
                guard adaptor.append(pixelBuffer, withPresentationTime: frame.presentationTime) else {
                    throw VideoMosaicExporterError.appendFailed
                }

                processedCount += 1
                progress?(min(1.0, Double(processedCount) / Double(estimatedTotalFrames)))
            }
            // pipelineが正常に空になって終わっても、producer側がエラーで終了していた
            // 場合はそのエラーを呼び出し元へ伝える（pop()はfinishProducing()でも
            // 自然にnilを返すため、ここで確認しないとproducerの失敗が握りつぶされる）。
            if let producerError = failure.error { throw producerError }
        } catch {
            // consumer側の失敗をproducerへ伝え、pushで待機中なら起こして早期終了させる
            // （producer自身は次のisCancelled()チェックで自然に止まる設計）。
            failure.recordFirst(error)
            pipeline.abort()
            producerFinished.wait()
            input.markAsFinished()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        // 正常終了時もproducerスレッドの完了を待ってから後始末する（リーク防止）。
        producerFinished.wait()
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
