import Foundation

/// ローテーション付きのログファイル。
///
/// デバッグログは従来 `OSLogStore(scope: .currentProcessIdentifier)` から直近10分を読むだけで、
/// **アプリを再起動すると前回のログが消えていた**（ユーザー要望 2026-08-02）。
/// 不具合の報告は再起動後になることが多いため、ファイルへ残す。
///
/// 方式は「1ファイルが上限に達したら連番へ退避し、新しいファイルへ書き直す」古典的なローテーション。
///
///     newMosaic.log      ← 現在書き込み中（最新）
///     newMosaic.1.log    ← 1つ前
///     ...
///     newMosaic.4.log    ← 最も古い（これを超えた分は削除）
///
/// 完全ローカルのファイル操作で、外部へは送信しない。
public final class RotatingLogFile: @unchecked Sendable {
    /// 1ファイルあたりの上限バイト数。
    public static let defaultMaxBytes = 1024 * 1024
    /// 保持する世代数（現在のファイルを含む）。
    public static let defaultMaxFiles = 5

    private let directory: URL
    private let baseName: String
    private let maxBytes: Int
    private let maxFiles: Int
    private let lock = NSLock()

    public init(
        directory: URL,
        baseName: String = "newMosaic",
        maxBytes: Int = defaultMaxBytes,
        maxFiles: Int = defaultMaxFiles
    ) {
        self.directory = directory
        self.baseName = baseName
        self.maxBytes = max(1024, maxBytes)
        self.maxFiles = max(1, maxFiles)
    }

    /// 現在書き込み中のファイル。
    public var currentURL: URL { directory.appendingPathComponent("\(baseName).log") }

    /// 世代ファイル（`index` は1以上。1が最も新しい退避）。
    public func rotatedURL(index: Int) -> URL {
        directory.appendingPathComponent("\(baseName).\(index).log")
    }

    /// 新しい順に並べたログファイル（存在するものだけ）。
    public func existingURLs() -> [URL] {
        let manager = FileManager.default
        var urls: [URL] = []
        if manager.fileExists(atPath: currentURL.path) { urls.append(currentURL) }
        for index in 1..<maxFiles where manager.fileExists(atPath: rotatedURL(index: index).path) {
            urls.append(rotatedURL(index: index))
        }
        return urls
    }

    /// 1行追記する（改行は自動で付ける）。上限に達していればローテーションしてから書く。
    public func append(_ line: String) {
        append(lines: [line])
    }

    /// 複数行をまとめて追記する。
    public func append(lines: [String]) {
        guard !lines.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

        var payload = Data(lines.joined(separator: "\n").utf8)
        payload.append(0x0A)

        rotateIfNeededUnsynchronized(adding: payload.count)

        if let handle = try? FileHandle(forWritingTo: currentURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: currentURL)
        }
    }

    /// 保持しているログを古い順に連結して返す（画面表示・書き出し用）。
    public func readAll() -> String {
        lock.lock()
        defer { lock.unlock() }
        return existingURLs()
            .reversed()
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined()
    }

    /// すべてのログファイルを削除する。
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        for url in existingURLs() {
            try? manager.removeItem(at: url)
        }
    }

    /// 追記後に上限を超えるならローテーションする。
    ///
    /// `newMosaic.(maxFiles-1).log` を消し、番号の大きい方から順に繰り上げ、
    /// 現在のファイルを `.1.log` にする。
    private func rotateIfNeededUnsynchronized(adding additionalBytes: Int) {
        let manager = FileManager.default
        let currentSize = (try? manager.attributesOfItem(atPath: currentURL.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        guard currentSize > 0, currentSize + additionalBytes > maxBytes else { return }

        let oldest = rotatedURL(index: maxFiles - 1)
        if manager.fileExists(atPath: oldest.path) {
            try? manager.removeItem(at: oldest)
        }
        var index = maxFiles - 2
        while index >= 1 {
            let from = rotatedURL(index: index)
            if manager.fileExists(atPath: from.path) {
                try? manager.moveItem(at: from, to: rotatedURL(index: index + 1))
            }
            index -= 1
        }
        try? manager.moveItem(at: currentURL, to: rotatedURL(index: 1))
    }
}
