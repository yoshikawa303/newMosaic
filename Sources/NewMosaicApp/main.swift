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
        window.center()
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
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

    func configure(title: String, state: NSControl.StateValue, allowsMixed: Bool) {
        label.stringValue = title
        checkbox.allowsMixedState = allowsMixed
        checkbox.state = state
    }

    @objc private func handleToggle() {
        onToggle?()
    }
}

/// ライブラリ一覧で上下（左右）矢印キーによる画像切替を可能にするテーブルビュー。
@MainActor
private final class NavigableTableView: NSTableView {
    var onNavigate: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
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

/// ライブラリ一覧（グリッド表示）で矢印キーによる画像切替を可能にするコレクションビュー。
@MainActor
private final class NavigableCollectionView: NSCollectionView {
    var onNavigate: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
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
    private let pipeline = StaticImageMosaicPipeline()
    private let mosaicEngine = MosaicEngine()
    private let historyEngine = HistoryEngine()
    private let libraryEngine: LibraryEngine = (try? LibraryEngine.defaultLibrary())
        ?? LibraryEngine(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("newMosaic/Library"))
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
        labels: ["矩形", "楕円"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let personLayerCheckbox = NSButton(checkboxWithTitle: "人物検出レイヤ", target: nil, action: nil)
    private let poseLayerCheckbox = NSButton(checkboxWithTitle: "骨格検出レイヤ", target: nil, action: nil)
    private let categoryControl = NSPopUpButton(title: "", target: nil, action: nil)
    private let segmentEngineControl = NSPopUpButton(title: "", target: nil, action: nil)
    private let layerButton = NSButton(title: "レイヤ...", target: nil, action: nil)
    private let layerOutlineView = NSOutlineView()
    private let layerPopover = NSPopover()
    private let groupButton = NSButton(title: "グループ化", target: nil, action: nil)
    private let ungroupButton = NSButton(title: "グループ解除", target: nil, action: nil)
    private let autoGenerateCheckbox = NSButton(checkboxWithTitle: "自動候補生成", target: nil, action: nil)
    private let autoSaveCheckbox = NSButton(checkboxWithTitle: "自動保存", target: nil, action: nil)
    private var ungroupedLayers: [LayerLeaf] = [
        LayerLeaf(kind: .image, isVisible: true),
        LayerLeaf(kind: .roi, isVisible: true)
    ]
    private var layerGroups: [LayerGroup] = []
    private var layerGroupCounter = 0
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

    override init() {
        super.init()
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
        let categoryLabel = NSTextField(labelWithString: "対象カテゴリ:")
        categoryControl.removeAllItems()
        categoryControl.addItems(withTitles: MosaicTargetCategory.allCases.map(\.displayName))
        if let otherIndex = MosaicTargetCategory.allCases.firstIndex(of: .other) {
            categoryControl.selectItem(at: otherIndex)
        }
        let segmentEngineLabel = NSTextField(labelWithString: "マスク生成:")
        segmentEngineControl.removeAllItems()
        segmentEngineControl.addItems(withTitles: SegmentEngineKind.allCases.map(\.displayName))
        segmentEngineControl.selectItem(at: 0)
        let editToolbar = NSStackView(views: [
            shapeLabel, shapeControl, categoryLabel, categoryControl,
            segmentEngineLabel, segmentEngineControl,
            personLayerCheckbox, poseLayerCheckbox, layerButton,
            autoGenerateCheckbox, autoSaveCheckbox
        ])
        editToolbar.orientation = .horizontal
        editToolbar.alignment = .centerY
        editToolbar.spacing = 10
        editToolbar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 8, right: 12)
        editToolbar.translatesAutoresizingMaskIntoConstraints = false

        canvas.translatesAutoresizingMaskIntoConstraints = false
        let libraryPanel = makeLibraryPanel()
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(canvas)
        splitView.addArrangedSubview(libraryPanel)
        libraryPanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        root.addSubview(toolbar)
        root.addSubview(editToolbar)
        root.addSubview(splitView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editToolbar.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            editToolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editToolbar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: editToolbar.bottomAnchor),
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
        reloadLibraryButton.action = #selector(reloadLibrary)
        revealButton.target = self
        revealButton.action = #selector(revealLibrary)
        shapeControl.target = self
        shapeControl.action = #selector(shapeControlChanged)
        categoryControl.target = self
        categoryControl.action = #selector(categoryControlChanged)
        personLayerCheckbox.target = self
        personLayerCheckbox.action = #selector(toggleDetectionLayers)
        poseLayerCheckbox.target = self
        poseLayerCheckbox.action = #selector(toggleDetectionLayers)
        layerButton.target = self
        layerButton.action = #selector(toggleLayerPopover)
        setUpLayerPopover()

        canvas.currentShape = .ellipse
        canvas.currentCategory = .other
        canvas.onROIsChanged = { [weak self] rois in
            self?.updateStatus("ROI \(rois.count)件")
        }
        canvas.onManualEditWillBegin = { [weak self] in
            guard let self else { return }
            self.pushUndoSnapshot(self.currentEditorState())
        }
        canvas.onROISelectionChanged = { [weak self] roi in
            guard let self, let roi else { return }
            self.shapeControl.selectedSegment = roi.shape == .rectangle ? 0 : 1
            if let index = MosaicTargetCategory.allCases.firstIndex(of: roi.category) {
                self.categoryControl.selectItem(at: index)
            }
        }
        tableView.onNavigate = { [weak self] delta in
            self?.navigateLibrary(by: delta)
        }
        collectionView.onNavigate = { [weak self] delta in
            self?.navigateLibrary(by: delta)
        }
        applyLayerVisibility()
        updateUndoRedoAvailability()
        reloadLibrary()
    }

