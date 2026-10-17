import Foundation

/// Which side of the terminal the tab list sits on. On the right it mirrors the left: its divider is on its other
/// edge, a drag the other way widens it and its chevron points the other way. The rows, drops, scrolling and chips
/// are the same on both sides.
public enum TabListSide: String, CaseIterable, Sendable {
    case left, right

    /// How wide the strip along the list's edge is that drags its width.
    public static let dividerWidth: CGFloat = 5
    /// How wide the selected row's edge is.
    public static let selectionEdgeWidth: CGFloat = 2

    /// The terminal is to the list's left: the list's left edge meets it.
    public var terminalIsLeft: Bool { self == .right }

    /// The strip that drags the width, in the list's own coordinates: along the edge that meets the terminal,
    /// inside the list, so a press at the terminal's edge still selects text there.
    public func dividerFrame(width: CGFloat, height: CGFloat) -> CGRect {
        let x: CGFloat = terminalIsLeft ? 0 : width - Self.dividerWidth
        return CGRect(x: x, y: 0, width: Self.dividerWidth, height: height)
    }

    /// How much wider the list gets as the pointer moves `dx` across (rightward positive): toward the terminal
    /// widens it, away narrows it.
    public func widthChange(pointerMoved dx: CGFloat) -> CGFloat { terminalIsLeft ? -dx : dx }

    /// The collapsed list's chevron points the way it opens: toward the terminal.
    public var expandPointsLeft: Bool { terminalIsLeft }

    /// The selected row's accent edge, in the row's coordinates: on the side away from the terminal, where the
    /// selected fill does not already meet the terminal's identical colour.
    public func selectionEdge(rowWidth: CGFloat, rowHeight: CGFloat) -> CGRect {
        let x: CGFloat = terminalIsLeft ? rowWidth - Self.selectionEdgeWidth : 0
        return CGRect(x: x, y: 0, width: Self.selectionEdgeWidth, height: rowHeight)
    }
}

/// One line per tab, or two with Show Folders. Every tab row in a list has the same height.
public enum TabListDensity: Equatable, Sendable {
    case oneLine, twoLines

    public init(showsFolders: Bool) { self = showsFolders ? .twoLines : .oneLine }
}

/// How many tabs out of view on one side are done, failed or need you, the most urgent of their states, and the
/// tab a click on the chip scrolls to.
public struct TabListChip: Equatable, Sendable {
    public var count: Int
    public var state: TabState
    /// The most urgent of them nearest the list's edge: the least scroll that shows it.
    public var target: Int

    public init(count: Int, state: TabState, target: Int) {
        self.count = count
        self.state = state
        self.target = target
    }
}

/// The chips at the list's top and bottom edges; nil where nothing out of view needs a look.
public struct TabListChips: Equatable, Sendable {
    public var above: TabListChip?
    public var below: TabListChip?

    public init(above: TabListChip?, below: TabListChip?) {
        self.above = above
        self.below = below
    }
}

/// The list's rows laid out down its document, y down from its top. Values in, frames out: the list lays out with
/// it, scrolls with it, drops with it and counts what is out of view with it.
public struct TabListLayout: Equatable, Sendable {
    /// Above the first row, as on the terminal rail.
    public static let topPadding: CGFloat = 4
    public static let oneLineHeight: CGFloat = 28
    public static let twoLineHeight: CGFloat = 40
    /// A pane's row, as a project tree row.
    public static let paneHeight: CGFloat = 24
    /// How near the list's top or bottom a drag scrolls it, and how far an event scrolls at the very edge.
    public static let autoscrollBand: CGFloat = 24
    public static let autoscrollFastest: CGFloat = 12

    /// A herdr agent's row has a second line with Show Folders, as a tab's (its question, or where it works).
    public static func rowHeight(for kind: TabListRow.Kind, density: TabListDensity) -> CGFloat {
        switch kind {
        case .tab: return density == .twoLines ? twoLineHeight : oneLineHeight
        case .herdrAgent: return density == .twoLines ? twoLineHeight : paneHeight
        case .pane, .herdrFolded: return paneHeight
        }
    }

