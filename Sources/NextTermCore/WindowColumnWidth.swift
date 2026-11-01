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
        if shown { return "The window column shows at the outer edge of every window while two or more are open: a dot for each window." }
        return "The window column is hidden in every window; View › Show Window Column\(keyNote(key)) or Settings › General brings it back."
    }

    /// set_layout's line for folding or unfolding it in every window.
    public static func approvalLine(folded: Bool) -> String {
        folded ? "The window column folds to its rail, a dot for each window, in every window."
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
    /// Folded to its rail: 24 points, as the folded terminal's, a dot for each window (WindowColumnRail).
    public static let folded: CGFloat = 24
    /// Unfolded: one row per window, its name, colour and marks.
    public static let expanded: CGFloat = 180
    /// Along the column's inner edge, as the sidebar's divider.
    public static let hairline: CGFloat = 1
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

/// The folded column's rail and the list it shows on hover (plan 030): the window count under the traffic lights, a dot
/// per window in its project's colour, a mark only where a window needs you or failed. Resting the pointer on it slides
/// the list out over the content after `openDelay`; leaving the rail and the list for `closeDelay` slides it back.
public enum WindowColumnRail {
    /// A window's place on the rail, as a tab's on the folded terminal's.
    public static let slot: CGFloat = 24
    /// A window's dot.
    public static let dot: CGFloat = 8
    /// How long the pointer rests on the rail before the list opens: passing over it opens nothing.
    public static var openDelay: TimeInterval = 0.35
    /// How long the pointer is off the rail and the list before the list goes.
    public static var closeDelay: TimeInterval = 0.3
    /// The hovering list's width: the unfolded column's. It covers the rail, so its dots are the rail's.
    public static var listWidth: CGFloat { WindowColumnWidth.expanded }

    /// Where a bar beside the traffic lights may start: `gap` points past the zoom button's right edge (in the window's
    /// coordinates), and never before `minimum`. The lights' place changes with the macOS release, so it is measured, not
    /// assumed; 16 points keeps the tab bar's first button (⌘B's) clear of the green light (69 on macOS 26: 85).
    public static func lightsEnd(zoomMaxX: CGFloat?, gap: CGFloat = 16, minimum: CGFloat = 78) -> CGFloat {
        guard let zoomMaxX, zoomMaxX > 0 else { return minimum }
        return max(minimum, ceil(zoomMaxX + gap))
    }
}

/// One grid for the rail, the list on hover and the pinned column (plan 031): every dot, the count and this window's well
/// sit at the same place in the window in all three, so opening, pinning or folding moves no dot, and only names come or
/// go beside them. In a strip's own points, the hairline left out: the strip is `WindowColumnWidth.folded` across on the
/// rail, `WindowColumnWidth.expanded` unfolded, its dot column at the window's outer edge.
public enum WindowColumnGrid {
    /// A row: the rail's place for a window.
    public static var row: CGFloat { WindowColumnRail.slot }
    /// The dot column: the rail's width, a dot in its middle.
    public static var dotColumn: CGFloat { WindowColumnWidth.folded }
    /// Above the first row and under the last.
    public static let margin: CGFloat = 4
    /// The title bar's strip: the tab bars' height.
    public static let titleStrip: CGFloat = 38
    /// The count's row under the traffic lights, under the title bar's strip.
    public static let countRow: CGFloat = 22
    /// The foot's row, kept in every form, so the rail and the list run out of room at the same place.
    public static let foot: CGFloat = 24
    /// Where a name starts past the dot column, and how much further in a nested worktree's goes (the tab list's pane
    /// indent).
    public static let nameGap: CGFloat = 4
    public static let indent: CGFloat = 14
    /// On the right, where a name starts from the strip's inner edge.
    public static let innerName: CGFloat = 12
    /// The trailing column's end before the strip's outer edge on the left.
    public static let trailingInset: CGFloat = 8
    /// The row's plate (this window's well, a hover): in from the strip's two edges, as tall as the rail's well, round.
    public static let plateInset: CGFloat = 3
    public static let plate: CGFloat = 18
    public static let plateRadius: CGFloat = 7

    /// The dot column's left edge in a strip `width` across: at the outer edge, the left one unless `onRight`.
    public static func dotColumnX(width: CGFloat, onRight: Bool) -> CGFloat { onRight ? max(0, width - dotColumn) : 0 }

    /// Where a row's name starts, `depth` deep: past the dot column on the left; from the inner edge on the right.
    public static func nameX(width: CGFloat, onRight: Bool, depth: Int) -> CGFloat {
        (onRight ? innerName : dotColumn + nameGap) + CGFloat(max(0, depth)) * indent
    }

    /// Where the trailing column (the marks, a key) ends: before the outer edge on the left; before the dot column on
    /// the right.
    public static func trailingEnd(width: CGFloat, onRight: Bool) -> CGFloat {
        onRight ? dotColumnX(width: width, onRight: true) - nameGap : width - trailingInset
    }

    /// The count's row: under the title bar's strip while the traffic lights are over it (`topInset`), else the top row
    /// with the tab bars. The first row comes `margin` under it.
    public static func countTop(topInset: CGFloat) -> CGFloat { topInset > 0 ? topInset : 0 }
    public static func countHeight(topInset: CGFloat) -> CGFloat { topInset > 0 ? countRow : titleStrip }
    public static func rowsTop(topInset: CGFloat) -> CGFloat { countTop(topInset: topInset) + countHeight(topInset: topInset) }

    /// A row's plate, in a row `width` across and `height` tall: the well round the dot on the rail, the pill unfolded.
    public static func plateRect(width: CGFloat, height: CGFloat, rail: Bool, onRight: Bool) -> CGRect {
        let y: CGFloat = ((height - plate) / 2).rounded()
        if rail {
            let x: CGFloat = dotColumnX(width: width, onRight: onRight) + ((dotColumn - plate) / 2).rounded()
            return CGRect(x: x, y: y, width: plate, height: plate)
        }
        return CGRect(x: plateInset, y: y, width: max(0, width - 2 * plateInset), height: plate)
    }

    /// A row's dot, in the middle of the dot column.
    public static func dotRect(width: CGFloat, height: CGFloat, onRight: Bool) -> CGRect {
        let size: CGFloat = WindowColumnRail.dot
        let x: CGFloat = dotColumnX(width: width, onRight: onRight) + ((dotColumn - size) / 2).rounded()
        return CGRect(x: x, y: ((height - size) / 2).rounded(), width: size, height: size)
    }
}
