import Foundation

/// The live chat's reading column (plan 041): the conversation and the composer share it, so their leading edges line
/// up. It fills the width less a calm margin either side, and caps at a readable measure only in a very wide view,
/// where it stays centred. The transcript sets its text inset from this; the rows under it are held to the same
/// numbers by constraints (the width less both margins, at most the cap, centred).
public struct ChatColumn: Equatable, Sendable {
    /// The room either side.
    public static let margin: Double = 20
    /// The widest the column reads at.
    public static let cap: Double = 860

    /// From the view's leading edge to the column's.
    public let leading: Double
    public let width: Double

    public init(leading: Double, width: Double) {
        self.leading = leading
        self.width = width
    }

    /// The column in a view `width` wide: centred, never wider than the view, never negative.
    public static func layout(width: Double) -> ChatColumn {
        let total = max(0, width.isFinite ? width : 0)
        let column = min(cap, max(0, total - 2 * margin))
        return ChatColumn(leading: (total - column) / 2, width: column)
    }
}
