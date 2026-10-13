import Foundation

/// Where a window's terminal tabs show: along the top, in the terminal's bar, or as a list inside the terminal
/// area, under that bar, at the terminal's left or right. View › Terminal Tabs, the terminal's ⋯ menu, Settings ›
/// Terminal › Tabs and set_layout's terminal_tabs. Every window has the same, and nothing else in the window moves.
public enum TerminalTabsSetting: String, CaseIterable, Sendable {
    case top, left, right

    /// Where the choice is kept.
    public static let key = "terminalTabs"

    /// As stored: anything else, or nothing, is the top, the default.
    public init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .top }

    public var title: String { rawValue.capitalized }

    /// The side of the terminal the list sits on; nil while the tabs are in the bar.
    public var listSide: TabListSide? {
        switch self {
        case .top: return nil
        case .left: return .left
        case .right: return .right
        }
    }

    /// What the user reads before an agent's set_layout moves the tabs here.
    public var approvalLine: String {
        guard listSide != nil else { return "Terminal tabs move back to the top, in every window." }
        return "Terminal tabs move to a list on the \(rawValue), in every window."
    }
}
