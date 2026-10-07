import AppKit
import NextTermCore
import Shiki

/// A Jupyter notebook in an editor tab, read-only: Markdown laid out, code coloured in the kernel's
/// language with Jupyter's `In [n]:` beside it, and below each cell what it showed the last time it ran
/// (text, errors in red, images). One text view holds the whole notebook, so selection, copying and ⌘F
/// work across cells. Nothing runs: Open as JSON edits the file itself, and Open With hands it to
/// Jupyter or another app.
final class NotebookPane: NSView, NSMenuDelegate {
    private(set) var url: URL
    var path: String { url.path }
    var name: String { url.lastPathComponent }
    /// Open as JSON was clicked: open the file as text in the editor.
    var onOpenAsJSON: ((URL) -> Void)?
    var onTitleChange: (() -> Void)?

    let scrollView = NSScrollView()
    let textView: NotebookTextView
    private let header = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let openAsJSON = NSButton(title: "Open as JSON", target: nil, action: nil)
    private let openWith = NSPopUpButton(frame: .zero, pullsDown: true)
    private let message = NSTextField(wrappingLabelWithString: "")

    /// The notebook as last read (kept when the file is later deleted or broken, until it reads again).
    private(set) var notebook: Notebook?
    /// Why the file could not be shown as a notebook, if it could not.
    private(set) var loadError: String?
    private(set) var isLoading = false
    private(set) var isDeletedOnDisk = false
    private var stamp: FileStamp?
    private var generation = 0
    private var highlighter: NotebookHighlighter?

    /// For the self-test: still reading, or colours still to come.
    var isSettled: Bool { !isLoading && (highlighter?.isDone ?? true) }