    @objc private func shapeControlChanged() {
        let shape: ROIShape = shapeControl.selectedSegment == 0 ? .rectangle : .ellipse
        canvas.currentShape = shape
        if let selectedID = canvas.selectedROIID,
           let index = canvas.rois.firstIndex(where: { $0.id == selectedID }),
           canvas.rois[index].shape != shape {
            pushUndoSnapshot(currentEditorState())
            canvas.rois[index].shape = shape
        }
    }

    @objc private func categoryControlChanged() {
        let index = categoryControl.indexOfSelectedItem
        guard index >= 0, index < MosaicTargetCategory.allCases.count else { return }
        let category = MosaicTargetCategory.allCases[index]
        canvas.currentCategory = category
        if let selectedID = canvas.selectedROIID,
           let roiIndex = canvas.rois.firstIndex(where: { $0.id == selectedID }),
           canvas.rois[roiIndex].category != category {
            pushUndoSnapshot(currentEditorState())
            canvas.rois[roiIndex].category = category
        }
    }

    @objc private func toggleDetectionLayers() {
        let personOn = personLayerCheckbox.state == .on
        let poseOn = poseLayerCheckbox.state == .on
        for leaf in allLayerLeaves() {
            if leaf.kind.isPerson { leaf.isVisible = personOn }
            if leaf.kind.isPose { leaf.isVisible = poseOn }
        }
        applyLayerVisibility()
        layerOutlineView.reloadData()
    }

    /// 候補生成で得た人物・骨格の検出数に合わせてレイヤを再構築する。
    /// 各人物のROIと骨格ヒントが1組ずつ揃う場合は自動的に「人物N」グループへまとめ、
    /// 対になる相手がいない場合はグループ化せずトップレベルへ追加する。
    private func rebuildDetectionLayers(personCount: Int, poseCount: Int) {
        ungroupedLayers.removeAll { $0.kind.isPerson || $0.kind.isPose }
        for group in layerGroups {
            group.children.removeAll { $0.kind.isPerson || $0.kind.isPose }
        }
        layerGroups.removeAll { $0.children.isEmpty }

        let pairedCount = min(personCount, poseCount)
        for index in 0..<pairedCount {
            let personLeaf = LayerLeaf(kind: .person(index), isVisible: false)
            let poseLeaf = LayerLeaf(kind: .pose(index), isVisible: false)
            let group = LayerGroup(name: "人物\(index + 1)", children: [personLeaf, poseLeaf])
            layerGroups.append(group)
        }
        if personCount > pairedCount {
            for index in pairedCount..<personCount {
                ungroupedLayers.append(LayerLeaf(kind: .person(index), isVisible: false))
            }
        }
        if poseCount > pairedCount {
            for index in pairedCount..<poseCount {
                ungroupedLayers.append(LayerLeaf(kind: .pose(index), isVisible: false))
            }
        }
        layerOutlineView.reloadData()
    }

    // MARK: - レイヤ表示・グループ化

