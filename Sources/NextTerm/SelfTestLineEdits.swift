import AppKit
import NextTermCore

/// Edit › Line on a scratch file (each edit and its undo), the whole-line copy and paste, Copy Path with Line,
/// and ⌘D: Duplicate Line while the editor has the keyboard and Split Right while the terminal has it, with
/// real key events through the window.
extension SelfTest {
    static func lineEditChecks(_ c: TerminalWindowController, proj: URL, tab: TerminalTab) async {
        guard let window = c.window else { return }
        let file = proj.appendingPathComponent("line-edits.txt")
        try? Data("one\r\ntwo\r\nthree\r\n".utf8).write(to: file) // Windows line endings, edited as plain newlines
        defer { try? FileManager.default.removeItem(at: file) }
        c.openFile(file)
        guard let editor = c.editorArea.activeEditor, editor.document.name == "line-edits.txt" else {
            return check(false, "line edits: the scratch file opens")
        }
        let view = editor.textView, doc = editor.document
        let text = "one\ntwo\nthree\n"
        defer {
            if doc.isDirty { doc.reload() }
            c.editorArea.close(editor)
        }
        window.makeFirstResponder(view)
        func place(line: Int, column: Int = 0, length: Int = 0) {
            view.setSelectedRange(NSRange(location: doc.lines.starts[line] + column, length: length))
        }

        /// An edit on the scratch file, the text it leaves, and ⌘Z back to the text before in one step.
        func step(_ name: String, _ expected: String, selected: NSRange? = nil, _ edit: () -> Void) {
            let before = doc.text
            edit()
            let selection = view.selectedRange()
            check(doc.text == expected && (selected.map { $0 == selection } ?? true), "line edits: \(name)",
                  "\(doc.text.debugDescription), selected \(selection)")
            doc.undoManager.undo()
            check(doc.text == before, "line edits: \(name), undone in one step", doc.text.debugDescription)
        }
        check(doc.text == text, "line edits: the scratch file is edited with plain newlines", doc.text.debugDescription)
        place(line: 1, column: 1)
        step("Duplicate Line puts a copy of the caret's line below it, the caret on the copy", "one\ntwo\ntwo\nthree\n",
             selected: NSRange(location: 9, length: 0)) { view.duplicateLine(nil) }
        place(line: 0, column: 1, length: 2)
        step("a selection in a line duplicates after itself, the copy selected", "onene\ntwo\nthree\n",
             selected: NSRange(location: 3, length: 2)) { view.duplicateLine(nil) }
        place(line: 0, column: 1, length: 5)
        step("a selection over lines duplicates the lines it touches", "one\ntwo\none\ntwo\nthree\n",
             selected: NSRange(location: 9, length: 5)) { view.duplicateLine(nil) }
        place(line: 1, column: 1)
        step("Delete Line takes the caret's line, the caret keeping its column", "one\nthree\n",
             selected: NSRange(location: 5, length: 0)) { view.deleteLine(nil) }
        place(line: 1, column: 1)
        step("Move Line Up", "two\none\nthree\n", selected: NSRange(location: 1, length: 0)) { view.moveLineUp(nil) }
        place(line: 1, column: 1)
        step("Move Line Down", "one\nthree\ntwo\n", selected: NSRange(location: 11, length: 0)) { view.moveLineDown(nil) }
        place(line: 0, length: 8)
        step("Move Line Down moves the selected lines and keeps them selected", "three\none\ntwo\n",
             selected: NSRange(location: 6, length: 8)) { view.moveLineDown(nil) }
        place(line: 0)
        view.moveLineUp(nil)
        check(doc.text == text && !doc.isDirty, "line edits: at the top, Move Line Up leaves the file as it is")

        // Typing, then a line edit: ⌘Z undoes the edit and leaves the typing.
        place(line: 2)
        view.insertText("x", replacementRange: view.selectedRange())
        await pause(0.1)
        view.duplicateLine(nil)
        doc.undoManager.undo()
        check(doc.text == "one\ntwo\nxthree\n", "line edits: ⌘Z after typing and Duplicate Line undoes only the duplicate", doc.text.debugDescription)
        doc.undoManager.undo()
        check(doc.text == text, "line edits: and the typing after it", doc.text.debugDescription)

        // Saved, a duplicated line keeps the file's CRLF.
        place(line: 0)
        view.duplicateLine(nil)
        c.saveDocument(nil)
        let saved = (try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) }
        check(saved == "one\r\none\r\ntwo\r\nthree\r\n", "line edits: saving keeps Windows line endings", saved.debugDescription)
        doc.undoManager.undo()
        c.saveDocument(nil)

