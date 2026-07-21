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
        window.title = "newMosaic"
        window.center()
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
    private let tableView = NSTableView()
    private var loadedImage: LoadedImage?
    private var renderedImage: CGImage?
    private var currentLibraryItem: MosaicLibraryItem?
    private var libraryItems: [MosaicLibraryItem] = []

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
        let saveButton = NSButton(title: "保存", target: nil, action: nil)
        let reloadLibraryButton = NSButton(title: "ライブラリ更新", target: nil, action: nil)
        let revealButton = NSButton(title: "Finder表示", target: nil, action: nil)

        let toolbar = NSStackView(views: [openButton, pasteButton, detectButton, applyButton, clearButton, saveButton, reloadLibraryButton, revealButton, statusLabel])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 8, right: 12)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

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
        root.addSubview(splitView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
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
        saveButton.target = self
        saveButton.action = #selector(saveImage)
        reloadLibraryButton.target = self
        reloadLibraryButton.action = #selector(reloadLibrary)
        revealButton.target = self
        revealButton.action = #selector(revealLibrary)

        canvas.onROIsChanged = { [weak self] rois in
            self?.updateStatus("ROI \(rois.count)件")
        }
        reloadLibrary()
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
        } catch {
            showError(error)
        }
    }

    @objc private func generateCandidates() {
        guard let loadedImage else {
            updateStatus("先に画像を開いてください")
            return
        }
        do {
            canvas.rois = try pipeline.generateCandidates(for: loadedImage.cgImage)
            updateStatus("候補生成: ROI \(canvas.rois.count)件。ドラッグで手動追加できます")
        } catch {
            showError(error)
        }
    }

    @objc private func applyMosaic() {
        guard let loadedImage else {
            updateStatus("先に画像を開いてください")
            return
        }
        do {
            let output = try mosaicEngine.applyMosaic(to: loadedImage.cgImage, rois: canvas.rois)
            renderedImage = output
            canvas.setImage(output)
            if let item = currentLibraryItem {
                currentLibraryItem = try libraryEngine.saveProcessedImage(output, rois: canvas.rois, for: item.id)
                reloadLibrary()
            }
            updateStatus("モザイク適用済み: ROI \(canvas.rois.count)件")
        } catch {
            showError(error)
        }
    }

    @objc private func clearROIs() {
        canvas.rois = []
        updateStatus("ROIをクリアしました")
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
            tableView.reloadData()
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

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelectedLibraryOriginal)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.title = "Item"
        column.width = 260
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        let openOriginalButton = NSButton(title: "元画像を開く", target: self, action: #selector(openSelectedLibraryOriginal))
        let openProcessedButton = NSButton(title: "加工後を開く", target: self, action: #selector(openSelectedLibraryProcessed))
        let buttons = NSStackView(views: [openOriginalButton, openProcessedButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(title)
        panel.addSubview(scrollView)
        panel.addSubview(buttons)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            buttons.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -8),
            buttons.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10)
        ])
        return panel
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
        let row = tableView.selectedRow
        guard row >= 0, row < libraryItems.count else { return nil }
        return libraryItems[row]
    }

    private func loadLibraryImage(at url: URL, item: MosaicLibraryItem, useProcessed: Bool) {
        do {
            let loaded = try imageLoader.loadImage(from: url)
            setWorkingImage(loaded.cgImage, sourceURL: url, item: item)
            canvas.rois = useProcessed ? item.rois : []
            renderedImage = useProcessed ? loaded.cgImage : nil
            updateStatus("\(useProcessed ? "加工後" : "元画像")を開きました: \(item.sourceName)")
        } catch {
            showError(error)
        }
    }

    private func setWorkingImage(_ image: CGImage, sourceURL: URL, item: MosaicLibraryItem) {
        loadedImage = LoadedImage(url: sourceURL, cgImage: image)
        renderedImage = nil
        currentLibraryItem = item
        canvas.setImage(image)
        canvas.rois = []
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
            let identifier = NSUserInterfaceItemIdentifier("LibraryCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = identifier
            let label = cell.textField ?? NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.font = .systemFont(ofSize: 12)
            label.stringValue = "\(item.processedRelativePath == nil ? "元" : "済") \(item.sourceName)\n\(item.imagePixelWidth)x\(item.imagePixelHeight) ROI \(item.rois.count)"
            label.maximumNumberOfLines = 2
            if label.superview == nil {
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
        44
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

    var onROIsChanged: (([MosaicROI]) -> Void)?

    private var image: NSImage?
    private var imagePixelSize: CGSize = .zero
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

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
        image.draw(in: target)
        drawROIs(in: target)
        if let dragStart, let dragCurrent {
            drawRect(NSRect(
                x: min(dragStart.x, dragCurrent.x),
                y: min(dragStart.y, dragCurrent.y),
                width: abs(dragCurrent.x - dragStart.x),
                height: abs(dragCurrent.y - dragStart.y)
            ), color: .systemYellow)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard image != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard imageDrawRect().contains(point) else { return }
        dragStart = point
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        defer {
            dragStart = nil
            dragCurrent = nil
            needsDisplay = true
        }
        let rect = NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        guard rect.width >= 8, rect.height >= 8 else { return }
        guard let normalized = normalizedRect(fromViewRect: rect) else { return }
        rois.append(MosaicROI(rect: normalized, confidence: 1, source: "manual"))
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
            drawRect(rect, color: roi.source == "manual" ? .systemGreen : .systemRed)
        }
    }

    private func drawRect(_ rect: NSRect, color: NSColor) {
        color.withAlphaComponent(0.18).setFill()
        rect.fill()
        color.setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        path.lineWidth = 2
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
