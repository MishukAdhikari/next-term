import AppKit
import NextTermCore

/// The Git Diff tab's All files page: every changed file's diff on one page, top to bottom, the way the
/// Unified view shows one. Each file has a header row (its icon, name, folder, +N −M, a chevron that folds
/// it away, Open File and Show Side by Side), then its rows, long unchanged runs folded into rows that open
/// on a click. Read-only. Laid out as it scrolls: a file's rows are made only when they come near the view,
/// so a large change stays quick, and a file with a very large diff waits for "Show anyway".
final class AllFilesView: NSView {
    /// One file on the page: its diff, its rows, and how it is shown (kept by path from one read to the next).
    final class Entry {
        var file: ChangedFile
        /// Nil until read: a large file (left out of the page's read), or one being read.
        var diff: FileDiff?
        var rows: [UnifiedRow] = []
        /// The file's unchanged lines, once a fold asked for them.
        var fill: [Int: DiffLine]?
        var expanded: Set<Int> = []
        var collapsed = false
        /// "Show anyway" was clicked.
        var forced = false
        var reading = false
        var failed = false
        var top: CGFloat = 0
        var height: CGFloat = 0
        var block: AllFilesBlock?

        init(file: ChangedFile) { self.file = file }
    }

    enum Body: Equatable {
        case none, rows
        case note(String, action: String?)
    }

    static let headerHeight: CGFloat = 32
    static let noteHeight: CGFloat = 36
    /// A file with more rows than this waits for "Show anyway".
    static let maxRows = 4000

