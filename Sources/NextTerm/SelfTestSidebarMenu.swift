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
        func barKey(_ id: String) -> String {
            shortcuts.commands.first { $0.id == id }?.item.flatMap(KeyboardShortcuts.chord(of:))?.display ?? "none"
        }
        let titles = ["Open", "Open Folder in New Tab", "Reveal in Finder", "New File", "New Folder", "Rename…", "Move to Trash", "Send to Agent",
                      "Insert Path in Terminal", "Copy Path", "Copy Relative Path", "Refresh"]
        let shown = keys(menu(forRow: fileRow()))
        let listed = titles.map { "\($0) \(shown[$0] ?? "missing")" }
        let expected = ["Open ⌘↓", "Open Folder in New Tab none", "Reveal in Finder ⌥⌘R", "New File ⌥⌘N", "New Folder ⇧⌘N", "Rename… none",
                        "Move to Trash ⌘⌫", "Send to Agent ⌥⌘K", "Insert Path in Terminal none", "Copy Path ⌥⌘C", "Copy Relative Path ⌥⇧⌘C",
                        "Refresh none"]
        check(listed == expected, "sidebar menu keys: a file's right-click menu shows each command's key", listed.joined(separator: ", "))
        // ↩, a key without ⌘ or ⌃, is named in Rename…'s tooltip: on the item it could be the open menu's own key.
        let renameTip = menu(forRow: fileRow()).items.first { $0.title == "Rename…" }?.toolTip ?? "none"
        check(renameTip == "Rename (↩)", "sidebar menu keys: Rename…'s ↩ is in its tooltip, not on the item", renameTip)

        // Every row's menu here (the project's, folders', files'), the Agent Sessions group's and a session's (none is in the
        // tree now): each item is a command showing its key (sidebarMenuKeyAudit). The Databases rows', deleted files' and
        // the sessions' own are audited where the tree has them (databaseChecks, deletedFileChecks, sidebarSessionChecks).
        let session = AgentSession(agent: .claude, id: "k1", cwd: proj.path, title: "Keys", named: false, createdAt: nil, updatedAt: Date(),
                                   gitBranch: nil, model: nil, isRunning: false)
        let audit = sidebarMenuKeyAudit((0..<outline.numberOfRows).map { (menu(forRow: $0), "row \($0)") }
            + [(c.sidebar.sessionsGroupMenu(), "Agent Sessions"), (c.sidebar.sessionMenu(for: SessionItem(session, inTab: false)), "a session")])
        let unseen = ["Open as Project", "Copy Path", "Refresh", "Show All Sessions…", "Refresh Sessions", "Resume", "Fork", "Copy Resume Command"]
            .filter { !audit.titles.contains($0) }
        check(audit.wrong.isEmpty && unseen.isEmpty, "sidebar menu keys: every item of every row's menu shows its command's key",
              (audit.wrong + unseen.map { "no \($0)" }).joined(separator: "; "))

        // Keys as AppKit hands a key with ⌘ over (pressKey). The sidebar's handler is watched, to see the key went through it.
        func optionCommandC() { pressKey("c", code: 8, [.command, .option], in: window) }
        func optionCommandN() { pressKey("n", code: 45, [.command, .option], in: window) }
        let pasteboard = NSPasteboard.general
        func copied(after press: () -> Void) -> String {
            pasteboard.clearContents()
            press()
            return pasteboard.string(forType: .string) ?? "nothing"
        }
        let savedOnCommand = outline.onCommand
        defer { outline.onCommand = savedOnCommand }
        var dispatched: [String] = []
        outline.onCommand = { id in
            dispatched.append(id)
            savedOnCommand?(id)
        }

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
        let byNewKey = copied { pressKey("c", code: 8, [.command, .option, .control], in: window) }
        check(byOldKey == "nothing" && byNewKey == path && dispatched == ["sidebar.copyPath"], "and the sidebar answers the new key, not the old one",
              "\(byOldKey), \(byNewKey), \(dispatched)")
        shortcuts.resetAll()

        // File › Copy Path given ⌥⌘C before it was the sidebar's Copy Path's default (a saved change, or an import then):
        // the sidebar's gives way, in its menu, its handler and Settings, which never lets the two have one key.
        let optionCommandCChord = KeyChord(key: "c", command: true, option: true)
        shortcuts.set(optionCommandCChord, for: "copyFilePath:")
        dispatched = []
        optionCommandC()
        let gaveWay = [shortcuts.chord(for: "sidebar.copyPath")?.display ?? "none", keys(menu(forRow: fileRow()))["Copy Path"] ?? "missing",
                       barKey("copyFilePath:")] + shortcuts.bindings.owners(of: optionCommandCChord, defaults: shortcuts.defaults, except: "goToLine:")
        check(gaveWay == ["none", "none", "⌥⌘C", "copyFilePath:"] && dispatched.isEmpty,
              "sidebar menu keys: a key you gave a menu command before it was a sidebar command's default stays the menu command's",
              "\(gaveWay), \(dispatched)")
        shortcuts.resetAll()

        // Settings' clash alert, VoiceOver and the import's preview name a key outside the menus with its part, apart from
        // the menu command of the same name.
        let names = [shortcuts.placedTitle(of: "copyFilePath:"), shortcuts.placedTitle(of: "sidebar.copyPath"),
                     ImportWindowController.presetLines(.vsCode).first { $0.hasPrefix("New Folder") } ?? "missing"]
        check(names == ["Copy Path", "Copy Path (Project Sidebar)", "New Folder (Project Sidebar)   ⇧⌘N → no key"],
              "sidebar menu keys: a sidebar command is named with its part, apart from the menu command of the same name",
              names.joined(separator: " | "))

        // ⌥⌘N: a new file beside the selected one (its rename ended at once, keeping the name).
        func untitled() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("untitled") }.sorted()
        }
        dispatched = []
        optionCommandN()
        let made = untitled()
        await pause(0.3)
        window.makeFirstResponder(outline)
        check(made.count == 1 && dispatched == ["sidebar.newFile"], "sidebar menu keys: ⌥⌘N with the sidebar's keyboard makes a new file",
              "\(made), \(dispatched)")

        // The menu a right-click opens shows the menu bar's Send to Agent and Rename Tab keys while the bar's items keep
        // them, and gives every key up as it closes: the bar's items take theirs again whenever the shortcuts change, and
        // on macOS 26 an item doesn't take a key another item still holds.
        let row = fileRow()
        guard row >= 0, let terminal = c.activeTab?.view, let rowMenu = outline.menu else {
            return check(false, "sidebar menu keys: the file, its menu and a terminal for the keys elsewhere")
        }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        c.sidebar.fill(rowMenu, forRow: row)
        let held = keys(rowMenu)
        let bar = [barKey("sendToAgent:"), barKey("renameTab:"), held["Send to Agent"] ?? "missing", held["Reveal in Finder"] ?? "missing"]
        check(bar == ["⌥⌘K", "⌥⌘R", "⌥⌘K", "⌥⌘R"], "sidebar menu keys: the menu bar's Send to Agent and Rename Tab keep their keys beside the sidebar's open menu",
              bar.joined(separator: " "))
        c.sidebar.menuDidClose(rowMenu)
        let left = rowMenu.items.compactMap(KeyboardShortcuts.chord(of:)).map(\.display)
        shortcuts.resetAll() // the shortcuts change after the right-click
        let retaken = [barKey("sendToAgent:"), barKey("renameTab:"), barKey("showChanges:")]
        check(left.isEmpty && retaken == ["⌥⌘K", "⌥⌘R", "⌥⌘G"],
              "sidebar menu keys: the closed menu holds no key, and the menu bar's items take theirs again when the shortcuts change",
              "left \(left), bar \(retaken)")

        // With the terminal's keyboard, then the editor's, neither key does anything, though the file stays selected in the
        // sidebar.
        let before = untitled()
        dispatched = []
        window.makeFirstResponder(terminal)
        let inTerminal = window.firstResponder === terminal
        let fromTerminal = copied(after: optionCommandC)
        optionCommandN()
        let terminalSaw = "\(fromTerminal), \(untitled()), \(dispatched)"
        let terminalQuiet = inTerminal && fromTerminal == "nothing" && untitled() == before && dispatched.isEmpty
        c.openFile(file)
        let editor = c.editorArea.activeEditor
        if let view = editor?.textView { window.makeFirstResponder(view) }
        let editing = editor != nil && window.firstResponder === editor?.textView
        let fromEditor = copied(after: optionCommandC)
        optionCommandN()
        let editorQuiet = editing && fromEditor == "nothing" && untitled() == before && dispatched.isEmpty
        if let editor { c.editorArea.close(editor) }
        check(terminalQuiet && editorQuiet, "sidebar menu keys: ⌥⌘C and ⌥⌘N do nothing with the terminal's or the editor's keyboard",
              "terminal (\(inTerminal)): \(terminalSaw); editor (\(editing)): \(fromEditor), \(untitled()), \(dispatched)")
        window.makeFirstResponder(terminal)
    }
    /// What is wrong with sidebar menus' keys, and every item's title: each item is a command (its identifier) showing the
    /// key that command has now, one without ⌘ or ⌃ named in its tooltip instead. Of the agents' Continue Latest, only the
    /// first is a command: one key does one of them.
    static func sidebarMenuKeyAudit(_ menus: [(menu: NSMenu, row: String)]) -> (wrong: [String], titles: [String]) {
        let shortcuts = KeyboardShortcuts.shared
        var wrong: [String] = [], titles: [String] = []
        for (menu, row) in menus {
            var continues = 0
            for item in menu.items where !item.isSeparatorItem {
                titles.append(item.title)
                let key = KeyboardShortcuts.chord(of: item)
                let id = item.identifier?.rawValue
                if item.title.hasPrefix("Continue Latest") {
                    continues += 1
                    if (id == "sidebar.continueLatest") != (continues == 1) { wrong.append("\(row): \(item.title) is \(id ?? "no command")") }
                }
                guard let id else {
                    if key != nil || !item.title.hasPrefix("Continue Latest") { wrong.append("\(row): \(item.title) is no command") }
                    continue
                }
                let chord = shortcuts.chord(for: id)
                let onItem = chord?.isUsable == false ? nil : chord
                let named = chord?.isUsable != false || item.toolTip?.contains(chord?.display ?? "") == true
                if key != onItem || !named { wrong.append("\(row): \(item.title) shows \(key?.display ?? "none")") }
            }
        }
        return (wrong, titles)
    }

    /// The right-click menu of a row of the sidebar.
    static func sidebarMenu(_ sidebar: ProjectSidebarView, row: Int) -> NSMenu {
        let menu = NSMenu()
        sidebar.fill(menu, forRow: row)
        return menu
    }

    /// A key as AppKit hands one with ⌘ over: to the window's views (the one with the keyboard first), then to the menu
    /// bar. `code` is the key's on a US layout (C is 8, L 37, N 45, R 15), which the menus read it by.
    static func pressKey(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags, in window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        guard let event, !window.performKeyEquivalent(with: event) else { return }
        _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
    }
}
