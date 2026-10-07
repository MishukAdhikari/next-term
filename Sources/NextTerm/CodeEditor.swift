import AppKit
import NextTermCore

/// The code text view: TextKit 1 (fast on long files with wrapping off), plain text, no smart quotes,
/// IDE keys: auto-indent, Tab and Shift-Tab on lines, ⌘/ to comment, and the current line highlighted.
final class CodeTextView: NSTextView {
    weak var document: EditorDocument?
    static let currentLine = NSColor(hex: 0x26282E)

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer, selectedRange().length == 0, window?.firstResponder === self else { return }
        let caret = min(selectedRange().location, (string as NSString).length)
        var line = NSRect.zero
        if caret == (string as NSString).length, layoutManager.extraLineFragmentTextContainer != nil {
            line = layoutManager.extraLineFragmentRect
        } else if layoutManager.numberOfGlyphs > 0 {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(caret, max(0, (string as NSString).length - 1)))
            line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else {
            return
        }
        _ = textContainer
        line.origin.x = 0
        line.size.width = bounds.width
        line = line.offsetBy(dx: 0, dy: textContainerOrigin.y)
        guard line.intersects(rect) else { return }
        Self.currentLine.setFill()
        line.fill()
        drawLineNote(at: caret)
    }

    /// A note after the caret line's text (the commit that last changed it), when there is one.
    var lineNote: ((_ line: Int) -> String?)?

    private func drawLineNote(at caret: Int) {
        guard let document, let layoutManager else { return }
        let line = document.lines.line(at: caret)
        let range = document.lines.range(ofLine: line)
        guard range.length > 0, let note = lineNote?(line) else { return }
        // After the line's last row of text.
        let last = NSMaxRange(range) - 1
        let glyph = layoutManager.glyphIndexForCharacter(at: last)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let font = self.font ?? EditorDocument.font
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.blameNote,
                                                         .paragraphStyle: Typography.paragraph(.byTruncatingTail)]
        let x = used.maxX + textContainerOrigin.x + (" " as NSString).size(withAttributes: [.font: font]).width * 4
        let size = (note as NSString).size(withAttributes: attributes)
        let width = min(size.width, visibleRect.maxX - x - 8)
        guard width > 40 else { return }
        let y = fragment.minY + textContainerOrigin.y + (fragment.height - size.height) / 2
        (note as NSString).draw(with: NSRect(x: x, y: y, width: width, height: size.height),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true // the current-line band moves
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        defer { needsDisplay = true }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer { needsDisplay = true }
        let resigned = super.resignFirstResponder()
        if resigned { caretPlacedByUser = false }
        return resigned
    }

    /// A click or a key in the text since it got the keyboard: a .env file's caret line then shows its
    /// value (CodeEditorView.hiddenEnvValues).
    var caretPlacedByUser = false {
        didSet { if caretPlacedByUser != oldValue { needsDisplay = true } }
    }

    private var keyObserver: NSObjectProtocol?

    /// The window keeps its first responder when another window or app takes the keyboard (a switch to
    /// a screen-share app), so that counts as losing it too: the caret's line hides again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            self?.caretPlacedByUser = false
        }
    }

    override func mouseDown(with event: NSEvent) {
        caretPlacedByUser = true
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        caretPlacedByUser = true
        super.keyDown(with: event)
    }

    private var indentUnit: String { document?.indentUnit ?? "    " }

    // MARK: typing

    /// Return keeps the indent; after an opening bracket it indents one more, and between a pair of
    /// brackets it puts the closing one on its own line.
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let caret = selectedRange()
        let lineRange = text.lineRange(for: NSRange(location: caret.location, length: 0))
        let beforeCaret = text.substring(with: NSRange(location: lineRange.location, length: caret.location - lineRange.location))
        let indent = String(beforeCaret.prefix { $0 == " " || $0 == "\t" })
        let opener = beforeCaret.trimmingCharacters(in: .whitespaces).last
        let after = caret.location + caret.length < text.length ? Character(UnicodeScalar(text.character(at: caret.location + caret.length)) ?? " ") : nil
        let pairs: [Character: Character] = ["{": "}", "[": "]", "(": ")"]
        if let opener, let closer = pairs[opener] {
            if after == closer {
                insertText("\n" + indent + indentUnit + "\n" + indent, replacementRange: caret)
                setSelectedRange(NSRange(location: caret.location + 1 + (indent + indentUnit as NSString).length, length: 0))
            } else {
                insertText("\n" + indent + indentUnit, replacementRange: caret)
            }
            return
        }
        if opener == ":", document?.language == "python" || document?.language == "yaml" {
            insertText("\n" + indent + indentUnit, replacementRange: caret)
            return
        }
        insertText("\n" + indent, replacementRange: caret)
    }

    /// Tab indents the selected lines when the selection spans lines; otherwise it inserts an indent.
    override func insertTab(_ sender: Any?) {
        let range = selectedRange()
        if range.length > 0, (string as NSString).substring(with: range).contains("\n") {
            shiftLines(by: 1)
            return
        }
        if indentUnit == "\t" { return super.insertTab(sender) }
        // Spaces to the next indent stop.
        let text = string as NSString
        let lineStart = text.lineRange(for: NSRange(location: range.location, length: 0)).location
        let column = range.location - lineStart
        let width = (indentUnit as NSString).length
        insertText(String(repeating: " ", count: width - column % width), replacementRange: range)
    }

    override func insertBacktab(_ sender: Any?) { shiftLines(by: -1) }

    @objc func indentSelection(_ sender: Any?) { shiftLines(by: 1) }
    @objc func outdentSelection(_ sender: Any?) { shiftLines(by: -1) }

    /// The whole lines the selection touches (a selection ending at a line's start leaves that line out).
    private func selectedLineRange() -> NSRange {
        let text = string as NSString
        var range = selectedRange()
        if range.length > 0, range.location + range.length <= text.length,
           range.location + range.length > 0, text.character(at: range.location + range.length - 1) == 0x0A {
            range.length -= 1
        }
        return text.lineRange(for: range)
    }

    /// Replaces whole lines as one undoable edit and selects the result.
    private func replaceLines(in lineRange: NSRange, transform: ([String]) -> [String]) {
        let text = string as NSString
        var body = text.substring(with: lineRange)
        let endsWithNewline = body.hasSuffix("\n")
        if endsWithNewline { body.removeLast() }
        let changed = transform(body.components(separatedBy: "\n")).joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        guard changed != text.substring(with: lineRange), shouldChangeText(in: lineRange, replacementString: changed) else { return }
        replaceCharacters(in: lineRange, with: changed)
        didChangeText()
        let length = (changed as NSString).length - (endsWithNewline ? 1 : 0)
        setSelectedRange(NSRange(location: lineRange.location, length: max(0, length)))
    }

    private func shiftLines(by step: Int) {
        let unit = indentUnit
        replaceLines(in: selectedLineRange()) { lines in
            lines.map { line in
                if step > 0 { return line.isEmpty ? line : unit + line }
                if line.hasPrefix(unit) { return String(line.dropFirst(unit.count)) }
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                return String(line.dropFirst(min(line.prefix { $0 == " " }.count, unit.count)))
            }
        }
    }

    /// ⌘/: comment or uncomment the selected lines in the file's language.
    @objc func toggleComment(_ sender: Any?) {
        guard let style = EditorLanguage.commentStyle(for: document?.language) else { return NSSound.beep() }
        replaceLines(in: selectedLineRange()) { EditorLanguage.toggleComment($0, style: style) }
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleComment(_:)) { return EditorLanguage.commentStyle(for: document?.language) != nil && isEditable }
        return super.validateMenuItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let send = NSMenuItem(title: selectedRange().length > 0 ? "Send Selection to Agent" : "Send File to Agent",
                              action: #selector(sendSelectionToAgent(_:)), keyEquivalent: "")
        send.target = self
        menu.insertItem(send, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc func sendSelectionToAgent(_ sender: Any?) {
        (window?.windowController as? TerminalWindowController)?.sendEditorSelection()
    }

    /// Selects a line (1-based) and scrolls it to the middle of the view.
    func go(toLine line: Int, column: Int = 1) {
        guard let document else { return }
        let index = document.lines
        let target = max(0, min(line - 1, index.count - 1))
        let range = index.range(ofLine: target)
        let content = max(0, range.length - ((string as NSString).length > range.location + range.length - 1 && range.length > 0
                                             && (string as NSString).character(at: range.location + range.length - 1) == 0x0A ? 1 : 0))
        let caret = range.location + min(max(0, column - 1), content)
        setSelectedRange(NSRange(location: caret, length: 0))
        guard let layoutManager, let textContainer, let scroll = enclosingScrollView else { return }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: range.location, length: 0))
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: range.location, length: 0), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        if rect.height == 0 { rect.size.height = font?.boundingRectForFont.height ?? 16 }
        // A rect as tall as the view, centred on the line: scrolling it into view centres the line, and
        // the scroll view keeps the gutter and the edges right (never a raw scroll(to:), which ignores them).
        let visible = scroll.contentView.bounds.height
        let centred = NSRect(x: 0, y: rect.midY + textContainerOrigin.y - visible / 2, width: 1, height: visible).intersection(bounds)
        scrollToVisible(centred.isEmpty ? rect : centred)
    }
}

