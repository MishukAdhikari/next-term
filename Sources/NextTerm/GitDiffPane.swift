import AppKit
import NextTermCore

/// Git › Git Diff: a repository's changes in one editor tab. On the left, "All files" and the changed files
/// as a tree with their counts, and under them what to compare: All changes (everything this branch changed
/// since it parted from its base, committed or not), Uncommitted, or one of this branch's commits. On the
/// right, the selected file's diff (side by side or unified, with everything a diff tab has), or every
/// file's on one page. The base is named above the list and can be changed there. Only reads, and reads
/// again when the repository changes, keeping the file, the scroll position and what is open.
final class GitDiffPane: NSView, NSSplitViewDelegate {
    /// The work tree's top folder.
    let root: String
    var onTitleChange: (() -> Void)?

    private(set) var scope: ChangeScope = .all
    private(set) var context: ChangeContext?
    private(set) var changes: ChangeSet?
    /// The scope `changes` was read for (the list shows it until the scope chosen since is read).
    private var changesScope: ChangeScope?
    /// The file whose diff shows on the right; nil: All files.
    private(set) var selectedPath: String?
    /// The selected file's diff.
    private(set) var diffPane: DiffPane?
    /// Every file's diff, while All files is selected.
    private(set) var allFiles: AllFilesView?
    private(set) var isLoading = false
    private(set) var failure: String?
    /// The repository has changes not committed yet (the Uncommitted row shows while it does).
    private(set) var uncommitted: LineStats?
    /// The scope and its context the right side shows (so a pane is made again only when they change).
    private var shownKey: String?
    /// The base the next uncommitted diff opens on (⌥⌘G from Staged keeps Staged).
    private var openingBase: GitRunner.DiffBase = .head
    /// A file asked for by name (⌥⌘G) stays selected even when it isn't listed.
    private var askedFor: String?

    // The commits since the base, a page at a time.
    private var order: CommitOrder?
    private(set) var commits: [Commit] = []
    private var loadingCommits = false
    private var commitQuery: CommitQuery?
    private var refsSignature: String?
    nonisolated static let commitPage = 100

    private let monitor = GitMonitor()
    private var watchers: [DirectoryWatcher] = []
    /// Paths that changed since the last read, to tell whether a re-read can matter.
    private var touched = Set<String>()
    private var snapshotKey: String?
    private let newest = NewestRequest()
    private static let queue = DispatchQueue(label: "nextterm.git-diff", qos: .userInitiated)

    private let topBar = NSStackView()
    private let toggleButton = NSButton()
    private let baseButton = NSButton()
    private let status = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    private let split = NSSplitView()
    let list = GitDiffListView(frame: .zero)
    private let detail = NSView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var placedDivider = false

    init(root: String) {
        self.root = root
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        build()
        watch()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { monitor.stop() }

    static let tabIcon: NSImage? = NSImage(systemSymbolName: "plus.forwardslash.minus", accessibilityDescription: "Git Diff")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(.init(paletteColors: [Theme.gitModified])))

    var title: String { "Git Diff" }
    var tooltip: String {
        let what: String
        switch effectiveScope {
        case .all: what = "everything \(context?.branchName ?? "this branch") changed since \(context?.baseName ?? "its base")"
        case .uncommitted: what = "the changes not committed yet"
        case let .commit(sha): what = "commit \(sha.prefix(7))"
        }
        return "Changes in \(RecentProjects.abbreviate(root)): \(what)"
    }
    /// The keyboard goes to the diff when a file is shown, else to the list.
    var focusView: NSView { diffPane?.focusView ?? list.outline }
    var isShowingAllFiles: Bool { selectedPath == nil }
    var effectiveScope: ChangeScope { context?.effective(scope) ?? scope }

    // MARK: opening

    /// Shows `path`'s changes not committed yet, side by side (or unified), with the list beside it; the
    /// diff opens on `base`. The way ⌥⌘G opens a file.
    func show(path: String, base: GitRunner.DiffBase = .head) {
        askedFor = path
        openingBase = base
        let scopeChanges = scope != .uncommitted && context?.effective(scope) != .uncommitted
        if scopeChanges { scope = .uncommitted }
        // Open on that file already: back to the base asked for (All Changes, unless ⌥⌘G said otherwise).
        if let pane = diffPane, pane.path == path, shownKey == "uncommitted:" + path { pane.base = base }
        select(path: path)
        list.select(scope: listScope)
        if scopeChanges || !hasRead { reload(quietly: hasRead) }
    }

