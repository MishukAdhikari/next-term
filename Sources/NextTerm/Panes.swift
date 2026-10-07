import AppKit
import NextTermCore

/// A terminal in a split tab: the terminal with its margins, and a veil that dims it while another pane
/// of the same tab has the keyboard.
final class PaneView: NSView {
    let tab: TerminalTab
    private let veil = Veil()

    init(tab: TerminalTab) {
        self.tab = tab
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        veil.isHidden = true
        veil.translatesAutoresizingMaskIntoConstraints = false
        addSubview(veil)
        NSLayoutConstraint.activate([
            veil.topAnchor.constraint(equalTo: topAnchor),
            veil.leadingAnchor.constraint(equalTo: leadingAnchor),
            veil.trailingAnchor.constraint(equalTo: trailingAnchor),
            veil.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Takes the terminal (from wherever it was) and keeps the veil above it.
    func adopt() {
        let view = tab.view
        guard view.superview !== self else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: veil)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    var dimmed = false {
        didSet { veil.isHidden = !dimmed }
    }

    /// Clicks go through to the terminal; the veil only shades it.
    private final class Veil: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        }

        required init?(coder: NSCoder) { fatalError("not used") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Between panes: a hairline that shows against the terminal background, easy to grab.
final class PaneSplitView: NSSplitView, NSSplitViewDelegate {
    weak var split: PaneGroup.Split?
    /// Set while the group lays itself out, so its own moves are not taken for the user's.
    var applying = false

    override var dividerColor: NSColor { WorkSplitView.line }
    override var dividerThickness: CGFloat { 1 }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                   ofDividerAt dividerIndex: Int) -> NSRect {
        isVertical ? drawnRect.insetBy(dx: -3, dy: 0) : drawnRect.insetBy(dx: 0, dy: -3)
    }

    /// No pane narrower than a usable terminal.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        let previous = arrangedSubviews[index].frame
        return (isVertical ? previous.minX : previous.minY) + PaneGroup.minimum
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        guard index + 1 < arrangedSubviews.count else { return proposed }
        let next = arrangedSubviews[index + 1].frame
        return (isVertical ? next.maxX : next.maxY) - PaneGroup.minimum
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !applying, let split else { return }
        let length = isVertical ? bounds.width : bounds.height
        guard length > 0, arrangedSubviews.count == split.children.count else { return }
        // Where each divider is now, as a fraction: kept across window resizes and new splits.
        split.dividers = arrangedSubviews.dropLast().map { view in
            (isVertical ? view.frame.maxX : view.frame.maxY) / length
        }
    }
}

/// The panes of one tab: a tree of splits with a terminal at each leaf. The tab bar shows the group as
/// one tab; the pane with the keyboard (`focused`) names it.
final class PaneGroup {
    static let minimum: CGFloat = 80

    final class Split {
        /// Side by side (true) or one above the other.
        let vertical: Bool
        var children: [Node]
        /// Divider positions as fractions of the split's length, one fewer than the children.
        var dividers: [CGFloat]

        init(vertical: Bool, children: [Node]) {
            self.vertical = vertical
            self.children = children
            dividers = (1..<children.count).map { CGFloat($0) / CGFloat(children.count) }
        }
    }

    indirect enum Node {
        case pane(TerminalTab)
        case split(Split)

        var panes: [TerminalTab] {
            switch self {
            case .pane(let tab): return [tab]
            case .split(let split): return split.children.flatMap(\.panes)
            }
        }

        func contains(_ tab: TerminalTab) -> Bool { panes.contains { $0 === tab } }
    }

    private(set) var root: Node
    var focused: TerminalTab
    /// One pane filling the tab, the others kept running behind it.
    var zoomed: TerminalTab?
    /// The tab's content, filling the terminal area.
    let view = NSView()
    private var paneViews: [UUID: PaneView] = [:]

    init(_ tab: TerminalTab) {
        root = .pane(tab)
        focused = tab
    }

    var panes: [TerminalTab] { root.panes }
    var isSplit: Bool { panes.count > 1 }

    /// The server mark the tab shows: the weakest connection among its panes on servers, with that pane's host.
    var remoteMark: RemoteMark? { RemoteMark.split(focused: focused.remoteMark, panes: panes.compactMap(\.remoteMark)) }

    func contains(_ tab: TerminalTab) -> Bool { root.contains(tab) }

    /// `new` next to `tab`: to its right (vertical) or below it.
    func split(_ tab: TerminalTab, with new: TerminalTab, vertical: Bool) {
        zoomed = nil
        root = Self.inserting(new, after: tab, vertical: vertical, in: root)
        focused = new
    }

    private static func inserting(_ new: TerminalTab, after tab: TerminalTab, vertical: Bool, in node: Node) -> Node {
        switch node {
        case .pane(let leaf):
            guard leaf === tab else { return node }
            return .split(Split(vertical: vertical, children: [node, .pane(new)]))
        case .split(let split):
            guard let index = split.children.firstIndex(where: { $0.contains(tab) }) else { return node }
            if case .pane(let leaf) = split.children[index], leaf === tab, split.vertical == vertical {
                // Same direction as this split: a sibling, taking half of the pane's room.
                let start = index == 0 ? 0 : split.dividers[index - 1]
                let end = index < split.dividers.count ? split.dividers[index] : 1
                split.children.insert(.pane(new), at: index + 1)
                split.dividers.insert((start + end) / 2, at: index)
                return node
            }
            split.children[index] = inserting(new, after: tab, vertical: vertical, in: split.children[index])
            return node
        }
    }

    /// Takes a pane out; its room goes to its neighbour. False when it was the last one.
    @discardableResult
    func remove(_ tab: TerminalTab) -> Bool {
        if zoomed === tab { zoomed = nil }
        paneViews.removeValue(forKey: tab.id)?.removeFromSuperview()
        guard let rest = Self.removing(tab, from: root) else { return false }
        if focused === tab {
            // The pane before it in reading order, else the first.
            let order = root.panes
            let index = order.firstIndex { $0 === tab } ?? 0
            focused = rest.panes[max(0, min(index - 1, rest.panes.count - 1))]
        }
        root = rest
        return true
    }

    private static func removing(_ tab: TerminalTab, from node: Node) -> Node? {
        switch node {
        case .pane(let leaf):
            return leaf === tab ? nil : node
        case .split(let split):
            guard let index = split.children.firstIndex(where: { $0.contains(tab) }) else { return node }
            if let rest = removing(tab, from: split.children[index]) {
                split.children[index] = rest
                return node
            }
            split.children.remove(at: index)
            if !split.dividers.isEmpty { split.dividers.remove(at: min(index, split.dividers.count - 1)) }
            // A split of one is just that one.
            return split.children.count == 1 ? split.children[0] : node
        }
    }

    /// Every split back to equal shares.
    func equalize() {
        func walk(_ node: Node) {
            guard case .split(let split) = node else { return }
            split.dividers = (1..<split.children.count).map { CGFloat($0) / CGFloat(split.children.count) }
            split.children.forEach(walk)
        }
        walk(root)
    }

    // MARK: views

    func paneView(_ tab: TerminalTab) -> PaneView {
        if let view = paneViews[tab.id] { return view }
        let view = PaneView(tab: tab)
        paneViews[tab.id] = view
        return view
    }

    /// Builds the views for the tree (or the zoomed pane), then puts the dividers where they were.
    func layout() {
        let content: NSView
        if let zoomed, contains(zoomed) {
            content = paneView(zoomed)
        } else {
            content = build(root)
        }
        for tab in panes { paneView(tab).adopt() }
        view.subviews.filter { $0 !== content }.forEach { $0.removeFromSuperview() }
        if content.superview !== view {
            content.removeFromSuperview()
            content.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: view.topAnchor),
                content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        view.layoutSubtreeIfNeeded()
        placeDividers(content)
        updateDimming()
    }

    private func build(_ node: Node) -> NSView {
        switch node {
        case .pane(let tab):
            let pane = paneView(tab)
            pane.translatesAutoresizingMaskIntoConstraints = true
            pane.autoresizingMask = [.width, .height]
            return pane
        case .split(let split):
            let splitView = PaneSplitView()
            splitView.isVertical = split.vertical
            splitView.dividerStyle = .thin
            splitView.delegate = splitView
            splitView.split = split
            splitView.applying = true
            for child in split.children {
                let childView = build(child)
                childView.removeFromSuperview()
                splitView.addArrangedSubview(childView)
            }
            return splitView
        }
    }

    /// Outside in: a split's own size is known only once its parent's dividers are placed.
    private func placeDividers(_ view: NSView) {
        guard let splitView = view as? PaneSplitView, let split = splitView.split else { return }
        splitView.applying = true
        let length = split.vertical ? splitView.bounds.width : splitView.bounds.height
        for (index, fraction) in split.dividers.enumerated() where index < splitView.arrangedSubviews.count - 1 {
            splitView.setPosition((fraction * length).rounded(), ofDividerAt: index)
        }
        splitView.layoutSubtreeIfNeeded()
        splitView.applying = false
        splitView.arrangedSubviews.forEach(placeDividers)
    }

    /// The panes without the keyboard are shaded, so you can tell where your typing goes.
    func updateDimming() {
        let shade = isSplit && zoomed == nil
        for tab in panes { paneView(tab).dimmed = shade && tab !== focused }
    }

    // MARK: moving between panes

    enum Direction { case left, right, up, down }

    /// The pane next to `tab` in a direction: the nearest one that overlaps it across that direction.
    func neighbor(of tab: TerminalTab, _ direction: Direction) -> TerminalTab? {
        guard zoomed == nil, let from = frame(of: tab) else { return nil }
        var best: (tab: TerminalTab, distance: CGFloat, overlap: CGFloat)?
        for other in panes where other !== tab {
            guard let to = frame(of: other) else { continue }
            let distance: CGFloat
            let overlap: CGFloat
            switch direction {
            case .left: distance = from.minX - to.maxX; overlap = min(from.maxY, to.maxY) - max(from.minY, to.minY)
            case .right: distance = to.minX - from.maxX; overlap = min(from.maxY, to.maxY) - max(from.minY, to.minY)
            case .up: distance = to.minY - from.maxY; overlap = min(from.maxX, to.maxX) - max(from.minX, to.minX)
            case .down: distance = from.minY - to.maxY; overlap = min(from.maxX, to.maxX) - max(from.minX, to.minX)
            }
            guard distance >= -2, overlap > 0 else { continue }
            if best == nil || distance < best!.distance - 1 || (abs(distance - best!.distance) <= 1 && overlap > best!.overlap) {
                best = (other, distance, overlap)
            }
        }
        return best?.tab
    }

    /// In the group view's coordinates (y up).
    private func frame(of tab: TerminalTab) -> NSRect? {
        guard let pane = paneViews[tab.id], pane.superview != nil, pane.window != nil else { return nil }
        return pane.convert(pane.bounds, to: view)
    }
}