/// Line numbers down the left, the current line's brighter.
final class LineNumberRuler: NSRulerView {
    private weak var codeView: CodeTextView?
    /// Lines that differ from the last commit, drawn as a bar beside the numbers.
    var marks = LineChanges.Marks() {
        didSet { if marks != oldValue { needsDisplay = true } }
    }
    /// A change mark was clicked.
    var onMarkClick: ((_ line: Int) -> Void)?
    /// Who last changed each line, in a column left of the numbers (View › Annotate with Git Blame).
    var showsBlame = false {
        didSet {
            guard showsBlame != oldValue else { return }
            updateThickness()
            needsDisplay = true
            if !showsBlame { setBlameToolTips([]) }
        }
    }
    var blameSource: (() -> EditedBlame?)?
    /// A commit in the blame column was clicked: its hash and the repository's root.
    var onBlameClick: ((_ sha: String, _ root: String) -> Void)?
    /// The blame column's hover areas, one per run of lines from a commit on screen, and whether
    /// installing them is already queued (once per turn of the run loop, however often it scrolls).
    var blameToolTipRects: [NSRect] = []
    var blameToolTipsQueued = false
    static let added = NSColor(hex: 0x549159)
    static let modified = NSColor(hex: 0x375FAD)
    static let deleted = NSColor(hex: 0xC75450)