    private let header = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "All files")
    private let counts = NSTextField(labelWithString: "")
    private let foldAll = NSButton(title: "Collapse All", target: nil, action: nil)
    let scroll = NSScrollView()
    private let page = AllFilesPage()
    private let message = NSTextField(wrappingLabelWithString: "")
    private(set) var entries: [Entry] = []
    private var root = ""
    private var rowHeight = UnifiedColumn.standardRowHeight
    private static let queue = DispatchQueue(label: "nextterm.all-files", qos: .userInitiated)

    /// Open File: the file in the editor.
    var onOpenFile: ((ChangedFile) -> Void)?
    /// Show Side by Side: the file's own diff.
    var onSideBySide: ((ChangedFile) -> Void)?
    /// Reads one file's diff with `lines` of context; called off the main thread.
    var reader: ((ChangedFile, Int) -> FileDiff?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: showing

    /// The files in the list's order with their diffs (a large file's left out). What is folded, opened and
    /// scrolled to stays; a file whose diff is the same keeps its rows as they are, so nothing flashes.
    func show(files: [ChangedFile], diffs: [String: FileDiff], root: String, message text: String?) {
        self.root = root
        let anchor = topEntry()
        let old = Dictionary(entries.map { ($0.file.path, $0) }, uniquingKeysWith: { first, _ in first })
        var rereads: [Entry] = []
        entries = files.map { file in
            let entry = old[file.path] ?? Entry(file: file)
            let isNew = old[file.path] == nil
            let fresh = diffs[file.path]
            entry.file = file
            if let fresh, isNew || fresh != entry.diff {
                if let fill = entry.fill, !UnifiedDiffPart.isConsistent(fill, with: fresh) { entry.fill = nil }
                entry.diff = fresh
                entry.failed = false
                entry.rows = UnifiedRows.rows(for: fresh, expanded: entry.expanded, fill: entry.fill)
                drop(entry)
            } else if fresh == nil, !isNew, entry.forced, !entry.reading {
                rereads.append(entry) // shown anyway, and not in the page's read: read again by itself
            } else if fresh == nil, isNew || !entry.forced {
                entry.diff = nil
                entry.rows = []
                drop(entry)
            }
            return entry
        }
        let kept = Set(entries.map(ObjectIdentifier.init))
        for entry in old.values where !kept.contains(ObjectIdentifier(entry)) { drop(entry) }
        let totals = files.reduce(LineStats()) { LineStats(added: $0.added + ($1.added ?? 0), removed: $0.removed + ($1.removed ?? 0), files: $0.files + 1) }
        let numbers = NSMutableAttributedString(string: totals.files == 1 ? "1 file  " : "\(totals.files.formatted()) files  ", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.textDim,
        ])
        numbers.append(GitDiffFileCell.numbers(added: totals.added, removed: totals.removed, binary: false))
        counts.attributedStringValue = numbers
        message.stringValue = text ?? ""
        message.isHidden = text == nil
        scroll.isHidden = text != nil
        relayout(keeping: anchor)
        for entry in rereads { read(entry, lines: UnifiedRows.context) }
    }

    /// For the self-test and the list: the files on the page, in order.
    var paths: [String] { entries.map(\.file.path) }

    /// For the self-test: each file's header as words, and what its body shows.
    var blockTitles: [String] {
        entries.map { entry in
            let counts = entry.file.added.map { " +\($0) −\(entry.file.removed ?? 0)" } ?? ""
            switch body(of: entry) {
            case .none: return entry.file.path + counts + " (folded away)"
            case .rows: return entry.file.path + counts + " \(entry.rows.count) rows"
            case let .note(text, action): return entry.file.path + counts + " — " + text + (action.map { " [\($0)]" } ?? "")
            }
        }
    }

    func entry(at path: String) -> Entry? { entries.first { $0.file.path == path } }

    /// The file's header at the top of the view.
    func reveal(_ path: String) {
        guard let entry = entry(at: path) else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(entry.top, max(0, page.frame.height - scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
        layoutVisible()
    }

    /// The font or line height changed: every row's height with it.
    func applyFont() {
        rowHeight = UnifiedColumn.standardRowHeight
        entries.forEach(drop)
        relayout(keeping: topEntry())
    }

    // MARK: what a file shows

    func body(of entry: Entry) -> Body {
        if entry.collapsed { return .none }
        if entry.reading { return .note("Reading…", action: nil) }
        if entry.failed { return .note("Git could not read this file’s changes.", action: nil) }
        guard let diff = entry.diff else { return .note(Self.largeText(entry.file), action: "Show anyway") }
        if diff.isBinary { return .note("A binary file: its contents can’t be compared line by line.", action: nil) }
        if entry.rows.isEmpty { return .note(Self.emptyText(entry.file, diff), action: nil) }
        if entry.rows.count > Self.maxRows, !entry.forced { return .note(Self.largeText(entry.file), action: "Show anyway") }
        return .rows
    }

    private static func largeText(_ file: ChangedFile) -> String {
        guard let added = file.added else { return "Large diff: not shown." }
        let lines = added + (file.removed ?? 0)
        return "Large diff: \(lines.formatted()) lines changed."
    }

    private static func emptyText(_ file: ChangedFile, _ diff: FileDiff) -> String {
        if let old = file.oldPath { return "Renamed from \(old); the lines are the same." }
        if diff.isNew || file.status == .added { return "An empty file." }
        if diff.isDeleted || file.status == .deleted { return "Deleted; it was empty." }
        return "Only the file’s mode changed, not its lines."
    }

    private func height(of entry: Entry) -> CGFloat {
        switch body(of: entry) {
        case .none: return Self.headerHeight + 1
        case .rows: return Self.headerHeight + 12 + CGFloat(entry.rows.count) * rowHeight + 1
        case .note: return Self.headerHeight + Self.noteHeight + 1
        }
    }

    // MARK: actions

    private func toggle(_ entry: Entry) {
        entry.collapsed.toggle()
        refresh(entry)
        updateFoldAllTitle()
    }

    @objc private func foldAllClicked() {
        let collapse = entries.contains { !$0.collapsed }
        let anchor = topEntry()
        for entry in entries where entry.collapsed != collapse {
            entry.collapsed = collapse
            drop(entry)
        }
        relayout(keeping: anchor)
        updateFoldAllTitle()
    }

    private func updateFoldAllTitle() {
        foldAll.title = entries.contains { !$0.collapsed } ? "Collapse All" : "Expand All"
    }

    private func showAnyway(_ entry: Entry) {
        entry.forced = true
        if entry.diff == nil { return read(entry, lines: UnifiedRows.context) }
        refresh(entry)
    }

    /// A fold was clicked: its lines show, now if they are known, else once the whole file is read.
    private func open(_ fold: UnifiedFold, in entry: Entry) {
        entry.expanded.insert(fold.oldStart)
        guard entry.fill == nil, let reader else { return rebuildRows(entry) }
        let file = entry.file
        Self.queue.async { [weak self] in
            let whole = reader(file, UnifiedRows.wholeFile)
            DispatchQueue.main.async {
                guard let self, self.entries.contains(where: { $0 === entry }) else { return }
                entry.fill = whole.map(UnifiedRows.fill(from:))
                self.rebuildRows(entry)
            }
        }
    }

    /// Reads one file's diff by itself (shown anyway, or not in the page's read).
    private func read(_ entry: Entry, lines: Int) {
        guard let reader else { return }
        entry.reading = true
        refresh(entry)
        let file = entry.file
        Self.queue.async { [weak self] in
            let diff = reader(file, lines)
            DispatchQueue.main.async {
                guard let self, self.entries.contains(where: { $0 === entry }) else { return }
                entry.reading = false
                entry.failed = diff == nil
                if let diff {
                    entry.diff = diff
                    entry.fill = nil
                }
                self.rebuildRows(entry)
            }
        }
    }

    private func rebuildRows(_ entry: Entry) {
        entry.rows = entry.diff.map { UnifiedRows.rows(for: $0, expanded: entry.expanded, fill: entry.fill) } ?? []
        refresh(entry)
    }

    /// One file's block made again, the page laid out around it.
    private func refresh(_ entry: Entry) {
        drop(entry)
        relayout(keeping: topEntry())
    }

    private func drop(_ entry: Entry) {
        entry.block?.removeFromSuperview()
        entry.block = nil
    }

    // MARK: layout

    /// The file at the top of the view, and how far into it the view starts.
    private func topEntry() -> (path: String, offset: CGFloat)? {
        let y = scroll.contentView.bounds.minY
        guard let entry = entries.first(where: { $0.top + $0.height > y }) else { return nil }
        return (entry.file.path, y - entry.top)
    }

    /// Every file's place and height, the page's size, then the view where it was (the same file at the
    /// top, as far into it).
    private func relayout(keeping anchor: (path: String, offset: CGFloat)?) {
        var y: CGFloat = 0
        for entry in entries {
            entry.top = y
            entry.height = height(of: entry)
            y += entry.height
        }
        let width = scroll.contentSize.width
        page.setFrameSize(NSSize(width: width, height: max(y, scroll.contentSize.height)))
        if let anchor, let entry = entry(at: anchor.path) {
            let target = min(entry.top + min(anchor.offset, entry.height), max(0, page.frame.height - scroll.contentView.bounds.height))
            if abs(target - scroll.contentView.bounds.minY) > 0.5 {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, target)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        layoutVisible()
    }

    /// Makes the blocks near the view and places them; lets go of those far from it.
    private func layoutVisible() {
        let visible = scroll.contentView.bounds
        let margin = max(visible.height, 400)
        let wanted = visible.insetBy(dx: 0, dy: -margin)
        let kept = visible.insetBy(dx: 0, dy: -margin * 3)
        let width = page.bounds.width
        for entry in entries {
            let frame = NSRect(x: 0, y: entry.top, width: width, height: entry.height)
            if frame.intersects(wanted) {
                let block = entry.block ?? makeBlock(entry)
                if block.frame != frame { block.frame = frame }
            } else if let block = entry.block {
                if frame.intersects(kept) {
                    if block.frame != frame { block.frame = frame }
                } else {
                    drop(entry)
                }
            }
        }
    }

    override func layout() {
        super.layout()
        if abs(page.frame.width - scroll.contentSize.width) > 0.5 { relayout(keeping: topEntry()) }
    }

    private func makeBlock(_ entry: Entry) -> AllFilesBlock {
        let block = AllFilesBlock(frame: NSRect(x: 0, y: entry.top, width: page.bounds.width, height: entry.height))
        block.header.show(entry.file, root: root, collapsed: entry.collapsed)
        block.header.onToggle = { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.toggle(entry)
        }
        block.header.onOpen = { [weak self, weak entry] in
            guard let file = entry?.file else { return }
            self?.onOpenFile?(file)
        }
        block.header.onSideBySide = { [weak self, weak entry] in
            guard let file = entry?.file else { return }
            self?.onSideBySide?(file)
        }
        switch body(of: entry) {
        case .none:
            break
        case .rows:
            let column = UnifiedColumn(scrollsVertically: false)
            column.frame = NSRect(x: 0, y: Self.headerHeight, width: block.bounds.width, height: entry.height - Self.headerHeight - 1)
            column.autoresizingMask = [.width]
            block.addSubview(column)
            column.show(entry.rows, language: EditorLanguage.id(forFileName: (entry.file.path as NSString).lastPathComponent))
            column.onFoldClick = { [weak self, weak entry] fold in
                guard let self, let entry else { return }
                self.open(fold, in: entry)
            }
            column.menuForRow = { [weak self, weak entry, weak column] _ in
                guard let self, let file = entry?.file else { return nil }
                let menu = NSMenu()
                menu.addBlock("Open File", enabled: file.status != .deleted) { [weak self] in self?.onOpenFile?(file) }
                menu.addBlock("Show Side by Side") { [weak self] in self?.onSideBySide?(file) }
                menu.addItem(.separator())
                menu.addBlock("Copy") { column?.textView.copy(nil) }
                return menu
            }
            block.column = column
        case let .note(text, action):
            let note = AllFilesNote(frame: NSRect(x: 0, y: Self.headerHeight, width: block.bounds.width, height: Self.noteHeight))
            note.autoresizingMask = [.width]
            note.show(text, action: action)
            note.onAction = { [weak self, weak entry] in
                guard let self, let entry else { return }
                self.showAnyway(entry)
            }
            block.addSubview(note)
        }
        page.addSubview(block)
        entry.block = block
        return block
    }

    private func build() {
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = Theme.text
        foldAll.bezelStyle = .rounded
        foldAll.controlSize = .small
        foldAll.font = .systemFont(ofSize: 11)
        foldAll.target = self
        foldAll.action = #selector(foldAllClicked)
        foldAll.toolTip = "Fold every file away, or open them all"
        header.setViews([titleLabel, counts, NSView(), foldAll], in: .leading)
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        header.wantsLayer = true
        header.layer?.backgroundColor = Theme.bar.cgColor
        scroll.documentView = page
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.background
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.layoutVisible()
        }
        message.textColor = Theme.textDim
        message.alignment = .center
        message.isHidden = true
        for view in [header, scroll, message] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            message.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
        ])
        setAccessibilityLabel("All files")
    }
}