    /// One per row, the full width across, no gaps between them.
    public let frames: [CGRect]
    /// Each tab's rows: its own, then its panes'.
    public let blocks: [Range<Int>]
    /// The padding and every row.
    public let contentHeight: CGFloat
    private let top: CGFloat

    public init(kinds: [TabListRow.Kind], density: TabListDensity, width: CGFloat, topPadding: CGFloat = TabListLayout.topPadding) {
        var frames: [CGRect] = []
        frames.reserveCapacity(kinds.count)
        var y: CGFloat = topPadding
        for kind in kinds {
            let height: CGFloat = Self.rowHeight(for: kind, density: density)
            frames.append(CGRect(x: 0, y: y, width: width, height: height))
            y += height
        }
        self.frames = frames
        self.blocks = TabListRows.blocks(of: kinds)
        self.contentHeight = y
        self.top = topPadding
    }

    public init(rows: [TabListRow], density: TabListDensity, width: CGFloat) {
        self.init(kinds: rows.map(\.kind), density: density, width: width)
    }

    public var tabCount: Int { blocks.count }

    /// Tab `tab`'s row and its panes' rows together; zero for no such tab.
    public func blockFrame(tab: Int) -> CGRect {
        guard blocks.indices.contains(tab) else { return .zero }
        let block = blocks[tab]
        let first: CGRect = frames[block.lowerBound]
        let last: CGRect = frames[block.upperBound - 1]
        return CGRect(x: first.minX, y: first.minY, width: first.width, height: last.maxY - first.minY)
    }

    private func blockHeight(_ tab: Int) -> CGFloat { blockFrame(tab: tab).height }

    // MARK: keeping the selected tab in view

    /// Where the visible part's top goes so the selected tab shows, with its panes when they fit, by the least
    /// scroll; nil when it shows already. Taller than the view, its own row goes to the top with as many panes as
    /// fit. A target within the top padding is the top, so the first row is never left flush under the edge.
    public func scrollTarget(selected: Int, visible: CGRect) -> CGFloat? {
        guard blocks.indices.contains(selected) else { return nil }
        let block: CGRect = blockFrame(tab: selected)
        let wanted: CGFloat
        if block.height > visible.height {
            wanted = block.minY
        } else if block.minY < visible.minY {
            wanted = block.minY
        } else if block.maxY > visible.maxY {
            wanted = block.maxY - visible.height
        } else {
            return nil
        }
        let most: CGFloat = max(0, contentHeight - visible.height)
        var target: CGFloat = min(most, max(0, wanted))
        if target <= top { target = 0 }
        return abs(target - visible.minY) < 0.5 ? nil : target
    }

    // MARK: dragging

    /// The tab place a dragged tab would drop into, its block's centre at `centreY`: the place whose slot centre is
    /// nearest, the other tabs keeping their order around it. In tab places, so a tab never lands between another
    /// tab and its panes. With tabs of one height it is the top bar's rule: a tab moves on once its centre crosses
    /// its neighbour's edge.
    public func dropIndex(dragged: Int, centreY: CGFloat) -> Int {
        guard blocks.indices.contains(dragged) else { return max(0, min(dragged, blocks.count - 1)) }
        let draggedHeight: CGFloat = blockHeight(dragged)
        let others: [CGFloat] = blocks.indices.filter { $0 != dragged }.map(blockHeight)
        var best = 0
        var bestDistance = CGFloat.infinity
        var above: CGFloat = top
        for place in 0...others.count {
            let centre: CGFloat = above + draggedHeight / 2
            let distance: CGFloat = abs(centreY - centre)
            if distance < bestDistance {
                best = place
                bestDistance = distance
            }
            if place < others.count { above += others[place] }
        }
        return best
    }

    /// Where a dragged tab's block can go: its top from the first row's to where its bottom meets the last row's.
    public func dragRange(tab: Int) -> ClosedRange<CGFloat> {
        let lowest: CGFloat = max(top, contentHeight - blockHeight(tab))
        return top...lowest
    }