    init(textView: CodeTextView) {
        codeView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        // Since macOS 14 views draw outside their bounds unless told not to: numbers scrolled past the
        // top would land on the tab bar.
        clipsToBounds = true
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { true }

    /// A click on a change bar opens the file's changes side by side; one in the blame column, the commit.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if showsBlame, point.x < blameWidth {
            if let line = line(at: point), let blame = blameSource?(), let commit = blame.commit(at: line) {
                onBlameClick?(commit.sha, blame.blame.root)
            }
            return
        }
        guard point.x >= ruleThickness - 10, let view = codeView, let document = view.document, let layoutManager = view.layoutManager,
              let container = view.textContainer else { return super.mouseDown(with: event) }
        let inText = view.convert(event.locationInWindow, from: nil)
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: inText.y - view.textContainerOrigin.y), in: container)
        let line = document.lines.line(at: layoutManager.characterIndexForGlyph(at: glyph))
        if marks.lines[line] != nil || marks.deletedBefore.contains(line) || marks.deletedBefore.contains(line + 1) {
            onMarkClick?(line)
        } else {
            super.mouseDown(with: event)
        }
    }

    /// Right-click: blame on or off, and on a commit's lines, that commit.
    override func menu(for event: NSEvent) -> NSMenu? {
        blameMenu(at: convert(event.locationInWindow, from: nil))
    }

    var numberFont: NSFont {
        let size = max(9, (codeView?.font?.pointSize ?? 13) - 1.5)
        return .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    /// Wide enough for the largest line number, with room either side, and the blame column when shown.
    func updateThickness() {
        guard let document = codeView?.document else { return }
        let digits = max(3, String(document.lines.count).count)
        let width = ceil(("8" as NSString).size(withAttributes: [.font: numberFont]).width * CGFloat(digits)) + 22 + (showsBlame ? blameWidth : 0)
        if abs(width - ruleThickness) > 0.5 { ruleThickness = width }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        guard let view = codeView, let document = view.document, let layoutManager = view.layoutManager,
              let container = view.textContainer, let scroll = view.enclosingScrollView else { return }
        let index = document.lines
        let text = view.string as NSString
        let visible = scroll.contentView.bounds
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible.offsetBy(dx: 0, dy: -view.textContainerOrigin.y), in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let caretLine = index.line(at: min(view.selectedRange().location, text.length))
        let font = numberFont
        let dim: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(hex: 0x4B5059)]
        let bright: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(hex: 0xA1A3AB)]
        let offset = convert(NSPoint.zero, from: view).y

        let marks = self.marks
        let blame = showsBlame ? blameSource?() : nil
        let blameStyle = blame.map { _ in BlameStyle(font: numberFont, width: blameWidth) }
        var tipRects: [NSRect] = []
        func draw(_ line: Int, fragment: NSRect) {
            let label = "\(line + 1)" as NSString
            let attributes = line == caretLine ? bright : dim
            let size = label.size(withAttributes: attributes)
            // Baseline-aligned with the code: same line fragment, vertically centred.
            let top = fragment.minY + view.textContainerOrigin.y + offset
            let y = top + (fragment.height - size.height) / 2
            guard top + fragment.height > bounds.minY, top < bounds.maxY else { return }
            if let blame, let blameStyle, blame.line(line) != nil {
                // The whole line, all of its rows when it wraps.
                let end = line + 1 < index.count ? index.starts[line + 1] - 1 : text.length - 1
                let last = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: max(index.starts[line], end)),
                                                          effectiveRange: nil, withoutAdditionalLayout: true)
                let rect = NSRect(x: 0, y: top, width: blameStyle.width, height: max(fragment.height, last.maxY - fragment.minY))
                drawBlame(blame, line: line, in: rect, rowHeight: fragment.height, style: blameStyle)
                if blame.isBlockStart(line) || tipRects.isEmpty { tipRects.append(rect) } else { tipRects[tipRects.count - 1] = tipRects[tipRects.count - 1].union(rect) }
            }
            label.draw(at: NSPoint(x: ruleThickness - size.width - 12, y: y), withAttributes: attributes)
            // The change bar, between the numbers and the code (a wrapped line's rows all get it).
            if let mark = marks.lines[line] {
                (mark == .added ? Self.added : Self.modified).setFill()
                NSRect(x: ruleThickness - 6, y: top, width: 3, height: fragment.height).fill()
            }
            if marks.deletedBefore.contains(line) { drawDeletion(at: top) }
        }

        /// Removed lines: a small red wedge on the line where they were.
        func drawDeletion(at y: CGFloat) {
            Self.deleted.setFill()
            let wedge = NSBezierPath()
            wedge.move(to: NSPoint(x: ruleThickness - 7, y: y - 3))
            wedge.line(to: NSPoint(x: ruleThickness - 1, y: y))
            wedge.line(to: NSPoint(x: ruleThickness - 7, y: y + 3))
            wedge.close()
            wedge.fill()
        }

        var line = index.line(at: characters.location)
        while line < index.count {
            let start = index.starts[line]
            if start > characters.location + characters.length { break }
            if start >= text.length {
                // The empty last line after a final newline.
                if layoutManager.extraLineFragmentTextContainer != nil { draw(line, fragment: layoutManager.extraLineFragmentRect) }
                break
            }
            if line == index.count - 1, marks.deletedBefore.contains(index.count) {
                // Lines removed from the very end: the wedge goes under the last line.
                let glyph = layoutManager.glyphIndexForCharacter(at: start)
                let last = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
                drawDeletion(at: last.maxY + view.textContainerOrigin.y + offset)
            }
            let glyph = layoutManager.glyphIndexForCharacter(at: start)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            draw(line, fragment: fragment)
            line += 1
        }
        if blame != nil { setBlameToolTips(tipRects) }
    }
}

