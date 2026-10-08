import AppKit
import NextTermCore

/// A terminal in a split tab: the terminal with its margins, a header above it while the tab shows more
/// than one pane, and a veil that dims the terminal while another pane of the same tab has the keyboard.
final class PaneView: NSView {
    let tab: TerminalTab
    /// The pane's own small tab: its mark, its title and a × that closes this pane alone.
    let header: PaneHeaderView
    private let veil = Veil()
    /// The header's room, taken from the pane's height (none while it is hidden).
    private var headerHeight: NSLayoutConstraint?

    init(tab: TerminalTab) {
        self.tab = tab
        header = PaneHeaderView(tab: tab)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        clipsToBounds = true // a terminal that keeps its size in a pane with none (see layout) shows nowhere
        header.isHidden = true
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        veil.isHidden = true
        veil.translatesAutoresizingMaskIntoConstraints = false
        addSubview(veil)
        let height = header.heightAnchor.constraint(equalToConstant: 0)
        headerHeight = height
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            height,
            veil.topAnchor.constraint(equalTo: header.bottomAnchor),
            veil.leadingAnchor.constraint(equalTo: leadingAnchor),
            veil.trailingAnchor.constraint(equalTo: trailingAnchor),
            veil.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Takes the terminal (from wherever it was) and keeps the veil above it, under the header.
    func adopt() {
        let view = tab.view
        guard view.superview !== self else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: veil)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    var dimmed = false {
        didSet {
            veil.isHidden = !dimmed
            header.focused = !dimmed
        }
    }

    /// The panes of a split sit in split views; a lone pane, or one maximized, sits in the tab itself and
    /// shows no header. Decided as the pane is placed, before the layout that sizes its terminal, so the
    /// terminal is resized once, to its size with or without the header.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let superview else { return } // on its way to another split
        showsHeader = superview is PaneSplitView
    }

    /// A pane is placed at no width or no height first, while its split is built, and has no height while
    /// the terminal is folded down to its tab bar. Its terminal keeps its size until the pane has one again:
    /// squeezed to two columns on the way, it would rewrap its history to fit them and lose most of it (a
    /// Split Down in a tab already split side by side did). It keeps its size too while its split view is
    /// still being placed (built at even shares, then its dividers put back): a split or a close resizes
    /// the terminal once, to where it ends up, and not at all a terminal whose room stays the same. Each
    /// resize is a redraw for the program in it.
    override func layout() {
        guard bounds.width >= 1, bounds.height >= 1, (superview as? PaneSplitView)?.applying != true else { return }
        super.layout()
    }

    /// The terminal had the keyboard as the pane left the window (see viewDidMoveToWindow).
    private var hadKeyboard = false

