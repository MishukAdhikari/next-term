import AppKit
import NextTermCore

/// The Git Diff tab's left column: "All files" and the changed files as a tree of the folders that hold
/// them (each file with its icon, +N −M and a mark when added, deleted or renamed), and under it the
/// scopes: All changes, Uncommitted (while there is any), then this branch's commits. ↑ and ↓ move between
/// files, ↩ goes to the diff.
final class GitDiffListView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// A row of the scopes list.
    enum ScopeRow: Equatable {
        case all(LineStats?)
        case uncommitted(LineStats?)
        case commit(Commit)
        case note(String)

        var scope: ChangeScope? {
            switch self {
            case .all: return .all
            case .uncommitted: return .uncommitted
            case let .commit(c): return .commit(c.sha)
            case .note: return nil
            }
        }
    }

    /// An outline row; kept from one read to the next (by key), so expansion and selection stay.
    final class Item: NSObject {
        enum Kind { case allFiles, folder, file }
        let kind: Kind
        let key: String
        var node: ChangeTreeNode?
        var children: [Item] = []
        var totals = LineStats()

        init(kind: Kind, key: String) {
            self.kind = kind
            self.key = key
        }

        var path: String? { node?.path }
        var file: ChangedFile? { node?.file }
    }

    let outline = GitDiffOutlineView()
    let scopesTable = GitLogTableView()
    private let filesScroll = NSScrollView()
    private let scopesScroll = NSScrollView()
    private let split = NSSplitView()
    private let commitsHeader = NSView()
    private let commitsTitle = NSTextField(labelWithString: "Commits")
    private let commitsCount = NSTextField(labelWithString: "")
    private let filesMessage = NSTextField(wrappingLabelWithString: "")

    private let allFiles = Item(kind: .allFiles, key: "all")
    private var top: [Item] = []
    private var items: [String: Item] = [:]
    /// Folders closed by hand; every other folder is open.
    private var closed = Set<String>()
    private(set) var scopeRows: [ScopeRow] = []
    private var root = ""
    /// Selection changes made here, not by a click: they don't call back.
    private var settingSelection = false
    private var placedDivider = false

    /// A file was picked (nil: All files).
    var onSelectFile: ((String?) -> Void)?
    var onSelectScope: ((ChangeScope) -> Void)?
    /// The scopes list came near its end: the next page of commits.
    var onNeedMoreCommits: (() -> Void)?
    /// ↩ on a file: to the diff.
    var onReturn: (() -> Void)?
    var onOpenFile: ((ChangedFile) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The files in the order the tree shows them.
    private(set) var orderedFiles: [ChangedFile] = []

    // MARK: showing

    /// The files of the scope as a tree, `selected` (nil: All files) selected. `message` stands in for an
    /// empty list.
    func show(tree: [ChangeTreeNode], totals: LineStats, root: String, selected: String?, message: String?) {
        // Read again and the same: only the selection, so nothing flashes or scrolls.
        if tree == shownTree, totals == allFiles.totals, root == self.root, message == shownMessage {
            return select(path: selected, reveal: false)
        }
        shownTree = tree
        shownMessage = message
        self.root = root
        allFiles.totals = totals
        var seen: [String: Item] = [:]
        func item(for node: ChangeTreeNode) -> Item {
            let key = (node.isFolder ? "folder:" : "file:") + node.path
            let made = items[key] ?? Item(kind: node.isFolder ? .folder : .file, key: key)
            made.node = node
            made.children = node.children.map(item(for:))
            seen[key] = made
            return made
        }
        top = tree.map(item(for:))
        items = seen
        orderedFiles = ChangeTree.files(in: tree)
        filesMessage.stringValue = message ?? ""
        filesMessage.isHidden = message == nil
        settingSelection = true
        outline.reloadData()
        for item in top { expand(item) }
        select(path: selected, reveal: false)
        settingSelection = false
    }

    private var shownTree: [ChangeTreeNode]?
    private var shownMessage: String?

    private func expand(_ item: Item) {
        guard item.kind == .folder else { return }
        if !closed.contains(item.key) { outline.expandItem(item) }
        item.children.forEach(expand)
    }

    /// Selects the file at `path` (nil: All files) without calling back; a file not listed selects nothing.
    /// `reveal`: scrolled to, when the selection moved.
    func select(path: String?, reveal: Bool = true) {
        let target: Item?
        if let path { target = items["file:" + path] } else { target = top.isEmpty ? nil : allFiles }
        let row = target.map { outline.row(forItem: $0) } ?? -1
        let was = settingSelection
        settingSelection = true
        if row >= 0 {
            let moved = outline.selectedRow != row
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if reveal || moved { outline.scrollRowToVisible(row) }
        } else {
            outline.deselectAll(nil)
        }
        settingSelection = was
    }

    /// The scopes: All changes, Uncommitted, the commits; `selected` selected. `count`: the commits in all.
    func show(scopes: [ScopeRow], selected: ChangeScope, count: Int?) {
        guard scopes != scopeRows else {
            commitsCount.stringValue = count.map { $0.formatted() } ?? ""
            return select(scope: selected)
        }
        scopeRows = scopes
        settingSelection = true
        scopesTable.reloadData()
        select(scope: selected)
        settingSelection = false
        commitsCount.stringValue = count.map { $0.formatted() } ?? ""
    }

    func select(scope: ChangeScope) {
        let was = settingSelection
        settingSelection = true
        if let row = scopeRows.firstIndex(where: { $0.scope == scope }) {
            scopesTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            scopesTable.deselectAll(nil)
        }
        settingSelection = was
    }

    /// For the self-test: the file rows as words ("All files +3 −1", "app/", "A src/new.txt +2 −0").
    var rowTitles: [String] {
        (0..<outline.numberOfRows).compactMap { row in
            guard let item = outline.item(atRow: row) as? Item else { return nil }
            switch item.kind {
            case .allFiles: return "All files " + Self.counts(added: item.totals.added, removed: item.totals.removed)
            case .folder: return (item.node?.name ?? "") + "/"
            case .file:
                guard let file = item.file else { return nil }
                let mark = GitDiffFileCell.mark(file.status).map { $0 + " " } ?? ""
                let counts = file.isBinary ? " binary" : (file.added.map { " " + Self.counts(added: $0, removed: file.removed ?? 0) } ?? "")
                return mark + file.path + counts
            }
        }
    }

    /// For the self-test: the selected file row, as `rowTitles` words it.
    var selectedTitle: String? { outline.selectedRow >= 0 ? rowTitles[safe: outline.selectedRow] : nil }

    /// For the self-test: the scope rows as words.
    var scopeTitles: [String] {
        scopeRows.map { row in
            switch row {
            case .all: return "All changes"
            case .uncommitted: return "Uncommitted"
            case let .commit(c): return c.subject
            case let .note(text): return "note " + text
            }
        }
    }

    static func counts(added: Int, removed: Int) -> String { "+\(added) −\(removed)" }

    // MARK: picking

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !settingSelection, let item = outline.item(atRow: outline.selectedRow) as? Item else { return }
        switch item.kind {
        case .allFiles: onSelectFile?(nil)
        case .file: onSelectFile?(item.path)
        case .folder: break
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !settingSelection, let scope = scopeRows[safe: scopesTable.selectedRow]?.scope else { return }
        onSelectScope?(scope)
    }

    /// ↑ and ↓ from the outline: the file above or below (All files at the top), past the folders.
    func step(by delta: Int) {
        var row = outline.selectedRow
        repeat {
            row += delta
        } while row >= 0 && row < outline.numberOfRows && (outline.item(atRow: row) as? Item)?.kind == .folder
        guard row >= 0, row < outline.numberOfRows else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    // MARK: layout

    private func build() {
        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = false // deep folders don't push the counts out of sight
        outline.backgroundColor = Theme.background
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.list = self
        outline.setAccessibilityLabel("Changed files")
        let menu = NSMenu()
        menu.delegate = outline
        outline.menu = menu
        filesScroll.documentView = outline
        filesScroll.hasVerticalScroller = true
        filesScroll.autohidesScrollers = true
        filesScroll.drawsBackground = true
        filesScroll.backgroundColor = Theme.background
        filesMessage.textColor = Theme.textDim
        filesMessage.font = .systemFont(ofSize: 12)
        filesMessage.alignment = .center
        filesMessage.isHidden = true

        let scopes = NSTableColumn(identifier: .init("scope"))
        scopes.resizingMask = .autoresizingMask
        scopesTable.addTableColumn(scopes)
        scopesTable.headerView = nil
        scopesTable.style = .plain
        scopesTable.intercellSpacing = .zero
        scopesTable.backgroundColor = Theme.background
        scopesTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        scopesTable.dataSource = self
        scopesTable.delegate = self
        scopesTable.setAccessibilityLabel("What to compare: all changes, uncommitted, or a commit")
        scopesScroll.documentView = scopesTable
        scopesScroll.hasVerticalScroller = true
        scopesScroll.autohidesScrollers = true
        scopesScroll.drawsBackground = true
        scopesScroll.backgroundColor = Theme.background
        scopesScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(checkCommitsEnd), name: NSView.boundsDidChangeNotification,
                                               object: scopesScroll.contentView)

        commitsTitle.font = .systemFont(ofSize: 11.5, weight: .semibold)
        commitsTitle.textColor = Theme.textDim
        commitsCount.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        commitsCount.textColor = Theme.textDim
        commitsCount.alignment = .right
        commitsHeader.wantsLayer = true
        commitsHeader.layer?.backgroundColor = Theme.bar.cgColor
        let lower = NSView()
        for view in [commitsTitle, commitsCount] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            commitsHeader.addSubview(view)
        }
        for view in [commitsHeader, scopesScroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            lower.addSubview(view)
        }
        let upper = NSView()
        for view in [filesScroll, filesMessage] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            upper.addSubview(view)
        }
        NSLayoutConstraint.activate([
            filesScroll.topAnchor.constraint(equalTo: upper.topAnchor),
            filesScroll.leadingAnchor.constraint(equalTo: upper.leadingAnchor),
            filesScroll.trailingAnchor.constraint(equalTo: upper.trailingAnchor),
            filesScroll.bottomAnchor.constraint(equalTo: upper.bottomAnchor),
            filesMessage.centerYAnchor.constraint(equalTo: upper.centerYAnchor),
            filesMessage.leadingAnchor.constraint(equalTo: upper.leadingAnchor, constant: 16),
            filesMessage.trailingAnchor.constraint(equalTo: upper.trailingAnchor, constant: -16),
            commitsHeader.topAnchor.constraint(equalTo: lower.topAnchor),
            commitsHeader.leadingAnchor.constraint(equalTo: lower.leadingAnchor),
            commitsHeader.trailingAnchor.constraint(equalTo: lower.trailingAnchor),
            commitsHeader.heightAnchor.constraint(equalToConstant: 28),
            commitsTitle.leadingAnchor.constraint(equalTo: commitsHeader.leadingAnchor, constant: 12),
            commitsTitle.centerYAnchor.constraint(equalTo: commitsHeader.centerYAnchor),
            commitsCount.trailingAnchor.constraint(equalTo: commitsHeader.trailingAnchor, constant: -12),
            commitsCount.centerYAnchor.constraint(equalTo: commitsHeader.centerYAnchor),
            scopesScroll.topAnchor.constraint(equalTo: commitsHeader.bottomAnchor),
            scopesScroll.leadingAnchor.constraint(equalTo: lower.leadingAnchor),
            scopesScroll.trailingAnchor.constraint(equalTo: lower.trailingAnchor),
            scopesScroll.bottomAnchor.constraint(equalTo: lower.bottomAnchor),
        ])
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(upper)
        split.addArrangedSubview(lower)
        split.setHoldingPriority(.init(250), forSubviewAt: 0)
        split.setHoldingPriority(.init(260), forSubviewAt: 1)
        split.translatesAutoresizingMaskIntoConstraints = false
        addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layout() {
        super.layout()
        // The files get most of the height at first; the divider then stays where it is dragged.
        if !placedDivider, split.bounds.height > 200, let upper = split.arrangedSubviews.first {
            let target = round(split.bounds.height * 0.62)
            split.setPosition(target, ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
            placedDivider = abs(upper.frame.height - target) < 2
        }
    }

    @objc private func checkCommitsEnd() {
        let visible = scopesTable.rows(in: scopesScroll.contentView.bounds)
        if NSMaxRange(visible) >= scopeRows.count - 5 { onNeedMoreCommits?() }
    }

    // MARK: outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? Item else { return top.isEmpty ? 0 : top.count + 1 }
        return item.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? Item else { return index == 0 ? allFiles : top[index - 1] }
        return item.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Item)?.kind == .folder }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? Item)?.kind != .folder }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { 24 }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { GitLogRowView() }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? Item { closed.insert(item.key) }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? Item { closed.remove(item.key) }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item else { return nil }
        let cell = outlineView.makeView(withIdentifier: GitDiffFileCell.identifier, owner: self) as? GitDiffFileCell ?? GitDiffFileCell()
        switch item.kind {
        case .allFiles: cell.showAllFiles(item.totals)
        case .folder: cell.showFolder(item.node?.name ?? "", path: item.path ?? "")
        case .file: if let file = item.file { cell.show(file, root: root) }
        }
        return cell
    }

    /// The menu of a file row: Open File, Copy Path.
    func menu(forRow row: Int) -> NSMenu? {
        guard let item = outline.item(atRow: row) as? Item, let file = item.file else { return nil }
        let menu = NSMenu()
        menu.addBlock("Open File", enabled: file.status != .deleted) { [weak self] in self?.onOpenFile?(file) }
        menu.addBlock("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.path, forType: .string)
        }
        return menu
    }

    // MARK: scopes

    func numberOfRows(in tableView: NSTableView) -> Int { scopeRows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .commit? = scopeRows[safe: row] { return 44 }
        return 30
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { scopeRows[safe: row]?.scope != nil }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GitLogRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = scopeRows[safe: row] else { return nil }
        let cell = tableView.makeView(withIdentifier: GitDiffScopeCell.identifier, owner: self) as? GitDiffScopeCell ?? GitDiffScopeCell()
        cell.show(item)
        return cell
    }
}

