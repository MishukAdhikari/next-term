import AppKit
import CoreServices
import NextTermCore

protocol ProjectSidebarDelegate: AnyObject {
    /// Type text into the active terminal.
    func sidebar(_ sidebar: ProjectSidebarView, insert text: String)
    /// Open a new tab in this folder.
    func sidebar(_ sidebar: ProjectSidebarView, openTabIn directory: String)
    /// Open this folder as a project (window choice is up to the app).
    func sidebar(_ sidebar: ProjectSidebarView, openProject directory: String)
    /// Open a file (double-click, ⌘↓).
    func sidebar(_ sidebar: ProjectSidebarView, openFile url: URL)
    /// A file or folder was renamed or moved (open editors follow it).
    func sidebar(_ sidebar: ProjectSidebarView, didMove from: String, to: String)
    /// Hand these files or folders to the agent in a tab.
    func sidebar(_ sidebar: ProjectSidebarView, sendToAgent urls: [(url: URL, isFolder: Bool)])
    /// Show a file's changes side by side.
    func sidebar(_ sidebar: ProjectSidebarView, showChanges url: URL)
}

/// Outline view with the keys a file tree needs: Return renames (as in Finder), ⌘⌫ moves to the Trash,
/// ⌘↓ opens.
final class SidebarOutlineView: NSOutlineView {
    var onRename: (() -> Void)?
    var onTrash: (() -> Void)?
    var onOpen: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, flags) {
        case (36, []), (76, []): onRename?()          // Return, Enter
        case (51, [.command]): onTrash?()             // ⌘⌫
        case (125, [.command]): onOpen?()             // ⌘↓
        default: super.keyDown(with: event)
        }
    }
}

