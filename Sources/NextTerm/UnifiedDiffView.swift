import AppKit
import NextTermCore
import Shiki

/// Side by Side or Unified: one choice for every diff, remembered, from the switch at the top of any diff
/// or View › Unified Diffs.
enum DiffLayout: String {
    case sideBySide, unified

    /// Posted when the choice changes, for every open diff to follow.
    static let changed = Notification.Name("NextTermDiffLayoutChanged")
    private static let key = "diffLayout"

    static var current: DiffLayout {
        get { DiffLayout(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .sideBySide }
        set {
            guard newValue != current else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}

/// View › Unified Diffs: checked while diffs show in one column.
final class DiffLayoutMenu: NSObject, NSMenuItemValidation {
    static let shared = DiffLayoutMenu()

    @objc func toggleUnifiedDiffs(_ sender: Any?) {
        DiffLayout.current = DiffLayout.current == .unified ? .sideBySide : .unified
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.state = DiffLayout.current == .unified ? .on : .off
        return true
    }
}

/// A diff in one column, top to bottom (UnifiedRows): removed lines on red with "−" and the old line's
/// number, added lines on green with "+" and the new one's, unchanged lines between, folds that open on a
/// click. Read-only text, syntax-coloured, the changed words marked. Rows have one height, so a row is
/// found from its place. In a diff tab it scrolls both ways; on the All files page it scrolls sideways
/// only and is as tall as its rows, the page scrolling it.
final class UnifiedColumn: NSScrollView {
    let textView: UnifiedTextView
    let scrollsVertically: Bool
    private let spacing = LineSpacing()
    var rowHeight: CGFloat { spacing.lineHeight }
    private(set) var rows: [UnifiedRow] = []
    /// Where each row's text starts (UTF-16).
    private(set) var starts: [Int] = []
    /// The rows of this hunk are marked as the one the hunk buttons act on.
    var currentHunk: Int? {
        didSet {
            guard currentHunk != oldValue else { return }
            textView.needsDisplay = true
            verticalRulerView?.needsDisplay = true
        }
    }
    var onFoldClick: ((UnifiedFold) -> Void)?
    var onRowClick: ((Int) -> Void)?
    /// The menu for a right-click on a row.
    var menuForRow: ((Int) -> NSMenu?)?
    /// The view scrolled (not the page around it).
    var onScroll: (() -> Void)?

    init(scrollsVertically: Bool = true) {
        self.scrollsVertically = scrollsVertically
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 6
        layout.addTextContainer(container)
        textView = UnifiedTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        super.init(frame: .zero)
        layout.delegate = spacing
        textView.column = self
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = Theme.background
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.usesFindBar = scrollsVertically
        textView.setAccessibilityLabel("Changes, one column")
        documentView = textView
        hasVerticalScroller = scrollsVertically
        verticalScrollElasticity = scrollsVertically ? .automatic : .none
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = true
        backgroundColor = Theme.background
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets()
        verticalRulerView = UnifiedRuler(column: self)
        hasVerticalRuler = true
        rulersVisible = true
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in
            self?.onScroll?()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// All the rows' height, with the margin above and below: the height the page gives it.
    var contentHeight: CGFloat { textView.textContainerInset.height * 2 + CGFloat(rows.count) * rowHeight }

    /// A row's height in the editor's font and line height, before any column shows one.
    static var standardRowHeight: CGFloat {
        let spacing = LineSpacing()
        spacing.font = EditorDocument.font
        spacing.factor = AppDelegate.shared?.editorLineHeight ?? 1.35
        return spacing.lineHeight
    }

    /// On the page, the wheel's up and down go to the page; sideways stays here.
    override func scrollWheel(with event: NSEvent) {
        if !scrollsVertically, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            var view = superview
            while let current = view, !(current is NSScrollView) { view = current.superview }
            if let page = view { return page.scrollWheel(with: event) }
        }
        super.scrollWheel(with: event)
    }

    /// Shows `rows`, keeping the scroll position.
    func show(_ rows: [UnifiedRow], language: String?) {
        self.rows = rows
        let font = EditorDocument.font
        spacing.font = font
        spacing.factor = AppDelegate.shared?.editorLineHeight ?? 1.35
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = spacing.lineHeight
        style.maximumLineHeight = spacing.lineHeight
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.terminalForeground, .paragraphStyle: style]
        let foldText: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(10, font.pointSize - 1.5)), .foregroundColor: Theme.textDim,
                                                       .paragraphStyle: style]
        let text = NSMutableAttributedString()
        var starts: [Int] = []
        starts.reserveCapacity(rows.count)
        for row in rows {
            starts.append(text.length)
            if let fold = row.fold {
                text.append(NSAttributedString(string: fold.title + "\n", attributes: foldText))
            } else {
                let line = (row.line?.text ?? "").replacingOccurrences(of: "\r", with: "")
                text.append(NSAttributedString(string: line + "\n", attributes: base))
            }
        }
        self.starts = starts
        colour(text, language: language)
        // The words that changed within a changed line.
        for (i, row) in rows.enumerated() where !row.changes.isEmpty {
            let tint = (row.kind == .removed ? Theme.linesRemoved : Theme.linesAdded).withAlphaComponent(0.32)
            for range in row.changes {
                let shifted = NSRange(location: starts[i] + range.location, length: range.length)
                if NSMaxRange(shifted) <= text.length { text.addAttribute(.backgroundColor, value: tint, range: shifted) }
            }
        }
        let origin = contentView.bounds.origin
        textView.textStorage?.setAttributedString(text)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        (verticalRulerView as? UnifiedRuler)?.updateThickness()
        tile()
        textView.sizeToFit()
        fitText()
        verticalRulerView?.needsDisplay = true
        textView.needsDisplay = true
        let bottom = max(0, textView.frame.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: horizontal(contentView.bounds.origin.x), y: scrollsVertically ? min(origin.y, bottom) : 0))
        reflectScrolledClipView(contentView)
    }

    /// The gutter sits over the clip view, which starts scrolled left by the gutter's width: unless the
    /// text was scrolled sideways, it starts after the gutter, however wide that is now.
    private var home: CGFloat = 0
    private func horizontal(_ x: CGFloat) -> CGFloat {
        let now = -contentView.contentInsets.left
        defer { home = now }
        return abs(x - home) < 0.5 || x < now ? now : x
    }

    /// The text at least as wide and as tall as the view, so the rows' tints reach its edges.
    private func fitText() {
        let insets = contentView.contentInsets
        let visible = NSSize(width: contentView.frame.width - insets.left - insets.right, height: contentView.frame.height - insets.top - insets.bottom)
        let width = max(textView.frame.width, visible.width), height = max(contentHeight, visible.height)
        if textView.frame.size != NSSize(width: width, height: height) { textView.setFrameSize(NSSize(width: width, height: height)) }
    }

    override func tile() {
        super.tile()
        fitText()
        let x = contentView.bounds.origin.x, wanted = horizontal(x)
        if abs(wanted - x) > 0.5 {
            contentView.scroll(to: NSPoint(x: wanted, y: contentView.bounds.origin.y))
            reflectScrolledClipView(contentView)
        }
    }

    /// Syntax colours, with the old file's state carried down the removed lines and the new file's down
    /// the added ones (an unchanged line carries on both).
    private func colour(_ text: NSMutableAttributedString, language: String?) {
        guard let engine = SyntaxEngine.shared, var grammar = engine.language(language) else { return }
        if grammar == "php" { grammar = engine.language("blade") ?? grammar }
        var old: ShikiGrammarState?, new: ShikiGrammarState?
        for (i, row) in rows.enumerated() where row.kind != .fold {
            guard let raw = row.line?.text, raw.count < 2000 else { continue }
            let line = raw.replacingOccurrences(of: "\r", with: "")
            guard let result = engine.tokenize(line: line, language: grammar, after: row.kind == .removed ? old : new) else { continue }
            switch row.kind {
            case .removed: old = result.state
            case .added: new = result.state
            case .context, .fold:
                old = result.state
                new = result.state
            }
            for token in result.tokens {
                guard let color = engine.color(token.color) else { continue }
                let range = NSRange(location: starts[i] + token.offset, length: (token.content as NSString).length)
                if NSMaxRange(range) <= text.length { text.addAttribute(.foregroundColor, value: color, range: range) }
            }
        }
    }

    // MARK: rows

    /// The row at `y` in the text view, if there is one.
    func row(atY y: CGFloat) -> Int? {
        guard rowHeight > 0 else { return nil }
        let row = Int(floor((y - textView.textContainerInset.height) / rowHeight))
        return rows.indices.contains(row) ? row : nil
    }

    /// The row holding the character at `offset`.
    func row(atOffset offset: Int) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return max(0, low)
    }

    /// The rows under the selection (none without one).
    func selectedRows() -> [Int] {
        let range = textView.selectedRange()
        guard range.length > 0, !rows.isEmpty else { return [] }
        // A selection ending at the start of a row does not include that row.
        let first = row(atOffset: range.location), last = row(atOffset: max(range.location, NSMaxRange(range) - 1))
        return Array(first...max(first, last)).filter { rows.indices.contains($0) }
    }

    /// Selects `row`'s text (a right-click on a row outside the selection).
    func select(row: Int) {
        guard starts.indices.contains(row) else { return }
        let end = row + 1 < starts.count ? starts[row + 1] : (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: starts[row], length: max(0, end - starts[row])))
    }

    /// The first row of each hunk, by hunk.
    var hunkStarts: [Int: Int] {
        var firsts: [Int: Int] = [:]
        for (index, row) in rows.enumerated() {
            if let hunk = row.hunk, firsts[hunk] == nil { firsts[hunk] = index }
        }
        return firsts
    }

    /// The row at the top of the view, two rows in.
    var topRow: Int {
        let top = contentView.bounds.minY + rowHeight * 2
        return max(0, Int((top - textView.textContainerInset.height) / max(1, rowHeight)))
    }

    var isTallerThanView: Bool { textView.frame.height > contentView.bounds.height + 1 }

    /// Scrolls so `row` is a row below the top.
    func scroll(toRow row: Int) {
        let y = textView.textContainerInset.height + CGFloat(row) * rowHeight - rowHeight
        contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: max(0, min(y, textView.frame.height - contentView.bounds.height))))
        reflectScrolledClipView(contentView)
    }

    /// The selected text without the folds' words: what ⌘C copies.
    func copyText() -> String {
        let range = textView.selectedRange()
        let text = textView.string as NSString
        var lines: [String] = []
        for row in selectedRows() where rows[row].kind != .fold {
            let start = starts[row]
            let end = row + 1 < starts.count ? starts[row + 1] - 1 : max(start, text.length - 1)
            let from = max(start, range.location), to = min(end, NSMaxRange(range))
            if to > from { lines.append(text.substring(with: NSRange(location: from, length: to - from))) } else { lines.append("") }
        }
        return lines.joined(separator: "\n")
    }
}