/// The changed files' outline: ↑ and ↓ go from file to file, past the folders; ↩ goes to the diff.
final class GitDiffOutlineView: NSOutlineView, NSMenuDelegate {
    weak var list: GitDiffListView?

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        switch event.keyCode {
        case 126 where plain: list?.step(by: -1)
        case 125 where plain: list?.step(by: 1)
        default:
            guard opens(event) else { return super.keyDown(with: event) }
            list?.onReturn?()
        }
    }

    /// A key with ⌘ comes here before the menus (KeyBindings.canShareKey).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, opens(event) else { return super.performKeyEquivalent(with: event) }
        list?.onReturn?()
        return true
    }

    /// To the diff: ↩, or the key Settings gives the Git lists' Open Commit or File.
    private func opens(_ event: NSEvent) -> Bool {
        KeyboardShortcuts.shared.partCommand(for: event, in: .gitLists) == "gitLists.open"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let built = list?.menu(forRow: clickedRow) else { return }
        for item in built.items {
            built.removeItem(item)
            menu.addItem(item)
        }
    }
}

/// A row of the changed files: All files with the total, a folder, or a file with its icon, name, mark and
/// counts.
final class GitDiffFileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GitDiffFile")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let mark = NSTextField(labelWithString: "")
    private let counts = NSTextField(labelWithString: "")
    private var iconWidth: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        Typography.singleLine(name, truncation: .byTruncatingMiddle)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mark.font = .monospacedSystemFont(ofSize: 10.5, weight: .bold)
        counts.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        counts.alignment = .right
        for field in [mark, counts] {
            field.setContentHuggingPriority(.required, for: .horizontal)
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        for view in [icon, name, mark, counts] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 16)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconWidth,
            icon.heightAnchor.constraint(equalToConstant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            counts.leadingAnchor.constraint(greaterThanOrEqualTo: mark.trailingAnchor, constant: 8),
            counts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            counts.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The letter shown after a file's name: added, deleted, renamed, copied, in conflict; none when modified.
    static func mark(_ status: ChangedFile.Status) -> String? {
        switch status {
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .unmerged: return "U"
        case .modified, .typeChanged, .unknown: return nil
        }
    }

    static func describe(_ status: ChangedFile.Status) -> String {
        switch status {
        case .added: return "added"
        case .deleted: return "deleted"
        case .renamed: return "renamed"
        case .copied: return "copied"
        case .unmerged: return "in conflict"
        case .typeChanged: return "type changed"
        case .modified, .unknown: return "modified"
        }
    }

    static func numbers(added: Int?, removed: Int?, binary: Bool) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        guard !binary else { return NSAttributedString(string: "binary", attributes: [.font: font, .foregroundColor: Theme.textDim]) }
        guard let added else { return NSAttributedString() }
        let text = NSMutableAttributedString(string: "+\(added)", attributes: [.font: font, .foregroundColor: Theme.linesAdded])
        text.append(NSAttributedString(string: " −\(removed ?? 0)", attributes: [.font: font, .foregroundColor: Theme.linesRemoved]))
        return text
    }

    func showAllFiles(_ totals: LineStats) {
        icon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        icon.contentTintColor = Theme.textDim
        iconWidth.constant = 16
        name.stringValue = "All files"
        name.font = .systemFont(ofSize: 12.5, weight: .medium)
        name.textColor = Theme.text
        mark.stringValue = ""
        counts.attributedStringValue = Self.numbers(added: totals.added, removed: totals.removed, binary: false)
        let files = totals.files == 1 ? "1 file" : "\(totals.files) files"
        toolTip = "Every changed file’s diff on one page"
        setAccessibilityLabel("All files, \(files), \(totals.added) lines added, \(totals.removed) removed")
    }

    func showFolder(_ title: String, path: String) {
        icon.image = nil
        iconWidth.constant = 0
        name.stringValue = title
        name.font = .systemFont(ofSize: 12.5)
        name.textColor = Theme.textDim
        mark.stringValue = ""
        counts.stringValue = ""
        toolTip = path
        setAccessibilityLabel("Folder \(path)")
    }

    func show(_ file: ChangedFile, root: String) {
        icon.image = FileIcons.icon(for: URL(fileURLWithPath: root).appendingPathComponent(file.path), size: 16)
        icon.contentTintColor = nil
        iconWidth.constant = 16
        name.stringValue = (file.path as NSString).lastPathComponent
        name.font = .systemFont(ofSize: 12.5)
        name.textColor = file.status == .deleted ? Theme.textDim : Theme.text
        mark.stringValue = Self.mark(file.status) ?? ""
        mark.textColor = GitFileCell.color(file.status)
        counts.attributedStringValue = Self.numbers(added: file.added, removed: file.removed, binary: file.isBinary)
        let from = file.oldPath.map { ", renamed from \($0)" } ?? ""
        toolTip = file.path + from
        let lines = file.isBinary ? "binary" : file.added.map { "\($0) lines added, \(file.removed ?? 0) removed" } ?? ""
        setAccessibilityLabel("\(file.path), \(Self.describe(file.status))\(from)" + (lines.isEmpty ? "" : ", " + lines))
    }
}

