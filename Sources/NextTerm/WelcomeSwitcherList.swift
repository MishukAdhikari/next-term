import AppKit
import NextTermCore

/// The Welcome window's one list: the projects, then the saved servers, under their headings, in one table, so ↑ and ↓
/// cross from the projects into the servers and the selection has one owner. What it lists and in which order is worked
/// out in Core (`SwitcherList`, `SwitcherSearch`); this shows it, and tells the window what the user picked.
final class WelcomeSwitcherList: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// One row of the table: a heading, or an entry of `shown.entries` by its index there.
    enum Row: Equatable {
        case projectsHeading
        case serversHeading
        case entry(Int)
    }

    static let projectRowHeight: CGFloat = 44
    static let serverRowHeight: CGFloat = 28
    static let headingRowHeight: CGFloat = 26

    let table: NSTableView
    private(set) var shown = SwitcherShown(projects: [], servers: [])
    private(set) var rows: [Row] = []
    /// Each project's branch, by path, as far as it is read.
    private var branches: [String: String] = [:]
    private var openCount = 0
    private var keys: SwitcherKeys = .standard
    /// Where each server's tabs open, by its id, for its row's tooltip.
    private var folders: [String: String] = [:]
    /// ⌘ is held: the first nine projects show their jump key in their branch's place.
    private(set) var showsJumps = false
    private let home: String = NSHomeDirectory()
    /// While the window selects a row itself, the table's notice of it is not the user's pick.
    private var selecting = false

    /// The user moved the selection (a click, or the table's own arrows).
    var onSelect: (() -> Void)?
    /// A double-click on a row.
    var onActivate: (() -> Void)?
    /// Remove from List on a closed project's row, by its path: the list may be read again while the menu is up.
    var onForget: ((String) -> Void)?

    init(table: NSTableView) {
        self.table = table
        super.init()
        table.addTableColumn(NSTableColumn(identifier: .init("main")))
        table.headerView = nil
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.floatsGroupRows = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        // A click below the rows keeps the selection, and Return's button with it.
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.setAccessibilityLabel("Projects and servers")
    }

    /// Shows `shown` as the search leaves it. `searching`: text is typed, so a heading shows only over its matches;
    /// with nothing typed the PROJECTS heading stays, over no project at all on a first launch.
    func show(_ shown: SwitcherShown, openCount: Int, searching: Bool, branches: [String: String], keys: SwitcherKeys,
              folders: [String: String]) {
        self.shown = shown
        self.folders = folders
        self.openCount = openCount
        self.branches = branches
        self.keys = keys
        var rows: [Row] = []
        if !searching || !shown.projects.isEmpty { rows.append(.projectsHeading) }
        for index in shown.projects.indices { rows.append(.entry(index)) }
        if !shown.servers.isEmpty { rows.append(.serversHeading) }
        for index in shown.servers.indices { rows.append(.entry(shown.projects.count + index)) }
        self.rows = rows
        // With the selected row gone, the table selects one of its own (it allows no empty selection): not the user's
        // pick, and the window selects the right one next.
        selecting = true
        defer { selecting = false }
        table.reloadData()
    }

    // MARK: selection

    /// The entry selected, an index in `shown.entries`.
    var selectedIndex: Int? {
        guard case .entry(let index)? = rows[safe: table.selectedRow] else { return nil }
        return index
    }

    var selectedEntry: SwitcherEntry? {
        selectedIndex.flatMap { (index: Int) -> SwitcherEntry? in shown.entries[safe: index] }
    }

    /// Selects the entry at `index` in `shown.entries` and scrolls it into view; nil leaves no row selected.
    func select(_ index: Int?) {
        selecting = true
        defer { selecting = false }
        guard let index, let row = rows.firstIndex(of: .entry(index)) else {
            // A click can't empty the selection; the window can, with nothing listed or matching.
            table.allowsEmptySelection = true
            table.deselectAll(nil)
            table.allowsEmptySelection = false
            return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // The heading over the first row comes into view with it.
        let top: Int = index == 0 || index == shown.projects.count ? max(0, row - 1) : row
        table.scrollRowToVisible(top)
        table.scrollRowToVisible(row)
    }

    /// How many entries a page holds, for Page Up and Page Down: the projects' rows that fit.
    var pageSize: Int {
        let height: CGFloat = table.enclosingScrollView?.contentView.bounds.height ?? table.visibleRect.height
        return max(1, Int(height / Self.projectRowHeight) - 1)
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0, case .entry? = rows[safe: table.clickedRow] else { return }
        onActivate?()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting else { return }
        onSelect?()
    }
}