    init(url: URL) {
        self.url = URL(fileURLWithPath: canonicalPath(url.path))
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false // text blocks are measured wrong when laid out piecemeal
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        textView = NotebookTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        build()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        Typography.singleLine(titleLabel, truncation: .byTruncatingMiddle)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = Theme.textDim
        Typography.singleLine(summary, truncation: .byTruncatingTail)
        summary.setContentCompressionResistancePriority(.init(740), for: .horizontal) // the folder gives way first
        showTitle()

        openAsJSON.bezelStyle = .rounded
        openAsJSON.controlSize = .small
        openAsJSON.font = .systemFont(ofSize: 11)
        openAsJSON.target = self
        openAsJSON.action = #selector(openAsJSONClicked)
        openAsJSON.toolTip = "Open the notebook’s file in the editor, to read or change its JSON"
        openWith.controlSize = .small
        openWith.font = .systemFont(ofSize: 11)
        (openWith.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        openWith.toolTip = "Open the notebook in another app, such as Jupyter or VS Code"
        openWith.menu?.delegate = self
        openWith.addItem(withTitle: "Open With")
        header.setViews([titleLabel, summary, NSView(), openAsJSON, openWith], in: .leading)
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        header.wantsLayer = true
        header.layer?.backgroundColor = Theme.bar.cgColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.backgroundColor = Theme.background
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        textView.linkTextAttributes = [.foregroundColor: Theme.gitModified, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                       .cursor: NSCursor.pointingHand]
        textView.textContainerInset = NSSize(width: 0, height: 14)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.setAccessibilityLabel("Notebook \(name)")
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.background
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()

        message.textColor = Theme.textDim
        message.alignment = .center
        message.isHidden = true

        for view in [header, scrollView, message] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            message.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
        ])
    }

    private func showTitle() {
        let folder = url.deletingLastPathComponent().path
        let text = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Theme.text])
        text.append(Typography.gap(8, font: .systemFont(ofSize: 12)))
        text.append(NSAttributedString(string: RecentProjects.abbreviate(folder), attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.textDim]))
        titleLabel.attributedStringValue = Typography.truncating(text, .byTruncatingMiddle)
        titleLabel.toolTip = path
    }

    /// "Python 3 (ipykernel) · 24 cells · read-only", or what is wrong.
    private func showSummary() {
        var parts: [String] = []
        if let notebook {
            let language = notebook.language.map(Self.languageName)
            switch (notebook.kernelName, language) {
            case let (kernel?, language?) where !kernel.localizedCaseInsensitiveContains(language): parts.append("\(kernel) (\(language))")
            case let (kernel?, _): parts.append(kernel)
            case let (nil, language): parts.append(language ?? "No kernel")
            }
            parts.append(notebook.cells.count == 1 ? "1 cell" : "\(notebook.cells.count.formatted()) cells")
        }
        if isLoading { parts.append("reading…") }
        parts.append(isDeletedOnDisk ? "deleted on disk" : "read-only")
        summary.stringValue = parts.joined(separator: " · ")
        summary.textColor = isDeletedOnDisk ? Theme.linesRemoved : Theme.textDim
        summary.toolTip = notebook.map { "nbformat \($0.format), \($0.language ?? "no language") kernel. Nothing in it runs here." }
    }

    static func languageName(_ id: String) -> String {
        ["python": "Python", "r": "R", "julia": "Julia", "typescript": "TypeScript", "javascript": "JavaScript", "cpp": "C++",
         "scala": "Scala", "rust": "Rust", "go": "Go", "sql": "SQL", "kotlin": "Kotlin", "java": "Java", "csharp": "C#"][id] ?? id
    }

    // MARK: loading

    /// Reads and lays out the file again, off the main thread, keeping the scroll position.
    func reload() {
        generation += 1
        let token = generation
        let url = self.url
        let style = NotebookRenderer.Style.current
        isLoading = true
        if notebook == nil, loadError == nil {
            message.stringValue = "Reading the notebook…"
            message.isHidden = false
        }
        showSummary()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stamp = FileStamp(path: url.path)
            let result = Result { try Notebook.read(contentsOf: url) }
            let rendered = (try? result.get()).map { NotebookRenderer.render($0, style: style) }
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.stamp = stamp
                self.isLoading = false
                self.isDeletedOnDisk = stamp == nil
                switch result {
                case let .success(notebook):
                    self.notebook = notebook
                    self.loadError = nil
                    if let rendered { self.show(rendered) }
                case let .failure(error):
                    self.loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    if self.notebook == nil || !self.isDeletedOnDisk { self.showError() }
                }
                self.showSummary()
                self.onTitleChange?()
            }
        }
    }

    private func showError() {
        notebook = nil
        highlighter = nil
        textView.textStorage?.setAttributedString(NSAttributedString())
        message.stringValue = (loadError ?? "") + "\n\nOpen as JSON shows the file as it is."
        message.isHidden = false
    }

    private func show(_ rendered: NotebookRenderer.Rendered) {
        guard let storage = textView.textStorage, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        // Keep the text at the top of the view there (the notebook changed on disk, or the font size did).
        let top = storage.length > 0 ? layout.characterIndexForGlyph(at: layout.glyphIndex(for: scrollView.contentView.bounds.origin, in: container)) : 0
        let wasAtTop = scrollView.contentView.bounds.origin.y <= 1
        for (attachment, image) in rendered.images { attachment.attachmentCell = NotebookImageCell(image) }
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        storage.setAttributedString(rendered.text)
        message.isHidden = true
        highlighter = SyntaxEngine.shared.map { NotebookHighlighter(engine: $0, code: rendered.code, layoutManager: layout) }
        highlighter?.run()
        guard !wasAtTop, storage.length > 0 else { return }
        let character = min(top, storage.length - 1)
        layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: character + 1))
        let glyph = layout.glyphIndexForCharacter(at: character)
        let y = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textView.textContainerOrigin.y
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, textView.frame.height - scrollView.contentView.bounds.height))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The file changed on disk (an agent ran it, someone saved it as JSON): read it again. About once a second.
    func refreshIfChanged() {
        guard !isLoading else { return }
        let now = FileStamp(path: path)
        guard now != stamp else { return }
        if now == nil {
            stamp = nil
            isDeletedOnDisk = true
            showSummary()
            return
        }
        reload()
    }

    /// The file was renamed or moved in the sidebar.
    func moved(to newURL: URL) {
        url = URL(fileURLWithPath: canonicalPath(newURL.path))
        stamp = FileStamp(path: url.path)
        isDeletedOnDisk = stamp == nil
        textView.setAccessibilityLabel("Notebook \(name)")
        showTitle()
        showSummary()
        onTitleChange?()
    }

    /// The font size or line height changed: lay the notebook out again (it is not read again).
    func applyFont() {
        guard let notebook, !isLoading else { return }
        generation += 1
        let token = generation
        let style = NotebookRenderer.Style.current
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let rendered = NotebookRenderer.render(notebook, style: style)
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.show(rendered)
            }
        }
    }

    // MARK: actions

    @objc func openAsJSONClicked() { onOpenAsJSON?(url) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Open With", action: nil, keyEquivalent: "") // the pull-down's own title
        let own = Bundle.main.bundleIdentifier
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: url)
        var seen: Set<String> = []
        var apps: [URL] = []
        for app in [preferred].compactMap({ $0 }) + NSWorkspace.shared.urlsForApplications(toOpen: url) {
            let id = Bundle(url: app)?.bundleIdentifier ?? app.path
            // Not Next Term itself, and never something that runs what it opens (Python Launcher).
            guard id != own, id != "me.mishuk.nextterm", !SafeOpen.launchers.contains(id), seen.insert(id).inserted else { continue }
            apps.append(app)
        }
        if apps.isEmpty {
            let none = NSMenuItem(title: "No app on this Mac opens notebooks", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for app in apps {
            var title = FileManager.default.displayName(atPath: app.path)
            if title.hasSuffix(".app") { title = String(title.dropLast(4)) }
            if app == preferred { title += " (default)" }
            let item = NSMenuItem(title: title, action: #selector(openWithApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The notebook's text: read-only, and copying leaves out the images' placeholder characters.
final class NotebookTextView: NSTextView {
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return super.writeSelection(to: pboard, type: type) }
        let text = selectedRanges.map { (string as NSString).substring(with: $0.rangeValue) }.joined(separator: "\n")
        return pboard.setString(text.replacingOccurrences(of: "\u{FFFC}", with: ""), forType: .string)
    }
}

// MARK: layout

/// A box in the notebook: a code cell's background with `In [n]:` beside it, an output with `Out[n]:`,
/// an error's red tint. Text blocks take the box's margins and padding into account when they lay out
/// the text, so the boxes only need drawing.
final class NotebookBlock: NSTextBlock {
    var fill: NSColor?
    var stroke: NSColor?
    var label: NSAttributedString?
    /// Where the first line's baseline sits below the top of the text, to put the label's on it.
    var baseline: CGFloat = 0

    override init() {
        super.init()
        // The full width, said outright: without it, only a block's first line is laid out inside it.
        setContentWidth(100, type: .percentageValueType)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView, characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let left = width(for: .margin, edge: .minX), right = width(for: .margin, edge: .maxX)
        let top = width(for: .margin, edge: .minY), bottom = width(for: .margin, edge: .maxY)
        let box = NSRect(x: frameRect.minX + left, y: frameRect.minY + top, width: frameRect.width - left - right,
                         height: frameRect.height - top - bottom)
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        }
        if let stroke {
            stroke.setStroke()
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            path.lineWidth = 1
            path.stroke()
        }
        if let label {
            let size = label.size()
            let font = label.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            let y = box.minY + width(for: .padding, edge: .minY) + baseline - (font?.ascender ?? size.height)
            label.draw(at: NSPoint(x: box.minX - size.width - 10, y: y))
        }
    }
}

/// An output image: sized from its header before it is decoded, decoded the first time it is drawn, and
/// scaled down to the width of the view.
final class NotebookImageCell: NSTextAttachmentCell {
    let source: Notebook.Image
    private var decoded: NSImage?
    private var failed = false

    init(_ source: Notebook.Image) {
        self.source = source
        super.init()
    }

    required init(coder: NSCoder) { fatalError("not used") }

    /// The size the notebook shows it at: its own width and height metadata, else a point per pixel.
    var naturalSize: NSSize {
        let pixels = NSSize(width: source.pixelWidth ?? 0, height: source.pixelHeight ?? 0)
        let aspect = pixels.width > 0 ? pixels.height / pixels.width : 0.75
        switch (source.width, source.height) {
        case let (w?, h?): return NSSize(width: w, height: h)
        case let (w?, nil): return NSSize(width: CGFloat(w), height: (CGFloat(w) * aspect).rounded())
        case let (nil, h?): return NSSize(width: aspect > 0 ? (CGFloat(h) / aspect).rounded() : CGFloat(h), height: CGFloat(h))
        case (nil, nil):
            if pixels.width > 0, pixels.height > 0 { return pixels }
            return image()?.size ?? NSSize(width: 240, height: 24)
        }
    }

    private func image() -> NSImage? {
        if decoded == nil, !failed {
            decoded = source.data().flatMap(NSImage.init(data:))
            failed = decoded == nil
        }
        return decoded
    }

    override func cellSize() -> NSSize { naturalSize }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint,
                            characterIndex charIndex: Int) -> NSRect {
        let natural = naturalSize
        let available = max(40, lineFrag.width - position.x - 2)
        let scale = min(1, available / max(1, natural.width))
        return NSRect(x: 0, y: 0, width: (natural.width * scale).rounded(.down), height: (natural.height * scale).rounded(.down))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let image = image() else {
            let note = "\(source.mime) image that could not be decoded" as NSString
            note.draw(at: cellFrame.origin, withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.textDim])
            return
        }
        image.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    override func wantsToTrackMouse() -> Bool { false }
}

