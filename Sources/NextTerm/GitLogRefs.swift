import AppKit
import NextTermCore

/// Branches and tags beside the Git Log: All Branches and HEAD first, then Local in folders by prefix
/// (agents' branches together, as in the branch popup), Remote by remote, and Tags. Selecting one shows
/// its history; the search field above narrows the tree.
final class GitLogRefsView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    final class Node {
        enum Kind { case all, head, group, folder, branch, remote, tag }
        let kind: Kind
        let id: String
        let title: String
        /// What the log shows when this is selected; nil for all branches (and for groups and folders,
        /// which are not selected).
        let ref: String?
        var children: [Node]
        let isCurrent: Bool
        let detail: String

        init(_ kind: Kind, id: String, title: String, ref: String? = nil, children: [Node] = [], isCurrent: Bool = false, detail: String = "") {
            self.kind = kind
            self.id = id
            self.title = title
            self.ref = ref
            self.children = children
            self.isCurrent = isCurrent
            self.detail = detail
        }

        var isSelectable: Bool { kind != .group && kind != .folder }
    }

    /// A branch, tag or HEAD was selected (nil: all branches).
    var onSelect: ((String?) -> Void)?
    private(set) var model: BranchModel?
    private(set) var tags: [String] = []
    private(set) var roots: [Node] = []
    let outline = NSOutlineView()
    let searchField = NSSearchField()
    private let scroll = NSScrollView()
    /// The rows' tooltips, through one area over the rows in view (set up in build()).
    private(set) var rowToolTips: RowToolTips?
    /// Folders open, by id, kept as the tree is read again.
    private var expanded: Set<String> = ["group:local"]
    private var selectedRef: String?
    private var selecting = false
    private var readOnce = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// For the self-test: the rows as shown, indented by depth.
    var rowTitles: [String] {
        (0..<outline.numberOfRows).compactMap { row in
            (outline.item(atRow: row) as? Node).map { String(repeating: "  ", count: outline.level(forRow: row)) + $0.title }
        }
    }

    func update(model: BranchModel?, tags: [String]) {
        self.model = model
        self.tags = tags
        if !readOnce, let current = model?.current {
            readOnce = true
            // The folder of the branch checked out starts open.
            if BranchModel.isAgentBranch(current, worktree: nil) { expanded.insert("folder:local:agents") }
            else if let folder = BranchModel.folder(of: current) { expanded.insert("folder:local:" + folder) }
        }
        rebuild()
    }

    /// Shows which ref the log is on (from the toolbar's Branch filter, say).
    func select(ref: String?) {
        selectedRef = ref
        selecting = true
        defer { selecting = false }
        guard let node = find(ref.map { "ref:" + $0 } ?? "all", in: roots) else { return outline.deselectAll(nil) }
        expandAncestors(of: node)
        let row = outline.row(forItem: node)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    // MARK: tree

    private func rebuild() {
        let filter = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        roots = Self.nodes(model: model, tags: tags, filter: filter)
        outline.reloadData()
        for node in all(roots) where filter.isEmpty ? expanded.contains(node.id) : !node.children.isEmpty {
            outline.expandItem(node)
        }
        select(ref: selectedRef)
        rowToolTips?.update()
    }

    /// The tree for a model and its tags; with a filter, only names containing it (and what holds them).
    static func nodes(model: BranchModel?, tags: [String], filter: String = "") -> [Node] {
        func keep(_ name: String) -> Bool { filter.isEmpty || name.lowercased().contains(filter) }
        let byName = { (a: BranchRef, b: BranchRef) in a.name.localizedStandardCompare(b.name) == .orderedAscending }
        var roots: [Node] = []
        if filter.isEmpty {
            roots.append(Node(.all, id: "all", title: "All Branches"))
            let head = model.map { m in m.current ?? m.headSHA.map { "detached at " + $0.prefix(7) } ?? "" } ?? ""
            roots.append(Node(.head, id: "ref:HEAD", title: "HEAD", ref: "HEAD", detail: head))
        }
        guard let model else { return roots }
        func leaf(_ ref: BranchRef, label: String) -> Node {
            var detail: [String] = []
            if ref.behind > 0 { detail.append("↓\(ref.behind)") }
            if ref.ahead > 0 { detail.append("↑\(ref.ahead)") }
            return Node(ref.isRemote ? .remote : .branch, id: "ref:" + (ref.isRemote ? "refs/remotes/" : "refs/heads/") + ref.name, title: label,
                        ref: (ref.isRemote ? "refs/remotes/" : "refs/heads/") + ref.name, isCurrent: ref.isHead, detail: detail.joined(separator: " "))
        }
        var local: [Node] = []
        if let current = model.currentRef, keep(current.name) { local.append(leaf(current, label: current.name)) }
        let others = model.locals.filter { !$0.isHead && keep($0.name) }
        let agents = others.filter { BranchModel.isAgentBranch($0.name, worktree: $0.worktree) }
        let mine = others.filter { !BranchModel.isAgentBranch($0.name, worktree: $0.worktree) }
        let folders = Dictionary(grouping: mine.filter { BranchModel.folder(of: $0.name) != nil }) { BranchModel.folder(of: $0.name)! }
        for name in folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let members = folders[name]!.sorted(by: byName).map { leaf($0, label: String($0.name.dropFirst(name.count + 1))) }
            local.append(Node(.folder, id: "folder:local:" + name, title: name + "/", children: members, detail: "\(members.count)"))
        }
        local += mine.filter { BranchModel.folder(of: $0.name) == nil }.sorted(by: byName).map { leaf($0, label: $0.name) }
        if !agents.isEmpty {
            local.append(Node(.folder, id: "folder:local:agents", title: "Agent branches", children: agents.sorted(by: byName).map { leaf($0, label: $0.name) },
                              detail: "\(agents.count)"))
        }
        if !local.isEmpty { roots.append(Node(.group, id: "group:local", title: "Local", children: local)) }
        var remote: [Node] = []
        for name in model.remoteNames {
            let members = model.remotes.filter { $0.remote == name && keep($0.name) }.sorted(by: byName).map { leaf($0, label: $0.shortName) }
            if !members.isEmpty { remote.append(Node(.folder, id: "folder:remote:" + name, title: name, children: members, detail: "\(members.count)")) }
        }
        if !remote.isEmpty { roots.append(Node(.group, id: "group:remote", title: "Remote", children: remote)) }
        let tagNodes = tags.filter(keep).map { Node(.tag, id: "ref:refs/tags/" + $0, title: $0, ref: "refs/tags/" + $0) }
        if !tagNodes.isEmpty { roots.append(Node(.group, id: "group:tags", title: "Tags", children: tagNodes, detail: "\(tagNodes.count)")) }
        return roots
    }

    private func all(_ nodes: [Node]) -> [Node] { nodes.flatMap { [$0] + all($0.children) } }

    private func find(_ id: String, in nodes: [Node]) -> Node? {
        for node in nodes {
            if node.id == id { return node }
            if let found = find(id, in: node.children) { return found }
        }
        return nil
    }

    private func expandAncestors(of target: Node) {
        func path(_ nodes: [Node]) -> [Node]? {
            for node in nodes {
                if node === target { return [] }
                if let below = path(node.children) { return [node] + below }
            }
            return nil
        }
        for node in path(roots) ?? [] { outline.expandItem(node) }
    }

    func controlTextDidChange(_ obj: Notification) { rebuild() }

    /// A click on a group or folder opens or closes it.
    @objc private func clicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? Node, !node.isSelectable else { return }
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }

    // MARK: outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Node)?.children.isEmpty ?? true) }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? Node)?.isSelectable ?? false }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { (item as? Node)?.kind == .group ? 26 : 22 }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? Node, searchField.stringValue.isEmpty { expanded.insert(node.id) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? Node, searchField.stringValue.isEmpty { expanded.remove(node.id) }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, let node = outline.item(atRow: outline.selectedRow) as? Node, node.isSelectable else { return }
        selectedRef = node.ref
        onSelect?(node.ref)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let cell = outlineView.makeView(withIdentifier: GitRefCell.identifier, owner: self) as? GitRefCell ?? GitRefCell()
        cell.show(node)
        return cell
    }

    // MARK: layout

    private func build() {
        searchField.placeholderString = "Filter branches and tags"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.setAccessibilityLabel("Filter branches and tags")
        let column = NSTableColumn(identifier: .init("ref"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = Theme.background
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = 14
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.setAccessibilityLabel("Branches and tags")
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.background
        rowToolTips = RowToolTips(outline, in: scroll) { [weak self] row in
            (self?.outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? GitRefCell)?.tipText ?? ""
        }
        for view in [searchField, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

/// One row of the branch tree: an icon, the name, and a count or ahead and behind on the right.
final class GitRefCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GitRef")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var iconWidth: NSLayoutConstraint!
    /// The row's tooltip, shown by the tree for rows in view (see RowToolTips).
    private(set) var tipText = ""

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        Typography.singleLine(title, truncation: .byTruncatingMiddle)
        Typography.singleLine(detail, truncation: .byTruncatingHead)
        detail.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        detail.textColor = Theme.textDim
        detail.alignment = .right
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        for view in [icon, title, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 14)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            icon.heightAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -6),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ node: GitLogRefsView.Node) {
        let symbol: String?
        var tint = Theme.textDim
        switch node.kind {
        case .all: symbol = "square.stack.3d.up"
        case .head: symbol = "smallcircle.filled.circle"; tint = Theme.done
        case .group: symbol = nil
        case .folder: symbol = "folder"
        case .branch: symbol = node.isCurrent ? "checkmark" : "arrow.triangle.branch"; if node.isCurrent { tint = Theme.done }
        case .remote: symbol = "cloud"
        case .tag: symbol = "tag"
        }
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) }
        icon.contentTintColor = tint
        icon.isHidden = symbol == nil
        iconWidth.constant = symbol == nil ? 0 : 14
        if node.kind == .group {
            title.attributedStringValue = NSAttributedString(string: node.title.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: Theme.textDim, .kern: 0.6,
            ])
        } else {
            title.attributedStringValue = NSAttributedString(string: node.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: node.isCurrent || node.kind == .folder ? .medium : .regular), .foregroundColor: Theme.text,
            ])
        }
        detail.stringValue = node.detail
        tipText = node.ref.map { $0 == "HEAD" ? "HEAD: " + node.detail : $0 } ?? ""
        setAccessibilityLabel([node.title, node.detail].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}