/// The unified column's text: each row's tint painted under it, a click on a fold opens it, a click on a
/// row picks its change, a right-click offers what can be done with it.
final class UnifiedTextView: NSTextView {
    weak var column: UnifiedColumn?

    private func row(for event: NSEvent) -> Int? {
        column?.row(atY: convert(event.locationInWindow, from: nil).y)
    }

    override func mouseDown(with event: NSEvent) {
        if let column, let row = row(for: event), let fold = column.rows[row].fold, event.clickCount == 1 {
            column.onFoldClick?(fold)
            return
        }
        super.mouseDown(with: event)
        if let row = row(for: event) { column?.onRowClick?(row) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if let column, let row = row(for: event), column.rows[row].kind == .fold { NSCursor.pointingHand.set() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let column, let row = row(for: event), column.rows[row].kind != .fold, let menu = column.menuForRow?(row) { return menu }
        return super.menu(for: event)
    }

    override func copy(_ sender: Any?) {
        guard let column, selectedRange().length > 0 else { return super.copy(sender) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(column.copyText(), forType: .string)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let column, !column.rows.isEmpty else { return }
        let height = column.rowHeight
        let top = textContainerInset.height
        let first = max(0, Int((rect.minY - top) / height))
        let last = min(column.rows.count - 1, Int((rect.maxY - top) / height) + 1)
        guard first <= last else { return }
        for index in first...last {
            let band = NSRect(x: rect.minX, y: top + CGFloat(index) * height, width: rect.width, height: height)
            switch column.rows[index].kind {
            case .removed: Theme.linesRemoved.withAlphaComponent(0.12).setFill()
            case .added: Theme.linesAdded.withAlphaComponent(0.12).setFill()
            case .fold: UnifiedRuler.foldBand.setFill()
            case .context: continue
            }
            band.fill()
        }
    }
}

/// The unified column's gutter: a bar, the line number and its "−" or "+" for each row, tinted as the row
/// is; a fold's chevron. It stays put while the text scrolls sideways.
final class UnifiedRuler: NSRulerView {
    static let foldBand = NSColor(hex: 0x26282E)
    private weak var column: UnifiedColumn?

    init(column: UnifiedColumn) {
        self.column = column
        super.init(scrollView: column, orientation: .verticalRuler)
        clientView = column.textView
        clipsToBounds = true
        ruleThickness = 56
    }

    required init(coder: NSCoder) { fatalError("not used") }

    func updateThickness() {
        let largest = column?.rows.compactMap(\.number).max() ?? 0
        ruleThickness = CGFloat(max(3, String(largest).count)) * 8 + 32
    }

    private static let chevron = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))?.tinted(Theme.textDim)

    override func drawHashMarksAndLabels(in rect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        guard let column, let text = clientView as? NSTextView, !column.rows.isEmpty else { return }
        let height = column.rowHeight
        let offset = convert(NSPoint.zero, from: text).y
        let visible = column.contentView.bounds
        let top = text.textContainerInset.height
        // The rows in view and in the rect asked for (on the All files page the column is as tall as its rows).
        let from = max(visible.minY, rect.minY - offset), to = min(visible.maxY, rect.maxY - offset)
        let first = max(0, Int((from - top) / height))
        let last = min(column.rows.count - 1, Int((to - top) / height) + 1)
        guard first <= last else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, EditorDocument.font.pointSize - 1.5), weight: .regular)
        for index in first...last {
            let row = column.rows[index]
            let band = NSRect(x: 0, y: top + CGFloat(index) * height + offset, width: ruleThickness, height: height)
            switch row.kind {
            case .removed, .added:
                let color = row.kind == .removed ? Theme.linesRemoved : Theme.linesAdded
                color.withAlphaComponent(0.16).setFill()
                band.fill()
                color.setFill()
                NSRect(x: 0, y: band.minY, width: 3, height: height).fill()
            case .fold:
                Self.foldBand.setFill()
                band.fill()
                Self.chevron?.draw(in: NSRect(x: 10, y: band.midY - 6, width: 9, height: 12))
                continue
            case .context:
                break
            }
            let current = row.hunk != nil && row.hunk == column.currentHunk
            let dim = NSColor(hex: current ? 0x8C909A : 0x5A5F69)
            if let number = row.number {
                let label = "\(number)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: dim]
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: ruleThickness - 22 - size.width, y: band.minY + (height - size.height) / 2), withAttributes: attributes)
            }
            if !row.marker.isEmpty {
                let color = row.kind == .removed ? Theme.linesRemoved : Theme.linesAdded
                let mark = row.marker as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let size = mark.size(withAttributes: attributes)
                mark.draw(at: NSPoint(x: ruleThickness - 14, y: band.minY + (height - size.height) / 2), withAttributes: attributes)
            }
        }
    }
}

