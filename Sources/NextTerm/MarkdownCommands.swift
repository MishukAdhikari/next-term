import AppKit
import NextTermCore

/// Edit › Markdown, in a Markdown file's editor: each command one edit of the text (MarkdownEdits), undone in one step
/// named in Edit › Undo, in the markers the file already uses. Return, Tab and ⇧Tab in a list, a click on a task's box,
/// ⌘-click on a link and pasting an address over text go through here too. In any other file the commands are off, so
/// their keys go where they would without them (⌘B then hides the project sidebar).
extension CodeTextView {
    /// The Markdown file's styler, when this is a Markdown file's editor.
    var markdownStyler: MarkdownStyler? { (delegate as? CodeEditorView)?.markdown }

    static let markdownActions: Set<Selector> = [
        #selector(toggleMarkdownBold(_:)), #selector(toggleMarkdownItalic(_:)), #selector(toggleMarkdownStrikethrough(_:)),
        #selector(toggleMarkdownCode(_:)), #selector(insertMarkdownLink(_:)), #selector(markdownBodyText(_:)),
        #selector(markdownHeading(_:)), #selector(toggleMarkdownBullets(_:)), #selector(toggleMarkdownNumbers(_:)),
        #selector(toggleMarkdownTask(_:)), #selector(toggleMarkdownQuote(_:)), #selector(insertMarkdownCodeBlock(_:)),
    ]

    /// One Markdown command: its edit, applied as one undo step, or a beep when it does nothing here.
    private func markdown(_ name: String, _ make: (NSRange, NSString, LineIndex, MarkdownEdits.Lines, MarkdownStyle) -> LineEdits.Edit?) {
        guard isEditable, let styler = markdownStyler else { return NSSound.beep() }
        guard let edit = make(selectedRange(), string as NSString, lineIndex, { styler.line($0) }, styler.style) else { return NSSound.beep() }
        apply(edit, named: name)
    }

    @objc func toggleMarkdownBold(_ sender: Any?) {
        markdown("Bold") { MarkdownEdits.toggleWrap(.strong, selection: $0, in: $1, $2, lines: $3, style: $4) }
    }

    @objc func toggleMarkdownItalic(_ sender: Any?) {
        markdown("Italic") { MarkdownEdits.toggleWrap(.emphasis, selection: $0, in: $1, $2, lines: $3, style: $4) }
    }

    @objc func toggleMarkdownStrikethrough(_ sender: Any?) {
        markdown("Strikethrough") { MarkdownEdits.toggleWrap(.strikethrough, selection: $0, in: $1, $2, lines: $3, style: $4) }
    }

    @objc func toggleMarkdownCode(_ sender: Any?) {
        markdown("Code") { MarkdownEdits.toggleWrap(.code, selection: $0, in: $1, $2, lines: $3, style: $4) }
    }

    /// Link: with one web address on the clipboard it is the link's destination; otherwise the caret waits between
    /// the parentheses for one.
    @objc func insertMarkdownLink(_ sender: Any?) {
        let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let destination = MarkdownEdits.isWebAddress(copied) ? copied : ""
        markdown("Link") { selection, text, index, lines, _ in
            MarkdownEdits.link(selection: selection, in: text, index, lines: lines, destination: destination)
        }
    }

    @objc func markdownBodyText(_ sender: Any?) {
        markdown("Body Text") { selection, text, index, lines, _ in MarkdownEdits.heading(0, selection: selection, in: text, index, lines: lines) }
    }

    /// Heading 1 to 6, by the menu item's tag.
    @objc func markdownHeading(_ sender: Any?) {
        let level = min(max((sender as? NSMenuItem)?.tag ?? 1, 1), 6)
        markdown("Heading \(level)") { selection, text, index, lines, _ in
            MarkdownEdits.heading(level, selection: selection, in: text, index, lines: lines)
        }
    }

    @objc func toggleMarkdownBullets(_ sender: Any?) {
        markdown("Bulleted List") { MarkdownEdits.toggleBullets(selection: $0, in: $1, $2, lines: $3, style: $4) }
    }

    @objc func toggleMarkdownNumbers(_ sender: Any?) {
        markdown("Numbered List") { MarkdownEdits.toggleNumbers(selection: $0, in: $1, $2, lines: $3, style: $4) }
    }

    @objc func toggleMarkdownTask(_ sender: Any?) {
        markdown("Toggle Task") { MarkdownEdits.toggleTask(selection: $0, in: $1, $2, lines: $3, style: $4) }
    }

    @objc func toggleMarkdownQuote(_ sender: Any?) {
        markdown("Quote") { selection, text, index, lines, _ in MarkdownEdits.toggleQuote(selection: selection, in: text, index, lines: lines) }
    }

    @objc func insertMarkdownCodeBlock(_ sender: Any?) {
        markdown("Code Block") { selection, text, index, lines, _ in MarkdownEdits.codeBlock(selection: selection, in: text, index, lines: lines) }
    }

    // MARK: Return, Tab and paste

