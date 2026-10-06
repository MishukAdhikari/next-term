import AppKit
import NextTermCore
import Shiki

/// A file's changes side by side: the old version on the left, the new on the right, rows aligned,
/// removed lines tinted red, added green, the changed words within a line stronger, both sides
/// syntax-coloured and scrolling together. Hunk by hunk you can stage, unstage or revert, each checked
/// against what the diff was made from, so a change an agent made meanwhile is never overwritten.
final class DiffPane: NSView {
    let root: String
    /// Relative to `root`.
    let path: String
    var base: GitRunner.DiffBase { didSet { if oldValue != base { baseControl.selectedSegment = Self.bases.firstIndex(of: base) ?? 0; reload() } } }
    var onTitleChange: (() -> Void)?

    static let bases: [GitRunner.DiffBase] = [.head, .unstaged, .staged]

    private let header = NSStackView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let baseControl = NSSegmentedControl(labels: ["All Changes", "Unstaged", "Staged"], trackingMode: .selectOne, target: nil, action: nil)
    private let counts = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private let position = NSTextField(labelWithString: "")
    private let stage = NSButton(title: "Stage Hunk", target: nil, action: nil)
    private let unstage = NSButton(title: "Unstage Hunk", target: nil, action: nil)
    private let revert = NSButton(title: "Revert Hunk", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let left = DiffColumn(side: .left)
    private let right = DiffColumn(side: .right)
    private let columns = NSStackView()

    private var file: FileDiff?
    private var rows: [SideBySideRow] = []
    /// Row index of each hunk's header, in order.
    private var hunkRows: [Int] = []
    private(set) var currentHunk = 0
    private var generation = 0
    private var stamps: (file: FileStamp?, index: FileStamp?) = (nil, nil)
    private var syncing = false
    /// Scrolling done by the stepper, which must not re-pick the hunk from the scroll position.
    private var steering = false
    private static let git = GitRunner.locateGit()

    var absolutePath: String { (root as NSString).appendingPathComponent(path) }
    var title: String { (path as NSString).lastPathComponent + " ↔ " + ["HEAD", "Index", "HEAD"][Self.bases.firstIndex(of: base) ?? 0] }
    var tooltip: String { "Changes in \(path) — " + ["working tree against HEAD", "working tree against the index (unstaged)", "index against HEAD (staged)"][Self.bases.firstIndex(of: base) ?? 0] }
    var focusView: NSView { right.textView }
    /// For the self-test: the hunks shown and the text of each side.
    var hunkCount: Int { hunkRows.count }
    var sideTexts: (String, String) { (left.textView.string, right.textView.string) }

    func matches(root: String, path: String) -> Bool { self.root == root && self.path == path }

    init(root: String, path: String, base: GitRunner.DiffBase) {
        self.root = root
        self.path = path
        self.base = base
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        build()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let folder = (path as NSString).deletingLastPathComponent
        let text = NSMutableAttributedString(string: (path as NSString).lastPathComponent,
                                             attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Theme.text])
        if !folder.isEmpty {
            text.append(Typography.gap(8, font: .systemFont(ofSize: 12)))
            text.append(NSAttributedString(string: folder, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.textDim]))
        }
        pathLabel.attributedStringValue = Typography.truncating(text, .byTruncatingMiddle)
        Typography.singleLine(pathLabel, truncation: .byTruncatingMiddle)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        baseControl.selectedSegment = Self.bases.firstIndex(of: base) ?? 0
        baseControl.controlSize = .small
        baseControl.target = self
        baseControl.action = #selector(baseChanged)
        counts.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        for (button, symbol, tip, action) in [(previous, "chevron.up", "Previous change", #selector(previousHunk)),
                                              (next, "chevron.down", "Next change", #selector(nextHunk))] {
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            button.contentTintColor = Theme.textDim
            button.toolTip = tip
            button.target = self
            button.action = action
        }
        position.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        position.textColor = Theme.textDim
        for (button, action, tip) in [(stage, #selector(stageHunk), "Stage this change (git add, for these lines only)"),
                                      (unstage, #selector(unstageHunk), "Unstage this change"),
                                      (revert, #selector(revertHunk), "Undo this change in the file")] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self
            button.action = action
            button.toolTip = tip
        }
        header.setViews([pathLabel, baseControl, counts, NSView(), previous, position, next, stage, unstage, revert], in: .leading)
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        header.wantsLayer = true
        header.layer?.backgroundColor = Theme.bar.cgColor

        message.textColor = Theme.textDim
        message.alignment = .center
        message.isHidden = true

        columns.setViews([left, right], in: .leading)
        columns.distribution = .fillEqually
        columns.spacing = 1
        columns.wantsLayer = true
        columns.layer?.backgroundColor = WorkSplitView.line.cgColor // the line between the sides

        for view in [header, columns, message] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            columns.topAnchor.constraint(equalTo: header.bottomAnchor),
            columns.leadingAnchor.constraint(equalTo: leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: trailingAnchor),
            columns.bottomAnchor.constraint(equalTo: bottomAnchor),
            message.centerYAnchor.constraint(equalTo: columns.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
        ])
        // The sides scroll together, both ways.
        for (column, other) in [(left, right), (right, left)] {
            column.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: column.contentView, queue: .main) { [weak self] _ in
                guard let self, !self.syncing else { return }
                self.syncing = true
                other.contentView.scroll(to: column.contentView.bounds.origin)
                other.reflectScrolledClipView(other.contentView)
                self.syncing = false
                if !self.steering { self.updateCurrentHunk() }
            }
        }
    }

    // MARK: loading

    /// Diffs again, keeping the scroll position.
    func reload() {
        generation += 1
        let token = generation
        let root = self.root, path = self.path, base = self.base
        let absolute = absolutePath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let git = Self.git else { return DispatchQueue.main.async { self?.show(nil, message: "Git is not installed.", token: token) } }
            let tracked = GitRunner.isTracked(path, in: root, git: git)
            let diff = GitRunner.diff(of: path, in: root, git: git, base: tracked ? base : .head, untracked: !tracked && base != .staged)
            let stamps = (FileStamp(path: absolute), FileStamp(path: (root as NSString).appendingPathComponent(".git/index")))
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.stamps = stamps
                self.show(diff, message: nil, token: token)
            }
        }
    }