// MARK: rows

extension WelcomeSwitcherList {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[safe: row] {
        case .entry(let index)?: return index < shown.projects.count ? Self.projectRowHeight : Self.serverRowHeight
        default: return Self.headingRowHeight
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard case .entry? = rows[safe: row] else { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard case .entry? = rows[safe: row] else { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard case .entry? = rows[safe: row] else { return SwitcherHeadingRowView() }
        return GoToFileRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[safe: row] {
        case .projectsHeading?:
            let cell = tableView.makeView(withIdentifier: SwitcherHeaderCell.identifier, owner: self) as? SwitcherHeaderCell
                ?? SwitcherHeaderCell()
            cell.show("Projects", count: SwitcherText.openCount(openCount),
                      accessibility: SwitcherText.heading(openCount: openCount))
            return cell
        case .serversHeading?:
            let cell = tableView.makeView(withIdentifier: SwitcherHeaderCell.identifier, owner: self) as? SwitcherHeaderCell
                ?? SwitcherHeaderCell()
            cell.show("Servers", count: nil, accessibility: "Servers")
            return cell
        case .entry(let index)?:
            if let project = shown.projects[safe: index] { return projectCell(tableView, project, row: index) }
            guard let server = shown.servers[safe: index - shown.projects.count] else { return nil }
            let cell = tableView.makeView(withIdentifier: SwitcherServerCell.identifier, owner: self) as? SwitcherServerCell
                ?? SwitcherServerCell()
            cell.show(server, folder: folders[server.id])
            return cell
        case nil:
            return nil
        }
    }

    private func projectCell(_ tableView: NSTableView, _ project: SwitcherProject, row: Int) -> NSView {
        let cell = tableView.makeView(withIdentifier: SwitcherProjectCell.identifier, owner: self) as? SwitcherProjectCell
            ?? SwitcherProjectCell()
        let jump: String? = keys.jumpHint(row, projects: shown.projects.count)
        cell.show(project, branch: branches[project.path], home: home, jump: jump)
        cell.showsJump = showsJumps
        return cell
    }

    /// ⌘ held or let go: the project rows in view show their jump key, or their branch again.
    func showJumps(_ on: Bool) {
        guard on != showsJumps else { return }
        showsJumps = on
        let visible: NSRange = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SwitcherProjectCell
            cell?.showsJump = on
        }
    }

    // MARK: Remove from List

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard case .entry(let index)? = rows[safe: table.clickedRow], let project = shown.projects[safe: index],
              !project.isOpen else { return }
        let item = NSMenuItem(title: "Remove from List", action: #selector(removeClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = project.path
        item.toolTip = "Leaves the Welcome window and File › Open Recent; the folder stays as it is"
        menu.addItem(item)
    }

    @objc private func removeClicked(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onForget?(path)
    }

    /// The title a project has in its window, read from git's files: a linked worktree's "xCloud ▸ 7027-sso", else
    /// the folder's name. Off the main thread, as the branches are read.
    nonisolated static func title(ofProject path: String) -> String {
        let folder: String = (path as NSString).lastPathComponent
        guard let repository = WorktreeWindow.repository(ofLinkedWorktree: path) else { return folder }
        return WorktreeWindow.title(repository: repository.name, folder: folder)
    }
}

/// A heading's row: no fill, selected or not.
final class SwitcherHeadingRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}

