import AppKit
import NextTermCore

/// Compare with Current and Show Diff with Working Tree, from a branch's menu in the branch popup, in an
/// editor tab. Compare lists the commits only on the branch and only on what is checked out (a commit
/// whose change the other side has too, a cherry-pick, is marked "="), then the files the branch changed
/// since the two parted. Working Tree lists the files on disk that differ from the branch. ↩ or a
/// double-click opens a commit in the Git Log, or a file's diff side by side. Only reads, and reads again
/// when a branch moves (or, for the working tree, when a file changes).
final class BranchComparePane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Mode: Equatable {
        /// Compare with Current.
        case compare
        /// Show Diff with Working Tree.
        case workingTree
    }

    enum Row: Equatable {
        case header(String, detail: String)
        case commit(ComparedCommit)
        case file(ChangedFile)
        case note(String)

        var isSelectable: Bool {
            switch self {
            case .commit, .file: return true
            case .header, .note: return false
            }
        }
    }

    /// The work tree's top folder.
    let root: String
    /// "refs/heads/feat/x", or "refs/remotes/origin/x".
    let branch: String
    let mode: Mode
    var onTitleChange: (() -> Void)?
    /// A file was opened: its diff, as this tab compares it.
    var onOpenFile: ((ChangedFile) -> Void)?

    private(set) var comparison: BranchComparison?
    private(set) var diskFiles: [ChangedFile]?
    private(set) var rows: [Row] = []
    private(set) var isLoading = false
    private(set) var failure: String?
    /// What is checked out, as shown: until the first read, what the branch popup said.
    private var current: String?
    private var generation = 0
    private var watchers: [DirectoryWatcher] = []
    private var signature: String?
    private var pendingCheck: DispatchWorkItem?
    private static let queue = DispatchQueue(label: "nextterm.branch-compare", qos: .userInitiated)

    private let header = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    let table = GitLogTableView()
    private let scroll = NSScrollView()
    private let message = NSTextField(wrappingLabelWithString: "")

    init(root: String, branch: String, mode: Mode, current: String?) {
        self.root = root
        self.branch = branch
        self.mode = mode
        self.current = current
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        build()
        reload()
        watch()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static let tabIcon: NSImage? = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Compare")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(.init(paletteColors: [Theme.gitModified])))

    var branchName: String { BranchCompare.displayName(branch) }
    /// The branch checked out, or HEAD when detached.
    var currentName: String { current ?? "HEAD" }
    var title: String { mode == .compare ? "\(branchName) ↔ \(currentName)" : "\(branchName) ↔ Working Tree" }
    var tooltip: String {
        if mode == .workingTree { return "The files on disk in \(RecentProjects.abbreviate(root)) that differ from \(branchName)" }
        return "The commits only on \(branchName) and only on \(currentName), and the files \(branchName) changed"
    }
    var focusView: NSView { table }

    func matches(root: String, branch: String, mode: Mode) -> Bool { self.root == root && self.branch == branch && self.mode == mode }

    /// For the self-test: the rows as words, and the message shown instead of them.
    var rowTitles: [String] {
        rows.map { row in
            switch row {
            case let .header(text, detail): return "# \(text) · \(detail)"
            case let .commit(c): return (c.isEquivalent ? "= " : "") + c.subject
            case let .file(f):
                let from = f.oldPath.map { " ← " + $0 } ?? ""
                return "\(f.status.rawValue) \(f.path)\(from)"
            case let .note(text): return "note " + text
            }
        }
    }
    var messageText: String { message.isHidden ? "" : message.stringValue }

    // MARK: reading

    /// Reads the comparison again; what is shown stays meanwhile, and so does the selection. `quietly`:
    /// without "Reading…" (a file or a branch changed, not a click).
    func reload(quietly: Bool = false) {
        guard let git = GitLogPane.git else {
            failure = "Git is not installed."
            return update()
        }
        generation += 1
        isLoading = true
        if !quietly { status.stringValue = "Reading…" }
        let token = generation, root = self.root, branch = self.branch, mode = self.mode
        Self.queue.async { [weak self] in
            let comparison = mode == .compare ? BranchCompare.compare(branch, in: root, git: git) : nil
            let files = mode == .workingTree ? BranchCompare.workingTreeFiles(against: branch, in: root, git: git) : nil
            let current = mode == .workingTree ? BranchCompare.current(in: root, git: git) : comparison?.current
            let signature = CommitLog.refsSignature(in: root, git: git)
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.isLoading = false
                self.signature = signature ?? self.signature
                let read = mode == .compare ? comparison != nil : files != nil
                let against = mode == .compare ? self.currentName : "the files on disk"
                self.failure = read ? nil : "Git could not compare \(self.branchName) with \(against)."
                let changed = comparison != self.comparison || files != self.diskFiles || current != self.current
                self.comparison = comparison
                self.diskFiles = files
                if read { self.current = current }
                if changed || !read { self.update() } else { self.updateStatus() }
            }
        }
    }

    /// A branch moving (yours or an agent's, in any worktree) changes the folder git keeps refs in; for the
    /// working tree, so does any file. Then, once things settle, the comparison is read again.
    private func watch() {
        guard let common = GitRunner.commonGitDir(root: root) else { return }
        let objects = canonicalPath(common) + "/objects"
        let changed: ([String]) -> Void = { [weak self] paths in
            guard paths.contains(where: { !canonicalPath($0).hasPrefix(objects) }) else { return }
            self?.checkSoon()
        }
        var folders = [common]
        if mode == .workingTree {
            // The files, and the refs too when they live outside them (a linked worktree's).
            folders = canonicalPath(common).hasPrefix(canonicalPath(root) + "/") ? [root] : [root, common]
        }
        watchers = folders.map { DirectoryWatcher(path: $0, onChange: changed) }
    }

    private func checkSoon() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// The working tree: read again. A comparison of commits: only when a ref did move.
    private func check() {
        if mode == .workingTree { return reload(quietly: true) }
        guard let git = GitLogPane.git else { return }
        let root = self.root
        Self.queue.async { [weak self] in
            let now = CommitLog.refsSignature(in: root, git: git)
            DispatchQueue.main.async {
                guard let self, let now, now != self.signature else { return }
                self.reload(quietly: true)
            }
        }
    }

    @objc private func refreshClicked() { reload() }

    // MARK: rows

    private func update() {
        let selected = rows[safe: table.selectedRow].flatMap(Self.key)
        rows = failure == nil ? (mode == .compare ? compareRows() : diskRows()) : []
        table.reloadData()
        if let selected, let index = rows.firstIndex(where: { Self.key($0) == selected }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        updateTitle()
        updateStatus()
        onTitleChange?()
    }

    private static func key(_ row: Row) -> String? {
        switch row {
        case let .commit(c): return "commit:" + c.sha
        case let .file(f): return "file:" + f.path
        default: return nil
        }
    }

    private static func commits(_ count: Int) -> String { "\(count.formatted()) commit\(count == 1 ? "" : "s")" }

    /// "3 commits", "3 commits, 1 also on main", "the newest 500 of 1,234".
    private func detail(listed: [ComparedCommit], count: Int, other: String) -> String {
        var text = listed.count < count ? "the newest \(listed.count.formatted()) of \(count.formatted())" : Self.commits(count)
        let same = listed.filter(\.isEquivalent).count
        if same > 0 { text += ", \(same) also on \(other)" }
        return text
    }

    private func compareRows() -> [Row] {
        guard let c = comparison, !c.isSameCommit else { return [] }
        let branch = branchName, current = currentName
        var rows: [Row] = []
        let sides: [(side: String, other: String, commits: [ComparedCommit], count: Int)] = [
            (branch, current, c.branchOnly, c.branchCount), (current, branch, c.currentOnly, c.currentCount),
        ]
        for (side, other, commits, count) in sides {
            rows.append(.header("Only on \(side)", detail: detail(listed: commits, count: count, other: other)))
            if commits.isEmpty {
                rows.append(.note("No commits on \(side) that \(other) doesn’t have."))
            } else {
                rows += commits.map { Row.commit($0) }
            }
        }
        guard let base = c.mergeBase else {
            rows.append(.header("Files changed on \(branch)", detail: ""))
            rows.append(.note("\(branch) and \(current) have no commit in common, so there is no starting point to compare files from."))
            return rows
        }
        let files = "\(c.files.count.formatted()) file\(c.files.count == 1 ? "" : "s")"
        rows.append(.header("Files changed on \(branch)", detail: "\(files), since \(base.prefix(7))"))
        if c.files.isEmpty, c.branchCount == 0 {
            rows.append(.note("None: \(branch) has nothing \(current) doesn’t."))
        } else if c.files.isEmpty {
            rows.append(.note("None: \(branch)’s commits leave the files as they were at \(base.prefix(7))."))
        }
        return rows + c.files.map { Row.file($0) }
    }

    private func diskRows() -> [Row] {
        guard let files = diskFiles, !files.isEmpty else { return [] }
        let count = "\(files.count.formatted()) file\(files.count == 1 ? "" : "s")"
        return [.header("On disk, different from \(branchName)", detail: count)] + files.map { Row.file($0) }
    }

    private func updateTitle() {
        let strong: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Theme.text]
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.textDim]
        let text = NSMutableAttributedString(string: branchName, attributes: strong)
        if mode == .compare {
            text.append(NSAttributedString(string: " compared with ", attributes: dim))
            text.append(NSAttributedString(string: currentName, attributes: strong))
        } else {
            text.append(NSAttributedString(string: " against the files on disk", attributes: dim))
        }
        titleLabel.attributedStringValue = Typography.truncating(text, .byTruncatingMiddle)
        titleLabel.toolTip = tooltip
    }

    private func updateStatus() {
        if !isLoading { status.stringValue = "" }
        if let failure {
            message.stringValue = failure
        } else if mode == .compare, let c = comparison, c.isSameCommit {
            message.stringValue = "\(branchName) and \(currentName) are at the same commit: there is nothing to compare."
        } else if mode == .workingTree, diskFiles?.isEmpty == true {
            message.stringValue = "The files on disk are the same as on \(branchName). Files git doesn’t track aren’t compared."
        } else {
            message.stringValue = ""
        }
        message.isHidden = message.stringValue.isEmpty
        scroll.isHidden = !message.isHidden
    }

    // MARK: opening

    /// A commit: in the Git Log. A file: its diff.
    func open(row: Int) {
        switch rows[safe: row] {
        case let .commit(c)?: (window?.windowController as? TerminalWindowController)?.showCommit(sha: c.sha, root: root)
        case let .file(f)?: onOpenFile?(f)
        default: NSSound.beep()
        }
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        open(row: table.clickedRow)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        switch rows[safe: row] {
        case let .commit(c)?:
            menu.addBlock("Show in Git Log") { [weak self] in self?.open(row: row) }
            menu.addBlock("Copy Hash") { [weak self] in self?.copy(c.sha, saying: c.shortSHA) }
        case let .file(f)?:
            menu.addBlock("Show Diff") { [weak self] in self?.open(row: row) }
            menu.addBlock("Copy Path") { [weak self] in self?.copy(f.path, saying: (f.path as NSString).lastPathComponent) }
        default:
            break
        }
    }

    /// ⌘C: the selected commit's hash, or the file's path.
    @objc func copy(_ sender: Any?) {
        switch rows[safe: table.selectedRow] {
        case let .commit(c)?: copy(c.sha, saying: c.shortSHA)
        case let .file(f)?: copy(f.path, saying: (f.path as NSString).lastPathComponent)
        default: NSSound.beep()
        }
    }

    private func copy(_ text: String, saying shown: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        GitToast.show("Copied \(shown)", in: window)
    }

    // MARK: layout

    private func build() {
        Typography.singleLine(titleLabel, truncation: .byTruncatingMiddle)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 11)
        status.textColor = Theme.textDim
        refreshButton.bezelStyle = .regularSquare
        refreshButton.isBordered = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        refreshButton.contentTintColor = Theme.textDim
        refreshButton.toolTip = "Compare again"
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        header.setViews([titleLabel, NSView(), status, refreshButton], in: .leading)
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        header.wantsLayer = true
        header.layer?.backgroundColor = Theme.bar.cgColor
        updateTitle()

        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = Theme.background
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onReturn = { [weak self] in
            guard let self else { return }
            self.open(row: self.table.selectedRow)
        }
        table.setAccessibilityLabel(mode == .compare ? "Commits and files" : "Files")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.background
        message.textColor = Theme.textDim
        message.alignment = .center
        message.isHidden = true

        for view in [header, scroll, message] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            message.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
        ])
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[safe: row] {
        case .header?: return 30
        case .file?: return 22
        default: return GitLogStyle.rowHeight
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[safe: row]?.isSelectable ?? false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GitLogRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = rows[safe: row] else { return nil }
        switch item {
        case let .file(file):
            let cell = tableView.makeView(withIdentifier: GitFileCell.identifier, owner: self) as? GitFileCell ?? GitFileCell()
            cell.show(file)
            return cell
        case let .commit(commit):
            let cell = tableView.makeView(withIdentifier: ComparedCommitCell.identifier, owner: self) as? ComparedCommitCell ?? ComparedCommitCell()
            cell.show(commit, other: commit.side == .branch ? currentName : branchName)
            return cell
        case let .header(text, detail):
            let cell = tableView.makeView(withIdentifier: CompareTextCell.identifier, owner: self) as? CompareTextCell ?? CompareTextCell()
            cell.show(header: text, detail: detail)
            return cell
        case let .note(text):
            let cell = tableView.makeView(withIdentifier: CompareTextCell.identifier, owner: self) as? CompareTextCell ?? CompareTextCell()
            cell.show(note: text)
            return cell
        }
    }
}

