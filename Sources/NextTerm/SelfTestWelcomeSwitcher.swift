import AppKit
import Carbon.HIToolbox
import NextTermCore

/// The Welcome window as a project switcher, on screen, with keys made as the keyboard makes them (CGEvents): the three
/// ways in and the cards a first launch shows, Esc that never leaves Next Term with no window, the open projects marked
/// with a dot and counted, the order and the search, Return, ⌘↩, ⌘1–⌘9, ⌘⌫ and ⌘ held, where each show puts the keyboard,
/// where the window comes up, and the list following the windows an agent opens and closes.
///
/// The projects are folders made up for the run, in a folder of the temporary folder named with a word of the run's own
/// (`switcherToken`), which the search types to list them alone; the servers are made up too, at hosts that never
/// resolve. What the checks change in the user's defaults (Recent Projects, the saved servers, the server picked last,
/// “Open projects in”) is put back; the history itself is the self-test's own (ProjectHistoryRecorder). What needs the
/// keys skips with a note when Next Term can't come to the front, or the window can't be seen.
extension SelfTest {
    /// At launch, with only the Welcome window up (launchChecks): what a first launch shows, the server picked last, Esc,
    /// ⌘W and the keyboard at each show, then ⌘N for the window every later check uses. True when ⌘N opened it.
    static func welcomeLaunchSwitcherChecks(_ app: AppDelegate) async -> Bool {
        #if DEBUG
        return await welcomeSwitcherAtLaunch(app)
        #else
        note("Welcome switcher: its launch checks need a debug build")
        return false
        #endif
    }

    /// In the run, with other windows open (sessionChecks): the list, its marks and order, and its keys.
    static func welcomeSwitcherChecks() async {
        #if DEBUG
        await welcomeSwitcherInRun()
        #else
        note("Welcome switcher: its checks need a debug build (a server's Return uses the stand-in ssh)")
        #endif
    }
}

#if DEBUG
/// The keys the checks press, by their virtual key codes. Return, Esc, Delete, ↓ and ⌘ sit in one place on every
/// keyboard. The letters and figures are found on the keyboard layout in use, as ⌘ types them, since AppKit and the
/// menus read a chord's character off the layout: on Dvorak, the key in QWERTY's W place types ⌘, (Settings).
@MainActor
private enum SwitcherKeyCode {
    static let returnKey: UInt16 = 36
    static let escape: UInt16 = 53
    static let delete: UInt16 = 51
    static let down: UInt16 = 125
    static let command: UInt16 = 55
    /// The keys that type N, O and W with ⌘ held, in an ANSI layout's places when the layout has none.
    static var n: UInt16 { code(typing: "n") ?? 45 }
    static var o: UInt16 { code(typing: "o") ?? 31 }
    static var w: UInt16 { code(typing: "w") ?? 13 }
    /// The key of `index + 1`, for ⌘1 to ⌘9.
    static func digit(_ index: Int) -> UInt16 {
        let ansi: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        return code(typing: String(index + 1)) ?? ansi[index]
    }

    /// Every letter and figure the checks press is on the layout in use.
    static var layoutHasKeys: Bool {
        let typed: [String] = ["n", "o", "w"] + (1...9).map { (figure: Int) -> String in String(figure) }
        return typed.allSatisfy { (text: String) -> Bool in code(typing: text) != nil }
    }

    /// The lowest key code that types `text` with ⌘ held on the keyboard layout in use (the main keys come before the
    /// keypad's), as AppKit works a chord out (KeyboardShortcuts.chord(from:)); nil when no key does, or the layout has
    /// no key map (an input method's).
    private static func code(typing text: String) -> UInt16? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data: Data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let command: UInt32 = UInt32((cmdKey >> 8) & 0xFF)
        let keyboard: UInt32 = UInt32(LMGetKbdType())
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> UInt16? in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code in UInt16(0)..<128 {
                var dead: UInt32 = 0
                var length: Int = 0
                let room: Int = 4
                var characters: [UniChar] = [0, 0, 0, 0]
                let status: OSStatus = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), command, keyboard,
                                                      OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, room, &length,
                                                      &characters)
                guard status == noErr, length == 1 else { continue }
                if String(utf16CodeUnits: characters, count: length).lowercased() == text { return code }
            }
            return nil
        }
    }
}

/// The run's made-up projects, in one folder of the temporary folder, and the windows opened on them.
@MainActor
private final class SwitcherFixtures {
    let base: String
    /// The linked worktree “billing ▸ sso”, once made; nil without git.
    private(set) var worktree: String?

    init(token: String) {
        base = canonicalPath(NSTemporaryDirectory()) + "/" + token
    }

    /// `<base>/<name>`, made.
    func path(_ name: String) -> String {
        let path: String = base + "/" + name
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// A new window on `name`'s folder, a second one when a window has it already, as File › Open Project does.
    func open(_ name: String) async -> TerminalWindowController {
        let controller: TerminalWindowController = AppDelegate.shared.openFolder(path(name), newWindow: true)
        _ = await SelfTest.wait(5) { controller.window?.isVisible == true }
        return controller
    }

    /// The repository “billing” with a linked worktree “billing-wt-sso” on the branch sso, made with git off the main
    /// thread, so the windows keep drawing meanwhile; nil without git.
    func makeWorktree() async -> String? {
        if let worktree { return worktree }
        guard let git = GitRunner.locateGit() else { return nil }
        let repo: String = path("billing")
        let tree: String = base + "/billing-wt-sso"
        try? "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        let steps: [[String]] = [["init", "-q", "-b", "main"], ["add", "-A"], ["commit", "-q", "-m", "start"],
                                 ["worktree", "add", "-q", "-b", "sso", tree]]
        let made: Bool = await Task.detached { () -> Bool in
            for arguments in steps { SwitcherFixtures.git(git, in: repo, arguments) }
            return FileManager.default.fileExists(atPath: tree + "/.git")
        }.value
        guard made else { return nil }
        worktree = canonicalPath(tree)
        return worktree
    }

    /// git in `folder`, as the self-test's own committer (SelfTest.gitOutput), waited for.
    nonisolated private static func git(_ git: String, in folder: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        let committer: [String] = ["-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        process.arguments = ["-C", folder] + committer + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    /// Every window on a project in `base`, however it opened.
    var windows: [TerminalWindowController] {
        let prefix: String = base + "/"
        return AppDelegate.shared.controllers.filter { (controller: TerminalWindowController) -> Bool in
            guard let project = controller.project, !controller.hasClosed else { return false }
            return project.hasPrefix(prefix)
        }
    }

    /// The windows open on `path`.
    func windows(on path: String) -> [TerminalWindowController] {
        AppDelegate.shared.controllers.filter { (controller: TerminalWindowController) -> Bool in
            controller.project == path && !controller.hasClosed
        }
    }
}
#endif

#if DEBUG
// MARK: - keys and helpers

extension SelfTest {
    /// The run's own word, letters only so the keys can type it: the fixtures' folder is named with it, and no project or
    /// server of the user's has it, so a search for it lists the fixtures alone.
    fileprivate static let switcherToken: String = {
        let letters: [Character] = Array("abcdefghij")
        let digits: [Int] = String(getpid()).compactMap { (digit: Character) -> Int? in digit.wholeNumberValue }
        let word: [Character] = digits.map { (digit: Int) -> Character in letters[digit] }
        return "ntsw" + String(word)
    }()

    /// A key down as the keyboard sends it, made from a CGEvent so AppKit reads its characters off the keyboard layout as
    /// it does a real key's, through the app: the key window's key equivalents first (the Welcome window's own, then the
    /// menus'), then the window's first responder. It is pressed only while `window` is the key window, since AppKit
    /// gives it to whichever window is (⌘W meant for the Welcome window would close a tab elsewhere). False when it is

    /// not, with a failed check, or a note when Next Term is not the app in front; nothing is pressed then.
    @discardableResult
    fileprivate static func switcherKey(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], to window: NSWindow) -> Bool {
        guard window.isKeyWindow else {
            let key: String = NSApp.keyWindow.map { (other: NSWindow) -> String in "“\(other.title)”" } ?? "no window"
            let detail: String = "key code \(code) not pressed, the keyboard in " + key
            if NSApp.isActive {
                check(false, "Welcome: the window a key is meant for has the keyboard when it is pressed", detail)
            } else {
                note("Welcome switcher: a key skipped, as Next Term is not the app in front (" + detail + ")")
            }
            return false
        }
        let masks: [(NSEvent.ModifierFlags, CGEventFlags)] = [(.command, .maskCommand), (.shift, .maskShift),
                                                              (.option, .maskAlternate), (.control, .maskControl)]
        let source = CGEventSource(stateID: .hidSystemState)
        guard let key = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) else { return false }
        var held = CGEventFlags()
        for (flag, mask) in masks where flags.contains(flag) { held.insert(mask) }
        key.flags = held
        guard let event = NSEvent(cgEvent: key) else { return false }
        NSApp.sendEvent(event)
        return true
    }

