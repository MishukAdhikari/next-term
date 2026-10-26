import Foundation

/// The window column's two settings, one for every window: whether it shows (Settings › General, View › Hide Window
/// Column) and whether it is unfolded (⌃⌘S, View › Expand Window Column, its chevron). Kept in Next Term's own defaults.
public enum WindowColumnSettings {
    /// "Show the window column when two or more windows are open": on unless turned off, for new installs and for
    /// existing ones that never wrote it.
    public static let shownKey = "showWindowColumn"
    /// Unfolded in every window; folded, the default, until the user unfolds it.
    public static let expandedKey = "windowColumnExpanded"
    /// Posted when either changes, so Settings follows the View menu and the menu Settings.
    public static let changedName = "NextTermWindowColumnChanged"

    public static func shown(_ value: Any?) -> Bool { value as? Bool ?? true }
    public static func expanded(_ value: Any?) -> Bool { value as? Bool ?? false }

    /// Whether every window shows the column: with the setting on and two or more terminal windows open, counting the
    /// ones a restore is about to open (`expecting`), so a restored window has it from its first frame.
    public static func visible(shown: Bool, windows: Int, expecting: Int = 0) -> Bool {
        shown && windows + max(0, expecting) >= 2
    }

    /// set_layout's line in the window that asks the user, for showing or hiding it in every window. `key`: the key that
    /// brings it back (View › Show Window Column's, as the user has it), or nil when it has none.
    public static func approvalLine(shown: Bool, key: String?) -> String {
        if shown { return "The window column shows at the outer edge of every window while two or more are open: a badge for each window." }
        return "The window column is hidden in every window; View › Show Window Column\(keyNote(key)) or Settings › General brings it back."
    }

    /// set_layout's line for folding or unfolding it in every window.
    public static func approvalLine(folded: Bool) -> String {
        folded ? "The window column folds to a badge for each window, in every window."
            : "The window column unfolds in every window: a row for each window, with its name and its agents’ marks."
    }

    /// A notice when the key or the menu changes the setting while fewer than two windows are open, where nothing on
    /// the screen changes.
    public static func unseenLine(shown: Bool) -> String {
        shown ? "Window column on: it shows from two windows on." : "Window column off: no window will show it."
    }

    /// A notice when an agent changed it through a remote door's grant, which asks nothing on the Mac.
    public static func grantedLine(shown: Bool, key: String?) -> String {
        shown ? "An agent showed the window column\(keyNote(key, "; ", " hides it"))."
            : "An agent hid the window column\(keyNote(key, "; ", " brings it back"))."
    }

    /// " (⌃⇧⌘S)", or with `before` and `after`: "; ⌃⇧⌘S brings it back". Nothing without a key.
    static func keyNote(_ key: String?, _ before: String = " (", _ after: String = ")") -> String {
        guard let key, !key.isEmpty else { return "" }
        return before + key + after
    }
}

/// How the column shows in one window: hidden, folded to its badges or unfolded to its rows; how wide, with its hairline;
/// and whether the window's room decided it rather than the user's choice.
public struct WindowColumnShown: Equatable, Sendable {
    public enum Form: Equatable, Sendable {
        case hidden, folded, expanded
    }

    public let form: Form
    /// The strip's width and the hairline along its inner edge; 0 hidden.
    public let width: CGFloat
    /// Folded although the user unfolded it, or hidden, for want of room: the user's choice is kept, and comes back with
    /// the room.
    public let byRoom: Bool

    public init(form: Form, width: CGFloat, byRoom: Bool) {
        self.form = form
        self.width = width
        self.byRoom = byRoom
    }

    public static let hidden = WindowColumnShown(form: .hidden, width: 0, byRoom: false)
}

/// The window column's widths, and the room a window needs for it.
public enum WindowColumnWidth {
    /// Folded: 28-point places, a 22-point badge in each, room for two capitals and the dot at its corner.
    public static let folded: CGFloat = 28
    /// Unfolded: one row per window, its name, colour and marks.
    public static let expanded: CGFloat = 180
    /// Along the column's inner edge, as the sidebar's divider.
    public static let hairline: CGFloat = 1
    /// The badge in each place.
    public static let badge: CGFloat = 22
    /// The narrowest the editor and terminal beside it get, as beside the tab list.
    public static let workMinimum: CGFloat = TabListWidth.terminalMinimum

    /// The column in a window whose content is `contentWidth` across, unfolded or not as the user has it: unfolded while
    /// the work area keeps `workMinimum` beside the sidebar as it is (`sidebarWidth`, with its divider), so unfolding never
    /// narrows the sidebar; else folded while the work area keeps it beside a minimal sidebar (`minimalSidebar`, with its
    /// divider), as a narrowing window narrows the sidebar toward it; else hidden in this window only. Both are 0 while
    /// the sidebar is hidden. Folded or hidden for want of room is `byRoom`, so the user's choice is kept. A width not
    /// measured yet (0) decides nothing.
    public static func shown(contentWidth: CGFloat, sidebarWidth: CGFloat, minimalSidebar: CGFloat,
                             expanded wantsExpanded: Bool) -> WindowColumnShown {
        let foldedWidth: CGFloat = folded + hairline
        let expandedWidth: CGFloat = expanded + hairline
        guard contentWidth > 0 else {
            return wantsExpanded ? WindowColumnShown(form: .expanded, width: expandedWidth, byRoom: false)
                : WindowColumnShown(form: .folded, width: foldedWidth, byRoom: false)
        }
        if wantsExpanded, contentWidth - expandedWidth - max(0, sidebarWidth) >= workMinimum {
            return WindowColumnShown(form: .expanded, width: expandedWidth, byRoom: false)
        }
        if contentWidth - foldedWidth - max(0, minimalSidebar) >= workMinimum {
            return WindowColumnShown(form: .folded, width: foldedWidth, byRoom: wantsExpanded)
        }
        return WindowColumnShown(form: .hidden, width: 0, byRoom: true)
    }
}
