import AppKit
import NextTermCore

protocol FindInFilesDelegate: AnyObject {
    /// Open a result: the file at a 1-based line.
    func findInFiles(_ controller: FindInFilesController, open url: URL, line: Int)
}

/// Find and Replace in Files for one project window: results grouped by file, updated as you type,
/// with a preview of every replacement before anything is written.
final class FindInFilesController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    weak var delegate: FindInFilesDelegate?
    /// Folder being searched (the project root).
    private(set) var root = ""

    private let queryField = NSTextField()
    private let replaceField = NSTextField()
    private let maskField = NSTextField()
    private let caseButton = NSButton()
    private let wordButton = NSButton()
    private let regexButton = NSButton()
    /// "⇡ .php": files of the type being edited are listed first (on by default, remembered).
    private let typeFirstButton = NSButton()
    private var order = ResultOrder(current: nil)
    private var typeFirst: Bool {
        get { UserDefaults.standard.object(forKey: "searchSameTypeFirst") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "searchSameTypeFirst") }
    }
    private var activeOrder: ResultOrder { typeFirst ? order : ResultOrder(current: nil) }
    private let replaceButton = NSButton(title: "Replace Selected", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "Replace All", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let outline = NSOutlineView()

    private final class FileResult {
        let path: String
        var matches: [SearchMatch]
        init(path: String, matches: [SearchMatch]) { self.path = path; self.matches = matches }
    }
    private var results: [FileResult] = []
    /// Thread-safe "stop": each search gets one; starting a new search cancels the old one.
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    private var running: Cancellation?
    /// Replace mode: previews show what each match would become, even before replace text is typed.
    private var replaceMode = false
    private var debounce: DispatchWorkItem?
    private(set) var isSearching = false
    private static let git = GitRunner.locateGit()

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Find in Files"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 480, height: 300)
        super.init(window: panel)
        panel.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: showing

    /// Opens the panel on `root`, optionally with the replace row focused. `current` is the file being edited
    /// (relative to `root`): it and files of its type are listed first.
    func show(root: String, replacing: Bool, initialText: String?, current: String? = nil, over parent: NSWindow?) {
        order = ResultOrder(current: current)
        if let type = order.typeLabel {
            typeFirstButton.title = "⇡ ." + type
            typeFirstButton.toolTip = "List .\(type) files first (the type you are editing)"
            typeFirstButton.setAccessibilityLabel(typeFirstButton.toolTip)
            typeFirstButton.isHidden = false
        } else {
            typeFirstButton.isHidden = true
        }
        typeFirstButton.state = typeFirst ? .on : .off
        if root != self.root {
            self.root = root
            results = []
            outline.reloadData()
        }
        replaceMode = replacing
        window?.title = (replacing ? "Replace in Files — " : "Find in Files — ") + (root as NSString).lastPathComponent
        if let initialText, !initialText.isEmpty, !initialText.contains("\n") { queryField.stringValue = initialText }
        if let parent, let window, !window.isVisible {
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(replacing && !queryField.stringValue.isEmpty ? replaceField : queryField)
        scheduleSearch(after: 0)
    }

    // MARK: layout

    private func build() {
        guard let content = window?.contentView else { return }
        for (field, placeholder) in [(queryField, "Find"), (replaceField, "Replace with"), (maskField, "File mask, e.g. *.php, !vendor/**")] {
            // What you type is code (monospaced); the hint is interface text.
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.placeholderTextColor,
            ])
            field.delegate = self
            field.font = Theme.monoFont(size: 12)
            field.lineBreakMode = .byClipping
            field.cell?.isScrollable = true
            field.cell?.wraps = false
        }
        for (button, title, tip) in [(caseButton, "Aa", "Match case"), (wordButton, "W", "Whole words"), (regexButton, ".*", "Regular expression")] {
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .recessed
            button.title = title
            button.toolTip = tip
            button.setAccessibilityLabel(tip)
            button.target = self
            button.action = #selector(optionChanged)
            button.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        }
        typeFirstButton.setButtonType(.pushOnPushOff)
        typeFirstButton.bezelStyle = .recessed
        typeFirstButton.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        typeFirstButton.target = self
        typeFirstButton.action = #selector(typeFirstChanged)
        typeFirstButton.isHidden = true
        replaceButton.target = self
        replaceButton.action = #selector(replaceSelected)
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAll)
        status.textColor = .secondaryLabelColor
        Typography.singleLine(status, truncation: .byTruncatingTail)

        let column = NSTableColumn(identifier: .init("result"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 22
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.style = .plain
        outline.allowsMultipleSelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openSelected)
        outline.usesAlternatingRowBackgroundColors = false
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let options = NSStackView(views: [caseButton, wordButton, regexButton, typeFirstButton])
        options.spacing = 4
        let findRow = NSStackView(views: [queryField, options])
        let replaceRow = NSStackView(views: [replaceField, replaceButton, replaceAllButton])
        let maskRow = NSStackView(views: [maskField, status])
        for row in [findRow, replaceRow, maskRow] { row.spacing = 8 }
        maskField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let stack = NSStackView(views: [findRow, replaceRow, maskRow, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            findRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            replaceRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            maskRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        queryField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        replaceField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    // MARK: searching

    var query: SearchQuery {
        let masks = maskField.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return SearchQuery(text: queryField.stringValue, isRegex: regexButton.state == .on,
                           matchCase: caseButton.state == .on, wholeWord: wordButton.state == .on, masks: masks)
    }

    /// For the self-test.
    func setQuery(_ text: String, replacement: String = "", masks: String = "", regex: Bool = false) {
        queryField.stringValue = text
        replaceField.stringValue = replacement
        maskField.stringValue = masks
        regexButton.state = regex ? .on : .off
        scheduleSearch(after: 0)
    }

    var matchCount: Int { results.reduce(0) { $0 + $1.matches.count } }
    var fileCount: Int { results.count }

    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSTextField) === replaceField {
            replaceMode = true
            outline.reloadData() // previews only
            expandAll()
        } else {
            scheduleSearch(after: 0.25)
        }
    }

    @objc private func optionChanged() { scheduleSearch(after: 0) }

    /// Re-sorts what is already found; no new search.
    @objc private func typeFirstChanged() {
        typeFirst = typeFirstButton.state == .on
        let order = activeOrder
        results.sort { order.precedes($0.path, $1.path) }
        outline.reloadData()
        expandAll()
    }

    /// For the self-test: what the Find field holds.
    var queryText: String { queryField.stringValue }

    /// For the self-test: the files in the order they are listed.
    var listedFiles: [String] { results.map(\.path) }

    private func scheduleSearch(after delay: TimeInterval) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.search() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func search() {
        running?.cancel()
        let token = Cancellation()
        running = token
        results = []
        matchItems = [:]
        outline.reloadData()
        let query = self.query
        guard !query.text.isEmpty, !root.isEmpty else {
            isSearching = false
            status.stringValue = ""
            updateButtons()
            return
        }
        do { _ = try query.expression() } catch {
            isSearching = false
            status.stringValue = "Invalid regular expression"
            status.textColor = .systemRed
            updateButtons()
            return
        }
        status.textColor = .secondaryLabelColor
        status.stringValue = "Searching…"
        isSearching = true
        let root = self.root
        DispatchQueue.global(qos: .userInitiated).async {
            let files = ProjectSearch.files(in: root, git: Self.git)
            let total = (try? ProjectSearch.search(root: root, files: files, query: query, isCancelled: { token.isCancelled }, found: { found in
                DispatchQueue.main.async { [weak self] in
                    guard let self, !token.isCancelled else { return }
                    self.add(found)
                }
            })) ?? 0
            DispatchQueue.main.async { [weak self] in
                guard let self, !token.isCancelled else { return }
                self.isSearching = false
                let capped = total >= ProjectSearch.maxMatches ? " (stopped at \(ProjectSearch.maxMatches.formatted()))" : ""
                self.status.stringValue = total == 0 ? "No matches"
                    : "\(self.matchCount.formatted()) match\(self.matchCount == 1 ? "" : "es") in \(self.fileCount.formatted()) file\(self.fileCount == 1 ? "" : "s")\(capped)"
                self.updateButtons()
            }
        }
    }

    private func add(_ found: FileMatches) {
        let entry = FileResult(path: found.relativePath, matches: found.matches)
        let order = activeOrder
        let index = results.firstIndex { order.precedes(found.relativePath, $0.path) } ?? results.count // keep the order
        results.insert(entry, at: index)
        outline.insertItems(at: IndexSet(integer: index), inParent: nil, withAnimation: [])
        outline.expandItem(entry)
    }

    private func expandAll() {
        for entry in results { outline.expandItem(entry) }
    }

    private func updateButtons() {
        replaceAllButton.isEnabled = !results.isEmpty && !isSearching
        replaceButton.isEnabled = !results.isEmpty && !isSearching && !outline.selectedRowIndexes.isEmpty
    }

    // MARK: replacing

    private var selectedMatches: [SearchMatch] {
        var picked: [SearchMatch] = []
        for row in outline.selectedRowIndexes {
            let item = outline.item(atRow: row)
            if let file = item as? FileResult { picked += file.matches }
            if let match = item as? MatchItem { picked.append(match.match) }
        }
        return Array(Set(picked))
    }

    @objc private func replaceSelected() { replace(selectedMatches, confirm: false) }

    @objc private func replaceAll() { replace(results.flatMap(\.matches), confirm: true) }

    /// Replaces matches file by file; each file is re-checked first (see ProjectSearch.replace).
    /// Undoable as one step with ⌘Z.
    func replace(_ matches: [SearchMatch], confirm: Bool) {
        guard !matches.isEmpty else { return }
        let replacement = replaceField.stringValue
        let byFile = Dictionary(grouping: matches, by: \.relativePath)
        if confirm, let window {
            let alert = NSAlert()
            alert.messageText = "Replace \(matches.count.formatted()) match\(matches.count == 1 ? "" : "es") in \(byFile.count.formatted()) file\(byFile.count == 1 ? "" : "s")?"
            alert.informativeText = replacement.isEmpty ? "The matches will be deleted. You can undo this with ⌘Z." : "You can undo this with ⌘Z."
            alert.addButton(withTitle: "Replace All")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.perform(byFile, replacement: replacement) }
            }
            return
        }
        perform(byFile, replacement: replacement)
    }

    private func perform(_ byFile: [String: [SearchMatch]], replacement: String) {
        var originals: [(URL, Data)] = []
        var replaced = 0, skipped = 0
        var failures: [String] = []
        for (path, matches) in byFile.sorted(by: { $0.key < $1.key }) {
            do {
                let result = try ProjectSearch.replace(matches, in: root, with: replacement, query: query)
                replaced += result.replaced
                skipped += result.skipped
                if let original = result.original { originals.append((URL(fileURLWithPath: root).appendingPathComponent(path), original)) }
            } catch {
                failures.append("\(path): \(error.localizedDescription)")
            }
        }
        if !originals.isEmpty, let undo = window?.undoManager ?? NSApp.keyWindow?.undoManager {
            undo.registerUndo(withTarget: self) { target in
                for (url, data) in originals { try? TextFile.write(data, to: url) }
                target.scheduleSearch(after: 0)
            }
            undo.setActionName("Replace in Files")
        }
        lastReplace = (replaced, skipped)
        scheduleSearch(after: 0)
        if skipped > 0 || !failures.isEmpty, let window {
            let alert = NSAlert()
            alert.messageText = "Replaced \(replaced.formatted()) match\(replaced == 1 ? "" : "es")."
            var lines: [String] = []
            if skipped > 0 {
                lines.append(skipped == 1 ? "1 match changed since the search and was left alone."
                    : "\(skipped.formatted()) matches changed since the search and were left alone.")
            }
            lines += failures
            alert.informativeText = lines.joined(separator: "\n")
            alert.beginSheetModal(for: window)
        }
    }

    /// Counts from the last replace, for the self-test.
    private(set) var lastReplace: (replaced: Int, skipped: Int) = (0, 0)

    // MARK: opening

    @objc private func openSelected() {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        let item = outline.item(atRow: row)
        let path: String, line: Int
        if let match = item as? MatchItem {
            (path, line) = (match.match.relativePath, match.match.line)
        } else if let file = item as? FileResult {
            (path, line) = (file.path, file.matches.first?.line ?? 1)
        } else {
            return
        }
        delegate?.findInFiles(self, open: URL(fileURLWithPath: root).appendingPathComponent(path), line: line)
    }

    // MARK: outline

    /// Wraps a match so the outline has a reference type to track.
    private final class MatchItem {
        let match: SearchMatch
        init(_ match: SearchMatch) { self.match = match }
    }
    private var matchItems: [ObjectIdentifier: [MatchItem]] = [:]

    private func items(for file: FileResult) -> [MatchItem] {
        let id = ObjectIdentifier(file)
        if let cached = matchItems[id], cached.count == file.matches.count { return cached }
        let made = file.matches.map(MatchItem.init)
        matchItems[id] = made
        return made
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return results.count }
        if let file = item as? FileResult { return file.matches.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let file = item as? FileResult { return items(for: file)[index] }
        return results[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is FileResult }

    func outlineViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    /// File rows a little taller than match rows: each file starts a group.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is FileResult ? 28 : 22
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let label = NSTextField(labelWithString: "")
        if let file = item as? FileResult {
            // "Alertable.php   app/Contracts   3": the name first, its folder quieter, the count in figures.
            Typography.singleLine(label, truncation: .byTruncatingMiddle) // a long folder keeps both ends
            let text = NSMutableAttributedString()
            let attachment = NSTextAttachment()
            let icon = FileIcons.icon(for: URL(fileURLWithPath: file.path), size: 16)
            attachment.image = icon
            attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
            text.append(NSAttributedString(attachment: attachment))
            text.append(Typography.gap(6, font: .systemFont(ofSize: 13)))
            let name = (file.path as NSString).lastPathComponent
            let folder = (file.path as NSString).deletingLastPathComponent
            text.append(NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor]))
            if !folder.isEmpty {
                text.append(Typography.gap(8, font: .systemFont(ofSize: 12)))
                text.append(NSAttributedString(string: folder, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
            }
            text.append(Typography.gap(10, font: .systemFont(ofSize: 12)))
            text.append(NSAttributedString(string: file.matches.count.formatted(), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            label.attributedStringValue = Typography.truncating(text, .byTruncatingMiddle)
            label.toolTip = file.path
        } else if let item = item as? MatchItem {
            Typography.singleLine(label, truncation: .byTruncatingTail)
            label.attributedStringValue = Typography.truncating(line(for: item.match), .byTruncatingTail)
            label.toolTip = item.match.lineText
        }
        return label
    }

    /// Colours a result line as the editor would (one line, without the state of the lines before it,
    /// which is right for nearly every line).
    private func syntaxColours(for match: SearchMatch) -> [(NSRange, NSColor)] {
        guard let engine = SyntaxEngine.shared else { return [] }
        let detected = EditorLanguage.id(forFileName: (match.relativePath as NSString).lastPathComponent)
        guard var language = engine.language(detected) else { return [] }
        // A lone line from a .php file is PHP code (it sits inside <?php … ?>), unless it opens or closes it.
        if language == "php", match.lineText.contains("<?") || match.lineText.contains("?>") {
            language = engine.language("blade") ?? language
        }
        guard let (tokens, _) = engine.tokenize(line: match.lineText, language: language, after: nil) else { return [] }
        return tokens.compactMap { token in
            guard let color = engine.color(token.color) else { return nil }
            return (NSRange(location: token.offset, length: (token.content as NSString).length), color)
        }
    }

    /// "12  the line, with the match highlighted" — and, with replace text, what it would become.
    private func line(for match: SearchMatch) -> NSAttributedString {
        let mono = Theme.monoFont(size: 12)
        let number = String(match.line)
        // Right-aligned with figure spaces (as wide as a digit), then one en space: a clean column.
        let text = NSMutableAttributedString(string: String(repeating: "\u{2007}", count: max(0, 5 - number.count)) + number + "\u{2002}", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        // Trim leading indentation so the match is in view.
        let ns = match.lineText as NSString
        var start = 0
        while start < match.range.location, start < ns.length, CharacterSet.whitespaces.contains(Unicode.Scalar(ns.character(at: start)) ?? " ") { start += 1 }
        let before = ns.substring(with: NSRange(location: start, length: match.range.location - start))
        let after = ns.substring(from: NSMaxRange(match.range))
        let codeStart = text.length
        text.append(NSAttributedString(string: before, attributes: [.font: mono, .foregroundColor: Theme.terminalForeground]))
        let replacement = replaceField.stringValue
        if replaceMode || !replacement.isEmpty, let preview = ProjectSearch.preview(match, replacement: replacement, query: query) {
            let replacedText = (preview as NSString).substring(with: NSRange(location: match.range.location,
                                                                             length: (preview as NSString).length - ns.length + match.range.length))
            text.append(NSAttributedString(string: match.matchedText, attributes: [
                .font: mono, .foregroundColor: Theme.linesRemoved, .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ]))
            text.append(NSAttributedString(string: replacedText, attributes: [
                .font: mono, .foregroundColor: Theme.linesAdded, .backgroundColor: Theme.linesAdded.withAlphaComponent(0.15),
            ]))
        } else {
            text.append(NSAttributedString(string: match.matchedText, attributes: [
                .font: mono, .foregroundColor: NSColor.white, .backgroundColor: Theme.accent.withAlphaComponent(0.55),
            ]))
        }
        let afterStart = text.length
        text.append(NSAttributedString(string: after, attributes: [.font: mono, .foregroundColor: Theme.terminalForeground]))
        // Syntax colours on the code around the match (the match keeps its own highlight).
        for (range, color) in syntaxColours(for: match) {
            // Before the match: shifted by the trimmed indentation.
            let beforeRange = NSIntersectionRange(range, NSRange(location: start, length: match.range.location - start))
            if beforeRange.length > 0 {
                text.addAttribute(.foregroundColor, value: color, range: NSRange(location: codeStart + beforeRange.location - start, length: beforeRange.length))
            }
            let afterRange = NSIntersectionRange(range, NSRange(location: NSMaxRange(match.range), length: ns.length - NSMaxRange(match.range)))
            if afterRange.length > 0 {
                text.addAttribute(.foregroundColor, value: color, range: NSRange(location: afterStart + afterRange.location - NSMaxRange(match.range), length: afterRange.length))
            }
        }
        return text
    }
}