    /// A split, a close or Make Panes Equal builds the split views again, which takes every pane out of the
    /// window for a moment, and AppKit gives the keyboard to the window. The pane that had it takes it back
    /// as it returns, if it is still the pane the keyboard belongs to (not one that was maximized before you
    /// moved on to another pane).
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { hadKeyboard = window?.firstResponder === tab.view }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return } // on its way out: keep what it had for its way back
        defer { hadKeyboard = false }
        guard hadKeyboard, window.firstResponder === window,
              (window.windowController as? TerminalWindowController)?.activeTab === tab else { return }
        window.makeFirstResponder(tab.view)
    }

    private(set) var showsHeader = false {
        didSet {
            guard showsHeader != oldValue else { return }
            header.isHidden = !showsHeader
            headerHeight?.constant = showsHeader ? PaneHeaderView.height : 0
            if showsHeader { header.update() }
        }
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

/// A pane's header in a split tab, like a small tab: the pane's status mark, its title as the tab bar
/// would show it (a pane on a server with its server mark) and a × that closes this pane alone. The pane
/// with the keyboard has the selected tab's look, the others the bar's. A click gives the pane the
/// keyboard; a double-click renames it. It sits above the terminal, never in its rows.
final class PaneHeaderView: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 30

    let tab: TerminalTab
    private let dot = StatusDotView()
    private let remoteMark = RemoteMarkView()
    private let label = NSTextField(labelWithString: "")
    let closeButton = NSButton()
    private var renameField: NSTextField?
    private var hovering = false { didSet { if hovering != oldValue { refresh() } } }
    /// The pane has the keyboard: the selected tab's look, and its × always shows.
    var focused = false { didSet { if focused != oldValue { refresh() } } }
    /// What the title was fitted from, so a refresh touches only what changed.
    private var title = ""
    private var shorterTitles: [String] = []

    private static let font = NSFont.systemFont(ofSize: 12)

    init(tab: TerminalTab) {
        self.tab = tab
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        wantsLayer = true
        label.font = Self.font
        Typography.singleLine(label, truncation: .byTruncatingMiddle)
        label.setAccessibilityElement(false) // the header says it
        addSubview(label)
        addSubview(dot)
        remoteMark.isHidden = true
        addSubview(remoteMark)
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Pane")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.contentTintColor = Theme.textDim
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        addSubview(closeButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription("pane")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var controller: TerminalWindowController? { window?.windowController as? TerminalWindowController }

    /// For the self-test: the title and mark as shown.
    var shownTitle: String { label.stringValue }
    var shownState: TabState { dot.state }
    var shownRemoteLink: RemoteLink? { remoteMark.isHidden ? nil : remoteMark.link }
    var isEditing: Bool { renameField != nil }

    /// Takes the pane's title, mark and server mark. Called several times a second: touch only what changed
    /// (setting a tooltip again resets it).
    func update() {
        if tab.title != title || tab.shorterTitles != shorterTitles {
            title = tab.title
            shorterTitles = tab.shorterTitles
            label.stringValue = title
            needsLayout = true // layout may shorten it
        }
        if label.lineBreakMode != tab.titleTruncation { label.lineBreakMode = tab.titleTruncation }
        dot.state = tab.status.state
        let remote = tab.remoteMark
        if (remote == nil) != remoteMark.isHidden { needsLayout = true } // the title moves over, or back
        remoteMark.link = remote?.link
        remoteMark.isHidden = remote == nil
        if toolTip != tab.tooltip { toolTip = tab.tooltip }
        let spoken = [title, tab.ownStateDescription ?? "", remote?.summary ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
        if accessibilityLabel() != spoken { setAccessibilityLabel(spoken) }
        let closeLabel = "Close pane \(title)"
        if closeButton.accessibilityLabel() != closeLabel { closeButton.setAccessibilityLabel(closeLabel) }
    }

    private func refresh() {
        layer?.backgroundColor = (focused ? Theme.background : hovering ? Theme.tabHover : Theme.bar).cgColor
        label.textColor = focused || hovering ? Theme.text : Theme.textDim
        remoteMark.tint = label.textColor ?? Theme.textDim
        closeButton.isHidden = !(focused || hovering)
        // ⌘W closes the pane with the keyboard, so only its × names the key.
        let tip = focused ? KeyboardShortcuts.shared.hint("Close pane", #selector(TerminalWindowController.closeTab(_:))) : "Close pane"
        if closeButton.toolTip != tip { closeButton.toolTip = tip }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        // The mark lines up with the terminal's text below it.
        dot.frame = NSRect(x: 8, y: (h - 10) / 2, width: 10, height: 10)
        closeButton.frame = NSRect(x: bounds.width - 24, y: (h - 18) / 2, width: 18, height: 18)
        remoteMark.frame = NSRect(x: 22, y: (h - 16) / 2, width: RemoteMarkView.size.width, height: RemoteMarkView.size.height)
        let labelX: CGFloat = remoteMark.isHidden ? 25 : remoteMark.frame.maxX + 3
        // The ×'s room is kept while it is hidden, so the title stays put as the pointer passes.
        let width = max(0, bounds.width - 28 - labelX)
        let labelHeight = label.intrinsicContentSize.height
        label.frame = NSRect(x: labelX, y: (h - labelHeight) / 2, width: width, height: labelHeight)
        let words = fits(title, within: width) ? title : shorterTitles.first { fits($0, within: width) } ?? shorterTitles.last ?? title
        if label.stringValue != words { label.stringValue = words }
        renameField?.frame = NSRect(x: labelX - 3, y: (h - 22) / 2, width: max(40, bounds.width - labelX - 26), height: 22)
    }

    private func fits(_ title: String, within width: CGFloat) -> Bool {
        (title as NSString).size(withAttributes: [.font: Self.font]).width + 4 <= width
    }

    override func draw(_ dirtyRect: NSRect) {
        guard focused else { return }
        Theme.accent.setFill()
        NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    /// Hidden under the pointer (its pane maximized, or the last but one closed): no exit comes.
    override func viewDidHide() {
        super.viewDidHide()
        hovering = false
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { return beginRename() }
        controller?.focusPane(tab)
    }

    // Middle-click closes, as on a tab.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { controller?.closePane(tab) }
    }

    @objc private func closeClicked() { controller?.closePane(tab) }

    override func accessibilityPerformPress() -> Bool {
        controller?.focusPane(tab)
        return controller != nil
    }

    // MARK: rename, as a tab's

    func beginRename() {
        guard renameField == nil else { return }
        let field = NSTextField(string: tab.editableTitle)
        field.font = Self.font
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.placeholderString = "Pane name"
        field.usesSingleLineMode = true // a pasted line break becomes a space
        renameField = field
        label.isHidden = true
        addSubview(field)
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private var renameCancelled = false

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            renameCancelled = true
            window?.makeFirstResponder(nil) // ends editing -> controlTextDidEndEditing
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = renameField else { return }
        renameField = nil
        let text = field.stringValue.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let controller = self.controller
        field.removeFromSuperview()
        label.isHidden = false
        if renameCancelled {
            renameCancelled = false
        } else {
            // An empty name goes back to the automatic title.
            controller?.renamePane(tab, to: text.isEmpty ? nil : text)
        }
        controller?.paneRenameEnded(tab)
    }
}

/// Between panes: a hairline that shows against the terminal background, easy to grab.
final class PaneSplitView: NSSplitView, NSSplitViewDelegate {
    weak var split: PaneGroup.Split?
    /// Set while the group lays itself out, so its own moves are not taken for the user's. Its panes size
    /// their terminals once it is done (see PaneView.layout).
    var applying = false {
        didSet {
            guard oldValue, !applying else { return }
            for case let pane as PaneView in arrangedSubviews { pane.needsLayout = true }
        }
    }

    override var dividerColor: NSColor { WorkSplitView.line }
    override var dividerThickness: CGFloat { 1 }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                   ofDividerAt dividerIndex: Int) -> NSRect {
        isVertical ? drawnRect.insetBy(dx: -3, dy: 0) : drawnRect.insetBy(dx: 0, dy: -3)
    }

    /// No pane narrower than a usable terminal, nor, one above another, shorter than its header and one.
    var minimum: CGFloat { PaneGroup.minimum + (isVertical ? 0 : PaneHeaderView.height) }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        let previous = arrangedSubviews[index].frame
        return (isVertical ? previous.minX : previous.minY) + minimum
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        guard index + 1 < arrangedSubviews.count else { return proposed }
        let next = arrangedSubviews[index + 1].frame
        return (isVertical ? next.maxX : next.maxY) - minimum
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

// MARK: - pane headers

extension PaneGroup {
    /// Each pane's header follows its terminal: its title, its mark, its server mark.
    func refreshHeaders() {
        for tab in panes { paneViews[tab.id]?.header.update() }
    }
}

extension TerminalWindowController {
    /// With the tab bar: the headers of every split tab follow their panes.
    func refreshPaneHeaders() {
        for group in groups where group.isSplit { group.refreshHeaders() }
    }

    /// A header's ×: that pane alone, asking first as ⌘W on it does.
    func closePane(_ tab: TerminalTab) { requestClose(tab) }

    /// A click on a header gives its pane the keyboard, as a click in its terminal does.
    func focusPane(_ tab: TerminalTab) {
        guard group(of: tab) != nil else { return }
        window?.makeFirstResponder(tab.view)
    }

    /// A header's rename names its pane, as the tab bar's names the pane with the keyboard; empty goes back
    /// to the automatic title.
    func renamePane(_ tab: TerminalTab, to title: String?) {
        tab.userTitle = title
        refresh()
    }

    /// The rename ended (Return or Esc): the keyboard goes back to the pane once the field editor has let go,
    /// unless a click put it somewhere else.
    func paneRenameEnded(_ tab: TerminalTab) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, self.group(of: tab) === self.activeGroup,
                  window.firstResponder === window || window.firstResponder == nil else { return }
            window.makeFirstResponder(tab.view)
        }
    }
}