    /// All files, in the scope shown.
    func showOverview() {
        select(path: nil)
    }

    /// Whether anything was read yet (a new tab reads when it is first asked to show something).
    private var hasRead: Bool { changes != nil || isLoading || failure != nil }

    /// A file, or All files (nil), on the right; the list follows.
    func select(path: String?) {
        if path != selectedPath, path != askedFor { askedFor = nil }
        let wasAll = selectedPath == nil
        selectedPath = path
        list.select(path: path)
        placeDetail()
        if path == nil, !wasAll || allFiles?.entries.isEmpty != false || !hasRead { reload(quietly: hasRead) }
        onTitleChange?()
    }

    /// What to compare: All changes, Uncommitted, or a commit.
    func select(scope: ChangeScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        askedFor = nil
        reload()
    }

    /// The row selected in the scopes list: All changes stands for Uncommitted on the base itself.
    private var listScope: ChangeScope {
        if scope == .uncommitted, let context, context.effective(.all) == .uncommitted { return .all }
        return scope
    }

    // MARK: reading

    /// Reads the base, the scope's files, the page's diffs while All files shows, and the commits when a
    /// branch moved; what is shown stays meanwhile. `quietly`: without "Reading…".
    func reload(quietly: Bool = false) {
        guard let git = GitLogPane.git else {
            failure = "Git is not installed."
            return apply()
        }
        isLoading = true
        if !quietly { status.stringValue = "Reading…" }
        let token = newest.next()
        let root = self.root, scope = self.scope, chosen = Self.chosenBase(of: root), wantsDiffs = selectedPath == nil
        let known = refsSignature, knownQuery = commitQuery
        newest.async(on: Self.queue, for: token) { [weak self] in
            let context = Changes.context(in: root, git: git, chosen: chosen)
            let set = context.flatMap { Changes.files(scope, context: $0, in: root, git: git) }
            var diffs: [String: FileDiff]?
            if wantsDiffs, let context, let set { diffs = Changes.diffs(scope, context: context, set: set, in: root, git: git) }
            let signature = CommitLog.refsSignature(in: root, git: git)
            let query = context.flatMap(Self.commitQuery(for:))
            var order: CommitOrder?, page: [Commit]?
            if let query, signature != known || query != knownQuery {
                order = CommitLog.order(query, in: root, git: git)
                page = order.flatMap { CommitLog.commits(0..<min(Self.commitPage, $0.count), of: $0, in: root, git: git) }
            }
            DispatchQueue.main.async {
                guard let self, self.newest.isNewest(token) else { return }
                self.isLoading = false
                self.status.stringValue = ""
                self.failure = context == nil ? "Git could not read this repository." : (set == nil ? "Git could not list the changes here." : nil)
                if let context { self.context = context }
                if let set {
                    self.updateSelection(for: set, scopeChanged: self.changesScope != scope)
                    self.changes = set
                    self.changesScope = scope
                }
                self.refsSignature = signature
                if query == nil {
                    self.commitQuery = nil
                    self.order = nil
                    self.commits = []
                } else if let order, let page {
                    self.commitQuery = query
                    self.order = order
                    self.commits = page
                }
                self.apply(diffs: diffs)
            }
        }
    }

    /// The commits the list offers: this branch's since it parted from its base; on the base itself (or
    /// with none), the branch's history.
    nonisolated static func commitQuery(for context: ChangeContext) -> CommitQuery? {
        guard context.head != nil else { return nil }
        if let mergeBase = context.mergeBase, !context.isOnBase { return CommitQuery(scope: .ref(mergeBase + "..HEAD")) }
        return CommitQuery(scope: .ref("HEAD"))
    }

