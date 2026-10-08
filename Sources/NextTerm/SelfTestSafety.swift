import AppKit
import NextTermCore

/// The keys outside the menus as commands in Settings › Keyboard Shortcuts (the sidebar's, the Git lists', a proposed
/// edit's Accept, the branch popup's), an editor save that keeps a private file private (SafeWrite), and where
/// LangGraph Studio links open.
extension SelfTest {
    static func safetyChecks(_ c: TerminalWindowController, proj: URL) async {
        partKeyChecks(c, proj: proj)
        await privateSaveChecks(c, proj: proj)
        studioLinkChecks()
    }

    /// A key press as the keyboard makes it.
    private static func press(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }

    private static func partKeyChecks(_ c: TerminalWindowController, proj: URL) {
        let shortcuts = KeyboardShortcuts.shared
        let savedBindings = shortcuts.bindings
        defer {
            shortcuts.bindings = savedBindings
            shortcuts.apply()
        }
        shortcuts.resetAll()
        func listed(_ id: String) -> String {
            guard let command = shortcuts.commands.first(where: { $0.id == id }) else { return "missing" }
            return "\(command.title) · \(command.path) · \(shortcuts.chord(for: id)?.display ?? "none")"
        }
        let rows = ["sidebar.rename", "sidebar.trash", "sidebar.open", "gitLists.open", "diff.accept", "branchPopup.fetch"].map(listed)
        check(rows == ["Rename · Project Sidebar · ↩", "Move to Trash · Project Sidebar · ⌘⌫", "Open · Project Sidebar · ⌘↓",
                       "Open Commit or File · Git Log and Compare lists · ↩", "Accept · Proposed Edit · ⌘↩", "Fetch · Branch Popup · ⌘R"],
              "Settings lists the keys outside the menus, with the part of the window each belongs to", rows.joined(separator: " | "))

        // Key presses, read as Settings records them.
        let returnKey = press("\r", code: 36), enter = press("\u{3}", code: 76), commandReturn = press("\r", code: 36, .command)
        let commandDelete = press("\u{7F}", code: 51, .command), commandDown = press("\u{F701}", code: 125, [.command, .numericPad, .function])
        func command(_ event: NSEvent?, in part: KeyBindings.Part) -> String {
            event.flatMap { shortcuts.partCommand(for: $0, in: part) } ?? "none"
        }
        let read = [command(returnKey, in: .sidebar), command(enter, in: .sidebar), command(commandDelete, in: .sidebar),
                    command(commandDown, in: .sidebar), command(returnKey, in: .gitLists), command(commandReturn, in: .diff),
                    command(commandReturn, in: .branchPopup), command(press("r", code: 15, .command), in: .branchPopup),
                    command(returnKey, in: .branchPopup)]
        check(read == ["sidebar.rename", "sidebar.rename", "sidebar.trash", "sidebar.open", "gitLists.open", "diff.accept",
                       "branchPopup.newBranch", "branchPopup.fetch", "none"],
              "each part reads its own keys: ↩ and Enter rename in the sidebar, ↩ opens in the Git lists, ⌘↩ accepts", read.joined(separator: ", "))
        check(shortcuts.bindings.owners(of: KeyChord(key: "t", command: true), defaults: shortcuts.defaults, except: "sidebar.open") == ["newTab:"],
              "a key a menu command has is a clash for the sidebar's Open, so it can be moved deliberately")
        check(ShortcutRecorder(commandID: "branchPopup.copyName").toolTip == "⌘C is Copy Name while the branch popup is open, Copy everywhere else",
              "Settings says where ⌘C copies a branch's name", ShortcutRecorder(commandID: "branchPopup.copyName").toolTip ?? "no tooltip")

        // The project sidebar answers the key Settings gives Move to Trash, and no longer the old one.
        let outline = c.sidebar.outline
        let savedTrash = outline.onTrash
        var trashed = 0
        outline.onTrash = { trashed += 1 }
        if let commandDelete { outline.keyDown(with: commandDelete) }
        let byDefault = trashed
        let optionCommandDelete = press("\u{7F}", code: 51, [.command, .option])
        shortcuts.set(KeyChord(key: "\u{8}", command: true, option: true), for: "sidebar.trash")
        if let commandDelete { outline.keyDown(with: commandDelete) }
        if let optionCommandDelete { outline.keyDown(with: optionCommandDelete) }
        outline.onTrash = savedTrash
        check(byDefault == 1 && trashed == 2 && listed("sidebar.trash") == "Move to Trash · Project Sidebar · ⌥⌘⌫",
              "the sidebar's Move to Trash moves to the key set in Settings", "\(byDefault) then \(trashed)")
        shortcuts.reset("sidebar.trash")

        // A proposed edit's Accept answers the key set in Settings from anywhere in the window, one with ⇧ too (a button's
        // own key equivalent would want "Y"), and no longer the old one; its tooltip names the key. The sidebar's keys
        // can't be Accept's: with the sidebar on the right, the proposal comes first and would take them.
        let path = canonicalPath(proj.appendingPathComponent("accept-key.txt").path)
        var decisions: [Bool] = []
        let proposal = DiffPane.Proposal(original: "a\n", proposed: "b\n", author: "Self-test", tag: "accept-key", client: nil)
        let pane = c.editorArea.openProposal(for: path, proposal: proposal) { accepted, _ in decisions.append(accepted) }
        let tipBefore = pane.acceptToolTip ?? "none"
        shortcuts.set(KeyChord(key: "y", command: true, shift: true), for: "diff.accept")
        let tipAfter = pane.acceptToolTip ?? "none"
        let commandShiftY = press("Y", code: 16, [.command, .shift])
        let byOldKey = commandReturn.map { c.window?.performKeyEquivalent(with: $0) == true } ?? false
        let stillOpen = !pane.isDecided
        let byNewKey = commandShiftY.map { c.window?.performKeyEquivalent(with: $0) == true } ?? false
        check(tipBefore == "Accept (⌘↩): Self-test then writes the file" && tipAfter == "Accept (⇧⌘Y): Self-test then writes the file"
              && !byOldKey && stillOpen && byNewKey && decisions == [true],
              "Accept on a proposed edit answers the key set in Settings, ⇧⌘Y too, and its tooltip names it",
              "\(tipBefore) → \(tipAfter); old key \(byOldKey), new key \(byNewKey), decided \(decisions)")
        if !pane.isDecided { c.editorArea.close(pane) }
        shortcuts.reset("diff.accept")
        check(shortcuts.bindings.owners(of: KeyChord(key: "\r", command: true), defaults: shortcuts.defaults, except: "sidebar.open").contains("diff.accept"),
              "Accept's key is a clash for the sidebar's Open")
    }

