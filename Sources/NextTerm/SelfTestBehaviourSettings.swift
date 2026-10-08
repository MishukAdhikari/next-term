import AppKit
import NextTermCore
import SwiftTerm

/// Settings › Terminal's cursor, scrollback and start folder, and Settings › Editor's clean-up on save and hidden
/// files: each one in the open window, an import of them and its exact undo, and both Settings tabs fitting their
/// window.
extension SelfTest {
    static let behaviourKeys = ["terminalScrollback", "terminalStartFolder", "terminalCursorShape", "terminalCursorBlink",
                                "trimTrailingWhitespace", "insertFinalNewline", "hiddenFilePatterns"]

    static func behaviourSettingsChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let app = AppDelegate.shared else { return }
        let defaults = UserDefaults.standard
        let saved = behaviourKeys.map { defaults.object(forKey: $0) }
        behaviourKeys.forEach(defaults.removeObject(forKey:))
        defer {
            for (key, value) in zip(behaviourKeys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            app.setTerminalCursor()
            app.setTerminalScrollback(defaults.object(forKey: "terminalScrollback") == nil ? nil : Preferences.terminalScrollback)
            app.setHiddenFilePatterns(Preferences.hiddenFilePatterns)
        }
        await terminalBehaviourChecks(c, app: app)
        await cleanUpOnSaveChecks(c, proj: proj, app: app)
        await hiddenFileChecks(c, app: app)
        await behaviourImportChecks(c, app: app)
        settingsFitChecks()
    }

    private static func terminalBehaviourChecks(_ c: TerminalWindowController, app: AppDelegate) async {
        guard let tab = c.activeTab ?? c.tabs.first else { return check(false, "terminal settings: a tab to check") }
        // The defaults, whatever this Mac had saved (the keys were taken away above).
        app.setTerminalCursor()
        app.setTerminalScrollback(nil)
        let terminal = tab.view.getTerminal()
        check(terminal.options.cursorStyle == .blinkBlock && terminal.options.scrollback == NextTermView.scrollbackLines,
              "terminals have a blinking block cursor and 10,000 lines of scrollback by default",
              "\(terminal.options.cursorStyle) \(terminal.options.scrollback)")

        app.setTerminalCursor(shape: .bar, blinks: false)
        check(c.tabs.allSatisfy { $0.view.getTerminal().options.cursorStyle == .steadyBar },
              "Settings › Terminal › Cursor changes every open terminal at once")
        // A program putting the cursor back (DECSCUSR 0, as vim does on quitting) gets the chosen one.
        tab.view.feed(text: "\u{1b}[5 q")
        let programs = terminal.options.cursorStyle
        tab.view.feed(text: "\u{1b}[0 q")
        check(programs == .blinkBar && terminal.options.cursorStyle == .steadyBar,
              "a program can set its own cursor, and putting it back gives the chosen one", "\(programs) \(terminal.options.cursorStyle)")
        app.setTerminalCursor(shape: .underline, blinks: true)
        check(terminal.options.cursorStyle == .blinkUnderline, "an underline that blinks")
        let fresh = NextTermView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        check(fresh.getTerminal().options.cursorStyle == .blinkUnderline, "a new terminal starts with the chosen cursor")

        app.setTerminalScrollback(2_000)
        check(c.tabs.allSatisfy { $0.view.getTerminal().options.scrollback == 2_000 }
              && NextTermView(frame: .zero).getTerminal().options.scrollback == 2_000,
              "Settings › Terminal › Scrollback changes open terminals and new ones")
        app.setTerminalScrollback(nil)
        check(terminal.options.scrollback == NextTermView.scrollbackLines && defaults(has: "terminalScrollback") == false,
              "and goes back to 10,000 lines")

        // Where ⌘T opens a tab.
        let current = c.activeTab.flatMap { $0.remote == nil ? $0.currentDirectory() : nil }
        Preferences.terminalStartFolder = .home
        check(c.newTabDirectory() == NSHomeDirectory(), "New tabs: in your home folder", c.newTabDirectory() ?? "nil")
        Preferences.terminalStartFolder = .current
        check(c.newTabDirectory() == (current ?? c.project), "New tabs: in the current tab’s folder", c.newTabDirectory() ?? "nil")
        Preferences.terminalStartFolder = .folder("/nonexistent-next-term-folder")
        check(c.newTabDirectory() == (c.project ?? current), "a chosen folder that is gone falls back to the project’s rule")
        UserDefaults.standard.removeObject(forKey: "terminalStartFolder")
        check(c.newTabDirectory() == (c.project ?? current), "New tabs: in the project’s folder (or the current tab’s), as before")
    }

