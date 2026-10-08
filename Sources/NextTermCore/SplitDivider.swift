import Foundation

/// The one-point lines between a split view's panes: where they are drawn, and where they can be grabbed.
/// A line sets two panes apart, so there is one only where a pane shows on each side of it. Beside a hidden
/// pane (the editor with nothing open, a hidden sidebar) there is none, and nothing grabs the divider there:
/// dragging it would have the split view show that pane by itself, empty, behind the app's back.
public enum SplitDivider {
    /// How far either side of the drawn line a press still grabs it.
    public static let slop: CGFloat = 3

    /// A pane as its split view lays it out: its frame in the split view's coordinates, and whether it is hidden.
    public struct Pane: Equatable, Sendable {
        public var frame: CGRect
        public var hidden: Bool

        public init(frame: CGRect, hidden: Bool) {
            self.frame = frame
            self.hidden = hidden
        }

        /// It takes room on screen: not hidden, and not squeezed to nothing.
        var shows: Bool { !hidden && frame.width >= 1 && frame.height >= 1 }
    }

    /// Where the lines go, in the split view's coordinates: one between each two neighbouring panes that both
    /// show, filling the room the split leaves between them (a divider's `thickness`), only as far across as
    /// both panes reach. A hidden pane, or one squeezed to nothing, has no line beside it, so none is left where
    /// it was or along the edge of the pane that took its room. A line touches a pane on each side and covers
    /// neither: with no room between two panes, or more than a divider's (something else between them), there
    /// is none.
    public static func lines(between panes: [Pane], sideBySide: Bool, thickness: CGFloat) -> [CGRect] {
        let shown = panes.filter(\.shows).map(\.frame).sorted { sideBySide ? $0.minX < $1.minX : $0.minY < $1.minY }
        func fits(_ room: CGFloat) -> Bool { room > 0 && room <= thickness + 0.01 }
        return zip(shown, shown.dropFirst()).compactMap { first, second in
            if sideBySide {
                let room = second.minX - first.maxX
                let top = max(first.minY, second.minY), bottom = min(first.maxY, second.maxY)
                guard fits(room), bottom > top else { return nil }
                return CGRect(x: first.maxX, y: top, width: room, height: bottom - top)
            }
            let room = second.minY - first.maxY
            let left = max(first.minX, second.minX), right = min(first.maxX, second.maxX)
            guard fits(room), right > left else { return nil }
            return CGRect(x: left, y: first.maxY, width: right - left, height: room)
        }
    }

    /// Whether divider `index`, between pane `index` and pane `index + 1`, is hidden: a pane beside it is
    /// (or there is no pane there, so no divider either).
    public static func isHidden(at index: Int, panesHidden: [Bool]) -> Bool {
        guard index >= 0, index + 1 < panesHidden.count else { return true }
        return panesHidden[index] || panesHidden[index + 1]
    }

    /// The area that grabs it: the drawn line widened across the split (sideways between panes side by
    /// side, up and down between stacked ones), and none at all while it is hidden.
    public static func grabArea(drawn: CGRect, sideBySide: Bool, hidden: Bool) -> CGRect {
        guard !hidden else { return .zero }
        return sideBySide ? drawn.insetBy(dx: -slop, dy: 0) : drawn.insetBy(dx: 0, dy: -slop)
    }
}
