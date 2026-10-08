import AppKit
import NextTermCore

/// The Welcome window's Return key: "Open…" while no project is listed, else "Open Project", and never Resume, even with
/// a project's sessions listed. A double-click and the buttons are checked with the sessions.
extension SelfTest {
    /// `welcome` shows `project`, with its sessions listed. A second Welcome window, never shown, lists nothing and then
    /// the project, as on a new Mac before and after a folder is opened.
    static func welcomeReturnKeyChecks(_ welcome: WelcomeWindowController, project: String) {
        let listed: [String] = returnKeyButtons(welcome.window)
        check(listed == ["Open Project"],
              "with a project and its sessions listed, Return on the Welcome window opens the project, and Resume has no key",
              "Return on \(listed)")

        let fresh = WelcomeWindowController()
        defer { fresh.close() }
        fresh.list(projects: [])
        let none: [String] = returnKeyButtons(fresh.window)
        check(none == ["Open…"], "with no recent projects, Return on the Welcome window is Open…", "Return on \(none)")
        fresh.list(projects: [project])
        let one: [String] = returnKeyButtons(fresh.window)
        check(one == ["Open Project"], "once a project is listed, Return moves to Open Project", "Return on \(one)")
    }

    /// The titles of the buttons in `window` that Return presses: one at most.
    private static func returnKeyButtons(_ window: NSWindow?) -> [String] {
        guard let content = window?.contentView else { return [] }
        var found: [String] = []
        var views: [NSView] = [content]
        while let view = views.popLast() {
            if let button = view as? NSButton, button.keyEquivalent == "\r" { found.append(button.title) }
            views.append(contentsOf: view.subviews)
        }
        return found
    }
}
