import Foundation

/// How a sidebar row's line splits between its name and the dimmed detail after it ("OpenAI", "AI model · .env"). The
/// name is the content and stays whole; the detail is background and gives way first, cut at its tail, and hides when
/// it would show less than `minimumDetail` (about three characters), so the row never ends in a lone ellipsis. A
/// hidden detail gives its gap back to the name, which is cut at its tail only when it alone does not fit. Apart from
/// AppKit, so it can be tested; widths are in points.
public struct NameDetailFit: Equatable, Sendable {
    /// The name's width: its whole width, or all the room when it alone does not fit.
    public var name: Double
    /// The detail's width, whole or cut; nil when it hides.
    public var detail: Double?

    public init(name: Double, detail: Double?) {
        self.name = name
        self.detail = detail
    }

    /// The widths for a line of `room` points, given the name's and the detail's whole widths, the gap between them,
    /// and the narrowest a cut detail may be. A detail that fits whole shows even when narrower than that.
    public static func fit(room: Double, name: Double, detail: Double, gap: Double, minimumDetail: Double) -> NameDetailFit {
        let room = max(0, room)
        guard name < room else { return NameDetailFit(name: room, detail: nil) }
        let left = room - name - gap
        guard detail > 0, left > 0 else { return NameDetailFit(name: name, detail: nil) }
        if detail <= left { return NameDetailFit(name: name, detail: detail) }
        return NameDetailFit(name: name, detail: left >= minimumDetail ? left : nil)
    }
}
