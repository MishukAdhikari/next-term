import AppKit
import NextTermCore

/// ⌘P: open any file in the project by typing a few letters of its name or path. The list follows each
/// keystroke; ↑ ↓ choose, Return opens, Esc closes. `name:42` opens at line 42.
final class GoToFileController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    /// Opens a file (absolute path) at a 1-based line and column.
    var onOpen: ((_ path: String, _ line: Int?, _ column: Int) -> Void)?

    private let panel: GoToFilePanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let footer = NSTextField(labelWithString: "")
    private var root = ""
    private var recent: [String] = []

    private struct Row {
        let path: String // relative to root
        let positions: [Int]
    }
    private var rows: [Row] = []

    /// One file list per folder, shared by every window, refreshed each time ⌘P opens.
    private final class Catalog: @unchecked Sendable {
        let index: FuzzyIndex
        let complete: Bool
        init(index: FuzzyIndex, complete: Bool) { self.index = index; self.complete = complete }
        /// Its paths as a set, made the first time a search asks (searches run one at a time, on `queue`).
        private var members: Set<String>?
        func contains(_ path: String) -> Bool {
            let set = members ?? Set(index.paths)
            members = set
            return set.contains(path)
        }
    }
    nonisolated(unsafe) private static var catalogs: [String: Catalog] = [:]
    private static let queue = DispatchQueue(label: "nextterm.go-to-file", qos: .userInitiated)
    private static let git = GitRunner.locateGit()
    private var catalog: Catalog?
    /// Each keystroke's search; a newer one makes older results stale.
    private var generation = 0
    /// The last search, so a longer query only looks through what the shorter one found.
    private var last: (query: String, catalog: Catalog, matches: [FuzzyIndex.Match])?

    static let rowHeight: CGFloat = 40
    static let width: CGFloat = 640
    static let visibleRows = 10

    override init() {
        panel = GoToFilePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        build()
    }

    // MARK: showing

    /// `query`: text to start with (the selection); it is selected, so typing replaces it.
    func show(root: String, recent: [String], query: String? = nil, over parent: NSWindow) {
        self.root = canonicalPath(root)
        self.recent = recent
        field.stringValue = query ?? ""
        last = nil
        catalog = Self.catalogs[self.root]
        position(over: parent)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        refreshRows()
        reloadCatalog()
    }

    func close() {
        generation += 1
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }

    private func position(over parent: NSWindow) {
        let height = 52 + Self.rowHeight * CGFloat(Self.visibleRows) + 30
        let frame = parent.frame
        let width = min(Self.width, frame.width - 40)
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - 72 - height, width: width, height: height), display: false)
    }

    /// The project's files: git's list (tracked and new, without ignored files), else a quick walk.
    private func reloadCatalog() {
        let root = self.root
        Self.queue.async { [weak self] in
            let paths: [String]
            var complete = true
            if Self.git != nil, FileManager.default.fileExists(atPath: (ProjectRoot.find(from: root) as NSString).appendingPathComponent(".git")) {
                paths = ProjectSearch.files(in: root, git: Self.git)
            } else {
                (paths, complete) = FileWalker.files(in: root)
            }
            let old = Self.catalogs[root]
            if let old, old.index.paths == paths {
                DispatchQueue.main.async { self?.catalogReady(old, for: root) }
                return
            }
            let catalog = Catalog(index: FuzzyIndex(paths: paths), complete: complete)
            DispatchQueue.main.async {
                Self.catalogs[root] = catalog
                self?.catalogReady(catalog, for: root)
            }
        }
    }

    private func catalogReady(_ catalog: Catalog, for root: String) {
        guard root == self.root, panel.isVisible, catalog !== self.catalog else { return }
        self.catalog = catalog
        last = nil
        refreshRows()
    }

    // MARK: searching

    /// "Main.php:42:5" → ("Main.php", 42, 5).
    static func parse(_ text: String) -> (query: String, line: Int?, column: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: #":(\d+)(:(\d+))?$"#, options: .regularExpression) else { return (trimmed, nil, 1) }
        let numbers = trimmed[range].split(separator: ":").compactMap { Int($0) }
        return (String(trimmed[..<range.lowerBound]), numbers.first, numbers.count > 1 ? numbers[1] : 1)
    }

    private func refreshRows() {
        generation += 1
        let token = generation
        guard let catalog else {
            rows = []
            table.reloadData()
            footer.stringValue = "Listing the project’s files…"
            return
        }
        let query = Self.parse(field.stringValue).query
        let recent = self.recent
        let root = self.root
        let previous = last
        Self.queue.async { [weak self] in
            let index = catalog.index
            var rows: [Row]
            var matches: [FuzzyIndex.Match] = []
            let opened = RecentFiles(recent, root: root, inCatalog: catalog.contains, isFile: isRegularFile)
            var extraFound = 0
            if FuzzyIndex.normalize(query).isEmpty {
                // Nothing typed: the files you opened lately, newest first.
                rows = opened.listed.map { Row(path: $0, positions: []) }
            } else {
                var among: [Int]?
                if let previous, previous.catalog === catalog, query.hasPrefix(previous.query), !previous.query.isEmpty {
                    among = previous.matches.map(\.index)
                }
                guard let found = index.search(query, among: among, cancelled: { [weak self] in
                    // Stale once another keystroke came in.
                    DispatchQueue.main.sync { self?.generation != token }
                }) else { return }
                matches = found
                // Files you opened lately rank a little higher.
                let boosted = Set(recent.compactMap { $0.hasPrefix(root + "/") ? String($0.dropFirst(root.count + 1)) : nil })
                let ranked = found.map { match in
                    boosted.contains(index.paths[match.index]) ? FuzzyIndex.Match(index: match.index, score: match.score + 12) : match
                }
                let best = index.sorted(ranked, limit: 200)
                rows = best.map { Row(path: index.paths[$0.index], positions: index.positions(of: query, in: $0.index)) }
                // The files you opened that the catalog leaves out, ranked among the rest as recent files.
                let extra = FuzzyIndex(paths: opened.outside)
                let extraBest = extra.sorted(extra.search(query) ?? [], limit: 200)
                extraFound = extraBest.count
                if !extraBest.isEmpty {
                    var merged: [Row] = []
                    var next = 0
                    for match in extraBest {
                        while next < best.count && best[next].score >= match.score + 12 {
                            merged.append(rows[next])
                            next += 1
                        }
                        merged.append(Row(path: extra.paths[match.index], positions: extra.positions(of: query, in: match.index)))
                    }
                    rows = Array((merged + rows[next...]).prefix(200))
                }
            }
            let extraCount = opened.outside.count
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.last = query.isEmpty ? nil : (query, catalog, matches)
                self.rows = rows
                self.table.reloadData()
                if !rows.isEmpty {
                    self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    self.table.scrollRowToVisible(0)
                }
                let total = NumberFormatter.localizedString(from: NSNumber(value: index.paths.count + extraCount), number: .decimal)
                if query.isEmpty {
                    self.footer.stringValue = rows.isEmpty ? "\(total) files" : "Recently opened · \(total) files"
                } else {
                    let found = NumberFormatter.localizedString(from: NSNumber(value: matches.count + extraFound), number: .decimal)
                    self.footer.stringValue = "\(found) of \(total) files" + (catalog.complete ? "" : " (the first \(total) found)")
                }
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) { refreshRows() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(by: Self.visibleRows)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(by: -Self.visibleRows)
        case #selector(NSResponder.insertNewline(_:)): openSelected()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        let row = max(0, min(rows.count - 1, (table.selectedRow < 0 ? 0 : table.selectedRow) + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(row) else { return NSSound.beep() }
        let (_, line, column) = Self.parse(field.stringValue)
        let path = (root as NSString).appendingPathComponent(rows[row].path)
        close()
        guard isRegularFile(path) else { return NSSound.beep() } // deleted since the list was made
        onOpen?(path, line, column)
    }

    /// For the self-test: what the list shows now.
    var shownPaths: [String] { rows.map(\.path) }
    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue; refreshRows() }
    }
    var footerText: String { footer.stringValue }
    var panelWindow: NSWindow { panel }
    func openFirst() {
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        openSelected()
    }

    // MARK: layout

    private func build() {
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.appearance = NSAppearance(named: .darkAqua)

        // The app's own dark surface (a system material washes out to grey over the dark theme).
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
        field.font = .systemFont(ofSize: 16)
        field.textColor = Theme.text
        field.placeholderAttributedString = NSAttributedString(string: "Go to file: name, path, or name:line", attributes: [
            .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.placeholderTextColor,
        ])
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel("Go to file")

        let rule = NSBox()
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = WorkSplitView.line

        let column = NSTableColumn(identifier: .init("file"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(openSelected)
        table.refusesFirstResponder = true
        table.setAccessibilityLabel("Files")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = Theme.textDim
        footer.lineBreakMode = .byTruncatingTail
        let hints = NSTextField(labelWithString: "↑↓ choose   ↩ open   esc close")
        hints.font = .systemFont(ofSize: 11)
        hints.textColor = Theme.textDim

        for view in [glass, field, rule, scroll, footer, hints] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            glass.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            glass.widthAnchor.constraint(equalToConstant: 16),
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            rule.topAnchor.constraint(equalTo: background.topAnchor, constant: 51),
            rule.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: hints.leadingAnchor, constant: -12),
            hints.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            hints.firstBaselineAnchor.constraint(equalTo: footer.firstBaselineAnchor),
        ])
        column.width = Self.width
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GoToFileRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: GoToFileCell.identifier, owner: self) as? GoToFileCell ?? GoToFileCell()
        let item = rows[row]
        cell.show(path: item.path, positions: item.positions, root: root)
        return cell
    }

    // MARK: window

    func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere dismisses it, as a menu would.
        if panel.isVisible { close() }
    }
}