    /// Every row's frame, in the rows' own order, with tab `from` and its pane rows moved to tab place `to` and the
    /// other tabs closed up around it: where the others slide while a tab is dragged, and where it settles.
    public func frames(movingTab from: Int, to: Int) -> [CGRect] {
        guard from != to, blocks.indices.contains(from), blocks.indices.contains(to) else { return frames }
        var order: [Int] = Array(blocks.indices)
        order.remove(at: from)
        order.insert(from, at: to)
        var moved: [CGRect] = frames
        var y: CGFloat = top
        for tab in order {
            for row in blocks[tab] {
                let frame: CGRect = frames[row]
                moved[row] = CGRect(x: frame.minX, y: y, width: frame.width, height: frame.height)
                y += frame.height
            }
        }
        return moved
    }

    /// How far each event of a drag scrolls the list (negative: up), with the pointer at `pointerY`: nothing
    /// outside the bands along its top and bottom, faster toward the edge, the fastest at it and past it. Nothing
    /// past either end of the rows.
    public func autoscrollSpeed(pointerY: CGFloat, visible: CGRect) -> CGFloat {
        let fromTop: CGFloat = pointerY - visible.minY
        let fromBottom: CGFloat = visible.maxY - pointerY
        let canGoUp = visible.minY > 0
        let canGoDown = visible.maxY < contentHeight
        if fromTop < fromBottom {
            return fromTop < Self.autoscrollBand && canGoUp ? -Self.autoscrollStep(fromTop) : 0
        }
        return fromBottom < Self.autoscrollBand && canGoDown ? Self.autoscrollStep(fromBottom) : 0
    }

    /// Where the visible part's top goes after one event of a drag held at `pointerY`: `autoscrollSpeed` further,
    /// never past either end of the rows. nil when it does not move, so a drag held still away from the edges does
    /// nothing.
    public func autoscrolled(pointerY: CGFloat, visible: CGRect) -> CGFloat? {
        let speed: CGFloat = autoscrollSpeed(pointerY: pointerY, visible: visible)
        guard speed != 0 else { return nil }
        let most: CGFloat = max(0, contentHeight - visible.height)
        let next: CGFloat = min(most, max(0, visible.minY + speed))
        return abs(next - visible.minY) < 0.5 ? nil : next
    }

    private static func autoscrollStep(_ distance: CGFloat) -> CGFloat {
        guard distance > 0 else { return autoscrollFastest }
        let share: CGFloat = (autoscrollBand - distance) / autoscrollBand
        return (autoscrollFastest * share).rounded(.up)
    }

    // MARK: the edge chips

    /// Out of view above and below: tabs whose own row is not wholly in view, done, failed or needing you. A pane
    /// row out of view counts for nothing, since its tab's row carries its mark. Working and idle never raise a
    /// chip: a list cut off shows it has more by its last row, and only what needs a look is pointed at.
    public func hidden(states: [TabState], visible: CGRect) -> TabListChips {
        let out = outOfView(tabCount: states.count, visible: visible)
        // Nearest the edge first, so a click on the chip scrolls the least.
        let aboveChip: TabListChip? = Self.chip(tabs: out.above.reversed(), states: states)
        let belowChip: TabListChip? = Self.chip(tabs: out.below, states: states)
        return TabListChips(above: aboveChip, below: belowChip)
    }

    /// What each chip says to VoiceOver and in its tooltip, the most urgent first: "2 tabs below: 1 needs you,
    /// 1 done". nil on a side with nothing that needs a look, as the chip itself.
    public func chipWords(states: [TabState], visible: CGRect) -> (above: String?, below: String?) {
        let out = outOfView(tabCount: states.count, visible: visible)
        let above: String? = Self.words(tabs: out.above, states: states, side: "above")
        let below: String? = Self.words(tabs: out.below, states: states, side: "below")
        return (above, below)
    }

