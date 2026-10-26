import AppKit
import NextTermCore

/// The keys of View › Unified Diffs, Annotate with Git Blame and Current Line Blame, and of Git › Fetch, Update Project,
/// Commit…, Push… and New Branch…: the menus as built have the keys the unit tests check for clashes (MenuKeys), each
/// item shows its key under every set of keys, Settings says where ⌘R is the branch popup's Fetch, and a key you gave
/// another command before it was one of these commands' default stays yours.
extension SelfTest {
    /// The commands, with their keys in Next Term's set.
    static let gitAndViewKeys: [(id: String, key: String)] = [
        ("gitFetch:", "⌘R"), ("gitUpdate:", "⌥⌘U"), ("gitCommit:", "⇧⌘C"), ("gitPush:", "⌥⌘P"), ("gitNewBranch:", "⇧⌘B"),
        ("toggleUnifiedDiffs:", "⌃⌘U"), ("toggleBlameAnnotations:", "⌃⇧⌘A"), ("toggleCurrentLineBlame:", "⌃⇧⌘L"),
        ("toggleWindowColumn:", "⌃⇧⌘S"), ("toggleWindowColumnExpanded:", "⌃⌘S"),
    ]

    static func gitAndViewKeyChecks(_ c: TerminalWindowController, proj: URL) async {
        let shortcuts = KeyboardShortcuts.shared
        let savedBindings = shortcuts.bindings, savedPreset = shortcuts.preset
        defer {
            shortcuts.bindings = savedBindings
            shortcuts.preset = savedPreset // applies both
        }
        shortcuts.preset = .nextTerm
        shortcuts.resetAll()
        func shown(_ id: String) -> String {
            shortcuts.commands.first { $0.id == id }?.item.flatMap(KeyboardShortcuts.chord(of:))?.display ?? "none"
        }

        // The menus as built are MenuKeys, which the unit tests check for clashes under every set.
        var built: [String: KeyChord] = [:]
        for command in shortcuts.commands where command.item != nil { built[command.id] = command.defaultChord }
        let drift = Set(built.keys).union(MenuKeys.defaults.keys).filter { built[$0] != MenuKeys.defaults[$0] }.sorted()
        check(drift.isEmpty, "menu keys: the menus as built have the keys MenuKeys lists for the unit tests",
              drift.map { "\($0) \(built[$0]?.display ?? "none"), listed \(MenuKeys.defaults[$0]?.display ?? "none")" }.joined(separator: "; "))
        check(shortcuts.aliases == MenuKeys.aliases, "menu keys: and so are the hidden items' keys",
              shortcuts.aliases.map { "\($0.key.display) \($0.value)" }.joined(separator: ", "))

        // Each item shows its key, in every set (JetBrains': Fetch ⌥⌘F, as ⌘R is Replace… there).
        let ids = gitAndViewKeys.map(\.id)
        check(ids.map(shown) == gitAndViewKeys.map(\.key), "view and git keys: each menu item shows its key", ids.map(shown).joined(separator: " "))
        for preset in KeymapPreset.allCases where preset != .nextTerm {
            shortcuts.preset = preset
            let expected = ids.map { shortcuts.baseChord(for: $0)?.display ?? "none" }
            let fetch = preset == .jetBrains ? "⌥⌘F" : "⌘R"
            check(ids.map(shown) == expected && shown("gitFetch:") == fetch && !expected.contains("none"),
                  "view and git keys: and under \(preset.name)'s keys", ids.map(shown).joined(separator: " "))
        }
        shortcuts.preset = .nextTerm

        // ⌘R is Fetch in the branch popup too, and Settings says which has it where.
        let fetchTip = ShortcutRecorder(commandID: "gitFetch:").toolTip
        check(fetchTip == "⌘R is Fetch while the branch popup is open and everywhere else", "Settings says ⌘R is the branch popup's Fetch too",
              fetchTip ?? "no tooltip")

        // A key you gave another command before it was Commit…'s default stays yours: Commit… has none until yours moves.
        let shiftCommandC = KeyChord(key: "c", command: true, shift: true)
        shortcuts.set(shiftCommandC, for: "toggleSoftWrap:")
        let taken = [shown("gitCommit:"), shown("toggleSoftWrap:"), shortcuts.chord(for: "gitCommit:")?.display ?? "none"]
            + shortcuts.bindings.owners(of: shiftCommandC, defaults: shortcuts.defaults, except: "goToLine:")
        check(taken == ["none", "⇧⌘C", "none", "toggleSoftWrap:"], "a key you gave a command before it was Commit…'s default stays yours",
              taken.joined(separator: " "))
        shortcuts.reset("toggleSoftWrap:")
        check(shown("gitCommit:") == "⇧⌘C" && shown("toggleSoftWrap:") == "⌥⌘W", "and Commit… has ⇧⌘C again once yours moves",
              "\(shown("gitCommit:")) \(shown("toggleSoftWrap:"))")

        guard let window = c.window else { return }
        guard await bringToFront(window) else {
            return note("view and git keys: not pressed, as real key events need the window in front, and \(notFrontmost(window))")
        }
        await viewKeyPresses(window)
        await gitKeyPresses(c, window: window, proj: proj)
    }