    /// The file or the index changed (an agent, a commit, a stage): diff again.
    func refreshIfChanged() {
        let now = (FileStamp(path: absolutePath), FileStamp(path: (root as NSString).appendingPathComponent(".git/index")))
        if now.0 != stamps.file || now.1 != stamps.index { reload() }
    }

    private func show(_ diff: FileDiff?, message text: String?, token: Int) {
        file = diff
        let empty = diff == nil || diff?.hunks.isEmpty == true
        if let text {
            message.stringValue = text
        } else if diff?.isBinary == true {
            message.stringValue = "This is a binary file: its contents cannot be compared line by line."
        } else if empty {
            message.stringValue = ["No changes against the last commit.", "No unstaged changes.", "No staged changes."][Self.bases.firstIndex(of: base) ?? 0]
        }
        let showRows = !(empty || diff?.isBinary == true || text != nil)
        message.isHidden = showRows
        columns.isHidden = !showRows
        rows = showRows ? SideBySide.rows(for: diff!) : []
        hunkRows = rows.indices.filter { rows[$0].kind == .hunkHeader }
        let origin = right.contentView.bounds.origin
        let language = EditorLanguage.id(forFileName: (path as NSString).lastPathComponent)
        left.show(rows, language: language)
        right.show(rows, language: language)
        right.contentView.scroll(to: NSPoint(x: origin.x, y: min(origin.y, max(0, right.textView.frame.height - right.contentView.bounds.height))))
        right.reflectScrolledClipView(right.contentView)
        currentHunk = min(currentHunk, max(0, hunkRows.count - 1))
        steering = true
        defer { steering = false }
        let added = diff?.hunks.reduce(0) { $0 + $1.added } ?? 0, removed = diff?.hunks.reduce(0) { $0 + $1.removed } ?? 0
        let numbers = NSMutableAttributedString()
        if added > 0 { numbers.append(NSAttributedString(string: "+\(added)", attributes: [.foregroundColor: Theme.linesAdded])) }
        if removed > 0 {
            if numbers.length > 0 { numbers.append(NSAttributedString(string: " ")) }
            numbers.append(NSAttributedString(string: "−\(removed)", attributes: [.foregroundColor: Theme.linesRemoved]))
        }
        counts.attributedStringValue = numbers
        updateButtons()
        updateCurrentHunk()
        onTitleChange?()
    }

