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
        return super.resignFirstResponder()
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

    private var numberFont: NSFont {
        let size = max(9, (codeView?.font?.pointSize ?? 13) - 1.5)
        return .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    /// Wide enough for the largest line number, with room either side.
    func updateThickness() {
        guard let document = codeView?.document else { return }
        let digits = max(3, String(document.lines.count).count)
        let width = ceil(("8" as NSString).size(withAttributes: [.font: numberFont]).width * CGFloat(digits)) + 22
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

        func draw(_ line: Int, fragment: NSRect) {
            let label = "\(line + 1)" as NSString
            let attributes = line == caretLine ? bright : dim
            let size = label.size(withAttributes: attributes)
            // Baseline-aligned with the code: same line fragment, vertically centred.
            let y = fragment.minY + view.textContainerOrigin.y + offset + (fragment.height - size.height) / 2
            guard y + size.height > bounds.minY, y < bounds.maxY else { return }
            label.draw(at: NSPoint(x: ruleThickness - size.width - 12, y: y), withAttributes: attributes)
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
            let glyph = layoutManager.glyphIndexForCharacter(at: start)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            draw(line, fragment: fragment)
            line += 1
        }
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

    init(document: EditorDocument) {
        self.document = document
        let layoutManager = NSLayoutManager()
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
        document.storage.beginEditing()
        document.storage.addAttributes([.font: font, .paragraphStyle: style], range: NSRange(location: 0, length: document.storage.length))
        document.storage.endEditing()
        textView.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: document.storage.length), actualCharacterRange: nil)
        ruler.updateThickness()
        ruler.needsDisplay = true
        textView.needsDisplay = true
    }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? { document.undoManager }

    func textDidChange(_ notification: Notification) {
        // Colour the edited line now, before it is drawn; longer runs continue on later turns.
        document.highlighter?.run()
        ruler.updateThickness()
        ruler.needsDisplay = true
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        textView.isEditable
    }
}