    private static func defaults(has key: String) -> Bool { UserDefaults.standard.object(forKey: key) != nil }

    private static func cleanUpOnSaveChecks(_ c: TerminalWindowController, proj: URL, app: AppDelegate) async {
        let file = proj.appendingPathComponent("clean-up.txt"), markdown = proj.appendingPathComponent("clean-up.md")
        try? Data("one  \ntwo\t".utf8).write(to: file)
        try? Data("line break  \nend".utf8).write(to: markdown)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: markdown)
        }
        func save(_ url: URL) async -> (disk: String, editor: CodeEditorView?) {
            c.openFile(url)
            guard let editor = c.editorArea.activeEditor, editor.document.path == canonicalPath(url.path) else { return ("", nil) }
            // A change of its own makes it dirty, as typing would, in an undo step of its own.
            editor.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
            await pause(0.2)
            c.editorArea.save(editor.document)
            return ((try? String(contentsOf: url, encoding: .utf8)) ?? "", editor)
        }

        // Off (the default): saved as it is.
        let untouched = await save(file)
        check(untouched.disk == "xone  \ntwo\t", "clean-up on save is off by default", untouched.disk.debugDescription)
        if let editor = untouched.editor { c.editorArea.close(editor) }
        try? Data("one  \ntwo\t".utf8).write(to: file)

        Preferences.trimTrailingWhitespace = true
        Preferences.insertFinalNewline = true
        let cleaned = await save(file)
        check(cleaned.disk == "xone\ntwo\n", "Trim trailing spaces and End files with a newline, as the file is saved",
              cleaned.disk.debugDescription)
        if let editor = cleaned.editor {
            let doc = editor.document
            doc.undoManager.undo()
            check(doc.text == "xone  \ntwo\t", "⌘Z undoes the clean-up in one step", doc.text.debugDescription)
            if doc.isDirty { doc.reload() }
            c.editorArea.close(editor)
        }
        // Markdown keeps its two-space line breaks, and still gets its newline.
        let kept = await save(markdown)
        check(kept.disk == "xline break  \nend\n", "a Markdown file keeps its trailing spaces", kept.disk.debugDescription)
        if let editor = kept.editor { c.editorArea.close(editor) }
        UserDefaults.standard.removeObject(forKey: "trimTrailingWhitespace")
        UserDefaults.standard.removeObject(forKey: "insertFinalNewline")
    }

    private static func hiddenFileChecks(_ c: TerminalWindowController, app: AppDelegate) async {
        guard let root = c.sidebar.root else { return check(false, "hidden files: the sidebar shows a folder") }
        let hidden = root.url.appendingPathComponent("scratch.hide-me")
        try? Data().write(to: hidden)
        defer { try? FileManager.default.removeItem(at: hidden) }
        func shown() -> Bool { root.children?.contains { $0.name == "scratch.hide-me" } == true }
        c.sidebar.reloadAll()
        check(await wait(5) { shown() }, "a file shows in the sidebar before it is hidden")
        app.setHiddenFilePatterns(FileHiding.patterns(from: "*.hide-me, /no-such-folder"))
        check(await wait(5) { !shown() }, "Settings › Editor › Hide leaves it out of the sidebar")
        app.setHiddenFilePatterns([])
        check(await wait(5) { shown() }, "and it shows again when the pattern goes")
    }

    /// An import of the new settings, then Undo Import: every value as it was, the open terminals too.
    private static func behaviourImportChecks(_ c: TerminalWindowController, app: AppDelegate) async {
        let settings = [PlannedSetting(.terminalScrollback(3_000), source: "Scrollback Lines 3000"),
                        PlannedSetting(.terminalCursorShape("underline"), source: "Cursor Type Underline"),
                        PlannedSetting(.terminalCursorBlink(false), source: "Blinking Cursor false"),
                        PlannedSetting(.terminalStartFolder("current"), source: "Custom Directory Recycle"),
                        PlannedSetting(.trimTrailingWhitespace(true), source: "files.trimTrailingWhitespace true"),
                        PlannedSetting(.hiddenFiles(["*.import-test"]), source: "files.exclude")]
        app.setHiddenFilePatterns(["mine"])
        app.setTerminalCursor(shape: .bar)
        let plan = ImportPlan(preset: .nextTerm, settings: settings)
        let lastBefore = ImportCoordinator.shared.last
        ImportCoordinator.shared.apply(ImportChoice(usePreset: false, settings: settings, recentProjects: []), plan: plan, from: "iTerm2")
        guard let terminal = c.tabs.first?.view.getTerminal() else { return check(false, "an import of terminal settings: a tab to check") }
        let expectedPatterns = ["mine", "*.import-test"]
        let terminalSet = terminal.options.scrollback == 3_000 && terminal.options.cursorStyle == .steadyUnderline
        let savedSet = Preferences.terminalScrollback == 3_000 && Preferences.terminalStartFolder == .current
        let editorSet = Preferences.trimTrailingWhitespace && Preferences.hiddenFilePatterns == expectedPatterns
        check(terminalSet && savedSet && editorSet,
              "an import sets the cursor, scrollback, start folder, clean-up and hidden files (added to yours)",
              "\(Preferences.terminalScrollback) \(terminal.options.cursorStyle) \(Preferences.hiddenFilePatterns)")
        ImportCoordinator.shared.undo()
        let terminalBack = terminal.options.scrollback == NextTermView.scrollbackLines && terminal.options.cursorStyle == .blinkBar
        let savedBack = !defaults(has: "terminalScrollback") && !defaults(has: "terminalStartFolder") && !defaults(has: "trimTrailingWhitespace")
        let patternsBack = Preferences.hiddenFilePatterns == ["mine"]
        check(terminalBack && savedBack && patternsBack, "Undo Import puts each of them back, in the open terminals too",
              "\(Preferences.terminalScrollback) \(terminal.options.cursorStyle) \(Preferences.hiddenFilePatterns)")
        ImportCoordinator.shared.last = lastBefore
    }

    /// Both tabs with new rows fit the window as it opens.
    private static func settingsFitChecks() {
        let settings = SettingsWindowController()
        defer { settings.window?.close() }
        guard let tabs = settings.window?.contentView as? NSTabView else { return check(false, "Settings opens as tabs") }
        for id in ["editor", "terminal"] {
            tabs.selectTabViewItem(withIdentifier: id)
            tabs.layoutSubtreeIfNeeded()
            guard let page = tabs.selectedTabViewItem?.view, let stack = page.subviews.compactMap({ $0 as? NSStackView }).first else {
                check(false, "Settings › \(id) has its rows")
                continue
            }
            let needed = stack.fittingSize.height + 24
            check(needed <= page.bounds.height, "Settings › \(id) fits its window", "\(Int(needed)) > \(Int(page.bounds.height))")
        }
        let terminal = tabs.tabViewItems.first { $0.identifier as? String == "terminal" }?.view as? TerminalSettingsView
        let shapes = terminal?.behaviour.shape.numberOfItems ?? 0
        let folders = terminal?.behaviour.startFolder.numberOfItems ?? 0
        check(shapes == 3 && folders >= 5, "Settings › Terminal offers three cursors and where new tabs open", "\(shapes) \(folders)")
    }
}