    /// A save from the editor keeps an owner-only file owner-only and its extended attributes, and leaves no
    /// temporary file beside it.
    private static func privateSaveChecks(_ c: TerminalWindowController, proj: URL) async {
        let file = proj.appendingPathComponent("private-notes.txt")
        try? Data("token: made-up\n".utf8).write(to: file)
        chmod(file.path, 0o600)
        let tag = Array("kept".utf8)
        setxattr(file.path, "me.mishuk.nextterm.selftest", tag, tag.count, 0, 0)
        defer { try? FileManager.default.removeItem(at: file) }
        c.openFile(file)
        guard let editor = c.editorArea.activeEditor, editor.document.name == "private-notes.txt" else {
            return check(false, "safe save: the private file opens")
        }
        defer { c.editorArea.close(editor) }
        let length = (editor.textView.string as NSString).length
        editor.textView.insertText("more: 1\n", replacementRange: NSRange(location: length, length: 0))
        let saved = c.editorArea.save(editor.document)
        var info = stat()
        let mode = stat(file.path, &info) == 0 ? info.st_mode & 0o777 : 0
        var buffer = [UInt8](repeating: 0, count: 8)
        let size = getxattr(file.path, "me.mishuk.nextterm.selftest", &buffer, buffer.count, 0, 0)
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: proj.path)) ?? []).filter { $0.contains(".nextterm-") }
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check(saved && text == "token: made-up\nmore: 1\n" && mode == 0o600 && size == tag.count && leftovers.isEmpty,
              "a save keeps an owner-only file owner-only, with its extended attributes, and leaves nothing beside it",
              "saved \(saved), mode \(String(mode, radix: 8)), attribute \(size), left \(leftovers), \(text.debugDescription)")
    }

    /// Studio links leave Safari for a Chromium browser, only while the setting is on and Safari is the default; nothing opens.
    private static func studioLinkChecks() {
        guard let studio = URL(string: "https://smith.langchain.com/studio/?baseUrl=http://127.0.0.1:2024"),
              let docs = URL(string: "http://127.0.0.1:2024/docs") else { return }
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: WebLinks.studioKey)
        defer {
            if let saved { defaults.set(saved, forKey: WebLinks.studioKey) } else { defaults.removeObject(forKey: WebLinks.studioKey) }
        }
        defaults.removeObject(forKey: WebLinks.studioKey)
        let browser = NSWorkspace.shared.urlForApplication(toOpen: studio).flatMap { Bundle(url: $0)?.bundleIdentifier } ?? "none"
        let choice = WebLinks.choice(for: studio)
        let leavesSafari = StudioLink.webKitBrowsers.contains(browser)
        check(WebLinks.studioInChromium && (leavesSafari ? choice != .defaultBrowser : choice == .defaultBrowser)
              && WebLinks.choice(for: docs) == .defaultBrowser,
              "a Studio link leaves the default browser only when it is Safari (on by default)", "\(browser): \(choice)")
        // Settings › Terminal has the switch.
        let settings = TerminalSettingsView()
        let wasOn = settings.studioLinks.state == .on
        settings.studioLinks.performClick(nil)
        check(wasOn && !WebLinks.studioInChromium && WebLinks.choice(for: studio) == .defaultBrowser,
              "Settings › Terminal turns it off: Studio links then open in the default browser")
    }
}
