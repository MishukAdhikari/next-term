import AppKit
import NextTermCore

/// A tab or window an agent opens over MCP comes forward without the keyboard (AgentArrival): in the window in use it
/// opens behind the user's tab; nothing gives an agent's tab the keyboard until the user chooses it; choosing it does;
/// another project's window comes forward as Settings › Editor › When an agent opens a tab says, and the setting is
/// MCP's agents_bring_tabs_forward too.
extension SelfTest {
    static func arrivalChecks(_ first: TerminalWindowController, proj: URL) async {
        let app: AppDelegate = AppDelegate.shared
        let modeBefore = app.agentArrival
        app.agentArrival = .focus // the default; the rest of the self-test runs with it off
        UserKeys.ignoredForTest = true // the self-test's own keys would hold every window back
        let other = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-arrival-\(getpid())")
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        var opened: [TerminalTab] = []
        // The window in use: the project's own window, where new_tab puts a tab for its folder; one made here goes after.
        let project = canonicalPath(proj.path)
        let existing = app.controllers.first { $0.project == project && !$0.hasClosed }
        let c = existing ?? app.openFolder(project, newWindow: false)
        defer {
            for tab in opened { app.controllers.first { $0.tabs.contains { $0 === tab } }?.remove(tab) }
            if existing == nil { for tab in c.tabs { c.remove(tab) } } // its last tab takes the window
            app.agentArrival = modeBefore
            UserKeys.ignoredForTest = false
            try? FileManager.default.removeItem(at: other)
        }
        guard let window = c.window else { return check(false, "arrival: the project has a window") }
        // What comes forward depends on Next Term being the app in front: with the screen in use elsewhere, say so.
        guard await bringToFront(window), NSApp.isActive else {
            return note("arrival checks skipped: Next Term isn't the app in front (" + notFrontmost(window) + ")")
        }
        func newTab(_ directory: String) async -> (TerminalTab?, [String: Any]) {
            var result = MCPServer.CallResult(text: "", isError: false)
            MCPControl.call("new_tab", ["directory": directory], caller: nil) { result = $0 }
            _ = await wait(10) { !result.text.isEmpty }
            let json = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any]) ?? [:]
            let id = json["id"] as? String
            let tab = app.controllers.flatMap(\.tabs).first { $0.id.uuidString.lowercased() == id }
            if let tab { opened.append(tab) }
            return (tab, json)
        }

        // In the window in use: behind the user's tab, waiting, and refused the keyboard whoever asks.
        let front = c.activeTab
        let (behind, answer) = await newTab(proj.path)
        guard let behind else { return check(false, "arrival: new_tab opens a tab", "\(answer)") }
        check(c.activeTab === front && behind.view.awaitsChoice && answer["selected"] as? Bool == false
              && (answer["note"] as? String)?.contains("behind their tab") == true,
              "arrival: a tab an agent opens in the window in use stays behind the user's tab, and says so",
              "\(answer); owner is c: \(c.tabs.contains { $0 === behind }), c tabs: \(c.tabs.count), front nil: \(front == nil), "
                + "c key: \(window.isKeyWindow), active: \(NSApp.isActive), windows with the project: "
                + "\(app.controllers.filter { $0.project == project }.map { "\($0.tabs.count) tabs, key \($0.window?.isKeyWindow == true)" })")
        let refused = window.makeFirstResponder(behind.view)
        check(!refused && window.firstResponder !== behind.view, "arrival: nothing gives an agent's tab the keyboard before the user chooses it")
        // Choosing it (its tab, as a click or ⌘-number does) gives it the keyboard.
        c.show(behind)
        check(!behind.view.awaitsChoice && window.firstResponder === behind.view, "arrival: choosing the tab gives it the keyboard")
        if let front { c.show(front) }

        // Another project's window: forward as the setting says, its tab selected and still waiting.
        app.agentArrival = .show
        let (shown, _) = await newTab(other.path)
        let shownOwner = shown.flatMap { tab in app.controllers.first { $0.tabs.contains { $0 === tab } } }
        check(shown?.view.awaitsChoice == true && shownOwner !== c && shownOwner?.window?.isVisible == true
              && shownOwner?.activeTab === shown && NSApp.keyWindow === window,
              "arrival: show: another project's window comes forward with the tab selected, and the keyboard stays where it was",
              "key: \(NSApp.keyWindow?.title ?? "none"), owner: \(shownOwner?.window?.title ?? "none"), waits: \(shown?.view.awaitsChoice == true), "
                + "visible: \(shownOwner?.window?.isVisible == true), selected: \(shownOwner?.activeTab === shown)")
        if let shown { shownOwner?.remove(shown) }
        _ = await bringToFront(window)
        app.agentArrival = .focus
        let (focused, _) = await newTab(other.path)
        let focusedOwner = focused.flatMap { tab in app.controllers.first { $0.tabs.contains { $0 === tab } } }
        _ = await wait(3) { NSApp.keyWindow === focusedOwner?.window }
        check(NSApp.keyWindow === focusedOwner?.window && focusedOwner?.window?.firstResponder !== focused?.view
              && focused?.view.awaitsChoice == true,
              "arrival: focus: its window becomes the key window, and the tab still waits for a click",
              "key: \(NSApp.keyWindow?.title ?? "none"), first responder: \(String(describing: focusedOwner?.window?.firstResponder))")
        if let focused { focusedOwner?.remove(focused) }
        _ = await bringToFront(window)

        // The setting, through MCP (approved by a grant here).
        var set = MCPServer.CallResult(text: "", isError: false)
        MCPControl.call("settings_set", ["values": ["agents_bring_tabs_forward": "off"]], caller: nil, approval: .preApprovedByGrant("g-selftest")) { set = $0 }
        _ = await wait(10) { !set.text.isEmpty }
        check(app.agentArrival == .off, "arrival: settings_set changes agents_bring_tabs_forward", set.text)

        // The windows made here go before the checks after these count windows (they leave the list a moment later).
        for tab in opened { app.controllers.first { $0.tabs.contains { $0 === tab } }?.remove(tab) }
        opened = []
        if existing == nil { for tab in c.tabs { c.remove(tab) } }
        _ = await wait(3) { !app.controllers.contains { $0.hasClosed || (existing == nil && $0 === c) } }
    }
}
