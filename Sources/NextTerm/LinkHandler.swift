import AppKit
import NextTermCore

/// Follows a `nextterm://` link (NextTermLink): a launcher's quick action. What a link names is done as the user would do it
/// by hand, in front and with the keyboard, since the user just asked for it; starting an agent asks first, as any web
/// page can open a link.
enum LinkHandler {
    static func follow(_ url: URL) {
        switch NextTermLink.parse(url) {
        case .failure(let refusal):
            tell(refusal.message)
        case .success(let link):
            follow(link)
        }
    }

    static func follow(_ link: NextTermLink) {
        let app: AppDelegate = AppDelegate.shared
        switch link {
        case .open(let path):
            guard isFolder(path) else { return tell("There is no folder at \(GoToAnything.shown(path)).") }
            let controller = app.openFolder(path, newWindow: false)
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
        case .tab(let id):
            guard let tab = MCPControl.tab(withID: id) else { return tell("That tab is gone.") }
            bring(tab)
        case .attention:
            guard let tab = waiting() else { return NSSound.beep() } // nothing waits: a launcher's hotkey, pressed again
            bring(tab)
        case .goTo:
            NSApp.activate(ignoringOtherApps: true)
            if !GoToAnythingPanel.isOpen { app.goToAnything(nil) }
        case .agent(let path, let agent):
            guard isFolder(path) else { return tell("There is no folder at \(GoToAnything.shown(path)).") }
            NSApp.activate(ignoringOtherApps: true)
            let name = NextTermLink.agents[agent] ?? agent
            let alert = NSAlert()
            alert.messageText = "Start \(name) in \(GoToAnything.shown(path))?"
            alert.informativeText = "A nextterm:// link asks for it, from a launcher or another app."
            alert.addButton(withTitle: "Start \(name)")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            MCPControl.call("new_tab", ["directory": path, "command": agent, "title": name], caller: nil) { result in
                DispatchQueue.main.async {
                    if result.isError { return tell(result.text) }
                    guard let data = result.text.data(using: .utf8),
                          let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let id = answer["id"] as? String ?? answer["tab_id"] as? String,
                          let tab = MCPControl.tab(withID: id) else { return }
                    bring(tab)
                }
            }
        }
    }

    /// The tab whose agent waits for the user: the one waiting longest, outside the tab in front when another waits.
    static func waiting() -> TerminalTab? {
        let app: AppDelegate = AppDelegate.shared
        let front = (UsersWindow.key?.windowController as? TerminalWindowController)?.activeTab
        let all = app.controllers.filter { !$0.hasClosed }.flatMap(\.tabs).filter { $0.status.state == .attention }
        return all.first { $0 !== front } ?? all.first
    }

    /// The tab in front of its window, the window in front, the keyboard in the tab: Go to Anything's way.
    static func bring(_ tab: TerminalTab) {
        guard let controller = MCPControl.controller(of: tab) else { return }
        AppDelegate.shared.bringForward(controller.indexID)
        controller.show(tab)
        controller.window?.makeFirstResponder(tab.view)
    }

    private static func isFolder(_ path: String) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
    }

    private static func tell(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Next Term can\u{2019}t follow that link"
        alert.informativeText = text
        alert.runModal()
    }
}
