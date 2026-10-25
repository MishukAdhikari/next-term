import AppKit
import NextTermCore

/// Edit › Go to Heading… in a Markdown file: its headings, indented by level, narrowed as you type a few of their
/// letters (as Go to File narrows paths); ↑ ↓ choose, Return jumps, Esc closes. Below them, the file's words, characters
/// and reading time, or the selection's when there is one.
final class GoToHeadingController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    /// Goes to a heading's line (0-based).
    var onJump: ((_ line: Int) -> Void)?

    private let panel = GoToFilePanel(contentRect: NSRect(x: 0, y: 0, width: GoToFileController.width, height: 100),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
    private let field = NSTextField()
    private let table = NSTableView()
    private let footer = NSTextField(labelWithString: "")
    private var headings: [MarkdownOutline.Heading] = []
    private var titles = FuzzyIndex(paths: [])
    private var rows: [(heading: MarkdownOutline.Heading, positions: [Int])] = []

    static let rowHeight: CGFloat = 28

    override init() {
        super.init()
        build()
    }

    func show(headings: [MarkdownOutline.Heading], stats: MarkdownOutline.Stats, ofSelection: Bool, over parent: NSWindow) {
        self.headings = headings
        // Titles go in as paths would, so a "/" in one is no folder to the matcher (a space is as long).
        titles = FuzzyIndex(paths: headings.map { $0.title.replacingOccurrences(of: "/", with: " ") })
        field.stringValue = ""
        footer.stringValue = (ofSelection ? "Selection: " : "") + Self.summary(stats)
        let height = 52 + Self.rowHeight * 12 + 30
        let frame = parent.frame
        let width = min(GoToFileController.width, frame.width - 40)
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - 72 - height, width: width, height: height), display: false)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        refreshRows()
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }

    /// "1,240 words · 7,830 characters · 6 min".
    static func summary(_ stats: MarkdownOutline.Stats) -> String {
        func count(_ value: Int, _ one: String, _ many: String) -> String {
            NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal) + " " + (value == 1 ? one : many)
        }
        return [count(stats.words, "word", "words"), count(stats.characters, "character", "characters"), "\(stats.minutes) min"]
            .joined(separator: " · ")
    }

    /// Every heading in order, or those the typed letters are in, best first.
    private func refreshRows() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        if FuzzyIndex.normalize(query).isEmpty {
            rows = headings.map { ($0, []) }
        } else {
            let found = titles.sorted(titles.search(query) ?? [], limit: 500)
            rows = found.map { (headings[$0.index], titles.positions(of: query, in: $0.index)) }
        }
        table.reloadData()
        if !rows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    func controlTextDidChange(_ obj: Notification) { refreshRows() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(by: 12)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(by: -12)
        case #selector(NSResponder.insertNewline(_:)): jumpToSelected()
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

    @objc private func jumpToSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(row) else { return NSSound.beep() }
        let line = rows[row].heading.line
        close()
        onJump?(line)
    }

    /// For the self-test.
    var shownTitles: [String] { rows.map(\.heading.title) }
    var footerText: String { footer.stringValue }
    var query: String {
        get { field.stringValue }
        set {
            field.stringValue = newValue
            refreshRows()
        }
    }
    func jumpToFirst() {
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        jumpToSelected()
    }

    // MARK: layout

    private func build() {
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.appearance = NSAppearance(named: .darkAqua)
        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = Theme.bar.cgColor
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = WorkSplitView.line.cgColor
        panel.contentView = background

        let mark = NSImageView(image: NSImage(systemSymbolName: "list.bullet.indent", accessibilityDescription: nil) ?? NSImage())
        mark.contentTintColor = Theme.textDim
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16)
        field.textColor = Theme.text
        field.placeholderAttributedString = NSAttributedString(string: "Go to heading", attributes: [
            .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.placeholderTextColor,
        ])
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel("Go to heading")

        let rule = NSBox()
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = WorkSplitView.line

        let column = NSTableColumn(identifier: .init("heading"))
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
        table.action = #selector(jumpToSelected)
        table.refusesFirstResponder = true
        table.setAccessibilityLabel("Headings")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = Theme.textDim
        footer.lineBreakMode = .byTruncatingTail
        let hints = NSTextField(labelWithString: "↑↓ choose   ↩ go   esc close")
        hints.font = .systemFont(ofSize: 11)
        hints.textColor = Theme.textDim

        for view in [mark, field, rule, scroll, footer, hints] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            mark.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: 16),
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 10),
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
        column.width = GoToFileController.width
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GoToFileRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: GoToHeadingCell.identifier, owner: self) as? GoToHeadingCell ?? GoToHeadingCell()
        cell.show(rows[row].heading, positions: rows[row].positions)
        return cell
    }

    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible { close() }
    }
}

/// One heading: its title, indented by its level, with the typed letters picked out, and its line number at the right.
final class GoToHeadingCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GoToHeadingCell")
    private let title = NSTextField(labelWithString: "")
    private let line = NSTextField(labelWithString: "")
    private var indent: NSLayoutConstraint?
    private var shown: (heading: MarkdownOutline.Heading, positions: [Int])?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.lineBreakMode = .byTruncatingTail
        line.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        line.textColor = Theme.textDim
        line.alignment = .right
        for view in [title, line] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let indent = title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
        self.indent = indent
        NSLayoutConstraint.activate([
            indent,
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: line.leadingAnchor, constant: -12),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        line.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if let shown, backgroundStyle != oldValue { show(shown.heading, positions: shown.positions) } }
    }

    func show(_ heading: MarkdownOutline.Heading, positions: [Int]) {
        shown = (heading, positions)
        indent?.constant = 16 + CGFloat(heading.level - 1) * 16
        let weight: NSFont.Weight = heading.level <= 2 ? .semibold : .regular
        let marked = Set(positions)
        let chosen = backgroundStyle == .emphasized
        let text = NSMutableAttributedString()
        let utf8 = Array(heading.title.utf8)
        var i = 0
        while i < utf8.count {
            var j = i + 1
            while j < utf8.count, utf8[j] & 0xC0 == 0x80 { j += 1 }
            let isMarked = (i..<j).contains { marked.contains($0) }
            text.append(NSAttributedString(string: String(decoding: utf8[i..<j], as: UTF8.self), attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: isMarked ? .bold : weight),
                .foregroundColor: isMarked ? (chosen ? NSColor.white : NSColor(hex: 0x6EA4F7)) : Theme.text,
            ]))
            i = j
        }
        title.attributedStringValue = text
        line.stringValue = "\(heading.line + 1)"
        setAccessibilityLabel("Heading \(heading.level): \(heading.title), line \(heading.line + 1)")
    }
}
