import Foundation

/// The live chat's reading column (plans 041, 047): the conversation and the composer share it, so their leading edges
/// line up. It fills the pane less a calm margin either side, as the terminal fills it, and follows the pane's width:
/// no cap and no centring, so the chat never leaves room on either side of a wide terminal.
public struct ChatColumn: Equatable, Sendable {
    /// The room either side.
    public static let margin: Double = 20

    /// From the view's leading edge to the column's.
    public let leading: Double
    public let width: Double

    public init(leading: Double, width: Double) {
        self.leading = leading
        self.width = width
    }

    /// The column in a view `width` wide: the width less both margins, never wider than the view, never negative. A view
    /// narrower than both margins splits what it has.
    public static func layout(width: Double) -> ChatColumn {
        let total = max(0, width.isFinite ? width : 0)
        let leading = min(margin, total / 2)
        return ChatColumn(leading: leading, width: max(0, total - 2 * leading))
    }
}
