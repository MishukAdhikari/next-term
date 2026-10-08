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
    /// Open a file (double-click, ⌘↓, Open in the right-click menu).
    func sidebar(_ sidebar: ProjectSidebarView, openFile url: URL)
    /// Open a file in the preview tab, the keyboard staying in the tree (a single click, when clicks open files).
    func sidebar(_ sidebar: ProjectSidebarView, previewFile url: URL)
    /// A file or folder was renamed or moved (open editors follow it).
    func sidebar(_ sidebar: ProjectSidebarView, didMove from: String, to: String)
    /// Hand these files or folders to the agent in a tab.
    func sidebar(_ sidebar: ProjectSidebarView, sendToAgent urls: [(url: URL, isFolder: Bool)])
    /// Show a file's changes side by side.
    func sidebar(_ sidebar: ProjectSidebarView, showChanges url: URL)
    /// A Databases row's Open or hand-off.
    func sidebar(_ sidebar: ProjectSidebarView, database: DetectedDatabase, perform action: DatabaseAction)
    /// An Agent Sessions row's Resume (Go to Tab when it is open in one) or Fork, an agent's Continue
    /// Latest, or More… (the whole list).
    func sidebar(_ sidebar: ProjectSidebarView, session: AgentSession?, perform action: SessionAction)
}

/// What a Databases row can do beyond copying and revealing.
enum DatabaseAction { case open, tablePlus, terminal, vercel }

/// What the Agent Sessions rows can do.
enum SessionAction: Equatable { case resume, fork, continueLatest(AgentKind), showAll }

