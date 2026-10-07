import AppKit
import NextTermCore

/// The branch popup, from the branch name at the top of the project sidebar (or ⌥⌘B): one search over
/// branches and git actions. Actions first (Update Project, Commit, Push, New Branch, Checkout Tag or
/// Revision, Git Log), then Recent, Local in folders by prefix (agents' branches together), Worktrees
/// and Remote.
/// Return checks a branch out; → opens everything else that can be done with it.
final class BranchPopupController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSMenuDelegate {
    enum Action: CaseIterable {
        case update, commit, push, newBranch, checkoutRevision, gitLog, fetch, gitCommands
        case continueOperation, skipStep, abortOperation, resolveWithAgent

        var title: String {
            switch self {
            case .update: return "Update Project"
            case .commit: return "Commit…"
            case .push: return "Push…"
            case .newBranch: return "New Branch…"
            case .checkoutRevision: return "Checkout Tag or Revision…"
            case .gitLog: return "Git Log"
            case .fetch: return "Fetch"
            case .gitCommands: return "Git Commands"
            case .continueOperation: return "Continue"
            case .skipStep: return "Skip This Commit"
            case .abortOperation: return "Abort"
            case .resolveWithAgent: return "Ask Agent to Resolve"
            }
        }

        var symbol: String {
            switch self {
            case .update: return "arrow.down.to.line"
            case .commit: return "checkmark.circle"
            case .push: return "arrow.up.to.line"
            case .newBranch: return "plus"
            case .checkoutRevision: return "tag"
            case .gitLog: return "point.3.connected.trianglepath.dotted"
            case .fetch: return "arrow.triangle.2.circlepath"
            case .gitCommands: return "list.bullet.rectangle"
            case .continueOperation: return "play"
            case .skipStep: return "forward"
            case .abortOperation: return "xmark.circle"
            case .resolveWithAgent: return "sparkles"
            }
        }

        /// Other words people search with.
        var synonyms: String {
            switch self {
            case .update: return "pull sync update"
            case .commit: return "commit save"
            case .push: return "push publish upload"
            case .newBranch: return "branch create new"
            case .checkoutRevision: return "switch checkout tag revision commit detach"
            case .gitLog: return "log history graph commits"
            case .fetch: return "fetch refresh"
            case .gitCommands: return "commands ran log"
            default: return ""
            }
        }
    }

    enum Item {
        case header(String)
        case action(Action, hint: String, enabled: Bool)
        case folder(id: String, title: String, count: Int, depth: Int)
        case branch(BranchRef, label: String, depth: Int, positions: [Int])
        case worktree(Worktree)
        case create(String)
        case revision(String)
        case note(String)

        var isSelectable: Bool {
            switch self {
            case .header, .note: return false
            case let .action(_, _, enabled): return enabled
            default: return true
            }
        }
    }

    weak var window: TerminalWindowController?
    private let panel = GoToFilePanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
    private let field = NSTextField()
    private let table = NSTableView()
    private let footer = NSTextField(labelWithString: "")
    /// The rows' tooltips, through one area over the rows in view (set up in build()).
    private(set) var rowToolTips: RowToolTips?
    private(set) var model: BranchModel?
    private(set) var items: [Item] = []
    private var openFolders: Set<String> = []
    private var directory = ""
    private var snapshot: GitSnapshot?
    private static let readQueue = DispatchQueue(label: "nextterm.branches", qos: .userInitiated)
    static let rowHeight: CGFloat = 26
    static let width: CGFloat = 440