/// The chosen row: a rounded highlight inside the panel's margins, in the editor's selection blue.
final class GoToFileRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(hex: 0x2E436E).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5).fill()
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

/// A borderless panel that can still take the keyboard.
final class GoToFilePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// One result: the file's icon, its name with the typed letters picked out, and its folder below.
final class GoToFileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GoToFileCell")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.lineBreakMode = .byTruncatingMiddle
        folder.lineBreakMode = .byTruncatingHead // the end of a folder path says the most
        for view in [icon, name, folder] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            folder.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            folder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            folder.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var shown: (path: String, positions: [Int], root: String)?

    /// On the chosen row the picked-out letters turn white: blue on the blue highlight would not read.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if let shown, backgroundStyle != oldValue { show(path: shown.path, positions: shown.positions, root: shown.root) } }
    }

    func show(path: String, positions: [Int], root: String) {
        shown = (path, positions, root)
        let chosen = backgroundStyle == .emphasized
        let utf8 = Array(path.utf8)
        let nameStart = (utf8.lastIndex(of: UInt8(ascii: "/")).map { $0 + 1 }) ?? 0
        let marked = Set(positions)
        name.attributedStringValue = Self.text(utf8[nameStart...], offset: nameStart, marked: marked,
                                               font: .systemFont(ofSize: 13), color: Theme.text,
                                               markFont: .systemFont(ofSize: 13, weight: .semibold),
                                               markColor: chosen ? .white : NSColor(hex: 0x6EA4F7))
        let folderBytes = nameStart > 0 ? utf8[..<(nameStart - 1)] : []
        folder.attributedStringValue = folderBytes.isEmpty
            ? NSAttributedString(string: "project root", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.textDim])
            : Self.text(folderBytes, offset: 0, marked: marked, font: .systemFont(ofSize: 11), color: Theme.textDim,
                        markFont: .systemFont(ofSize: 11, weight: .semibold), markColor: Theme.text)
        icon.image = FileIcons.icon(for: URL(fileURLWithPath: (root as NSString).appendingPathComponent(path)))
        toolTip = path
        setAccessibilityLabel(path)
    }

    /// The bytes as text, with the matched ones in the mark style (a character is marked if any of its bytes is).
    private static func text(_ bytes: ArraySlice<UInt8>, offset: Int, marked: Set<Int>, font: NSFont, color: NSColor,
                             markFont: NSFont, markColor: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var i = bytes.startIndex
        while i < bytes.endIndex {
            // One character: a lead byte and its continuation bytes.
            var j = i + 1
            while j < bytes.endIndex, bytes[j] & 0xC0 == 0x80 { j += 1 }
            let character = String(decoding: bytes[i..<j], as: UTF8.self)
            let isMarked = (i..<j).contains { marked.contains($0) }
            _ = offset
            result.append(NSAttributedString(string: character, attributes: [
                .font: isMarked ? markFont : font, .foregroundColor: isMarked ? markColor : color,
            ]))
            i = j
        }
        return result
    }
}
