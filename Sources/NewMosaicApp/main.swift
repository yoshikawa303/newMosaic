import AppKit
import MosaicCore
import UniformTypeIdentifiers

@main
final class NewMosaicApplication {
    static func main() {
        let app = NSApplication.shared
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle()
        window.contentMinSize = NSSize(width: 1100, height: 700)
        window.center()
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [controller] in
            controller.applyInitialLayoutIfNeeded()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private static func windowTitle() -> String {
        let info = Bundle.main.infoDictionary
        let marketingVersion = info?["CFBundleShortVersionString"] as? String ?? "0.0.00000"
        let buildVersion = info?["CFBundleVersion"] as? String ?? "0"
        return "newMosaic v\(marketingVersion) (beta Build \(buildVersion))"
    }
}

private enum LibraryViewMode: Int {
    case thumbnailGrid = 0
    case textList = 1
    case thumbnailList = 2
}

private struct EditorState {
    var rois: [MosaicROI]
    var renderedImage: CGImage?
}

private enum LayerKind: Equatable {
    case image
    case roi
    case person(Int)
    case pose(Int)

    var title: String {
        switch self {
        case .image: return "画像"
        case .roi: return "モザイク対象"
        case .person(let index): return "人物検出\(index + 1)"
        case .pose(let index): return "骨格検出\(index + 1)"
        }
    }

    var isPerson: Bool { if case .person = self { return true }; return false }
    var isPose: Bool { if case .pose = self { return true }; return false }
}

@MainActor
private final class LayerLeaf {
    let kind: LayerKind
    var isVisible: Bool

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
        label.font = .systemFont(ofSize: 12)
        addSubview(checkbox)
        addSubview(label)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(title: String, state: NSControl.StateValue, allowsMixed: Bool, showsCheckbox: Bool = true) {
        label.stringValue = title
        checkbox.allowsMixedState = allowsMixed
        checkbox.state = state
        checkbox.isHidden = !showsCheckbox
    }