/// A commit in a comparison: "=" when the other side has its change, its short hash, subject, author and date.
final class ComparedCommitCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ComparedCommit")
    private let mark = NSTextField(labelWithString: "")
    private let sha = NSTextField(labelWithString: "")
    private let subject = NSTextField(labelWithString: "")
    private let author = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        mark.font = .monospacedSystemFont(ofSize: 11.5, weight: .bold)
        mark.textColor = Theme.attention
        mark.alignment = .center
        sha.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        sha.textColor = Theme.textDim
        subject.font = .systemFont(ofSize: 12.5)
        subject.textColor = Theme.text
        for field in [author, date] {
            field.font = .systemFont(ofSize: 12)
            field.textColor = Theme.textDim
        }
        date.alignment = .right
        for field in [sha, subject, author, date] { Typography.singleLine(field, truncation: .byTruncatingTail) }
        subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        author.setContentCompressionResistancePriority(.init(600), for: .horizontal)
        for view in [mark, sha, subject, author, date] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            mark.widthAnchor.constraint(equalToConstant: 14),
            sha.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 6),
            sha.widthAnchor.constraint(equalToConstant: 62),
            subject.leadingAnchor.constraint(equalTo: sha.trailingAnchor, constant: 6),
            subject.trailingAnchor.constraint(lessThanOrEqualTo: author.leadingAnchor, constant: -12),
            author.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
            author.trailingAnchor.constraint(equalTo: date.leadingAnchor, constant: -12),
            date.widthAnchor.constraint(equalToConstant: 140),
            date.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        for view in [mark, sha, subject, author, date] { view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// `other`: the side that has the same change, for the "=" mark's tooltip.
    func show(_ commit: ComparedCommit, other: String) {
        mark.stringValue = commit.isEquivalent ? "=" : ""
        mark.toolTip = commit.isEquivalent ? "\(other) has the same change (cherry-picked)" : nil
        sha.stringValue = commit.shortSHA
        subject.stringValue = commit.subject
        author.stringValue = commit.authorName
        date.stringValue = GitLogStyle.dateText(commit.authorDate)
        date.toolTip = GitLogStyle.fullDate(commit.authorDate)
        toolTip = "\(commit.subject)\n\(commit.shortSHA) by \(commit.authorName). Double-click to see it in the Git Log."
        let same = commit.isEquivalent ? ", the same change is on \(other)" : ""
        setAccessibilityLabel("\(commit.subject), \(commit.shortSHA), \(commit.authorName), \(date.stringValue)\(same)")
    }
}

/// A group's heading with its count, or a note in place of the rows a group doesn't have.
final class CompareTextCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CompareText")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        Typography.singleLine(title, truncation: .byTruncatingMiddle)
        Typography.singleLine(detail, truncation: .byTruncatingTail)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        for view in [title, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        leading = title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        NSLayoutConstraint.activate([
            leading,
            detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            title.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            detail.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(header text: String, detail count: String) {
        leading.constant = 12
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = Theme.text
        title.stringValue = text
        title.toolTip = nil
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = Theme.textDim
        detail.stringValue = count
        detail.isHidden = count.isEmpty
        setAccessibilityLabel(count.isEmpty ? text : "\(text), \(count)")
    }

    func show(note text: String) {
        leading.constant = 30
        title.font = .systemFont(ofSize: 12)
        title.textColor = Theme.textDim
        title.stringValue = text
        title.toolTip = text
        detail.isHidden = true
        setAccessibilityLabel(text)
    }
}