/// The "Project" panel: a live file tree with git status, file operations and drag and drop.
final class ProjectSidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    static let defaultWidth: CGFloat = 280

    weak var delegate: ProjectSidebarDelegate?
    /// Space reserved on the left of the header for the traffic-light buttons.
    var headerInset: CGFloat = 70 { didSet { needsLayout = true } }

    private(set) var root: FileNode?
    let header = SidebarHeaderView()
    private let scrollView = NSScrollView()
    let outline = SidebarOutlineView()
    private var watcher: DirectoryWatcher?
    /// Watches the repository's .git when the tree shows a folder inside it (commits, checkouts).
    private var gitDirWatcher: DirectoryWatcher?
    let git = GitMonitor()
    private var hiddenRows: [ObjectIdentifier: HiddenEntries] = [:]
    private var loading: Set<ObjectIdentifier> = []

    /// Trees of recently shown roots, so switching between tabs in different projects keeps
    /// what was expanded and where you had scrolled.
    private struct SavedTree {
        let node: FileNode
        let expanded: [String]
        let scroll: NSPoint
    }
    private var savedTrees: [String: SavedTree] = [:]
    private var savedOrder: [String] = []

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
        outline.allowsMultipleSelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.copy], forLocal: false)
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.setAccessibilityLabel("Project files")
        outline.onRename = { [weak self] in self?.renameSelected() }
        outline.onTrash = { [weak self] in self?.trashSelected() }
        outline.onOpen = { [weak self] in self?.openSelected() }
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
        // Row tooltips through one area over the visible rows. Tooltips set on the row views themselves
        // stay live for rows scrolled out of sight, so hovering the header showed some hidden row's path.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateToolTips), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)

        git.onChange = { [weak self] snapshot in self?.gitChanged(snapshot) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        header.inset = headerInset
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: TabBarView.height)
        scrollView.frame = NSRect(x: 0, y: TabBarView.height, width: bounds.width, height: max(0, bounds.height - TabBarView.height))
        updateToolTips()
    }

    @objc private func updateToolTips() {
        outline.removeAllToolTips()
        outline.addToolTip(outline.visibleRect, owner: self, userData: nil)
    }

    /// The tooltip for the row under the pointer (NSViewToolTipOwner).
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let row = outline.row(at: point)
        guard row >= 0, outline.visibleRect.contains(point),
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCellView else { return "" }
        return cell.tipText
    }

    // MARK: root

    /// Shows `path`'s tree (a no-op if it is already the root). Folders are read in the background.
    func setRoot(_ path: String) {
        let canonical = canonicalPath(path)
        guard canonical != root?.path else { return }
        saveCurrentTree()
        if let saved = savedTrees[canonical] {
            root = saved.node
            outline.reloadData()
            for path in saved.expanded {
                if let node = saved.node.node(at: path) { outline.expandItem(node) }
            }
            outline.scroll(saved.scroll)
            refreshLoadedFolders(of: saved.node) // catch up on what changed while it was hidden
        } else {
            let node = FileNode(url: URL(fileURLWithPath: canonical))
            root = node
            outline.reloadData()
            load(node) { [weak self] in
                self?.outline.expandItem(node)
                self?.outline.scrollRowToVisible(0)
            }
        }
        watcher = DirectoryWatcher(path: canonical) { [weak self] paths in self?.filesChanged(paths) }
        gitDirWatcher = nil
        git.watch(canonical)
    }

    private func saveCurrentTree() {
        guard let root else { return }
        var expanded: [String] = []
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, outline.isItemExpanded(node) { expanded.append(node.path) }
        }
        savedTrees[root.path] = SavedTree(node: root, expanded: expanded, scroll: scrollView.contentView.bounds.origin)
        savedOrder.removeAll { $0 == root.path }
        savedOrder.append(root.path)
        while savedOrder.count > 8 { savedTrees[savedOrder.removeFirst()] = nil }
    }

    /// Opens the folders down to a file (reading them as needed), selects it and scrolls it into view,
    /// leaving the keyboard where it is. Files outside the tree are left alone.
    func reveal(_ path: String) {
        let target = canonicalPath(path)
        guard let root, target.hasPrefix(root.path + "/") else { return }
        let names = target.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
        revealStep(root, names[...])
    }

    private func revealStep(_ node: FileNode, _ rest: ArraySlice<String>) {
        load(node) { [weak self] in
            guard let self, let name = rest.first, let child = node.children?.first(where: { $0.name == name }) else { return }
            if !self.outline.isItemExpanded(node) { self.outline.expandItem(node) }
            if rest.count == 1 {
                let row = self.outline.row(forItem: child)
                guard row >= 0 else { return }
                self.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                self.outline.scrollRowToVisible(row)
            } else if child.isDirectory {
                self.revealStep(child, rest.dropFirst())
            }
        }
    }

    /// Reads a folder off the main thread, then installs it and updates the outline.
    private func load(_ node: FileNode, then completion: (() -> Void)? = nil) {
        if node.isLoaded {
            completion?()
            return
        }
        let id = ObjectIdentifier(node)
        guard !loading.contains(id) else { return }
        loading.insert(id)
        let url = node.url
        DispatchQueue.global(qos: .userInitiated).async {
            let listing = FileNode.readChildren(of: url)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loading.remove(id)
                node.install(listing)
                self.syncHiddenRow(for: node)
                guard self.isShowing(node) else { return }
                self.outline.reloadItem(node, reloadChildren: true)
                completion?()
            }
        }
    }

    /// Re-reads one loaded folder in the background; updates the outline if it changed.
    private func refresh(_ node: FileNode) {
        guard node.isLoaded else { return }
        let url = node.url
        DispatchQueue.global(qos: .utility).async {
            let listing = FileNode.readChildren(of: url)
            DispatchQueue.main.async { [weak self] in
                guard let self, node.install(listing) else { return }
                self.syncHiddenRow(for: node)
                if self.isShowing(node) { self.outline.reloadItem(node, reloadChildren: true) }
            }
        }
    }

    private func refreshLoadedFolders(of node: FileNode) {
        refresh(node)
        node.children?.filter { $0.isDirectory && $0.isLoaded }.forEach(refreshLoadedFolders(of:))
    }

    /// Whether the node belongs to the tree on screen (the root may have changed while it loaded).
    private func isShowing(_ node: FileNode) -> Bool {
        var current: FileNode? = node
        while let c = current {
            if c === root { return true }
            current = c.parent
        }
        return false
    }

    private func syncHiddenRow(for node: FileNode) {
        hiddenRows[ObjectIdentifier(node)] = node.hiddenCount > 0 ? HiddenEntries(count: node.hiddenCount) : nil
    }

    /// FSEvents reports changed folders: re-read the ones the tree has loaded, and refresh git.
    private func filesChanged(_ paths: [String]) {
        guard let root else { return }
        for raw in Set(paths) {
            let path = raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            if let node = root.node(at: path), node.isLoaded { refresh(node) }
        }
        git.refreshSoon()
    }

    func reloadAll() {
        guard let root else { return }
        refreshLoadedFolders(of: root)
        git.refresh()
    }

    // MARK: git

    private func gitChanged(_ snapshot: GitSnapshot?) {
        header.show(snapshot)
        // A folder inside a repository: its watcher cannot see .git, so watch that too.
        if let snapshot, let root, canonicalPath(snapshot.root) != root.path {
            let dotGit = canonicalPath(snapshot.root) + "/.git"
            if gitDirWatcher == nil, FileManager.default.fileExists(atPath: dotGit) {
                gitDirWatcher = DirectoryWatcher(path: dotGit) { [weak self] _ in self?.git.refreshSoon() }
            }
        } else {
            gitDirWatcher = nil
        }
        let rows = IndexSet(integersIn: 0..<outline.numberOfRows)
        outline.reloadData(forRowIndexes: rows, columnIndexes: [0])
    }

    private func gitState(for node: FileNode) -> (GitChange?, LineStats?) {
        guard let snapshot = git.snapshot, let relative = node.relativePath(to: canonicalPath(snapshot.root)) else { return (nil, nil) }
        return (snapshot.change(at: relative, isDirectory: node.isDirectory), snapshot.stats(at: relative, isDirectory: node.isDirectory))
    }

    // MARK: data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return root == nil ? 0 : 1 }
        return (node.children?.count ?? 0) + (hiddenRows[ObjectIdentifier(node)] == nil ? 0 : 1)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return root! }
        let children = node.children ?? []
        if index < children.count { return children[index] }
        return hiddenRows[ObjectIdentifier(node)]!
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        if node.isLoaded { return true }
        load(node) { [weak self] in self?.outline.expandItem(node) }
        return false
    }

    // MARK: delegate

    // Folder icons open and close with the folder.
    func outlineViewItemDidExpand(_ notification: Notification) { refreshIcon(of: notification) }
    func outlineViewItemDidCollapse(_ notification: Notification) { refreshIcon(of: notification) }

    private func refreshIcon(of notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCellView else { return }
        cell.setIcon(FileIcons.image(for: node, expanded: outline.isItemExpanded(node)))
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? FileCellView ?? FileCellView()
        cell.identifier = id
        if let hidden = item as? HiddenEntries {
            cell.configureHidden(hidden)
        } else if let node = item as? FileNode {
            let (change, lines) = gitState(for: node)
            cell.configure(node: node, isRoot: node === root, expanded: outlineView.isItemExpanded(node), change: change, lines: lines)
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { 24 }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is FileNode }

    @objc private func doubleClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if node.isDirectory {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        } else {
            delegate?.sidebar(self, openFile: node.url)
        }
    }

    private func openSelected() {
        for node in selectedNodes where !node.isDirectory { delegate?.sidebar(self, openFile: node.url) }
    }

    // MARK: selection helpers

    private var selectedNodes: [FileNode] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }
    }

    /// Right-click acts on the clicked row, or on the whole selection if the clicked row is part of it.
    private var menuNodes: [FileNode] {
        let clicked = outline.clickedRow
        if clicked >= 0, !outline.selectedRowIndexes.contains(clicked) {
            return (outline.item(atRow: clicked) as? FileNode).map { [$0] } ?? []
        }
        return selectedNodes
    }

    /// The folder new items go into: the clicked/selected folder, or the folder of the selected file.
    private var targetFolder: FileNode? {
        guard let node = menuNodes.first ?? selectedNodes.first ?? root else { return nil }
        return node.isDirectory ? node : node.parent ?? root
    }

    // MARK: context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let nodes = menuNodes
        guard let node = nodes.first else { return }
        let single = nodes.count == 1
        if single && !node.isDirectory { add(menu, "Open", #selector(openNode)) }
        if single && !node.isDirectory, change(of: node) != nil { add(menu, "Show Changes", #selector(showChangesFromMenu)) }
        if single {
            let folder = node.isDirectory ? node.path : node.url.deletingLastPathComponent().path
            add(menu, node.isDirectory ? "Open in New Tab" : "Open Folder in New Tab", #selector(openTab)).representedObject = folder
            if node.isDirectory && node !== root {
                add(menu, "Open as Project", #selector(openAsProject)).representedObject = node.path
            }
        }
        add(menu, "Reveal in Finder", #selector(revealNode))
        menu.addItem(.separator())
        add(menu, "New File", #selector(newFile))
        add(menu, "New Folder", #selector(newFolder))
        if single && node !== root { add(menu, "Rename…", #selector(renameFromMenu)) }
        if !nodes.contains(where: { $0 === root }) { add(menu, "Move to Trash", #selector(trashFromMenu)) }
        menu.addItem(.separator())
        add(menu, nodes.count == 1 ? "Send to Agent" : "Send \(nodes.count) Items to Agent", #selector(sendToAgentFromMenu))
        add(menu, "Insert Path in Terminal", #selector(insertPath))
        add(menu, "Copy Path", #selector(copyPath))
        add(menu, "Copy Relative Path", #selector(copyRelativePath))
        menu.addItem(.separator())
        add(menu, "Refresh", #selector(refreshFromMenu))
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showChangesFromMenu() {
        if let node = menuNodes.first { delegate?.sidebar(self, showChanges: node.url) }
    }

    /// The git change of a file, if any (for the context menu).
    private func change(of node: FileNode) -> GitChange? {
        guard let snapshot = git.snapshot else { return nil }
        let root = canonicalPath(snapshot.root), path = canonicalPath(node.url.path)
        guard path.hasPrefix(root + "/") else { return nil }
        return snapshot.files[String(path.dropFirst(root.count + 1))]
    }

    @objc private func sendToAgentFromMenu() {
        delegate?.sidebar(self, sendToAgent: menuNodes.map { ($0.url, $0.isDirectory) })
    }

    /// The selected files and folders (⌥⌘K with the sidebar focused).
    var selection: [(url: URL, isFolder: Bool)] { selectedNodes.map { ($0.url, $0.isDirectory) } }

    @objc private func openNode() {
        if let node = menuNodes.first { delegate?.sidebar(self, openFile: node.url) }
    }

    @objc private func revealNode() {
        NSWorkspace.shared.activateFileViewerSelecting(menuNodes.map(\.url))
    }

    @objc private func refreshFromMenu() { reloadAll() }

    @objc private func openTab(_ sender: NSMenuItem) {
        if let folder = sender.representedObject as? String { delegate?.sidebar(self, openTabIn: folder) }
    }

    @objc private func openAsProject(_ sender: NSMenuItem) {
        if let folder = sender.representedObject as? String { delegate?.sidebar(self, openProject: folder) }
    }

    @objc private func insertPath() {
        let text = menuNodes.map { ShellQuote.quote($0.path) }.joined(separator: " ")
        if !text.isEmpty { delegate?.sidebar(self, insert: text + " ") }
    }

    @objc private func copyPath() { copy(menuNodes.map(\.path).joined(separator: "\n")) }

    @objc private func copyRelativePath() {
        guard let root else { return }
        copy(menuNodes.map { $0.relativePath(to: root.path) ?? $0.path }.joined(separator: "\n"))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: new, rename, trash (all undoable with ⌘Z)

    @objc private func newFile() { create(folder: false) }
    @objc private func newFolder() { create(folder: true) }

    private func create(folder isFolder: Bool) {
        guard let parent = targetFolder else { return }
        let name = FileOps.availableName(isFolder ? "untitled folder" : "untitled", in: parent.url)
        let url = parent.url.appendingPathComponent(name)
        do {
            if isFolder {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else if !FileManager.default.createFile(atPath: url.path, contents: Data()) {
                throw NSError(domain: "NextTerm", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create “\(name)”."])
            }
        } catch {
            return report(error)
        }
        registerUndo("New \(isFolder ? "Folder" : "File")") { [weak self] in self?.trash([url], confirm: false) }
        // Show it, select it, and start renaming it.
        parent.reload()
        syncHiddenRow(for: parent)
        outline.reloadItem(parent, reloadChildren: true)
        outline.expandItem(parent)
        if let node = parent.children?.first(where: { $0.url == url }) { beginRename(node) }
    }

    @objc private func renameFromMenu() {
        if let node = menuNodes.first { beginRename(node) }
    }

    private func renameSelected() {
        guard selectedNodes.count == 1, let node = selectedNodes.first, node !== root else { return }
        beginRename(node)
    }

    func beginRename(_ node: FileNode) {
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCellView)?.beginRename(delegate: self)
    }

    private var renameCancelled = false

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            renameCancelled = true
            window?.makeFirstResponder(outline)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let cell = field.superview as? FileCellView, cell.isRenaming, let node = cell.node else { return }
        let newName = cell.renameText
        cell.endRename()
        defer {
            renameCancelled = false
            outline.reloadItem(node)
        }
        guard !renameCancelled, newName != node.name else { return }
        rename(node.url, to: newName)
    }

    func rename(_ url: URL, to newName: String) {
        do {
            let renamed = try FileOps.rename(url, to: newName)
            registerUndo("Rename") { [weak self] in self?.rename(renamed, to: url.lastPathComponent) }
            refreshParent(of: url)
            delegate?.sidebar(self, didMove: canonicalPath(url.deletingLastPathComponent().path) + "/" + url.lastPathComponent,
                              to: canonicalPath(renamed.path))
        } catch {
            report(error)
        }
    }

    @objc private func trashFromMenu() { trash(menuNodes.filter { $0 !== root }.map(\.url), confirm: true) }

    private func trashSelected() { trash(selectedNodes.filter { $0 !== root }.map(\.url), confirm: true) }

    func trash(_ urls: [URL], confirm: Bool) {
        guard !urls.isEmpty else { return }
        if confirm {
            let alert = NSAlert()
            alert.messageText = urls.count == 1 ? "Move “\(urls[0].lastPathComponent)” to the Trash?" : "Move \(urls.count) items to the Trash?"
            alert.informativeText = "You can undo this with ⌘Z, or put it back from the Trash."
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var restored: [(from: URL, to: URL)] = []
        for url in urls {
            var result: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                if let inTrash = result as URL? { restored.append((inTrash, url)) }
            } catch {
                report(error)
            }
            refreshParent(of: url)
        }
        registerUndo("Move to Trash") { [weak self] in
            for item in restored {
                try? FileManager.default.moveItem(at: item.from, to: item.to)
                self?.refreshParent(of: item.to)
            }
        }
    }

    private func refreshParent(of url: URL) {
        if let parent = root?.node(at: canonicalPath(url.deletingLastPathComponent().path)) { refresh(parent) }
        git.refreshSoon()
    }

    private func registerUndo(_ name: String, _ action: @escaping () -> Void) {
        guard let undo = window?.undoManager else { return }
        undo.registerUndo(withTarget: self) { _ in action() }
        undo.setActionName(name)
    }

    private func report(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: drag and drop: move within the project, copy in from Finder

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode, node !== root else { return nil }
        return node.url as NSURL
    }

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func isCopy(_ info: NSDraggingInfo) -> Bool {
        // From another app: copy. Within the tree: move, or copy with Option held.
        (info.draggingSource as? NSOutlineView) !== outline || NSEvent.modifierFlags.contains(.option)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let target = item as? FileNode ?? root, let root else { return [] }
        // Dropping on or between files means their folder.
        let folder = target.isDirectory ? target : (target.parent ?? root)
        if folder !== target || index != NSOutlineViewDropOnItemIndex {
            outlineView.setDropItem(folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
        }
        let urls = droppedURLs(info)
        guard !urls.isEmpty else { return [] }
        if isCopy(info) { return .copy }
        return urls.allSatisfy { FileOps.canMove($0, into: folder.url) } ? .move : []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let folder = (item as? FileNode) ?? root, folder.isDirectory else { return false }
        return transfer(droppedURLs(info), into: folder.url, copy: isCopy(info))
    }

    /// Moves or copies items into a folder, undoably. Also used by the self-test.
    @discardableResult
    func transfer(_ urls: [URL], into folder: URL, copy: Bool) -> Bool {
        do {
            let done = try FileOps.transfer(urls, into: folder, copy: copy)
            guard !done.isEmpty else { return false }
            registerUndo(copy ? "Copy" : "Move") { [weak self] in
                if copy {
                    self?.trash(done.map(\.to), confirm: false)
                } else {
                    for item in done.reversed() {
                        try? FileManager.default.moveItem(at: item.to, to: item.from)
                        self?.refreshParent(of: item.from)
                        if let self { self.delegate?.sidebar(self, didMove: canonicalPath(item.to.path), to: canonicalPath(item.from.path)) }
                    }
                }
                done.forEach { self?.refreshParent(of: $0.to) }
            }
            for item in done {
                refreshParent(of: item.from)
                refreshParent(of: item.to)
                if !copy {
                    delegate?.sidebar(self, didMove: canonicalPath(item.from.deletingLastPathComponent().path) + "/" + item.from.lastPathComponent,
                                      to: canonicalPath(item.to.path))
                }
            }
            return true
        } catch {
            report(error)
            return false
        }
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