/// A scope row: All changes or Uncommitted (with counts when known), or a commit: its subject, then its
/// short hash, author and date, dimmed.
final class GitDiffScopeCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GitDiffScope")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let counts = NSTextField(labelWithString: "")
    private var titleCentre: NSLayoutConstraint!
    private var titleTop: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        Typography.singleLine(title, truncation: .byTruncatingTail)
        Typography.singleLine(detail, truncation: .byTruncatingTail)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = Theme.textDim
        counts.setContentHuggingPriority(.required, for: .horizontal)
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [title, detail, counts] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        titleCentre = title.centerYAnchor.constraint(equalTo: centerYAnchor)
        titleTop = title.topAnchor.constraint(equalTo: topAnchor, constant: 5)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: counts.leadingAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            counts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            counts.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ row: GitDiffListView.ScopeRow) {
        title.font = .systemFont(ofSize: 12.5)
        title.textColor = Theme.text
        detail.isHidden = true
        counts.attributedStringValue = NSAttributedString()
        titleTop.isActive = false
        titleCentre.isActive = true
        switch row {
        case let .all(stats), let .uncommitted(stats):
            let isAll: Bool
            if case .all = row { isAll = true } else { isAll = false }
            title.stringValue = isAll ? "All changes" : "Uncommitted"
            title.font = .systemFont(ofSize: 12.5, weight: .medium)
            if let stats { counts.attributedStringValue = GitDiffFileCell.numbers(added: stats.added, removed: stats.removed, binary: false) }
            toolTip = isAll ? "Everything this branch changed since it parted from its base, committed or not" : "Changes not committed yet, staged or not"
            setAccessibilityLabel(title.stringValue)
        case let .commit(commit):
            titleCentre.isActive = false
            titleTop.isActive = true
            title.stringValue = commit.subject
            detail.isHidden = false
            detail.stringValue = "\(commit.shortSHA) · \(commit.authorName) · \(GitLogStyle.dateText(commit.authorDate))"
            toolTip = "\(commit.subject)\n\(commit.shortSHA) by \(commit.authorName), \(GitLogStyle.fullDate(commit.authorDate))"
            setAccessibilityLabel("\(commit.subject), \(commit.shortSHA), \(commit.authorName), \(GitLogStyle.dateText(commit.authorDate))")
        case let .note(text):
            title.stringValue = text
            title.textColor = Theme.textDim
            title.font = .systemFont(ofSize: 12)
            toolTip = text
            setAccessibilityLabel(text)
        }
    }
}
