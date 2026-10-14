import AppKit
import NextTermCore

/// What the tab list asks of its window: the top bar's calls, turned to the list, and the pane rows' and the width's.
protocol TabListViewDelegate: AnyObject {
    func tabList(_ list: TabListView, didSelect index: Int)
    /// A pane's row was clicked: its tab comes forward and that pane (`pane`, its place in the tab) takes the
    /// keyboard.
    func tabList(_ list: TabListView, didSelectPane pane: Int, of index: Int)
    func tabList(_ list: TabListView, didClose index: Int)
    func tabList(_ list: TabListView, didMove from: Int, to: Int)
    /// `title` nil means "back to the automatic title".
    func tabList(_ list: TabListView, didRename index: Int, to title: String?)
    /// Rename finished or was cancelled; focus can go back to the terminal.
    func tabListDidEndEditing(_ list: TabListView)
    func tabListDidRequestNewTab(_ list: TabListView)
    /// A tab's right-click menu: what it says acts on that tab, selected or not.
    func tabList(_ list: TabListView, menuFor index: Int) -> NSMenu?
    /// The list's width is about to change (its edge pressed, or it collapses or opens): the terminals keep their
    /// width until it is let go, so they change size once.
    func tabListWillResize(_ list: TabListView)
    /// Let go at `width` (the width it opens at, when collapsed): the window keeps it, and the terminals take the
    /// rest.
    func tabList(_ list: TabListView, didResizeTo width: CGFloat, collapsed: Bool)
}

/// The terminal's tabs as a list down the terminal's left or right, under its bar: the top bar's tabs turned on their
/// side. Fed as the bar is, from the window's tick, and as sparing: rows are matched to their views by key, so a tab
/// opening or closing adds or removes its own rows while every other row keeps its view (its spinner's turn, its
/// hover); the list lays out again only when the rows, their order, the density or the collapsed form change, and a
/// row's own change touches that row alone. Rows are plain views with frames set by hand in a flipped document,
/// never a table: a table would take the keyboard on a click and reload its rows.
final class TabListView: NSView {
    weak var delegate: TabListViewDelegate?
    /// The side of the terminal it sits on: the selected row's edge and the chevron's direction follow it.
    var side: TabListSide = .left { didSet { if side != oldValue { sideChanged() } } }
    /// The width it opens at, as the window keeps it.
    var openWidth: CGFloat = TabListWidth.defaultWidth

    /// Scrolling the selected tab into view, as the bar's tabs slide; at once under Reduce Motion.
    static let revealDuration: TimeInterval = 0.15
    /// The edge chips' distance from the list's top and bottom.
    private static let chipInset: CGFloat = 6

    private(set) var rows: [TabListRow] = []
    private(set) var selectedIndex = 0
    private(set) var density: TabListDensity = .oneLine
    private(set) var isCollapsed = false
    /// In the rows' order: a tab's row, then its panes'.
    private(set) var rowViews: [TabListRowView] = []
    /// Each row's tab, and each tab's own row.
    private(set) var tabOfRow: [Int] = []
    private(set) var tabRows: [Int] = []
    private var tabStates: [TabState] = []
    /// The rows' frames as last laid out.
    private(set) var rowLayout = TabListLayout(kinds: [], density: .oneLine, width: 0)

    let scrollView = NSScrollView()
    let document = TabListDocument()
    /// Collapsed: the chevron at the top that opens the list, and the "+3" for the tabs there is no room for.
    private let chevron = HoverButton()
    private let moreButton = HoverButton()
    /// How many marks the collapsed column shows, and where its last one ends.
    private var columnShown = 0
    private var columnBottom: CGFloat = 0
    private let chipAbove = TabListChipButton(below: false)
    private let chipBelow = TabListChipButton(below: true)
    private(set) var chips = TabListChips(above: nil, below: nil)
    /// What the chips say, nil where none shows (for the self-test too).
    private(set) var chipWords: (above: String?, below: String?) = (nil, nil)
    /// The selected tab scrolls into view at the next layout, when the selection or the list's form changed:
    /// sliding there when only the selection moved.
    private var revealPending: Bool?
    private var toolTipsScheduled = false