        // ⌘C and ⌘X with nothing selected take the whole line; pasted with nothing selected it goes above the
        // caret's line. The clipboard is put back afterwards.
        let board = NSPasteboard.general
        let clipboard = board.string(forType: .string)
        defer {
            board.clearContents()
            if let clipboard { board.setString(clipboard, forType: .string) }
        }
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        place(line: 1, column: 2)
        check(view.validateMenuItem(copyItem), "whole-line copy: Copy is on with nothing selected")
        view.copy(nil)
        check(board.string(forType: .string) == "two\n" && board.string(forType: CodeTextView.wholeLineType) == "two\n",
              "whole-line copy: ⌘C with nothing selected copies the caret's line with its line break", board.string(forType: .string).debugDescription)
        place(line: 0, column: 1)
        step("whole-line paste: pasted with nothing selected, the line goes in above the caret's line, the caret staying in its text",
             "two\none\ntwo\nthree\n", selected: NSRange(location: 5, length: 0)) { view.paste(nil) }
        place(line: 0, column: 1, length: 1)
        step("whole-line paste: over a selection, it replaces the selection as any paste does", "otwo\ne\ntwo\nthree\n") { view.paste(nil) }
        place(line: 2, column: 2)
        step("whole-line cut: ⌘X with nothing selected cuts the caret's line", "one\ntwo\n") { view.cut(nil) }
        check(board.string(forType: .string) == "three\n", "whole-line cut: the line is on the clipboard", board.string(forType: .string).debugDescription)
        place(line: 0, length: 3)
        view.copy(nil)
        check(board.string(forType: .string) == "one" && board.string(forType: CodeTextView.wholeLineType) == nil,
              "a selection copies as before, and pastes where the caret is")
        place(line: 1)
        step("a selection's copy pastes at the caret", "one\nonetwo\nthree\n") { view.paste(nil) }

