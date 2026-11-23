import AppKit
import NextTermCore

/// A remote tab on your own server (U15): where ssh asks for a login that Remote access can't give itself (R47), and
/// where "Set up Caddy" types the commands the user confirmed (R48). It goes through the remote tabs' own path, so
/// ssh asks the user there about a password, a passphrase or a host key, and nothing is typed into it until the
/// server's shell is at its prompt. A plain ssh shell whatever the host keeps (tmux, herdr): no session is left on
/// the server, and the prompt it waits for is the shell's.
@MainActor
enum RemoteAccessServerTab {
    /// The tab logging in to the host already, else a new one. `inFront`: selected, its window forward and Next Term
    /// active, for a click the user just made. Otherwise added beside the selected tab and left unselected, so what
    /// the user is typing in Next Term never goes to it.
    static func open(_ host: RemoteHost, inFront: Bool = true) -> TerminalTab {
        if let asking = RemoteConnection.loginTab(for: host), let owner = MCPControl.controller(of: asking) {
            if inFront { show(asking, in: owner) }
            return asking
        }
        let app: AppDelegate = AppDelegate.shared
        let front = NSApp.keyWindow?.windowController as? TerminalWindowController
        let controller = front ?? app.controllers.first ?? app.openWindow(directory: nil)
        let tab = controller.addRemoteTab(RemoteTab(host: host, keep: .off), select: inFront)
        if inFront { show(tab, in: controller) }
        return tab
    }

    private static func show(_ tab: TerminalTab, in controller: TerminalWindowController) {
        controller.show(tab)
        controller.refresh()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The tab is still in one of Next Term's windows.
    static func isOpen(_ tab: TerminalTab) -> Bool {
        let app: AppDelegate = AppDelegate.shared
        return app.controllers.contains { controller in controller.tabs.contains { $0 === tab } }
    }

    /// The server's shell is at its prompt in the tab, with its own login through, so a line typed there goes to
    /// that shell and never to ssh asking.
    static func canType(_ tab: TerminalTab) -> Bool {
        guard isOpen(tab), !tab.exited, !tab.disconnected, tab.view.acceptsInput else { return false }
        return tab.remoteConnected && tab.remoteReady
    }

    /// Types `line`, literally, and then Return, once the tab can take it; `done(false)` with nothing typed when it
    /// can't within `seconds` (the user may be logging in there meanwhile) or the tab ended first.
    static func type(_ line: String, into tab: TerminalTab, within seconds: TimeInterval,
                     done: @escaping @MainActor (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(seconds)
        waitForPrompt(tab, until: deadline) { ready in
            guard ready else { return done(false) }
            tab.view.typeIn(line)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated {
                    // The connection may have dropped in between: Return would then reconnect, not run the line.
                    guard canType(tab) else { return done(false) }
                    tab.view.send(txt: "\r")
                    done(true)
                }
            }
        }
    }

    private static func waitForPrompt(_ tab: TerminalTab, until deadline: Date,
                                      _ body: @escaping @MainActor (Bool) -> Void) {
        if canType(tab) { return body(true) }
        if !isOpen(tab) || tab.exited || Date() >= deadline { return body(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated { waitForPrompt(tab, until: deadline, body) }
        }
    }
}