// MARK: - cells

/// What a project's and a server's row share: secondary text a shade lighter on the selection, and the branch mark.
enum SwitcherRowStyle {
    /// Secondary text (folder, branch, destination) on a selected row. `Theme.textDim` is 3.74:1 on the selection's
    /// blue, under the 4.5:1 small text needs; this is 5.10:1.
    static let selectedSecondary = NSColor(hex: 0xB8BBC2)
    static let gutterCenter: CGFloat = 20
    /// Where the names start in a row: the gutter, 14 to 26, then 8.
    static let nameX: CGFloat = 34

    static func secondary(selected: Bool) -> NSColor { selected ? selectedSecondary : Theme.textDim }

    /// "main" after the branch symbol the sidebar and Git Log use, tail truncated, aligned right.
    static func branch(_ name: String, font: NSFont, symbolSize: CGFloat, color: NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let size = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
        let config: NSImage.SymbolConfiguration = size.applying(.init(paletteColors: [color]))
        let symbol: NSImage? = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        if let image = symbol?.withSymbolConfiguration(config) {
            let attachment = NSTextAttachment()
            attachment.image = image
            let y: CGFloat = (font.capHeight - image.size.height) / 2
            attachment.bounds = NSRect(x: 0, y: y, width: image.size.width, height: image.size.height)
            text.append(NSAttributedString(attachment: attachment))
            text.append(Typography.gap(4, font: font))
        }
        text.append(NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: color]))
        return Typography.truncating(text, .byTruncatingTail, alignment: .right)
    }
}

/// A heading row: PROJECTS or SERVERS in small letterspaced capitals, at the column's x 20; at the PROJECTS heading's
/// right end, on its baseline, how many projects are open ("3 open").
final class SwitcherHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SwitcherHeaderCell")
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        // A number that changes in place: tabular figures. Lowercase, so not letterspaced.
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = Theme.textDim
        count.alignment = .right
        Typography.singleLine(count, truncation: .byClipping)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [title, count] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityElement(false) // the cell says it, "Projects, 3 open"
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            count.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ heading: String, count text: String?, accessibility: String) {
        title.attributedStringValue = WelcomeWindowController.headingText(heading)
        count.stringValue = text ?? ""
        count.isHidden = text == nil
        setAccessibilityLabel(accessibility)
    }

    /// For the self-test: what the count says, nil while it is hidden.
    var countText: String? { count.isHidden ? nil : count.stringValue }
}

