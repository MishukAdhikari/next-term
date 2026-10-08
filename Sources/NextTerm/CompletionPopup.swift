import AppKit
import NextTermCore

/// Tab completion's list: a borderless panel at the caret, a child of the terminal's window, that never
/// takes the keyboard. The terminal keeps the first responder, the caret, input methods and VoiceOver's
/// focus; the window's CompletionController moves the selection and picks rows. Each row is the name with the
/// letters typed picked out, a folder or file symbol, and zsh's description when it gave one.
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// A row clicked.
    var onPick: ((Int) -> Void)?

    private let panel: CompletionPanel
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private var rows: [CompletionList.Row] = []
    private(set) var loading = false
    private(set) var selected = 0

    static let rowHeight: CGFloat = 22
    static let visibleRows = 10
    static let minWidth: CGFloat = 200
    static let maxWidth: CGFloat = 560
    static let footerHeight: CGFloat = 22
    static let nameFont = NSFont.systemFont(ofSize: 13)
    static let markFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let descriptionFont = NSFont.systemFont(ofSize: 12)

    override init() {
        panel = CompletionPanel(contentRect: NSRect(x: 0, y: 0, width: Self.minWidth, height: 100),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        build()
    }

    var isVisible: Bool { panel.isVisible }
    var window: NSWindow { panel }
    /// For the self-test and VoiceOver: the names listed, in order.
    var shownTexts: [String] { rows.map(\.text) }
    var footerText: String { footer.isHidden ? "" : footer.stringValue }

    // MARK: showing

    /// Shows `rows` (or the Loading row) under the word starting at `anchor`, the screen rectangle of the
    /// word's first cell, over `parent`. The selection stays on its row while the rows are the same.
    func show(_ rows: [CompletionList.Row], loading: Bool, footer note: String?, anchor: NSRect, over parent: NSWindow) {
        let changed = rows != self.rows || loading != self.loading
        self.rows = rows
        self.loading = loading
        if changed {
            selected = 0
            table.reloadData()
        }
        footer.stringValue = note ?? ""
        footer.isHidden = note == nil
        place(at: anchor, over: parent)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.appearance = parent.appearance
        panel.orderFront(nil)
        if !rows.isEmpty { select(selected, announce: false) }
    }

    func hide() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        rows = []
        loading = false
    }

    /// Moves the selection by `delta` rows, stopping at the ends.
    func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        select(max(0, min(rows.count - 1, selected + delta)), announce: true)
    }

    private func select(_ row: Int, announce: Bool) {
        selected = row
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        if announce { Self.announce("\(Self.spoken(rows[row])), \(row + 1) of \(rows.count)") }
    }

    /// The panel's size for the rows, and its place: under the word on the caret's row, above it when there
    /// is no room below, and on the caret's screen.
    private func place(at anchor: NSRect, over parent: NSWindow) {
        let width = Self.width(for: rows, loading: loading)
        let shown = loading ? 1 : min(max(rows.count, 1), Self.visibleRows)
        let height = CGFloat(shown) * Self.rowHeight + 8 + (footer.isHidden ? 0 : Self.footerHeight)
        let screen = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? parent.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 10_000, height: 10_000)
        var origin = NSPoint(x: anchor.minX - 10, y: anchor.minY - height - 2)
        if origin.y < screen.minY { origin.y = anchor.maxY + 2 } // flip above the caret's row
        origin.x = max(screen.minX, min(origin.x, screen.maxX - width))
        origin.y = max(screen.minY, min(origin.y, screen.maxY - height))
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        layout(NSSize(width: width, height: height))
        panel.contentView?.needsDisplay = true
    }

    /// Wide enough for the longest of the first rows, within bounds.
    static func width(for rows: [CompletionList.Row], loading: Bool) -> CGFloat {
        if loading { return minWidth }
        var widest: CGFloat = 0
        for row in rows.prefix(200) {
            var width = (row.text as NSString).size(withAttributes: [.font: markFont]).width
            if !row.description.isEmpty {
                width += 24 + min(240, (row.description as NSString).size(withAttributes: [.font: descriptionFont]).width)
            }
            widest = max(widest, width)
        }
        return max(minWidth, min(maxWidth, widest + 16 + 22 + 24))
    }

    // MARK: VoiceOver

    static func spoken(_ row: CompletionList.Row) -> String {
        let kind = row.isFolder ? (row.dimmed ? "folder, can't be opened" : "folder") : "file"
        return row.description.isEmpty ? "\(row.text), \(kind)" : "\(row.text), \(kind), \(row.description)"
    }

    /// Opening the list, said once.
    func announceOpen() {
        guard let first = rows.first else { return Self.announce("Loading completions") }
        Self.announce("\(rows.count) completion\(rows.count == 1 ? "" : "s"), \(Self.spoken(first))")
    }

    static func announce(_ text: String) {
        let element: Any = NSApp.keyWindow ?? NSApp as Any
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: layout

    private func build() {
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.setAccessibilityLabel("Completions")

        // The app's own dark surface, as Go to File's (a system material washes out over the dark theme).
        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = Theme.bar.cgColor
        background.layer?.cornerRadius = 7
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = WorkSplitView.line.cgColor
        panel.contentView = background

        let column = NSTableColumn(identifier: .init("completion"))
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
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        table.setAccessibilityLabel("Completions")
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = Theme.textDim
        footer.lineBreakMode = .byTruncatingTail

        background.addSubview(scroll)
        background.addSubview(footer)
    }

    /// The list above the footer (when it shows), inside the panel's margins.
    private func layout(_ size: NSSize) {
        let footerRoom = footer.isHidden ? 0 : Self.footerHeight
        footer.frame = NSRect(x: 12, y: 3, width: size.width - 24, height: Self.footerHeight - 6)
        scroll.frame = NSRect(x: 0, y: 4 + footerRoom, width: size.width, height: size.height - 8 - footerRoom)
        table.tableColumns.first?.width = size.width
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        onPick?(row)
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { loading ? 1 : rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GoToFileRowView() }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !loading }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: CompletionCell.identifier, owner: self) as? CompletionCell ?? CompletionCell()
        if loading {
            cell.showLoading()
        } else {
            cell.show(rows[row])
        }
        return cell
    }

}