    func applyFont() {
        left.show(rows, language: EditorLanguage.id(forFileName: (path as NSString).lastPathComponent))
        right.show(rows, language: EditorLanguage.id(forFileName: (path as NSString).lastPathComponent))
    }

    // MARK: hunks

    private func updateButtons() {
        let has = !hunkRows.isEmpty
        stage.isHidden = base != .unstaged
        unstage.isHidden = base != .staged
        revert.isHidden = base == .staged
        for button in [stage, unstage, revert, previous, next] { button.isEnabled = has }
        position.stringValue = has ? "\(currentHunk + 1) of \(hunkRows.count)" : ""
    }

    /// When you scroll, the hunk at the top of the view becomes the one the buttons act on (unless the
    /// whole diff fits: then only the stepper or a click picks it).
    private func updateCurrentHunk() {
        guard !hunkRows.isEmpty else { return }
        if right.textView.frame.height > right.contentView.bounds.height + 1 {
            let top = right.contentView.bounds.minY + right.rowHeight * 2
            let row = Int(max(0, top - right.textView.textContainerInset.height) / right.rowHeight)
            currentHunk = (hunkRows.lastIndex { $0 <= row }) ?? 0
        }
        showCurrentHunk()
    }

    private func showCurrentHunk() {
        guard hunkRows.indices.contains(currentHunk) else { return }
        position.stringValue = "\(currentHunk + 1) of \(hunkRows.count)"
        left.currentHunkRow = hunkRows[currentHunk]
        right.currentHunkRow = hunkRows[currentHunk]
    }

    /// A click in a row picks its hunk.
    func select(row: Int) {
        guard let hunk = rows[safe: row]?.hunkIndex, hunkRows.indices.contains(hunk) else { return }
        currentHunk = hunk
        showCurrentHunk()
    }

    @objc private func previousHunk() { go(toHunk: currentHunk - 1) }
    @objc private func nextHunk() { go(toHunk: currentHunk + 1) }