    /// ⌘ pressed or let go, as the flagsChanged CGEvent the keyboard makes, queued for the app as the keyboard's events
    /// are, so the Welcome window's watch on the modifier keys sees it.
    fileprivate static func holdCommand(_ down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let key = CGEvent(keyboardEventSource: source, virtualKey: SwitcherKeyCode.command, keyDown: down) else { return }
        key.type = .flagsChanged
        key.flags = down ? .maskCommand : []
        guard let event = NSEvent(cgEvent: key) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// The keys pressed here have the menus' default chords: ⌘1–⌘9 (Select Tab 1–9), ⌘W (Close Tab), ⌘O, ⌥⌘T and ⌘N;
    /// and the keyboard layout in use has a key for each of their letters and figures.
    fileprivate static var switcherKeysAreDefault: Bool {
        guard SwitcherKeyCode.layoutHasKeys else { return false }
        let shortcuts = KeyboardShortcuts.shared
        let jumps: [KeyChord?] = SwitcherKeys.jumpCommands.map { (id: String) -> KeyChord? in shortcuts.chord(for: id) }
        let keys = SwitcherKeys(jumps: jumps, close: shortcuts.chord(for: SwitcherKeys.closeCommand))
        let waysIn = SwitcherWaysIn { (id: String) -> KeyChord? in shortcuts.chord(for: id) }
        return keys == .standard && waysIn == .standard
    }

    /// The keys the three ways in show, in their order, as the window works them out: the menus' now, less a key the
    /// window takes first. Nil for one with none.
    fileprivate static var wayInKeys: [String?] {
        let shortcuts = KeyboardShortcuts.shared
        let jumps: [KeyChord?] = SwitcherKeys.jumpCommands.map { (id: String) -> KeyChord? in shortcuts.chord(for: id) }
        let keys = SwitcherKeys(jumps: jumps, close: shortcuts.chord(for: SwitcherKeys.closeCommand))
        let menus = SwitcherWaysIn { (id: String) -> KeyChord? in shortcuts.chord(for: id) }
        let shown: SwitcherWaysIn = menus.notTaken(by: keys)
        return SwitcherWayIn.allCases.map { (way: SwitcherWayIn) -> String? in shown.key(for: way)?.display }
    }

    /// The hint line with nothing selected: each way in that has a key, with it, “⌘O open…”.
    fileprivate static var wayInHints: [String] {
        var parts: [String] = []
        for (way, key) in zip(SwitcherWayIn.allCases, wayInKeys) {
            if let key { parts.append(key + " " + way.hintLabel) }
        }
        return parts
    }

    /// The keyboard is in the projects search: its field editor is the window's first responder.
    fileprivate static func searchHasKeyboard(_ welcome: WelcomeWindowController) -> Bool {
        guard let window = welcome.window, let editor = welcome.projectsSearchField.currentEditor() else { return false }
        return window.firstResponder === editor
    }

    /// The search's text is all selected, so the next key typed replaces it.
    fileprivate static func searchAllSelected(_ welcome: WelcomeWindowController) -> Bool {
        guard let editor = welcome.projectsSearchField.currentEditor() else { return false }
        let length: Int = (editor.string as NSString).length
        return editor.selectedRange == NSRange(location: 0, length: length)
    }

    /// Saves what the checks change in the user's defaults: Recent Projects, the saved servers and the one connected to
    /// last, the server picked last in the Welcome window, and “Open projects in”. Call what it returns to put them back.
    fileprivate static func keepSwitcherDefaults() -> () -> Void {
        let defaults = UserDefaults.standard
        let recents: [String] = defaults.stringArray(forKey: "recentProjects") ?? []
        let hosts: [RemoteHost] = RemoteHosts.all
        let keys: [String] = ["lastRemoteHost", SwitcherSelection.lastPickKey, "openProjectsIn"]
        let values: [Any?] = keys.map { (key: String) -> Any? in defaults.object(forKey: key) }
        return {
            AppDelegate.shared.setRecentProjects(recents)
            RemoteHosts.all = hosts
            for (key, value) in zip(keys, values) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
    }

    /// Closes `controller`'s window and waits until Next Term has let it go (AppDelegate drops it a moment later).
    fileprivate static func closeSwitcherWindow(_ controller: TerminalWindowController) async {
        if !controller.hasClosed { controller.window?.close() }
        _ = await wait(5) {
            !AppDelegate.shared.controllers.contains { (other: TerminalWindowController) -> Bool in other === controller }
        }
    }

    /// The last part of each path, for a failed check's detail.
    fileprivate static func names(_ paths: [String]) -> String {
        paths.map { (path: String) -> String in (path as NSString).lastPathComponent }.joined(separator: ", ")
    }

    /// Whether `text` has the word “open” in it, by itself: a row says open with its dot only.
    fileprivate static func saysOpen(_ text: String) -> Bool {
        let words: [Substring] = text.lowercased().split { (character: Character) -> Bool in !character.isLetter }
        return words.contains("open")
    }
}
#endif

#if DEBUG
// MARK: - at launch

extension SelfTest {
    fileprivate static func welcomeSwitcherAtLaunch(_ app: AppDelegate) async -> Bool {
        guard let welcome = app.welcomeController, let window = welcome.window, window.isVisible, app.controllers.isEmpty else {
            note("Welcome switcher: the launch checks skipped, as the Welcome window is not up alone")
            return false
        }
        firstLaunchChecks()
        atLaunchFooterChecks()
        check(searchHasKeyboard(welcome), "Welcome: at launch the keyboard is in its search, “Search projects and servers”",
              String(describing: window.firstResponder))
        let parts: [String] = welcome.hintParts
        check(!parts.contains("esc close"), "Welcome: with no other window open, its hint line offers no “esc close”",
              parts.joined(separator: " | "))
        let restore = keepSwitcherDefaults()
        lastPickChecks(app, welcome)
        restore()
        return await launchKeyChecks(app, welcome, window)
    }

    /// A first launch, on a second Welcome window never shown that lists nothing: the three ways in as rows at the foot of
    /// the list, in their order, with the keys the menus give them and their tooltips, and as three cards of one width with
    /// their sentences; the list's one line; no button with Return. A search hides the cards and says nothing matches,
    /// and the hint line names the three ways in with their keys.
    private static func firstLaunchChecks() {
        let fresh = WelcomeWindowController()
        defer { fresh.close() }
        fresh.list(projects: [])
        fresh.window?.contentView?.layoutSubtreeIfNeeded()
        let keys: [String?] = wayInKeys
        let ways: [SwitcherWayIn] = SwitcherWayIn.allCases
        let titles: [String] = ways.map(\.title)
        let rows: [WayInRow] = fresh.wayInRows
        let rowTitles: [String] = rows.map(\.title)
        let rowKeys: [String?] = rows.map(\.shownKey)
        check(rowTitles == titles && rowKeys == keys,
              "Welcome, first launch: Open…, Connect to Server… and New Terminal, three rows with the menus' keys at the right",
              "\(rowTitles), keys \(rowKeys)")
        var tips: [String] = []
        for (way, key) in zip(ways, keys) { tips.append(key.map { (key: String) -> String in "\(way.help) (\(key))" } ?? way.help) }
        let rowTips: [String] = rows.map { (row: WayInRow) -> String in row.toolTip ?? "" }
        check(rowTips == tips, "Welcome: each way in's tooltip says what it opens and its key, New Terminal's too",
              rowTips.joined(separator: " | "))
        let returnKeys: [String] = returnKeyButtons(fresh.window)
        let waysReturn: Bool = rows.contains { (row: WayInRow) -> Bool in row.keyEquivalent == "\r" }
        check(returnKeys.isEmpty && !waysReturn,
              "Welcome, first launch: no button is Return's, and none of the three ways in is the default",
              "Return on \(returnKeys)")

        let cards: [WayInCard] = fresh.wayInCards
        var said: [[String]] = []
        for (way, key) in zip(ways, keys) { said.append([way.title, way.sentence, key ?? ""]) }
        let shown: [[String]] = cards.map(\.shownText)
        check(fresh.cardsShown && shown == said,
              "Welcome, first launch: the right pane shows the three as cards, each with its sentence and key",
              "shown \(fresh.cardsShown), \(shown)")
        let frames: [NSRect] = cards.map { (card: WayInCard) -> NSRect in card.convert(card.bounds, to: nil) }
        let widths: [CGFloat] = frames.map(\.width)
        let equal: Bool = widths.allSatisfy { (width: CGFloat) -> Bool in abs(width - (widths.first ?? 0)) < 0.5 }
        var ordered: Bool = frames.allSatisfy { (frame: NSRect) -> Bool in frame.width > 0 }
        for index in frames.indices.dropFirst() where frames[index].minX <= frames[index - 1].maxX { ordered = false }
        check(equal && ordered, "Welcome: the three cards are one width, side by side in the rows' order",
              frames.map { (frame: NSRect) -> String in NSStringFromRect(frame) }.joined(separator: " "))
        check(fresh.emptyListText == SwitcherText.emptyList, "Welcome, first launch: the list says “Projects you open are listed here.”",
              fresh.emptyListText ?? "no line")
        let hints: [String] = Array(fresh.hintParts.prefix(3))
        check(hints == wayInHints, "Welcome, first launch: with nothing to select, the hint line names the three ways in and their keys",
              fresh.hintParts.joined(separator: " | "))

        let typed = "zzq" + switcherToken
        fresh.searchProjects(typed)
        let none: String = "No project or server matches “" + typed + "”."
        let stillNone: Bool = returnKeyButtons(fresh.window).isEmpty
        check(fresh.noMatchText == none && !fresh.cardsShown && fresh.emptyListText == nil && stillNone,
              "Welcome: a search that finds nothing hides the cards, says “No project or server matches …”, and Return does nothing",
              "\(fresh.noMatchText ?? "no line"), cards \(fresh.cardsShown)")
        let unmatched: [String] = Array(fresh.hintParts.prefix(3))
        check(unmatched == wayInHints, "Welcome: and the hint line names the three ways in with their keys",
              fresh.hintParts.joined(separator: " | "))
        fresh.searchProjects("")
        check(fresh.cardsShown, "Welcome: emptied, the search brings the cards back")
    }
}
#endif

#if DEBUG
extension SelfTest {
    /// The server picked last in the window, still saved: a show from no project window starts on it, its pane says where
    /// it points, where its tabs open and how it is kept, and Connect is Return's. Typed, the search finds another server
    /// and selects it. The servers are made up and put back by the caller.
    private static func lastPickChecks(_ app: AppDelegate, _ welcome: WelcomeWindowController) {
        let staging = RemoteHost(name: switcherToken + "staging", destination: "deploy@staging.example.invalid",
                                 directory: "~/srv/shop", keep: .tmux)
        let prod = RemoteHost(name: switcherToken + "prod", destination: "deploy@prod.example.invalid", keep: .off)
        RemoteHosts.save(staging)
        RemoteHosts.save(prod)
        UserDefaults.standard.set(staging.id, forKey: SwitcherSelection.lastPickKey)
        app.showWelcome(nil)
        let picked: Bool = welcome.selectedEntry?.server?.id == staging.id
        let lines: [String] = welcome.serverPaneLines
        let place: String = lines.count > 1 ? lines[1] : ""
        let said: Bool = lines.first == staging.name && place.hasPrefix(staging.destination) && place.hasSuffix(staging.directory)
        let kept: Bool = lines.last == WelcomeServerPane.keptText(.tmux)
        check(picked && welcome.serverPaneShown && said && kept,
              "Welcome: shown from no project window, it starts on the server picked last, its pane saying where it points, its folder and “kept with tmux”",
              "selected \(String(describing: welcome.selectedEntry?.id)), pane \(welcome.serverPaneShown): " + lines.joined(separator: " | "))
        let returnKeys: [String] = returnKeyButtons(welcome.window)
        check(welcome.returnButtonTitle == "Connect" && returnKeys == ["Connect"], "Welcome: and Connect is Return's",
              "Return on \(returnKeys)")
        welcome.searchProjects(switcherToken + "pro")
        let found: Bool = welcome.shownServers == [prod.name] && welcome.shownProjects.isEmpty
        check(found && welcome.selectedEntry?.server?.id == prod.id, "Welcome: typed, the search finds the other server, selected",
              welcome.shownServers.joined(separator: ", "))
        welcome.searchProjects("")
    }

    /// At launch with no other window: Esc never closes the Welcome window, ⌘W does; each show (Window › Welcome to Next
    /// Term, a Dock click on it minimized) puts the keyboard in its search, emptied after a close and kept, selected, while
    /// minimized. Then ⌘N, typed in the search, opens a shell window and closes the Welcome window, and that window's
    /// close brings it back (lastWindowChecks). True when a window is open for the checks after these.
    private static func launchKeyChecks(_ app: AppDelegate, _ welcome: WelcomeWindowController, _ window: NSWindow) async -> Bool {
        guard switcherKeysAreDefault else {
            note("Welcome switcher: the launch's keys not pressed, as the menus' keys were changed or the keyboard layout lacks one")
            return false
        }
        guard await bringToFront(window), window.canBeSeen else {
            note("Welcome switcher: the launch's keys skipped, as " + notFrontmost(window))
            return false
        }
        let search: NSSearchField = welcome.projectsSearchField
        guard switcherKey(SwitcherKeyCode.escape, to: window) else { return false }
        await pause(0.3)
        check(window.isVisible, "Welcome: Esc on its empty search, with no other window open, leaves it up")
        typeKeys(window, "zz")
        let typed: Bool = await wait(2) { search.stringValue == "zz" }
        switcherKey(SwitcherKeyCode.escape, to: window)
        let emptied: Bool = await wait(2) { search.stringValue.isEmpty }
        switcherKey(SwitcherKeyCode.escape, to: window)
        await pause(0.3)
        check(typed && emptied && window.isVisible && searchHasKeyboard(welcome),
              "Welcome: Esc empties a typed search, and Esc again, with no other window, leaves it up, the keyboard in the search",
              "typed \(typed), emptied \(emptied), up \(window.isVisible)")

        // ⌘W closes it all the same; what was typed is gone at the next show.
        typeKeys(window, "zz")
        _ = await wait(2) { search.stringValue == "zz" }
        guard switcherKey(SwitcherKeyCode.w, .command, to: window) else { return false }
        let closed: Bool = await wait(2) { !window.isVisible }
        check(closed, "Welcome: ⌘W closes it, though it is the only window")
        app.showWelcome(nil)
        let back: Bool = await wait(2) { window.isVisible && searchHasKeyboard(welcome) }
        check(back && search.stringValue.isEmpty,
              "Welcome: Window › Welcome to Next Term shows it again, its search emptied, with the keyboard",
              "up \(window.isVisible), “\(search.stringValue)”, keyboard in \(String(describing: window.firstResponder))")

        // Minimized with text typed, then a Dock click: the text kept and selected, and the keyboard in the search again.
        typeKeys(window, "zz")
        _ = await wait(2) { search.stringValue == "zz" }
        window.miniaturize(nil)
        if await wait(8, { window.isMiniaturized }) {
            let handled: Bool = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            let restored: Bool = await wait(5) { !window.isMiniaturized && window.isVisible }
            let focused: Bool = await wait(2) { searchHasKeyboard(welcome) && searchAllSelected(welcome) }
            check(restored && !handled && focused && search.stringValue == "zz",
                  "Welcome: minimized, a Dock click brings it back with what was typed, selected, the keyboard in the search",
                  "back \(restored), keyboard and all selected \(focused), “\(search.stringValue)”")
        } else {
            note("Welcome: it did not minimize, so a Dock click bringing it back was not checked")
        }
        welcome.searchProjects("")

        guard await bringToFront(window) else {
            note("Welcome switcher: ⌘N not pressed, as " + notFrontmost(window))
            return false
        }
        guard switcherKey(SwitcherKeyCode.n, .command, to: window) else { return false }
        let opened: Bool = await wait(5) { !app.controllers.isEmpty }
        check(opened && app.controllers.count == 1, "Welcome: ⌘N, typed with the keyboard in its search, opens a shell window",
              "\(app.controllers.count) windows")
        guard opened else { return false }
        return await lastWindowChecks(app, welcome, window)
    }
}
#endif

#if DEBUG
extension SelfTest {
    /// The last window closing with its last tab, as at the end of a day's work: the Welcome window shows on that
    /// window's display, the keyboard in its search with its text selected. Then ⌘N again opens the window the later
    /// checks use. True when a window is open for them.
    private static func lastWindowChecks(_ app: AppDelegate, _ welcome: WelcomeWindowController, _ window: NSWindow) async -> Bool {
        guard app.controllers.count == 1, let shell = app.controllers.first, let tab = shell.tabs.first,
              let shellWindow = shell.window else { return !app.controllers.isEmpty }
        let frame: CGRect = shellWindow.frame
        shell.remove(tab)
        let shown: Bool = await wait(5) { app.controllers.isEmpty && window.isVisible }
        let focused: Bool = await wait(2) { searchHasKeyboard(welcome) && searchAllSelected(welcome) }
        let screens: [CGRect] = NSScreen.screens.map { (screen: NSScreen) -> CGRect in screen.frame }
        let expected: Int? = SwitcherPlacement.screen(of: frame, among: screens)
        let placed: Int? = SwitcherPlacement.screen(of: window.frame, among: screens)
        let display: String = "display \(placed.map(String.init) ?? "none"), the window's \(expected.map(String.init) ?? "none")"
        check(shown && focused && placed == expected,
              "Welcome: the last window closed with its last tab, it shows on that window's display, the keyboard in its search, its text selected",
              "up \(window.isVisible), windows \(app.controllers.count), keyboard \(focused), " + display)
        guard shown else { return !app.controllers.isEmpty }
        guard await bringToFront(window) else {
            note("Welcome switcher: ⌘N not pressed again, as " + notFrontmost(window))
            return false
        }
        guard switcherKey(SwitcherKeyCode.n, .command, to: window) else { return false }
        let again: Bool = await wait(5) { !app.controllers.isEmpty }
        check(again && app.controllers.count == 1, "Welcome: and ⌘N there opens a shell window again", "\(app.controllers.count) windows")
        return again
    }

    /// The footer's “At launch:” pop-up, on a second Welcome window never shown, as a first launch lays it out: in the
    /// window, with the three choices titled as Settings › General titles its radio buttons, the third one too, and the
    /// one saved selected. “Open a new terminal” picked there is saved, and an open General tab and a new one show it
    /// selected; picked back in Settings › General, the footer follows. What was saved is put back.
    private static func atLaunchFooterChecks() {
        let defaults: UserDefaults = AppDelegate.shared.launchDefaults
        let restore = defaultLaunchSettings(defaults)
        defer {
            restore()
            NotificationCenter.default.post(name: LaunchSettings.changed, object: nil)
        }
        let fresh = WelcomeWindowController()
        defer { fresh.close() }
        fresh.list(projects: [])
        fresh.window?.contentView?.layoutSubtreeIfNeeded()
        let footer: AtLaunchFooter = fresh.atLaunchFooter
        let titles: [String] = footer.popUp.itemTitles
        let expected: [String] = ["Show the Welcome window", "Resume where I left off", "Open a new terminal"]
        let content: CGRect = fresh.window?.contentView?.bounds ?? .zero
        let placed: CGRect = footer.convert(footer.bounds, to: nil)
        let shown: Bool = !footer.isHiddenOrHasHiddenAncestor && placed.width > 0 && content.contains(placed)
        let general = GeneralSettingsView(frame: .zero)
        check(titles == expected && general.opens.map(\.title) == expected && footer.choice == .welcome && shown,
              "Welcome: its footer's At launch offers Settings › General's three choices, “Open a new terminal” too, “Show the Welcome window” until changed",
              "\(titles), selected \(footer.popUp.titleOfSelectedItem ?? "none"), shown \(shown) at \(NSStringFromRect(placed))")

        footer.choose(.newTerminal)
        let saved: LaunchOpens = LaunchSettings(defaults: defaults).opens
        let openTab: Bool = general.radio(.newTerminal).state == .on && general.radio(.welcome).state == .off
        let newTab: Bool = GeneralSettingsView(frame: .zero).radio(.newTerminal).state == .on
        check(saved == .newTerminal && openTab && newTab,
              "Welcome: “Open a new terminal” picked in its footer is saved, and Settings › General shows it selected, open or opened after",
              "saved \(saved.title), open tab \(openTab), new tab \(newTab)")
        general.radio(.welcome).performClick(nil)
        check(footer.choice == .welcome, "Welcome: picked back in Settings › General, the footer's At launch follows",
              footer.popUp.titleOfSelectedItem ?? "none")
    }
}
#endif

#if DEBUG
// MARK: - in the run

extension SelfTest {
    fileprivate static func welcomeSwitcherInRun() async {
        let app = AppDelegate.shared!
        let restore = keepSwitcherDefaults()
        let historyBefore: NSArray? = UserDefaults.standard.array(forKey: ProjectHistory.key) as NSArray?
        // A project opened from the list opens in a new window, never behind the question “Open in this window?”.
        app.projectTarget = .newWindow
        app.welcomeController?.close()
        let fixtures = SwitcherFixtures(token: switcherToken)
        await orderChecks(app, fixtures)
        await restoreOpenChecks(app, fixtures)
        searchScopeChecks()
        await markerChecks(app, fixtures)
        await switcherKeyChecks(app, fixtures)

        app.welcomeController?.close()
        for controller in fixtures.windows { await closeSwitcherWindow(controller) }
        restore()
        try? FileManager.default.removeItem(atPath: fixtures.base)
        let historyAfter: NSArray? = UserDefaults.standard.array(forKey: ProjectHistory.key) as NSArray?
        check(historyAfter == historyBefore,
              "Welcome: the projects a self-test opens and closes are kept in its own history, never in yours",
              "\(historyBefore?.count ?? 0) entries before, \(historyAfter?.count ?? 0) after")
    }

    /// Projects closed one after another are listed newest first, with no dot, and found by their folder; a search starts
    /// on the best match, with Open Project as Return's and the hint line saying so.
    private static func orderChecks(_ app: AppDelegate, _ fixtures: SwitcherFixtures) async {
        for name in ["docs", "shop", "api"] {
            let controller: TerminalWindowController = await fixtures.open(name)
            await pause(0.3) // a time of its own
            await closeSwitcherWindow(controller)
        }
        app.showWelcome(nil)
        guard let welcome = app.welcomeController else { return check(false, "Welcome: the Welcome window shows") }
        welcome.searchProjects(switcherToken)
        let expected: [String] = ["api", "shop", "docs"].map(fixtures.path)
        let order: [String] = welcome.shownProjects
        check(order == expected, "Welcome: projects closed one after another are listed newest first, found by their folder",
              names(order))
        var dots: [String] = []
        for (index, path) in order.enumerated() where welcome.switcherList.projectCell(at: index)?.showsOpenDot == true {
            dots.append(path)
        }
        check(dots.isEmpty, "Welcome: a closed project's row has no dot", names(dots))
        let enter: String = KeyChord(key: "\r").display
        let hint: [String] = [enter + " open", SwitcherKeys.newWindow.display + " new window"]
        let first: Bool = welcome.selectedProject == expected.first && welcome.returnButtonTitle == "Open Project"
        check(first && welcome.hintParts == hint,
              "Welcome: typed, the search selects its best match, Open Project is Return's, and the hint line says “↩ open” and “⌘↩ new window”",
              "\(welcome.selectedProject.map { ($0 as NSString).lastPathComponent } ?? "none"), "
                  + "\(welcome.returnButtonTitle ?? "no button"), " + welcome.hintParts.joined(separator: " | "))
        welcome.searchProjects("")
        welcome.close()
    }

    /// The search's ranking and reach, on a second Welcome window never shown, over made-up projects in the home folder:
    /// the start of a name first, then the start of a word in it, then anywhere in it, then the folder; and the home
    /// folder's own name finds only a project whose name has it, never every project in the home folder. The home is the
    /// real one, as the window reads it (the search's own tests use a made-up one); a failed check's detail names no
    /// folder there, so the account's name stays out of the report.
    private static func searchScopeChecks() {
        let home: String = NSHomeDirectory()
        let shop: String = home + "/Code/shop"
        let shell: String = home + "/Code/bash-shell"
        let fresh: String = home + "/Code/fresh"
        let notes: String = home + "/Work/shelf/notes"
        let controller = WelcomeWindowController()
        defer { controller.close() }
        controller.list(projects: [notes, fresh, shell, shop])
        controller.searchProjects("sh")
        let ranked: [String] = controller.shownProjects
        check(ranked == [shop, shell, fresh, notes],
              "Welcome: “sh” lists shop (the name's start), bash-shell (a word's start), fresh (in the name), then shelf/notes (its folder)",
              names(ranked))
        let user: String = (home as NSString).lastPathComponent
        let named: String = home + "/Work/" + user + "-samples"
        guard !SearchWords.fold("~/Code/shop").contains(SearchWords.fold(user)), !user.contains(" ") else {
            return note("Welcome: the home folder's name is in a made-up project's folder, so its search was not checked")
        }
        controller.list(projects: [shop, named])
        controller.searchProjects(user)
        let listed: [String] = controller.shownProjects
        let detail: String = "\(listed.count) listed, the one named with it " + (listed.contains(named) ? "among them" : "not")
        check(listed == [named],
              "Welcome: the home folder's own name finds only a project named with it, never every project in the home folder",
              detail)
    }

    /// A restore's window (after an update, a quit or a crash) counts as an open, as the launch builds it: its project is
    /// recorded open in one window while it is up, and stays in the history once it closes. The snapshot is made up, and
    /// planned with nothing read of the user's (no session, no host).
    private static func restoreOpenChecks(_ app: AppDelegate, _ fixtures: SwitcherFixtures) async {
        let kept: String = fixtures.path("kept")
        let pane = SessionSnapshot.Pane(id: UUID(), folder: kept)
        let group = SessionSnapshot.Group(root: .pane(pane), focused: pane.id)
        let header = SessionSnapshot.Header(launchID: UUID(), generation: 1, clean: true, savedAt: Date())
        let snapshot = SessionSnapshot(header: header, windows: [SessionSnapshot.Window(project: kept, groups: [group])])
        let nothing = SessionLookup(read: { (_: AgentKind, _: String, _: Date) -> [AgentSession] in [] },
                                    newest: { (_: AgentKind, _: String, _: Date, _: Set<String>) -> AgentSession? in nil })
        let world = RestorePlanner.World(home: fixtures.base, checkFolder: { (_: String) -> FolderCheck in .found },
                                         resumeFacts: { (_: SessionSnapshot.Evidence, _: String?, _: [String]) -> ResumeFacts in
                                             ResumeFacts()
                                         }, sessions: nothing)
        let plans: [PanePlan] = RestorePlanner.plan(snapshot, kind: .quit, quitConsent: true, world: world)
        let planned = RestorePlanning.Planned(plans: plans, folders: [:])
        let built: RestoreBuild.Built = RestoreBuild.build(snapshot, planned: planned, scrollback: [:], savedAt: nil)
        guard let restored = built.windows.first else { return check(false, "Welcome: a restore builds the made-up project's window") }
        let recorder = ProjectHistoryRecorder.shared
        let open: Bool = await wait(3) { recorder.windowCounts[kept] == 1 && recorder.history.lastUsed(kept) != nil }
        check(open, "Welcome: a project a restore brings back is recorded as open, as every other open is",
              "windows \(recorder.windowCounts[kept] ?? 0), in the history \(recorder.history.lastUsed(kept) != nil)")
        for controller in built.windows { await closeSwitcherWindow(controller) }
        let closed: Bool = await wait(3) { recorder.windowCounts[kept] == nil && recorder.history.lastUsed(kept) != nil }
        check(closed && restored.hasClosed, "Welcome: and once its window closes, it is kept among the closed projects",
              "windows \(recorder.windowCounts[kept] ?? 0), in the history \(recorder.history.lastUsed(kept) != nil)")
    }
}
#endif

#if DEBUG
extension SelfTest {
    /// The open marker, with shop in two windows, wiki in one and the linked worktree billing ▸ sso in its own: a dot on
    /// each open row and none on a closed one, no row saying “open” in words, “2 windows” after shop's folder, the heading
    /// counting the open projects, the worktree's title as its window has it, VoiceOver's words, and the two lines' spacing.
    private static func markerChecks(_ app: AppDelegate, _ fixtures: SwitcherFixtures) async {
        let shop: String = fixtures.path("shop")
        let wiki: String = fixtures.path("wiki")
        _ = await fixtures.open("shop")
        _ = await fixtures.open("shop")
        // A project the user opens while the Welcome window is up closes it: the next show lists the project.
        app.showWelcome(nil)
        let welcomeWindow: NSWindow? = app.welcomeController?.window
        let up: Bool = await wait(2) { welcomeWindow?.isVisible == true }
        _ = await fixtures.open("wiki")
        let gone: Bool = await wait(2) { welcomeWindow?.isVisible != true }
        check(up && gone, "Welcome: a project the user opens, as File › Open Project does, closes the Welcome window",
              "up before \(up), up after \(welcomeWindow?.isVisible == true)")
        var open: Set<String> = [shop, wiki]
        let tree: String? = await fixtures.makeWorktree()
        if let tree {
            let controller: TerminalWindowController = app.openWorktreeWindow(tree)
            _ = await wait(5) { controller.window?.isVisible == true }
            open.insert(tree)
        } else {
            note("Welcome: no git, so a linked worktree's row was not checked")
        }
        app.showWelcome(nil)
        guard let welcome = app.welcomeController else { return check(false, "Welcome: the Welcome window shows") }
        welcome.searchProjects(switcherToken)
        let list: WelcomeSwitcherList = welcome.switcherList
        func dotted() -> Set<String> {
            var paths: Set<String> = []
            for (index, project) in list.shown.projects.enumerated() where list.projectCell(at: index)?.showsOpenDot == true {
                paths.insert(project.path)
            }
            return paths
        }
        let marked: Bool = await wait(3) { dotted() == open }
        check(marked, "Welcome: each open project's row has a dot, and a closed one's none", names(dotted().sorted()))
        var said: [String] = []
        for index in list.shown.projects.indices {
            guard let cell = list.projectCell(at: index) else { continue }
            let text: String = cell.shownName + " " + cell.shownFolder
            if saysOpen(text) { said.append(text) }
        }
        check(said.isEmpty, "Welcome: no row says “open” in words: the dot says it", said.joined(separator: " | "))

        let projects: [String] = app.controllers.filter { !$0.hasClosed }.compactMap(\.project)
        let count: String = "\(Set(projects).count) open"
        let counted: Bool = await wait(3) { list.headingCount == count }
        check(counted, "Welcome: the PROJECTS heading counts the open projects, “\(count)”", list.headingCount ?? "no count")

        let shopIndex: Int? = list.shown.projects.firstIndex { (project: SwitcherProject) -> Bool in project.path == shop }
        let shopCell: SwitcherProjectCell? = shopIndex.flatMap { (index: Int) -> SwitcherProjectCell? in list.projectCell(at: index) }
        let wikiIndex: Int? = list.shown.projects.firstIndex { (project: SwitcherProject) -> Bool in project.path == wiki }
        let wikiCell: SwitcherProjectCell? = wikiIndex.flatMap { (index: Int) -> SwitcherProjectCell? in list.projectCell(at: index) }
        let twice: Bool = shopCell?.shownFolder.hasSuffix("2 windows") == true
        let once: Bool = wikiCell.map { (cell: SwitcherProjectCell) -> Bool in !cell.shownFolder.contains("window") } ?? false
        check(twice && once, "Welcome: a project open in two windows says “2 windows” after its folder; one in one window, nothing",
              "shop “\(shopCell?.shownFolder ?? "no row")”, wiki “\(wikiCell?.shownFolder ?? "no row")”")
        let shopSaid: String = shopCell?.accessibilityLabel() ?? ""
        let wikiSaid: String = wikiCell?.accessibilityLabel() ?? ""
        check(shopSaid.hasPrefix("shop, open in 2 windows") && wikiSaid.hasPrefix("wiki, open"),
              "Welcome: VoiceOver hears “shop, open in 2 windows” and “wiki, open”", shopSaid + " | " + wikiSaid)
        let gap: CGFloat = shopCell?.baselineGap ?? 0
        check((13...16).contains(gap), "Welcome: a row's two lines sit 13 to 16 pt apart, baseline to baseline",
              String(format: "%.1f pt", gap))
        if let tree {
            let treeIndex: Int? = list.shown.projects.firstIndex { (project: SwitcherProject) -> Bool in project.path == tree }
            let treeCell: SwitcherProjectCell? = treeIndex.flatMap { (index: Int) -> SwitcherProjectCell? in list.projectCell(at: index) }
            let title: String = WorktreeWindow.title(repository: "billing", folder: "billing-wt-sso")
            check(treeCell?.shownName == title, "Welcome: a linked worktree's row reads as its window, “\(title)”",
                  treeCell?.shownName ?? "no row")
        }
        welcome.searchProjects("")
        welcome.close()
    }
}
#endif

#if DEBUG
// MARK: - the keys, in the run

extension SelfTest {
    /// The keys, pressed as the keyboard sends them, with shop in two windows and wiki in one (markerChecks).
    private static func switcherKeyChecks(_ app: AppDelegate, _ fixtures: SwitcherFixtures) async {
        guard switcherKeysAreDefault else {
            return note("Welcome switcher: its keys not pressed, as the menus' keys were changed or the keyboard layout lacks one")
        }
        let shops: [TerminalWindowController] = fixtures.windows(on: fixtures.path("shop"))
        guard shops.count == 2, let wiki = fixtures.windows(on: fixtures.path("wiki")).first, let wikiWindow = wiki.window,
              let shopA = shops[0].window, let shopB = shops[1].window else {
            return check(false, "Welcome: shop is open in two windows and wiki in one, for the keys", names(fixtures.windows.compactMap(\.project)))
        }
        // shop's second window was in front last of its two, then wiki's: ⌘O is pressed there.
        for window in [shopA, shopB, wikiWindow] {
            guard await bringToFront(window), window.canBeSeen else {
                return note("Welcome switcher: its keys skipped, as " + notFrontmost(window))
            }
        }
        await returnChecks(app, from: wikiWindow, back: shopB)
        await hintAndEscapeChecks(app, fixtures, from: shopB)
        await jumpChecks(app, fixtures, from: shopB)
        await forgetChecks(app, fixtures, from: shopB)
        await agentOpenChecks(app, fixtures, from: shopB)
        await serverReturnChecks(app, from: shopB)
    }

    /// ⌘O pressed in `window`, with the Welcome window closed first so it comes up anew: the Welcome window, key; nil
    /// (with a failed check) when it did not show.
    private static func showSwitcher(_ app: AppDelegate, from window: NSWindow) async -> WelcomeWindowController? {
        if let up = app.welcomeController?.window, up.isVisible {
            app.welcomeController?.close()
            _ = await wait(2) { !up.isVisible }
        }
        guard await bringToFront(window) else {
            note("Welcome switcher: ⌘O not pressed, as " + notFrontmost(window))
            return nil
        }
        guard switcherKey(SwitcherKeyCode.o, .command, to: window) else { return nil }
        let shown: Bool = await wait(3) { app.welcomeController?.window?.isKeyWindow == true }
        guard shown, let welcome = app.welcomeController else {
            check(false, "Welcome: ⌘O in a project window shows the Welcome window, key", String(describing: NSApp.keyWindow))
            return nil
        }
        return welcome
    }

    /// ⌘O in wiki's window: the Welcome window comes up centred over it, on its screen, the keyboard in the search with
    /// its text selected, and the selection on the other open project used last, shop, with “Go to Window” as Return's.
    /// Return brings forward shop's window that was in front last, of its two, and closes the Welcome window.
    private static func returnChecks(_ app: AppDelegate, from origin: NSWindow, back: NSWindow) async {
        guard let welcome = await showSwitcher(app, from: origin), let window = welcome.window else { return }
        check(searchHasKeyboard(welcome) && searchAllSelected(welcome),
              "Welcome: shown by ⌘O, the keyboard is in its search, its text selected", String(describing: window.firstResponder))
        let screen: NSScreen? = origin.screen ?? NSScreen.main
        let visible: CGRect = screen?.visibleFrame ?? .zero
        let over: CGRect = origin.frame
        let expected: CGRect = SwitcherPlacement.frame(size: window.frame.size, minSize: window.minSize, over: over, within: visible)
        let dx: CGFloat = abs(window.frame.midX - expected.midX)
        let dy: CGFloat = abs(window.frame.midY - expected.midY)
        let centred: Bool = abs(window.frame.midX - over.midX) <= 1 && abs(window.frame.midY - over.midY) <= 1
        check(dx <= 1 && dy <= 1 && window.screen == origin.screen,
              "Welcome: it comes up centred over the window ⌘O was pressed in, on that window's screen, kept within it",
              "\(NSStringFromRect(window.frame)) over \(NSStringFromRect(over)), centred \(centred)")
        check(noBackdrop(window) && origin.isVisible && origin.alphaValue == 1,
              "Welcome: nothing dims, blurs or covers the windows behind it, which stay as they are")
        let shop: String = back.windowController.flatMap { ($0 as? TerminalWindowController)?.project } ?? ""
        let enter: String = KeyChord(key: "\r").display
        let hint: [String] = [enter + " go to window", SwitcherKeys.newWindow.display + " new window", "esc close"]
        check(welcome.selectedProject == shop && welcome.returnButtonTitle == "Go to Window" && welcome.hintParts == hint,
              "Welcome: it starts on the other open project used last, “Go to Window” is Return's, and the hint line says “↩ go to window”, “⌘↩ new window” and “esc close”",
              "\(welcome.selectedProject.map { ($0 as NSString).lastPathComponent } ?? "none"), "
                  + "\(welcome.returnButtonTitle ?? "no button"), " + welcome.hintParts.joined(separator: " | "))
        guard switcherKey(SwitcherKeyCode.returnKey, to: window) else { return }
        let switched: Bool = await wait(3) { back.isKeyWindow && !window.isVisible }
        check(switched, "Welcome: Return brings forward that project's window used last, of its two, and closes the Welcome window",
              "key \(String(describing: NSApp.keyWindow?.title)), Welcome up \(window.isVisible)")
    }
}
#endif

#if DEBUG
extension SelfTest {
    /// ⌘ held shows each listed project's jump key in its branch's place, and letting go gives the branches their place
    /// back (the worktree's, sso); typed text that matches nothing says so, and the hint line names the three ways in; Esc
    /// empties the search and Esc again closes the window, another being open. Left behind the window it came from, it
    /// keeps what was typed for the next ⌘O, selected; what was typed before ⌘W is gone at the next ⌘O.
    private static func hintAndEscapeChecks(_ app: AppDelegate, _ fixtures: SwitcherFixtures, from origin: NSWindow) async {
        guard let welcome = await showSwitcher(app, from: origin), let window = welcome.window else { return }
        let search: NSSearchField = welcome.projectsSearchField
        typeKeys(window, switcherToken)
        let list: WelcomeSwitcherList = welcome.switcherList
        _ = await wait(2) { search.stringValue == switcherToken }
        let count: Int = min(list.shown.projects.count, 9)
        func jumps() -> [String?] {
            (0..<count).map { (index: Int) -> String? in list.projectCell(at: index)?.shownJump }
        }
        func branchesShown() -> Int {
            (0..<count).filter { (index: Int) -> Bool in list.projectCell(at: index)?.shownBranch != nil }.count
        }
        let expected: [String?] = (0..<count).map { (index: Int) -> String? in "⌘\(index + 1)" }
        holdCommand(true)
        let shown: Bool = await wait(2) { count > 0 && jumps() == expected && branchesShown() == 0 }
        check(shown, "Welcome: ⌘ held, each of the \(count) projects listed shows its key, ⌘1 to ⌘\(count), in its branch's place",
              jumps().map { (key: String?) -> String in key ?? "none" }.joined(separator: " ") + ", \(branchesShown()) branches shown")
        holdCommand(false)
        let gone: Bool = await wait(2) { jumps().allSatisfy { (key: String?) -> Bool in key == nil } }
        let treeIndex: Int? = fixtures.worktree.flatMap { (tree: String) -> Int? in
            list.shown.projects.firstIndex { (project: SwitcherProject) -> Bool in project.path == tree }
        }
        func treeBranch() -> String? { treeIndex.flatMap { (index: Int) -> String? in list.projectCell(at: index)?.shownBranch } }
        var branchBack = true
        if treeIndex != nil { branchBack = await wait(3) { treeBranch()?.contains("sso") == true } }
        check(gone && branchBack, "Welcome: let go, the keys give the branches their place back, the worktree's “sso” too",
              "keys gone \(gone), the worktree's branch “\(treeBranch() ?? "hidden")”")

        guard switcherKey(SwitcherKeyCode.escape, to: window) else { return }
        _ = await wait(2) { search.stringValue.isEmpty }
        let typed: String = "zq" + switcherToken
        typeKeys(window, typed)
        let none: String = "No project or server matches “" + typed + "”."
        let unmatched: Bool = await wait(2) { welcome.noMatchText == none }
        check(unmatched && welcome.selectedEntry == nil && welcome.hintParts == wayInHints,
              "Welcome: typed with no match, the list says so, nothing is selected, and the hint line names the three ways in",
              "\(welcome.noMatchText ?? "no line"), " + welcome.hintParts.joined(separator: " | "))
        guard switcherKey(SwitcherKeyCode.escape, to: window) else { return }
        let emptied: Bool = await wait(2) { search.stringValue.isEmpty && window.isVisible }
        guard switcherKey(SwitcherKeyCode.escape, to: window) else { return }
        let closed: Bool = await wait(2) { !window.isVisible }
        check(emptied && closed, "Welcome: Esc empties the search, and Esc again closes the window, another window being open",
              "emptied \(emptied), closed \(closed)")
        await behindChecks(app, from: origin)
    }

    /// Typed in, then left behind the window it came from: ⌘O there brings it back with what was typed, selected, the
    /// keyboard in the search. ⌘W then closes it, and at the next ⌘O what was typed is gone.
    private static func behindChecks(_ app: AppDelegate, from origin: NSWindow) async {
        guard let again = await showSwitcher(app, from: origin), let shownAgain = again.window else { return }
        let search: NSSearchField = again.projectsSearchField
        typeKeys(shownAgain, "zz")
        _ = await wait(2) { search.stringValue == "zz" }
        guard await bringToFront(origin) else {
            return note("Welcome: left behind a window, not checked, as " + notFrontmost(origin))
        }
        let behind: Bool = shownAgain.isVisible && !shownAgain.isKeyWindow
        guard switcherKey(SwitcherKeyCode.o, .command, to: origin) else { return }
        let front: Bool = await wait(3) { shownAgain.isKeyWindow && searchHasKeyboard(again) }
        let kept: Bool = search.stringValue == "zz" && searchAllSelected(again)
        check(behind && front && kept,
              "Welcome: left behind another window and shown again by ⌘O, it keeps what was typed, selected, the keyboard in the search",
              "behind \(behind), key again \(front), “\(search.stringValue)”, all selected \(searchAllSelected(again))")
        guard switcherKey(SwitcherKeyCode.w, .command, to: shownAgain) else { return }
        let shut: Bool = await wait(2) { !shownAgain.isVisible }
        guard let third = await showSwitcher(app, from: origin) else { return }
        check(shut && third.projectsSearchField.stringValue.isEmpty && searchHasKeyboard(third),
              "Welcome: ⌘W closes it, and at the next ⌘O what was typed is gone, the keyboard in the search",
              "closed \(shut), “\(third.projectsSearchField.stringValue)”")
        third.close()
    }
}
#endif

#if DEBUG
extension SelfTest {
    /// ⌘3 does to the third project listed what Return would: with the worktree's window closed, that is the worktree,
    /// which opens in a window of its own and stays out of File › Open Recent. ↓ moves the selection with the keyboard
    /// still in the search, and ⌘↩ on an open project opens a second window on it, without asking.
    private static func jumpChecks(_ app: AppDelegate, _ fixtures: SwitcherFixtures, from origin: NSWindow) async {
        if let tree = fixtures.worktree {
            for controller in fixtures.windows(on: tree) { await closeSwitcherWindow(controller) }
        }
        guard let welcome = await showSwitcher(app, from: origin), let window = welcome.window else { return }
        typeKeys(window, switcherToken)
        let list: WelcomeSwitcherList = welcome.switcherList
        _ = await wait(2) { welcome.projectsSearchField.stringValue == switcherToken }
        guard list.shown.projects.count >= 3 else {
            return check(false, "Welcome: three projects or more are listed for ⌘3", names(welcome.shownProjects))
        }
        let third: SwitcherProject = list.shown.projects[2]
        let before: Int = fixtures.windows(on: third.path).count
        guard switcherKey(SwitcherKeyCode.digit(2), .command, to: window) else { return }
        let acted: Bool = await wait(5) {
            let windows: [TerminalWindowController] = fixtures.windows(on: third.path)
            let front: Bool = windows.contains { (controller: TerminalWindowController) -> Bool in controller.window?.isKeyWindow == true }
            return third.isOpen ? front : windows.count == before + 1
        }
        check(acted && !window.isVisible, "Welcome: ⌘3 does what Return does to the third project listed, \(third.title), and closes the Welcome window",
              "open before \(third.isOpen), windows on it \(fixtures.windows(on: third.path).count), Welcome up \(window.isVisible)")
        if let tree = fixtures.worktree, third.path == tree {
            check(!app.recentProjects.contains(tree), "Welcome: the closed worktree opened from the list stays out of File › Open Recent")
        }

        guard let next = await showSwitcher(app, from: origin), let nextWindow = next.window else { return }
        typeKeys(nextWindow, switcherToken)
        _ = await wait(2) { next.projectsSearchField.stringValue == switcherToken }
        let wiki: String = fixtures.path("wiki")
        let rows: Int = next.switcherList.shown.entries.count
        var pressed = 0
        while next.selectedProject != wiki && pressed < rows {
            guard switcherKey(SwitcherKeyCode.down, to: nextWindow) else { return }
            pressed += 1
        }
        check(next.selectedProject == wiki && searchHasKeyboard(next),
              "Welcome: ↓ moves the selection down the list, the keyboard staying in the search", "\(pressed) presses")
        let wikis: Int = fixtures.windows(on: wiki).count
        guard switcherKey(SwitcherKeyCode.returnKey, .command, to: nextWindow) else { return }
        let second: Bool = await wait(5) { fixtures.windows(on: wiki).count == wikis + 1 }
        check(second && !nextWindow.isVisible, "Welcome: ⌘↩ on an open project opens a second window on it, without asking",
              "\(fixtures.windows(on: wiki).count) windows on wiki, \(wikis) before")
    }
}
#endif

#if DEBUG
extension SelfTest {
    /// ⌘⌫ with text typed deletes the text, as in any field, and forgets nothing; on the empty search it forgets the
    /// selected closed project, from this list and from File › Open Recent; an open project it never forgets. ⌘↩ with the
    /// keyboard in the sessions search, a made-up session listed there, opens no window and resumes nothing.
    private static func forgetChecks(_ app: AppDelegate, _ fixtures: SwitcherFixtures, from origin: NSWindow) async {
        let shop: String = fixtures.path("shop")
        let sessionFolder: URL? = fixtureSession(for: shop)
        defer { if let sessionFolder { try? FileManager.default.removeItem(at: sessionFolder) } }
        guard let welcome = await showSwitcher(app, from: origin), let window = welcome.window else { return }
        let search: NSSearchField = welcome.projectsSearchField
        let recorder = ProjectHistoryRecorder.shared
        let historyBefore: [String] = recorder.history.paths
        let recentsBefore: [String] = app.recentProjects
        typeKeys(window, "zz")
        _ = await wait(2) { search.stringValue == "zz" }
        // ⌘⌫ with text typed is the field's (delete to the line's start): the window must leave it alone and forget
        // nothing. A ⌘⌫ made in this process never runs the field's command (AppKit runs it for none, Next Term or not,
        // while Delete, ⌥⌫ and ⌃H made the same way do), so the field's own command checks that the search lets it through.
        guard switcherKey(SwitcherKeyCode.delete, .command, to: window) else { return }
        await pause(0.3)
        let kept: Bool = recorder.history.paths == historyBefore && app.recentProjects == recentsBefore
        let editor: NSTextView? = search.currentEditor() as? NSTextView
        editor?.doCommand(by: #selector(NSResponder.deleteToBeginningOfLine(_:)))
        let cleared: Bool = await wait(2) { search.stringValue.isEmpty }
        check(cleared && kept, "Welcome: ⌘⌫ with text typed forgets no project, and the search deletes to the line's start",
              "“\(search.stringValue)”, history kept \(recorder.history.paths == historyBefore), recents kept \(app.recentProjects == recentsBefore)")

        let docs: String = fixtures.path("docs")
        welcome.select(project: docs)
        guard welcome.selectedProject == docs else { return check(false, "Welcome: the closed project docs is listed, for ⌘⌫") }
        guard switcherKey(SwitcherKeyCode.delete, .command, to: window) else { return }
        let forgot: Bool = await wait(2) {
            !welcome.shownProjects.contains(docs) && recorder.history.lastUsed(docs) == nil && !app.recentProjects.contains(docs)
        }
        check(forgot, "Welcome: ⌘⌫ on the empty search forgets the selected closed project, here and in File › Open Recent",
              "listed \(welcome.shownProjects.contains(docs)), in Open Recent \(app.recentProjects.contains(docs))")

        welcome.select(project: shop)
        guard switcherKey(SwitcherKeyCode.delete, .command, to: window) else { return }
        await pause(0.3)
        check(welcome.shownProjects.contains(shop) && recorder.history.lastUsed(shop) != nil,
              "Welcome: ⌘⌫ never forgets an open project")

        var listed = false
        if sessionFolder != nil { listed = await wait(10) { welcome.shownSessionTitles == ["Tidy the fixtures"] } }
        if !listed { note("Welcome: shop's made-up session was not listed, so ⌘↩ in the sessions search had none to resume") }
        func tabCount() -> Int {
            app.controllers.reduce(0) { (count: Int, controller: TerminalWindowController) -> Int in count + controller.tabs.count }
        }
        let windows: Int = app.controllers.count
        let tabs: Int = tabCount()
        guard welcome.focusSessionSearch() else { return check(false, "Welcome: a selected project's sessions search takes the keyboard") }
        guard switcherKey(SwitcherKeyCode.returnKey, .command, to: window) else { return }
        await pause(0.5)
        check(app.controllers.count == windows && tabCount() == tabs && window.isVisible,
              "Welcome: ⌘↩ in the sessions search, a session listed, opens no window and resumes nothing",
              "\(app.controllers.count) windows, \(windows) before; \(tabCount()) tabs, \(tabs) before; session listed \(listed)")
        welcome.close()
    }

    /// A made-up Claude Code session, “Tidy the fixtures”, for `project`, in the sessions home the run points the Welcome
    /// window at (in the temporary folder): its folder, to remove after; nil when that home is elsewhere, as nothing is
    /// written in a real one.
    private static func fixtureSession(for project: String) -> URL? {
        let home: String = canonicalPath(SessionStore.home)
        guard home.hasPrefix(canonicalPath(NSTemporaryDirectory()) + "/") else { return nil }
        let projects: URL = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects", isDirectory: true)
        let folder: URL = projects.appendingPathComponent(AgentSessions.claudeFolderName(project), isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        let stamp: String = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
        let asked: [String: Any] = ["type": "user", "cwd": project, "timestamp": stamp, "message": ["content": "Tidy the fixtures"]]
        let titled: [String: Any] = ["type": "ai-title", "aiTitle": "Tidy the fixtures"]
        let lines: [String] = [asked, titled].map { (object: [String: Any]) -> String in
            let data: Data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        let file: URL = folder.appendingPathComponent(switcherToken + ".jsonl")
        guard (try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)) != nil else { return nil }
        return folder
    }

    /// An agent opens a project over MCP while the user types in the Welcome window: the Welcome window stays up, though
    /// the agent's window comes forward with the keyboard, and the project is listed at once with a dot. Its window
    /// closed, the row loses the dot at once and comes first among the closed, with no new show. A window brought to the
    /// front after its open, then left, is recorded as used when it was last in front.
    private static func agentOpenChecks(_ app: AppDelegate, _ fixtures: SwitcherFixtures, from origin: NSWindow) async {
        guard let welcome = await showSwitcher(app, from: origin), let window = welcome.window else { return }
        welcome.searchProjects(switcherToken)
        let list: WelcomeSwitcherList = welcome.switcherList
        let feed: String = fixtures.path("feed")
        func feedRow() -> (index: Int, project: SwitcherProject)? {
            guard let index = list.shown.projects.firstIndex(where: { (project: SwitcherProject) -> Bool in project.path == feed }) else {
                return nil
            }
            return (index, list.shown.projects[index])
        }
        // As MCP open_project does it, under the default “When an agent opens a tab” (its window comes forward with the
        // keyboard), the self-test's own keys not taken for typing, so it comes forward now and never after its close.
        let arrival: AgentArrival.Mode = app.agentArrival
        app.agentArrival = .focus
        UserKeys.ignoredForTest = true
        let agent: TerminalWindowController = app.openFolder(feed, newWindow: false, forAgent: true)
        agent.presentForAgent(nil, explicit: true)
        UserKeys.ignoredForTest = false
        app.agentArrival = arrival
        let listed: Bool = await wait(3) {
            guard let row = feedRow() else { return false }
            return row.project.isOpen && list.projectCell(at: row.index)?.showsOpenDot == true
        }
        check(listed && window.isVisible,
              "Welcome: a project an agent opens over MCP while the Welcome window has the keyboard is listed at once, with a dot, the window staying up",
              "listed \(feedRow() != nil), up \(window.isVisible), Welcome key \(window.isKeyWindow), "
                  + "agent's key \(agent.window?.isKeyWindow == true)")
        await closeSwitcherWindow(agent)
        let followed: Bool = await wait(3) {
            guard let row = feedRow() else { return false }
            let firstClosed: Int? = list.shown.projects.firstIndex { (project: SwitcherProject) -> Bool in !project.isOpen }
            return !row.project.isOpen && firstClosed == row.index && list.projectCell(at: row.index)?.showsOpenDot == false
        }
        check(followed && window.isVisible, "Welcome: its window closed, the row loses its dot at once and comes first among the closed",
              names(welcome.shownProjects))
        welcome.close()
        await lastInFrontChecks(app, fixtures, from: origin)
    }
}
#endif

#if DEBUG
extension SelfTest {
    /// A window brought to the front a while after its open, then left for another and closed a while later: its project
    /// is recorded as used when it was last in front, not when it opened, nor when it closed.
    private static func lastInFrontChecks(_ app: AppDelegate, _ fixtures: SwitcherFixtures, from origin: NSWindow) async {
        let opened = Date()
        let notes: TerminalWindowController = await fixtures.open("notes")
        guard let notesWindow = notes.window else { return check(false, "Welcome: a window opens on notes") }
        await pause(1)
        guard await bringToFront(notesWindow) else { return note("Welcome: the last time in front not checked, as " + notFrontmost(notesWindow)) }
        let front = Date()
        guard await bringToFront(origin) else { return note("Welcome: the last time in front not checked, as " + notFrontmost(origin)) }
        await pause(1)
        let closing = Date()
        await closeSwitcherWindow(notes)
        let used: Date? = ProjectHistoryRecorder.shared.history.lastUsed(fixtures.path("notes"))
        let late: Bool = used.map { (date: Date) -> Bool in date >= front.addingTimeInterval(-0.05) } ?? false
        let notAtOpen: Bool = used.map { (date: Date) -> Bool in date.timeIntervalSince(opened) > 0.5 } ?? false
        let beforeClose: Bool = used.map { (date: Date) -> Bool in date < closing } ?? false
        let detail: String = used.map { (date: Date) -> String in
            String(format: "%.2f s after the open, %.2f s before the close", date.timeIntervalSince(opened), closing.timeIntervalSince(date))
        } ?? "not recorded"
        check(late && notAtOpen && beforeClose,
              "Welcome: a closed project is recorded as used when its window was last in front, not when it opened or closed", detail)
    }

    /// The servers in the list: ↓ past the last project selects the first server, whose pane shows with Connect as
    /// Return's; typed, the search finds one server; Return opens a window with a tab on it (a stand-in ssh that only
    /// waits), closes the Welcome window and remembers the pick for the next show. The servers are made up.
    private static func serverReturnChecks(_ app: AppDelegate, from origin: NSWindow) async {
        let staging = RemoteHost(name: switcherToken + "staging", destination: "deploy@staging.example.invalid",
                                 directory: "~/srv/shop", keep: .tmux)
        let prod = RemoteHost(name: switcherToken + "prod", destination: "deploy@prod.example.invalid", keep: .off)
        RemoteHosts.save(staging)
        RemoteHosts.save(prod)
        let standIn: String = (NSTemporaryDirectory() as NSString).appendingPathComponent("nt-switcher-ssh-\(getpid())")
        try? "#!/bin/sh\nexec sleep 30\n".write(toFile: standIn, atomically: true, encoding: .utf8)
        chmod(standIn, 0o755)
        RemoteConnection.testSSHPath = standIn
        defer {
            RemoteConnection.testSSHPath = nil
            try? FileManager.default.removeItem(atPath: standIn)
        }
        guard let welcome = await showSwitcher(app, from: origin), let window = welcome.window else { return }
        typeKeys(window, switcherToken)
        _ = await wait(2) { welcome.projectsSearchField.stringValue == switcherToken }
        for _ in welcome.shownProjects {
            guard switcherKey(SwitcherKeyCode.down, to: window) else { return }
        }
        let enter: String = KeyChord(key: "\r").display
        let onServer: Bool = welcome.selectedEntry?.server != nil && welcome.serverPaneShown
        check(onServer && welcome.returnButtonTitle == "Connect" && welcome.hintParts == [enter + " connect"],
              "Welcome: ↓ past the last project selects the first server: its pane shows, Connect is Return's, the hint line says “↩ connect”",
              "\(String(describing: welcome.selectedEntry?.id)), " + welcome.hintParts.joined(separator: " | "))
        guard switcherKey(SwitcherKeyCode.escape, to: window) else { return }
        _ = await wait(2) { welcome.projectsSearchField.stringValue.isEmpty }
        typeKeys(window, switcherToken + "pro")
        let found: Bool = await wait(2) {
            welcome.shownServers == [prod.name] && welcome.shownProjects.isEmpty && welcome.selectedEntry?.server?.id == prod.id
        }
        check(found, "Welcome: typed, the search lists the one server it matches, selected", welcome.shownServers.joined(separator: ", "))
        let before: Set<ObjectIdentifier> = Set(app.controllers.map { (controller: TerminalWindowController) -> ObjectIdentifier in
            ObjectIdentifier(controller)
        })
        func added() -> [TerminalWindowController] {
            app.controllers.filter { (controller: TerminalWindowController) -> Bool in !before.contains(ObjectIdentifier(controller)) }
        }
        guard switcherKey(SwitcherKeyCode.returnKey, to: window) else { return }
        let opened: Bool = await wait(5) {
            added().contains { (controller: TerminalWindowController) -> Bool in controller.tabs.first?.remote?.host.id == prod.id }
        }
        let picked: Bool = UserDefaults.standard.string(forKey: SwitcherSelection.lastPickKey) == prod.id
        check(opened && !window.isVisible && picked,
              "Welcome: Return on a server opens a window with a tab on it, closes the Welcome window, and is remembered for the next show",
              "opened \(opened), Welcome up \(window.isVisible), remembered \(picked)")
        for controller in added() { await closeSwitcherWindow(controller) }
    }
}
#endif

#if DEBUG
extension SelfTest {
    /// The Welcome window comes up with nothing laid over the screen: no window of its own, no borderless window the size
    /// of a screen, and no material behind its content (a system material the size of half the window or more); the
    /// window itself solid.
    fileprivate static func noBackdrop(_ window: NSWindow) -> Bool {
        let children: Bool = window.childWindows?.isEmpty ?? true
        let screens: [CGRect] = NSScreen.screens.map(\.frame)
        let overlay: Bool = NSApp.windows.contains { (other: NSWindow) -> Bool in
            other.isVisible && !other.styleMask.contains(.titled) && screens.contains(other.frame)
        }
        guard let content = window.contentView else { return false }
        let half: CGFloat = content.bounds.width * content.bounds.height / 2
        var views: [NSView] = [content]
        var material = false
        while let view = views.popLast() {
            if view is NSVisualEffectView, view.bounds.width * view.bounds.height >= half { material = true }
            views.append(contentsOf: view.subviews)
        }
        let solid: Bool = window.alphaValue == 1 && window.backgroundColor == Theme.background
        return children && !overlay && !material && solid
    }

    /// NEXTTERM_SELFTEST_ONLY=welcome: the Welcome window's own checks, on a scratch folder, for its own failures
    /// without the whole run.
    static func welcomePartChecks() async {
        let app = AppDelegate.shared!
        let restore = keepSwitcherDefaults()
        let folder: String = canonicalPath(NSTemporaryDirectory()) + "/nt-welcome-part-\(getpid())"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let controller: TerminalWindowController = app.openFolder(folder, newWindow: true)
        _ = await wait(5) { controller.window?.isVisible == true }
        await openProjectChecks(app, from: controller)
        app.showWelcome(nil)
        if let welcome = app.welcomeController {
            welcome.select(project: folder)
            welcomeReturnKeyChecks(welcome, project: folder)
            welcome.close()
        } else {
            check(false, "Welcome: the Welcome window shows")
        }
        await closeSwitcherWindow(controller)
        restore()
        try? FileManager.default.removeItem(atPath: folder)
        await welcomeSwitcherChecks()
    }
}
#endif