extension NSImage {
    /// A template symbol drawn in one colour.
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}

// MARK: - the Unified view in a diff tab

/// A diff tab's Unified view: the Side by Side | Unified switch in its header, the column, and the whole
/// file (read when a fold needs it) that opens the folds. The diff tab keeps doing everything else; in
/// Unified its hunk buttons and Send to Agent act on the selected lines, or the row clicked.
final class UnifiedDiffPart: NSObject {
    let control = NSSegmentedControl(labels: ["Side by Side", "Unified"], trackingMode: .selectOne, target: nil, action: nil)
    let column = UnifiedColumn()
    private weak var pane: DiffPane?
    private(set) var rows: [UnifiedRow] = []
    /// The file's unchanged lines by old line number, from the diff with the whole file as context.
    private var fill: [Int: DiffLine]?
    /// The diff `fill` was read for: it fills only that one's folds.
    private var fillSource: FileDiff?
    /// Folds opened, by their first old line: they stay open when the diff is read again.
    private(set) var expanded: Set<Int> = []
    /// Bumped with each new diff, so a whole-file read for an older one is dropped.
    private var generation = 0
    /// Scrolling done by the stepper, which must not pick the change from the scroll position again.
    private var steering = false

    var isOn: Bool { DiffLayout.current == .unified }