    /// What `update` was last given while a row was dragged: the views are in drag order, not the model's, until
    /// the drop, which applies it.
    struct Update {
        var rows: [TabListRow]
        var selectedIndex: Int
        var density: TabListDensity
        var collapsed: Bool
    }
    var isDragging = false
    var pendingUpdate: Update?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.bar.cgColor
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        document.list = self
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.setAccessibilityElement(false) // the rows are the tab group's own
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)

        chevron.bezelStyle = .regularSquare
        chevron.isBordered = false
        chevron.contentTintColor = Theme.textDim
        chevron.target = self
        chevron.action = #selector(expandClicked)
        chevron.refusesFirstResponder = true
        chevron.toolTip = "Show the tab list"
        chevron.setAccessibilityLabel("Expand Tab List")
        chevron.isHidden = true
        updateChevron()
        addSubview(chevron)
        moreButton.bezelStyle = .regularSquare
        moreButton.isBordered = false
        moreButton.target = self
        moreButton.action = #selector(expandClicked)
        moreButton.refusesFirstResponder = true
        moreButton.isHidden = true
        addSubview(moreButton)
        for chip in [chipAbove, chipBelow] {
            chip.target = self
            chip.action = #selector(chipClicked(_:))
            addSubview(chip) // over the rows
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Terminal tabs")
        setAccessibilityOrientation(.vertical)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: update

    /// Called several times a second: only what changed is touched.
    func update(rows newRows: [TabListRow], selectedIndex newSelected: Int, density newDensity: TabListDensity, collapsed newCollapsed: Bool) {
        if isDragging {
            pendingUpdate = Update(rows: newRows, selectedIndex: newSelected, density: newDensity, collapsed: newCollapsed)
            return
        }
        let rowsChanged: Bool = newRows.count != rows.count || zip(newRows, rows).contains { new, old in new.key != old.key || new.kind != old.kind }
        if rowsChanged { match(newRows) }
        // A server mark before some title moves every title of its kind over, so they line up; with two lines a
        // tab's mark is on its second line instead.
        let paneRemote: Bool = newRows.contains { $0.isPane && $0.remote != nil }
        let tabRemote: Bool = newDensity == .oneLine && newRows.contains { !$0.isPane && $0.remote != nil }
        for (index, row) in newRows.enumerated() {
            let view = rowViews[index]
            view.side = side
            view.density = newDensity
            view.collapsed = newCollapsed
            view.remoteColumn = row.isPane ? paneRemote : tabRemote
            view.configure(row: row, selected: tabOfRow[index] == newSelected)
        }
        var widestKey: CGFloat = 0
        for view in rowViews where !view.isPane { widestKey = max(widestKey, view.hintWidth) }
        for view in rowViews where !view.isPane { view.listHintWidth = widestKey }

        let newStates: [TabState] = tabRows.map { newRows[$0].state }
        let statesChanged = newStates != tabStates
        let selectionChanged = newSelected != selectedIndex
        let formChanged = newDensity != density || newCollapsed != isCollapsed
        rows = newRows
        tabStates = newStates
        selectedIndex = newSelected
        density = newDensity
        if newCollapsed != isCollapsed {
            isCollapsed = newCollapsed
            collapsedChanged()
        }
        if selectionChanged || formChanged { revealPending = selectionChanged && !formChanged }
        if rowsChanged || formChanged || selectionChanged {
            needsLayout = true // which brings the selected tab into view, and the chips up to date
        } else if statesChanged {
            updateChips()
            if isCollapsed { updateMore() }
        }
    }

    /// The rows' views for `newRows`: a view kept for each key still there, a new one for each new key, and the
    /// views of keys gone removed.
    private func match(_ newRows: [TabListRow]) {
        var spare: [String: [TabListRowView]] = [:]
        for (row, view) in zip(rows, rowViews) { spare[row.key, default: []].append(view) }
        var views: [TabListRowView] = []
        views.reserveCapacity(newRows.count)
        for row in newRows {
            if let kept = spare[row.key]?.popLast() {
                views.append(kept)
                continue
            }
            let view = TabListRowView()
            view.list = self
            document.addSubview(view)
            views.append(view)
        }
        for gone in spare.values.joined() { gone.removeFromSuperview() }
        rowViews = views
        var tabs: [Int] = []
        var owners: [Int] = []
        owners.reserveCapacity(newRows.count)
        for (index, row) in newRows.enumerated() {
            if !row.isPane || tabs.isEmpty { tabs.append(index) }
            owners.append(tabs.count - 1)
        }
        tabRows = tabs
        tabOfRow = owners
    }

    private func collapsedChanged() {
        scrollView.verticalScrollElasticity = isCollapsed ? .none : .automatic
        scrollView.hasVerticalScroller = !isCollapsed
        chevron.isHidden = !isCollapsed
        if !isCollapsed { moreButton.isHidden = true }
    }

    private func sideChanged() {
        rowViews.forEach { $0.side = side }
        updateChevron()
    }

    /// The chevron points the way the list opens: toward the terminal.
    private func updateChevron() {
        let symbol = side.expandPointsLeft ? "chevron.left" : "chevron.right"
        chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Expand Tab List")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    }

    // MARK: layout

    override func layout() {
        super.layout()
        #if DEBUG
        layoutCount += 1
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true) // a re-layout never animates by accident
        if scrollView.frame != bounds {
            scrollView.frame = bounds
            scrollView.tile() // its content size, which the rows' width comes from, at once
        }
        if isCollapsed { layoutColumn() } else { layoutRows() }
        CATransaction.commit()
        if let animated = revealPending {
            revealPending = nil
            scroll(toTab: selectedIndex, animated: animated)
        }
        updateChips()
        placeChips()
        scheduleToolTips()
    }

    private func layoutRows() {
        let width: CGFloat = scrollView.contentSize.width
        let layout = TabListLayout(rows: rows, density: density, width: width)
        rowLayout = layout
        let size = NSSize(width: width, height: max(layout.contentHeight, scrollView.contentSize.height))
        if document.frame.size != size { document.setFrameSize(size) }
        for (index, view) in rowViews.enumerated() where !view.isDragging {
            view.isHidden = false
            view.frame = layout.frames[index]
        }
        chevron.isHidden = true
        moreButton.isHidden = true
    }

    /// Collapsed: a column of marks under the chevron, as the terminal rail's, and no scrolling; when not all fit,
    /// the last place says how many more.
    private func layoutColumn() {
        let column = TabListLayout.collapsed(tabCount: tabRows.count, height: bounds.height)
        let size: NSSize = scrollView.contentSize
        if document.frame.size != size { document.setFrameSize(size) }
        let clip = scrollView.contentView
        if clip.bounds.origin != .zero {
            clip.setBoundsOrigin(.zero)
            scrollView.reflectScrolledClipView(clip)
        }
        let slotX: CGFloat = ((bounds.width - TabListCollapsed.slotSize) / 2).rounded()
        for (index, view) in rowViews.enumerated() where !view.isDragging {
            let slot: CGRect? = view.isPane ? nil : column.slots[safe: tabOfRow[index]]
            view.isHidden = slot == nil
            if let slot { view.frame = slot.offsetBy(dx: slotX, dy: 0) }
        }
        chevron.isHidden = false
        chevron.frame = NSRect(x: 0, y: 0, width: bounds.width, height: TabListCollapsed.chevronStrip)
        columnShown = column.shownCount
        let lastSlot: CGRect? = column.more ?? column.slots.last
        columnBottom = lastSlot?.maxY ?? TabListCollapsed.chevronStrip
        moreButton.isHidden = column.more == nil
        if let more = column.more {
            moreButton.frame = more.offsetBy(dx: slotX, dy: 0)
            updateMore()
        }
    }

    /// The collapsed column's "+3", in the colour of the most urgent of the tabs it stands for.
    private func updateMore() {
        guard !moreButton.isHidden else { return }
        let hidden: [Int] = Array(tabRows.dropFirst(columnShown))
        let state: TabState = TabListCollapsed.moreState(hidden.map { rows[$0].state })
        let color: NSColor = state == .idle || state == .working ? Theme.textDim : StatusGlyph.color(for: state)
        moreButton.attributedTitle = NSAttributedString(string: "+\(hidden.count)", attributes: [
            .foregroundColor: color, .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
        ])
        let names: [String] = hidden.map { rows[$0].accessibilityLabel }
        let tip = "\(hidden.count) more tab\(hidden.count == 1 ? "" : "s"): " + names.joined(separator: "; ")
        if moreButton.toolTip != tip { moreButton.toolTip = tip } // re-setting a tooltip resets it
        moreButton.setAccessibilityLabel(tip)
    }

    // MARK: scrolling and the edge chips

    /// Scrolls the least that shows tab `index`'s row, with its panes when they fit.
    func scroll(toTab index: Int, animated: Bool) {
        let clip = scrollView.contentView
        guard !isCollapsed, let target = rowLayout.scrollTarget(selected: index, visible: clip.bounds) else { return }
        let origin = NSPoint(x: 0, y: target)
        if animated && !AgentSpinner.reducesMotion {
            NSAnimationContext.runAnimationGroup { (context: NSAnimationContext) in
                context.duration = Self.revealDuration
                clip.animator().setBoundsOrigin(origin)
            }
        } else {
            clip.setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    @objc private func scrolled() {
        updateChips()
        scheduleToolTips()
    }

    /// A chip at each edge where a tab out of view is done, failed or needs you; touched only when what it says
    /// changes.
    private func updateChips() {
        let visible: NSRect = scrollView.contentView.bounds
        let none = TabListChips(above: nil, below: nil)
        let new: TabListChips = isCollapsed ? none : rowLayout.hidden(states: tabStates, visible: visible)
        let words: (above: String?, below: String?) = new == none ? (nil, nil) : rowLayout.chipWords(states: tabStates, visible: visible)
        guard new != chips || words != chipWords else { return }
        chips = new
        chipWords = words
        chipAbove.configure(new.above, words: words.above)
        chipBelow.configure(new.below, words: words.below)
        placeChips()
    }

    private func placeChips() {
        let height: CGFloat = TabListChipButton.height
        let places: [(TabListChipButton, CGFloat)] = [(chipAbove, Self.chipInset), (chipBelow, bounds.height - Self.chipInset - height)]
        for (chip, y) in places where !chip.isHidden {
            let width: CGFloat = min(chip.width, bounds.width)
            chip.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: y, width: width, height: height)
        }
    }

    @objc private func chipClicked(_ sender: TabListChipButton) {
        let chip: TabListChip? = sender === chipAbove ? chips.above : chips.below
        guard let chip else { return }
        scroll(toTab: chip.target, animated: true)
    }

    /// For the self-test: a click on the chip at the top or the bottom.
    func clickChip(below: Bool) { (below ? chipBelow : chipAbove).performClick(nil) }

    // MARK: tooltips

    /// One tooltip area over the rows in view, which asks for the row under the pointer when it shows: a tooltip set
    /// on a row itself stays live while the row is scrolled out of sight, over whatever is there (the bar above, or
    /// the editor below). Replaced on the next turn of the run loop, never at once: AppKit's display pass may be
    /// reading it.
    private func scheduleToolTips() {
        guard !toolTipsScheduled else { return }
        toolTipsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            toolTipsScheduled = false
            document.removeAllToolTips()
            document.addToolTip(document.visibleRect, owner: TabListToolTipOwner.shared, userData: nil)
        }
    }

    /// The tooltip at `point`, in the document: the × under the pointer, else its row's.
    func rowToolTip(at point: NSPoint) -> String {
        guard document.visibleRect.contains(point),
              let view = rowViews.first(where: { !$0.isHidden && $0.frame.contains(point) }) else { return "" }
        if view.closeContains(view.convert(point, from: document)) {
            return KeyboardShortcuts.shared.hint("Close tab", #selector(TerminalWindowController.closeTab(_:)))
        }
        return view.toolTipText
    }

    // MARK: collapsing

    /// Collapses the list to its column of marks, or opens it at its width; the window holds the terminals' width
    /// meanwhile, so they change size once.
    func toggleCollapsed() {
        let next = TabListWidth.toggled(width: openWidth, shownCollapsed: isCollapsed)
        delegate?.tabListWillResize(self)
        delegate?.tabList(self, didResizeTo: next.width, collapsed: next.collapsed)
    }

    @objc private func expandClicked() {
        guard isCollapsed else { return }
        toggleCollapsed()
    }

    // MARK: rename

    var isEditing: Bool { rowViews.contains { $0.isEditing } }

    /// The field on tab `index`'s row, brought into view first; a collapsed list opens for it.
    func beginRename(at index: Int) {
        guard tabRows.indices.contains(index) else { return }
        if isCollapsed {
            toggleCollapsed()
            window?.layoutIfNeeded()
            guard !isCollapsed else { return } // no room to open it
        }
        layoutSubtreeIfNeeded()
        scroll(toTab: index, animated: false)
        rowViews[safe: tabRows[index]]?.beginRename()
    }

    // MARK: called by the rows and the document

    /// A row's place in the list and its tab's.
    private func place(of view: TabListRowView) -> (row: Int, tab: Int)? {
        guard let index = rowViews.firstIndex(where: { $0 === view }), rows.indices.contains(index), tabOfRow.indices.contains(index) else { return nil }
        return (index, tabOfRow[index])
    }

    func rowMouseDown(_ view: TabListRowView, event: NSEvent) {
        guard let place = place(of: view) else { return }
        if case .pane(let pane, _) = rows[place.row].kind {
            delegate?.tabList(self, didSelectPane: pane, of: place.tab)
            return
        }
        if event.clickCount == 2, !isCollapsed {
            view.beginRename()
            return
        }
        delegate?.tabList(self, didSelect: place.tab)
    }

    /// VoiceOver's press: as a click.
    func rowPressed(_ view: TabListRowView) -> Bool {
        guard let place = place(of: view) else { return false }
        if case .pane(let pane, _) = rows[place.row].kind {
            delegate?.tabList(self, didSelectPane: pane, of: place.tab)
        } else {
            delegate?.tabList(self, didSelect: place.tab)
        }
        return true
    }

    /// A middle click closes a tab; on a pane's row it closes nothing, as the pane's row has no ×.
    func rowMiddleClicked(_ view: TabListRowView) {
        guard let place = place(of: view), !view.isPane else { return }
        delegate?.tabList(self, didClose: place.tab)
    }

    func rowClose(_ view: TabListRowView) {
        guard let place = place(of: view) else { return }
        delegate?.tabList(self, didClose: place.tab)
    }

    /// A pane's row has its tab's menu.
    func rowMenu(_ view: TabListRowView) -> NSMenu? {
        place(of: view).flatMap { menu(forTabAt: $0.tab) }
    }

    /// A tab's right-click menu (for the self-test too).
    func menu(forTabAt index: Int) -> NSMenu? {
        guard tabRows.indices.contains(index) else { return nil }
        return delegate?.tabList(self, menuFor: index)
    }

    func rowRenamed(_ view: TabListRowView, to title: String?) {
        guard let place = place(of: view) else { return }
        delegate?.tabList(self, didRename: place.tab, to: title)
    }

    func rowEndedEditing(_ view: TabListRowView) {
        delegate?.tabListDidEndEditing(self)
    }

    /// A double-click under the last row opens a tab, as the bar's + does.
    func documentMouseDown(_ event: NSEvent) {
        guard event.clickCount == 2 else { return }
        let point = document.convert(event.locationInWindow, from: nil)
        let lastRow: CGFloat = isCollapsed ? columnBottom : rowLayout.contentHeight
        if point.y >= lastRow { delegate?.tabListDidRequestNewTab(self) }
    }

    // MARK: VoiceOver

    /// The chevron and the top chip, the rows in order, then the bottom chip and the "+3".
    override func accessibilityChildren() -> [Any]? {
        let before: [NSView] = [chevron, chipAbove].filter { !$0.isHidden }
        let after: [NSView] = [chipBelow, moreButton].filter { !$0.isHidden }
        let shown: [Any] = rowViews.filter { !$0.isHidden }
        return NSAccessibility.unignoredChildren(from: before) + shown + NSAccessibility.unignoredChildren(from: after)
    }

    // MARK: for the self-test

    /// A row's view, in the rows' order (a split tab's panes after it), and tab `index`'s own row.
    func rowView(at index: Int) -> TabListRowView? { rowViews[safe: index] }
    func tabRowView(at index: Int) -> TabListRowView? { tabRows[safe: index].flatMap { rowViews[safe: $0] } }

    #if DEBUG
    /// How often the list laid out, for the self-test's budget.
    private(set) var layoutCount = 0

    func resetCounters() {
        layoutCount = 0
        rowViews.forEach { $0.resetCounters() }
    }
    #endif
}

/// The rows' document in the list's scroll view: flipped, so the rows go down from its top.
final class TabListDocument: NSView {
    weak var list: TabListView?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        list?.documentMouseDown(event)
    }
}