    override init() {
        super.init()
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(fetchedInBackground(_:)), name: BackgroundFetcher.fetched, object: nil)
    }

    /// A background fetch of this repository worked: the counts update in place.
    @objc private func fetchedInBackground(_ notification: Notification) {
        guard panel.isVisible, notification.object as? String == GitWriter.repository(of: directory) else { return }
        reload()
    }

    // MARK: showing

    /// Opens under the sidebar header of `controller`'s window, for the worktree the sidebar shows.
    func show(for controller: TerminalWindowController, directory: String, snapshot: GitSnapshot?, anchor: NSRect) {
        window = controller
        guard let parent = controller.window else { return }
        self.directory = directory
        self.snapshot = snapshot
        field.stringValue = ""
        if model.map({ canonicalPath($0.root) != canonicalPath(directory) }) ?? false { model = nil; openFolders = [] }
        let height = min(parent.frame.height * 0.7, 560)
        let origin = NSPoint(x: anchor.minX, y: anchor.minY - height - 2)
        panel.setFrame(NSRect(x: max(parent.frame.minX + 8, origin.x), y: max(parent.frame.minY + 8, origin.y), width: Self.width, height: height),
                       display: false)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        rebuild()
        reload()
        // It draws first; if the last fetch is over five minutes old, a background fetch brings the counts up to date.
        BackgroundFetcher.shared.popupOpened(directory: directory)
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// For the Git menu: the model for `directory`, read fresh, without opening the popup.
    func prepare(for controller: TerminalWindowController, directory: String, snapshot: GitSnapshot?, then body: @escaping () -> Void) {
        window = controller
        if canonicalPath(self.directory) != canonicalPath(directory) { model = nil; openFolders = [] }
        self.directory = directory
        self.snapshot = snapshot
        reload(then: body)
    }

    var isVisible: Bool { panel.isVisible }
    var panelWindow: NSWindow { panel }
    /// For the self-test: the list, to right-click a row.
    var tableView: NSTableView { table }

    /// For the self-test: the search text, and the rows as words.
    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue; rebuild() }
    }
    var rowTitles: [String] {
        items.map { item in
            switch item {
            case let .header(text): return "# " + text
            case let .action(action, _, _): return action.title
            case let .folder(_, title, count, _): return "▸ \(title) \(count)"
            case let .branch(ref, label, _, _): return (ref.isHead ? "✓ " : "") + (ref.isRemote ? "remote " : "") + label
            case let .worktree(w): return "worktree " + (w.path as NSString).lastPathComponent
            case let .create(name): return "new " + name
            case let .revision(rev): return "revision " + rev
            case let .note(text): return "note " + text
            }
        }
    }
    func toggleFolder(_ id: String) {
        if openFolders.contains(id) { openFolders.remove(id) } else { openFolders.insert(id) }
        rebuild()
    }

    /// Reads the branches again (after an operation, or as the popup opens: the cached model draws first).
    func reload(then done: (() -> Void)? = nil) {
        guard let git = GitWriter.git else { return }
        let directory = self.directory
        Self.readQueue.async { [weak self] in
            let fresh = BranchModel.read(at: directory, git: git)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.model == nil, let current = fresh?.current, let folder = BranchModel.folder(of: current) {
                    self.openFolders.insert(BranchModel.isAgentBranch(current, worktree: nil) ? "local:agents" : "local:" + folder)
                }
                self.model = fresh
                if self.panel.isVisible { self.rebuild() }
                done?()
            }
        }
    }

    // MARK: rows

    private func rebuild() {
        let previous = selectedItemKey
        items = field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? browseItems() : searchItems(field.stringValue)
        table.reloadData()
        let index = items.firstIndex { key(of: $0) == previous && previous != nil } ?? items.firstIndex { $0.isSelectable }
        if let index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
        rowToolTips?.update()
        updateFooter()
    }

    private var selectedItemKey: String? { items.indices.contains(table.selectedRow) ? key(of: items[table.selectedRow]) : nil }

    private func key(of item: Item) -> String? {
        switch item {
        case let .action(action, _, _): return "action:\(action)"
        case let .folder(id, _, _, _): return "folder:" + id
        case let .branch(ref, _, _, _): return (ref.isRemote ? "remote:" : "local:") + ref.name
        case let .worktree(w): return "worktree:" + w.path
        default: return nil
        }
    }

    private func actionItems() -> [Item] {
        guard let model else { return [.note("Reading branches…")] }
        var rows: [Item] = []
        if let progress = model.inProgress {
            rows.append(.header(progress.title))
            rows.append(.action(.continueOperation, hint: "", enabled: true))
            if case .rebase = progress { rows.append(.action(.skipStep, hint: "", enabled: true)) }
            rows.append(.action(.abortOperation, hint: "", enabled: true))
            rows.append(.action(.resolveWithAgent, hint: "", enabled: true))
        }
        let current = model.currentRef
        rows.append(.action(.update, hint: current?.behind ?? 0 > 0 ? "↓\(current!.behind)" : "", enabled: current?.upstream != nil))
        let totals = snapshot?.totals
        let changes = snapshot.map { $0.files.values.filter { $0 != .ignored }.count } ?? 0
        rows.append(.action(.commit, hint: changes > 0 ? "\(changes) file\(changes == 1 ? "" : "s") +\(totals?.added ?? 0) −\(totals?.removed ?? 0)" : "",
                            enabled: model.current != nil || true))
        let pushHint = current.map { $0.upstream == nil ? "Publish" : ($0.ahead > 0 ? "↑\($0.ahead)" : "") } ?? ""
        rows.append(.action(.push, hint: pushHint, enabled: current != nil))
        rows.append(.action(.newBranch, hint: model.current == nil ? "from here" : "", enabled: true))
        rows.append(.action(.checkoutRevision, hint: "", enabled: true))
        rows.append(.action(.gitLog, hint: "", enabled: true))
        return rows
    }

    private func browseItems() -> [Item] {
        var rows = actionItems()
        guard let model else { return rows }
        if model.current == nil, let sha = model.headSHA {
            rows.insert(.note("Detached at \(sha.prefix(7)): New Branch… keeps work made here"), at: 0)
        }
        let recent = model.recent.compactMap(model.local)
        if !recent.isEmpty {
            rows.append(.header("Recent"))
            rows += recent.map { .branch($0, label: $0.name, depth: 0, positions: []) }
        }
        rows.append(.header("Local"))
        if let current = model.currentRef { rows.append(.branch(current, label: current.name, depth: 0, positions: [])) }
        let others = model.locals.filter { !$0.isHead }
        let agents = others.filter { BranchModel.isAgentBranch($0.name, worktree: $0.worktree) }
        let mine = others.filter { !BranchModel.isAgentBranch($0.name, worktree: $0.worktree) }
        let folders = Dictionary(grouping: mine.filter { BranchModel.folder(of: $0.name) != nil }) { BranchModel.folder(of: $0.name)! }
        for name in folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let id = "local:" + name
            let members = folders[name]!.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            rows.append(.folder(id: id, title: name + "/", count: members.count, depth: 0))
            if openFolders.contains(id) {
                rows += members.map { .branch($0, label: String($0.name.dropFirst(name.count + 1)), depth: 1, positions: []) }
            }
        }
        rows += mine.filter { BranchModel.folder(of: $0.name) == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { .branch($0, label: $0.name, depth: 0, positions: []) }
        if !agents.isEmpty {
            rows.append(.folder(id: "local:agents", title: "Agent branches", count: agents.count, depth: 0))
            if openFolders.contains("local:agents") {
                rows += agents.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    .map { .branch($0, label: $0.name, depth: 1, positions: []) }
            }
        }
        let worktrees = model.worktrees.filter { !$0.isBare && canonicalPath($0.path) != canonicalPath(model.root) }
        if !worktrees.isEmpty {
            rows.append(.header("Worktrees"))
            rows += worktrees.map { .worktree($0) }
        }
        if !model.remotes.isEmpty {
            rows.append(.header("Remote"))
            for remote in model.remoteNames {
                let id = "remote:" + remote
                let members = model.remotes.filter { $0.remote == remote }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                rows.append(.folder(id: id, title: remote, count: members.count, depth: 0))
                if openFolders.contains(id) { rows += members.map { .branch($0, label: $0.shortName, depth: 1, positions: []) } }
            }
        }
        return rows
    }

    private func searchItems(_ query: String) -> [Item] {
        guard let model else { return [.note("Reading branches…")] }
        var rows: [Item] = []
        // Actions: by title and the other words people use for them.
        let actions = actionItems().filter {
            guard case let .action(action, _, _) = $0 else { return false }
            return FuzzyIndex(paths: [action.title + " " + action.synonyms]).search(query)?.isEmpty == false
        }
        if !actions.isEmpty { rows.append(.header("Actions")); rows += actions }
        func matches(_ refs: [BranchRef]) -> [Item] {
            let index = FuzzyIndex(paths: refs.map(\.name))
            guard let found = index.search(query) else { return [] }
            return index.sorted(found, limit: 60).map { .branch(refs[$0.index], label: refs[$0.index].name, depth: 0, positions: index.positions(of: query, in: $0.index)) }
        }
        let locals = matches(model.locals)
        if !locals.isEmpty { rows.append(.header("Local")); rows += locals }
        let worktrees = model.worktrees.filter { w in
            !w.isBare && FuzzyIndex(paths: [w.path + " " + (w.branch ?? "")]).search(query)?.isEmpty == false && canonicalPath(w.path) != canonicalPath(model.root)
        }
        if !worktrees.isEmpty { rows.append(.header("Worktrees")); rows += worktrees.map { .worktree($0) } }
        let remotes = matches(model.remotes)
        if !remotes.isEmpty { rows.append(.header("Remote")); rows += remotes }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let name = BranchName.suggest(from: trimmed)
        if model.local(name) == nil, BranchName.problem(name, existing: Set(model.locals.map(\.name))) == nil {
            rows.append(.header("New"))
            rows.append(.create(name))
        }
        if !trimmed.contains(" ") { rows.append(.revision(trimmed)) }
        return rows
    }

    private func updateFooter() {
        guard let model else { footer.stringValue = ""; return }
        let ahead = model.currentRef.map { r in r.upstream.map { "tracking \($0)" } ?? "not published" } ?? "detached"
        footer.stringValue = "\(model.current ?? "HEAD") · \(ahead) · \(model.locals.count) local, \(model.remotes.count) remote"
    }

    // MARK: keys

    func controlTextDidChange(_ obj: Notification) { rebuild() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(by: 12)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(by: -12)
        case #selector(NSResponder.insertNewline(_:)): activate(row: table.selectedRow)
        case #selector(NSResponder.insertTab(_:)): showMenu(row: table.selectedRow)
        case #selector(NSResponder.moveRight(_:)):
            // In the search field → moves the caret; at its end it opens the row's menu.
            guard textView.selectedRange().location >= (textView.string as NSString).length else { return false }
            showMenu(row: table.selectedRow)
        case #selector(NSResponder.moveLeft(_:)):
            guard textView.string.isEmpty, case let .folder(id, _, _, _)? = items[safe: table.selectedRow], openFolders.contains(id) else { return false }
            openFolders.remove(id)
            rebuild()
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { close() } else { field.stringValue = ""; rebuild() }
        default: return false
        }
        return true
    }

    private func move(by delta: Int) {
        guard !items.isEmpty else { return }
        var row = table.selectedRow < 0 ? -1 : table.selectedRow
        let step = delta > 0 ? 1 : -1
        var remaining = abs(delta)
        var candidate = row
        while remaining > 0 {
            candidate += step
            guard items.indices.contains(candidate) else { break }
            if items[candidate].isSelectable { row = candidate; remaining -= 1 }
        }
        guard items.indices.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /// ⌘R fetch, ⌘C copy the name, ⌘⌫ delete, ⌘↩ new branch from the selected one.
    fileprivate func keyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
        let item = items[safe: table.selectedRow]
        switch event.charactersIgnoringModifiers {
        case "r": perform(.fetch)
        case "c":
            guard case let .branch(ref, _, _, _)? = item else { return false }
            copy(ref.name)
        case "\r":
            guard case let .branch(ref, _, _, _)? = item else { return false }
            close()
            GitActions(self).newBranch(from: ref)
        case "\u{7F}":
            guard case let .branch(ref, _, _, _)? = item, !ref.isRemote else { return false }
            close()
            GitActions(self).delete(ref)
        default: return false
        }
        return true
    }

    // MARK: doing

    @objc private func clicked() {
        let row = table.clickedRow
        guard items.indices.contains(row) else { return }
        // The › at a branch row's end opens its menu; anywhere else, the default action.
        if let event = NSApp.currentEvent, case .branch = items[row] {
            let point = table.convert(event.locationInWindow, from: nil)
            if point.x > table.bounds.width - 28 { return showMenu(row: row) }
        }
        activate(row: row)
    }

    func activate(row: Int) {
        guard let item = items[safe: row], item.isSelectable, let model else { return NSSound.beep() }
        switch item {
        case let .action(action, _, _): perform(action)
        case let .folder(id, _, _, _):
            if openFolders.contains(id) { openFolders.remove(id) } else { openFolders.insert(id) }
            rebuild()
        case let .branch(ref, _, _, _):
            if ref.isHead { return showMenu(row: row) }
            close()
            if !ref.isRemote, let elsewhere = model.otherWorktree(of: ref) { return GitActions(self).openWorktree(elsewhere) }
            GitActions(self).checkout(ref)
        case let .worktree(w):
            close()
            GitActions(self).openWorktree(w.path)
        case let .create(name):
            close()
            GitActions(self).createBranch(name, base: nil, switching: true)
        case let .revision(rev):
            close()
            GitActions(self).checkoutRevision(rev)
        default: break
        }
    }

    func perform(_ action: Action) {
        let actions = GitActions(self)
        close()
        switch action {
        case .update: actions.updateProject()
        case .commit: actions.commit()
        case .push: actions.push()
        case .newBranch: actions.askNewBranch(base: nil)
        case .checkoutRevision: actions.askRevision()
        case .fetch: actions.fetch()
        case .gitLog: window?.openGitLog(root: model?.root ?? directory)
        case .gitCommands: GitCommandsWindowController.shared.present()
        case .continueOperation: actions.inProgress(["--continue"])
        case .skipStep: actions.inProgress(["--skip"])
        case .abortOperation: actions.inProgress(["--abort"])
        case .resolveWithAgent: actions.askAgent("Resolve the git conflicts in this repository (`git status` lists them), keeping what both sides meant, then stage the resolved files. Don't commit or push.")
        }
    }

    /// Everything that can be done with a branch or a worktree, beside its row.
    func showMenu(row: Int) {
        guard items.indices.contains(row), model != nil else { return }
        guard let menu = menu(forRow: row) else { return activate(row: row) }
        let rect = table.rect(ofRow: row)
        menu.popUp(positioning: nil, at: NSPoint(x: rect.maxX - 24, y: rect.maxY), in: table)
    }

    /// The menu of a branch or worktree row (nil for other rows): each item closes the popup, then acts.
    func menu(forRow row: Int) -> NSMenu? {
        guard let item = items[safe: row], let model else { return nil }
        let menu = NSMenu()
        let actions = GitActions(self)
        func add(_ title: String, enabled: Bool = true, tip: String? = nil, _ run: @escaping () -> Void) {
            let entry = NSMenuItem(title: title, action: enabled ? #selector(MenuBlock.run(_:)) : nil, keyEquivalent: "")
            let block = MenuBlock { [weak self] in self?.close(); run() }
            entry.target = block
            entry.representedObject = block
            entry.toolTip = tip
            entry.isEnabled = enabled
            menu.addItem(entry)
        }
        let current = model.current
        // Compare needs a commit checked out; the working tree can be compared with a branch any time.
        let compareTitle = current.map { "Compare with “\($0)”" } ?? "Compare with HEAD"
        let noCommit = model.headSHA == nil ? "Nothing is committed here yet." : nil
        func comparing(_ ref: BranchRef) {
            add(compareTitle, enabled: noCommit == nil, tip: noCommit) { actions.compare(ref) }
            add("Show Diff with Working Tree") { actions.diffWithWorkingTree(ref) }
        }
        switch item {
        case let .branch(ref, _, _, _) where ref.isHead:
            add("New Branch from Here…") { actions.askNewBranch(base: nil) }
            add("Show History") { self.showHistory(of: ref) }
            add("Update", enabled: ref.upstream != nil) { actions.updateProject() }
            add("Push…") { actions.push() }
            menu.addItem(.separator())
            add("Rename…") { actions.rename(ref) }
            add("Copy Name") { self.copy(ref.name) }
        case let .branch(ref, _, _, _) where !ref.isRemote:
            let elsewhere = model.otherWorktree(of: ref)
            if let elsewhere {
                add("Open Worktree") { actions.openWorktree(elsewhere) }
            } else {
                add("Checkout") { actions.checkout(ref) }
            }
            add("New Branch from “\(ref.name)”…") { actions.newBranch(from: ref) }
            add("Show History") { self.showHistory(of: ref) }
            menu.addItem(.separator())
            comparing(ref)
            menu.addItem(.separator())
            if let current {
                add("Rebase “\(current)” onto “\(ref.name)”") { actions.rebase(onto: ref.name) }
                add("Merge “\(ref.name)” into “\(current)”") { actions.merge(ref.name) }
                menu.addItem(.separator())
            }
            add(ref.upstream == nil ? "Publish “\(ref.name)”…" : "Push “\(ref.name)”…") { actions.push(branch: ref) }
            menu.addItem(.separator())
            let held = elsewhere.map { "It is checked out in \(RecentProjects.abbreviate($0))." }
            add("Rename…", enabled: elsewhere == nil, tip: held) { actions.rename(ref) }
            add("Delete…", enabled: elsewhere == nil, tip: held) { actions.delete(ref) }
            add("Copy Name") { self.copy(ref.name) }
        case let .branch(ref, _, _, _):
            add("Checkout") { actions.checkout(ref) }
            add("New Branch from “\(ref.name)”…") { actions.newBranch(from: ref) }
            add("Show History") { self.showHistory(of: ref) }
            menu.addItem(.separator())
            comparing(ref)
            if let current {
                menu.addItem(.separator())
                add("Rebase “\(current)” onto “\(ref.name)”") { actions.rebase(onto: ref.name) }
                add("Merge “\(ref.name)” into “\(current)”") { actions.merge(ref.name) }
            }
            menu.addItem(.separator())
            add("Copy Name") { self.copy(ref.name) }
        case let .worktree(w):
            add("Open in New Tab") { actions.openWorktree(w.path) }
            add("Open as Project") { _ = AppDelegate.shared.openFolder(w.path, newWindow: true) }
            add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)]) }
            add("Copy Path") { self.copy(w.path) }
        default:
            return nil
        }
        return menu
    }

    /// The Git Log, showing one branch.
    private func showHistory(of ref: BranchRef) {
        guard let root = model?.root else { return }
        window?.openGitLog(root: root)?.show(ref: (ref.isRemote ? "refs/remotes/" : "refs/heads/") + ref.name)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        GitToast.show("Copied “\(text)”", in: window?.window)
    }

    // MARK: layout

    private func build() {
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.keyHandler = { [weak self] event in self?.keyEquivalent(event) ?? false }
        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = Theme.bar.cgColor
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = WorkSplitView.line.cgColor
        panel.contentView = background

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        glass.contentTintColor = Theme.textDim
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.textColor = Theme.text
        field.placeholderAttributedString = NSAttributedString(string: "Search branches and actions", attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor,
        ])
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel("Search branches and actions")
        let fetch = HoverButton()
        fetch.isBordered = false
        fetch.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Fetch")
        fetch.contentTintColor = Theme.textDim
        fetch.toolTip = "Fetch from all remotes (⌘R)"
        fetch.target = self
        fetch.action = #selector(fetchClicked)

        let rule = NSBox()
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = WorkSplitView.line

        let column = NSTableColumn(identifier: .init("branch"))
        table.addTableColumn(column)
        table.headerView = nil
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        table.setAccessibilityLabel("Branches and actions")
        let rightClick = NSMenu()
        rightClick.delegate = self
        table.menu = rightClick
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        rowToolTips = RowToolTips(table, in: scroll) { [weak self] row in
            (self?.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? BranchCell)?.tipText ?? ""
        }

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = Theme.textDim
        Typography.singleLine(footer, truncation: .byTruncatingTail)
        let hints = NSTextField(labelWithString: "↩ checkout  → more  esc close")
        hints.font = .systemFont(ofSize: 11)
        hints.textColor = Theme.textDim

        for view in [glass, field, fetch, rule, scroll, footer, hints] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            glass.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            glass.widthAnchor.constraint(equalToConstant: 14),
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 11),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: fetch.leadingAnchor, constant: -8),
            fetch.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            fetch.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            fetch.widthAnchor.constraint(equalToConstant: 24),
            rule.topAnchor.constraint(equalTo: background.topAnchor, constant: 42),
            rule.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: hints.leadingAnchor, constant: -10),
            hints.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            hints.firstBaselineAnchor.constraint(equalTo: footer.firstBaselineAnchor),
        ])
        column.width = Self.width
    }

    @objc private func fetchClicked() { perform(.fetch) }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = items[row] { return 24 }
        return Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items[row].isSelectable }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GoToFileRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: BranchCell.identifier, owner: self) as? BranchCell ?? BranchCell()
        cell.show(items[row], model: model)
        return cell
    }

    /// Right-click on a branch or worktree: the same menu as →.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let built = self.menu(forRow: table.clickedRow) else { return }
        for item in built.items {
            built.removeItem(item)
            menu.addItem(item)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible, NSApp.modalWindow == nil, panel.attachedSheet == nil { close() }
    }
}