    func install(in pane: DiffPane, header: NSStackView, before anchor: NSView) {
        self.pane = pane
        control.controlSize = .small
        control.target = self
        control.action = #selector(switched)
        control.selectedSegment = isOn ? 1 : 0
        control.toolTip = "Both versions side by side, or one column top to bottom: every diff follows (View › Unified Diffs)"
        control.setAccessibilityLabel("Diff layout")
        if let at = header.arrangedSubviews.firstIndex(of: anchor) {
            header.insertArrangedSubview(control, at: at)
        } else {
            header.addArrangedSubview(control)
        }
        column.isHidden = true
        column.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: header.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
        column.onFoldClick = { [weak self] fold in self?.open(fold) }
        column.onRowClick = { [weak self] row in
            guard let self, let hunk = self.rows[safe: row]?.hunk else { return }
            self.pane?.pick(hunk: hunk)
        }
        column.onScroll = { [weak self] in self?.scrolled() }
        column.menuForRow = { [weak self] row in self?.menu(for: row) }
        NotificationCenter.default.addObserver(self, selector: #selector(layoutChanged), name: DiffLayout.changed, object: nil)
    }

    @objc private func switched() { DiffLayout.current = control.selectedSegment == 1 ? .unified : .sideBySide }
    @objc private func layoutChanged() { pane?.applyLayout() }

    private func language(_ pane: DiffPane) -> String? { EditorLanguage.id(forFileName: (pane.path as NSString).lastPathComponent) }

    /// The diff was read (again): its rows now if the lines the folds need are known or not needed; else
    /// the rows shown stay until the whole file is read, so nothing flashes shut and open again.
    func update(_ pane: DiffPane) {
        generation += 1
        guard let file = pane.file, !file.hunks.isEmpty else {
            fill = nil
            return render(pane)
        }
        let folds = UnifiedRows.rows(for: file).contains { $0.kind == .fold }
        if !folds || !UnifiedRows.fill(of: fillSource, fits: file) { fill = nil }
        if !folds || fill != nil { return render(pane) }
        if rows.isEmpty { render(pane) }
        readWholeFile(pane)
    }

    private func readWholeFile(_ pane: DiffPane) {
        let token = generation, source = pane.file
        let read = pane.wholeFileReader()
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak pane] in
            let whole = read()
            DispatchQueue.main.async {
                guard let self, let pane, token == self.generation else { return }
                self.fill = whole.map(UnifiedRows.fill(from:))
                self.fillSource = source
                self.render(pane)
            }
        }
    }

    /// Lays the rows out again (a fold opened, the font changed, the diff read again).
    func render(_ pane: DiffPane) {
        rows = pane.file.map { UnifiedRows.rows(for: $0, expanded: expanded, fill: fill) } ?? []
        column.show(rows, language: language(pane))
        column.currentHunk = pane.currentHunk
    }

    /// A fold was clicked: its lines show, now if they are known, else once the whole file is read.
    private func open(_ fold: UnifiedFold) {
        guard let pane else { return }
        expanded.insert(fold.oldStart)
        if fill == nil { readWholeFile(pane) } else { render(pane) }
    }

    /// Scrolls to hunk `index`'s first row.
    func go(toHunk index: Int) {
        guard let row = column.hunkStarts[index] else { return }
        steering = true
        column.scroll(toRow: row)
        steering = false
        column.currentHunk = index
    }

    /// When you scroll, the change at the top of the view becomes the one the buttons act on (unless the
    /// whole diff fits: then only the stepper or a click picks it).
    private func scrolled() {
        guard !steering, isOn, column.isTallerThanView, let pane else { return }
        let top = column.topRow
        let starts = column.hunkStarts.sorted { $0.value < $1.value }
        guard let hunk = starts.last(where: { $0.value <= top })?.key ?? starts.first?.key else { return }
        pane.pick(hunk: hunk)
    }

    /// Before a hunk button acts: the change the selected lines are in, if any are selected.
    func pickForAction(_ pane: DiffPane) {
        if let hunk = column.selectedRows().lazy.compactMap({ self.rows[safe: $0]?.hunk }).first { pane.pick(hunk: hunk) }
    }

    /// A right-click on a row: the hunk actions for its change, Send to Agent, Copy.
    private func menu(for row: Int) -> NSMenu? {
        guard let pane else { return nil }
        if !column.selectedRows().contains(row) { column.select(row: row) }
        let menu = NSMenu()
        if let hunk = rows[safe: row]?.hunk {
            for action in pane.hunkActions {
                let title: String
                switch action {
                case .stage: title = "Stage Hunk"
                case .unstage: title = "Unstage Hunk"
                case .revert: title = "Revert Hunk…"
                }
                menu.addBlock(title) { [weak pane] in
                    guard let pane else { return }
                    pane.pick(hunk: hunk)
                    if action == .revert { pane.revertHunk() } else { pane.perform(action) }
                }
            }
        }
        if pane.proposal == nil {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addBlock("Send to Agent") { [weak pane] in
                (pane?.window?.windowController as? TerminalWindowController)?.sendEditorSelection()
            }
        }
        menu.addBlock("Copy") { [weak self] in self?.column.textView.copy(nil) }
        return menu
    }

    /// Send to Agent from the Unified view, as from the side-by-side one: the file at the selected lines'
    /// numbers in the new file, or the removed lines as code when only those are selected.
    func contextItem(of pane: DiffPane) -> ContextItem? {
        guard pane.proposal == nil else { return nil }
        var item = ContextItem(path: pane.absolutePath)
        let language = self.language(pane) ?? "text"
        let selected = column.selectedRows().compactMap { rows[safe: $0] }.filter { $0.kind != .fold }
        let kept = selected.filter { $0.kind != .removed }
        if kept.isEmpty, !selected.isEmpty {
            // Only removed lines: the file no longer has them, so they are the code.
            let removed = Self.code(selected.compactMap { row in row.line.flatMap { line in line.oldNumber.map { ($0, line.text) } } })
            guard !removed.isEmpty, !AgentPrompt.isTooLargeToInline(removed) else { return nil }
            if let commit = pane.commit {
                item.note = "lines removed in commit \(commit.sha.prefix(7))"
            } else {
                item.note = FileManager.default.fileExists(atPath: pane.absolutePath) ? "lines removed" : "deleted"
            }
            item.code = removed
            item.language = language
            return item
        }
        let numbered = kept.compactMap { row in row.line.flatMap { line in line.newNumber.map { ($0, line.text) } } }
        if let first = numbered.first?.0, let last = numbered.last?.0 { item.lines = first...last }
        if let commit = pane.commit {
            item.note = "as of commit \(commit.sha.prefix(7))"
        } else if pane.base == .staged, item.lines != nil {
            item.note = "as staged"
        } else if !FileManager.default.fileExists(atPath: pane.absolutePath) {
            item.note = "deleted"
        }
        if pane.commit != nil || pane.base == .staged, item.lines != nil {
            let code = Self.code(numbered)
            if !AgentPrompt.isTooLargeToInline(code) {
                item.code = code
                item.language = language
            }
        }
        return item
    }

    /// The lines, with a "⋯" line where their numbers jump (lines not selected, or not shown).
    static func code(_ lines: [(Int, String)]) -> String {
        var out: [String] = []
        var previous: Int?
        for (number, text) in lines {
            if let previous, number != previous + 1 { out.append("⋯") }
            previous = number
            out.append(text)
        }
        return out.joined(separator: "\n")
    }
}

