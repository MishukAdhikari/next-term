import AppKit
import NextTermCore

/// A chat tab's transcript (plan 037 KTD4): one read-only, selectable text view holding every block as attributed
/// paragraphs, a range per block id. An update replaces only the blocks that changed, so a streaming message touches
/// its own range. The content column caps at 760 points and centres. It stays at the bottom while the user hasn't
/// scrolled up; scrolled up, a Jump to Latest pill shows. Main thread.
final class ChatTranscriptView: NSView, NSTextViewDelegate {
    static let columnWidth: CGFloat = 760
    static let sideMargin: CGFloat = 20
    /// The room above the first block and below the last.
    private static let endMargin: CGFloat = 16

    let scrollView = NSScrollView()
    let textView: ChatTextView
    private let jump = NSButton()

    /// The blocks shown, in order, and each one's length in the text.
    private(set) var blocks: [ChatBlock] = []
    private var lengths: [Int] = []
    private var renderer: ChatBlockRenderer
    /// Tools whose whole output is drawn.
    private var showAll: Set<String> = []

    /// A link on Next Term's own scheme was clicked (or Space or Return on a row).
    var onLink: ((ChatLink) -> Void)?

    init(sizes: ChatTextSizes) {
        renderer = ChatBlockRenderer(sizes: sizes)
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        textView = ChatTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: Self.sideMargin, height: Self.endMargin)
        // Next Term's rows colour themselves; links only get the hand.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.delegate = self
        textView.setAccessibilityLabel("Conversation")
        textView.blockAt = { [weak self] location in self?.block(at: location) }
        textView.blockRange = { [weak self] id in self?.range(of: id) }
        textView.onActivate = { [weak self] id in self?.activate(id) }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)

        jump.title = "Jump to Latest"
        jump.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        jump.imagePosition = .imageLeading
        jump.bezelStyle = .rounded
        jump.controlSize = .small
        jump.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        jump.target = self
        jump.action = #selector(jumpToLatest)
        jump.isHidden = true
        jump.translatesAutoresizingMaskIntoConstraints = false
        jump.setAccessibilityLabel("Jump to the latest message")
        addSubview(jump)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            jump.centerXAnchor.constraint(equalTo: centerXAnchor),
            jump.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        // The column: at most 760 points, centred, with a margin either side.
        let side = max(Self.sideMargin, ((bounds.width - Self.columnWidth) / 2).rounded(.down))
        if textView.textContainerInset.width != side { textView.textContainerInset = NSSize(width: side, height: Self.endMargin) }
    }

    // MARK: updating

    /// Shows `new`: only the blocks whose value changed are drawn again. `sizes` or `offersTerminal` changing draws
    /// everything again (View › Bigger and Smaller).
    func show(_ new: [ChatBlock], sizes: ChatTextSizes, offersTerminal: Bool) {
        let pinned = isAtBottom
        let restyled = sizes != renderer.sizes || offersTerminal != renderer.offersTerminal
        if restyled {
            renderer = ChatBlockRenderer(sizes: sizes, showAll: showAll, offersTerminal: offersTerminal)
            blocks = []
            lengths = []
            textView.textStorage?.setAttributedString(NSAttributedString())
        }
        let change = ChatTranscript.diff(old: blocks, new: new)
        guard !change.isEmpty else { return }
        apply(change, new: new)
        if pinned { scrollToEnd() } else { jump.isHidden = false }
    }

    /// Draws everything again: the appearance changed (the symbols are drawn in its colours).
    func redrawAll() {
        let all = blocks
        blocks = []
        lengths = []
        textView.textStorage?.setAttributedString(NSAttributedString())
        show(all, sizes: renderer.sizes, offersTerminal: renderer.offersTerminal)
    }

    private func apply(_ change: ChatTranscript.Change, new: [ChatBlock]) {
        guard let storage = textView.textStorage else { return }
        let removed = Set(change.removed)
        let inserted = Set(change.inserted)
        var dirty = Set(change.updated)
        storage.beginEditing()
        // Gone blocks first, from the end, so the earlier ranges stay put.
        if !removed.isEmpty {
            var location = lengths.reduce(0, +)
            for index in blocks.indices.reversed() {
                location -= lengths[index]
                guard removed.contains(blocks[index].id) else { continue }
                storage.deleteCharacters(in: NSRange(location: location, length: lengths[index]))
                // The block after it now follows another: its gap may change.
                if index + 1 < blocks.count { dirty.insert(blocks[index + 1].id) }
                blocks.remove(at: index)
                lengths.remove(at: index)
            }
        }
        var kept: [String: Int] = [:]
        for (index, block) in blocks.enumerated() { kept[block.id] = lengths[index] }
        var location = 0
        var nextLengths: [Int] = []
        nextLengths.reserveCapacity(new.count)
        var previous: ChatBlock?
        var previousInserted = false
        for block in new {
            if inserted.contains(block.id) || kept[block.id] == nil {
                let text = renderer.render(block, after: previous)
                storage.insert(text, at: location)
                nextLengths.append(text.length)
                location += text.length
                previousInserted = true
            } else if let length = kept[block.id] {
                if dirty.contains(block.id) || previousInserted {
                    let text = renderer.render(block, after: previous)
                    storage.replaceCharacters(in: NSRange(location: location, length: length), with: text)
                    nextLengths.append(text.length)
                    location += text.length
                } else {
                    nextLengths.append(length)
                    location += length
                }
                previousInserted = false
            }
            previous = block
        }
        storage.endEditing()
        blocks = new
        lengths = nextLengths
    }

    // MARK: blocks by place

    /// The block holding character `location`, or the last one past the end.
    func block(at location: Int) -> ChatBlock? {
        var start = 0
        for (index, length) in lengths.enumerated() {
            if location < start + length { return blocks[index] }
            start += length
        }
        return blocks.last
    }

    /// Where block `id` sits in the text.
    func range(of id: String) -> NSRange? {
        var start = 0
        for (index, block) in blocks.enumerated() {
            if block.id == id { return NSRange(location: start, length: lengths[index]) }
            start += lengths[index]
        }
        return nil
    }

    /// Space or Return on a row: a tool or thought unfolds or folds; a file change opens its diff.
    private func activate(_ id: String) {
        guard let block = blocks.first(where: { $0.id == id }) else { return }
        switch block.content {
        case .tool(let tool) where !tool.output.isEmpty: onLink?(.toggle(id))
        case .thought: onLink?(.toggle(id))
        case .change: onLink?(.diff(id))
        default: NSSound.beep()
        }
    }

    // MARK: links

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let chat = ChatLink(link) else {
            // Only web links leave the app.
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            if let url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            return true
        }
        if case .showAll(let id) = chat {
            showAll.insert(id)
            renderer.showAll = showAll
            if let index = blocks.firstIndex(where: { $0.id == id }), let range = range(of: id), let storage = textView.textStorage {
                let text = renderer.render(blocks[index], after: index > 0 ? blocks[index - 1] : nil)
                storage.replaceCharacters(in: range, with: text)
                lengths[index] = text.length
            }
            return true
        }
        onLink?(chat)
        return true
    }

    // MARK: scrolling

    private var isAtBottom: Bool {
        let clip = scrollView.contentView
        return clip.bounds.maxY >= textView.frame.height - 24
    }

    func scrollToEnd() {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        textView.sizeToFit()
        let clip = scrollView.contentView
        let y = max(0, textView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
        jump.isHidden = true
    }

    @objc private func jumpToLatest() {
        scrollToEnd()
    }

    @objc private func scrolled() {
        if isAtBottom { jump.isHidden = true }
    }

    #if DEBUG
    /// For the self-test and the snapshot: the text as shown.
    var shownText: String { textView.string }
    #endif
}