    func go(toHunk index: Int) {
        guard !hunkRows.isEmpty else { return }
        let target = (index + hunkRows.count) % hunkRows.count
        let y = right.textView.textContainerInset.height + CGFloat(hunkRows[target]) * right.rowHeight - right.rowHeight
        steering = true
        right.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, right.textView.frame.height - right.contentView.bounds.height))))
        right.reflectScrolledClipView(right.contentView)
        steering = false
        currentHunk = target
        showCurrentHunk()
    }

    @objc private func baseChanged() {
        base = Self.bases[max(0, baseControl.selectedSegment)]
        onTitleChange?()
    }

    @objc private func stageHunk() { perform(.stage) }
    @objc private func unstageHunk() { perform(.unstage) }

    @objc private func revertHunk() {
        guard let window else { return }
        // Unsaved edits to this file in the editor would be overwritten by the reload: ask to save first.
        if let open = (window.windowController as? TerminalWindowController)?.editorArea.documents.first(where: { $0.path == canonicalPath(absolutePath) }),
           open.isDirty {
            let alert = NSAlert()
            alert.messageText = "“\((path as NSString).lastPathComponent)” has unsaved changes in the editor"
            alert.informativeText = "Save or close it before reverting a change in it."
            alert.beginSheetModal(for: window)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Revert this change in “\((path as NSString).lastPathComponent)”?"
        alert.informativeText = "The lines go back to how they were. You can undo this with ⌘Z."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.perform(.revert) }
        }
    }

    /// Runs a hunk operation; tells the user if the file changed meanwhile or git is busy.
    func perform(_ action: HunkOps.Action) {
        guard let file, let git = Self.git, hunkRows.indices.contains(currentHunk), file.hunks.indices.contains(currentHunk) else { return NSSound.beep() }
        let hunk = file.hunks[currentHunk]
        let before = action == .revert ? try? Data(contentsOf: URL(fileURLWithPath: absolutePath)) : nil
        let outcome = HunkOps.perform(action, hunk: hunk, in: file, root: root, git: git)
        switch outcome {
        case .done:
            if action == .revert, let before { registerUndo(restoring: before) }
        case .changedSinceDiff:
            tell("The file changed since this diff was made", "Nothing was changed. The diff is up to date again: check it and try once more.")
        case .gitBusy:
            tell("Git is busy", "Another git command (perhaps an agent committing) holds the index. Try again in a moment.")
        case .failed:
            tell("That change could not be applied", "Git refused it. The diff is refreshed.")
        }
        reload()
    }

    /// ⌘Z after a revert puts the file back, if nothing changed it since.
    private func registerUndo(restoring data: Data) {
        let url = URL(fileURLWithPath: absolutePath)
        let after = try? Data(contentsOf: url)
        window?.undoManager?.registerUndo(withTarget: self) { pane in
            guard (try? Data(contentsOf: url)) == after else { return pane.tell("The file changed since", "The revert was not undone, so nothing is lost.") }
            try? TextFile.write(data, to: url)
            pane.reload()
        }
        window?.undoManager?.setActionName("Revert Change")
    }

    private func tell(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

/// One side of the diff: a read-only text view with fixed-height rows, tinted per row, with line numbers.
final class DiffColumn: NSScrollView {
    enum Side { case left, right }
    let side: Side
    let textView: DiffTextView
    private let spacing = LineSpacing()
    var rowHeight: CGFloat { spacing.lineHeight }
    var currentHunkRow: Int? { didSet { if currentHunkRow != oldValue { textView.needsDisplay = true } } }

    init(side: Side) {
        self.side = side
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 6
        layout.addTextContainer(container)
        textView = DiffTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
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
        textView.usesFindBar = true
        textView.setAccessibilityLabel(side == .left ? "Before" : "After")
        documentView = textView
        hasVerticalScroller = side == .right
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = true
        backgroundColor = Theme.background
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets()
        let ruler = DiffRuler(column: self)
        verticalRulerView = ruler
        hasVerticalRuler = true
        rulersVisible = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private(set) var rows: [SideBySideRow] = []

    /// Line number shown on each row (nil: a filler or a hunk header).
    func number(at row: Int) -> Int? {
        guard rows.indices.contains(row) else { return nil }
        return side == .left ? rows[row].left?.oldNumber : rows[row].right?.newNumber
    }

    func show(_ rows: [SideBySideRow], language: String?) {
        self.rows = rows
        let font = EditorDocument.font
        spacing.font = font
        spacing.factor = AppDelegate.shared?.editorLineHeight ?? 1.35
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = spacing.lineHeight
        style.maximumLineHeight = spacing.lineHeight
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.terminalForeground, .paragraphStyle: style]
        let text = NSMutableAttributedString()
        var lineStarts: [Int] = []
        for row in rows {
            lineStarts.append(text.length)
            let line: String
            if row.kind == .hunkHeader {
                line = ""
            } else {
                line = (side == .left ? row.left?.text : row.right?.text) ?? ""
            }
            text.append(NSAttributedString(string: line.replacingOccurrences(of: "\r", with: "") + "\n", attributes: base))
        }
        // Syntax colours, carrying the grammar's state down each side.
        if let engine = SyntaxEngine.shared, var grammar = engine.language(language) {
            if grammar == "php" { grammar = engine.language("blade") ?? grammar }
            var state: ShikiGrammarState?
            for (i, row) in rows.enumerated() where row.kind != .hunkHeader {
                guard let line = side == .left ? row.left?.text : row.right?.text, line.count < 2000 else { continue }
                guard let result = engine.tokenize(line: line, language: grammar, after: state) else { continue }
                state = result.state
                for token in result.tokens {
                    guard let color = engine.color(token.color) else { continue }
                    let range = NSRange(location: lineStarts[i] + token.offset, length: (token.content as NSString).length)
                    if NSMaxRange(range) <= text.length { text.addAttribute(.foregroundColor, value: color, range: range) }
                }
            }
        }
        // The words that changed within a changed line.
        let wordTint = (side == .left ? Theme.linesRemoved : Theme.linesAdded).withAlphaComponent(0.32)
        for (i, row) in rows.enumerated() where row.kind == .changed {
            for range in side == .left ? row.leftChanges : row.rightChanges {
                let shifted = NSRange(location: lineStarts[i] + range.location, length: range.length)
                if NSMaxRange(shifted) <= text.length { text.addAttribute(.backgroundColor, value: wordTint, range: shifted) }
            }
        }
        textView.textStorage?.setAttributedString(text)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.sizeToFit()
        let height = textView.textContainerInset.height * 2 + CGFloat(rows.count) * spacing.lineHeight
        textView.setFrameSize(NSSize(width: max(textView.frame.width, contentSize.width), height: max(height, contentSize.height)))
        (verticalRulerView as? DiffRuler)?.updateThickness()
        verticalRulerView?.needsDisplay = true
        textView.needsDisplay = true
    }
}

/// Paints each row's tint under the text: removed red, added green, a quiet hatch where the other side
/// has the line, a band for each hunk's start.
final class DiffTextView: NSTextView {
    weak var column: DiffColumn?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard let column, column.rowHeight > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let row = Int((point.y - textContainerInset.height) / column.rowHeight)
        var view: NSView? = superview
        while let current = view, !(current is DiffPane) { view = current.superview }
        (view as? DiffPane)?.select(row: row)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let column else { return }
        let height = column.rowHeight
        let top = textContainerInset.height
        let first = max(0, Int((rect.minY - top) / height))
        let last = min(column.rows.count - 1, Int((rect.maxY - top) / height) + 1)
        guard first <= last else { return }
        for index in first...last {
            let row = column.rows[index]
            let band = NSRect(x: 0, y: top + CGFloat(index) * height, width: bounds.width, height: height)
            let mine = column.side == .left ? row.left : row.right
            switch row.kind {
            case .hunkHeader:
                (index == column.currentHunkRow ? NSColor(hex: 0x2E3440) : NSColor(hex: 0x26282E)).setFill()
                band.fill()
                if let hunk = row.hunkIndex {
                    let label = "⋯  change \(hunk + 1)" as NSString
                    label.draw(at: NSPoint(x: 8, y: band.minY + (height - 14) / 2), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: Theme.textDim,
                    ])
                }
            case .removed, .added, .changed:
                if mine == nil {
                    NSColor(hex: 0x232428).setFill() // the line exists only on the other side
                    band.fill()
                } else {
                    (column.side == .left ? Theme.linesRemoved : Theme.linesAdded).withAlphaComponent(0.12).setFill()
                    band.fill()
                }
            case .unchanged:
                break
            }
        }
    }
}