    /// Return in a list or a quote: the next item, or the end of the list on an empty one (MarkdownEdits.newline).
    func markdownNewline() -> Bool {
        guard isEditable, let styler = markdownStyler,
              let edit = MarkdownEdits.newline(at: selectedRange(), in: string as NSString, lineIndex, lines: { styler.line($0) }) else { return false }
        apply(edit, named: "Typing")
        return true
    }

    /// Tab (1) or ⇧Tab (-1) on a list item: nested under the item above, or back out.
    func markdownNest(_ step: Int) -> Bool {
        guard isEditable, let styler = markdownStyler,
              let edit = MarkdownEdits.nest(step, selection: selectedRange(), in: string as NSString, lineIndex, lines: { styler.line($0) }) else {
            return false
        }
        apply(edit, named: step > 0 ? "Indent" : "Outdent")
        return true
    }

    /// One web address pasted over text on one line: pasted as it is, then made `[text](address)` as a second step, so
    /// ⌘Z gives the plain paste back, then the text as it was.
    func pasteMarkdownLink() -> Bool {
        guard isEditable, let styler = markdownStyler, let pasted = NSPasteboard.general.string(forType: .string) else { return false }
        let selection = selectedRange()
        let text = string as NSString
        guard let link = MarkdownEdits.pastedLink(pasted, over: selection, in: text, lineIndex, lines: { styler.line($0) }) else { return false }
        let leading = text.substring(with: NSRange(location: selection.location, length: link.range.location - selection.location))
        let trailing = text.substring(with: NSRange(location: NSMaxRange(link.range), length: NSMaxRange(selection) - NSMaxRange(link.range)))
        let before = text.length
        super.paste(nil)
        let inserted = (string as NSString).length - before + selection.length
        guard inserted >= 0, selection.location + inserted <= (string as NSString).length else { return true }
        let replacement = leading + link.text + trailing
        let end = selection.location + (replacement as NSString).length
        apply(LineEdits.Edit(range: NSRange(location: selection.location, length: inserted), text: replacement,
                             selection: NSRange(location: end, length: 0)), named: "Paste as Link")
        return true
    }

    // MARK: clicks

    /// A click on a task's box ticks it (one character, one undo step) and leaves the caret where it was; ⌘-click on
    /// a link opens it. Either answers the click.
    func handleMarkdownClick(_ event: NSEvent) -> Bool {
        guard markdownStyler != nil, event.clickCount == 1, let character = character(at: convert(event.locationInWindow, from: nil)) else {
            return false
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags.isEmpty, isEditable, let preview = (delegate as? CodeEditorView)?.preview, let box = preview.box(at: character),
           let edit = MarkdownEdits.tick(box: box, in: string as NSString, selection: selectedRange()) {
            if window?.firstResponder !== self { window?.makeFirstResponder(self) }
            apply(edit, named: edit.text == "x" ? "Tick Task" : "Untick Task", scrolls: false)
            return true
        }
        if flags == .command { return openMarkdownLink(at: character) }
        return false
    }

    /// The character whose glyph is under a point of the view, if one is.
    private func character(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(inContainer) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    /// ⌘-click on a link: a web address in the browser (as the gate for links from a project's files allows), any other
    /// destination as a file next to this one, opened in Next Term at the heading its `#anchor` names.
    private func openMarkdownLink(at character: Int) -> Bool {
        guard let styler = markdownStyler, character < (string as NSString).length else { return false }
        let index = lineIndex
        let line = index.line(at: character)
        let local = character - index.starts[line]
        guard let link = styler.line(line).links.first(where: { NSLocationInRange(local, $0.range) }) else { return false }
        openMarkdownDestination(link.destination)
        return true
    }

    /// A web address opens in the browser, by the gate links from a project's files go through; any other
    /// destination is a file beside this one (or this file, for `#anchor` alone), opened in Next Term at the heading
    /// its `#anchor` names, as the file is open (unsaved edits too).
    func openMarkdownDestination(_ destination: String) {
        guard let document, let controller = window?.windowController as? TerminalWindowController else { return NSSound.beep() }
        if let url = URL(string: destination), let scheme = url.scheme?.lowercased(), scheme.count > 1 {
            guard scheme == "http" || scheme == "https", SafeWebLink.isAllowed(url) else { return NSSound.beep() }
            return WebLinks.open(url, from: window)
        }
        let parts = destination.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let written = String(parts.first ?? "")
        let path = written.removingPercentEncoding ?? written
        let folder = (document.path as NSString).deletingLastPathComponent
        let target = path.isEmpty ? document.path : ((path.hasPrefix("/") ? path : folder + "/" + path) as NSString).standardizingPath
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isFolder), !isFolder.boolValue else { return NSSound.beep() }
        controller.openFile(URL(fileURLWithPath: target))
        guard parts.count > 1, !parts[1].isEmpty, let editor = controller.editorArea.activeEditor,
              editor.document.path == canonicalPath(target), let styler = editor.markdown else { return }
        let text = editor.document.storage.string as NSString
        let headings = MarkdownOutline.headings(styler.allLines(), in: text, editor.document.lines)
        guard let heading = MarkdownOutline.heading(named: String(parts[1]), among: headings) else { return }
        editor.textView.go(toLine: heading.line + 1)
    }
}
