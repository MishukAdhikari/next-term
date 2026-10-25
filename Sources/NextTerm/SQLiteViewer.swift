import AppKit
import NextTermCore

/// A SQLite file in an editor tab, read-only: its tables on the left, a page of 1,000 rows in the middle,
/// and the current cell's whole value on the right (CellDetailView). Everything is read off the main
/// thread through SQLiteReader, which never writes. Rows copy as CSV, JSON or Markdown, and go to the
/// agent the way files do (⌥⌘K).
final class DatabasePane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var url: URL
    var path: String { url.path }
    var name: String { url.lastPathComponent }
    var onTitleChange: (() -> Void)?
    /// Send to Agent was clicked.
    var onSendToAgent: (([ContextItem]) -> Void)?

    private let header = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let copyAs = NSPopUpButton(frame: .zero, pullsDown: true)
    private let sendButton = NSButton(title: "Send to Agent", target: nil, action: nil)
    private var sendTip: ShortcutToolTip?
    let tableList = NSTableView()
    let grid = DatabaseGridView()
    let detail = CellDetailView()
    private let listScroll = NSScrollView()
    private let gridScroll = NSScrollView()
    private let right = NSView()
    private lazy var split = DataSplitView(list: listScroll, grid: right, detail: detail)
    private let pageLabel = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private let message = NSTextField(wrappingLabelWithString: "")

    private(set) var tables: [SQLiteTable] = []
    private(set) var selectedTable: String?
    private(set) var page: SQLitePage?
    private(set) var total: Int?
    private(set) var loadError: String?
    private(set) var isLoading = false
    private(set) var isDeletedOnDisk = false
    private let queue = DispatchQueue(label: "me.mishuk.nextterm.sqlite-viewer", qos: .userInitiated)
    private var generation = 0
    private var stamps: [FileStamp?] = []
    /// Values read whole by their row's key (a text cut at 10,000 characters on the page), until the
    /// page is read again.
    private var wholeValues: [CellKey: SQLiteValue] = [:]
    /// Moves on with every current cell, so a whole value read for a cell left behind is not shown.
    private var detailToken = 0
    #if DEBUG
    /// For the self-test: how many values were read whole.
    private(set) var fetches = 0
    #endif

    struct CellKey: Hashable {
        let key: SQLiteRowKey
        let column: String
    }

    /// For the self-test: nothing is being read.
    var isSettled: Bool { !isLoading }
    var focusView: NSView { grid }

    init(url: URL) {
        self.url = URL(fileURLWithPath: canonicalPath(url.path))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        build()
        reloadTables()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: building

    private func build() {
        Typography.singleLine(titleLabel, truncation: .byTruncatingMiddle)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = Theme.textDim
        Typography.singleLine(summary, truncation: .byTruncatingTail)
        summary.setContentCompressionResistancePriority(.init(740), for: .horizontal)
        showTitle()

        copyAs.controlSize = .small
        copyAs.font = .systemFont(ofSize: 11)
        (copyAs.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        copyAs.toolTip = "Copy the selected rows, or the whole page when none are selected"
        copyAs.addItem(withTitle: "Copy As")
        for (title, action) in [("CSV", #selector(copyCSV)), ("JSON", #selector(copyJSON)), ("Markdown", #selector(copyMarkdown))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            copyAs.menu?.addItem(item)
        }
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .small
        sendButton.font = .systemFont(ofSize: 11)
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        sendTip = ShortcutToolTip(sendButton, "Send the selected rows to the agent in this window", #selector(TerminalWindowController.sendToAgent(_:)))
        header.setViews([titleLabel, summary, NSView(), split.toggle, copyAs, sendButton], in: .leading)
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        header.wantsLayer = true
        header.layer?.backgroundColor = Theme.bar.cgColor

        let listColumn = NSTableColumn(identifier: .init("table"))
        listColumn.resizingMask = .autoresizingMask
        tableList.addTableColumn(listColumn)
        tableList.headerView = nil
        tableList.style = .sourceList
        tableList.backgroundColor = Theme.bar
        tableList.rowHeight = 22
        tableList.dataSource = self
        tableList.delegate = self
        tableList.setAccessibilityLabel("Tables")
        listScroll.documentView = tableList
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = true
        listScroll.backgroundColor = Theme.bar

        grid.dataSource = self
        grid.delegate = self
        grid.allowsMultipleSelection = true
        grid.allowsColumnReordering = false
        grid.usesAlternatingRowBackgroundColors = false
        grid.backgroundColor = Theme.background
        grid.gridColor = Theme.bar
        grid.gridStyleMask = [.solidVerticalGridLineMask]
        grid.rowHeight = 20
        grid.intercellSpacing = NSSize(width: 6, height: 2)
        grid.columnAutoresizingStyle = .noColumnAutoresizing
        grid.setAccessibilityLabel("Rows")
        grid.onCopy = { [weak self] in self?.copy(TableExport.csv) }
        grid.onCurrentCellChange = { [weak self] in self?.showCurrentCell() }
        grid.onClickCell = { [weak self] _ in self?.showDetail(true) }
        grid.onSpace = { [weak self] in self?.toggleDetail() }
        grid.onEnter = { [weak self] in self?.enterValue() }
        split.onShownChange = { [weak self] in self?.showCurrentCell() }
        detail.onSelectColumn = { [weak self] column in
            guard let self else { return }
            self.grid.setCurrent(column: column)
            self.grid.scrollColumnToVisible(column)
        }
        detail.onEscape = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.grid)
        }
        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true
        gridScroll.hasHorizontalScroller = true
        gridScroll.autohidesScrollers = true
        gridScroll.drawsBackground = true
        gridScroll.backgroundColor = Theme.background

        pageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        pageLabel.textColor = Theme.textDim
        for (button, symbol, label, action) in [(previous, "chevron.left", "Previous Page", #selector(previousPage)),
                                                (next, "chevron.right", "Next Page", #selector(nextPage))] {
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            button.contentTintColor = Theme.textDim
            button.toolTip = label
            button.target = self
            button.action = action
        }
        let footer = NSStackView(views: [pageLabel, NSView(), previous, next])
        footer.spacing = 6
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        footer.wantsLayer = true
        footer.layer?.backgroundColor = Theme.bar.cgColor
        for view in [gridScroll, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            right.addSubview(view)
        }
        NSLayoutConstraint.activate([
            gridScroll.topAnchor.constraint(equalTo: right.topAnchor),
            gridScroll.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            gridScroll.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            gridScroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: right.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 26),
        ])

        message.textColor = Theme.textDim
        message.alignment = .center
        message.isHidden = true
        for view in [header, split, message] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            split.topAnchor.constraint(equalTo: header.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
            message.centerYAnchor.constraint(equalTo: split.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
        ])
    }

    private func showTitle() {
        let text = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Theme.text])
        text.append(Typography.gap(8, font: .systemFont(ofSize: 12)))
        text.append(NSAttributedString(string: RecentProjects.abbreviate(url.deletingLastPathComponent().path),
                                       attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.textDim]))
        titleLabel.attributedStringValue = Typography.truncating(text, .byTruncatingMiddle)
        titleLabel.toolTip = path
    }

    /// "SQLite · 4 tables · read-only", or what is wrong.
    private func showSummary() {
        var parts = ["SQLite"]
        let count = tables.filter { !$0.isView }.count, views = tables.count - count
        if !tables.isEmpty || loadError == nil { parts.append(count == 1 ? "1 table" : "\(count) tables") }
        if views > 0 { parts.append(views == 1 ? "1 view" : "\(views) views") }
        if isLoading { parts.append("reading…") }
        parts.append(isDeletedOnDisk ? "deleted on disk" : "read-only")
        summary.stringValue = parts.joined(separator: " · ")
        summary.textColor = isDeletedOnDisk ? Theme.linesRemoved : Theme.textDim
        summary.toolTip = "Opened read-only. Nothing here writes to the file."
        if let page, let total {
            let first = page.rows.isEmpty ? 0 : page.offset + 1
            pageLabel.stringValue = total == 0 ? "No rows" : "Rows \(first.formatted())–\((page.offset + page.rows.count).formatted()) of \(total.formatted())"
        } else {
            pageLabel.stringValue = ""
        }
        previous.isEnabled = (page?.offset ?? 0) > 0
        next.isEnabled = page.map { $0.offset + $0.rows.count < (total ?? 0) } ?? false
    }

    // MARK: reading

    /// Lists the tables again (the file changed, or it was just opened), keeping the table and page in view.
    func reloadTables() {
        generation += 1
        let token = generation, path = self.path
        isLoading = true
        showSummary()
        queue.async { [weak self] in
            let stamps = Self.stamps(path)
            let result = Result { try SQLiteReader.tables(at: path) }
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.stamps = stamps
                self.isDeletedOnDisk = stamps.first == nil
                switch result {
                case let .success(tables):
                    self.tables = tables
                    self.loadError = nil
                    self.tableList.reloadData()
                    let keep = self.selectedTable.flatMap { name in tables.firstIndex { $0.name == name } }
                    if let index = keep ?? (tables.isEmpty ? nil : 0) {
                        self.tableList.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                        self.load(tables[index].name, offset: keep != nil ? self.page?.offset ?? 0 : 0)
                    } else {
                        self.isLoading = false
                        self.show(nil, total: nil, error: tables.isEmpty ? "This database has no tables yet." : nil)
                    }
                case let .failure(error):
                    self.isLoading = false
                    self.loadError = DatabaseMask.redact(error.localizedDescription)
                    if !self.isDeletedOnDisk { self.tables = []; self.tableList.reloadData(); self.show(nil, total: nil, error: self.loadError) }
                }
                self.showSummary()
                self.onTitleChange?()
            }
        }
    }

    /// A page of a table, and how many rows it has.
    func load(_ table: String, offset: Int) {
        generation += 1
        let token = generation, path = self.path
        selectedTable = table
        isLoading = true
        showSummary()
        queue.async { [weak self] in
            let result = Result { () throws -> (SQLitePage, Int) in
                let total = try SQLiteReader.count(table, at: path)
                let start = min(offset, max(0, (total - 1) / SQLiteReader.pageSize * SQLiteReader.pageSize))
                return (try SQLiteReader.page(table, at: path, offset: start), total)
            }
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.isLoading = false
                switch result {
                case let .success((page, total)): self.show(page, total: total, error: nil)
                case let .failure(error): self.show(nil, total: nil, error: DatabaseMask.redact(error.localizedDescription))
                }
                self.showSummary()
            }
        }
    }

    private func show(_ page: SQLitePage?, total: Int?, error: String?) {
        let sameColumns = page?.columns == self.page?.columns && page?.table == self.page?.table
        // The current cell's row, by its key, to find again on the page read now (rows may have come before it).
        let kept = currentCellKey
        self.page = page
        self.total = total
        wholeValues = [:]
        if !sameColumns { rebuildColumns() }
        grid.reloadData()
        if !sameColumns { grid.scrollRowToVisible(0) }
        if let kept, let page, page.table == kept.table {
            if let row = page.row(for: kept.cell.key) {
                grid.setCurrent(row: row, column: page.columns.firstIndex(of: kept.cell.column) ?? grid.currentColumn)
            } else {
                grid.deselectAll(nil)
            }
        }
        message.stringValue = error ?? ""
        message.isHidden = error == nil
        showCurrentCell()
    }

    private func rebuildColumns() {
        grid.tableColumns.forEach(grid.removeTableColumn)
        guard let page else { return }
        let font = Theme.monoFont(size: 12)
        let charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        for (i, name) in page.columns.enumerated() {
            let column = NSTableColumn(identifier: .init("c\(i)"))
            column.title = name
            column.headerToolTip = name
            let longest = page.rows.prefix(50).map { min(40, $0[i].display.count) }.max() ?? 0
            column.width = min(320, max(60, CGFloat(max(longest, name.count)) * charWidth + 16))
            column.minWidth = 40
            grid.addTableColumn(column)
        }
        grid.columnsChanged()
    }

    private static func stamps(_ path: String) -> [FileStamp?] { [FileStamp(path: path), FileStamp(path: path + "-wal")] }

    /// The file changed on disk (a migration ran, an agent wrote to it): read it again. About once a second.
    func refreshIfChanged() {
        guard !isLoading else { return }
        let now = Self.stamps(path)
        guard now != stamps else { return }
        if now.first == nil {
            stamps = now
            isDeletedOnDisk = true
            return showSummary()
        }
        reloadTables()
    }

    /// The file was renamed or moved in the sidebar.
    func moved(to newURL: URL) {
        url = URL(fileURLWithPath: canonicalPath(newURL.path))
        stamps = Self.stamps(path)
        isDeletedOnDisk = stamps.first == nil
        showTitle()
        showSummary()
        onTitleChange?()
    }

    @objc private func previousPage() {
        guard let table = selectedTable, let page else { return }
        load(table, offset: max(0, page.offset - SQLiteReader.pageSize))
    }

    @objc private func nextPage() {
        guard let table = selectedTable, let page else { return }
        load(table, offset: page.offset + SQLiteReader.pageSize)
    }

    // MARK: copying and sending

    /// The selected rows, or the whole page when none are selected.
    var chosenRows: [[SQLiteValue]] {
        guard let page else { return [] }
        let selected = grid.selectedRowIndexes.filter { $0 < page.rows.count }
        return selected.isEmpty ? page.rows : selected.map { page.rows[$0] }
    }

    func export(_ format: ([String], [[SQLiteValue]]) -> String) -> String {
        format(page?.columns ?? [], chosenRows)
    }

    private func copy(_ format: ([String], [[SQLiteValue]]) -> String) {
        guard page != nil else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(export(format), forType: .string)
    }

    @objc func copyCSV() { copy(TableExport.csv) }
    @objc func copyJSON() { copy(TableExport.json) }
    @objc func copyMarkdown() { copy(TableExport.markdown) }

    /// The file and table for the agent, with the selected rows as Markdown when they are small enough to
    /// type into its prompt. Nothing selected: the table only, and the agent reads what it needs.
    func contextItem() -> ContextItem {
        var item = ContextItem(path: path)
        guard let table = selectedTable, let page else { return item }
        let selected = grid.selectedRowIndexes.filter { $0 < page.rows.count }
        var note = "SQLite database, table “\(table)”"
        if selected.isEmpty {
            if let total { note += ", \(total.formatted()) row\(total == 1 ? "" : "s")" }
        } else {
            let rows = selected.map { page.rows[$0] }
            let first = page.offset + (selected.first ?? 0) + 1, last = page.offset + (selected.last ?? 0) + 1
            note += selected.count == 1 ? ", row \(first.formatted())" : ", \(selected.count.formatted()) rows between \(first.formatted()) and \(last.formatted())"
            let markdown = TableExport.markdown(columns: page.columns, rows: rows)
            if !AgentPrompt.isTooLargeToInline(markdown) {
                item.code = markdown
                item.language = "markdown"
            }
        }
        item.note = note
        return item
    }

    @objc func sendClicked() { onSendToAgent?([contextItem()]) }

    // MARK: table views

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === tableList ? tables.count : page?.rows.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView === tableList else {
            let cell = grid.cell(for: tableColumn, row: row)
            guard let page, let column = tableColumn, let index = Int(column.identifier.rawValue.dropFirst()),
                  row < page.rows.count, index < page.rows[row].count else {
                cell.configure(text: "")
                return cell
            }
            cell.configure(page.rows[row][index])
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("tableName")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? Self.makeTableCell(id)
        let table = tables[row]
        cell.textField?.stringValue = table.name
        cell.textField?.textColor = Theme.text
        cell.imageView?.image = NSImage(systemSymbolName: table.isView ? "eye" : "tablecells", accessibilityDescription: table.isView ? "View" : "Table")
        cell.imageView?.contentTintColor = Theme.textDim
        cell.setAccessibilityLabel(table.name + (table.isView ? ", view" : ""))
        return cell
    }

    /// A row of the table list: an icon and the table's name.
    private static func makeTableCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let label = NSTextField(labelWithString: "")
        Typography.singleLine(label, truncation: .byTruncatingTail)
        label.font = .systemFont(ofSize: 12.5)
        label.translatesAutoresizingMaskIntoConstraints = false
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(label)
        cell.textField = label
        cell.imageView = image
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === tableList else { return }
        let row = tableList.selectedRow
        guard tables.indices.contains(row), tables[row].name != selectedTable || page == nil else { return }
        grid.deselectAll(nil)
        load(tables[row].name, offset: 0)
    }

    // MARK: the current cell

    /// The table the page is of.
    var currentTable: SQLiteTable? { page.flatMap { page in tables.first { $0.name == page.table } } }

    /// The current cell's row key and column, with its table.
    private var currentCellKey: (table: String, cell: CellKey)? {
        guard let page, let cell = grid.currentCell, cell.row < page.keys.count, cell.column < page.columns.count,
              let key = page.keys[cell.row] else { return nil }
        return (page.table, CellKey(key: key, column: page.columns[cell.column]))
    }

    /// The current cell's value: the one read whole when it was, else the page's.
    var currentValue: SQLiteValue? {
        guard let page, let cell = grid.currentCell, cell.row < page.rows.count, cell.column < page.rows[cell.row].count else { return nil }
        if let kept = currentCellKey, let whole = wholeValues[kept.cell] { return whole }
        return page.rows[cell.row][cell.column]
    }

    /// The detail pane shows the current cell, from what the page read. A text cut on read is read whole
    /// once, by its row's key; nothing else is read.
    func showCurrentCell() {
        detailToken += 1
        guard !detail.isHidden else { return }
        guard let page, let cell = grid.currentCell, cell.row < page.rows.count, cell.column < page.columns.count,
              cell.column < page.rows[cell.row].count else {
            return detail.show(nil, items: [], current: -1)
        }
        let row = page.rows[cell.row], name = page.columns[cell.column]
        let items = zip(page.columns, row).map { DetailRowItem(name: $0, value: $1) }
        let key = cell.row < page.keys.count ? page.keys[cell.row] : nil
        let declared = page.info?.column(named: name)?.declaredType ?? ""
        var value = row[cell.column]
        var source = CellDetail.Source.page(fetching: false, isView: currentTable?.kind == .view)
        if let key, let whole = wholeValues[CellKey(key: key, column: name)] {
            value = whole
            source = .whole
        } else if value.isTruncated, key != nil {
            source = .page(fetching: true, isView: false)
        }
        let token = detailToken
        if case let .text(text, _) = value, text.utf8.count > 64 << 10 {
            // A long JSON value is indented off the main thread.
            queue.async { [weak self] in
                let made = CellDetail.make(column: name, declaredType: declared, value: value, source: source)
                DispatchQueue.main.async {
                    guard let self, token == self.detailToken else { return }
                    self.detail.show(made, items: items, current: cell.column)
                }
            }
        } else {
            detail.show(CellDetail.make(column: name, declaredType: declared, value: value, source: source), items: items, current: cell.column)
        }
        if case .page(fetching: true, _) = source, let key { readWhole(page.table, column: name, declaredType: declared, key: key, items: items, current: cell.column) }
    }

    /// Reads one value whole by its row's key, on the reading queue; shown if its cell is still current.
    private func readWhole(_ table: String, column: String, declaredType: String, key: SQLiteRowKey, items: [DetailRowItem], current: Int) {
        let token = detailToken, path = self.path, generation = self.generation
        #if DEBUG
        fetches += 1
        #endif
        queue.async { [weak self] in
            let read = Result { try SQLiteReader.value(table, column: column, key: key, at: path) }
            let value = (try? read.get()) ?? nil
            let made = value.map { CellDetail.make(column: column, declaredType: declaredType, value: $0, source: .whole) }
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                if let value { self.wholeValues[CellKey(key: key, column: column)] = value }
                guard token == self.detailToken else { return }
                if let made { return self.detail.show(made, items: items, current: current) }
                if case .failure = read { return self.detail.showNote("The whole value could not be read.") }
                self.detail.showNote("This row was deleted since the page was read.")
            }
        }
    }

    var isDetailShown: Bool { split.isDetailShown }

    /// Shows or hides the value pane (Space, the header's button); a click on a cell shows it.
    func showDetail(_ shown: Bool) { split.setDetailShown(shown) }

    func toggleDetail() { showDetail(!split.isDetailShown) }

    /// ↩ in the grid: the keyboard goes into the value.
    func enterValue() {
        guard grid.currentCell != nil else { return NSSound.beep() }
        showDetail(true)
        detail.focusValue()
    }

    /// Shows a table by name (for the self-test).
    func select(table name: String) {
        guard let index = tables.firstIndex(where: { $0.name == name }) else { return }
        tableList.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }
}

extension DatabasePane {
    /// What the viewer opens (decided in NextTermCore, so the sidebar's single click can ask too).
    static func opens(_ path: String) -> Bool { Databases.opensInViewer(path) }

    static func isEmptyFile(_ path: String) -> Bool { Databases.isEmptyFile(path) }
}