/// Lays a notebook out as one attributed string, off the main thread: each cell a block, its outputs
/// blocks below it.
enum NotebookRenderer {
    /// Fonts and spacing, read on the main thread from the app's settings.
    struct Style {
        var fontSize: CGFloat
        var lineHeight: CGFloat

        @MainActor static var current: Style {
            Style(fontSize: AppDelegate.shared?.fontSize ?? Theme.defaultFontSize, lineHeight: AppDelegate.shared?.editorLineHeight ?? 1.35)
        }
    }

    struct Rendered {
        let text: NSAttributedString
        /// Each code cell's source (its characters in `text`) and the language it is written in.
        let code: [(range: NSRange, language: String?)]
        /// Images, to get their drawing cell on the main thread.
        let images: [(attachment: NSTextAttachment, image: Notebook.Image)]
    }

    static let codeFill = NSColor(hex: 0x2B2D30)
    static let codeStroke = NSColor(hex: 0x35373B)
    static let stderrFill = NSColor(hex: 0x33282A)
    static let errorFill = NSColor(hex: 0x3A2527)
    static let errorText = NSColor(hex: 0xF0928D)

    static func render(_ notebook: Notebook, style: Style) -> Rendered {
        var builder = Builder(style: style)
        for cell in notebook.cells { builder.cell(cell, language: notebook.language(of: cell)) }
        if notebook.cells.isEmpty {
            builder.append("This notebook has no cells.\n", font: .systemFont(ofSize: style.fontSize), color: Theme.textDim,
                           style: builder.paragraph(builder.block(padding: 10)))
        }
        return Rendered(text: builder.out, code: builder.code, images: builder.images)
    }

