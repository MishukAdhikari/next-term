import AppKit
import NextTermCore

/// When the user last pressed a key in Next Term, in any of its windows (TerminalWindow.sendEvent, and the app's own
/// key monitor for Settings, panels and the Welcome window): the typing an agent's window waits out (AgentArrival).
enum UserKeys {
    nonisolated(unsafe) private static var last: TimeInterval = 0

    static func pressed() { last = ProcessInfo.processInfo.systemUptime }

    /// Seconds since the last key.
    static var since: TimeInterval {
        #if DEBUG
        if ignoredForTest { return .infinity }
        #endif
        return ProcessInfo.processInfo.systemUptime - last
    }

    #if DEBUG
    /// For the self-test, whose own keys would hold every window back.
    nonisolated(unsafe) static var ignoredForTest = false
    #endif
}

extension TerminalWindowController {
    /// The window the user is working in: Next Term's key or main window while it is the app in front, else the window
    /// they went to last (they come back to it, and the tab they left in front).
    var hasUsersKeyboard: Bool {
        if NSApp.isActive { return window?.isKeyWindow == true || window?.isMainWindow == true }
        return AppDelegate.shared.lastUsedController === self
    }

    /// An agent opened `tab` over MCP (nil: the window itself, a file in its editor, or a pane beside the user's): it comes
    /// forward as Settings › Editor › "When an agent opens a tab" says (AgentArrival), never with the keyboard. The tab
    /// was made waiting for the user's choice (`byAgent`). Returns what the tool's answer says: whether the tab was
    /// selected, and why it stayed where it was. The window may come forward later, once the user stops typing.
    /// `explicit`: the agent asked to show it (show_tab, open_project). `login`: ssh asks for a password in it.
    @discardableResult
    func presentForAgent(_ tab: TerminalTab?, explicit: Bool = false, login: Bool = false) -> (selected: Bool, note: String?) {
        let first = arrive(tab, explicit: explicit, login: login, waited: 0, selected: false)
        return (first.selected || tab.map { activeTab === $0 } == true, first.note)
    }

    @discardableResult
    private func arrive(_ tab: TerminalTab?, explicit: Bool, login: Bool, waited: TimeInterval, selected: Bool) -> (selected: Bool, note: String?) {
        guard let window else { return (false, nil) }
        if let tab, !tabs.contains(where: { $0 === tab }) { return (false, nil) } // closed meanwhile
        let plan = AgentArrival.plan(mode: AppDelegate.shared.agentArrival, explicit: explicit, login: login, hasTab: tab != nil,
                                     usersWindow: hasUsersKeyboard, appActive: NSApp.isActive,
                                     onActiveSpace: !window.isVisible || window.isOnActiveSpace, sheetUp: window.attachedSheet != nil,
                                     modalUp: NSApp.modalWindow != nil, sinceKey: UserKeys.since, waited: waited)
        var selected = selected
        if plan.select, !selected, let tab {
            show(tab, arming: false)
            selected = true
        }
        if let again = plan.again {
            DispatchQueue.main.asyncAfter(deadline: .now() + again) { [weak self] in
                self?.arrive(tab, explicit: explicit, login: login, waited: waited + again, selected: selected)
            }
            return (selected, plan.note)
        }
        raise(plan.raise)
        return (selected, plan.note)
    }

    private func raise(_ raise: AgentArrival.Raise) {
        guard let window else { return }
        if raise != .none, window.isMiniaturized { window.deminiaturize(nil) }
        // A terminal hidden behind the tab now in front keeps no keyboard for the window to give it.
        if raise != .none, let terminal = window.firstResponder as? NSView, terminal is NextTermView, terminal.isHiddenOrHasHiddenAncestor {
            window.makeFirstResponder(nil)
        }
        switch raise {
        case .none:
            // A window opened for the agent and left where it is: on screen, behind the one in use.
            if !window.isVisible {
                if let key = NSApp.keyWindow { window.order(.below, relativeTo: key.windowNumber) } else { window.orderFront(nil) }
            }
        case .orderFront:
            window.orderFront(nil)
        case .makeKey:
            keyingForAgent = true
            window.makeKeyAndOrderFront(nil)
            keyingForAgent = false
        case .attention:
            window.orderFront(nil) // in front of Next Term's own windows, never over the app in use
            NSApp.requestUserAttention(.informationalRequest)
        }
    }
}