/// A panel that never takes the keyboard or the main window.
final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One completion: a folder or file symbol, the name with the typed letters picked out (cut in the middle
/// when long; the whole name in the tooltip), and zsh's description, dimmer, at the end.
final class CompletionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CompletionCell")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var shown: CompletionList.Row?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.lineBreakMode = .byTruncatingTail
        detail.font = CompletionPopup.descriptionFont
        detail.textColor = Theme.textDim
        detail.alignment = .right
        detail.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        icon.imageScaling = .scaleProportionallyDown
        for view in [icon, name, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 16),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// On the chosen row the picked-out letters turn white: blue on the blue highlight would not read.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if let shown, backgroundStyle != oldValue { show(shown) } }
    }

    func show(_ row: CompletionList.Row) {
        shown = row
        let chosen = backgroundStyle == .emphasized
        let text = NSMutableAttributedString()
        let marked = Set(row.highlights)
        let base = row.dimmed ? Theme.textDim : Theme.text
        for (index, scalar) in row.text.unicodeScalars.enumerated() {
            let isMarked = marked.contains(index)
            text.append(NSAttributedString(string: String(scalar), attributes: [
                .font: isMarked ? CompletionPopup.markFont : CompletionPopup.nameFont,
                .foregroundColor: isMarked ? (chosen ? NSColor.white : NSColor(hex: 0x6EA4F7)) : base,
            ]))
        }
        name.attributedStringValue = text
        detail.stringValue = row.description
        detail.isHidden = row.description.isEmpty
        let symbol = row.isFolder ? "folder" : "doc"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: row.isFolder ? "Folder" : "File")
        icon.contentTintColor = row.isFolder ? NSColor(hex: 0x6EA4F7) : Theme.textDim
        toolTip = row.description.isEmpty ? row.text : "\(row.text) — \(row.description)"
        setAccessibilityLabel(CompletionPopup.spoken(row))
    }

    func showLoading() {
        shown = nil
        name.attributedStringValue = NSAttributedString(string: "Loading…", attributes: [
            .font: CompletionPopup.nameFont, .foregroundColor: Theme.textDim,
        ])
        detail.isHidden = true
        icon.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        icon.contentTintColor = Theme.textDim
        toolTip = nil
        setAccessibilityLabel("Loading completions")
    }
}