extension DiffPane {
    /// Reads this diff again with the whole file as context, off the main thread: what fills the folds.
    func wholeFileReader() -> () -> FileDiff? {
        let root = self.root, path = self.path, base = self.base, renamedFrom = self.renamedFrom
        let proposal = self.proposal, commit = self.commit, branchChange = self.branchChange
        let lines = UnifiedRows.wholeFile
        return {
            guard let git = GitRunner.locateGit() else { return nil }
            if let proposal {
                func lf(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: "\n") }
                return GitRunner.diff(old: lf(proposal.original), new: lf(proposal.proposed), git: git, context: lines)
            }
            if let commit {
                return CommitLog.diff(of: path, oldPath: commit.oldPath, commit: commit.sha, parent: commit.parent, in: root, git: git, context: lines)
            }
            if let change = branchChange {
                return BranchCompare.diff(of: path, oldPath: change.oldPath, branch: change.branch, base: change.base, in: root, git: git, context: lines)
            }
            if case .ref = base { return GitRunner.diff(of: path, in: root, git: git, base: base, context: lines, oldPath: renamedFrom) }
            let tracked = GitRunner.isTracked(path, in: root, git: git)
            return GitRunner.diff(of: path, in: root, git: git, base: tracked ? base : .head, context: lines, untracked: !tracked && base != .staged)
        }
    }

    /// For the self-test: the Unified view's rows and whether it is the one showing.
    var unifiedRows: [UnifiedRow] { unified.rows }
    var showsUnified: Bool { !unified.column.isHidden }
}