/// A borderless panel that takes the keyboard and passes ⌘-keys to the popup.
private extension GoToFilePanel {
    private static var handlers: [ObjectIdentifier: (NSEvent) -> Bool] = [:]
    var keyHandler: ((NSEvent) -> Bool)? {
        get { Self.handlers[ObjectIdentifier(self)] }
        set { Self.handlers[ObjectIdentifier(self)] = newValue }
    }
}

extension GoToFilePanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let handler = Self.handlerFor(self), handler(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    fileprivate static func handlerFor(_ panel: GoToFilePanel) -> ((NSEvent) -> Bool)? { panel.keyHandler }
}

/// A menu item that runs a closure.
final class MenuBlock: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func run(_ sender: Any?) { block() }
}

/// One row: an icon, the name (typed letters in bold), and on the right the counts, where it is checked
/// out, and › for its menu.
final class BranchCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("BranchCell")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        Typography.singleLine(title, truncation: .byTruncatingMiddle)
        Typography.singleLine(detail, truncation: .byTruncatingHead)
        detail.alignment = .right
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        for view in [icon, title, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        leading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
        NSLayoutConstraint.activate([
            leading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -8),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var leading: NSLayoutConstraint!
    private var shown: (BranchPopupController.Item, BranchModel?)?
    /// The row's tooltip, shown by the popup for rows in view (see RowToolTips).
    private(set) var tipText = ""

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if let shown, backgroundStyle != oldValue { show(shown.0, model: shown.1) } }
    }

    private func symbol(_ name: String, _ color: NSColor = Theme.textDim) {
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        icon.contentTintColor = color
    }

    func show(_ item: BranchPopupController.Item, model: BranchModel?) {
        shown = (item, model)
        let chosen = backgroundStyle == .emphasized
        let font = NSFont.systemFont(ofSize: 13)
        title.font = font
        title.textColor = Theme.text
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = chosen ? Theme.text : Theme.textDim
        detail.stringValue = ""
        icon.isHidden = false
        leading.constant = 14
        tipText = ""
        switch item {
        case let .header(text):
            icon.isHidden = true
            leading.constant = 0
            title.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: Theme.textDim, .kern: 0.6,
            ])
        case let .note(text):
            symbol("info.circle")
            title.attributedStringValue = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.textDim])
        case let .action(action, hint, enabled):
            symbol(action.symbol, enabled ? Theme.accent : Theme.textDim)
            title.stringValue = action.title
            title.textColor = enabled ? Theme.text : Theme.textDim
            detail.stringValue = hint
        case let .folder(id, text, count, depth):
            let open = (superview?.superview as? NSTableView).flatMap { ($0.delegate as? BranchPopupController)?.isOpen(id) } ?? false
            symbol(open ? "chevron.down" : "chevron.right")
            leading.constant = 14 + CGFloat(depth) * 16
            title.attributedStringValue = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: Theme.text])
            detail.stringValue = "\(count)"
        case let .branch(ref, label, depth, positions):
            leading.constant = 14 + CGFloat(depth) * 16
            symbol(ref.isHead ? "checkmark" : (ref.isRemote ? "cloud" : "arrow.triangle.branch"), ref.isHead ? Theme.done : Theme.textDim)
            let text = NSMutableAttributedString(string: label, attributes: [.font: font, .foregroundColor: Theme.text])
            let offset = label.utf8.count - ref.name.utf8.count // positions are in the full name
            let bytes = Array(label.utf8)
            for p in positions {
                let i = p + offset
                guard i >= 0, i < bytes.count else { continue }
                let start = String(decoding: bytes[..<i], as: UTF8.self).utf16.count
                let length = String(decoding: bytes[i...i], as: UTF8.self).utf16.count
                text.addAttributes([.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: chosen ? NSColor.white : NSColor(hex: 0x6EA4F7)],
                                   range: NSRange(location: start, length: length))
            }
            title.attributedStringValue = text
            var parts: [String] = []
            if ref.upstreamGone { parts.append("gone") }
            if ref.behind > 0 { parts.append("↓\(ref.behind)") }
            if ref.ahead > 0 { parts.append("↑\(ref.ahead)") }
            if let model, !ref.isRemote, let elsewhere = model.otherWorktree(of: ref) { parts.append("⧉ " + (elsewhere as NSString).lastPathComponent) }
            detail.stringValue = (parts.joined(separator: "  ") + "  ›").trimmingCharacters(in: .whitespaces)
            var tip = ref.name
            if let upstream = ref.upstream {
                tip += ref.upstreamGone ? ", tracked \(upstream), which was deleted" : ", tracking \(upstream)"
                var sync: [String] = []
                if ref.ahead > 0 { sync.append("\(ref.ahead) ahead") }
                if ref.behind > 0 { sync.append("\(ref.behind) behind") }
                if !sync.isEmpty { tip += ": " + sync.joined(separator: ", ") }
            }
            if let worktree = ref.worktree { tip += ". Checked out in \(RecentProjects.abbreviate(worktree))" }
            tipText = tip + "."
        case let .worktree(w):
            symbol(w.lockReason != nil ? "lock" : "folder")
            title.stringValue = (w.path as NSString).lastPathComponent
            detail.stringValue = (w.branch ?? "detached @" + String((w.head ?? "").prefix(7))) + (w.isPrunable ? "  missing" : "")
            tipText = RecentProjects.abbreviate(w.path) + (w.lockReason.map { "\nLocked" + ($0.isEmpty ? "" : ": \($0)") } ?? "")
        case let .create(name):
            symbol("plus", Theme.accent)
            title.attributedStringValue = NSAttributedString(string: "New Branch “\(name)”", attributes: [.font: font, .foregroundColor: Theme.text])
        case let .revision(rev):
            symbol("tag")
            title.attributedStringValue = NSAttributedString(string: "Checkout “\(rev)” (tag or revision)", attributes: [.font: font, .foregroundColor: Theme.text])
        }
        setAccessibilityLabel([title.stringValue, detail.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

extension BranchPopupController {
    func isOpen(_ folder: String) -> Bool { openFolders.contains(folder) }
}
