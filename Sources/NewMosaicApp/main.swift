import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import ImageIO
import MosaicCore
import MosaicVideoKit
import OSLog
import UniformTypeIdentifiers

/// 人物レイヤ由来のROI（source "person-layer-N"）を、候補生成時の人物シルエットマスクで
/// マスクするラッパー。人物ROIを矩形のままモザイクすると人物矩形全体が塗られてしまうため、
/// 選択中のマスク生成方式に関係なく人物の輪郭に沿ったマスクを適用する。
/// それ以外のROIは内包する基エンジンへそのまま委譲する。
/// ROIが個別のマスク生成方式（`MosaicROI.maskEngine` / `maskThreshold`）を持つ場合に、
/// そのROIだけ専用エンジンでマスクを作る。持たないROIは全体設定のエンジンへ委譲する。
///
/// 「個別」ONでマスク生成方式やしきい値を変えたとき、選択中レイヤ以外のマスクが
/// 巻き添えで作り直されないようにするために使う。
private final class PerROISegmentEngine: Segmenting {
    private let base: Segmenting
    private let engineForOverride: (String, Double?) -> Segmenting

    init(base: Segmenting, engineForOverride: @escaping (String, Double?) -> Segmenting) {
        self.base = base
        self.engineForOverride = engineForOverride
    }

    func createMasks(for rois: [MosaicROI], in image: CGImage, extent: CGRect) throws -> [CIImage] {
        var results = [CIImage?](repeating: nil, count: rois.count)
        var baseIndices: [Int] = []
        // 同じ方式・しきい値のROIはまとめて1回の推論に渡す（ROIごとに呼ぶと検出が重くなるため）
        var overrideGroups: [String: [Int]] = [:]
        for (index, roi) in rois.enumerated() {
            guard let kind = roi.maskEngine else {
                baseIndices.append(index)
                continue
            }
            let key = "\(kind)|\(roi.maskThreshold.map { String($0) } ?? "-")"
            overrideGroups[key, default: []].append(index)
        }
        for (_, indices) in overrideGroups {
            guard let first = indices.first, let kind = rois[first].maskEngine else { continue }
            let engine = engineForOverride(kind, rois[first].maskThreshold)
            let masks = try engine.createMasks(for: indices.map { rois[$0] }, in: image, extent: extent)
            for (position, index) in indices.enumerated() where position < masks.count {
                results[index] = masks[position]
            }
        }
        if !baseIndices.isEmpty {
            let baseMasks = try base.createMasks(for: baseIndices.map { rois[$0] }, in: image, extent: extent)
            for (position, index) in baseIndices.enumerated() where position < baseMasks.count {
                results[index] = baseMasks[position]
            }
        }
        return results.compactMap { $0 }
    }
}

/// 動画再生用のSAMマスクは毎フレーム再推論せず、一定間隔で再生成した輪郭を
/// 追跡済みROIの移動・拡縮へワープする。停止中の表示と書き出しは従来どおり
/// 各フレームのSAMを使い、これは実時間プレビューだけの高速経路である。
private final class VideoPlaybackSegmentEngine: Segmenting {
    private struct CachedMask {
        let image: CIImage
        let roiRect: NormalizedRect
        let extent: CGRect
        let settingsSignature: String
        let generatedFrame: Int
    }

    private let samEngine: Segmenting
    private let otherEngine: Segmenting
    private var cachedSAMMasks: [UUID: CachedMask] = [:]
    private var frameNumber = 0
    private let refreshInterval = 30

    init(engineFactory: @escaping (String, Double?) -> Segmenting) {
        samEngine = engineFactory(SegmentEngineKind.samShape.rawValue, nil)
        otherEngine = PerROISegmentEngine(base: ShapeSegmentEngine(), engineForOverride: engineFactory)
    }

    func reset() {
        cachedSAMMasks.removeAll()
        frameNumber = 0
    }

    func createMasks(for rois: [MosaicROI], in image: CGImage, extent: CGRect) throws -> [CIImage] {
        frameNumber += 1
        var results = [CIImage?](repeating: nil, count: rois.count)
        var samRefreshIndices: [Int] = []
        var otherIndices: [Int] = []
        let activeIDs = Set(rois.map(\.id))
        cachedSAMMasks = cachedSAMMasks.filter { activeIDs.contains($0.key) }

        for (index, roi) in rois.enumerated() {
            guard roi.maskEngine == SegmentEngineKind.samShape.rawValue else {
                otherIndices.append(index)
                continue
            }
            let signature = settingsSignature(for: roi)
            if let cached = cachedSAMMasks[roi.id],
               cached.extent.width == extent.width,
               cached.extent.height == extent.height,
               cached.settingsSignature == signature,
               frameNumber - cached.generatedFrame < refreshInterval {
                results[index] = Self.warp(
                    cached.image,
                    from: cached.roiRect,
                    to: roi.rect,
                    extent: extent
                )
            } else {
                samRefreshIndices.append(index)
            }
        }

        if !samRefreshIndices.isEmpty {
            let refreshROIs = samRefreshIndices.map { rois[$0] }
            let masks = try samEngine.createMasks(for: refreshROIs, in: image, extent: extent)
            for (offset, index) in samRefreshIndices.enumerated() where offset < masks.count {
                let mask = masks[offset]
                results[index] = mask
                cachedSAMMasks[rois[index].id] = CachedMask(
                    image: mask,
                    roiRect: rois[index].rect,
                    extent: extent,
                    settingsSignature: settingsSignature(for: rois[index]),
                    generatedFrame: frameNumber
                )
            }
        }
        if !otherIndices.isEmpty {
            let masks = try otherEngine.createMasks(for: otherIndices.map { rois[$0] }, in: image, extent: extent)
            for (offset, index) in otherIndices.enumerated() where offset < masks.count {
                results[index] = masks[offset]
            }
        }
        return results.map { $0 ?? CIImage(color: .black).cropped(to: extent) }
    }

    private func settingsSignature(for roi: MosaicROI) -> String {
        [
            roi.shape.rawValue,
            "rotationBucket:\(Int((roi.rotation / 15).rounded()))",
            roi.maskThreshold.map { String(format: "%.3f", $0) } ?? "-",
            roi.maskShapeScale.map { String(format: "%.3f", $0) } ?? "-",
            roi.polygonPoints?.map { String(format: "%.3f:%.3f", $0.x, $0.y) }.joined(separator: ",") ?? "-"
        ].joined(separator: "|")
    }

    private static func warp(
        _ mask: CIImage,
        from oldROI: NormalizedRect,
        to newROI: NormalizedRect,
        extent: CGRect
    ) -> CIImage {
        let oldRect = oldROI.cgRect(imageSize: extent.size, origin: .bottomLeft)
        let newRect = newROI.cgRect(imageSize: extent.size, origin: .bottomLeft)
        guard oldRect.width > 0.5, oldRect.height > 0.5 else { return mask }
        let scaleX = newRect.width / oldRect.width
        let scaleY = newRect.height / oldRect.height
        let transform = CGAffineTransform(
            a: scaleX,
            b: 0,
            c: 0,
            d: scaleY,
            tx: newRect.minX - oldRect.minX * scaleX,
            ty: newRect.minY - oldRect.minY * scaleY
        )
        return mask.transformed(by: transform).cropped(to: extent)
    }
}

/// 再生中のランダムアクセスデコーダ、Core Image描画コンテキスト、SAM等の
/// マスクエンジンを動画ごと・フレームごとに作り直さず、専用直列キュー上で再利用する。
private final class VideoPlaybackRenderer: @unchecked Sendable {
    private var readerURL: URL?
    private var reader: VideoFrameReader?
    private let mosaicEngine = MosaicEngine()
    private let segmentEngine: VideoPlaybackSegmentEngine
    private var lastTimeSeconds: Double?

    init(segmentEngine: VideoPlaybackSegmentEngine) {
        self.segmentEngine = segmentEngine
    }

    func render(
        url: URL,
        time: CMTime,
        tolerance: CMTime,
        maximumSize: CGSize?,
        rois: [MosaicROI],
        style: MosaicStyle,
        patternImages: [String: CGImage],
        previewEnabled: Bool
    ) throws -> (frame: CGImage, rendered: CGImage?) {
        if readerURL != url || reader == nil {
            readerURL = url
            reader = VideoFrameReader(url: url)
            mosaicEngine.invalidateMaskCache()
            segmentEngine.reset()
            lastTimeSeconds = nil
        }
        let seconds = CMTimeGetSeconds(time)
        if let lastTimeSeconds,
           seconds.isFinite,
           (seconds < lastTimeSeconds - 0.001 || seconds > lastTimeSeconds + 1.0) {
            segmentEngine.reset()
        }
        if seconds.isFinite { lastTimeSeconds = seconds }
        guard let reader else {
            throw VideoFrameReaderError.readerCreationFailed("再生用デコーダを初期化できません")
        }
        let frame = try reader.frame(at: time, tolerance: tolerance, maximumSize: maximumSize)
        guard previewEnabled, !rois.isEmpty else { return (frame, nil) }
        // フレームごとに画像内容が変わるため、画像オブジェクトIDを使う静止画向け
        // マスクキャッシュは持ち越さない。CIContextと推論エンジンだけを再利用する。
        mosaicEngine.invalidateMaskCache()
        let rendered = try mosaicEngine.applyMosaic(
            to: frame,
            rois: rois,
            style: style,
            segmentEngine: segmentEngine,
            patternImageProvider: { patternImages[$0] },
            skipIncompletePatterns: true
        )
        return (frame, rendered)
    }
}

private final class PersonLayerSegmentEngine: Segmenting {
    static let sourcePrefix = "person-layer-"
    private let base: Segmenting
    private let personMasks: [CGImage?]

    init(base: Segmenting, personMasks: [CGImage?]) {
        self.base = base
        self.personMasks = personMasks
    }

    func createMasks(for rois: [MosaicROI], in image: CGImage, extent: CGRect) throws -> [CIImage] {
        var results = [CIImage?](repeating: nil, count: rois.count)
        var baseIndices: [Int] = []
        for (index, roi) in rois.enumerated() {
            if let mask = personSilhouetteMask(for: roi, extent: extent) {
                results[index] = mask
            } else {
                baseIndices.append(index)
            }
        }
        if !baseIndices.isEmpty {
            let baseMasks = try base.createMasks(for: baseIndices.map { rois[$0] }, in: image, extent: extent)
            for (position, index) in baseIndices.enumerated() {
                results[index] = baseMasks[position]
            }
        }
        return results.compactMap { $0 }
    }

    private func personSilhouetteMask(for roi: MosaicROI, extent: CGRect) -> CIImage? {
        guard roi.source.hasPrefix(Self.sourcePrefix),
              let personIndex = Int(roi.source.dropFirst(Self.sourcePrefix.count)),
              personIndex >= 0, personIndex < personMasks.count,
              let mask = personMasks[personIndex] else { return nil }
        var silhouette = CIImage(cgImage: mask)
        if silhouette.extent.width != extent.width || silhouette.extent.height != extent.height {
            guard silhouette.extent.width > 0, silhouette.extent.height > 0 else { return nil }
            silhouette = silhouette.transformed(by: CGAffineTransform(
                scaleX: extent.width / silhouette.extent.width,
                y: extent.height / silhouette.extent.height
            ))
        }
        // ROI（移動後の矩形）内へ制限する（シルエットの他の部分へモザイクが漏れないようにする）
        let black = CIImage(color: .black).cropped(to: extent)
        let boundsMask = ShapeSegmentEngine.rectangleMask(
            rect: roi.rect.cgRect(imageSize: extent.size, origin: .bottomLeft),
            extent: extent,
            rotation: roi.rotation
        )
        return silhouette.composited(over: black).applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: boundsMask
        ]).cropped(to: extent)
    }
}

/// アプリ側（NewMosaicApp）のUnified Loggingラッパー。`MosaicCore`側の検出診断ログ
/// （subsystem `com.yoshikawa.newMosaic`、category `Detection`）と同一subsystemで統一し、
/// ヘルプ＞デバッグ＞デバッグログ画面から両方をまとめて参照できるようにする。
/// 画像内容・ファイルパス・個人情報は記録しない（エラー種別・件数等のみ）。
enum AppLog {
    private static let subsystem = "com.yoshikawa.newMosaic"
    static let ui = Logger(subsystem: subsystem, category: "UI")
    static let library = Logger(subsystem: subsystem, category: "Library")
    static let export = Logger(subsystem: subsystem, category: "Export")
    static let project = Logger(subsystem: subsystem, category: "Project")
    static let video = Logger(subsystem: subsystem, category: "Video")
    /// 自動検出（解析）の診断。`Detection` カテゴリに揃えて既存のデバッグログ画面で拾えるようにする。
    /// ここだけはユーザー要望により**ソース画像のファイル名とMD5**を記録する（フルパス・画像内容は残さない）。
    static let analysis = Logger(subsystem: subsystem, category: "Detection")
    /// ユーザー操作（メニュー・ボタン等）の実行記録。GUI不具合報告の再現手順を
    /// ログから追えるようにする（ユーザー要望 2026-08-06）。UI上の表示名のみ記録し、
    /// 画像内容・ファイルパス・入力テキスト等は記録しない。
    static let action = Logger(subsystem: subsystem, category: "Action")
}

/// 全コントロール・メニューのaction送出を一元的にフックし、ユーザー操作を
/// デバッグログへ記録する（GUI不具合報告の再現手順を追えるようにするため）。
/// メニュー項目・ボタン・セグメント切替・ポップアップ選択のみ記録し、
/// スライダーのドラッグ（連続送出でログが溢れる）やテキスト入力（内容が
/// プライバシーに関わる）は記録しない。
final class MosaicApplication: NSApplication {
    override func sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
        if let name = Self.userActionDisplayName(sender) {
            AppLog.action.info("操作: \(name, privacy: .public)")
        }
        return super.sendAction(action, to: target, from: sender)
    }

    /// senderからUI上の表示名を組み立てる。記録対象外（スライダー・テキスト欄等）は nil。
    private static func userActionDisplayName(_ sender: Any?) -> String? {
        switch sender {
        case let item as NSMenuItem:
            // 「ファイル > 画像を開く…」のようにメニュー階層のパスで記録する。
            var path = [item.title]
            var menu = item.menu
            while let current = menu, current !== NSApp.mainMenu, !current.title.isEmpty {
                path.insert(current.title, at: 0)
                menu = current.supermenu
            }
            return "メニュー \(path.joined(separator: " > "))"
        case let popUp as NSPopUpButton:
            let context = popUp.toolTip.map { " (\($0))" } ?? ""
            return "選択 \(popUp.titleOfSelectedItem ?? "?")\(context)"
        case let segmented as NSSegmentedControl:
            let segment = segmented.selectedSegment
            guard segment >= 0 else { return nil }
            var name = segmented.label(forSegment: segment)
            if name?.isEmpty != false {
                name = segmented.image(forSegment: segment)?.accessibilityDescription
            }
            return "切替 \(name ?? "セグメント\(segment)")"
        case let button as NSButton:
            // アイコンボタンはtitleが空なので、accessibilityLabel（ホバーヘルプの短文）
            // → 記号画像の説明 → title の順で表示名を拾う。
            var name = button.accessibilityLabel()
            if name?.isEmpty != false { name = button.image?.accessibilityDescription }
            if name?.isEmpty != false { name = button.title }
            guard let name, !name.isEmpty else { return nil }
            // チェックボックス等の状態持ちボタン（showsStateByが空でない）はON/OFFも記録する。
            // `buttonType`はAppKitに読み取りAPIが無いため、セルの状態表示設定で判定する。
            let isToggle = (button.cell as? NSButtonCell).map { !$0.showsStateBy.isEmpty } ?? false
            let state = isToggle ? (button.state == .on ? " → ON" : " → OFF") : ""
            return "ボタン \(name)\(state)"
        default:
            return nil
        }
    }
}

@main
final class NewMosaicApplication {
    static func main() {
        // MosaicApplication.shared を最初に呼ぶことで、共有インスタンスが
        // サブクラス（ユーザー操作ログのフック入り）として生成される。
        let app = MosaicApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let controller = MosaicWindowController()
    /// デバッグログをファイルへ退避する周期（秒）。
    /// 退避しておかないと、アプリを再起動した時点で前回のログが失われる。
    private static let logArchiveInterval: TimeInterval = 30
    private var logArchiveTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.ui.info("applicationDidFinishLaunching: \(Self.windowTitle(), privacy: .public)")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle()
        // 保持している参照があるので、閉じてもAppKitに解放させない。
        // `isReleasedWhenClosed` は既定が `true` で、閉じるとAppKitがreleaseする。
        // ARCの強参照と組み合わさると過剰解放になり、次に参照した時点で解放済みメモリを触る。
        // 主ウィンドウの場合は「最後のウィンドウを閉じた」→終了判定→
        // `applicationShouldTerminate` 内の `if let window` で落ちていた
        // （クラッシュ報告 2026-08-02。v0.0.00113で補助ウィンドウ5つは直したが主ウィンドウを見落としていた）。
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 560)
        // ウィンドウ枠はポータブル設定（AppSettings）を優先して復元する。
        // 保存時と画面構成が変わっている（外部ディスプレイを外した・解像度変更）場合、
        // そのまま復元すると画面外に開いて操作できなくなるため、可視領域へ収める。
        if let savedFrame = AppSettings.shared.string(forKey: "Layout.windowFrame"),
           !savedFrame.isEmpty,
           let clamped = Self.frameClampedToVisibleScreen(NSRectFromString(savedFrame)) {
            window.setFrame(clamped, display: true)
        } else if !window.setFrameUsingName("newMosaicMainWindow") {
            window.center()
        }
        window.contentView = controller.view
        window.delegate = controller
        installMainMenu(target: controller)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        controller.installNumpadShortcutMonitor()
        startDebugLogArchiving()
        DispatchQueue.main.async { [controller] in
            controller.applyInitialLayoutIfNeeded()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 保存済みウィンドウ枠を、現在接続されている画面の可視領域へ収めて返す。
    /// どの画面とも重ならない（外部ディスプレイを外した等）場合はnilを返し、呼び出し側で
    /// 既定位置へフォールバックさせる。
    private static func frameClampedToVisibleScreen(_ frame: NSRect) -> NSRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return frame }
        // 面積がもっとも重なる画面を復元先とする（複数ディスプレイ環境で元の画面を優先）
        func overlapArea(_ screen: NSScreen) -> CGFloat {
            let overlap = screen.visibleFrame.intersection(frame)
            guard !overlap.isNull else { return 0 }
            return overlap.width * overlap.height
        }
        let target = screens.max { overlapArea($0) < overlapArea($1) }
        guard let visible = target?.visibleFrame else { return nil }
        // まったく重なっていない場合は復元せず既定位置へ
        guard visible.intersects(frame) else { return nil }
        var clamped = frame
        clamped.size.width = min(clamped.width, visible.width)
        clamped.size.height = min(clamped.height, visible.height)
        clamped.origin.x = min(max(clamped.minX, visible.minX), visible.maxX - clamped.width)
        clamped.origin.y = min(max(clamped.minY, visible.minY), visible.maxY - clamped.height)
        return clamped
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.confirmCurrentChangesBeforeLeaving() else { return .terminateCancel }
        // 分割位置・ウィンドウ枠はリサイズ通知経由の保存に依存せず、終了直前に現在値を
        // 明示的に保存する（「終了時にUIレイアウトが保存されない」報告への対応。
        // 特にズーム（緑ボタン/タイトルバーのダブルクリック）はwindowDidEndLiveResizeが
        // 発火しないため、通知だけに頼ると枠が保存されない）。
        if let window {
            AppSettings.shared.set(NSStringFromRect(window.frame), forKey: "Layout.windowFrame")
        }
        controller.saveSplitPositionsNow()
        // AppSettingsは連続書き込み対策で0.3秒デバウンスしているため、その待機中に終了すると
        // 直前の変更（ウィンドウ枠・分割位置等）が保存されないまま失われることがあった。
        // 終了直前に必ず同期保存する。
        AppSettings.shared.persistNow()
        return .terminateNow
    }

    private static func windowTitle() -> String {
        let info = Bundle.main.infoDictionary
        let marketingVersion = info?["CFBundleShortVersionString"] as? String ?? "0.0.00000"
        return "newMosaic v\(marketingVersion)"
    }

    private func installMainMenu(target: MosaicWindowController) {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "newMosaic")
        appMenu.addItem(withTitle: "newMosaicについて", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "newMosaicを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "ファイル")
        fileMenu.addItem(shortcutMenuItem("openImage", titleSuffix: "…", target: target))
        fileMenu.addItem(shortcutMenuItem("openVideo", titleSuffix: "…", target: target))
        fileMenu.addItem(shortcutMenuItem("pasteImage", target: target))
        fileMenu.addItem(.separator())
        fileMenu.addItem(shortcutMenuItem("exportImage", titleSuffix: "…", target: target))
        fileMenu.addItem(shortcutMenuItem("revealLibrary", target: target))
        fileMenu.addItem(.separator())
        fileMenu.addItem(shortcutMenuItem("cleanUpPastedIconImports", target: target))
        fileMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "設定", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu(title: "設定")
        settingsMenu.addItem(menuItem("詳細設定…", action: "showAdvancedSettings", key: "", target: target))
        let projectItem = NSMenuItem(title: "プロジェクト", action: nil, keyEquivalent: "")
        let projectMenu = NSMenu(title: "プロジェクト")
        projectMenu.delegate = target
        projectItem.submenu = projectMenu
        settingsMenu.addItem(projectItem)
        settingsMenu.addItem(.separator())
        settingsMenu.addItem(menuItem("保存…", action: "saveProject", key: "", target: target))
        settingsMenu.addItem(menuItem("読込…", action: "loadProject", key: "", target: target))
        settingsMenu.addItem(.separator())
        settingsMenu.addItem(menuItem("初期化…", action: "resetAllSettings", key: "", target: target))
        settingsMenu.addItem(menuItem("バックアップ…", action: "backupAllSettings", key: "", target: target))
        settingsItem.submenu = settingsMenu
        fileMenu.addItem(settingsItem)
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(shortcutMenuItem("performUndo", target: target))
        editMenu.addItem(shortcutMenuItem("performRedo", target: target))
        editMenu.addItem(.separator())
        editMenu.addItem(shortcutMenuItem("clearROIs", target: target))
        editItem.submenu = editMenu

        let processItem = NSMenuItem()
        mainMenu.addItem(processItem)
        let processMenu = NSMenu(title: "処理")
        processMenu.addItem(shortcutMenuItem("generateCandidates", target: target))
        processMenu.addItem(shortcutMenuItem("applyMosaic", target: target))
        processItem.submenu = processMenu

        // 動画メニュー（V3。キーフレーム操作と追跡確認）
        let videoItem = NSMenuItem()
        mainMenu.addItem(videoItem)
        let videoMenu = NSMenu(title: "動画")
        videoMenu.addItem(shortcutMenuItem("previewSelectedVideo", target: target))
        videoMenu.addItem(.separator())
        videoMenu.addItem(shortcutMenuItem("toggleVideoPlayback", target: target, registersKeyEquivalent: false))
        videoMenu.addItem(shortcutMenuItem("stepToPreviousVideoFrame", target: target))
        videoMenu.addItem(shortcutMenuItem("stepToNextVideoFrame", target: target))
        videoMenu.addItem(.separator())
        videoMenu.addItem(shortcutMenuItem("jumpToPreviousKeyframe", target: target, registersKeyEquivalent: false))
        videoMenu.addItem(shortcutMenuItem("jumpToNextKeyframe", target: target, registersKeyEquivalent: false))
        videoMenu.addItem(shortcutMenuItem("addVideoKeyframe", target: target))
        videoMenu.addItem(shortcutMenuItem("removeVideoKeyframe", target: target))
        videoMenu.addItem(shortcutMenuItem("deleteSelectedVideoKeyframes", target: target))
        videoMenu.addItem(shortcutMenuItem("deleteAllVideoKeyframes", target: target))
        videoMenu.addItem(.separator())
        videoMenu.addItem(shortcutMenuItem("runTrackingPreview", target: target))
        videoMenu.addItem(shortcutMenuItem("autoProcessCurrentVideo", target: target))
        videoMenu.addItem(.separator())
        videoMenu.addItem(shortcutMenuItem("exportVideoWithMosaic", target: target))
        videoItem.submenu = videoMenu

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "表示")
        viewMenu.addItem(shortcutMenuItem("zoomIn", target: target))
        viewMenu.addItem(shortcutMenuItem("zoomOut", target: target))
        viewMenu.addItem(shortcutMenuItem("zoomToFit", target: target))
        viewItem.submenu = viewMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "ウィンドウ")
        windowMenu.addItem(withTitle: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "拡大／縮小", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "ヘルプ")
        helpMenu.addItem(menuItem("ショートカット一覧…", action: "showShortcutsWindow", key: "", target: target))
        helpMenu.addItem(.separator())
        // デバッグログはヘルプ直下に置く（旧: ヘルプ＞デバッグ＞デバッグログの3階層。
        // ログウィンドウを開きやすくするためのユーザー要望 2026-08-06 で1階層に変更）。
        helpMenu.addItem(menuItem("デバッグログ…", action: "showDebugLogWindow", key: "", target: target))
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    private func menuItem(_ title: String, action: String, key: String, target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector((action)), keyEquivalent: key)
        item.target = target
        return item
    }

    /// `AppShortcut` レジストリを参照してメニュー項目を構築する。タイトル・キー等価文字・
    /// 修飾キー・アクションのすべてを登録データから取得するため、メニュー表示と実際の
    /// 動作が食い違うことがない（手入力の重複によるバグを構造的に防ぐ）。
    private func shortcutMenuItem(
        _ id: String,
        titleSuffix: String = "",
        target: AnyObject,
        registersKeyEquivalent: Bool = true
    ) -> NSMenuItem {
        guard let shortcut = MosaicWindowController.shortcut(id: id) else {
            return NSMenuItem(title: id, action: nil, keyEquivalent: "")
        }
        let item = NSMenuItem(
            title: shortcut.title + titleSuffix,
            action: shortcut.action,
            keyEquivalent: registersKeyEquivalent ? shortcut.key : ""
        )
        item.keyEquivalentModifierMask = shortcut.modifiers
        item.target = target
        return item
    }
}

/// ツールバー・パターンタイル等のアイコンボタン。
///
/// `NSButton`の`.texturedRounded`/`.shadowlessSquare`ベゼルやフォーカスリングは、
/// いずれもアイコン拡大（Build 66）後の大きな正方形フレームへ正しく追従せず、
/// 押下時のハイライトが横長に潰れる／ボタン枠と合わない不具合が繰り返し発生していた
/// （AppKit内部の既定寸法に依存した描画のため、実測でしか原因を特定できなかった）。
/// ネイティブのベゼル・フォーカスリングを一切使わず、押下中(`isHighlighted`)の背景を
/// 自前で`bounds`いっぱいに描くことで、サイズによらず必ずボタン枠と一致させる。
@MainActor
private final class SquareIconButton: NSButton {
    var usesCompactPanelChrome = false

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

@MainActor
private final class WrappingToolbarView: NSView {
    private let groups: [[NSView]]
    private let separators: [NSBox]
    private let horizontalSpacing: CGFloat = 2
    private let verticalSpacing: CGFloat = 2
    private let separatorWidth: CGFloat = 1
    private let separatorHeight: CGFloat = 18

    init(groups: [[NSView]]) {
        self.groups = groups
        self.separators = (0..<max(0, groups.count - 1)).map { _ in
            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            return separator
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for (index, group) in groups.enumerated() {
            if index > 0 { addSubview(separators[index - 1]) }
            for view in group {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
        }
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let naturalWidth = layoutGroups(maxWidth: .greatestFiniteMagnitude, applyFrames: false).width
        let measurementWidth = bounds.width > 1 ? bounds.width : naturalWidth
        return NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight(for: measurementWidth))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.size.width
        super.setFrameSize(newSize)
        if abs(oldWidth - newSize.width) > 0.5 {
            invalidateIntrinsicContentSize()
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        layoutGroups(applyFrames: true)
    }

    private func measuredHeight(for width: CGFloat) -> CGFloat {
        let result = layoutGroups(maxWidth: width, applyFrames: false)
        return result.height
    }

    @discardableResult
    private func layoutGroups(maxWidth: CGFloat? = nil, applyFrames: Bool) -> NSSize {
        let availableWidth = max(1, maxWidth ?? bounds.width)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for (index, group) in groups.enumerated() {
            let groupSize = size(for: group)
            let separatorNeeded = index > 0 && x > 0
            let separatorSpace = separatorNeeded ? separatorWidth + horizontalSpacing * 2 : 0
            let neededWidth = groupSize.width + separatorSpace
            if x > 0 && x + neededWidth > availableWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            let needsSeparator = index > 0 && x > 0
            if index > 0 {
                let separator = separators[index - 1]
                separator.isHidden = !needsSeparator
                if needsSeparator {
                    let separatorY = y + max(0, (max(rowHeight, groupSize.height) - separatorHeight) / 2)
                    if applyFrames {
                        separator.frame = NSRect(x: x + horizontalSpacing, y: separatorY, width: separatorWidth, height: separatorHeight)
                    }
                    x += separatorWidth + horizontalSpacing * 2
                }
            }

            var groupX = x
            for view in group {
                let viewSize = size(for: view)
                if applyFrames {
                    view.frame = NSRect(x: groupX, y: y + max(0, (groupSize.height - viewSize.height) / 2), width: viewSize.width, height: viewSize.height)
                }
                groupX += viewSize.width + horizontalSpacing
            }
            x += groupSize.width
            rowHeight = max(rowHeight, groupSize.height)
            usedWidth = max(usedWidth, x)
        }

        return NSSize(width: usedWidth, height: y + rowHeight)
    }

    private func size(for group: [NSView]) -> NSSize {
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (index, view) in group.enumerated() {
            let viewSize = size(for: view)
            if index > 0 { width += horizontalSpacing }
            width += viewSize.width
            height = max(height, viewSize.height)
        }
        return NSSize(width: width, height: height)
    }

    private func size(for view: NSView) -> NSSize {
        let fitting = view.fittingSize
        return NSSize(width: max(32, fitting.width), height: max(30, fitting.height))
    }
}

@MainActor
private final class WrappingControlRowView: NSView {
    private let groups: [[NSView]]
    private let itemSpacing: CGFloat
    private let groupSpacing: CGFloat
    private let rowSpacing: CGFloat
    private var heightConstraint: NSLayoutConstraint?
    private let minimumControlHeight: CGFloat = 24

    init(groups: [[NSView]], itemSpacing: CGFloat = 6, groupSpacing: CGFloat = 8, rowSpacing: CGFloat = 2) {
        self.groups = groups
        self.itemSpacing = itemSpacing
        self.groupSpacing = groupSpacing
        self.rowSpacing = rowSpacing
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for group in groups {
            for view in group {
                view.translatesAutoresizingMaskIntoConstraints = false
                if let button = view as? NSButton {
                    button.cell?.wraps = false
                    button.cell?.lineBreakMode = .byClipping
                    button.setContentCompressionResistancePriority(.required, for: .horizontal)
                } else if let textField = view as? NSTextField {
                    textField.cell?.wraps = false
                    textField.cell?.lineBreakMode = .byClipping
                    textField.setContentCompressionResistancePriority(.required, for: .horizontal)
                }
                addSubview(view)
            }
        }
        let height = heightAnchor.constraint(equalToConstant: minimumControlHeight)
        height.priority = .required
        height.isActive = true
        heightConstraint = height
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let naturalWidth = layoutGroups(maxWidth: .greatestFiniteMagnitude, applyFrames: false).width
        let measurementWidth = bounds.width > 1 ? bounds.width : naturalWidth
        return NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight(for: measurementWidth))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.size.width
        super.setFrameSize(newSize)
        if abs(oldWidth - newSize.width) > 0.5 {
            updateMeasuredHeight(for: newSize.width)
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        updateMeasuredHeight(for: bounds.width)
    }

    override func layout() {
        super.layout()
        updateMeasuredHeight(for: bounds.width)
        layoutGroups(applyFrames: true)
    }

    private func measuredHeight(for width: CGFloat) -> CGFloat {
        let naturalWidth = layoutGroups(maxWidth: .greatestFiniteMagnitude, applyFrames: false).width
        let measurementWidth = width > 1 ? width : naturalWidth
        return max(minimumControlHeight, ceil(layoutGroups(maxWidth: measurementWidth, applyFrames: false).height))
    }

    private func updateMeasuredHeight(for width: CGFloat) {
        let height = measuredHeight(for: width)
        if let constraint = heightConstraint, abs(constraint.constant - height) > 0.5 {
            constraint.constant = height
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
        }
    }

    @discardableResult
    private func layoutGroups(maxWidth: CGFloat? = nil, applyFrames: Bool) -> NSSize {
        let availableWidth = max(1, maxWidth ?? bounds.width)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for group in groups {
            let groupSize = size(for: group)
            let spacing = x > 0 ? groupSpacing : 0
            if x > 0 && x + spacing + groupSize.width > availableWidth {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            if x > 0 { x += groupSpacing }

            var groupX = x
            for view in group {
                let viewSize = size(for: view)
                if applyFrames {
                    view.frame = NSRect(
                        x: groupX,
                        y: y + max(0, (groupSize.height - viewSize.height) / 2),
                        width: viewSize.width,
                        height: viewSize.height
                    )
                }
                groupX += viewSize.width + itemSpacing
            }

            x += groupSize.width
            rowHeight = max(rowHeight, groupSize.height)
            usedWidth = max(usedWidth, x)
        }

        return NSSize(width: usedWidth, height: y + rowHeight)
    }

    private func size(for group: [NSView]) -> NSSize {
        var width: CGFloat = 0
        var height: CGFloat = minimumControlHeight
        for (index, view) in group.enumerated() {
            let viewSize = size(for: view)
            if index > 0 { width += itemSpacing }
            width += viewSize.width
            height = max(height, viewSize.height)
        }
        return NSSize(width: width, height: height)
    }

    private func size(for view: NSView) -> NSSize {
        let fitting = view.fittingSize
        return NSSize(width: ceil(fitting.width), height: max(minimumControlHeight, ceil(fitting.height)))
    }
}

/// ツールバーボタンのホバー時にヘルプ文をステータスバーへ表示するための追跡中継。
@MainActor
private final class HoverHelpRelay: NSResponder {
    private let text: String
    private let onHover: (String?) -> Void

    init(text: String, onHover: @escaping (String?) -> Void) {
        self.text = text
        self.onHover = onHover
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func mouseEntered(with event: NSEvent) {
        onHover(text)
    }

    override func mouseExited(with event: NSEvent) {
        onHover(nil)
    }
}

/// NSScrollView内で内容を上寄せ表示するための反転ドキュメントビュー。
/// 非flippedのままだと内容が短いときに下寄せ表示になる（サイドパネル移動時の不要な空間の原因）。
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// アプリのショートカット可能な操作を表す。メニュー・ツールバーのツールチップ・
/// ヘルプ＞ショートカット一覧・詳細設定＞テンキー割当のすべてがこの一覧を参照することで、
/// 表示（メニューやツールチップの文言）と実際の動作（keyEquivalent/action）が食い違う
/// バグを構造的に防ぐ（表示用文字列は key/modifiers から自動生成し、手入力しない）。
struct AppShortcut {
    let id: String
    let category: String
    let title: String
    /// キー等価文字（""=デフォルトのキーボードショートカットなし。テンキー割当のみで使うことも可）
    let key: String
    let modifiers: NSEvent.ModifierFlags
    /// ヘルプ画面「よく使うおすすめショートカット」に先頭表示するか
    let isRecommended: Bool
    let action: Selector

    /// メニュー・ツールチップ・ヘルプ画面へ表示する文字列（例: "⌘O"、"⇧⌘Z"）。keyが空なら空文字。
    var displayString: String {
        guard !key.isEmpty else { return "" }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case "\r": text += "⏎"
        case "\u{1b}": text += "⎋"
        case " ": text += "Space"
        case "+": text += "+"
        case "-": text += "-"
        default: text += key.uppercased()
        }
        return text
    }
}

private enum LibraryViewMode: Int {
    case thumbnailGrid = 0
    case textList = 1
    case thumbnailList = 2
}

private enum LibraryProcessedFilter: Int, CaseIterable {
    case all = 0
    case unprocessed = 1
    case processed = 2
}

private enum LibraryKindFilter: Int, CaseIterable {
    case all = 0
    case image = 1
    case video = 2

    var title: String {
        switch self {
        case .all: return "すべて"
        case .image: return "静止画"
        case .video: return "動画"
        }
    }
}

private enum LibrarySortKey: String {
    case name, status, kind, resolution, roiCount, updatedAt
}

/// 「元に戻す」「やり直し」1ステップ分の状態。
///
/// **描画済み画像は持たない。** 以前はフル解像度のCGImageを各ステップに保持していたが、
/// A4・300dpi（2480x3508）で1枚あたり34.8MB、しかもスタックに上限が無いため、
/// 編集を重ねるだけでGB単位が常駐した（「使用メモリが6GBを超える」報告の主因）。
/// 描画結果はROIから作り直せるので、ROIだけを保持する（ARCHITECTURE §5.49）。
private struct EditorState {
    var rois: [MosaicROI]
}

private struct CandidateGenerationInput: @unchecked Sendable {
    var image: CGImage
    var domainMode: Int
    var groinPositionRatio: Double
}

private struct CandidateGenerationOutput: @unchecked Sendable {
    var domain: ImageDomain
    var domainSourceNote: String
    var snapshot: DetectionSnapshot
    var rois: [MosaicROI]
    var animeDetectionCount: Int
    var photoDetectionCount: Int
    var domainDetectorAvailable: Bool
    var detectorFailureMessage: String?
}

private enum CandidateGenerationTaskResult: @unchecked Sendable {
    case success(CandidateGenerationOutput)
    case failure(String)
}

/// ONNX/Vision推論をメインスレッド外で直列実行する。各モデルはワーカー内で再利用する。
///
/// **直列化はこのクラスの責務**（v0.0.00136）。従来は呼び出し側が`isGeneratingCandidates`で
/// 1本に絞っていたため実質直列だったが、動画の自動再検出が書き出しスレッドから同じワーカーを
/// 使うようになり、静止画の候補生成と同時に走り得るようになった。`lazy var`のモデル生成と
/// 推論セッションはスレッド安全ではないため、`run(_:)`全体をロックで囲って直列を保証する。
private final class CandidateGenerationWorker: @unchecked Sendable {
    private let runLock = NSLock()
    private lazy var animeCensorDetector: AnimeCensorDetector? = try? AnimeCensorDetector()
    private lazy var animePersonDetector: AnimePersonDetector? = try? AnimePersonDetector()
    private lazy var photoCensorDetector: PhotoCensorDetector? = try? PhotoCensorDetector()
    private lazy var domainModelClassifier: DomainModelClassifier? = try? DomainModelClassifier()
    private lazy var animeSegmenter: AnimeSegmenter? = try? AnimeSegmenter()
    private lazy var animePoseEstimator: AnimePoseEstimator? = try? AnimePoseEstimator()
    private lazy var faceRegionDetector = FaceRegionDetector()

    func run(_ input: CandidateGenerationInput) throws -> CandidateGenerationOutput {
        runLock.lock()
        defer { runLock.unlock() }
        return try runLocked(input)
    }

    private func runLocked(_ input: CandidateGenerationInput) throws -> CandidateGenerationOutput {
        var detectorFailures: [String] = []
        let domain: ImageDomain
        let domainSourceNote: String
        switch input.domainMode {
        case 1:
            domain = .photo
            domainSourceNote = "手動指定"
        case 2:
            domain = .illustration
            domainSourceNote = "手動指定"
        default:
            if let result = try? domainModelClassifier?.classify(input.image) {
                domain = result.domain
                domainSourceNote = "自動判定 \(Int(result.confidence * 100))%"
            } else {
                domain = DomainClassifier.classify(input.image)
                domainSourceNote = "自動判定"
            }
        }

        let snapshot: DetectionSnapshot
        if domain == .illustration {
            let persons: [PersonDetection]
            if let detector = animePersonDetector {
                do {
                    persons = try detector.detectPersons(in: input.image)
                } catch {
                    detectorFailures.append("アニメ人物検出: \(error.localizedDescription)")
                    persons = []
                }
            } else {
                persons = []
            }
            // キャラクターセグメンテーションで人物シルエットを付与する（実写のVisionシルエット相当）。
            // 経路（クロップ推論→SAM→全体画像推論）と、人物枠を塗り潰したマスクを弾く判定は
            // コア側の `PersonSilhouetteProvider` に集約してある（実画像テストと同じ経路を通すため）。
            var personsWithMasks = persons
            if !persons.isEmpty, let segmenter = animeSegmenter {
                let silhouetteProvider = PersonSilhouetteProvider(segmenter: segmenter)
                personsWithMasks = persons.map { person in
                    let result = silhouetteProvider.silhouette(in: input.image, bounds: person.bounds)
                    return PersonDetection(bounds: person.bounds, maskImage: result.mask)
                }
            }
            // アニメ骨格検出（DWPose）。関節が取れた人物は骨格レイヤ+骨格ベースの候補ROIも生成する
            let hints: [PoseHint]
            if let poseEstimator = animePoseEstimator,
               let estimated = try? poseEstimator.estimatePose(in: input.image, persons: personsWithMasks) {
                hints = estimated
            } else {
                hints = personsWithMasks.map {
                    PoseHint(bodyBounds: $0.bounds, lowerBodyBounds: $0.bounds, joints: [])
                }
            }
            let generator = SensitiveROIGenerator(groinPositionRatio: input.groinPositionRatio)
            var priorROIs = generator.generateROIs(
                from: hints,
                imageSize: CGSize(width: input.image.width, height: input.image.height)
            )
            // 顔領域（目元・眼窩下〜あご）: DWPoseの顔キーポイントから人物ごとに生成する
            if let poseEstimator = animePoseEstimator {
                priorROIs.append(
                    contentsOf: (try? poseEstimator.faceRegionROIs(in: input.image, persons: personsWithMasks)) ?? []
                )
            }
            snapshot = DetectionSnapshot(persons: personsWithMasks, poseHints: hints, rois: priorROIs)
        } else {
            let generator = SensitiveROIGenerator(groinPositionRatio: input.groinPositionRatio)
            snapshot = try StaticImageMosaicPipeline(roiGenerator: generator)
                .generateDetailedCandidates(for: input.image)
        }

        var rois = snapshot.rois
        // 実写の顔領域（目元・眼窩下〜あご）: Visionランドマークから顔ごとに生成する
        if domain == .photo {
            rois.append(contentsOf: (try? faceRegionDetector.detectRegions(in: input.image)) ?? [])
        }
        var animeDetectionCount = 0
        var photoDetectionCount = 0
        let detectorAvailable: Bool
        if domain == .illustration {
            detectorAvailable = animeCensorDetector != nil
            if let detector = animeCensorDetector {
                do {
                    // 全体画像＋人物クロップの多重スケール推論。1ページに複数コマがある漫画では
                    // 小さいコマの対象部位が640px入力で数ピクセルへ縮小され検出できないため
                    // （GUI報告: 下段コマの男性器が自動検出されない）。実写側と同じ方式に揃えた。
                    let detected = try detector.detect(
                        in: input.image,
                        personBounds: snapshot.personBounds
                    )
                    animeDetectionCount = detected.count
                    rois = Self.mergeCandidates(base: rois, adding: detected)
                    rois = Self.dropPoseGroinPriors(from: rois, ifDetectorFound: detected)
                    rois = DetectedROIRefiner.splitNippleAndAreola(rois)
                } catch {
                    detectorFailures.append("アニメ部位検出: \(error.localizedDescription)")
                }
            }
        } else {
            detectorAvailable = photoCensorDetector != nil
            if let detector = photoCensorDetector {
                do {
                    let detected = try detector.detect(in: input.image, personBounds: snapshot.personBounds)
                    photoDetectionCount = detected.count
                    rois = Self.mergeCandidates(base: rois, adding: detected)
                    rois = Self.dropPoseGroinPriors(from: rois, ifDetectorFound: detected)
                    rois = DetectedROIRefiner.splitNippleAndAreola(rois)
                } catch {
                    detectorFailures.append("実写部位検出: \(error.localizedDescription)")
                }
            }
        }

        return CandidateGenerationOutput(
            domain: domain,
            domainSourceNote: domainSourceNote,
            snapshot: snapshot,
            rois: rois,
            animeDetectionCount: animeDetectionCount,
            photoDetectionCount: photoDetectionCount,
            domainDetectorAvailable: detectorAvailable,
            detectorFailureMessage: detectorFailures.isEmpty ? nil : detectorFailures.joined(separator: " / ")
        )
    }

    private static func mergeCandidates(base: [MosaicROI], adding: [MosaicROI]) -> [MosaicROI] {
        var result = base
        for roi in adding {
            result.removeAll { existing in
                existing.source != "manual" && existing.rect.iou(with: roi.rect) > 0.5
            }
            result.append(roi)
        }
        return result
    }

    /// 直接検出器が性器を1つでも検出できた場合、骨格由来の推定鼠径部ROI（source "pose-groin"、
    /// カテゴリは`.other`）は全て取り除く。乳首と同じ理由で、腰関節からの幾何プライアは
    /// 位置精度が低く、人数分だけ「その他」の大きな誤ROIが並ぶ（GUI報告で確定。3人検出で
    /// 「その他1〜3」が生成され、うち1件は下段コマ全体を覆っていた）。カテゴリが`.other`のため
    /// 検出器の性器ROIとはIoUによる重複除去でも統合されず、そのまま残ってしまう。
    /// 検出器が性器を見つけられなかった画像でのみフォールバックとして残す。
    private static func dropPoseGroinPriors(from rois: [MosaicROI], ifDetectorFound detected: [MosaicROI]) -> [MosaicROI] {
        PoseDerivedROIFilter.dropGroinPriors(from: rois, ifDetectorFound: detected)
    }
}

private enum LayerKind: Equatable, Hashable {
    case image
    case roi
    case person(Int)
    case pose(Int)

    var title: String {
        switch self {
        case .image: return "画像"
        case .roi: return "モザイク対象"
        case .person(let index): return "人物\(index + 1)"
        case .pose(let index): return "骨格\(index + 1)"
        }
    }

    var isPerson: Bool { if case .person = self { return true }; return false }
    var isPose: Bool { if case .pose = self { return true }; return false }
}

@MainActor
private final class LayerLeaf {
    let kind: LayerKind
    var isVisible: Bool
    /// レイヤの輪郭（枠線）表示ON/OFF
    var showsOutline = true
    /// レイヤのタグ（名称・カテゴリラベル）表示ON/OFF
    var showsTag = true

    init(kind: LayerKind, isVisible: Bool) {
        self.kind = kind
        self.isVisible = isVisible
    }
}

/// レイヤパネル内「モザイク対象」配下に表示するROI選択リストの1行。
/// 同一カテゴリ名のROIが複数ある場合はタイトルへ連番を付与する。
@MainActor
private final class ROIListEntry {
    let roiID: UUID
    let title: String

    init(roiID: UUID, title: String) {
        self.roiID = roiID
        self.title = title
    }
}

/// ROI選択リストのグループ（`MosaicROI.roiGroupName` が同じROIをまとめたもの）。
@MainActor
private final class ROIListGroup {
    var name: String
    var children: [ROIListEntry]

    init(name: String, children: [ROIListEntry]) {
        self.name = name
        self.children = children
    }
}

@MainActor
private final class LayerGroup {
    var name: String
    var children: [LayerLeaf]

    init(name: String, children: [LayerLeaf]) {
        self.name = name
        self.children = children
    }

    var visibilityState: NSControl.StateValue {
        guard !children.isEmpty else { return .off }
        let visibleCount = children.filter(\.isVisible).count
        if visibleCount == 0 { return .off }
        if visibleCount == children.count { return .on }
        return .mixed
    }
}

@MainActor
private final class LayerRowView: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let label = NSTextField(labelWithString: "")
    var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        checkbox.title = ""
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.target = self
        checkbox.action = #selector(handleToggle)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = MosaicWindowController.scaledFont(12)
        // lineBreakModeの設定がalignmentを既定（末尾寄せ表示）へ戻してしまうAppKitの癖があるため、
        // alignmentはlineBreakModeの後に設定し、さらにconfigure()でも毎回再設定する
        // （「レイヤ名が右寄せになる」デグレの恒久対策）。
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .left
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(checkbox)
        addSubview(label)
        // ラベルのtrailingを行末へ固定するとラベルが行幅いっぱいへ引き伸ばされ、テキストの
        // 寄せ設定次第で右端に表示されてしまう（alignment指定・属性付き文字列でも環境により
        // 右寄せ表示になるデグレが再発した）。trailingは「はみ出さない」上限（<=）だけにして
        // ラベル幅を内容幅に保ち、フレーム自体をチェックボックス直後（左側）へ置く。
        // これでテキスト寄せ設定に関係なく、見た目は常に左寄せになる。
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2)
        ])
    }

    func configure(
        title: String,
        state: NSControl.StateValue,
        allowsMixed: Bool,
        showsCheckbox: Bool = true
    ) {
        // stringValue更新後にも左寄せを強制する（属性付き文字列で段落スタイルまで明示し、
        // フォント・lineBreakMode変更によるalignmentリセットの影響を受けないようにする）。
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        label.attributedStringValue = NSAttributedString(string: title, attributes: [
            .font: MosaicWindowController.scaledFont(12),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        checkbox.allowsMixedState = allowsMixed
        checkbox.state = state
        checkbox.isHidden = !showsCheckbox
    }

    @objc private func handleToggle() {
        onToggle?()
    }
}

/// 追跡プレビューを目標フレームで打ち切るための内部シグナル
/// （`readFrames`のハンドラから投げて走査を止める。エラーではない）。
private enum TrackingPreviewStop: Error {
    case reachedTarget
}

/// 動画プレビュー再生ビュー（V2）。
/// AVKitの`AVPlayerView`はSwiftPMの実行ファイルターゲットからリンクできない（SwiftUICore依存）ため、
/// `AVPlayerLayer`＋最小限の再生コントロール（再生/一時停止・シークバー・時刻表示）を自前で構成する。
/// 編集は行わず、確認用の再生に徹する（編集はV3のキャンバス側で行う）。
@MainActor
private final class VideoPreviewView: NSView {
    private let player: AVPlayer
    private let playerLayer = AVPlayerLayer()
    private let playPauseButton = NSButton(title: "▶", target: nil, action: nil)
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private var timeObserver: Any?
    private var durationSeconds: Double = 0

    init(url: URL) {
        player = AVPlayer(url: url)
        super.init(frame: .zero)
        wantsLayer = true
        // 純黒は白基調の漫画原稿に対してコントラストが強すぎるため、
        // 標準のアンダーページ色（画像編集アプリの一般的な台紙色）を使う
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)

        playPauseButton.target = self
        playPauseButton.action = #selector(togglePlay)
        playPauseButton.bezelStyle = .rounded
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.widthAnchor.constraint(equalToConstant: 44).isActive = true

        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.font = MosaicWindowController.scaledMonospacedDigitFont(11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let controls = NSStackView(views: [playPauseButton, slider, timeLabel])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.heightAnchor.constraint(equalToConstant: 36)
        ])

        // 再生位置の追従（0.2秒間隔。シーク中はスライダーを更新しない）
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.updateProgress(currentSeconds: CMTimeGetSeconds(time)) }
        }
        let seconds = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        if seconds.isFinite, seconds > 0 {
            durationSeconds = seconds
            slider.maxValue = seconds
        }
        updateProgress(currentSeconds: 0)
    }

    required init?(coder: NSCoder) { nil }

    /// 再生停止＋時刻オブザーバの解除。ウィンドウを閉じる際に必ず呼ぶ
    /// （deinitからは`@MainActor`隔離のプロパティへ触れられないため、明示的な後始末とする）。

    override func layout() {
        super.layout()
        // 下部36ptはコントロール用に空ける
        playerLayer.frame = CGRect(x: 0, y: 36, width: bounds.width, height: max(0, bounds.height - 36))
    }

    /// 再生停止・時刻オブザーバの解除・コントロールのtarget解除。
    ///
    /// **必ず呼ぶこと**（ウィンドウを閉じるとき・差し替えるとき）。呼ばないと:
    /// - AVPlayerが再生を続け、時刻オブザーバも登録されたまま残る
    /// - ボタン/スライダーの`target`が解放済みの自分自身を指したままになり、
    ///   その後の操作で解放済みメモリへメッセージが飛ぶ（クラッシュ報告 2026-08-02。
    ///   `@objc VideoPreviewView.togglePlay()` 内の `objc_msgSend` で EXC_BAD_ACCESS）
    ///
    /// 何度呼んでも安全（冪等）。
    func stop() {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        playerLayer.player = nil
        playPauseButton.target = nil
        playPauseButton.action = nil
        slider.target = nil
        slider.action = nil
    }

    @objc private func togglePlay() {
        if player.timeControlStatus == .playing {
            player.pause()
            playPauseButton.title = "▶"
        } else {
            player.play()
            playPauseButton.title = "❚❚"
        }
    }

    @objc private func sliderChanged() {
        player.seek(
            to: CMTime(seconds: slider.doubleValue, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        updateProgress(currentSeconds: slider.doubleValue)
    }

    private func updateProgress(currentSeconds: Double) {
        if !slider.isHighlighted, currentSeconds.isFinite {
            slider.doubleValue = currentSeconds
        }
        timeLabel.stringValue = "\(Self.timeText(currentSeconds)) / \(Self.timeText(durationSeconds))"
        if player.timeControlStatus != .playing, playPauseButton.title != "▶" {
            playPauseButton.title = "▶"
        }
    }

    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// ライブラリ一覧で上下（左右）矢印キーによる画像切替と、Deleteキーによる削除を可能にするテーブルビュー。
@MainActor
private final class NavigableTableView: NSTableView {
    var onNavigate: ((Int) -> Void)?
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
            return
        }
        switch Int(event.specialKey?.rawValue ?? 0) {
        case Int(NSUpArrowFunctionKey), Int(NSLeftArrowFunctionKey):
            onNavigate?(-1)
        case Int(NSDownArrowFunctionKey), Int(NSRightArrowFunctionKey):
            onNavigate?(1)
        default:
            super.keyDown(with: event)
        }
    }
}

/// ライブラリ一覧（グリッド表示）で矢印キーによる画像切替と、Deleteキーによる削除を可能にするコレクションビュー。
@MainActor
private final class NavigableCollectionView: NSCollectionView {
    var onNavigate: ((Int) -> Void)?
    var onDelete: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
            return
        }
        switch Int(event.specialKey?.rawValue ?? 0) {
        case Int(NSUpArrowFunctionKey), Int(NSLeftArrowFunctionKey):
            onNavigate?(-1)
        case Int(NSDownArrowFunctionKey), Int(NSRightArrowFunctionKey):
            onNavigate?(1)
        default:
            super.keyDown(with: event)
        }
    }
}

/// 動画キーフレーム一覧では左右キーを「行内移動」ではなく前後キーフレーム移動として扱う。
/// Enterは選択行を確定して、そのキーフレーム時刻をキャンバスへ開く。
@MainActor
private final class VideoKeyframeTableView: NSTableView {
    var onNavigate: ((Int) -> Void)?
    var onOpenSelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch Int(event.specialKey?.rawValue ?? 0) {
        case Int(NSLeftArrowFunctionKey):
            onNavigate?(-1)
        case Int(NSRightArrowFunctionKey):
            onNavigate?(1)
        default:
            if event.keyCode == 36 || event.keyCode == 76 {
                onOpenSelection?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

@MainActor
private final class VideoTimelineSlider: NSSlider {
    var keyframeTimes: [Double] = [] {
        didSet { needsDisplay = true }
    }
    var durationSeconds: Double = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard durationSeconds > 0, !keyframeTimes.isEmpty else { return }
        let trackInset: CGFloat = 12
        let usableWidth = max(1, bounds.width - trackInset * 2)
        let markerTop = bounds.midY - 9
        let markerBottom = bounds.midY + 9
        NSColor.controlAccentColor.setFill()
        for time in keyframeTimes {
            let ratio = min(1, max(0, time / durationSeconds))
            let x = trackInset + usableWidth * CGFloat(ratio)
            let marker = NSBezierPath()
            marker.move(to: NSPoint(x: x, y: markerTop))
            marker.line(to: NSPoint(x: x - 4, y: markerBottom))
            marker.line(to: NSPoint(x: x + 4, y: markerBottom))
            marker.close()
            marker.fill()
        }
    }
}

@MainActor
final class MosaicWindowController: NSObject {
    private(set) var view = NSView()

    private let imageLoader = ImageLoader()
    private let candidateGenerationWorker = CandidateGenerationWorker()
    private let mosaicEngine = MosaicEngine()
    private let historyEngine = HistoryEngine()
    private let libraryEngine: LibraryEngine = (try? LibraryEngine.defaultLibrary())
        ?? LibraryEngine(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("newMosaic/Library"))
    private let learningEngine: LearningEngine? = try? LearningEngine.defaultStore()
    /// 学習モード（ユーザーの修正結果を学習データとして記録し、候補生成へ反映するか）。
    ///
    /// 既定はOFF。以前は常に学習しており、テスト用に描いたROIまで学習されて、
    /// 別の人物へ誤った候補が提案されていた（GUI報告 2026-07-31）。
    /// 学習するかどうかはユーザーが決める、という方針にした。
    static let learningModeDefaultsKey = "Learning.Enabled"
    private let learningModeButton = SquareIconButton()
    private var isLearningModeEnabled: Bool {
        AppSettings.shared.object(forKey: Self.learningModeDefaultsKey) as? Bool ?? false
    }
    // MARK: 動画対応（MosaicVideoKitプラグイン）
    /// 動画サムネイル（LRUキャッシュ付き）。
    private let videoThumbnailProvider = VideoThumbnailProvider()
    /// 動画のキーフレームROI保存（ライブラリ配下のサイドカーJSON）。
    private lazy var videoEditStore = VideoEditStore(libraryRootURL: libraryEngine.rootURL)
    /// 動画プレビュー再生ウィンドウ（V2。編集は行わない）。
    private var videoPreviewWindow: NSWindow?
    // MARK: 動画編集（V3）
    /// キャンバス＋タイムラインを縦に積むコンテナ（静止画ではタイムラインは非表示）。
    private let canvasContainer = NSView()
    private let videoTimelineBar = NSView()
    private let videoTimeSlider = VideoTimelineSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let videoTimeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let videoKeyframeCountLabel = NSTextField(labelWithString: "キーフレーム 0件")
    private let videoKeyframeTableView = VideoKeyframeTableView()
    private let videoPlayButton = SquareIconButton()
    private let videoPauseButton = SquareIconButton()
    private let videoStopButton = SquareIconButton()
    private let analysisStopButton = NSButton(title: "停止", target: nil, action: nil)
    private var isAutoProcessingVideo = false
    private var videoAutoProcessCancellation: VideoMosaicExporter.CancellationFlag?
    private var candidateGenerationID: UUID?
    private var cancelledCandidateGenerationIDs: Set<UUID> = []
    private var videoPlaybackTimer: Timer?
    private let videoPreviewRenderQueue = DispatchQueue(label: "com.yoshikawa.newMosaic.videoPreviewRender", qos: .userInitiated)
    private lazy var videoPlaybackRenderer = VideoPlaybackRenderer(segmentEngine: Self.videoPlaybackSegmentEngine())
    private var videoSeekRequestID = 0
    private var videoPlaybackRenderInFlight = false
    private var pendingVideoPlaybackSeekSeconds: Double?
    private var videoPlaybackStartedAt: Date?
    private var videoPlaybackStartTimeSeconds: Double = 0
    private var isVideoPlaying = false
    private var lastTrackedVideoTimeSeconds: Double?
    /// 編集中の動画（nil=静止画編集中）。
    private var currentVideoItem: MosaicLibraryItem?
    private var currentVideoInfo: VideoInfo?
    private var currentVideoEditState = VideoEditState()
    private var currentVideoTimeSeconds: Double = 0
    /// 追跡プレビューで見失ったROIのID（キャンバス上で警告表示するため保持）。
    private var videoTrackingLostIDs: Set<UUID> = []
    // MARK: 動画書き出し（V4）
    private var videoExportSheet: NSWindow?
    private var videoExportCancellation: VideoMosaicExporter.CancellationFlag?
    private let videoExportProgressBar = NSProgressIndicator()
    private let videoExportProgressLabel = NSTextField(labelWithString: "")
    private let canvas = ImageCanvasView()
    private let statusLabel = NSTextField(labelWithString: "画像を開いてください")
    private let tableView = NavigableTableView()
    private let collectionView = NavigableCollectionView()
    private let libraryScrollView = NSScrollView()
    private let viewModeControl = NSSegmentedControl(
        labels: ["グリッド", "テキスト", "サムネイル"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let thumbnailSizeSlider = NSSlider(value: 120, minValue: 64, maxValue: 220, target: nil, action: nil)
    /// サムネイルグリッド表示以外（テキスト/サムネイルリスト表示）では無効表示にする
    /// （`updateLibraryModeVisibility()`参照。グリッド以外ではサムネイルサイズに意味がないため）。
    private let thumbSmallerButton = SquareIconButton()
    private let thumbLargerButton = SquareIconButton()
    /// 画像が開かれている時だけ有効にするツールバーボタン（候補生成・適用・全レイヤ削除など）。
    private var imageDependentToolbarButtons: [NSButton] = []
    private let undoButton = NSButton(title: "元に戻す", target: nil, action: nil)
    private let redoButton = NSButton(title: "やり直す", target: nil, action: nil)
    private let zoomLabel = NSTextField(labelWithString: "100%")
    /// ツールバーのモード切替（編集モード/範囲選択モード）。既定は編集モード（従来通りの挙動）。
    /// Option(⌥)キーを押しながらのドラッグで、そのドラッグ限定に一時的にモードを入れ替えられる。
    /// マスク追加ペン／マスク消しゴムの太さ設定。いずれかのモードのときだけ表示する。
    private let maskBrushSlider = NSSlider(value: 0.15, minValue: 0.01, maxValue: 0.6, target: nil, action: nil)
    private let maskBrushValueLabel = NSTextField(labelWithString: "15 %")
    private var maskBrushRow: NSView?

    private let canvasModeControl = NSSegmentedControl(
        labels: ["", "", "", ""],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let shapeControl = NSSegmentedControl(
        labels: ["矩形", "楕円", "多角形"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    // レイヤパネル先頭の表示トグル（ツールバーから移設）
    private let personLayerCheckbox = NSButton(checkboxWithTitle: "人物", target: nil, action: nil)
    private let poseLayerCheckbox = NSButton(checkboxWithTitle: "骨格", target: nil, action: nil)
    private let roiLayerCheckbox = NSButton(checkboxWithTitle: "ROI", target: nil, action: nil)
    /// 全レイヤ一括の輪郭/タグ表示ON/OFF（旧: レイヤ行毎の個別設定から変更）。
    private let layerOutlineAllCheckbox = NSButton(checkboxWithTitle: "輪郭", target: nil, action: nil)
    private let layerTagAllCheckbox = NSButton(checkboxWithTitle: "タグ", target: nil, action: nil)
    // 対象カテゴリ（複数チェック可。候補生成時にチェックされたものだけを生成する）
    private let categoryFilterChecks: [(category: MosaicTargetCategory, button: NSButton)] =
        MosaicTargetCategory.allCases.map { ($0, NSButton(checkboxWithTitle: $0.displayName, target: nil, action: nil)) }
    private let generatePersonCheckbox = NSButton(checkboxWithTitle: "人物", target: nil, action: nil)
    private let generatePoseCheckbox = NSButton(checkboxWithTitle: "骨格", target: nil, action: nil)
    private let segmentEngineControl = NSPopUpButton(title: "", target: nil, action: nil)
    private let domainModeControl = NSPopUpButton(title: "", target: nil, action: nil)
    private static let domainModeDefaultsKey = "DetectionDomainMode"
    private let layerOutlineView = NSOutlineView()
    private let groupButton = NSButton(title: "グループ化", target: nil, action: nil)
    private let ungroupButton = NSButton(title: "グループ解除", target: nil, action: nil)
    private let autoGenerateCheckbox = NSButton(checkboxWithTitle: "自動候補生成", target: nil, action: nil)
    private let autoSaveCheckbox = NSButton(checkboxWithTitle: "自動保存", target: nil, action: nil)
    private let mosaicPreviewCheckbox = NSButton(checkboxWithTitle: "モザイク", target: nil, action: nil)
    /// レイヤパネル「表示:」の「モザイク」既定値。ONのとき、画像を開いた直後からモザイク表示で始まる。
    private static let mosaicPreviewDefaultKey = "Layer.mosaicVisibleDefault"
    private var mosaicPreviewDefaultOn: Bool {
        AppSettings.shared.object(forKey: Self.mosaicPreviewDefaultKey) as? Bool ?? true
    }
    private let groinPositionSlider = NSSlider(value: 0.45, minValue: 0.2, maxValue: 0.8, target: nil, action: nil)
    private let groinPositionValueLabel = NSTextField(labelWithString: "45%")
    private static let groinPositionDefaultsKey = "GroinPositionRatio"
    /// マスク生成「対象形状」の補助しきい値（0=自動のみ。上げるほどマスクを締める）
    /// 「検出」設定を選択中レイヤだけに適用するか（ONで他レイヤのマスク・モザイクへ影響を与えない）。
    private let individualDetectionCheckbox = NSButton(checkboxWithTitle: "個別", target: nil, action: nil)
    private static let individualDetectionDefaultsKey = "Detection.individual"
    private let maskThresholdSlider = NSSlider(value: 0, minValue: 0, maxValue: 0.9, target: nil, action: nil)
    private let maskThresholdValueLabel = NSTextField(labelWithString: "自動")
    private static let maskThresholdDefaultsKey = "RegionMaskThreshold"

    // モザイク描画スタイル設定（右側インスペクタへ常設。選択ROIごとに個別保持）
    /// 選択中レイヤの設定継承状態（下部ステータスバーへ表示。nilなら選択なし＝表示しない）。
    private var selectedLayerStatusSummary: String?
    private let applyStyleToAllButton = NSButton(title: "全レイヤ適用", target: nil, action: nil)
    /// パターン選択の実体（状態保持用）。UI表示はタイル（`patternTileButtons`）へ置き換えたため非表示。
    private let stylePatternPopUp = NSPopUpButton(title: "", target: nil, action: nil)
    /// パターン選択のプレビューアイコンタイル（`MosaicFillPattern.allCases` と同順）。
    private var patternTileButtons: [NSButton] = []
    private let styleOpacitySlider = NSSlider(value: 1.0, minValue: 0.1, maxValue: 1.0, target: nil, action: nil)
    private let styleOpacityValueLabel = NSTextField(labelWithString: "100%")
    private let styleTintCheckbox = NSButton(checkboxWithTitle: "色を付ける", target: nil, action: nil)
    private let styleTintColorWell: NSColorWell = {
        let well = NSColorWell()
        // 幅制約が無いとスタック内で横いっぱいへ伸び、他の設定行と見た目が揃わない
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        well.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return well
    }()
    private let styleBlockScaleSlider = NSSlider(value: 28, minValue: 4, maxValue: 80, target: nil, action: nil)
    private let styleBlockScaleValueLabel = NSTextField(labelWithString: "28")
    private let styleFeatherSlider = NSSlider(value: 0, minValue: 0, maxValue: 40, target: nil, action: nil)
    private let styleFeatherValueLabel = NSTextField(labelWithString: "0px")
    private let styleStripeWidthSlider = NSSlider(value: 12, minValue: 2, maxValue: 60, target: nil, action: nil)
    private let styleStripeWidthValueLabel = NSTextField(labelWithString: "12px")
    private let styleStripeSpacingSlider = NSSlider(value: 12, minValue: 0, maxValue: 60, target: nil, action: nil)
    private let styleStripeSpacingValueLabel = NSTextField(labelWithString: "12px")
    /// ボーダー: 方向（縦/横）。ランダムON時も方向設定は有効（太さ・間隔のみランダム化される）。
    private let styleBorderDirectionControl = NSSegmentedControl(
        labels: ["縦", "横"], trackingMode: .selectOne, target: nil, action: nil
    )
    private let styleBorderRandomCheckbox = NSButton(checkboxWithTitle: "ランダム", target: nil, action: nil)
    private let styleBorderToneCheckbox = NSButton(checkboxWithTitle: "トーン", target: nil, action: nil)
    /// すべてのパターンで使える網点（漫画トーン風）のON/OFF。
    private let stylePatternToneCheckbox = NSButton(checkboxWithTitle: "トーン", target: nil, action: nil)
    /// ボーダー: 並行揺れ（各線を中央軸にランダムで傾ける度合い。「ランダム」のON/OFFに関わらず有効）
    private let styleStripeWobbleSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let styleStripeWobbleValueLabel = NSTextField(labelWithString: "0 %")
    /// フラッシュ: 種別（集中線 / ベタフラッシュ / ウニフラッシュ）
    private let styleFlashKindControl = NSSegmentedControl(
        labels: MosaicFlashKind.allCases.map(\.displayName), trackingMode: .selectOne, target: nil, action: nil
    )
    private let styleCloudDensitySlider = NSSlider(value: 0.5, minValue: 0.1, maxValue: 1.0, target: nil, action: nil)
    private let styleCloudDensityValueLabel = NSTextField(labelWithString: "50%")
    private let styleCloudToneCheckbox = NSButton(checkboxWithTitle: "トーン", target: nil, action: nil)
    /// フラッシュ: 中心位置は画像上のハンドルをドラッグして指定する（既定はROI中心）。
    private let styleFlashResetButton = NSButton(title: "中心をリセット", target: nil, action: nil)
    /// モザイク詳細設定のグリッド（パターン切替時に関連する設定行だけを表示するための参照）。
    private var styleGridView: NSGridView?
    private let stylePatternImageButton = NSButton(title: "画像選択...", target: nil, action: nil)
    private let stylePatternImageLabel = NSTextField(labelWithString: "未選択")
    private var customPatternImage: CGImage?
    private var customPatternImageIdentifier: String?
    /// フラッシュパターンの中心位置（ROIローカル正規化座標）。画像上のハンドルドラッグで更新される。
    /// nilはROI中心を使う。`customPatternImage`同様、コントロール化していない実行時状態。
    private var pendingFlashCenter: NormalizedPoint?
    /// 候補生成時の人物シルエット（未着色・全体フレーム）。人物レイヤ由来ROI（source
    /// "person-layer-N"）のモザイクを人物の輪郭に沿わせるために使う。表示用の着色版
    /// （canvas.personLayerMasks）とは別に保持し、レイヤ移動時は同じ量だけ平行移動する。
    private var personMaskImages: [CGImage?] = []
    private var patternImageCache: [String: CGImage] = [:]
    /// `patternImageCache`のLRU順（末尾が最新）。ファイル選択のたびに新規UUIDでキャッシュへ
    /// 追加され続け際限なく増える不具合があったため、上限を超えたら古いものから破棄する
    /// （コードレビューで検出）。
    private var patternImageCacheOrder: [String] = []
    private static let patternImageCacheLimit = 40
    private var ungroupedLayers: [LayerLeaf] = [
        LayerLeaf(kind: .image, isVisible: true),
        LayerLeaf(kind: .roi, isVisible: true)
    ]
    private var layerGroups: [LayerGroup] = []
    /// レイヤパネル「モザイク対象」配下のROI選択リスト（同一カテゴリ名は連番付き。フラット・全件）
    private var roiListEntries: [ROIListEntry] = []
    /// ROI選択リストのグループ（`MosaicROI.roiGroupName` 単位）。表示順に構築する。
    private var roiListGroups: [ROIListGroup] = []
    /// どのグループにも属さないROI選択リスト行（表示順）。
    private var ungroupedROIEntries: [ROIListEntry] = []
    private var roiListSignature: [String] = []
    private var isSyncingROISelection = false
    private var loadedImage: LoadedImage?
    private var renderedImage: CGImage?
    private var currentLibraryItem: MosaicLibraryItem?
    private var libraryItems: [MosaicLibraryItem] = []
    private var libraryViewMode: LibraryViewMode = .thumbnailGrid
    private var selectedLibraryItemID: UUID?
    // 処理済みフラグ・テキスト検索フィルタ、列ソート状態
    private var libraryProcessedFilter: LibraryProcessedFilter = .all
    private var libraryKindFilter: LibraryKindFilter = .all
    private var libraryFormatFilter: String?
    private var librarySearchText: String = ""
    private var librarySortKey: LibrarySortKey = .updatedAt
    private var librarySortAscending: Bool = false
    private let libraryProcessedFilterControl = NSSegmentedControl(
        labels: ["すべて", "未処理", "処理済"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let libraryMediaFilterButton = SquareIconButton()
    private let librarySearchField = NSSearchField()
    private var libraryThumbnailColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("thumbnail"))
    private var libraryNameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    private var libraryStatusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
    private var libraryKindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
    private var libraryResolutionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("resolution"))
    private var libraryROIColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("roi"))
    private var libraryUpdatedColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("updated"))

    /// 現在の処理済みフィルタ・検索テキスト・ソート設定を適用したライブラリ表示用配列。
    /// 一覧・選択・キー操作（カーソルキー移動等）はすべてこの配列を基準に動作する
    /// （libraryItems自体はフィルタの影響を受けない全件リストとして保持する）。
    private var displayedLibraryItems: [MosaicLibraryItem] {
        var items = libraryItems
        switch libraryProcessedFilter {
        case .all: break
        case .unprocessed: items = items.filter { $0.processedRelativePath == nil }
        case .processed: items = items.filter { $0.processedRelativePath != nil }
        }
        switch libraryKindFilter {
        case .all: break
        case .image: items = items.filter { !$0.isVideo }
        case .video: items = items.filter(\.isVideo)
        }
        if let libraryFormatFilter {
            items = items.filter { Self.libraryFileFormat(for: $0) == libraryFormatFilter }
        }
        if !librarySearchText.isEmpty {
            let needle = librarySearchText
            items = items.filter { $0.sourceName.localizedCaseInsensitiveContains(needle) }
        }
        let ascending = librarySortAscending
        switch librarySortKey {
        case .name:
            items.sort {
                let order = $0.sourceName.localizedStandardCompare($1.sourceName)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        case .status:
            items.sort {
                let lhs = $0.processedRelativePath != nil
                let rhs = $1.processedRelativePath != nil
                return ascending ? (!lhs && rhs) : (lhs && !rhs)
            }
        case .kind:
            items.sort {
                let lhs = $0.isVideo ? 1 : 0
                let rhs = $1.isVideo ? 1 : 0
                if lhs == rhs {
                    return $0.sourceName.localizedStandardCompare($1.sourceName) == .orderedAscending
                }
                return ascending ? lhs < rhs : lhs > rhs
            }
        case .resolution:
            items.sort {
                let lhs = $0.imagePixelWidth * $0.imagePixelHeight
                let rhs = $1.imagePixelWidth * $1.imagePixelHeight
                return ascending ? lhs < rhs : lhs > rhs
            }
        case .roiCount:
            items.sort { ascending ? $0.rois.count < $1.rois.count : $0.rois.count > $1.rois.count }
        case .updatedAt:
            items.sort { ascending ? $0.updatedAt < $1.updatedAt : $0.updatedAt > $1.updatedAt }
        }
        return items
    }
    private var thumbnailCache: [UUID: NSImage] = [:]
    private var thumbnailCacheUpdatedAt: [UUID: Date] = [:]
    /// `thumbnailCache`のLRU順（末尾が最新）。
    private var thumbnailCacheOrder: [UUID] = []
    /// サムネイル1枚は240ptで約230KB。ライブラリが数千件になると無制限では数百MBになるため上限を設ける。
    private static let thumbnailCacheLimit = 300
    private var undoStack: [EditorState] = []
    private var redoStack: [EditorState] = []
    private var hasUnsavedChanges = false
    private var lastAutoROIs: [MosaicROI] = []
    private var lastPersonBounds: [NormalizedRect] = []
    private var learnedROIIDs: Set<UUID> = []

    /// 画像（ライブラリアイテム）ごとの編集状態。エクスポート/加工確定に関わらずセッション内で保持し、
    /// 画像を切り替えて戻ってきたときにROI・検出レイヤ・アンドゥ履歴・モザイク表示状態を復元する。
    /// 画像を切り替えても編集内容を保つための退避データ。
    ///
    /// **描画済み画像は保持しない。** フル解像度のCGImageはA4・300dpiで1枚34.8MBあり、
    /// 最大`imageEditStateLimit`枚ぶん常駐していた。ROIから作り直せるので保持しない
    /// （ARCHITECTURE §5.49.3）。人物マスクはAI推論が必要で作り直しが高価なため保持する。
    private struct PerImageEditState {
        var rois: [MosaicROI]
        var mosaicPreviewOn: Bool
        var personLayerRects: [NormalizedRect]
        var personLayerMasks: [CGImage?]
        var personMaskImages: [CGImage?]
        var poseLayerRects: [NormalizedRect]
        var poseLayerBones: [[(from: CGPoint, to: CGPoint)]]
        var poseLayerJointPoints: [[CGPoint]]
        var undoStack: [EditorState]
        var redoStack: [EditorState]
        var hasUnsavedChanges: Bool
        var lastAutoROIs: [MosaicROI]
        var lastPersonBounds: [NormalizedRect]
        var learnedROIIDs: Set<UUID>
    }

    private var imageEditStates: [UUID: PerImageEditState] = [:]
    private var imageEditStateOrder: [UUID] = []
    /// 画像切替で編集内容を保つ枚数。1枚あたり人物マスク（フル解像度グレー）を人数分×2系統
    /// 保持するため、A4・300dpiで4人なら約70MBになる。8枚では約560MBに達したので3枚とする。
    private let imageEditStateLimit = 3
    private var rightPaneSplitView: NSSplitView?
    private var leftPaneSplitView: NSSplitView?
    private var mainSplitView: NSSplitView?
    private var isRestoringSplitPositions = false
    // 一括処理の進捗UI
    private var isBatchProcessing = false
    // 下部ステータス兼ヘルプバー
    private let statsLabel = NSTextField(labelWithString: "")
    private var hoverRelays: [HoverHelpRelay] = []
    // ツールバーアイコンボタン（詳細設定のアイコンサイズ変更で一括リサイズするために保持）
    private var toolbarIconButtons: [NSButton] = []
    private var advancedSettingsWindow: NSWindow?
    // 画像出力ウィンドウ
    private var exportWindow: NSWindow?
    private var exportSourceImage: CGImage?
    private var exportOriginalImage: CGImage?
    private var exportSourceName = "export"
    private var exportFolderURL: URL?
    private let exportFilenameField = NSTextField(string: "")
    private let exportFolderLabel = NSTextField(labelWithString: "")
    private let exportFormatPopUp = NSPopUpButton(title: "", target: nil, action: nil)
    private let exportQualitySlider = NSSlider(value: 92, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let exportQualityValueLabel = NSTextField(labelWithString: "92 %")
    private let exportDPIField = NSTextField(string: "350")
    private let exportIncludeOriginalLayerCheckbox = NSButton(
        checkboxWithTitle: "元画像レイヤを含める（非表示レイヤとして追加）",
        target: nil,
        action: nil
    )
    private let exportPreserveTransparencyCheckbox = NSButton(
        checkboxWithTitle: "透明を保持する（オフで白背景に統合）",
        target: nil,
        action: nil
    )
    private let exportPreviewFullImageView = NSImageView()
    private let exportPreviewZoomImageView = NSImageView()
    private let exportFormatNoteLabel = NSTextField(labelWithString: "")
    private let iconSizeControl = NSSegmentedControl(
        labels: ["小", "中", "大"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private static let iconSizeDefaultsKey = "AdvancedSettings.iconSize"
    private static let textSizeDefaultsKey = "AdvancedSettings.textSize"
    private let textSizeControl = NSSegmentedControl(
        labels: ["小", "中", "大"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    /// 詳細設定「動画の自動追随」のコントロール（v0.0.00136）
    private let videoAutoRedetectCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let videoRedetectIntervalPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let videoSceneCutCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let videoLostExpansionCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    /// `applyScaledFont(_:size:weight:)` で登録された静的コントロール。テキストサイズ変更時に
    /// このリストを走査してフォントを再適用する。
    private var scaledTextControls: [(control: NSControl, baseSize: CGFloat, weight: NSFont.Weight)] = []
    private static let recentProjectsDefaultsKey = "RecentProjects"
    // Win/Mac両対応の4文字拡張子（newMosaic Config の略）。旧 "newmosaicproj" は冗長なため短縮。
    private static let projectFileExtension = "nmcf"

    // MARK: テンキー割当（詳細設定）・ショートカット一覧（ヘルプ）
    private static let numpadAssignmentsDefaultsKey = "AdvancedSettings.numpadAssignments"
    private var numpadEventMonitor: Any?
    private var videoShortcutEventMonitor: Any?
    private var shortcutsWindow: NSWindow?
    private var numpadAssignmentWindow: NSWindow?
    private var debugLogWindow: NSWindow?
    private var debugLogTextView: NSTextView?

    /// アプリ内の全ショートカット対応操作の一覧（唯一の情報源）。
    /// メニュー構築・ツールバーのツールチップ・ヘルプ＞ショートカット一覧・
    /// 詳細設定＞テンキー割当のすべてがここを参照する。
    static let appShortcuts: [AppShortcut] = [
        AppShortcut(id: "openImage", category: "ファイル", title: "画像を開く",
                    key: "o", modifiers: [.command], isRecommended: true, action: #selector(openImage)),
        AppShortcut(id: "openVideo", category: "ファイル", title: "動画を開く",
                    key: "o", modifiers: [.command, .shift], isRecommended: true, action: #selector(openVideo)),
        AppShortcut(id: "pasteImage", category: "ファイル", title: "クリップボードから読み込む",
                    key: "v", modifiers: [.command], isRecommended: false, action: #selector(pasteImage)),
        AppShortcut(id: "exportImage", category: "ファイル", title: "画像出力",
                    key: "s", modifiers: [.command], isRecommended: true, action: #selector(exportImage)),
        AppShortcut(id: "revealLibrary", category: "ファイル", title: "ライブラリをFinderで表示",
                    key: "", modifiers: [], isRecommended: false, action: #selector(revealLibrary)),
        AppShortcut(id: "performUndo", category: "編集", title: "元に戻す",
                    key: "z", modifiers: [.command], isRecommended: true, action: #selector(performUndo)),
        AppShortcut(id: "performRedo", category: "編集", title: "やり直す",
                    key: "z", modifiers: [.command, .shift], isRecommended: true, action: #selector(performRedo)),
        AppShortcut(id: "clearROIs", category: "編集", title: "全レイヤ削除",
                    key: "", modifiers: [], isRecommended: false, action: #selector(clearROIs)),
        AppShortcut(id: "generateCandidates", category: "処理", title: "自動候補生成",
                    key: "g", modifiers: [.command], isRecommended: true, action: #selector(generateCandidates)),
        AppShortcut(id: "applyMosaic", category: "処理", title: "モザイクを適用",
                    key: "\r", modifiers: [.command], isRecommended: true, action: #selector(applyMosaic)),
        AppShortcut(id: "zoomIn", category: "表示", title: "拡大",
                    key: "+", modifiers: [.command], isRecommended: false, action: #selector(zoomIn)),
        AppShortcut(id: "zoomOut", category: "表示", title: "縮小",
                    key: "-", modifiers: [.command], isRecommended: false, action: #selector(zoomOut)),
        AppShortcut(id: "zoomToFit", category: "表示", title: "ウィンドウに合わせる",
                    key: "0", modifiers: [.command], isRecommended: false, action: #selector(zoomToFit)),
        AppShortcut(id: "openSelectedLibraryOriginal", category: "ライブラリ", title: "元画像/動画を開く",
                    key: "", modifiers: [], isRecommended: false, action: #selector(openSelectedLibraryOriginal)),
        AppShortcut(id: "toggleVideoPlayback", category: "動画", title: "動画の再生／一時停止",
                    key: " ", modifiers: [], isRecommended: true, action: #selector(toggleVideoPlayback)),
        AppShortcut(id: "stepToPreviousVideoFrame", category: "動画", title: "1フレーム前へ",
                    key: "<", modifiers: [.command], isRecommended: true, action: #selector(stepToPreviousVideoFrame)),
        AppShortcut(id: "stepToNextVideoFrame", category: "動画", title: "1フレーム後へ",
                    key: ">", modifiers: [.command], isRecommended: true, action: #selector(stepToNextVideoFrame)),
        AppShortcut(id: "jumpToPreviousKeyframe", category: "動画", title: "前のキーフレームへ",
                    key: "<", modifiers: [], isRecommended: false, action: #selector(jumpToPreviousKeyframe)),
        AppShortcut(id: "jumpToNextKeyframe", category: "動画", title: "次のキーフレームへ",
                    key: ">", modifiers: [], isRecommended: false, action: #selector(jumpToNextKeyframe)),
        AppShortcut(id: "addVideoKeyframe", category: "動画", title: "キーフレーム追加",
                    key: "k", modifiers: [.command], isRecommended: true, action: #selector(addVideoKeyframe)),
        AppShortcut(id: "removeVideoKeyframe", category: "動画", title: "キーフレーム削除",
                    key: "", modifiers: [], isRecommended: false, action: #selector(removeVideoKeyframe)),
        AppShortcut(id: "deleteSelectedVideoKeyframes", category: "動画", title: "選択キーフレーム削除",
                    key: "k", modifiers: [.command, .option], isRecommended: false, action: #selector(deleteSelectedVideoKeyframes)),
        AppShortcut(id: "openSelectedVideoKeyframe", category: "動画", title: "一覧の選択キーフレームへ移動",
                    key: "\r", modifiers: [], isRecommended: false, action: #selector(openSelectedVideoKeyframe)),
        AppShortcut(id: "deleteAllVideoKeyframes", category: "動画", title: "全キーフレーム削除",
                    key: "", modifiers: [], isRecommended: false, action: #selector(deleteAllVideoKeyframes)),
        AppShortcut(id: "autoProcessCurrentVideo", category: "動画", title: "動画自動モザイク処理",
                    key: "", modifiers: [], isRecommended: true, action: #selector(autoProcessCurrentVideo)),
        AppShortcut(id: "exportVideoWithMosaic", category: "動画", title: "動画を書き出す",
                    key: "e", modifiers: [.command, .shift], isRecommended: true,
                    action: #selector(exportVideoWithMosaic)),
        AppShortcut(id: "runTrackingPreview", category: "動画", title: "追跡を確認",
                    key: "t", modifiers: [.command], isRecommended: true, action: #selector(runTrackingPreview)),
        AppShortcut(id: "previewSelectedVideo", category: "ライブラリ", title: "動画をプレビュー再生",
                    key: "", modifiers: [], isRecommended: false, action: #selector(previewSelectedVideo)),
        AppShortcut(id: "openSelectedLibraryProcessed", category: "ライブラリ", title: "加工後画像を開く",
                    key: "", modifiers: [], isRecommended: false, action: #selector(openSelectedLibraryProcessed)),
        AppShortcut(id: "deleteSelectedLibraryItems", category: "ライブラリ", title: "選択画像を削除",
                    key: "", modifiers: [], isRecommended: false, action: #selector(deleteSelectedLibraryItems)),
        AppShortcut(id: "cleanUpPastedIconImports", category: "ライブラリ", title: "ファイルアイコン画像を整理…",
                    key: "", modifiers: [], isRecommended: false, action: #selector(cleanUpPastedIconImports)),
        AppShortcut(id: "reloadLibraryFromButton", category: "ライブラリ", title: "ライブラリを更新",
                    key: "", modifiers: [], isRecommended: false, action: #selector(reloadLibraryFromButton)),
        AppShortcut(id: "exportTrainingDataset", category: "ライブラリ", title: "学習用データセットを書き出す",
                    key: "", modifiers: [], isRecommended: false, action: #selector(exportTrainingDataset)),
        AppShortcut(id: "exportShapeDataset", category: "ライブラリ", title: "形状学習用データセットを書き出す",
                    key: "", modifiers: [], isRecommended: false, action: #selector(exportShapeTrainingDataset)),
        AppShortcut(id: "registerFolderAsLinks", category: "一括処理", title: "フォルダを一括登録（リンク）",
                    key: "", modifiers: [], isRecommended: false, action: #selector(registerFolderAsLinks)),
        AppShortcut(id: "repairBrokenLinksAction", category: "一括処理", title: "リンク切れ修正",
                    key: "", modifiers: [], isRecommended: false, action: #selector(repairBrokenLinksAction)),
        AppShortcut(id: "batchProcessAll", category: "一括処理", title: "一括処理",
                    key: "", modifiers: [], isRecommended: false, action: #selector(batchProcessAll))
    ]

    static func shortcut(id: String) -> AppShortcut? {
        appShortcuts.first { $0.id == id }
    }
    private var lastStatusText = ""
    private var batchCancelRequested = false
    private var batchPanel: NSPanel?
    private let batchProgressBar = NSProgressIndicator()
    private let batchProgressLabel = NSTextField(labelWithString: "")
    /// サイドパネル内の移動可能ウィンドウ（ライブラリ/レイヤ/動画編集/モザイク設定）
    private enum SidePanelKind: String, CaseIterable {
        case library, layers, video, inspector
    }
    private struct SplitRestoreResult {
        var any = false
        var leftPaneHeights = false
        var rightPaneHeights = false
    }
    private var sidePanels: [SidePanelKind: NSView] = [:]
    private var isLoadingMosaicStyleControls = false
    private var defaultMosaicStyle = MosaicStyle()
    private var discardedEditStateID: UUID?
    private var isGeneratingCandidates = false
    private var hasPendingCandidateGeneration = false
    private var editorRevision = 0

    override init() {
        let savedRatio = AppSettings.shared.object(forKey: Self.groinPositionDefaultsKey) as? Double ?? 0.45
        super.init()
        groinPositionSlider.doubleValue = savedRatio
        groinPositionValueLabel.stringValue = "\(Int(savedRatio * 100)) %"
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let openButton = shortcutToolbarButton("openImage", symbol: "folder")
        let pasteButton = shortcutToolbarButton("pasteImage", symbol: "doc.on.clipboard")
        let detectButton = shortcutToolbarButton("generateCandidates", symbol: "wand.and.stars")
        let applyButton = shortcutToolbarButton("applyMosaic", symbol: "checkerboard.rectangle")
        // ライブラリの「選択画像を削除」（trashアイコン）と区別するため別アイコンにする。
        let clearButton = shortcutToolbarButton("clearROIs", symbol: "rectangle.badge.minus")
        configureShortcutToolbarButton(undoButton, id: "performUndo", symbol: "arrow.uturn.backward")
        configureShortcutToolbarButton(redoButton, id: "performRedo", symbol: "arrow.uturn.forward")
        undoButton.keyEquivalent = "z"
        undoButton.keyEquivalentModifierMask = [.command]
        redoButton.keyEquivalent = "z"
        redoButton.keyEquivalentModifierMask = [.command, .shift]
        let linkFolderButton = shortcutToolbarButton("registerFolderAsLinks", symbol: "folder.badge.plus")
        let batchButton = shortcutToolbarButton(
            "batchProcessAll",
            symbol: "bolt.circle",
            helpOverride: "一括処理（未加工の静止画を候補生成→適用→保存）"
        )
        let zoomOutButton = shortcutToolbarButton("zoomOut", symbol: "minus.magnifyingglass")
        let zoomFitButton = shortcutToolbarButton("zoomToFit", symbol: "arrow.up.left.and.arrow.down.right")
        let zoomInButton = shortcutToolbarButton("zoomIn", symbol: "plus.magnifyingglass")

        // ステータスは余白に収め、長文時は末尾省略（幅がウィンドウを超えて制約が破綻しないようにする）
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        zoomLabel.font = Self.scaledMonospacedDigitFont(11, weight: .regular)
        zoomLabel.alignment = .center
        zoomLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        // 配置（ユーザー指定）: ファイル系 | 一括処理・候補生成・適用・全レイヤ削除 | 元に戻す・やり直す |
        // 編集/範囲選択モード切替。ライブラリ関連（リンク切れ修正・画像出力・Finderで表示・削除）は
        // ライブラリパネル側の操作行へ移動した。
        configureLearningModeButton()
        let toolbar = NSStackView(views: [
            openButton, linkFolderButton, pasteButton, makeToolbarSeparator(),
            batchButton, detectButton, applyButton, clearButton, makeToolbarSeparator(),
            undoButton, redoButton, makeToolbarSeparator(),
            canvasModeControl, learningModeButton,
            NSView(), makeToolbarSeparator(), zoomOutButton, zoomFitButton, zoomInButton, zoomLabel
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        imageDependentToolbarButtons = [detectButton, applyButton, clearButton,
                                        zoomOutButton, zoomFitButton, zoomInButton]
        updateImageActionAvailability()

        canvasModeControl.segmentStyle = .texturedRounded
        // 編集モード=矩形破線（ROIを描くモード）、範囲選択モード=カーソル（選択するモード）。
        applyIconSizeToCanvasModeControl()
        canvasModeControl.setToolTip("編集モード（ドラッグでROIを新規作成。従来通り）", forSegment: 0)
        canvasModeControl.setToolTip("範囲選択モード（ドラッグで複数ROIを一括選択。Option(⌥)キーで一時的に編集モードへ切替）", forSegment: 1)
        canvasModeControl.setToolTip(
            "マスク追加ペン（ドラッグでマスクを塗る。レイヤ未選択ならモザイク対象へ新しいレイヤ「その他」を作って塗る。"
            + "Option(⌥)キーを押しながらで一時的に消しゴム）",
            forSegment: 2
        )
        canvasModeControl.setToolTip(
            "マスク消しゴム（ドラッグでマスクを消す。Option(⌥)キーを押しながらで一時的に追加ペン）",
            forSegment: 3
        )
        canvasModeControl.selectedSegment = 0
        canvasModeControl.target = self
        canvasModeControl.action = #selector(canvasModeChanged)
        canvasModeControl.toolTip = "画像上の操作モード（編集/範囲選択/マスク追加ペン/マスク消しゴム）"

        shapeControl.selectedSegment = 1
        shapeControl.toolTip = "新規または選択中のモザイク範囲の形状"
        applyScaledFont(shapeControl, size: 12)
        segmentEngineControl.removeAllItems()
        segmentEngineControl.addItems(withTitles: Self.selectableEngineKinds.map(\.displayName))
        let defaultEngineIndex = Self.selectableEngineKinds.firstIndex(of: .samShape) ?? 0
        segmentEngineControl.selectItem(at: defaultEngineIndex)
        segmentEngineControl.toolTip = "選択範囲から実際の処理マスクを生成する方式"
        segmentEngineControl.target = self
        segmentEngineControl.action = #selector(segmentEngineChanged)
        applyScaledFont(segmentEngineControl, size: 13)
        applyScaledFont(individualDetectionCheckbox, size: 12)
        individualDetectionCheckbox.toolTip =
            "ONのとき、検出設定（マスク生成・形状しきい値）は選択中のレイヤにだけ適用する。他レイヤのマスクとモザイクは変化しない"
        individualDetectionCheckbox.target = self
        individualDetectionCheckbox.action = #selector(individualDetectionChanged)
        individualDetectionCheckbox.state =
            (AppSettings.shared.object(forKey: Self.individualDetectionDefaultsKey) as? Bool ?? true) ? .on : .off

        // 画像種別（自動判定の誤りを手動で上書きできるようにする）
        domainModeControl.removeAllItems()
        domainModeControl.addItems(withTitles: ["自動判定", "実写", "イラスト・漫画"])
        domainModeControl.toolTip = "人物・部位検出に使用する画像種別"
        applyScaledFont(domainModeControl, size: 13)
        let savedDomainMode = AppSettings.shared.integer(forKey: Self.domainModeDefaultsKey)
        domainModeControl.selectItem(at: (0...2).contains(savedDomainMode) ? savedDomainMode : 0)
        loadLibraryViewPreferences()
        for (_, button) in categoryFilterChecks {
            applyScaledFont(button, size: 12)
        }
        applyScaledFont(generatePersonCheckbox, size: 12)
        applyScaledFont(generatePoseCheckbox, size: 12)
        applyScaledFont(mosaicPreviewCheckbox, size: 12)
        applyScaledFont(autoGenerateCheckbox, size: 12)
        applyScaledFont(autoSaveCheckbox, size: 12)
        for checkbox in [autoGenerateCheckbox, autoSaveCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(workflowOptionChanged)
        }
        loadWorkflowOptions()
        applyScaledFont(applyStyleToAllButton, size: 12)
        applyScaledFont(styleTintCheckbox, size: 12)
        applyScaledFont(styleCloudToneCheckbox, size: 12)
        applyScaledFont(stylePatternImageButton, size: 12)
        applyScaledFont(stylePatternPopUp, size: 13)
        applyScaledFont(undoButton, size: 12)
        applyScaledFont(redoButton, size: 12)

        toolbar.setHuggingPriority(.required, for: .vertical)

        canvas.translatesAutoresizingMaskIntoConstraints = false
        configureMosaicStyleControls()
        let libraryPanel = makeLibraryPanel()
        let layerPanel = makeLayerPanel()
        let videoPanel = makeVideoPanel()
        let inspectorPanel = makeInspectorPanel()

        // サイドパネル（左右）: 各ウィンドウ（ライブラリ/レイヤ/モザイク設定）は◀▶ボタンで左右へ移動できる。
        // 分割位置はポータブル設定（AppSettings）へ手動保存する（UserDefaults依存のautosaveNameは廃止）
        let leftPane = NSSplitView()
        leftPane.isVertical = false
        leftPane.dividerStyle = .thin
        leftPane.identifier = NSUserInterfaceItemIdentifier("LeftPaneSplit")
        leftPane.translatesAutoresizingMaskIntoConstraints = false
        leftPaneSplitView = leftPane

        let rightPane = NSSplitView()
        rightPane.isVertical = false
        rightPane.dividerStyle = .thin
        rightPane.identifier = NSUserInterfaceItemIdentifier("RightPaneSplit")
        rightPaneSplitView = rightPane
        rightPane.translatesAutoresizingMaskIntoConstraints = false

        sidePanels = [.library: libraryPanel, .layers: layerPanel, .video: videoPanel, .inspector: inspectorPanel]
        // 最小高さは低めに抑え、境界ドラッグで自由に配分できるようにする
        libraryPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        layerPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        videoPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        inspectorPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        attachPanelMoveButtons(to: libraryPanel, kind: .library)
        attachPanelMoveButtons(to: layerPanel, kind: .layers)
        attachPanelMoveButtons(to: videoPanel, kind: .video)
        attachPanelMoveButtons(to: inspectorPanel, kind: .inspector)

        // メイン分割: 左ペイン / キャンバス / 右ペイン。各境界の左右ドラッグで幅変更できる。
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.identifier = NSUserInterfaceItemIdentifier("MainSplit")
        mainSplitView = splitView
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(leftPane)
        // キャンバス直下へ動画タイムライン（V3）を積む。静止画では非表示のため、
        // 従来のレイアウト（キャンバスのみ）と見た目は変わらない。
        canvasContainer.translatesAutoresizingMaskIntoConstraints = false
        let timeline = makeVideoTimelineBar()
        canvasContainer.addSubview(canvas)
        canvasContainer.addSubview(timeline)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: canvasContainer.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: canvasContainer.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: canvasContainer.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: timeline.topAnchor),
            timeline.leadingAnchor.constraint(equalTo: canvasContainer.leadingAnchor),
            timeline.trailingAnchor.constraint(equalTo: canvasContainer.trailingAnchor),
            timeline.bottomAnchor.constraint(equalTo: canvasContainer.bottomAnchor)
        ])
        splitView.addArrangedSubview(canvasContainer)
        splitView.addArrangedSubview(rightPane)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 2)
        // 最小幅はAuto LayoutのwidthAnchor制約ではなく、NSSplitViewDelegateの
        // constrainMinCoordinate/constrainMaxCoordinateで与える（下記delegate実装参照）。
        // Auto Layoutの必須制約とNSSplitViewの独自フレーム操作を併用すると、
        // 制約解決時にドラッグ後のフレームが即座に元へ戻され「境界がまったく動かせない」
        // 不具合につながるため（サイドパネル幅バグの原因）。
        splitView.delegate = self
        leftPane.delegate = self
        rightPane.delegate = self
        applyPanelAssignments()
        // 下部ステータス兼ヘルプバー（左=状態/ホバーヘルプ、右=選択数・解像度・ROI数）
        let statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        let statusSeparator = NSBox()
        statusSeparator.boxType = .separator
        statusSeparator.translatesAutoresizingMaskIntoConstraints = false
        applyScaledFont(statusLabel, size: 11)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.font = Self.scaledMonospacedDigitFont(11, weight: .regular)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.alignment = .right
        statsLabel.lineBreakMode = .byTruncatingHead
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        analysisStopButton.target = self
        analysisStopButton.action = #selector(stopCurrentAnalysis)
        analysisStopButton.bezelStyle = .rounded
        analysisStopButton.isHidden = true
        analysisStopButton.translatesAutoresizingMaskIntoConstraints = false
        applyScaledFont(analysisStopButton, size: 11, weight: .semibold)
        statusBar.addSubview(statusSeparator)
        statusBar.addSubview(statusLabel)
        statusBar.addSubview(analysisStopButton)
        statusBar.addSubview(statsLabel)
        NSLayoutConstraint.activate([
            statusSeparator.topAnchor.constraint(equalTo: statusBar.topAnchor),
            statusSeparator.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            statusSeparator.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            analysisStopButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            analysisStopButton.trailingAnchor.constraint(equalTo: statsLabel.leadingAnchor, constant: -10),
            statsLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -10),
            statsLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: analysisStopButton.leadingAnchor, constant: -10)
        ])

        root.addSubview(toolbar)
        root.addSubview(splitView)
        root.addSubview(statusBar)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: splitView.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        self.view = root

        shapeControl.target = self
        shapeControl.action = #selector(shapeControlChanged)
        for (_, button) in categoryFilterChecks {
            button.target = self
            button.action = #selector(generationFilterChanged)
        }
        generatePersonCheckbox.target = self
        generatePersonCheckbox.action = #selector(generationFilterChanged)
        generatePoseCheckbox.target = self
        generatePoseCheckbox.action = #selector(generationFilterChanged)
        loadGenerationFilter()
        personLayerCheckbox.target = self
        personLayerCheckbox.action = #selector(toggleDetectionLayers)
        poseLayerCheckbox.target = self
        poseLayerCheckbox.action = #selector(toggleDetectionLayers)
        roiLayerCheckbox.target = self
        roiLayerCheckbox.action = #selector(toggleDetectionLayers)
        mosaicPreviewCheckbox.target = self
        mosaicPreviewCheckbox.action = #selector(toggleMosaicPreview)
        groinPositionSlider.target = self
        groinPositionSlider.action = #selector(groinPositionChanged)
        domainModeControl.target = self
        domainModeControl.action = #selector(domainModeChanged)
        applyStyleToAllButton.target = self
        applyStyleToAllButton.action = #selector(applyCurrentStyleToAllLayers)
        loadMosaicStyleSettings()
        reloadLayerList()

        canvas.currentShape = .ellipse
        canvas.currentCategory = .other
        canvas.onROIsChanged = { [weak self] rois in
            guard let self else { return }
            self.updateStatus("ROI \(rois.count)件")
            self.refreshROIListIfNeeded()
            self.updateStatsBar()
        }
        canvas.onCategoryChangeRequest = { [weak self] roiID, category in
            guard let self,
                  let index = self.canvas.rois.firstIndex(where: { $0.id == roiID }),
                  self.canvas.rois[index].category != category else { return }
            self.pushUndoSnapshot(self.currentEditorState())
            self.canvas.rois[index].category = category
            self.refreshMaskShapeScale(at: index)
            self.updateStatus("ROIのカテゴリを「\(category.displayName)」へ変更しました")
        }
        canvas.onManualEditWillBegin = { [weak self] in
            guard let self else { return }
            self.pushUndoSnapshot(self.currentEditorState())
            // 編集中は元画像表示に切り替える（チェック状態は維持し、編集完了時に自動で再適用）
            self.suspendMosaicPreview()
        }
        canvas.onManualEditDidEnd = { [weak self] in
            guard let self else { return }
            // フラッシュ中心ハンドルのドラッグはcanvas側が直接ROIのstyleへ書き込むため、
            // インスペクタ側の保持値（pendingFlashCenter）をここで実際の値へ再同期する
            // （再同期しないと、直後に他のスライダーを操作した際に古い中心位置へ戻ってしまう）。
            if let selectedID = self.canvas.selectedROIID,
               let roi = self.canvas.rois.first(where: { $0.id == selectedID }) {
                self.pendingFlashCenter = roi.style?.flashCenter ?? self.defaultMosaicStyle.flashCenter
            }
            self.resumeMosaicPreviewIfNeeded()
        }
        canvas.onROISelectionChanged = { [weak self] roi in
            guard let self else { return }
            if let roi {
                switch roi.shape {
                case .rectangle: self.shapeControl.selectedSegment = 0
                case .ellipse: self.shapeControl.selectedSegment = 1
                case .polygon: self.shapeControl.selectedSegment = 2
                }
            }
            self.loadMosaicStyleForSelection(roi)
            self.loadDetectionSettingForSelection(roi)
            self.syncROIListSelectionFromCanvas()
        }
        canvas.onMaskStrokeCompleted = { [weak self] roiID, stroke, isNewLayer in
            self?.applyMaskStroke(roiID: roiID, stroke: stroke, isNewLayer: isNewLayer)
        }
        canvas.onMaskStrokeNeedsNewLayer = { [weak self] rect in
            self?.addLayerForMaskPaint(rect: rect)
        }
        canvas.onROIGroupSelectionByMarquee = { [weak self] ids in
            self?.syncROIListSelectionFromCanvasGroup(ids)
        }
        canvas.onDetectionLayerDeleteRequest = { [weak self] kind in
            self?.deleteDetectionLayer(kind)
        }
        canvas.onDetectionLayerSelected = { [weak self] kind in
            self?.selectDetectionLayerInList(kind)
        }
        canvas.onDetectionLayerMoved = { [weak self] kind, dx, dy in
            self?.applyDetectionLayerMove(kind, dx: dx, dy: dy)
        }
        canvas.onZoomChanged = { [weak self] zoom in
            self?.zoomLabel.stringValue = "\(Int((zoom * 100).rounded()))%"
        }
        tableView.onNavigate = { [weak self] delta in
            self?.navigateLibrary(by: delta)
        }
        collectionView.onNavigate = { [weak self] delta in
            self?.navigateLibrary(by: delta)
        }
        tableView.onDelete = { [weak self] in
            self?.deleteSelectedLibraryItems()
        }
        collectionView.onDelete = { [weak self] in
            self?.deleteSelectedLibraryItems()
        }
        applyLayerVisibility()
        updateUndoRedoAvailability()
        reloadLibrary()
    }

    /// 形状・カテゴリの変更後、性器ROIの「マスクを切り取る形状」の拡大倍率を今の状態へ合わせ直す。
    ///
    /// `maskShapeScale` は検出時に一度だけ設定される想定だったが、ユーザーがインスペクタで
    /// 形状（矩形/楕円/多角形）やカテゴリを手動変更しても再計算されず、古い倍率が残っていた
    /// （コードレビューで検出）。実体は `DetectedROIRefiner.recalculateMaskShapeScale`
    /// （コア側にあるのはテストしやすくするため。ロジックの詳細はそちらのコメントを参照）。
    private func refreshMaskShapeScale(at index: Int) {
        guard canvas.rois.indices.contains(index) else { return }
        canvas.rois[index] = DetectedROIRefiner.recalculateMaskShapeScale(for: canvas.rois[index])
    }

    @objc private func shapeControlChanged() {
        let shapes: [ROIShape] = [.rectangle, .ellipse, .polygon]
        let index = shapeControl.selectedSegment
        guard (0..<shapes.count).contains(index) else { return }
        let shape = shapes[index]
        canvas.currentShape = shape
        if let selectedID = canvas.selectedROIID,
           let roiIndex = canvas.rois.firstIndex(where: { $0.id == selectedID }),
           canvas.rois[roiIndex].shape != shape {
            pushUndoSnapshot(currentEditorState())
            canvas.rois[roiIndex].shape = shape
            if shape == .polygon {
                if canvas.rois[roiIndex].polygonPoints == nil {
                    canvas.rois[roiIndex].polygonPoints = MosaicROI.defaultPolygonPoints
                }
                updateStatus("多角形へ変更しました。頂点をドラッグで変形、Option+クリックで頂点の追加/削除ができます")
            } else {
                canvas.rois[roiIndex].polygonPoints = nil
            }
            refreshMaskShapeScale(at: roiIndex)
        } else if shape == .polygon {
            updateStatus("追加形状: 多角形（ドラッグで追加後、頂点ドラッグで変形、Option+クリックで頂点の追加/削除）")
        }
    }

    @objc private func zoomIn() {
        canvas.setZoom(canvas.zoomFactor * 1.2)
    }

    @objc private func zoomOut() {
        canvas.setZoom(canvas.zoomFactor / 1.2)
    }

    @objc private func zoomToFit() {
        canvas.resetZoom()
    }

    // MARK: - 候補生成の対象フィルタ（対象カテゴリ複数チェック）

    /// チェックされている生成対象カテゴリの集合。
    private func checkedGenerationCategories() -> Set<MosaicTargetCategory> {
        Set(categoryFilterChecks.filter { $0.button.state == .on }.map(\.category))
    }

    @objc private func generationFilterChanged() {
        saveGenerationFilter()
        updateStatus("候補生成の対象: \(generationFilterSummary())（次回の候補生成から適用）")
    }

    private func generationFilterSummary() -> String {
        var names = categoryFilterChecks.filter { $0.button.state == .on }.map { $0.category.displayName }
        if generatePersonCheckbox.state == .on { names.append("人物") }
        if generatePoseCheckbox.state == .on { names.append("骨格") }
        return names.isEmpty ? "なし" : names.joined(separator: "・")
    }

    private func saveGenerationFilter() {
        let defaults = AppSettings.shared
        for (category, button) in categoryFilterChecks {
            defaults.set(button.state == .on, forKey: "GenerateFilter.category.\(category.rawValue)")
        }
        defaults.set(generatePersonCheckbox.state == .on, forKey: "GenerateFilter.person")
        defaults.set(generatePoseCheckbox.state == .on, forKey: "GenerateFilter.pose")
    }

    /// ワークフロー設定（自動候補生成・自動保存）の保存。他のユーザー設定と同様に
    /// 次回起動へ引き継ぐ（従来はセッション限りで、再起動すると既定へ戻っていた）。
    @objc private func workflowOptionChanged() {
        let defaults = AppSettings.shared
        defaults.set(autoGenerateCheckbox.state == .on, forKey: "Workflow.autoGenerate")
        defaults.set(autoSaveCheckbox.state == .on, forKey: "Workflow.autoSave")
    }

    private func loadWorkflowOptions() {
        let defaults = AppSettings.shared
        // 既定はON（初回起動時に候補生成・保存まで自動で進む運用を標準とする）
        autoGenerateCheckbox.state = (defaults.object(forKey: "Workflow.autoGenerate") as? Bool ?? true) ? .on : .off
        autoSaveCheckbox.state = (defaults.object(forKey: "Workflow.autoSave") as? Bool ?? true) ? .on : .off
    }

    /// 保存済みの生成対象フィルタを復元する（未保存キーは既定ON）。
    private func loadGenerationFilter() {
        let defaults = AppSettings.shared
        for (category, button) in categoryFilterChecks {
            let key = "GenerateFilter.category.\(category.rawValue)"
            // 「乳輪」は乳首を含む上位範囲のため既定OFF（両方ONにすると同じ場所へ
            // 大小2つのROIが重なる）。乳輪まで覆いたい場合にユーザーがONにする。
            let fallback = category != .areola
            button.state = (defaults.object(forKey: key) as? Bool ?? fallback) ? .on : .off
        }
        generatePersonCheckbox.state = (defaults.object(forKey: "GenerateFilter.person") as? Bool ?? true) ? .on : .off
        generatePoseCheckbox.state = (defaults.object(forKey: "GenerateFilter.pose") as? Bool ?? true) ? .on : .off
    }

    // MARK: - サイドパネルのウィンドウ移動（◀▶）

    /// 各パネル右上へ「◀」「▶」ボタンを重ねて配置する。押した方向のサイドパネルへウィンドウを移動する。
    private func attachPanelMoveButtons(to panel: NSView, kind: SidePanelKind) {
        let leftButton = NSButton(title: "◀", target: self, action: #selector(movePanelToLeft(_:)))
        let rightButton = NSButton(title: "▶", target: self, action: #selector(movePanelToRight(_:)))
        for button in [leftButton, rightButton] {
            button.isBordered = false
            applyScaledFont(button, size: 9)
            button.contentTintColor = .secondaryLabelColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        leftButton.toolTip = "このウィンドウを左サイドパネルへ移動"
        rightButton.toolTip = "このウィンドウを右サイドパネルへ移動"
        let stack = NSStackView(views: [leftButton, rightButton])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            // スクロールバーと重ならないよう左へ寄せる
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -26)
        ])
    }

    @objc private func movePanelToLeft(_ sender: NSButton) {
        movePanel(from: sender, to: "left")
    }

    @objc private func movePanelToRight(_ sender: NSButton) {
        movePanel(from: sender, to: "right")
    }

    private func movePanel(from sender: NSButton, to side: String) {
        guard let raw = sender.identifier?.rawValue,
              let kind = SidePanelKind(rawValue: raw) else { return }
        let currentSide = panelSide(for: kind)
        // 移動先サイドに他のパネルが既にあれば、その幅を維持すべきなので幅の引き継ぎは行わない。
        let destinationOccupied = SidePanelKind.allCases.contains { other in
            guard other != kind else { return false }
            return panelSide(for: other) == side
        }
        let inheritedWidth: CGFloat? = {
            guard !destinationOccupied, currentSide != side else { return nil }
            let width = currentSide == "left" ? leftPaneSplitView?.frame.width : rightPaneSplitView?.frame.width
            guard let width, width > 50 else { return nil }
            return width
        }()
        AppSettings.shared.set(side, forKey: "Layout.panelSide.\(kind.rawValue)")
        applyPanelAssignments()
        rebalancePanelHeights(in: currentSide == "left" ? leftPaneSplitView : rightPaneSplitView)
        rebalancePanelHeights(in: side == "left" ? leftPaneSplitView : rightPaneSplitView)
        if let inheritedWidth {
            applyPaneWidth(inheritedWidth, side: side)
        }
        updateStatus("\(panelDisplayName(kind))を\(side == "left" ? "左" : "右")サイドパネルへ移動しました")
    }

    /// 指定サイドのペイン幅をmainSplit上へ即時反映し、次回起動時の復元用に設定へも保存する。
    private func applyPaneWidth(_ width: CGFloat, side: String) {
        guard let mainSplit = mainSplitView, let rightPane = rightPaneSplitView else { return }
        let wasRestoring = isRestoringSplitPositions
        isRestoringSplitPositions = true
        defer { isRestoringSplitPositions = wasRestoring }
        mainSplit.layoutSubtreeIfNeeded()
        if side == "left" {
            mainSplit.setPosition(width, ofDividerAt: 0)
            AppSettings.shared.set(Double(width), forKey: "Layout.leftPaneWidth")
        } else {
            setMainSplitRightPaneWidth(width, mainSplit: mainSplit, rightPane: rightPane)
            AppSettings.shared.set(Double(width), forKey: "Layout.rightPaneWidth")
        }
    }

    /// mainSplit上で右ペインの幅を指定値へ設定する。
    ///
    /// 左ペインが非表示（既定状態）のとき、Appleの公式ドキュメントによれば
    /// 「非表示のarrangedSubviewはdivider dragging上で存在しないものとして扱われ、
    /// 対応するdividerも消える」とされており、`setPosition(_:ofDividerAt:)` に渡すべき
    /// インデックスが「非表示ペインを詰めて数え直した実効インデックス」になる可能性がある。
    /// これがOS/バージョンにより`arrangedSubviews.count - 2`（詰めない場合の本来の右ペイン境界）
    /// と食い違い、狙った位置に反映されない不具合が繰り返し発生していた。
    /// 挙動の詳細に依存せず確実に反映するため、候補インデックスを順に試し、
    /// 実際の幅を測定して一致した時点で確定する。
    private func setMainSplitRightPaneWidth(_ width: CGFloat, mainSplit: NSSplitView, rightPane: NSView) {
        // constrainMinCoordinate/constrainMaxCoordinateはsetPosition(_:ofDividerAt:)からも
        // 呼ばれる。ドラッグ用に書かれたこの制約が、まだ更新されていない隣接ビューの古い
        // フレーム値を基準に意図しない位置へクランプしてしまい、Build 69〜72で右ペイン幅の
        // 既定化が繰り返し失敗していた真因だった（実測診断で判明）。プログラムからの
        // 一括設定中は制約を無効化する。
        let wasRestoring = isRestoringSplitPositions
        isRestoringSplitPositions = true
        defer { isRestoringSplitPositions = wasRestoring }
        mainSplit.layoutSubtreeIfNeeded()
        let target = max(200, mainSplit.bounds.width - mainSplit.dividerThickness - width)
        let lastIndex = mainSplit.arrangedSubviews.count - 2
        var candidates = [lastIndex]
        if !candidates.contains(0) { candidates.append(0) }
        for index in candidates where index >= 0 {
            mainSplit.setPosition(target, ofDividerAt: index)
            mainSplit.layoutSubtreeIfNeeded()
            if abs(rightPane.frame.width - width) < 30 { return }
        }
    }

    /// ライブラリのグリッド表示（サムネイル既定サイズ120pt）がちょうど2列になる幅。
    /// サイドパネルの「工場初期値」として使う（右パネルは既定でライブラリが配置されるため）。
    /// 左ペインの工場既定幅。インスペクタが入っている場合は省略表示にならない幅を使う。
    private func defaultLeftPaneWidth(_ leftPane: NSView) -> CGFloat {
        max(280, minimumWidth(forPane: leftPane) + 20)
    }

    private func libraryTwoColumnPaneWidth() -> CGFloat {
        let itemWidth: CGFloat = 120 // thumbnailSizeSliderの既定値
        let interitem: CGFloat = 5
        let sectionInset: CGFloat = 5 * 2
        let scrollbarReserve: CGFloat = 16
        let panelPadding: CGFloat = 8 * 2
        let twoColumns = itemWidth * 2 + interitem + sectionInset + scrollbarReserve + panelPadding
        // 表示モード切替（グリッド/テキスト/サムネイル）とズーム・更新アイコンが
        // 省略表示にならない下限。2列幅がこれを下回る場合はこちらを採る。
        let controlRowMinimum: CGFloat = 340
        return max(twoColumns, controlRowMinimum)
    }

    /// パネル配置が一度も保存されていない場合の工場既定サイド。
    /// 右＝「ライブラリ」＋「レイヤ」、左＝「インスペクタ」（添付レイアウト準拠）。
    /// 従来は全パネルが一律「right」既定だったため、初期化すると右ペインへ
    /// インスペクタまで含めた3ウィンドウが詰め込まれ、右ペイン幅がアプリの9割以上を
    /// 占める不具合があった（左ペインが空のまま非表示になり、右ペインの幅解決ロジックが
    /// 想定していない状態に陥っていたのが真因）。
    private func defaultPanelSide(for kind: SidePanelKind) -> String {
        kind == .inspector ? "left" : "right"
    }

    private func panelSide(for kind: SidePanelKind) -> String {
        AppSettings.shared.string(forKey: "Layout.panelSide.\(kind.rawValue)") ?? defaultPanelSide(for: kind)
    }

    private func panelDisplayName(_ kind: SidePanelKind) -> String {
        switch kind {
        case .library: return "ライブラリ"
        case .layers: return "レイヤ"
        case .video: return "動画編集"
        case .inspector: return "モザイク設定"
        }
    }

    private func kind(forPanel panel: NSView) -> SidePanelKind? {
        sidePanels.first { $0.value === panel }?.key
    }

    private func defaultHeightWeight(for panel: NSView) -> CGFloat {
        switch kind(forPanel: panel) {
        case .library: return 1.15
        case .layers: return 0.95
        case .video: return 1.10
        case .inspector: return 1.25
        case .none: return 1.0
        }
    }

    /// サイド内のパネル数が増減した後に、現在の構成へ合わせて高さを再配分する。
    ///
    /// 幅だけ復元できた場合や、動画編集パネル追加前の2枚構成高さが残っている場合、
    /// NSSplitViewが先頭パネル（ライブラリ）を0px近くまで潰すことがある。保存高さが
    /// 現在のパネル数と合わないときは、ライブラリを含む全パネルが見える既定配分へ戻す。
    private func rebalancePanelHeights(in pane: NSSplitView?) {
        guard let pane, !pane.isHidden, pane.arrangedSubviews.count > 1 else { return }
        pane.layoutSubtreeIfNeeded()
        let dividerTotal = pane.dividerThickness * CGFloat(pane.arrangedSubviews.count - 1)
        let available = pane.bounds.height - dividerTotal
        guard available > CGFloat(pane.arrangedSubviews.count) * 40 else { return }

        let weights = pane.arrangedSubviews.map(defaultHeightWeight(for:))
        let totalWeight = max(0.01, weights.reduce(0, +))
        var heights = zip(pane.arrangedSubviews, weights).map { panel, weight -> CGFloat in
            let weighted = available * weight / totalWeight
            return max(80, min(weighted, minimumHeight(forPanel: panel)))
        }
        let currentTotal = heights.reduce(0, +)
        if currentTotal > available {
            let scale = available / currentTotal
            heights = heights.map { max(60, $0 * scale) }
        } else if let last = heights.indices.last {
            heights[last] += available - currentTotal
        }

        var position: CGFloat = 0
        for (index, height) in heights.dropLast().enumerated() {
            position += height
            pane.setPosition(position, ofDividerAt: index)
            position += pane.dividerThickness
        }
    }

    /// 保存された配置（Layout.panelSide.*）に従って各ウィンドウを左右のサイドパネルへ配置する。
    /// 空になったサイドパネルは非表示にする（最小幅制約も無効化して幅0で畳む）。
    private func applyPanelAssignments() {
        guard let leftPane = leftPaneSplitView, let rightPane = rightPaneSplitView,
              let mainSplit = mainSplitView else { return }
        let wasRestoring = isRestoringSplitPositions
        isRestoringSplitPositions = true
        defer { isRestoringSplitPositions = wasRestoring }
        let wasLeftHidden = leftPane.isHidden
        let wasRightHidden = rightPane.isHidden

        for pane in [leftPane, rightPane] {
            for view in pane.arrangedSubviews {
                pane.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        }
        for kind in SidePanelKind.allCases {
            guard let panel = sidePanels[kind] else { continue }
            let side = panelSide(for: kind)
            (side == "left" ? leftPane : rightPane).addArrangedSubview(panel)
        }
        let leftEmpty = leftPane.arrangedSubviews.isEmpty
        let rightEmpty = rightPane.arrangedSubviews.isEmpty
        leftPane.isHidden = leftEmpty
        rightPane.isHidden = rightEmpty
        mainSplit.adjustSubviews()

        // NSSplitViewは非表示→表示への切替時に幅を自動で確保しないため
        // （adjustSubviewsは既存フレーム比率を維持するだけで、幅0のまま残ることがある）、
        // 隠れていたペインが新たに表示された場合は明示的に既定幅を与える
        // （「サイドパネルを左へ移動すると表示されなくなる」バグの修正）。
        mainSplit.layoutSubtreeIfNeeded()
        // 左ペインの既定幅はインスペクタの最小幅（340）を下回らない共通ヘルパを使う
        //（旧: ハードコード280で、インスペクタを左へ移すと省略表示になっていた）。
        let defaultRightPaneWidth = libraryTwoColumnPaneWidth()
        if wasLeftHidden && !leftEmpty {
            mainSplit.setPosition(defaultLeftPaneWidth(leftPane), ofDividerAt: 0)
        }
        if wasRightHidden && !rightEmpty {
            setMainSplitRightPaneWidth(defaultRightPaneWidth, mainSplit: mainSplit, rightPane: rightPane)
        }
    }

    /// 分割位置の適用。保存済みの位置（ポータブル設定）があれば復元し、なければ初回既定レイアウト
    /// （レイヤパネル=人物4人分相当）を適用する。以後のドラッグ調整は `splitViewDidResizeSubviews` で保存される。
    func applyInitialLayoutIfNeeded() {
        guard let rightPane = rightPaneSplitView, let leftPane = leftPaneSplitView,
              let mainSplit = mainSplitView else { return }
        let wasRestoring = isRestoringSplitPositions
        isRestoringSplitPositions = true
        defer { isRestoringSplitPositions = wasRestoring }
        rightPane.layoutSubtreeIfNeeded()
        mainSplit.layoutSubtreeIfNeeded()
        let restored = restoreSplitPositions()

        // 保険: 表示状態（isHidden=false）のペインが実際にはほぼ幅0のまま残ることがある。
        // 一度もドラッグ保存されていない（Layout.leftPaneWidth等が未保存の）ペインを
        // 別ペインの復元成功によりrestoreSplitPositions()がtrueを返す状況で通過してしまうと
        // 幅0のまま気づかれず、「再起動するとサイドパネルが表示されない」不具合につながるため、
        // 復元結果によらず常に最終チェックとして既定幅を強制する。
        mainSplit.layoutSubtreeIfNeeded()
        if !leftPane.isHidden && leftPane.frame.width < minimumWidth(forPane: leftPane) {
            mainSplit.setPosition(defaultLeftPaneWidth(leftPane), ofDividerAt: 0)
        }
        if !rightPane.isHidden && rightPane.frame.width < 50 {
            setMainSplitRightPaneWidth(libraryTwoColumnPaneWidth(), mainSplit: mainSplit, rightPane: rightPane)
        }

        // 保険（逆方向）: サイドペインがウィンドウの大半を占めてキャンバスが見えない状態も
        // 既定幅へ強制する（「初期値の幅がおかしく画面全体を覆う」報告への対応。保存値が
        // 無い初回起動で左ペインが全幅で解決されるケースがあった）。
        mainSplit.layoutSubtreeIfNeeded()
        let totalWidth = mainSplit.bounds.width
        if totalWidth > 400 {
            if !leftPane.isHidden, leftPane.frame.width > totalWidth * 0.5 {
                mainSplit.setPosition(defaultLeftPaneWidth(leftPane), ofDividerAt: 0)
                mainSplit.layoutSubtreeIfNeeded()
            }
            if !rightPane.isHidden, rightPane.frame.width > totalWidth * 0.5 {
                setMainSplitRightPaneWidth(libraryTwoColumnPaneWidth(), mainSplit: mainSplit, rightPane: rightPane)
            }
        }

        // 右ペイン幅の既定化（工場既定レイアウト）は、右ペイン「内部」のライブラリ/レイヤ/
        // インスペクタの高さ配分（下記、ウィンドウの縦幅に依存）とは独立した話のため、
        // 縦幅が足りない場合に早期returnするガードの影響を受けないようここで確定させる。
        if !restored.any && !rightPane.isHidden {
            setMainSplitRightPaneWidth(libraryTwoColumnPaneWidth(), mainSplit: mainSplit, rightPane: rightPane)
        }

        if !restored.leftPaneHeights {
            rebalancePanelHeights(in: leftPane)
        }
        if !restored.rightPaneHeights {
            rebalancePanelHeights(in: rightPane)
        }

        // 起動直後の最終保険: ここまでの復元・既定化の後に走るレイアウト解決
        // （ウィンドウ枠復元やAuto Layoutの遅延パス）でサイドペインが最小幅未満へ
        // 縮められることがある（GUI報告 2026-08-08: 起動直後のサイドツールパネル幅が微妙）。
        // 1ターン遅らせて再確認し、狭ければ既定幅へ戻す。
        DispatchQueue.main.async { [weak self] in
            self?.enforceSidePaneMinimumWidths()
            self?.enforceSidePanelMinimumHeights()
        }
    }

    /// サイドペインが最小幅未満なら既定幅へ戻す（表示中のペインのみ）。
    private func enforceSidePaneMinimumWidths() {
        guard let leftPane = leftPaneSplitView, let rightPane = rightPaneSplitView,
              let mainSplit = mainSplitView, mainSplit.bounds.width > 400 else { return }
        let wasRestoring = isRestoringSplitPositions
        isRestoringSplitPositions = true
        defer { isRestoringSplitPositions = wasRestoring }
        mainSplit.layoutSubtreeIfNeeded()
        if !leftPane.isHidden, leftPane.frame.width < minimumWidth(forPane: leftPane) {
            mainSplit.setPosition(defaultLeftPaneWidth(leftPane), ofDividerAt: 0)
        }
        if !rightPane.isHidden, rightPane.frame.width < minimumWidth(forPane: rightPane) {
            setMainSplitRightPaneWidth(
                max(libraryTwoColumnPaneWidth(), minimumWidth(forPane: rightPane)),
                mainSplit: mainSplit, rightPane: rightPane
            )
        }
    }

    /// サイド内でいずれかのパネルが見えない高さまで潰れていたら再配分する。
    ///
    /// 起動直後のNSSplitView通知で `[0, 0, 残り]` のような過渡的高さが保存済みに
    /// なっている環境を復旧する保険。ライブラリパネル消失報告の実設定でこの形を確認した。
    private func enforceSidePanelMinimumHeights() {
        guard let leftPane = leftPaneSplitView, let rightPane = rightPaneSplitView else { return }
        let wasRestoring = isRestoringSplitPositions
        isRestoringSplitPositions = true
        defer { isRestoringSplitPositions = wasRestoring }
        for pane in [leftPane, rightPane] where !pane.isHidden && pane.arrangedSubviews.count > 1 {
            pane.layoutSubtreeIfNeeded()
            let hasCollapsedPanel = pane.arrangedSubviews.contains { panel in
                panel.frame.height < min(80, minimumHeight(forPanel: panel))
            }
            if hasCollapsedPanel {
                rebalancePanelHeights(in: pane)
            }
        }
    }

    /// 終了時などに現在の分割位置を明示的に保存する（リサイズ通知経由の保存に依存しない確実な保存）。
    func saveSplitPositionsNow() {
        guard let leftPane = leftPaneSplitView, let rightPane = rightPaneSplitView else { return }
        let settings = AppSettings.shared
        // 最小幅未満の過渡的な幅は保存しない（splitViewDidResizeSubviewsと同じ判定）
        if !leftPane.isHidden, leftPane.frame.width >= minimumWidth(forPane: leftPane) {
            settings.set(Double(leftPane.frame.width), forKey: "Layout.leftPaneWidth")
        }
        if !rightPane.isHidden, rightPane.frame.width >= minimumWidth(forPane: rightPane) {
            settings.set(Double(rightPane.frame.width), forKey: "Layout.rightPaneWidth")
        }
        for (pane, key) in [(leftPane, "Layout.leftPaneHeights"), (rightPane, "Layout.rightPaneHeights")] {
            guard !pane.isHidden, pane.bounds.height > 0, !pane.arrangedSubviews.isEmpty else { continue }
            let heights = pane.arrangedSubviews.map(\.frame.height)
            guard zip(pane.arrangedSubviews, heights).allSatisfy({ panel, height in
                height >= min(80, minimumHeight(forPanel: panel))
            }) else { continue }
            settings.set(heights.map(Double.init), forKey: key)
        }
    }

    /// 保存済みの分割位置（左右サイドパネル幅・各ウィンドウの高さ）を復元する。保存があればtrue。
    private func restoreSplitPositions() -> SplitRestoreResult {
        let settings = AppSettings.shared
        guard let rightPane = rightPaneSplitView,
              let leftPane = leftPaneSplitView,
              let mainSplit = mainSplitView else { return SplitRestoreResult() }
        var restored = SplitRestoreResult()
        let wasRestoring = isRestoringSplitPositions
        isRestoringSplitPositions = true
        defer { isRestoringSplitPositions = wasRestoring }

        // メイン分割: 左ペイン幅（divider 0）と右ペイン幅
        if !leftPane.isHidden,
           let leftWidth = settings.object(forKey: "Layout.leftPaneWidth") as? Double, leftWidth > 50 {
            mainSplit.setPosition(leftWidth, ofDividerAt: 0)
            restored.any = true
        }
        if !rightPane.isHidden,
           let rightWidth = settings.object(forKey: "Layout.rightPaneWidth") as? Double, rightWidth > 50 {
            setMainSplitRightPaneWidth(rightWidth, mainSplit: mainSplit, rightPane: rightPane)
            restored.any = true
        }

        // 各サイドパネル内: 保存された高さ配列から分割位置を復元する
        for (pane, key) in [(leftPane, "Layout.leftPaneHeights"), (rightPane, "Layout.rightPaneHeights")] {
            guard !pane.isHidden,
                  let heights = settings.object(forKey: key) as? [Double],
                  heights.count == pane.arrangedSubviews.count,
                  heights.allSatisfy({ $0 > 20 }) else { continue }
            pane.layoutSubtreeIfNeeded()
            var position = 0.0
            for (index, height) in heights.dropLast().enumerated() {
                position += height
                pane.setPosition(position, ofDividerAt: index)
                position += pane.dividerThickness
            }
            restored.any = true
            if pane === leftPane {
                restored.leftPaneHeights = true
            } else {
                restored.rightPaneHeights = true
            }
        }
        return restored
    }

    // MARK: - モザイク描画スタイル設定

    private func makeToolbarButton(symbol: String, help: String, action: Selector) -> NSButton {
        let button = SquareIconButton()
        configureToolbarButton(button, symbol: symbol, help: help, action: action)
        return button
    }

    /// `AppShortcut` レジストリのidからツールバーボタンを構築する。ツールチップの
    /// ショートカット表示（例:「画像を開く (⌘O)」）は登録データのdisplayStringから自動生成するため、
    /// メニュー・レジストリと食い違うことがない。
    /// 学習モードのON/OFFボタン。状態は記号と色で示す。
    private func configureLearningModeButton() {
        configureToolbarButton(
            learningModeButton,
            symbol: "graduationcap",
            help: "学習モード",
            action: #selector(toggleLearningMode)
        )
        refreshLearningModeButton()
    }

    private func refreshLearningModeButton() {
        let enabled = isLearningModeEnabled
        let symbol = enabled ? "graduationcap.fill" : "graduationcap"
        // アイコンサイズ設定を反映したSymbolConfigurationを必ず適用する。
        // これがないと他のツールバーアイコンより小さい既定サイズで描画される
        // （＝学習モードアイコンだけサイズが揃わないバグの原因）。
        learningModeButton.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: enabled ? "学習モードON" : "学習モードOFF"
        )?.withSymbolConfiguration(Self.currentIconSymbolConfiguration())
        learningModeButton.contentTintColor = enabled ? .controlAccentColor : .secondaryLabelColor
        let help = enabled
            ? "学習モード: ON（修正結果を学習し、次回以降の候補生成へ反映します）"
            : "学習モード: OFF（学習データの記録も利用も行いません）"
        learningModeButton.toolTip = help
    }

    /// 学習モードを切り替える。
    @objc func toggleLearningMode() {
        let next = !isLearningModeEnabled
        AppSettings.shared.set(next, forKey: Self.learningModeDefaultsKey)
        refreshLearningModeButton()
        updateStatus(next
            ? "学習モードをONにしました（修正結果を学習し、次回以降の候補生成へ反映します）"
            : "学習モードをOFFにしました（学習データの記録も利用も行いません）")
        AppLog.ui.info("学習モード: \(next ? "ON" : "OFF", privacy: .public)")
    }

    private func shortcutToolbarButton(
        _ id: String,
        symbol: String,
        helpOverride: String? = nil,
        compactPanelChrome: Bool = false
    ) -> NSButton {
        let button = SquareIconButton()
        configureShortcutToolbarButton(
            button,
            id: id,
            symbol: symbol,
            helpOverride: helpOverride,
            compactPanelChrome: compactPanelChrome
        )
        return button
    }

    private func configureShortcutToolbarButton(
        _ button: NSButton,
        id: String,
        symbol: String,
        helpOverride: String? = nil,
        compactPanelChrome: Bool = false
    ) {
        guard let shortcut = MosaicWindowController.shortcut(id: id) else {
            configureToolbarButton(
                button,
                symbol: symbol,
                help: helpOverride ?? id,
                action: Selector(id),
                compactPanelChrome: compactPanelChrome
            )
            return
        }
        let display = shortcut.displayString
        let help = (helpOverride ?? shortcut.title) + (display.isEmpty ? "" : " (\(display))")
        configureToolbarButton(
            button,
            symbol: symbol,
            help: help,
            action: shortcut.action,
            compactPanelChrome: compactPanelChrome
        )
    }

    private func configureToolbarButton(
        _ button: NSButton,
        symbol: String,
        help: String,
        action: Selector,
        compactPanelChrome: Bool = false
    ) {
        button.title = ""
        button.identifier = NSUserInterfaceItemIdentifier(symbol)
        button.imagePosition = .imageOnly
        // ネイティブのベゼル・フォーカスリングはどちらも大きな正方形フレームへ正しく
        // 追従しなかったため使わない（`SquareIconButton`が押下時ハイライトを自前で描く）。
        button.isBordered = false
        button.focusRingType = .none
        button.toolTip = help
        // ホバー中は下部ステータスバーへヘルプ文を表示する
        let relay = HoverHelpRelay(text: help) { [weak self] text in
            self?.showHoverHelp(text)
        }
        hoverRelays.append(relay)
        button.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: relay,
            userInfo: nil
        ))
        button.setAccessibilityLabel(help)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        if let squareButton = button as? SquareIconButton {
            squareButton.usesCompactPanelChrome = compactPanelChrome
        }
        toolbarIconButtons.append(button)
        applyIconSize(to: button, symbol: symbol)
    }

    /// 詳細設定「アイコンサイズ」に応じてツールバーアイコンの見た目サイズを変更する。
    /// SF Symbolの実描画サイズはSymbolConfigurationのpointSizeで制御し、
    /// ボタン自体のフレームサイズもwidthAnchor/heightAnchor制約で追従させる
    /// （固定サイズ制約のままだとアイコンサイズ設定を変えても見た目が変化しないため）。
    private func applyIconSize(to button: NSButton, symbol: String) {
        let size = Self.currentIconSizeSetting()
        let frameSize: CGFloat
        if (button as? SquareIconButton)?.usesCompactPanelChrome == true {
            frameSize = 32
        } else {
            // 従来の既定（大=18pt/40pt枠）が小さすぎるとの指摘を受け、全体的に一段階大きくシフトした
            // （旧「大」を新「小」の基準とし、中・大はそこから拡大。既定値は「中」）。
            switch size {
            case 0: frameSize = 40
            case 2: frameSize = 58
            default: frameSize = 48
            }
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.toolTip)?
            .withSymbolConfiguration(Self.currentIconSymbolConfiguration())
        if (button as? SquareIconButton)?.usesCompactPanelChrome == true {
            button.controlSize = .small
        } else {
            button.controlSize = size == 2 ? .large : (size == 0 ? .small : .regular)
        }
        for constraint in button.constraints where constraint.firstAttribute == .width || constraint.firstAttribute == .height {
            constraint.isActive = false
        }
        button.widthAnchor.constraint(equalToConstant: frameSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: frameSize - 2).isActive = true
    }

    private static func currentIconSizeSetting() -> Int {
        let value = AppSettings.shared.object(forKey: iconSizeDefaultsKey) as? Int
        guard let value, (0...2).contains(value) else { return 1 } // 既定値=中
        return value
    }

    /// アイコンサイズ設定（小/中/大）に対応するSF SymbolのpointSize設定。
    /// ツールバーボタン・モード切替セグメント・学習モードボタンの全てで共用する。
    private static func currentIconSymbolConfiguration() -> NSImage.SymbolConfiguration {
        let pointSize: CGFloat
        switch currentIconSizeSetting() {
        case 0: pointSize = 18
        case 2: pointSize = 28
        default: pointSize = 23
        }
        return NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    }

    /// モード切替セグメント（編集/範囲選択/マスク追加ペン/マスク消しゴム）へ
    /// アイコンサイズ設定を反映する。NSSegmentedControlは`toolbarIconButtons`の
    /// `NSButton`経路を通らないため、セグメント画像のSymbolConfigurationと
    /// セグメント幅を個別に設定する（未設定だと他のツールバーアイコンとサイズが揃わない）。
    private func applyIconSizeToCanvasModeControl() {
        let size = Self.currentIconSizeSetting()
        let segmentWidth: CGFloat
        // applyIconSize(to:symbol:) と同じ段階（小=40/中=48/大=58）に合わせる。
        switch size {
        case 0: segmentWidth = 40
        case 2: segmentWidth = 58
        default: segmentWidth = 48
        }
        let configuration = Self.currentIconSymbolConfiguration()
        let symbols: [(symbol: String, description: String)] = [
            ("rectangle.dashed", "編集モード"),
            ("cursorarrow", "範囲選択モード"),
            ("paintbrush.pointed", "マスク追加ペン"),
            ("eraser", "マスク消しゴム"),
        ]
        for (segment, entry) in symbols.enumerated() {
            canvasModeControl.setImage(
                NSImage(systemSymbolName: entry.symbol, accessibilityDescription: entry.description)?
                    .withSymbolConfiguration(configuration),
                forSegment: segment
            )
            canvasModeControl.setWidth(segmentWidth, forSegment: segment)
        }
        canvasModeControl.controlSize = size == 2 ? .large : (size == 0 ? .small : .regular)
    }

    // MARK: - 画面内テキストサイズ

    private static func currentTextSizeSetting() -> Int {
        let value = AppSettings.shared.object(forKey: textSizeDefaultsKey) as? Int
        guard let value, (0...2).contains(value) else { return 1 } // 既定値=中
        return value
    }

    /// 「テキストサイズ」設定（小/中/大）による倍率。既定（中＝現在のデフォルトサイズ）を
    /// 基準（等倍）に据え、小・大をそこから調整する。
    static func textScale() -> CGFloat {
        switch currentTextSizeSetting() {
        case 0: return 0.8
        case 2: return 1.25
        default: return 1.0
        }
    }

    /// テキストサイズ設定を反映したシステムフォント。画面上のUIラベル・キャンバス描画テキストに使う
    /// （モザイクパターンのプレビューアイコン等、固定サイズの絵として描くテキストには使わない）。
    static func scaledFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size * textScale(), weight: weight)
    }

    static func scaledMonospacedDigitFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size * textScale(), weight: weight)
    }

    /// 起動時に一度だけ組み立てる静的コントロール（ラベル・ボタン・チェックボックス・
    /// セグメントコントロール・ポップアップ）へスケール後のフォントを適用しつつ、
    /// テキストサイズ変更時に再適用できるよう基準サイズを記録する。
    /// レイヤ行・ライブラリセル・キャンバス描画テキストなど毎回作り直される表示は
    /// 呼び出し側で直接 `Self.scaledFont` を使うため、この登録は不要。
    @discardableResult
    private func applyScaledFont(_ control: NSControl, size: CGFloat, weight: NSFont.Weight = .regular) -> NSControl {
        control.font = Self.scaledFont(size, weight: weight)
        scaledTextControls.append((control, size, weight))
        return control
    }

    /// テキストサイズ変更を全画面へ即座に反映する。静的コントロールは登録済みフォントの
    /// 再適用で、動的に再構築される表示（レイヤ一覧・ライブラリ一覧・キャンバス描画・
    /// ステータスバー）は再読込/再描画で反映する。
    @objc private func textSizeChanged() {
        AppSettings.shared.set(textSizeControl.selectedSegment, forKey: Self.textSizeDefaultsKey)
        for entry in scaledTextControls {
            entry.control.font = Self.scaledFont(entry.baseSize, weight: entry.weight)
        }
        statsLabel.font = Self.scaledMonospacedDigitFont(11, weight: .regular)
        zoomLabel.font = Self.scaledMonospacedDigitFont(11, weight: .regular)
        for label in [styleOpacityValueLabel, styleBlockScaleValueLabel, styleFeatherValueLabel,
                      styleStripeWidthValueLabel, styleStripeSpacingValueLabel, styleStripeWobbleValueLabel,
                      styleCloudDensityValueLabel, maskThresholdValueLabel, groinPositionValueLabel] {
            label.font = Self.scaledMonospacedDigitFont(11, weight: .regular)
        }
        stylePatternImageLabel.font = Self.scaledFont(11)
        reloadLayerList()
        reloadLibrary()
        canvas.needsDisplay = true
        updateStatsBar()
        view.window?.layoutIfNeeded()
        updateStatus("テキストサイズを変更しました")
    }

    /// 詳細設定でアイコンサイズが変更されたとき、既存の全ツールバーボタンへ即座に反映する。
    private func applyIconSizeToAllToolbarButtons() {
        for button in toolbarIconButtons {
            guard let identifier = button.identifier?.rawValue else { continue }
            applyIconSize(to: button, symbol: identifier)
        }
        // モード切替セグメントと学習モードボタンも追従させる。学習モードボタンは
        // ON/OFF状態で記号（graduationcap/.fill）と色を出し分けるため、サイズ適用後に
        // 状態表示を再構築する（applyIconSizeがidentifierの記号で上書きするため）。
        applyIconSizeToCanvasModeControl()
        refreshLearningModeButton()
    }

    private func makeToolbarSeparator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return separator
    }

    private func configureMosaicStyleControls() {
        stylePatternPopUp.removeAllItems()
        stylePatternPopUp.addItems(withTitles: MosaicFillPattern.allCases.map(\.displayName))
        for (index, pattern) in MosaicFillPattern.allCases.enumerated() {
            stylePatternPopUp.item(at: index)?.image = makePatternPreviewImage(pattern)
        }
        stylePatternPopUp.target = self
        stylePatternPopUp.action = #selector(mosaicStyleChanged)
        stylePatternPopUp.toolTip = "選択レイヤの塗りつぶしパターン"
        stylePatternPopUp.isHidden = true
        for slider in [styleOpacitySlider, styleBlockScaleSlider, styleFeatherSlider, styleStripeWidthSlider, styleStripeSpacingSlider, styleStripeWobbleSlider, styleCloudDensitySlider, groinPositionSlider] {
            slider.target = self
            slider.translatesAutoresizingMaskIntoConstraints = false
            // 固定幅にするとサイドパネルを狭められないため、希望幅160(低優先)+最小80で圧縮可能にする。
            // 上限が無いとサイドパネルを広げた際にスライダーだけ際限なく伸びてしまう不具合が
            // あったため、最大幅も必須制約で明示する。
            let preferred = slider.widthAnchor.constraint(equalToConstant: 160)
            preferred.priority = NSLayoutConstraint.Priority(400)
            preferred.isActive = true
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
            slider.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        }
        for slider in [styleOpacitySlider, styleBlockScaleSlider, styleFeatherSlider, styleStripeWidthSlider, styleStripeSpacingSlider, styleStripeWobbleSlider, styleCloudDensitySlider] {
            slider.action = #selector(mosaicStyleChanged)
        }
        // 数値スライダーはツールチップ・VoiceOverラベルの有無がばらついていたため、
        // 行ラベルと同じ名称でまとめて設定する（設定行ごとの体験差をなくす）。
        let sliderDescriptions: [(NSSlider, String)] = [
            (styleOpacitySlider, "透明度（下げるほど元画像が透ける）"),
            (styleBlockScaleSlider, "細かさ（モザイクのブロックサイズ・ノイズ粒度・ボケ半径）"),
            (styleFeatherSlider, "輪郭ぼかし（選択範囲の境界をぼかす量）"),
            (styleStripeWidthSlider, "帯の太さ（ボーダーの各線の太さ）"),
            (styleStripeSpacingSlider, "帯の間隔（間隔部分は元画像が見える）"),
            (styleStripeWobbleSlider, "並行揺れ（各線を中央軸にランダムで傾ける度合い）"),
            (styleCloudDensitySlider, "密度（トーンの塗り面積・フラッシュの放射線の本数）"),
            (groinPositionSlider, "鼠径部位置（腰から膝へ向かう線分上の比率）")
        ]
        for (slider, description) in sliderDescriptions {
            slider.toolTip = description
            slider.setAccessibilityLabel(description)
        }
        styleTintColorWell.setAccessibilityLabel("塗りつぶし色")
        // 設定値ラベルは固定幅+等幅数字+左寄せ。右寄せだと数値が短い場合にスライダーとの間へ
        // 不要な空白が見えるため、スライダー直後から数値が始まる左寄せへ変更（GUI報告による）。
        // 固定幅は維持し、ドラッグ中に幅が変わってレイアウトが揺れるのを防ぐ。
        for label in [styleOpacityValueLabel, styleBlockScaleValueLabel, styleFeatherValueLabel,
                      styleStripeWidthValueLabel, styleStripeSpacingValueLabel, styleStripeWobbleValueLabel,
                      styleCloudDensityValueLabel, groinPositionValueLabel] {
            label.font = Self.scaledMonospacedDigitFont(11, weight: .regular)
            label.alignment = .left
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 48).isActive = true
        }
        // 「色を付ける」チェックはカラーウェルの左に置く（行ラベルは「塗りつぶし色」）
        styleTintCheckbox.title = ""
        styleTintCheckbox.toolTip = "色を付ける（チェックで塗りつぶし色を適用）"
        styleTintCheckbox.target = self
        styleTintCheckbox.action = #selector(mosaicStyleChanged)
        styleCloudToneCheckbox.target = self
        styleCloudToneCheckbox.action = #selector(mosaicStyleChanged)
        styleBorderDirectionControl.target = self
        styleBorderDirectionControl.action = #selector(mosaicStyleChanged)
        styleBorderDirectionControl.selectedSegment = 0
        styleBorderDirectionControl.toolTip = "ボーダーの方向（縦/横）"
        styleBorderRandomCheckbox.target = self
        styleBorderRandomCheckbox.action = #selector(mosaicStyleChanged)
        styleBorderRandomCheckbox.toolTip = "帯の太さ・間隔をランダムに揺らす（方向は「方向」設定に従う）"
        stylePatternToneCheckbox.target = self
        stylePatternToneCheckbox.action = #selector(mosaicStyleChanged)
        stylePatternToneCheckbox.toolTip = "塗りつぶしを網点（漫画トーン風）にする"
        applyScaledFont(stylePatternToneCheckbox, size: 12)

        styleBorderToneCheckbox.target = self
        styleBorderToneCheckbox.action = #selector(mosaicStyleChanged)
        styleBorderToneCheckbox.toolTip = "帯を網点（漫画トーン風）で塗る"
        styleFlashKindControl.target = self
        styleFlashKindControl.action = #selector(mosaicStyleChanged)
        styleFlashKindControl.selectedSegment = 0
        styleFlashKindControl.toolTip = "フラッシュの種別（集中線=黒線 / ベタフラッシュ=黒地に白 / ウニフラッシュ=紡錘形の線のリング）"
        styleFlashResetButton.target = self
        styleFlashResetButton.action = #selector(resetFlashCenter)
        styleFlashResetButton.toolTip = "フラッシュの中心を選択範囲の中央に戻す（中心位置は画像上のハンドルをドラッグして指定できます）"
        applyScaledFont(styleBorderDirectionControl, size: 11)
        applyScaledFont(styleBorderRandomCheckbox, size: 12)
        applyScaledFont(styleBorderToneCheckbox, size: 12)
        applyScaledFont(styleFlashKindControl, size: 11)
        applyScaledFont(styleFlashResetButton, size: 11)
        styleTintColorWell.target = self
        styleTintColorWell.action = #selector(mosaicStyleChanged)
        styleTintColorWell.translatesAutoresizingMaskIntoConstraints = false
        styleTintColorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        styleTintColorWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
        styleTintColorWell.color = .black
        stylePatternImageButton.target = self
        stylePatternImageButton.action = #selector(choosePatternImage)
        stylePatternImageLabel.textColor = .secondaryLabelColor
        stylePatternImageLabel.font = Self.scaledFont(11)
        applyStyleToAllButton.toolTip = "現在の設定をすべてのモザイクレイヤへ複製"
    }

    /// モザイクパターン選択を、プレビューアイコンのタイル表示（1行4個で折り返し）で構築する。
    /// 実際の選択状態は非表示の `stylePatternPopUp` を引き続き使い（他コードとの整合維持）、
    /// タイルはそれを操作する見た目だけの表現とする。
    private func makePatternTileGrid() -> NSView {
        let columns = 4
        let patterns = MosaicFillPattern.allCases
        patternTileButtons = patterns.map { pattern in
            let button = NSButton()
            button.title = ""
            button.image = makePatternPreviewImage(pattern)
            button.imagePosition = .imageOnly
            button.bezelStyle = .shadowlessSquare
            button.isBordered = true
            button.focusRingType = .none
            button.wantsLayer = true
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            button.target = self
            button.action = #selector(patternTileClicked(_:))
            button.tag = MosaicFillPattern.allCases.firstIndex(of: pattern) ?? 0
            button.toolTip = pattern.displayName
            let relay = HoverHelpRelay(text: pattern.displayName) { [weak self] text in
                self?.showHoverHelp(text)
            }
            hoverRelays.append(relay)
            button.addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: relay,
                userInfo: nil
            ))
            return button
        }
        let rows = stride(from: 0, to: patternTileButtons.count, by: columns).map { start in
            Array(patternTileButtons[start..<min(start + columns, patternTileButtons.count)])
        }
        let rowStacks = rows.map { row -> NSStackView in
            let stack = NSStackView(views: row)
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.alignment = .centerY
            return stack
        }
        let grid = NSStackView(views: rowStacks)
        grid.orientation = .vertical
        grid.spacing = 6
        grid.alignment = .leading
        return grid
    }

    @objc private func patternTileClicked(_ sender: NSButton) {
        stylePatternPopUp.selectItem(at: sender.tag)
        // パターン切替時、直前のパターン用に調整していた色付け等の詳細設定を
        // そのまま引き継ぐと「ノイズに切替えたらカラーのままだった」のような
        // 意図しない持ち越しになる。パターンごとに最後に使った設定を記憶・復元する。
        if (0..<MosaicFillPattern.allCases.count).contains(sender.tag) {
            loadMosaicStyleDetails(for: MosaicFillPattern.allCases[sender.tag])
        }
        mosaicStyleChanged()
    }

    /// 現在選択中のパターンに対応するタイルへ強調表示を反映する。
    private func refreshPatternTileSelectionHighlight() {
        let selectedIndex = stylePatternPopUp.indexOfSelectedItem
        for (index, button) in patternTileButtons.enumerated() {
            button.layer?.borderWidth = index == selectedIndex ? 2 : 0
            button.layer?.borderColor = NSColor.controlAccentColor.cgColor
            button.layer?.cornerRadius = 4
        }
    }

    private func makeInspectorPanel() -> NSView {
        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "インスペクタ")
        applyScaledFont(title, size: 15, weight: .semibold)

        let shapeRow = inspectorRow("追加形状", control: shapeControl)
        let maskRow = inspectorRow("マスク生成", control: segmentEngineControl)
        // 「対象形状」の補助しきい値。自動一発の結果が広すぎる画像でマスクを締めるための任意設定
        maskThresholdSlider.target = self
        maskThresholdSlider.action = #selector(maskThresholdChanged)
        maskThresholdSlider.translatesAutoresizingMaskIntoConstraints = false
        maskThresholdSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        maskThresholdSlider.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        let thresholdPreferred = maskThresholdSlider.widthAnchor.constraint(equalToConstant: 160)
        thresholdPreferred.priority = NSLayoutConstraint.Priority(400)
        thresholdPreferred.isActive = true
        maskThresholdSlider.toolTip = "対象形状マスクのしきい値（自動=0。上げるほどマスクが締まり、広がりすぎを抑える）"
        maskThresholdValueLabel.font = Self.scaledMonospacedDigitFont(11, weight: .regular)
        maskThresholdValueLabel.alignment = .left
        maskThresholdValueLabel.translatesAutoresizingMaskIntoConstraints = false
        maskThresholdValueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        maskThresholdSlider.doubleValue = AppSettings.shared.double(forKey: Self.maskThresholdDefaultsKey)
        maskThresholdValueLabel.stringValue = maskThresholdSlider.doubleValue < 0.01
            ? "自動" : "\(Int(maskThresholdSlider.doubleValue * 100)) %"
        let maskThresholdRow = inspectorRow("形状しきい値", control: maskThresholdSlider, trailing: maskThresholdValueLabel)

        // マスク追加ペン／マスク消しゴムの筆の太さ。いずれかのモードのときだけ表示する。
        maskBrushSlider.minValue = ManualMaskPainter.minimumWidth
        maskBrushSlider.maxValue = 0.6
        maskBrushSlider.doubleValue = canvas.maskBrushWidth
        maskBrushSlider.target = self
        maskBrushSlider.action = #selector(maskBrushWidthChanged)
        maskBrushSlider.toolTip = "ペンの太さ（選択範囲の短辺に対する割合）"
        maskBrushValueLabel.stringValue = "\(Int(canvas.maskBrushWidth * 100)) %"
        let brushRow = inspectorRow("ペンの太さ", control: maskBrushSlider, trailing: maskBrushValueLabel)
        brushRow.isHidden = true
        maskBrushRow = brushRow
        let domainRow = inspectorRow("画像種別", control: domainModeControl)
        let generateLayerRow = NSStackView(views: [generatePersonCheckbox, generatePoseCheckbox])
        generateLayerRow.orientation = .horizontal
        generateLayerRow.spacing = 10
        // 候補カテゴリは3列表示（1行目=顔領域、2行目=胸部、3行目=性器、4行目=その他）
        func categoryButton(_ category: MosaicTargetCategory) -> NSView {
            categoryFilterChecks.first(where: { $0.category == category })?.button ?? NSView()
        }
        let categories = NSGridView(views: [
            [categoryButton(.eyes), categoryButton(.lowerFace), NSGridCell.emptyContentView],
            [categoryButton(.nipple), categoryButton(.areola), NSGridCell.emptyContentView],
            [categoryButton(.femaleGenital), categoryButton(.maleGenital), NSGridCell.emptyContentView],
            [categoryButton(.other), NSGridCell.emptyContentView, NSGridCell.emptyContentView]
        ])
        categories.rowSpacing = 3
        categories.columnSpacing = 12
        categories.translatesAutoresizingMaskIntoConstraints = false
        // NSGridViewは内容から一意な幅が決まらず、親のcontentスタック（alignment=.leading）内で
        // 幅いっぱいに引き伸ばされてチェックボックス列の間隔が広がる（styleGridと同じ再発防止策）。
        categories.widthAnchor.constraint(lessThanOrEqualToConstant: 362).isActive = true
        let groinRow = inspectorRow("鼠径部位置", control: groinPositionSlider, trailing: groinPositionValueLabel)

        let tintRow = NSStackView(views: [styleTintCheckbox, styleTintColorWell])
        tintRow.orientation = .horizontal
        tintRow.spacing = 6
        // スライダーと設定値は1つのスタックにまとめ、固定8ptマージンで隣接させる
        // （NSGridViewの列幅に依存すると他行の幅次第で間隔が広がるため。鼠径部位置の行と同じ方式）。
        func sliderValueRow(_ slider: NSSlider, _ value: NSTextField) -> NSStackView {
            let stack = NSStackView(views: [slider, value])
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.alignment = .centerY
            return stack
        }
        // ランダム/トーンは候補カテゴリと同程度の間隔で横並びにする（列をまたいで離れないように）
        let borderOptionsRow = NSStackView(views: [styleBorderRandomCheckbox, styleBorderToneCheckbox])
        borderOptionsRow.orientation = .horizontal
        borderOptionsRow.spacing = 12
        let styleGrid = NSGridView(views: [
            [styleRowLabel("パターン"), makePatternTileGrid(), NSGridCell.emptyContentView],
            [styleRowLabel("透明度"), sliderValueRow(styleOpacitySlider, styleOpacityValueLabel), NSGridCell.emptyContentView],
            [styleRowLabel("塗りつぶし色"), tintRow, NSGridCell.emptyContentView],
            [styleRowLabel("細かさ"), sliderValueRow(styleBlockScaleSlider, styleBlockScaleValueLabel), NSGridCell.emptyContentView],
            [styleRowLabel("輪郭ぼかし"), sliderValueRow(styleFeatherSlider, styleFeatherValueLabel), NSGridCell.emptyContentView],
            [styleRowLabel("帯の太さ"), sliderValueRow(styleStripeWidthSlider, styleStripeWidthValueLabel), NSGridCell.emptyContentView],
            [styleRowLabel("帯の間隔"), sliderValueRow(styleStripeSpacingSlider, styleStripeSpacingValueLabel), NSGridCell.emptyContentView],
            [styleRowLabel("並行揺れ"), sliderValueRow(styleStripeWobbleSlider, styleStripeWobbleValueLabel), NSGridCell.emptyContentView],
            [styleRowLabel("方向"), styleBorderDirectionControl, NSGridCell.emptyContentView],
            [styleRowLabel("ボーダー"), borderOptionsRow, NSGridCell.emptyContentView],
            [styleRowLabel("種別"), styleFlashKindControl, NSGridCell.emptyContentView],
            [styleRowLabel("密度"), sliderValueRow(styleCloudDensitySlider, styleCloudDensityValueLabel), NSGridCell.emptyContentView],
            [styleRowLabel("トーン"), styleCloudToneCheckbox, NSGridCell.emptyContentView],
            [styleRowLabel("フラッシュ"), styleFlashResetButton, NSGridCell.emptyContentView],
            [stylePatternImageButton, stylePatternImageLabel, NSGridCell.emptyContentView],
            // 15=トーン（全パターン共通）。既存の行番号をずらさないよう末尾へ追加する。
            // ボーダー・雲・フラッシュは各々専用のトーン設定を持つため、そちらでは出さない
            // （1つのパターンにトーンのチェックが2つ並ぶのを避ける）。
            [styleRowLabel("トーン"), stylePatternToneCheckbox, NSGridCell.emptyContentView]
        ])
        styleGridView = styleGrid
        styleGrid.rowSpacing = 7
        styleGrid.columnSpacing = 8
        styleGrid.translatesAutoresizingMaskIntoConstraints = false
        // NSGridViewは（他のinspectorRow系の行と異なり）内容から一意な幅が決まらないため、
        // 親のNSStackView（content, alignment=.leading）内で幅いっぱいに引き伸ばされてしまい、
        // サイドパネルを広げるとラベル位置やスライダー-数値間の間隔が広がる不具合があった。
        // 想定最大幅（ラベル78+間隔8+スライダー220+間隔8+数値48）を明示して伸縮を止める。
        styleGrid.widthAnchor.constraint(lessThanOrEqualToConstant: 362).isActive = true

        // 「モザイク表示」はレイヤパネルの表示:設定へ移動した（他のレイヤ表示トグルと並べて操作しやすくするため）。
        let options = NSStackView(views: [autoGenerateCheckbox, autoSaveCheckbox])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 4

        let content = NSStackView(views: [
            title,
            inspectorHeading("選択範囲"), shapeRow,
            inspectorHeading("検出"), individualDetectionCheckbox, domainRow, maskRow, maskThresholdRow,
            inspectorHeading("候補カテゴリ"), categories,
            inspectorHeading("表示レイヤ生成"), generateLayerRow, groinRow,
            inspectorHeading("モザイク"), styleGrid, applyStyleToAllButton,
            inspectorHeading("ワークフロー"), options
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        content.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        content.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: panel.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        return panel
    }

    private func makeVideoPanel() -> NSView {
        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "動画編集")
        applyScaledFont(title, size: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        videoKeyframeCountLabel.textColor = .secondaryLabelColor
        videoKeyframeCountLabel.translatesAutoresizingMaskIntoConstraints = false
        applyScaledFont(videoKeyframeCountLabel, size: 12)

        let prevButton = shortcutToolbarButton("jumpToPreviousKeyframe", symbol: "backward.end", compactPanelChrome: true)
        let nextButton = shortcutToolbarButton("jumpToNextKeyframe", symbol: "forward.end", compactPanelChrome: true)
        let addButton = shortcutToolbarButton("addVideoKeyframe", symbol: "plus.rectangle.on.rectangle", compactPanelChrome: true)
        let removeButton = shortcutToolbarButton("removeVideoKeyframe", symbol: "minus.rectangle", compactPanelChrome: true)
        let selectedDeleteButton = shortcutToolbarButton("deleteSelectedVideoKeyframes", symbol: "trash", compactPanelChrome: true)
        let allDeleteButton = shortcutToolbarButton("deleteAllVideoKeyframes", symbol: "rectangle.badge.minus", compactPanelChrome: true)
        let trackButton = shortcutToolbarButton("runTrackingPreview", symbol: "scope", compactPanelChrome: true)
        let exportVideoButton = shortcutToolbarButton("exportVideoWithMosaic", symbol: "square.and.arrow.up.on.square", compactPanelChrome: true)
        let autoButton = shortcutToolbarButton("autoProcessCurrentVideo", symbol: "wand.and.stars", compactPanelChrome: true)
        let controls = WrappingToolbarView(groups: [
            [prevButton, nextButton],
            [addButton, removeButton, selectedDeleteButton, allDeleteButton],
            [trackButton, autoButton, exportVideoButton]
        ])

        videoKeyframeTableView.headerView = NSTableHeaderView()
        videoKeyframeTableView.delegate = self
        videoKeyframeTableView.dataSource = self
        videoKeyframeTableView.target = self
        videoKeyframeTableView.doubleAction = #selector(openSelectedVideoKeyframe)
        videoKeyframeTableView.onNavigate = { [weak self] direction in
            self?.navigateVideoKeyframeSelection(by: direction)
        }
        videoKeyframeTableView.onOpenSelection = { [weak self] in
            self?.openSelectedVideoKeyframe()
        }
        videoKeyframeTableView.allowsMultipleSelection = true
        videoKeyframeTableView.usesAlternatingRowBackgroundColors = true
        for column in videoKeyframeTableView.tableColumns {
            videoKeyframeTableView.removeTableColumn(column)
        }
        let noColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("videoKeyframeNo"))
        noColumn.title = "No"
        noColumn.width = 38
        let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("videoKeyframeTime"))
        timeColumn.title = "時刻"
        timeColumn.width = 72
        let roiColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("videoKeyframeROI"))
        roiColumn.title = "ROI"
        roiColumn.width = 52
        let trackingColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("videoKeyframeTracking"))
        trackingColumn.title = "追跡"
        trackingColumn.width = 48
        videoKeyframeTableView.addTableColumn(noColumn)
        videoKeyframeTableView.addTableColumn(timeColumn)
        videoKeyframeTableView.addTableColumn(roiColumn)
        videoKeyframeTableView.addTableColumn(trackingColumn)

        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.documentView = videoKeyframeTableView
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(title)
        panel.addSubview(controls)
        panel.addSubview(tableScroll)
        panel.addSubview(videoKeyframeCountLabel)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            controls.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 70),
            tableScroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            tableScroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            tableScroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            videoKeyframeCountLabel.topAnchor.constraint(equalTo: tableScroll.bottomAnchor, constant: 6),
            videoKeyframeCountLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            videoKeyframeCountLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            videoKeyframeCountLabel.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10)
        ])
        updateVideoTimelineLabels()
        return panel
    }

    private func inspectorHeading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        applyScaledFont(label, size: 12, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    /// `styleGrid`（モザイク詳細設定）の行ラベルを、`inspectorRow` と同じ最小幅（78pt）で作る。
    /// 以前は素の `NSTextField` を使っており、他の設定項目（inspectorRow使用）とラベル列の
    /// 左マージンが揃わず、サイドパネルを狭めた際にモザイク詳細設定だけレイアウトが
    /// 崩れる不具合があった。
    private func styleRowLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        applyScaledFont(label, size: 13)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 78).isActive = true
        return label
    }

    private func inspectorRow(_ title: String, control: NSView, trailing: NSView? = nil) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        applyScaledFont(label, size: 13)
        label.textColor = .secondaryLabelColor
        // 固定幅（旧: equalToConstant）だと、幅より長いラベル文字列が隣接コントロールへ
        // はみ出して重なって見える不具合があったため、最小幅のみを指定して伸縮可能にする。
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 78).isActive = true
        // 行ラベルは見た目の並びでしか意味が伝わらないため、VoiceOver向けに
        // コントロール自身へも同じ名称を設定する（呼び出し側で個別に書かなくて済むようにする）。
        control.setAccessibilityLabel(title)
        var views: [NSView] = [label, control]
        if let trailing { views.append(trailing) }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    /// パターン選択のプレビューアイコンを生成する。
    /// 白地に太字の「画」を描いた横長画像の**右半分だけ**へ実際のパターン処理を適用し、
    /// 元画像（左）と加工結果（右）の違いが一目で分かるようにする（ユーザー指定の仕様）。
    private func makePatternPreviewImage(_ pattern: MosaicFillPattern) -> NSImage? {
        let width = 32
        let height = 24
        let scale = 2  // Retina解像度で描画し、小サイズでも文字とパターンをくっきり見せる
        let pixelWidth = width * scale
        let pixelHeight = height * scale
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        // 太字の「画」をアイコン全幅に大きく描く（右半分が加工領域に掛かる）
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let text = "画" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: CGFloat(pixelHeight) * 0.95),
            .foregroundColor: NSColor.black
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(
                x: (CGFloat(pixelWidth) - textSize.width) / 2,
                y: (CGFloat(pixelHeight) - textSize.height) / 2
            ),
            withAttributes: attributes
        )
        NSGraphicsContext.restoreGraphicsState()
        guard let source = context.makeImage() else { return nil }

        // 右半分のみへ実際のエンジンでパターンを適用（プレビュー=実処理の見た目）
        let roi = MosaicROI(
            rect: NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1),
            confidence: 1,
            source: "pattern-preview",
            shape: .rectangle
        )
        // 各パラメータは小さいアイコン内で実際の加工の見た目が分かる値にする
        var style = MosaicStyle(
            pattern: pattern,
            blockScale: 6,
            stripeWidth: 4,
            stripeSpacing: 3,
            cloudDensity: 0.75
        )
        // 画像必須パターンのプレビューにはプレースホルダ（かぶせ画像=サングラス風の黒帯）を使う
        if pattern.requiresPatternImage {
            style.patternImage = Self.makeOverlayPlaceholderImage()
        }
        guard let result = try? mosaicEngine.applyMosaic(to: source, rois: [roi], style: style) else { return nil }
        let image = NSImage(cgImage: result, size: NSSize(width: width, height: height))
        image.isTemplate = false
        return image
    }

    /// かぶせ画像プレビュー用のプレースホルダ（角丸の黒帯=サングラス風。中央は透明）。
    private static func makeOverlayPlaceholderImage() -> CGImage? {
        let width = 64
        let height = 32
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(NSColor.black.withAlphaComponent(0.9).cgColor)
        let band = CGPath(
            roundedRect: CGRect(x: 2, y: 8, width: width - 4, height: 16),
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        )
        context.addPath(band)
        context.fillPath()
        return context.makeImage()
    }

    /// 現在のUI設定からモザイク描画スタイルを構築する。
    private func currentMosaicStyle() -> MosaicStyle {
        var style = MosaicStyle()
        let patterns = MosaicFillPattern.allCases
        let index = stylePatternPopUp.indexOfSelectedItem
        if (0..<patterns.count).contains(index) {
            style.pattern = patterns[index]
        }
        style.opacity = styleOpacitySlider.doubleValue
        if styleTintCheckbox.state == .on,
           let color = styleTintColorWell.color.usingColorSpace(.deviceRGB) {
            style.tintColor = (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
        }
        style.blockScale = styleBlockScaleSlider.doubleValue
        style.edgeFeather = styleFeatherSlider.doubleValue
        style.stripeWidth = styleStripeWidthSlider.doubleValue
        style.stripeSpacing = styleStripeSpacingSlider.doubleValue
        style.stripeVertical = styleBorderDirectionControl.selectedSegment == 0
        style.stripeRandom = styleBorderRandomCheckbox.state == .on
        style.stripeTone = styleBorderToneCheckbox.state == .on
        style.patternTone = stylePatternToneCheckbox.state == .on
        style.stripeWobble = styleStripeWobbleSlider.doubleValue
        style.cloudDensity = styleCloudDensitySlider.doubleValue
        style.cloudTone = styleCloudToneCheckbox.state == .on
        style.flashCenter = pendingFlashCenter
        let flashKinds = MosaicFlashKind.allCases
        if (0..<flashKinds.count).contains(styleFlashKindControl.selectedSegment) {
            style.flashKind = flashKinds[styleFlashKindControl.selectedSegment]
        }
        style.patternImage = customPatternImage
        style.patternImageIdentifier = customPatternImageIdentifier
        return style
    }

    private func defaultMosaicStyleForRendering() -> MosaicStyle {
        defaultMosaicStyle
    }

    @objc private func mosaicStyleChanged() {
        updateMosaicStyleControlAvailability()
        guard !isLoadingMosaicStyleControls else { return }
        if let selectedID = canvas.selectedROIID,
           let index = canvas.rois.firstIndex(where: { $0.id == selectedID }) {
            let newStyle = currentMosaicStyle().persistentStyle()
            guard canvas.rois[index].style != newStyle else { return }
            pushUndoSnapshot(currentEditorState())
            canvas.rois[index].style = newStyle
            hasUnsavedChanges = true
            selectedLayerStatusSummary = "\(canvas.rois[index].category.displayName) <個別>"
            updateStatsBar()
        } else {
            let previousStyle = defaultMosaicStyleForRendering().persistentStyle()
            let nextStyle = currentMosaicStyle()
            defaultMosaicStyle = nextStyle
            saveMosaicStyleSettings()
            applyVideoDefaultMosaicStyleChange(
                from: previousStyle,
                to: nextStyle.persistentStyle()
            )
        }
        // モザイク表示中は変更を即時反映する
        resumeMosaicPreviewIfNeeded()
    }

    private func applyVideoDefaultMosaicStyleChange(
        from previousStyle: MosaicROIStyle,
        to nextStyle: MosaicROIStyle
    ) {
        guard let item = currentVideoItem else { return }
        var changed = false
        currentVideoEditState.keyframes = currentVideoEditState.keyframes.map { keyframe in
            var updatedKeyframe = keyframe
            updatedKeyframe.rois = keyframe.rois.map { roi in
                var updatedROI = roi
                if updatedROI.style == nil || updatedROI.style == previousStyle {
                    updatedROI.style = nextStyle
                }
                if updatedROI != roi {
                    changed = true
                }
                return updatedROI
            }
            return updatedKeyframe
        }
        canvas.rois = canvas.rois.map { roi in
            var updatedROI = roi
            if updatedROI.style == nil || updatedROI.style == previousStyle {
                updatedROI.style = nextStyle
            }
            return updatedROI
        }
        guard changed else { return }
        do {
            try videoEditStore.save(currentVideoEditState, for: item.id)
            updateVideoTimelineLabels()
            reloadLayerList()
            updateStatsBar()
        } catch {
            showError(error)
        }
    }

    @objc private func applyCurrentStyleToAllLayers() {
        guard !canvas.rois.isEmpty else {
            updateStatus("適用先のモザイクレイヤがありません")
            return
        }
        pushUndoSnapshot(currentEditorState())
        let style = currentMosaicStyle().persistentStyle()
        for index in canvas.rois.indices {
            canvas.rois[index].style = style
        }
        hasUnsavedChanges = true
        resumeMosaicPreviewIfNeeded()
        updateStatus("現在のモザイク設定を全レイヤへ適用しました")
    }

    private func loadMosaicStyleForSelection(_ roi: MosaicROI?) {
        isLoadingMosaicStyleControls = true
        defer {
            updateMosaicStyleControlAvailability()
            isLoadingMosaicStyleControls = false
        }
        guard let roi else {
            selectedLayerStatusSummary = nil
            updateStatsBar()
            applyMosaicStyleToControls(defaultMosaicStyle)
            return
        }
        if let individual = roi.style {
            selectedLayerStatusSummary = "\(roi.category.displayName) <個別>"
            updateStatsBar()
            applyMosaicStyleToControls(MosaicStyle(roiStyle: individual, patternImage: customPatternImage))
        } else {
            selectedLayerStatusSummary = "\(roi.category.displayName) <継承>"
            updateStatsBar()
            applyMosaicStyleToControls(defaultMosaicStyle)
        }
    }

    private func applyMosaicStyleToControls(_ style: MosaicStyle) {
        if let index = MosaicFillPattern.allCases.firstIndex(of: style.pattern) {
            stylePatternPopUp.selectItem(at: index)
        }
        styleOpacitySlider.doubleValue = style.opacity
        styleBlockScaleSlider.doubleValue = style.blockScale
        styleFeatherSlider.doubleValue = style.edgeFeather
        styleStripeWidthSlider.doubleValue = style.stripeWidth
        styleStripeSpacingSlider.doubleValue = style.stripeSpacing
        styleBorderDirectionControl.selectedSegment = style.stripeVertical ? 0 : 1
        styleBorderRandomCheckbox.state = style.stripeRandom ? .on : .off
        styleBorderToneCheckbox.state = style.stripeTone ? .on : .off
        styleStripeWobbleSlider.doubleValue = style.stripeWobble
        styleCloudDensitySlider.doubleValue = style.cloudDensity
        styleCloudToneCheckbox.state = style.cloudTone ? .on : .off
        pendingFlashCenter = style.flashCenter
        styleFlashKindControl.selectedSegment = MosaicFlashKind.allCases.firstIndex(of: style.flashKind) ?? 0
        customPatternImageIdentifier = style.patternImageIdentifier
        customPatternImage = style.patternImageIdentifier.flatMap { patternImage(for: $0) } ?? style.patternImage
        updateCustomPatternPreview(customPatternImage)
        stylePatternImageLabel.stringValue = style.patternImageIdentifier == nil ? "未選択" : "保存済みパターン"
        if let tint = style.tintColor {
            styleTintCheckbox.state = .on
            styleTintColorWell.color = NSColor(deviceRed: tint.red, green: tint.green, blue: tint.blue, alpha: 1)
        } else {
            styleTintCheckbox.state = .off
        }
    }

    private func updateMosaicStyleControlAvailability() {
        let patterns = MosaicFillPattern.allCases
        let index = stylePatternPopUp.indexOfSelectedItem
        let pattern = (0..<patterns.count).contains(index) ? patterns[index] : .pixelate
        refreshPatternTileSelectionHighlight()
        styleStripeWidthSlider.isEnabled = pattern.isStripes
        styleStripeSpacingSlider.isEnabled = pattern.isStripes
        styleBorderRandomCheckbox.isEnabled = pattern.isStripes
        styleBorderToneCheckbox.isEnabled = pattern.isStripes
        // ランダム時も方向設定は有効（太さ・間隔のみランダム化される仕様へ変更）
        styleBorderDirectionControl.isEnabled = pattern.isStripes
        // 並行揺れは「ランダム」OFFでも単独で使える（GUI報告 2026-08-09: ランダムON必須だと
        // ボーダー選択直後はスライダーが無効のままで設定できない）
        styleStripeWobbleSlider.isEnabled = pattern.isStripes
        styleCloudDensitySlider.isEnabled = pattern == .clouds || pattern == .flash
        styleCloudToneCheckbox.isEnabled = pattern == .clouds || pattern == .flash
        styleFlashKindControl.isEnabled = pattern == .flash
        styleFlashResetButton.isEnabled = pattern == .flash && canvas.selectedROIID != nil
        stylePatternImageButton.isEnabled = pattern.requiresPatternImage
        styleCloudDensityValueLabel.stringValue = "\(Int(styleCloudDensitySlider.doubleValue * 100)) %"
        styleOpacityValueLabel.stringValue = "\(Int(styleOpacitySlider.doubleValue * 100)) %"
        styleBlockScaleValueLabel.stringValue = "\(Int(styleBlockScaleSlider.doubleValue)) px"
        styleFeatherValueLabel.stringValue = "\(Int(styleFeatherSlider.doubleValue)) px"
        styleStripeWidthValueLabel.stringValue = "\(Int(styleStripeWidthSlider.doubleValue)) px"
        styleStripeSpacingValueLabel.stringValue = "\(Int(styleStripeSpacingSlider.doubleValue)) px"
        styleStripeWobbleValueLabel.stringValue = "\(Int(styleStripeWobbleSlider.doubleValue * 100)) %"
        updateStyleGridRowVisibility(pattern: pattern)
        updateFlashHandle(pattern: pattern)
    }

    /// パターン切替時、関連する設定行だけを表示する（無関係な行は非表示。
    /// 「トーン」等の同名行が複数パターン分並んで見える問題の解消も兼ねる）。
    private func updateStyleGridRowVisibility(pattern: MosaicFillPattern) {
        guard let grid = styleGridView else { return }
        let isBorder = pattern.isStripes
        let isFlash = pattern == .flash
        let isClouds = pattern == .clouds
        let usesBlockScale = pattern != .border && pattern != .overlayImage
        // 行番号: 0=パターン 1=透明度 2=塗りつぶし色 3=細かさ 4=輪郭ぼかし 5=帯の太さ
        // 6=帯の間隔 7=並行揺れ 8=方向 9=ボーダー 10=種別(フラッシュ) 11=密度 12=トーン(雲/フラッシュ)
        // 13=フラッシュ 14=画像選択 15=トーン(全パターン共通)
        let visibility: [Int: Bool] = [
            2: pattern != .overlayImage,
            3: usesBlockScale,
            4: pattern != .overlayImage,
            5: isBorder,
            6: isBorder,
            7: isBorder,
            8: isBorder,
            9: isBorder,
            10: isFlash,
            11: isClouds || isFlash,
            12: isClouds || isFlash,
            13: isFlash,
            14: pattern.requiresPatternImage,
            15: !isBorder && !isClouds && !isFlash && pattern != .overlayImage
        ]
        for (rowIndex, visible) in visibility where rowIndex < grid.numberOfRows {
            grid.row(at: rowIndex).isHidden = !visible
        }
    }

    /// キャンバス上のフラッシュ中心ハンドル表示を、現在のパターン・ROI選択状態へ同期する。
    private func updateFlashHandle(pattern: MosaicFillPattern) {
        if pattern == .flash, canvas.selectedROIID != nil {
            canvas.flashHandleLocal = pendingFlashCenter ?? NormalizedPoint(x: 0.5, y: 0.5)
        } else {
            canvas.flashHandleLocal = nil
        }
    }

    /// フラッシュの中心位置をROI中心へリセットする。
    @objc private func resetFlashCenter() {
        pendingFlashCenter = nil
        canvas.flashHandleLocal = NormalizedPoint(x: 0.5, y: 0.5)
        mosaicStyleChanged()
    }

    /// 任意パターン画像を選択し、ライブラリ配下へコピーして永続化する。
    /// パターン画像ボタン: 同梱素材（SNS向け）のメニューを表示する。
    /// レイヤタグ（現在編集中のROIのカテゴリ）に応じて、かぶせ画像素材の候補表示を切り替える。
    /// 該当カテゴリ向けの素材を先頭にまとめ、それ以外は「その他の素材」として下にまとめる
    /// （改善: パターン選択画像はレイヤタグ毎に表示内容を変更する）。
    @objc private func choosePatternImage() {
        let menu = NSMenu()
        let currentCategory = canvas.selectedROIID.flatMap { id in canvas.rois.first { $0.id == id } }?.category
        func addAsset(_ asset: OverlayAsset) {
            let item = NSMenuItem(
                title: "\(asset.displayName)（\(asset.suggestedCategory.displayName)向け）",
                action: #selector(selectBuiltinOverlay(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = asset.identifier
            if let image = OverlayAssetCatalog.image(for: asset.identifier) {
                let preview = NSImage(cgImage: image, size: NSSize(width: 40, height: 40 * CGFloat(image.height) / CGFloat(image.width)))
                item.image = preview
            }
            menu.addItem(item)
        }
        if let currentCategory {
            let matching = OverlayAssetCatalog.assets.filter { $0.suggestedCategory == currentCategory }
            let others = OverlayAssetCatalog.assets.filter { $0.suggestedCategory != currentCategory }
            if !matching.isEmpty {
                let header = NSMenuItem(title: "\(currentCategory.displayName)向けの素材", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                matching.forEach(addAsset)
            }
            if !others.isEmpty {
                if !matching.isEmpty { menu.addItem(.separator()) }
                let header = NSMenuItem(title: "その他の同梱素材", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                others.forEach(addAsset)
            }
        } else {
            let header = NSMenuItem(title: "同梱素材（SNS向け）", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            OverlayAssetCatalog.assets.forEach(addAsset)
        }
        menu.addItem(.separator())
        let fileItem = NSMenuItem(title: "ファイルから選択...", action: #selector(choosePatternImageFromFile), keyEquivalent: "")
        fileItem.target = self
        menu.addItem(fileItem)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: stylePatternImageButton.bounds.height + 4),
            in: stylePatternImageButton
        )
    }

    /// `patternImageCache`へ登録し、上限を超えたらLRU順で古いものから破棄する。
    private func setPatternImageCache(_ image: CGImage, for identifier: String) {
        patternImageCache[identifier] = image
        patternImageCacheOrder.removeAll { $0 == identifier }
        patternImageCacheOrder.append(identifier)
        while patternImageCacheOrder.count > Self.patternImageCacheLimit {
            let oldest = patternImageCacheOrder.removeFirst()
            patternImageCache.removeValue(forKey: oldest)
        }
    }

    /// 同梱素材をパターン画像として選択する。
    @objc private func selectBuiltinOverlay(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let image = OverlayAssetCatalog.image(for: identifier),
              let asset = OverlayAssetCatalog.assets.first(where: { $0.identifier == identifier }) else { return }
        customPatternImage = image
        customPatternImageIdentifier = identifier
        setPatternImageCache(image, for: identifier)
        stylePatternImageLabel.stringValue = asset.displayName
        updateCustomPatternPreview(image)
        mosaicStyleChanged()
    }

    @objc private func choosePatternImageFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try imageLoader.loadImage(from: url)
            customPatternImage = loaded.cgImage
            let identifier = UUID().uuidString
            customPatternImageIdentifier = identifier
            setPatternImageCache(loaded.cgImage, for: identifier)
            try libraryEngine.savePatternImage(loaded.cgImage, identifier: identifier)
            stylePatternImageLabel.stringValue = url.lastPathComponent
            updateCustomPatternPreview(loaded.cgImage)
            mosaicStyleChanged()
        } catch {
            showError(error)
        }
    }

    private func patternImage(for identifier: String) -> CGImage? {
        if let cached = patternImageCache[identifier] { return cached }
        if identifier.hasPrefix(OverlayAssetCatalog.identifierPrefix) {
            guard let image = OverlayAssetCatalog.image(for: identifier) else { return nil }
            setPatternImageCache(image, for: identifier)
            return image
        }
        let url: URL?
        if identifier == "legacy" {
            url = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("newMosaic/Patterns/custom_pattern.png")
        } else {
            url = libraryEngine.patternURL(identifier: identifier)
        }
        guard let url, let loaded = try? imageLoader.loadImage(from: url) else { return nil }
        setPatternImageCache(loaded.cgImage, for: identifier)
        return loaded.cgImage
    }

    private func updateCustomPatternPreview(_ image: CGImage?) {
        guard let index = MosaicFillPattern.allCases.firstIndex(of: .customImage),
              let item = stylePatternPopUp.item(at: index) else { return }
        item.image = image.map { NSImage(cgImage: $0, size: NSSize(width: 24, height: 18)) }
            ?? makePatternPreviewImage(.customImage)
    }

    /// パターン毎の詳細設定を独立して記憶するためのUserDefaultsキー接頭辞
    /// （例: "MosaicStyle.noise.opacity"）。パターン切替時に前のパターンの
    /// 色付け等を引き継いでしまわないようにするための名前空間分け。
    private func mosaicStyleKeyPrefix(for pattern: MosaicFillPattern) -> String {
        "MosaicStyle.\(pattern.rawValue)."
    }

    private func saveMosaicStyleSettings() {
        let defaults = AppSettings.shared
        let patterns = MosaicFillPattern.allCases
        let index = stylePatternPopUp.indexOfSelectedItem
        guard (0..<patterns.count).contains(index) else { return }
        let pattern = patterns[index]
        defaults.set(pattern.rawValue, forKey: "MosaicStyle.pattern")
        let prefix = mosaicStyleKeyPrefix(for: pattern)
        defaults.set(styleOpacitySlider.doubleValue, forKey: prefix + "opacity")
        defaults.set(styleTintCheckbox.state == .on, forKey: prefix + "useTint")
        if let color = styleTintColorWell.color.usingColorSpace(.deviceRGB) {
            defaults.set(Double(color.redComponent), forKey: prefix + "tintR")
            defaults.set(Double(color.greenComponent), forKey: prefix + "tintG")
            defaults.set(Double(color.blueComponent), forKey: prefix + "tintB")
        }
        defaults.set(styleBlockScaleSlider.doubleValue, forKey: prefix + "blockScale")
        defaults.set(styleFeatherSlider.doubleValue, forKey: prefix + "edgeFeather")
        defaults.set(styleStripeWidthSlider.doubleValue, forKey: prefix + "stripeWidth")
        defaults.set(styleStripeSpacingSlider.doubleValue, forKey: prefix + "stripeSpacing")
        defaults.set(styleBorderDirectionControl.selectedSegment == 0, forKey: prefix + "stripeVertical")
        defaults.set(styleBorderRandomCheckbox.state == .on, forKey: prefix + "stripeRandom")
        defaults.set(styleBorderToneCheckbox.state == .on, forKey: prefix + "stripeTone")
        defaults.set(stylePatternToneCheckbox.state == .on, forKey: prefix + "patternTone")
        defaults.set(styleStripeWobbleSlider.doubleValue, forKey: prefix + "stripeWobble")
        defaults.set(styleCloudDensitySlider.doubleValue, forKey: prefix + "cloudDensity")
        defaults.set(styleCloudToneCheckbox.state == .on, forKey: prefix + "cloudTone")
        let flashKindsForSave = MosaicFlashKind.allCases
        if (0..<flashKindsForSave.count).contains(styleFlashKindControl.selectedSegment) {
            defaults.set(flashKindsForSave[styleFlashKindControl.selectedSegment].rawValue, forKey: prefix + "flashKind")
        }
        defaults.set(customPatternImageIdentifier, forKey: prefix + "patternImageIdentifier")
    }

    private func loadMosaicStyleSettings() {
        let defaults = AppSettings.shared
        var pattern = MosaicFillPattern.pixelate
        if let raw = defaults.string(forKey: "MosaicStyle.pattern"),
           let saved = MosaicFillPattern(rawValue: raw) {
            pattern = saved
        }
        if let index = MosaicFillPattern.allCases.firstIndex(of: pattern) {
            stylePatternPopUp.selectItem(at: index)
        }
        loadMosaicStyleDetails(for: pattern)
    }

    /// 指定パターンの詳細設定（透明度・色付け・粒度等）を、そのパターン専用に
    /// 記憶された値（無ければ既定値）から復元する。パターン切替のたびに呼び出し、
    /// 前のパターンの設定（特に色付け）を引き継がないようにする。
    private func loadMosaicStyleDetails(for pattern: MosaicFillPattern) {
        isLoadingMosaicStyleControls = true
        defer {
            updateMosaicStyleControlAvailability()
            isLoadingMosaicStyleControls = false
        }
        let defaults = AppSettings.shared
        let prefix = mosaicStyleKeyPrefix(for: pattern)
        let fallback = MosaicStyle(pattern: pattern)
        styleOpacitySlider.doubleValue = defaults.object(forKey: prefix + "opacity") != nil
            ? defaults.double(forKey: prefix + "opacity") : fallback.opacity
        styleTintCheckbox.state = defaults.bool(forKey: prefix + "useTint") ? .on : .off
        if defaults.object(forKey: prefix + "tintR") != nil {
            styleTintColorWell.color = NSColor(
                deviceRed: defaults.double(forKey: prefix + "tintR"),
                green: defaults.double(forKey: prefix + "tintG"),
                blue: defaults.double(forKey: prefix + "tintB"),
                alpha: 1
            )
        }
        // 「細かさ」の既定値はパターンごとに変える。ノイズは粒が細かい方が自然なため4px
        // （ユーザー要望 2026-08-03）。他のパターンは従来どおり。
        let blockScaleFallback = pattern == .noise ? 4.0 : fallback.blockScale
        styleBlockScaleSlider.doubleValue = defaults.object(forKey: prefix + "blockScale") != nil
            ? defaults.double(forKey: prefix + "blockScale") : blockScaleFallback
        styleFeatherSlider.doubleValue = defaults.object(forKey: prefix + "edgeFeather") != nil
            ? defaults.double(forKey: prefix + "edgeFeather") : fallback.edgeFeather
        styleStripeWidthSlider.doubleValue = defaults.object(forKey: prefix + "stripeWidth") != nil
            ? defaults.double(forKey: prefix + "stripeWidth") : fallback.stripeWidth
        styleStripeSpacingSlider.doubleValue = defaults.object(forKey: prefix + "stripeSpacing") != nil
            ? defaults.double(forKey: prefix + "stripeSpacing") : fallback.stripeSpacing
        styleBorderDirectionControl.selectedSegment = (defaults.object(forKey: prefix + "stripeVertical") != nil
            ? defaults.bool(forKey: prefix + "stripeVertical") : fallback.stripeVertical) ? 0 : 1
        styleBorderRandomCheckbox.state = defaults.bool(forKey: prefix + "stripeRandom") ? .on : .off
        styleBorderToneCheckbox.state = defaults.bool(forKey: prefix + "stripeTone") ? .on : .off
        stylePatternToneCheckbox.state = defaults.bool(forKey: prefix + "patternTone") ? .on : .off
        styleStripeWobbleSlider.doubleValue = defaults.object(forKey: prefix + "stripeWobble") != nil
            ? defaults.double(forKey: prefix + "stripeWobble") : fallback.stripeWobble
        if let rawKind = defaults.string(forKey: prefix + "flashKind"),
           let savedKind = MosaicFlashKind(rawValue: rawKind),
           let kindIndex = MosaicFlashKind.allCases.firstIndex(of: savedKind) {
            styleFlashKindControl.selectedSegment = kindIndex
        } else {
            // v0.0.00080の一時キー（flashBeta: Bool）からの移行
            styleFlashKindControl.selectedSegment = defaults.bool(forKey: prefix + "flashBeta") ? 1 : 0
        }
        pendingFlashCenter = nil
        styleCloudDensitySlider.doubleValue = defaults.object(forKey: prefix + "cloudDensity") != nil
            ? defaults.double(forKey: prefix + "cloudDensity") : fallback.cloudDensity
        styleCloudToneCheckbox.state = defaults.bool(forKey: prefix + "cloudTone") ? .on : .off
        customPatternImageIdentifier = nil
        customPatternImage = nil
        if let identifier = defaults.string(forKey: prefix + "patternImageIdentifier"),
           let image = patternImage(for: identifier) {
            customPatternImageIdentifier = identifier
            customPatternImage = image
            stylePatternImageLabel.stringValue = "保存済みパターン"
        } else if pattern.requiresPatternImage, let legacy = patternImage(for: "legacy") {
            // 旧バージョン（パターン毎の記憶が無かった単一グローバル設定時代）の
            // 保存先からの移行フォールバック。画像必須パターンでのみ意味を持つ。
            customPatternImageIdentifier = "legacy"
            customPatternImage = legacy
            stylePatternImageLabel.stringValue = "保存済みパターン"
        } else {
            stylePatternImageLabel.stringValue = "未選択"
        }
        updateCustomPatternPreview(customPatternImage)
        updateMosaicStyleControlAvailability()
        // 個別設定中のROIを選択したままパターンを切替えた場合、ここでグローバルな
        // 既定スタイルまで書き換えてしまわないようにする（そちらは直後の
        // mosaicStyleChanged()が選択中ROIの個別スタイルとして反映する）。
        if canvas.selectedROIID == nil {
            defaultMosaicStyle = currentMosaicStyle()
        }
    }

    /// 画像種別（自動判定/実写/イラスト・漫画）の手動指定。永続化され、次回の候補生成から適用される。
    @objc private func domainModeChanged() {
        let index = domainModeControl.indexOfSelectedItem
        AppSettings.shared.set(index, forKey: Self.domainModeDefaultsKey)
        let labels = ["自動判定", "実写（固定）", "イラスト・漫画（固定）"]
        if (0..<labels.count).contains(index) {
            updateStatus("画像種別: \(labels[index])（次回の候補生成から適用）")
        }
    }

    /// 鼠径部ROIの位置基準（腰0%〜膝100%の比率）を事前補正する。設定は永続化され、次回の候補生成から適用される。
    @objc private func groinPositionChanged() {
        let ratio = groinPositionSlider.doubleValue
        AppSettings.shared.set(ratio, forKey: Self.groinPositionDefaultsKey)
        groinPositionValueLabel.stringValue = "\(Int(ratio * 100)) %"
        updateStatus("鼠径部位置の基準: 腰から膝方向へ\(Int(ratio * 100))%（次回の候補生成から適用）")
    }

    /// レイヤパネル先頭の表示トグル（人物検出/骨格検出/ROI）を該当レイヤへ一括適用する。
    @objc private func toggleDetectionLayers() {
        editorRevision += 1
        let personOn = personLayerCheckbox.state == .on
        let poseOn = poseLayerCheckbox.state == .on
        let roiOn = roiLayerCheckbox.state == .on
        for leaf in allLayerLeaves() {
            if leaf.kind.isPerson { leaf.isVisible = personOn }
            if leaf.kind.isPose { leaf.isVisible = poseOn }
            if leaf.kind == .roi { leaf.isVisible = roiOn }
        }
        applyLayerVisibility()
        updateLayerDetailToggleAvailability()
        reloadLayerList()
    }

    /// 候補生成で得た人物・骨格の検出結果に合わせてレイヤを再構築する。
    /// 人物ごとに「人物N」グループを作り、**骨格の関節が実際に検出できた人物のみ**骨格検出レイヤを入れる。
    /// 骨格が取れていない人物へ固定比率のフォールバック矩形を骨格レイヤとして表示するのは
    /// 「検出していないものは表示しない」方針に反するため行わない（アニメ等で偽の骨格枠が出ていた問題の修正）。
    private func rebuildDetectionLayers(
        personCount: Int,
        poseAvailability: [Bool],
        includePersonLayer: Bool = true,
        includePoseLayer: Bool = true
    ) {
        ungroupedLayers.removeAll { $0.kind.isPerson || $0.kind.isPose }
        for group in layerGroups {
            group.children.removeAll { $0.kind.isPerson || $0.kind.isPose }
        }
        layerGroups.removeAll { $0.children.isEmpty }

        for index in 0..<personCount {
            var children: [LayerLeaf] = []
            if includePersonLayer {
                children.append(LayerLeaf(kind: .person(index), isVisible: false))
            }
            let hasPose = index < poseAvailability.count && poseAvailability[index]
            if includePoseLayer && hasPose {
                children.append(LayerLeaf(kind: .pose(index), isVisible: false))
            }
            guard !children.isEmpty else { continue }
            layerGroups.append(LayerGroup(name: "人物\(index + 1)", children: children))
        }
        reloadLayerList()
    }

    // MARK: - レイヤ表示・グループ化

    /// アプリウィンドウ右下（ライブラリの下）に常時表示するレイヤパネルを構築する。
    private func makeLayerPanel() -> NSView {
        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "レイヤ")
        applyScaledFont(title, size: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        // レイヤ表示トグル（ツールバーから移設: 人物検出レイヤ・骨格検出レイヤ・ROIレイヤ・
        // モザイク表示の一括ON/OFF）
        let togglesLabel = NSTextField(labelWithString: "表示:")
        applyScaledFont(togglesLabel, size: 13)
        togglesLabel.textColor = .secondaryLabelColor
        applyScaledFont(personLayerCheckbox, size: 13)
        applyScaledFont(poseLayerCheckbox, size: 13)
        applyScaledFont(roiLayerCheckbox, size: 13)
        applyScaledFont(mosaicPreviewCheckbox, size: 13)
        let togglesRow = WrappingControlRowView(groups: [
            [togglesLabel, roiLayerCheckbox],
            [mosaicPreviewCheckbox],
            [personLayerCheckbox],
            [poseLayerCheckbox]
        ])

        // 輪郭/タグ表示は要素毎の個別設定から全レイヤ一括設定へ変更（レイヤ行の表示幅も拡がる）。
        let detailToggleLabel = NSTextField(labelWithString: "詳細:")
        applyScaledFont(detailToggleLabel, size: 13)
        detailToggleLabel.textColor = .secondaryLabelColor
        applyScaledFont(layerOutlineAllCheckbox, size: 13)
        applyScaledFont(layerTagAllCheckbox, size: 13)
        layerOutlineAllCheckbox.state = .on
        layerTagAllCheckbox.state = .on
        layerOutlineAllCheckbox.target = self
        layerOutlineAllCheckbox.action = #selector(toggleAllLayerOutlines)
        layerTagAllCheckbox.target = self
        layerTagAllCheckbox.action = #selector(toggleAllLayerTags)
        let detailTogglesRow = WrappingControlRowView(groups: [
            [detailToggleLabel, layerOutlineAllCheckbox],
            [layerTagAllCheckbox]
        ])

        layerOutlineView.headerView = nil
        layerOutlineView.dataSource = self
        layerOutlineView.delegate = self
        layerOutlineView.allowsMultipleSelection = true
        layerOutlineView.indentationPerLevel = 14
        attachLayerContextMenu()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
        column.width = 220
        column.resizingMask = .autoresizingMask
        layerOutlineView.addTableColumn(column)
        layerOutlineView.outlineTableColumn = column

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        // 内容が収まっている時にスクロールバーが出ていると、まだ続きがあるように見えて紛らわしい
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = layerOutlineView

        groupButton.target = self
        groupButton.action = #selector(groupSelectedLayers)
        ungroupButton.target = self
        ungroupButton.action = #selector(ungroupSelectedGroup)
        let deleteLayerButton = SquareIconButton()
        configureToolbarButton(deleteLayerButton, symbol: "trash", help: "選択レイヤを削除", action: #selector(deleteSelectedLayers))
        applyScaledFont(groupButton, size: 12)
        applyScaledFont(ungroupButton, size: 12)
        let buttons = NSStackView(views: [groupButton, ungroupButton, deleteLayerButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(title)
        panel.addSubview(togglesRow)
        panel.addSubview(detailTogglesRow)
        panel.addSubview(scrollView)
        panel.addSubview(buttons)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            togglesRow.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            togglesRow.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            togglesRow.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            detailTogglesRow.topAnchor.constraint(equalTo: togglesRow.bottomAnchor, constant: 4),
            detailTogglesRow.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            detailTogglesRow.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: detailTogglesRow.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            buttons.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -8),
            buttons.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10)
        ])
        return panel
    }

    /// レイヤ一覧を再読込し、全階層を展開した状態で表示する（通常時は常に全展開）。
    private func reloadLayerList() {
        rebuildROIListEntries()
        layerOutlineView.reloadData()
        layerOutlineView.expandItem(nil, expandChildren: true)
        layerOutlineView.sizeLastColumnToFit()
        syncROIListSelectionFromCanvas()
    }

    /// ROI選択リストの行データを再構築する。同一カテゴリ名が複数ある場合のみ連番を付与する。
    /// あわせて `roiGroupName` が同じROIをグループへまとめる（レイヤ一覧のグループ化機能対応）。
    private func rebuildROIListEntries() {
        var counts: [String: Int] = [:]
        for roi in canvas.rois { counts[roi.category.displayName, default: 0] += 1 }
        var counters: [String: Int] = [:]
        var entryByROIID: [UUID: ROIListEntry] = [:]
        roiListEntries = canvas.rois.map { roi in
            let name = roi.category.displayName
            let pattern = (roi.style?.pattern ?? defaultMosaicStyle.pattern).displayName
            // レイヤ名とモザイク種別の間に、設定が個別かどうかのフラグを表示する
            // （画面下部ステータスバーの表記と統一: 個別設定=<個別>、既定設定を継承=<継承>）。
            let inheritanceFlag = roi.style == nil ? "<継承>" : "<個別>"
            let entry: ROIListEntry
            if counts[name, default: 0] > 1 {
                counters[name, default: 0] += 1
                entry = ROIListEntry(roiID: roi.id, title: "\(name) \(counters[name] ?? 0) \(inheritanceFlag) · \(pattern)")
            } else {
                entry = ROIListEntry(roiID: roi.id, title: "\(name) \(inheritanceFlag) · \(pattern)")
            }
            entryByROIID[roi.id] = entry
            return entry
        }
        roiListSignature = canvas.rois.map {
            "\($0.id.uuidString)#\($0.category.rawValue)#\(($0.style?.pattern ?? defaultMosaicStyle.pattern).rawValue)#\($0.roiGroupName ?? "")"
        }

        var groupsByName: [String: ROIListGroup] = [:]
        var groupOrder: [String] = []
        var ungrouped: [ROIListEntry] = []
        for roi in canvas.rois {
            guard let entry = entryByROIID[roi.id] else { continue }
            if let groupName = roi.roiGroupName {
                if let group = groupsByName[groupName] {
                    group.children.append(entry)
                } else {
                    let group = ROIListGroup(name: groupName, children: [entry])
                    groupsByName[groupName] = group
                    groupOrder.append(groupName)
                }
            } else {
                ungrouped.append(entry)
            }
        }
        roiListGroups = groupOrder.compactMap { groupsByName[$0] }
        ungroupedROIEntries = ungrouped
    }

    /// ROIの件数・カテゴリが変わったときだけリストを再読込する（ドラッグ移動中の毎フレーム再描画を避ける）。
    private func refreshROIListIfNeeded() {
        let signature = canvas.rois.map {
            "\($0.id.uuidString)#\($0.category.rawValue)#\(($0.style?.pattern ?? defaultMosaicStyle.pattern).rawValue)#\($0.roiGroupName ?? "")"
        }
        guard signature != roiListSignature else { return }
        reloadLayerList()
    }

    /// キャンバス側のROI選択をレイヤパネルのROIリストへ反映する。
    private func syncROIListSelectionFromCanvas() {
        guard !isSyncingROISelection else { return }
        isSyncingROISelection = true
        defer { isSyncingROISelection = false }
        guard let selectedID = canvas.selectedROIID,
              let entry = roiListEntries.first(where: { $0.roiID == selectedID }) else {
            for index in layerOutlineView.selectedRowIndexes
            where layerOutlineView.item(atRow: index) is ROIListEntry {
                layerOutlineView.deselectRow(index)
            }
            return
        }
        let row = layerOutlineView.row(forItem: entry)
        guard row >= 0 else { return }
        layerOutlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        layerOutlineView.scrollRowToVisible(row)
    }

    /// 範囲選択モードで画像上をラバーバンド選択した結果（複数ROI）を、レイヤ一覧側の
    /// 選択にも反映する（画像上の一括選択とレイヤ一覧の選択状態を一致させる）。
    private func syncROIListSelectionFromCanvasGroup(_ ids: Set<UUID>) {
        guard !isSyncingROISelection else { return }
        isSyncingROISelection = true
        defer { isSyncingROISelection = false }
        guard !ids.isEmpty else {
            for index in layerOutlineView.selectedRowIndexes
            where layerOutlineView.item(atRow: index) is ROIListEntry {
                layerOutlineView.deselectRow(index)
            }
            return
        }
        let rows = roiListEntries
            .filter { ids.contains($0.roiID) }
            .map { layerOutlineView.row(forItem: $0) }
            .filter { $0 >= 0 }
        guard !rows.isEmpty else { return }
        layerOutlineView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    /// ツールバーの編集モード/範囲選択モード切替。
    @objc private func canvasModeChanged() {
        switch canvasModeControl.selectedSegment {
        case 1: canvas.interactionMode = .marqueeSelect
        case 2: canvas.interactionMode = .maskPaint
        case 3: canvas.interactionMode = .maskErase
        default: canvas.interactionMode = .edit
        }
        maskBrushRow?.isHidden = !canvas.interactionMode.editsMask
    }

    /// 保存済みログを削除する（ローテーションの世代ファイルも含む）。
    ///
    /// 取り消せないので確認ダイアログを出す。今回の起動分（`OSLogStore`にあるもの）は
    /// アプリ側から物理削除はできないが、消去時刻より前のエントリを表示・退避の対象外に
    /// することで、画面上は完全にクリアされたように見せる
    /// （GUI報告 2026-08-06「クリア操作を行っても過去ログがすべて削除されていない」）。
    @objc private func clearDebugLog() {
        let alert = NSAlert()
        alert.messageText = "保存済みのデバッグログを削除しますか？"
        alert.informativeText = """
            \(MosaicWindowController.debugLogFile.existingURLs().count)個のログファイル（世代分を含む）を削除します。
            この操作は取り消せません。
            """
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        MosaicWindowController.debugLogFile.removeAll()
        // 消去時刻を記録し、これ以前の今回起動分エントリを表示・退避の両方から除外する。
        // 従来の「退避位置を最後の行まで進める」方式は退避の復活だけを防ぎ、
        // 表示側（OSLogStoreから毎回再取得する今回起動分）には過去ログが残っていた。
        MosaicWindowController.debugLogClearedAt.value = Date()
        refreshDebugLog()
        updateStatus("保存済みのデバッグログを削除しました")
        AppLog.ui.info("デバッグログを削除しました")
    }

    /// マスク追加ペン／マスク消しゴムの太さ変更。
    @objc private func maskBrushWidthChanged() {
        canvas.maskBrushWidth = maskBrushSlider.doubleValue
        maskBrushValueLabel.stringValue = "\(Int(maskBrushSlider.doubleValue * 100)) %"
    }

    /// マスク追加ペンでレイヤ未選択のとき、モザイク対象へ新しいレイヤ（その他）を作る。
    ///
    /// 作ったレイヤは「その他」グループへ入れる（自動検出のカテゴリ別グループと並ぶ）。
    /// マスクは手描きのみで使うので、生成方式は図形にせずROI形状（矩形）をそのまま使う。
    private func addLayerForMaskPaint(rect: NormalizedRect) -> UUID? {
        guard loadedImage != nil else { return nil }
        pushUndoSnapshot(currentEditorState())
        let roi = MosaicROI(
            rect: rect,
            confidence: 1.0,
            source: "manual",
            shape: .rectangle,
            category: .other,
            roiGroupName: MosaicTargetCategory.other.displayName
        )
        canvas.rois.append(roi)
        canvas.selectedROIID = roi.id
        hasUnsavedChanges = true
        reloadLayerList()
        updateStatus("モザイク対象へ新しいレイヤを追加しました（\(MosaicTargetCategory.other.displayName)）")
        return roi.id
    }

    /// ペンで塗った／消したストロークを選択中のROIへ反映する。
    ///
    /// 1ストロークを1回の「元に戻す」単位にする（塗るたびに全部消えるのを避ける）。
    /// `isNewLayer` が true の場合（`addLayerForMaskPaint` で新規レイヤを作った直後の最初の
    /// ストローク）は、ここでは追加でスナップショットを積まない。既に `addLayerForMaskPaint`
    /// 側でレイヤ追加前の状態を積んであるため、二重に積むと「レイヤ追加」と「最初のストローク」が
    /// 別々のUndo単位になり、1回のUndoではストロークだけが消えて空のレイヤが残ってしまう
    /// （コードレビューで検出）。
    private func applyMaskStroke(roiID: UUID, stroke: ManualMaskStroke, isNewLayer: Bool) {
        guard let index = canvas.rois.firstIndex(where: { $0.id == roiID }) else { return }
        if !isNewLayer {
            pushUndoSnapshot(currentEditorState())
        }
        canvas.rois[index].manualMaskStrokes.append(stroke)
        hasUnsavedChanges = true
        resumeMosaicPreviewIfNeeded()
        updateStatus(stroke.isAdditive
            ? "マスクを塗りました（Option(⌥)キーを押しながらで消せます）"
            : "マスクを消しました")
    }

    /// 選択中のレイヤをグループ化する。選択行は「未グループのレイヤ」だけでなく、
    /// 既存グループの内側にある子レイヤ（人物検出/骨格検出など）も対象にでき、
    /// 元の場所（未グループ配列・元グループ）から取り除いた上で新しいグループへまとめる
    /// （元グループが空になった場合はそのグループごと削除する）。
    /// レイヤ一覧（アウトライン）の右クリックメニューを構築する。項目の表示/非表示・タイトルは
    /// 右クリック直前に `updateLayerContextMenu(_:)` で選択内容に応じて更新する。
    private func attachLayerContextMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "グループ化", action: #selector(groupSelectedLayers), keyEquivalent: "")
        menu.addItem(withTitle: "グループ解除", action: #selector(ungroupSelectedGroup), keyEquivalent: "")
        menu.addItem(withTitle: "モザイク対象に追加", action: #selector(addPersonLayerAsROI), keyEquivalent: "")
        layerOutlineView.menu = menu
    }

    /// 右クリックされた行を選択に含めた上で、グループ化/グループ解除項目の表示・タイトルを更新する。
    /// 複数レイヤ選択後の右クリックで「グループ化」（既にグループ化済みの項目が混ざる場合は
    /// 「再グループ化」）・グループ行選択時は「グループ解除」を表示する。
    private func updateLayerContextMenu(_ menu: NSMenu) {
        let clickedRow = layerOutlineView.clickedRow
        if clickedRow >= 0, !layerOutlineView.selectedRowIndexes.contains(clickedRow) {
            layerOutlineView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        let items = layerOutlineView.selectedRowIndexes.map { layerOutlineView.item(atRow: $0) }
        let leaves = items.compactMap { $0 as? LayerLeaf }
        let roiEntries = items.compactMap { $0 as? ROIListEntry }
        let canGroup = leaves.count >= 2 || roiEntries.count >= 2
        let alreadyGrouped = leaves.contains { leaf in layerGroups.contains { $0.children.contains { $0 === leaf } } }
            || roiEntries.contains { entry in roiListGroups.contains { $0.children.contains { $0 === entry } } }
        // グループ名自体の選択に加え、グループ内の個別レイヤ/ROIを選択した場合も
        // 「グループ解除」（その項目だけをグループから除外）を出せるようにする。
        let hasGroupSelected = items.contains { $0 is LayerGroup || $0 is ROIListGroup } || alreadyGrouped
        let hasPersonSelected = leaves.contains { $0.kind.isPerson }
        guard menu.items.count >= 3 else { return }
        menu.items[0].title = (canGroup && alreadyGrouped) ? "再グループ化" : "グループ化"
        menu.items[0].isHidden = !canGroup
        menu.items[1].isHidden = !hasGroupSelected
        // 人物レイヤ選択時のみ「モザイク対象に追加」を表示（人物にもモザイク処理を可能にする導線）
        menu.items[2].isHidden = !hasPersonSelected
    }

    /// 選択中の人物レイヤの認識範囲からモザイクROIを作成する（人物にもモザイク処理を可能にする）。
    /// マスク生成を「人物の輪郭」にすれば人物のシルエットに沿ったマスクになる。
    @objc private func addPersonLayerAsROI() {
        let items = layerOutlineView.selectedRowIndexes.map { layerOutlineView.item(atRow: $0) }
        let personIndices = items.compactMap { item -> Int? in
            guard let leaf = item as? LayerLeaf, case .person(let index) = leaf.kind else { return nil }
            return index
        }
        let validIndices = personIndices.filter { $0 < canvas.personLayerRects.count }
        guard !validIndices.isEmpty else {
            updateStatus("モザイク対象に追加する人物レイヤを選択してください")
            return
        }
        pushUndoSnapshot(currentEditorState())
        suspendMosaicPreview()
        for index in validIndices {
            // sourceへ人物インデックスを埋め込み、モザイク適用時に該当シルエットで
            // マスクできるようにする（PersonLayerSegmentEngine参照）
            canvas.rois.append(MosaicROI(
                rect: canvas.personLayerRects[index],
                confidence: 1,
                source: "person-layer-\(index)",
                shape: .rectangle,
                category: .other
            ))
        }
        resumeMosaicPreviewIfNeeded()
        reloadLayerList()
        updateStatus("人物レイヤをモザイク対象に追加しました（マスク生成を「人物の輪郭」にすると輪郭に沿ってマスクされます）")
    }

    /// 既存グループ名を避けた「グループN」のうち、使われていない最小のNを採番する
    /// （解除→再グループ化を繰り返しても過去の番号から増え続けないようにする）。
    private func nextAvailableGroupName(excluding existingNames: Set<String>) -> String {
        var n = 1
        while existingNames.contains("グループ\(n)") { n += 1 }
        return "グループ\(n)"
    }

    @objc private func groupSelectedLayers() {
        var leavesToGroup: [LayerLeaf] = []
        var roiEntriesToGroup: [ROIListEntry] = []
        for index in layerOutlineView.selectedRowIndexes {
            let item = layerOutlineView.item(atRow: index)
            if let leaf = item as? LayerLeaf {
                leavesToGroup.append(leaf)
            } else if let entry = item as? ROIListEntry {
                roiEntriesToGroup.append(entry)
            }
        }
        // ROI選択リストの行（目元・乳首等）が選択されている場合はROIのグループ化として扱う。
        // 人物検出/骨格検出などのレイヤ（LayerLeaf）とは別のデータ型のため、
        // 従来はROI行を選択してもグループ化ボタンが常に無反応になる欠落があった。
        if !roiEntriesToGroup.isEmpty {
            guard roiEntriesToGroup.count >= 2 else {
                updateStatus("グループ化するROIを2つ以上選択してください")
                return
            }
            let existingROIGroupNames = Set(canvas.rois.compactMap(\.roiGroupName))
            let groupName = nextAvailableGroupName(excluding: existingROIGroupNames)
            let ids = Set(roiEntriesToGroup.map(\.roiID))
            for index in canvas.rois.indices where ids.contains(canvas.rois[index].id) {
                canvas.rois[index].roiGroupName = groupName
            }
            editorRevision += 1
            reloadLayerList()
            updateStatus("\(groupName) を作成しました（\(roiEntriesToGroup.count)件）")
            return
        }
        guard leavesToGroup.count >= 2 else {
            updateStatus("グループ化するレイヤを2つ以上選択してください")
            return
        }
        ungroupedLayers.removeAll { leaf in leavesToGroup.contains { $0 === leaf } }
        for group in layerGroups {
            group.children.removeAll { leaf in leavesToGroup.contains { $0 === leaf } }
        }
        layerGroups.removeAll { $0.children.isEmpty }
        let existingLayerGroupNames = Set(layerGroups.map(\.name))
        let group = LayerGroup(name: nextAvailableGroupName(excluding: existingLayerGroupNames), children: leavesToGroup)
        layerGroups.append(group)
        editorRevision += 1
        reloadLayerList()
        updateStatus("\(group.name) を作成しました（\(leavesToGroup.count)件）")
    }

    @objc private func ungroupSelectedGroup() {
        var didUngroup = false
        var didUngroupROI = false
        var leavesToRemove: [LayerLeaf] = []
        var entriesToRemove: [ROIListEntry] = []
        for index in layerOutlineView.selectedRowIndexes {
            let item = layerOutlineView.item(atRow: index)
            if let group = item as? LayerGroup {
                ungroupedLayers.append(contentsOf: group.children)
                layerGroups.removeAll { $0 === group }
                didUngroup = true
            } else if let roiGroup = item as? ROIListGroup {
                let ids = Set(roiGroup.children.map(\.roiID))
                for roiIndex in canvas.rois.indices where ids.contains(canvas.rois[roiIndex].id) {
                    canvas.rois[roiIndex].roiGroupName = nil
                }
                didUngroupROI = true
            } else if let leaf = item as? LayerLeaf {
                leavesToRemove.append(leaf)
            } else if let entry = item as? ROIListEntry {
                entriesToRemove.append(entry)
            }
        }
        // グループ名自体ではなく、グループ内の個別レイヤ/ROIを選択して「グループ解除」を
        // 押した場合は、そのレイヤ/ROIだけをグループから除外する（グループ名を選択した
        // 場合の従来動作＝グループ全体の解除はそのまま維持）。
        if !leavesToRemove.isEmpty {
            let actuallyGrouped = leavesToRemove.filter { leaf in
                layerGroups.contains { $0.children.contains { $0 === leaf } }
            }
            if !actuallyGrouped.isEmpty {
                for group in layerGroups {
                    group.children.removeAll { leaf in actuallyGrouped.contains { $0 === leaf } }
                }
                layerGroups.removeAll { $0.children.isEmpty }
                ungroupedLayers.append(contentsOf: actuallyGrouped)
                didUngroup = true
            }
        }
        if !entriesToRemove.isEmpty {
            let ids = Set(entriesToRemove.map(\.roiID))
            for roiIndex in canvas.rois.indices where ids.contains(canvas.rois[roiIndex].id) {
                if canvas.rois[roiIndex].roiGroupName != nil {
                    canvas.rois[roiIndex].roiGroupName = nil
                    didUngroupROI = true
                }
            }
        }
        if didUngroupROI {
            editorRevision += 1
            reloadLayerList()
            updateStatus("ROIグループを解除しました")
        } else if didUngroup {
            editorRevision += 1
            reloadLayerList()
            updateStatus("グループを解除しました")
        } else {
            updateStatus("解除するグループを選択してください")
        }
    }

    @objc private func deleteSelectedLayers() {
        let selectedItems = layerOutlineView.selectedRowIndexes.map { layerOutlineView.item(atRow: $0) }
        var roiIDs = Set<UUID>()
        var layerKinds: [LayerKind] = []

        for item in selectedItems {
            if let entry = item as? ROIListEntry {
                roiIDs.insert(entry.roiID)
            } else if let roiGroup = item as? ROIListGroup {
                roiIDs.formUnion(roiGroup.children.map(\.roiID))
            } else if let leaf = item as? LayerLeaf, leaf.kind.isPerson || leaf.kind.isPose {
                if !layerKinds.contains(leaf.kind) { layerKinds.append(leaf.kind) }
            } else if let group = item as? LayerGroup {
                for leaf in group.children where leaf.kind.isPerson || leaf.kind.isPose {
                    if !layerKinds.contains(leaf.kind) { layerKinds.append(leaf.kind) }
                }
            }
        }

        guard !roiIDs.isEmpty || !layerKinds.isEmpty else {
            updateStatus("削除するROIまたは人物/骨格レイヤを選択してください")
            return
        }

        pushUndoSnapshot(currentEditorState())
        if !roiIDs.isEmpty {
            canvas.rois.removeAll { roiIDs.contains($0.id) }
            canvas.hiddenROIIDs.subtract(roiIDs)
            canvas.selectedROIGroupIDs.subtract(roiIDs)
            if let selected = canvas.selectedROIID, roiIDs.contains(selected) {
                canvas.selectedROIID = nil
            }
            hasUnsavedChanges = true
        }
        if !layerKinds.isEmpty {
            ungroupedLayers.removeAll { layerKinds.contains($0.kind) }
            for group in layerGroups {
                group.children.removeAll { layerKinds.contains($0.kind) }
            }
            layerGroups.removeAll { $0.children.isEmpty }
            if let selected = canvas.selectedDetectionLayer, layerKinds.contains(selected) {
                canvas.selectedDetectionLayer = nil
            }
        }

        editorRevision += 1
        resumeMosaicPreviewIfNeeded()
        applyLayerVisibility()
        syncLegacyLayerCheckboxes()
        reloadLayerList()
        updateStatsBar()
        updateStatus("選択レイヤを削除しました（ROI \(roiIDs.count)件、検出レイヤ \(layerKinds.count)件）")
    }

    private func toggleLeafVisibility(_ leaf: LayerLeaf) {
        editorRevision += 1
        leaf.isVisible.toggle()
        applyLayerVisibility()
        syncLegacyLayerCheckboxes()
        reloadLayerList()
    }

    private func toggleGroupVisibility(_ group: LayerGroup) {
        editorRevision += 1
        let makeVisible = group.visibilityState != .on
        for child in group.children { child.isVisible = makeVisible }
        applyLayerVisibility()
        syncLegacyLayerCheckboxes()
        reloadLayerList()
    }

    /// カテゴリグループの表示状態（全表示=on、全非表示=off、混在=mixed）。
    private func roiGroupVisibilityState(_ group: ROIListGroup) -> NSControl.StateValue {
        let hiddenCount = group.children.filter { canvas.hiddenROIIDs.contains($0.roiID) }.count
        if hiddenCount == 0 { return .on }
        if hiddenCount == group.children.count { return .off }
        return .mixed
    }

    /// モザイク対象1件の表示ON/OFF。**画面表示だけの設定で、画像出力には影響しない。**
    private func toggleROIVisibility(_ roiID: UUID) {
        if canvas.hiddenROIIDs.contains(roiID) {
            canvas.hiddenROIIDs.remove(roiID)
        } else {
            canvas.hiddenROIIDs.insert(roiID)
        }
        refreshAfterROIVisibilityChange()
    }

    /// カテゴリグループ単位の表示ON/OFF。1つでも表示中なら全て非表示にする。
    private func toggleROIGroupVisibility(_ group: ROIListGroup) {
        let makeHidden = roiGroupVisibilityState(group) != .off
        for child in group.children {
            if makeHidden {
                canvas.hiddenROIIDs.insert(child.roiID)
            } else {
                canvas.hiddenROIIDs.remove(child.roiID)
            }
        }
        refreshAfterROIVisibilityChange()
    }

    private func refreshAfterROIVisibilityChange() {
        editorRevision += 1
        resumeMosaicPreviewIfNeeded()
        reloadLayerList()
        let hidden = canvas.hiddenROIIDs.count
        updateStatus(hidden == 0
            ? "すべてのモザイク対象を表示しています"
            : "\(hidden)件のモザイク対象を非表示にしています（画面表示のみ。画像出力には反映されます）")
    }

    private func allLayerLeaves() -> [LayerLeaf] {
        ungroupedLayers + layerGroups.flatMap(\.children)
    }

    /// 画像上のクリックで選択された人物/骨格レイヤを、レイヤ一覧の選択にも反映する。
    private func selectDetectionLayerInList(_ kind: LayerKind) {
        guard let leaf = allLayerLeaves().first(where: { $0.kind == kind }) else { return }
        let row = layerOutlineView.row(forItem: leaf)
        guard row >= 0 else { return }
        layerOutlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        layerOutlineView.scrollRowToVisible(row)
    }

    /// 人物/骨格レイヤの移動完了時、マスク画像・骨格ボーンを同じ移動量だけ追従させる。
    private func applyDetectionLayerMove(_ kind: LayerKind, dx: Double, dy: Double) {
        switch kind {
        case .person(let index):
            if index < canvas.personLayerMasks.count, let mask = canvas.personLayerMasks[index] {
                canvas.personLayerMasks[index] = Self.translatedMask(mask, dx: dx, dy: dy)
            }
            // モザイク用の未着色シルエットも同じ量だけ追従させる（人物レイヤ由来ROIの
            // マスクが移動後の位置とずれないようにする）
            if index < personMaskImages.count, let untinted = personMaskImages[index] {
                personMaskImages[index] = Self.translatedMask(untinted, dx: dx, dy: dy)
            }
            updateStatus("人物\(index + 1) レイヤを移動しました")
        case .pose(let index):
            if index < canvas.poseLayerBones.count {
                canvas.poseLayerBones[index] = canvas.poseLayerBones[index].map { bone in
                    (from: CGPoint(x: bone.from.x + dx, y: bone.from.y + dy),
                     to: CGPoint(x: bone.to.x + dx, y: bone.to.y + dy))
                }
            }
            if index < canvas.poseLayerJointPoints.count {
                canvas.poseLayerJointPoints[index] = canvas.poseLayerJointPoints[index].map {
                    CGPoint(x: $0.x + dx, y: $0.y + dy)
                }
            }
            updateStatus("骨格\(index + 1) レイヤを移動しました")
        default:
            break
        }
    }

    /// 全面マスク画像を正規化座標の移動量だけ平行移動した画像を返す（はみ出しは切り捨て）。
    private static func translatedMask(_ mask: CGImage, dx: Double, dy: Double) -> CGImage? {
        let width = mask.width
        let height = mask.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return mask }
        // 正規化dyは下方向が正（上原点）、CGContextは下原点のためyを反転して描画する
        context.draw(mask, in: CGRect(
            x: dx * Double(width),
            y: -dy * Double(height),
            width: Double(width),
            height: Double(height)
        ))
        return context.makeImage()
    }

    /// 画像上のダブルクリックによる人物/骨格レイヤの削除。レイヤ一覧から該当レイヤを取り除き、
    /// 画像上の表示も消す（配列インデックスを保つため、表示配列は該当だけfalseにする）。
    private func deleteDetectionLayer(_ kind: LayerKind) {
        ungroupedLayers.removeAll { $0.kind == kind }
        for group in layerGroups {
            group.children.removeAll { $0.kind == kind }
        }
        layerGroups.removeAll { $0.children.isEmpty }
        if canvas.selectedDetectionLayer == kind {
            canvas.selectedDetectionLayer = nil
        }
        editorRevision += 1
        applyLayerVisibility()
        syncLegacyLayerCheckboxes()
        reloadLayerList()
        updateStatus("\(kind.title) レイヤを削除しました")
    }

    /// 輪郭表示のON/OFFを全レイヤへ一括適用する（旧: レイヤ行毎の個別設定から変更）。
    @objc private func toggleAllLayerOutlines() {
        let on = layerOutlineAllCheckbox.state == .on
        for leaf in allLayerLeaves() { leaf.showsOutline = on }
        editorRevision += 1
        applyLayerVisibility()
        reloadLayerList()
    }

    /// タグ表示のON/OFFを全レイヤへ一括適用する（旧: レイヤ行毎の個別設定から変更）。
    @objc private func toggleAllLayerTags() {
        let on = layerTagAllCheckbox.state == .on
        for leaf in allLayerLeaves() { leaf.showsTag = on }
        editorRevision += 1
        applyLayerVisibility()
        reloadLayerList()
    }

    /// レイヤパネル内のすべてのレイヤ（グループ内含む）を表示状態にする。
    private func showAllLayers() {
        for leaf in allLayerLeaves() {
            leaf.isVisible = true
        }
        applyLayerVisibility()
        syncLegacyLayerCheckboxes()
        reloadLayerList()
    }

    private func applyLayerVisibility() {
        var personVisibility = [Bool](repeating: false, count: canvas.personLayerRects.count)
        var poseVisibility = [Bool](repeating: false, count: canvas.poseLayerRects.count)
        var personOutline = [Bool](repeating: true, count: canvas.personLayerRects.count)
        var personTag = [Bool](repeating: true, count: canvas.personLayerRects.count)
        var poseOutline = [Bool](repeating: true, count: canvas.poseLayerRects.count)
        var poseTag = [Bool](repeating: true, count: canvas.poseLayerRects.count)
        for leaf in allLayerLeaves() {
            switch leaf.kind {
            case .image: canvas.showImageLayer = leaf.isVisible
            case .roi:
                canvas.showROILayer = leaf.isVisible
                canvas.showROIOutlines = leaf.showsOutline
                canvas.showROITags = leaf.showsTag
            case .person(let index):
                if index < personVisibility.count {
                    personVisibility[index] = leaf.isVisible
                    personOutline[index] = leaf.showsOutline
                    personTag[index] = leaf.showsTag
                }
            case .pose(let index):
                if index < poseVisibility.count {
                    poseVisibility[index] = leaf.isVisible
                    poseOutline[index] = leaf.showsOutline
                    poseTag[index] = leaf.showsTag
                }
            }
        }
        canvas.personLayerVisibility = personVisibility
        canvas.poseLayerVisibility = poseVisibility
        canvas.personLayerOutlineVisibility = personOutline
        canvas.personLayerTagVisibility = personTag
        canvas.poseLayerOutlineVisibility = poseOutline
        canvas.poseLayerTagVisibility = poseTag
    }

    /// レイヤパネル先頭の表示トグルを、各レイヤの実際の表示状態と同期する。
    private func syncLegacyLayerCheckboxes() {
        personLayerCheckbox.allowsMixedState = true
        poseLayerCheckbox.allowsMixedState = true
        personLayerCheckbox.state = aggregateVisibilityState(allLayerLeaves().filter(\.kind.isPerson))
        poseLayerCheckbox.state = aggregateVisibilityState(allLayerLeaves().filter(\.kind.isPose))
        roiLayerCheckbox.state = allLayerLeaves().first { $0.kind == .roi }?.isVisible == true ? .on : .off
    }

    private func aggregateVisibilityState(_ leaves: [LayerLeaf]) -> NSControl.StateValue {
        guard !leaves.isEmpty else { return .off }
        let visibleCount = leaves.filter(\.isVisible).count
        if visibleCount == 0 { return .off }
        if visibleCount == leaves.count { return .on }
        return .mixed
    }

    // MARK: - フォルダ一括登録（リンク）とリンク切れ修正

    /// フォルダ内の画像/動画をライブラリへ**リンク**として一括登録する（コピーしない。
    /// ROI・レイヤ情報は従来どおりアプリ側で管理する）。
    @objc private func registerFolderAsLinks() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "一括登録"
        panel.message = "画像/動画フォルダを選択してください（ファイルはコピーせずリンクとして登録されます）"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let manager = FileManager.default
        let files = ((try? manager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentTypeKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { Self.isImageFile($0) || Self.isVideoFile($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !files.isEmpty else {
            updateStatus("選択フォルダに登録できる画像/動画がありません")
            return
        }
        updateStatus("フォルダ一括登録中: \(files.count)件")
        let libraryRoot = libraryEngine.rootURL
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = LibraryEngine(rootURL: libraryRoot)
            var imageCount = 0
            var videoCount = 0
            var failed = 0
            for file in files {
                do {
                    if Self.isVideoFile(file) {
                        let info = try VideoFrameReader(url: file).loadInfo()
                        _ = try engine.importLinkedVideo(
                            url: file,
                            pixelWidth: Int(info.naturalSize.width),
                            pixelHeight: Int(info.naturalSize.height),
                            durationSeconds: info.durationSeconds
                        )
                        videoCount += 1
                    } else {
                        _ = try engine.importLinked(url: file)
                        imageCount += 1
                    }
                } catch {
                    failed += 1
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reloadLibrary(preserveOrder: false)
                let failNote = failed > 0 ? "（読み込み不可 \(failed)件）" : ""
                self.updateStatus("フォルダ一括登録: 静止画\(imageCount)件 / 動画\(videoCount)件をリンク登録しました\(failNote)")
            }
        }
    }

    /// リンク切れの修正。ライブラリでリンク切れアイテムを選択中ならそのアイテムをファイル指定で修正（画像単位）、
    /// 未選択ならフォルダ指定でファイル名一致の一括修正を行う。
    @objc private func repairBrokenLinksAction() {
        // 画像単位: 選択中のリンク切れアイテム
        if let selectedID = selectedLibraryItemID,
           let item = libraryItems.first(where: { $0.id == selectedID }),
           libraryEngine.isLinkBroken(item) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
            panel.prompt = "この画像へ再リンク"
            panel.message = "「\(item.sourceName)」の新しい参照先を選択してください"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                _ = try libraryEngine.relink(id: item.id, to: url)
                thumbnailCache.removeValue(forKey: item.id)
                reloadLibrary()
                updateStatus("リンクを修正しました: \(url.lastPathComponent)")
            } catch {
                showError(error)
            }
            return
        }

        // 一括: フォルダ指定でファイル名一致の再リンク
        let brokenCount = (try? libraryEngine.brokenLinkedItems().count) ?? 0
        guard brokenCount > 0 else {
            updateStatus("リンク切れのアイテムはありません（画像単位で修正する場合はリンク切れアイテムを選択してから実行）")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "一括修正"
        panel.message = "リンク切れ\(brokenCount)件の参照先を探すフォルダを選択してください（ファイル名一致で一括修正）"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let repaired = try libraryEngine.repairBrokenLinks(searchFolder: folder)
            thumbnailCache.removeAll()
            thumbnailCacheUpdatedAt.removeAll()
            thumbnailCacheOrder.removeAll()
            reloadLibrary()
            updateStatus("リンク切れ一括修正: \(repaired)/\(brokenCount)件を修正しました")
        } catch {
            showError(error)
        }
    }

    // MARK: - 一括処理

    /// 一括処理の実行パラメータ（非Sendableな型をまとめてバックグラウンドタスクへ渡すための箱）。
    private struct BatchConfig: @unchecked Sendable {
        let library: LibraryEngine
        let style: MosaicStyle
        let domainMode: Int
        let groinRatio: Double
        let checkedCategories: Set<MosaicTargetCategory>
        let shape: ROIShape
        let engineKindIndex: Int
    }

    /// 未加工（加工後画像なし）かつリンク有効な全画像を、候補生成→モザイク適用→保存で一括処理する。
    /// 処理中は進捗パネル（件数・進捗バー・キャンセル）をリアルタイム更新する。
    @objc private func batchProcessAll() {
        guard !isBatchProcessing else { return }
        let targets = libraryItems.filter { !$0.isVideo && $0.processedRelativePath == nil && !libraryEngine.isLinkBroken($0) }
        guard !targets.isEmpty else {
            updateStatus("一括処理の対象がありません（未加工かつリンク有効な画像が対象です）")
            return
        }
        let alert = NSAlert()
        alert.messageText = "一括処理"
        alert.informativeText = "未加工の\(targets.count)件を一括処理します（候補生成 → モザイク適用 → ライブラリ保存）。よろしいですか？"
        alert.addButton(withTitle: "開始")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 実行パラメータはメインスレッドで確定してから開始する
        let config = BatchConfig(
            library: libraryEngine,
            style: defaultMosaicStyleForRendering(),
            domainMode: domainModeControl.indexOfSelectedItem,
            groinRatio: groinPositionSlider.doubleValue,
            checkedCategories: checkedGenerationCategories(),
            shape: canvas.currentShape,
            engineKindIndex: segmentEngineControl.indexOfSelectedItem
        )
        isBatchProcessing = true
        batchCancelRequested = false
        presentBatchPanel(total: targets.count)

        Task.detached(priority: .userInitiated) { [weak self] in
            let worker = CandidateGenerationWorker()
            let loader = ImageLoader()
            let engine = MosaicEngine()
            func makeSegmentEngine() -> Segmenting {
                let kinds = MosaicWindowController.selectableEngineKinds
                guard config.engineKindIndex >= 0, config.engineKindIndex < kinds.count else {
                    return ShapeSegmentEngine()
                }
                switch kinds[config.engineKindIndex] {
                case .shape: return ShapeSegmentEngine()
                case .visionPersonSegmentation: return VisionPersonSegmentEngine()
                case .foregroundObjects: return ForegroundSegmentEngine()
                case .regionForeground: return RegionForegroundSegmentEngine()
                case .learnedShape: return LearnedShapeSegmentEngine()
                case .samShape: return SAMSegmentEngine()
                }
            }

            var processed = 0
            var failed = 0
            var cancelled = false
            for (index, item) in targets.enumerated() {
                let shouldStop = await MainActor.run { [weak self] in self?.batchCancelRequested ?? true }
                if shouldStop {
                    cancelled = true
                    break
                }
                await MainActor.run { [weak self] in
                    self?.updateBatchProgress(current: index + 1, total: targets.count, name: item.sourceName)
                }
                do {
                    let loaded = try loader.loadImage(from: config.library.originalURL(for: item))
                    let output = try worker.run(CandidateGenerationInput(
                        image: loaded.cgImage,
                        domainMode: config.domainMode,
                        groinPositionRatio: config.groinRatio
                    ))
                    var rois = output.rois.filter { config.checkedCategories.contains($0.category) }
                    rois = rois.map { roi in
                        var updated = roi
                        updated.shape = config.shape
                        if config.shape == .polygon && updated.polygonPoints == nil {
                            updated.polygonPoints = MosaicROI.defaultPolygonPoints
                        }
                        return updated
                    }
                    let result = try engine.applyMosaic(
                        to: loaded.cgImage,
                        rois: rois,
                        style: config.style,
                        segmentEngine: makeSegmentEngine(),
                        patternImageProvider: { identifier in
                            if let builtin = OverlayAssetCatalog.image(for: identifier) { return builtin }
                            let url = config.library.patternURL(identifier: identifier)
                            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                            return CGImageSourceCreateImageAtIndex(source, 0, nil)
                        }
                    )
                    _ = try config.library.saveProcessedImage(result, rois: rois, for: item.id)
                    processed += 1
                } catch {
                    failed += 1
                }
            }
            let processedCount = processed
            let failedCount = failed
            let wasCancelled = cancelled
            await MainActor.run { [weak self] in
                self?.finishBatchProcessing(processed: processedCount, failed: failedCount, cancelled: wasCancelled)
            }
        }
    }

    private func presentBatchPanel(total: Int) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 110),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "一括処理"
        batchProgressLabel.stringValue = "0/\(total) 準備中..."
        batchProgressLabel.lineBreakMode = .byTruncatingMiddle
        batchProgressBar.style = .bar
        batchProgressBar.isIndeterminate = false
        batchProgressBar.minValue = 0
        batchProgressBar.maxValue = Double(total)
        batchProgressBar.doubleValue = 0
        let cancelButton = NSButton(title: "キャンセル", target: self, action: #selector(cancelBatchProcessing))
        let stack = NSStackView(views: [batchProgressLabel, batchProgressBar, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            batchProgressBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            batchProgressLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        panel.contentView = content
        batchPanel = panel
        if let window = view.window {
            window.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func cancelBatchProcessing() {
        batchCancelRequested = true
        batchProgressLabel.stringValue = "キャンセルしています..."
    }

    private func updateBatchProgress(current: Int, total: Int, name: String) {
        batchProgressLabel.stringValue = "\(current)/\(total) 処理中: \(name)"
        batchProgressBar.doubleValue = Double(current - 1)
        updateStatus("一括処理 \(current)/\(total): \(name)")
    }

    private func finishBatchProcessing(processed: Int, failed: Int, cancelled: Bool) {
        if let panel = batchPanel {
            view.window?.endSheet(panel)
            panel.orderOut(nil)
        }
        batchPanel = nil
        isBatchProcessing = false
        reloadLibrary()
        let failNote = failed > 0 ? "・失敗\(failed)件" : ""
        if cancelled {
            updateStatus("一括処理をキャンセルしました（処理済み\(processed)件\(failNote)）")
        } else {
            updateStatus("一括処理が完了しました（\(processed)件\(failNote)）")
        }
        AppLog.library.info("一括処理終了: 処理済み=\(processed) 失敗=\(failed) キャンセル=\(cancelled)")
    }

    /// 開く/貼り付けで受け付ける静止画の型
    private static let openableImageTypes: [UTType] = [.png, .jpeg, .tiff, .heic]
    /// 開く/貼り付けで受け付ける動画の型。抽象型（movie/video）と主要拡張子由来型を併用し、
    /// FinderのOpen PanelでMOV等がグレーアウトする環境差を避ける。
    private static let openableVideoTypes: [UTType] =
        [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        + ["mov", "mp4", "m4v", "qt"].compactMap { UTType(filenameExtension: $0) }
    private static let openableMediaTypes: [UTType] = openableImageTypes + openableVideoTypes

    /// URLの実体が動画かをUTTypeで判定する。拡張子だけの判定にしないのは、
    /// 拡張子が無い/違うファイルでも実体で正しく振り分けるため。
    nonisolated private static func isVideoFile(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .movie)
                || type.conforms(to: .video)
                || type.conforms(to: .audiovisualContent)
        }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie)
            || type.conforms(to: .video)
            || type.conforms(to: .audiovisualContent)
    }

    nonisolated private static func isImageFile(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// 動画をライブラリへリンク登録して開く（本体はコピーしない）。
    /// 解像度・尺の取得はデコードを伴うためバックグラウンドで行い、完了後にUIを更新する。
    @objc private func openVideo() {
        let panel = NSOpenPanel()
        // 静止画も選べるようにして「画像を開く」と入口を対称にする（GUI報告 2026-08-10:
        // 動画認識をしたいのに『画像を開く』でMOVが選べない、という迷いを無くす）。
        // 選択後は実体のUTTypeで静止画/動画へ自動的に振り分ける。
        panel.allowedContentTypes = Self.openableMediaTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Self.isVideoFile(url) else {
            openImageFile(at: url)
            return
        }
        importVideoFile(at: url)
    }

    /// 動画ファイルをライブラリへリンク登録し、キーフレーム編集モードで開く。
    /// 「動画を開く」「画像を開く（動画を選んだ場合）」「動画ファイルの貼り付け」で共用する。
    private func importVideoFile(at url: URL) {
        guard confirmCurrentChangesBeforeLeaving() else { return }

        updateStatus("動画を読み込み中: \(url.lastPathComponent)")
        // 動画情報の取得はデコードを伴うためバックグラウンドで行い、UI更新はメインへ戻す
        let engine = libraryEngine
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let info = try VideoFrameReader(url: url).loadInfo()
                let item = try engine.importLinkedVideo(
                    url: url,
                    pixelWidth: Int(info.naturalSize.width),
                    pixelHeight: Int(info.naturalSize.height),
                    durationSeconds: info.durationSeconds
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.reloadLibrary()
                    self.selectLibraryItemInUI(item)
                    self.enterVideoEditingMode(
                        item: item,
                        info: info,
                        reason: "動画を登録して編集モードで開きました。\(Self.videoAnalysisStepHint)"
                    )
                    self.updateStatus(
                        "動画を登録: \(item.sourceName) "
                        + "\(Int(info.naturalSize.width))x\(Int(info.naturalSize.height)) "
                        + "\(String(format: "%.1f", info.durationSeconds))秒。"
                        + Self.videoAnalysisStepHint
                    )
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.showError(error) }
            }
        }
    }



    // MARK: - 動画書き出し（V4）

    // MARK: - 動画の自動追随（v0.0.00136〜）

    static let videoAutoRedetectDefaultsKey = "videoAutoRedetectEnabled"
    static let videoRedetectIntervalDefaultsKey = "videoRedetectIntervalFrames"
    static let videoSceneCutDefaultsKey = "videoSceneCutRedetectEnabled"
    static let videoLostExpansionDefaultsKey = "videoLostExpansionEnabled"
    private static let videoAnalysisStepHint =
        "自動候補生成→必要ならROI修正→キーフレーム追加→時刻移動→追跡を確認→動画を書き出す"
    /// 再検出間隔の選択肢（フレーム）。30fps動画では 10≒0.3秒 / 30≒1秒 / 90≒3秒。
    static let videoRedetectIntervalChoices = [10, 15, 30, 60, 90]

    /// 既定値ONの設定を読む。未設定（初回起動・旧バージョンからの移行）は`true`にする。
    /// `AppSettings.bool(forKey:)`は未設定で`false`を返すため、そのままでは
    /// 「既定ONのつもりの機能が既定OFFで動く」ことになる。
    static func videoSettingIsEnabled(_ key: String) -> Bool {
        let settings = AppSettings.shared
        guard settings.object(forKey: key) != nil else { return true }
        return settings.bool(forKey: key)
    }

    /// 現在の設定から動画追随のオプションを組み立てる。
    /// 既定は全てON（検閲漏れよりも過剰なモザイクを選ぶ方針）。
    private func currentVideoTrackingOptions() -> VideoTrackingCoordinator.Options {
        let interval = AppSettings.shared.integer(forKey: Self.videoRedetectIntervalDefaultsKey)
        return VideoTrackingCoordinator.Options(
            autoRedetectEnabled: Self.videoSettingIsEnabled(Self.videoAutoRedetectDefaultsKey),
            redetectIntervalFrames: interval > 0 ? interval : 30,
            sceneCutRedetectEnabled: Self.videoSettingIsEnabled(Self.videoSceneCutDefaultsKey),
            lostExpansionEnabled: Self.videoSettingIsEnabled(Self.videoLostExpansionDefaultsKey)
        )
    }

    private typealias VideoFrameDetector = @Sendable (CGImage) throws -> [MosaicROI]

    private struct VideoFrameDetectionConfiguration: Sendable {
        let domainMode: Int
        let groinPositionRatio: Double
        let categories: Set<MosaicTargetCategory>
        let shape: ROIShape
        let maskEngineRawValue: String
        let maskThreshold: Double
    }

    /// 動画フレーム1枚からROIを検出するクロージャを作る。
    ///
    /// 静止画の「候補生成」と同じ`CandidateGenerationWorker`・同じ候補カテゴリ絞り込み・
    /// 同じ形状適用を通すため、動画の自動再検出は静止画の検出精度をそのまま引き継ぐ。
    /// 学習モードによる候補の補正（`refineCandidates`）はフレーム毎に走らせると
    /// 学習履歴の重み付けが動画1本で偏るため、動画側では適用しない。
    private func makeVideoFrameDetector() -> VideoFrameDetector {
        let worker = candidateGenerationWorker
        let configuration = VideoFrameDetectionConfiguration(
            domainMode: domainModeControl.indexOfSelectedItem,
            groinPositionRatio: groinPositionSlider.doubleValue,
            categories: checkedGenerationCategories(),
            shape: canvas.currentShape,
            maskEngineRawValue: currentSegmentEngineKind().rawValue,
            maskThreshold: maskThresholdSlider.doubleValue
        )
        return Self.makeVideoFrameDetector(worker: worker, configuration: configuration)
    }

    nonisolated private static func makeVideoFrameDetector(
        worker: CandidateGenerationWorker,
        configuration: VideoFrameDetectionConfiguration
    ) -> VideoFrameDetector {
        return { frame in
            let output = try worker.run(
                CandidateGenerationInput(
                    image: frame,
                    domainMode: configuration.domainMode,
                    groinPositionRatio: configuration.groinPositionRatio
                )
            )
            var rois = output.rois.filter { configuration.categories.contains($0.category) }
            rois = rois.map { roi in
                var updated = roi
                updated.shape = configuration.shape
                if configuration.shape == .polygon && updated.polygonPoints == nil {
                    updated.polygonPoints = MosaicROI.defaultPolygonPoints
                }
                if updated.roiGroupName == nil {
                    updated.roiGroupName = updated.category.displayName
                }
                return updated
            }
            return DetectedROIRefiner.expandGenitalROIsToCoverShape(rois).map { roi in
                var updated = roi
                if updated.maskEngine == nil {
                    updated.maskEngine = configuration.maskEngineRawValue
                }
                if updated.maskThreshold == nil {
                    updated.maskThreshold = configuration.maskThreshold
                }
                return updated
            }
        }
    }

    /// 書き出し後に「要確認の時間帯」を組み立てる（見失い区間・自動追加区間）。
    /// 書き出しスレッド（非メイン）から呼ぶため`nonisolated`。時刻整形も
    /// `VideoPreviewView.timeText`（MainActor隔離）ではなくここで完結させる。
    nonisolated private static func trackingReviewSummary(
        for coordinator: VideoTrackingCoordinator
    ) -> String? {
        func timeText(_ seconds: Double) -> String {
            let total = Int(seconds.rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        func format(_ ranges: [ClosedRange<Double>]) -> String {
            ranges.prefix(8)
                .map { "\(timeText($0.lowerBound))〜\(timeText($0.upperBound))" }
                .joined(separator: "、")
                + (ranges.count > 8 ? " ほか\(ranges.count - 8)件" : "")
        }
        var lines: [String] = []
        let lost = coordinator.lostTimeRanges()
        if !lost.isEmpty {
            lines.append("追跡を見失った時間帯（要確認）: \(format(lost))")
        }
        let added = coordinator.addedTimeRanges()
        if !added.isEmpty {
            lines.append("自動再検出で対象を追加した時間帯: \(format(added))")
        }
        if !coordinator.sceneCutFrameIndices.isEmpty {
            lines.append("シーンカット検出: \(coordinator.sceneCutFrameIndices.count)箇所（その都度検出をやり直しました）")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 動画へモザイクを適用して書き出す。キーフレームのROIを起点に、その間のフレームは
    /// 追跡で追随させる（ROI移動追随マスク）。進捗シートで経過表示・キャンセルができる。
    @objc private func exportVideoWithMosaic() {
        guard let item = currentVideoItem, let info = currentVideoInfo else {
            updateStatus("動画をライブラリでダブルクリックして編集モードで開いてから実行してください")
            return
        }
        guard !currentVideoEditState.keyframes.isEmpty else {
            updateStatus("キーフレームがありません。\(Self.videoAnalysisStepHint)")
            return
        }

        let panel = NSSavePanel()
        // MP4に加えMOVでも書き出せるようにする（読み込みはMP4/MOV両対応なのに
        // 書き出しがMP4のみで非対称だった。v0.0.00136）
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.nameFieldStringValue = (item.sourceName as NSString).deletingPathExtension + "_mosaic.mp4"
        panel.message = "モザイクを適用した動画の保存先を選択してください（MP4 / MOV）"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        let inputURL = libraryEngine.originalURL(for: item)
        let style = defaultMosaicStyleForRendering()
        let segmentEngine = currentSegmentEngine()
        let editState = videoEditStateWithResolvedInheritedSettings(currentVideoEditState)
        let frameRate = max(1, info.frameRate)
        let cancellation = VideoMosaicExporter.CancellationFlag()
        let options = currentVideoTrackingOptions()
        // 検出器は自動再検出（またはシーンカット再検出）が有効なときだけ用意する。
        // 生成コスト自体は小さいが、無効時に誤って呼ばれないよう nil を渡す。
        let detector: VideoFrameDetector? =
            (options.autoRedetectEnabled || options.sceneCutRedetectEnabled)
            ? makeVideoFrameDetector()
            : nil

        let sheet = makeVideoExportProgressSheet(cancellation: cancellation)
        view.window?.beginSheet(sheet, completionHandler: nil)
        videoExportSheet = sheet

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // フレーム番号→ROIの解決は`VideoTrackingCoordinator`へ集約する。
            // キーフレーム起点の追跡に加え、定期的な自動再検出・シーンカット検出・
            // 見失い時の安全側膨張までを一箇所で扱う（v0.0.00136）。
            let coordinator = VideoTrackingCoordinator(
                editState: editState,
                frameRate: frameRate,
                options: options
            )

            let exporter = VideoMosaicExporter(
                style: style,
                segmentEngine: segmentEngine,
                patternImageProvider: nil
            )
            do {
                try exporter.export(
                    from: inputURL,
                    to: outputURL,
                    roiProvider: { index, frame in
                        try coordinator.rois(forFrame: index, image: frame, detector: detector).rois
                    },
                    includeAudio: true,
                    cancellation: cancellation,
                    progress: { value in
                        DispatchQueue.main.async { [weak self] in
                            self?.videoExportProgressBar.doubleValue = value * 100
                            self?.videoExportProgressLabel.stringValue = "書き出し中… \(Int(value * 100))%"
                        }
                    }
                )
                let summary = Self.trackingReviewSummary(for: coordinator)
                DispatchQueue.main.async { [weak self] in
                    self?.finishVideoExport(outputURL: outputURL, item: item, error: nil,
                                            trackingSummary: summary)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.finishVideoExport(outputURL: outputURL, item: item, error: error,
                                            trackingSummary: nil)
                }
            }
        }
    }

    /// 書き出し進捗シート（進捗バー＋キャンセル）。
    private func makeVideoExportProgressSheet(cancellation: VideoMosaicExporter.CancellationFlag) -> NSWindow {
        videoExportCancellation = cancellation
        videoExportProgressBar.isIndeterminate = false
        videoExportProgressBar.minValue = 0
        videoExportProgressBar.maxValue = 100
        videoExportProgressBar.doubleValue = 0
        videoExportProgressBar.translatesAutoresizingMaskIntoConstraints = false
        videoExportProgressLabel.stringValue = "書き出しを準備中…"
        applyScaledFont(videoExportProgressLabel, size: 12)

        let cancelButton = NSButton(title: "キャンセル", target: self, action: #selector(cancelVideoExport))
        cancelButton.bezelStyle = .rounded
        applyScaledFont(cancelButton, size: 12)

        let content = NSStackView(views: [videoExportProgressLabel, videoExportProgressBar, cancelButton])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        videoExportProgressBar.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.title = "動画の書き出し"
        // `videoExportSheet` で保持するため、AppKitに解放させない（上記と同じ理由）。
        sheet.isReleasedWhenClosed = false
        sheet.contentView = content
        return sheet
    }

    @objc private func cancelVideoExport() {
        videoExportCancellation?.isCancelled = true
        videoExportProgressLabel.stringValue = "キャンセルしています…"
    }

    /// 書き出し完了/失敗/キャンセルの後始末。成功時はライブラリへ加工後動画として登録する。
    /// - Parameter trackingSummary: 追跡の見失い区間・自動追加区間のまとめ（v0.0.00136）。
    ///   書き出しは成功していても、追跡を見失った区間はモザイクがズレている可能性があるため、
    ///   「どの時間帯を目視確認すべきか」をここで必ず提示する（黙って完了にしない）。
    private func finishVideoExport(
        outputURL: URL,
        item: MosaicLibraryItem,
        error: Error?,
        trackingSummary: String? = nil
    ) {
        if let sheet = videoExportSheet {
            view.window?.endSheet(sheet)
            sheet.orderOut(nil)
        }
        videoExportSheet = nil
        videoExportCancellation = nil

        if let error {
            if case VideoMosaicExporterError.cancelled = error {
                updateStatus("動画の書き出しをキャンセルしました")
                return
            }
            showError(error)
            AppLog.export.error("Video export failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        AppLog.export.info("Video export finished")
        updateStatus("動画を書き出しました: \(outputURL.lastPathComponent)")
        reloadLibrary()

        guard let trackingSummary else { return }
        AppLog.export.info("Video export tracking summary: \(trackingSummary, privacy: .public)")
        let alert = NSAlert()
        alert.messageText = "書き出しは完了しました（要確認の時間帯があります）"
        alert.informativeText = trackingSummary
            + "\n\n見失った区間はモザイクがズレている可能性があります。"
            + "該当時刻にキーフレームを追加して修正すると精度が上がります。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - 動画編集タイムライン（V3）

    /// キャンバス下部の動画タイムラインを構築する。静止画編集中は非表示（高さ0）にする。
    private func makeVideoTimelineBar() -> NSView {
        videoTimelineBar.translatesAutoresizingMaskIntoConstraints = false
        videoTimelineBar.wantsLayer = true
        videoTimelineBar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        videoTimeSlider.target = self
        videoTimeSlider.action = #selector(videoTimeSliderChanged)
        videoTimeSlider.translatesAutoresizingMaskIntoConstraints = false
        videoTimeSlider.toolTip = "再生位置（ドラッグでそのフレームへ移動。三角マーカーはキーフレーム位置）"
        videoTimeSlider.setAccessibilityLabel("再生位置")

        videoTimeLabel.font = Self.scaledMonospacedDigitFont(11, weight: .regular)
        videoTimeLabel.textColor = .secondaryLabelColor
        videoTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        videoTimeLabel.widthAnchor.constraint(equalToConstant: 96).isActive = true
        configureToolbarButton(videoPlayButton, symbol: "play.fill", help: "動画タイムラインを再生", action: #selector(playVideoTimeline))
        configureToolbarButton(videoPauseButton, symbol: "pause.fill", help: "動画タイムラインを一時停止", action: #selector(pauseVideoTimeline))
        configureToolbarButton(videoStopButton, symbol: "stop.fill", help: "動画タイムラインを停止して先頭へ戻す", action: #selector(stopVideoTimeline))

        let row = NSStackView(views: [
            videoPlayButton, videoPauseButton, videoStopButton,
            makeToolbarSeparator(), videoTimeSlider, videoTimeLabel
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false

        videoTimelineBar.addSubview(separator)
        videoTimelineBar.addSubview(row)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: videoTimelineBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: videoTimelineBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: videoTimelineBar.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            row.topAnchor.constraint(equalTo: separator.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: videoTimelineBar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: videoTimelineBar.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: videoTimelineBar.bottomAnchor)
        ])
        videoTimelineBar.isHidden = true
        return videoTimelineBar
    }

    /// 動画をキーフレーム編集モードで開く（V3）。先頭（または最初のキーフレーム）を
    /// キャンバスへ表示し、以後は静止画と同じ操作でROIを編集できる。
    private func openVideoForEditing(_ item: MosaicLibraryItem) {
        guard item.isVideo else { return }
        let url = libraryEngine.originalURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            updateStatus("動画ファイルが見つかりません: \(item.sourceName)（リンク切れ修正をお試しください）")
            return
        }
        guard item.id == currentVideoItem?.id || confirmCurrentChangesBeforeLeaving() else { return }

        updateStatus("動画を開いています: \(item.sourceName)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let info = try VideoFrameReader(url: url).loadInfo()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.enterVideoEditingMode(
                        item: item,
                        info: info,
                        reason: "動画を編集モードで開きました。\(Self.videoAnalysisStepHint)"
                    )
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.showError(error) }
            }
        }
    }

    private func enterVideoEditingMode(item: MosaicLibraryItem, info: VideoInfo, reason: String) {
        currentVideoItem = item
        currentVideoInfo = info
        currentLibraryItem = item
        renderedImage = nil
        currentVideoEditState = videoEditStore.load(for: item.id) ?? VideoEditState()
        mosaicPreviewCheckbox.state = currentVideoEditState.keyframes.contains { !$0.rois.isEmpty } ? .on : .off
        videoTimelineBar.isHidden = false
        videoTimeSlider.minValue = 0
        videoTimeSlider.maxValue = max(0.001, info.durationSeconds)
        selectLibraryItemInUI(item)
        // 既存キーフレームがあればその先頭、無ければ動画先頭を開く。
        let startTime = currentVideoEditState.keyframes.first?.timeSeconds ?? 0
        seekVideo(to: startTime, reason: reason)
    }

    /// 動画編集モードを終了する（静止画を開いた場合など）。
    private func exitVideoEditingMode() {
        pauseVideoTimeline()
        currentVideoItem = nil
        currentVideoInfo = nil
        currentVideoEditState = VideoEditState()
        currentVideoTimeSeconds = 0
        videoTrackingLostIDs = []
        videoTimelineBar.isHidden = true
    }

    /// 指定時刻のフレームをキャンバスへ読み込み、その時刻に適用されるROIを表示する。
    private func seekVideo(to seconds: Double, reason: String? = nil, playback: Bool = false) {
        guard let item = currentVideoItem, let info = currentVideoInfo else { return }
        let clamped = min(max(0, seconds), max(0, info.durationSeconds))
        let url = libraryEngine.originalURL(for: item)
        if playback, videoPlaybackRenderInFlight {
            pendingVideoPlaybackSeekSeconds = clamped
            return
        }
        if playback {
            videoPlaybackRenderInFlight = true
            pendingVideoPlaybackSeekSeconds = nil
        }
        let keyframe = currentVideoEditState.interpolatedKeyframe(at: clamped)
        let rois = keyframe?.rois ?? []
        let previewEnabled = mosaicPreviewCheckbox.state == .on && !rois.isEmpty
        let hiddenROIIDs = canvas.hiddenROIIDs
        let visibleROIs = rois.filter { !hiddenROIIDs.contains($0.id) }
        let style = defaultMosaicStyleForRendering()
        let patternImages = videoPreviewPatternImages(for: rois, style: style)
        let renderer = videoPlaybackRenderer
        let backingScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let playbackMaximumSize: CGSize? = playback ? CGSize(
            width: max(640, canvas.bounds.width * backingScale),
            height: max(360, canvas.bounds.height * backingScale)
        ) : nil
        videoSeekRequestID += 1
        let requestID = videoSeekRequestID
        let tolerance = playback
            ? CMTime(seconds: max(1.0 / 240.0, 0.5 / max(1, info.frameRate)), preferredTimescale: 600)
            : .zero
        videoPreviewRenderQueue.async { [weak self] in
            guard let self else { return }
            let result = try? renderer.render(
                url: url,
                time: CMTime(seconds: clamped, preferredTimescale: 600),
                tolerance: tolerance,
                maximumSize: playbackMaximumSize,
                rois: visibleROIs,
                style: style,
                patternImages: patternImages,
                previewEnabled: playback && previewEnabled
            )
            DispatchQueue.main.async {
                defer {
                    if playback {
                        self.videoPlaybackRenderInFlight = false
                        let pending = self.pendingVideoPlaybackSeekSeconds
                        self.pendingVideoPlaybackSeekSeconds = nil
                        if let pending, self.isVideoPlaying {
                            self.seekVideo(to: pending, playback: true)
                        }
                    }
                }
                guard requestID == self.videoSeekRequestID,
                      self.currentVideoItem?.id == item.id else {
                    return
                }
                guard let result else {
                    self.updateStatus("フレームを取得できませんでした（\(VideoPreviewView.timeText(clamped))）")
                    return
                }
                let frame = result.frame
                self.currentVideoTimeSeconds = clamped
                self.videoTimeSlider.doubleValue = clamped
                self.loadedImage = LoadedImage(url: url, cgImage: frame)
                // その時刻に効くキーフレームのROIを表示（無ければ空）
                self.canvas.rois = rois
                if playback {
                    self.renderedImage = result.rendered
                    self.canvas.setImage(result.rendered ?? frame)
                    self.updateVideoPlaybackLabels()
                } else {
                    self.displayVideoFrame(frame, rois: self.canvas.rois)
                }
                self.canvas.selectedROIID = nil
                self.videoTrackingLostIDs = []
                self.canvas.trackingLostROIIDs = []
                if !playback {
                    self.resetUndoHistory()
                    self.editorRevision += 1
                    self.reloadLayerList()
                    self.updateVideoTimelineLabels()
                    self.updateStatsBar()
                }
                if let reason {
                    self.updateStatus("\(reason): \(item.sourceName) \(VideoPreviewView.timeText(clamped))")
                }
            }
        }
    }

    private func displayVideoFrame(_ frame: CGImage, rois: [MosaicROI]) {
        guard mosaicPreviewCheckbox.state == .on, !rois.isEmpty else {
            renderedImage = nil
            canvas.setImage(frame)
            return
        }
        do {
            let output = try renderMosaicOutput(for: rois)
            renderedImage = output
            canvas.setImage(output ?? frame)
        } catch {
            renderedImage = nil
            mosaicPreviewCheckbox.state = .off
            canvas.setImage(frame)
            updateStatus("動画モザイク表示を解除しました: \(error.localizedDescription)")
        }
    }

    private func videoPreviewPatternImages(for rois: [MosaicROI], style: MosaicStyle) -> [String: CGImage] {
        var identifiers = Set<String>()
        if let identifier = style.patternImageIdentifier {
            identifiers.insert(identifier)
        }
        for roi in rois {
            if let identifier = roi.style?.patternImageIdentifier {
                identifiers.insert(identifier)
            }
        }
        var images: [String: CGImage] = [:]
        for identifier in identifiers {
            if let image = patternImage(for: identifier) {
                images[identifier] = image
            }
        }
        return images
    }

    private func updateVideoPlaybackLabels() {
        guard let info = currentVideoInfo else { return }
        videoTimeLabel.stringValue = "\(VideoPreviewView.timeText(currentVideoTimeSeconds))"
            + " / \(VideoPreviewView.timeText(info.durationSeconds))"
    }

    private func updateVideoTimelineLabels() {
        guard let info = currentVideoInfo else {
            videoKeyframeCountLabel.stringValue = "動画未選択"
            videoTimeSlider.keyframeTimes = []
            videoTimeSlider.durationSeconds = 0
            videoKeyframeTableView.reloadData()
            return
        }
        videoTimeLabel.stringValue = "\(VideoPreviewView.timeText(currentVideoTimeSeconds))"
            + " / \(VideoPreviewView.timeText(info.durationSeconds))"
        let isKeyframe = currentVideoEditState.keyframes.contains {
            abs($0.timeSeconds - currentVideoTimeSeconds) < 0.01
        }
        videoKeyframeCountLabel.stringValue = "キーフレーム \(currentVideoEditState.keyframes.count)件"
            + (isKeyframe ? "（現在）" : "")
        videoTimeSlider.keyframeTimes = currentVideoEditState.keyframes.map(\.timeSeconds)
        videoTimeSlider.durationSeconds = info.durationSeconds
        videoKeyframeTableView.reloadData()
        selectVideoKeyframeRow(at: currentVideoTimeSeconds)
    }

    private func selectVideoKeyframeRow(at timeSeconds: Double) {
        let sorted = currentVideoEditState.keyframes.sorted { $0.timeSeconds < $1.timeSeconds }
        guard let row = sorted.firstIndex(where: { abs($0.timeSeconds - timeSeconds) < 0.01 }) else {
            videoKeyframeTableView.deselectAll(nil)
            return
        }
        videoKeyframeTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        videoKeyframeTableView.scrollRowToVisible(row)
    }

    private func videoROIsForKeyframePersistence() -> [MosaicROI] {
        videoKeyframeWithResolvedInheritedSettings(
            timeSeconds: currentVideoTimeSeconds,
            rois: canvas.rois,
            trackingStatus: currentVideoKeyframeTrackingStatus()
        )
            .rois
    }

    private func videoKeyframeWithResolvedInheritedSettings(
        timeSeconds: Double,
        rois: [MosaicROI],
        trackingStatus: VideoKeyframeTrackingStatus
    ) -> VideoKeyframe {
        VideoKeyframe(timeSeconds: timeSeconds, rois: rois, trackingStatus: trackingStatus)
            .resolvingInheritedSettings(
                inheritedStyle: defaultMosaicStyleForRendering().persistentStyle(),
                maskEngineRawValue: currentSegmentEngineKind().rawValue,
                maskThreshold: maskThresholdSlider.doubleValue
            )
    }

    private func videoEditStateWithResolvedInheritedSettings(_ state: VideoEditState) -> VideoEditState {
        state.resolvingInheritedSettings(
            inheritedStyle: defaultMosaicStyleForRendering().persistentStyle(),
            maskEngineRawValue: currentSegmentEngineKind().rawValue,
            maskThreshold: maskThresholdSlider.doubleValue
        )
    }

    private func currentVideoKeyframeTrackingStatus() -> VideoKeyframeTrackingStatus {
        if let lastTrackedVideoTimeSeconds,
           abs(lastTrackedVideoTimeSeconds - currentVideoTimeSeconds) < 0.01 {
            return .tracked
        }
        return .manual
    }

    @objc private func videoTimeSliderChanged() {
        pauseVideoTimeline()
        seekVideo(to: videoTimeSlider.doubleValue)
    }

    @objc private func toggleVideoPlayback() {
        if isVideoPlaying {
            pauseVideoTimeline()
            updateStatus("動画タイムラインを一時停止")
        } else {
            playVideoTimeline()
        }
    }

    @objc private func stepToPreviousVideoFrame() {
        stepVideoFrame(by: -1)
    }

    @objc private func stepToNextVideoFrame() {
        stepVideoFrame(by: 1)
    }

    private func stepVideoFrame(by offset: Int) {
        guard let info = currentVideoInfo else {
            updateStatus("動画を開いてから実行してください")
            return
        }
        pauseVideoTimeline()
        let frameRate = max(1, info.frameRate)
        let currentFrame = Int((currentVideoTimeSeconds * frameRate).rounded())
        let targetFrame = max(0, min(info.frameCount - 1, currentFrame + offset))
        seekVideo(
            to: Double(targetFrame) / frameRate,
            reason: offset < 0 ? "1フレーム前へ" : "1フレーム後へ"
        )
    }

    @objc private func playVideoTimeline() {
        guard let info = currentVideoInfo else {
            updateStatus("動画を開いてから実行してください")
            return
        }
        pauseVideoTimeline()
        isVideoPlaying = true
        videoPlaybackStartedAt = Date()
        videoPlaybackStartTimeSeconds = currentVideoTimeSeconds
        let tick = 1.0 / min(max(1, info.frameRate), 240)
        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let info = self.currentVideoInfo else { return }
                let elapsed = Date().timeIntervalSince(self.videoPlaybackStartedAt ?? Date())
                let next = self.videoPlaybackStartTimeSeconds + elapsed
                if next >= info.durationSeconds {
                    self.stopVideoTimeline()
                } else {
                    self.seekVideo(to: next, playback: true)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        videoPlaybackTimer = timer
        updateStatus("動画タイムラインを再生中")
    }

    @objc private func pauseVideoTimeline() {
        videoPlaybackTimer?.invalidate()
        videoPlaybackTimer = nil
        videoSeekRequestID += 1
        videoPlaybackRenderInFlight = false
        pendingVideoPlaybackSeekSeconds = nil
        videoPlaybackStartedAt = nil
        isVideoPlaying = false
    }

    @objc private func stopVideoTimeline() {
        pauseVideoTimeline()
        seekVideo(to: 0, reason: "動画タイムラインを停止")
    }

    /// 現在のフレームのROIをキーフレームとして保存する。
    @objc private func addVideoKeyframe() {
        guard let item = currentVideoItem else {
            updateStatus("動画をライブラリでダブルクリックして編集モードで開いてから実行してください")
            return
        }
        currentVideoEditState.upsertKeyframe(
            VideoKeyframe(
                timeSeconds: currentVideoTimeSeconds,
                rois: videoROIsForKeyframePersistence(),
                trackingStatus: currentVideoKeyframeTrackingStatus()
            )
        )
        lastTrackedVideoTimeSeconds = nil
        mosaicPreviewCheckbox.state = .on
        if let loadedImage {
            displayVideoFrame(loadedImage.cgImage, rois: currentVideoEditState.keyframe(at: currentVideoTimeSeconds)?.rois ?? canvas.rois)
        }
        saveCurrentVideoEditState(item: item)
        updateVideoTimelineLabels()
        updateStatus(
            "キーフレームを保存: \(VideoPreviewView.timeText(currentVideoTimeSeconds))"
            + "（ROI \(canvas.rois.count)件）"
        )
    }

    @objc private func removeVideoKeyframe() {
        guard let item = currentVideoItem else { return }
        currentVideoEditState.removeKeyframe(atTime: currentVideoTimeSeconds)
        saveCurrentVideoEditState(item: item)
        updateVideoTimelineLabels()
        updateStatus("キーフレームを削除: \(VideoPreviewView.timeText(currentVideoTimeSeconds))")
    }

    @objc private func deleteSelectedVideoKeyframes() {
        guard let item = currentVideoItem else {
            updateStatus("動画を開いてから実行してください")
            return
        }
        let selectedRows = videoKeyframeTableView.selectedRowIndexes
        guard !selectedRows.isEmpty else {
            updateStatus("削除するキーフレームを一覧で選択してください")
            return
        }
        let sorted = currentVideoEditState.keyframes.sorted { $0.timeSeconds < $1.timeSeconds }
        for row in selectedRows.reversed() where row >= 0 && row < sorted.count {
            currentVideoEditState.removeKeyframe(atTime: sorted[row].timeSeconds)
        }
        saveCurrentVideoEditState(item: item)
        updateVideoTimelineLabels()
        updateStatus("選択キーフレームを削除しました（\(selectedRows.count)件）")
        AppLog.video.info("選択キーフレーム削除: count=\(selectedRows.count, privacy: .public)")
    }

    @objc private func deleteAllVideoKeyframes() {
        guard let item = currentVideoItem else {
            updateStatus("動画を開いてから実行してください")
            return
        }
        guard !currentVideoEditState.keyframes.isEmpty else {
            updateStatus("削除するキーフレームはありません")
            return
        }
        let alert = NSAlert()
        alert.messageText = "すべてのキーフレームを削除しますか？"
        alert.informativeText = "この動画のキーフレーム編集内容をすべて削除します。この操作は取り消せません。"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let count = currentVideoEditState.keyframes.count
        currentVideoEditState.keyframes.removeAll()
        saveCurrentVideoEditState(item: item)
        updateVideoTimelineLabels()
        updateStatus("全キーフレームを削除しました（\(count)件）")
        AppLog.video.info("全キーフレーム削除: count=\(count, privacy: .public)")
    }

    @objc private func openSelectedVideoKeyframe() {
        let row = videoKeyframeTableView.selectedRow
        let sorted = currentVideoEditState.keyframes.sorted { $0.timeSeconds < $1.timeSeconds }
        guard row >= 0, row < sorted.count else { return }
        seekVideo(to: sorted[row].timeSeconds, reason: "キーフレーム")
    }

    private func navigateVideoKeyframeSelection(by offset: Int) {
        let sorted = currentVideoEditState.keyframes.sorted { $0.timeSeconds < $1.timeSeconds }
        guard !sorted.isEmpty else { return }
        let selected = videoKeyframeTableView.selectedRow
        let currentRow = selected >= 0 ? selected : (sorted.firstIndex {
            abs($0.timeSeconds - currentVideoTimeSeconds) < 0.01
        } ?? 0)
        let destination = max(0, min(sorted.count - 1, currentRow + offset))
        videoKeyframeTableView.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        videoKeyframeTableView.scrollRowToVisible(destination)
        seekVideo(to: sorted[destination].timeSeconds, reason: offset < 0 ? "前のキーフレーム" : "次のキーフレーム")
    }

    @objc private func autoProcessCurrentVideo() {
        guard let item = currentVideoItem, let info = currentVideoInfo else {
            updateStatus("動画を開いてから実行してください")
            return
        }
        guard !isAutoProcessingVideo else {
            updateStatus("動画自動モザイク処理は実行中です")
            return
        }
        let detector: VideoFrameDetector = makeVideoFrameDetector()
        let trackingOptions = currentVideoTrackingOptions()
        let intervalFrames = trackingOptions.redetectIntervalFrames
        guard info.frameCount > 0 else {
            updateStatus("処理できる動画フレームがありません")
            return
        }
        let url = libraryEngine.originalURL(for: item)
        let baseState = currentVideoEditState
        let inheritedStyle = defaultMosaicStyleForRendering().persistentStyle()
        let inheritedMaskEngineRawValue = currentSegmentEngineKind().rawValue
        let inheritedMaskThreshold = maskThresholdSlider.doubleValue
        let cancellation = VideoMosaicExporter.CancellationFlag()
        videoAutoProcessCancellation = cancellation
        isAutoProcessingVideo = true
        updateAnalysisStopButtonVisibility()
        updateStatus("動画自動モザイク処理中… 0/\(info.frameCount)フレーム")
        AppLog.video.info(
            "動画自動モザイク処理開始: frames=\(info.frameCount, privacy: .public) redetect=\(intervalFrames, privacy: .public)"
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var state = VideoEditState(
                keyframeInterval: intervalFrames,
                maskEngineRawValue: inheritedMaskEngineRawValue
            )
            var detectedKeyframes = 0
            var previousLostIDs: Set<UUID> = []
            let trackingSampleInterval = max(1, min(intervalFrames, Int((max(1, info.frameRate) / 6).rounded())))
            let coordinator = VideoTrackingCoordinator(
                editState: VideoEditState(),
                frameRate: info.frameRate,
                options: trackingOptions
            )
            do {
                try VideoFrameReader(url: url).readFrames(
                    shouldContinue: { !cancellation.isCancelled }
                ) { index, frame, presentationTime in
                    let outcome = try coordinator.rois(forFrame: index, image: frame, detector: detector)
                    let rawTime = CMTimeGetSeconds(presentationTime)
                    let time = rawTime.isFinite ? rawTime : Double(index) / max(1, info.frameRate)
                    let lostStateChanged = outcome.lostIDs != previousLostIDs
                    let shouldSave = !outcome.rois.isEmpty && (
                        outcome.didRedetect
                            || lostStateChanged
                            || index % trackingSampleInterval == 0
                            || index >= info.frameCount - 1
                    )
                    if shouldSave {
                        let persistedKeyframe = VideoKeyframe(
                            timeSeconds: time,
                            rois: outcome.rois,
                            trackingStatus: outcome.didRedetect ? .autoDetected : .tracked
                        ).resolvingInheritedSettings(
                            inheritedStyle: inheritedStyle,
                            maskEngineRawValue: inheritedMaskEngineRawValue,
                            maskThreshold: inheritedMaskThreshold
                        )
                        state.upsertKeyframe(persistedKeyframe)
                        detectedKeyframes += 1
                    }
                    previousLostIDs = outcome.lostIDs
                    if index % max(1, Int(info.frameRate / 5)) == 0 {
                        DispatchQueue.main.async { [weak self] in
                            self?.updateStatus(
                                "動画自動モザイク処理中… \(min(index + 1, info.frameCount))/\(info.frameCount)フレーム"
                            )
                        }
                    }
                }
                // 手動で確定したキーフレームは自動解析結果より優先して残す。
                for keyframe in baseState.keyframes where keyframe.trackingStatus == .manual {
                    state.upsertKeyframe(keyframe)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isAutoProcessingVideo = false
                    let wasCancelled = cancellation.isCancelled
                    self.videoAutoProcessCancellation = nil
                    self.updateAnalysisStopButtonVisibility()
                    guard self.currentVideoItem?.id == item.id else { return }
                    self.currentVideoEditState = state
                    self.mosaicPreviewCheckbox.state = state.keyframes.contains { !$0.rois.isEmpty } ? .on : .off
                    self.saveCurrentVideoEditState(item: item)
                    self.updateVideoTimelineLabels()
                    self.seekVideo(to: self.currentVideoTimeSeconds, reason: wasCancelled ? "動画自動モザイク処理を停止" : "動画自動モザイク処理完了")
                    self.updateStatus(
                        (wasCancelled ? "動画自動モザイク処理を停止しました" : "動画自動モザイク処理完了")
                        + ": キーフレーム\(state.keyframes.count)件（追跡保存 \(detectedKeyframes)件）。必要なら確認後に動画を書き出してください"
                    )
                    AppLog.video.info(
                        "動画自動モザイク処理完了: keyframes=\(state.keyframes.count, privacy: .public) detected=\(detectedKeyframes, privacy: .public)"
                    )
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.isAutoProcessingVideo = false
                    self?.videoAutoProcessCancellation = nil
                    self?.updateAnalysisStopButtonVisibility()
                    self?.showError(error)
                    AppLog.video.error("動画自動モザイク処理失敗: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func saveCurrentVideoEditState(item: MosaicLibraryItem) {
        do {
            currentVideoEditState = videoEditStateWithResolvedInheritedSettings(currentVideoEditState)
            try videoEditStore.save(currentVideoEditState, for: item.id)
        } catch {
            showError(error)
        }
    }

    @objc private func jumpToPreviousKeyframe() {
        let previous = currentVideoEditState.keyframes
            .filter { $0.timeSeconds < currentVideoTimeSeconds - 0.01 }
            .max { $0.timeSeconds < $1.timeSeconds }
        guard let previous else {
            updateStatus("これより前のキーフレームはありません")
            return
        }
        seekVideo(to: previous.timeSeconds, reason: "前のキーフレーム")
    }

    @objc private func jumpToNextKeyframe() {
        let next = currentVideoEditState.keyframes
            .filter { $0.timeSeconds > currentVideoTimeSeconds + 0.01 }
            .min { $0.timeSeconds < $1.timeSeconds }
        guard let next else {
            updateStatus("これより後のキーフレームはありません")
            return
        }
        seekVideo(to: next.timeSeconds, reason: "次のキーフレーム")
    }

    /// 直前のキーフレームから現在時刻までROIを追跡し、追随後の位置をキャンバスへ表示する。
    /// 見失ったROIはステータスへ件数を出し、ユーザーが修正して新しいキーフレームにできる。
    @objc private func runTrackingPreview() {
        guard let item = currentVideoItem, let info = currentVideoInfo else {
            updateStatus("動画をライブラリでダブルクリックして編集モードで開いてから実行してください")
            AppLog.video.info("追跡確認を中止: 動画未選択")
            return
        }
        let targetTime = currentVideoTimeSeconds
        let editState = videoEditStateWithResolvedInheritedSettings(currentVideoEditState)
        guard let keyframe = editState.keyframe(before: targetTime, requiringROIs: true) else {
            updateStatus("追跡の起点となる直前のROI付きキーフレームがありません。先にROIを作り「キーフレーム追加」後、後の時刻へ移動してください")
            AppLog.video.info("追跡確認を中止: 起点なし target=\(targetTime, privacy: .public)")
            return
        }
        let url = libraryEngine.originalURL(for: item)
        let frameRate = max(1, info.frameRate)
        let options = currentVideoTrackingOptions()
        let detector: VideoFrameDetector? =
            (options.autoRedetectEnabled || options.sceneCutRedetectEnabled)
            ? makeVideoFrameDetector()
            : nil
        let startIndex = Int((keyframe.timeSeconds * frameRate).rounded())
        let endIndex = Int((targetTime * frameRate).rounded())
        updateStatus("追跡中… \(VideoPreviewView.timeText(keyframe.timeSeconds)) → \(VideoPreviewView.timeText(targetTime))")
        AppLog.video.info(
            "追跡確認開始: start=\(keyframe.timeSeconds, privacy: .public) target=\(targetTime, privacy: .public) roi=\(keyframe.rois.count, privacy: .public)"
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 書き出しと同じ`VideoTrackingCoordinator`を使う。プレビューと書き出しで
            // 挙動が食い違うと「プレビューでは追随したのに書き出すとズレる」ことになるため、
            // 自動再検出・シーンカット検出・見失い時の膨張まで同じ設定で通す（v0.0.00136）。
            let coordinator = VideoTrackingCoordinator(
                editState: editState,
                frameRate: frameRate,
                options: options
            )
            var trackedROIs = keyframe.rois
            var lostIDs: Set<UUID> = []
            do {
                try VideoFrameReader(url: url).readFrames(shouldContinue: { true }) { index, image, _ in
                    guard index >= startIndex else { return }
                    guard index <= endIndex else { throw TrackingPreviewStop.reachedTarget }
                    let outcome = try coordinator.rois(forFrame: index, image: image, detector: detector)
                    trackedROIs = outcome.rois
                    lostIDs = outcome.lostIDs
                }
            } catch is TrackingPreviewStop {
                // 目標フレームへ到達したので正常終了
            } catch {
                DispatchQueue.main.async { [weak self] in self?.showError(error) }
                return
            }
            let resultROIs = trackedROIs
            let resultLost = lostIDs
            DispatchQueue.main.async {
                guard let self, self.currentVideoItem?.id == item.id,
                      abs(self.currentVideoTimeSeconds - targetTime) < 0.01 else { return }
                self.canvas.rois = self.videoKeyframeWithResolvedInheritedSettings(
                    timeSeconds: targetTime,
                    rois: resultROIs,
                    trackingStatus: .tracked
                ).rois
                self.videoTrackingLostIDs = resultLost
                self.canvas.trackingLostROIIDs = resultLost
                self.lastTrackedVideoTimeSeconds = targetTime
                self.hasUnsavedChanges = true
                self.editorRevision += 1
                self.reloadLayerList()
                self.updateStatsBar()
                if resultLost.isEmpty {
                    self.updateStatus("追跡完了: ROI \(resultROIs.count)件が追随しました（修正後「キーフレーム追加」で確定できます）")
                } else {
                    self.updateStatus(
                        "追跡完了: ROI \(resultROIs.count)件中 \(resultLost.count)件を見失いました"
                        + "（直前の位置を保持しています。修正後「キーフレーム追加」で確定してください）"
                    )
                }
                AppLog.video.info(
                    "追跡確認完了: roi=\(resultROIs.count, privacy: .public) lost=\(resultLost.count, privacy: .public)"
                )
            }
        }
    }

    private func trackingStartKeyframe(before targetTime: Double) -> VideoKeyframe? {
        currentVideoEditState.keyframe(before: targetTime, requiringROIs: true)
    }

    /// 動画プレビュー再生ウィンドウを開く（V2。確認用の再生のみで編集は行わない）。
    /// 既に開いている場合は作り直して選択中の動画へ差し替える。
    private func openVideoPreview(for item: MosaicLibraryItem) {
        guard item.isVideo else { return }
        let url = libraryEngine.originalURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            updateStatus("動画ファイルが見つかりません: \(item.sourceName)（リンク切れ修正をお試しください）")
            return
        }
        closeVideoPreview()
        let preview = VideoPreviewView(url: url)
        preview.translatesAutoresizingMaskIntoConstraints = false
        let size = NSSize(
            width: max(480, min(960, CGFloat(item.imagePixelWidth))),
            height: max(320, min(640, CGFloat(item.imagePixelHeight))) + 36
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "動画プレビュー: \(item.sourceName)"
        window.contentView = preview
        window.isReleasedWhenClosed = false
        // 閉じるボタン（赤い×）で閉じたときも後始末する。delegateが無いと再生が続き、
        // 時刻オブザーバとコントロールのtargetが残ったままになる（クラッシュ報告 2026-08-02）。
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        videoPreviewWindow = window
    }

    /// 動画プレビューを閉じる（再生を止めてから破棄する）。
    private func closeVideoPreview() {
        (videoPreviewWindow?.contentView as? VideoPreviewView)?.stop()
        videoPreviewWindow?.delegate = nil
        videoPreviewWindow?.orderOut(nil)
        videoPreviewWindow = nil
    }

    /// 閉じられた補助ウィンドウへの参照を解放する。
    ///
    /// 参照を残したままだと `showAdvancedSettings()` 等の「既に開いていれば前面へ出す」経路が
    /// 閉じたウィンドウを掴み続ける。次に開くときは作り直す方が状態の食い違いも起きない。
    fileprivate func releaseAuxiliaryWindowReference(_ window: NSWindow) {
        if window === advancedSettingsWindow { advancedSettingsWindow = nil }
        if window === exportWindow { exportWindow = nil }
        if window === shortcutsWindow { shortcutsWindow = nil }
        if window === numpadAssignmentWindow { numpadAssignmentWindow = nil }
        if window === debugLogWindow { debugLogWindow = nil }
    }

    /// 開いている補助ウィンドウをすべて閉じる（主ウィンドウを閉じたときの後始末）。
    ///
    /// `close()` はそれぞれの `windowWillClose` を呼ぶので、動画プレビューの停止や
    /// 参照の解放はそちらで行われる。
    fileprivate func closeAllAuxiliaryWindows() {
        for window in [
            videoPreviewWindow, advancedSettingsWindow, exportWindow,
            shortcutsWindow, numpadAssignmentWindow, debugLogWindow
        ].compactMap({ $0 }) {
            window.close()
        }
    }

    /// このウィンドウが動画プレビューか。主ウィンドウと同じdelegateを共有するため必要。
    fileprivate func isVideoPreviewWindow(_ window: NSWindow) -> Bool {
        window === videoPreviewWindow
    }

    /// 主ウィンドウ以外の、このコントローラがdelegateを兼ねているウィンドウか。
    fileprivate func isAuxiliaryWindow(_ window: NSWindow) -> Bool {
        window === videoPreviewWindow
            || window === advancedSettingsWindow
            || window === exportWindow
            || window === shortcutsWindow
            || window === numpadAssignmentWindow
            || window === debugLogWindow
    }

    /// 閉じられたウィンドウが動画プレビューなら後始末する（`windowWillClose`から呼ぶ）。
    fileprivate func finishVideoPreviewIfNeeded(_ window: NSWindow) {
        guard window === videoPreviewWindow else { return }
        (window.contentView as? VideoPreviewView)?.stop()
        window.delegate = nil
        videoPreviewWindow = nil
    }

    /// ライブラリで選択中の動画をプレビュー再生する（静止画では何もしない）。
    @objc private func previewSelectedVideo() {
        guard let item = selectedLibraryItem() else { return }
        guard item.isVideo else {
            updateStatus("選択項目は静止画です（動画を選択してください）")
            return
        }
        openVideoPreview(for: item)
    }

    @objc private func openImage() {
        let panel = NSOpenPanel()
        // 動画も選べるようにする（GUI報告 2026-08-10: 動画認識をしたいのに「画像を開く」で
        // MOVがグレーアウトして選べない）。選択後は実体のUTTypeで静止画/動画へ振り分ける。
        panel.allowedContentTypes = Self.openableMediaTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !Self.isVideoFile(url) else {
            importVideoFile(at: url)
            return
        }
        openImageFile(at: url)
    }

    /// 静止画ファイルをライブラリへ取り込み、作業対象として開く。
    private func openImageFile(at url: URL) {
        do {
            let loaded = try imageLoader.loadImage(from: url)
            guard confirmCurrentChangesBeforeLeaving() else { return }
            let item = try libraryEngine.importOriginal(loaded.cgImage, sourceName: url.lastPathComponent)
            setWorkingImage(loaded.cgImage, sourceURL: libraryEngine.originalURL(for: item), item: item)
            updateStatus("読み込み: \(url.lastPathComponent) \(Int(loaded.pixelSize.width))x\(Int(loaded.pixelSize.height))")
            reloadLibrary()
            autoGenerateIfEnabled()
        } catch {
            discardedEditStateID = nil
            showError(error)
        }
    }

    /// クリップボードの貼り付け。
    ///
    /// **ファイルURLを先に見る**（GUI報告 2026-08-10: Finderでコピーした動画を貼り付けても
    /// 再生もプレビューもされない）。Finderでファイルをコピーすると、ペーストボードには
    /// ファイルURLに加えて**そのファイルのアイコン画像**もNSImageとして載る。
    /// 以前は`NSImage`だけを見ていたため、動画を貼り付けると1024×1024のMOVアイコンが
    /// 静止画としてライブラリへ登録され、動画としては一切扱われていなかった。
    /// URLがあればその実体で振り分け（動画=リンク登録+プレビュー / 静止画=原寸で取り込み）、
    /// URLが無い場合だけ従来どおりNSImage（ブラウザ画像・スクリーンショット等）として扱う。
    @objc private func pasteImage() {
        let fileURL = (NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL])?.first
        if let fileURL {
            if Self.isVideoFile(fileURL) {
                importVideoFile(at: fileURL)
                return
            }
            // 画像ファイルのコピーはアイコンではなく原寸の実体を取り込む
            if (try? fileURL.checkResourceIsReachable()) == true,
               NSImage(contentsOf: fileURL) != nil {
                openImageFile(at: fileURL)
                return
            }
        }

        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            updateStatus("クリップボードに画像・動画がありません。画像をコピーするか、Finderで画像／動画ファイルをコピーしてから貼り付けてください")
            return
        }

        do {
            guard confirmCurrentChangesBeforeLeaving() else { return }
            let item = try libraryEngine.importOriginal(cgImage, sourceName: "clipboard_\(Self.timestamp()).png")
            setWorkingImage(cgImage, sourceURL: libraryEngine.originalURL(for: item), item: item)
            updateStatus("貼り付け画像をライブラリへ保存: \(item.sourceName)")
            reloadLibrary()
            autoGenerateIfEnabled()
        } catch {
            discardedEditStateID = nil
            showError(error)
        }
    }

    @objc private func generateCandidates() {
        guard let loadedImage else {
            updateStatus("先に画像を開いてください")
            return
        }
        guard !isGeneratingCandidates else {
            hasPendingCandidateGeneration = true
            updateStatus("解析中です。現在の解析完了後にもう一度実行します")
            return
        }

        let previousState = currentEditorState()
        let requestedEditorRevision = editorRevision
        let requestedItemID = currentLibraryItem?.id
        let selectedShape = canvas.currentShape
        let checkedCategories = checkedGenerationCategories()
        let includePersonLayers = generatePersonCheckbox.state == .on
        let includePoseLayers = generatePoseCheckbox.state == .on
        let input = CandidateGenerationInput(
            image: loadedImage.cgImage,
            domainMode: domainModeControl.indexOfSelectedItem,
            groinPositionRatio: groinPositionSlider.doubleValue
        )
        let worker = candidateGenerationWorker
        let generationID = UUID()

        isGeneratingCandidates = true
        candidateGenerationID = generationID
        cancelledCandidateGenerationIDs.remove(generationID)
        updateAnalysisStopButtonVisibility()
        updateStatus("人物・骨格・対象部位を解析中…")
        Task { [weak self] in
            let taskResult = await Task.detached(priority: .userInitiated) {
                do {
                    return CandidateGenerationTaskResult.success(try worker.run(input))
                } catch {
                    return CandidateGenerationTaskResult.failure(error.localizedDescription)
                }
            }.value

            guard let self else { return }
            self.isGeneratingCandidates = false
            let wasCancelled = self.cancelledCandidateGenerationIDs.remove(generationID) != nil
            if self.candidateGenerationID == generationID {
                self.candidateGenerationID = nil
            }
            self.updateAnalysisStopButtonVisibility()
            guard self.currentLibraryItem?.id == requestedItemID else {
                if self.hasPendingCandidateGeneration {
                    self.hasPendingCandidateGeneration = false
                    self.generateCandidates()
                }
                return
            }
            guard !wasCancelled else {
                self.updateStatus("解析を停止しました。停止前までの既存データを表示しています")
                return
            }

            switch taskResult {
            case .failure(let message):
                self.updateStatus("候補生成に失敗しました: \(message)")
            case .success(let output):
                guard self.editorRevision == requestedEditorRevision,
                      self.canvas.rois == previousState.rois else {
                    self.updateStatus("解析中に編集されたため、候補生成結果は適用しませんでした。必要に応じて再実行してください")
                    break
                }
                self.applyCandidateGenerationOutput(
                    output,
                    sourceImage: input.image,
                    previousState: previousState,
                    selectedShape: selectedShape,
                    checkedCategories: checkedCategories,
                    includePersonLayers: includePersonLayers,
                    includePoseLayers: includePoseLayers
                )
            }

            if self.hasPendingCandidateGeneration {
                self.hasPendingCandidateGeneration = false
                self.generateCandidates()
            }
        }
    }

    private func applyCandidateGenerationOutput(
        _ output: CandidateGenerationOutput,
        sourceImage: CGImage,
        previousState: EditorState,
        selectedShape: ROIShape,
        checkedCategories: Set<MosaicTargetCategory>,
        includePersonLayers: Bool,
        includePoseLayers: Bool
    ) {
        let snapshot = output.snapshot
        var rois = output.rois
        // 学習モードOFFのときは、記録も利用も行わない。
        // 利用だけ残すと、OFFにしても過去の学習由来の候補が出続けて止める手段が無くなる。
        if let learningEngine, isLearningModeEnabled {
            rois = learningEngine.refineCandidates(rois, persons: snapshot.personBounds, image: sourceImage)
        }
        let beforeFilterCount = rois.count
        rois = rois.filter { checkedCategories.contains($0.category) }
        let filteredOutCount = beforeFilterCount - rois.count
        rois = rois.map { roi in
            var updated = roi
            updated.shape = selectedShape
            if selectedShape == .polygon && updated.polygonPoints == nil {
                updated.polygonPoints = MosaicROI.defaultPolygonPoints
            }
            return updated
        }
        // 形状が決まってから広げる（形状ごとに必要な倍率が違うため）
        rois = DetectedROIRefiner.expandGenitalROIsToCoverShape(rois)
        // 自動検出の結果は候補カテゴリごとにグループへまとめる（ユーザー要望 2026-08-02）。
        // 手描き（manual）はユーザーが自分でまとめる想定なので触らない。
        rois = rois.map { roi in
            guard roi.source != "manual", roi.roiGroupName == nil else { return roi }
            var grouped = roi
            grouped.roiGroupName = roi.category.displayName
            return grouped
        }

        logAnalysisDiagnostics(rois: rois, sourceImage: sourceImage, output: output, checkedCategories: checkedCategories)

        pushUndoSnapshot(previousState)
        suspendMosaicPreview()
        canvas.rois = rois
        lastAutoROIs = rois
        lastPersonBounds = snapshot.personBounds
        canvas.personLayerRects = includePersonLayers ? snapshot.personBounds : []
        canvas.personLayerMasks = includePersonLayers
            ? snapshot.persons.map { $0.maskImage.flatMap { self.tintedMask(from: $0) } }
            : []
        // 未着色の人物シルエット（人物レイヤ由来ROIのモザイクマスク用。表示用の着色版とは別に保持）
        personMaskImages = includePersonLayers ? snapshot.persons.map(\.maskImage) : []
        canvas.poseLayerRects = includePoseLayers ? snapshot.poseHints.map { Self.poseDisplayRect(for: $0) } : []
        canvas.poseLayerBones = includePoseLayers ? snapshot.poseHints.map { Self.boneSegments(for: $0) } : []
        canvas.poseLayerJointPoints = includePoseLayers
            ? snapshot.poseHints.map { $0.joints.map { CGPoint(x: $0.x, y: $0.y) } }
            : []
        rebuildDetectionLayers(
            personCount: snapshot.personBounds.count,
            poseAvailability: snapshot.poseHints.map { !$0.joints.isEmpty },
            includePersonLayer: includePersonLayers,
            includePoseLayer: includePoseLayers
        )
        showAllLayers()
        resumeMosaicPreviewIfNeeded()

        let domainNote: String
        if let failure = output.detectorFailureMessage {
            domainNote = "検出器エラー（\(failure)）: "
        } else if output.domain == .illustration {
            domainNote = output.domainDetectorAvailable
                ? "イラスト/漫画（\(output.domainSourceNote)・アニメ部位検出: \(output.animeDetectionCount)件）: "
                : "イラスト/漫画（\(output.domainSourceNote)・アニメ用検出モデルを読み込めませんでした）: "
        } else {
            domainNote = output.domainDetectorAvailable
                ? "実写（\(output.domainSourceNote)・実写部位検出: \(output.photoDetectionCount)件）: "
                : "実写（\(output.domainSourceNote)・実写用検出モデルを読み込めませんでした）: "
        }
        let filterNote = filteredOutCount > 0 ? "（対象カテゴリ外 \(filteredOutCount)件を除外）" : ""
        if snapshot.persons.isEmpty && canvas.rois.isEmpty {
            updateStatus(domainNote + "人物を検出できませんでした（候補0件）\(filterNote)。ドラッグで手動追加してください")
        } else {
            let poseDetectedCount = snapshot.poseHints.filter { !$0.joints.isEmpty }.count
            updateStatus(domainNote + "候補生成: 人物\(snapshot.persons.count)名（骨格検出 \(poseDetectedCount)名） / ROI \(canvas.rois.count)件\(filterNote)。ドラッグで手動追加できます")
        }
    }

    private let maskTintContext = CIContext(options: [.cacheIntermediates: false])

    /// 人物マスク（白黒）を青の半透明オーバーレイ画像に変換する。
    private func tintedMask(from mask: CGImage) -> CGImage? {
        let ciMask = CIImage(cgImage: mask)
        let tint = CIImage(color: CIColor(red: 0.25, green: 0.5, blue: 1, alpha: 0.45)).cropped(to: ciMask.extent)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: ciMask.extent)
        let blended = tint.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: ciMask
        ])
        return maskTintContext.createCGImage(blended, from: ciMask.extent)
    }

    private static func poseDisplayRect(for hint: PoseHint) -> NormalizedRect {
        // 骨格レイヤは関節外接矩形ではなく、対応する人物検出領域を表示範囲とする。
        // 欠損関節がある立位・横臥・遠景でも人物レイヤと同じ範囲に重なり、狭い誤認識枠に見えない。
        hint.bodyBounds
    }

    private static func boneSegments(for hint: PoseHint) -> [(from: CGPoint, to: CGPoint)] {
        // 保持している関節（保存閾値0.1）はすべて描画する。既定のminConfidence(0.15)を使うと
        // 保持済み関節すら描画されず「マスク内なのにボーンが出ない」度合いが悪化するため明示的に0.1を指定。
        PoseJointName.boneConnections.compactMap { pair in
            guard let a = hint.joint(pair.0, minConfidence: 0.1),
                  let b = hint.joint(pair.1, minConfidence: 0.1) else { return nil }
            return (CGPoint(x: a.x, y: a.y), CGPoint(x: b.x, y: b.y))
        }
    }

    // MARK: - モザイク表示切替（未保存プレビュー）

    /// 「モザイク表示」チェックのON/OFF。ONで現在のROIにモザイクを適用した見た目を表示し、
    /// OFFで元画像+ROI表示に戻す（ROI・レイヤ情報は保持され再編集可能。ライブラリ保存はしない）。
    @objc private func toggleMosaicPreview() {
        AppSettings.shared.set(mosaicPreviewCheckbox.state == .on, forKey: Self.mosaicPreviewDefaultKey)
        guard let loadedImage else {
            mosaicPreviewCheckbox.state = .off
            return
        }
        if mosaicPreviewCheckbox.state == .on {
            do {
                // `renderMosaicOutput` を経由させ、非表示レイヤ（`hiddenROIIDs`）を除外する。
                // 以前はここで `canvas.rois` を直接渡していたため、レイヤの表示チェックを
                // 外した状態でこのチェックボックスをOFF→ONと手動切替すると、非表示にした
                // はずのレイヤが画面に復活していた（コードレビューで検出）。
                let output = try renderMosaicOutput(for: canvas.rois)
                renderedImage = output
                canvas.setImage(output ?? loadedImage.cgImage)
                updateStatus("モザイク表示中（未保存プレビュー。編集を始めると解除されます）")
            } catch {
                mosaicPreviewCheckbox.state = .off
                showError(error)
            }
        } else {
            canvas.setImage(loadedImage.cgImage)
            updateStatus("モザイク解除表示（ROIは保持しています）")
        }
    }

    /// 編集中はモザイク表示を一時停止して元画像を表示する（「モザイク表示」チェックの状態は変更しない。
    /// チェックはユーザー操作でのみ変わる仕様。編集完了後に `resumeMosaicPreviewIfNeeded()` で自動再適用する）。
    private func suspendMosaicPreview() {
        guard renderedImage != nil else { return }
        renderedImage = nil
        if let loadedImage {
            canvas.setImage(loadedImage.cgImage)
        }
    }

    /// 「モザイク表示」チェックがONなら現在のROIでモザイクを再レンダリングして表示する。
    /// ROIが空の場合は元画像表示。失敗時はプレビューを解除し、エラーを通知する。
    private func resumeMosaicPreviewIfNeeded() {
        guard mosaicPreviewCheckbox.state == .on, let loadedImage else { return }
        guard !canvas.rois.isEmpty else {
            renderedImage = nil
            canvas.setImage(loadedImage.cgImage)
            return
        }
        do {
            let output = try renderMosaicOutput(for: canvas.rois)
            renderedImage = output
            canvas.setImage(output ?? loadedImage.cgImage)
        } catch {
            renderedImage = nil
            canvas.setImage(loadedImage.cgImage)
            mosaicPreviewCheckbox.state = .off
            updateStatus("モザイクプレビューを解除しました: \(error.localizedDescription)")
            showError(error)
        }
    }

    /// ROIからモザイク適用結果を作る（表示はしない）。ROIが空・画像未読み込みならnil。
    /// 「元に戻す」で描画済み画像を復元する代わりに作り直すために使う。
    private func renderMosaicOutput(for rois: [MosaicROI]) throws -> CGImage? {
        // 表示OFFのレイヤはプレビューに出さない（画面表示だけの設定）。
        let visible = rois.filter { !canvas.hiddenROIIDs.contains($0.id) }
        guard let loadedImage, !visible.isEmpty else { return nil }
        return try mosaicEngine.applyMosaic(
            to: loadedImage.cgImage,
            rois: visible,
            style: defaultMosaicStyleForRendering(),
            segmentEngine: currentSegmentEngine(),
            patternImageProvider: { [weak self] in self?.patternImage(for: $0) },
            skipIncompletePatterns: true
        )
    }

    @objc private func maskThresholdChanged() {
        let value = maskThresholdSlider.doubleValue
        maskThresholdValueLabel.stringValue = value < 0.01 ? "自動" : "\(Int(value * 100)) %"
        // 形状しきい値はマスクの内容を変えるので、キャッシュを捨ててから作り直す
        // （キャッシュはエンジンの型名で識別しており、同じ型で設定だけ変わる場合は
        //  明示的に捨てないと古いマスクが残る）。
        mosaicEngine.invalidateMaskCache()
        if applyDetectionSettingToSelectedLayers() { return }
        AppSettings.shared.set(value, forKey: Self.maskThresholdDefaultsKey)
        applyVideoDefaultMaskSettingChange(
            maskEngineRawValue: currentSegmentEngineKind().rawValue,
            maskThreshold: value
        )
        // モザイク表示中は変更を即時反映する
        resumeMosaicPreviewIfNeeded()
    }

    /// インスペクタ「マスク生成」に表示する方式（v0.0.00133〜 3択へ絞り込み。GUI要望 2026-08-08）。
    /// 旧方式（人物の輪郭/物体の輪郭/対象形状(旧)）は内部エンジン・保存データ互換として残し、
    /// 表示・選択のみ廃止。ROI個別設定に旧方式のrawValueが残っていてもPerROISegmentEngine経由で
    /// 従来通り動作する。インスペクタへ読み戻す際は`selectableEngineKind(for:)`でSAMへ丸める。
    nonisolated static let selectableEngineKinds: [SegmentEngineKind] = [.shape, .samShape, .learnedShape]

    /// 保存値・ROI個別設定の方式を、表示可能な3択のいずれかへ丸める（旧方式→対象形状(SAM)）。
    private static func selectableEngineKind(for kind: SegmentEngineKind) -> SegmentEngineKind {
        selectableEngineKinds.contains(kind) ? kind : .samShape
    }

    /// 「マスク生成」方式の変更。「個別」ONで選択中レイヤがあれば、そのレイヤにだけ方式を書き込む。
    @objc private func segmentEngineChanged() {
        // 生成方式が変わればマスクは別物になる
        mosaicEngine.invalidateMaskCache()
        let kinds = Self.selectableEngineKinds
        let index = segmentEngineControl.indexOfSelectedItem
        if index >= 0, index < kinds.count, kinds[index] == .learnedShape, !LearnedShapeSegmentEngine.isAvailable {
            // 未導入でもクラッシュせず図形へフォールバックするが、無言だと原因が分からないため案内する
            updateStatus(
                "形状モデル（part_seg.onnx）が未導入のため「図形」で処理します。"
                + "Docs/FINETUNE_GUIDE.md の手順で作成し Application Support/newMosaic/Models へ配置してください"
            )
        }
        if applyDetectionSettingToSelectedLayers() { return }
        applyVideoDefaultMaskSettingChange(
            maskEngineRawValue: currentSegmentEngineKind().rawValue,
            maskThreshold: maskThresholdSlider.doubleValue
        )
        resumeMosaicPreviewIfNeeded()
    }

    private func applyVideoDefaultMaskSettingChange(
        maskEngineRawValue: String,
        maskThreshold: Double
    ) {
        guard let item = currentVideoItem else { return }
        var changed = currentVideoEditState.maskEngineRawValue != maskEngineRawValue
        currentVideoEditState.maskEngineRawValue = maskEngineRawValue
        currentVideoEditState.keyframes = currentVideoEditState.keyframes.map { keyframe in
            var updatedKeyframe = keyframe
            updatedKeyframe.rois = keyframe.rois.map { roi in
                var updatedROI = roi
                updatedROI.maskEngine = maskEngineRawValue
                updatedROI.maskThreshold = maskThreshold
                if updatedROI != roi {
                    changed = true
                }
                return updatedROI
            }
            return updatedKeyframe
        }
        canvas.rois = canvas.rois.map { roi in
            var updatedROI = roi
            updatedROI.maskEngine = maskEngineRawValue
            updatedROI.maskThreshold = maskThreshold
            return updatedROI
        }
        guard changed else { return }
        do {
            try videoEditStore.save(currentVideoEditState, for: item.id)
            updateVideoTimelineLabels()
            reloadLayerList()
            updateStatsBar()
        } catch {
            showError(error)
        }
    }

    @objc private func individualDetectionChanged() {
        AppSettings.shared.set(individualDetectionCheckbox.state == .on, forKey: Self.individualDetectionDefaultsKey)
        updateStatus(individualDetectionCheckbox.state == .on
            ? "検出設定を個別適用にしました（変更は選択中のレイヤにだけ反映されます）"
            : "検出設定を全体適用にしました（個別設定を持たないレイヤすべてに反映されます）")
    }

    /// 「個別」ONかつレイヤ選択がある場合に、現在の検出設定（マスク生成方式・形状しきい値）を
    /// 選択中ROIへ書き込んで再生成する。書き込んだ場合はtrueを返し、呼び出し側は
    /// 全体設定の更新を行わない（他レイヤのマスク・モザイク状態を変えないため）。
    @discardableResult
    private func applyDetectionSettingToSelectedLayers() -> Bool {
        guard individualDetectionCheckbox.state == .on else { return false }
        let targetIDs = selectedROIIDsForIndividualSettings()
        guard !targetIDs.isEmpty else { return false }

        let index = segmentEngineControl.indexOfSelectedItem
        let kinds = Self.selectableEngineKinds
        guard index >= 0, index < kinds.count else { return false }
        let kind = kinds[index].rawValue
        let threshold = maskThresholdSlider.doubleValue

        let previousState = currentEditorState()
        var changed = false
        canvas.rois = canvas.rois.map { roi in
            guard targetIDs.contains(roi.id) else { return roi }
            var updated = roi
            updated.maskEngine = kind
            updated.maskThreshold = threshold
            if updated != roi { changed = true }
            return updated
        }
        guard changed else { return true }
        pushUndoSnapshot(previousState)
        hasUnsavedChanges = true
        resumeMosaicPreviewIfNeeded()
        updateStatus("検出設定を選択中レイヤ \(targetIDs.count)件に適用しました（他レイヤは変更していません）")
        return true
    }

    /// 選択されたROIが個別のマスク生成設定を持つ場合、インスペクタの表示をその値へ合わせる。
    /// （合わせておかないと、次に別項目を触ったときに画面表示と違う値が書き込まれてしまう）
    private func loadDetectionSettingForSelection(_ roi: MosaicROI?) {
        guard individualDetectionCheckbox.state == .on, let roi else { return }
        if let rawValue = roi.maskEngine,
           let kind = SegmentEngineKind(rawValue: rawValue),
           let index = Self.selectableEngineKinds.firstIndex(of: Self.selectableEngineKind(for: kind)) {
            segmentEngineControl.selectItem(at: index)
        }
        if let threshold = roi.maskThreshold {
            maskThresholdSlider.doubleValue = threshold
            maskThresholdValueLabel.stringValue = threshold < 0.01 ? "自動" : "\(Int(threshold * 100)) %"
        }
    }

    /// 「個別」適用の対象ROI。複数選択（グループ選択）があればそれを、無ければ単一選択を使う。
    private func selectedROIIDsForIndividualSettings() -> Set<UUID> {
        if !canvas.selectedROIGroupIDs.isEmpty { return canvas.selectedROIGroupIDs }
        if let id = canvas.selectedROIID { return [id] }
        return []
    }

    /// マスク生成方式としきい値から実際のエンジンを作る。全体設定・ROI個別設定の双方から使う。
    private func makeSegmentEngine(kind: SegmentEngineKind, threshold: Double) -> Segmenting {
        Self.makeSegmentEngine(kind: kind, threshold: threshold)
    }

    nonisolated private static func makeSegmentEngine(kind: SegmentEngineKind, threshold: Double) -> Segmenting {
        switch kind {
        case .shape: return ShapeSegmentEngine()
        case .visionPersonSegmentation: return VisionPersonSegmentEngine()
        case .foregroundObjects: return ForegroundSegmentEngine()
        case .regionForeground: return RegionForegroundSegmentEngine(maskThreshold: threshold)
        case .learnedShape: return LearnedShapeSegmentEngine()
        case .samShape: return SAMSegmentEngine()
        }
    }

    nonisolated private static func videoPlaybackSegmentEngine() -> VideoPlaybackSegmentEngine {
        VideoPlaybackSegmentEngine { rawValue, threshold in
            guard let kind = SegmentEngineKind(rawValue: rawValue) else { return ShapeSegmentEngine() }
            return Self.makeSegmentEngine(kind: kind, threshold: threshold ?? 0)
        }
    }

    /// 解析1回分の診断をデバッグログへ残す。
    ///
    /// GUI報告の切り分けを推測ではなく事実で行うため（ユーザー要望 2026-07-31）。
    /// 「どの画像に対して・どの設定で・何が出たか」を揃えて残す。
    /// 記録するのはファイル名・MD5・画素サイズ・設定・ROI情報のみで、フルパスと画像内容は残さない。
    private func logAnalysisDiagnostics(
        rois: [MosaicROI],
        sourceImage: CGImage,
        output: CandidateGenerationOutput,
        checkedCategories: Set<MosaicTargetCategory>
    ) {
        let url = loadedImage?.url
        let lines = AnalysisDiagnostics.report(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            fileName: url?.lastPathComponent ?? "unknown",
            md5: url.flatMap { AnalysisDiagnostics.md5Hex(ofFileAt: $0) },
            imageSize: CGSize(width: sourceImage.width, height: sourceImage.height),
            domain: String(describing: output.domain),
            confidenceThreshold: AnimeCensorDetector.defaultConfidenceThreshold,
            maskEngine: currentSegmentEngineKind().rawValue,
            enabledCategories: Array(checkedCategories),
            rois: rois
        )
        // `.notice` にするのは、`.info` より確実にログストアへ残るため
        // （報告時に添付してもらう前提の記録なので取りこぼしを避ける）。
        for line in lines {
            AppLog.analysis.notice("\(line, privacy: .public)")
        }
    }

    /// インスペクタで選択中のマスク生成方式。
    private func currentSegmentEngineKind() -> SegmentEngineKind {
        let index = segmentEngineControl.indexOfSelectedItem
        let kinds = Self.selectableEngineKinds
        guard index >= 0, index < kinds.count else { return .shape }
        return kinds[index]
    }

    private func currentSegmentEngine() -> Segmenting {
        let index = segmentEngineControl.indexOfSelectedItem
        let kinds = Self.selectableEngineKinds
        var base: Segmenting
        if index >= 0, index < kinds.count {
            base = makeSegmentEngine(kind: kinds[index], threshold: maskThresholdSlider.doubleValue)
        } else {
            base = ShapeSegmentEngine()
        }
        // 個別のマスク生成設定を持つROIは、全体設定ではなくそのROIの設定でマスクを作る
        base = PerROISegmentEngine(base: base) { rawValue, threshold in
            guard let kind = SegmentEngineKind(rawValue: rawValue) else { return ShapeSegmentEngine() }
            return Self.makeSegmentEngine(kind: kind, threshold: threshold ?? 0)
        }
        // 人物レイヤ由来のROIは、選択中のマスク生成方式に関係なく候補生成時の人物シルエットで
        // マスクする（「人物矩形全体がモザイクされてしまう」報告への修正。人物の輪郭に沿った
        // モザイクにする）。
        return PersonLayerSegmentEngine(base: base, personMasks: personMaskImages)
    }

    @objc private func applyMosaic() {
        guard let loadedImage else {
            updateStatus("先に画像を開いてください")
            return
        }
        if let item = currentLibraryItem, item.isVideo {
            let persistedROIs = videoROIsForKeyframePersistence()
            do {
                let output = try mosaicEngine.applyMosaic(
                    to: loadedImage.cgImage,
                    rois: persistedROIs,
                    style: defaultMosaicStyleForRendering(),
                    segmentEngine: currentSegmentEngine(),
                    patternImageProvider: { [weak self] in self?.patternImage(for: $0) }
                )
                currentVideoEditState.upsertKeyframe(
                    VideoKeyframe(
                        timeSeconds: currentVideoTimeSeconds,
                        rois: persistedROIs,
                        trackingStatus: currentVideoKeyframeTrackingStatus()
                    )
                )
                lastTrackedVideoTimeSeconds = nil
                try videoEditStore.save(currentVideoEditState, for: item.id)
                canvas.rois = persistedROIs
                renderedImage = output
                canvas.setImage(output)
                mosaicPreviewCheckbox.state = .on
                hasUnsavedChanges = false
                updateVideoTimelineLabels()
                reloadLayerList()
                updateStatsBar()
                updateStatus(
                    "動画キーフレームへモザイク設定を保存: \(VideoPreviewView.timeText(currentVideoTimeSeconds))"
                    + "（ROI \(persistedROIs.count)件）"
                )
            } catch {
                showError(error)
            }
            return
        }
        let previousState = currentEditorState()
        do {
            let output = try mosaicEngine.applyMosaic(
                to: loadedImage.cgImage,
                rois: canvas.rois,
                style: defaultMosaicStyleForRendering(),
                segmentEngine: currentSegmentEngine(),
                patternImageProvider: { [weak self] in self?.patternImage(for: $0) }
            )
            pushUndoSnapshot(previousState)
            renderedImage = output
            canvas.setImage(output)
            mosaicPreviewCheckbox.state = .on
            if let item = currentLibraryItem {
                currentLibraryItem = try libraryEngine.saveProcessedImage(output, rois: canvas.rois, for: item.id)
                hasUnsavedChanges = false
                recordLearningSamples()
                reloadLibrary()
            }
            updateStatus("モザイク適用済み: ROI \(canvas.rois.count)件（「モザイク表示」で解除/再適用を切替できます）")
        } catch {
            showError(error)
        }
    }

    /// ツールバー「全レイヤ削除」: ROIだけでなく人物/骨格検出レイヤも含めた全レイヤを削除する
    /// （従来はROIのみクリアで「すべてのレイヤが削除されない」と報告があった）。
    @objc private func clearROIs() {
        let hasDetectionLayers = !canvas.personLayerRects.isEmpty || !canvas.poseLayerRects.isEmpty
        guard !canvas.rois.isEmpty || hasDetectionLayers else { return }
        pushUndoSnapshot(currentEditorState())
        suspendMosaicPreview()
        canvas.rois = []
        canvas.selectedROIID = nil
        canvas.selectedROIGroupIDs = []
        canvas.selectedDetectionLayer = nil
        canvas.personLayerRects = []
        canvas.poseLayerRects = []
        canvas.personLayerMasks = []
        personMaskImages = []
        canvas.poseLayerBones = []
        canvas.poseLayerJointPoints = []
        rebuildDetectionLayers(personCount: 0, poseAvailability: [])
        applyLayerVisibility()
        resumeMosaicPreviewIfNeeded()
        updateStatus("すべてのレイヤを削除しました（人物・骨格レイヤは元に戻す対象外）")
    }

    @objc private func performUndo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentEditorState())
        applyEditorState(previous)
        hasUnsavedChanges = true
        editorRevision += 1
        updateUndoRedoAvailability()
        updateStatus("元に戻しました: ROI \(canvas.rois.count)件")
    }

    @objc private func performRedo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentEditorState())
        applyEditorState(next)
        hasUnsavedChanges = true
        editorRevision += 1
        updateUndoRedoAvailability()
        updateStatus("やり直しました: ROI \(canvas.rois.count)件")
    }

    private func currentEditorState() -> EditorState {
        EditorState(rois: canvas.rois)
    }

    private func applyEditorState(_ state: EditorState) {
        canvas.rois = state.rois
        guard let loadedImage else { return }
        // 描画済み画像はスタックに持たないのでROIから作り直す。
        // モザイク表示OFFでも `renderedImage` は画像出力・ライブラリ保存が参照するため
        // （`exportImage()` / `performLibraryAutoSave()`）、表示の有無にかかわらず更新する。
        // ここで未描画のままにすると、元に戻した直後の出力が無修正になり検閲漏れになる。
        do {
            renderedImage = try renderMosaicOutput(for: state.rois)
        } catch {
            renderedImage = nil
            showError(error)
        }
        // 「モザイク表示」チェックはユーザー操作でのみ変わる。チェック状態に合わせて表示を復元する。
        if mosaicPreviewCheckbox.state == .on {
            canvas.setImage(renderedImage ?? loadedImage.cgImage)
        } else {
            canvas.setImage(loadedImage.cgImage)
        }
    }

    /// 「元に戻す」の保持段数。1段はROI配列のみ（数KB）なので大きめに取れる。
    private static let undoHistoryLimit = 100

    private func pushUndoSnapshot(_ state: EditorState) {
        undoStack.append(state)
        if undoStack.count > Self.undoHistoryLimit {
            undoStack.removeFirst(undoStack.count - Self.undoHistoryLimit)
        }
        redoStack.removeAll()
        hasUnsavedChanges = true
        editorRevision += 1
        updateUndoRedoAvailability()
    }

    private func resetUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateUndoRedoAvailability()
    }

    private func updateUndoRedoAvailability() {
        undoButton.isEnabled = !undoStack.isEmpty
        redoButton.isEnabled = !redoStack.isEmpty
        updateImageActionAvailability()
    }

    /// 画像を開いていない状態では、画像に対する操作（候補生成・モザイク適用・全レイヤ削除）を無効化する。
    /// 従来は押せてしまい、「先に画像を開いてください」というエラーで初めて分かる作りだった。
    private func updateImageActionAvailability() {
        let hasImage = loadedImage != nil
        for button in imageDependentToolbarButtons {
            button.isEnabled = hasImage
        }
    }

    @objc private func exportImage() {
        guard let loadedImage else {
            updateStatus("画像出力する画像がありません")
            return
        }
        exportSourceImage = renderedImage ?? loadedImage.cgImage
        exportOriginalImage = loadedImage.cgImage
        exportSourceName = loadedImage.url.deletingPathExtension().lastPathComponent
        showExportWindow()
    }

    /// 「画像出力」完了処理: 元のexportImage()が担っていたライブラリ保存・履歴記録・
    /// 学習サンプル記録を、新しい画像出力ウィンドウからの書き出し後にも同様に行う。
    private func finalizeExport(image: CGImage, url: URL) {
        do {
            let historyURL = try defaultHistoryURL()
            let entry = MosaicHistoryEntry(
                imageName: url.lastPathComponent,
                imagePixelWidth: image.width,
                imagePixelHeight: image.height,
                rois: canvas.rois
            )
            try historyEngine.append(entry, to: historyURL)
            if let item = currentLibraryItem {
                currentLibraryItem = try libraryEngine.saveProcessedImage(image, rois: canvas.rois, for: item.id)
                hasUnsavedChanges = false
                recordLearningSamples()
                reloadLibrary()
            }
            updateStatus("画像出力しました: \(url.lastPathComponent)")
        } catch {
            showError(error)
        }
    }

    /// 「ライブラリ更新」ボタン: 明示操作なので最新の並び（更新日時降順）で再読込する。
    @objc private func reloadLibraryFromButton() {
        reloadLibrary(preserveOrder: false)
    }

    @objc private func reloadLibrary() {
        reloadLibrary(preserveOrder: true)
    }

    private func reloadLibrary(preserveOrder: Bool) {
        do {
            let loaded = try libraryEngine.loadItems()
            // アイテムの集合が変わらない再読込（自動保存・上書き保存など）では現在の表示順を維持する。
            // 並びは updatedAt 降順のため、従来はカーソルキー移動中の自動保存のたびに
            // 一覧の並びが変わり、ブラウズ順が崩れていた（既知の注意点への対応）。
            let currentIDs = libraryItems.map(\.id)
            if preserveOrder, !currentIDs.isEmpty, Set(currentIDs) == Set(loaded.map(\.id)) {
                let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
                libraryItems = currentIDs.compactMap { byID[$0] }
            } else {
                libraryItems = loaded
            }
            pruneThumbnailCache()
            tableView.reloadData()
            collectionView.reloadData()
            updateStatsBar()
        } catch {
            showError(error)
        }
    }

    @objc private func revealLibrary() {
        NSWorkspace.shared.activateFileViewerSelecting([libraryEngine.rootURL])
    }

    private func makeLibraryPanel() -> NSView {
        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "ライブラリ")
        applyScaledFont(title, size: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        viewModeControl.selectedSegment = libraryViewMode.rawValue
        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeChanged)
        viewModeControl.translatesAutoresizingMaskIntoConstraints = false
        applyScaledFont(viewModeControl, size: 12)

        thumbnailSizeSlider.target = self
        thumbnailSizeSlider.action = #selector(thumbnailSizeChanged)
        thumbnailSizeSlider.translatesAutoresizingMaskIntoConstraints = false
        thumbnailSizeSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true

        // サムネイルの拡大縮小は虫めがねボタンで段階調整（スライダーは内部の値保持として維持）。
        // キャンバスのズームボタンと同じ`configureToolbarButton`経路で構築し、見た目のサイズや
        // 詳細設定「アイコンサイズ」への追従を統一する（従来は独自のtexturedRoundedベゼルで
        // サイズが揃っていなかった）。
        configureToolbarButton(thumbSmallerButton, symbol: "minus.magnifyingglass", help: "サムネイルを縮小", action: #selector(thumbnailSizeStepDown), compactPanelChrome: true)
        configureToolbarButton(thumbLargerButton, symbol: "plus.magnifyingglass", help: "サムネイルを拡大", action: #selector(thumbnailSizeStepUp), compactPanelChrome: true)
        // 「ライブラリを更新」はツールバーから、ライブラリパネルの拡大縮小アイコンの右へ移設。
        let reloadLibraryButton = shortcutToolbarButton("reloadLibraryFromButton", symbol: "arrow.clockwise", compactPanelChrome: true)
        let modeRow = NSStackView(views: [viewModeControl, thumbSmallerButton, thumbLargerButton, reloadLibraryButton])
        modeRow.orientation = .horizontal
        modeRow.spacing = 8
        modeRow.translatesAutoresizingMaskIntoConstraints = false

        // 処理済みフラグフィルタ・テキスト検索フィルタ（タブ切替コントロールの下に配置）
        libraryProcessedFilterControl.selectedSegment = libraryProcessedFilter.rawValue
        libraryProcessedFilterControl.target = self
        libraryProcessedFilterControl.action = #selector(libraryFilterChanged)
        libraryProcessedFilterControl.toolTip = "処理済みフラグで絞り込む"
        applyScaledFont(libraryProcessedFilterControl, size: 11)
        configureToolbarButton(
            libraryMediaFilterButton,
            symbol: "line.3.horizontal.decrease.circle",
            help: "種別・ファイル形式で絞り込む",
            action: #selector(showLibraryMediaFilterMenu(_:)),
            compactPanelChrome: true
        )
        librarySearchField.placeholderString = "ファイル名で検索"
        librarySearchField.target = self
        librarySearchField.action = #selector(librarySearchChanged)
        librarySearchField.translatesAutoresizingMaskIntoConstraints = false
        librarySearchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        // 行の余白を検索欄が吸収するようにする（絞り込みコントロールは固有幅のまま）
        librarySearchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        librarySearchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        libraryProcessedFilterControl.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        applyScaledFont(librarySearchField, size: 12)
        let filterRow = NSStackView(views: [libraryProcessedFilterControl, libraryMediaFilterButton, librarySearchField])
        filterRow.orientation = .horizontal
        filterRow.spacing = 8
        filterRow.translatesAutoresizingMaskIntoConstraints = false

        libraryScrollView.hasVerticalScroller = true
        libraryScrollView.translatesAutoresizingMaskIntoConstraints = false

        // リスト表示（テキスト/サムネイル）は項目を横一列に並べた列テーブルとし、
        // 列見出しクリックでソートできるようにする（サムネイル列はサムネイル表示モードのみ使用）。
        tableView.headerView = NSTableHeaderView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelectedLibraryOriginal)
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        libraryThumbnailColumn = makeLibraryColumn(id: "thumbnail", title: "", width: 44, sortKey: nil)
        libraryNameColumn = makeLibraryColumn(id: "name", title: "ファイル名", width: 160, sortKey: .name)
        libraryStatusColumn = makeLibraryColumn(id: "status", title: "状態", width: 60, sortKey: .status)
        libraryKindColumn = makeLibraryColumn(id: "kind", title: "種別", width: 58, sortKey: .kind)
        libraryResolutionColumn = makeLibraryColumn(id: "resolution", title: "解像度", width: 90, sortKey: .resolution)
        libraryROIColumn = makeLibraryColumn(id: "roi", title: "ROI", width: 40, sortKey: .roiCount)
        libraryUpdatedColumn = makeLibraryColumn(id: "updated", title: "更新日時", width: 120, sortKey: .updatedAt)
        for column in [libraryThumbnailColumn, libraryNameColumn, libraryStatusColumn,
                       libraryKindColumn, libraryResolutionColumn, libraryROIColumn, libraryUpdatedColumn] {
            tableView.addTableColumn(column)
        }
        // 既定ソート（更新日時の新しい順）に合わせた初期インジケータを表示する
        tableView.sortDescriptors = [NSSortDescriptor(key: LibrarySortKey.updatedAt.rawValue, ascending: false)]

        configureCollectionView()
        libraryScrollView.documentView = libraryViewMode == .thumbnailGrid ? collectionView : tableView

        let openOriginalButton = shortcutToolbarButton("openSelectedLibraryOriginal", symbol: "photo", compactPanelChrome: true)
        let openProcessedButton = shortcutToolbarButton("openSelectedLibraryProcessed", symbol: "photo.badge.checkmark", compactPanelChrome: true)
        let deleteButton = shortcutToolbarButton("deleteSelectedLibraryItems", symbol: "trash", compactPanelChrome: true)
        let exportButton = shortcutToolbarButton("exportTrainingDataset", symbol: "shippingbox", compactPanelChrome: true)
        // ライブラリ関連の操作はツールバーからライブラリパネルへ集約（ユーザー指定の配置）。
        // 並び: 元画像/加工後を開く → リンク切れ修正 → 画像出力 → Finderで表示 → データセット
        // → 削除（削除は誤操作を避けるため行末尾）。
        let repairLinksButton = shortcutToolbarButton("repairBrokenLinksAction", symbol: "link.badge.plus", compactPanelChrome: true)
        let saveButton = shortcutToolbarButton("exportImage", symbol: "square.and.arrow.down", compactPanelChrome: true)
        let revealButton = shortcutToolbarButton("revealLibrary", symbol: "finder", compactPanelChrome: true)
        let previewVideoButton = shortcutToolbarButton("previewSelectedVideo", symbol: "play.rectangle", compactPanelChrome: true)
        let buttons = WrappingToolbarView(groups: [
            [openOriginalButton, openProcessedButton, previewVideoButton],
            [repairLinksButton, saveButton, revealButton],
            [exportButton, deleteButton]
        ])

        panel.addSubview(title)
        panel.addSubview(modeRow)
        panel.addSubview(filterRow)
        panel.addSubview(libraryScrollView)
        panel.addSubview(buttons)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            modeRow.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            modeRow.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            modeRow.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -8),
            filterRow.topAnchor.constraint(equalTo: modeRow.bottomAnchor, constant: 6),
            filterRow.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            // 検索欄をパネル幅へ追従させる。`lessThanOrEqualTo` だと行が縮んだままで
            // サイドパネルを広げても検索欄が伸びなかった（GUI報告 2026-08-03）。
            filterRow.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            // 一覧が潰れきると、上のフィルタ行と下のアイコン行が重なる（GUI報告 2026-07-31）。
            // 最小高さを与えて、パネル全体の最小高さが内容から決まるようにする。
            libraryScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            libraryScrollView.topAnchor.constraint(equalTo: filterRow.bottomAnchor, constant: 8),
            libraryScrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            libraryScrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            buttons.topAnchor.constraint(equalTo: libraryScrollView.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            buttons.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            buttons.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8)
        ])
        updateLibraryModeVisibility()
        return panel
    }

    /// ソート対応の列を1つ構築する。`sortKey` がnilの列（サムネイル）はソート不可。
    private func makeLibraryColumn(id: String, title: String, width: CGFloat, sortKey: LibrarySortKey?) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = max(30, width * 0.6)
        if let sortKey {
            column.sortDescriptorPrototype = NSSortDescriptor(key: sortKey.rawValue, ascending: true)
        }
        return column
    }

    private static func libraryFileFormat(for item: MosaicLibraryItem) -> String {
        let sourceNameExtension = (item.sourceName as NSString).pathExtension
        let source = sourceNameExtension.isEmpty
            ? (item.linkedOriginalPath ?? item.originalRelativePath)
            : item.sourceName
        let ext = (source as NSString).pathExtension.lowercased()
        if !ext.isEmpty { return ext }
        return item.isVideo ? "video" : "image"
    }

    private var availableLibraryFormats: [String] {
        Array(Set(libraryItems.map { Self.libraryFileFormat(for: $0) }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    @objc private func showLibraryMediaFilterMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let kindHeader = NSMenuItem(title: "種別", action: nil, keyEquivalent: "")
        kindHeader.isEnabled = false
        menu.addItem(kindHeader)
        for kind in LibraryKindFilter.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(selectLibraryKindFilter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.state = kind == libraryKindFilter ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let formatHeader = NSMenuItem(title: "ファイル形式", action: nil, keyEquivalent: "")
        formatHeader.isEnabled = false
        menu.addItem(formatHeader)
        let allFormats = NSMenuItem(title: "すべて", action: #selector(selectLibraryFormatFilter(_:)), keyEquivalent: "")
        allFormats.target = self
        allFormats.representedObject = ""
        allFormats.state = libraryFormatFilter == nil ? .on : .off
        menu.addItem(allFormats)
        for format in availableLibraryFormats {
            let item = NSMenuItem(title: format.uppercased(), action: #selector(selectLibraryFormatFilter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = format
            item.state = libraryFormatFilter == format ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func selectLibraryKindFilter(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let filter = LibraryKindFilter(rawValue: rawValue) else { return }
        libraryKindFilter = filter
        refreshLibraryDisplay()
        updateStatus("ライブラリ種別フィルタ: \(filter.title)")
    }

    @objc private func selectLibraryFormatFilter(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        libraryFormatFilter = value.isEmpty ? nil : value
        refreshLibraryDisplay()
        updateStatus("ライブラリ形式フィルタ: \(libraryFormatFilter?.uppercased() ?? "すべて")")
    }

    @objc private func libraryFilterChanged() {
        guard let filter = LibraryProcessedFilter(rawValue: libraryProcessedFilterControl.selectedSegment) else { return }
        libraryProcessedFilter = filter
        refreshLibraryDisplay()
    }

    @objc private func librarySearchChanged() {
        librarySearchText = librarySearchField.stringValue
        refreshLibraryDisplay()
    }

    /// フィルタ・検索・ソート条件の変更後に一覧を再描画する（選択状態は可能な範囲で維持する）。
    private func refreshLibraryDisplay() {
        let previousSelectedID = selectedLibraryItemID
        tableView.reloadData()
        collectionView.reloadData()
        if !displayedLibraryItems.isEmpty {
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<displayedLibraryItems.count))
        }
        if let previousSelectedID, let item = displayedLibraryItems.first(where: { $0.id == previousSelectedID }) {
            selectLibraryItemInUI(item)
        }
        updateStatsBar()
    }

    /// ライブラリのアノテーション（元画像+保存済みROI）をYOLO形式でエクスポートする。
    /// 出力先はユーザーがフォルダ選択。以後のモザイク作業がそのまま学習データになる。
    @objc private func exportTrainingDataset() {
        let annotated = libraryItems.filter { !$0.rois.isEmpty }
        guard !annotated.isEmpty else {
            updateStatus("エクスポート対象がありません（ROIを保存した画像が必要です）")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "エクスポート"
        panel.message = "YOLO形式データセットの出力先フォルダを選択してください"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try YOLODatasetExporter.export(items: annotated, libraryEngine: libraryEngine, to: url)
            updateStatus("学習用データセットを書き出しました: 画像\(result.imageCount)件 / ROI \(result.roiCount)件")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            showError(error)
        }
    }

    /// 形状モデル（学習モデル形状）用に、手描き多角形ROIの輪郭をYOLOセグメンテーション形式で書き出す。
    /// 楕円・矩形ROIは形状学習に有害（楕円を出力するモデルが育つ）ため既定で除外される。
    /// 手順の詳細は Docs/FINETUNE_GUIDE.md「部位セグメンテーション（形状）モデルの学習」を参照。
    @objc private func exportShapeTrainingDataset() {
        let annotated = libraryItems.filter { item in
            item.rois.contains { $0.shape == .polygon && $0.polygonPoints != nil }
        }
        guard !annotated.isEmpty else {
            updateStatus(
                "形状学習用の対象がありません。選択範囲の形状を「多角形」にして頂点を輪郭へ沿わせ、保存してください"
            )
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "エクスポート"
        panel.message = "形状学習用データセット（YOLOセグメンテーション形式）の出力先フォルダを選択してください"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try YOLOSegDatasetExporter.export(
                items: annotated,
                libraryEngine: libraryEngine,
                to: url
            )
            updateStatus(
                "形状学習用データセットを書き出しました: 画像\(result.imageCount)件 / 輪郭\(result.polygonCount)件"
                + "（形状なしのため除外 \(result.skippedCount)件）"
            )
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            showError(error)
        }
    }

    private func configureCollectionView() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = libraryGridItemSize(CGFloat(thumbnailSizeSlider.doubleValue))
        layout.minimumInteritemSpacing = 5
        layout.minimumLineSpacing = 3
        layout.sectionInset = NSEdgeInsets(top: 4, left: 5, bottom: 4, right: 5)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(LibraryGridItem.self, forItemWithIdentifier: LibraryGridItem.identifier)
        let doubleClickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(collectionViewDoubleClicked(_:)))
        doubleClickRecognizer.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClickRecognizer)
    }

    @objc private func collectionViewDoubleClicked(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point), indexPath.item < displayedLibraryItems.count else { return }
        selectedLibraryItemID = displayedLibraryItems[indexPath.item].id
        openSelectedLibraryOriginal()
    }

    @objc private func viewModeChanged() {
        guard let mode = LibraryViewMode(rawValue: viewModeControl.selectedSegment) else { return }
        libraryViewMode = mode
        AppSettings.shared.set(mode.rawValue, forKey: "LibraryView.mode")
        updateLibraryModeVisibility()
    }

    /// 虫めがねボタンによるサムネイルサイズの段階調整（±24px、64〜220の範囲）。
    @objc private func thumbnailSizeStepDown() {
        thumbnailSizeSlider.doubleValue = max(64, thumbnailSizeSlider.doubleValue - 24)
        thumbnailSizeChanged()
    }

    @objc private func thumbnailSizeStepUp() {
        thumbnailSizeSlider.doubleValue = min(220, thumbnailSizeSlider.doubleValue + 24)
        thumbnailSizeChanged()
    }

    @objc private func thumbnailSizeChanged() {
        guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let size = CGFloat(thumbnailSizeSlider.doubleValue)
        layout.itemSize = libraryGridItemSize(size)
        AppSettings.shared.set(Double(size), forKey: "LibraryView.thumbnailSize")
        layout.invalidateLayout()
    }

    private func libraryGridItemSize(_ width: CGFloat) -> NSSize {
        NSSize(width: width, height: max(54, (width - 8) * 0.75 + 24))
    }

    private func loadLibraryViewPreferences() {
        let defaults = AppSettings.shared
        if let mode = LibraryViewMode(rawValue: defaults.integer(forKey: "LibraryView.mode")) {
            libraryViewMode = mode
        }
        if defaults.object(forKey: "LibraryView.thumbnailSize") != nil {
            thumbnailSizeSlider.doubleValue = min(220, max(64, defaults.double(forKey: "LibraryView.thumbnailSize")))
        }
    }

    private func updateLibraryModeVisibility() {
        thumbnailSizeSlider.isHidden = libraryViewMode != .thumbnailGrid
        thumbSmallerButton.isEnabled = libraryViewMode == .thumbnailGrid
        thumbLargerButton.isEnabled = libraryViewMode == .thumbnailGrid
        libraryThumbnailColumn.isHidden = libraryViewMode != .thumbnailList
        switch libraryViewMode {
        case .thumbnailGrid:
            libraryScrollView.documentView = collectionView
            collectionView.reloadData()
        case .textList, .thumbnailList:
            libraryScrollView.documentView = tableView
            tableView.reloadData()
            if !displayedLibraryItems.isEmpty {
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<displayedLibraryItems.count))
            }
        }
    }

    private static let libraryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yy/MM/dd HH:mm"
        return formatter
    }()

    private func pruneThumbnailCache() {
        let currentIDs = Set(libraryItems.map(\.id))
        thumbnailCache = thumbnailCache.filter { currentIDs.contains($0.key) }
        thumbnailCacheUpdatedAt = thumbnailCacheUpdatedAt.filter { currentIDs.contains($0.key) }
    }

    private func thumbnail(for item: MosaicLibraryItem, maxDimension: CGFloat = 240) -> NSImage {
        if let cached = thumbnailCache[item.id], thumbnailCacheUpdatedAt[item.id] == item.updatedAt {
            thumbnailCacheOrder.removeAll { $0 == item.id }
            thumbnailCacheOrder.append(item.id)
            return cached
        }
        let url = libraryEngine.processedURL(for: item) ?? libraryEngine.originalURL(for: item)
        let loaded: NSImage?
        if item.isVideo {
            // 動画は静止画として読めないため、代表フレームをサムネイルにする
            loaded = videoThumbnailProvider.thumbnail(for: url)
                .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        } else {
            loaded = NSImage(contentsOf: url)
        }
        guard let source = loaded, source.size.width > 0, source.size.height > 0 else {
            return NSImage(size: NSSize(width: maxDimension, height: maxDimension))
        }
        let size = source.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let targetSize = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let thumb = NSImage(size: targetSize)
        thumb.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1)
        thumb.unlockFocus()
        thumbnailCache[item.id] = thumb
        thumbnailCacheUpdatedAt[item.id] = item.updatedAt
        thumbnailCacheOrder.removeAll { $0 == item.id }
        thumbnailCacheOrder.append(item.id)
        while thumbnailCacheOrder.count > Self.thumbnailCacheLimit {
            let oldest = thumbnailCacheOrder.removeFirst()
            thumbnailCache.removeValue(forKey: oldest)
            thumbnailCacheUpdatedAt.removeValue(forKey: oldest)
        }
        return thumb
    }

    @objc private func openSelectedLibraryOriginal() {
        guard let item = selectedLibraryItem() else { return }
        if item.isVideo {
            openVideoForEditing(item)
            return
        }
        guard item.id == currentLibraryItem?.id || confirmCurrentChangesBeforeLeaving() else { return }
        loadLibraryImage(at: libraryEngine.originalURL(for: item), item: item, useProcessed: false)
    }

    @objc private func openSelectedLibraryProcessed() {
        guard let item = selectedLibraryItem(), let url = libraryEngine.processedURL(for: item) else {
            updateStatus("選択項目に加工後画像がありません")
            return
        }
        guard item.id == currentLibraryItem?.id || confirmCurrentChangesBeforeLeaving() else { return }
        loadLibraryImage(at: url, item: item, useProcessed: true)
    }

    private func selectedLibraryItem() -> MosaicLibraryItem? {
        switch libraryViewMode {
        case .thumbnailGrid:
            guard let id = selectedLibraryItemID else { return nil }
            return displayedLibraryItems.first { $0.id == id }
        case .textList, .thumbnailList:
            let row = tableView.selectedRow
            guard row >= 0, row < displayedLibraryItems.count else { return nil }
            return displayedLibraryItems[row]
        }
    }

    /// 現在の表示モードで選択中の全アイテムを返す（Shift=範囲選択 / Cmd=個別追加選択に対応）。
    private func selectedLibraryItems() -> [MosaicLibraryItem] {
        switch libraryViewMode {
        case .thumbnailGrid:
            return collectionView.selectionIndexPaths
                .map(\.item)
                .sorted()
                .compactMap { $0 < displayedLibraryItems.count ? displayedLibraryItems[$0] : nil }
        case .textList, .thumbnailList:
            return tableView.selectedRowIndexes.compactMap { $0 < displayedLibraryItems.count ? displayedLibraryItems[$0] : nil }
        }
    }

    /// 選択中の画像をライブラリから一括削除する（確認ダイアログあり。元画像・加工後画像とも完全削除）。
    /// ライブラリ項目の削除に合わせて、動画のキーフレーム編集状態（サイドカーJSON）も破棄する。
    private func deleteVideoEditStates(for items: [MosaicLibraryItem]) {
        for item in items where item.isVideo {
            videoEditStore.delete(for: item.id)
        }
    }

    /// v0.0.00135以前の貼り付け不具合で「ファイルのアイコン画像」として取り込まれてしまった
    /// 項目を探し、確認のうえまとめて削除する（残務対応 v0.0.00136）。
    ///
    /// 削除は取り消せないため、**候補の提示と確認を必ず挟む**。判定（`PastedIconImageDetector`）は
    /// 名前・寸法での事前絞り込み → 外周の一様性チェックの2段で、全件デコードは避ける。
    @objc private func cleanUpPastedIconImports() {
        let allItems: [MosaicLibraryItem]
        do {
            allItems = try libraryEngine.loadItems()
        } catch {
            showError(error)
            return
        }
        let items = allItems.filter { item in
            !item.isVideo && PastedIconImageDetector.isCandidateBySize(
                sourceName: item.sourceName,
                pixelWidth: item.imagePixelWidth,
                pixelHeight: item.imagePixelHeight
            )
        }
        let suspects = items.filter { item in
            guard let loaded = try? imageLoader.loadImage(from: libraryEngine.originalURL(for: item)) else {
                return false
            }
            return PastedIconImageDetector.hasUniformBorder(loaded.cgImage)
        }
        guard !suspects.isEmpty else {
            updateStatus("ファイルアイコンとして取り込まれた画像は見つかりませんでした")
            return
        }

        let names = suspects.prefix(10).map(\.sourceName).joined(separator: "\n")
        let more = suspects.count > 10 ? "\n…ほか\(suspects.count - 10)件" : ""
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ファイルアイコンとして取り込まれた疑いのある画像が\(suspects.count)件あります"
        alert.informativeText = """
        v0.0.00135以前は、Finderでコピーしたファイルを貼り付けると実体ではなく\
        ファイルのアイコン画像が取り込まれていました。その残りと思われる項目です。

        \(names)\(more)

        削除するとライブラリから完全に消えます。この操作は取り消せません。\
        判定は推定のため、必要な画像が含まれていないかご確認ください。
        """
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else {
            updateStatus("整理をキャンセルしました")
            return
        }

        do {
            try libraryEngine.deleteItems(ids: suspects.map(\.id))
            let deletedIDs = Set(suspects.map(\.id))
            for id in deletedIDs {
                imageEditStates[id] = nil
                imageEditStateOrder.removeAll { $0 == id }
                thumbnailCache[id] = nil
            }
            if let current = currentLibraryItem, deletedIDs.contains(current.id) {
                discardedEditStateID = nil
                currentLibraryItem = nil
                loadedImage = nil
                renderedImage = nil
                canvas.clearImage()
                canvas.rois = []
            }
            reloadLibrary()
            updateStatus("ファイルアイコンとして取り込まれた画像を\(suspects.count)件削除しました")
        } catch {
            showError(error)
        }
    }

    @objc private func deleteSelectedLibraryItems() {
        let items = selectedLibraryItems()
        guard !items.isEmpty else {
            updateStatus("削除する画像を選択してください（Shift/Cmd+クリックで複数選択できます）")
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "選択した\(items.count)件の画像を削除しますか？"
        alert.informativeText = "元画像と加工後画像がライブラリから完全に削除されます。この操作は取り消せません。"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let currentID = currentLibraryItem?.id,
           items.contains(where: { $0.id == currentID }),
           !confirmCurrentChangesBeforeLeaving() {
            return
        }

        do {
            try libraryEngine.deleteItems(ids: items.map(\.id))
            deleteVideoEditStates(for: items)
            let deletedIDs = Set(items.map(\.id))
            for id in deletedIDs {
                imageEditStates[id] = nil
                imageEditStateOrder.removeAll { $0 == id }
            }
            if let current = currentLibraryItem, deletedIDs.contains(current.id) {
                discardedEditStateID = nil
                currentLibraryItem = nil
                loadedImage = nil
                renderedImage = nil
                mosaicPreviewCheckbox.state = .off
                canvas.clearImage()
                canvas.rois = []
                canvas.personLayerRects = []
                canvas.poseLayerRects = []
                canvas.personLayerMasks = []
        personMaskImages = []
                canvas.poseLayerBones = []
                canvas.poseLayerJointPoints = []
                rebuildDetectionLayers(personCount: 0, poseAvailability: [])
                applyLayerVisibility()
                syncLegacyLayerCheckboxes()
                resetUndoHistory()
                hasUnsavedChanges = false
            }
            if let selectedID = selectedLibraryItemID, deletedIDs.contains(selectedID) {
                selectedLibraryItemID = nil
            }
            reloadLibrary()
            updateStatus("\(items.count)件の画像を削除しました")
        } catch {
            discardedEditStateID = nil
            showError(error)
        }
    }

    private func selectLibraryItemInUI(_ item: MosaicLibraryItem) {
        selectedLibraryItemID = item.id
        if let row = displayedLibraryItems.firstIndex(where: { $0.id == item.id }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            collectionView.selectionIndexPaths = [IndexPath(item: row, section: 0)]
            collectionView.scrollToItems(at: [IndexPath(item: row, section: 0)], scrollPosition: .nearestHorizontalEdge)
        }
    }

    /// カーソルキーでのライブラリ画像切替。自動保存の設定に応じて保存確認を行ってから切り替える。
    private func navigateLibrary(by delta: Int) {
        guard !displayedLibraryItems.isEmpty else { return }
        let currentIndex = currentLibraryItem.flatMap { current in displayedLibraryItems.firstIndex { $0.id == current.id } }
        let newIndex = (currentIndex ?? -1) + delta
        guard newIndex >= 0, newIndex < displayedLibraryItems.count else { return }
        requestLibrarySwitch(to: displayedLibraryItems[newIndex])
    }

    private func requestLibrarySwitch(to item: MosaicLibraryItem) {
        guard item.id != currentLibraryItem?.id else { return }
        guard confirmCurrentChangesBeforeLeaving() else { return }
        loadLibraryItemAsWorking(item)
    }

    fileprivate func confirmCurrentChangesBeforeLeaving() -> Bool {
        guard hasUnsavedChanges else { return true }
        if autoSaveCheckbox.state == .on {
            performLibraryAutoSave()
            return !hasUnsavedChanges
        }
        let alert = NSAlert()
        alert.messageText = "変更を保存しますか？"
        alert.informativeText = "現在の編集内容はまだ保存されていません。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "保存しない")
        alert.addButton(withTitle: "キャンセル")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            performLibraryAutoSave()
            return !hasUnsavedChanges
        case .alertSecondButtonReturn:
            discardedEditStateID = currentLibraryItem?.id
            if let id = discardedEditStateID {
                imageEditStates[id] = nil
                imageEditStateOrder.removeAll { $0 == id }
            }
            hasUnsavedChanges = false
            return true
        default:
            return false
        }
    }

    private func performLibraryAutoSave() {
        guard hasUnsavedChanges, let loadedImage, let item = currentLibraryItem else { return }
        if item.isVideo {
            currentVideoEditState.upsertKeyframe(
                VideoKeyframe(
                    timeSeconds: currentVideoTimeSeconds,
                    rois: videoROIsForKeyframePersistence(),
                    trackingStatus: currentVideoKeyframeTrackingStatus()
                )
            )
            lastTrackedVideoTimeSeconds = nil
            do {
                try videoEditStore.save(currentVideoEditState, for: item.id)
                hasUnsavedChanges = false
                updateVideoTimelineLabels()
                updateStatus("動画キーフレームを保存: \(VideoPreviewView.timeText(currentVideoTimeSeconds))")
            } catch {
                showError(error)
            }
            return
        }
        do {
            let output = renderedImage ?? loadedImage.cgImage
            currentLibraryItem = try libraryEngine.saveProcessedImage(output, rois: canvas.rois, for: item.id)
            hasUnsavedChanges = false
            recordLearningSamples()
            reloadLibrary()
        } catch {
            showError(error)
        }
    }

    /// 保存時に採用ROI（正例）と削除された自動候補（負例）を学習ストアへ記録する。
    /// 同一ROIの二重計上は `learnedROIIDs` で防ぐ。画像切替でリセットされる。
    private func recordLearningSamples() {
        guard isLearningModeEnabled else { return }
        guard let learningEngine, let loadedImage else { return }
        let accepted = canvas.rois.filter { !learnedROIIDs.contains($0.id) }
        let rejected = lastAutoROIs.filter { auto in
            !canvas.rois.contains { $0.id == auto.id } && !learnedROIIDs.contains(auto.id)
        }
        guard !accepted.isEmpty || !rejected.isEmpty else { return }
        _ = try? learningEngine.record(
            acceptedROIs: accepted,
            rejectedROIs: rejected,
            persons: lastPersonBounds,
            image: loadedImage.cgImage
        )
        for roi in accepted + rejected {
            learnedROIIDs.insert(roi.id)
        }
    }

    private func loadLibraryItemAsWorking(_ item: MosaicLibraryItem) {
        // 動画はキーフレーム編集モードで開く（V3。再生確認はライブラリの
        // 「動画をプレビュー再生」から別途行える）。
        if item.isVideo {
            openVideoForEditing(item)
            return
        }
        if let processedURL = libraryEngine.processedURL(for: item) {
            loadLibraryImage(at: processedURL, item: item, useProcessed: true)
        } else {
            loadLibraryImage(at: libraryEngine.originalURL(for: item), item: item, useProcessed: false)
        }
    }

    /// ライブラリ画像を作業対象として開く。作業画像は常に元画像とし、加工後表示は
    /// モザイク表示（renderedImage）側に読み込むことで、解除/再適用の切替と再編集を可能にする。
    private func loadLibraryImage(at url: URL, item: MosaicLibraryItem, useProcessed: Bool) {
        do {
            let originalURL = libraryEngine.originalURL(for: item)
            let original = try imageLoader.loadImage(from: originalURL)
            if item.id == currentLibraryItem?.id {
                selectLibraryItemInUI(item)
                if useProcessed {
                    let processed = try imageLoader.loadImage(from: url)
                    renderedImage = processed.cgImage
                    mosaicPreviewCheckbox.state = .on
                    canvas.setImage(processed.cgImage)
                } else {
                    renderedImage = nil
                    mosaicPreviewCheckbox.state = .off
                    canvas.setImage(original.cgImage)
                }
                editorRevision += 1
                updateStatus("\(useProcessed ? "加工後" : "元画像")を開きました: \(item.sourceName)")
                return
            }
            let restored = setWorkingImage(original.cgImage, sourceURL: originalURL, item: item)
            selectLibraryItemInUI(item)
            if restored {
                if useProcessed {
                    let processed = try imageLoader.loadImage(from: url)
                    renderedImage = processed.cgImage
                    mosaicPreviewCheckbox.state = .on
                    canvas.setImage(processed.cgImage)
                } else {
                    renderedImage = nil
                    mosaicPreviewCheckbox.state = .off
                    canvas.setImage(original.cgImage)
                }
                updateStatus("\(useProcessed ? "加工後" : "元画像")を開きました: \(item.sourceName)")
                return
            }

            canvas.rois = item.rois
            if useProcessed,
               let processedURL = libraryEngine.processedURL(for: item),
               let processed = try? imageLoader.loadImage(from: processedURL) {
                renderedImage = processed.cgImage
                mosaicPreviewCheckbox.state = .on
                canvas.setImage(processed.cgImage)
            }
            updateStatus("\(useProcessed ? "加工後" : "元画像")を開きました: \(item.sourceName)")
            if item.rois.isEmpty {
                autoGenerateIfEnabled()
            }
        } catch {
            discardedEditStateID = nil
            showError(error)
        }
    }

    private func autoGenerateIfEnabled() {
        guard autoGenerateCheckbox.state == .on else { return }
        generateCandidates()
    }

    /// 現在の画像の編集状態（ROI・検出レイヤ・アンドゥ履歴・モザイク表示）をセッション内キャッシュへ退避する。
    private func stashCurrentEditState() {
        guard let current = currentLibraryItem else { return }
        imageEditStates[current.id] = PerImageEditState(
            rois: canvas.rois,
            mosaicPreviewOn: mosaicPreviewCheckbox.state == .on,
            personLayerRects: canvas.personLayerRects,
            personLayerMasks: canvas.personLayerMasks,
            personMaskImages: personMaskImages,
            poseLayerRects: canvas.poseLayerRects,
            poseLayerBones: canvas.poseLayerBones,
            poseLayerJointPoints: canvas.poseLayerJointPoints,
            undoStack: undoStack,
            redoStack: redoStack,
            hasUnsavedChanges: hasUnsavedChanges,
            lastAutoROIs: lastAutoROIs,
            lastPersonBounds: lastPersonBounds,
            learnedROIIDs: learnedROIIDs
        )
        imageEditStateOrder.removeAll { $0 == current.id }
        imageEditStateOrder.append(current.id)
        while imageEditStateOrder.count > imageEditStateLimit {
            let evicted = imageEditStateOrder.removeFirst()
            imageEditStates[evicted] = nil
        }
    }

    /// 作業画像を切り替える。退避済みの編集状態があれば復元し true を返す。
    @discardableResult
    private func setWorkingImage(_ image: CGImage, sourceURL: URL, item: MosaicLibraryItem) -> Bool {
        // 静止画を開いたら動画編集モード（タイムライン表示）を終了する
        if !item.isVideo { exitVideoEditingMode() }
        editorRevision += 1
        if let currentID = currentLibraryItem?.id, discardedEditStateID == currentID {
            imageEditStates[currentID] = nil
            imageEditStateOrder.removeAll { $0 == currentID }
            discardedEditStateID = nil
        } else {
            stashCurrentEditState()
        }
        loadedImage = LoadedImage(url: sourceURL, cgImage: image)
        currentLibraryItem = item
        canvas.resetZoom()

        if let saved = imageEditStates[item.id] {
            canvas.rois = saved.rois
            // 描画済み画像は保持していないのでROIから作り直す。
            // 表示していなくても画像出力・ライブラリ保存が `renderedImage` を参照するため
            // 必ず更新する（未描画のまま出力すると検閲漏れになる）。
            renderedImage = (try? renderMosaicOutput(for: saved.rois)) ?? nil
            if saved.mosaicPreviewOn, let rendered = renderedImage {
                mosaicPreviewCheckbox.state = .on
                canvas.setImage(rendered)
            } else {
                mosaicPreviewCheckbox.state = .off
                canvas.setImage(image)
            }
            canvas.personLayerRects = saved.personLayerRects
            canvas.personLayerMasks = saved.personLayerMasks
            personMaskImages = saved.personMaskImages
            canvas.poseLayerRects = saved.poseLayerRects
            canvas.poseLayerBones = saved.poseLayerBones
            canvas.poseLayerJointPoints = saved.poseLayerJointPoints
            canvas.selectedROIID = nil
            undoStack = saved.undoStack
            redoStack = saved.redoStack
            hasUnsavedChanges = saved.hasUnsavedChanges
            lastAutoROIs = saved.lastAutoROIs
            lastPersonBounds = saved.lastPersonBounds
            learnedROIIDs = saved.learnedROIIDs
            rebuildDetectionLayers(
                personCount: saved.personLayerRects.count,
                poseAvailability: saved.poseLayerJointPoints.map { !$0.isEmpty }
            )
            applyLayerVisibility()
            syncLegacyLayerCheckboxes()
            updateUndoRedoAvailability()
            updateStatus("編集状態を復元しました: ROI \(saved.rois.count)件")
            return true
        }

        renderedImage = nil
        // 既定でモザイク表示ON（候補生成が終わり次第そのままモザイクが乗った状態で確認できる）
        mosaicPreviewCheckbox.state = mosaicPreviewDefaultOn ? .on : .off
        canvas.setImage(image)
        canvas.rois = []
        canvas.personLayerRects = []
        canvas.poseLayerRects = []
        canvas.personLayerMasks = []
        personMaskImages = []
        canvas.poseLayerBones = []
        canvas.poseLayerJointPoints = []
        canvas.selectedROIID = nil
        rebuildDetectionLayers(personCount: 0, poseAvailability: [])
        applyLayerVisibility()
        syncLegacyLayerCheckboxes()
        resetUndoHistory()
        hasUnsavedChanges = false
        lastAutoROIs = []
        lastPersonBounds = []
        learnedROIIDs = []
        return false
    }

    private func defaultHistoryURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("newMosaic/history.jsonl")
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private func updateStatus(_ message: String) {
        lastStatusText = message
        statusLabel.stringValue = message
        updateStatsBar()
    }

    private func updateAnalysisStopButtonVisibility() {
        analysisStopButton.isHidden = !(isGeneratingCandidates || isAutoProcessingVideo)
        analysisStopButton.isEnabled = isGeneratingCandidates || isAutoProcessingVideo
    }

    @objc private func stopCurrentAnalysis() {
        var didRequestStop = false
        if isAutoProcessingVideo {
            videoAutoProcessCancellation?.isCancelled = true
            didRequestStop = true
        }
        if isGeneratingCandidates, let candidateGenerationID {
            cancelledCandidateGenerationIDs.insert(candidateGenerationID)
            didRequestStop = true
        }
        updateStatus(didRequestStop ? "解析停止を要求しました。現在のステップ完了後に停止します" : "実行中の解析はありません")
        updateAnalysisStopButtonVisibility()
    }

    /// ツールバーホバー時のヘルプ表示（離れたら直前のステータスへ戻す）。
    private func showHoverHelp(_ text: String?) {
        statusLabel.stringValue = text ?? lastStatusText
    }

    /// ステータスバー右端の統計（選択数/全画像数・解像度・色ビット数・ROI数）を更新する。
    private func updateStatsBar() {
        let total = displayedLibraryItems.count
        let selected: Int
        if libraryViewMode == .thumbnailGrid {
            selected = collectionView.selectionIndexPaths.count
        } else {
            selected = tableView.selectedRowIndexes.count
        }
        var parts = ["画像 \(selected)/\(total)"]
        if let image = loadedImage?.cgImage {
            parts.append("\(image.width)×\(image.height)  \(image.bitsPerPixel)bit")
        }
        parts.append("ROI \(canvas.rois.count)")
        if let selectedLayerStatusSummary {
            parts.append(selectedLayerStatusSummary)
        }
        statsLabel.stringValue = parts.joined(separator: "   |   ")
    }

    private func showError(_ error: Error) {
        AppLog.ui.error("showError: \(error.localizedDescription, privacy: .public)")
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}

extension MosaicWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 補助ウィンドウ（動画プレビュー・詳細設定・各種一覧）は編集を持たないので、
        // 保存確認なしで閉じてよい。主ウィンドウと同じdelegateを共有しているため明示的に分ける。
        guard !isAuxiliaryWindow(sender) else { return true }
        return confirmCurrentChangesBeforeLeaving()
    }

    /// 補助ウィンドウが閉じられたときの後始末。
    ///
    /// 保持している参照を解放して、次に開くときは作り直させる。
    /// これをしないと閉じたウィンドウを使い回そうとして、内容が古いまま表示されたり、
    /// `isReleasedWhenClosed` と相まって解放済みメモリへメッセージが飛んだりする
    /// （クラッシュ報告 2026-08-02「キー割当後、再度設定画面が開けない」）。
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        finishVideoPreviewIfNeeded(window)
        releaseAuxiliaryWindowReference(window)
        // 主ウィンドウを閉じたら、開いたままの補助ウィンドウも閉じる。
        // 残しておくと本体が終了できず、画面にウィンドウだけ取り残される
        // （ユーザー要望 2026-08-02）。
        if !isAuxiliaryWindow(window) {
            if let videoShortcutEventMonitor {
                NSEvent.removeMonitor(videoShortcutEventMonitor)
                self.videoShortcutEventMonitor = nil
            }
            if let numpadEventMonitor {
                NSEvent.removeMonitor(numpadEventMonitor)
                self.numpadEventMonitor = nil
            }
            closeAllAuxiliaryWindows()
        }
    }

    /// ウィンドウ枠（位置・サイズ）をポータブル設定へ保存する。
    func windowDidEndLiveResize(_ notification: Notification) {
        saveWindowFrame(notification)
    }

    /// ズーム（緑ボタン/タイトルバーのダブルクリック）やフルスクリーン復帰など、
    /// ドラッグを伴わないサイズ変更では`windowDidEndLiveResize`が発火しないため、
    /// `windowDidResize`でも保存する（AppSettings側で0.3秒デバウンスされる）。
    func windowDidResize(_ notification: Notification) {
        saveWindowFrame(notification)
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowFrame(notification)
    }

    private func saveWindowFrame(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // 補助ウィンドウの枠を主ウィンドウの設定へ書き込まないようにする
        guard !isAuxiliaryWindow(window) else { return }
        AppSettings.shared.set(NSStringFromRect(window.frame), forKey: "Layout.windowFrame")
    }
}

// MARK: - 画像出力ウィンドウ

extension MosaicWindowController {
    /// 「画像出力」ウィンドウを構築・表示する。可変サイズ・旧NSSavePanelの約2倍の横幅、
    /// 出力形式選択（jpg/png/bmp/gif/tif/heic/pdf/psd/ai/eps）、形式ごとの詳細設定、
    /// 全体プレビュー＋一部拡大プレビューを備える。
    private func showExportWindow() {
        if exportWindow == nil {
            exportWindow = buildExportWindow()
        }
        exportFilenameField.stringValue = exportSourceName + "_mosaic"
        if exportFolderURL == nil {
            exportFolderURL = libraryEngine.rootURL
        }
        updateExportFolderLabel()
        exportFormatPopUp.selectItem(withTitle: ImageExportFormat.png.displayName)
        exportFormatChanged()
        if let window = exportWindow {
            if let parent = view.window {
                parent.beginSheet(window)
            } else {
                window.center()
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func buildExportWindow() -> NSWindow {
        exportFormatPopUp.removeAllItems()
        exportFormatPopUp.addItems(withTitles: ImageExportFormat.allCases.map(\.displayName))
        exportFormatPopUp.target = self
        exportFormatPopUp.action = #selector(exportFormatChanged)
        applyScaledFont(exportFormatPopUp, size: 13)
        applyScaledFont(exportFilenameField, size: 13)
        applyScaledFont(exportDPIField, size: 13)
        applyScaledFont(exportIncludeOriginalLayerCheckbox, size: 12)
        applyScaledFont(exportPreserveTransparencyCheckbox, size: 12)
        applyScaledFont(exportQualityValueLabel, size: 12)

        exportQualitySlider.target = self
        exportQualitySlider.action = #selector(exportQualityChanged)
        exportQualitySlider.translatesAutoresizingMaskIntoConstraints = false
        exportQualitySlider.widthAnchor.constraint(equalToConstant: 200).isActive = true

        exportDPIField.target = self
        exportDPIField.action = #selector(exportOptionChanged)
        exportDPIField.translatesAutoresizingMaskIntoConstraints = false
        exportDPIField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        exportIncludeOriginalLayerCheckbox.state = .on
        exportIncludeOriginalLayerCheckbox.target = self
        exportIncludeOriginalLayerCheckbox.action = #selector(exportOptionChanged)

        exportPreserveTransparencyCheckbox.state = .on
        exportPreserveTransparencyCheckbox.target = self
        exportPreserveTransparencyCheckbox.action = #selector(exportOptionChanged)

        exportFilenameField.translatesAutoresizingMaskIntoConstraints = false
        // 「デフォルトのサイズが小さすぎ使いづらい」報告への対応で、旧NSSavePanel標準幅の
        // 概ね2倍にあたる幅を確保する
        exportFilenameField.widthAnchor.constraint(equalToConstant: 420).isActive = true

        let chooseFolderButton = NSButton(title: "保存先を変更…", target: self, action: #selector(exportChooseFolder))
        applyScaledFont(chooseFolderButton, size: 12)

        applyScaledFont(exportFormatNoteLabel, size: 10)
        exportFormatNoteLabel.textColor = .secondaryLabelColor
        exportFormatNoteLabel.maximumNumberOfLines = 3
        exportFormatNoteLabel.lineBreakMode = .byWordWrapping
        exportFormatNoteLabel.translatesAutoresizingMaskIntoConstraints = false
        exportFormatNoteLabel.widthAnchor.constraint(equalToConstant: 420).isActive = true

        let formRows = NSStackView(views: [
            inspectorRow("ファイル名", control: exportFilenameField),
            inspectorRow("保存先", control: exportFolderLabel, trailing: chooseFolderButton),
            inspectorRow("形式", control: exportFormatPopUp),
            inspectorRow("品質", control: exportQualitySlider, trailing: exportQualityValueLabel),
            inspectorRow("解像度 (DPI)", control: exportDPIField),
            exportIncludeOriginalLayerCheckbox,
            exportPreserveTransparencyCheckbox,
            exportFormatNoteLabel
        ])
        formRows.orientation = .vertical
        formRows.alignment = .leading
        formRows.spacing = 10
        formRows.translatesAutoresizingMaskIntoConstraints = false

        exportPreviewFullImageView.imageScaling = .scaleProportionallyUpOrDown
        exportPreviewFullImageView.wantsLayer = true
        exportPreviewFullImageView.layer?.borderWidth = 1
        exportPreviewFullImageView.layer?.borderColor = NSColor.separatorColor.cgColor
        exportPreviewFullImageView.translatesAutoresizingMaskIntoConstraints = false
        exportPreviewFullImageView.widthAnchor.constraint(equalToConstant: 300).isActive = true
        exportPreviewFullImageView.heightAnchor.constraint(equalToConstant: 220).isActive = true

        exportPreviewZoomImageView.imageScaling = .scaleProportionallyUpOrDown
        exportPreviewZoomImageView.wantsLayer = true
        exportPreviewZoomImageView.layer?.borderWidth = 1
        exportPreviewZoomImageView.layer?.borderColor = NSColor.separatorColor.cgColor
        exportPreviewZoomImageView.translatesAutoresizingMaskIntoConstraints = false
        exportPreviewZoomImageView.widthAnchor.constraint(equalToConstant: 300).isActive = true
        exportPreviewZoomImageView.heightAnchor.constraint(equalToConstant: 220).isActive = true

        let fullLabel = NSTextField(labelWithString: "全体プレビュー")
        applyScaledFont(fullLabel, size: 11, weight: .medium)
        let zoomLabel = NSTextField(labelWithString: "拡大プレビュー（中央部）")
        applyScaledFont(zoomLabel, size: 11, weight: .medium)

        let previewColumn = NSStackView(views: [
            fullLabel, exportPreviewFullImageView, zoomLabel, exportPreviewZoomImageView
        ])
        previewColumn.orientation = .vertical
        previewColumn.alignment = .leading
        previewColumn.spacing = 6
        previewColumn.translatesAutoresizingMaskIntoConstraints = false

        let mainRow = NSStackView(views: [formRows, previewColumn])
        mainRow.orientation = .horizontal
        mainRow.alignment = .top
        mainRow.spacing = 24
        mainRow.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "キャンセル", target: self, action: #selector(exportCancelled))
        cancelButton.keyEquivalent = "\u{1b}"
        applyScaledFont(cancelButton, size: 13)
        let exportButton = NSButton(title: "画像出力", target: self, action: #selector(exportConfirmed))
        exportButton.keyEquivalent = "\r"
        exportButton.bezelStyle = .rounded
        exportButton.hasDestructiveAction = false
        applyScaledFont(exportButton, size: 13)
        let buttonRow = NSStackView(views: [NSView(), cancelButton, exportButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [mainRow, buttonRow])
        content.orientation = .vertical
        content.alignment = .trailing
        content.spacing = 20
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            mainRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            mainRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])

        // 「画像を書き出す」→「画像出力」への名称統一に合わせ、操作ウィンドウ名も同一にする。
        // 可変サイズ（.resizable）にし、旧NSSavePanelより大幅に広い初期幅を確保する。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "画像出力"
        // 保持している参照があるので、閉じてもAppKitに解放させない。
        // `isReleasedWhenClosed` は既定が `true` で、閉じるとAppKitがreleaseする。
        // ARCの強参照と組み合わさると過剰解放になり、次に開こうとした時点で
        // 解放済みメモリへ `makeKeyAndOrderFront:` を送って落ちる
        // （クラッシュ報告 2026-08-02「キー割当後、再度設定画面が開けない」）。
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 760, height: 480)
        window.contentView = container
        return window
    }

    private func updateExportFolderLabel() {
        exportFolderLabel.stringValue = exportFolderURL?.path ?? "未選択"
        exportFolderLabel.lineBreakMode = .byTruncatingMiddle
        exportFolderLabel.toolTip = exportFolderURL?.path
    }

    @objc private func exportChooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "選択"
        if let current = exportFolderURL {
            panel.directoryURL = current
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportFolderURL = url
        updateExportFolderLabel()
    }

    private func selectedExportFormat() -> ImageExportFormat {
        let index = exportFormatPopUp.indexOfSelectedItem
        let formats = ImageExportFormat.allCases
        guard (0..<formats.count).contains(index) else { return .png }
        return formats[index]
    }

    @objc private func exportFormatChanged() {
        let format = selectedExportFormat()
        exportQualitySlider.isEnabled = format.supportsQuality
        exportQualityValueLabel.textColor = format.supportsQuality ? .labelColor : .tertiaryLabelColor
        exportIncludeOriginalLayerCheckbox.isHidden = !format.supportsLayers
        switch format {
        case .ai:
            exportFormatNoteLabel.stringValue = "※本アプリはベクターデータを持たないため、Illustratorで開けるPDF互換の画像コンテナとして出力します（パスとしての編集はできません）。"
        case .eps:
            exportFormatNoteLabel.stringValue = "※JPEG圧縮した画像をPostScriptへ埋め込む標準的なラスターEPSとして出力します。"
        case .psd:
            exportFormatNoteLabel.stringValue = "※「モザイク適用」レイヤ（表示）と「元画像」レイヤ（非表示）の2レイヤ構成で書き出します。Photoshopでレイヤーの表示切替による比較・追加レタッチができます。"
        default:
            exportFormatNoteLabel.stringValue = ""
        }
        let extensionText = "." + format.fileExtension
        var name = exportFilenameField.stringValue
        for other in ImageExportFormat.allCases where name.hasSuffix("." + other.fileExtension) {
            name = String(name.dropLast(other.fileExtension.count + 1))
        }
        exportFilenameField.stringValue = name
        exportFormatNoteLabel.toolTip = extensionText
        updateExportPreview()
    }

    @objc private func exportQualityChanged() {
        exportQualityValueLabel.stringValue = "\(Int(exportQualitySlider.doubleValue)) %"
        updateExportPreview()
    }

    @objc private func exportOptionChanged() {
        updateExportPreview()
    }

    private func currentExportOptions() -> ImageExportOptions {
        let dpi = Double(exportDPIField.stringValue) ?? 350
        return ImageExportOptions(
            quality: exportQualitySlider.doubleValue / 100.0,
            dpi: max(1, dpi),
            includeOriginalLayer: exportIncludeOriginalLayerCheckbox.state == .on,
            preserveTransparency: exportPreserveTransparencyCheckbox.state == .on
        )
    }

    /// プレビューを更新する。JPEG/HEICは実際に品質設定でエンコード→デコードした結果を表示し、
    /// 圧縮アーティファクトを保存前に確認できるようにする。それ以外の形式は元画素をそのまま表示する。
    private func updateExportPreview() {
        guard let source = exportSourceImage else { return }
        let format = selectedExportFormat()
        let previewSource: CGImage
        if format.supportsQuality, let encoded = Self.inMemoryPreviewEncode(source, format: format, quality: exportQualitySlider.doubleValue / 100.0) {
            previewSource = encoded
        } else {
            previewSource = source
        }
        exportPreviewFullImageView.image = NSImage(cgImage: previewSource, size: NSSize(width: previewSource.width, height: previewSource.height))
        let cropSize = max(32, min(previewSource.width, previewSource.height) / 3)
        if let zoomed = Self.centerCrop(of: previewSource, size: cropSize) {
            exportPreviewZoomImageView.image = NSImage(cgImage: zoomed, size: NSSize(width: zoomed.width, height: zoomed.height))
        } else {
            exportPreviewZoomImageView.image = exportPreviewFullImageView.image
        }
    }

    private static func inMemoryPreviewEncode(_ image: CGImage, format: ImageExportFormat, quality: Double) -> CGImage? {
        guard let utType = format.utType else { return nil }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, utType.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        guard let source = CGImageSourceCreateWithData(mutableData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func centerCrop(of image: CGImage, size: Int) -> CGImage? {
        let cropWidth = min(size, image.width)
        let cropHeight = min(size, image.height)
        let originX = (image.width - cropWidth) / 2
        let originY = (image.height - cropHeight) / 2
        return image.cropping(to: CGRect(x: originX, y: originY, width: cropWidth, height: cropHeight))
    }

    @objc private func exportCancelled() {
        closeExportWindow()
    }

    private func closeExportWindow() {
        guard let window = exportWindow else { return }
        if let parent = view.window, parent.attachedSheet === window {
            parent.endSheet(window)
        }
        window.orderOut(nil)
    }

    @objc private func exportConfirmed() {
        guard let source = exportSourceImage, let folder = exportFolderURL else {
            updateStatus("保存先を選択してください")
            return
        }
        var filename = exportFilenameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty else {
            updateStatus("ファイル名を入力してください")
            return
        }
        let format = selectedExportFormat()
        for other in ImageExportFormat.allCases where filename.hasSuffix("." + other.fileExtension) {
            filename = String(filename.dropLast(other.fileExtension.count + 1))
        }
        let url = folder.appendingPathComponent(filename).appendingPathExtension(format.fileExtension)
        let options = currentExportOptions()

        var imageToWrite = source
        if !options.preserveTransparency, let flattened = Self.flattenOverWhite(source) {
            imageToWrite = flattened
        }

        do {
            try ImageExporter.export(
                image: imageToWrite,
                originalImage: exportOriginalImage,
                format: format,
                options: options,
                to: url
            )
            closeExportWindow()
            finalizeExport(image: imageToWrite, url: url)
            AppLog.export.info("画像出力: format=\(format.rawValue, privacy: .public)")
        } catch {
            AppLog.export.error("画像出力に失敗: format=\(format.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            showError(error)
        }
    }

    private static func flattenOverWhite(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

// MARK: - 詳細設定・プロジェクト（保存/読込/初期化）

extension MosaicWindowController: NSMenuDelegate {
    /// ファイル＞設定＞プロジェクト の最近のプロジェクト一覧（最大10件）を、開く直前に再構築する。
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === layerOutlineView.menu {
            updateLayerContextMenu(menu)
            return
        }
        guard menu.title == "プロジェクト" else { return }
        menu.removeAllItems()
        let recents = Self.loadRecentProjects()
        if recents.isEmpty {
            let empty = NSMenuItem(title: "最近保存されたプロジェクトはありません", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for recent in recents {
            let item = NSMenuItem(title: recent.name, action: #selector(loadRecentProject(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = recent.path
            item.toolTip = recent.path
            menu.addItem(item)
        }
    }
}

extension MosaicWindowController {
    private struct RecentProject {
        var path: String
        var name: String
    }

    private static func loadRecentProjects() -> [RecentProject] {
        guard let raw = AppSettings.shared.object(forKey: recentProjectsDefaultsKey) as? [[String: String]] else {
            return []
        }
        return raw.compactMap { entry in
            guard let path = entry["path"], let name = entry["name"] else { return nil }
            return RecentProject(path: path, name: name)
        }
    }

    /// 保存/読込のたびに「最近のプロジェクト」の先頭へ追加し、同一パスの重複を除いて最大10件に切り詰める。
    private func addRecentProject(path: String, name: String) {
        var recents = Self.loadRecentProjects().filter { $0.path != path }
        recents.insert(RecentProject(path: path, name: name), at: 0)
        if recents.count > 10 {
            recents.removeLast(recents.count - 10)
        }
        AppSettings.shared.set(recents.map { ["path": $0.path, "name": $0.name] }, forKey: Self.recentProjectsDefaultsKey)
    }

    // MARK: プロジェクトファイルの保存/読込

    /// 現在のアプリ設定状態（モザイクスタイル・レイアウト・検出設定等の全AppSettings値）を
    /// プロジェクトファイル（JSON, .newmosaicproj）へ書き出す。
    @objc func saveProject() {
        let panel = NSSavePanel()
        panel.title = "プロジェクトを保存"
        panel.nameFieldStringValue = "newMosaic Project"
        if let utType = UTType(filenameExtension: Self.projectFileExtension) {
            panel.allowedContentTypes = [utType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let snapshot = AppSettings.shared.exportSnapshot()
            guard JSONSerialization.isValidJSONObject(snapshot) else {
                throw CocoaError(.propertyListWriteInvalid)
            }
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            addRecentProject(path: url.path, name: url.deletingPathExtension().lastPathComponent)
            updateStatus("プロジェクトを保存しました: \(url.lastPathComponent)")
        } catch {
            showError(error)
        }
    }

    /// プロジェクトファイルを選択して読み込む。
    @objc func loadProject() {
        let panel = NSOpenPanel()
        panel.title = "プロジェクトを読込"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let utType = UTType(filenameExtension: Self.projectFileExtension) {
            panel.allowedContentTypes = [utType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadProject(from: url)
    }

    @objc private func loadRecentProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        loadProject(from: URL(fileURLWithPath: path))
    }

    private func loadProject(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "プロジェクトファイルの形式が不正です"
                ])
            }
            AppSettings.shared.importSnapshot(snapshot)
            refreshAllUIFromSettings()
            addRecentProject(path: url.path, name: url.deletingPathExtension().lastPathComponent)
            updateStatus("プロジェクトを読み込みました: \(url.lastPathComponent)")
            AppLog.project.info("プロジェクトを読み込みました: \(url.lastPathComponent, privacy: .public)")
        } catch {
            AppLog.project.error("プロジェクト読込に失敗: \(error.localizedDescription, privacy: .public)")
            showError(error)
        }
    }

    /// 初期化する項目をユーザーが選べる形で実行する（確認ダイアログ付き）。
    ///
    /// 以前は「すべてのアプリ設定」を一括で戻すだけで、学習内容だけ消したい・レイアウトは
    /// 残したい、といった要求に応えられなかった（ユーザー要望 2026-07-31）。
    @objc func resetAllSettings() {
        let picker = MaintenanceItemPicker { $0.isCheckedByDefaultForReset }
        let alert = NSAlert()
        alert.messageText = "初期化する項目を選んでください"
        alert.informativeText = "チェックした項目だけを既定の状態へ戻します。この操作は取り消せません。"
        alert.accessoryView = picker.view
        alert.addButton(withTitle: "初期化")
        alert.addButton(withTitle: "キャンセル")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let items = picker.selected
        guard !items.isEmpty else {
            updateStatus("初期化する項目が選ばれていません")
            return
        }
        var done: [String] = []
        var failures: [String] = []
        for item in items {
            switch item {
            case .appSettings, .windowLayout:
                // どちらも settings.json に入っているため、片方でも選ばれていれば1回だけ実行する
                if !done.contains("設定") {
                    AppSettings.shared.resetAll()
                    refreshAllUIFromSettings()
                    done.append("設定")
                }
            case .learningData:
                do {
                    try learningEngine?.removeAllLearningData()
                    done.append(item.title)
                } catch {
                    failures.append("\(item.title): \(error.localizedDescription)")
                }
            case .libraryIndex:
                do {
                    try libraryEngine.deleteItems(ids: libraryEngine.loadItems().map(\.id))
                    reloadLibrary()
                    done.append(item.title)
                } catch {
                    failures.append("\(item.title): \(error.localizedDescription)")
                }
            }
        }
        let doneText = items.map(\.title).joined(separator: "、")
        if failures.isEmpty {
            updateStatus("初期化しました: \(doneText)")
        } else {
            updateStatus("一部の初期化に失敗しました: \(failures.joined(separator: " / "))")
        }
        AppLog.ui.info("初期化: \(doneText, privacy: .public) 失敗\(failures.count)件")
    }

    /// 各種設定・動作状態・学習内容を1つのフォルダへ一括バックアップする。
    ///
    /// 項目ごとにON/OFFを選べる（ユーザー要望 2026-07-31）。すべてローカルへの複製で、
    /// 外部へは送信しない。
    @objc func backupAllSettings() {
        let picker = MaintenanceItemPicker { $0.isCheckedByDefaultForBackup }
        let alert = NSAlert()
        alert.messageText = "バックアップする項目を選んでください"
        alert.informativeText = "チェックした項目を1つのフォルダへ書き出します。ライブラリの元画像ファイル本体とAIモデルは含みません（容量が大きいため）。"
        alert.accessoryView = picker.view
        alert.addButton(withTitle: "保存先を選ぶ…")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let items = picker.selected
        guard !items.isEmpty else {
            updateStatus("バックアップする項目が選ばれていません")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "ここへバックアップ"
        panel.message = "バックアップの保存先フォルダを選んでください"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let created = try MaintenanceBackup.create(
                items: items,
                into: destination,
                settingsFileURL: AppSettings.resolveSettingsFileURL(),
                learningDirectory: learningEngine?.storageDirectory,
                libraryDirectory: libraryEngine.rootURL
            )
            NSWorkspace.shared.activateFileViewerSelecting([created])
            updateStatus("バックアップしました: \(created.lastPathComponent)")
            AppLog.ui.info("バックアップ: \(items.count)項目")
        } catch {
            AppLog.ui.error("バックアップに失敗: \(error.localizedDescription, privacy: .public)")
            showError(error)
        }
    }

    /// 「検出」セクションの各コントロールを保存値（無ければ既定値）へ戻す。
    private func loadDetectionSettings() {
        individualDetectionCheckbox.state =
            (AppSettings.shared.object(forKey: Self.individualDetectionDefaultsKey) as? Bool ?? true) ? .on : .off
        let defaultEngineIndex = Self.selectableEngineKinds.firstIndex(of: .samShape) ?? 0
        segmentEngineControl.selectItem(at: defaultEngineIndex)
        let threshold = AppSettings.shared.double(forKey: Self.maskThresholdDefaultsKey)
        maskThresholdSlider.doubleValue = threshold
        maskThresholdValueLabel.stringValue = threshold < 0.01 ? "自動" : "\(Int(threshold * 100)) %"
        shapeControl.selectedSegment = 1
    }

    /// レイヤパネル「表示:」「詳細:」を既定状態へ戻す。
    /// 既定はROIとモザイクをON（候補生成の結果がすぐ見える状態）、人物・骨格はOFF。
    private func loadLayerVisibilityDefaults() {
        roiLayerCheckbox.state = .on
        mosaicPreviewCheckbox.state = mosaicPreviewDefaultOn ? .on : .off
        personLayerCheckbox.state = .off
        poseLayerCheckbox.state = .off
        layerOutlineAllCheckbox.state = .on
        layerTagAllCheckbox.state = .on
        applyLayerVisibility()
        updateLayerDetailToggleAvailability()
    }

    /// 「詳細: 輪郭 / タグ」は表示中のレイヤに対する設定なので、
    /// ROI・人物・骨格がすべて非表示なら操作しても効果が無い。無効化して状態の矛盾を防ぐ。
    private func updateLayerDetailToggleAvailability() {
        let hasVisibleLayer = roiLayerCheckbox.state == .on
            || personLayerCheckbox.state == .on
            || poseLayerCheckbox.state == .on
        layerOutlineAllCheckbox.isEnabled = hasVisibleLayer
        layerTagAllCheckbox.isEnabled = hasVisibleLayer
    }

    /// 設定の読込・初期化後に、画面上の全コントロールをAppSettingsの現在値へ再同期する。
    private func refreshAllUIFromSettings() {
        let savedDomainMode = AppSettings.shared.integer(forKey: Self.domainModeDefaultsKey)
        domainModeControl.selectItem(at: (0...2).contains(savedDomainMode) ? savedDomainMode : 0)
        let savedRatio = AppSettings.shared.object(forKey: Self.groinPositionDefaultsKey) as? Double ?? 0.45
        groinPositionSlider.doubleValue = savedRatio
        groinPositionValueLabel.stringValue = "\(Int(savedRatio * 100)) %"
        refreshLearningModeButton()
        loadGenerationFilter()
        loadMosaicStyleSettings()
        loadLibraryViewPreferences()
        // 「検出」「ワークフロー」「レイヤ表示」は従来ここで再同期しておらず、初期化しても
        // 直前の状態が残っていた（初期化直後にレイヤ表示が全OFFのまま等。GUI報告）。
        loadWorkflowOptions()
        loadDetectionSettings()
        loadLayerVisibilityDefaults()
        applyPanelAssignments()
        // restoreSplitPositions()を直接呼ぶだけだと、保存値が無い場合（初期化直後や、
        // レイアウト情報を含まない古いプロジェクトファイルの読込時）に分割位置が
        // 「変更前のまま」残ってしまい、「レイアウトも既定値に戻る」という初期化の説明と
        // 食い違う不具合があった。applyInitialLayoutIfNeeded()を使い、保存値が無ければ
        // 工場既定レイアウト（右パネル=ライブラリ2列幅 等）へ確実に戻す。
        applyInitialLayoutIfNeeded()
        applyIconSizeToAllToolbarButtons()
        iconSizeControl.selectedSegment = Self.currentIconSizeSetting()
        textSizeControl.selectedSegment = Self.currentTextSizeSetting()
        reloadLibrary()
    }

    // MARK: 詳細設定ウィンドウ

    @objc func showAdvancedSettings() {
        if let window = advancedSettingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        iconSizeControl.selectedSegment = Self.currentIconSizeSetting()
        iconSizeControl.target = self
        iconSizeControl.action = #selector(iconSizeChanged)
        iconSizeControl.toolTip = "ツールバーアイコンの表示サイズ"
        applyScaledFont(iconSizeControl, size: 12)

        textSizeControl.selectedSegment = Self.currentTextSizeSetting()
        textSizeControl.target = self
        textSizeControl.action = #selector(textSizeChanged)
        textSizeControl.toolTip = "画面内のテキストサイズ（変更すると即座に反映されます）"
        applyScaledFont(textSizeControl, size: 12)

        let iconSizeRow = inspectorRow("アイコンサイズ", control: iconSizeControl)
        let textSizeRow = inspectorRow("テキストサイズ", control: textSizeControl)

        // 「設定ファイル」行もinspectorRowで統一し、アイコンサイズ等のラベルと
        // 左寄せ位置・テキストサイズを揃える（旧実装は別スタイルのラベルで揃っていなかった）。
        let settingsPathValueLabel = NSTextField(labelWithString: AppSettings.shared.settingsFileLocation.path)
        applyScaledFont(settingsPathValueLabel, size: 11)
        settingsPathValueLabel.textColor = .secondaryLabelColor
        settingsPathValueLabel.lineBreakMode = .byTruncatingMiddle
        settingsPathValueLabel.maximumNumberOfLines = 2
        settingsPathValueLabel.translatesAutoresizingMaskIntoConstraints = false
        settingsPathValueLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        let settingsPathRow = inspectorRow("設定ファイル", control: settingsPathValueLabel)

        let numpadButton = NSButton(title: "テンキー割当…", target: self, action: #selector(showNumpadAssignmentWindow))
        applyScaledFont(numpadButton, size: 12)
        let numpadRow = inspectorRow("機能割当", control: numpadButton)

        let videoRows = makeVideoTrackingSettingRows()

        let content = NSStackView(views: [iconSizeRow, textSizeRow, numpadRow] + videoRows + [settingsPathRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        content.translatesAutoresizingMaskIntoConstraints = false

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "詳細設定"
        // 保持している参照があるので、閉じてもAppKitに解放させない。
        // `isReleasedWhenClosed` は既定が `true` で、閉じるとAppKitがreleaseする。
        // ARCの強参照と組み合わさると過剰解放になり、次に開こうとした時点で
        // 解放済みメモリへ `makeKeyAndOrderFront:` を送って落ちる
        // （クラッシュ報告 2026-08-02「キー割当後、再度設定画面が開けない」）。
        window.isReleasedWhenClosed = false
        window.delegate = self
        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])
        window.contentView = container
        window.center()
        advancedSettingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func iconSizeChanged() {
        AppSettings.shared.set(iconSizeControl.selectedSegment, forKey: Self.iconSizeDefaultsKey)
        applyIconSizeToAllToolbarButtons()
    }

    // MARK: - 詳細設定: 動画の自動追随（v0.0.00136）

    /// 動画の自動追随に関する設定行。既定は全てONで、検閲漏れよりも
    /// 過剰なモザイク・書き出し時間の増加を選ぶ側に倒してある。
    private func makeVideoTrackingSettingRows() -> [NSView] {
        let header = NSTextField(labelWithString: "動画の自動追随")
        applyScaledFont(header, size: 12)
        header.textColor = .secondaryLabelColor

        videoAutoRedetectCheckbox.title = "一定間隔で検出をやり直す（新規登場の対象を拾い、追跡ズレを補正）"
        videoAutoRedetectCheckbox.target = self
        videoAutoRedetectCheckbox.action = #selector(videoTrackingSettingChanged)
        videoAutoRedetectCheckbox.state =
            Self.videoSettingIsEnabled(Self.videoAutoRedetectDefaultsKey) ? .on : .off
        videoAutoRedetectCheckbox.toolTip =
            "OFFにするとキーフレーム起点の追跡のみになります（速いが、途中から映り込んだ対象は検出されません）"
        applyScaledFont(videoAutoRedetectCheckbox, size: 12)

        videoRedetectIntervalPopUp.removeAllItems()
        for interval in Self.videoRedetectIntervalChoices {
            videoRedetectIntervalPopUp.addItem(withTitle: "\(interval) フレームごと")
        }
        let savedInterval = AppSettings.shared.integer(forKey: Self.videoRedetectIntervalDefaultsKey)
        let intervalIndex = Self.videoRedetectIntervalChoices.firstIndex(of: savedInterval) ?? 2
        videoRedetectIntervalPopUp.selectItem(at: intervalIndex)
        videoRedetectIntervalPopUp.target = self
        videoRedetectIntervalPopUp.action = #selector(videoTrackingSettingChanged)
        videoRedetectIntervalPopUp.toolTip = "短いほど精度が上がり、書き出し時間は延びます（30fps動画で30＝約1秒ごと）"
        applyScaledFont(videoRedetectIntervalPopUp, size: 12)

        videoSceneCutCheckbox.title = "シーンカットを検出して、その場で検出をやり直す"
        videoSceneCutCheckbox.target = self
        videoSceneCutCheckbox.action = #selector(videoTrackingSettingChanged)
        videoSceneCutCheckbox.state =
            Self.videoSettingIsEnabled(Self.videoSceneCutDefaultsKey) ? .on : .off
        videoSceneCutCheckbox.toolTip = "カットを跨ぐと追跡は必ず外れるため、切り替わりを検出して追跡を張り直します"
        applyScaledFont(videoSceneCutCheckbox, size: 12)

        videoLostExpansionCheckbox.title = "追跡を見失ったら、覆う範囲を少しずつ広げる（安全側）"
        videoLostExpansionCheckbox.target = self
        videoLostExpansionCheckbox.action = #selector(videoTrackingSettingChanged)
        videoLostExpansionCheckbox.state =
            Self.videoSettingIsEnabled(Self.videoLostExpansionDefaultsKey) ? .on : .off
        videoLostExpansionCheckbox.toolTip =
            "見失うと対象がどこへ動いたか分からないため、時間の経過に応じて覆う範囲を広げます（上限あり）"
        applyScaledFont(videoLostExpansionCheckbox, size: 12)

        return [
            header,
            videoAutoRedetectCheckbox,
            inspectorRow("再検出の間隔", control: videoRedetectIntervalPopUp),
            videoSceneCutCheckbox,
            videoLostExpansionCheckbox
        ]
    }

    @objc private func videoTrackingSettingChanged() {
        let settings = AppSettings.shared
        settings.set(videoAutoRedetectCheckbox.state == .on, forKey: Self.videoAutoRedetectDefaultsKey)
        settings.set(videoSceneCutCheckbox.state == .on, forKey: Self.videoSceneCutDefaultsKey)
        settings.set(videoLostExpansionCheckbox.state == .on, forKey: Self.videoLostExpansionDefaultsKey)
        let index = videoRedetectIntervalPopUp.indexOfSelectedItem
        if Self.videoRedetectIntervalChoices.indices.contains(index) {
            settings.set(Self.videoRedetectIntervalChoices[index],
                         forKey: Self.videoRedetectIntervalDefaultsKey)
        }
        videoRedetectIntervalPopUp.isEnabled = videoAutoRedetectCheckbox.state == .on
        updateStatus("動画の自動追随設定を更新しました（次回の追跡プレビュー・書き出しから適用）")
    }
}

// MARK: - テンキー割当

/// macOS仮想キーコードのテンキー一覧（トップ行の数字キーとは別の物理キー）。
/// NSMenuItem.keyEquivalentは文字ベースの一致のためテンキー/トップ行を区別できず、
/// テンキー専用の割当を実現するにはキーコードで判定するイベント監視が必要になる。
private enum NumpadKey: Int, CaseIterable {
    case n0 = 82, n1 = 83, n2 = 84, n3 = 85, n4 = 86
    case n5 = 87, n6 = 88, n7 = 89, n8 = 91, n9 = 92
    case decimal = 65, multiply = 67, plus = 69, divide = 75, enter = 76, minus = 78, equals = 81

    var displayLabel: String {
        switch self {
        case .n0: return "テンキー 0"
        case .n1: return "テンキー 1"
        case .n2: return "テンキー 2"
        case .n3: return "テンキー 3"
        case .n4: return "テンキー 4"
        case .n5: return "テンキー 5"
        case .n6: return "テンキー 6"
        case .n7: return "テンキー 7"
        case .n8: return "テンキー 8"
        case .n9: return "テンキー 9"
        case .decimal: return "テンキー ."
        case .multiply: return "テンキー *"
        case .plus: return "テンキー +"
        case .divide: return "テンキー /"
        case .enter: return "テンキー Enter"
        case .minus: return "テンキー -"
        case .equals: return "テンキー ="
        }
    }
}

extension MosaicWindowController {
    /// テンキー割当（キーコード文字列→ショートカットID）を読み込む。
    private static func numpadAssignments() -> [String: String] {
        (AppSettings.shared.object(forKey: numpadAssignmentsDefaultsKey) as? [String: String]) ?? [:]
    }

    private static func setNumpadAssignments(_ assignments: [String: String]) {
        AppSettings.shared.set(assignments, forKey: numpadAssignmentsDefaultsKey)
    }

    /// アプリ起動時に一度だけ呼び出し、テンキー押下を監視してショートカットへディスパッチする。
    /// メニューのkeyEquivalentでは（文字一致のため）テンキーとトップ行の数字キーを区別できないため、
    /// ローカルイベント監視でキーコードから直接判定する。
    func installNumpadShortcutMonitor() {
        videoShortcutEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleVideoShortcut(event) else { return event }
            return nil
        }
        numpadEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let numpadKey = NumpadKey(rawValue: Int(event.keyCode)) else { return event }
            let assignments = Self.numpadAssignments()
            guard let shortcutID = assignments[String(numpadKey.rawValue)],
                  let shortcut = Self.shortcut(id: shortcutID) else { return event }
            _ = self.perform(shortcut.action)
            return nil
        }
    }

    /// 動画編集中だけ有効な文脈依存ショートカット。
    /// テキスト編集中は文字入力を優先し、`<`/`>`/Spaceを横取りしない。
    private func handleVideoShortcut(_ event: NSEvent) -> Bool {
        guard currentVideoItem != nil else { return false }
        if view.window?.firstResponder is NSTextView { return false }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let characters = event.characters ?? ""
        let key = (event.charactersIgnoringModifiers ?? characters).lowercased()

        if modifiers.contains(.command), modifiers.contains(.option),
           !modifiers.contains(.control), !modifiers.contains(.shift), key == "k" {
            deleteSelectedVideoKeyframes()
            return true
        }
        if modifiers.contains(.command), !modifiers.contains(.option), !modifiers.contains(.control) {
            if characters == "<" || (event.keyCode == 43 && modifiers.contains(.shift)) {
                stepToPreviousVideoFrame()
                return true
            }
            if characters == ">" || (event.keyCode == 47 && modifiers.contains(.shift)) {
                stepToNextVideoFrame()
                return true
            }
        }
        if !modifiers.contains(.command), !modifiers.contains(.option), !modifiers.contains(.control) {
            if event.keyCode == 49 {
                toggleVideoPlayback()
                return true
            }
            if characters == "<" {
                jumpToPreviousKeyframe()
                return true
            }
            if characters == ">" {
                jumpToNextKeyframe()
                return true
            }
        }
        return false
    }

    /// 詳細設定「テンキー割当…」ウィンドウを表示する。各ショートカットへテンキーを割り当てられる
    /// （同じテンキーへの再割当は元の割当を自動的に解除する）。
    @objc func showNumpadAssignmentWindow() {
        if let window = numpadAssignmentWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let rows = MosaicWindowController.appShortcuts.map { shortcut -> NSStackView in
            let titleLabel = NSTextField(labelWithString: shortcut.title)
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let categoryLabel = NSTextField(labelWithString: shortcut.category)
            categoryLabel.textColor = .secondaryLabelColor
            categoryLabel.font = MosaicWindowController.scaledFont(10)
            categoryLabel.translatesAutoresizingMaskIntoConstraints = false
            categoryLabel.widthAnchor.constraint(equalToConstant: 70).isActive = true
            let popup = NSPopUpButton(title: "", target: self, action: #selector(numpadAssignmentChanged(_:)))
            popup.identifier = NSUserInterfaceItemIdentifier(shortcut.id)
            popup.addItem(withTitle: "未割当")
            popup.item(at: 0)?.representedObject = ""
            for key in NumpadKey.allCases {
                popup.addItem(withTitle: key.displayLabel)
                popup.lastItem?.representedObject = String(key.rawValue)
            }
            let currentAssignments = MosaicWindowController.numpadAssignments()
            if let assignedKey = currentAssignments.first(where: { $0.value == shortcut.id })?.key,
               let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == assignedKey }) {
                popup.selectItem(at: index)
            }
            let row = NSStackView(views: [titleLabel, categoryLabel, popup])
            row.orientation = .horizontal
            row.spacing = 10
            return row
        }
        let content = NSStackView(views: rows)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "テンキー割当"
        // 保持している参照があるので、閉じてもAppKitに解放させない。
        // `isReleasedWhenClosed` は既定が `true` で、閉じるとAppKitがreleaseする。
        // ARCの強参照と組み合わさると過剰解放になり、次に開こうとした時点で
        // 解放済みメモリへ `makeKeyAndOrderFront:` を送って落ちる
        // （クラッシュ報告 2026-08-02「キー割当後、再度設定画面が開けない」）。
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 380, height: 240)
        window.contentView = scroll
        window.center()
        numpadAssignmentWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func numpadAssignmentChanged(_ sender: NSPopUpButton) {
        guard let shortcutID = sender.identifier?.rawValue,
              let selectedKey = sender.selectedItem?.representedObject as? String else { return }
        var assignments = MosaicWindowController.numpadAssignments()
        assignments = assignments.filter { $0.value != shortcutID }
        if !selectedKey.isEmpty {
            assignments[selectedKey] = shortcutID
        }
        MosaicWindowController.setNumpadAssignments(assignments)
        updateStatus(selectedKey.isEmpty ? "テンキー割当を解除しました" : "テンキーを割り当てました")
    }
}

// MARK: - ヘルプ＞ショートカット一覧

extension MosaicWindowController {
    /// ヘルプ＞ショートカット一覧を表示する。先頭に「よく使うおすすめショートカット」、
    /// 続けて機能分類ごとにグループ表示する。表示内容は `AppShortcut` レジストリを直接参照するため、
    /// 実際のメニュー・ツールバーの動作と常に一致する。
    @objc func showShortcutsWindow() {
        if let window = shortcutsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        var sections: [NSView] = []

        func makeSection(title: String, shortcuts: [AppShortcut]) -> NSView {
            let heading = NSTextField(labelWithString: title)
            heading.font = MosaicWindowController.scaledFont(13, weight: .semibold)
            var rows: [NSView] = [heading]
            for shortcut in shortcuts {
                let titleLabel = NSTextField(labelWithString: shortcut.title)
                titleLabel.translatesAutoresizingMaskIntoConstraints = false
                titleLabel.widthAnchor.constraint(equalToConstant: 260).isActive = true
                let keyLabel = NSTextField(labelWithString: shortcut.displayString.isEmpty ? "—" : shortcut.displayString)
                keyLabel.font = MosaicWindowController.scaledMonospacedDigitFont(12, weight: .medium)
                keyLabel.textColor = .secondaryLabelColor
                let numpadAssignments = MosaicWindowController.numpadAssignments()
                if let key = numpadAssignments.first(where: { $0.value == shortcut.id })?.key,
                   let numpadKey = NumpadKey(rawValue: Int(key) ?? -1) {
                    keyLabel.stringValue += "  /  " + numpadKey.displayLabel
                }
                let row = NSStackView(views: [titleLabel, keyLabel])
                row.orientation = .horizontal
                row.spacing = 10
                rows.append(row)
            }
            let section = NSStackView(views: rows)
            section.orientation = .vertical
            section.alignment = .leading
            section.spacing = 6
            return section
        }

        let recommended = MosaicWindowController.appShortcuts.filter(\.isRecommended)
        sections.append(makeSection(title: "よく使うおすすめショートカット", shortcuts: recommended))

        let categories = Array(NSOrderedSet(array: MosaicWindowController.appShortcuts.map(\.category))) as? [String] ?? []
        for category in categories {
            let shortcuts = MosaicWindowController.appShortcuts.filter { $0.category == category }
            sections.append(makeSection(title: category, shortcuts: shortcuts))
        }

        let content = NSStackView(views: sections)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        content.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ショートカット一覧"
        // 保持している参照があるので、閉じてもAppKitに解放させない。
        // `isReleasedWhenClosed` は既定が `true` で、閉じるとAppKitがreleaseする。
        // ARCの強参照と組み合わさると過剰解放になり、次に開こうとした時点で
        // 解放済みメモリへ `makeKeyAndOrderFront:` を送って落ちる
        // （クラッシュ報告 2026-08-02「キー割当後、再度設定画面が開けない」）。
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 360, height: 300)
        window.contentView = scroll
        window.center()
        shortcutsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - ヘルプ＞デバッグ＞デバッグログ

    /// アプリのUnified Logging（`AppLog`／MosaicCoreの検出診断ログ、subsystem
    /// `com.yoshikawa.newMosaic`）を、直近分だけこのプロセス内から読み出して一覧表示する。
    /// 画像内容やファイルパスは記録していないため、そのまま画面表示・書き出しして問題ない。
    @objc func showDebugLogWindow() {
        if let window = debugLogWindow {
            refreshDebugLog()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = Self.scaledMonospacedDigitFont(11)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        debugLogTextView = textView

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let refreshButton = NSButton(title: "更新", target: self, action: #selector(refreshDebugLog))
        applyScaledFont(refreshButton, size: 12)
        let exportButton = NSButton(title: "書き出し…", target: self, action: #selector(exportDebugLog))
        applyScaledFont(exportButton, size: 12)
        let clearButton = NSButton(title: "消去…", target: self, action: #selector(clearDebugLog))
        applyScaledFont(clearButton, size: 12)
        clearButton.toolTip = "保存済みのログファイル（世代分を含む）をすべて削除します"
        let infoLabel = NSTextField(labelWithString: "保存済み（前回起動分を含む）＋今回起動分を表示します（subsystem: com.yoshikawa.newMosaic）")
        applyScaledFont(infoLabel, size: 10)
        infoLabel.textColor = .secondaryLabelColor
        let buttonRow = NSStackView(views: [infoLabel, NSView(), clearButton, refreshButton, exportButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [buttonRow, scroll])
        content.orientation = .vertical
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        content.translatesAutoresizingMaskIntoConstraints = false

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "デバッグログ"
        // 保持している参照があるので、閉じてもAppKitに解放させない。
        // `isReleasedWhenClosed` は既定が `true` で、閉じるとAppKitがreleaseする。
        // ARCの強参照と組み合わさると過剰解放になり、次に開こうとした時点で
        // 解放済みメモリへ `makeKeyAndOrderFront:` を送って落ちる
        // （クラッシュ報告 2026-08-02「キー割当後、再度設定画面が開けない」）。
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 420, height: 260)
        window.contentView = content
        window.center()
        debugLogWindow = window
        window.makeKeyAndOrderFront(nil)
        refreshDebugLog()
    }

    /// `OSLogStore` の走査（システム全体のログを一旦スキャンしてから絞り込むため、
    /// 直近分でも数秒かかることがある）をメインスレッドで同期実行しており、
    /// ウィンドウを開くたび・更新のたびにUIが固まる不具合があった。バックグラウンドで
    /// 取得し、完了後にメインアクターへ戻してテキストを反映する。
    @objc private func refreshDebugLog() {
        debugLogTextView?.string = "読み込み中…"
        Task.detached(priority: .userInitiated) {
            let text = Self.fetchDebugLogText()
            await MainActor.run { [weak self] in
                guard let self, self.debugLogWindow != nil else { return }
                self.debugLogTextView?.string = text
                self.debugLogTextView?.scrollToEndOfDocument(nil)
            }
        }
    }

    @objc private func exportDebugLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "newMosaic_debug_log.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateStatus("デバッグログを書き出し中…")
        Task.detached(priority: .userInitiated) { [weak self] in
            let text = Self.fetchDebugLogText()
            await MainActor.run {
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    self?.updateStatus("デバッグログを書き出しました: \(url.lastPathComponent)")
                } catch {
                    self?.showError(error)
                }
            }
        }
    }

    /// 保存済みログ（前回起動分を含む）＋今回起動分を連結して返す。
    ///
    /// 従来は`OSLogStore`から直近10分を読むだけで、アプリを再起動すると前回のログが
    /// 消えていた（ユーザー要望 2026-08-02）。不具合の報告は再起動後になることが多いため、
    /// 起動中は定期的にファイルへ退避し、表示時は保存済み＋今回分を合わせて出す。
    nonisolated static func fetchDebugLogText() -> String {
        let archived = debugLogFile.readAll()
        let current = fetchCurrentProcessLogText()
        if archived.isEmpty { return current }
        return archived + "\n--- ここから今回の起動 ---\n" + current
    }

    /// ローテーション付きの保存先（1ファイル1MB・最大5世代）。
    nonisolated static let debugLogFile: RotatingLogFile = {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return RotatingLogFile(directory: support.appendingPathComponent("newMosaic/Logs"))
    }()

    /// 今回の起動分のうち、まだファイルへ退避していない行を書き出す。
    /// 起動直後・一定間隔・終了時に呼ぶ。
    nonisolated static func archiveDebugLog() {
        let text = fetchCurrentProcessLogText()
        guard !text.isEmpty else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = lines.filter { $0 > lastArchivedLogLine.value }
        guard !newLines.isEmpty else { return }
        debugLogFile.append(lines: newLines)
        if let last = newLines.last { lastArchivedLogLine.value = last }
    }

    /// 退避済みの最後の行（時刻始まりなので文字列比較で新旧を判定できる）。
    nonisolated static let lastArchivedLogLine = LockedValue("")

    /// 「消去…」を実行した時刻。これ以前の今回起動分エントリは
    /// `fetchCurrentProcessLogText()` が読み飛ばすため、表示にも退避にも現れない
    /// （OSLogStore自体からは削除できないため、読み出し側で除外する）。
    nonisolated static let debugLogClearedAt = LockedValue(Date.distantPast)

    /// 直近10分・最大500件の自アプリログ（subsystem `com.yoshikawa.newMosaic`）を取得し、
    /// 「時刻 [category] レベル: メッセージ」形式のテキストへ整形する。
    /// バックグラウンドスレッドから呼ぶこと（メインスレッドで呼ぶとUIが固まる）。
    nonisolated private static func fetchCurrentProcessLogText() -> String {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else {
            return "ログストアを取得できませんでした。"
        }
        let since = store.position(date: Date().addingTimeInterval(-600))
        guard let entries = try? store.getEntries(at: since) else {
            return "ログの取得に失敗しました。"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let clearedAt = debugLogClearedAt.value
        var lines: [String] = []
        for entry in entries {
            guard let logEntry = entry as? OSLogEntryLog,
                  logEntry.subsystem == "com.yoshikawa.newMosaic" else { continue }
            // 「消去…」実行より前のエントリは消去済みとして読み飛ばす。
            guard entry.date > clearedAt else { continue }
            let time = formatter.string(from: entry.date)
            lines.append("\(time) [\(logEntry.category)] \(logEntry.level.description): \(entry.composedMessage)")
            if lines.count >= 500 { break }
        }
        return lines.joined(separator: "\n")
    }
}

private extension OSLogEntryLog.Level {
    var description: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        case .undefined: return "?"
        @unknown default: return "?"
        }
    }
}

extension MosaicWindowController: NSTableViewDataSource, NSTableViewDelegate {
    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated {
            tableView === videoKeyframeTableView
                ? currentVideoEditState.keyframes.count
                : displayedLibraryItems.count
        }
    }

    /// 列ごとにセルを生成する（項目を横一列に並べたリスト表示。列見出しクリックでソート可能）。
    /// サムネイル列はサムネイル表示モードのみ使用する。
    nonisolated func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        MainActor.assumeIsolated {
            if tableView === videoKeyframeTableView {
                return videoKeyframeCell(tableColumn: tableColumn, row: row)
            }
            guard row >= 0, row < displayedLibraryItems.count,
                  let columnID = tableColumn?.identifier.rawValue else { return nil }
            let item = displayedLibraryItems[row]
            let identifier = NSUserInterfaceItemIdentifier("LibraryCell.\(columnID)")

            if columnID == "thumbnail" {
                let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
                    let cell = NSTableCellView()
                    let imageView = NSImageView()
                    imageView.imageScaling = .scaleProportionallyUpOrDown
                    imageView.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(imageView)
                    NSLayoutConstraint.activate([
                        imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                        imageView.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
                        imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                        imageView.widthAnchor.constraint(equalToConstant: 36),
                        imageView.heightAnchor.constraint(equalToConstant: 36)
                    ])
                    cell.imageView = imageView
                    return cell
                }()
                cell.identifier = identifier
                cell.imageView?.image = thumbnail(for: item)
                return cell
            }

            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                let label = NSTextField(labelWithString: "")
                label.lineBreakMode = .byTruncatingMiddle
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
                cell.textField = label
                return cell
            }()
            cell.identifier = identifier
            guard let label = cell.textField else { return cell }
            // makeView によるセル再利用時もフォントを毎回再適用し、テキストサイズ変更を即反映する。
            label.font = Self.scaledFont(11)

            let isBroken = libraryEngine.isLinkBroken(item)
            switch columnID {
            case "name":
                let linkMark = isBroken ? "⚠️ " : (item.isLinked ? "🔗" : "")
                label.stringValue = linkMark + item.sourceName
                label.toolTip = isBroken ? "リンク切れ: \(item.sourceName)" : item.sourceName
            case "status":
                label.stringValue = item.processedRelativePath == nil ? "元" : "済"
            case "kind":
                label.stringValue = item.isVideo ? "動画" : "静止画"
            case "resolution":
                // 動画は解像度に加えて尺も表示する（一覧から長さを把握できるようにする）
                if item.isVideo, let duration = item.videoDurationSeconds {
                    label.stringValue = "\(item.imagePixelWidth)×\(item.imagePixelHeight) "
                        + VideoPreviewView.timeText(duration)
                } else {
                    label.stringValue = "\(item.imagePixelWidth)×\(item.imagePixelHeight)"
                }
            case "roi":
                label.stringValue = "\(item.rois.count)"
            case "updated":
                label.stringValue = Self.libraryDateFormatter.string(from: item.updatedAt)
            default:
                label.stringValue = ""
            }
            label.textColor = isBroken ? .systemRed : .labelColor
            return cell
        }
    }

    nonisolated func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        MainActor.assumeIsolated {
            tableView === videoKeyframeTableView ? 22 : (libraryViewMode == .thumbnailList ? 40 : 22)
        }
    }

    /// 列見出しクリックによるソート（項目名クリックでリストソート可能にする改善への対応）。
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard tableView !== videoKeyframeTableView else { return }
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let sortKey = LibrarySortKey(rawValue: key) else { return }
        librarySortKey = sortKey
        librarySortAscending = descriptor.ascending
        refreshLibraryDisplay()
    }

    private func videoKeyframeCell(tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let keyframes = currentVideoEditState.keyframes.sorted { $0.timeSeconds < $1.timeSeconds }
        guard row >= 0, row < keyframes.count,
              let columnID = tableColumn?.identifier.rawValue else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("VideoKeyframeCell.\(columnID)")
        let cell = videoKeyframeTableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            cell.textField = label
            return cell
        }()
        cell.identifier = identifier
        cell.textField?.font = Self.scaledFont(11)
        switch columnID {
        case "videoKeyframeNo":
            cell.textField?.stringValue = "\(row + 1)"
        case "videoKeyframeTime":
            cell.textField?.stringValue = VideoPreviewView.timeText(keyframes[row].timeSeconds)
        case "videoKeyframeROI":
            cell.textField?.stringValue = "\(keyframes[row].rois.count)"
        case "videoKeyframeTracking":
            cell.textField?.stringValue = keyframes[row].trackingStatus.displayText
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }
}

extension MosaicWindowController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    nonisolated func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        MainActor.assumeIsolated { displayedLibraryItems.count }
    }

    nonisolated func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        MainActor.assumeIsolated {
            let item = displayedLibraryItems[indexPath.item]
            guard let gridItem = collectionView.makeItem(
                withIdentifier: LibraryGridItem.identifier,
                for: indexPath
            ) as? LibraryGridItem else {
                return NSCollectionViewItem()
            }
            let linkMark = libraryEngine.isLinkBroken(item) ? "⚠️" : (item.isLinked ? "🔗" : "")
            let caption = "\(item.processedRelativePath == nil ? "元" : "済") \(linkMark)\(item.sourceName)"
            gridItem.configure(image: thumbnail(for: item), caption: caption)
            return gridItem
        }
    }

    nonisolated func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        MainActor.assumeIsolated {
            guard let indexPath = indexPaths.first, indexPath.item < displayedLibraryItems.count else { return }
            selectedLibraryItemID = displayedLibraryItems[indexPath.item].id
            updateStatsBar()
        }
    }
}

extension MosaicWindowController: NSSplitViewDelegate {
    /// mainSplitView（左ペイン/キャンバス/右ペイン）の境界ドラッグ範囲を、隣接ビューの
    /// 現在フレーム＋最小幅から算出する。Auto Layoutの必須制約でNSSplitViewの
    /// フレーム操作と競合させない（サイドパネル幅がまったく動かせないバグの修正）。
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // 縦分割（左ペイン/右ペイン内のパネル積み重ね）は下限が無く、境界を上へドラッグすると
        // パネルが内容より小さくされ、Auto Layoutの必須制約が壊れてアイコンや行が重なっていた
        // （GUI報告 2026-07-31）。内容が要求する最小高さで止める。
        if splitView === leftPaneSplitView || splitView === rightPaneSplitView {
            guard !isRestoringSplitPositions else { return proposedMinimumPosition }
            let subviews = splitView.arrangedSubviews
            guard dividerIndex >= 0, dividerIndex < subviews.count else { return proposedMinimumPosition }
            let leadingView = subviews[dividerIndex]
            guard !leadingView.isHidden else { return proposedMinimumPosition }
            return leadingView.frame.minY + minimumHeight(forPanel: leadingView)
        }
        // setPosition(_:ofDividerAt:)はプログラムからの呼び出しでもこのdelegateを経由するため、
        // インタラクティブなドラッグ用に書かれた本制約（隣接ビューの現在フレームに依存）を
        // 初期化・復元などの一括レイアウト設定中に適用すると、まだ古いフレーム値のままの
        // 隣接ビューを基準に不本意な位置へクランプされてしまう不具合があった
        // （「初期化してもレイアウトが既定値へ戻らない」不具合の真因）。
        // 一括設定中はこの制約を適用しない。
        guard !isRestoringSplitPositions else { return proposedMinimumPosition }
        guard splitView === mainSplitView else { return proposedMinimumPosition }
        let subviews = splitView.arrangedSubviews
        guard dividerIndex >= 0, dividerIndex < subviews.count else { return proposedMinimumPosition }
        let leadingView = subviews[dividerIndex]
        guard !leadingView.isHidden else { return proposedMinimumPosition }
        return leadingView.frame.minX + minimumWidth(forPane: leadingView)
    }

    /// サイドペイン/キャンバスの最小幅。インスペクタを含むペインは、モザイクパターンの
    /// プレビュータイル（44pt×4列＋ラベル列）が必須制約で圧縮できないため、他のペインより
    /// 広い下限を与える（狭めるとAuto Layoutの制約違反やタイルのはみ出しが起きるため）。
    /// インスペクタを含むペインの既定幅。最小幅(340)を下回ると
    /// 「性器（男性）」が「性」になる等の省略表示とパターンタイルの横切れが起きるため、
    /// 余白を含めた値をここで一元管理する。
    static let inspectorPaneDefaultWidth: CGFloat = 360

    /// パネルの最小高さ。内容が要求する高さ（Auto Layoutの制約から算出）を使う。
    ///
    /// 数値を直書きするとパネルの中身を変えたときに追従しないため `fittingSize` から取る。
    /// 上限を設けるのは、スクロール可能な中身を持つパネル（インスペクタ等）で極端に大きな値が
    /// 返ると境界をまったく動かせなくなるため。
    private func minimumHeight(forPanel panel: NSView) -> CGFloat {
        min(max(panel.fittingSize.height, 80), 280)
    }

    private func minimumWidth(forPane pane: NSView) -> CGFloat {
        if pane === canvasContainer { return 200 }
        if let inspector = sidePanels[.inspector],
           let split = pane as? NSSplitView,
           split.arrangedSubviews.contains(where: { $0 === inspector }) {
            return 340
        }
        return 160
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === leftPaneSplitView || splitView === rightPaneSplitView {
            guard !isRestoringSplitPositions else { return proposedMaximumPosition }
            let subviews = splitView.arrangedSubviews
            guard dividerIndex + 1 >= 0, dividerIndex + 1 < subviews.count else { return proposedMaximumPosition }
            let trailingView = subviews[dividerIndex + 1]
            guard !trailingView.isHidden else { return proposedMaximumPosition }
            return trailingView.frame.maxY - minimumHeight(forPanel: trailingView)
        }
        guard !isRestoringSplitPositions else { return proposedMaximumPosition }
        guard splitView === mainSplitView else { return proposedMaximumPosition }
        let subviews = splitView.arrangedSubviews
        guard dividerIndex + 1 >= 0, dividerIndex + 1 < subviews.count else { return proposedMaximumPosition }
        let trailingView = subviews[dividerIndex + 1]
        guard !trailingView.isHidden else { return proposedMaximumPosition }
        let minWidth: CGFloat = trailingView === canvasContainer ? 200 : minimumWidth(forPane: trailingView)
        return trailingView.frame.maxX - minWidth
    }

    /// サイドパネルはドラッグで完全に折りたためない（幅0への収縮は「◀▶」移動で行う仕様のため）。
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    /// 分割位置の変更（境界ドラッグ・ウィンドウリサイズ）をポータブル設定へ保存する。
    /// AppSettings側で0.3秒デバウンスされるためドラッグ中の多発書き込みは抑制される。
    func splitViewDidResizeSubviews(_ notification: Notification) {
        // レイヤ一覧の唯一の列（`layerOutlineView`）は`resizingMask = .autoresizingMask`だけでは
        // サイドパネルの分割ドラッグに追従せず、パネル幅が十分でもレイヤ名が旧い（狭い）列幅の
        // ままトランケートされ続ける不具合があった。分割位置が変わるたびに明示的に追従させる。
        layerOutlineView.sizeLastColumnToFit()

        guard !isRestoringSplitPositions,
              let leftPane = leftPaneSplitView,
              let rightPane = rightPaneSplitView,
              let mainSplit = mainSplitView,
              mainSplit.bounds.width > 0 else { return }
        let settings = AppSettings.shared
        // 最小幅未満の過渡的な幅（起動途中のレイアウト解決・ウィンドウ縮小の巻き添え等）は
        // 保存しない。保存すると次回起動時に「幅が微妙に狭い」状態が復元されてしまう
        //（GUI報告 2026-08-08: 起動直後のサイドツールパネル幅が微妙）。
        if !leftPane.isHidden, leftPane.frame.width >= minimumWidth(forPane: leftPane) {
            settings.set(Double(leftPane.frame.width), forKey: "Layout.leftPaneWidth")
        }
        if !rightPane.isHidden, rightPane.frame.width >= minimumWidth(forPane: rightPane) {
            settings.set(Double(rightPane.frame.width), forKey: "Layout.rightPaneWidth")
        }
        for (pane, key) in [(leftPane, "Layout.leftPaneHeights"), (rightPane, "Layout.rightPaneHeights")] {
            guard !pane.isHidden, pane.bounds.height > 0, !pane.arrangedSubviews.isEmpty else { continue }
            let heights = pane.arrangedSubviews.map(\.frame.height)
            guard zip(pane.arrangedSubviews, heights).allSatisfy({ panel, height in
                height >= min(80, minimumHeight(forPanel: panel))
            }) else { continue }
            settings.set(heights.map(Double.init), forKey: key)
        }
    }
}

extension MosaicWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// レイヤ一覧のルート表示順: モザイク対象 → 人物（グループ含む）→ 骨格 → 画像
    /// （従来の画像先頭から変更。ユーザー指定の並び順）。
    fileprivate func rootLayerItems() -> [AnyObject] {
        // ROIが1件も無いのに「モザイク対象」、画像未読込なのに「画像」が並んでいると、
        // 中身の無いレイヤがあるように見えて紛らわしい（GUI報告）。実体がある時だけ出す。
        let roiLeaves = canvas.rois.isEmpty ? [] : ungroupedLayers.filter { $0.kind == .roi }
        let personLeaves = ungroupedLayers.filter { $0.kind.isPerson }
        let poseLeaves = ungroupedLayers.filter { $0.kind.isPose }
        let imageLeaves = loadedImage == nil ? [] : ungroupedLayers.filter { $0.kind == .image }
        let others = ungroupedLayers.filter {
            $0.kind != .roi && $0.kind != .image && !$0.kind.isPerson && !$0.kind.isPose
        }
        return roiLeaves + layerGroups + personLeaves + poseLeaves + others + imageLeaves
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return rootLayerItems().count }
        if let group = item as? LayerGroup { return group.children.count }
        if let leaf = item as? LayerLeaf, leaf.kind == .roi {
            return roiListGroups.count + ungroupedROIEntries.count
        }
        if let roiGroup = item as? ROIListGroup { return roiGroup.children.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is LayerGroup { return true }
        if item is ROIListGroup { return true }
        if let leaf = item as? LayerLeaf, leaf.kind == .roi {
            return !roiListGroups.isEmpty || !ungroupedROIEntries.isEmpty
        }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            let items = rootLayerItems()
            if index < items.count { return items[index] }
        }
        if let group = item as? LayerGroup { return group.children[index] }
        if let roiGroup = item as? ROIListGroup { return roiGroup.children[index] }
        if let leaf = item as? LayerLeaf, leaf.kind == .roi {
            if index < roiListGroups.count { return roiListGroups[index] }
            return ungroupedROIEntries[index - roiListGroups.count]
        }
        // 現在の isItemExpandable() の実装では到達しないはずの分岐だが、`ungroupedLayers[0]` への
        // 固定インデックスアクセスは配列が空の場合にクラッシュしうる脆い書き方だった
        // （コードレビューで検出）。空でも安全なプレースホルダへフォールバックする。
        assertionFailure("outlineView(child:ofItem:) reached unexpected fallback for item: \(item ?? "nil")")
        return ungroupedLayers.first ?? LayerLeaf(kind: .image, isVisible: false)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("LayerRow")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? LayerRowView ?? LayerRowView()
        cell.identifier = identifier

        if let group = item as? LayerGroup {
            cell.configure(title: group.name, state: group.visibilityState, allowsMixed: true)
            cell.onToggle = { [weak self] in self?.toggleGroupVisibility(group) }
        } else if let leaf = item as? LayerLeaf {
            cell.configure(title: leaf.kind.title, state: leaf.isVisible ? .on : .off, allowsMixed: false)
            cell.onToggle = { [weak self] in self?.toggleLeafVisibility(leaf) }
        } else if let entry = item as? ROIListEntry {
            // モザイク対象1件の行。チェックで表示ON/OFF（画面表示のみ。出力には影響しない）
            cell.configure(
                title: entry.title,
                state: canvas.hiddenROIIDs.contains(entry.roiID) ? .off : .on,
                allowsMixed: false
            )
            cell.onToggle = { [weak self] in self?.toggleROIVisibility(entry.roiID) }
        } else if let roiGroup = item as? ROIListGroup {
            // カテゴリごとのグループ見出し。まとめて表示ON/OFFできる
            cell.configure(
                title: roiGroup.name,
                state: roiGroupVisibilityState(roiGroup),
                allowsMixed: true
            )
            cell.onToggle = { [weak self] in self?.toggleROIGroupVisibility(roiGroup) }
        }
        return cell
    }

    nonisolated func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        true
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let selectedItems = layerOutlineView.selectedRowIndexes.map { layerOutlineView.item(atRow: $0) }

        // 人物検出/骨格検出レイヤの選択を画像上の強調表示へ反映する
        // （レイヤ一覧の選択状態と画像上の表示を一致させる）。
        if let leaf = selectedItems.compactMap({ $0 as? LayerLeaf }).first, leaf.kind.isPerson || leaf.kind.isPose {
            canvas.selectedDetectionLayer = leaf.kind
        } else {
            canvas.selectedDetectionLayer = nil
        }

        // ROIグループ（またはROI選択リスト行の複数選択）を、画像上の一括選択・一括移動へ反映する
        // （「レイヤパネル上でグループ選択しても画像上で一括選択にならない」不具合の修正）。
        let selectedROIGroups = selectedItems.compactMap { $0 as? ROIListGroup }
        let selectedEntries = selectedItems.compactMap { $0 as? ROIListEntry }
        if !selectedROIGroups.isEmpty {
            canvas.selectedROIGroupIDs = Set(selectedROIGroups.flatMap { $0.children.map(\.roiID) })
        } else if selectedEntries.count >= 2 {
            canvas.selectedROIGroupIDs = Set(selectedEntries.map(\.roiID))
        } else {
            canvas.selectedROIGroupIDs = []
        }

        guard !isSyncingROISelection else { return }
        guard let entry = selectedEntries.first else { return }
        isSyncingROISelection = true
        canvas.selectedROIID = entry.roiID
        isSyncingROISelection = false
    }
}

@MainActor
final class LibraryGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("LibraryGridItem")

    private let thumbnailView = NSImageView()
    private let captionField = NSTextField(labelWithString: "")

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        captionField.font = MosaicWindowController.scaledFont(11)
        captionField.alignment = .center
        captionField.lineBreakMode = .byTruncatingMiddle
        captionField.maximumNumberOfLines = 1
        captionField.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(thumbnailView)
        container.addSubview(captionField)
        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            thumbnailView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            thumbnailView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            thumbnailView.heightAnchor.constraint(equalTo: thumbnailView.widthAnchor, multiplier: 0.75),
            captionField.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 4),
            captionField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            captionField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            captionField.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -2)
        ])
        self.view = container
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3).cgColor
                : NSColor.clear.cgColor
        }
    }

    func configure(image: NSImage?, caption: String) {
        thumbnailView.image = image
        captionField.stringValue = caption
        // NSCollectionView によるアイテム再利用時もフォントを毎回再適用し、テキストサイズ変更を即反映する。
        captionField.font = MosaicWindowController.scaledFont(11)
    }
}

@MainActor
final class ImageCanvasView: NSView {
    var rois: [MosaicROI] = [] {
        didSet {
            needsDisplay = true
            onROIsChanged?(rois)
        }
    }

    var currentShape: ROIShape = .ellipse
    var currentCategory: MosaicTargetCategory = .other
    var selectedROIID: UUID? {
        didSet {
            guard oldValue != selectedROIID else { return }
            needsDisplay = true
            onROISelectionChanged?(rois.first { $0.id == selectedROIID })
        }
    }

    var personLayerRects: [NormalizedRect] = [] { didSet { needsDisplay = true } }
    var poseLayerRects: [NormalizedRect] = [] { didSet { needsDisplay = true } }
    /// レイヤ一覧で選択中の人物検出/骨格検出レイヤ（画像上に強調枠を表示するため）。
    /// レイヤ一覧側の選択状態と画像上の表示を一致させる。
    fileprivate var selectedDetectionLayer: LayerKind? { didSet { needsDisplay = true } }
    /// 追跡プレビューで見失ったROIのID。該当ROIは警告色の枠で強調し、
    /// ユーザーが位置を直して新しいキーフレームにできることを示す（V3）。
    var trackingLostROIIDs: Set<UUID> = [] { didSet { needsDisplay = true } }
    /// レイヤ一覧でROIグループ（`ROIListGroup`）を選択したときの、そのグループに属するROIのID集合。
    /// 画像上でまとめて強調表示し、いずれか1つをドラッグするとグループ全体を一括移動できる
    /// （レイヤ一覧のグループ選択と画像上の一括範囲選択・一括移動を一致させる）。
    var selectedROIGroupIDs: Set<UUID> = [] { didSet { needsDisplay = true } }
    /// ツールバーで切替える画像上の操作モード。編集モードでは空白部分のドラッグで新規ROIを
    /// 作成する（従来通り）。範囲選択モードでは同じ操作が既存ROIのラバーバンド一括選択になる。
    /// Option(⌥)キーを押しながら開始したドラッグは、そのドラッグ限定で一時的に逆モードになる。
    enum InteractionMode {
        case edit
        case marqueeSelect
        /// マスク追加ペン。ドラッグでマスクを塗る（Option(⌥)で一時的に消しゴム）。
        case maskPaint
        /// マスク消しゴム。ドラッグでマスクを消す（Option(⌥)で一時的に追加ペン）。
        case maskErase

        /// ペン系（マスクを直接編集するモード）か。
        var editsMask: Bool { self == .maskPaint || self == .maskErase }
    }
    var interactionMode: InteractionMode = .edit {
        didSet { refreshHoverCursor() }
    }
    /// 範囲選択モードで複数ROIをラバーバンド選択したとき、レイヤ一覧側の選択にも反映するための通知。
    var onROIGroupSelectionByMarquee: ((Set<UUID>) -> Void)?
    private var dragIsMarqueeSelect = false
    /// 表示をOFFにしたレイヤ（ROI）。**画面表示だけの設定で、画像出力には影響しない。**
    /// 既存の「表示: ROI/モザイク/人物/骨格」と同じ扱いにする（隠したまま出力して
    /// 検閲漏れになるのを避けるため）。
    var hiddenROIIDs: Set<UUID> = [] { didSet { needsDisplay = true } }

    /// マスク追加ペン／マスク消しゴムの筆の太さ。ROIの短辺に対する割合。
    var maskBrushWidth: Double = 0.15
    /// 描画中のストローク（ROIローカル座標）。mouseUpで対象ROIへ確定する。
    private var maskStrokeInProgress: (roiID: UUID, points: [NormalizedPoint], isAdditive: Bool, isNewLayer: Bool)?
    /// タブレットペンは高頻度にdragイベントを送るため、画面上でほぼ同じ点は取り込まない。
    /// 筆跡は1px台の間隔で残せば見た目の連続性を保ちつつ、配列肥大化と再描画頻度を抑えられる。
    private var lastMaskStrokeViewPoint: NSPoint?
    private let maskStrokeMinimumViewSpacing: CGFloat = 1.25
    /// マスク追加ペン／消しゴムで塗った・消したときの通知（再描画・undo登録はコントローラ側で行う）。
    /// 第3引数は、このストロークのために `onMaskStrokeNeedsNewLayer` で新規レイヤを作ったか。
    /// true の場合、レイヤ追加時点で既にundoスナップショットを積んであるので、
    /// コントローラ側は最初のストロークぶんの追加スナップショットを積まない
    /// （「レイヤ追加＋最初のストローク」を1回のUndoで両方戻すため。コードレビューで検出）。
    var onMaskStrokeCompleted: ((UUID, ManualMaskStroke, Bool) -> Void)?
    /// マスク追加ペンで、対象レイヤが無いときに新しいレイヤを作る要求。
    /// 戻り値は作成したROIのID（作れなければnil）。
    var onMaskStrokeNeedsNewLayer: ((NormalizedRect) -> UUID?)?
    var personLayerVisibility: [Bool] = [] { didSet { needsDisplay = true } }
    var poseLayerVisibility: [Bool] = [] { didSet { needsDisplay = true } }
    var personLayerMasks: [CGImage?] = [] { didSet { needsDisplay = true } }
    var poseLayerBones: [[(from: CGPoint, to: CGPoint)]] = [] { didSet { needsDisplay = true } }
    var poseLayerJointPoints: [[CGPoint]] = [] { didSet { needsDisplay = true } }
    var showImageLayer = true { didSet { needsDisplay = true } }
    var showROILayer = true { didSet { needsDisplay = true } }
    // レイヤ毎の輪郭（枠線）・タグ（名称ラベル）表示（レイヤパネルの輪郭/タグチェックから制御）
    var showROIOutlines = true { didSet { needsDisplay = true } }
    var showROITags = true { didSet { needsDisplay = true } }
    var personLayerOutlineVisibility: [Bool] = [] { didSet { needsDisplay = true } }
    var personLayerTagVisibility: [Bool] = [] { didSet { needsDisplay = true } }
    var poseLayerOutlineVisibility: [Bool] = [] { didSet { needsDisplay = true } }
    var poseLayerTagVisibility: [Bool] = [] { didSet { needsDisplay = true } }

    /// フラッシュパターンの中心ハンドル（選択中ROIの塗りつぶしパターンがフラッシュのときだけ
    /// ウィンドウコントローラ側から設定される。nilなら非表示）。ROIローカル正規化座標（0〜1、左上原点）。
    var flashHandleLocal: NormalizedPoint? { didSet { needsDisplay = true } }

    var onROIsChanged: (([MosaicROI]) -> Void)?
    var onManualEditWillBegin: (() -> Void)?
    var onManualEditDidEnd: (() -> Void)?
    var onROISelectionChanged: ((MosaicROI?) -> Void)?
    var onZoomChanged: ((CGFloat) -> Void)?
    /// ROI右クリックメニューからのカテゴリ変更要求（ツールバーのカテゴリポップアップ廃止に伴う置き換え）
    var onCategoryChangeRequest: ((UUID, MosaicTargetCategory) -> Void)?
    /// 画像上の人物/骨格レイヤのダブルクリック削除要求（ROIのダブルクリック削除と操作を統一）
    fileprivate var onDetectionLayerDeleteRequest: ((LayerKind) -> Void)?
    /// 画像上のクリックで人物/骨格レイヤを選択したときの通知（レイヤ一覧の選択と同期する）
    fileprivate var onDetectionLayerSelected: ((LayerKind) -> Void)?
    /// 人物/骨格レイヤの移動完了通知（正規化座標の累積移動量。マスク・ボーンの追従に使う）
    fileprivate var onDetectionLayerMoved: ((LayerKind, Double, Double) -> Void)?

    /// 表示中の人物/骨格レイヤのヒットテスト（骨格優先）。ダブルクリック削除の対象判定に使う。
    fileprivate func detectionLayerHit(at point: NSPoint, imageRect: NSRect) -> LayerKind? {
        for (index, rect) in poseLayerRects.enumerated()
        where index < poseLayerVisibility.count && poseLayerVisibility[index] {
            if viewRect(from: rect, imageRect: imageRect).contains(point) { return .pose(index) }
        }
        for (index, rect) in personLayerRects.enumerated()
        where index < personLayerVisibility.count && personLayerVisibility[index] {
            if viewRect(from: rect, imageRect: imageRect).contains(point) { return .person(index) }
        }
        return nil
    }

    /// 表示中の人物/骨格レイヤの「枠線帯」（±8px）のヒットテスト。選択+移動の掴み判定に使う。
    fileprivate func detectionLayerEdgeHit(at point: NSPoint, imageRect: NSRect) -> LayerKind? {
        func hitsEdge(_ viewR: NSRect) -> Bool {
            let outer = viewR.insetBy(dx: -8, dy: -8)
            let inner = viewR.insetBy(dx: 8, dy: 8)
            return outer.contains(point) && !inner.contains(point)
        }
        for (index, rect) in poseLayerRects.enumerated()
        where index < poseLayerVisibility.count && poseLayerVisibility[index] {
            if hitsEdge(viewRect(from: rect, imageRect: imageRect)) { return .pose(index) }
        }
        for (index, rect) in personLayerRects.enumerated()
        where index < personLayerVisibility.count && personLayerVisibility[index] {
            if hitsEdge(viewRect(from: rect, imageRect: imageRect)) { return .person(index) }
        }
        return nil
    }

    private var lastSize: [ROIShape: NSSize] = [:]
    private var image: NSImage?
    private var imagePixelSize: CGSize = .zero
    private(set) var zoomFactor: CGFloat = 1
    private var panOffset: CGPoint = .zero
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var resizeState: ResizeState?
    private var moveState: MoveState?
    private var rotationState: RotationState?
    private var vertexDragState: VertexDragState?
    private var flashCenterDragState: FlashCenterDragState?

    private struct ResizeState {
        var roiID: UUID
        /// ローカル（無回転）座標系でのアンカー点
        var anchor: NSPoint
        /// ドラッグ開始時のROI中心（ビュー座標）
        var center: NSPoint
        var rotationDegrees: Double
    }

    private struct RotationState {
        var roiID: UUID
        var center: NSPoint
    }

    private struct VertexDragState {
        var roiID: UUID
        var vertexIndex: Int
        /// ドラッグ開始時のビュー座標rect（ドラッグ中は凍結し、終了時に外接矩形を再計算する）
        var rect: NSRect
        var center: NSPoint
        var rotationDegrees: Double
    }

    private struct FlashCenterDragState {
        var roiID: UUID
        /// ドラッグ開始時のビュー座標rect（回転中のROIでも一貫した基準を保つため凍結する）
        var rect: NSRect
        var center: NSPoint
        var rotationDegrees: Double
    }

    private struct MoveState {
        var roiID: UUID
        var lastPoint: NSPoint
        var didBeginEdit = false
    }

    /// ROIグループ（`selectedROIGroupIDs`）の一括移動用ドラッグ状態。
    private struct GroupMoveState {
        var roiIDs: Set<UUID>
        var lastPoint: NSPoint
        var didBeginEdit = false
    }
    private var groupMoveState: GroupMoveState?

    /// 人物/骨格レイヤの移動用ドラッグ状態（モザイク対象と同様の選択＆移動を可能にする）。
    /// マスク・ボーンの追従はドラッグ終了時にまとめて行うため、累積移動量を保持する。
    fileprivate struct DetectionMoveState {
        var kind: LayerKind
        var lastPoint: NSPoint
        var totalDX: Double = 0
        var totalDY: Double = 0
        var didMove = false
    }
    fileprivate var detectionMoveState: DetectionMoveState?

    private let handleRadius: CGFloat = 7
    private let dragThreshold: CGFloat = 4
    private static let maskPaintCursor = ImageCanvasView.makeSymbolCursor(
        symbolName: "paintbrush.pointed",
        fallback: .crosshair,
        hotSpot: NSPoint(x: 4, y: 21)
    )
    private static let maskEraseCursor = ImageCanvasView.makeSymbolCursor(
        symbolName: "eraser",
        fallback: .crosshair,
        hotSpot: NSPoint(x: 5, y: 20)
    )

    override var isFlipped: Bool { true }

    // MARK: - カーソル表示（操作に応じて分かりやすいカーソルへ変更）

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        guard image != nil, rightPanState == nil, moveState == nil, resizeState == nil else { return }
        applyHoverCursor(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    /// 現在の操作モード（Option押下による一時反転を含む）に応じたカーソルを設定する。
    /// 編集モード=＋（crosshair、ドラッグでROIを描く）、範囲選択モード=矢印（ドラッグで一括選択）。
    private func applyHoverCursor(at point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        let imageRect = imageDrawRect()
        guard imageRect.contains(point) else {
            NSCursor.arrow.set()
            return
        }
        if interactionMode.editsMask {
            maskCursor(erasing: currentMaskStrokeIsErasing(modifiers: modifiers)).set()
            return
        }
        let marquee = modifiers.contains(.option)
            ? interactionMode == .edit
            : interactionMode == .marqueeSelect
        let detectionKind = marquee
            ? detectionLayerHit(at: point, imageRect: imageRect)
            : detectionLayerEdgeHit(at: point, imageRect: imageRect)
        if roiHit(at: point, imageRect: imageRect) != nil || detectionKind != nil {
            NSCursor.openHand.set()
        } else {
            (marquee ? NSCursor.arrow : NSCursor.crosshair).set()
        }
    }

    private static func makeSymbolCursor(symbolName: String, fallback: NSCursor, hotSpot: NSPoint) -> NSCursor {
        guard let source = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return fallback
        }
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()
        source.draw(in: NSRect(x: 2, y: 2, width: 20, height: 20),
                    from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: hotSpot)
    }

    private func currentMaskStrokeIsErasing(modifiers: NSEvent.ModifierFlags) -> Bool {
        let inverted = modifiers.contains(.option)
        return (interactionMode == .maskErase) != inverted
    }

    private func maskCursor(erasing: Bool) -> NSCursor {
        erasing ? Self.maskEraseCursor : Self.maskPaintCursor
    }

    /// マウスを動かさなくても、Optionキーの押下/解放やモード切替の瞬間にカーソルを更新する。
    func refreshHoverCursor(modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        guard let window, image != nil, rightPanState == nil, moveState == nil, resizeState == nil else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return }
        applyHoverCursor(at: point, modifiers: modifiers)
    }

    private var flagsChangedMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // flagsChangedはファーストレスポンダにしか届かないため、ローカルモニタで受けて
        // Optionキーの一時モード切替に合わせてカーソル表示を即座に切り替える。
        if window != nil, flagsChangedMonitor == nil {
            flagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.refreshHoverCursor(modifiers: event.modifierFlags)
                return event
            }
        }
    }

    func setImage(_ cgImage: CGImage) {
        image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        imagePixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        needsDisplay = true
    }

    func setZoom(_ value: CGFloat) {
        zoomFactor = min(8, max(0.1, value))
        if zoomFactor <= 1.001 { panOffset = .zero }
        onZoomChanged?(zoomFactor)
        needsDisplay = true
    }

    func resetZoom() {
        panOffset = .zero
        setZoom(1)
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoomFactor * (1 + event.magnification))
    }

    /// ホイール上下回転=画像の拡大縮小。トラックパッドの2本指スクロールは従来どおりパン。
    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            guard zoomFactor > 1.001 else {
                super.scrollWheel(with: event)
                return
            }
            panOffset.x -= event.scrollingDeltaX
            panOffset.y -= event.scrollingDeltaY
            needsDisplay = true
            return
        }
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        setZoom(zoomFactor * (delta > 0 ? 1.1 : 1 / 1.1))
    }

    // MARK: - 右ボタンドラッグによる全体移動と右クリックメニュー

    private var rightPanState: (last: NSPoint, moved: Bool)?

    override func rightMouseDown(with event: NSEvent) {
        guard image != nil else { return }
        rightPanState = (convert(event.locationInWindow, from: nil), false)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard var state = rightPanState else { return }
        let point = convert(event.locationInWindow, from: nil)
        panOffset.x += point.x - state.last.x
        panOffset.y += point.y - state.last.y
        state.last = point
        state.moved = true
        rightPanState = state
        NSCursor.closedHand.set()
        needsDisplay = true
    }

    override func rightMouseUp(with event: NSEvent) {
        let moved = rightPanState?.moved ?? false
        rightPanState = nil
        NSCursor.crosshair.set()
        // ドラッグせず右クリックした場合のみ従来のカテゴリ変更メニューを表示する
        if !moved, let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    /// 表示画像を破棄してプレースホルダ表示に戻す（ライブラリから表示中画像を削除した場合など）。
    func clearImage() {
        image = nil
        imagePixelSize = .zero
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        dirtyRect.fill()

        guard let image else {
            drawPlaceholder()
            return
        }

        let target = imageDrawRect()
        if showImageLayer {
            image.draw(in: target)
        }
        drawDetectionLayers(in: target)
        if showROILayer {
            drawROIs(in: target)
        }
        drawMaskStrokePreview(in: target)
        if let dragStart, let dragCurrent {
            let rect = NSRect(
                x: min(dragStart.x, dragCurrent.x),
                y: min(dragStart.y, dragCurrent.y),
                width: abs(dragCurrent.x - dragStart.x),
                height: abs(dragCurrent.y - dragStart.y)
            )
            if dragIsMarqueeSelect {
                drawMarqueeSelectionRect(rect)
            } else {
                drawPreviewShape(rect)
            }
        }
    }

    // MARK: - 回転ヘルパー

    /// ビュー座標での点の回転（フリップ座標系のため正の角度が画面上で時計回りに見える）。
    private func rotatedPoint(_ point: NSPoint, around center: NSPoint, degrees: Double) -> NSPoint {
        guard abs(degrees) > 0.001 else { return point }
        let radians = degrees * .pi / 180
        let dx = point.x - center.x
        let dy = point.y - center.y
        return NSPoint(
            x: center.x + dx * cos(radians) - dy * sin(radians),
            y: center.y + dx * sin(radians) + dy * cos(radians)
        )
    }

    /// -180〜180度へ正規化する。
    private func normalizedDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }

    /// 回転を考慮したROIの当たり判定（点を無回転ローカル座標へ逆回転して矩形判定）。
    private func roiHit(at point: NSPoint, imageRect: NSRect) -> MosaicROI? {
        rois.last(where: { roi in
            let rect = viewRect(from: roi.rect, imageRect: imageRect)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let local = rotatedPoint(point, around: center, degrees: -roi.rotation)
            if roi.shape == .polygon {
                return polygonContains(localPoint: local, roi: roi, rect: rect)
            }
            return rect.contains(local)
        })
    }

    /// 回転ハンドル（選択ROI上部の丸）の位置。
    private func rotationHandlePoint(rect: NSRect, rotation: Double) -> NSPoint {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        return rotatedPoint(NSPoint(x: rect.midX, y: rect.minY - 22), around: center, degrees: rotation)
    }

    // MARK: - 多角形ヘルパー

    /// 多角形頂点のビュー座標（回転適用済み）。
    private func polygonVertexViewPoints(roi: MosaicROI, rect: NSRect) -> [NSPoint] {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        return (roi.polygonPoints ?? MosaicROI.defaultPolygonPoints).map { point in
            rotatedPoint(
                NSPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height),
                around: center,
                degrees: roi.rotation
            )
        }
    }

    /// 無回転ローカル座標での多角形内包判定（レイキャスティング）。
    private func polygonContains(localPoint: NSPoint, roi: MosaicROI, rect: NSRect) -> Bool {
        let points = (roi.polygonPoints ?? MosaicROI.defaultPolygonPoints).map { point in
            NSPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
        }
        guard points.count >= 3 else { return rect.contains(localPoint) }
        var inside = false
        var j = points.count - 1
        for i in 0..<points.count {
            let a = points[i]
            let b = points[j]
            if (a.y > localPoint.y) != (b.y > localPoint.y),
               localPoint.x < (b.x - a.x) * (localPoint.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// 頂点ドラッグ終了後に、多角形の外接矩形へrect/頂点座標を正規化し直す。
    /// 回転中のROIは回転中心がずれて見た目が跳ぶため正規化しない（頂点は0-1の範囲外も許容される）。
    private func renormalizePolygonBounds(roiID: UUID) {
        guard let index = rois.firstIndex(where: { $0.id == roiID }),
              abs(rois[index].rotation) < 0.01,
              let points = rois[index].polygonPoints, points.count >= 3 else { return }
        let rect = rois[index].rect
        let imagePoints = points.map { point in
            (x: rect.x + point.x * rect.width, y: rect.y + point.y * rect.height)
        }
        guard let minX = imagePoints.map(\.x).min(),
              let maxX = imagePoints.map(\.x).max(),
              let minY = imagePoints.map(\.y).min(),
              let maxY = imagePoints.map(\.y).max(),
              maxX - minX > 0.005, maxY - minY > 0.005 else { return }
        let newRect = NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        rois[index].rect = newRect
        rois[index].polygonPoints = imagePoints.map { point in
            NormalizedPoint(
                x: (point.x - newRect.x) / newRect.width,
                y: (point.y - newRect.y) / newRect.height
            )
        }
        lastSize[.polygon] = NSSize(width: newRect.width, height: newRect.height)
    }

    /// Option+クリックによる多角形頂点の追加（辺上）/削除（頂点上）。処理した場合true。
    private func handlePolygonVertexOptionClick(at point: NSPoint, imageRect: NSRect) -> Bool {
        guard let selectedID = selectedROIID,
              let index = rois.firstIndex(where: { $0.id == selectedID }),
              rois[index].shape == .polygon else { return false }
        let roi = rois[index]
        let rect = viewRect(from: roi.rect, imageRect: imageRect)
        let vertices = polygonVertexViewPoints(roi: roi, rect: rect)
        var points = roi.polygonPoints ?? MosaicROI.defaultPolygonPoints

        // 頂点上: 削除（3頂点は下限）
        if let vertexIndex = vertices.firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) <= handleRadius }) {
            guard points.count > 3 else { return true }
            onManualEditWillBegin?()
            points.remove(at: vertexIndex)
            rois[index].polygonPoints = points
            onManualEditDidEnd?()
            return true
        }

        // 辺上: 最寄りの辺へ頂点を挿入
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let local = rotatedPoint(point, around: center, degrees: -roi.rotation)
        var best: (edgeIndex: Int, distance: CGFloat, projection: NSPoint)?
        let localVertices = points.map { p in
            NSPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
        }
        for i in 0..<localVertices.count {
            let a = localVertices[i]
            let b = localVertices[(i + 1) % localVertices.count]
            let abx = b.x - a.x
            let aby = b.y - a.y
            let lengthSq = abx * abx + aby * aby
            guard lengthSq > 0.001 else { continue }
            let t = max(0, min(1, ((local.x - a.x) * abx + (local.y - a.y) * aby) / lengthSq))
            let projection = NSPoint(x: a.x + t * abx, y: a.y + t * aby)
            let distance = hypot(local.x - projection.x, local.y - projection.y)
            if best == nil || distance < best!.distance {
                best = (i, distance, projection)
            }
        }
        guard let best, best.distance <= 8, rect.width > 0, rect.height > 0 else { return false }
        onManualEditWillBegin?()
        points.insert(
            NormalizedPoint(
                x: (best.projection.x - rect.minX) / rect.width,
                y: (best.projection.y - rect.minY) / rect.height
            ),
            at: best.edgeIndex + 1
        )
        rois[index].polygonPoints = points
        onManualEditDidEnd?()
        return true
    }

    /// ROI上の右クリックで対象カテゴリを変更するコンテキストメニューを表示する。
    override func menu(for event: NSEvent) -> NSMenu? {
        guard image != nil else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let imageRect = imageDrawRect()
        guard let hit = roiHit(at: point, imageRect: imageRect) else {
            return nil
        }
        selectedROIID = hit.id
        let menu = NSMenu()
        let header = NSMenuItem(title: "対象カテゴリ", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for category in MosaicTargetCategory.allCases {
            let item = NSMenuItem(title: category.displayName, action: #selector(changeROICategory(_:)), keyEquivalent: "")
            item.target = self
            item.state = category == hit.category ? .on : .off
            item.representedObject = category.rawValue
            menu.addItem(item)
        }
        return menu
    }

    @objc private func changeROICategory(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let category = MosaicTargetCategory(rawValue: raw),
              let selectedID = selectedROIID else { return }
        onCategoryChangeRequest?(selectedID, category)
    }

    override func mouseDown(with event: NSEvent) {
        guard image != nil else { return }
        // 直前のドラッグ操作がmouseUpを受け取らないまま中断した場合（ウィンドウがキーを失う、
        // シートが割り込む等）、古いジェスチャー状態が残ってしまい、次のドラッグを乗っ取って
        // 別のROIを意図せず移動・リサイズ・回転させる不具合があった（コードレビューで検出）。
        // 新しいジェスチャーを判定する前に必ず全状態をクリアする。
        vertexDragState = nil
        rotationState = nil
        resizeState = nil
        moveState = nil
        groupMoveState = nil
        flashCenterDragState = nil
        detectionMoveState = nil
        dragStart = nil
        dragCurrent = nil
        let point = convert(event.locationInWindow, from: nil)

        // ペン系（マスク追加ペン／マスク消しゴム）: 選択中のROIへ塗る／消す。
        // Option(⌥)を押している間は、もう一方の動作へ一時的に切り替わる。
        if interactionMode.editsMask {
            let inverted = event.modifierFlags.contains(.option)
            let erasing = (interactionMode == .maskErase) != inverted
            beginMaskStroke(at: point, erasing: erasing)
            return
        }

        // Option+クリック: 多角形の頂点追加（辺上）/削除（頂点上）
        if event.clickCount < 2, event.modifierFlags.contains(.option),
           handlePolygonVertexOptionClick(at: point, imageRect: imageDrawRect()) {
            return
        }

        // 回転・リサイズ・頂点ハンドルは画像端のROIで画像範囲の外側に出ることがあるため、
        // 画像範囲ガードより先に判定する
        if event.clickCount < 2,
           let selectedID = selectedROIID,
           let roi = rois.first(where: { $0.id == selectedID }) {
            let imageRect = imageDrawRect()
            let rect = viewRect(from: roi.rect, imageRect: imageRect)
            let handle = rotationHandlePoint(rect: rect, rotation: roi.rotation)
            if hypot(handle.x - point.x, handle.y - point.y) <= handleRadius + 2 {
                onManualEditWillBegin?()
                rotationState = RotationState(roiID: selectedID, center: NSPoint(x: rect.midX, y: rect.midY))
                return
            }
            // フラッシュ中心ハンドル（パターンがフラッシュのROI選択時のみ表示される）
            if let local = flashHandleLocal {
                let center = NSPoint(x: rect.midX, y: rect.midY)
                let raw = NSPoint(x: rect.minX + local.x * rect.width, y: rect.minY + local.y * rect.height)
                let flashHandle = rotatedPoint(raw, around: center, degrees: roi.rotation)
                if hypot(flashHandle.x - point.x, flashHandle.y - point.y) <= handleRadius + 2 {
                    onManualEditWillBegin?()
                    flashCenterDragState = FlashCenterDragState(
                        roiID: selectedID,
                        rect: rect,
                        center: center,
                        rotationDegrees: roi.rotation
                    )
                    return
                }
            }
            // 多角形の頂点ドラッグ（四隅リサイズより優先）
            if roi.shape == .polygon {
                let vertices = polygonVertexViewPoints(roi: roi, rect: rect)
                if let vertexIndex = vertices.firstIndex(where: {
                    hypot($0.x - point.x, $0.y - point.y) <= handleRadius
                }) {
                    onManualEditWillBegin?()
                    vertexDragState = VertexDragState(
                        roiID: selectedID,
                        vertexIndex: vertexIndex,
                        rect: rect,
                        center: NSPoint(x: rect.midX, y: rect.midY),
                        rotationDegrees: roi.rotation
                    )
                    return
                }
            }
            if let anchor = handleAnchor(at: point, roi: roi, imageRect: imageRect) {
                onManualEditWillBegin?()
                resizeState = ResizeState(
                    roiID: selectedID,
                    anchor: anchor,
                    center: NSPoint(x: rect.midX, y: rect.midY),
                    rotationDegrees: roi.rotation
                )
                return
            }
        }

        guard imageDrawRect().contains(point) else { return }

        if event.clickCount >= 2 {
            let imageRect = imageDrawRect()
            if let hit = roiHit(at: point, imageRect: imageRect) {
                onManualEditWillBegin?()
                if selectedROIID == hit.id { selectedROIID = nil }
                rois.removeAll { $0.id == hit.id }
                onManualEditDidEnd?()
                return
            }
            // ROIに当たらない場合、表示中の人物/骨格レイヤのダブルクリックでもレイヤを削除できる
            // （モザイク範囲のダブルクリック削除と操作を統一）。骨格を先に判定する
            // （骨格の表示領域は対応する人物領域と重なるため、内側にある方を優先）。
            if let kind = detectionLayerHit(at: point, imageRect: imageRect) {
                onDetectionLayerDeleteRequest?(kind)
                return
            }
        }

        let imageRect = imageDrawRect()
        if let hit = roiHit(at: point, imageRect: imageRect) {
            // レイヤ一覧でROIグループを選択中、そのグループに属するROIをクリックした場合は
            // グループ全体を一括移動する（レイヤ一覧のグループ選択と画像上の一括選択・
            // 一括移動を一致させる）。
            if !event.modifierFlags.contains(.command), selectedROIGroupIDs.contains(hit.id) {
                groupMoveState = GroupMoveState(roiIDs: selectedROIGroupIDs, lastPoint: point)
                return
            }
            // Command+ドラッグ: 選択中のレイヤ（ROI）をコピーしてから移動する
            // （Finderのオプションドラッグ相当。コピーはドラッグ開始と同時に生成し、
            // 元のROIはその場に残す）。
            if event.modifierFlags.contains(.command) {
                onManualEditWillBegin?()
                var duplicate = hit
                duplicate.id = UUID()
                rois.append(duplicate)
                selectedROIID = duplicate.id
                moveState = MoveState(roiID: duplicate.id, lastPoint: point, didBeginEdit: true)
                return
            }
            selectedROIID = hit.id
            moveState = MoveState(roiID: hit.id, lastPoint: point)
            return
        }

        // Optionキーを押しながらの場合、このドラッグ限定でモードを一時的に入れ替える
        // （Photoshopのスペースキー一時パン切替と同様の考え方）。
        let wantsMarquee = event.modifierFlags.contains(.option)
            ? interactionMode == .edit
            : interactionMode == .marqueeSelect

        // 表示中の人物/骨格レイヤのクリックで選択+ドラッグ移動（モザイク対象と同じ操作感）。
        // 編集モードでは、人物矩形が画面の大部分を覆うことがあり内側クリックまで奪うと
        // ROIの新規作成ドラッグができなくなるため、枠の帯（±8px）のみを掴む。
        // 範囲選択モードでは新規作成と競合しないため、矩形内側のどこでも掴んで移動できる。
        let detectionKind = wantsMarquee
            ? detectionLayerHit(at: point, imageRect: imageRect)
            : detectionLayerEdgeHit(at: point, imageRect: imageRect)
        if let kind = detectionKind {
            selectedDetectionLayer = kind
            onDetectionLayerSelected?(kind)
            detectionMoveState = DetectionMoveState(kind: kind, lastPoint: point)
            return
        }

        dragIsMarqueeSelect = wantsMarquee
        selectedROIID = nil
        if !wantsMarquee {
            selectedROIGroupIDs = []
        }
        dragStart = point
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if interactionMode.editsMask {
            extendMaskStroke(to: convert(event.locationInWindow, from: nil))
            return
        }
        let point = convert(event.locationInWindow, from: nil)

        if let vertexDrag = vertexDragState {
            guard let index = rois.firstIndex(where: { $0.id == vertexDrag.roiID }),
                  var points = rois[index].polygonPoints,
                  vertexDrag.vertexIndex < points.count,
                  vertexDrag.rect.width > 0, vertexDrag.rect.height > 0 else { return }
            // 回転中のROIはマウス点を無回転ローカル座標へ逆回転してから頂点を更新する
            let local = rotatedPoint(point, around: vertexDrag.center, degrees: -vertexDrag.rotationDegrees)
            points[vertexDrag.vertexIndex] = NormalizedPoint(
                x: (local.x - vertexDrag.rect.minX) / vertexDrag.rect.width,
                y: (local.y - vertexDrag.rect.minY) / vertexDrag.rect.height
            )
            rois[index].polygonPoints = points
            return
        }

        if let flashDrag = flashCenterDragState {
            guard flashDrag.rect.width > 0, flashDrag.rect.height > 0 else { return }
            // 回転中のROIはマウス点を無回転ローカル座標へ逆回転してから中心位置を更新する
            let local = rotatedPoint(point, around: flashDrag.center, degrees: -flashDrag.rotationDegrees)
            let newLocal = NormalizedPoint(
                x: min(max(0, (local.x - flashDrag.rect.minX) / flashDrag.rect.width), 1),
                y: min(max(0, (local.y - flashDrag.rect.minY) / flashDrag.rect.height), 1)
            )
            flashHandleLocal = newLocal
            if let index = rois.firstIndex(where: { $0.id == flashDrag.roiID }) {
                rois[index].style?.flashCenter = newLocal
            }
            return
        }

        if let rotation = rotationState {
            guard let index = rois.firstIndex(where: { $0.id == rotation.roiID }) else { return }
            // ハンドルはROI上方に付くため、マウス方向の角度+90度が回転角になる
            let angle = atan2(point.y - rotation.center.y, point.x - rotation.center.x) * 180 / .pi + 90
            // 45度の倍数の近く（±3度）はスナップ
            let nearest = (angle / 45).rounded() * 45
            let snapped = abs(angle - nearest) <= 3 ? nearest : angle
            rois[index].rotation = normalizedDegrees(snapped)
            return
        }

        if let resize = resizeState {
            // 回転中のROIはマウス点を無回転ローカル座標へ逆回転してからリサイズする
            let local = rotatedPoint(point, around: resize.center, degrees: -resize.rotationDegrees)
            let newViewRect = NSRect(
                x: min(resize.anchor.x, local.x),
                y: min(resize.anchor.y, local.y),
                width: abs(local.x - resize.anchor.x),
                height: abs(local.y - resize.anchor.y)
            )
            if let normalized = normalizedRect(fromViewRect: newViewRect),
               let index = rois.firstIndex(where: { $0.id == resize.roiID }) {
                rois[index].rect = normalized.clamped()
            }
            return
        }

        if var move = moveState {
            let imageRect = imageDrawRect()
            guard imageRect.width > 0, imageRect.height > 0,
                  let index = rois.firstIndex(where: { $0.id == move.roiID }) else { return }
            if !move.didBeginEdit {
                guard hypot(point.x - move.lastPoint.x, point.y - move.lastPoint.y) >= dragThreshold else { return }
                onManualEditWillBegin?()
                move.didBeginEdit = true
            }
            let dx = (point.x - move.lastPoint.x) / imageRect.width
            let dy = (point.y - move.lastPoint.y) / imageRect.height
            var rect = rois[index].rect
            rect.x = min(max(0, rect.x + dx), 1 - rect.width)
            rect.y = min(max(0, rect.y + dy), 1 - rect.height)
            rois[index].rect = rect
            move.lastPoint = point
            moveState = move
            NSCursor.closedHand.set()
            return
        }

        if var detectionMove = detectionMoveState {
            let imageRect = imageDrawRect()
            guard imageRect.width > 0, imageRect.height > 0 else { return }
            let dx = Double((point.x - detectionMove.lastPoint.x) / imageRect.width)
            let dy = Double((point.y - detectionMove.lastPoint.y) / imageRect.height)
            switch detectionMove.kind {
            case .person(let index) where index < personLayerRects.count:
                var rect = personLayerRects[index]
                rect.x = min(max(0, rect.x + dx), 1 - rect.width)
                rect.y = min(max(0, rect.y + dy), 1 - rect.height)
                personLayerRects[index] = rect
            case .pose(let index) where index < poseLayerRects.count:
                var rect = poseLayerRects[index]
                rect.x = min(max(0, rect.x + dx), 1 - rect.width)
                rect.y = min(max(0, rect.y + dy), 1 - rect.height)
                poseLayerRects[index] = rect
            default:
                return
            }
            detectionMove.totalDX += dx
            detectionMove.totalDY += dy
            detectionMove.lastPoint = point
            detectionMove.didMove = true
            detectionMoveState = detectionMove
            NSCursor.closedHand.set()
            return
        }

        if var groupMove = groupMoveState {
            let imageRect = imageDrawRect()
            guard imageRect.width > 0, imageRect.height > 0 else { return }
            if !groupMove.didBeginEdit {
                guard hypot(point.x - groupMove.lastPoint.x, point.y - groupMove.lastPoint.y) >= dragThreshold else { return }
                onManualEditWillBegin?()
                groupMove.didBeginEdit = true
            }
            let dx = (point.x - groupMove.lastPoint.x) / imageRect.width
            let dy = (point.y - groupMove.lastPoint.y) / imageRect.height
            for index in rois.indices where groupMove.roiIDs.contains(rois[index].id) {
                var rect = rois[index].rect
                rect.x = min(max(0, rect.x + dx), 1 - rect.width)
                rect.y = min(max(0, rect.y + dy), 1 - rect.height)
                rois[index].rect = rect
            }
            groupMove.lastPoint = point
            groupMoveState = groupMove
            NSCursor.closedHand.set()
            return
        }

        guard dragStart != nil else { return }
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if interactionMode.editsMask {
            finishMaskStroke()
            return
        }
        let point = convert(event.locationInWindow, from: nil)

        if let vertexDrag = vertexDragState {
            vertexDragState = nil
            renormalizePolygonBounds(roiID: vertexDrag.roiID)
            needsDisplay = true
            onManualEditDidEnd?()
            return
        }

        if rotationState != nil {
            rotationState = nil
            needsDisplay = true
            onManualEditDidEnd?()
            return
        }

        if flashCenterDragState != nil {
            flashCenterDragState = nil
            needsDisplay = true
            onManualEditDidEnd?()
            return
        }

        if let resize = resizeState {
            resizeState = nil
            if let index = rois.firstIndex(where: { $0.id == resize.roiID }) {
                lastSize[rois[index].shape] = NSSize(width: rois[index].rect.width, height: rois[index].rect.height)
            }
            needsDisplay = true
            onManualEditDidEnd?()
            return
        }

        if let move = moveState {
            moveState = nil
            needsDisplay = true
            if move.didBeginEdit {
                onManualEditDidEnd?()
            }
            return
        }

        if let groupMove = groupMoveState {
            groupMoveState = nil
            needsDisplay = true
            if groupMove.didBeginEdit {
                onManualEditDidEnd?()
            }
            return
        }

        if let detectionMove = detectionMoveState {
            detectionMoveState = nil
            needsDisplay = true
            if detectionMove.didMove {
                // マスク・ボーンの追従はドラッグ完了時に累積移動量でまとめて行う（毎フレームの
                // 全面画像再生成を避けるため）。
                onDetectionLayerMoved?(detectionMove.kind, detectionMove.totalDX, detectionMove.totalDY)
            }
            return
        }

        guard let start = dragStart else { return }
        let wasMarqueeSelect = dragIsMarqueeSelect
        defer {
            dragStart = nil
            dragCurrent = nil
            dragIsMarqueeSelect = false
            needsDisplay = true
        }

        guard imageDrawRect().contains(start) else { return }

        if wasMarqueeSelect {
            // 範囲選択モード: 空白部分のドラッグは新規ROI作成ではなく、矩形と重なる
            // 既存ROIすべてのラバーバンド一括選択にする（クリックのみの場合は選択解除のみ）。
            guard hypot(point.x - start.x, point.y - start.y) >= dragThreshold else { return }
            let marqueeRect = NSRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(point.x - start.x),
                height: abs(point.y - start.y)
            )
            let imageRect = imageDrawRect()
            let hitIDs = Set(rois.filter { roi in
                viewRect(from: roi.rect, imageRect: imageRect).intersects(marqueeRect)
            }.map(\.id))
            selectedROIGroupIDs = hitIDs
            onROIGroupSelectionByMarquee?(hitIDs)
            return
        }

        if hypot(point.x - start.x, point.y - start.y) < dragThreshold {
            addROIWithRememberedSize(at: point)
            return
        }

        let rect = NSRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        )
        guard rect.width >= 8, rect.height >= 8 else { return }
        guard let normalized = normalizedRect(fromViewRect: rect) else { return }
        onManualEditWillBegin?()
        lastSize[currentShape] = NSSize(width: normalized.width, height: normalized.height)
        var roi = MosaicROI(rect: normalized, confidence: 1, source: "manual", shape: currentShape, category: currentCategory)
        if currentShape == .polygon {
            roi.polygonPoints = MosaicROI.defaultPolygonPoints
        }
        rois.append(roi)
        selectedROIID = roi.id
        onManualEditDidEnd?()
    }

    private func addROIWithRememberedSize(at point: NSPoint) {
        guard let size = lastSize[currentShape] else { return }
        let imageRect = imageDrawRect()
        guard imageRect.width > 0, imageRect.height > 0 else { return }
        let normalizedPoint = CGPoint(
            x: (point.x - imageRect.minX) / imageRect.width,
            y: (point.y - imageRect.minY) / imageRect.height
        )
        let rect = NormalizedRect(
            x: normalizedPoint.x - size.width / 2,
            y: normalizedPoint.y - size.height / 2,
            width: size.width,
            height: size.height
        ).clamped()
        onManualEditWillBegin?()
        var roi = MosaicROI(rect: rect, confidence: 1, source: "manual", shape: currentShape, category: currentCategory)
        if currentShape == .polygon {
            roi.polygonPoints = MosaicROI.defaultPolygonPoints
        }
        rois.append(roi)
        selectedROIID = roi.id
        onManualEditDidEnd?()
    }

    /// 四隅リサイズハンドルの判定。回転中のROIはマウス点をローカル座標へ逆回転して判定し、
    /// アンカー（対角）もローカル座標で返す。
    private func handleAnchor(at point: NSPoint, roi: MosaicROI, imageRect: NSRect) -> NSPoint? {
        let rect = viewRect(from: roi.rect, imageRect: imageRect)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let local = rotatedPoint(point, around: center, degrees: -roi.rotation)
        let corners: [(handle: NSPoint, anchor: NSPoint)] = [
            (NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.maxY)),
            (NSPoint(x: rect.maxX, y: rect.minY), NSPoint(x: rect.minX, y: rect.maxY)),
            (NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.minY)),
            (NSPoint(x: rect.maxX, y: rect.maxY), NSPoint(x: rect.minX, y: rect.minY))
        ]
        for corner in corners where abs(corner.handle.x - local.x) <= handleRadius && abs(corner.handle.y - local.y) <= handleRadius {
            return corner.anchor
        }
        return nil
    }

    private func drawPlaceholder() {
        let text = "画像を開く"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: MosaicWindowController.scaledFont(28, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func drawROIs(in target: NSRect) {
        for roi in rois where !hiddenROIIDs.contains(roi.id) {
            let rect = viewRect(from: roi.rect, imageRect: target)
            let color: NSColor = roi.source == "manual" ? .systemGreen : .systemRed
            if showROIOutlines {
                drawShape(roi, rect: rect, color: color)
            }
            if showROITags {
                drawCategoryLabel(roi, near: rect, color: color)
            }
            if trackingLostROIIDs.contains(roi.id) {
                drawTrackingLostWarning(rect)
            }
            if roi.id == selectedROIID {
                drawSelectionHandles(rect, rotation: roi.rotation)
                drawRotationHandle(rect: rect, rotation: roi.rotation)
                if roi.shape == .polygon {
                    drawPolygonVertexHandles(roi: roi, rect: rect)
                }
                if let local = flashHandleLocal {
                    drawFlashCenterHandle(local: local, rect: rect, rotation: roi.rotation)
                }
            } else if selectedROIGroupIDs.contains(roi.id) {
                drawSelectedLayerHighlight(rect)
            }
        }
    }

    private func drawMaskStrokePreview(in imageRect: NSRect) {
        guard let state = maskStrokeInProgress,
              !state.points.isEmpty,
              let roi = rois.first(where: { $0.id == state.roiID }) else { return }
        let rect = viewRect(from: roi.rect, imageRect: imageRect)
        guard rect.width > 0, rect.height > 0 else { return }

        let points = state.points.map { point in
            NSPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
        }
        let lineWidth = max(2, min(rect.width, rect.height) * CGFloat(maskBrushWidth))
        let color = state.isAdditive ? NSColor.systemGreen : NSColor.systemRed
        color.withAlphaComponent(0.72).setStroke()
        color.withAlphaComponent(0.22).setFill()

        if points.count == 1, let point = points.first {
            let dotRect = NSRect(
                x: point.x - lineWidth / 2,
                y: point.y - lineWidth / 2,
                width: lineWidth,
                height: lineWidth
            )
            NSBezierPath(ovalIn: dotRect).fill()
            return
        }

        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = lineWidth
        path.stroke()
    }

    /// ROIのカテゴリ名を矩形の左上へ小さく表示する（対象カテゴリ変更の結果を画面上で確認できるようにする）。
    private func drawCategoryLabel(_ roi: MosaicROI, near rect: NSRect, color: NSColor) {
        let text = roi.category.displayName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: MosaicWindowController.scaledFont(10, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: color.withAlphaComponent(0.85)
        ]
        let size = text.size(withAttributes: attributes)
        let y = rect.minY - size.height - 2 >= 0 ? rect.minY - size.height - 2 : rect.minY + 2
        text.draw(at: CGPoint(x: max(0, rect.minX), y: y), withAttributes: attributes)
    }

    private func drawShape(_ roi: MosaicROI, rect: NSRect, color: NSColor) {
        let path: NSBezierPath
        switch roi.shape {
        case .ellipse:
            path = NSBezierPath(ovalIn: rect)
        case .rectangle:
            path = NSBezierPath(rect: rect)
        case .polygon:
            path = Self.polygonPath(points: roi.polygonPoints ?? MosaicROI.defaultPolygonPoints, rect: rect)
        }
        applyRotation(to: path, rect: rect, degrees: roi.rotation)
        color.withAlphaComponent(0.18).setFill()
        path.fill()
        color.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    /// 多角形頂点（rectローカル正規化座標）からビュー座標のパスを構築する。
    private static func polygonPath(points: [NormalizedPoint], rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        guard points.count >= 3 else {
            path.appendRect(rect)
            return path
        }
        for (index, point) in points.enumerated() {
            let viewPoint = NSPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
            if index == 0 {
                path.move(to: viewPoint)
            } else {
                path.line(to: viewPoint)
            }
        }
        path.close()
        return path
    }

    /// パスへ矩形中心基準の回転を適用する。
    private func applyRotation(to path: NSBezierPath, rect: NSRect, degrees: Double) {
        guard abs(degrees) > 0.01 else { return }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.midY)
        transform.rotate(byDegrees: degrees)
        transform.translateX(by: -rect.midX, yBy: -rect.midY)
        path.transform(using: transform as AffineTransform)
    }

    /// 回転ハンドル（選択ROI上部の丸と接続線）を描画する。
    private func drawRotationHandle(rect: NSRect, rotation: Double) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let top = rotatedPoint(NSPoint(x: rect.midX, y: rect.minY), around: center, degrees: rotation)
        let handle = rotationHandlePoint(rect: rect, rotation: rotation)
        NSColor.controlAccentColor.setStroke()
        let line = NSBezierPath()
        line.move(to: top)
        line.line(to: handle)
        line.lineWidth = 1
        line.stroke()
        let circle = NSBezierPath(ovalIn: NSRect(x: handle.x - 5, y: handle.y - 5, width: 10, height: 10))
        NSColor.white.setFill()
        circle.fill()
        NSColor.controlAccentColor.setStroke()
        circle.lineWidth = 1.5
        circle.stroke()
    }

    /// 追跡で見失ったROIの警告枠（黄色の破線）。位置が直前フレームのまま保持されていることを示す。
    private func drawTrackingLostWarning(_ rect: NSRect) {
        let path = NSBezierPath(rect: rect.insetBy(dx: -3, dy: -3))
        path.lineWidth = 2.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemYellow.setStroke()
        path.stroke()
    }

    /// フラッシュパターンの中心ハンドル（ドラッグして放射の中心位置を指定できる、十字マーク付きの丸）。
    private func drawFlashCenterHandle(local: NormalizedPoint, rect: NSRect, rotation: Double) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let raw = NSPoint(x: rect.minX + local.x * rect.width, y: rect.minY + local.y * rect.height)
        let handle = rotatedPoint(raw, around: center, degrees: rotation)
        let circle = NSBezierPath(ovalIn: NSRect(x: handle.x - 6, y: handle.y - 6, width: 12, height: 12))
        NSColor.systemYellow.setFill()
        circle.fill()
        NSColor.black.setStroke()
        circle.lineWidth = 1.5
        circle.stroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: handle.x - 4, y: handle.y))
        cross.line(to: NSPoint(x: handle.x + 4, y: handle.y))
        cross.move(to: NSPoint(x: handle.x, y: handle.y - 4))
        cross.line(to: NSPoint(x: handle.x, y: handle.y + 4))
        cross.lineWidth = 1
        NSColor.black.setStroke()
        cross.stroke()
    }

    /// 多角形の頂点ハンドル（丸）を描画する。ドラッグで変形、Option+クリックで追加/削除。
    private func drawPolygonVertexHandles(roi: MosaicROI, rect: NSRect) {
        for vertex in polygonVertexViewPoints(roi: roi, rect: rect) {
            let handle = NSBezierPath(ovalIn: NSRect(x: vertex.x - 4, y: vertex.y - 4, width: 8, height: 8))
            NSColor.white.setFill()
            handle.fill()
            NSColor.systemGreen.setStroke()
            handle.lineWidth = 1.5
            handle.stroke()
        }
    }

    private func drawPreviewShape(_ rect: NSRect) {
        let path: NSBezierPath
        switch currentShape {
        case .ellipse: path = NSBezierPath(ovalIn: rect)
        case .rectangle: path = NSBezierPath(rect: rect)
        case .polygon: path = Self.polygonPath(points: MosaicROI.defaultPolygonPoints, rect: rect)
        }
        NSColor.systemYellow.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    /// 範囲選択モードのラバーバンド矩形（点線。新規ROI作成時の実線プレビューと区別する）。
    private func drawMarqueeSelectionRect(_ rect: NSRect) {
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.5
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        path.fill()
    }

    private func drawSelectionHandles(_ rect: NSRect, rotation: Double = 0) {
        let size: CGFloat = 8
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let points = [
            NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY)
        ].map { rotatedPoint($0, around: center, degrees: rotation) }
        for point in points {
            let handleRect = NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            let path = NSBezierPath(rect: handleRect)
            NSColor.white.setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    private func drawDetectionLayers(in target: NSRect) {
        for (index, rect) in personLayerRects.enumerated() {
            guard index < personLayerVisibility.count, personLayerVisibility[index] else { continue }
            let showsOutline = index < personLayerOutlineVisibility.count ? personLayerOutlineVisibility[index] : true
            let showsTag = index < personLayerTagVisibility.count ? personLayerTagVisibility[index] : true
            let viewR = viewRect(from: rect, imageRect: target)
            if index < personLayerMasks.count, let mask = personLayerMasks[index] {
                // NSImage.draw(in:from:operation:fraction:)はflippedビューで上下反転を補正しない
                // （respectFlipped指定なしの既定はfalse）。人物マスクだけ上下反転・鏡映位置に
                // 表示される不具合の真因だったため、respectFlipped: trueを明示する。
                NSImage(cgImage: mask, size: NSSize(width: mask.width, height: mask.height))
                    .draw(in: target, from: .zero, operation: .sourceOver, fraction: 0.9,
                          respectFlipped: true, hints: nil)
                if showsOutline {
                    drawDashedRect(viewR, color: .systemBlue)
                }
            } else if showsOutline {
                drawLayerRect(viewR, color: .systemBlue)
            }
            if showsTag {
                drawLayerName("人物\(index + 1)", in: viewR, color: .systemBlue)
            }
            if case .person(index) = selectedDetectionLayer {
                drawSelectedLayerHighlight(viewR)
            }
        }
        for (index, rect) in poseLayerRects.enumerated() {
            guard index < poseLayerVisibility.count, poseLayerVisibility[index] else { continue }
            let showsOutline = index < poseLayerOutlineVisibility.count ? poseLayerOutlineVisibility[index] : true
            let showsTag = index < poseLayerTagVisibility.count ? poseLayerTagVisibility[index] : true
            let viewR = viewRect(from: rect, imageRect: target)
            if showsOutline {
                drawLayerRect(viewR, color: .systemOrange)
            }
            if index < poseLayerBones.count {
                drawBones(
                    poseLayerBones[index],
                    jointPoints: index < poseLayerJointPoints.count ? poseLayerJointPoints[index] : [],
                    imageRect: target
                )
            }
            if showsTag {
                drawLayerName("骨格\(index + 1)", in: viewR, color: .systemOrange)
            }
            if case .pose(index) = selectedDetectionLayer {
                drawSelectedLayerHighlight(viewR)
            }
        }
    }

    /// レイヤ一覧で選択中の人物検出/骨格検出レイヤを画像上に強調表示する。
    private func drawSelectedLayerHighlight(_ rect: NSRect) {
        let path = NSBezierPath(rect: rect.insetBy(dx: -2, dy: -2))
        path.lineWidth = 3
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    /// レイヤ範囲の右下内側にレイヤ名を表示する。
    private func drawLayerName(_ text: String, in rect: NSRect, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: MosaicWindowController.scaledFont(10, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: color.withAlphaComponent(0.85)
        ]
        let size = text.size(withAttributes: attributes)
        let x = max(rect.minX + 2, rect.maxX - size.width - 2)
        let y = max(rect.minY + 2, rect.maxY - size.height - 2)
        text.draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
    }

    private func drawDashedRect(_ rect: NSRect, color: NSColor) {
        color.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.stroke()
    }

    private func drawBones(_ bones: [(from: CGPoint, to: CGPoint)], jointPoints: [CGPoint], imageRect: NSRect) {
        // ボーン線は枠線（2px）より2段階太く、枠線より暗い色で描画する
        let boneColor = NSColor.systemOrange.blended(withFraction: 0.4, of: .black) ?? .systemOrange
        boneColor.setStroke()
        for bone in bones {
            let path = NSBezierPath()
            path.move(to: viewPoint(bone.from, imageRect: imageRect))
            path.line(to: viewPoint(bone.to, imageRect: imageRect))
            path.lineWidth = 4
            path.lineCapStyle = .round
            path.stroke()
        }
        boneColor.setFill()
        for joint in jointPoints {
            let center = viewPoint(joint, imageRect: imageRect)
            NSBezierPath(ovalIn: NSRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)).fill()
        }
    }

    private func viewPoint(_ normalized: CGPoint, imageRect: NSRect) -> NSPoint {
        NSPoint(
            x: imageRect.minX + normalized.x * imageRect.width,
            y: imageRect.minY + normalized.y * imageRect.height
        )
    }

    private func drawLayerRect(_ rect: NSRect, color: NSColor) {
        color.withAlphaComponent(0.25).setFill()
        rect.fill()
        color.withAlphaComponent(0.7).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.5
        path.stroke()
    }

    private func imageDrawRect() -> NSRect {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else { return .zero }
        let padding: CGFloat = 18
        let available = bounds.insetBy(dx: padding, dy: padding)
        let imageAspect = imagePixelSize.width / imagePixelSize.height
        let viewAspect = available.width / max(1, available.height)
        let fitted: NSRect
        if imageAspect > viewAspect {
            let width = available.width
            let height = width / imageAspect
            fitted = NSRect(x: available.minX, y: available.midY - height / 2, width: width, height: height)
        } else {
            let height = available.height
            let width = height * imageAspect
            fitted = NSRect(x: available.midX - width / 2, y: available.minY, width: width, height: height)
        }
        let scaledWidth = fitted.width * zoomFactor
        let scaledHeight = fitted.height * zoomFactor
        return NSRect(
            x: bounds.midX - scaledWidth / 2 + panOffset.x,
            y: bounds.midY - scaledHeight / 2 + panOffset.y,
            width: scaledWidth,
            height: scaledHeight
        )
    }

    private func viewRect(from normalized: NormalizedRect, imageRect: NSRect) -> NSRect {
        let rect = normalized.clamped()
        return NSRect(
            x: imageRect.minX + rect.x * imageRect.width,
            y: imageRect.minY + rect.y * imageRect.height,
            width: rect.width * imageRect.width,
            height: rect.height * imageRect.height
        )
    }

    private func normalizedRect(fromViewRect rect: NSRect) -> NormalizedRect? {
        let imageRect = imageDrawRect()
        let clipped = rect.intersection(imageRect)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        return NormalizedRect(
            x: (clipped.minX - imageRect.minX) / imageRect.width,
            y: (clipped.minY - imageRect.minY) / imageRect.height,
            width: clipped.width / imageRect.width,
            height: clipped.height / imageRect.height
        )
    }
}

/// アプリ設定のポータブル保存ストア。
///
/// Windowsアプリの `*.ini` に相当する設定ファイルとして、**アプリ（.app）と同じフォルダ**の
/// `newMosaic_Settings/settings.json` へ全設定を保存する。アプリと設定フォルダをまとめて
/// 移動・コピーすれば、他のPC環境でも同じ設定で動作する（ポータブル運用）。
///
/// - 保存先が書き込めない場合（/Applications 直下へ管理者権限なしで配置した場合等）は
///   `~/Library/Application Support/newMosaic/Settings/settings.json` へフォールバックする。
/// - 初回起動時（設定ファイル未作成）は、従来の UserDefaults に保存済みの既知キーを移行する。
/// - APIは UserDefaults 互換（object/bool/integer/double/string/set）。
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private var values: [String: Any] = [:]
    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?

    /// 旧UserDefaultsから移行する既知キー（前方一致のプレフィックスも可）。
    private static let migratedKeyPrefixes = [
        "GroinPositionRatio", "DetectionDomainMode", "MosaicStyle.", "GenerateFilter.",
        "LibraryView.", "RightPaneDefaultLayoutApplied"
    ]

    private init() {
        let resolved = Self.resolveSettingsFileURL()
        fileURL = resolved
        if let data = try? Data(contentsOf: resolved),
           let loaded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            values = loaded
        } else {
            migrateFromUserDefaults()
            persistNow()
        }
    }

    /// 設定ファイルの場所を決める。第一候補はアプリ本体と同じフォルダ（ポータブル）。
    static func resolveSettingsFileURL() -> URL {
        let portableDirectory = portableSettingsDirectory()
        if isWritableDirectory(portableDirectory) {
            return portableDirectory.appendingPathComponent("settings.json")
        }
        // フォールバック: Application Support（従来のアプリデータ領域）
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let directory = support.appendingPathComponent("newMosaic/Settings")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("settings.json")
    }

    /// アプリ本体（.app）と同じフォルダの `newMosaic_Settings`。swift run 等の非バンドル実行では
    /// 実行ファイルのあるフォルダを基準にする。
    static func portableSettingsDirectory() -> URL {
        let bundleURL = Bundle.main.bundleURL
        let baseDirectory: URL
        if bundleURL.pathExtension == "app" {
            baseDirectory = bundleURL.deletingLastPathComponent()
        } else {
            let executable = Bundle.main.executableURL
                ?? URL(fileURLWithPath: CommandLine.arguments[0])
            baseDirectory = executable.deletingLastPathComponent()
        }
        return baseDirectory.appendingPathComponent("newMosaic_Settings")
    }

    private static func isWritableDirectory(_ directory: URL) -> Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if !manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return false
            }
        } else if !isDirectory.boolValue {
            return false
        }
        // 実際に書けるかをプローブファイルで確認する（リムーバブル・読み取り専用ボリューム対策）
        let probe = directory.appendingPathComponent(".write_probe")
        guard manager.createFile(atPath: probe.path, contents: Data()) else { return false }
        try? manager.removeItem(at: probe)
        return true
    }

    private func migrateFromUserDefaults() {
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        for (key, value) in defaults {
            guard Self.migratedKeyPrefixes.contains(where: { key.hasPrefix($0) }) else { continue }
            guard JSONSerialization.isValidJSONObject([key: value]) else { continue }
            values[key] = value
        }
    }

    // MARK: - UserDefaults互換API

    func object(forKey key: String) -> Any? {
        values[key]
    }

    func bool(forKey key: String) -> Bool {
        values[key] as? Bool ?? (values[key] as? NSNumber)?.boolValue ?? false
    }

    func integer(forKey key: String) -> Int {
        values[key] as? Int ?? (values[key] as? NSNumber)?.intValue ?? 0
    }

    func double(forKey key: String) -> Double {
        values[key] as? Double ?? (values[key] as? NSNumber)?.doubleValue ?? 0
    }

    func string(forKey key: String) -> String? {
        values[key] as? String
    }

    func set(_ value: Bool, forKey key: String) {
        values[key] = value
        scheduleSave()
    }

    func set(_ value: Int, forKey key: String) {
        values[key] = value
        scheduleSave()
    }

    func set(_ value: Double, forKey key: String) {
        values[key] = value
        scheduleSave()
    }

    func set(_ value: Any?, forKey key: String) {
        if let value, JSONSerialization.isValidJSONObject([key: value]) {
            values[key] = value
        } else if let string = value as? String {
            values[key] = string
        } else if value == nil {
            values.removeValue(forKey: key)
        }
        scheduleSave()
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
        scheduleSave()
    }

    // MARK: - 保存

    /// 連続変更（スライダードラッグ・分割ドラッグ等）で書き込みが多発しないよう0.3秒デバウンスする。
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.persistNow()
            }
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    func persistNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        guard JSONSerialization.isValidJSONObject(values) else {
            AppLog.ui.error("AppSettings.persistNow: valuesがJSONとして不正なため保存を中止しました")
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 全設定変更（初期化・分割位置の自動保存・プロジェクト読込等）がここを経由するため、
            // 失敗を無言のtry?で握りつぶさずログへ残す（コードレビューで検出）。
            AppLog.ui.error("AppSettings.persistNow failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 現在の設定ファイルの場所（ステータス表示・診断用）。
    var settingsFileLocation: URL { fileURL }

    // MARK: - プロジェクトファイル（設定スナップショットの保存/読込）・初期化

    /// 現在の全設定値のスナップショット（プロジェクトファイル書き出し用）。
    func exportSnapshot() -> [String: Any] {
        values
    }

    /// スナップショットで全設定値を置き換える（プロジェクトファイル読込用）。
    func importSnapshot(_ snapshot: [String: Any]) {
        values = snapshot
        persistNow()
    }

    /// すべての設定を初期化する（次回起動時に既定値で再構築される）。
    func resetAll() {
        values = [:]
        persistNow()
    }
}

// MARK: - 初期化・バックアップ（設定の保守）

/// 初期化・バックアップの対象項目。
///
/// ユーザーが項目ごとにON/OFFを選べるようにするため、UIとは独立した一覧としてここに置く
/// （ユーザー要望 2026-07-31）。追加する場合はここへ1件足せば両方のダイアログへ反映される。
enum MaintenanceItem: String, CaseIterable, Sendable {
    case appSettings
    case windowLayout
    case learningData
    case libraryIndex

    var title: String {
        switch self {
        case .appSettings: return "アプリ設定"
        case .windowLayout: return "画面レイアウト・動作状態"
        case .learningData: return "モデルの学習内容"
        case .libraryIndex: return "ライブラリ（画像とROI）"
        }
    }

    var detail: String {
        switch self {
        case .appSettings:
            return "モザイクスタイル、検出設定、候補カテゴリなど"
        case .windowLayout:
            return "サイドパネルの配置・幅、表示モード、ズーム設定など"
        case .learningData:
            return "修正結果から学習した位置・大きさの統計とサンプル"
        case .libraryIndex:
            return "登録した画像・動画の一覧と保存済みROI（元画像ファイルは削除しません）"
        }
    }

    /// 初期化の既定チェック状態。ライブラリは失うものが大きいので既定OFF。
    var isCheckedByDefaultForReset: Bool {
        switch self {
        case .appSettings, .windowLayout: return true
        case .learningData, .libraryIndex: return false
        }
    }

    /// バックアップは既定ですべて対象にする（失って困るものを漏らさないため）。
    var isCheckedByDefaultForBackup: Bool { true }
}

/// 初期化・バックアップのダイアログで使う、項目ごとのチェックボックス一覧。
@MainActor
final class MaintenanceItemPicker {
    private var checkboxes: [MaintenanceItem: NSButton] = [:]
    let view: NSStackView

    init(defaultChecked: (MaintenanceItem) -> Bool) {
        var rows: [NSView] = []
        for item in MaintenanceItem.allCases {
            let checkbox = NSButton(checkboxWithTitle: item.title, target: nil, action: nil)
            checkbox.state = defaultChecked(item) ? .on : .off
            checkboxes[item] = checkbox

            let detail = NSTextField(labelWithString: item.detail)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            // チェックボックスのラベルと縦位置を揃えるため、左に字下げを入れる
            let detailRow = NSStackView(views: [detail])
            detailRow.orientation = .horizontal
            detailRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

            let row = NSStackView(views: [checkbox, detailRow])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 1
            rows.append(row)
        }
        view = NSStackView(views: rows)
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 10
        view.translatesAutoresizingMaskIntoConstraints = false
        view.frame = NSRect(x: 0, y: 0, width: 380, height: CGFloat(MaintenanceItem.allCases.count) * 46)
    }

    var selected: [MaintenanceItem] {
        MaintenanceItem.allCases.filter { checkboxes[$0]?.state == .on }
    }
}

/// バックアップの作成・内容説明。
///
/// 対象はいずれもローカルのファイルで、外部へ送信しない。
enum MaintenanceBackup {
    /// 選択項目を1つのフォルダへ書き出す。戻り値は作成したフォルダ。
    static func create(
        items: [MaintenanceItem],
        into destination: URL,
        settingsFileURL: URL,
        learningDirectory: URL?,
        libraryDirectory: URL
    ) throws -> URL {
        let manager = FileManager.default
        let stamp = ISO8601DateFormatter.backupStampFormatter.string(from: Date())
        let root = destination.appendingPathComponent("newMosaic_Backup_\(stamp)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        for item in items {
            switch item {
            case .appSettings, .windowLayout:
                // どちらも settings.json に入っているため、1回だけコピーする
                let copied = root.appendingPathComponent("settings.json")
                if manager.fileExists(atPath: settingsFileURL.path), !manager.fileExists(atPath: copied.path) {
                    try manager.copyItem(at: settingsFileURL, to: copied)
                }
            case .learningData:
                guard let learningDirectory, manager.fileExists(atPath: learningDirectory.path) else { continue }
                try manager.copyItem(at: learningDirectory, to: root.appendingPathComponent("Learning"))
            case .libraryIndex:
                let index = libraryDirectory.appendingPathComponent("index.json")
                guard manager.fileExists(atPath: index.path) else { continue }
                try manager.copyItem(at: index, to: root.appendingPathComponent("library_index.json"))
            }
        }
        try readme(for: items).write(
            to: root.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8
        )
        return root
    }

    static func readme(for items: [MaintenanceItem]) -> String {
        var lines = [
            "newMosaic バックアップ",
            "作成日時: \(ISO8601DateFormatter.backupStampFormatter.string(from: Date()))",
            "",
            "含まれる項目:"
        ]
        for item in items {
            lines.append("  - \(item.title): \(item.detail)")
        }
        lines.append("")
        lines.append("戻し方:")
        lines.append("  settings.json        → アプリ設定ファイルの場所へ上書き（ヘルプ＞デバッグで場所を確認できます）")
        lines.append("  Learning/            → ~/Library/Application Support/newMosaic/Learning へ上書き")
        lines.append("  library_index.json   → ライブラリフォルダの index.json へ上書き")
        lines.append("")
        lines.append("注意: ライブラリの元画像ファイル本体はバックアップに含まれません（容量が大きいため）。")
        lines.append("      AIモデルも含まれません（Docs/MODELS.md の手順で再導入できます）。")
        return lines.joined(separator: "\n")
    }
}

extension ISO8601DateFormatter {
    /// バックアップフォルダ名に使う `yyyyMMdd-HHmmss` 形式。
    static let backupStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// ロックで守った可変値。`nonisolated static let` から安全に読み書きするための最小の入れ物。
final class LockedValue<Value>: @unchecked Sendable {
    private var storage: Value
    private let lock = NSLock()

    init(_ initial: Value) { storage = initial }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

extension AppDelegate {
    /// デバッグログの定期退避を開始する。
    ///
    /// `OSLogStore` はプロセス内のログしか読めないため、退避しないと再起動で前回分が消える
    /// （ユーザー要望 2026-08-02）。定期的に、および終了時にファイルへ書き出す。
    fileprivate func startDebugLogArchiving() {
        MosaicWindowController.archiveDebugLog()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.logArchiveInterval, repeats: true) { _ in
            // ファイルI/Oを主スレッドで行わない
            DispatchQueue.global(qos: .utility).async {
                MosaicWindowController.archiveDebugLog()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        logArchiveTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        logArchiveTimer?.invalidate()
        logArchiveTimer = nil
        // 終了直前の分まで残す（クラッシュ直前の状況を追えるようにする）
        MosaicWindowController.archiveDebugLog()
    }
}

// MARK: - マスク追加ペン／マスク消しゴム

extension ImageCanvasView {
    /// ビュー座標を、選択中ROIのローカル座標（0〜1・左上原点）へ変換する。
    /// ROI外は0〜1の外側になるが、そのまま渡してよい（描画時にROI枠で切られる）。
    fileprivate func maskStrokePoint(at point: NSPoint, roi: MosaicROI) -> NormalizedPoint? {
        let imageRect = imageDrawRect()
        guard imageRect.width > 0, imageRect.height > 0 else { return nil }
        let rect = roi.rect.clamped()
        guard rect.width > 0, rect.height > 0 else { return nil }
        let normalizedX = (point.x - imageRect.minX) / imageRect.width
        let normalizedY = (point.y - imageRect.minY) / imageRect.height
        return NormalizedPoint(
            x: (normalizedX - rect.x) / rect.width,
            y: (normalizedY - rect.y) / rect.height
        )
    }

    private func maskStrokeDirtyRect(roi: MosaicROI, from oldPoint: NSPoint?, to newPoint: NSPoint) -> NSRect {
        let imageRect = imageDrawRect()
        let roiRect = viewRect(from: roi.rect, imageRect: imageRect)
        let padding = max(8, min(roiRect.width, roiRect.height) * CGFloat(maskBrushWidth) / 2 + 6)
        let base = oldPoint.map {
            NSRect(
                x: min($0.x, newPoint.x),
                y: min($0.y, newPoint.y),
                width: abs($0.x - newPoint.x),
                height: abs($0.y - newPoint.y)
            )
        } ?? NSRect(x: newPoint.x, y: newPoint.y, width: 1, height: 1)
        return base.insetBy(dx: -padding, dy: -padding)
    }

    /// 選択中のROI（無ければクリック位置のROI）へストロークを開始する。
    fileprivate func beginMaskStroke(at point: NSPoint, erasing: Bool) {
        let imageRect = imageDrawRect()
        // 選択中のROIを優先し、無ければクリック位置のROIを対象にする
        var target = rois.first { $0.id == selectedROIID }
            ?? rois.last { viewRect(from: $0.rect, imageRect: imageRect).contains(point) }

        // 対象が無い場合、追加ペンなら新しいレイヤを作ってそこへ塗る
        // （消しゴムでは何もしない。消す対象が無いため）。
        var isNewLayer = false
        if target == nil, !erasing, imageRect.width > 0, imageRect.height > 0 {
            // クリック位置を中心に、筆の太さから決めた正方形の枠を作る
            let side = max(maskBrushWidth * 2, 0.06)
            let centerX = (point.x - imageRect.minX) / imageRect.width
            let centerY = (point.y - imageRect.minY) / imageRect.height
            let rect = NormalizedRect(
                x: centerX - side / 2, y: centerY - side / 2, width: side, height: side
            ).clamped()
            if let newID = onMaskStrokeNeedsNewLayer?(rect) {
                target = rois.first { $0.id == newID }
                isNewLayer = true
            }
        }
        guard let roi = target, let local = maskStrokePoint(at: point, roi: roi) else { return }
        selectedROIID = roi.id
        maskStrokeInProgress = (roi.id, [local], !erasing, isNewLayer)
        lastMaskStrokeViewPoint = point
        maskCursor(erasing: erasing).set()
        setNeedsDisplay(maskStrokeDirtyRect(roi: roi, from: nil, to: point))
    }

    fileprivate func extendMaskStroke(to point: NSPoint) {
        guard var state = maskStrokeInProgress,
              let roi = rois.first(where: { $0.id == state.roiID }),
              let local = maskStrokePoint(at: point, roi: roi) else { return }
        if let previous = lastMaskStrokeViewPoint,
           hypot(point.x - previous.x, point.y - previous.y) < maskStrokeMinimumViewSpacing {
            return
        }
        let previous = lastMaskStrokeViewPoint
        state.points.append(local)
        maskStrokeInProgress = state
        lastMaskStrokeViewPoint = point
        maskCursor(erasing: !state.isAdditive).set()
        setNeedsDisplay(maskStrokeDirtyRect(roi: roi, from: previous, to: point))
    }

    fileprivate func finishMaskStroke() {
        guard let state = maskStrokeInProgress else { return }
        maskStrokeInProgress = nil
        lastMaskStrokeViewPoint = nil
        guard !state.points.isEmpty else { return }
        onMaskStrokeCompleted?(state.roiID, ManualMaskStroke(
            points: state.points, width: maskBrushWidth, isAdditive: state.isAdditive
        ), state.isNewLayer)
        needsDisplay = true
    }
}