/// Outline view with the keys a file tree needs: Return renames (as in Finder), ⌘⌫ moves to the Trash,
/// ⌘↓ opens, and the right-click menu's other commands have theirs (by default: Settings can change them). It notes
/// how each click began, for "Open files with a single click".
final class SidebarOutlineView: NSOutlineView {
    var onRename: (() -> Void)?
    var onTrash: (() -> Void)?
    var onOpen: (() -> Void)?
    /// The right-click menu's other commands (Copy Path, New File…), by their ids in KeyBindings.partCommands.
    var onCommand: ((String) -> Void)?
    /// The row the last click went down on (a click released over another row dragged across rows).
    private(set) var mouseDownRow = -1
    /// A rename was going on when the last click went down: that click only ends it.
    private(set) var mouseDownWhileRenaming = false
    /// The event that ended the last rename. The window can end one, taking the keyboard back, before
    /// the click that did it reaches the outline.
    var renameEndedBy: NSEvent?
    /// A file drag began from the last click.
    var dragBegan = false
    /// For the self-test: runs while a click is down, before AppKit tracks it (a drag beginning mid-click).
    var whilePressed: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        mouseDownRow = row(at: convert(event.locationInWindow, from: nil))
        let responder = window?.firstResponder as? NSView
        let renaming = responder is NSTextView && responder?.isDescendant(of: self) == true
        let endedRename = renameEndedBy.map { $0.type == .leftMouseDown && $0.timestamp == event.timestamp } ?? false
        mouseDownWhileRenaming = renaming || endedRename
        renameEndedBy = nil
        dragBegan = false
        whilePressed?()
        super.mouseDown(with: event) // sends the action on mouse-up, and the double action on a double-click
    }

    override func keyDown(with event: NSEvent) {
        if perform(event) { return }
        super.keyDown(with: event)
    }

    /// A key with ⌘ comes here before the menus, so a terminal command on the same key gives way while the tree has
    /// the keyboard (KeyBindings.canShareKey).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, perform(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Rename, Move to Trash and Open on their keys: ↩ (or Enter), ⌘⌫ and ⌘↓, or what Settings › Keyboard Shortcuts says;
    /// the menu's other commands on theirs (⌥⌘C Copy Path, ⌥⌘N New File…).
    private func perform(_ event: NSEvent) -> Bool {
        guard let id = KeyboardShortcuts.shared.partCommand(for: event, in: .sidebar) else { return false }
        switch id {
        case "sidebar.rename": onRename?()
        case "sidebar.trash": onTrash?()
        case "sidebar.open": onOpen?()
        default: onCommand?(id)
        }
        return true
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
    /// "Files on this Mac", while the active tab runs on a server.
    let remoteNote = RemoteFilesNote()
    private let scrollView = NSScrollView()
    let outline = SidebarOutlineView()
    private var watcher: DirectoryWatcher?
    /// Watches the repository's .git when the tree shows a folder inside it (commits, checkouts).
    private var gitDirWatcher: DirectoryWatcher?
    let git = GitMonitor()
    /// HEAD moved (a commit, a checkout): open files compare against the new commit.
    var onHeadChange: (() -> Void)?
    private var lastHead: String?
    private var hiddenRows: [ObjectIdentifier: HiddenEntries] = [:]
    private var loading: Set<ObjectIdentifier> = []
    /// What else waits for a folder being read: it runs once the folder is in.
    private var waitingForLoad: [ObjectIdentifier: [() -> Void]] = [:]
    /// Each folder's rows (its entries on disk, the deleted ones in their place, "… N more"), built once
    /// per change. The folder is kept with them, so its identifier cannot be reused while cached.
    private var rowCache: [ObjectIdentifier: (owner: AnyObject, rows: [AnyObject])] = [:]
    /// Deleted entries by path from the work tree's root: the same object each time, so the outline keeps
    /// a deleted folder open across refreshes.
    private var deletedCache: [String: DeletedEntry] = [:]
    private var lastDeleted: Set<String> = []

    /// "Databases" at the top of the tree: what the project's own files name (see Databases.scan).
    let databasesGroup = DatabasesGroup()
    private(set) var databaseScan = DatabaseScan()
    private var databaseItems: [String: DatabaseItem] = [:]
    /// Bumped by every scan, so one that finishes after a newer one started is dropped.
    private(set) var databaseScanToken = 0
    private var databaseScanQueued = false
    /// Projects whose Databases group you closed: it stays closed for them.
    private var collapsedDatabaseRoots: Set<String> = []
    private var expandDatabasesWithRoot = false

    /// "Agent Sessions" under it: the newest sessions any agent kept for this folder.
    let sessionsGroup = SessionsGroup()

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
        outline.action = #selector(clicked)
        outline.doubleAction = #selector(doubleClicked)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.copy], forLocal: false)
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.setAccessibilityLabel("Project files")
        outline.onRename = { [weak self] in self?.renameSelected() }
        outline.onTrash = { [weak self] in self?.trashSelected() }
        outline.onOpen = { [weak self] in self?.openSelected() }
        outline.onCommand = { [weak self] id in self?.perform(command: id) }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false

        addSubview(header)
        remoteNote.isHidden = true
        addSubview(remoteNote)
        addSubview(scrollView)
        // Row tooltips through one area over the visible rows. Tooltips set on the row views themselves
        // stay live for rows scrolled out of sight, so hovering the header showed some hidden row's path.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(gitActivityChanged), name: GitWriter.activityChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(fetchedInBackground(_:)), name: BackgroundFetcher.fetched, object: nil)
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
        let top = TabBarView.height + (remoteNote.isHidden ? 0 : RemoteFilesNote.height)
        remoteNote.frame = NSRect(x: 0, y: TabBarView.height, width: bounds.width, height: RemoteFilesNote.height)
        scrollView.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        updateToolTips()
    }

    /// The active tab's server, if it runs on one: the tree then says its files are this Mac's.
    func showRemote(_ mark: RemoteMark?) {
        if let mark { remoteNote.show(mark) }
        guard remoteNote.isHidden != (mark == nil) else { return }
        remoteNote.isHidden = mark == nil
        needsLayout = true
    }

    @objc private func updateToolTips() {
        outline.removeAllToolTips()
        outline.addToolTip(outline.visibleRect, owner: self, userData: nil)
    }

    /// The tooltip for the row under the pointer (NSViewToolTipOwner).
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let row = outline.row(at: point)
        guard row >= 0, outline.visibleRect.contains(point) else { return "" }
        if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? DatabaseCellView { return cell.tipText }
        if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionRowCellView { return cell.tipText }
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCellView else { return "" }
        return cell.tipText
    }

    // MARK: root

    /// Shows `path`'s tree (a no-op if it is already the root). Folders are read in the background.
    func setRoot(_ path: String) {
        let canonical = canonicalPath(path)
        guard canonical != root?.path else { return }
        // A name being edited is done, as a click elsewhere would end it, while its row is still there.
        if isRenaming { window?.makeFirstResponder(outline) }
        runHeld()
        saveCurrentTree()
        rowCache.removeAll()
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
        showDatabases(DatabaseScan())
        scanDatabases()
        showSessions([], tabs: SessionTabs())
        loadSessions()
    }

    // MARK: databases

    /// Reads the project's files for databases, off the main thread.
    func scanDatabases() {
        guard let root else { return }
        let path = root.path
        databaseScanToken += 1
        let token = databaseScanToken
        DispatchQueue.global(qos: .utility).async {
            let scan = Databases.scan(root: path)
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.databaseScanToken, self.root?.path == path else { return }
                self.whenNotRenaming("databases") { [weak self] in
                    guard let self, self.root?.path == path else { return }
                    self.showDatabases(scan)
                }
            }
        }
    }

    /// Something changed near the top of the project (an env file, a config, a SQLite file): scan again
    /// soon. Changes in dependency and build folders are ignored.
    private func scheduleDatabaseScan(for paths: [String]) {
        guard let root, !databaseScanQueued else { return }
        let ignored = ["/node_modules/", "/vendor/", "/.git/", "/.next/", "/build/", "/dist/", "/.build/", "/storage/framework/"]
        let relevant = paths.contains { raw in
            let path = raw.hasSuffix("/") ? raw : raw + "/"
            guard path == root.path + "/" || path.hasPrefix(root.path + "/") else { return false }
            let rest = path.dropFirst(root.path.count)
            return !ignored.contains { rest.contains($0) } && rest.split(separator: "/").count <= 3
        }
        guard relevant else { return }
        databaseScanQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.databaseScanQueued = false
            self?.scanDatabases()
        }
    }

    private func showDatabases(_ scan: DatabaseScan) {
        guard scan != databaseScan else { return }
        let hadRows = !databasesGroup.items.isEmpty
        databaseScan = scan
        databasesGroup.vercelProject = scan.vercelProject
        databasesGroup.items = scan.databases.map { db in
            let item = databaseItems[db.id] ?? DatabaseItem(db)
            item.database = db
            return item
        }
        databaseItems = Dictionary(databasesGroup.items.map { ($0.database.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard let root else { return }
        rowCache[ObjectIdentifier(root)] = nil
        rowCache[ObjectIdentifier(databasesGroup)] = nil
        let hasRows = !databasesGroup.items.isEmpty
        if hadRows != hasRows {
            outline.reloadItem(root, reloadChildren: true)
        } else if hasRows {
            outline.reloadItem(databasesGroup, reloadChildren: true)
        }
        if !hadRows, hasRows, !collapsedDatabaseRoots.contains(root.path) {
            // The scan can finish before the project's own folder is listed and opened: open it then.
            if outline.isItemExpanded(root) { outline.expandItem(databasesGroup) } else { expandDatabasesWithRoot = true }
        }
        updateToolTips()
    }

    // MARK: agent sessions

    /// Reads the folder's agent sessions, and the tabs any are open in, off the main thread.
    func loadSessions() {
        guard let root else { return }
        let path = root.path
        sessionsGroup.token += 1
        let token = sessionsGroup.token
        SessionStore.load(path) { [weak self] listing, tabs in
            guard let self, token == self.sessionsGroup.token, self.root?.path == path else { return }
            self.whenNotRenaming("sessions") { [weak self] in
                guard let self, token == self.sessionsGroup.token, self.root?.path == path else { return }
                self.showSessions(listing.sessions, tabs: tabs)
            }
        }
    }

    /// Reads them again soon: an agent started or stopped, or the window came to the front. While the
    /// sidebar is hidden, once it shows again instead.
    func scheduleSessionsReload() {
        guard root != nil else { return }
        if isHiddenOrHasHiddenAncestor {
            sessionsGroup.reloadWhenShown = true
            return
        }
        guard !sessionsGroup.reloadQueued else { return }
        sessionsGroup.reloadQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.sessionsGroup.reloadQueued = false
            if self.isHiddenOrHasHiddenAncestor {
                self.sessionsGroup.reloadWhenShown = true // hidden meanwhile
            } else {
                self.loadSessions()
            }
        }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        guard sessionsGroup.reloadWhenShown else { return }
        sessionsGroup.reloadWhenShown = false
        loadSessions()
    }

    func showSessions(_ sessions: [AgentSession], tabs: SessionTabs) {
        let group = sessionsGroup
        let hadRows = !group.items.isEmpty
        let before = group.children.map(ObjectIdentifier.init)
        let old = Dictionary(group.items.map { ($0.session.identity, $0) }, uniquingKeysWith: { a, _ in a })
        group.all = sessions
        group.tabs = tabs
        group.items = sessions.prefix(SessionsGroup.shown).map { session in
            let inTab = tabs.tab(of: session) != nil
            guard let item = old[session.identity] else { return SessionItem(session, inTab: inTab) }
            item.session = session
            item.inTab = inTab
            return item
        }
        guard let root else { return }
        rowCache[ObjectIdentifier(root)] = nil
        rowCache[ObjectIdentifier(group)] = nil
        let hasRows = !group.items.isEmpty
        if hadRows != hasRows {
            outline.reloadItem(root, reloadChildren: true)
        } else if hasRows {
            // The same rows in the same order: only their text changed, and the outline keeps its selection.
            if before == group.children.map(ObjectIdentifier.init) {
                outline.reloadItem(group, reloadChildren: false)
                for item in group.children { outline.reloadItem(item) }
            } else {
                outline.reloadItem(group, reloadChildren: true)
            }
        }
        if !hadRows, hasRows, !group.collapsedRoots.contains(root.path) {
            if outline.isItemExpanded(root) { outline.expandItem(group) } else { group.expandWithRoot = true }
        }
        updateToolTips()
    }

    /// The row of a session, for the self-test.
    func sessionRow(_ identity: String) -> Int? {
        guard let item = sessionsGroup.items.first(where: { $0.session.identity == identity }) else { return nil }
        let row = outline.row(forItem: item)
        return row >= 0 ? row : nil
    }

    /// The row of a database, for the self-test.
    func databaseRow(_ id: String) -> Int? {
        guard let item = databaseItems[id] else { return nil }
        let row = outline.row(forItem: item)
        return row >= 0 ? row : nil
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
        // Selecting another row would take the selection from a name being edited.
        whenNotRenaming("reveal") { [weak self] in
            guard let self, self.root === root else { return }
            self.revealStep(root, names[...])
        }
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

    /// Reads a folder off the main thread, then installs it and updates the outline. A second call while
    /// it is being read waits for the same read (a reveal right after the tree changed root).
    private func load(_ node: FileNode, then completion: (() -> Void)? = nil) {
        if node.isLoaded {
            completion?()
            return
        }
        let id = ObjectIdentifier(node)
        guard !loading.contains(id) else {
            if let completion { waitingForLoad[id, default: []].append(completion) }
            return
        }
        loading.insert(id)
        let url = node.url, hiding = fileHiding
        DispatchQueue.global(qos: .userInitiated).async {
            let listing = FileNode.readChildren(of: url, hiding: hiding)
            DispatchQueue.main.async { [weak self] in
                self?.whenNotRenaming("load \(id)") { [weak self] in
                    guard let self else { return }
                    self.loading.remove(id)
                    let waiting = self.waitingForLoad.removeValue(forKey: id) ?? []
                    node.install(listing)
                    self.syncHiddenRow(for: node)
                    self.rowCache[id] = nil
                    guard self.isShowing(node) else { return }
                    self.outline.reloadItem(node, reloadChildren: true)
                    completion?()
                    waiting.forEach { $0() }
                }
            }
        }
    }

    /// Re-reads one loaded folder in the background; updates the outline if it changed.
    private func refresh(_ node: FileNode) {
        guard node.isLoaded else { return }
        let url = node.url, hiding = fileHiding
        DispatchQueue.global(qos: .utility).async {
            let listing = FileNode.readChildren(of: url, hiding: hiding)
            DispatchQueue.main.async { [weak self] in
                // The newest listing of each folder waits for a name being edited, keeping its row there.
                self?.whenNotRenaming("refresh \(ObjectIdentifier(node))") { [weak self] in
                    guard let self, node.install(listing) else { return }
                    self.syncHiddenRow(for: node)
                    self.rowCache[ObjectIdentifier(node)] = nil
                    if self.isShowing(node) { self.outline.reloadItem(node, reloadChildren: true) }
                }
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
        scheduleDatabaseScan(for: paths)
    }

    func reloadAll() {
        guard let root else { return }
        refreshLoadedFolders(of: root)
        git.refresh()
        scanDatabases()
    }

    // MARK: git

    /// A fetch, pull or push started or ended somewhere: the header spins while one runs here.
    @objc private func gitActivityChanged() {
        guard let root = git.snapshot?.root else { return header.show(activity: nil) }
        header.show(activity: GitWriter.shared.activity(in: root), fetchingInBackground: GitWriter.shared.isFetchingInBackground(in: root))
    }

    /// A background fetch of this repository worked: read git again, so "Pull 3" shows by itself.
    @objc private func fetchedInBackground(_ notification: Notification) {
        guard let root = git.snapshot?.root, notification.object as? String == GitWriter.repository(of: root) else { return }
        git.refresh()
    }

    private func gitChanged(_ snapshot: GitSnapshot?) {
        header.show(snapshot)
        gitActivityChanged()
        if let head = snapshot?.head, head != lastHead {
            if lastHead != nil { onHeadChange?() }
            lastHead = head
        }
        // A folder inside a repository: its watcher cannot see .git, so watch that too.
        if let snapshot, let root, canonicalPath(snapshot.root) != root.path {
            let dotGit = canonicalPath(snapshot.root) + "/.git"
            if gitDirWatcher == nil, FileManager.default.fileExists(atPath: dotGit) {
                gitDirWatcher = DirectoryWatcher(path: dotGit) { [weak self] _ in self?.git.refreshSoon() }
            }
        } else {
            gitDirWatcher = nil
        }
        whenNotRenaming("git") { [weak self] in self?.showGitState(snapshot) }
    }

    /// The rows' colours and counts, and the deleted files in their folders.
    private func showGitState(_ snapshot: GitSnapshot?) {
        let deleted = snapshot?.deletedPaths ?? []
        if deleted != lastDeleted {
            reloadFolders(around: deleted.symmetricDifference(lastDeleted), gitRoot: snapshot.map { canonicalPath($0.root) })
            lastDeleted = deleted
            deletedCache = deletedCache.filter { path, _ in deleted.contains { $0 == path || $0.hasPrefix(path + "/") } }
        }
        let rows = IndexSet(integersIn: 0..<outline.numberOfRows)
        outline.reloadData(forRowIndexes: rows, columnIndexes: [0])
    }

    /// Files were deleted or came back: rebuild the rows of the nearest folder on screen above each.
    private func reloadFolders(around paths: Set<String>, gitRoot: String?) {
        rowCache.removeAll()
        guard let root else { return }
        var folders: [FileNode] = []
        for path in paths {
            var folder = (path as NSString).deletingLastPathComponent
            while true {
                let absolute = gitRoot.map { folder.isEmpty ? $0 : $0 + "/" + folder }
                if let absolute, let node = root.node(at: absolute), node.isLoaded {
                    if !folders.contains(where: { $0 === node }) { folders.append(node) }
                    break
                }
                if folder.isEmpty { break }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        // Outer folders first: reloading one reloads everything below it.
        for node in folders.sorted(by: { $0.path.count < $1.path.count }) where isShowing(node) {
            if folders.contains(where: { $0 !== node && node.path.hasPrefix($0.path + "/") }) { continue }
            outline.reloadItem(node, reloadChildren: true)
        }
    }

    /// A folder's rows: its entries on disk with the deleted ones in their place (folders first, in
    /// Finder order), then "… N more" if it is too big to list in full.
    private func rows(of item: AnyObject) -> [AnyObject] {
        let id = ObjectIdentifier(item)
        if let cached = rowCache[id], cached.owner === item { return cached.rows }
        var rows: [AnyObject] = []
        if let node = item as? FileNode {
            let children = node.children ?? []
            let gone = node.isLoaded ? deleted(in: node) : []
            if gone.isEmpty {
                rows = children
            } else {
                let all: [(name: String, folder: Bool, item: AnyObject)] = children.map { ($0.name, $0.isDirectory, $0) } + gone.map { ($0.name, $0.isDirectory, $0) }
                rows = all.sorted { a, b in
                    a.folder != b.folder ? a.folder : a.name.localizedStandardCompare(b.name) == .orderedAscending
                }.map(\.item)
            }
            if let hidden = hiddenRows[id] { rows.append(hidden) }
            if node === root, !sessionsGroup.items.isEmpty { rows.insert(sessionsGroup, at: 0) }
            if node === root, !databasesGroup.items.isEmpty { rows.insert(databasesGroup, at: 0) }
        } else if item === databasesGroup {
            rows = databasesGroup.items
        } else if item === sessionsGroup {
            rows = sessionsGroup.children
        } else if let entry = item as? DeletedEntry, entry.isDirectory, let snapshot = git.snapshot {
            rows = snapshot.deletedEntries(in: entry.relative, existing: []).map {
                deletedEntry(in: entry.relative, $0.name, isDirectory: $0.isDirectory, gitRoot: snapshot.root, realFolder: entry.realFolder)
            }
        }
        rowCache[id] = (item, rows)
        return rows
    }

    private func deleted(in node: FileNode) -> [DeletedEntry] {
        guard let snapshot = git.snapshot, !snapshot.files.isEmpty, let relative = node.relativePath(to: canonicalPath(snapshot.root)) else { return [] }
        let existing = Set((node.children ?? []).map(\.name))
        return snapshot.deletedEntries(in: relative, existing: existing).map {
            deletedEntry(in: relative, $0.name, isDirectory: $0.isDirectory, gitRoot: snapshot.root, realFolder: node)
        }
    }

    private func deletedEntry(in folder: String, _ name: String, isDirectory: Bool, gitRoot: String, realFolder: FileNode?) -> DeletedEntry {
        let relative = folder.isEmpty ? name : folder + "/" + name
        if let cached = deletedCache[relative], cached.isDirectory == isDirectory { return cached }
        let entry = DeletedEntry(url: URL(fileURLWithPath: canonicalPath(gitRoot)).appendingPathComponent(relative), relative: relative,
                                 isDirectory: isDirectory, realFolder: realFolder)
        deletedCache[relative] = entry
        return entry
    }

    private func gitState(for node: FileNode) -> (GitChange?, LineStats?) {
        guard let snapshot = git.snapshot, let relative = node.relativePath(to: canonicalPath(snapshot.root)) else { return (nil, nil) }
        return (snapshot.change(at: relative, isDirectory: node.isDirectory), snapshot.stats(at: relative, isDirectory: node.isDirectory))
    }

    // MARK: data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return root == nil ? 0 : 1 }
        return rows(of: item as AnyObject).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return root! }
        return rows(of: item as AnyObject)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is DatabasesGroup || item is SessionsGroup { return true }
        return (item as? FileNode)?.isDirectory ?? (item as? DeletedEntry)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        if item is DeletedEntry || item is DatabasesGroup || item is SessionsGroup { return true }
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
        guard let item = notification.userInfo?["NSObject"] else { return }
        if item is DatabasesGroup, let root {
            // Remember a group you closed, for this project (not one that closed with its parent).
            if notification.name == NSOutlineView.itemDidCollapseNotification, outline.isItemExpanded(root) { collapsedDatabaseRoots.insert(root.path) }
            if notification.name == NSOutlineView.itemDidExpandNotification { collapsedDatabaseRoots.remove(root.path) }
            return
        }
        if item is SessionsGroup, let root {
            if notification.name == NSOutlineView.itemDidCollapseNotification, outline.isItemExpanded(root) { sessionsGroup.collapsedRoots.insert(root.path) }
            if notification.name == NSOutlineView.itemDidExpandNotification { sessionsGroup.collapsedRoots.remove(root.path) }
            return
        }
        if item as AnyObject === root, notification.name == NSOutlineView.itemDidExpandNotification, expandDatabasesWithRoot {
            expandDatabasesWithRoot = false
            if !databasesGroup.items.isEmpty { outline.expandItem(databasesGroup) }
        }
        if item as AnyObject === root, notification.name == NSOutlineView.itemDidExpandNotification, sessionsGroup.expandWithRoot {
            sessionsGroup.expandWithRoot = false
            if !sessionsGroup.items.isEmpty { outline.expandItem(sessionsGroup) }
        }
        let row = outline.row(forItem: item)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCellView else { return }
        if let node = item as? FileNode {
            cell.setIcon(FileIcons.image(for: node, expanded: outline.isItemExpanded(node)))
        } else if let entry = item as? DeletedEntry {
            cell.configureDeleted(entry, expanded: outline.isItemExpanded(entry), lines: git.snapshot?.stats(at: entry.relative, isDirectory: true))
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if item is DatabasesGroup || item is DatabaseItem {
            let id = NSUserInterfaceItemIdentifier("database")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? DatabaseCellView ?? DatabaseCellView()
            cell.identifier = id
            if let database = item as? DatabaseItem {
                cell.configure(database)
                cell.onMenu = { [weak self, weak database] in
                    guard let self, let database else { return NSMenu() }
                    return self.databaseMenu(for: database.database)
                }
            } else {
                cell.configureGroup(databasesGroup)
                cell.onMenu = nil
            }
            return cell
        }
        if item is SessionsGroup || item is SessionItem || item is MoreSessionsItem {
            return sessionCell(for: item)
        }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? FileCellView ?? FileCellView()
        cell.identifier = id
        if let hidden = item as? HiddenEntries {
            cell.configureHidden(hidden)
        } else if let entry = item as? DeletedEntry {
            cell.configureDeleted(entry, expanded: outlineView.isItemExpanded(entry),
                                  lines: git.snapshot?.stats(at: entry.relative, isDirectory: entry.isDirectory))
        } else if let node = item as? FileNode {
            let (change, lines) = gitState(for: node)
            cell.configure(node: node, isRoot: node === root, expanded: outlineView.isItemExpanded(node), change: change, lines: lines)
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { 24 }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is FileNode || item is DeletedEntry || item is DatabaseItem || item is SessionItem || item is MoreSessionsItem
    }

    /// A click, sent on mouse-up (the first click of a double-click too). With "Open files with a single
    /// click" on, a plain click on one file the editor can show cheaply opens it in the preview tab and
    /// leaves the keyboard in the tree. Every other click only selects, as it does with the setting off.
    @objc private func clicked() {
        // "More…" is a link: one click shows the whole list, whatever the setting.
        if outline.clickedRow >= 0, outline.item(atRow: outline.clickedRow) is MoreSessionsItem {
            return delegate?.sidebar(self, session: nil, perform: .showAll) ?? ()
        }
        guard AppDelegate.shared.sidebarSingleClickOpens, let event = NSApp.currentEvent else { return }
        let row = outline.clickedRow
        let item = row >= 0 ? outline.item(atRow: row) : nil
        let isMouseUp = event.type == .leftMouseUp
        let flags = event.modifierFlags
        let click = SidebarClick.Click(isMouseUp: isMouseUp, clickCount: isMouseUp ? event.clickCount : 0,
                                       command: flags.contains(.command), shift: flags.contains(.shift),
                                       option: flags.contains(.option), control: flags.contains(.control),
                                       row: row, mouseDownRow: outline.mouseDownRow, selection: outline.selectedRowIndexes,
                                       dragBegan: outline.dragBegan, wasRenaming: outline.mouseDownWhileRenaming, kind: kind(of: item))
        guard SidebarClick.outcome(of: click) == .open, let node = item as? FileNode,
              SidebarClick.opensOnSingleClick(node.url.path) else { return }
        delegate?.sidebar(self, previewFile: node.url)
    }

    private func kind(of item: Any?) -> SidebarClick.Row {
        if let node = item as? FileNode { return node === root ? .root : node.isDirectory ? .folder : .file }
        if item is DeletedEntry { return .deleted }
        if item is DatabaseItem || item is DatabasesGroup { return .database }
        return .other
    }

    @objc private func doubleClicked() {
        if let entry = outline.item(atRow: outline.clickedRow) as? DeletedEntry { return openDeleted(entry) }
        if let item = outline.item(atRow: outline.clickedRow) as? DatabaseItem { return openDatabase(item.database) }
        if outline.item(atRow: outline.clickedRow) is DatabasesGroup {
            return outline.isItemExpanded(databasesGroup) ? outline.collapseItem(databasesGroup) : outline.expandItem(databasesGroup)
        }
        if let item = outline.item(atRow: outline.clickedRow) as? SessionItem {
            return delegate?.sidebar(self, session: item.session, perform: .resume) ?? ()
        }
        if outline.item(atRow: outline.clickedRow) is MoreSessionsItem { return } // its click showed the list
        if outline.item(atRow: outline.clickedRow) is SessionsGroup {
            return outline.isItemExpanded(sessionsGroup) ? outline.collapseItem(sessionsGroup) : outline.expandItem(sessionsGroup)
        }
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if node.isDirectory {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        } else {
            delegate?.sidebar(self, openFile: node.url)
        }
    }

    /// ⌘↓: every selected file, deleted file and database. The selection is read first: opening a file
    /// shows it in the tree, which selects its row alone.
    private func openSelected() {
        let items = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) }
        for case let node as FileNode in items where !node.isDirectory { delegate?.sidebar(self, openFile: node.url) }
        for case let entry as DeletedEntry in items where !entry.isDirectory { openDeleted(entry) }
        for case let item as DatabaseItem in items { openDatabase(item.database) }
        for case let item as SessionItem in items { delegate?.sidebar(self, session: item.session, perform: .resume) }
        if items.contains(where: { $0 is MoreSessionsItem }) { delegate?.sidebar(self, session: nil, perform: .showAll) }
    }

    /// A deleted file opens as what was removed; a deleted folder opens and closes.
    func openDeleted(_ entry: DeletedEntry) {
        if entry.isDirectory {
            outline.isItemExpanded(entry) ? outline.collapseItem(entry) : outline.expandItem(entry)
        } else {
            delegate?.sidebar(self, showChanges: entry.url)
        }
    }

    /// Selected deleted files and folders (Show Changes, Return).
    var selectedDeleted: [DeletedEntry] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? DeletedEntry }
    }

    // MARK: selection helpers

    private var selectedNodes: [FileNode] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }
    }

    /// The row in place of the right-clicked one while a menu is built for it (`fill`), and while a command's key runs
    /// (the selection's first).
    private var menuRow: Int?

    /// Right-click acts on the clicked row, or on the whole selection if the clicked row is part of it.
    private var menuNodes: [FileNode] {
        let clicked = menuRow ?? outline.clickedRow
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

    func menuNeedsUpdate(_ menu: NSMenu) { fill(menu, forRow: outline.clickedRow) }

    /// The menu shows its keys only while it is open: the menu bar's Send to Agent, Rename Tab and Show Changes take
    /// theirs again whenever the shortcuts change, and on macOS 26 an item doesn't take a key another item still holds.
    /// No item's action reads its key.
    func menuDidClose(_ menu: NSMenu) {
        guard menu === outline.menu else { return }
        for item in menu.items { KeyboardShortcuts.set(nil, on: item) }
    }

    /// The right-click menu of `row` (of the selection, when `row` is part of it), each item showing the key its command
    /// has in Settings › Keyboard Shortcuts (KeyboardShortcuts.show). Built as it opens, so a key changed there shows
    /// the next time.
    func fill(_ menu: NSMenu, forRow row: Int) {
        menuRow = row
        defer { menuRow = nil }
        menu.removeAllItems()
        let clicked = row >= 0 ? outline.item(atRow: row) : nil
        if let item = clicked as? DatabaseItem {
            let built = databaseMenu(for: item.database)
            for entry in built.items {
                built.removeItem(entry)
                menu.addItem(entry)
            }
            return
        }
        if clicked is DatabasesGroup {
            add(menu, "Refresh Databases", #selector(refreshDatabasesFromMenu), "sidebar.refresh")
            return
        }
        if let built = sessionsMenu(forRow: row) {
            for entry in built.items {
                built.removeItem(entry)
                menu.addItem(entry)
            }
            return
        }
        if let entry = clicked as? DeletedEntry {
            // Not on disk: nothing to open, rename or move; what it was is still in git.
            if !entry.isDirectory {
                add(menu, "Show What Was Deleted", #selector(showDeletedFromMenu), "showChanges:").representedObject = entry
            }
            add(menu, "Copy Path", #selector(copyDeletedPath(_:)), "sidebar.copyPath").representedObject = entry
            add(menu, "Copy Relative Path", #selector(copyDeletedPath(_:)), "sidebar.copyRelativePath").representedObject = entry
            return
        }
        let nodes = menuNodes
        guard let node = nodes.first else { return }
        let single = nodes.count == 1
        if single && !node.isDirectory { add(menu, "Open", #selector(openNode), "sidebar.open") }
        if single && !node.isDirectory, change(of: node) != nil { add(menu, "Show Changes", #selector(showChangesFromMenu), "showChanges:") }
        if single {
            let folder = node.isDirectory ? node.path : node.url.deletingLastPathComponent().path
            let title = node.isDirectory ? "Open in New Tab" : "Open Folder in New Tab"
            add(menu, title, #selector(openTab), "sidebar.openTab").representedObject = folder
            if node.isDirectory && node !== root {
                add(menu, "Open as Project", #selector(openAsProject), "sidebar.openProject").representedObject = node.path
            }
        }
        add(menu, "Reveal in Finder", #selector(revealNode), "sidebar.reveal")
        menu.addItem(.separator())
        add(menu, "New File", #selector(newFile), "sidebar.newFile")
        add(menu, "New Folder", #selector(newFolder), "sidebar.newFolder")
        if single && node !== root { add(menu, "Rename…", #selector(renameFromMenu), "sidebar.rename") }
        if !nodes.contains(where: { $0 === root }) { add(menu, "Move to Trash", #selector(trashFromMenu), "sidebar.trash") }
        menu.addItem(.separator())
        // The menu bar's Send to Agent, which sends the sidebar's selection while it has the keyboard.
        add(menu, nodes.count == 1 ? "Send to Agent" : "Send \(nodes.count) Items to Agent", #selector(sendToAgentFromMenu), "sendToAgent:")
        add(menu, "Insert Path in Terminal", #selector(insertPath), "sidebar.insertPath")
        add(menu, "Copy Path", #selector(copyPath), "sidebar.copyPath")
        add(menu, "Copy Relative Path", #selector(copyRelativePath), "sidebar.copyRelativePath")
        menu.addItem(.separator())
        add(menu, "Refresh", #selector(refreshFromMenu), "sidebar.refresh")
    }

    /// An item of the menu, as `command` (a sidebar command, or the menu bar's that acts on the sidebar's selection).
    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ command: String) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        KeyboardShortcuts.show(command, on: item)
        return item
    }

    /// A sidebar command's key, pressed while the tree has the keyboard: the item for it in the menu a right-click on
    /// the selection shows, so the key does what that item says, to the same rows. A Databases or Agent Sessions row
    /// offers its group's items too (Refresh, Continue Latest): the group's own row can't be selected. A command neither
    /// menu offers (Open as Project on a file) does nothing. Rename, Move to Trash and Open have handlers of their own.
    func perform(command id: String) {
        guard let first = outline.selectedRowIndexes.first else { return }
        var rows = [first]
        let selected = outline.item(atRow: first)
        if selected is DatabaseItem || selected is SessionItem, let group = outline.parent(forItem: selected) {
            rows.append(outline.row(forItem: group))
        }
        for row in rows {
            let menu = NSMenu()
            fill(menu, forRow: row)
            guard let item = menu.items.first(where: { $0.identifier?.rawValue == id }), let action = item.action else { continue }
            menuRow = row
            defer { menuRow = nil }
            NSApp.sendAction(action, to: item.target, from: item)
            return
        }
    }

    @objc private func showDeletedFromMenu(_ sender: NSMenuItem) {
        if let entry = sender.representedObject as? DeletedEntry { openDeleted(entry) }
    }

    @objc private func copyDeletedPath(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? DeletedEntry else { return }
        let relative = root.flatMap { root in entry.url.path.hasPrefix(root.path + "/") ? String(entry.url.path.dropFirst(root.path.count + 1)) : nil }
        copy(sender.title == "Copy Path" ? entry.url.path : relative ?? entry.url.path)
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
    @objc private func refreshDatabasesFromMenu() { scanDatabases() }

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
        // A name being edited is done first, as a click elsewhere would end it, while its row is still there.
        if isRenaming { window?.makeFirstResponder(outline) }
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
        // Show it, select it, and start renaming it. The folder's rows are built again from the listing just
        // read: those kept from before lack the new item, and without its row there is nothing to rename.
        parent.reload(hiding: fileHiding)
        syncHiddenRow(for: parent)
        rowCache[ObjectIdentifier(parent)] = nil
        outline.reloadItem(parent, reloadChildren: true)
        outline.expandItem(parent)
        // By name: a folder's URL read back from the disk ends in "/", the one it was made with does not.
        if let node = parent.children?.first(where: { $0.name == name }) { beginRename(node) }
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
        outline.renameEndedBy = NSApp.currentEvent
        cell.endRename()
        defer {
            renameCancelled = false
            outline.reloadItem(node)
            // What waited for the name: after this, not inside the field giving up the keyboard.
            DispatchQueue.main.async { [weak self] in self?.runHeld() }
        }
        guard !renameCancelled, newName != node.name else { return }
        let byKey = NSApp.currentEvent?.type == .keyDown // Return, not a click on another row
        rename(node.url, to: newName)
        // Named with Return, it stays selected, as in Finder: the folder's new listing makes it a new node,
        // which the outline would otherwise drop from the selection.
        if byKey, let parent = node.parent {
            DispatchQueue.main.async { [weak self, weak parent] in
                guard let self, let parent, !self.isRenaming else { return }
                parent.reload(hiding: self.fileHiding)
                self.syncHiddenRow(for: parent)
                self.rowCache[ObjectIdentifier(parent)] = nil
                self.outline.reloadItem(parent, reloadChildren: true)
                if let named = parent.children?.first(where: { $0.name == newName }) {
                    let row = self.outline.row(forItem: named)
                    if row >= 0 { self.outline.selectRowIndexes([row], byExtendingSelection: false) }
                }
            }
        }
    }

    // MARK: the rows hold still while a name is edited

    /// Whether a file or folder's name is being edited in the tree: its field has the keyboard.
    private var isRenaming: Bool {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField, let cell = field.superview as? FileCellView else { return false }
        return cell.isRenaming && cell.isDescendant(of: outline)
    }

    /// Updates of the rows that wait for a name being edited, the newest of each kind.
    private var held: [(key: String, work: () -> Void)] = []

    /// Runs `work` now, or once the name being edited is done (Return, Escape, a click elsewhere). Reloading
    /// the rows takes the field away, which ends the rename with what was typed so far (and with its row
    /// gone, AppKit throws), and they reload all the time: the new file's own git status, a folder's new
    /// listing, the Databases scan, the agent sessions. So the tree holds still while you type, as Finder's
    /// does, and catches up after.
    private func whenNotRenaming(_ key: String, _ work: @escaping () -> Void) {
        guard isRenaming else {
            runHeld() // left by a rename that ended without saying so
            return work()
        }
        held.removeAll { $0.key == key }
        held.append((key, work))
    }

    private func runHeld() {
        guard !held.isEmpty, !isRenaming else { return }
        let work = held
        held.removeAll()
        // Rows rebuilt lose their selection: the item just named (or kept as "untitled") stays selected.
        let selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as AnyObject? }
        work.forEach { $0.work() }
        let rows = IndexSet(selected.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        if outline.selectedRowIndexes.isEmpty, !rows.isEmpty { outline.selectRowIndexes(rows, byExtendingSelection: false) }
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

    /// The click that starts a drag opens nothing, even with single clicks opening files.
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                     forItems draggedItems: [Any]) {
        outline.dragBegan = true
    }

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func isCopy(_ info: NSDraggingInfo) -> Bool {
        // From another app: copy. Within the tree: move, or copy with Option held.
        (info.draggingSource as? NSOutlineView) !== outline || NSEvent.modifierFlags.contains(.option)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let target = item as? FileNode ?? (item as? DeletedEntry)?.realFolder ?? root, let root else { return [] }
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
        guard let folder = (item as? FileNode) ?? (item as? DeletedEntry)?.realFolder ?? root, folder.isDirectory else { return false }
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
