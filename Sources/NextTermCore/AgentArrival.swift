import Foundation

/// A tab or window an agent opened over MCP (new_tab, new_remote_tab, split_pane, open_project, show_tab,
/// open_in_editor): how it comes forward. The window comes to the front, and in `focus` mode becomes the key window,
/// but no terminal an agent opened ever takes the keyboard until the user clicks it or chooses it: a key, or a
/// Return, meant for the tab they were typing in never lands in an agent's prompt (a trust question it may be showing).
///
/// Never over what the user is doing:
/// - In the window the user is working in, a new tab opens behind theirs (the tab bar shows it), unless it is ssh asking
///   for a password, which they must see.
/// - While the user types in Next Term, the window waits until they stop (`typingQuiet`), at most `typingPatience`,
///   then comes forward without becoming key.
/// - From another app, Next Term asks for attention (the Dock icon bounces once) instead of coming over it.
/// - A window on another Space is not pulled over; a modal alert is waited for; a sheet keeps its tab where it is.
public enum AgentArrival {
    /// Settings › Editor › "When an agent opens a tab" (MCP: agents_bring_tabs_forward).
    public enum Mode: String, CaseIterable, Sendable {
        /// Its window comes forward and becomes the key window (the tab still waits for a click).
        case focus
        /// Its window comes forward; the keyboard stays where it is.
        case show
        /// Tabs open in the background, windows stay where they are.
        case off
    }

    public enum Raise: Equatable, Sendable {
        case none
        /// In front of Next Term's other windows; the key window stays the key window.
        case orderFront
        /// In front, and the key window (focus).
        case makeKey
        /// Next Term is not the app in front: the window comes forward among Next Term's, and the Dock icon bounces once.
        case attention
    }

    public struct Plan: Equatable, Sendable {
        /// Select the tab in its window (never with the keyboard).
        public var select: Bool
        public var raise: Raise
        /// Ask again after this many seconds (the user is typing, or a modal alert is up); nil: done.
        public var again: TimeInterval?
        /// For the tool's answer, when the tab or window did not come forward.
        public var note: String?

        public init(select: Bool, raise: Raise, again: TimeInterval? = nil, note: String? = nil) {
            self.select = select
            self.raise = raise
            self.again = again
            self.note = note
        }
    }

    /// A key pressed in Next Term this recently means the user is typing: no window comes forward over them yet.
    public static let typingQuiet: TimeInterval = 1.5
    /// How long a window waits for the typing to stop before it comes forward without the keyboard.
    public static let typingPatience: TimeInterval = 8
    /// How often a waiting window asks again.
    public static let tick: TimeInterval = 0.25

    /// - Parameters:
    ///   - explicit: the agent asked to show it (show_tab, open_project): it comes forward even when `mode` is off.
    ///   - login: ssh is asking for a password or a host key in it: it is selected even in the user's window.
    ///   - hasTab: a tab to select (nil for open_project, a pane beside the user's, a file in the editor).
    ///   - usersWindow: Next Term is the app in front and this is its key or main window.
    ///   - sinceKey: seconds since the user last pressed a key in Next Term.
    ///   - waited: seconds this arrival has waited so far.
    public static func plan(mode: Mode, explicit: Bool = false, login: Bool = false, hasTab: Bool, usersWindow: Bool,
                            appActive: Bool, onActiveSpace: Bool, sheetUp: Bool, modalUp: Bool,
                            sinceKey: TimeInterval, waited: TimeInterval = 0) -> Plan {
        let mode: Mode = (explicit || login) && mode == .off ? .show : mode
        if modalUp { return Plan(select: false, raise: .none, again: tick) } // over an alert the user is answering: after it
        let select = hasTab && mode != .off && !sheetUp && (!usersWindow || login)
        guard mode != .off else { return Plan(select: false, raise: .none) }
        if usersWindow {
            let note = hasTab && !select && !login
                ? "It is in the window the user is working in, so it opened behind their tab; focus_tab asks to give it the keyboard."
                : nil
            return Plan(select: select, raise: .none, note: note)
        }
        guard onActiveSpace else {
            return Plan(select: select, raise: appActive ? .none : .attention,
                        note: "Its window is on another Space, so it was not brought forward.")
        }
        guard appActive else { return Plan(select: select, raise: .attention) }
        if sinceKey < typingQuiet {
            if waited < typingPatience { return Plan(select: select, raise: .none, again: max(tick, typingQuiet - sinceKey)) }
            return Plan(select: select, raise: .orderFront) // still typing: in front, without the keyboard
        }
        return Plan(select: select, raise: mode == .focus ? .makeKey : .orderFront)
    }
}