    @objc private func handleToggle() {
        onToggle?()
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

@MainActor
final class MosaicWindowController: NSObject {
    private(set) var view = NSView()

    private let imageLoader = ImageLoader()
    private let roiGenerator: SensitiveROIGenerator
    private let pipeline: StaticImageMosaicPipeline
    private let mosaicEngine = MosaicEngine()
    private let historyEngine = HistoryEngine()
    private let libraryEngine: LibraryEngine = (try? LibraryEngine.defaultLibrary())
        ?? LibraryEngine(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("newMosaic/Library"))
    private let learningEngine: LearningEngine? = try? LearningEngine.defaultStore()
    /// アニメ・イラスト用のNSFW部位検出器（初回アクセス時にモデルロード。失敗時はnil=従来動作）
    private lazy var animeCensorDetector: AnimeCensorDetector? = try? AnimeCensorDetector()
    /// アニメ・イラスト用の人物検出器（矩形。イラストでのVisionシルエット不安定問題への対応）
    private lazy var animePersonDetector: AnimePersonDetector? = try? AnimePersonDetector()
    /// 実写用のNSFW部位検出器（NudeNet。実写でも性器・乳首を内容ベースで検出する）
    private lazy var photoCensorDetector: PhotoCensorDetector? = try? PhotoCensorDetector()
    /// 画像種別（実写/アニメ）のモデルベース分類器（読み込めない場合は統計判定へフォールバック）
    private lazy var domainModelClassifier: DomainModelClassifier? = try? DomainModelClassifier()
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
    private let undoButton = NSButton(title: "元に戻す", target: nil, action: nil)
    private let redoButton = NSButton(title: "やり直す", target: nil, action: nil)
    private let shapeControl = NSSegmentedControl(
        labels: ["矩形", "楕円", "多角形"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    // レイヤパネル先頭の表示トグル（ツールバーから移設）
    private let personLayerCheckbox = NSButton(checkboxWithTitle: "人物検出", target: nil, action: nil)
    private let poseLayerCheckbox = NSButton(checkboxWithTitle: "骨格検出", target: nil, action: nil)
    private let roiLayerCheckbox = NSButton(checkboxWithTitle: "ROI", target: nil, action: nil)
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
    private let mosaicPreviewCheckbox = NSButton(checkboxWithTitle: "モザイク表示", target: nil, action: nil)
    private let groinPositionSlider = NSSlider(value: 0.45, minValue: 0.2, maxValue: 0.8, target: nil, action: nil)
    private let groinPositionValueLabel = NSTextField(labelWithString: "45%")
    private static let groinPositionDefaultsKey = "GroinPositionRatio"

    // モザイク描画スタイル設定（パターン+パラメータ。永続化しモザイク表示中は即時反映）
    private let mosaicSettingsButton = NSButton(title: "モザイク設定...", target: nil, action: nil)
    private let mosaicSettingsPopover = NSPopover()
    private let stylePatternPopUp = NSPopUpButton(title: "", target: nil, action: nil)
    private let styleOpacitySlider = NSSlider(value: 1.0, minValue: 0.1, maxValue: 1.0, target: nil, action: nil)
    private let styleOpacityValueLabel = NSTextField(labelWithString: "100%")
    private let styleTintCheckbox = NSButton(checkboxWithTitle: "色を付ける", target: nil, action: nil)
    private let styleTintColorWell = NSColorWell()
    private let styleBlockScaleSlider = NSSlider(value: 28, minValue: 4, maxValue: 80, target: nil, action: nil)
    private let styleBlockScaleValueLabel = NSTextField(labelWithString: "28")
    private let styleFeatherSlider = NSSlider(value: 0, minValue: 0, maxValue: 40, target: nil, action: nil)
    private let styleFeatherValueLabel = NSTextField(labelWithString: "0px")
    private let styleStripeWidthSlider = NSSlider(value: 12, minValue: 2, maxValue: 60, target: nil, action: nil)
    private let styleStripeWidthValueLabel = NSTextField(labelWithString: "12px")
    private let styleStripeSpacingSlider = NSSlider(value: 12, minValue: 0, maxValue: 60, target: nil, action: nil)
    private let styleStripeSpacingValueLabel = NSTextField(labelWithString: "12px")
    private let styleCloudDensitySlider = NSSlider(value: 0.5, minValue: 0.1, maxValue: 1.0, target: nil, action: nil)
    private let styleCloudDensityValueLabel = NSTextField(labelWithString: "50%")
    private let styleCloudToneCheckbox = NSButton(checkboxWithTitle: "トーン化（漫画トーン）", target: nil, action: nil)
    private let stylePatternImageButton = NSButton(title: "パターン画像を選択...", target: nil, action: nil)
    private let stylePatternImageLabel = NSTextField(labelWithString: "未選択")
    private var customPatternImage: CGImage?
    private var ungroupedLayers: [LayerLeaf] = [
        LayerLeaf(kind: .image, isVisible: true),
        LayerLeaf(kind: .roi, isVisible: true)
    ]
    private var layerGroups: [LayerGroup] = []
    private var layerGroupCounter = 0
    /// レイヤパネル「モザイク対象」配下のROI選択リスト（同一カテゴリ名は連番付き）
    private var roiListEntries: [ROIListEntry] = []
    private var roiListSignature: [String] = []
    private var isSyncingROISelection = false
    private var loadedImage: LoadedImage?
    private var renderedImage: CGImage?
    private var currentLibraryItem: MosaicLibraryItem?
    private var libraryItems: [MosaicLibraryItem] = []
    private var libraryViewMode: LibraryViewMode = .thumbnailGrid
    private var selectedLibraryItemID: UUID?
    private var thumbnailCache: [UUID: NSImage] = [:]
    private var thumbnailCacheUpdatedAt: [UUID: Date] = [:]
    private var undoStack: [EditorState] = []
    private var redoStack: [EditorState] = []
    private var hasUnsavedChanges = false
    private var lastAutoROIs: [MosaicROI] = []
    private var lastPersonBounds: [NormalizedRect] = []
    private var learnedROIIDs: Set<UUID> = []

    /// 画像（ライブラリアイテム）ごとの編集状態。エクスポート/加工確定に関わらずセッション内で保持し、
    /// 画像を切り替えて戻ってきたときにROI・検出レイヤ・アンドゥ履歴・モザイク表示状態を復元する。
    private struct PerImageEditState {
        var rois: [MosaicROI]
        var renderedImage: CGImage?
        var mosaicPreviewOn: Bool
        var personLayerRects: [NormalizedRect]
        var personLayerMasks: [CGImage?]
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
    private let imageEditStateLimit = 8
    private var rightPaneSplitView: NSSplitView?

    override init() {
        let savedRatio = UserDefaults.standard.object(forKey: Self.groinPositionDefaultsKey) as? Double ?? 0.45
        let generator = SensitiveROIGenerator(groinPositionRatio: savedRatio)
        self.roiGenerator = generator
        self.pipeline = StaticImageMosaicPipeline(roiGenerator: generator)
        super.init()
        groinPositionSlider.doubleValue = savedRatio
        groinPositionValueLabel.stringValue = "\(Int(savedRatio * 100))%"
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let openButton = NSButton(title: "画像を開く", target: nil, action: nil)
        let pasteButton = NSButton(title: "画像を貼り付け", target: nil, action: nil)
        pasteButton.keyEquivalent = "v"
        pasteButton.keyEquivalentModifierMask = [.command]
        let detectButton = NSButton(title: "候補生成", target: nil, action: nil)
        let applyButton = NSButton(title: "モザイク適用", target: nil, action: nil)
        let clearButton = NSButton(title: "ROIクリア", target: nil, action: nil)
        undoButton.keyEquivalent = "z"
        undoButton.keyEquivalentModifierMask = [.command]
        redoButton.keyEquivalent = "z"
        redoButton.keyEquivalentModifierMask = [.command, .shift]
        let saveButton = NSButton(title: "保存", target: nil, action: nil)
        let reloadLibraryButton = NSButton(title: "ライブラリ更新", target: nil, action: nil)
        let revealButton = NSButton(title: "Finder表示", target: nil, action: nil)

        // ステータスは余白に収め、長文時は末尾省略（幅がウィンドウを超えて制約が破綻しないようにする）
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let toolbar = NSStackView(views: [
            openButton, pasteButton, detectButton, applyButton, clearButton,
            undoButton, redoButton, saveButton, reloadLibraryButton, revealButton, statusLabel
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 4, right: 12)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let shapeLabel = NSTextField(labelWithString: "追加形状:")
        shapeControl.selectedSegment = 1
        let segmentEngineLabel = NSTextField(labelWithString: "マスク生成:")
        segmentEngineControl.removeAllItems()
        segmentEngineControl.addItems(withTitles: SegmentEngineKind.allCases.map(\.displayName))
        segmentEngineControl.selectItem(at: 0)

        // 画像種別（自動判定の誤りを手動で上書きできるようにする）
        let domainModeLabel = NSTextField(labelWithString: "画像種別:")
        domainModeControl.removeAllItems()
        domainModeControl.addItems(withTitles: ["自動判定", "実写", "イラスト・漫画"])
        let savedDomainMode = UserDefaults.standard.integer(forKey: Self.domainModeDefaultsKey)
        domainModeControl.selectItem(at: (0...2).contains(savedDomainMode) ? savedDomainMode : 0)

        // 項目過多による幅超過（レイアウト破綻）を防ぐため、編集ツールバーは複数行に分ける
        let editToolbar = NSStackView(views: [
            shapeLabel, shapeControl,
            segmentEngineLabel, segmentEngineControl,
            domainModeLabel, domainModeControl
        ])
        editToolbar.orientation = .horizontal
        editToolbar.alignment = .centerY
        editToolbar.spacing = 10
        editToolbar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 2, right: 12)
        editToolbar.translatesAutoresizingMaskIntoConstraints = false

        // 対象カテゴリ行: 複数チェック可。候補生成時にチェックされたカテゴリ・レイヤだけを生成する
        let categoryLabel = NSTextField(labelWithString: "対象カテゴリ:")
        let categoryToolbar = NSStackView(
            views: [categoryLabel] + categoryFilterChecks.map(\.button) + [generatePersonCheckbox, generatePoseCheckbox]
        )
        categoryToolbar.orientation = .horizontal
        categoryToolbar.alignment = .centerY
        categoryToolbar.spacing = 10
        categoryToolbar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 2, right: 12)
        categoryToolbar.translatesAutoresizingMaskIntoConstraints = false

        let groinPositionLabel = NSTextField(labelWithString: "鼠径部位置:")
        groinPositionSlider.translatesAutoresizingMaskIntoConstraints = false
        groinPositionSlider.widthAnchor.constraint(equalToConstant: 100).isActive = true

        let optionToolbar = NSStackView(views: [
            autoGenerateCheckbox, autoSaveCheckbox, mosaicPreviewCheckbox,
            mosaicSettingsButton,
            groinPositionLabel, groinPositionSlider, groinPositionValueLabel
        ])
        optionToolbar.orientation = .horizontal
        optionToolbar.alignment = .centerY
        optionToolbar.spacing = 10
        optionToolbar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 8, right: 12)
        optionToolbar.translatesAutoresizingMaskIntoConstraints = false

        // 縦の余白はキャンバス側（splitView）に吸収させ、ツールバー3段は内容ぴったりの高さに固定する。
        // NSStackViewは内在サイズを持たないため NSView汎用の setContentHuggingPriority は効かず、
        // スタック境界を内容へフィットさせる専用API setHuggingPriority を使う必要がある
        // （これが無いとAuto Layoutがツールバーを縦に引き伸ばし、コンテンツが下へ押し込まれる）。
        toolbar.setHuggingPriority(.required, for: .vertical)
        editToolbar.setHuggingPriority(.required, for: .vertical)
        categoryToolbar.setHuggingPriority(.required, for: .vertical)
        optionToolbar.setHuggingPriority(.required, for: .vertical)

        canvas.translatesAutoresizingMaskIntoConstraints = false
        let libraryPanel = makeLibraryPanel()
        let layerPanel = makeLayerPanel()

        // 右ペイン: 上=ライブラリ / 下=レイヤ。境界の上下ドラッグで比率変更できる。
        let rightPane = NSSplitView()
        rightPane.isVertical = false
        rightPane.dividerStyle = .thin
        rightPane.autosaveName = "RightPaneSplit"
        rightPaneSplitView = rightPane
        rightPane.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addArrangedSubview(libraryPanel)
        rightPane.addArrangedSubview(layerPanel)
        libraryPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        layerPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        // メイン分割: 左=キャンバス / 右=ライブラリ+レイヤ。左端境界の左右ドラッグで幅変更できる。
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "MainSplit"
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(canvas)
        splitView.addArrangedSubview(rightPane)
        rightPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        root.addSubview(toolbar)
        root.addSubview(editToolbar)
        root.addSubview(categoryToolbar)
        root.addSubview(optionToolbar)
        root.addSubview(splitView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editToolbar.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            editToolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editToolbar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            categoryToolbar.topAnchor.constraint(equalTo: editToolbar.bottomAnchor),
            categoryToolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            categoryToolbar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            optionToolbar.topAnchor.constraint(equalTo: categoryToolbar.bottomAnchor),
            optionToolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            optionToolbar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: optionToolbar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        self.view = root

        openButton.target = self
        openButton.action = #selector(openImage)
        pasteButton.target = self
        pasteButton.action = #selector(pasteImage)
        detectButton.target = self
        detectButton.action = #selector(generateCandidates)
        applyButton.target = self
        applyButton.action = #selector(applyMosaic)
        clearButton.target = self
        clearButton.action = #selector(clearROIs)
        undoButton.target = self
        undoButton.action = #selector(performUndo)
        redoButton.target = self
        redoButton.action = #selector(performRedo)
        saveButton.target = self
        saveButton.action = #selector(saveImage)
        reloadLibraryButton.target = self
        reloadLibraryButton.action = #selector(reloadLibraryFromButton)
        revealButton.target = self
        revealButton.action = #selector(revealLibrary)
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
        mosaicSettingsButton.target = self
        mosaicSettingsButton.action = #selector(toggleMosaicSettingsPopover)
        setUpMosaicSettingsPanel()
        loadMosaicStyleSettings()
        reloadLayerList()

        canvas.currentShape = .ellipse
        canvas.currentCategory = .other
        canvas.onROIsChanged = { [weak self] rois in
            guard let self else { return }
            self.updateStatus("ROI \(rois.count)件")
            self.refreshROIListIfNeeded()
        }
        canvas.onCategoryChangeRequest = { [weak self] roiID, category in
            guard let self,
                  let index = self.canvas.rois.firstIndex(where: { $0.id == roiID }),
                  self.canvas.rois[index].category != category else { return }
            self.pushUndoSnapshot(self.currentEditorState())
            self.canvas.rois[index].category = category
            self.updateStatus("ROIのカテゴリを「\(category.displayName)」へ変更しました")
        }
        canvas.onManualEditWillBegin = { [weak self] in
            guard let self else { return }
            self.pushUndoSnapshot(self.currentEditorState())
            // 編集中は元画像表示に切り替える（チェック状態は維持し、編集完了時に自動で再適用）
            self.suspendMosaicPreview()
        }
        canvas.onManualEditDidEnd = { [weak self] in
            self?.resumeMosaicPreviewIfNeeded()
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
            self.syncROIListSelectionFromCanvas()
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
        } else if shape == .polygon {
            updateStatus("追加形状: 多角形（ドラッグで追加後、頂点ドラッグで変形、Option+クリックで頂点の追加/削除）")
        }
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
        let defaults = UserDefaults.standard
        for (category, button) in categoryFilterChecks {
            defaults.set(button.state == .on, forKey: "GenerateFilter.category.\(category.rawValue)")
        }
        defaults.set(generatePersonCheckbox.state == .on, forKey: "GenerateFilter.person")
        defaults.set(generatePoseCheckbox.state == .on, forKey: "GenerateFilter.pose")
    }

    /// 保存済みの生成対象フィルタを復元する（未保存キーは既定ON）。
    private func loadGenerationFilter() {
        let defaults = UserDefaults.standard
        for (category, button) in categoryFilterChecks {
            let key = "GenerateFilter.category.\(category.rawValue)"
            button.state = (defaults.object(forKey: key) as? Bool ?? true) ? .on : .off
        }
        generatePersonCheckbox.state = (defaults.object(forKey: "GenerateFilter.person") as? Bool ?? true) ? .on : .off
        generatePoseCheckbox.state = (defaults.object(forKey: "GenerateFilter.pose") as? Bool ?? true) ? .on : .off
    }

    /// レイヤパネルの初期縦幅を「人物4人分」（グループ4+子8+固定2=14行×約24pt+見出し・ボタン≈430pt）に設定する。
    /// 右ペインの高さが足りない場合はライブラリと半々。一度適用した後はユーザーのドラッグ調整（autosave）を尊重する。
    func applyInitialLayoutIfNeeded() {
        let appliedKey = "RightPaneDefaultLayoutApplied.v1"
        guard !UserDefaults.standard.bool(forKey: appliedKey), let rightPane = rightPaneSplitView else { return }
        rightPane.layoutSubtreeIfNeeded()
        let total = rightPane.bounds.height
        guard total > 100 else { return }
        let divider = rightPane.dividerThickness
        var layerHeight = min(430, total / 2)
        layerHeight = max(160, min(layerHeight, total - 200 - divider))
        rightPane.setPosition(total - divider - layerHeight, ofDividerAt: 0)
        UserDefaults.standard.set(true, forKey: appliedKey)
    }

    // MARK: - モザイク描画スタイル設定

    private func setUpMosaicSettingsPanel() {
        stylePatternPopUp.removeAllItems()
        stylePatternPopUp.addItems(withTitles: MosaicFillPattern.allCases.map(\.displayName))
        stylePatternPopUp.target = self
        stylePatternPopUp.action = #selector(mosaicStyleChanged)
        for slider in [styleOpacitySlider, styleBlockScaleSlider, styleFeatherSlider, styleStripeWidthSlider, styleStripeSpacingSlider, styleCloudDensitySlider] {
            slider.target = self
            slider.action = #selector(mosaicStyleChanged)
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        }
        styleTintCheckbox.target = self
        styleTintCheckbox.action = #selector(mosaicStyleChanged)
        styleCloudToneCheckbox.target = self
        styleCloudToneCheckbox.action = #selector(mosaicStyleChanged)
        styleTintColorWell.target = self
        styleTintColorWell.action = #selector(mosaicStyleChanged)
        styleTintColorWell.translatesAutoresizingMaskIntoConstraints = false
        styleTintColorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        styleTintColorWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
        styleTintColorWell.color = .black
        stylePatternImageButton.target = self
        stylePatternImageButton.action = #selector(choosePatternImage)
        stylePatternImageLabel.textColor = .secondaryLabelColor
        stylePatternImageLabel.font = .systemFont(ofSize: 11)

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "塗りつぶしパターン:"), stylePatternPopUp, NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "透明度:"), styleOpacitySlider, styleOpacityValueLabel],
            [styleTintCheckbox, styleTintColorWell, NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "パターン細かさ:"), styleBlockScaleSlider, styleBlockScaleValueLabel],
            [NSTextField(labelWithString: "範囲輪郭ぼかし:"), styleFeatherSlider, styleFeatherValueLabel],
            [NSTextField(labelWithString: "帯の太さ:"), styleStripeWidthSlider, styleStripeWidthValueLabel],
            [NSTextField(labelWithString: "帯の間隔（透明）:"), styleStripeSpacingSlider, styleStripeSpacingValueLabel],
            [NSTextField(labelWithString: "雲の密度:"), styleCloudDensitySlider, styleCloudDensityValueLabel],
            [NSTextField(labelWithString: "雲:"), styleCloudToneCheckbox, NSGridCell.emptyContentView],
            [stylePatternImageButton, stylePatternImageLabel, NSGridCell.emptyContentView]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            grid.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            grid.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14)
        ])
        let controller = NSViewController()
        controller.view = panel
        mosaicSettingsPopover.behavior = .transient
        mosaicSettingsPopover.contentViewController = controller
    }

    @objc private func toggleMosaicSettingsPopover() {
        if mosaicSettingsPopover.isShown {
            mosaicSettingsPopover.close()
        } else {
            updateMosaicStyleControlAvailability()
            mosaicSettingsPopover.show(relativeTo: mosaicSettingsButton.bounds, of: mosaicSettingsButton, preferredEdge: .maxY)
        }
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
        style.cloudDensity = styleCloudDensitySlider.doubleValue
        style.cloudTone = styleCloudToneCheckbox.state == .on
        style.patternImage = customPatternImage
        return style
    }

    @objc private func mosaicStyleChanged() {
        updateMosaicStyleControlAvailability()
        saveMosaicStyleSettings()
        // モザイク表示中は変更を即時反映する
        resumeMosaicPreviewIfNeeded()
    }

    private func updateMosaicStyleControlAvailability() {
        let patterns = MosaicFillPattern.allCases
        let index = stylePatternPopUp.indexOfSelectedItem
        let pattern = (0..<patterns.count).contains(index) ? patterns[index] : .pixelate
        styleStripeWidthSlider.isEnabled = pattern.isStripes
        styleStripeSpacingSlider.isEnabled = pattern.isStripes
        styleCloudDensitySlider.isEnabled = pattern == .clouds
        styleCloudToneCheckbox.isEnabled = pattern == .clouds
        stylePatternImageButton.isEnabled = pattern == .customImage
        styleCloudDensityValueLabel.stringValue = "\(Int(styleCloudDensitySlider.doubleValue * 100))%"
        styleOpacityValueLabel.stringValue = "\(Int(styleOpacitySlider.doubleValue * 100))%"
        styleBlockScaleValueLabel.stringValue = "\(Int(styleBlockScaleSlider.doubleValue))"
        styleFeatherValueLabel.stringValue = "\(Int(styleFeatherSlider.doubleValue))px"
        styleStripeWidthValueLabel.stringValue = "\(Int(styleStripeWidthSlider.doubleValue))px"
        styleStripeSpacingValueLabel.stringValue = "\(Int(styleStripeSpacingSlider.doubleValue))px"
    }

    /// 任意パターン画像を選択し、Application Supportへコピーして永続化する。
    @objc private func choosePatternImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try imageLoader.loadImage(from: url)
            customPatternImage = loaded.cgImage
            let destination = try Self.patternImageStoreURL()
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let bitmap = NSBitmapImageRep(cgImage: loaded.cgImage)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: destination, options: .atomic)
            }
            stylePatternImageLabel.stringValue = url.lastPathComponent
            mosaicStyleChanged()
        } catch {
            showError(error)
        }
    }

    private static func patternImageStoreURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("newMosaic/Patterns/custom_pattern.png")
    }

    private func saveMosaicStyleSettings() {
        let defaults = UserDefaults.standard
        let patterns = MosaicFillPattern.allCases
        let index = stylePatternPopUp.indexOfSelectedItem
        if (0..<patterns.count).contains(index) {
            defaults.set(patterns[index].rawValue, forKey: "MosaicStyle.pattern")
        }
        defaults.set(styleOpacitySlider.doubleValue, forKey: "MosaicStyle.opacity")
        defaults.set(styleTintCheckbox.state == .on, forKey: "MosaicStyle.useTint")
        if let color = styleTintColorWell.color.usingColorSpace(.deviceRGB) {
            defaults.set(Double(color.redComponent), forKey: "MosaicStyle.tintR")
            defaults.set(Double(color.greenComponent), forKey: "MosaicStyle.tintG")
            defaults.set(Double(color.blueComponent), forKey: "MosaicStyle.tintB")
        }
        defaults.set(styleBlockScaleSlider.doubleValue, forKey: "MosaicStyle.blockScale")
        defaults.set(styleFeatherSlider.doubleValue, forKey: "MosaicStyle.edgeFeather")
        defaults.set(styleStripeWidthSlider.doubleValue, forKey: "MosaicStyle.stripeWidth")
        defaults.set(styleStripeSpacingSlider.doubleValue, forKey: "MosaicStyle.stripeSpacing")
        defaults.set(styleCloudDensitySlider.doubleValue, forKey: "MosaicStyle.cloudDensity")
        defaults.set(styleCloudToneCheckbox.state == .on, forKey: "MosaicStyle.cloudTone")
    }

    private func loadMosaicStyleSettings() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "MosaicStyle.pattern"),
           let pattern = MosaicFillPattern(rawValue: raw),
           let index = MosaicFillPattern.allCases.firstIndex(of: pattern) {
            stylePatternPopUp.selectItem(at: index)
        }
        if defaults.object(forKey: "MosaicStyle.opacity") != nil {
            styleOpacitySlider.doubleValue = defaults.double(forKey: "MosaicStyle.opacity")
        }
        styleTintCheckbox.state = defaults.bool(forKey: "MosaicStyle.useTint") ? .on : .off
        if defaults.object(forKey: "MosaicStyle.tintR") != nil {
            styleTintColorWell.color = NSColor(
                deviceRed: defaults.double(forKey: "MosaicStyle.tintR"),
                green: defaults.double(forKey: "MosaicStyle.tintG"),
                blue: defaults.double(forKey: "MosaicStyle.tintB"),
                alpha: 1
            )
        }
        if defaults.object(forKey: "MosaicStyle.blockScale") != nil {
            styleBlockScaleSlider.doubleValue = defaults.double(forKey: "MosaicStyle.blockScale")
        }
        if defaults.object(forKey: "MosaicStyle.edgeFeather") != nil {
            styleFeatherSlider.doubleValue = defaults.double(forKey: "MosaicStyle.edgeFeather")
        }
        if defaults.object(forKey: "MosaicStyle.stripeWidth") != nil {
            styleStripeWidthSlider.doubleValue = defaults.double(forKey: "MosaicStyle.stripeWidth")
        }
        if defaults.object(forKey: "MosaicStyle.stripeSpacing") != nil {
            styleStripeSpacingSlider.doubleValue = defaults.double(forKey: "MosaicStyle.stripeSpacing")
        }
        if defaults.object(forKey: "MosaicStyle.cloudDensity") != nil {
            styleCloudDensitySlider.doubleValue = defaults.double(forKey: "MosaicStyle.cloudDensity")
        }
        styleCloudToneCheckbox.state = defaults.bool(forKey: "MosaicStyle.cloudTone") ? .on : .off
        if let storeURL = try? Self.patternImageStoreURL(),
           FileManager.default.fileExists(atPath: storeURL.path),
           let loaded = try? imageLoader.loadImage(from: storeURL) {
            customPatternImage = loaded.cgImage
            stylePatternImageLabel.stringValue = "保存済みパターン"
        }
        updateMosaicStyleControlAvailability()
    }

    /// 画像種別（自動判定/実写/イラスト・漫画）の手動指定。永続化され、次回の候補生成から適用される。
    @objc private func domainModeChanged() {
        let index = domainModeControl.indexOfSelectedItem
        UserDefaults.standard.set(index, forKey: Self.domainModeDefaultsKey)
        let labels = ["自動判定", "実写（固定）", "イラスト・漫画（固定）"]
        if (0..<labels.count).contains(index) {
            updateStatus("画像種別: \(labels[index])（次回の候補生成から適用）")
        }
    }

    /// 鼠径部ROIの位置基準（腰0%〜膝100%の比率）を事前補正する。設定は永続化され、次回の候補生成から適用される。
    @objc private func groinPositionChanged() {
        let ratio = groinPositionSlider.doubleValue
        roiGenerator.groinPositionRatio = ratio
        UserDefaults.standard.set(ratio, forKey: Self.groinPositionDefaultsKey)
        groinPositionValueLabel.stringValue = "\(Int(ratio * 100))%"
        updateStatus("鼠径部位置の基準: 腰から膝方向へ\(Int(ratio * 100))%（次回の候補生成から適用）")
    }

    /// レイヤパネル先頭の表示トグル（人物検出/骨格検出/ROI）を該当レイヤへ一括適用する。
    @objc private func toggleDetectionLayers() {
        let personOn = personLayerCheckbox.state == .on
        let poseOn = poseLayerCheckbox.state == .on
        let roiOn = roiLayerCheckbox.state == .on
        for leaf in allLayerLeaves() {
            if leaf.kind.isPerson { leaf.isVisible = personOn }
            if leaf.kind.isPose { leaf.isVisible = poseOn }
            if leaf.kind == .roi { leaf.isVisible = roiOn }
        }
        applyLayerVisibility()
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
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        // レイヤ表示トグル（ツールバーから移設: 人物検出レイヤ・骨格検出レイヤ・ROIレイヤの一括ON/OFF）
        let togglesLabel = NSTextField(labelWithString: "表示:")
        togglesLabel.textColor = .secondaryLabelColor
        let togglesRow = NSStackView(views: [togglesLabel, personLayerCheckbox, poseLayerCheckbox, roiLayerCheckbox])
        togglesRow.orientation = .horizontal
        togglesRow.alignment = .centerY
        togglesRow.spacing = 8
        togglesRow.translatesAutoresizingMaskIntoConstraints = false
        togglesRow.setHuggingPriority(.required, for: .vertical)

        layerOutlineView.headerView = nil
        layerOutlineView.dataSource = self
        layerOutlineView.delegate = self
        layerOutlineView.allowsMultipleSelection = true
        layerOutlineView.indentationPerLevel = 14
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
        column.width = 220
        layerOutlineView.addTableColumn(column)
        layerOutlineView.outlineTableColumn = column

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = layerOutlineView

        groupButton.target = self
        groupButton.action = #selector(groupSelectedLayers)
        ungroupButton.target = self
        ungroupButton.action = #selector(ungroupSelectedGroup)
        let buttons = NSStackView(views: [groupButton, ungroupButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(title)
        panel.addSubview(togglesRow)
        panel.addSubview(scrollView)
        panel.addSubview(buttons)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            togglesRow.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            togglesRow.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            togglesRow.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: togglesRow.bottomAnchor, constant: 6),
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
        syncROIListSelectionFromCanvas()
    }

    /// ROI選択リストの行データを再構築する。同一カテゴリ名が複数ある場合のみ連番を付与する。
    private func rebuildROIListEntries() {
        var counts: [String: Int] = [:]
        for roi in canvas.rois { counts[roi.category.displayName, default: 0] += 1 }
        var counters: [String: Int] = [:]
        roiListEntries = canvas.rois.map { roi in
            let name = roi.category.displayName
            guard counts[name, default: 0] > 1 else { return ROIListEntry(roiID: roi.id, title: name) }
            counters[name, default: 0] += 1
            return ROIListEntry(roiID: roi.id, title: "\(name) \(counters[name] ?? 0)")
        }
        roiListSignature = canvas.rois.map { "\($0.id.uuidString)#\($0.category.rawValue)" }
    }

    /// ROIの件数・カテゴリが変わったときだけリストを再読込する（ドラッグ移動中の毎フレーム再描画を避ける）。
    private func refreshROIListIfNeeded() {
        let signature = canvas.rois.map { "\($0.id.uuidString)#\($0.category.rawValue)" }
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

    @objc private func groupSelectedLayers() {
        var leavesToGroup: [LayerLeaf] = []
        for index in layerOutlineView.selectedRowIndexes {
            if let leaf = layerOutlineView.item(atRow: index) as? LayerLeaf,
               ungroupedLayers.contains(where: { $0 === leaf }) {
                leavesToGroup.append(leaf)
            }
        }
        guard leavesToGroup.count >= 2 else {
            updateStatus("グループ化するレイヤを2つ以上選択してください")
            return
        }
        ungroupedLayers.removeAll { leaf in leavesToGroup.contains { $0 === leaf } }
        layerGroupCounter += 1
        let group = LayerGroup(name: "グループ\(layerGroupCounter)", children: leavesToGroup)
        layerGroups.append(group)
        reloadLayerList()
        updateStatus("\(group.name) を作成しました")
    }

    @objc private func ungroupSelectedGroup() {
        var didUngroup = false
        for index in layerOutlineView.selectedRowIndexes {
            if let group = layerOutlineView.item(atRow: index) as? LayerGroup {
                ungroupedLayers.append(contentsOf: group.children)
                layerGroups.removeAll { $0 === group }
                didUngroup = true
            }
        }
        if didUngroup {
            reloadLayerList()
            updateStatus("グループを解除しました")
        } else {
            updateStatus("解除するグループを選択してください")
        }
    }

    private func toggleLeafVisibility(_ leaf: LayerLeaf) {
        leaf.isVisible.toggle()
        applyLayerVisibility()
        syncLegacyLayerCheckboxes()
        reloadLayerList()
    }

    private func toggleGroupVisibility(_ group: LayerGroup) {
        let makeVisible = group.visibilityState != .on
        for child in group.children { child.isVisible = makeVisible }
        applyLayerVisibility()
        syncLegacyLayerCheckboxes()
        reloadLayerList()
    }

    private func allLayerLeaves() -> [LayerLeaf] {
        ungroupedLayers + layerGroups.flatMap(\.children)
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
        for leaf in allLayerLeaves() {
            switch leaf.kind {
            case .image: canvas.showImageLayer = leaf.isVisible
            case .roi: canvas.showROILayer = leaf.isVisible
            case .person(let index):
                if index < personVisibility.count { personVisibility[index] = leaf.isVisible }
            case .pose(let index):
                if index < poseVisibility.count { poseVisibility[index] = leaf.isVisible }
            }
        }
        canvas.personLayerVisibility = personVisibility
        canvas.poseLayerVisibility = poseVisibility
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

    @objc private func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let loaded = try imageLoader.loadImage(from: url)
            let item = try libraryEngine.importOriginal(loaded.cgImage, sourceName: url.lastPathComponent)
            setWorkingImage(loaded.cgImage, sourceURL: libraryEngine.originalURL(for: item), item: item)
            updateStatus("読み込み: \(url.lastPathComponent) \(Int(loaded.pixelSize.width))x\(Int(loaded.pixelSize.height))")
            reloadLibrary()
            autoGenerateIfEnabled()
        } catch {
            showError(error)
        }
    }

    @objc private func pasteImage() {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            updateStatus("クリップボードに画像がありません。ブラウザ画像をコピーしてから貼り付けてください")
            return
        }

        do {
            let item = try libraryEngine.importOriginal(cgImage, sourceName: "clipboard_\(Self.timestamp()).png")
            setWorkingImage(cgImage, sourceURL: libraryEngine.originalURL(for: item), item: item)
            updateStatus("貼り付け画像をライブラリへ保存: \(item.sourceName)")
            reloadLibrary()
            autoGenerateIfEnabled()
        } catch {
            showError(error)
        }
    }

    @objc private func generateCandidates() {
        guard let loadedImage else {
            updateStatus("先に画像を開いてください")
            return
        }
        let previousState = currentEditorState()
        do {
            // 実写/イラスト・漫画を先に判定する（「画像種別」の手動指定は自動判定より優先）
            let domain: ImageDomain
            let domainSourceNote: String
            switch domainModeControl.indexOfSelectedItem {
            case 1:
                domain = .photo
                domainSourceNote = "手動指定"
            case 2:
                domain = .illustration
                domainSourceNote = "手動指定"
            default:
                // モデルベース分類器（deepghs/anime_real_cls）を優先し、読み込めない場合は統計判定
                if let result = try? domainModelClassifier?.classify(loadedImage.cgImage) {
                    domain = result.domain
                    domainSourceNote = "自動判定 \(Int(result.confidence * 100))%"
                } else {
                    domain = DomainClassifier.classify(loadedImage.cgImage)
                    domainSourceNote = "自動判定"
                }
            }

            // 検出経路をドメインで切替える:
            // - 実写: Vision（インスタンスマスク+骨格）ベースの既存パイプライン
            // - イラスト/漫画: アニメ人物検出（矩形）。実写学習のVisionシルエットが
            //   イラストでは部分的にしか反応しないため使用しない。骨格モデルは未導入のため骨格なし。
            let snapshot: DetectionSnapshot
            if domain == .illustration {
                let persons = (try? animePersonDetector?.detectPersons(in: loadedImage.cgImage)) ?? []
                let hints = persons.map {
                    PoseHint(bodyBounds: $0.bounds, lowerBodyBounds: $0.bounds, joints: [])
                }
                snapshot = DetectionSnapshot(persons: persons, poseHints: hints, rois: [])
            } else {
                snapshot = try pipeline.generateDetailedCandidates(for: loadedImage.cgImage)
            }
            pushUndoSnapshot(previousState)
            suspendMosaicPreview()
            var rois = snapshot.rois

            // イラスト/漫画ではアニメ部位検出モデル（内容ベース検出）を実行して統合する
            var animeDetectionCount = 0
            if domain == .illustration, let detector = animeCensorDetector {
                let animeROIs = (try? detector.detect(in: loadedImage.cgImage)) ?? []
                animeDetectionCount = animeROIs.count
                rois = Self.mergeCandidates(base: rois, adding: animeROIs)
            }

            // 実写では実写用NSFW部位検出モデル（NudeNet）を実行して統合する
            // （従来は骨格からの位置推定のみで、性器の内容ベース検出が無かった）。
            // 全体画像に加えて人物クロップごとにも推論し、全身写真での解像度不足による検出漏れを防ぐ。
            var photoDetectionCount = 0
            if domain == .photo, let detector = photoCensorDetector {
                let photoROIs = (try? detector.detect(
                    in: loadedImage.cgImage,
                    personBounds: snapshot.personBounds
                )) ?? []
                photoDetectionCount = photoROIs.count
                rois = Self.mergeCandidates(base: rois, adding: photoROIs)
            }

            if let learningEngine {
                rois = learningEngine.refineCandidates(rois, persons: snapshot.personBounds, image: loadedImage.cgImage)
            }
            // 対象カテゴリでチェックされたものだけ生成する
            let checkedCategories = checkedGenerationCategories()
            let beforeFilterCount = rois.count
            rois = rois.filter { checkedCategories.contains($0.category) }
            let filteredOutCount = beforeFilterCount - rois.count
            // 自動候補にも「追加形状」の選択（矩形/楕円）を適用する
            let selectedShape = canvas.currentShape
            rois = rois.map { roi in
                var updated = roi
                updated.shape = selectedShape
                if selectedShape == .polygon && updated.polygonPoints == nil {
                    updated.polygonPoints = MosaicROI.defaultPolygonPoints
                }
                return updated
            }
            canvas.rois = rois
            lastAutoROIs = rois
            lastPersonBounds = snapshot.personBounds
            // 人物・骨格レイヤも「対象カテゴリ」のチェックに従って生成する（内部検出はROI推定に必要なため常時実行）
            let includePersonLayers = generatePersonCheckbox.state == .on
            let includePoseLayers = generatePoseCheckbox.state == .on
            canvas.personLayerRects = includePersonLayers ? snapshot.personBounds : []
            canvas.personLayerMasks = includePersonLayers
                ? snapshot.persons.map { $0.maskImage.flatMap { self.tintedMask(from: $0) } }
                : []
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
            // 候補生成後はレイヤパネル内のすべてのレイヤを表示状態にする
            showAllLayers()
            // 「モザイク表示」チェックがONなら新しい候補で自動的に再適用する
            resumeMosaicPreviewIfNeeded()

            let domainNote: String
            if domain == .illustration {
                domainNote = animeCensorDetector != nil
                    ? "イラスト/漫画（\(domainSourceNote)・アニメ部位検出: \(animeDetectionCount)件）: "
                    : "イラスト/漫画（\(domainSourceNote)・アニメ用検出モデルを読み込めませんでした）: "
            } else {
                domainNote = photoCensorDetector != nil
                    ? "実写（\(domainSourceNote)・実写部位検出: \(photoDetectionCount)件）: "
                    : "実写（\(domainSourceNote)・実写用検出モデルを読み込めませんでした）: "
            }
            let filterNote = filteredOutCount > 0 ? "（対象カテゴリ外 \(filteredOutCount)件を除外）" : ""
            if snapshot.persons.isEmpty && canvas.rois.isEmpty {
                updateStatus(domainNote + "人物を検出できませんでした（候補0件）\(filterNote)。ドラッグで手動追加してください")
            } else {
                let poseDetectedCount = snapshot.poseHints.filter { !$0.joints.isEmpty }.count
                updateStatus(domainNote + "候補生成: 人物\(snapshot.persons.count)名（骨格検出 \(poseDetectedCount)名） / ROI \(canvas.rois.count)件\(filterNote)。ドラッグで手動追加できます")
            }
        } catch {
            showError(error)
        }
    }

    /// 内容ベース検出（アニメ部位検出）の結果を既存候補へ統合する。
    /// 大きく重なる既存の自動候補（骨格ベース推定）は内容ベース検出を優先して置き換える。
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
        guard !hint.joints.isEmpty else { return hint.lowerBodyBounds }
        let xs = hint.joints.map(\.x)
        let ys = hint.joints.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return hint.lowerBodyBounds
        }
        let pad = 0.02
        return NormalizedRect(
            x: minX - pad,
            y: minY - pad,
            width: (maxX - minX) + pad * 2,
            height: (maxY - minY) + pad * 2
        ).clamped()
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
        guard let loadedImage else {
            mosaicPreviewCheckbox.state = .off
            return
        }
        if mosaicPreviewCheckbox.state == .on {
            do {
                let output = try mosaicEngine.applyMosaic(
                    to: loadedImage.cgImage,
                    rois: canvas.rois,
                    style: currentMosaicStyle(),
                    segmentEngine: currentSegmentEngine()
                )
                renderedImage = output
                canvas.setImage(output)
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
    /// ROIが空の場合や失敗時は元画像表示（チェック状態は維持）。
    private func resumeMosaicPreviewIfNeeded() {
        guard mosaicPreviewCheckbox.state == .on, let loadedImage else { return }
        guard !canvas.rois.isEmpty else {
            renderedImage = nil
            canvas.setImage(loadedImage.cgImage)
            return
        }
        do {
            let output = try mosaicEngine.applyMosaic(
                to: loadedImage.cgImage,
                rois: canvas.rois,
                style: currentMosaicStyle(),
                segmentEngine: currentSegmentEngine()
            )
            renderedImage = output
            canvas.setImage(output)
        } catch {
            renderedImage = nil
            canvas.setImage(loadedImage.cgImage)
        }
    }

    private func currentSegmentEngine() -> Segmenting {
        let index = segmentEngineControl.indexOfSelectedItem
        let kinds = SegmentEngineKind.allCases
        guard index >= 0, index < kinds.count else { return ShapeSegmentEngine() }
        switch kinds[index] {
        case .shape: return ShapeSegmentEngine()
        case .visionPersonSegmentation: return VisionPersonSegmentEngine()
        case .foregroundObjects: return ForegroundSegmentEngine()
        case .regionForeground: return RegionForegroundSegmentEngine()
        }
    }

    @objc private func applyMosaic() {
        guard let loadedImage else {
            updateStatus("先に画像を開いてください")
            return
        }
        let previousState = currentEditorState()
        do {
            let output = try mosaicEngine.applyMosaic(
                to: loadedImage.cgImage,
                rois: canvas.rois,
                style: currentMosaicStyle(),
                segmentEngine: currentSegmentEngine()
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

    @objc private func clearROIs() {
        guard !canvas.rois.isEmpty else { return }
        pushUndoSnapshot(currentEditorState())
        suspendMosaicPreview()
        canvas.rois = []
        resumeMosaicPreviewIfNeeded()
        updateStatus("ROIをクリアしました")
    }

    @objc private func performUndo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentEditorState())
        applyEditorState(previous)
        hasUnsavedChanges = true
        updateUndoRedoAvailability()
        updateStatus("元に戻しました: ROI \(canvas.rois.count)件")
    }

    @objc private func performRedo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentEditorState())
        applyEditorState(next)
        hasUnsavedChanges = true
        updateUndoRedoAvailability()
        updateStatus("やり直しました: ROI \(canvas.rois.count)件")
    }

    private func currentEditorState() -> EditorState {
        EditorState(rois: canvas.rois, renderedImage: renderedImage)
    }

    private func applyEditorState(_ state: EditorState) {
        canvas.rois = state.rois
        renderedImage = state.renderedImage
        guard let loadedImage else { return }
        // 「モザイク表示」チェックはユーザー操作でのみ変わる。チェック状態に合わせて表示を復元する。
        if mosaicPreviewCheckbox.state == .on {
            if let rendered = state.renderedImage {
                canvas.setImage(rendered)
            } else {
                resumeMosaicPreviewIfNeeded()
            }
        } else {
            canvas.setImage(loadedImage.cgImage)
        }
    }

    private func pushUndoSnapshot(_ state: EditorState) {
        undoStack.append(state)
        redoStack.removeAll()
        hasUnsavedChanges = true
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
    }

    @objc private func saveImage() {
        guard let loadedImage else {
            updateStatus("保存する画像がありません")
            return
        }
        let image = renderedImage ?? loadedImage.cgImage
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = loadedImage.url.deletingPathExtension().lastPathComponent + "_mosaic.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try savePNG(image, to: url)
            let historyURL = try defaultHistoryURL()
            let entry = MosaicHistoryEntry(
                imageName: loadedImage.url.lastPathComponent,
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
            updateStatus("保存しました: \(url.lastPathComponent)")
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
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        viewModeControl.selectedSegment = libraryViewMode.rawValue
        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeChanged)
        viewModeControl.translatesAutoresizingMaskIntoConstraints = false

        thumbnailSizeSlider.target = self
        thumbnailSizeSlider.action = #selector(thumbnailSizeChanged)
        thumbnailSizeSlider.translatesAutoresizingMaskIntoConstraints = false
        thumbnailSizeSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let modeRow = NSStackView(views: [viewModeControl, thumbnailSizeSlider])
        modeRow.orientation = .horizontal
        modeRow.spacing = 8
        modeRow.translatesAutoresizingMaskIntoConstraints = false

        libraryScrollView.hasVerticalScroller = true
        libraryScrollView.translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelectedLibraryOriginal)
        tableView.allowsMultipleSelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.title = "Item"
        column.width = 260
        tableView.addTableColumn(column)

        configureCollectionView()
        libraryScrollView.documentView = libraryViewMode == .thumbnailGrid ? collectionView : tableView

        let openOriginalButton = NSButton(title: "元画像を開く", target: self, action: #selector(openSelectedLibraryOriginal))
        let openProcessedButton = NSButton(title: "加工後を開く", target: self, action: #selector(openSelectedLibraryProcessed))
        let deleteButton = NSButton(title: "選択画像を削除", target: self, action: #selector(deleteSelectedLibraryItems))
        let buttons = NSStackView(views: [openOriginalButton, openProcessedButton, deleteButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let exportButton = NSButton(title: "学習用エクスポート（YOLO形式）", target: self, action: #selector(exportTrainingDataset))
        let secondButtons = NSStackView(views: [exportButton])
        secondButtons.orientation = .horizontal
        secondButtons.spacing = 8
        secondButtons.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(title)
        panel.addSubview(modeRow)
        panel.addSubview(libraryScrollView)
        panel.addSubview(buttons)
        panel.addSubview(secondButtons)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            modeRow.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            modeRow.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            modeRow.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -8),
            libraryScrollView.topAnchor.constraint(equalTo: modeRow.bottomAnchor, constant: 8),
            libraryScrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            libraryScrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            buttons.topAnchor.constraint(equalTo: libraryScrollView.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -8),
            secondButtons.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 6),
            secondButtons.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            secondButtons.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -8),
            secondButtons.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10)
        ])
        updateLibraryModeVisibility()
        return panel
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

    private func configureCollectionView() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: thumbnailSizeSlider.doubleValue, height: thumbnailSizeSlider.doubleValue + 28)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
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
        guard let indexPath = collectionView.indexPathForItem(at: point), indexPath.item < libraryItems.count else { return }
        selectedLibraryItemID = libraryItems[indexPath.item].id
        openSelectedLibraryOriginal()
    }

    @objc private func viewModeChanged() {
        guard let mode = LibraryViewMode(rawValue: viewModeControl.selectedSegment) else { return }
        libraryViewMode = mode
        updateLibraryModeVisibility()
    }

    @objc private func thumbnailSizeChanged() {
        guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let size = CGFloat(thumbnailSizeSlider.doubleValue)
        layout.itemSize = NSSize(width: size, height: size + 28)
        layout.invalidateLayout()
    }

    private func updateLibraryModeVisibility() {
        thumbnailSizeSlider.isHidden = libraryViewMode != .thumbnailGrid
        switch libraryViewMode {
        case .thumbnailGrid:
            libraryScrollView.documentView = collectionView
            collectionView.reloadData()
        case .textList, .thumbnailList:
            libraryScrollView.documentView = tableView
            tableView.reloadData()
            if !libraryItems.isEmpty {
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<libraryItems.count))
            }
        }
    }

    private func pruneThumbnailCache() {
        let currentIDs = Set(libraryItems.map(\.id))
        thumbnailCache = thumbnailCache.filter { currentIDs.contains($0.key) }
        thumbnailCacheUpdatedAt = thumbnailCacheUpdatedAt.filter { currentIDs.contains($0.key) }
    }

    private func thumbnail(for item: MosaicLibraryItem, maxDimension: CGFloat = 240) -> NSImage {
        if let cached = thumbnailCache[item.id], thumbnailCacheUpdatedAt[item.id] == item.updatedAt {
            return cached
        }
        let url = libraryEngine.processedURL(for: item) ?? libraryEngine.originalURL(for: item)
        guard let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0 else {
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
        return thumb
    }

    @objc private func openSelectedLibraryOriginal() {
        guard let item = selectedLibraryItem() else { return }
        loadLibraryImage(at: libraryEngine.originalURL(for: item), item: item, useProcessed: false)
    }

    @objc private func openSelectedLibraryProcessed() {
        guard let item = selectedLibraryItem(), let url = libraryEngine.processedURL(for: item) else {
            updateStatus("選択項目に加工後画像がありません")
            return
        }
        loadLibraryImage(at: url, item: item, useProcessed: true)
    }

    private func selectedLibraryItem() -> MosaicLibraryItem? {
        switch libraryViewMode {
        case .thumbnailGrid:
            guard let id = selectedLibraryItemID else { return nil }
            return libraryItems.first { $0.id == id }
        case .textList, .thumbnailList:
            let row = tableView.selectedRow
            guard row >= 0, row < libraryItems.count else { return nil }
            return libraryItems[row]
        }
    }

    /// 現在の表示モードで選択中の全アイテムを返す（Shift=範囲選択 / Cmd=個別追加選択に対応）。
    private func selectedLibraryItems() -> [MosaicLibraryItem] {
        switch libraryViewMode {
        case .thumbnailGrid:
            return collectionView.selectionIndexPaths
                .map(\.item)
                .sorted()
                .compactMap { $0 < libraryItems.count ? libraryItems[$0] : nil }
        case .textList, .thumbnailList:
            return tableView.selectedRowIndexes.compactMap { $0 < libraryItems.count ? libraryItems[$0] : nil }
        }
    }

    /// 選択中の画像をライブラリから一括削除する（確認ダイアログあり。元画像・加工後画像とも完全削除）。
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

        do {
            try libraryEngine.deleteItems(ids: items.map(\.id))
            let deletedIDs = Set(items.map(\.id))
            for id in deletedIDs {
                imageEditStates[id] = nil
                imageEditStateOrder.removeAll { $0 == id }
            }
            if let current = currentLibraryItem, deletedIDs.contains(current.id) {
                currentLibraryItem = nil
                loadedImage = nil
                renderedImage = nil
                mosaicPreviewCheckbox.state = .off
                canvas.clearImage()
                canvas.rois = []
                canvas.personLayerRects = []
                canvas.poseLayerRects = []
                canvas.personLayerMasks = []
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
            showError(error)
        }
    }

    private func selectLibraryItemInUI(_ item: MosaicLibraryItem) {
        selectedLibraryItemID = item.id
        if let row = libraryItems.firstIndex(where: { $0.id == item.id }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            collectionView.selectionIndexPaths = [IndexPath(item: row, section: 0)]
            collectionView.scrollToItems(at: [IndexPath(item: row, section: 0)], scrollPosition: .nearestHorizontalEdge)
        }
    }

    /// カーソルキーでのライブラリ画像切替。自動保存の設定に応じて保存確認を行ってから切り替える。
    private func navigateLibrary(by delta: Int) {
        guard !libraryItems.isEmpty else { return }
        let currentIndex = currentLibraryItem.flatMap { current in libraryItems.firstIndex { $0.id == current.id } }
        let newIndex = (currentIndex ?? -1) + delta
        guard newIndex >= 0, newIndex < libraryItems.count else { return }
        requestLibrarySwitch(to: libraryItems[newIndex])
    }

    private func requestLibrarySwitch(to item: MosaicLibraryItem) {
        guard item.id != currentLibraryItem?.id else { return }
        if autoSaveCheckbox.state == .on {
            performLibraryAutoSave()
            loadLibraryItemAsWorking(item)
            return
        }
        guard hasUnsavedChanges else {
            loadLibraryItemAsWorking(item)
            return
        }
        let alert = NSAlert()
        alert.messageText = "変更を保存しますか？"
        alert.informativeText = "現在の編集内容はまだ保存されていません。"
        alert.addButton(withTitle: "保存して次へ")
        alert.addButton(withTitle: "保存せず次へ")
        alert.addButton(withTitle: "キャンセル")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            performLibraryAutoSave()
            loadLibraryItemAsWorking(item)
        case .alertSecondButtonReturn:
            loadLibraryItemAsWorking(item)
        default:
            break
        }
    }

    private func performLibraryAutoSave() {
        guard hasUnsavedChanges, let loadedImage, let item = currentLibraryItem else { return }
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
            let restored = setWorkingImage(original.cgImage, sourceURL: originalURL, item: item)
            selectLibraryItemInUI(item)
            if restored { return }

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
            renderedImage: renderedImage,
            mosaicPreviewOn: mosaicPreviewCheckbox.state == .on,
            personLayerRects: canvas.personLayerRects,
            personLayerMasks: canvas.personLayerMasks,
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
        stashCurrentEditState()
        loadedImage = LoadedImage(url: sourceURL, cgImage: image)
        currentLibraryItem = item

        if let saved = imageEditStates[item.id] {
            renderedImage = saved.renderedImage
            mosaicPreviewCheckbox.state = (saved.mosaicPreviewOn && saved.renderedImage != nil) ? .on : .off
            canvas.setImage(mosaicPreviewCheckbox.state == .on ? saved.renderedImage! : image)
            canvas.rois = saved.rois
            canvas.personLayerRects = saved.personLayerRects
            canvas.personLayerMasks = saved.personLayerMasks
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
        mosaicPreviewCheckbox.state = .off
        canvas.setImage(image)
        canvas.rois = []
        canvas.personLayerRects = []
        canvas.poseLayerRects = []
        canvas.personLayerMasks = []
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

    private func savePNG(_ image: CGImage, to url: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
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
        statusLabel.stringValue = message
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}

extension MosaicWindowController: NSTableViewDataSource, NSTableViewDelegate {
    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated { libraryItems.count }
    }

    nonisolated func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        MainActor.assumeIsolated {
            guard row >= 0, row < libraryItems.count else { return nil }
            let item = libraryItems[row]
            let showThumbnail = libraryViewMode == .thumbnailList
            let identifier = NSUserInterfaceItemIdentifier(showThumbnail ? "LibraryCellThumb" : "LibraryCellText")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = identifier

            let label = cell.textField ?? NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.font = .systemFont(ofSize: 12)
            label.stringValue = "\(item.processedRelativePath == nil ? "元" : "済") \(item.sourceName)\n\(item.imagePixelWidth)x\(item.imagePixelHeight) ROI \(item.rois.count)"
            label.maximumNumberOfLines = 2

            if showThumbnail {
                let imageView = cell.imageView ?? NSImageView()
                imageView.imageScaling = .scaleProportionallyUpOrDown
                if imageView.superview == nil {
                    imageView.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(imageView)
                    NSLayoutConstraint.activate([
                        imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                        imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                        imageView.widthAnchor.constraint(equalToConstant: 36),
                        imageView.heightAnchor.constraint(equalToConstant: 36)
                    ])
                    cell.imageView = imageView
                }
                imageView.image = thumbnail(for: item)
                if label.superview == nil {
                    label.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(label)
                    NSLayoutConstraint.activate([
                        label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
                        label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                    ])
                    cell.textField = label
                }
            } else if label.superview == nil {
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
                cell.textField = label
            }
            return cell
        }
    }

    nonisolated func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        MainActor.assumeIsolated { libraryViewMode == .thumbnailList ? 44 : 34 }
    }
}