    private func setUpLayerPopover() {
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

        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scrollView)
        panel.addSubview(buttons)
        NSLayoutConstraint.activate([
            panel.widthAnchor.constraint(equalToConstant: 260),
            panel.heightAnchor.constraint(equalToConstant: 260),
            scrollView.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            buttons.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -8),
            buttons.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8)
        ])

        let contentController = NSViewController()
        contentController.view = panel
        layerPopover.behavior = .transient
        layerPopover.contentViewController = contentController
    }

    @objc private func toggleLayerPopover() {
        if layerPopover.isShown {
            layerPopover.close()
        } else {
            layerOutlineView.reloadData()
            layerPopover.show(relativeTo: layerButton.bounds, of: layerButton, preferredEdge: .maxY)
        }
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
        layerOutlineView.reloadData()
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
            layerOutlineView.reloadData()
            updateStatus("グループを解除しました")
        } else {
            updateStatus("解除するグループを選択してください")
        }
    }

    private func toggleLeafVisibility(_ leaf: LayerLeaf) {
        leaf.isVisible.toggle()
        applyLayerVisibility()
        syncLegacyLayerCheckboxes()
        layerOutlineView.reloadData()
    }

    private func toggleGroupVisibility(_ group: LayerGroup) {
        let makeVisible = group.visibilityState != .on
        for child in group.children { child.isVisible = makeVisible }
        applyLayerVisibility()
        syncLegacyLayerCheckboxes()
        layerOutlineView.reloadData()
    }

    private func allLayerLeaves() -> [LayerLeaf] {
        ungroupedLayers + layerGroups.flatMap(\.children)
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

    private func syncLegacyLayerCheckboxes() {
        personLayerCheckbox.allowsMixedState = true
        poseLayerCheckbox.allowsMixedState = true
        personLayerCheckbox.state = aggregateVisibilityState(allLayerLeaves().filter(\.kind.isPerson))
        poseLayerCheckbox.state = aggregateVisibilityState(allLayerLeaves().filter(\.kind.isPose))
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
            let snapshot = try pipeline.generateDetailedCandidates(for: loadedImage.cgImage)
            pushUndoSnapshot(previousState)
            canvas.rois = snapshot.rois
            canvas.personLayerRects = snapshot.personBounds
            canvas.personLayerMasks = snapshot.persons.map { $0.maskImage.flatMap { self.tintedMask(from: $0) } }
            canvas.poseLayerRects = snapshot.poseHints.map { Self.poseDisplayRect(for: $0) }
            canvas.poseLayerBones = snapshot.poseHints.map { Self.boneSegments(for: $0) }
            canvas.poseLayerJointPoints = snapshot.poseHints.map { $0.joints.map { CGPoint(x: $0.x, y: $0.y) } }
            rebuildDetectionLayers(personCount: snapshot.personBounds.count, poseCount: snapshot.poseHints.count)
            applyLayerVisibility()
            syncLegacyLayerCheckboxes()
            updateStatus("候補生成: 人物\(snapshot.persons.count)名 / ROI \(canvas.rois.count)件。ドラッグで手動追加できます")
        } catch {
            showError(error)
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
        PoseJointName.boneConnections.compactMap { pair in
            guard let a = hint.joint(pair.0), let b = hint.joint(pair.1) else { return nil }
            return (CGPoint(x: a.x, y: a.y), CGPoint(x: b.x, y: b.y))
        }
    }

    private func currentSegmentEngine() -> Segmenting {
        let index = segmentEngineControl.indexOfSelectedItem
        let kinds = SegmentEngineKind.allCases
        guard index >= 0, index < kinds.count else { return ShapeSegmentEngine() }
        switch kinds[index] {
        case .shape: return ShapeSegmentEngine()
        case .visionPersonSegmentation: return VisionPersonSegmentEngine()
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
                segmentEngine: currentSegmentEngine()
            )
            pushUndoSnapshot(previousState)
            renderedImage = output
            canvas.setImage(output)
            if let item = currentLibraryItem {
                currentLibraryItem = try libraryEngine.saveProcessedImage(output, rois: canvas.rois, for: item.id)
                hasUnsavedChanges = false
                reloadLibrary()
            }
            updateStatus("モザイク適用済み: ROI \(canvas.rois.count)件")
        } catch {
            showError(error)
        }
    }

    @objc private func clearROIs() {
        guard !canvas.rois.isEmpty else { return }
        pushUndoSnapshot(currentEditorState())
        canvas.rois = []
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
        if let loadedImage {
            canvas.setImage(state.renderedImage ?? loadedImage.cgImage)
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
                reloadLibrary()
            }
            updateStatus("保存しました: \(url.lastPathComponent)")
        } catch {
            showError(error)
        }
    }

    @objc private func reloadLibrary() {
        do {
            libraryItems = try libraryEngine.loadItems()
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
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.title = "Item"
        column.width = 260
        tableView.addTableColumn(column)

        configureCollectionView()
        libraryScrollView.documentView = libraryViewMode == .thumbnailGrid ? collectionView : tableView

        let openOriginalButton = NSButton(title: "元画像を開く", target: self, action: #selector(openSelectedLibraryOriginal))
        let openProcessedButton = NSButton(title: "加工後を開く", target: self, action: #selector(openSelectedLibraryProcessed))
        let buttons = NSStackView(views: [openOriginalButton, openProcessedButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(title)
        panel.addSubview(modeRow)
        panel.addSubview(libraryScrollView)
        panel.addSubview(buttons)
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
            buttons.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10)
        ])
        updateLibraryModeVisibility()
        return panel
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
            reloadLibrary()
        } catch {
            showError(error)
        }
    }

    private func loadLibraryItemAsWorking(_ item: MosaicLibraryItem) {
        if let processedURL = libraryEngine.processedURL(for: item) {
            loadLibraryImage(at: processedURL, item: item, useProcessed: true)
        } else {
            loadLibraryImage(at: libraryEngine.originalURL(for: item), item: item, useProcessed: false)
        }
    }

    private func loadLibraryImage(at url: URL, item: MosaicLibraryItem, useProcessed: Bool) {
        do {
            let loaded = try imageLoader.loadImage(from: url)
            setWorkingImage(loaded.cgImage, sourceURL: url, item: item)
            canvas.rois = useProcessed ? item.rois : []
            renderedImage = useProcessed ? loaded.cgImage : nil
            selectLibraryItemInUI(item)
            updateStatus("\(useProcessed ? "加工後" : "元画像")を開きました: \(item.sourceName)")
            if !useProcessed || item.rois.isEmpty {
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

    private func setWorkingImage(_ image: CGImage, sourceURL: URL, item: MosaicLibraryItem) {
        loadedImage = LoadedImage(url: sourceURL, cgImage: image)
        renderedImage = nil
        currentLibraryItem = item
        canvas.setImage(image)
        canvas.rois = []
        canvas.personLayerRects = []
        canvas.poseLayerRects = []
        canvas.personLayerMasks = []
        canvas.poseLayerBones = []
        canvas.poseLayerJointPoints = []
        canvas.selectedROIID = nil
        rebuildDetectionLayers(personCount: 0, poseCount: 0)
        applyLayerVisibility()
        syncLegacyLayerCheckboxes()
        resetUndoHistory()
        hasUnsavedChanges = false
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
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is LayerGroup
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            if index < layerGroups.count { return layerGroups[index] }
            return ungroupedLayers[index - layerGroups.count]
        }
        if let group = item as? LayerGroup { return group.children[index] }
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
        }
        return cell
    }

    nonisolated func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        true
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
    var onROISelectionChanged: ((MosaicROI?) -> Void)?

    private var lastSize: [ROIShape: NSSize] = [:]
    private var image: NSImage?
    private var imagePixelSize: CGSize = .zero
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var resizeState: ResizeState?
    private var moveState: MoveState?

    private struct ResizeState {
        var roiID: UUID
        var anchor: NSPoint
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

    override func mouseDown(with event: NSEvent) {
        guard image != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard imageDrawRect().contains(point) else { return }

        if event.clickCount >= 2 {
            let imageRect = imageDrawRect()
            if let hit = rois.last(where: { viewRect(from: $0.rect, imageRect: imageRect).contains(point) }) {
                onManualEditWillBegin?()
                if selectedROIID == hit.id { selectedROIID = nil }
                rois.removeAll { $0.id == hit.id }
                return
            }
        }

        if let selectedID = selectedROIID,
           let roi = rois.first(where: { $0.id == selectedID }),
           let anchor = handleAnchor(at: point, roi: roi, imageRect: imageDrawRect()) {
            onManualEditWillBegin?()
            resizeState = ResizeState(roiID: selectedID, anchor: anchor)
            return
        }

        let imageRect = imageDrawRect()
        if let hit = rois.last(where: { viewRect(from: $0.rect, imageRect: imageRect).contains(point) }) {
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

        if let resize = resizeState {
            let newViewRect = NSRect(
                x: min(resize.anchor.x, point.x),
                y: min(resize.anchor.y, point.y),
                width: abs(point.x - resize.anchor.x),
                height: abs(point.y - resize.anchor.y)
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

        if let resize = resizeState {
            resizeState = nil
            if let index = rois.firstIndex(where: { $0.id == resize.roiID }) {
                lastSize[rois[index].shape] = NSSize(width: rois[index].rect.width, height: rois[index].rect.height)
            }
            needsDisplay = true
            return
        }

        if moveState != nil {
            moveState = nil
            needsDisplay = true
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
        let roi = MosaicROI(rect: normalized, confidence: 1, source: "manual", shape: currentShape, category: currentCategory)
        rois.append(roi)
        selectedROIID = roi.id
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
        let roi = MosaicROI(rect: rect, confidence: 1, source: "manual", shape: currentShape, category: currentCategory)
        rois.append(roi)
        selectedROIID = roi.id
    }

    private func handleAnchor(at point: NSPoint, roi: MosaicROI, imageRect: NSRect) -> NSPoint? {
        let rect = viewRect(from: roi.rect, imageRect: imageRect)
        let corners: [(handle: NSPoint, anchor: NSPoint)] = [
            (NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.maxY)),
            (NSPoint(x: rect.maxX, y: rect.minY), NSPoint(x: rect.minX, y: rect.maxY)),
            (NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.minY)),
            (NSPoint(x: rect.maxX, y: rect.maxY), NSPoint(x: rect.minX, y: rect.minY))
        ]
        for corner in corners where abs(corner.handle.x - point.x) <= handleRadius && abs(corner.handle.y - point.y) <= handleRadius {
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
            drawShape(roi.shape, rect: rect, color: color)
            if roi.id == selectedROIID {
                drawSelectionHandles(rect)
            }
        }
    }

    private func drawShape(_ shape: ROIShape, rect: NSRect, color: NSColor) {
        let path = shape == .ellipse ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
        color.withAlphaComponent(0.18).setFill()
        path.fill()
        color.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private func drawPreviewShape(_ rect: NSRect) {
        let path = currentShape == .ellipse ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
        NSColor.systemYellow.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private func drawSelectionHandles(_ rect: NSRect) {
        let size: CGFloat = 8
        let points = [
            NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY)
        ]
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
            if index < personLayerMasks.count, let mask = personLayerMasks[index] {
                NSImage(cgImage: mask, size: NSSize(width: mask.width, height: mask.height))
                    .draw(in: target, from: .zero, operation: .sourceOver, fraction: 0.9)
                drawDashedRect(viewRect(from: rect, imageRect: target), color: .systemBlue)
            } else {
                drawLayerRect(viewRect(from: rect, imageRect: target), color: .systemBlue)
            }
        }
        for (index, rect) in poseLayerRects.enumerated() {
            guard index < poseLayerVisibility.count, poseLayerVisibility[index] else { continue }
            drawLayerRect(viewRect(from: rect, imageRect: target), color: .systemOrange)
            if index < poseLayerBones.count {
                drawBones(
                    poseLayerBones[index],
                    jointPoints: index < poseLayerJointPoints.count ? poseLayerJointPoints[index] : [],
                    imageRect: target
                )
            }
        }
    }

    private func drawDashedRect(_ rect: NSRect, color: NSColor) {
        color.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.stroke()
    }

    private func drawBones(_ bones: [(from: CGPoint, to: CGPoint)], jointPoints: [CGPoint], imageRect: NSRect) {
        NSColor.systemOrange.setStroke()
        for bone in bones {
            let path = NSBezierPath()
            path.move(to: viewPoint(bone.from, imageRect: imageRect))
            path.line(to: viewPoint(bone.to, imageRect: imageRect))
            path.lineWidth = 2
            path.stroke()
        }
        NSColor.systemOrange.setFill()
        for joint in jointPoints {
            let center = viewPoint(joint, imageRect: imageRect)
            NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)).fill()
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