/// A project in the Welcome list: a green dot in the gutter while a window has it open (open is said by the dot only,
/// the name keeps its weight and colour), its name, its branch at the right, and below the folder it is in, with "2
/// windows" after it when more than one window has it. While ⌘ is held its jump key ("⌘1") shows in its branch's place.
final class SwitcherProjectCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SwitcherProjectCell")
    static let secondaryFont = NSFont.systemFont(ofSize: 11)
    private let dot = NSView()
    private let name = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")
    private let branch = NSTextField(labelWithString: "")
    private let jump = NSTextField(labelWithString: "")
    private var project: SwitcherProject?
    private var branchName: String?
    private var folderName = ""

    /// ⌘ is held: the jump key shows instead of the branch.
    var showsJump = false {
        didSet { showJumpOrBranch() }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        dot.wantsLayer = true
        dot.layer?.backgroundColor = Theme.done.cgColor
        dot.layer?.cornerRadius = 3
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = Theme.text
        Typography.singleLine(name, truncation: .byTruncatingMiddle)
        // The end of a folder path says the most; "2 windows" after it is never cut.
        Typography.singleLine(folder, truncation: .byTruncatingHead)
        Typography.singleLine(branch, truncation: .byTruncatingTail)
        KeyHint.style(jump)
        jump.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        // The name wins: the branch takes what room it leaves.
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        branch.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        jump.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [dot, name, folder, branch, jump] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityElement(false) // the cell says it all
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.centerXAnchor.constraint(equalTo: leadingAnchor, constant: SwitcherRowStyle.gutterCenter),
            dot.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SwitcherRowStyle.nameX),
            name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            name.trailingAnchor.constraint(lessThanOrEqualTo: branch.leadingAnchor, constant: -8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: jump.leadingAnchor, constant: -8),
            branch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            branch.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            jump.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            jump.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            folder.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            folder.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            folder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { paintSecondary() } }
    }

    func show(_ project: SwitcherProject, branch head: String?, home: String, jump key: String?) {
        self.project = project
        branchName = head
        folderName = SwitcherText.folder(of: project, home: home)
        name.stringValue = project.title
        dot.isHidden = !project.isOpen
        jump.stringValue = key ?? ""
        paintSecondary()
        showJumpOrBranch()
        var tip: String = project.path
        if !project.isOpen, let used = project.lastUsed { tip += "\nLast used " + SessionStore.when(used) }
        toolTip = tip
        setAccessibilityLabel(SwitcherText.accessibilityLabel(project, branch: head, home: home))
        let help: String = project.isOpen ? "Go to its window" : "Open it"
        setAccessibilityHelp(key.map { (key: String) -> String in help + " with " + key } ?? help)
    }

    private func showJumpOrBranch() {
        let hint: Bool = showsJump && !jump.stringValue.isEmpty
        jump.isHidden = !hint
        branch.isHidden = hint
    }

    /// The folder, "2 windows" and the branch, in `textDim`, or a shade lighter on the selection.
    private func paintSecondary() {
        guard let project else { return }
        let color: NSColor = SwitcherRowStyle.secondary(selected: backgroundStyle == .emphasized)
        let font: NSFont = Self.secondaryFont
        let line = NSMutableAttributedString(string: folderName, attributes: [.font: font, .foregroundColor: color])
        if let windows = SwitcherText.windows(project) {
            let figures: NSFont = .monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
            line.append(Typography.gap(6, font: font))
            line.append(NSAttributedString(string: windows, attributes: [.font: figures, .foregroundColor: color]))
        }
        folder.attributedStringValue = Typography.truncating(line, .byTruncatingHead)
        let head: String = branchName ?? ""
        branch.attributedStringValue = head.isEmpty ? NSAttributedString()
            : SwitcherRowStyle.branch(head, font: font, symbolSize: 10, color: color)
        jump.textColor = color
    }

    /// For the self-test: what the row shows.
    var shownName: String { name.stringValue }
    var shownFolder: String { folder.stringValue }
    var showsOpenDot: Bool { !dot.isHidden }
    var shownJump: String? { jump.isHidden ? nil : jump.stringValue }
}

/// A saved server in the Welcome list: the server mark in the gutter, its name, and where it points after it.
final class SwitcherServerCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SwitcherServerCell")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let destination = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.contentTintColor = Theme.textDim
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = Theme.text
        Typography.singleLine(name, truncation: .byTruncatingMiddle)
        destination.font = .systemFont(ofSize: 11)
        destination.textColor = Theme.textDim
        Typography.singleLine(destination, truncation: .byTruncatingMiddle)
        destination.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [icon, name, destination] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityElement(false) // the cell says it all
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: SwitcherRowStyle.gutterCenter),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SwitcherRowStyle.nameX),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            destination.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8),
            destination.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            destination.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { destination.textColor = SwitcherRowStyle.secondary(selected: backgroundStyle == .emphasized) }
    }

    /// `folder`: where its tabs open on the server, for the tooltip.
    func show(_ server: SwitcherServer, folder: String?) {
        name.stringValue = server.name
        destination.stringValue = server.destination
        toolTip = "Open a tab on \(server.name) (\(server.destination))" + (folder.map { ", in " + $0 } ?? "")
        setAccessibilityLabel("\(server.name), \(server.destination)")
        setAccessibilityHelp("Opens a tab on this server")
    }
}