    /// The next page of commits, when the list nears its end.
    private func loadMoreCommits() {
        guard !loadingCommits, let order, commits.count < order.count, let git = GitLogPane.git else { return }
        loadingCommits = true
        let root = self.root, start = commits.count
        Self.queue.async { [weak self] in
            let page = CommitLog.commits(start..<min(start + Self.commitPage, order.count), of: order, in: root, git: git)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingCommits = false
                guard let page, self.order == order, self.commits.count == start else { return }
                self.commits += page
                self.showScopes()
            }
        }
    }

    /// A listed file that is no longer changed leaves the list: the selection moves to its neighbour (or
    /// All files when none is left). Another scope without the file shows All files. A file asked for by
    /// name (⌥⌘G) stays while it was never listed: its diff then says it has no changes.
    private func updateSelection(for set: ChangeSet, scopeChanged: Bool) {
        guard let path = selectedPath, set.file(at: path) == nil else { return }
        if scopeChanged {
            if path != askedFor { selectedPath = nil }
            return
        }
        let old = list.orderedFiles.map(\.path)
        guard old.contains(path) else { return }
        selectedPath = ChangeTree.neighbour(of: path, in: old, keeping: Set(set.files.map(\.path)))
    }

    /// Shows what was read: the list, the scopes, the header, and the right side.
    private func apply(diffs: [String: FileDiff]? = nil) {
        let tree = ChangeTree.build(changes?.files ?? [])
        list.show(tree: tree, totals: changes?.totals ?? LineStats(), root: root, selected: selectedPath, message: listMessage)
        showScopes()
        updateTopBar()
        placeDetail()
        if let page = allFiles, selectedPath == nil, let diffs {
            page.reader = reader()
            page.show(files: ChangeTree.files(in: tree), diffs: diffs, root: root, message: listMessage)
        }
        onTitleChange?()
    }

    private var listMessage: String? {
        if let failure { return failure }
        guard let changes else { return isLoading ? "Reading…" : nil }
        guard changes.files.isEmpty else { return nil }
        switch effectiveScope {
        case .all: return "No changes since \(context?.baseName ?? "the base")."
        case .uncommitted: return "No changes. Everything is committed."
        case .commit: return "This commit changes no files."
        }
    }

    private func showScopes() {
        var rows: [GitDiffListView.ScopeRow] = []
        let all = effectiveScope == .all ? changes?.totals : nil
        let onBase = context.map { $0.effective(.all) == .uncommitted } ?? false
        rows.append(.all(onBase ? uncommitted : all))
        // Uncommitted while there is any, and while it is the one shown.
        if !onBase, uncommitted != nil || scope == .uncommitted { rows.append(.uncommitted(uncommitted)) }
        rows += commits.map { .commit($0) }
        if context?.head == nil, context != nil { rows.append(.note("No commits yet")) }
        list.show(scopes: rows, selected: listScope, count: order?.count)
    }

    /// Reads one file's diff for the All files page, as the page was read (off the main thread).
    private func reader() -> ((ChangedFile, Int) -> FileDiff?)? {
        guard let git = GitLogPane.git, let context, let changes, let scope = changesScope else { return nil }
        let root = self.root
        return { file, lines in Changes.diff(of: file, scope: scope, context: context, set: changes, in: root, git: git, lines: lines) }
    }

    // MARK: the right side

    /// The selected file's diff in the scope, or All files: kept while they are the same, made again when
    /// the file, the scope or its base changed.
    private func placeDetail() {
        guard let path = selectedPath else {
            removeDiffPane()
            if allFiles == nil {
                let page = AllFilesView(frame: detail.bounds)
                page.onOpenFile = { [weak self] file in self?.openFile(file) }
                page.onSideBySide = { [weak self] file in
                    DiffLayout.current = .sideBySide
                    self?.select(path: file.path)
                }
                fill(page)
                allFiles = page
            }
            message.isHidden = true
            return
        }
        allFiles?.removeFromSuperview()
        allFiles = nil
        let key = paneKey(for: path)
        guard let key else {
            // The scope's base is not read yet: what shows stays until it is.
            return
        }
        guard key != shownKey || diffPane == nil else { return }
        // The same file's uncommitted diff again: on the base it was on (All Changes, Unstaged or Staged).
        let base = diffPane?.path == path && shownKey?.hasPrefix("uncommitted:") == true ? diffPane?.base : nil
        removeDiffPane()
        let pane = makeDiffPane(for: path, base: base ?? openingBase)
        pane.onTitleChange = { [weak self] in self?.onTitleChange?() }
        pane.onStepPastEnd = { [weak self] forward in self?.step(forward: forward) ?? false }
        fill(pane)
        diffPane = pane
        shownKey = key
    }

    /// What tells one file's diff from another's: the path, the scope and what it compares with. Nil while
    /// that is not known yet.
    private func paneKey(for path: String) -> String? {
        switch scope {
        case .uncommitted:
            return "uncommitted:" + path
        case .all:
            guard let context else { return nil }
            if context.effective(.all) == .uncommitted { return "uncommitted:" + path }
            let untracked = changes?.untracked.contains(path) == true
            return untracked ? "uncommitted:" + path : "all:\(context.mergeBase ?? ""):\(changes?.file(at: path)?.oldPath ?? ""):" + path
        case let .commit(sha):
            // Its parent comes with its files.
            guard changesScope == scope else { return nil }
            return "commit:\(sha):\(changes?.parent ?? ""):" + path
        }
    }

    private func makeDiffPane(for path: String, base: GitRunner.DiffBase) -> DiffPane {
        let file = changes?.file(at: path)
        switch shownScope(for: path) {
        case let .commit(sha):
            return DiffPane(root: root, path: path, commit: DiffPane.CommitChange(sha: sha, parent: changes?.parent, oldPath: file?.oldPath))
        case .all:
            if let mergeBase = context?.mergeBase {
                return DiffPane(root: root, path: path, workingTreeAgainst: mergeBase, renamedFrom: file?.oldPath, label: context?.baseName)
            }
            return DiffPane(root: root, path: path, base: base)
        case .uncommitted:
            return DiffPane(root: root, path: path, base: base)
        }
    }

    /// The scope a file's diff shows: All changes is Uncommitted on the base, and for a file git doesn't
    /// track yet (the same lines, and they can be staged there).
    private func shownScope(for path: String) -> ChangeScope {
        let scope = effectiveScope
        if scope == .all, changes?.untracked.contains(path) == true { return .uncommitted }
        return scope
    }

    private func removeDiffPane() {
        diffPane?.removeFromSuperview()
        diffPane = nil
        shownKey = nil
    }

    private func fill(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: detail.topAnchor),
            view.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
        ])
    }

    /// Next or previous change past the file's last or first: the next or previous file, at its first or
    /// last change. False at the list's ends (the diff then goes round the file).
    private func step(forward: Bool) -> Bool {
        let files = list.orderedFiles.map(\.path)
        guard let path = selectedPath, let at = files.firstIndex(of: path) else { return false }
        let next = at + (forward ? 1 : -1)
        guard files.indices.contains(next) else { return false }
        select(path: files[next])
        diffPane?.pendingHunk = forward ? 0 : -1
        if let pane = diffPane { window?.makeFirstResponder(pane.focusView) }
        return true
    }

    private func openFile(_ file: ChangedFile) {
        let url = URL(fileURLWithPath: root).appendingPathComponent(file.path)
        guard FileManager.default.fileExists(atPath: url.path), let controller = window?.windowController as? TerminalWindowController else { return NSSound.beep() }
        controller.openFile(url)
    }

    func applyFont() { allFiles?.applyFont() }

    // MARK: the header

    private func updateTopBar() {
        let strong: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Theme.text]
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.textDim]
        let text = NSMutableAttributedString()
        let branch = context?.branchName ?? (context?.head.map { "HEAD at \($0.prefix(7))" } ?? "HEAD")
        if let base = context?.baseName {
            text.append(NSAttributedString(string: base, attributes: dim))
            text.append(NSAttributedString(string: "  →  ", attributes: dim))
        }
        text.append(NSAttributedString(string: branch, attributes: strong))
        baseButton.attributedTitle = text
        let about = context?.baseName.map { "All changes count from where \(branch) parted from \($0). Click to compare with another branch." }
        baseButton.toolTip = about ?? "Click to choose the branch All changes counts from"
        baseButton.setAccessibilityLabel(context?.baseName.map { "Compared with \($0); choose another branch" } ?? "Choose the branch to compare with")
    }

    /// The branch All changes counts from: the default, or one chosen from the list.
    private func baseMenu() -> NSMenu {
        let menu = NSMenu()
        let chosen = Self.chosenBase(of: root)
        let header = NSMenuItem(title: "Count All Changes From", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let defaultName = context?.defaultBase.map(BranchCompare.displayName) ?? "none found"
        menu.addBlock("The Default (\(defaultName))", on: chosen == nil) { [weak self] in self?.choose(base: nil) }
        let bases = context?.bases ?? []
        for (title, prefix) in [("Local Branches", "refs/heads/"), ("Remote Branches", "refs/remotes/")] {
            let refs = bases.filter { $0.hasPrefix(prefix) && $0 != context?.branch }
            guard !refs.isEmpty else { continue }
            menu.addItem(.separator())
            let section = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            section.isEnabled = false
            menu.addItem(section)
            for ref in refs {
                menu.addBlock(BranchCompare.displayName(ref), on: chosen == ref) { [weak self] in self?.choose(base: ref) }
            }
        }
        return menu
    }

    @objc private func baseClicked() {
        baseMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: baseButton.isFlipped ? baseButton.bounds.maxY + 4 : -4), in: baseButton)
    }

    /// Counts All changes from `base` (nil: the default), remembered for this repository.
    func choose(base: String?) {
        var all = UserDefaults.standard.dictionary(forKey: Self.basesKey) as? [String: String] ?? [:]
        all[root] = base
        UserDefaults.standard.set(all, forKey: Self.basesKey)
        if scope != .all { scope = .all }
        reload()
    }

    private static let basesKey = "gitDiffBases"
    static func chosenBase(of root: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: basesKey) as? [String: String])?[root]
    }

    @objc private func refreshClicked() { reload() }

    // MARK: the column

    private static let widthKey = "gitDiffColumnWidth"
    private static let hiddenKey = "gitDiffColumnHidden"
    static var columnHidden: Bool {
        get { UserDefaults.standard.bool(forKey: hiddenKey) }
        set { UserDefaults.standard.set(newValue, forKey: hiddenKey) }
    }

    @objc func toggleColumn(_ sender: Any?) {
        Self.columnHidden.toggle()
        applyColumnHidden()
    }

    private func applyColumnHidden() {
        let hidden = Self.columnHidden
        list.isHidden = hidden
        split.adjustSubviews()
        if !hidden { placeDivider() }
        toggleButton.toolTip = hidden ? "Show the list of changed files" : "Hide the list of changed files"
        toggleButton.setAccessibilityLabel(hidden ? "Show File List" : "Hide File List")
        toggleButton.contentTintColor = hidden ? Theme.textDim : Theme.text
    }

    var isColumnHidden: Bool { list.isHidden }

    private func placeDivider() {
        let saved = UserDefaults.standard.double(forKey: Self.widthKey)
        let width = saved > 0 ? CGFloat(saved) : 300
        split.setPosition(min(max(180, width), max(180, split.bounds.width - 300)), ofDividerAt: 0)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard placedDivider, !list.isHidden, list.frame.width > 0 else { return }
        UserDefaults.standard.set(Double(list.frame.width), forKey: Self.widthKey)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 180 }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(640, splitView.bounds.width - 300)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    override func layout() {
        super.layout()
        if !placedDivider, split.bounds.width > 400 {
            placeDivider()
            placedDivider = true
        }
    }

    // MARK: watching

    /// A file or a branch changing (yours, an agent's, a commit, a stage) is read again once things settle;
    /// what can't matter (git's objects, files it ignores) is not.
    private func watch() {
        let objects = GitRunner.commonGitDir(root: root).map { canonicalPath($0) + "/objects" }
        let changed: ([String]) -> Void = { [weak self] paths in
            guard let self else { return }
            let relevant = paths.filter { path in objects.map { !canonicalPath(path).hasPrefix($0) } ?? true }
            guard !relevant.isEmpty else { return }
            self.touched.formUnion(relevant.map { canonicalPath($0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0) })
            self.monitor.refreshSoon()
        }
        var folders = [root]
        if let common = GitRunner.commonGitDir(root: root), !canonicalPath(common).hasPrefix(canonicalPath(root) + "/") { folders.append(common) }
        watchers = folders.map { DirectoryWatcher(path: $0, onChange: changed) }
        monitor.onChange = { [weak self] snapshot in self?.repositoryChanged(snapshot) }
        monitor.watch(root)
    }

    /// The repository's state was read again: whether there are uncommitted changes, and whether the
    /// scope may have changed (its files, a branch, a listed file's lines).
    private func repositoryChanged(_ snapshot: GitSnapshot?) {
        let lines = snapshot.map { s in s.files.values.contains { $0 != .ignored } || s.wholeFolders.values.contains { $0 != .ignored } } ?? false
        let shown = lines ? snapshot?.totals : nil
        let key = snapshot.map(Self.key(of:))
        // File events name folders: a listed file's folder changing may have changed its lines.
        let top = canonicalPath(root)
        let listed = (changes?.files ?? []).map { (top as NSString).appendingPathComponent($0.path) }
        let folders = Set(listed.map { ($0 as NSString).deletingLastPathComponent })
        let gitDir = GitRunner.commonGitDir(root: root).map(canonicalPath)
        let inGit = touched.contains { path in gitDir.map { path.hasPrefix($0) } ?? false || path.contains("/.git/") || path.hasSuffix("/.git") }
        let nearListed = !touched.isDisjoint(with: folders) || !touched.isDisjoint(with: Set(listed))
        let matters = key != snapshotKey || inGit || nearListed
        touched = []
        snapshotKey = key
        if shown != uncommitted {
            uncommitted = shown
            showScopes()
        }
        if matters { reload(quietly: true) }
    }

    /// What the snapshot says that the tab shows: the branch, HEAD, and each changed file with its lines.
    private static func key(of snapshot: GitSnapshot) -> String {
        let files = snapshot.files.filter { $0.value != .ignored }.map { path, change in
            let stats = snapshot.fileStats[path]
            return "\(path) \(change.rawValue) \(snapshot.codes[path] ?? "") \(stats?.added ?? -1) \(stats?.removed ?? -1)"
        }
        return ([snapshot.branch ?? "", snapshot.head ?? ""] + files.sorted()).joined(separator: "\n")
    }

    // MARK: layout

    private func build() {
        toggleButton.bezelStyle = .regularSquare
        toggleButton.isBordered = false
        toggleButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "File List")?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        toggleButton.target = self
        toggleButton.action = #selector(toggleColumn(_:))
        baseButton.bezelStyle = .regularSquare
        baseButton.isBordered = false
        baseButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        baseButton.imagePosition = .imageTrailing
        baseButton.contentTintColor = Theme.textDim
        baseButton.target = self
        baseButton.action = #selector(baseClicked)
        baseButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 11)
        status.textColor = Theme.textDim
        refreshButton.bezelStyle = .regularSquare
        refreshButton.isBordered = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        refreshButton.contentTintColor = Theme.textDim
        refreshButton.toolTip = "Read the changes again"
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        topBar.setViews([toggleButton, baseButton, NSView(), status, refreshButton], in: .leading)
        topBar.spacing = 8
        topBar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = Theme.bar.cgColor
        updateTopBar()

        list.onSelectFile = { [weak self] path in self?.select(path: path) }
        list.onSelectScope = { [weak self] scope in self?.select(scope: scope) }
        list.onNeedMoreCommits = { [weak self] in self?.loadMoreCommits() }
        list.onOpenFile = { [weak self] file in self?.openFile(file) }
        list.onReturn = { [weak self] in
            guard let self, let pane = self.diffPane else { return }
            self.window?.makeFirstResponder(pane.focusView)
        }
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(list)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setHoldingPriority(.init(200), forSubviewAt: 1)
        message.textColor = Theme.textDim
        message.alignment = .center
        message.isHidden = true
        for view in [topBar, split] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 34),
            split.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyColumnHidden()
        setAccessibilityLabel("Git Diff")
    }
}