/// The page the files are laid on, top to bottom.
final class AllFilesPage: NSView {
    override var isFlipped: Bool { true }
}

/// One file on the All files page: its header, then its rows or a note.
final class AllFilesBlock: NSView {
    let header: AllFilesHeader
    weak var column: UnifiedColumn?

    override init(frame: NSRect) {
        header = AllFilesHeader(frame: NSRect(x: 0, y: 0, width: frame.width, height: AllFilesView.headerHeight))
        super.init(frame: frame)
        header.autoresizingMask = [.width]
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        WorkSplitView.line.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// A file's header on the All files page: a chevron that folds it away (a click anywhere on the row does),
/// its icon, name, folder and +N −M, a mark when added, deleted or renamed, then Open File and Show Side by
/// Side.
final class AllFilesHeader: NSView {
    private let chevron = NSImageView()
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let counts = NSTextField(labelWithString: "")
    private let open = NSButton()
    private let sideBySide = NSButton()
    private var collapsed = false
    var onToggle: (() -> Void)?
    var onOpen: (() -> Void)?
    var onSideBySide: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.bar.cgColor
        chevron.contentTintColor = Theme.textDim
        Typography.singleLine(name, truncation: .byTruncatingMiddle)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        counts.setContentHuggingPriority(.required, for: .horizontal)
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)
        for (button, symbol, tip, action) in [(open, "doc.text", "Open File", #selector(openClicked)),
                                              (sideBySide, "rectangle.split.2x1", "Show Side by Side", #selector(sideBySideClicked))] {
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            button.contentTintColor = Theme.textDim
            button.toolTip = tip
            button.setAccessibilityLabel(tip)
            button.target = self
            button.action = action
        }
        for view in [chevron, icon, name, counts, open, sideBySide] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 8),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            counts.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8),
            counts.centerYAnchor.constraint(equalTo: centerYAnchor),
            counts.trailingAnchor.constraint(lessThanOrEqualTo: open.leadingAnchor, constant: -12),
            open.trailingAnchor.constraint(equalTo: sideBySide.leadingAnchor, constant: -6),
            open.centerYAnchor.constraint(equalTo: centerYAnchor),
            open.widthAnchor.constraint(equalToConstant: 24),
            sideBySide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sideBySide.centerYAnchor.constraint(equalTo: centerYAnchor),
            sideBySide.widthAnchor.constraint(equalToConstant: 24),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ file: ChangedFile, root: String, collapsed: Bool) {
        self.collapsed = collapsed
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        icon.image = FileIcons.icon(for: URL(fileURLWithPath: root).appendingPathComponent(file.path), size: 16)
        let folder = (file.path as NSString).deletingLastPathComponent
        let text = NSMutableAttributedString(string: (file.path as NSString).lastPathComponent, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: file.status == .deleted ? Theme.textDim : Theme.text,
        ])
        if !folder.isEmpty {
            text.append(Typography.gap(7, font: .systemFont(ofSize: 12)))
            text.append(NSAttributedString(string: folder, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.textDim]))
        }
        if let mark = GitDiffFileCell.mark(file.status) {
            text.append(Typography.gap(7, font: .systemFont(ofSize: 12)))
            text.append(NSAttributedString(string: mark, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .bold),
                                                                       .foregroundColor: GitFileCell.color(file.status)]))
        }
        name.attributedStringValue = Typography.truncating(text, .byTruncatingMiddle)
        counts.attributedStringValue = GitDiffFileCell.numbers(added: file.added, removed: file.removed, binary: file.isBinary)
        open.isEnabled = file.status != .deleted
        let from = file.oldPath.map { ", renamed from \($0)" } ?? ""
        toolTip = file.path + from + (collapsed ? "\nClick to show its changes" : "\nClick to fold it away")
        let lines = file.added.map { ", \($0) lines added, \(file.removed ?? 0) removed" } ?? ""
        setAccessibilityLabel("\(file.path), \(GitDiffFileCell.describe(file.status))\(from)\(lines), \(collapsed ? "folded away" : "shown")")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for button in [open, sideBySide] where button.frame.contains(local) { return button }
        return frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onToggle?() }
    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(NSRect(x: 0, y: 0, width: max(0, open.frame.minX - 4), height: bounds.height), cursor: .pointingHand)
    }

    @objc private func openClicked() { onOpen?() }
    @objc private func sideBySideClicked() { onSideBySide?() }
}

/// Instead of a file's rows: why there are none, or "Large diff" with Show anyway.
final class AllFilesNote: NSView {
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    var onAction: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.textDim
        Typography.singleLine(label, truncation: .byTruncatingTail)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.target = self
        button.action = #selector(clicked)
        for view in [label, button] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ text: String, action: String?) {
        label.stringValue = text
        button.title = action ?? ""
        button.isHidden = action == nil
    }

    @objc private func clicked() { onAction?() }
}
