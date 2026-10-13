import Foundation

/// How wide the tab list is: dragged by its edge between 160 and 400 points, snapped to a 24-point column of marks
/// when dragged in past 120, and collapsed by itself when the terminal beside it would be too narrow. The user's own
/// collapse and the one for want of room are kept apart, so a window growing again never undoes the user's.
public enum TabListWidth {
    /// The project sidebar's minimum to a comfortable sidebar's widest.
    public static let range: ClosedRange<CGFloat> = 160...400
    /// The top bar's widest tab.
    public static let defaultWidth: CGFloat = 220
    /// The terminal rail's width.
    public static let collapsedWidth: CGFloat = 24
    /// A drag that leaves it narrower than this collapses it.
    public static let snapBelow: CGFloat = 120
    /// The narrowest the terminal beside it gets, as beside the editor.
    public static let terminalMinimum: CGFloat = 240
    /// Where the width last set in any window is kept: a new window starts there.
    public static let lastKey = "tabListWidth"

    /// A width the list can have; anything not a width at all is the first one.
    public static func clamp(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultWidth }
        return min(range.upperBound, max(range.lowerBound, width))
    }

    /// Where a drag of the edge leaves the list. Collapsed, it keeps the width it had for when it opens again.
    public enum Drag: Equatable, Sendable {
        case collapsed
        case width(CGFloat)
    }

    /// The list as a drag leaves it at `width`: collapsed under `snapBelow`, else within `range`. Shown live while
    /// the edge moves, and kept when it is let go.
    public static func afterDrag(_ width: CGFloat) -> Drag {
        width < snapBelow ? .collapsed : .width(clamp(width))
    }

    /// The list as a drag leaves it: pressed at `pressWidth` (the collapsed width when it was collapsed), the
    /// pointer moved `dx` across, rightward positive. The side says which way widens it.
    public static func dragged(from pressWidth: CGFloat, by dx: CGFloat, side: TabListSide) -> Drag {
        let width: CGFloat = pressWidth + side.widthChange(pointerMoved: dx)
        return afterDrag(width)
    }

    /// A double-click on the edge, or Collapse Tab List and Expand Tab List: collapsed if it shows open, open if it
    /// shows collapsed, at the width it had. It acts on what shows, so on a list collapsed for want of room it asks
    /// for the list to open once there is room.
    public static func toggled(width: CGFloat, shownCollapsed: Bool) -> (width: CGFloat, collapsed: Bool) {
        (clamp(width), !shownCollapsed)
    }

    /// The list as it shows: its width, collapsed or not, and whether for want of room.
    public struct Shown: Equatable, Sendable {
        public var width: CGFloat
        public var collapsed: Bool
        public var byRoom: Bool

        public init(width: CGFloat, collapsed: Bool, byRoom: Bool) {
            self.width = width
            self.collapsed = collapsed
            self.byRoom = byRoom
        }
    }

    /// The list as it shows in a terminal pane `paneWidth` across (the list and the terminal together), at the
    /// user's `width`: collapsed when the user collapsed it, or when the terminal would be left narrower than
    /// `terminalMinimum`; open again once there is room. A pane not measured yet (hidden, or not laid out) decides
    /// nothing: the list never collapses for want of room it has not measured.
    public static func shown(paneWidth: CGFloat, width: CGFloat, userCollapsed: Bool,
                             terminalMinimum: CGFloat = TabListWidth.terminalMinimum) -> Shown {
        if userCollapsed { return Shown(width: collapsedWidth, collapsed: true, byRoom: false) }
        let open: CGFloat = clamp(width)
        guard paneWidth > 0, paneWidth - open < terminalMinimum else { return Shown(width: open, collapsed: false, byRoom: false) }
        return Shown(width: collapsedWidth, collapsed: true, byRoom: true)
    }

    /// The width last set anywhere, as kept: nothing kept (UserDefaults reads a missing number as 0), or nothing
    /// that is a width, is the first one.
    public static func stored(_ value: Double?) -> CGFloat {
        guard let value, value.isFinite, value > 0 else { return defaultWidth }
        return clamp(CGFloat(value))
    }

    /// Which way the edge's resize cursor points: both ways between the ends (in from 160 still collapses it), only
    /// toward the terminal while collapsed, only away from it at the widest.
    public static func cursor(width: CGFloat, collapsed: Bool, side: TabListSide) -> TabListCursor {
        let widens: TabListCursor = side.terminalIsLeft ? .left : .right
        let narrows: TabListCursor = side.terminalIsLeft ? .right : .left
        if collapsed { return widens }
        return width >= range.upperBound ? narrows : .leftRight
    }
}

