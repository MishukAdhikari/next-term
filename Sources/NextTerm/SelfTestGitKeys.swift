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
        check(shown("gitCommit:") == "⇧⌘C" && shown("toggleSoftWrap:") == "none", "and Commit… has ⇧⌘C again once yours moves",
              "\(shown("gitCommit:")) \(shown("toggleSoftWrap:"))")

        guard let window = c.window else { return }
        guard await bringToFront(window) else {
            return note("view and git keys: not pressed, as real key events need the window in front, and \(notFrontmost(window))")
        }
        await viewKeyPresses(window)
        await gitKeyPresses(c, window: window, proj: proj)
    }

    /// A key down as the keyboard sends it, to the window that has the keyboard (a sheet over the window, while one is).
    private static func pressKey(_ window: NSWindow, _ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags) {
        pressAppKey(NSApp.keyWindow ?? window, characters, code: code, flags: flags)
    }

    /// ⌃⌘U, ⌃⇧⌘A and ⌃⇧⌘L turn View › Unified Diffs, Annotate with Git Blame and Current Line Blame over, and back.
    private static func viewKeyPresses(_ window: NSWindow) async {
        let app = AppDelegate.shared!
        let layout = DiffLayout.current, annotations = app.blameAnnotations, lineBlame = app.currentLineBlame
        func turned() -> [Bool] { [DiffLayout.current != layout, app.blameAnnotations != annotations, app.currentLineBlame != lineBlame] }
        func pressAll() {
            pressKey(window, "u", code: 32, [.command, .control])
            pressKey(window, "A", code: 0, [.command, .shift, .control])
            pressKey(window, "L", code: 37, [.command, .shift, .control])
        }
        pressAll()
        let over = await wait(3) { turned() == [true, true, true] }
        check(over, "view keys: ⌃⌘U, ⌃⇧⌘A and ⌃⇧⌘L turn Unified Diffs, Annotate with Git Blame and Current Line Blame over", "\(turned())")
        pressAll()
        let back = await wait(3) { turned() == [false, false, false] }
        check(back, "view keys: and pressed again, each goes back", "\(turned())")
        if DiffLayout.current != layout { DiffLayout.current = layout }
        if app.blameAnnotations != annotations { app.toggleBlameAnnotations(nil) }
        if app.currentLineBlame != lineBlame { app.toggleCurrentLineBlame(nil) }
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
        pressKey(window, "r", code: 15, .command)
        let fetched = await wait(15) {
            GitToast.text?.hasPrefix("Fetched") == true && !run(repo, "rev-parse", "--verify", "-q", "refs/remotes/keys/keys-fetch").isEmpty
        }
        check(fetched, "git keys: ⌘R fetches, as Git › Fetch", GitToast.text ?? "no notice")

        // ⌥⌘U: Update Project, already up to date.
        GitToast.dismiss()
        let head = run(repo, "rev-parse", "HEAD")
        pressKey(window, "u", code: 32, [.command, .option])
        let updated = await wait(15) { GitToast.text == "Already up to date" }
        check(updated && run(repo, "rev-parse", "HEAD") == head, "git keys: ⌥⌘U updates the project", GitToast.text ?? "no notice")
        GitToast.dismiss()

        // ⇧⌘C: the commit sheet, listing what there is to commit. While it is up, ⌥⌘P asks nothing, then or after.
        try? "keys\n".write(to: file, atomically: true, encoding: .utf8)
        c.sidebar.git.refresh()
        _ = await wait(5) { c.sidebar.git.snapshot?.files["keys.txt"] != nil }
        pressKey(window, "C", code: 8, [.command, .shift])
        let opened = await wait(10) { CommitSheet.current != nil }
        check(opened && CommitSheet.current?.fileListText.contains("keys.txt") == true, "git keys: ⇧⌘C opens the commit sheet",
              CommitSheet.current?.fileListText ?? "no sheet")
        if let sheet = CommitSheet.current {
            pressKey(window, "p", code: 35, [.command, .option])
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
        pressKey(window, "p", code: 35, [.command, .option])
        pressKey(window, "p", code: 35, [.command, .option])
        let asked = await wait(10) { sheetText().contains("Push “\(start)” to keys/\(start)?") }
        check(asked, "git keys: ⌥⌘P asks before it pushes", sheetText())
        if asked { _ = await press("Cancel") }
        let askedTwice = await wait(2) { window.attachedSheet != nil }
        check(!askedTwice, "git keys: ⌥⌘P pressed twice, quickly, asks once", sheetText())
        if askedTwice { _ = await press("Cancel") }

        // ⇧⌘B: New Branch… asks for the name, once for two quick presses; Cancel leaves the branch as it was.
        _ = await wait(5) { window.attachedSheet == nil }
        pressKey(window, "B", code: 11, [.command, .shift])
        pressKey(window, "B", code: 11, [.command, .shift])
        let named = await wait(10) { sheetText().contains("Next Term switches to it.") }
        check(named, "git keys: ⇧⌘B asks for the new branch's name", sheetText())
        if named { _ = await press("Cancel") }
        let namedTwice = await wait(2) { window.attachedSheet != nil }
        check(!namedTwice, "git keys: ⇧⌘B pressed twice, quickly, asks once", sheetText())
        if namedTwice { _ = await press("Cancel") }
        _ = await wait(5) { window.attachedSheet == nil }
        check(run(repo, "rev-parse", "--abbrev-ref", "HEAD") == start, "git keys: and Cancel leaves the branch as it was")
    }
}
