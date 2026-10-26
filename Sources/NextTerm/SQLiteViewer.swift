import AppKit
import NextTermCore

/// A SQLite file in an editor tab: its tables on the left, a page of 1,000 rows in the middle, and the
/// current cell's whole value on the right (CellDetailView). Everything is read off the main thread
/// through SQLiteReader, which never writes. Rows copy as CSV, JSON or Markdown, and go to the agent the
/// way files do (⌥⌘K). It stays read-only until "Allow Editing…" (SQLiteViewerEditing.swift).
final class DatabasePane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var url: URL
    var path: String { url.path }
    var name: String { url.lastPathComponent }
    var onTitleChange: (() -> Void)?
    /// Send to Agent was clicked.
    var onSendToAgent: (([ContextItem]) -> Void)?
    /// A draft was opened, typed, saved or put back: the tab's modified dot, and a preview kept.
    var onDraftChange: (() -> Void)?

    private let header = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let copyAs = NSPopUpButton(frame: .zero, pullsDown: true)
    /// Allow Editing… or Stop Editing.
    let editingButton = NSButton(title: "Allow Editing…", target: nil, action: nil)
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
    /// Reads, and the one write of a Save, in turn.
    let queue = DispatchQueue(label: "me.mishuk.nextterm.sqlite-viewer", qos: .userInitiated)
    /// Editing in this tab: allowed or not, the draft, the saves' undo steps (SQLiteViewerEditing.swift).
    var edit = EditState()
    private var generation = 0
    private var stamps: [FileStamp?] = []
    /// Values read whole by their row's key (a text cut at 10,000 characters on the page), until the
    /// page is read again.
    private(set) var wholeValues: [CellKey: SQLiteValue] = [:]
    /// Values read whole before the page was read again, whose row is still on it and starts the same way:
    /// shown while they are read again, never edited.
    private var earlierWholeValues: [CellKey: SQLiteValue] = [:]
    /// The whole values asked for and not read yet, with the page read they are for.
    private var pendingWhole: (generation: Int, cells: Set<CellKey>) = (0, [])
    /// The whole value the detail wants now. A read queued for a cell left behind is dropped before it reads.
    private let wantedWhole = WantedCell()
    /// Moves on with every current cell, so a value worked out for a cell left behind is not shown.
    private var detailToken = 0
    #if DEBUG
    /// For the self-test: how many values were read whole, and what the last write did.
    private(set) var fetches = 0
    var lastOutcome: SQLiteSaveOutcome?
    #endif

    struct CellKey: Hashable, Sendable {
        let key: SQLiteRowKey
        let column: String
    }

    /// The one whole value wanted, set on the main thread and read on the reading queue.
    final class WantedCell: @unchecked Sendable {
        private let lock = NSLock()
        private var wanted: (generation: Int, cell: CellKey)?

        func set(_ generation: Int, _ cell: CellKey?) {
            lock.lock()
            defer { lock.unlock() }
            wanted = cell.map { (generation, $0) }
        }

        func isWanted(_ generation: Int, _ cell: CellKey) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return wanted?.generation == generation && wanted?.cell == cell
        }
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
        editingButton.bezelStyle = .rounded
        editingButton.controlSize = .small
        editingButton.font = .systemFont(ofSize: 11)
        editingButton.target = self
        editingButton.action = #selector(editingButtonClicked)
        showEditButton()
        header.setViews([titleLabel, summary, NSView(), editingButton, split.toggle, copyAs, sendButton], in: .leading)
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
        grid.onClickCell = { [weak self] clicks in
            guard let self else { return }
            self.showDetail(true)
            if clicks == 2, self.isEditingAllowed { self.beginEditing() }
        }
        grid.onSpace = { [weak self] in self?.toggleDetail() }
        grid.onEnter = { [weak self] in
            guard let self else { return }
            self.isEditingAllowed ? self.beginEditing() : self.enterValue()
        }
        grid.shouldMoveCurrentCell = { [weak self] row, column in self?.shouldLeaveDraft(to: row, column: column) ?? true }
        grid.shouldSelectAll = { [weak self] in self?.askToLeaveDraft { self?.grid.selectAllRows() } ?? true }
        detail.editor = self
        split.onShownChange = { [weak self] in self?.showCurrentCell() }
        detail.onSelectColumn = { [weak self] column in
            guard let self else { return }
            let move = { [weak self] in
                guard let self else { return }
                self.grid.setCurrent(column: column)
                self.grid.scrollColumnToVisible(column)
            }
            // A line of the row list moves the current cell as a click on the grid does: a draft is asked about
            // first, and meanwhile the list shows the current cell's line again.
            if column == self.grid.currentColumn || self.askToLeaveDraft(then: move) { move() } else { self.showCurrentCell() }
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

    /// "SQLite · 4 tables · read-only" ("editing allowed" while it is), or what is wrong.
    func showSummary() {
        var parts = ["SQLite"]
        let count = tables.filter { !$0.isView }.count, views = tables.count - count
        if !tables.isEmpty || loadError == nil { parts.append(count == 1 ? "1 table" : "\(count) tables") }
        if views > 0 { parts.append(views == 1 ? "1 view" : "\(views) views") }
        if isLoading { parts.append("reading…") }
        let state = isDeletedOnDisk ? "deleted on disk" : isEditingAllowed ? "editing allowed" : "read-only"
        let text = NSMutableAttributedString(string: parts.joined(separator: " · ") + " · ",
                                             attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.textDim])
        let color = isDeletedOnDisk ? Theme.linesRemoved : isEditingAllowed ? Theme.attention : Theme.textDim
        text.append(NSAttributedString(string: state, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color]))
        summary.attributedStringValue = Typography.truncating(text, .byTruncatingTail)
        summary.toolTip = isEditingAllowed ? "Editing is allowed in this tab: Save writes one value to the file. Stop Editing makes it read-only again."
                                           : "Opened read-only. Nothing here writes to the file."
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
            // Noted before the read, as reloadTables does: a save's own read is not taken for another app's write.
            let stamps = Self.stamps(path)
            let result = Result { () throws -> (SQLitePage, Int) in
                let total = try SQLiteReader.count(table, at: path)
                let start = min(offset, max(0, (total - 1) / SQLiteReader.pageSize * SQLiteReader.pageSize))
                return (try SQLiteReader.page(table, at: path, offset: start), total)
            }
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.stamps = stamps
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
        // The grid's cells are made again: a value being typed in one goes to the detail pane first.
        let aside = moveInCellDraftAside()
        let sameColumns = page?.columns == self.page?.columns && page?.table == self.page?.table
        // The current cell's row, by its key, to find again on the page read now (rows may have come before it).
        let kept = currentCellKey
        let earlier = wholeValues.merging(earlierWholeValues) { now, _ in now }
        let sameTable = page?.table == self.page?.table
        self.page = page
        self.total = total
        wholeValues = [:]
        earlierWholeValues = [:]
        if let page, sameTable {
            // Kept to show while they are read again, where the page still starts them the same way.
            for (cell, value) in earlier {
                guard let row = page.row(for: cell.key), let column = page.columns.firstIndex(of: cell.column),
                      value.agrees(with: page.rows[row][column]) else { continue }
                earlierWholeValues[cell] = value
            }
        }
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
        checkDraftRow()
        showCurrentCell()
        switch aside {
        case .moved?: if editingUI?.isEditing == true { detail.focusValue() }
        case let .reopen(cell)?: if currentEditTarget?.cell == cell { beginEditing() }
        case nil: break
        }
    }

    /// The row a draft is in, read again: other values that changed since it opened are said now, not only
    /// when Save finds them.
    private func checkDraftRow() {
        guard edit.draft != nil, let cell = edit.cell, let page, page.table == cell.table, let row = page.row(for: cell.key) else { return }
        guard !SQLiteEdit.rowAgrees(edit.row, columns: page.columns, values: page.rows[row], except: cell.column) else { return }
        edit.message = "Other values in this row changed since it was read: see the row below. Save checks the row again first."
    }

    /// The row at `index` as read, for a draft to check against: the page's values, those read whole in place.
    func rowSnapshot(_ index: Int) -> [SQLiteColumnValue] {
        guard let page, index >= 0, index < page.rows.count else { return [] }
        let key = index < page.keys.count ? page.keys[index] : nil
        return zip(page.columns, page.rows[index]).map { column, value in
            SQLiteColumnValue(column: column, value: key.flatMap { wholeValues[CellKey(key: $0, column: column)] } ?? value)
        }
    }

    /// After a save: the row as the file has it now (read back in the save's own transaction), in the page
    /// and the grid, until the page is read again.
    func showSaved(_ row: [SQLiteColumnValue], table: String, key: SQLiteRowKey) {
        guard let page, page.table == table, let index = page.row(for: key) else { return }
        var values = page.rows[index]
        for part in row {
            guard let column = page.columns.firstIndex(of: part.column), column < values.count else { continue }
            values[column] = part.value
            // A value read whole before that the row doesn't have any more (the saved cell, one a trigger set) goes.
            let cell = CellKey(key: key, column: part.column)
            if wholeValues[cell]?.agrees(with: part.value) == false { wholeValues[cell] = nil }
            if earlierWholeValues[cell]?.agrees(with: part.value) == false { earlierWholeValues[cell] = nil }
        }
        var rows = page.rows
        rows[index] = values
        self.page = SQLitePage(table: page.table, columns: page.columns, rows: rows, offset: page.offset, keys: page.keys, info: page.info)
        // Not under a value being typed in a cell (an undo from the notice): the page read next shows it.
        guard !edit.inCell else { return }
        grid.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integersIn: 0..<grid.numberOfColumns))
    }

    private func rebuildColumns() {
        grid.tableColumns.forEach(grid.removeTableColumn)
        guard let page else { return }
        let font = Theme.monoFont(size: 12)
        let charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        for (i, name) in page.columns.enumerated() {
            let column = NSTableColumn(identifier: .init("c\(i)"))
            column.title = CellText.line(name, limit: 120)
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
        checkIdentity()
        // Not under a value being typed in its cell: the stamps stay, so the first tick after it ends reads.
        guard !isLoading, !edit.isSaving, !edit.inCell else { return }
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
        guard let page else { return }
        turnPage(to: max(0, page.offset - SQLiteReader.pageSize))
    }

    @objc private func nextPage() {
        guard let page else { return }
        turnPage(to: page.offset + SQLiteReader.pageSize)
    }

    /// Another page of the table, once a draft on this one is saved or put back.
    private func turnPage(to offset: Int) {
        guard let table = selectedTable else { return }
        if askToLeaveDraft(then: { [weak self] in self?.load(table, offset: offset) }) { load(table, offset: offset) }
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
            // The cell open for an edit in place keeps what is being typed in it.
            if cell.isEditingInPlace { return cell }
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
        // On one line, whatever the name holds; the tooltip has it as it is.
        let name = CellText.line(table.name, limit: 120)
        cell.textField?.stringValue = name
        cell.textField?.textColor = Theme.text
        cell.toolTip = name == table.name ? nil : table.name
        cell.imageView?.image = NSImage(systemSymbolName: table.isView ? "eye" : "tablecells", accessibilityDescription: table.isView ? "View" : "Table")
        cell.imageView?.contentTintColor = Theme.textDim
        cell.setAccessibilityLabel(name + (table.isView ? ", view" : ""))
        return cell
    }

    /// A row of the table list: an icon and the table's name.
    private static func makeTableCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        if #available(macOS 14, *) { cell.clipsToBounds = true }
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

    /// Another table with a draft open: Save, Don't Save or Cancel first.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableView === tableList, hasDraft, row != tableList.selectedRow else { return true }
        return askToLeaveDraft { [weak self] in self?.tableList.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === tableList else { return }
        let row = tableList.selectedRow
        guard tables.indices.contains(row), tables[row].name != selectedTable || page == nil else { return }
        if edit.draft != nil { endDraft() }
        grid.deselectAll(nil)
        load(tables[row].name, offset: 0)
    }

    // MARK: the current cell

    /// The table the page is of.
    var currentTable: SQLiteTable? { page.flatMap { page in tables.first { $0.name == page.table } } }

    /// The current cell's row key and column, with its table.
    var currentCellKey: (table: String, cell: CellKey)? {
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
    /// once, by its row's key; nothing else is read. After the page is read again, a value read whole before
    /// shows while it is read again, and is replaced only if it changed.
    func showCurrentCell() {
        detailToken += 1
        guard !detail.isHidden else { return wantedWhole.set(generation, nil) }
        guard let page, let cell = grid.currentCell, cell.row < page.rows.count, cell.column < page.columns.count,
              cell.column < page.rows[cell.row].count else {
            wantedWhole.set(generation, nil)
            return detail.show(nil, items: [], current: -1)
        }
        let row = page.rows[cell.row], name = page.columns[cell.column]
        let items = zip(page.columns, row).map { DetailRowItem(name: $0, value: $1) }
        let key = cell.row < page.keys.count ? page.keys[cell.row] : nil
        let declared = page.info?.column(named: name)?.declaredType ?? ""
        var value = row[cell.column]
        var source = CellDetail.Source.page(fetching: false, isView: currentTable?.kind == .view)
        var read = false
        let cellKey = key.map { CellKey(key: $0, column: name) }
        if let cellKey, let whole = wholeValues[cellKey] {
            value = whole
            source = .whole
        } else if value.isTruncated, let cellKey {
            read = true
            if let earlier = earlierWholeValues[cellKey] {
                value = earlier
                source = .whole
            } else {
                source = .page(fetching: true, isView: false)
            }
        }
        wantedWhole.set(generation, read ? cellKey : nil)
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
        detail.showEditing(editingUI)
        if read, let cellKey { readWhole(page.table, cell: cellKey) }
    }

    /// Reads one value whole by its row's key, on the reading queue, unless it is being read already; shown
    /// if its cell is still current. A read whose cell was left before its turn on the queue never reads.
    private func readWhole(_ table: String, cell: CellKey) {
        let path = self.path, generation = self.generation
        if pendingWhole.generation != generation { pendingWhole = (generation, []) }
        guard pendingWhole.cells.insert(cell).inserted else { return }
        let wanted = wantedWhole
        queue.async { [weak self] in
            guard wanted.isWanted(generation, cell) else {
                DispatchQueue.main.async { self?.wholeRead(cell, generation: generation, result: nil) }
                return
            }
            let read = Result { try SQLiteReader.value(table, column: cell.column, key: cell.key, at: path) }
            DispatchQueue.main.async { self?.wholeRead(cell, generation: generation, result: read) }
        }
    }

    /// A whole value's read came back (nil: it was dropped before it read).
    private func wholeRead(_ cell: CellKey, generation: Int, result: Result<SQLiteValue?, Error>?) {
        guard generation == self.generation else { return }
        pendingWhole.cells.remove(cell)
        guard let result else { return }
        #if DEBUG
        fetches += 1
        #endif
        let current = currentCellKey?.cell == cell && !detail.isHidden
        switch result {
        case let .success(value?):
            wholeValues[cell] = value
            earlierWholeValues[cell] = nil
            if current { showCurrentCell() }
        case .success(nil):
            earlierWholeValues[cell] = nil
            if current { detail.showNote("This row was deleted since the page was read.") }
        case .failure:
            if current { detail.showNote("The whole value could not be read.") }
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

extension DatabasePane: CellDetailEditor {
    func detailBeginEdit() { beginDetailEdit() }
    func detailTyped(_ text: String) { draftTyped(text) }
    func detailSetNull() { setDraftNull() }
    func detailRevert() { revertDraft() }
    func detailSave() { save() }

    /// For the self-test: the header's summary as it reads.
    var summaryText: String { summary.stringValue }
    var summaryTip: String { summary.toolTip ?? "" }

    func showEditButton() {
        editingButton.title = isEditingAllowed ? "Stop Editing" : "Allow Editing…"
        editingButton.toolTip = isEditingAllowed ? "Make this tab read-only again" : "Edit values in this file, after a question; Save writes one value at a time"
    }
}

extension DatabasePane {
    /// What the viewer opens (decided in NextTermCore, so the sidebar's single click can ask too).
    static func opens(_ path: String) -> Bool { Databases.opensInViewer(path) }

    static func isEmptyFile(_ path: String) -> Bool { Databases.isEmptyFile(path) }
}