        // Copy Path with Line: the path from the project, with the caret's line or the selected lines; also in the
        // editor's right-click menu.
        place(line: 1)
        view.copyPathWithLine(nil)
        check(board.string(forType: .string) == "line-edits.txt:2", "Copy Path with Line copies path:line", board.string(forType: .string).debugDescription)
        place(line: 0, column: 1, length: 9)
        view.copyPathWithLine(nil)
        check(board.string(forType: .string) == "line-edits.txt:1-3", "and path:first-last for selected lines", board.string(forType: .string).debugDescription)
        let click = NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(NSPoint(x: 20, y: 10), to: nil), modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)
        let contextMenu = click.flatMap { view.menu(for: $0) }
        check(contextMenu?.items.contains { $0.title == "Copy Path with Line" } == true, "Copy Path with Line is in the editor's right-click menu")

        await keyChecks(c, view: view, doc: doc, tab: tab)
    }

    /// ⌘D in the editor and in the terminal, the menus' keys open and closed, and Settings' view of the pair.
    private static func keyChecks(_ c: TerminalWindowController, view: CodeTextView, doc: EditorDocument, tab: TerminalTab) async {
        guard let window = c.window else { return }
        let shortcuts = KeyboardShortcuts.shared
        let savedBindings = shortcuts.bindings
        let savedPreset = shortcuts.preset
        defer {
            shortcuts.bindings = savedBindings
            shortcuts.preset = savedPreset // applies both
        }
        shortcuts.preset = .nextTerm
        shortcuts.resetAll()
        func item(_ id: String) -> NSMenuItem? { shortcuts.commands.first { $0.id == id }?.item }
        let d = KeyChord(key: "d", command: true)
        let line = shortcuts.commands.first { $0.id == "duplicateLine:" }
        check(line?.path == "Edit › Line" && line?.defaultChord == d, "Edit › Line › Duplicate Line is a menu command, ⌘D by default",
              "\(line?.path ?? "missing") \(line?.defaultChord?.display ?? "no key")")
        let onD = shortcuts.commands.filter { shortcuts.chord(for: $0.id) == d }.map(\.id).sorted()
        check(onD == ["duplicateLine:", "splitRight:"], "Settings lists both Duplicate Line and Split Right on ⌘D", onD.joined(separator: ", "))
        check(shortcuts.bindings.owners(of: d, defaults: shortcuts.defaults, except: "duplicateLine:").isEmpty
              && shortcuts.bindings.owners(of: d, defaults: shortcuts.defaults, except: "splitRight:").isEmpty,
              "and does not call the pair a clash")
        check(shortcuts.bindings.owners(of: d, defaults: shortcuts.defaults, except: "goToLine:") == ["duplicateLine:", "splitRight:"],
              "but ⌘D for Go to Line clashes with both")
        let shared = "⌘D is Duplicate Line while the editor has the keyboard, Split Right everywhere else"
        check(ShortcutRecorder(commandID: "duplicateLine:").toolTip == shared && ShortcutRecorder(commandID: "splitRight:").toolTip == shared,
              "each shortcut in Settings says where ⌘D does what", ShortcutRecorder(commandID: "duplicateLine:").toolTip ?? "no tooltip")

        // The menu bar: Split Right holds ⌘D while the menus are closed; opened over the editor, Duplicate Line
        // shows it; over the terminal, Split Right does. Unshared keys show either way.
        func key(_ id: String) -> String { item(id).flatMap(KeyboardShortcuts.chord(of:))?.display ?? "none" }
        check(key("splitRight:") == "⌘D" && key("duplicateLine:") == "none" && key("deleteLine:") == "none",
              "with the menus closed, Split Right holds ⌘D and the editor's commands hold no key", "\(key("splitRight:")) \(key("duplicateLine:"))")
        shortcuts.menuBarOpened(editorHasKeyboard: true)
        check(key("duplicateLine:") == "⌘D" && key("splitRight:") == "none" && key("deleteLine:") == "⇧⌘K" && key("moveLineUp:") == "⌃⌘↑",
              "the menus opened over the editor show ⌘D on Duplicate Line", "\(key("duplicateLine:")) \(key("splitRight:")) \(key("moveLineUp:"))")
        shortcuts.menuBarClosed()
        shortcuts.menuBarOpened(editorHasKeyboard: false)
        check(key("duplicateLine:") == "none" && key("splitRight:") == "⌘D" && key("moveLineDown:") == "⌃⌘↓",
              "and over the terminal on Split Right", "\(key("duplicateLine:")) \(key("splitRight:"))")
        shortcuts.menuBarClosed()
        check(key("splitRight:") == "⌘D" && key("duplicateLine:") == "none", "closed again, as they were")

        guard NSApp.keyWindow === window else {
            return note("skipped ⌘D's key events: the window does not have the keyboard (app not frontmost?)")
        }
        func send(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
            NSApp.sendEvent(event)
        }
        let text = doc.text
        let panes = c.activeGroup?.panes.count ?? 0
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: doc.lines.starts[1], length: 0))
        check(NSApp.target(forAction: #selector(CodeTextView.duplicateLine(_:)), to: nil, from: nil) as? CodeTextView === view,
              "Edit › Line is on while the editor has the keyboard")
        send("d", code: 2, .command)
        check(doc.text == "one\ntwo\ntwo\nthree\n" && c.activeGroup?.panes.count == panes, "⌘D in the editor duplicates the line, and splits nothing",
              "\(doc.text.debugDescription), panes \(c.activeGroup?.panes.count ?? 0)")
        doc.undoManager.undo()
        view.setSelectedRange(NSRange(location: doc.lines.starts[1], length: 0))
        send("\u{F701}", code: 125, [.command, .control, .function, .numericPad])
        check(doc.text == "one\nthree\ntwo\n", "⌃⌘↓ in the editor moves the line down", doc.text.debugDescription)
        doc.undoManager.undo()
        view.setSelectedRange(NSRange(location: doc.lines.starts[1], length: 0))
        send("k", code: 40, [.command, .shift])
        check(doc.text == "one\nthree\n", "⇧⌘K in the editor deletes the line", doc.text.debugDescription)
        doc.undoManager.undo()
        check(doc.text == text, "and each is undone", doc.text.debugDescription)

        // The terminal has the keyboard: ⌘D splits it, and the file is left alone.
        guard let terminal = c.activeTab else { return check(false, "⌘D in the terminal: a terminal tab") }
        c.show(terminal)
        window.makeFirstResponder(terminal.view)
        check(NSApp.target(forAction: #selector(CodeTextView.duplicateLine(_:)), to: nil, from: nil) == nil,
              "Edit › Line is off while the terminal has the keyboard")
        send("d", code: 2, .command)
        let split = c.activeTab
        check(c.activeGroup?.panes.count == panes + 1 && doc.text == text, "⌘D in the terminal splits it, and the file is left alone",
              "panes \(c.activeGroup?.panes.count ?? 0), text \(doc.text.debugDescription)")
        if let split, split !== terminal, c.activeGroup?.panes.count == panes + 1 { c.remove(split) }

        // Another key for Duplicate Line: ⌘D splits from the editor too, and the new key duplicates.
        let other = KeyChord(key: "d", command: true, shift: true, control: true)
        shortcuts.set(other, for: "duplicateLine:")
        check(shortcuts.sharing("duplicateLine:") == nil && shortcuts.chord(for: "splitRight:") == d, "Duplicate Line can have another key")
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: doc.lines.starts[1], length: 0))
        send("d", code: 2, [.command, .shift, .control])
        check(doc.text == "one\ntwo\ntwo\nthree\n", "and that key duplicates in the editor", doc.text.debugDescription)
        doc.undoManager.undo()
        send("d", code: 2, .command)
        let fromEditor = c.activeTab
        check(c.activeGroup?.panes.count == panes + 1 && doc.text == text, "while ⌘D splits the terminal, from the editor too",
              "panes \(c.activeGroup?.panes.count ?? 0)")
        if let fromEditor, fromEditor !== terminal, c.activeGroup?.panes.count == panes + 1 { c.remove(fromEditor) }
        shortcuts.reset("duplicateLine:")

        // Another key for Split Right: ⌘D is the editor's alone, and the terminal's ⌘D reaches the terminal.
        shortcuts.set(KeyChord(key: "\\", command: true), for: "splitRight:")
        check(key("splitRight:") == "⌘\\" && shortcuts.chord(for: "duplicateLine:") == d, "Split Right can have another key, Duplicate Line keeping ⌘D")
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: doc.lines.starts[1], length: 0))
        send("d", code: 2, .command)
        check(doc.text == "one\ntwo\ntwo\nthree\n", "and ⌘D still duplicates in the editor", doc.text.debugDescription)
        doc.undoManager.undo()
        shortcuts.reset("splitRight:")
        window.makeFirstResponder(view)
    }
}
