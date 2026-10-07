import AppKit
import NextTermCore

/// The Git Log: a repository's commit history as a graph, in an editor tab. The commits newest first,
/// each after its children, in lanes with a dot each (a ring for a merge), then the subject behind its
/// branch and tag badges, the author and the date. A page of 1,000 commits loads at a time, the next as
/// you scroll. Above, a search by message or hash and filters by branch, author, date and paths. Only
/// reads: checking out or branching from a commit goes through GitActions, with their safety rules.
final class GitLogPane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// The work tree's top folder.
    let root: String
    var onTitleChange: (() -> Void)?
    /// A changed file was opened from the details: its path and the commit's change to it.
    var onOpenChange: ((String, DiffPane.CommitChange) -> Void)?

    private(set) var query = CommitQuery()
    private(set) var commits: [Commit] = []
    private(set) var rows: [GraphRow] = []
    private var graph = CommitGraph()
    private(set) var isLoading = false
    /// Every commit the query lists is loaded.
    private(set) var isComplete = false
    private(set) var failure: String?
    private var generation = 0
    /// HEAD's commit, ringed in the graph.
    private var headSHA: String?
    /// A commit to select once a page lists it: kept over a refresh, or asked for by `select(sha:)`.
    /// Pages load until it is found (up to `pagesLeft` more); then, with `orFilter`, the log shows it alone.
    private var wanted: (sha: String, pagesLeft: Int, orFilter: Bool)?
    private var lanesShown = 1
    /// Who commits here (`user.name`), for "Me" in the author filter.
    private var me: String?

    private static let queue = DispatchQueue(label: "nextterm.git-log", qos: .userInitiated)
    static let git = GitRunner.locateGit()

    private let header = NSStackView()
    let searchField = NSSearchField()
    private let regexButton = NSButton()
    private let branchButton = GitLogFilterButton()
    private let authorButton = GitLogFilterButton()
    private let dateButton = GitLogFilterButton()
    private let pathsButton = GitLogFilterButton()
    private let status = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    let table = GitLogTableView()
    private let scroll = NSScrollView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let graphColumn = NSTableColumn(identifier: .init("graph"))
    /// Left of the commits (the branch tree) and right of them (the commit's details).
    let split = NSSplitView()
    let centre = NSView()
    /// The selected commit in full.
    let details: GitLogDetailsView
    /// Branches and tags, to show one.
    let refs = GitLogRefsView(frame: .zero)
    private var placedDividers = false
    private var watcher: DirectoryWatcher?
    private var signature: String?
    private var pendingCheck: DispatchWorkItem?

    init(root: String) {
        self.root = root
        details = GitLogDetailsView(root: root)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        build()
        updateFilterTitles()
        reload(keepSelection: false)
        readRefs()
        let root = self.root
        Self.queue.async { [weak self] in
            let me = Self.git.flatMap { CommitLog.userName(in: root, git: $0) }
            DispatchQueue.main.async { self?.me = me }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static let tabIcon: NSImage? = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Git Log")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium).applying(.init(paletteColors: [Theme.gitModified])))

    var title: String { "Git Log" }
    var tooltip: String { "Commit history of \(RecentProjects.abbreviate(root))" }
    var selectedCommit: Commit? { commits[safe: table.selectedRow] }

    // MARK: loading

    /// Reads the log again from the first page, keeping the selected commit selected.
    func reload(keepSelection: Bool = true) {
        let keep = keepSelection ? selectedCommit?.sha ?? wanted?.sha : wanted?.sha
        generation += 1
        commits = []
        rows = []
        graph = CommitGraph(maxColumns: GitLogStyle.maxLanes, connected: query.isConnected)
        isLoading = false
        isComplete = false
        failure = nil
        lanesShown = 1
        graphColumn.width = GitLogStyle.graphWidth(lanes: 1)
        if let keep, wanted?.sha != keep { wanted = (keep, 2, false) }
        table.reloadData()
        updateStatus()
        loadMore()
    }

    /// The next page, unless one is loading or all are loaded.
    func loadMore() {
        guard !isLoading, !isComplete, failure == nil else { return }
        guard let git = Self.git else {
            failure = "Git is not installed."
            return updateStatus()
        }
        isLoading = true
        updateStatus()
        let token = generation, skip = commits.count, query = self.query, root = self.root
        Self.queue.async { [weak self] in
            let page = CommitLog.page(query, skip: skip, in: root, git: git)
            let head = skip == 0 ? CommitLog.resolve("HEAD", in: root, git: git) : nil
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.isLoading = false
                if skip == 0 { self.headSHA = head }
                guard let page else {
                    self.failure = "Git could not read the log here."
                    return self.updateStatus()
                }
                self.append(page)
            }
        }
    }

    private func append(_ page: [Commit]) {
        let start = commits.count
        commits += page
        let added = graph.add(page)
        rows += added
        isComplete = page.count < CommitLog.pageSize
        let widest = added.map(\.width).max() ?? 1
        if widest > lanesShown {
            lanesShown = widest
            graphColumn.width = GitLogStyle.graphWidth(lanes: widest)
        }
        if start == 0 {
            table.reloadData()
        } else {
            table.insertRows(at: IndexSet(integersIn: start..<commits.count), withAnimation: [])
        }
        updateStatus()
        findWanted()
    }

    private func findWanted() {
        guard let wanted else { return }
        if let index = commits.firstIndex(where: { $0.sha == wanted.sha }) {
            self.wanted = nil
            select(row: index)
        } else if !isComplete, wanted.pagesLeft > 0 {
            self.wanted?.pagesLeft -= 1
            loadMore()
        } else {
            self.wanted = nil
            guard wanted.orFilter else { return }
            // Not on the branches listed (or too far down): the log shows that commit alone.
            searchField.stringValue = wanted.sha
            query = CommitQuery(text: wanted.sha)
            self.wanted = (wanted.sha, 0, false)
            updateFilterTitles()
            reload(keepSelection: false)
        }
    }

    /// Selects a commit, loading pages until it is found; one that no branch lists is shown alone.
    func select(sha: String) {
        if let index = commits.firstIndex(where: { $0.sha == sha }) { return select(row: index) }
        wanted = (sha, 30, true)
        if query.isFiltered || query.scope != .all {
            // Filters could hide it: look in the whole history.
            query = CommitQuery()
            searchField.stringValue = ""
            regexButton.state = .off
            updateFilterTitles()
            return reload(keepSelection: false)
        }
        if isComplete || failure != nil { return findWanted() }
        if !isLoading { loadMore() } // else the page on its way looks for it
    }

    private func select(row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func updateStatus() {
        let count = commits.count.formatted()
        if let failure {
            status.stringValue = ""
            message.stringValue = failure
        } else if commits.isEmpty {
            status.stringValue = isLoading ? "Loading…" : ""
            message.stringValue = isLoading ? "" : (query.isFiltered || query.scope != .all ? "No commits match." : "No commits yet.")
        } else {
            status.stringValue = isComplete ? "\(count) commit\(commits.count == 1 ? "" : "s")" : "\(count)+ commits"
            message.stringValue = ""
        }
        message.isHidden = message.stringValue.isEmpty
    }

    // MARK: filters

    /// Changes the query and reads the log again.
    func apply(_ change: (inout CommitQuery) -> Void) {
        var next = query
        change(&next)
        guard next != query else { return }
        query = next
        if searchField.stringValue != query.text { searchField.stringValue = query.text }
        regexButton.state = query.regex ? .on : .off
        updateFilterTitles()
        reload()
    }

    /// Shows one branch, tag or revision; nil for all branches.
    func show(ref: String?) { apply { $0.scope = ref.map { .ref($0) } ?? .all } }

    @objc private func searchChanged() { apply { $0.text = searchField.stringValue } }
    @objc private func regexChanged() { apply { $0.regex = regexButton.state == .on } }
    @objc private func refreshClicked() {
        reload()
        readRefs()
    }

    // MARK: following the repository

    /// Reads the branches and tags for the tree, and starts watching the repository.
    private func readRefs() {
        guard let git = Self.git else { return }
        let root = self.root
        Self.queue.async { [weak self] in
            let model = BranchModel.read(at: root, git: git)
            let tags = CommitLog.tags(in: root, git: git)
            let signature = CommitLog.refsSignature(in: root, git: git)
            DispatchQueue.main.async {
                guard let self else { return }
                self.refs.update(model: model, tags: tags)
                if self.signature == nil { self.signature = signature }
                if self.watcher == nil, let common = model?.commonDir { self.watch(common) }
            }
        }
    }

    /// A commit, checkout, fetch or rebase (yours or an agent's, in any worktree) changes the folder git
    /// keeps refs in; when the refs did change, the log reads again, keeping the selection.
    private func watch(_ commonDir: String) {
        let objects = canonicalPath(commonDir) + "/objects"
        watcher = DirectoryWatcher(path: commonDir) { [weak self] paths in
            guard paths.contains(where: { !canonicalPath($0).hasPrefix(objects) }) else { return }
            self?.checkSoon()
        }
    }

    private func checkSoon() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkRefs() }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func checkRefs() {
        guard let git = Self.git else { return }
        let root = self.root
        Self.queue.async { [weak self] in
            let now = CommitLog.refsSignature(in: root, git: git)
            DispatchQueue.main.async {
                guard let self, let now, now != self.signature else { return }
                self.signature = now
                self.reload()
                self.readRefs()
            }
        }
    }

    static func scopeTitle(_ scope: CommitQuery.Scope) -> String {
        switch scope {
        case .all: return "All Branches"
        case let .ref(name):
            for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where name.hasPrefix(prefix) { return String(name.dropFirst(prefix.count)) }
            return name.count == 40 ? String(name.prefix(7)) : name
        }
    }

    private func updateFilterTitles() {
        branchButton.set(Self.scopeTitle(query.scope), active: query.scope != .all)
        if case let .ref(name) = query.scope { refs.select(ref: name) } else { refs.select(ref: nil) }
        authorButton.set(query.author.isEmpty ? "Author" : "Author: " + query.author, active: !query.author.isEmpty)
        let date: String
        switch (query.since, query.until) {
        case (nil, nil): date = "Date"
        case let (since?, nil): date = Self.datePresets.first { $0.since == since }?.title ?? "Since " + since
        case let (nil, until?): date = "Until " + until
        case let (since?, until?): date = since + " – " + until
        }
        dateButton.set(date, active: query.since != nil || query.until != nil)
        let paths = query.paths
        pathsButton.set(paths.isEmpty ? "Paths" : paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) Paths", active: !paths.isEmpty)
        pathsButton.toolTip = paths.isEmpty ? "Only commits that changed these files or folders" : paths.joined(separator: "\n")
    }

    static let datePresets: [(title: String, since: String)] = [
        ("Last 24 Hours", "24 hours ago"), ("Last 7 Days", "7 days ago"), ("Last 30 Days", "30 days ago"), ("Last 12 Months", "12 months ago"),
    ]

    private func branchMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addBlock("All Branches", on: query.scope == .all) { [weak self] in self?.show(ref: nil) }
        menu.addBlock("HEAD", on: query.scope == .ref("HEAD")) { [weak self] in self?.show(ref: "HEAD") }
        let refs = Set(commits.prefix(2000).flatMap(\.refs).filter { $0.kind == .branch || $0.kind == .remote || $0.kind == .tag })
        let byKind = Dictionary(grouping: refs, by: \.kind)
        for (kind, title) in [(CommitRef.Kind.branch, "Local"), (.remote, "Remote"), (.tag, "Tags")] {
            guard let list = byKind[kind], !list.isEmpty else { continue }
            menu.addItem(.separator())
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
            for ref in list.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }).prefix(40) {
                menu.addBlock(ref.name, on: query.scope == .ref(ref.fullName)) { [weak self] in self?.show(ref: ref.fullName) }
            }
        }
        return menu
    }

    private func authorMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addBlock("Any Author", on: query.author.isEmpty) { [weak self] in self?.apply { $0.author = "" } }
        if let me { menu.addBlock("Me (\(me))", on: query.author == me) { [weak self] in self?.apply { $0.author = me } } }
        // The people with the most commits among those loaded.
        let counts = Dictionary(commits.prefix(5000).map { ($0.authorName, 1) }, uniquingKeysWith: +)
        let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(12).map(\.key).filter { $0 != me && !$0.isEmpty }
        if !top.isEmpty { menu.addItem(.separator()) }
        for name in top { menu.addBlock(name, on: query.author == name) { [weak self] in self?.apply { $0.author = name } } }
        menu.addItem(.separator())
        menu.addBlock("Other…") { [weak self] in
            guard let self else { return }
            GitPrompt.text("Show Commits by", info: "Part of a name or an email address, in any case.", initial: self.query.author, placeholder: "ann@example.com",
                           button: "Show", over: self.window, check: { _ in nil }) { text in
                if let text { self.apply { $0.author = text } }
            }
        }
        return menu
    }

    private func dateMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addBlock("Any Time", on: query.since == nil && query.until == nil) { [weak self] in self?.apply { $0.since = nil; $0.until = nil } }
        menu.addItem(.separator())
        for preset in Self.datePresets {
            menu.addBlock(preset.title, on: query.since == preset.since && query.until == nil) { [weak self] in self?.apply { $0.since = preset.since; $0.until = nil } }
        }
        menu.addItem(.separator())
        for (title, isSince) in [("Since…", true), ("Until…", false)] {
            menu.addBlock(title) { [weak self] in
                guard let self else { return }
                GitPrompt.text(isSince ? "Commits Since" : "Commits Until", info: "A date such as 2025-01-31, or words git understands, such as “2 weeks ago” or “yesterday”.",
                               initial: (isSince ? self.query.since : self.query.until) ?? "", placeholder: "2025-01-31", button: "Show", over: self.window,
                               check: { _ in nil }) { text in
                    guard let text else { return }
                    self.apply { isSince ? ($0.since = text.isEmpty ? nil : text) : ($0.until = text.isEmpty ? nil : text) }
                }
            }
        }
        return menu
    }

    private func pathsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addBlock("Any Path", on: query.paths.isEmpty) { [weak self] in self?.apply { $0.paths = [] } }
        let selected = sidebarPaths()
        if !selected.isEmpty {
            menu.addBlock("Selected in the Sidebar (\(selected.count))", on: query.paths == selected) { [weak self] in self?.apply { $0.paths = selected } }
        }
        menu.addItem(.separator())
        menu.addBlock("Choose…") { [weak self] in self?.choosePaths() }
        menu.addBlock("Type…") { [weak self] in
            guard let self else { return }
            GitPrompt.text("Commits That Changed", info: "Files or folders from the top of the repository, separated by commas.",
                           initial: self.query.paths.joined(separator: ", "), placeholder: "src/app, README.md", button: "Show", over: self.window,
                           check: { _ in nil }) { text in
                guard let text else { return }
                self.apply { $0.paths = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            }
        }
        return menu
    }

    /// The files and folders selected in the sidebar, from the top of this repository.
    private func sidebarPaths() -> [String] {
        guard let controller = window?.windowController as? TerminalWindowController else { return [] }
        let top = canonicalPath(root)
        return controller.sidebar.selection.map { canonicalPath($0.url.path) }.filter { $0.hasPrefix(top + "/") }.map { String($0.dropFirst(top.count + 1)) }
    }

    private func choosePaths() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: root)
        panel.message = "Show the commits that changed these files or folders."
        panel.prompt = "Show"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            let top = canonicalPath(self.root)
            let paths = panel.urls.map { canonicalPath($0.path) }.compactMap { path -> String? in
                path == top ? nil : path.hasPrefix(top + "/") ? String(path.dropFirst(top.count + 1)) : nil
            }
            self.apply { $0.paths = paths }
        }
    }

    // MARK: keys

    /// ⌘F (Find…): to the search field.
    @objc func performFindPanelAction(_ sender: Any?) {
        guard ((sender as? NSMenuItem)?.tag ?? Int(NSFindPanelAction.showFindPanel.rawValue)) == Int(NSFindPanelAction.showFindPanel.rawValue) else { return NSSound.beep() }
        window?.makeFirstResponder(searchField)
    }

    var focusView: NSView { table }

    // MARK: layout

    private func build() {
        searchField.placeholderString = "Text or hash"
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityLabel("Search commits by message text or hash")
        searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        regexButton.title = ".*"
        regexButton.setButtonType(.pushOnPushOff)
        regexButton.bezelStyle = .rounded
        regexButton.controlSize = .small
        regexButton.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        regexButton.toolTip = "Search the message with a regular expression"
        regexButton.target = self
        regexButton.action = #selector(regexChanged)
        branchButton.menuProvider = { [weak self] in self?.branchMenu() }
        authorButton.menuProvider = { [weak self] in self?.authorMenu() }
        dateButton.menuProvider = { [weak self] in self?.dateMenu() }
        pathsButton.menuProvider = { [weak self] in self?.pathsMenu() }
        branchButton.toolTip = "Commits on one branch or tag, or on all"
        authorButton.toolTip = "Commits by one person"
        dateButton.toolTip = "Commits from a time"
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = Theme.textDim
        refreshButton.bezelStyle = .regularSquare
        refreshButton.isBordered = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        refreshButton.contentTintColor = Theme.textDim
        refreshButton.toolTip = "Read the log again"
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        header.setViews([searchField, regexButton, branchButton, authorButton, dateButton, pathsButton, NSView(), status, refreshButton], in: .leading)
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        header.wantsLayer = true
        header.layer?.backgroundColor = Theme.bar.cgColor
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        graphColumn.title = ""
        graphColumn.width = GitLogStyle.graphWidth(lanes: 1)
        graphColumn.minWidth = 20
        graphColumn.maxWidth = GitLogStyle.graphWidth(lanes: GitLogStyle.maxLanes)
        graphColumn.resizingMask = []
        let subject = NSTableColumn(identifier: .init("subject"))
        subject.title = "Subject"
        subject.minWidth = 160
        subject.resizingMask = .autoresizingMask
        let author = NSTableColumn(identifier: .init("author"))
        author.title = "Author"
        author.width = 150
        author.minWidth = 60
        author.resizingMask = .userResizingMask
        let date = NSTableColumn(identifier: .init("date"))
        date.title = "Date"
        date.width = 150
        date.minWidth = 60
        date.resizingMask = .userResizingMask
        for column in [graphColumn, subject, author, date] { table.addTableColumn(column) }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.style = .plain
        table.rowHeight = GitLogStyle.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = Theme.background
        table.gridStyleMask = []
        table.allowsColumnReordering = false
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Commits")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.background
        message.textColor = Theme.textDim
        message.alignment = .center
        message.isHidden = true

        for view in [scroll, message] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            centre.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: centre.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: centre.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: centre.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: centre.bottomAnchor),
            message.centerYAnchor.constraint(equalTo: centre.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: centre.leadingAnchor, constant: 30),
            message.trailingAnchor.constraint(equalTo: centre.trailingAnchor, constant: -30),
        ])

        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(refs)
        split.addArrangedSubview(centre)
        split.addArrangedSubview(details)
        refs.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        centre.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        details.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        // The commits take what the window gives or takes; the sides keep their width.
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setHoldingPriority(.init(200), forSubviewAt: 1)
        split.setHoldingPriority(.init(260), forSubviewAt: 2)
        refs.onSelect = { [weak self] ref in self?.show(ref: ref) }
        table.onReturn = { [weak self] in self?.details.focusFiles() }
        details.onSelectCommit = { [weak self] sha in self?.select(sha: sha) }
        details.onOpenFile = { [weak self] file, shown in
            self?.onOpenChange?(file.path, DiffPane.CommitChange(sha: shown.commit.sha, parent: shown.commit.parents.first, oldPath: file.oldPath))
        }
        for view in [header, split] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            split.topAnchor.constraint(equalTo: header.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layout() {
        super.layout()
        // The tree 210 wide, the details a third of the width (at most 380), the first time there is room.
        if !placedDividers, split.bounds.width > 800 {
            placedDividers = true
            let width = split.bounds.width
            split.setPosition(210, ofDividerAt: 0)
            split.setPosition(width - min(380, round(width / 3)), ofDividerAt: 1)
        }
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { commits.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GitLogRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let commit = commits[safe: row], let id = tableColumn?.identifier else { return nil }
        // Near the end of what is loaded: the next page.
        if row > commits.count - 200, !isComplete, !isLoading { DispatchQueue.main.async { [weak self] in self?.loadMore() } }
        switch id.rawValue {
        case "graph":
            let view = tableView.makeView(withIdentifier: GitGraphView.identifier, owner: self) as? GitGraphView ?? GitGraphView(frame: .zero)
            view.row = rows[safe: row]
            view.isHead = commit.sha == headSHA
            return view
        case "subject":
            let view = tableView.makeView(withIdentifier: GitSubjectView.identifier, owner: self) as? GitSubjectView ?? GitSubjectView(frame: .zero)
            view.show(commit)
            return view
        default:
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? GitTextCell ?? GitTextCell(identifier: id)
            if id.rawValue == "author" {
                cell.textField?.stringValue = commit.authorName
                cell.toolTip = "\(commit.authorName) <\(commit.authorEmail)>"
            } else {
                cell.textField?.stringValue = GitLogStyle.dateText(commit.authorDate)
                cell.toolTip = GitLogStyle.fullDate(commit.authorDate)
            }
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let commit = selectedCommit
        // Over a refresh the selection comes back: the details stay meanwhile.
        if commit == nil, let wanted, wanted.sha == details.shown?.sha { return }
        if let commit, commit == details.shown { return }
        details.show(commit)
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let commit = commits[safe: table.clickedRow] else { return }
        buildMenu(menu, commit)
    }

    /// Filled in by the commit actions (copy, branch, checkout).
    var buildMenu: (NSMenu, Commit) -> Void = { _, _ in }
}

/// The commit table: ↩ opens the selected commit's details.
final class GitLogTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty, selectedRow >= 0 {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

/// A toolbar button that opens a menu of choices; highlighted while it filters.
final class GitLogFilterButton: NSButton {
    var menuProvider: (() -> NSMenu?)?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: 11.5)
        image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        imagePosition = .imageTrailing
        target = self
        action = #selector(pop)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ text: String, active: Bool) {
        title = Typography.shortened(text, to: 28)
        contentTintColor = active ? Theme.accent : nil
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: active ? .semibold : .regular),
            .foregroundColor: active ? Theme.gitModified : Theme.text,
        ])
        setAccessibilityLabel(text)
    }

    @objc private func pop() {
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : -4), in: self)
    }
}

extension NSMenu {
    /// An item that runs a closure; `on` shows a check mark.
    @discardableResult
    func addBlock(_ title: String, on: Bool = false, enabled: Bool = true, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? #selector(MenuBlock.run(_:)) : nil, keyEquivalent: "")
        let block = MenuBlock(run)
        item.target = block
        item.representedObject = block
        item.state = on ? .on : .off
        item.isEnabled = enabled
        addItem(item)
        return item
    }
}
