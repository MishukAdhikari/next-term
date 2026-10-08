import Foundation

/// Who answers Tab at a shell prompt (Settings › Terminal › Tab completion).
enum TabCompletionMode: String, CaseIterable {
    /// Next Term's popup, unless a plugin owns Tab; then Next Term asks once.
    case auto
    /// Next Term's popup wherever the hook is, with no question.
    case nextTerm
    /// The shell's own Tab, as before.
    case off

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .nextTerm: return "Next Term"
        case .off: return "Off"
        }
    }
}

/// Tab completion's settings, for this Mac. A shell loads the hook only when Tab completion is on as it starts:
/// turning it on reaches new tabs; turning it off works at once everywhere (the window stops converting Tab).
enum CompletionPreferences {
    static let modeKey = "tabCompletion"

    /// An unknown stored value reads as Auto.
    static var mode: TabCompletionMode {
        get { UserDefaults.standard.string(forKey: modeKey).flatMap(TabCompletionMode.init(rawValue:)) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    static var isOn: Bool { mode != .off }
}