/// The resize cursor over the list's edge.
public enum TabListCursor: Equatable, Sendable {
    case leftRight, left, right
}

/// Each project's tab list width and whether it is collapsed, kept under the project's folder (canonical) across
/// launches. Only the edge and the collapse commands set one: minimising, full screen and resizing the window never
/// do, so nothing resets it. The least recently set go first past `limit`.
public struct TabListWidths: Equatable, Sendable {
    /// Where they are kept.
    public static let key = "tabListWidths"
    public static let limit = 50

    public struct Entry: Equatable, Sendable {
        public var width: CGFloat
        public var collapsed: Bool
        /// When it was set, in seconds on any one clock (the caller's): the oldest goes first.
        public var setAt: Double

        public init(width: CGFloat, collapsed: Bool, setAt: Double) {
            self.width = width
            self.collapsed = collapsed
            self.setAt = setAt
        }
    }

    public private(set) var entries: [String: Entry]

    public init(_ entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /// As kept in preferences: a dictionary from folder to `width`, `collapsed` and `setAt`. What is not an entry
    /// (not a dictionary, or no width that is a number) is left out; a width out of range reads back in range.
    public init(propertyList: Any?) {
        var entries: [String: Entry] = [:]
        for (folder, value) in propertyList as? [String: Any] ?? [:] {
            guard let fields = value as? [String: Any], let width = (fields["width"] as? NSNumber)?.doubleValue, width.isFinite else { continue }
            let collapsed: Bool = fields["collapsed"] as? Bool ?? false
            let setAt: Double = (fields["setAt"] as? NSNumber)?.doubleValue ?? 0
            entries[folder] = Entry(width: TabListWidth.clamp(CGFloat(width)), collapsed: collapsed, setAt: setAt)
        }
        self.entries = entries
    }

    /// To keep in preferences.
    public var propertyList: [String: Any] {
        var list: [String: Any] = [:]
        for (folder, entry) in entries {
            let fields: [String: Any] = ["width": Double(entry.width), "collapsed": entry.collapsed, "setAt": entry.setAt]
            list[folder] = fields
        }
        return list
    }

    public func entry(for folder: String) -> Entry? { entries[folder] }

    /// With `folder` set to `width` (brought into range) and `collapsed`, at `now`; past `limit`, the least
    /// recently set go.
    public func setting(width: CGFloat, collapsed: Bool, for folder: String, now: Double) -> TabListWidths {
        var kept = entries
        kept[folder] = Entry(width: TabListWidth.clamp(width), collapsed: collapsed, setAt: now)
        guard kept.count > Self.limit else { return TabListWidths(kept) }
        let oldestFirst: [String] = kept.keys.sorted { first, second in
            let a: Double = kept[first]?.setAt ?? 0
            let b: Double = kept[second]?.setAt ?? 0
            return a == b ? first < second : a < b
        }
        for folder in oldestFirst.prefix(kept.count - Self.limit) { kept[folder] = nil }
        return TabListWidths(kept)
    }

    /// Without the folders that are gone.
    public func pruned(exists: (String) -> Bool) -> TabListWidths {
        TabListWidths(entries.filter { exists($0.key) })
    }

    /// Where a window for `folder` starts: as the folder had it, else open at `last`, the width last set in any
    /// window (as kept under `TabListWidth.lastKey`), else 220. A window with no project starts as a new one.
    public func start(for folder: String?, last: Double?) -> (width: CGFloat, collapsed: Bool) {
        if let folder, let entry = entries[folder] { return (entry.width, entry.collapsed) }
        return (TabListWidth.stored(last), false)
    }
}
