import AppKit
import NextTermCore

/// View › Agent Spinner (and Settings › Notifications): how a terminal tab shows that its agent is working. The blue
/// ring turning (Spinning, as before), the same ring still, or no ring. Only the tab's own mark turns: in the tab bar,
/// the tab list, a split tab's pane headers, the » button and the terminal rail; ⌘O and the window column, lists looked
/// at rather than watched, keep it still. Off never hides the state: hovering the tab and
/// VoiceOver still say Working, and agents read it over MCP as before.
enum AgentSpinner: String, CaseIterable {
    case spinning, still, off

    static let key = "agentSpinner"
    /// Posted when the choice changes, or macOS's Reduce Motion or Increase Contrast does (DisplayOptions): every mark
    /// draws itself again.
    static let changed = Notification.Name("NextTermAgentSpinnerChanged")

    static var current: AgentSpinner {
        get { AgentSpinner(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .spinning }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    var title: String {
        switch self {
        case .spinning: return "Spinning"
        case .still: return "Still"
        case .off: return "Off"
        }
    }

    /// Whether the ring turns: Spinning, unless macOS's Reduce Motion is on (`reducesMotion`, for the self-test).
    static var turns: Bool { current == .spinning && !reducesMotion }
    static var reducesMotion: Bool { reducesMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// For the self-test: Reduce Motion as if set.
    static var reducesMotionOverride: Bool?

    /// A tab's title as shown: an agent's own spinner frame at its start (Claude Code turns one in its title while it
    /// works) left out unless the ring turns too, so Still and Off mean nothing on the tab moves.
    static func shown(_ title: String) -> String {
        turns ? title : AgentTitle.withoutSpinnerFrame(title)
    }

    /// Reduce Motion turned on or off in System Settings: the marks follow at once, not at their next change.
    static func followSystemMotion() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
                                                          queue: .main) { _ in
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}
