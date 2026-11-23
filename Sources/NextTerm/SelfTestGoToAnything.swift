#if DEBUG
import AppKit
import NextTermCore

/// Go to Anything (plan 034): ⌘K is Clear in a terminal with the keyboard and Go to Anything everywhere else; the panel
/// lists Clear Terminal first, this window's tabs, then the others'; a search and Return bring a tab forward with the
/// keyboard; Escape closes it.
extension SelfTest {
    static func goToAnythingChecks(_ c: TerminalWindowController) async {
        let app: AppDelegate = AppDelegate.shared
        guard let window = c.window else { return check(false, "Go to Anything: a window to start from") }
        guard await bringToFront(window) else { return note("Go to Anything: skipped, " + notFrontmost(window)) }
        let commandK = KeyChord(key: "k", command: true)
        // ⌘K's two homes: the File menu's item outside a terminal, Clear Buffer's when a terminal has the keyboard.
        let fileItem: NSMenuItem? = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.items.first { $0.title == "Go to Anything…" }
        let menuKey: Bool = fileItem?.keyEquivalent == "k" && fileItem?.keyEquivalentModifierMask == .command
        let event: NSEvent? = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: "k",
                                               charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)
        let inTerminal: Selector? = event.flatMap { KeyboardShortcuts.shared.terminalItem(for: $0) }?.action
        check(menuKey && inTerminal == #selector(TerminalWindowController.clearBuffer(_:))
              && KeyboardShortcuts.shared.chord(for: "goToAnything:") == commandK,
              "Go to Anything: ⌘K is File › Go to Anything… outside a terminal and Clear Buffer while a terminal has the keyboard",
              "menu key \(menuKey), in a terminal \(inTerminal.map(NSStringFromSelector) ?? "none")")

        // A second tab with a name to find.
        let named = c.addTab(directory: nil, select: false)
        defer { c.remove(named) }
        _ = await wait(20) { named.status.integrated }
        named.userTitle = "selftest-goto-zebra"
        c.refresh()
        let front: TerminalTab? = c.activeTab
        app.goToAnything(nil)
        guard await wait(3, { GoToAnythingPanel.open?.isVisible == true }), let panel = GoToAnythingPanel.open else {
            return check(false, "Go to Anything: the panel opens")
        }
        let titles: [String] = panel.shownTitles
        let ordered: Bool = titles.first == GoToAnything.clearTitle && panel.selectedRow == 0
            && titles.firstIndex(of: "selftest-goto-zebra").map { $0 <= c.tabs.count } == true
        check(ordered, "Go to Anything: Clear Terminal first and selected, this window's tabs next", titles.prefix(8).joined(separator: ", "))
        panel.type("zebra")
        let found: Bool = panel.shownTitles.first == "selftest-goto-zebra" && panel.selectedRow == 0
        panel.pressReturn()
        let jumped: Bool = await wait(3) { c.activeTab === named && GoToAnythingPanel.open == nil }
        check(found && jumped, "Go to Anything: a search finds a tab by its name, and Return brings it forward and closes the panel",
              "found \(found), jumped \(jumped)")
        if let front { c.show(front) }

        app.goToAnything(nil)
        _ = await wait(3) { GoToAnythingPanel.open?.isVisible == true }
        GoToAnythingPanel.open?.cancelOperation(nil)
        let escaped: Bool = await wait(2) { GoToAnythingPanel.open == nil }
        check(escaped, "Go to Anything: Escape closes it, nothing chosen")
    }
}
#endif