/// Line numbers for one side of a diff (blank on filler and header rows).
final class DiffRuler: NSRulerView {
    private weak var column: DiffColumn?

    init(column: DiffColumn) {
        self.column = column
        super.init(scrollView: column, orientation: .verticalRuler)
        clientView = column.textView
        clipsToBounds = true
        ruleThickness = 40
    }

    required init(coder: NSCoder) { fatalError("not used") }

    func updateThickness() {
        let largest = column?.rows.compactMap { column?.side == .left ? $0.left?.oldNumber : $0.right?.newNumber }.max() ?? 0
        let digits = max(3, String(largest).count)
        ruleThickness = CGFloat(digits) * 8 + 18
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        guard let column, let text = clientView as? NSTextView else { return }
        let height = column.rowHeight
        let offset = convert(NSPoint.zero, from: text).y
        let visible = column.contentView.bounds
        let top = text.textContainerInset.height
        let first = max(0, Int((visible.minY - top) / height))
        let last = min(column.rows.count - 1, Int((visible.maxY - top) / height) + 1)
        guard first <= last else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, (EditorDocument.font.pointSize) - 1.5), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(hex: 0x5A5F69)]
        for index in first...last {
            guard let number = column.number(at: index) else { continue }
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = top + CGFloat(index) * height + offset + (height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)
        }
    }
}