    private struct Builder {
        let style: Style
        let out = NSMutableAttributedString()
        var code: [(range: NSRange, language: String?)] = []
        var images: [(attachment: NSTextAttachment, image: Notebook.Image)] = []
        let mono: NSFont
        let labelFont: NSFont
        let body: NSFont
        /// Left of every box: room for `In [12]:`.
        let gutter: CGFloat
        /// Every code line this tall, as in the editor. (A paragraph style's line spacing would do it
        /// more simply, but with any line or paragraph spacing TextKit 1 ignores the paragraph's text blocks.)
        let codeLine: CGFloat
        /// The glyphs sit at the bottom of a tall line: a code box takes this off its top padding.
        let codeRaise: CGFloat
        static let cellGap: CGFloat = 14
        static let indentStep: CGFloat = 18

        init(style: Style) {
            self.style = style
            mono = Theme.monoFont(size: style.fontSize)
            labelFont = Theme.monoFont(size: max(8, style.fontSize - 2))
            body = .systemFont(ofSize: style.fontSize)
            gutter = ceil(("Out[000]:" as NSString).size(withAttributes: [.font: labelFont]).width) + 22
            let natural = ceil(mono.ascender - mono.descender + mono.leading)
            codeLine = max(natural, (natural * style.lineHeight).rounded())
            codeRaise = codeLine - natural
        }

