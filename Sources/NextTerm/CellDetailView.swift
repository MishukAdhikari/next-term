import AppKit
import NextTermCore

/// One line of the detail pane's row list: a column and its value in the selected row.
struct DetailRowItem: Equatable {
    var name: String
    var text: String
    var dim = false
    /// Cut short on read: it ends in "…".
    var cut = false

    /// A SQLite value as a grid cell shows it.
    init(name: String, value: SQLiteValue) {
        self.name = name
        switch value {
        case .null, .blob:
            text = value.display
            dim = true
        case let .text(value, truncated):
            text = value
            cut = truncated
        default:
            text = value.display
        }
    }

    init(name: String, text: String, dim: Bool = false, cut: Bool = false) {
        self.name = name
        self.text = text
        self.dim = dim
        self.cut = cut
    }
}

/// The whole value of the grid's current cell, beside the grid: the column and what kind of value it is,
/// the value in a text view (wrapped, selectable, its control characters shown, ⌘F to find in it), and
/// below a thin divider the selected row as a list of column: value lines. Copy copies the value as
/// stored. The SQLite viewer and the data head view both show their cells here.
final class CellDetailView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate {
    static let defaultWidth: CGFloat = 340
    static let minimumWidth: CGFloat = 260

    private let titleLabel = NSTextField(labelWithString: "")
    private let kindLabel = NSTextField(labelWithString: "")
    let textView = DetailTextView()
    private let textScroll = NSScrollView()
    let rowList = NSTableView()
    private let listScroll = NSScrollView()
    private let split = NSSplitView()
    let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    let noteLabel = NSTextField(wrappingLabelWithString: "")
    let footer = NSStackView()
    private var didPlaceDivider = false

    private(set) var detail: CellDetail?
    private(set) var items: [DetailRowItem] = []
    private(set) var currentItem = -1

    /// A line of the row list was clicked: that column becomes the current cell.
    var onSelectColumn: ((Int) -> Void)?
    /// Esc in the value: back to the grid.
    var onEscape: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        build()
        show(nil, items: [], current: -1)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = Theme.text
        Typography.singleLine(titleLabel, truncation: .byTruncatingMiddle)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        kindLabel.font = .systemFont(ofSize: 11)
        kindLabel.textColor = Theme.textDim
        Typography.singleLine(kindLabel, truncation: .byTruncatingTail)
        kindLabel.setContentCompressionResistancePriority(.init(740), for: .horizontal)
        let header = NSStackView(views: [titleLabel, kindLabel, NSView()])
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        header.wantsLayer = true
        header.layer?.backgroundColor = Theme.bar.cgColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.allowsUndo = false
        textView.font = Theme.monoFont(size: 12)
        textView.textColor = Theme.terminalForeground
        textView.backgroundColor = Theme.background
        textView.insertionPointColor = Theme.caret
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.showsControlCharacters = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.onEscape = { [weak self] in self?.onEscape?() }
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.drawsBackground = true
        textScroll.backgroundColor = Theme.background

        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.width = 110
        nameColumn.minWidth = 50
        let valueColumn = NSTableColumn(identifier: .init("value"))
        valueColumn.width = 200
        valueColumn.minWidth = 60
        rowList.addTableColumn(nameColumn)
        rowList.addTableColumn(valueColumn)
        rowList.headerView = nil
        rowList.rowHeight = 20
        rowList.intercellSpacing = NSSize(width: 6, height: 2)
        rowList.backgroundColor = Theme.background
        rowList.usesAlternatingRowBackgroundColors = false
        rowList.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        rowList.allowsTypeSelect = false
        rowList.dataSource = self
        rowList.delegate = self
        rowList.target = self
        rowList.action = #selector(rowClicked)
        rowList.setAccessibilityLabel("The selected row")
        listScroll.documentView = rowList
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = true
        listScroll.backgroundColor = Theme.background

        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(textScroll)
        split.addArrangedSubview(listScroll)

        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.font = .systemFont(ofSize: 11)
        copyButton.target = self
        copyButton.action = #selector(copyValue)
        copyButton.toolTip = "Copy the value as it is stored"
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = Theme.textDim
        noteLabel.maximumNumberOfLines = 3
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footer.setViews([noteLabel, NSView(), copyButton], in: .leading)
        footer.spacing = 6
        footer.alignment = .centerY
        footer.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        footer.wantsLayer = true
        footer.layer?.backgroundColor = Theme.bar.cgColor