/// The owner AppKit asks for a row's tooltip. AppKit does not keep a tooltip's owner alive, so it is one object for
/// the app's life; it asks the list the document belongs to, and a list that has gone has nothing to show.
private final class TabListToolTipOwner: NSObject {
    static let shared = TabListToolTipOwner()

    /// NSViewToolTipOwner.
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        (view as? TabListDocument)?.list?.rowToolTip(at: point) ?? ""
    }
}

/// "↓ 2" with the most urgent mark: the tabs out of view on that side that are done, failed or need you, drawn as
/// the top bar's "» N" is, on a pill of the terminal's colour over the rows. A click scrolls to the most urgent.
final class TabListChipButton: NSButton {
    static let height: CGFloat = 22
    private let dot = StatusDotView()
    private let below: Bool

    init(below: Bool) {
        self.below = below
        super.init(frame: .zero)
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        layer?.cornerRadius = Self.height / 2
        refusesFirstResponder = true // the list never takes the keyboard from the terminal
        addSubview(dot)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    func configure(_ chip: TabListChip?, words: String?) {
        guard let chip else {
            isHidden = true
            return
        }
        isHidden = false
        let arrow = below ? "↓" : "↑"
        let text = NSMutableAttributedString(string: "\(arrow) \(chip.count)", attributes: [
            .foregroundColor: Theme.textDim, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ])
        // Room for the mark after the count is kerning, not padding spaces. A chip always has a mark.
        text.addAttribute(.kern, value: 14, range: NSRange(location: text.length - 1, length: 1))
        attributedTitle = text
        dot.state = chip.state
        if toolTip != words { toolTip = words } // re-setting a tooltip resets it
        setAccessibilityLabel(words)
        needsLayout = true
    }

    /// The arrow, the count and the mark, with room either side.
    var width: CGFloat { ceil(attributedTitle.size().width) + 20 }

    override func layout() {
        super.layout()
        // At the end of the centred title, so a two-digit count never runs into it.
        let titleWidth: CGFloat = attributedTitle.size().width
        dot.frame = NSRect(x: (bounds.width + titleWidth) / 2 - 10, y: (bounds.height - 10) / 2, width: 10, height: 10)
    }
}