/// The transcript's text view: draws the prompt, code and output panels, quote bars and turn rules under the text;
/// ↑ and ↓ move from block to block (the one the caret is in is outlined while the view has the keyboard), and Space or
/// Return opens a tool row's output, a thought or a file change's diff.
final class ChatTextView: NSTextView {
    var blockAt: ((Int) -> ChatBlock?)?
    var blockRange: ((String) -> NSRange?)?
    var onActivate: ((String) -> Void)?

    private var hasKeyboard = false

    override func becomeFirstResponder() -> Bool {
        let made = super.becomeFirstResponder()
        if made { hasKeyboard = true; needsDisplay = true }
        return made
    }

    override func resignFirstResponder() -> Bool {
        let made = super.resignFirstResponder()
        if made { hasKeyboard = false; needsDisplay = true }
        return made
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if hasKeyboard { needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty, event.charactersIgnoringModifiers == " " || event.keyCode == 36 || event.keyCode == 76 {
            if let block = blockAt?(selectedRange().location) { onActivate?(block.id) }
            return
        }
        super.keyDown(with: event)
    }

    override func moveDown(_ sender: Any?) { step(1) }
    override func moveUp(_ sender: Any?) { step(-1) }

    /// The caret to the start of the next (or previous) block, scrolled into view.
    private func step(_ direction: Int) {
        guard let current = blockAt?(selectedRange().location), let range = blockRange?(current.id) else { return }
        let target = direction > 0 ? NSMaxRange(range) : max(0, range.location - 1)
        guard target < (textStorage?.length ?? 0), let next = blockAt?(target), let nextRange = blockRange?(next.id) else { return }
        setSelectedRange(NSRange(location: nextRange.location, length: 0))
        scrollRangeToVisible(nextRange)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer, storage.length > 0 else { return }
        let visibleGlyphs = layout.glyphRange(forBoundingRect: rect.insetBy(dx: 0, dy: -40), in: container)
        let visible = layout.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        // Panels may start above the visible part: widen to whole paragraphs.
        let paragraphs = (storage.string as NSString).paragraphRange(for: visible)
        storage.enumerateAttribute(.chatPanel, in: paragraphs, options: []) { value, range, _ in
            guard let panel = value as? ChatPanel else { return }
            draw(panel, characters: range, layout: layout, container: container)
        }
        if hasKeyboard, let block = blockAt?(selectedRange().location), let range = blockRange?(block.id) {
            var box = lineBox(range, layout: layout, container: container)
            box = box.insetBy(dx: -6, dy: -3)
            NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.5).setStroke()
            let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    /// The box around the glyphs of `characters`: the column's width, from the top of their first line to the bottom of
    /// their last, without paragraph spacing.
    private func lineBox(_ characters: NSRange, layout: NSLayoutManager, container: NSTextContainer) -> NSRect {
        let glyphs = layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        var top = CGFloat.greatestFiniteMagnitude
        var bottom: CGFloat = 0
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            top = min(top, used.minY)
            bottom = max(bottom, used.maxY)
        }
        guard top <= bottom else { return .zero }
        let origin = textContainerOrigin
        return NSRect(x: origin.x, y: origin.y + top, width: container.size.width, height: bottom - top)
    }

    private func draw(_ panel: ChatPanel, characters: NSRange, layout: NSLayoutManager, container: NSTextContainer) {
        // The trailing line break belongs to the last line; one alone would add a line of its own.
        var range = characters
        if range.length > 1, (textStorage?.string as NSString?)?.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
        let box = lineBox(range, layout: layout, container: container)
        guard box.height > 0 else { return }
        switch panel.kind {
        case .prompt:
            let fill = box.insetBy(dx: 0, dy: -8)
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 8, yRadius: 8).fill()
        case .code, .detail:
            let indent: CGFloat = panel.kind == .detail ? headIndent(at: range.location) - 10 : 0
            var fill = box.insetBy(dx: 0, dy: panel.kind == .code ? -8 : -6)
            fill.origin.x += indent
            fill.size.width -= indent
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            let path = NSBezierPath(roundedRect: fill, xRadius: 6, yRadius: 6)
            path.fill()
            NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        case .quote:
            let x = box.minX + headIndent(at: range.location) - 10
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: box.minY, width: 2, height: box.height), xRadius: 1, yRadius: 1).fill()
        case .rule:
            // A hairline from the end of the closing words to the column's end.
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let used = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let origin = textContainerOrigin
            let start = origin.x + used.maxX + 12
            let end = box.maxX
            guard end > start + 8 else { return }
            NSColor.separatorColor.setFill()
            NSRect(x: start, y: (box.midY).rounded() + 0.5, width: end - start, height: 1 / max(1, window?.backingScaleFactor ?? 2)).fill()
        }
    }

    private func headIndent(at location: Int) -> CGFloat {
        (textStorage?.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        (enclosingScrollView?.superview as? ChatTranscriptView)?.redrawAll()
    }
}
