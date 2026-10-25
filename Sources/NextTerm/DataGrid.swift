import AppKit
import NextTermCore

/// The rows of the SQLite viewer and of the data head view. NSTableView selects rows; this adds a current
/// cell, the selected row (its last, under a multiple selection) at `currentColumn`, outlined. A click
/// sets both; ↑↓ move the row as ever and ←→ the column; ↩ and Space go to the host. ⌘C copies the
/// selected rows the host's way.
final class DatabaseGridView: NSTableView {
    var onCopy: (() -> Void)?
    /// ↩ was pressed in the grid.
    var onEnter: (() -> Void)?
    /// Space was pressed in the grid.
    var onSpace: (() -> Void)?
    /// The current cell moved (a click, an arrow, a new selection), at most once per run-loop turn.
    var onCurrentCellChange: (() -> Void)?
    /// A click on a cell, after it made the cell current: its click count (2 for a double-click).
    var onClickCell: ((Int) -> Void)?
    /// The first column the current cell can be in (the head view's line number is not a value).
    var firstValueColumn = 0
    /// The column of the current cell, or -1 before there is one.
    private(set) var currentColumn = -1
    private var outlined: (row: Int, column: Int)?
    private var changeQueued = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        // Space shows the detail pane rather than typing a row's first letters.
        allowsTypeSelect = false
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: NSTableView.selectionDidChangeNotification, object: self)
    }

    @objc func copy(_ sender: Any?) { onCopy?() }

    /// The current cell: the selected row at the current column, when both are there.
    var currentCell: (row: Int, column: Int)? {
        let row = selectedRow
        guard row >= 0, row < numberOfRows, currentColumn >= firstValueColumn, currentColumn < numberOfColumns else { return nil }
        return (row, currentColumn)
    }

    /// Makes `column` current (and `row`, when given), as a click would.
    func setCurrent(row: Int? = nil, column: Int) {
        if let row, row >= 0, row < numberOfRows, !selectedRowIndexes.contains(row) || selectedRow != row {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let clamped = numberOfColumns == 0 ? -1 : min(max(column, firstValueColumn), numberOfColumns - 1)
        guard clamped != currentColumn || row != nil else { return }
        currentColumn = clamped
        cellMoved()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let column = column(at: point)
        if column >= firstValueColumn, row(at: point) >= 0, column != currentColumn {
            currentColumn = column
            cellMoved()
        }
        super.mouseDown(with: event)
        if column >= firstValueColumn, row(at: point) >= 0 { onClickCell?(event.clickCount) }
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        switch event.keyCode {
        case 123 where plain, 124 where plain: // ← →
            guard numberOfColumns > 0, numberOfRows > 0 else { return super.keyDown(with: event) }
            if selectedRow < 0 { selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            let start = currentColumn < firstValueColumn ? firstValueColumn : currentColumn + (event.keyCode == 123 ? -1 : 1)
            let next = min(max(start, firstValueColumn), numberOfColumns - 1)
            if next != currentColumn {
                currentColumn = next
                cellMoved()
            }
            scrollColumnToVisible(next)
        case 36 where plain, 76 where plain: // ↩, Enter
            guard let onEnter else { return super.keyDown(with: event) }
            onEnter()
        case 49 where plain: // Space
            guard let onSpace else { return super.keyDown(with: event) }
            onSpace()
        default:
            super.keyDown(with: event)
        }
    }

    @objc private func selectionChanged() { cellMoved() }

    /// Outlines the new current cell (redrawing only it and the one before) and tells the host once this turn.
    private func cellMoved() {
        let now = currentCell
        if outlined?.row != now?.row || outlined?.column != now?.column {
            if let old = outlined { gridCell(row: old.row, column: old.column)?.isCurrent = false }
            if let now { gridCell(row: now.row, column: now.column)?.isCurrent = true }
            outlined = now
        }
        guard !changeQueued else { return }
        changeQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changeQueued = false
            self.onCurrentCellChange?()
        }
    }

    /// After the columns change: the current cell stays in range, or goes.
    func columnsChanged() {
        if currentColumn >= numberOfColumns { currentColumn = numberOfColumns - 1 }
        if numberOfColumns == 0 { currentColumn = -1 }
        outlined = nil
        cellMoved()
    }

    private func gridCell(row: Int, column: Int) -> GridCellView? {
        guard row >= 0, row < numberOfRows, column >= 0, column < numberOfColumns else { return nil }
        return view(atColumn: column, row: row, makeIfNecessary: false) as? GridCellView
    }

    /// A cell for `tableColumn` at `row`, reused when one is free, outlined when it is the current one.
    func cell(for tableColumn: NSTableColumn?, row: Int) -> GridCellView {
        let cell = GridCellView.make(in: self)
        let column = tableColumn.map { tableColumns.firstIndex(of: $0) ?? -1 } ?? -1
        cell.isCurrent = currentCell.map { $0.row == row && $0.column == column } ?? false
        if cell.isCurrent { outlined = (row, column) }
        return cell
    }
}

/// One cell of a data grid, and of the detail pane's row list: one line of text that never draws past
/// its row. CellText.line turns line breaks and control characters into marks, and the cell clips, so
/// even a string that slipped past would stay inside it.
final class GridCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("gridCell")
    static let font = Theme.monoFont(size: 12)
    static let dimFont = NSFontManager.shared.convert(Theme.monoFont(size: 12), toHaveTrait: .italicFontMask)

    let label = NSTextField(labelWithString: "")
    /// Outlined: the grid's current cell.
    var isCurrent = false {
        didSet { if isCurrent != oldValue { needsDisplay = true } }
    }

    /// A free cell of `tableView`, or a new one.
    static func make(in tableView: NSTableView) -> GridCellView {
        tableView.makeView(withIdentifier: identifier, owner: nil) as? GridCellView ?? GridCellView()
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        if #available(macOS 14, *) { clipsToBounds = true }
        Typography.singleLine(label, truncation: .byTruncatingTail)
        label.font = Self.font
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `text` on one line (CellText.line), ending in "…" when it was cut short on read.
    func configure(text: String, color: NSColor = Theme.terminalForeground, font: NSFont = GridCellView.font, cut: Bool = false) {
        label.stringValue = CellText.line(text, cut: cut)
        label.textColor = color
        label.font = font
        label.toolTip = nil
    }

    /// A SQLite value: NULL and a blob dim and italic.
    func configure(_ value: SQLiteValue) {
        switch value {
        case .null, .blob: configure(text: value.display, color: Theme.textDim, font: Self.dimFont)
        case let .text(text, truncated): configure(text: text, cut: truncated)
        default: configure(text: value.display)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isCurrent else { return }
        Theme.accent.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
        path.lineWidth = 2
        path.stroke()
    }
}
