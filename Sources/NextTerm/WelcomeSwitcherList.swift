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
    /// Each project's colour, by path (View › Project Color): none while Show Project Colors is off.
    private var colors: [String: ProjectColor] = [:]
    private var openCount = 0
    private var keys: SwitcherKeys = .standard
    /// Where each server's tabs open, by its id, for its row's tooltip.
    private var folders: [String: String] = [:]
    /// The jumps' modifiers are held (⌘, or as rebound): the first nine projects show their jump key in their branch's
    /// place.
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
              folders: [String: String], colors: [String: ProjectColor]) {
        self.shown = shown
        self.folders = folders
        self.openCount = openCount
        self.branches = branches
        self.colors = colors
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

    /// Whether the selected row is in view, wholly or in part.
    var selectedRowVisible: Bool {
        let row: Int = table.selectedRow
        return row >= 0 && table.rows(in: table.visibleRect).contains(row)
    }

    /// Selects the entry at `index` in `shown.entries` and, unless `scrolls` is false, scrolls it into view; nil leaves
    /// no row selected.
    func select(_ index: Int?, scrolls: Bool = true) {
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
        guard scrolls else { return }
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
        cell.show(project, branch: branches[project.path], home: home, jump: jump, color: colors[project.path])
        cell.showsJump = showsJumps
        return cell
    }

    /// The jumps' modifiers held or let go: the project rows in view show their jump key, or their branch again.
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

    /// For the self-test: the PROJECTS heading's count as drawn ("3 open"), nil while it shows none or the heading is
    /// not listed.
    var headingCount: String? {
        guard let row = rows.firstIndex(of: .projectsHeading) else { return nil }
        let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? SwitcherHeaderCell
        return cell?.countText
    }

    /// For the self-test: the row of the project at `index` in `shown.projects`, made if it is out of view.
    func projectCell(at index: Int) -> SwitcherProjectCell? {
        guard index < shown.projects.count, let row = rows.firstIndex(of: .entry(index)) else { return nil }
        return table.view(atColumn: 0, row: row, makeIfNecessary: true) as? SwitcherProjectCell
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

    /// The title a project has in its window, a linked worktree's "xCloud ▸ 7027-sso", else the folder's name, from the
    /// repository read from git's files (WorktreeWindow.repository). Off the main thread, as the branches are read.
    nonisolated static func title(ofProject path: String, repository: WorktreeWindow.Repository?) -> String {
        let folder: String = (path as NSString).lastPathComponent
        guard let repository else { return folder }
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

/// What a row's window shows of its agents, at the right of the row's second line: each mark its terminals show, drawn
/// as the tab bar draws it (StatusDotView, without the amber pulse: the list is looked at, not watched; a lost
/// connection as RemoteMarkView), with how many show it when more than one ("2"). The row says it to VoiceOver in words.
final class SwitcherMarksView: NSStackView {
    private(set) var shown: [AgentMarks.Mark] = []
    #if DEBUG
    /// For the self-test: the marks' dots as they are drawn.
    var dotsForTest: [StatusDotView] { arrangedSubviews.compactMap { $0 as? StatusDotView } }
    #endif
    private var counts: [NSTextField] = []
    /// The server marks, in the row's secondary colour as the counts are.
    private var links: [RemoteMarkView] = []

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ marks: [AgentMarks.Mark], color: NSColor) {
        for count in counts { count.textColor = color }
        for link in links { link.tint = color }
        guard marks != shown else { return }
        shown = marks
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        counts = []
        links = []
        for mark in marks {
            let view: NSView = mark.disconnected ? link(color) : dot(mark.state)
            addArrangedSubview(view)
            guard mark.count > 1 else { continue }
            let count = NSTextField(labelWithString: "\(mark.count)")
            count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            count.textColor = color
            count.setAccessibilityElement(false)
            addArrangedSubview(count)
            setCustomSpacing(3, after: view)
            counts.append(count)
        }
        isHidden = marks.isEmpty
    }

    private func dot(_ state: TabState) -> StatusDotView {
        let dot = StatusDotView()
        dot.pulsesForAttention = false
        dot.turnsWhileWorking = false // the list is looked at, not watched
        dot.state = state
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        dot.setAccessibilityElement(false)
        return dot
    }

    /// A lost connection: the server with its barred red dot, as on the tab.
    private func link(_ color: NSColor) -> RemoteMarkView {
        let mark = RemoteMarkView()
        mark.link = .disconnected
        mark.tint = color
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.widthAnchor.constraint(equalToConstant: RemoteMarkView.size.width).isActive = true
        mark.heightAnchor.constraint(equalToConstant: RemoteMarkView.size.height).isActive = true
        links.append(mark)
        return mark
    }
}

/// A project in the Welcome list: a dot in the gutter in the project's colour (View › Project Color; dim without one, as
/// its repository's for a worktree), filled while a window has it open and a ring while none does (open is said by the
/// dot only, the name keeps its weight and colour), its name, its branch at the right, and below the folder it is in,
/// with "2 windows" after it when more than one window has it, and at the right the marks of its agents. While the
/// jumps' modifiers are held its jump key ("⌘1") shows in its branch's place. A window's own row is laid out the same:
/// the window's title for a name; for a window with no project a terminal or a server in the gutter, and "No project"
/// or the server's destination for a folder.
final class SwitcherProjectCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SwitcherProjectCell")
    static let secondaryFont = NSFont.systemFont(ofSize: 11)
    private let dot = NSView()
    /// A window with no project's mark, in the dot's place.
    private let symbol = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")
    private let branch = NSTextField(labelWithString: "")
    private let jump = NSTextField(labelWithString: "")
    private let marks = SwitcherMarksView()
    private var project: SwitcherProject?
    private var dotColor: NSColor = Theme.textDim
    private var branchName: String?
    private var folderName = ""

    /// The jumps' modifiers are held: the jump key shows instead of the branch.
    var showsJump = false {
        didSet { showJumpOrBranch() }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        dot.wantsLayer = true
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
        // The marks are never cut: the folder gives way to them.
        marks.setContentCompressionResistancePriority(.required, for: .horizontal)
        symbol.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        symbol.contentTintColor = Theme.textDim
        symbol.isHidden = true
        for view in [dot, symbol, name, folder, branch, jump, marks] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityElement(false) // the cell says it all
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.centerXAnchor.constraint(equalTo: leadingAnchor, constant: SwitcherRowStyle.gutterCenter),
            dot.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            symbol.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            marks.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            marks.centerYAnchor.constraint(equalTo: folder.centerYAnchor),
            folder.trailingAnchor.constraint(lessThanOrEqualTo: marks.leadingAnchor, constant: -8),
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

    func show(_ project: SwitcherProject, branch head: String?, home: String, jump key: String?, color: ProjectColor?) {
        self.project = project
        branchName = head
        folderName = SwitcherText.folder(of: project, home: home)
        name.stringValue = project.title
        dotColor = color?.swatchColor ?? Theme.textDim
        // Filled: open in a window. A ring: closed.
        dot.layer?.backgroundColor = project.isOpen ? dotColor.cgColor : NSColor.clear.cgColor
        dot.layer?.borderColor = dotColor.cgColor
        dot.layer?.borderWidth = project.isOpen ? 0 : 1
        // A window with no project: a terminal, or a server for one whose tab in front is on a server.
        let kind: WindowKind? = project.window?.kind
        let mark: String? = kind == .server ? "server.rack" : kind == .plain ? "terminal" : nil
        symbol.image = mark.flatMap { (name: String) -> NSImage? in
            NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }
        symbol.isHidden = mark == nil
        dot.isHidden = mark != nil
        jump.stringValue = key ?? ""
        paintSecondary()
        showJumpOrBranch()
        var tip: String = project.path.isEmpty ? project.title : project.path
        if !project.isOpen, let used = project.lastUsed { tip += "\nLast used " + SessionStore.when(used) }
        toolTip = tip
        let working: Bool = AgentSpinner.current != .off
        setAccessibilityLabel(SwitcherText.accessibilityLabel(project, branch: head, home: home, working: working))
        let help: String = project.window != nil ? "Go to this window" : project.isOpen ? "Go to its window" : "Open it"
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
        symbol.contentTintColor = color
        // A working agent's mark only while View › Agent Spinner shows one, as on the tab bar.
        marks.show(project.marks.shown(working: AgentSpinner.current != .off), color: color)
    }

    /// For the self-test: what the row shows.
    var shownName: String { name.stringValue }
    var shownFolder: String { folder.stringValue }
    /// The dot is filled: a window has the project open.
    var showsOpenDot: Bool { !dot.isHidden && dot.layer?.borderWidth == 0 }
    /// The dot's colour: the project's swatch, or `textDim` without one.
    var shownDotColor: NSColor { dotColor }
    var shownJump: String? { jump.isHidden ? nil : jump.stringValue }
    var shownBranch: String? { branch.isHidden ? nil : branch.stringValue }
    /// The marks shown at the right of the second line, in their order.
    var shownMarks: [AgentMarks.Mark] { marks.isHidden ? [] : marks.shown }
    /// A window with no project's terminal or server shows in the gutter, in the dot's place.
    var shownSymbol: Bool { !symbol.isHidden }

    /// For the self-test: how far below the name's baseline the folder's is, as laid out (about 15 pt: 136 percent of
    /// the second line's 11 pt).
    var baselineGap: CGFloat {
        layoutSubtreeIfNeeded()
        let nameBase: CGFloat = baseline(of: name)
        let folderBase: CGFloat = baseline(of: folder)
        return isFlipped ? folderBase - nameBase : nameBase - folderBase
    }

    private func baseline(of label: NSTextField) -> CGFloat {
        let offset: CGFloat = label.firstBaselineOffsetFromTop
        return isFlipped ? label.frame.minY + offset : label.frame.maxY - offset
    }
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
        setAccessibilityLabel(SwitcherText.accessibilityLabel(server))
        setAccessibilityHelp("Opens a tab on this server")
    }
}