        for view in [header, split, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),
            split.topAnchor.constraint(equalTo: header.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])
    }

    override func layout() {
        super.layout()
        if !didPlaceDivider, split.bounds.height > 200 {
            didPlaceDivider = true
            split.setPosition(round(split.bounds.height * 0.6), ofDividerAt: 0)
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 60 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(60, splitView.bounds.height - 44)
    }
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { view === textScroll }

    /// Shows a cell's value, and its row (`items`, with `current` the cell's column), or "click a cell".
    func show(_ detail: CellDetail?, items: [DetailRowItem], current: Int) {
        let sameValue = detail?.body == self.detail?.body && detail?.isNull == self.detail?.isNull
        self.detail = detail
        guard let detail else {
            titleLabel.stringValue = "No cell"
            kindLabel.stringValue = ""
            setBody("Click a cell to see its whole value here.", dim: true)
            textView.setAccessibilityLabel("Value")
            copyButton.isEnabled = false
            showNote(nil)
            setItems(items, current: current)
            return
        }
        titleLabel.stringValue = detail.title
        titleLabel.toolTip = detail.declaredType.isEmpty ? detail.title : "\(detail.title) (declared \(detail.declaredType))"
        kindLabel.stringValue = detail.kind
        if !sameValue { setBody(detail.body, dim: detail.isNull || detail.isBlob) }
        textView.setAccessibilityLabel("Value of \(detail.title)")
        copyButton.isEnabled = detail.copyText != nil
        showNote(detail.note)
        setItems(items, current: current)
    }

    private func setBody(_ text: String, dim: Bool) {
        let font = dim && !(detail?.isBlob ?? false) ? GridCellView.dimFont : Theme.monoFont(size: 12)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: dim ? Theme.textDim : Theme.terminalForeground]
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        textView.typingAttributes = attributes
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
    }

    func showNote(_ note: String?) {
        noteLabel.stringValue = note ?? ""
        noteLabel.isHidden = note == nil
    }

    private func setItems(_ items: [DetailRowItem], current: Int) {
        if items != self.items {
            self.items = items
            currentItem = current
            rowList.reloadData()
        }
        if current != currentItem || rowList.selectedRow != current {
            currentItem = current
            if items.indices.contains(current) {
                rowList.selectRowIndexes(IndexSet(integer: current), byExtendingSelection: false)
                rowList.scrollRowToVisible(current)
            } else {
                rowList.deselectAll(nil)
            }
        }
    }

    /// The keyboard goes into the value.
    func focusValue() {
        window?.makeFirstResponder(textView)
    }

    @objc func copyValue() {
        guard let text = detail?.copyText else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func rowClicked() {
        let row = rowList.clickedRow
        guard items.indices.contains(row) else { return }
        onSelectColumn?(row)
    }

    // MARK: the row list

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = GridCellView.make(in: tableView)
        guard items.indices.contains(row) else { return cell }
        let item = items[row]
        if tableColumn?.identifier.rawValue == "name" {
            cell.configure(text: item.name, color: Theme.textDim)
        } else {
            cell.configure(text: item.text, color: item.dim ? Theme.textDim : Theme.terminalForeground,
                           font: item.dim ? GridCellView.dimFont : GridCellView.font, cut: item.cut)
        }
        cell.setAccessibilityLabel("\(item.name): \(CellText.line(item.text, limit: 200, cut: item.cut))")
        return cell
    }
}

/// The detail's value: Esc goes back to the grid.
final class DetailTextView: NSTextView {
    var onEscape: (() -> Void)?
    /// Esc does nothing (while an edit has changes, so one key can't lose it).
    var keepsEscape = false

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            if keepsEscape { return NSSound.beep() }
            if let onEscape { return onEscape() }
        }
        super.keyDown(with: event)
    }
}

/// The viewers' split: their table list (the SQLite viewer's), the grid, and the detail pane on the right.
/// The grid takes what the window gives and keeps at least 240 points; the list and the detail keep their
/// widths. The detail starts hidden, shows at its own width (340 points, at least 260) and keeps the width
/// it was given while the tab is open, hidden and shown again.
final class DataSplitView: NSSplitView, NSSplitViewDelegate {
    static let minimumGridWidth: CGFloat = 240

    let list: NSView?
    let grid: NSView
    let detail: CellDetailView
    /// The header's button that shows and hides the detail.
    let toggle = NSButton()
    /// The detail was shown or hidden.
    var onShownChange: (() -> Void)?
    private var listWidth: CGFloat = 190
    private var detailWidth = CellDetailView.defaultWidth
    private var didPlaceList = false

    init(list: NSView?, grid: NSView, detail: CellDetailView) {
        self.list = list
        self.grid = grid
        self.detail = detail
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        delegate = self
        if let list { addArrangedSubview(list) }
        addArrangedSubview(grid)
        addArrangedSubview(detail)
        detail.isHidden = true
        toggle.bezelStyle = .regularSquare
        toggle.isBordered = false
        toggle.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Value Pane")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        toggle.target = self
        toggle.action = #selector(toggleClicked)
        showToggle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var isDetailShown: Bool { !detail.isHidden }
    private var detailDivider: Int { list == nil ? 0 : 1 }

    /// Shows or hides the detail, at the width it had.
    func setDetailShown(_ shown: Bool) {
        guard shown != isDetailShown else { return }
        detail.isHidden = !shown
        adjustSubviews()
        if shown, bounds.width > 0 {
            let width = min(detailWidth, max(CellDetailView.minimumWidth, bounds.width - (list?.frame.width ?? 0) - Self.minimumGridWidth))
            setPosition(bounds.width - width - dividerThickness, ofDividerAt: detailDivider)
        }
        showToggle()
        onShownChange?()
    }

    @objc private func toggleClicked() { setDetailShown(!isDetailShown) }

    private func showToggle() {
        toggle.contentTintColor = isDetailShown ? Theme.accent : Theme.textDim
        toggle.toolTip = isDetailShown ? "Hide the value pane (Space)" : "Show the selected cell’s whole value (Space)"
        toggle.setAccessibilityLabel(isDetailShown ? "Hide Value Pane" : "Show Value Pane")
    }

    override func layout() {
        super.layout()
        if list != nil, !didPlaceList, bounds.width > 400 {
            didPlaceList = true
            setPosition(listWidth, ofDividerAt: 0)
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if list != nil, dividerIndex == 0 { return 120 }
        return (list.map { $0.frame.maxX + dividerThickness } ?? 0) + Self.minimumGridWidth
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if list != nil, dividerIndex == 0 {
            let detail = isDetailShown ? CellDetailView.minimumWidth + dividerThickness : 0
            return max(120, bounds.width - Self.minimumGridWidth - detail)
        }
        return bounds.width - CellDetailView.minimumWidth - dividerThickness
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { view === grid }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        if let list, didPlaceList, list.frame.width > 0 { listWidth = list.frame.width }
        if isDetailShown, detail.frame.width >= CellDetailView.minimumWidth { detailWidth = detail.frame.width }
    }
}
