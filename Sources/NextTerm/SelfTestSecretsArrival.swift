import AppKit
import NextTermCore

/// A tab run_with_secrets opens in another project's window comes forward as Settings › Editor › "When an agent opens
/// a tab" says, as new_tab's does (AgentArrival). While the user is in request_secret's window or in Settings, where a
/// key is typed or pasted, a window an agent opens comes forward behind it and never takes the keyboard
/// (SecretEntryWindows).
extension SelfTest {
    static func secretsArrivalChecks(_ c: TerminalWindowController) async {
        let app = AppDelegate.shared!
        let modeBefore = app.agentArrival
        SecretRequests.shared.resetForSelfTest() // the limits the checks before counted
        let other = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-secrets-arrival-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        var opened: [TerminalTab] = []
        defer {
            for tab in opened { MCPControl.controller(of: tab)?.remove(tab) } // its last tab takes the window
            app.agentArrival = modeBefore
            try? FileManager.default.removeItem(at: other)
        }
        guard let window = c.window, await bringToFront(window) else {
            return check(false, "secrets: the project's window comes to the front for the arrival checks")
        }
        app.agentArrival = .focus
        await secretsArrivalRunCheck(window, folder: other, opened: &opened)
        _ = await bringToFront(window)
        await secretsEntryKeepsKeyboardChecks(folder: other, opened: &opened)
        _ = await bringToFront(window)
    }

    /// run_with_secrets in a folder no window holds: its project's window comes forward and, in focus, becomes the key
    /// window; the tab is selected there and still waits for a click; the answer says it was selected.
    private static func secretsArrivalRunCheck(_ window: NSWindow, folder: URL, opened: inout [TerminalTab]) async {
        let requests = SecretRequests.shared
        let app = AppDelegate.shared!
        let before = Set(app.controllers.flatMap(\.tabs).map(\.id))
        let call = secretsStart("run_with_secrets", ["secrets": ["TOOL_KEY"], "command": "true", "directory": folder.path])
        _ = await wait(15) { requests.showing?.panel != nil }
        opened += app.controllers.flatMap(\.tabs).filter { !before.contains($0.id) }
        // The ticket's tab, by its title: the new window's own first tab is new too.
        let tab = opened.first { $0.userTitle == "true · with TOOL_KEY" }
        let owner = tab.flatMap { MCPControl.controller(of: $0) }
        _ = await wait(3) { NSApp.keyWindow === owner?.window }
        check(owner != nil && owner?.window !== window && NSApp.keyWindow === owner?.window && owner?.activeTab === tab
              && tab?.view.awaitsChoice == true && owner?.window?.firstResponder !== tab?.view,
              "secrets: focus: a tab run_with_secrets opens in another project's window is selected there, its window "
                  + "becomes the key window, and the tab still waits for a click",
              "key: \(NSApp.keyWindow?.title ?? "none"), owner: \(owner?.window?.title ?? "none"), "
                  + "selected: \(owner?.activeTab === tab), waits: \(tab?.view.awaitsChoice == true)")
        requests.showing?.panel?.declineButton.performClick(nil)
        let declined = await call.value
        check(declined["status"] as? String == "declined" && declined["selected"] as? Bool == true
              && declined["tab_id"] as? String == tab?.id.uuidString.lowercased(),
              "secrets: the answer for that tab says it was selected in its window", secretsJSON(declined))
    }

    /// new_tab for `folder`'s window (open, not the key window) while the user is in `entry`: it comes forward behind
    /// `entry`, which keeps the keyboard.
    private static func secretsArrivesBehind(_ entry: NSWindow, folder: URL, opened: inout [TerminalTab]) async -> (Bool, String) {
        // The keyboard before the agent's window came and after: one that moved before it came is not the arrival's doing.
        let before: String = secretsKeyboardNow()
        let answer = await secretsTool("new_tab", ["directory": folder.path])
        let tab = AppDelegate.shared.controllers.flatMap(\.tabs).first { $0.id.uuidString.lowercased() == answer["id"] as? String }
        if let tab { opened.append(tab) }
        let owner = tab.flatMap { MCPControl.controller(of: $0) }
        _ = await wait(2) { NSApp.keyWindow !== entry } // an arrival that took the keyboard would show by now
        let order = NSApp.orderedWindows
        let entryAt = order.firstIndex(of: entry)
        let ownerAt = owner?.window.flatMap { order.firstIndex(of: $0) }
        let behind = entryAt.flatMap { at in ownerAt.map { $0 > at } } ?? false
        let waits = tab?.view.awaitsChoice == true
        let held = waits && NSApp.keyWindow === entry && owner?.window?.isVisible == true && behind
        let after: String = secretsKeyboardNow()
        let placed: String = "order: \(String(describing: ownerAt)) behind \(String(describing: entryAt))"
        let detail: String = "\(secretsJSON(answer)); before: \(before); after: \(after), \(placed)"
        return (held, detail)
    }

    /// The key window's title and whether Next Term is the app in front, for a check's detail.
    private static func secretsKeyboardNow() -> String {
        let key: String = NSApp.keyWindow?.title ?? "none"
        return "key: \(key), active: \(NSApp.isActive)"
    }

    /// The user clicked into Settings, then request_secret's value field (a click is not a key, so nothing waits for it):
    /// an agent's window comes forward behind each in focus mode, and the key a ⌘V pastes goes where they meant it.
    /// Settings goes first, and each window is gone before the next check starts: a key window closed just before could
    /// take the keyboard back when Next Term is made active again.
    private static func secretsEntryKeepsKeyboardChecks(folder: URL, opened: inout [TerminalTab]) async {
        await secretsSettingsKeepsKeyboardCheck(folder: folder, opened: &opened)

        let requests = SecretRequests.shared
        let call = secretsStart("request_secret", ["name": "ARRIVAL_KEY", "reason": "the arrival check"])
        _ = await wait(10) { requests.showing?.requestWindow != nil }
        let request: SecretRequestWindow? = requests.showing?.requestWindow
        if let request, let entry = request.window, await bringToFront(entry) {
            entry.makeFirstResponder(request.valueField)
            let (held, detail) = await secretsArrivesBehind(entry, folder: folder, opened: &opened)
            check(held, "secrets: focus: while the user is in request_secret's window, a window an agent opens comes forward "
                      + "behind it, and the request window keeps the keyboard", detail)
            request.declineButton.performClick(nil)
        } else {
            check(false, "secrets: request_secret's window opens and takes the keyboard when the user clicks it")
            requests.showing?.requestWindow?.declineButton.performClick(nil)
        }
        _ = await call.value
        let window: NSWindow? = request?.window
        _ = await wait(5) { window?.isVisible != true && requests.showing == nil && NSApp.keyWindow !== window }
    }

    private static func secretsSettingsKeepsKeyboardCheck(folder: URL, opened: inout [TerminalTab]) async {
        let settings = SettingsWindowController()
        guard let entry = settings.window, await bringToFront(entry) else {
            settings.window?.close()
            return check(false, "secrets: Settings comes to the front for the arrival check")
        }
        let (held, detail) = await secretsArrivesBehind(entry, folder: folder, opened: &opened)
        check(held, "secrets: focus: while the user is in Settings, a window an agent opens comes forward behind it, "
                  + "and Settings keeps the keyboard", detail)
        entry.close()
        _ = await wait(5) { !entry.isVisible && NSApp.keyWindow !== entry }
    }
}
