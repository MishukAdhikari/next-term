import Foundation

/// Where the terminal sits relative to the editor: View › Terminal Position, the terminal's ⋯ menu and Settings ›
/// Terminal › Position. Every window has the same.
public enum TerminalPosition: String, CaseIterable, Sendable {
    case bottom, right, left, top

    /// As stored: anything else, or nothing, is the bottom, the default.
    public init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .bottom }

    public var title: String { rawValue.capitalized }

    /// Beside the editor, left or right of it, rather than above or below it.
    public var sideBySide: Bool { self == .left || self == .right }

    /// Before the editor along the split: left of it, or above it.
    public var terminalFirst: Bool { self == .left || self == .top }

    /// Whether a window laid out with the terminal at `laidOut` (nil: never laid out) lays its work area out
    /// again for this position: the terminal unfolded and the divider at the editor's share. Only a new
    /// position does; the same one chosen again, or the sidebar moved to its other side, leaves a folded
    /// terminal folded and the divider where it is.
    public func relaysWork(from laidOut: TerminalPosition?) -> Bool { laidOut != self }

    /// With no file open the editor is hidden and the terminal fills the work area, so a position chosen then
    /// shows nothing yet: this says what it does once a file opens.
    public var noticeWithNoFileOpen: String { "The terminal moves to the \(rawValue) when a file is open" }
}

/// How much of the work area the editor gets, the terminal having the rest. One is kept for the terminal beside
/// the editor and one for it above or below: a width dragged with the terminal on the right says nothing about a
/// height with it at the bottom.
public enum EditorShare {
    /// Before anything is dragged.
    public static let standard: CGFloat = 0.62
    /// What can be kept: neither pane takes nearly all of the work area.
    public static let range: ClosedRange<CGFloat> = 0.15...0.9
    /// Where one share was kept for both before each had its own: read for one that has none of its own yet.
    public static let sharedKey = "editorFraction"

    /// Where the share for the terminal beside the editor, or above or below it, is kept.
    public static func key(sideBySide: Bool) -> String { sideBySide ? "editorFractionSideBySide" : "editorFractionStacked" }

    /// Every key a share is kept under.
    public static var keys: [String] { [sharedKey, key(sideBySide: true), key(sideBySide: false)] }

    /// The share to lay out with: the orientation's own, else the one kept for both before, else the standard.
    /// A value out of `range` counts as none.
    public static func share(own: Double?, shared: Double?) -> CGFloat {
        for value in [own, shared] {
            guard let value else { continue }
            let share = CGFloat(value)
            if range.contains(share) { return share }
        }
        return standard
    }

    /// A share to keep, brought into `range`.
    public static func kept(_ share: CGFloat) -> CGFloat { min(range.upperBound, max(range.lowerBound, share)) }

    /// The editor's length along a work area `length` long, the divider's `thickness` in it, for `share`, held so
    /// that neither pane goes under its minimum: a share kept in a bigger window never squeezes either pane in
    /// a smaller one. With no room for both minimums, neither can be had: the share as it is.
    public static func editorLength(share: CGFloat, of length: CGFloat, thickness: CGFloat,
                                    editorMinimum: CGFloat, terminalMinimum: CGFloat) -> CGFloat {
        let wanted: CGFloat = (length * share).rounded()
        let most: CGFloat = length - thickness - terminalMinimum
        guard most >= editorMinimum else { return wanted }
        return min(most, max(editorMinimum, wanted))
    }
}
