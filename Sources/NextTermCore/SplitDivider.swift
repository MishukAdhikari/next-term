import Foundation

/// Where a one-point split-view divider can be grabbed. A divider beside a hidden pane (the editor with
/// nothing open, a hidden sidebar) is hidden too, and nothing grabs it: dragging it would have the split
/// view show that pane by itself, empty, behind the app's back.
public enum SplitDivider {
    /// How far either side of the drawn line a press still grabs it.
    public static let slop: CGFloat = 3

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