/// Line height for code: every line the same height (the font's natural height times the user's
/// factor), with the text centred in it rather than sitting on the bottom as a paragraph style would
/// put it. The gutter and the current-line band follow the same line fragments.
final class LineSpacing: NSObject, NSLayoutManagerDelegate {
    var factor: CGFloat = 1.35
    var font: NSFont = Theme.monoFont(size: 13)

    private var natural: CGFloat { ceil(font.ascender - font.descender + font.leading) }
    var lineHeight: CGFloat { max(natural, round(natural * factor)) }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        let height = lineHeight
        let extra = height - natural
        lineFragmentRect.pointee.size.height = height
        lineFragmentUsedRect.pointee.size.height = height
        baselineOffset.pointee = ceil(font.ascender) + floor(extra / 2)
        return true
    }
}

/// A document's editor: the text view in a scroll view with the line-number gutter.
final class CodeEditorView: NSView, NSTextViewDelegate {
    let document: EditorDocument
    let scrollView = NSScrollView()
    let textView: CodeTextView
    private let ruler: LineNumberRuler
    let spacing = LineSpacing()
    /// A .env file's values, drawn hidden (EditorEnvValues.swift).
    let envValues = EnvValueMask()

    init(document: EditorDocument) {
        self.document = document
        let layoutManager = CodeLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.delegate = spacing
        document.storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 6
        layoutManager.addTextContainer(container)
        textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        textView.document = document

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.background
        scrollView.scrollerStyle = .overlay
        // The gutter and the code side by side; no automatic insets sliding the code under the gutter.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.documentView = textView
        ruler = LineNumberRuler(textView: textView)
        super.init(frame: .zero)

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.usesFontPanel = false
        textView.allowsDocumentBackgroundColorChange = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.backgroundColor = Theme.background
        textView.drawsBackground = true
        textView.insertionPointColor = Theme.caret
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = self
        textView.setAccessibilityLabel(document.name)
        applyFont()
        document.onTextReplaced = { [weak self] in
            self?.restyleReplacedLines()
            self?.scheduleChangeMarks(after: 0)
        }
        document.onLinesEdited = { [weak self] old, newLast in
            self?.shiftBlame(old, newLast)
            self?.envValues.textEdited()
        }
        layoutManager.hiddenRanges = { [weak self] in self?.hiddenEnvValues() ?? [] }
        ruler.blameSource = { [weak self] in self?.editedBlame }
        ruler.onBlameClick = { [weak self] sha, root in
            (self?.window?.windowController as? TerminalWindowController)?.showCommit(sha: sha, root: root)
        }
        textView.lineNote = { [weak self] line in self?.blameNote(forLine: line) }

        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        ruler.updateThickness()
        applyWrap()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if document.highlighter == nil, let engine = SyntaxEngine.shared, let language = document.grammar,
           document.storage.length <= DocumentHighlighter.maxLength {
            document.highlighter = DocumentHighlighter(engine: engine, language: language, storage: document.storage,
                                                       layoutManager: layoutManager) { [weak document] in document?.lines ?? LineIndex() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Soft wrap (View menu): long lines wrap at the window's edge instead of scrolling sideways.
    /// Line numbers stay on each line's first row.
    func applyWrap() {
        let wrap = AppDelegate.shared?.softWrap ?? true
        guard let container = textView.textContainer else { return }
        let width = scrollView.contentSize.width
        if wrap {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            container.containerSize = NSSize(width: width - textView.textContainerInset.width * 2, height: .greatestFiniteMagnitude)
        } else {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            scrollView.hasHorizontalScroller = true
        }
        textView.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: document.storage.length), actualCharacterRange: nil)
        textView.sizeToFit()
        ruler.needsDisplay = true
        textView.needsDisplay = true
    }

    func applyFont() {
        let font = EditorDocument.font
        spacing.font = font
        spacing.factor = AppDelegate.shared?.editorLineHeight ?? 1.35
        textView.font = font
        textView.typingAttributes = EditorDocument.attributes
        // Tab stops every indent width, in this font.
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = space * 4
        // The same height for the empty line after the last newline (laid out without the delegate).
        style.minimumLineHeight = spacing.lineHeight
        style.maximumLineHeight = spacing.lineHeight
        textView.defaultParagraphStyle = style
        textView.typingAttributes[.paragraphStyle] = style
        baseStyle = style
        indentStyles = [:]
        spaceWidth = space
        document.storage.beginEditing()
        document.storage.addAttributes([.font: font, .paragraphStyle: style], range: NSRange(location: 0, length: document.storage.length))
        if document.lines.count > 0 { applyWrapIndents(0...(document.lines.count - 1)) }
        document.storage.endEditing()
        textView.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: document.storage.length), actualCharacterRange: nil)
        ruler.updateThickness()
        ruler.needsDisplay = true
        textView.needsDisplay = true
    }

    // MARK: wrap indent

    private var baseStyle = NSParagraphStyle()
    private var spaceWidth: CGFloat = 7
    private var indentStyles: [Int: NSParagraphStyle] = [:]

    /// A wrapped line continues under its own indentation plus two columns, so a long line still reads
    /// as one statement at its level instead of spilling back to the margin.
    private func applyWrapIndents(_ lineRange: ClosedRange<Int>) {
        let text = document.storage.string as NSString
        let index = document.lines
        let tabColumns = 4
        for line in lineRange where line < index.count {
            let range = index.range(ofLine: line)
            guard range.length > 0 else { continue }
            var columns = 0, i = range.location
            while i < NSMaxRange(range) {
                let c = text.character(at: i)
                if c == 0x20 { columns += 1 } else if c == 0x09 { columns += tabColumns - columns % tabColumns } else { break }
                i += 1
            }
            let hang = min(columns + 2, 40) // never so deep that a wrapped row has no room
            let style = indentStyles[hang] ?? {
                let made = (baseStyle.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                made.headIndent = CGFloat(hang) * spaceWidth
                indentStyles[hang] = made
                return made
            }()
            document.storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    private func restyleReplacedLines() {
        guard let lines = document.takePendingIndentLines() else { return }
        document.storage.beginEditing()
        applyWrapIndents(lines)
        document.storage.endEditing()
    }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? { document.undoManager }

    /// Claude Code follows the selection (debounced in the window controller).
    var onSelectionChange: (() -> Void)?

    func textViewDidChangeSelection(_ notification: Notification) {
        onSelectionChange?()
    }

    func textDidChange(_ notification: Notification) {
        if let lines = document.takePendingIndentLines() {
            document.storage.beginEditing()
            applyWrapIndents(lines)
            document.storage.endEditing()
        }
        // Colour the edited line now, before it is drawn; longer runs continue on later turns.
        document.highlighter?.run()
        ruler.updateThickness()
        ruler.needsDisplay = true
        scheduleChangeMarks()
    }

    // MARK: change marks

    /// The file as of the last commit (nil: not committed, or not in a repository), and that commit.
    private var baseline: String?
    private var baselineHead: String?
    private var baselineLoaded = false
    private var marksWork: DispatchWorkItem?
    private static let marksQueue = DispatchQueue(label: "nextterm.change-marks", qos: .utility)
    /// Blame has its own queue: a slow one never holds up the change marks.
    private static let blameQueue = DispatchQueue(label: "nextterm.blame", qos: .utility)
    private static let git = GitRunner.locateGit()
    /// For the self-test.
    var changeMarks: LineChanges.Marks { ruler.marks }
    /// A change mark was clicked (the window shows the file's changes).
    var onChangeMarkClick: ((_ line: Int) -> Void)? {
        get { ruler.onMarkClick }
        set { ruler.onMarkClick = newValue }
    }

    /// Reads the committed version again (after a save, a commit, or coming back to the window), then
    /// redraws the marks. With blame on, the file's blame too, unless it is known for this HEAD; with
    /// `blame` false, only once the file is in front again (`refreshBlameIfStale`).
    func refreshBaseline(blame: Bool = true) {
        guard let git = Self.git else { return }
        guard document.storage.length <= Self.maxGitSize else { return announceBlame(.tooLarge) }
        blameStale = !blame && Self.blameWanted
        let path = document.path
        let format = document.format
        Self.marksQueue.async { [weak self] in
            guard self != nil else { return } // closed meanwhile
            // One commit for the text and its blame, so a commit between the two reads cannot mix them.
            let head = GitRunner.headCommit(of: path, git: git)
            // As the editor holds the file (CRLF made LF), or every line would differ from it.
            let text = head.flatMap { GitRunner.headText(of: path, git: git, revision: $0) }.map(format.editorText)
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = !self.baselineLoaded || text != self.baseline || head != self.baselineHead
                self.baseline = text
                self.baselineHead = head
                self.baselineLoaded = true
                if changed { self.scheduleChangeMarks(after: 0) }
                if blame { self.refreshBlame(at: head) }
            }
        }
    }

    /// Recomputes the marks a moment after typing stops (git diff on the text as it is, unsaved edits too),
    /// and with them the blame of each line.
    func scheduleChangeMarks(after delay: TimeInterval = 0.35) {
        guard baselineLoaded, let git = Self.git else { return }
        marksWork?.cancel()
        // A blame of another commit than the baseline's (a new one is being read): the one shown stays,
        // moving with edits, until the new one comes.
        let keepsBlame = blameResult != nil && blameHead != baselineHead
        guard let baseline else {
            ruler.marks = LineChanges.Marks() // new or untracked: nothing to compare with
            if keepsBlame { return }
            if case .notCommitted(let root)? = blameResult {
                editedBlame = .notCommitted(lineCount: gitLineCount, root: root)
            } else {
                editedBlame = nil
            }
            return
        }
        let current = document.text
        let head = baselineHead
        let committed: Blame? = if case .annotated(let blame)? = blameResult, !keepsBlame { blame } else { nil }
        let work = DispatchWorkItem { [weak self] in
            guard self != nil else { return }
            let diff = baseline == current ? nil : GitRunner.diff(old: baseline, new: current, git: git, context: 0)
            let marks = diff.map(LineChanges.marks(from:)) ?? LineChanges.Marks()
            // The blame is of the same commit as the baseline (same lines), carried over by the same diff.
            let aligned = committed.flatMap { blame -> EditedBlame? in
                guard blame.head == head, blame.lines.count == EditedBlame.lineCount(of: baseline) else { return nil }
                guard diff != nil || baseline == current else { return nil }
                return EditedBlame(blame, diff: diff, lineCount: EditedBlame.lineCount(of: current))
            }
            DispatchQueue.main.async {
                guard let self, self.document.text == current else { return } // typed on since: a newer run follows
                self.ruler.marks = marks
                if !keepsBlame { self.editedBlame = aligned }
            }
        }
        marksWork = work
        Self.marksQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: blame

    /// Files larger than this get no change marks and no blame.
    private static let maxGitSize = 2_000_000
    private static let blameCache = BlameCache()
    private static var blameWanted: Bool {
        AppDelegate.shared?.blameAnnotations == true || AppDelegate.shared?.currentLineBlame == true
    }
    /// What git blame said about the file as of the last commit; nil while blame is off.
    private var blameResult: GitRunner.BlameResult?
    /// The commit `blameResult` was read for (nil: no commit yet, or outside git).
    private var blameHead: String?
    /// The blame being read, for which commit, and whether another commit asked for one meanwhile.
    private var blameReading: (head: String?, again: Bool)?
    /// HEAD moved while the file was not in front: its blame is read when it is.
    private var blameStale = false
    /// Say once, after blame was turned on, when the file has none.
    private var blameAnnouncement = false
    /// Each line's commit; kept in step with edits between diffs.
    private(set) var editedBlame: EditedBlame? {
        didSet { showBlame() }
    }

    /// Reads the file's blame as of `head` in the background, one at a time: a refresh while one is
    /// being read waits for it, and the cache answers at once for a commit already read.
    private func refreshBlame(at head: String?) {
        guard Self.blameWanted, let git = Self.git else { return }
        if let reading = blameReading {
            if reading.head != head { blameReading?.again = true }
            return
        }
        blameReading = (head, false)
        let path = document.path
        Self.blameQueue.async { [weak self] in
            guard self != nil else { return } // closed meanwhile
            let blame = GitRunner.blame(of: path, git: git, revision: head, maxSize: Self.maxGitSize, cache: Self.blameCache)
            DispatchQueue.main.async {
                guard let self else { return }
                let again = self.blameReading?.again == true
                self.blameReading = nil
                if Self.blameWanted { // not turned off meanwhile
                    let changed = blame != self.blameResult || head != self.blameHead
                    self.blameResult = blame
                    self.blameHead = head
                    self.announceBlame(blame)
                    if changed { self.scheduleChangeMarks(after: 0) }
                }
                if again { self.refreshBlame(at: self.baselineHead) }
            }
        }
    }

    /// The file came to the front: the blame put off while it was behind is read now.
    func refreshBlameIfStale() {
        guard blameStale else { return }
        blameStale = false
        refreshBaseline()
    }

    private func showBlame() {
        ruler.showsBlame = AppDelegate.shared?.blameAnnotations == true && editedBlame != nil
        ruler.needsDisplay = true
        textView.needsDisplay = true // the caret line's note
    }

    /// Lines as git counts them in the text being edited (none after a final newline).
    private var gitLineCount: Int {
        let lines = document.lines
        return lines.starts.last == lines.length ? lines.count - 1 : lines.count
    }

    /// The View menu turned the blame column or the caret line's note on or off. A file not in front
    /// (`now` false) is blamed when it comes to the front.
    func applyBlame(announce: Bool = false, now: Bool = true) {
        guard Self.blameWanted else {
            blameResult = nil
            blameHead = nil
            blameStale = false
            editedBlame = nil
            return
        }
        blameAnnouncement = announce
        showBlame() // the column or the note alone may have changed
        refreshBaseline(blame: now)
    }

    private func announceBlame(_ result: GitRunner.BlameResult) {
        guard blameAnnouncement else { return }
        blameAnnouncement = false
        let name = "“\(document.name)”"
        let text: String
        switch result {
        case .notInRepository: text = "\(name) is not in a git repository"
        case .tooLarge: text = "\(name) is too large to annotate"
        case .timedOut: text = "\(name) took too long to annotate"
        case .binary, .failed: text = "git blame could not read \(name)"
        case .annotated, .notCommitted: return
        }
        GitToast.show(text, in: window)
    }

    /// An edit: the lines after it move along, and the edited lines are not committed (until the next
    /// diff says exactly which changed).
    private func shiftBlame(_ old: ClosedRange<Int>, _ newLast: Int) {
        editedBlame?.edit(lines: old, nowEndingAt: newLast, lineCount: gitLineCount)
    }

    /// The caret line's note: “Ann, 3 days ago · Fix login”.
    private func blameNote(forLine line: Int) -> String? {
        guard AppDelegate.shared?.currentLineBlame == true, let entry = editedBlame?.line(line) else { return nil }
        guard let commit = editedBlame?.blame.commit(entry) else { return "Not committed yet" }
        if editedBlame?.blame.isShallowBoundary(commit) == true { return "Before the clone’s history · \(commit.shortSHA) or earlier" }
        return "\(commit.shortAuthor), \(BlameText.relative(commit.authorTime)) · \(commit.summary)"
    }

    /// For the self-test: the blame column's text on a line ("" when it shows none), and the note.
    func blameColumnText(line: Int) -> String? { ruler.showsBlame ? editedBlame.map { BlameText.column($0, line: line) } : nil }
    func blameNoteText(line: Int) -> String? { blameNote(forLine: line) }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        textView.isEditable
    }
}
