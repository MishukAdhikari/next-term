import AppKit
import CoreServices
import NextTermCore
import UniformTypeIdentifiers

protocol ProjectSidebarDelegate: AnyObject {
    /// Type text into the active terminal.
    func sidebar(_ sidebar: ProjectSidebarView, insert text: String)
    /// Open a new tab in this folder.
    func sidebar(_ sidebar: ProjectSidebarView, openTabIn directory: String)
}

/// The "Project" panel: the active tab's project as a live file tree.
final class ProjectSidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    static let defaultWidth: CGFloat = 260

    weak var delegate: ProjectSidebarDelegate?
    /// Space reserved on the left of the header for the traffic-light buttons.
    var headerInset: CGFloat = 78 { didSet { needsLayout = true } }

    private(set) var root: FileNode?
    private let header = SidebarHeaderView()
    private let scrollView = NSScrollView()
    let outline = NSOutlineView()
    private var watcher: DirectoryWatcher?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.bar.cgColor

        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = Theme.bar
        outline.rowHeight = 24
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setDraggingSourceOperationMask(.copy, forLocal: true)
        outline.setAccessibilityLabel("Project files")
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false

        addSubview(header)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        header.inset = headerInset
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: TabBarView.height)
        scrollView.frame = NSRect(x: 0, y: TabBarView.height, width: bounds.width, height: max(0, bounds.height - TabBarView.height))
    }

    // MARK: root

    /// Shows `path`'s tree (a no-op if it is already the root).
    func setRoot(_ path: String) {
        let resolved = URL(fileURLWithPath: canonicalPath(path))
        guard resolved.path != root?.path else { return }
        let node = FileNode(url: resolved)
        node.loadChildren()
        root = node
        outline.reloadData()
        outline.expandItem(node)
        outline.scrollRowToVisible(0)
        watcher = DirectoryWatcher(path: resolved.path) { [weak self] paths in self?.filesChanged(paths) }
    }

    /// FSEvents reports changed folders; re-read the ones the tree has loaded.
    private func filesChanged(_ paths: [String]) {
        guard let root else { return }
        for raw in Set(paths) {
            let path = raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            guard let node = root.node(at: path), node.isLoaded, node.reload() else { continue }
            outline.reloadItem(node, reloadChildren: true)
        }
    }

    func reloadAll() {
        guard let root else { return }
        func reload(_ node: FileNode) {
            guard node.isLoaded else { return }
            node.reload()
            node.children?.forEach(reload)
        }
        reload(root)
        outline.reloadData()
    }

    // MARK: data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return root == nil ? 0 : 1 }
        if !node.isLoaded { node.loadChildren() }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return root! }
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileNode)?.url as NSURL?
    }

    // MARK: delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? FileCellView ?? FileCellView()
        cell.identifier = id
        cell.configure(node: node, isRoot: node === root)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { 24 }

    @objc private func doubleClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if node.isDirectory {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        } else {
            SafeOpen.open(node.url, from: window)
        }
    }

    // MARK: context menu

    private var menuNode: FileNode? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return outline.item(atRow: row) as? FileNode
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = menuNode else { return }
        let folder = node.isDirectory ? node.path : node.url.deletingLastPathComponent().path
        if !node.isDirectory { add(menu, "Open", #selector(openNode)) }
        add(menu, node.isDirectory ? "Open in New Tab" : "Open Folder in New Tab", #selector(openTab)).representedObject = folder
        add(menu, "Reveal in Finder", #selector(revealNode))
        menu.addItem(.separator())
        add(menu, "Insert Path in Terminal", #selector(insertPath))
        add(menu, "Copy Path", #selector(copyPath))
        add(menu, "Copy Relative Path", #selector(copyRelativePath))
        menu.addItem(.separator())
        add(menu, "Refresh", #selector(refresh))
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openNode() {
        if let node = menuNode { SafeOpen.open(node.url, from: window) }
    }
    @objc private func revealNode() {
        if let node = menuNode { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
    }
    @objc private func refresh() { reloadAll() }

    @objc private func openTab(_ sender: NSMenuItem) {
        if let folder = sender.representedObject as? String { delegate?.sidebar(self, openTabIn: folder) }
    }

    @objc private func insertPath() {
        if let node = menuNode { delegate?.sidebar(self, insert: ShellQuote.quote(node.path) + " ") }
    }

    @objc private func copyPath() {
        if let node = menuNode { copy(node.path) }
    }

    @objc private func copyRelativePath() {
        guard let node = menuNode, let root else { return }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        copy(node.path.hasPrefix(prefix) ? String(node.path.dropFirst(prefix.count)) : node.path)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - header

private final class SidebarHeaderView: NSView {
    private let label = NSTextField(labelWithString: "Project")
    var inset: CGFloat = 78 { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = Theme.text
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    // The whole header, label included, is a drag handle for the window.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: inset + 4, y: (bounds.height - size.height) / 2, width: ceil(size.width) + 4, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // The header is title bar too: drag moves the window.
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

// MARK: - row

private final class FileCellView: NSTableCellView {
    private static var iconCache: [String: NSImage] = [:]
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12.5)
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: 21, y: (bounds.height - h) / 2, width: max(0, bounds.width - 23), height: h)
    }

    func configure(node: FileNode, isRoot: Bool) {
        icon.image = Self.icon(for: node)
        if isRoot {
            let home = canonicalPath(FileManager.default.homeDirectoryForCurrentUser.path)
            let shown = node.path == home || node.path.hasPrefix(home + "/") ? "~" + node.path.dropFirst(home.count) : node.path
            let text = NSMutableAttributedString(string: node.name, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Theme.text,
            ])
            text.append(NSAttributedString(string: "  \(shown)", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.textDim,
            ]))
            label.attributedStringValue = text
        } else {
            label.stringValue = node.name
            label.textColor = node.name.hasPrefix(".") ? Theme.textDim : Theme.text
        }
        toolTip = node.path
    }

    /// Finder's icons, cached by type so big folders stay fast.
    private static func icon(for node: FileNode) -> NSImage {
        // A symlink gets its target's icon, so a link to a script does not pass for a document.
        let real = node.isSymlink ? node.url.resolvingSymlinksInPath() : node.url
        let key = node.isDirectory ? "/folder" : real.pathExtension.lowercased()
        if let cached = iconCache[key] { return cached }
        let type: UTType = node.isDirectory ? .folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        iconCache[key] = image
        return image
    }
}

// MARK: - FSEvents

/// Calls back on the main queue with the folders that changed under `path`.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void

    init(path: String, onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.onChange(changed)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
