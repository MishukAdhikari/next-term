import AppKit
import NextTermCore

/// The project sidebar's right-click menu: each item shows the key of its command as Settings › Keyboard Shortcuts has
/// it, a change there shows the next time the menu opens, and the keys do what the items do while the sidebar has the
/// keyboard, through the sidebar's own handler, and nothing while the terminal or the editor has it.
extension SelfTest {
    static func sidebarMenuKeyChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let window = c.window, c.isSidebarVisible else { return note("sidebar menu keys: the sidebar is hidden, so not checked") }
        let shortcuts = KeyboardShortcuts.shared
        let savedBindings = shortcuts.bindings, savedPreset = shortcuts.preset
        defer {
            shortcuts.bindings = savedBindings
            shortcuts.preset = savedPreset // applies both
        }
        shortcuts.preset = .nextTerm
        shortcuts.resetAll()

        // No sidebar command starts on a key a command it can't share with has, in Next Term's keys or either set.
        let sidebarIDs = KeyBindings.partCommands.filter { $0.part == .sidebar }.map(\.id)
        for preset in KeymapPreset.allCases {
            let chords = shortcuts.chords(under: preset)
            let clashes = sidebarIDs.compactMap { id -> String? in
                guard let chord = chords[id] ?? nil else { return nil }
                let owners = KeyBindings().owners(of: chord, defaults: chords, except: id)
                return owners.isEmpty ? nil : "\(id) \(chord.display): \(owners.joined(separator: ", "))"
            }
            check(clashes.isEmpty, "sidebar menu keys: no default clashes under \(preset.name)'s keys", clashes.joined(separator: "; "))
        }

        // A folder of its own with one file, selected.
        let folder = proj.appendingPathComponent("menu-keys")
        let file = folder.appendingPathComponent("keys.txt")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data("keys\n".utf8).write(to: file)
        defer {
            try? FileManager.default.removeItem(at: folder)
            c.sidebar.reloadAll()
        }
        let outline = c.sidebar.outline
        let path = canonicalPath(file.path)
        func fileRow() -> Int {
            for row in 0..<outline.numberOfRows where (outline.item(atRow: row) as? FileNode)?.path == path { return row }
            return -1
        }
        c.sidebar.reloadAll()
        _ = await wait(5) { c.sidebar.root?.node(at: canonicalPath(folder.path)) != nil }
        c.sidebar.reveal(path)
        guard await wait(5, { fileRow() >= 0 && outline.selectedRowIndexes == IndexSet(integer: fileRow()) }) else {
            return check(false, "sidebar menu keys: the file shows in the sidebar, selected")
        }

        // The menu a right-click on it shows, each item with its command's key as the menu bar shows one.
        func menu(forRow row: Int) -> NSMenu {
            let menu = NSMenu()
            c.sidebar.fill(menu, forRow: row)
            return menu
        }
        func keys(_ menu: NSMenu) -> [String: String] {
            var keys: [String: String] = [:]
            for item in menu.items where !item.isSeparatorItem { keys[item.title] = KeyboardShortcuts.chord(of: item)?.display ?? "none" }
            return keys
        }
        let titles = ["Open", "Open Folder in New Tab", "Reveal in Finder", "New File", "New Folder", "Rename…", "Move to Trash", "Send to Agent",
                      "Insert Path in Terminal", "Copy Path", "Copy Relative Path", "Refresh"]
        let shown = keys(menu(forRow: fileRow()))
        let listed = titles.map { "\($0) \(shown[$0] ?? "missing")" }
        let expected = ["Open ⌘↓", "Open Folder in New Tab none", "Reveal in Finder ⌥⌘R", "New File ⌥⌘N", "New Folder ⇧⌘N", "Rename… ↩",
                        "Move to Trash ⌘⌫", "Send to Agent ⌥⌘K", "Insert Path in Terminal none", "Copy Path ⌥⌘C", "Copy Relative Path ⌥⇧⌘C",
                        "Refresh none"]
        check(listed == expected, "sidebar menu keys: a file's right-click menu shows each command's key", listed.joined(separator: ", "))

        // Every row's menu (the project's, folders', files', deleted files', Databases', Agent Sessions'): each item is a
        // command and shows its key now. Only the agents' Continue Latest after the first are none: one key does one.
        var wrong: [String] = []
        func audit(_ menu: NSMenu, _ row: String) {
            for item in menu.items where !item.isSeparatorItem {
                let key = KeyboardShortcuts.chord(of: item)
                guard let id = item.identifier?.rawValue else {
                    if !item.title.hasPrefix("Continue Latest") || key != nil { wrong.append("\(row): \(item.title) is no command") }
                    continue
                }
                if key != shortcuts.chord(for: id) { wrong.append("\(row): \(item.title) shows \(key?.display ?? "none")") }
            }
        }
        for row in 0..<outline.numberOfRows { audit(menu(forRow: row), "row \(row)") }
        audit(c.sidebar.sessionsGroupMenu(), "Agent Sessions")
        check(wrong.isEmpty, "sidebar menu keys: every item of every row's menu shows its command's key", wrong.joined(separator: "; "))

