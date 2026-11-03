import Foundation

/// The window column's two settings, one for every window: whether it shows (Settings › General, View › Hide Window
/// Column) and whether it is unfolded (⌃⌘S, View › Expand Window Column, its chevron). Kept in Next Term's own defaults.
public enum WindowColumnSettings {
    /// "Show the window column when two or more windows are open": on unless turned off, for new installs and for
    /// existing ones that never wrote it.
    public static let shownKey = "showWindowColumn"
    /// Unfolded in every window; folded, the default, until the user unfolds it.
    public static let expandedKey = "windowColumnExpanded"
    /// The repositories whose worktrees' windows are folded into their row, in every window: their rows' fold keys.
    public static let foldedKey = "windowColumnFolded"
    /// The unfolded width the user dragged it to; none, the default.
    public static let widthKey = "windowColumnWidth"
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
    /// Unfolded: one row per window, its name, colour and marks. As wide as the user dragged it (Settings' `widthKey`),
    /// `defaultExpanded` until then, the same in every window and for the list on hover.
    public static var expanded: CGFloat = defaultExpanded
    public static let defaultExpanded: CGFloat = 180
    /// How narrow and how wide a drag can make it.
    public static let expandedRange: ClosedRange<CGFloat> = 140...360

    /// `width` within `expandedRange`, whole points; a width never set (0) is the default.
    public static func expandedWidth(_ width: CGFloat) -> CGFloat {
        guard width > 0 else { return defaultExpanded }
        return min(max(width.rounded(.down), expandedRange.lowerBound), expandedRange.upperBound)
    }
    /// Where a drag of the pinned column's edge leaves it (plan 033): unfolded at a width, or folded to the rail.
    public enum Dragged: Equatable, Sendable {
        case unfolded(CGFloat)
        case folded
    }

    /// Dragged in to this width or less, the column snaps folded, as a macOS sidebar collapses: half its narrowest.
    public static let foldSnap: CGFloat = expandedRange.lowerBound / 2

    /// A drag's proposed width, as the column takes it: at or under `foldSnap` folded; between it and the narrowest,
    /// held at the narrowest (the deliberate hold before the snap); else within `expandedRange`, whole points. Stateless,
    /// so dragging back out in the same drag unfolds it again.
    public static func dragged(_ proposed: CGFloat) -> Dragged {
        guard proposed > foldSnap else { return .folded }
        let whole: CGFloat = proposed.rounded(.down)
        let floor: CGFloat = max(whole, expandedRange.lowerBound)
        return .unfolded(min(floor, expandedRange.upperBound))
    }

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
    /// A window's place on the rail and its row in the list: 32 points, a macOS 26 sidebar's row, so a row is easy to hit
    /// (the owner's "the click feeling"). The rail stays 24 points wide.
    public static let slot: CGFloat = 32
    /// A window's dot.
    public static let dot: CGFloat = 8
    /// How long the pointer rests on the rail, moving no more than `restRadius`, before the list opens: passing over it,
    /// or moving along it, opens nothing (the Dock opens the same way, after the pointer stops for 0.2 seconds).
    public static var openDelay: TimeInterval = 0.15
    /// How far the pointer may drift and still be resting.
    public static let restRadius: CGFloat = 5
    /// A list closed this recently opens again at once when the pointer comes back onto the rail: a slip off the edge
    /// costs no wait.
    public static var warmDelay: TimeInterval = 0.8
    /// How long the pointer is off the rail and the list before the list goes: room to overshoot its edge.
    public static var closeDelay: TimeInterval = 0.4
    /// A few seconds after the pointer leaves the rail, its dots settle to a trace (`settledOpacity`), faded over
    /// `settleDuration`, so a rail at rest all but goes; a mark that needs you stays whole.
    public static var settleDelay: TimeInterval = 3
    public static let settleDuration: TimeInterval = 1
    public static let settledOpacity: Float = 0.3
    /// How long the list takes to come out, and to go back.
    public static let openDuration: TimeInterval = 0.12
    public static let closeDuration: TimeInterval = 0.1
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
    /// The foot, kept in every form, so the rail and the list run out of room at the same place: on the rail the hide key
    /// stands in it top to bottom, a key to a line; unfolded, its last row says "Hide Column" with the key.
    public static let foot: CGFloat = 48
    /// Where a name starts past the dot column, and how much further in a nested worktree's goes (the tab list's pane
    /// indent). Its guide runs down beside the nested names, `guideX` from the name's start.
    public static let nameGap: CGFloat = 4
    public static let indent: CGFloat = 14
    public static let guideX: CGFloat = 5
    /// On the right, where a name starts from the strip's inner edge.
    public static let innerName: CGFloat = 12
    /// The trailing column's end before the strip's outer edge on the left.
    public static let trailingInset: CGFloat = 8
    /// The row's plate (this window's well, a hover): unfolded a pill in from the strip's two edges, `pill` tall; on the
    /// rail, a well `plate` square round the dot, as wide as the 24-point rail allows.
    public static let plateInset: CGFloat = 2
    public static let plate: CGFloat = 20
    public static let pill: CGFloat = 24
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
        if rail {
            let x: CGFloat = dotColumnX(width: width, onRight: onRight) + ((dotColumn - plate) / 2).rounded()
            return CGRect(x: x, y: ((height - plate) / 2).rounded(), width: plate, height: plate)
        }
        return CGRect(x: plateInset, y: ((height - pill) / 2).rounded(), width: max(0, width - 2 * plateInset), height: pill)
    }

    /// A row's dot, in the middle of the dot column.
    public static func dotRect(width: CGFloat, height: CGFloat, onRight: Bool) -> CGRect {
        let size: CGFloat = WindowColumnRail.dot
        let x: CGFloat = dotColumnX(width: width, onRight: onRight) + ((dotColumn - size) / 2).rounded()
        return CGRect(x: x, y: ((height - size) / 2).rounded(), width: size, height: size)
    }
}