extension TerminalWindowController {
    /// The repository Git › Git Diff shows: the sidebar's, or that of a Git Diff tab already open.
    var gitDiffRoot: String? { sidebar.git.snapshot?.root ?? editorArea.activeGitDiff?.root ?? editorArea.gitDiffs.first?.root }

    /// Git › Git Diff (and a click on the sidebar header's +N −M): the repository's changes in the Git Diff
    /// tab, all its files on one page.
    @objc func showGitDiff(_ sender: Any?) {
        guard let root = gitDiffRoot else { return NSSound.beep() }
        openGitDiff(root: root)
    }

    /// The Git Diff tab of the repository containing `root`, all its files on one page; nil outside one.
    @discardableResult
    func openGitDiff(root: String) -> GitDiffPane? {
        let top = canonicalPath(ProjectRoot.find(from: root))
        guard FileManager.default.fileExists(atPath: (top as NSString).appendingPathComponent(".git")) else {
            NSSound.beep()
            return nil
        }
        return editorArea.openGitDiff(root: top)
    }
}

/// The project sidebar header's +N −M: a click (or VoiceOver's press) shows the changes in the Git Diff tab.
final class HeaderCountsLabel: NSTextField {
    var onClick: (() -> Void)? {
        didSet {
            toolTip = onClick == nil ? nil : "Show Git Diff"
            window?.invalidateCursorRects(for: self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let onClick else { return super.mouseDown(with: event) }
        onClick()
    }

    override func resetCursorRects() {
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    // The header lays the counts out by hand: the hand cursor moves with them.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func isAccessibilityElement() -> Bool { !stringValue.isEmpty }
    override func accessibilityRole() -> NSAccessibility.Role? { onClick == nil ? .staticText : .button }
    override func accessibilityLabel() -> String? {
        let lines = stringValue.replacingOccurrences(of: "+", with: "plus ").replacingOccurrences(of: "−", with: "minus ")
        return onClick == nil ? lines : "Show Git Diff: \(lines) lines"
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }
}