        // Keys as AppKit hands a key with ⌘ over: to the window's views, then to the menu bar. The sidebar's handler is
        // watched, to see the key went through it.
        func press(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: code)
        }
        func send(_ event: NSEvent?) {
            guard let event, !window.performKeyEquivalent(with: event) else { return }
            _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
        }
        let pasteboard = NSPasteboard.general
        func copied(after event: NSEvent?) -> String {
            pasteboard.clearContents()
            send(event)
            return pasteboard.string(forType: .string) ?? "nothing"
        }
        let savedOnCommand = outline.onCommand
        defer { outline.onCommand = savedOnCommand }
        var dispatched: [String] = []
        outline.onCommand = { id in
            dispatched.append(id)
            savedOnCommand?(id)
        }
        let optionCommandC = press("c", code: 8, [.command, .option])

        window.makeFirstResponder(outline)
        let byDefault = copied(after: optionCommandC)
        check(byDefault == path && dispatched == ["sidebar.copyPath"],
              "sidebar menu keys: ⌥⌘C with the sidebar's keyboard copies the selected file's path, through the sidebar's handler",
              "\(byDefault), \(dispatched)")

        // Copy Path moved, Reveal in Finder's key removed: the next menu says so, and only the new key copies.
        shortcuts.set(KeyChord(key: "c", command: true, option: true, control: true), for: "sidebar.copyPath")
        shortcuts.set(nil, for: "sidebar.reveal")
        let changed = keys(menu(forRow: fileRow()))
        let moved = [changed["Copy Path"] ?? "missing", changed["Reveal in Finder"] ?? "missing", changed["Copy Relative Path"] ?? "missing"]
        check(moved == ["⌃⌥⌘C", "none", "⌥⇧⌘C"], "sidebar menu keys: a key changed in Settings shows in the next menu, and a removed one goes",
              moved.joined(separator: " "))
        dispatched = []
        let byOldKey = copied(after: optionCommandC)
        let byNewKey = copied(after: press("c", code: 8, [.command, .option, .control]))
        check(byOldKey == "nothing" && byNewKey == path && dispatched == ["sidebar.copyPath"], "and the sidebar answers the new key, not the old one",
              "\(byOldKey), \(byNewKey), \(dispatched)")
        shortcuts.resetAll()

        // ⌥⌘N: a new file beside the selected one (its rename ended at once, keeping the name).
        func untitled() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("untitled") }.sorted()
        }
        let optionCommandN = press("n", code: 45, [.command, .option])
        dispatched = []
        send(optionCommandN)
        let made = untitled()
        await pause(0.3)
        window.makeFirstResponder(outline)
        check(made.count == 1 && dispatched == ["sidebar.newFile"], "sidebar menu keys: ⌥⌘N with the sidebar's keyboard makes a new file",
              "\(made), \(dispatched)")

        // With the terminal's keyboard, then the editor's, neither key does anything, though the sidebar's own menu holds
        // both as they show after a right-click, and the file stays selected there.
        let row = fileRow()
        guard row >= 0, let terminal = c.activeTab?.view else {
            return check(false, "sidebar menu keys: the file and a terminal for the keys elsewhere")
        }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if let rowMenu = outline.menu { c.sidebar.fill(rowMenu, forRow: row) }
        // The menu bar's items keep the keys the sidebar's menu shows too (on macOS 26 an item doesn't take a key another
        // item of its menus still holds).
        func barKey(_ id: String) -> String {
            shortcuts.commands.first { $0.id == id }?.item.flatMap(KeyboardShortcuts.chord(of:))?.display ?? "none"
        }
        let held = outline.menu.map(keys) ?? [:]
        let bar = [barKey("sendToAgent:"), barKey("renameTab:"), held["Send to Agent"] ?? "missing", held["Reveal in Finder"] ?? "missing"]
        check(bar == ["⌥⌘K", "⌥⌘R", "⌥⌘K", "⌥⌘R"], "sidebar menu keys: the menu bar's Send to Agent and Rename Tab keep their keys beside the sidebar's menu",
              bar.joined(separator: " "))
        let before = untitled()
        dispatched = []
        window.makeFirstResponder(terminal)
        let inTerminal = window.firstResponder === terminal
        let fromTerminal = copied(after: optionCommandC)
        send(optionCommandN)
        let terminalSaw = "\(fromTerminal), \(untitled()), \(dispatched)"
        let terminalQuiet = inTerminal && fromTerminal == "nothing" && untitled() == before && dispatched.isEmpty
        c.openFile(file)
        let editor = c.editorArea.activeEditor
        if let view = editor?.textView { window.makeFirstResponder(view) }
        let editing = editor != nil && window.firstResponder === editor?.textView
        let fromEditor = copied(after: optionCommandC)
        send(optionCommandN)
        let editorQuiet = editing && fromEditor == "nothing" && untitled() == before && dispatched.isEmpty
        if let editor { c.editorArea.close(editor) }
        check(terminalQuiet && editorQuiet, "sidebar menu keys: ⌥⌘C and ⌥⌘N do nothing with the terminal's or the editor's keyboard",
              "terminal (\(inTerminal)): \(terminalSaw); editor (\(editing)): \(fromEditor), \(untitled()), \(dispatched)")
        window.makeFirstResponder(terminal)
    }
}
