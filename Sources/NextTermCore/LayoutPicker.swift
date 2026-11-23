import Foundation

/// "How do you like to work?": a sheet of three layouts, shown once, over the Welcome window of a new install's first
/// launch, and from Settings › General › Choose a Layout… any time after. An install that has used Next Term before
/// never sees it by itself, on an update or any other launch.
public enum LayoutPicker {
    /// Stored once the sheet has shown by itself, whatever was chosen: it never shows by itself again.
    public static let shownKey = "layoutPickerShown"

    public static let title = "How do you like to work?"
    public static let footer = "After you start a coding agent, ask it to set Next Term up your way, or change it anytime in Settings."
    public static let skipTitle = "Skip"
    /// Settings › General's button.
    public static let settingsButtonTitle = "Choose a Layout…"

    /// The rule: never once shown, and never on an install used before.
    public static func shouldShow(shown: Bool, usedBefore: Bool) -> Bool {
        !shown && !usedBefore
    }

    /// Whether this launch shows it, read before the launch writes any of the keys that tell a new install from one used
    /// before (`SidebarClick.usedInstallKeys`).
    public static func isDue(in defaults: UserDefaults) -> Bool {
        let usedBefore = SidebarClick.usedInstallKeys.contains { defaults.object(forKey: $0) != nil }
        return shouldShow(shown: defaults.bool(forKey: shownKey), usedBefore: usedBefore)
    }

    /// Records that it showed, so it never shows by itself again.
    public static func markShown(in defaults: UserDefaults) {
        defaults.set(true, forKey: shownKey)
    }
}

/// The three layouts the picker offers, each a set of set_layout's fields applied together.
public enum LayoutPreset: String, CaseIterable, Sendable {
    case ide, terminal, agents

    public var name: String {
        switch self {
        case .ide: return "IDE"
        case .terminal: return "Terminal"
        case .agents: return "Agents"
        }
    }

    public var line: String {
        switch self {
        case .ide: return "Project folder on the left, terminal in the middle, windows on the right."
        case .terminal: return "Windows and project folder on the left, terminal on the right."
        case .agents: return "Project folder on the left, the terminal’s tabs listed down the side, windows on the right."
        }
    }

    /// What VoiceOver reads for its card.
    public var accessibilityLabel: String { "\(name) layout: \(line)" }

    /// set_layout's arguments, as an agent would send them.
    public var arguments: [String: String] {
        switch self {
        case .ide:
            return ["sidebar_side": "left", "window_column": "shown", "window_column_side": "right", "terminal_tabs": "top",
                    "terminal_position": "bottom"]
        case .terminal:
            return ["window_column": "shown", "window_column_side": "left", "sidebar_side": "left", "terminal_position": "right",
                    "terminal_tabs": "top"]
        case .agents:
            return ["sidebar_side": "left", "terminal_tabs": "left", "window_column": "shown", "window_column_side": "right",
                    "terminal_position": "bottom"]
        }
    }

    /// The change, through set_layout's own parsing, so every value is one it takes.
    public var change: MCPLayoutChange {
        (try? MCPLayoutChange.parse(arguments).get()) ?? MCPLayoutChange()
    }
}