        mutating func cell(_ cell: Notebook.Cell, language: String?) {
            switch cell.kind {
            case .code:
                let box = block(padding: 8, bottom: cell.outputs.isEmpty ? Self.cellGap : 2, fill: NotebookRenderer.codeFill,
                                stroke: NotebookRenderer.codeStroke, code: true)
                box.label = label("In [\(cell.executionCount.map(String.init) ?? " ")]:")
                box.baseline = codeBaseline
                let start = out.length
                append(cell.source + "\n", font: mono, color: Theme.terminalForeground, style: paragraph(box, lineHeight: codeLine))
                code.append((NSRange(location: start, length: (cell.source as NSString).length), language))
                for (index, output) in cell.outputs.enumerated() {
                    self.output(output, last: index == cell.outputs.count - 1)
                }
            case .markdown:
                let box = block(padding: 2, bottom: Self.cellGap - 4)
                markdown(cell.source, in: box)
            case .raw:
                let box = block(padding: 8, bottom: Self.cellGap, stroke: NotebookRenderer.codeStroke, code: true)
                append(cell.source + "\n", font: mono, color: Theme.textDim, style: paragraph(box, lineHeight: codeLine))
            }
        }

        mutating func output(_ output: Notebook.Output, last: Bool) {
            var fill: NSColor?
            var color = Theme.terminalForeground
            switch output.kind {
            case .stream(stderr: true): fill = NotebookRenderer.stderrFill
            case .error: fill = NotebookRenderer.errorFill; color = NotebookRenderer.errorText
            default: break
            }
            let isText: Bool
            if case .text = output.content { isText = true } else { isText = false }
            let box = block(padding: fill == nil ? 4 : 8, top: 4, bottom: last ? Self.cellGap : 0, fill: fill, code: isText)
            if case let .result(count) = output.kind {
                box.label = label("Out[\(count.map(String.init) ?? " ")]:")
                box.baseline = isText ? codeBaseline : body.ascender
            }
            switch output.content {
            case let .text(excerpt):
                let lines = paragraph(box, lineHeight: codeLine)
                append(excerpt.head + "\n", font: mono, color: color, style: lines)
                if excerpt.omittedLines > 0 {
                    let count = excerpt.omittedLines == 1 ? "1 line" : "\(excerpt.omittedLines.formatted()) lines"
                    let italic = NSFont(descriptor: body.fontDescriptor.withSymbolicTraits(.italic), size: style.fontSize - 1) ?? body
                    append("⋯ \(count) not shown (Open as JSON has them all)\n", font: italic, color: Theme.textDim, style: paragraph(box, before: 4, after: 4))
                    append(excerpt.tail + "\n", font: mono, color: color, style: lines)
                }
            case let .markdown(source):
                markdown(source, in: box)
            case let .image(image):
                let attachment = NSTextAttachment()
                images.append((attachment, image))
                let piece = NSMutableAttributedString(attachment: attachment)
                piece.append(NSAttributedString(string: "\n"))
                piece.addAttribute(.paragraphStyle, value: paragraph(box), range: NSRange(location: 0, length: piece.length))
                out.append(piece)
            case let .unsupported(mime, bytes):
                let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                append("\(mime) output (\(size)): only Jupyter shows it.\n", font: .systemFont(ofSize: style.fontSize - 1),
                       color: Theme.textDim, style: paragraph(box))
            }
        }

