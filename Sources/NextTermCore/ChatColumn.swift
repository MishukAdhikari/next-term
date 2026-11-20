import Foundation

/// The live chat's reading column (plans 041, 047): the conversation and the composer share it, so their leading edges
/// line up. It starts a calm margin from the leading edge at every width and runs to the width less both margins, but
/// never past a readable measure: 90 characters of the body font, the top of Practical Typography's 45–90. Past that
/// the right side stays empty (ragged right, as Mail and Notes set text), never a centred block with room on the left.
public struct ChatColumn: Equatable, Sendable {
    /// The room on the leading side, and at least as much on the trailing side.
    public static let margin: Double = 20
    /// The longest line, in characters of the body font.
    public static let measure: Double = 90

    /// From the view's leading edge to the column's.
    public let leading: Double
    public let width: Double

    public init(leading: Double, width: Double) {
        self.leading = leading
        self.width = width
    }

    /// The widest the column reads at, for a body font whose lowercase alphabet is `alphabetWidth` wide: 90 of its
    /// average letters.
    public static func cap(alphabetWidth: Double) -> Double {
        guard alphabetWidth.isFinite, alphabetWidth > 0 else { return 0 }
        return (measure * alphabetWidth / 26).rounded()
    }

    /// The column in a view `width` wide, no wider than `cap`: from the margin, never wider than the view, never
    /// negative. A view narrower than both margins splits what it has.
    public static func layout(width: Double, cap: Double) -> ChatColumn {
        let total = max(0, width.isFinite ? width : 0)
        let leading = min(margin, total / 2)
        let room = max(0, total - 2 * margin)
        let column = cap.isFinite && cap > 0 ? min(cap, room) : room
        return ChatColumn(leading: leading, width: column)
    }
}