    /// Where a pressed key went, for a failed check's detail: the window with the keyboard, what in it has the keyboard,
    /// and whether the command's menu item is on, with its key.
    private static func keyRoute(_ id: String) -> String {
        let item = KeyboardShortcuts.shared.commands.first { $0.id == id }?.item
        item?.menu?.update()
        var window = "none"
        if let key = NSApp.keyWindow {
            window = "\(type(of: key)) “\(key.title)”"
            if let controller = key.windowController { window += " of \(type(of: controller))" }
            if !key.isVisible { window += " (hidden)" }
            if let parent = key.sheetParent { window += " over “\(parent.title)”" }
        }
        let responder = NSApp.keyWindow?.firstResponder.map { "\(type(of: $0))" } ?? "nothing"
        let shown = NSApp.windows.filter(\.isVisible).map { "“\($0.title)” \(type(of: $0))" }.joined(separator: ", ")
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
        return "key window \(window), keyboard in \(responder), \(item?.title ?? id) \(item?.isEnabled == true ? "on" : "off") on "
            + (item.flatMap(KeyboardShortcuts.chord(of:))?.display ?? "no key") + ", app active \(NSApp.isActive), in front \(front), shown: " + shown
    }

    /// A key down as the keyboard sends it: made from a CGEvent, so AppKit reads its characters off the keyboard layout as
    /// it does a real key's (an NSEvent given its characters can match an item's key with ⇧ for the same key without it: ⌘R
    /// then opens Replace in Files, ⇧⌘R). Like a real key, it goes to the window that has the keyboard (a sheet over `window`,
    /// while one is).
    static func pressKey(_ window: NSWindow, code: UInt16, _ flags: NSEvent.ModifierFlags) {
        let masks: [(NSEvent.ModifierFlags, CGEventFlags)] = [(.command, .maskCommand), (.shift, .maskShift), (.option, .maskAlternate),
                                                              (.control, .maskControl)]
        guard let key = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: true) else { return }
        key.flags = CGEventFlags(masks.filter { flags.contains($0.0) }.map(\.1))
        guard let event = NSEvent(cgEvent: key) else { return }
        NSApp.sendEvent(event)
    }

    /// ⌃⌘U, ⌃⇧⌘A, ⌃⇧⌘L and ⌥⌘W turn View › Unified Diffs, Annotate with Git Blame, Current Line Blame and Soft Wrap over,
    /// and back.
    private static func viewKeyPresses(_ window: NSWindow) async {
        let app = AppDelegate.shared!
        let layout = DiffLayout.current, annotations = app.blameAnnotations, lineBlame = app.currentLineBlame, wrap = app.softWrap
        func turned() -> [Bool] {
            [DiffLayout.current != layout, app.blameAnnotations != annotations, app.currentLineBlame != lineBlame, app.softWrap != wrap]
        }
        func pressAll() {
            pressKey(window, code: 32, [.command, .control])
            pressKey(window, code: 0, [.command, .shift, .control])
            pressKey(window, code: 37, [.command, .shift, .control])
            pressKey(window, code: 13, [.command, .option])
        }
        pressAll()
        let over = await wait(3) { turned() == [true, true, true, true] }
        check(over, "view keys: ⌃⌘U, ⌃⇧⌘A, ⌃⇧⌘L and ⌥⌘W turn Unified Diffs, Annotate with Git Blame, Current Line Blame and Soft Wrap over",
              "\(turned()); " + ["toggleUnifiedDiffs:", "toggleBlameAnnotations:", "toggleCurrentLineBlame:", "toggleSoftWrap:"].map(keyRoute)
                .joined(separator: "; "))
        pressAll()
        let back = await wait(3) { turned() == [false, false, false, false] }
        check(back, "view keys: and pressed again, each goes back", "\(turned())")
        if DiffLayout.current != layout { DiffLayout.current = layout }
        if app.blameAnnotations != annotations { app.toggleBlameAnnotations(nil) }
        if app.currentLineBlame != lineBlame { app.toggleCurrentLineBlame(nil) }
        if app.softWrap != wrap { app.toggleSoftWrap(nil) }
    }

    /// In the project's repository, given a remote of its own: ⌘R fetches, ⌥⌘U updates (up to date, so nothing changes),
    /// ⇧⌘C opens the commit sheet, ⌥⌘P asks before it pushes and ⇧⌘B asks for a name; each sheet is cancelled. While a
    /// sheet is up, the Git commands are off, so a key pressed again asks nothing more; pressed twice before the first
    /// question is up, ⌥⌘P and ⇧⌘B ask once.
    private static func gitKeyPresses(_ c: TerminalWindowController, window: NSWindow, proj: URL) async {
        guard let git = GitRunner.locateGit() else { return }
        @discardableResult func run(_ dir: String, _ args: String...) -> String { gitOutput(git, dir, args) }
        func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
        func fields(_ view: NSView) -> [NSTextField] { view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? fields($0) } }
        func sheetText() -> String { window.attachedSheet?.contentView.map(fields)?.map(\.stringValue).joined(separator: "\n") ?? "" }
        func press(_ title: String) async -> Bool {
            guard await wait(5, { window.attachedSheet?.contentView.map(buttons)?.contains { $0.title == title } == true }),
                  let button = window.attachedSheet?.contentView.map(buttons)?.first(where: { $0.title == title }) else { return false }
            button.performClick(nil)
            return true
        }
        let repo = proj.path
        let start = run(repo, "rev-parse", "--abbrev-ref", "HEAD")
        let bare = proj.deletingLastPathComponent().appendingPathComponent("keys-remote.git").path
        let file = proj.appendingPathComponent("keys.txt")
        try? FileManager.default.removeItem(atPath: bare)
        run(repo, "init", "-q", "--bare", bare)
        run(repo, "remote", "add", "keys", bare)
        run(repo, "push", "-q", "-u", "keys", start)
        defer {
            try? FileManager.default.removeItem(at: file)
            run(repo, "branch", "--unset-upstream")
            run(repo, "remote", "remove", "keys")
            try? FileManager.default.removeItem(atPath: bare)
            GitToast.dismiss()
            c.sidebar.git.refresh()
        }

        // ⌘R: Git › Fetch, of every remote: a branch only the remote has comes in.
        run(bare, "branch", "keys-fetch", start)
        GitToast.dismiss()
        let beforeFetch = keyRoute("gitFetch:")
        pressKey(window, code: 15, .command)
        let fetched = await wait(15) {
            GitToast.text?.hasPrefix("Fetched") == true && !run(repo, "rev-parse", "--verify", "-q", "refs/remotes/keys/keys-fetch").isEmpty
        }
        check(fetched, "git keys: ⌘R fetches, as Git › Fetch", (GitToast.text ?? "no notice") + "; before: " + beforeFetch + "; after: " + keyRoute("gitFetch:"))

        // ⌥⌘U: Update Project, already up to date. Pressed twice, quickly, it fetches once: the second press finds the first's
        // claim (TerminalWindowController.gitAsking), which no sheet would stop, as an update that is up to date asks nothing.
        GitToast.dismiss()
        let head = run(repo, "rev-parse", "HEAD")
        func logged(_ title: String, since: Date) -> Int { GitCommandLog.shared.entries.filter { $0.title == title && $0.start >= since }.count }
        let pressedU = Date()
        pressKey(window, code: 32, [.command, .option])
        let claimedU = c.gitAsking.contains(#selector(TerminalWindowController.gitUpdate(_:)))
        pressKey(window, code: 32, [.command, .option])
        let updated = await wait(15) { GitToast.text == "Already up to date" }
        check(updated && run(repo, "rev-parse", "HEAD") == head, "git keys: ⌥⌘U updates the project", (GitToast.text ?? "no notice") + "; " + keyRoute("gitUpdate:"))
        let fetchedTwice = await wait(2) { logged("Update Project", since: pressedU) > 1 }
        check(claimedU && !fetchedTwice && logged("Update Project", since: pressedU) == 1 && c.gitAsking.isEmpty,
              "git keys: ⌥⌘U pressed twice, quickly, fetches once, and the key works again after",
              "claimed \(claimedU), \(logged("Update Project", since: pressedU)) fetches, still claimed: \(c.gitAsking.count)")
        GitToast.dismiss()

        // ⇧⌘C: the commit sheet, listing what there is to commit. While it is up, ⌥⌘P asks nothing, then or after.
        try? "keys\n".write(to: file, atomically: true, encoding: .utf8)
        c.sidebar.git.refresh()
        _ = await wait(5) { c.sidebar.git.snapshot?.files["keys.txt"] != nil }
        pressKey(window, code: 8, [.command, .shift])
        let opened = await wait(10) { CommitSheet.current != nil }
        check(opened && CommitSheet.current?.fileListText.contains("keys.txt") == true, "git keys: ⇧⌘C opens the commit sheet",
              (CommitSheet.current?.fileListText ?? "no sheet") + "; " + keyRoute("gitCommit:"))
        if let sheet = CommitSheet.current {
            pressKey(window, code: 35, [.command, .option])
            await pause(0.5)
            sheet.pressCancel()
            let queued = await wait(3) { window.attachedSheet != nil }
            check(!queued && CommitSheet.current == nil, "git keys: under the commit sheet, ⌥⌘P asks nothing (Git's commands are off under a sheet)",
                  sheetText())
            if queued { _ = await press("Cancel") }
        }
        try? FileManager.default.removeItem(at: file)

        // ⌥⌘P: Push… asks first; Cancel sends nothing. Pressed twice before its question is up (both presses pass the
        // menu's check, as no sheet is up yet), it asks once.
        _ = await wait(5) { window.attachedSheet == nil }
        let pressedP = Date()
        pressKey(window, code: 35, [.command, .option])
        let claimedP = c.gitAsking.contains(#selector(TerminalWindowController.gitPush(_:)))
        pressKey(window, code: 35, [.command, .option])
        let asked = await wait(10) { sheetText().contains("Push “\(start)” to keys/\(start)?") }
        check(asked, "git keys: ⌥⌘P asks before it pushes", sheetText() + "; " + keyRoute("gitPush:"))
        let givenBack = c.gitAsking.isEmpty // its question is up: the sheet keeps the key off from here
        if asked { _ = await press("Cancel") }
        let askedTwice = await wait(2) { window.attachedSheet != nil }
        check(claimedP && givenBack && !askedTwice && logged("Outgoing commits", since: pressedP) == 1,
              "git keys: ⌥⌘P pressed twice, quickly, asks once, however quickly it is answered",
              "claimed \(claimedP), given back \(givenBack), \(logged("Outgoing commits", since: pressedP)) reads; " + sheetText())
        if askedTwice { _ = await press("Cancel") }

        // ⇧⌘B: New Branch… asks for the name, once for two quick presses; Cancel leaves the branch as it was.
        _ = await wait(5) { window.attachedSheet == nil }
        pressKey(window, code: 11, [.command, .shift])
        let claimedB = c.gitAsking.contains(#selector(TerminalWindowController.gitNewBranch(_:)))
        pressKey(window, code: 11, [.command, .shift])
        let named = await wait(10) { sheetText().contains("Next Term switches to it.") }
        check(claimedB && c.gitAsking.isEmpty, "git keys: ⇧⌘B holds its key from the press until its sheet is up",
              "claimed \(claimedB), still claimed: \(c.gitAsking.count)")
        check(named, "git keys: ⇧⌘B asks for the new branch's name", sheetText() + "; " + keyRoute("gitNewBranch:"))
        if named { _ = await press("Cancel") }
        let namedTwice = await wait(2) { window.attachedSheet != nil }
        check(!namedTwice, "git keys: ⇧⌘B pressed twice, quickly, asks once", sheetText())
        if namedTwice { _ = await press("Cancel") }
        _ = await wait(5) { window.attachedSheet == nil }
        check(run(repo, "rev-parse", "--abbrev-ref", "HEAD") == start, "git keys: and Cancel leaves the branch as it was")
    }
}