        /// Markdown as the release notes are laid out, in the notebook's colours.
        func markdown(_ source: String, in box: NotebookBlock) {
            let blocks = Notebook.markdownBlocks(source)
            for (index, block) in blocks.enumerated() {
                let first = index == 0
                switch block {
                case let .heading(level, text):
                    let scale: [CGFloat] = [1.7, 1.4, 1.2, 1.05, 1, 1]
                    let font = NSFont.systemFont(ofSize: (style.fontSize * scale[min(level, 6) - 1]).rounded(), weight: level <= 2 ? .bold : .semibold)
                    inline(text, font: font, color: Theme.text, style: paragraph(box, multiple: 1.1, before: first ? 0 : 10, after: 6))
                case let .bullet(depth, text):
                    inline((depth == 0 ? "•" : "◦") + "\t" + text, font: body, color: Theme.text, style: list(box, depth: depth))
                case let .numbered(depth, number, text):
                    inline(number + ".\t" + text, font: body, color: Theme.text, style: list(box, depth: depth))
                case let .paragraph(depth, text):
                    let indented = paragraph(box, multiple: 1.15, after: 6)
                    indented.firstLineHeadIndent = CGFloat(depth) * Self.indentStep
                    indented.headIndent = indented.firstLineHeadIndent
                    inline(text, font: body, color: Theme.text, style: indented)
                case let .code(text):
                    let inner = NotebookBlock()
                    inner.fill = NotebookRenderer.codeFill
                    inner.setWidth(8, type: .absoluteValueType, for: .padding)
                    inner.setWidth(max(0, 8 - codeRaise), type: .absoluteValueType, for: .padding, edge: .minY)
                    inner.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
                    inner.setWidth(8, type: .absoluteValueType, for: .margin, edge: .maxY)
                    let nested = paragraph(box, lineHeight: codeLine)
                    nested.textBlocks = [box, inner]
                    append(text + "\n", font: mono, color: Theme.terminalForeground, style: nested)
                }
            }
            if blocks.isEmpty { append("\n", font: body, color: Theme.text, style: paragraph(box)) }
        }

        // MARK: pieces

        /// Where a code line's baseline is, from the top of its box's text.
        var codeBaseline: CGFloat { codeLine + mono.descender }

        /// A box from the gutter to the right edge. `code`: it holds code lines, whose glyphs sit low.
        func block(padding: CGFloat, top: CGFloat = 0, bottom: CGFloat = 0, fill: NSColor? = nil, stroke: NSColor? = nil,
                   code: Bool = false) -> NotebookBlock {
            let box = NotebookBlock()
            box.fill = fill
            box.stroke = stroke
            box.setWidth(code ? max(0, padding - codeRaise) : padding, type: .absoluteValueType, for: .padding, edge: .minY)
            box.setWidth(padding, type: .absoluteValueType, for: .padding, edge: .maxY)
            box.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
            box.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
            box.setWidth(gutter, type: .absoluteValueType, for: .margin, edge: .minX)
            box.setWidth(18, type: .absoluteValueType, for: .margin, edge: .maxX)
            box.setWidth(top, type: .absoluteValueType, for: .margin, edge: .minY)
            box.setWidth(bottom, type: .absoluteValueType, for: .margin, edge: .maxY)
            return box
        }

        func label(_ text: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: labelFont, .foregroundColor: Theme.textDim])
        }

        /// A paragraph in `box`: code lines `lineHeight` tall, or prose lines `multiple` times their own height.
        func paragraph(_ box: NotebookBlock, lineHeight: CGFloat? = nil, multiple: CGFloat = 1, before: CGFloat = 0,
                       after: CGFloat = 0) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.textBlocks = [box]
            if before > 0 || after > 0 {
                // Spacing as the margins of a block inside the box: a paragraph style's own spacing would
                // make TextKit 1 drop the paragraph's text blocks.
                let spacer = NotebookBlock()
                spacer.setWidth(before, type: .absoluteValueType, for: .margin, edge: .minY)
                spacer.setWidth(after, type: .absoluteValueType, for: .margin, edge: .maxY)
                style.textBlocks = [box, spacer]
            }
            if let lineHeight {
                style.minimumLineHeight = lineHeight
                style.maximumLineHeight = lineHeight
            }
            style.lineHeightMultiple = multiple
            style.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: mono]).width * 4
            style.tabStops = []
            return style
        }

        /// The marker hangs in the margin; wrapped lines line up with the text after it.
        func list(_ box: NotebookBlock, depth: Int) -> NSMutableParagraphStyle {
            let style = paragraph(box, multiple: 1.15, after: 3)
            let start = CGFloat(depth) * Self.indentStep
            style.firstLineHeadIndent = start
            style.headIndent = start + Self.indentStep
            style.tabStops = [NSTextTab(textAlignment: .left, location: start + Self.indentStep)]
            style.defaultTabInterval = Self.indentStep
            return style
        }

        func append(_ text: String, font: NSFont, color: NSColor, style: NSParagraphStyle) {
            out.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
        }

        func inline(_ text: String, font: NSFont, color: NSColor, style: NSParagraphStyle) {
            let piece = NSMutableAttributedString(attributedString: ReleaseNotesRenderer.inline(text, font: font, color: color))
            piece.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            piece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: piece.length))
            out.append(piece)
        }
    }
}