extension MosaicWindowController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    nonisolated func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        MainActor.assumeIsolated { libraryItems.count }
    }

    nonisolated func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        MainActor.assumeIsolated {
            let item = libraryItems[indexPath.item]
            guard let gridItem = collectionView.makeItem(
                withIdentifier: LibraryGridItem.identifier,
                for: indexPath
            ) as? LibraryGridItem else {
                return NSCollectionViewItem()
            }
            let caption = "\(item.processedRelativePath == nil ? "元" : "済") \(item.sourceName)"
            gridItem.configure(image: thumbnail(for: item), caption: caption)
            return gridItem
        }
    }

    nonisolated func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        MainActor.assumeIsolated {
            guard let indexPath = indexPaths.first, indexPath.item < libraryItems.count else { return }
            selectedLibraryItemID = libraryItems[indexPath.item].id
        }
    }
}

extension MosaicWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return layerGroups.count + ungroupedLayers.count }
        if let group = item as? LayerGroup { return group.children.count }
        if let leaf = item as? LayerLeaf, leaf.kind == .roi { return roiListEntries.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is LayerGroup { return true }
        if let leaf = item as? LayerLeaf, leaf.kind == .roi { return !roiListEntries.isEmpty }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            if index < layerGroups.count { return layerGroups[index] }
            return ungroupedLayers[index - layerGroups.count]
        }
        if let group = item as? LayerGroup { return group.children[index] }
        if let leaf = item as? LayerLeaf, leaf.kind == .roi, index < roiListEntries.count {
            return roiListEntries[index]
        }
        return ungroupedLayers[0]
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
            // ROI選択リストの行（表示チェックなし。クリックでキャンバス上のROIを選択）
            cell.configure(title: entry.title, state: .off, allowsMixed: false, showsCheckbox: false)
            cell.onToggle = nil
        }
        return cell
    }

    nonisolated func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        true
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingROISelection else { return }
        let selectedEntries = layerOutlineView.selectedRowIndexes.compactMap {
            layerOutlineView.item(atRow: $0) as? ROIListEntry
        }
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

        captionField.font = .systemFont(ofSize: 11)
        captionField.alignment = .center
        captionField.lineBreakMode = .byTruncatingMiddle
        captionField.maximumNumberOfLines = 2
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
    var personLayerVisibility: [Bool] = [] { didSet { needsDisplay = true } }
    var poseLayerVisibility: [Bool] = [] { didSet { needsDisplay = true } }
    var personLayerMasks: [CGImage?] = [] { didSet { needsDisplay = true } }
    var poseLayerBones: [[(from: CGPoint, to: CGPoint)]] = [] { didSet { needsDisplay = true } }
    var poseLayerJointPoints: [[CGPoint]] = [] { didSet { needsDisplay = true } }
    var showImageLayer = true { didSet { needsDisplay = true } }
    var showROILayer = true { didSet { needsDisplay = true } }

    var onROIsChanged: (([MosaicROI]) -> Void)?
    var onManualEditWillBegin: (() -> Void)?
    var onManualEditDidEnd: (() -> Void)?
    var onROISelectionChanged: ((MosaicROI?) -> Void)?
    /// ROI右クリックメニューからのカテゴリ変更要求（ツールバーのカテゴリポップアップ廃止に伴う置き換え）
    var onCategoryChangeRequest: ((UUID, MosaicTargetCategory) -> Void)?

    private var lastSize: [ROIShape: NSSize] = [:]
    private var image: NSImage?
    private var imagePixelSize: CGSize = .zero
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var resizeState: ResizeState?
    private var moveState: MoveState?
    private var rotationState: RotationState?
    private var vertexDragState: VertexDragState?

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

    private struct MoveState {
        var roiID: UUID
        var lastPoint: NSPoint
        var didBeginEdit = false
    }

    private let handleRadius: CGFloat = 7
    private let dragThreshold: CGFloat = 4

    override var isFlipped: Bool { true }

    func setImage(_ cgImage: CGImage) {
        image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        imagePixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        needsDisplay = true
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
        if let dragStart, let dragCurrent {
            drawPreviewShape(NSRect(
                x: min(dragStart.x, dragCurrent.x),
                y: min(dragStart.y, dragCurrent.y),
                width: abs(dragCurrent.x - dragStart.x),
                height: abs(dragCurrent.y - dragStart.y)
            ))
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
        let point = convert(event.locationInWindow, from: nil)

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
        }

        let imageRect = imageDrawRect()
        if let hit = roiHit(at: point, imageRect: imageRect) {
            selectedROIID = hit.id
            moveState = MoveState(roiID: hit.id, lastPoint: point)
            return
        }

        selectedROIID = nil
        dragStart = point
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
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
            return
        }

        guard dragStart != nil else { return }
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
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

        guard let start = dragStart else { return }
        defer {
            dragStart = nil
            dragCurrent = nil
            needsDisplay = true
        }

        guard imageDrawRect().contains(start) else { return }

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
            .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func drawROIs(in target: NSRect) {
        for roi in rois {
            let rect = viewRect(from: roi.rect, imageRect: target)
            let color: NSColor = roi.source == "manual" ? .systemGreen : .systemRed
            drawShape(roi, rect: rect, color: color)
            drawCategoryLabel(roi, near: rect, color: color)
            if roi.id == selectedROIID {
                drawSelectionHandles(rect, rotation: roi.rotation)
                drawRotationHandle(rect: rect, rotation: roi.rotation)
                if roi.shape == .polygon {
                    drawPolygonVertexHandles(roi: roi, rect: rect)
                }
            }
        }
    }

    /// ROIのカテゴリ名を矩形の左上へ小さく表示する（対象カテゴリ変更の結果を画面上で確認できるようにする）。
    private func drawCategoryLabel(_ roi: MosaicROI, near rect: NSRect, color: NSColor) {
        let text = roi.category.displayName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
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
            let viewR = viewRect(from: rect, imageRect: target)
            if index < personLayerMasks.count, let mask = personLayerMasks[index] {
                NSImage(cgImage: mask, size: NSSize(width: mask.width, height: mask.height))
                    .draw(in: target, from: .zero, operation: .sourceOver, fraction: 0.9)
                drawDashedRect(viewR, color: .systemBlue)
            } else {
                drawLayerRect(viewR, color: .systemBlue)
            }
            drawLayerName("人物検出\(index + 1)", in: viewR, color: .systemBlue)
        }
        for (index, rect) in poseLayerRects.enumerated() {
            guard index < poseLayerVisibility.count, poseLayerVisibility[index] else { continue }
            let viewR = viewRect(from: rect, imageRect: target)
            drawLayerRect(viewR, color: .systemOrange)
            if index < poseLayerBones.count {
                drawBones(
                    poseLayerBones[index],
                    jointPoints: index < poseLayerJointPoints.count ? poseLayerJointPoints[index] : [],
                    imageRect: target
                )
            }
            drawLayerName("骨格検出\(index + 1)", in: viewR, color: .systemOrange)
        }
    }

    /// レイヤ範囲の右下内側にレイヤ名を表示する。
    private func drawLayerName(_ text: String, in rect: NSRect, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
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
        if imageAspect > viewAspect {
            let width = available.width
            let height = width / imageAspect
            return NSRect(x: available.minX, y: available.midY - height / 2, width: width, height: height)
        } else {
            let height = available.height
            let width = height * imageAspect
            return NSRect(x: available.midX - width / 2, y: available.minY, width: width, height: height)
        }
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
