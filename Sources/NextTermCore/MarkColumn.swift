import Foundation

/// A column of marks under a strip, one slot each, top to bottom: the terminal rail's tabs, the folded tab list's and
/// the window column's windows. Values in, frames out, y down from the column's top. The rule all three share: the marks
/// start a margin under the strip and stop a margin above the bottom, and when not all fit, the last place says how many
/// more ("+3"). With no room for even one place, nothing shows, not even the count.
public struct MarkColumn: Equatable, Sendable {
    /// The marks that show, in order, each `slot` square at the column's left edge.
    public let slots: [CGRect]
    /// The "+N" place, while some marks do not fit and there is room for it.
    public let more: CGRect?
    /// The marks that do not fit.
    public let hiddenCount: Int
    /// Where the first place's top is: the strip's bottom and the margin under it.
    public let marksTop: CGFloat
    public let slot: CGFloat

    /// - `count`: how many marks there are.
    /// - `height`: the column's.
    /// - `top`: the strip above the marks (a chevron's, a header's).
    /// - `slot`: each place's height, and its width.
    /// - `margin`: under the strip and above the bottom.
    public init(count: Int, height: CGFloat, top: CGFloat, slot: CGFloat, margin: CGFloat) {
        let marksTop: CGFloat = top + margin
        let room: Int = slot > 0 ? Int(max(0, height - marksTop - margin) / slot) : 0
        let count: Int = max(0, count)
        let shown: Int = count <= room ? count : max(0, room - 1)
        self.marksTop = marksTop
        self.slot = slot
        self.slots = (0..<shown).map { (index: Int) -> CGRect in
            CGRect(x: 0, y: marksTop + CGFloat(index) * slot, width: slot, height: slot)
        }
        self.hiddenCount = count - shown
        self.more = count > shown && room > 0 ? CGRect(x: 0, y: marksTop + CGFloat(shown) * slot, width: slot, height: slot) : nil
    }

    public var shownCount: Int { slots.count }

    /// Place `index` down the column, whether or not it fits.
    public func place(_ index: Int) -> CGRect {
        CGRect(x: 0, y: marksTop + CGFloat(index) * slot, width: slot, height: slot)
    }

    /// The "+N"'s colour: the most urgent of the marks it stands for (needs you, failed, done, working), idle for none.
    public static func moreState(_ hidden: [TabState]) -> TabState {
        let urgency: [TabState] = [.attention, .failed, .done, .working]
        return urgency.first(where: hidden.contains) ?? .idle
    }
}
