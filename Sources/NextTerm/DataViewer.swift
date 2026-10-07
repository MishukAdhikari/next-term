import AppKit
import NextTermCore

/// A large data file in an editor tab, read-only: its first 1,000 records as a table (or as lines), and
/// 1,000 more at a time. Everything is read off the main thread through DataHead, which never writes, so
/// a 2 GB log opens as fast as a small one. A JSON Lines file gets a column per top-level key, a CSV
/// its header row.
final class DataPane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private(set) var url: URL
    var path: String { url.path }
    var name: String { url.lastPathComponent }
    let kind: DataFileKind
    var onTitleChange: (() -> Void)?
    /// Open in Editor was clicked (the file is small enough for it).
    var onOpenInEditor: ((URL) -> Void)?

    private let header = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    let search = NSSearchField()
    let mode = NSSegmentedControl(labels: ["Table", "Lines"], trackingMode: .selectOne, target: nil, action: nil)
    private let copyAs = NSPopUpButton(frame: .zero, pullsDown: true)
    let grid = DatabaseGridView()
    private let gridScroll = NSScrollView()
    private let rowsLabel = NSTextField(labelWithString: "")
    let headerBox = NSButton(checkboxWithTitle: "First row is a header", target: nil, action: nil)
    let loadMoreButton = NSButton(title: "Load More", target: nil, action: nil)
    private let editorButton = NSButton(title: "Open in Editor", target: nil, action: nil)
    private let defaultAppButton = NSButton(title: "Open in Default App", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")

    /// Every record read so far, in file order.
    private(set) var records: [DataRecord] = []
    /// The table's columns (not counting the line number).
    private(set) var columns: [String] = []
    /// The records the grid shows, as indexes into `records`: search misses are left out, and the header
    /// row too in the table (the Lines view lists it).
    private(set) var visible: [Int] = []
    private(set) var end = DataPosition.start
    private(set) var isAtEnd = false
    private(set) var fileSize: UInt64 = 0
    private(set) var delimiter: UInt8?
    /// The whole file's lines, once counted.
    private(set) var lineCount: Int?
    private(set) var loadError: String?
    private(set) var isLoading = false
    private(set) var isCounting = false
    private(set) var isDeletedOnDisk = false
    /// CSV and TSV: the first record names the columns.
    private(set) var hasHeader = false
    private var headerChosen = false
    /// Records whose text has the search, or nil without one.
    private var matches: IndexSet?
    private var countedBytes: UInt64 = 0
    private var stamp: FileStamp?
    /// What the last read saw, to tell a file that grew from one written again in place.
    private var fingerprint: DataFingerprint?
    /// Where the last record starts, when the end of the file ended it rather than a line break.
    private var unterminated: DataPosition?
    private let queue = DispatchQueue(label: "me.mishuk.nextterm.data-viewer", qos: .userInitiated)
    private let countQueue = DispatchQueue(label: "me.mishuk.nextterm.data-count", qos: .utility)
    private var generation = 0
    private var searchGeneration = 0
    private var isSearching = false
    private var counting: DataCancellation?

    /// For the self-test: nothing is being read.
    var isSettled: Bool { !isLoading && !isSearching }
    var focusView: NSView { grid }
    var showsLines: Bool { kind == .lines || mode.selectedSegment == 1 }

    init(url: URL) {
        self.url = URL(fileURLWithPath: canonicalPath(url.path))
        kind = DataFileKind(path: self.url.path)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        build()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { counting?.cancel() }

    // MARK: building

    private func build() {
        Typography.singleLine(titleLabel, truncation: .byTruncatingMiddle)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = Theme.textDim
        Typography.singleLine(summary, truncation: .byTruncatingTail)
        summary.setContentCompressionResistancePriority(.init(740), for: .horizontal)
        showTitle()

        search.placeholderString = "Search loaded rows"
        search.controlSize = .small
        search.font = .systemFont(ofSize: 11)
        search.sendsSearchStringImmediately = false
        search.target = self
        search.action = #selector(searchChanged)
        search.setAccessibilityLabel("Search the loaded rows")
        let searchWidth = search.widthAnchor.constraint(equalToConstant: 170)
        searchWidth.priority = .defaultHigh // a narrow window squeezes it rather than breaking the layout
        searchWidth.isActive = true
        search.setContentCompressionResistancePriority(.init(745), for: .horizontal)
        mode.controlSize = .small
        mode.font = .systemFont(ofSize: 11)
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.setToolTip("Rows split into columns", forSegment: 0)
        mode.setToolTip("Each record as the file has it", forSegment: 1)
        mode.isHidden = kind == .lines

        copyAs.controlSize = .small
        copyAs.font = .systemFont(ofSize: 11)
        (copyAs.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        copyAs.toolTip = "Copy the selected rows"
        copyAs.addItem(withTitle: "Copy As")
        for item in copyItems() { copyAs.menu?.addItem(item) }
        header.setViews([titleLabel, summary, NSView(), search, mode, copyAs], in: .leading)
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        header.wantsLayer = true
        header.layer?.backgroundColor = Theme.bar.cgColor

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
        grid.onCopy = { [weak self] in self?.copy(self?.exportLines() ?? "") }
        let menu = NSMenu()
        let copyLine = NSMenuItem(title: "Copy", action: #selector(copyLines), keyEquivalent: "")
        copyLine.target = self
        menu.addItem(copyLine)
        for item in copyItems(prefix: "Copy as ") { menu.addItem(item) }
        menu.delegate = self
        grid.menu = menu
        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true
        gridScroll.hasHorizontalScroller = true
        gridScroll.autohidesScrollers = true
        gridScroll.drawsBackground = true
        gridScroll.backgroundColor = Theme.background

        rowsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        rowsLabel.textColor = Theme.textDim
        Typography.singleLine(rowsLabel, truncation: .byTruncatingTail)
        rowsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerBox.controlSize = .small
        headerBox.font = .systemFont(ofSize: 11)
        headerBox.target = self
        headerBox.action = #selector(headerToggled)
        headerBox.toolTip = "Use the first row as the column names"
        loadMoreButton.target = self
        loadMoreButton.action = #selector(loadMore)
        loadMoreButton.toolTip = "Read the next \(DataHead.pageSize.formatted()) rows"
        editorButton.target = self
        editorButton.action = #selector(openInEditor)
        editorButton.toolTip = "Open the whole file in the editor, to read or change it"
        defaultAppButton.target = self
        defaultAppButton.action = #selector(openInDefaultApp)
        defaultAppButton.toolTip = "Open the file in the app macOS uses for it"
        for button in [loadMoreButton, editorButton, defaultAppButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        let footer = NSStackView(views: [rowsLabel, NSView(), headerBox, loadMoreButton, editorButton, defaultAppButton])
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        footer.wantsLayer = true
        footer.layer?.backgroundColor = Theme.bar.cgColor

        message.textColor = Theme.textDim
        message.alignment = .center
        message.isHidden = true
        for view in [header, gridScroll, footer, message] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            gridScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            gridScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            gridScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            gridScroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 30),
            message.centerYAnchor.constraint(equalTo: gridScroll.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
        ])
    }

    /// Copy As: JSON and CSV for data, and the lines as the file has them.
    private func copyItems(prefix: String = "") -> [NSMenuItem] {
        var items: [(String, Selector)] = []
        if kind != .lines { items += [(prefix + "JSON", #selector(copyJSON)), (prefix + "CSV", #selector(copyCSV))] }
        if prefix.isEmpty { items.append(("Lines", #selector(copyLines))) }
        return items.map { title, action in
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
    }

    private func showTitle() {
        let text = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Theme.text])
        text.append(Typography.gap(8, font: .systemFont(ofSize: 12)))
        text.append(NSAttributedString(string: RecentProjects.abbreviate(url.deletingLastPathComponent().path),
                                       attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.textDim]))
        titleLabel.attributedStringValue = Typography.truncating(text, .byTruncatingMiddle)
        titleLabel.toolTip = path
    }

    /// What the file is, and how much of it is in view.
    private func showSummary() {
        var parts = [kindName]
        if fileSize > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)) }
        let bad = records.filter { $0.error != nil }.count
        if bad > 0, kind == .jsonLines {
            parts.append(bad == 1 ? "1 line is not JSON" : "\(bad.formatted()) lines are not JSON")
        } else if bad > 0 {
            parts.append(bad == 1 ? "1 row with an unclosed quote" : "\(bad.formatted()) rows with an unclosed quote")
        }
        if isLoading { parts.append("reading…") }
        parts.append(isDeletedOnDisk ? "deleted on disk" : "read-only")
        summary.stringValue = parts.joined(separator: " · ")
        summary.textColor = isDeletedOnDisk ? Theme.linesRemoved : Theme.textDim
        let editorLimit = TextFile.maxEditableSize / 1024 / 1024
        summary.toolTip = isTooLargeForEditor
            ? "Too large for the editor (over \(editorLimit) MB): its first rows, read-only. Nothing here writes to the file."
            : "Opened read-only. Nothing here writes to the file."
        rowsLabel.stringValue = rowsText
        loadMoreButton.isEnabled = !isAtEnd && !isLoading && loadError == nil
        editorButton.isHidden = isTooLargeForEditor
        headerBox.isHidden = kind != .delimited || showsLines
        headerBox.state = hasHeader ? .on : .off
    }

    private var kindName: String {
        switch kind {
        case .jsonLines: return "JSON Lines"
        case .lines: return "Text"
        case .delimited:
            if delimiter == 0x09 { return "TSV" }
            return delimiter == 0x3B ? "CSV, semicolons" : "CSV"
        }
    }

    var isTooLargeForEditor: Bool { fileSize > UInt64(TextFile.maxEditableSize) }

    /// The data rows read so far: the header row is not one.
    var rowCount: Int { max(0, records.count - (headerRow ? 1 : 0)) }
    private var headerRow: Bool { kind == .delimited && hasHeader && !records.isEmpty }
    /// The rows the grid lists before a search: in the Lines view the header line is one of them.
    private var listedCount: Int { showsLines ? records.count : rowCount }

    /// About how many rows the whole file holds (as the grid lists them); exact once it is all read.
    var estimatedTotal: Int? {
        if isAtEnd { return listedCount }
        guard !records.isEmpty else { return nil }
        let total = DataHead.estimatedTotal(records: records.count, through: end, fileSize: fileSize, lineCount: lineCount)
        return max(listedCount, total - (records.count - listedCount))
    }

    /// "1,000 rows loaded of about 1,240,000", "All 312 rows", "12 of 1,000 loaded rows match".
    var rowsText: String {
        if let loadError, records.isEmpty { return loadError }
        if records.isEmpty { return isLoading ? "Reading…" : "No rows" }
        let unit = kind == .lines ? "line" : "row"
        if matches != nil, !search.stringValue.isEmpty {
            return "\(visible.count.formatted()) of \(listedCount.formatted()) loaded \(unit)s match"
        }
        if isAtEnd { return listedCount == 1 ? "1 \(unit)" : "All \(listedCount.formatted()) \(unit)s" }
        var text = "\(listedCount.formatted()) \(unit)s loaded"
        if let total = estimatedTotal { text += " of about \(total.formatted())" }
        if isCounting, fileSize > 0 {
            let percent = Int(Double(countedBytes) / Double(fileSize) * 100)
            text += " (counting lines, \(percent)%)"
        }
        return text
    }

    // MARK: reading

    /// Reads the first page again (just opened, or the file was replaced), keeping the view's choices.
    func reload() {
        generation += 1
        let token = generation, path = self.path, kind = self.kind
        counting?.cancel()
        isCounting = false
        isLoading = true
        showSummary()
        queue.async { [weak self] in
            let stamp = FileStamp(path: path)
            let result = Result { try DataHead.page(at: path, kind: kind) }
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.isLoading = false
                self.stamp = stamp
                self.isDeletedOnDisk = stamp == nil
                self.matches = nil
                self.lineCount = nil
                switch result {
                case let .success(page):
                    self.loadError = nil
                    self.records = page.records
                    self.take(page)
                    if !self.headerChosen, kind == .delimited {
                        self.hasHeader = DataHead.looksLikeHeader(page.records.prefix(51).map(\.fields))
                    }
                    if !page.isAtEnd { self.startCounting() }
                case let .failure(error):
                    self.records = []
                    self.fingerprint = nil
                    self.unterminated = nil
                    self.loadError = error.localizedDescription
                }
                self.rebuildColumns()
                self.runSearch()
                self.showSummary()
                self.onTitleChange?()
            }
        }
    }

    /// The next 1,000 rows.
    @objc func loadMore() {
        guard !isLoading, !isAtEnd, loadError == nil else { return NSSound.beep() }
        generation += 1
        let token = generation, path = self.path, kind = self.kind, start = end, delimiter = self.delimiter
        isLoading = true
        showSummary()
        queue.async { [weak self] in
            let result = Result { try DataHead.page(at: path, kind: kind, from: start, delimiter: delimiter) }
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.isLoading = false
                switch result {
                case let .success(page):
                    self.records += page.records
                    self.take(page)
                    self.rebuildColumns()
                    self.runSearch()
                case .failure:
                    NSSound.beep()
                }
                self.showSummary()
            }
        }
    }

    private func take(_ page: DataPage) {
        end = page.end
        isAtEnd = page.isAtEnd
        fileSize = page.fileSize
        fingerprint = page.fingerprint
        unterminated = page.unterminated
        if page.delimiter != nil { delimiter = page.delimiter }
    }

    /// Counts the whole file's lines in the background, for the estimate. Cancelled by a reload or closing.
    private func startCounting() {
        counting?.cancel()
        let cancel = DataCancellation()
        counting = cancel
        isCounting = true
        countedBytes = 0
        let path = self.path
        countQueue.async { [weak self] in
            var reported = Date.distantPast
            let lines = DataHead.countLines(path, cancellation: cancel) { bytes, _ in
                guard Date().timeIntervalSince(reported) > 0.25 else { return }
                reported = Date()
                DispatchQueue.main.async {
                    guard let self, self.counting === cancel else { return }
                    self.countedBytes = bytes
                    self.showSummary()
                }
            }
            DispatchQueue.main.async {
                guard let self, self.counting === cancel, !cancel.isCancelled else { return }
                self.isCounting = false
                self.lineCount = lines
                self.showSummary()
            }
        }
    }

    /// The file changed on disk. A log that grew keeps what was read and can load more; anything else
    /// (a file written again in place too, though it keeps its inode and grew) is read again. About once
    /// a second.
    func refreshIfChanged() {
        guard !isLoading else { return }
        let now = FileStamp(path: path)
        guard now != stamp else { return }
        guard let now else {
            stamp = nil
            isDeletedOnDisk = true
            return showSummary()
        }
        if let old = stamp, old.inode == now.inode, now.size > old.size, UInt64(now.size) >= end.offset {
            stamp = now
            return checkGrowth(to: now)
        }
        reload()
    }

    /// The file is larger under the same inode. Whether it still has what was read is checked off the
    /// main thread; Load More waits for the answer.
    private func checkGrowth(to now: FileStamp) {
        let token = generation, path = self.path, print = fingerprint
        isLoading = true
        queue.async { [weak self] in
            let same = print?.matches(path) == true
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.isLoading = false
                guard same else { return self.reload() }
                self.grew(to: now)
            }
        }
    }

    /// Only appended to: the rows stay and Load More reads on.
    private func grew(to now: FileStamp) {
        fileSize = UInt64(now.size)
        isAtEnd = false
        lineCount = nil // the estimate goes by bytes until the next count
        if let start = unterminated, !records.isEmpty {
            // Its last line had no line break yet, so it may have been half written: read it again.
            records.removeLast()
            end = start
            unterminated = nil
            rebuildColumns()
            runSearch()
        }
        showSummary()
    }

    /// The file was renamed or moved in the sidebar.
    func moved(to newURL: URL) {
        url = URL(fileURLWithPath: canonicalPath(newURL.path))
        stamp = FileStamp(path: path)
        isDeletedOnDisk = stamp == nil
        showTitle()
        showSummary()
        onTitleChange?()
    }

    // MARK: table and search

    private static let charWidth = ("M" as NSString).size(withAttributes: [.font: Theme.monoFont(size: 12)]).width

    /// The grid's columns for the mode: a line number, then the table's columns or the line's text.
    /// Kept as they are (and as wide as you made them) while Load More adds rows with the same columns.
    private func rebuildColumns() {
        let names = showsLines ? [] : tableColumns()
        let ids = ["line"] + (showsLines ? ["raw"] : names.indices.map { "c\($0)" })
        let titles = ["#"] + (showsLines ? ["Text"] : names)
        columns = names
        if grid.tableColumns.map(\.identifier.rawValue) != ids || grid.tableColumns.map(\.title) != titles {
            grid.tableColumns.forEach(grid.removeTableColumn)
            let number = NSTableColumn(identifier: .init("line"))
            number.title = "#"
            number.headerToolTip = "Line in the file"
            number.minWidth = 30
            grid.addTableColumn(number)
            if showsLines {
                let text = NSTableColumn(identifier: .init("raw"))
                text.title = "Text"
                text.width = 4000
                grid.addTableColumn(text)
            }
            let sample = records.prefix(50)
            for (i, name) in names.enumerated() {
                let column = NSTableColumn(identifier: .init("c\(i)"))
                column.title = name
                column.headerToolTip = name
                let longest = sample.map { cellText($0, column: i).prefix(41).count }.max() ?? 0
                column.width = min(320, max(60, CGFloat(max(longest, name.count)) * Self.charWidth + 16))
                column.minWidth = 40
                grid.addTableColumn(column)
            }
        }
        let digits = max(3, String(records.last?.line ?? 1).count)
        if let number = grid.tableColumns.first { number.width = max(number.width, CGFloat(digits) * Self.charWidth + 14) }
        refreshRows()
    }

    /// The column names: the header row's (or "Column 1"…) for CSV, every top-level key for JSON Lines.
    private func tableColumns() -> [String] {
        switch kind {
        case .lines:
            return []
        case .jsonLines:
            var names = DataHead.columns(of: records)
            if records.contains(where: { $0.error == nil && $0.keys.isEmpty }) { names.append("(value)") }
            if names.isEmpty, !records.isEmpty { names = ["(value)"] }
            return names
        case .delimited:
            let width = min(200, records.map(\.fields.count).max() ?? 0)
            let named = headerRow ? records[0].fields : []
            return (0..<width).map { i in
                let name = i < named.count ? named[i].trimmingCharacters(in: .whitespaces) : ""
                return name.isEmpty ? "Column \(i + 1)" : name
            }
        }
    }

    private func refreshRows() {
        let first = !showsLines && headerRow ? 1 : 0
        var shown = Array(first..<max(first, records.count))
        if let matches, !search.stringValue.isEmpty { shown = shown.filter { matches.contains($0) } }
        visible = shown
        grid.reloadData()
        message.stringValue = loadError ?? (records.isEmpty && !isLoading ? "This file has no rows." : "")
        message.isHidden = message.stringValue.isEmpty
        rowsLabel.stringValue = rowsText
    }

    @objc private func searchChanged() { runSearch() }

    /// Searches the loaded rows (for the self-test too).
    func find(_ text: String) {
        search.stringValue = text
        runSearch()
    }

    /// Finds the loaded records with the search's text in them, off the main thread.
    private func runSearch() {
        searchGeneration += 1
        let token = searchGeneration, query = search.stringValue, records = self.records
        guard !query.isEmpty else {
            matches = nil
            isSearching = false
            return refreshRows()
        }
        isSearching = true
        queue.async { [weak self] in
            var found = IndexSet()
            for (i, record) in records.enumerated() where record.raw.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                found.insert(i)
            }
            DispatchQueue.main.async {
                guard let self, token == self.searchGeneration else { return }
                self.isSearching = false
                self.matches = found
                self.refreshRows()
            }
        }
    }

    @objc private func modeChanged() {
        rebuildColumns()
        showSummary()
    }

    @objc private func headerToggled() {
        headerChosen = true
        hasHeader = headerBox.state == .on
        rebuildColumns()
        showSummary()
    }

    /// Shows the rows as a table or as the file's lines (for the self-test too).
    func show(lines: Bool) {
        mode.selectedSegment = lines ? 1 : 0
        modeChanged()
    }

    /// What a table cell shows: a CSV field, or a JSON value (a string without its quotes).
    func cellText(_ record: DataRecord, column: Int) -> String {
        switch kind {
        case .lines:
            return record.raw
        case .delimited:
            return column < record.fields.count ? record.fields[column] : ""
        case .jsonLines:
            if let error = record.error { return column == 0 ? error : "" }
            guard column < columns.count else { return "" }
            if columns[column] == "(value)", record.keys.isEmpty { return record.fields.first ?? "" }
            return record.value(for: columns[column]).map(DataHead.displayValue) ?? ""
        }
    }

    // MARK: copying

    /// The rows Copy works on: the selected ones, or the one right-clicked outside them.
    var chosenRecords: [DataRecord] {
        grid.selectedRowIndexes.compactMap { visible[safe: $0] }.map { records[$0] }
    }

    /// The chosen rows that are data, for Copy As JSON and CSV: the Lines view lists the header line,
    /// which names the columns rather than being one more row.
    var chosenRows: [DataRecord] {
        let indexes = grid.selectedRowIndexes.compactMap { visible[safe: $0] }
        return indexes.filter { !headerRow || $0 != 0 }.map { records[$0] }
    }

    /// A right-click on a row outside the selection selects it, so the menu copies what it points at.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = grid.clickedRow
        guard row >= 0, !grid.selectedRowIndexes.contains(row) else { return }
        grid.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// The chosen rows as JSON: JSON Lines as written, CSV rows as objects keyed by the header.
    func exportJSON() -> String {
        let chosen = chosenRows
        if kind == .jsonLines { return DataExport.jsonLines(chosen.map(\.raw)) }
        let fields = chosen.map(allFields)
        let names = csvColumns(fields)
        let rows = fields.map { row in names.indices.map { $0 < row.count ? row[$0] : nil } }
        return DataExport.objects(columns: names, rows: rows)
    }

    /// The chosen rows as CSV with a header line. JSON values are shown as cells show them.
    func exportCSV() -> String {
        let chosen = chosenRows
        if kind == .jsonLines {
            let keys = DataHead.columns(of: chosen)
            let rows = chosen.map { record in keys.map { record.value(for: $0).map(DataHead.displayValue) } }
            return DataExport.csv(columns: keys, rows: rows)
        }
        let fields = chosen.map(allFields)
        let names = csvColumns(fields)
        let rows = fields.map { row in names.indices.map { $0 < row.count ? row[$0] : nil } }
        return DataExport.csv(columns: names, rows: rows)
    }

    /// The chosen rows as the file has them.
    func exportLines() -> String {
        let chosen = chosenRecords
        return chosen.isEmpty ? "" : chosen.map(\.raw).joined(separator: "\n") + "\n"
    }

    /// A CSV row's fields, the ones it did not keep too (a row of 100,000 columns keeps the first 1,000).
    private func allFields(_ record: DataRecord) -> [String] {
        DataHead.allFields(of: record, delimiter: delimiter ?? 0x2C)
    }

    /// The header's names (or "Column 1"…), in the Lines view too.
    /// Past the 200 the table shows, the rest of the header's names.
    private func csvColumns(_ rows: [[String]]) -> [String] {
        var names = tableColumns()
        let width = rows.map(\.count).max() ?? 0
        let header = width > names.count && headerRow ? allFields(records[0]) : []
        while names.count < width {
            let i = names.count
            let name = i < header.count ? header[i].trimmingCharacters(in: .whitespaces) : ""
            names.append(name.isEmpty ? "Column \(i + 1)" : name)
        }
        return names
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func copyJSON() { copy(chosenRows.isEmpty ? "" : exportJSON()) }
    @objc func copyCSV() { copy(chosenRows.isEmpty ? "" : exportCSV()) }
    @objc func copyLines() { copy(exportLines()) }

    @objc private func openInEditor() { onOpenInEditor?(url) }
    @objc private func openInDefaultApp() { SafeOpen.open(url, from: window) }

    /// The file for the agent, at the selected rows' lines.
    func contextItem() -> ContextItem {
        var item = ContextItem(path: path)
        let lines = chosenRecords.map(\.line)
        if let first = lines.min(), let last = lines.max() { item.lines = first...last }
        return item
    }

    // MARK: table view

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("dataValue")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? Self.makeCell(id)
        guard let column = tableColumn, let index = visible[safe: row], index < records.count else { return cell }
        let record = records[index]
        let font = Theme.monoFont(size: 12)
        var color = Theme.terminalForeground
        var text: String
        switch column.identifier.rawValue {
        case "line":
            text = String(record.line)
            color = record.error == nil ? Theme.textDim : Theme.linesRemoved
        case "raw":
            text = record.raw
            if record.error != nil { color = Theme.linesRemoved }
        default:
            text = cellText(record, column: Int(column.identifier.rawValue.dropFirst()) ?? 0)
            if record.error != nil {
                color = Theme.linesRemoved
            } else if kind == .jsonLines, text == "null" {
                color = Theme.textDim
            }
        }
        let long = text.utf8.count > 600 && text.count > 300
        var shown = long ? String(text.prefix(300)) + "…" : text
        if !long, record.isTruncated, column.identifier.rawValue == "raw" { shown += "…" }
        cell.textField?.stringValue = shown.replacingOccurrences(of: "\r\n", with: " ⏎ ").replacingOccurrences(of: "\n", with: " ⏎ ")
        cell.textField?.textColor = color
        cell.textField?.font = font
        cell.textField?.toolTip = column.identifier.rawValue == "line" ? record.error : (text.utf8.count > 40 ? String(text.prefix(2000)) : nil)
        return cell
    }

    private static func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let label = NSTextField(labelWithString: "")
        Typography.singleLine(label, truncation: .byTruncatingTail)
        label.font = Theme.monoFont(size: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
        ])
        return cell
    }
}

extension DataPane {
    /// Below this the editor is better: it colours the file and opens it whole.
    static let threshold = DataHead.viewThreshold

    /// What opens here rather than in the editor (decided in NextTermCore, so the sidebar's single click
    /// can ask too).
    static func opens(_ path: String) -> Bool { DataHead.opensInView(path) }
}
