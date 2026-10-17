import AppKit
import NextTermCore

/// The markdown part (NEXTTERM_SELFTEST_ONLY=markdown): Live Preview, in a scratch folder of the project. Every Markdown
/// fixture keeps its bytes when it is opened, switched, scrolled, selected and saved; the syntax is hidden but on the
/// caret's line; the switch changes no text, dirty flag or undo; a .env file's mask still draws; the commands, their keys,
/// Return, Tab and a box's click each make one edit; ⌘-click opens a link at its heading; Go to Heading; an agent's
/// write; diffs as source; and notes on the time large files take.
extension SelfTest {
    static func markdownChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let app = AppDelegate.shared else { return }
        let folder = proj.appendingPathComponent("markdown-scratch")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let savedSetting = app.markdownLivePreview
        let savedChoices = app.markdownViewChoices
        defer {
            app.markdownLivePreview = savedSetting
            app.markdownViewChoices = savedChoices
            try? FileManager.default.removeItem(at: folder)
        }
        app.markdownLivePreview = true
        await markdownBytesChecks(c, folder: folder)
        await markdownPreviewChecks(c, folder: folder)
        markdownEnvMaskCheck(c, folder: folder)
        await markdownCommandChecks(c, folder: folder)
        await markdownHeadingChecks(c, folder: folder)
        markdownDiffChecks(c, folder: folder)
        await markdownLargeFileNotes(c, folder: folder)
    }

    /// Fixtures/Markdown in the source tree (the Core tests' own).
    static let markdownFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Tests/NextTermCoreTests/Fixtures/Markdown")

    /// A Markdown file opened, its styling done and laid out.
    private static func openMarkdown(_ c: TerminalWindowController, _ url: URL) async -> CodeEditorView? {
        c.openFile(url)
        guard let editor = c.editorArea.activeEditor, editor.document.path == canonicalPath(url.path) else { return nil }
        _ = await wait(10) { (editor.markdown?.pendingLines ?? 0) == 0 }
        let all = NSRange(location: 0, length: editor.document.storage.length)
        editor.textView.layoutManager?.ensureLayout(forCharacterRange: all)
        return editor
    }

    // MARK: bytes

    /// Opening, switching three times, scrolling, selecting all and saving leave each fixture's bytes as they were, and
    /// none of it but saving touches the file or marks it edited.
    private static func markdownBytesChecks(_ c: TerminalWindowController, folder: URL) async {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: markdownFixtures.path))?.filter { $0.hasSuffix(".md") }.sorted() ?? []
        guard !names.isEmpty else { return note("markdown: the fixtures are not in the source tree here; the bytes are not checked") }
        for name in names {
            let source = markdownFixtures.appendingPathComponent(name)
            let url = folder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.copyItem(at: source, to: url)
            guard let original = try? Data(contentsOf: url) else { continue }
            let stamp = FileStamp(path: url.path)
            guard let editor = await openMarkdown(c, url) else {
                check(false, "markdown: \(name) opens")
                continue
            }
            let doc = editor.document, view = editor.textView
            check(editor.showsLivePreview && !doc.isDirty && !doc.undoManager.canUndo, "markdown: \(name) opens in Live Preview, clean, with no undo step")
            for _ in 0..<3 { editor.toggleMarkdownPreview() }
            check(!doc.isDirty && !doc.undoManager.canUndo && FileStamp(path: url.path) == stamp,
                  "markdown: switching \(name) three times changes nothing: not dirty, no undo step, the file untouched")
            view.scrollToEndOfDocument(nil)
            view.selectAll(nil)
            view.scrollToBeginningOfDocument(nil)
            check(!doc.isDirty, "markdown: scrolling and selecting all in \(name) leave it clean")
            c.saveDocument(nil)
            check((try? Data(contentsOf: url)) == original, "markdown: \(name) saves to the same bytes",
                  "\((try? Data(contentsOf: url))?.count ?? -1) bytes, was \(original.count)")
            c.editorArea.close(editor)
        }
    }

    // MARK: hiding and drawing

    private static let previewText = "# Title\n\nSome **bold** and `code` text.\n\n- [ ] a task\n- an item\n\n---\n\n> a quote\n\n```\n# not a heading\n```\n"

    private static func markdownPreviewChecks(_ c: TerminalWindowController, folder: URL) async {
        guard let window = c.window, let app = AppDelegate.shared else { return }
        let url = folder.appendingPathComponent("preview.md")
        try? previewText.write(to: url, atomically: true, encoding: .utf8)
        guard let editor = await openMarkdown(c, url), let manager = editor.textView.layoutManager else { return check(false, "markdown: preview.md opens") }
        let view = editor.textView, doc = editor.document
        defer { c.editorArea.close(editor) }
        window.makeFirstResponder(view)
        func null(_ character: Int) -> Bool {
            manager.ensureLayout(forCharacterRange: NSRange(location: character, length: 1))
            return manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: character)).contains(.null)
        }
        func width(ofLine line: Int) -> CGFloat {
            let range = doc.lines.range(ofLine: line)
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: range.location, length: max(0, range.length - 1)), actualCharacterRange: nil)
            return manager.boundingRect(forGlyphRange: glyphs, in: view.textContainer!).width
        }
        func height(ofLine line: Int) -> CGFloat {
            manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: doc.lines.starts[line]), effectiveRange: nil).height
        }
        // The caret on the paragraph, put there by a click's worth of attention.
        view.setSelectedRange(NSRange(location: doc.lines.starts[2], length: 0))
        view.caretPlacedByUser = true
        let narrow = width(ofLine: 0)
        check(null(0) && null(1) && !null(2), "markdown: a heading's # and its space are hidden (null glyphs), its title is not")
        let bold = (previewText as NSString).range(of: "**bold**")
        check(!null(bold.location) && editor.preview?.revealed == 2...2, "markdown: the caret's line shows its syntax", "\(editor.preview?.revealed as Any)")
        check(height(ofLine: 0) > height(ofLine: 2), "markdown: a heading's line is taller than a paragraph's", "\(height(ofLine: 0)) vs \(height(ofLine: 2))")
        let font = doc.storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        check(font.map { abs($0.pointSize - EditorDocument.font.pointSize * 1.5) < 0.5 } == true, "markdown: a level-1 heading is 1.5 times the font's size")
        // Onto the heading: it shows; off it: hidden again, and only its own line moved.
        view.setSelectedRange(NSRange(location: 3, length: 0))
        check(!null(0) && width(ofLine: 0) > narrow, "markdown: the caret on the heading shows its #", "\(width(ofLine: 0)) vs \(narrow)")
        view.setSelectedRange(NSRange(location: doc.lines.starts[2], length: 0))
        check(null(0), "markdown: and moving off hides it again")
        check(!null(doc.lines.starts[12]), "markdown: nothing is hidden in a fence")
        // A drag over three lines keeps what shows until the mouse is up.
        let shownBefore = editor.preview?.revealed
        view.setSelectedRanges([NSValue(range: NSRange(location: 0, length: doc.lines.starts[4]))], affinity: .downstream, stillSelecting: true)
        check(editor.preview?.revealed == shownBefore, "markdown: while a drag selects, the lines shown stay as they were")
        view.setSelectedRanges([NSValue(range: NSRange(location: 0, length: doc.lines.starts[4]))], affinity: .downstream, stillSelecting: false)
        check(editor.preview?.revealed == 0...3, "markdown: at mouse-up the selected lines show their syntax", "\(editor.preview?.revealed as Any)")
        // The marks drawn over the characters.
        let task = doc.lines.starts[4], rule = doc.lines.starts[7], quote = doc.lines.starts[9]
        view.setSelectedRange(NSRange(location: doc.lines.starts[2], length: 0))
        let marks = editor.drawOver(in: NSRange(location: 0, length: doc.storage.length)).map(\.drawing)
        check(marks.contains(.checkbox(done: false)) && marks.contains(.listBullet) && marks.contains(.rule) && marks.contains(.quoteBar),
              "markdown: a box, a bullet, a rule and a quote bar are drawn", "\(marks)")
        check(editor.preview?.box(at: task + 3) != nil && editor.preview?.box(at: rule) == nil && quote > 0, "markdown: the box is where its brackets are")
        // An Option character types as typed.
        view.setSelectedRange(NSRange(location: doc.lines.starts[2], length: 0))
        pressKey(window, "ƒ", code: 3, flags: .option)
        check(doc.text.hasPrefix("# Title\n\nƒSome"), "markdown: ⌥F types ƒ", doc.text.prefix(20).debugDescription)
        await endOfEvent(doc.undoManager)
        doc.undoManager.undo()
        // Styling never marks the file edited nor makes an undo step, and a new font size restyles it.
        doc.reload()
        check(!doc.isDirty && !doc.undoManager.canUndo, "markdown: styling leaves the file clean, with nothing to undo")
        let size = app.fontSize
        app.setFontSize(size + 2)
        _ = await wait(5) { (editor.markdown?.pendingLines ?? 0) == 0 }
        let bigger = doc.storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        check(bigger.map { abs($0.pointSize - (size + 2) * 1.5) < 0.5 } == true, "markdown: a new font size restyles the headings", "\(bigger?.pointSize ?? 0)")
        app.setFontSize(size)
        check(!doc.isDirty, "markdown: and leaves the file clean")
        // An agent's write to the clean file: the changed line is restyled and the caret stays in its text, below.
        view.setSelectedRange(NSRange(location: doc.lines.starts[9] + 2, length: 0))
        try? previewText.replacingOccurrences(of: "Some **bold**", with: "## Agent").write(to: url, atomically: true, encoding: .utf8)
        doc.checkDisk()
        _ = await wait(5) { (editor.markdown?.pendingLines ?? 0) == 0 && doc.text.contains("## Agent") }
        let agentFont = doc.storage.attribute(.font, at: doc.lines.starts[2] + 3, effectiveRange: nil) as? NSFont
        let caret = view.selectedRange().location
        check(doc.lines.line(at: caret) == 9 && caret - doc.lines.starts[9] == 2 && agentFont.map { $0.pointSize > EditorDocument.font.pointSize } == true
              && !doc.isDirty, "markdown: an agent's write restyles the line it changed and keeps the caret", "\(caret) \(agentFont?.pointSize ?? 0)")
        // The switch's memory, and its menu item.
        editor.toggleMarkdownPreview()
        check(!editor.showsLivePreview && app.markdownViewChoices.choice(for: doc.path) == false && !null(0),
              "markdown: View › Markdown Live Preview shows the file as source, remembered for it")
        let item = NSMenuItem(title: "", action: #selector(TerminalWindowController.toggleMarkdownPreview(_:)), keyEquivalent: "")
        check(c.validateMenuItem(item) && item.state == .off && item.title == "Markdown Live Preview", "markdown: its menu item is on, unchecked")
        c.toggleMarkdownPreview(nil)
        check(editor.showsLivePreview && null(0) && c.validateMenuItem(item) && item.state == .on, "markdown: and back to Live Preview, checked")
    }

    /// A .env file's values still draw as bullets: they come through the same draw-over hook as Live Preview's marks.
    private static func markdownEnvMaskCheck(_ c: TerminalWindowController, folder: URL) {
        guard let app = AppDelegate.shared else { return }
        let env = folder.appendingPathComponent(".env")
        try? "API_KEY=abc123\n".write(to: env, atomically: true, encoding: .utf8)
        let hides = app.hidesEnvValues
        app.hidesEnvValues = true
        defer { app.hidesEnvValues = hides }
        c.openFile(env)
        guard let editor = c.editorArea.activeEditor, editor.isEnvFile else { return check(false, "markdown: a .env file opens") }
        let drawn = editor.drawOver(in: NSRange(location: 0, length: editor.document.storage.length))
        check(!drawn.isEmpty && drawn.allSatisfy { $0.drawing == .bullet } && editor.preview == nil,
              "markdown: a .env file's values still draw as bullets, through the hook Live Preview draws with", "\(drawn)")
        c.editorArea.close(editor)
    }

    // MARK: commands and keys

    private static func markdownCommandChecks(_ c: TerminalWindowController, folder: URL) async {
        guard let window = c.window else { return }
        let url = folder.appendingPathComponent("commands.md")
        let text = "# Notes\n\nmake this bold\n\n- one\n- two\n- [ ] a task\n\nSee [the setup](other.md#setup).\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? "# Other\n\nSome text.\n\n## Setup\n\nThe steps.\n".write(to: folder.appendingPathComponent("other.md"), atomically: true, encoding: .utf8)
        guard let editor = await openMarkdown(c, url) else { return check(false, "markdown: commands.md opens") }
        let view = editor.textView, doc = editor.document
        defer { c.editorArea.editors.filter { $0.document.path.hasPrefix(canonicalPath(folder.path)) }.forEach { c.editorArea.close($0) } }
        window.makeFirstResponder(view)
        let shortcuts = KeyboardShortcuts.shared
        let savedBindings = shortcuts.bindings, savedPreset = shortcuts.preset
        defer {
            shortcuts.bindings = savedBindings
            shortcuts.preset = savedPreset
        }
        shortcuts.preset = .nextTerm
        shortcuts.resetAll()
        let source = text as NSString
        // ⌘B on a selection, ⌘Z, ⇧⌘Z, as keys from the keyboard (each edit its own undo step, as after a real key).
        let bold = source.range(of: "bold")
        view.setSelectedRange(bold)
        pressKey(window, code: 11, [.command])
        await endOfEvent(doc.undoManager)
        check(doc.text.contains("make this **bold**") && view.selectedRange() == NSRange(location: bold.location + 2, length: 4),
              "markdown: ⌘B makes the selection bold and keeps it selected", doc.text.debugDescription)
        check(doc.undoManager.undoActionName == "Bold", "markdown: Edit › Undo says Undo Bold", doc.undoManager.undoActionName)
        doc.undoManager.undo()
        check(doc.text == text, "markdown: ⌘Z gives the exact bytes back")
        doc.undoManager.redo()
        check(doc.text.contains("**bold**"), "markdown: and ⇧⌘Z the bold again")
        doc.undoManager.undo()
        // Heading 2, Toggle Task, Return and Tab.
        view.setSelectedRange(NSRange(location: doc.lines.starts[2], length: 0))
        pressKey(window, code: 19, [.command, .option])
        await endOfEvent(doc.undoManager)
        check(doc.text.contains("\n## make this bold\n"), "markdown: ⌥⌘2 makes the line a level-2 heading", doc.text.debugDescription)
        doc.undoManager.undo()
        view.setSelectedRange(NSRange(location: doc.lines.starts[6] + 8, length: 0))
        view.toggleMarkdownTask(nil)
        await endOfEvent(doc.undoManager)
        check(doc.text.contains("- [x] a task") && view.selectedRange().location == doc.lines.starts[6] + 8, "markdown: Toggle Task ticks the task, the caret staying")
        doc.undoManager.undo()
        view.setSelectedRange(NSRange(location: NSMaxRange(doc.lines.range(ofLine: 5)) - 1, length: 0))
        view.insertNewline(nil)
        await endOfEvent(doc.undoManager)
        check(doc.text.contains("- two\n- \n- [ ] a task"), "markdown: Return after an item starts the next one", doc.text.debugDescription)
        view.insertNewline(nil)
        await endOfEvent(doc.undoManager)
        check(doc.text.contains("- two\n\n- [ ] a task"), "markdown: and Return on the empty item ends the list", doc.text.debugDescription)
        doc.undoManager.undo()
        doc.undoManager.undo()
        check(doc.text == text, "markdown: each Return is one undo step", doc.text.debugDescription)
        view.setSelectedRange(NSRange(location: doc.lines.starts[5] + 3, length: 0))
        view.insertTab(nil)
        await endOfEvent(doc.undoManager)
        check(doc.text.contains("- one\n  - two\n"), "markdown: Tab nests an item under the one above", doc.text.debugDescription)
        view.insertBacktab(nil)
        await endOfEvent(doc.undoManager)
        check(doc.text == text, "markdown: and ⇧Tab takes it back out", doc.text.debugDescription)
        // A click on the box, drawn while the editor has no keyboard: one byte, the caret where it was, one undo step.
        view.setSelectedRange(NSRange(location: doc.lines.starts[2] + 4, length: 0))
        view.caretPlacedByUser = false
        window.makeFirstResponder(nil)
        view.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: 0, length: doc.storage.length))
        let boxAt = doc.lines.starts[6] + 3
        if let manager = view.layoutManager, let container = view.textContainer,
           let down = NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(boxPoint(manager, container, view, boxAt), to: nil), modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                         eventNumber: 0, clickCount: 1, pressure: 1) {
            let caret = view.selectedRange()
            view.mouseDown(with: down)
            await endOfEvent(doc.undoManager)
            check(doc.text == source.replacingCharacters(in: NSRange(location: boxAt, length: 1), with: "x") && view.selectedRange() == caret,
                  "markdown: a click on a box ticks it, one character, and the caret stays", doc.text.debugDescription)
            doc.undoManager.undo()
            check(doc.text == text, "markdown: and ⌘Z unticks it in one step")
        }
        // ⌘-click on the link opens other.md at its Setup heading.
        let link = source.range(of: "the setup")
        if let manager = view.layoutManager, let container = view.textContainer,
           let click = NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(boxPoint(manager, container, view, link.location + 2), to: nil),
                                          modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            view.mouseDown(with: click)
            let other = c.editorArea.activeEditor
            let line = other.map { $0.document.lines.line(at: $0.textView.selectedRange().location) }
            check(other?.document.name == "other.md" && line == 4, "markdown: ⌘-click on a link opens its file at the heading its #anchor names",
                  "\(other?.document.name ?? "nothing") line \(line.map { $0 + 1 } ?? 0)")
            c.openFile(url)
        }
        window.makeFirstResponder(view)
        // ⌘E is still Use Selection for Find.
        view.setSelectedRange(source.range(of: "Notes"))
        pressKey(window, code: 14, [.command])
        check(NSPasteboard(name: .find).string(forType: .string) == "Notes", "markdown: ⌘E still puts the selection in Find")
        // ⌘B in a Swift file hides the sidebar, as everywhere but a Markdown file's editor.
        let swift = folder.appendingPathComponent("code.swift")
        try? "let x = 1\n".write(to: swift, atomically: true, encoding: .utf8)
        c.openFile(swift)
        if let code = c.editorArea.activeEditor, code.document.name == "code.swift" {
            window.makeFirstResponder(code.textView)
            let visible = c.isSidebarVisible
            pressKey(window, code: 11, [.command])
            check(c.isSidebarVisible != visible && code.document.text == "let x = 1\n", "markdown: ⌘B in a Swift file hides or shows the sidebar")
            pressKey(window, code: 11, [.command])
            c.editorArea.close(code)
        }
    }

    /// The middle of the glyph of a character, in the text view.
    private static func boxPoint(_ manager: NSLayoutManager, _ container: NSTextContainer, _ view: NSTextView, _ character: Int) -> NSPoint {
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: character, length: 1), actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        return NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
    }

    // MARK: Go to Heading

    private static func markdownHeadingChecks(_ c: TerminalWindowController, folder: URL) async {
        let url = folder.appendingPathComponent("headings.md")
        try? "# Guide\n\nIntro words here.\n\n## Install\n\n## Set up: the API\n\n```\n# not one\n```\n".write(to: url, atomically: true, encoding: .utf8)
        guard let editor = await openMarkdown(c, url) else { return check(false, "markdown: headings.md opens") }
        defer { c.editorArea.close(editor) }
        let item = NSMenuItem(title: "", action: #selector(TerminalWindowController.goToHeading(_:)), keyEquivalent: "")
        check(c.validateMenuItem(item), "markdown: Go to Heading… is on in a Markdown file")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        c.goToHeading(nil)
        let finder = c.headingFinder
        check(finder.isVisible && finder.shownTitles == ["Guide", "Install", "Set up: the API"], "markdown: Go to Heading lists the headings, not the fence's",
              finder.shownTitles.joined(separator: ", "))
        check(finder.footerText == "9 words · 44 characters · 1 min", "markdown: with the file's words, characters and reading time", finder.footerText)
        finder.query = "setup"
        check(finder.shownTitles.first == "Set up: the API", "markdown: typing narrows them", finder.shownTitles.joined(separator: ", "))
        finder.jumpToFirst()
        let line = editor.document.lines.line(at: editor.textView.selectedRange().location)
        check(!finder.isVisible && line == 6, "markdown: ↩ goes to the heading's line", "line \(line + 1)")
    }

    // MARK: diffs

    /// An agent's proposed edit of a Markdown file shows its source: its text views are the diff's own, with nothing
    /// hidden and no heading font.
    private static func markdownDiffChecks(_ c: TerminalWindowController, folder: URL) {
        let path = canonicalPath(folder.appendingPathComponent("preview.md").path)
        let diff = DiffPane(proposalFor: path, proposal: .init(original: "# Title\n", proposed: "## Title **bold**\n", author: "self-test",
                                                               tag: "markdown", client: nil))
        let texts = diff.sideTexts
        check(texts.1.contains("## Title **bold**"), "markdown: a proposed edit of a Markdown file shows its source", texts.1.debugDescription)
        var views: [NSView] = [diff]
        var styled = false
        while let view = views.popLast() {
            views += view.subviews
            guard let text = view as? NSTextView, let storage = text.textStorage, storage.length > 0 else { continue }
            if text.layoutManager?.delegate is MarkdownSpacing { styled = true }
            storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { font, _, _ in
                if let font = font as? NSFont, font.pointSize > EditorDocument.font.pointSize + 0.5 { styled = true }
            }
        }
        check(!styled, "markdown: with no Live Preview and no heading font in it")
    }

    // MARK: large files

    /// The time Live Preview takes on large files: a 1 MB file styled to the end, typing at the end and near the top of
    /// 20,000 lines, and a 3 MB file opening as source with the menu item off.
    private static func markdownLargeFileNotes(_ c: TerminalWindowController, folder: URL) async {
        guard let window = c.window else { return }
        var paragraph = "## Section\n\nSome **bold** text, a [link](a.md), `code` and _italic_ words in a longer line of prose.\n\n- [ ] a task\n- an item\n\n"
        while paragraph.utf8.count < 2_000 { paragraph += paragraph }
        let oneMB = String(repeating: paragraph, count: (1_048_576 / paragraph.utf8.count) + 1)
        let big = folder.appendingPathComponent("one-mb.md")
        try? oneMB.write(to: big, atomically: true, encoding: .utf8)
        let started = Date()
        c.openFile(big)
        if let editor = c.editorArea.activeEditor, editor.document.name == "one-mb.md" {
            let styled = await wait(30) { (editor.markdown?.pendingLines ?? 1) == 0 }
            note(String(format: "markdown: a 1 MB file (%ld lines) is styled to the end in %.2f s", editor.document.lines.count, Date().timeIntervalSince(started)))
            check(styled, "markdown: a 1 MB file is styled to the end")
            c.editorArea.close(editor)
        }
        let lines = (0..<20_000).map { $0 % 10 == 0 ? "## Heading \($0)" : "Line \($0) with **bold** text." }.joined(separator: "\n") + "\n"
        let long = folder.appendingPathComponent("twenty-thousand.md")
        try? lines.write(to: long, atomically: true, encoding: .utf8)
        if let editor = await openMarkdown(c, long) {
            window.makeFirstResponder(editor.textView)
            // Sixteen keys at a place: the average and the slowest, in ms.
            func typing(at location: Int) -> (average: Double, slowest: Double) {
                editor.textView.setSelectedRange(NSRange(location: location, length: 0))
                var slowest = 0.0, total = 0.0
                for character in "sixteen letters." {
                    let start = Date()
                    editor.textView.insertText(String(character), replacementRange: editor.textView.selectedRange())
                    let took = Date().timeIntervalSince(start) * 1000
                    slowest = max(slowest, took)
                    total += took
                }
                return (total / 16, slowest)
            }
            // At the end, and near the top, where each key's restyle finds the line below it ending as before and stops.
            let places: [(String, Int)] = [("the end", editor.document.storage.length), ("the top", editor.document.lines.starts[2] + 4)]
            for (place, location) in places {
                let (average, slowest) = typing(at: location)
                let took = String(format: "%.2f ms a key on average, %.2f ms at most", average, slowest)
                note("markdown: typing at \(place) of 20,000 lines restyles in \(took)")
                // The aim is under 2 ms a key (the note says); a key slower than a frame at 60 Hz is a failure.
                check(average < 16, "markdown: typing at \(place) of 20,000 lines takes less than a frame a key", String(format: "%.2f ms", average))
            }
            editor.document.reload()
            c.editorArea.close(editor)
        }
        let threeMB = folder.appendingPathComponent("three-mb.md")
        try? String(repeating: paragraph, count: (3 * 1_048_576 / paragraph.utf8.count) + 1).write(to: threeMB, atomically: true, encoding: .utf8)
        c.openFile(threeMB)
        if let editor = c.editorArea.activeEditor, editor.document.name == "three-mb.md" {
            let item = NSMenuItem(title: "", action: #selector(TerminalWindowController.toggleMarkdownPreview(_:)), keyEquivalent: "")
            let on = c.validateMenuItem(item)
            check(editor.markdown == nil && !on && item.title == "Markdown Live Preview (file too large)",
                  "markdown: a 3 MB file opens as source, the menu item off and saying why", item.title)
            c.editorArea.close(editor)
        }
    }
}