    /// The tabs whose own row is not wholly in view, above it and below it, in tab order.
    private func outOfView(tabCount: Int, visible: CGRect) -> (above: [Int], below: [Int]) {
        var above: [Int] = []
        var below: [Int] = []
        for tab in 0..<min(tabCount, blocks.count) {
            let row: CGRect = frames[blocks[tab].lowerBound]
            if row.minY < visible.minY - 0.5 {
                above.append(tab)
            } else if row.maxY > visible.maxY + 0.5 {
                below.append(tab)
            }
        }
        return (above, below)
    }

    private static func words(tabs: [Int], states: [TabState], side: String) -> String? {
        let looks: [TabState] = tabs.map { states[$0] }.filter(chipUrgency.contains)
        guard !looks.isEmpty else { return nil }
        let parts: [String] = chipUrgency.compactMap { state -> String? in
            let count: Int = looks.filter { $0 == state }.count
            guard count > 0 else { return nil }
            return "\(count) \(word(for: state, count: count))"
        }
        let noun: String = looks.count == 1 ? "tab" : "tabs"
        return "\(looks.count) \(noun) \(side): " + parts.joined(separator: ", ")
    }

    private static func word(for state: TabState, count: Int) -> String {
        switch state {
        case .attention: return count == 1 ? "needs you" : "need you"
        case .failed: return "failed"
        default: return "done"
        }
    }

    /// The bar's order for what it hides, without working: needs you, failed, done.
    private static let chipUrgency: [TabState] = [.attention, .failed, .done]

    private static func chip(tabs: [Int], states: [TabState]) -> TabListChip? {
        let looks: [Int] = tabs.filter { chipUrgency.contains(states[$0]) }
        guard let state = chipUrgency.first(where: { urgent in looks.contains { states[$0] == urgent } }),
              let target = looks.first(where: { states[$0] == state }) else { return nil }
        return TabListChip(count: looks.count, state: state, target: target)
    }

    // MARK: collapsed

    /// The collapsed list: a column of marks.
    public static func collapsed(tabCount: Int, height: CGFloat) -> TabListCollapsed {
        TabListCollapsed(tabCount: tabCount, height: height)
    }
}

/// The collapsed list, a 24-point column with one mark per tab in 24-point slots under the chevron that opens it,
/// counted as the terminal rail counts its marks: when not all fit, the last place says how many more.
public struct TabListCollapsed: Equatable, Sendable {
    /// The chevron's strip along the top.
    public static let chevronStrip: CGFloat = 38
    public static let slotSize: CGFloat = 24
    /// Between the chevron's strip and the first mark, and under the last.
    public static let margin: CGFloat = 4

    /// The marks that show, in tab order.
    public let slots: [CGRect]
    /// The "+N" place, while some tabs do not fit.
    public let more: CGRect?
    public let hiddenCount: Int

    public init(tabCount: Int, height: CGFloat) {
        let marksTop: CGFloat = Self.chevronStrip + Self.margin
        let room = Int(max(0, height - marksTop - Self.margin) / Self.slotSize)
        let shown: Int = tabCount <= room ? tabCount : max(0, room - 1)
        let slots: [CGRect] = (0..<shown).map { index -> CGRect in
            CGRect(x: 0, y: marksTop + CGFloat(index) * Self.slotSize, width: Self.slotSize, height: Self.slotSize)
        }
        let hidden: Int = tabCount - shown
        let moreY: CGFloat = marksTop + CGFloat(shown) * Self.slotSize
        self.slots = slots
        self.hiddenCount = hidden
        self.more = hidden > 0 && room > 0 ? CGRect(x: 0, y: moreY, width: Self.slotSize, height: Self.slotSize) : nil
    }

    public var shownCount: Int { slots.count }

    /// The "+N"'s colour: the most urgent of the tabs it stands for, as the rail's.
    public static func moreState(_ hidden: [TabState]) -> TabState {
        let urgency: [TabState] = [.attention, .failed, .done, .working]
        return urgency.first(where: hidden.contains) ?? .idle
    }
}