/// Colours the code cells a slice of time at a time, as the editor colours a file, so a long notebook
/// shows at once and its colours follow. IPython's `%pip …` and `!ls` lines are coloured as shell.
final class NotebookHighlighter {
    private let engine: SyntaxEngine
    private weak var layoutManager: NSLayoutManager?
    private let runs: [(range: NSRange, grammar: String)]
    private var current = 0
    /// Where the next line starts, in the current run.
    private var location = 0
    private var state: ShikiGrammarState?
    private var scheduled = false
    private lazy var magicColor: NSColor? = engine.tokenize(line: "import", language: "python", after: nil)
        .flatMap { engine.color($0.tokens.first?.color) }

    var isDone: Bool { current >= runs.count }

    init(engine: SyntaxEngine, code: [(range: NSRange, language: String?)], layoutManager: NSLayoutManager) {
        self.engine = engine
        self.layoutManager = layoutManager
        runs = code.compactMap { cell in engine.language(cell.language).map { (range: cell.range, grammar: $0) } }
        location = runs.first?.range.location ?? 0
    }

    func run(budget: TimeInterval = DocumentHighlighter.sliceBudget) {
        guard let layoutManager, let storage = layoutManager.textStorage else { return }
        let text = storage.string as NSString
        let deadline = Date().addingTimeInterval(budget)
        while current < runs.count {
            let (range, grammar) = runs[current]
            let end = NSMaxRange(range)
            guard end <= text.length else { current = runs.count; break } // the text changed under us
            if location >= end {
                current += 1
                location = runs[safe: current]?.range.location ?? 0
                state = nil
                continue
            }
            let newline = text.range(of: "\n", options: .literal, range: NSRange(location: location, length: end - location))
            let line = NSRange(location: location, length: (newline.location == NSNotFound ? end : newline.location) - location)
            colour(line: line, text: text.substring(with: line), grammar: grammar, in: layoutManager)
            location = NSMaxRange(line) + 1
            if Date() > deadline { break }
        }
        if current < runs.count { schedule() }
    }

    private func colour(line: NSRange, text: String, grammar: String, in layoutManager: NSLayoutManager) {
        // A magic only where a statement can start: not inside a string or brackets.
        if grammar == "python", state.map({ $0.scopes.count <= 1 }) ?? true, let magic = Notebook.magicPrefixLength(text) {
            if let magicColor { layoutManager.addTemporaryAttribute(.foregroundColor, value: magicColor, forCharacterRange: NSRange(location: line.location, length: magic)) }
            let rest = (text as NSString).substring(from: magic)
            if let shell = engine.language("shellscript"), let result = engine.tokenize(line: rest, language: shell, after: nil) {
                apply(result.tokens, at: NSRange(location: line.location + magic, length: line.length - magic), in: layoutManager)
            }
            return
        }
        guard let result = engine.tokenize(line: text, language: grammar, after: state) else { return }
        state = result.state
        apply(result.tokens, at: line, in: layoutManager)
    }

    private func apply(_ tokens: [ThemedToken], at line: NSRange, in layoutManager: NSLayoutManager) {
        for token in tokens {
            let length = (token.content as NSString).length
            guard length > 0, token.offset >= 0, token.offset + length <= line.length, let color = engine.color(token.color) else { continue }
            layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: NSRange(location: line.location + token.offset, length: length))
        }
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.run()
        }
    }
}
