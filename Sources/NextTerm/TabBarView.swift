import AppKit
import NextTermCore

struct TabBarItem: Equatable {
    var title: String
    /// Folder and program names keep both ends (as in Finder); a title a program sets is prose.
    var truncation: NSLineBreakMode = .byTruncatingMiddle
    var state: TabState
    var tooltip: String
    var accessibilityStatus: String
    /// Editor tabs: the file's icon in place of the status mark.
    var icon: NSImage? = nil
    /// Editor tabs: unsaved changes, shown as a dot in place of the close button (as in VS Code).
    var modified = false
    /// Terminal tabs: the shortcut that selects it ("⌘1"), shown before the close button.
    var shortcut: String? = nil
    /// Terminal tabs on a server: a server mark before the title, with the connection's dot on it.
    var remote: RemoteMark? = nil
    /// Shorter forms of the title, tried in order when it does not fit ("app (connecting)", then "app").
    var shorterTitles: [String] = []
    /// What the rename field starts with, if not the title: the name without a connection note or a port.
    var editableTitle: String? = nil
}

protocol TabBarViewDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, didSelect index: Int)
    func tabBar(_ bar: TabBarView, didClose index: Int)
    func tabBar(_ bar: TabBarView, didMove from: Int, to: Int)
    /// `title` nil means "back to the automatic title".
    func tabBar(_ bar: TabBarView, didRename index: Int, to title: String?)
    /// Rename finished or was cancelled; focus can go back to the terminal.
    func tabBarDidEndEditing(_ bar: TabBarView)
    func tabBarDidRequestNewTab(_ bar: TabBarView)
}

/// The tab strip along the top of the window, drawn in the title bar area.
final class TabBarView: NSView {
    static let height: CGFloat = 38
    /// Narrower than this and titles stop being readable: extra tabs go behind the » button instead.
    static let minTabWidth: CGFloat = 104
    static let maxTabWidth: CGFloat = 220
    static let newTabButtonWidth: CGFloat = 36
    static let overflowButtonWidth: CGFloat = 46

    weak var delegate: TabBarViewDelegate?
    /// Space reserved on the left for the traffic-light buttons.
    var leadingInset: CGFloat = 78 { didSet { needsLayout = true } }
    /// Terminal tabs: a + button, and double-click renames. Editor tabs have neither.
    var allowsNewTab = true { didSet { newTabButton.isHidden = !allowsNewTab; needsLayout = true } }
    var allowsRename = true
    /// At the top of the window, the empty part of the bar drags the window like a title bar.
    var dragsWindow = true
    /// A ⋯ button at the right end with this menu (the terminal's layout choices).
    var moreMenu: (() -> NSMenu)? {
        didSet {
            moreButton?.removeFromSuperview()
            moreButton = moreMenu.map { MoreButton(toolTip: "Terminal layout", menu: $0) }
            moreButton.map(addSubview)
            needsLayout = true
        }
    }
    private var moreButton: MoreButton?
    static let moreButtonWidth: CGFloat = 34

    /// With the project sidebar hidden, the bar at the window's top-left corner gets a button to show it
    /// again, just after the traffic lights.
    var showsSidebarButton = false {
        didSet {
            sidebarButton.isHidden = !showsSidebarButton
            needsLayout = true
        }
    }
    func setSidebarButton(onRight: Bool) {
        sidebarButton.image = NSImage(systemSymbolName: onRight ? "sidebar.right" : "sidebar.left", accessibilityDescription: "Show Project Sidebar")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    }
    private let sidebarButton = HoverButton()
    static let sidebarButtonWidth: CGFloat = 30
    private var tabsStart: CGFloat { leadingInset + (sidebarButton.isHidden ? 0 : Self.sidebarButtonWidth) }

    /// A button at the right end that shows the open file in the project sidebar (the editor's tab bar).
    var onReveal: (() -> Void)? {
        didSet {
            revealButton.isHidden = onReveal == nil
            needsLayout = true
        }
    }
    private let revealButton = HoverButton()
    private var revealWidth: CGFloat { revealButton.isHidden ? 0 : Self.collapseButtonWidth }

    /// A collapse/expand button before the ⋯ (the terminal, when the editor shares the window).
    var onToggleCollapse: (() -> Void)? {
        didSet {
            collapseButton.isHidden = onToggleCollapse == nil
            needsLayout = true
        }
    }
    /// The arrow points the way a click moves the bar: toward the window's edge to collapse, back to expand.
    func setCollapseButton(symbol: String, toolTip: String) {
        collapseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        collapseButton.toolTip = toolTip
        collapseButton.setAccessibilityLabel(toolTip)
    }
    private let collapseButton = HoverButton()
    static let collapseButtonWidth: CGFloat = 28
    private var collapseWidth: CGFloat { collapseButton.isHidden ? 0 : Self.collapseButtonWidth }

    /// The blue Update button (in the bar at the window's top-right corner, while an update waits).
    var onUpdate: (() -> Void)?
    func setUpdateButton(title: String?, symbol: String = "arrow.down.circle.fill", toolTip: String = "") {
        if let title { updateButton.configure(title: title, symbol: symbol, toolTip: toolTip) }
        updateButton.isHidden = title == nil
        needsLayout = true
    }
    let updateButton = UpdatePill()
    private var updateWidth: CGFloat { updateButton.isHidden ? 0 : updateButton.width + 8 }

    /// The title for the accessibility tab group and the close button's tooltip.
    var kind = "tab" { didSet { setAccessibilityLabel(kind == "tab" ? "Terminal tabs" : "Editor tabs") } }

    private(set) var items: [TabBarItem] = []
    private(set) var selectedIndex = 0
    private var tabViews: [TabItemView] = []
    private let newTabButton = NSButton()
    /// "» 3": the tabs that do not fit, with the most urgent status among them.
    private let overflowButton = OverflowButton()
    /// First tab shown when not all fit; moves so the selected tab is always visible.
    private var firstVisible = 0
    private var dragging: (view: TabItemView, offset: CGFloat)?
    /// Updates that arrive mid-drag, applied on drop (views are in drag order, not model order, until then).
    private var pendingUpdate: (items: [TabBarItem], selected: Int)?

    var isEditing: Bool { tabViews.contains { $0.isEditing } }

    /// The shortcut a tab shows, if there is room for it (for the self-test).
    func shownShortcut(at index: Int) -> String? { tabViews[safe: index]?.shownShortcut }
    /// The connection a tab's server mark shows, and what VoiceOver says for the tab (for the self-test).
    func shownRemoteLink(at index: Int) -> RemoteLink? { tabViews[safe: index]?.shownRemoteLink }
    func shownTitle(at index: Int) -> String? { tabViews[safe: index]?.shownTitle }
    func spokenLabel(at index: Int) -> String? { tabViews[safe: index]?.accessibilityLabel() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.bar.cgColor

        newTabButton.bezelStyle = .regularSquare
        newTabButton.isBordered = false
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        newTabButton.contentTintColor = Theme.textDim
        newTabButton.toolTip = "New tab (⌘T)"
        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked)
        addSubview(newTabButton)
        collapseButton.bezelStyle = .regularSquare
        collapseButton.isBordered = false
        collapseButton.contentTintColor = Theme.textDim
        collapseButton.target = self
        collapseButton.action = #selector(collapseClicked)
        collapseButton.isHidden = true
        addSubview(collapseButton)
        revealButton.bezelStyle = .regularSquare
        revealButton.isBordered = false
        revealButton.contentTintColor = Theme.textDim
        revealButton.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "Show in Project Sidebar")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        revealButton.toolTip = "Show this file in the project sidebar"
        revealButton.setAccessibilityLabel("Show in Project Sidebar")
        revealButton.target = self
        revealButton.action = #selector(revealClicked)
        revealButton.isHidden = true
        addSubview(revealButton)
        updateButton.isBordered = false
        updateButton.bezelStyle = .regularSquare
        updateButton.target = self
        updateButton.action = #selector(updateClicked)
        updateButton.isHidden = true
        addSubview(updateButton)
        sidebarButton.bezelStyle = .regularSquare
        sidebarButton.isBordered = false
        sidebarButton.contentTintColor = Theme.textDim
        sidebarButton.action = #selector(TerminalWindowController.toggleProjectSidebar(_:)) // up the responder chain
        sidebarButton.toolTip = "Show the project sidebar (⌘B)"
        sidebarButton.setAccessibilityLabel("Show Project Sidebar")
        sidebarButton.isHidden = true
        setSidebarButton(onRight: false)
        addSubview(sidebarButton)

        overflowButton.target = self
        overflowButton.action = #selector(showOverflowMenu)
        overflowButton.isHidden = true
        addSubview(overflowButton)

        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Terminal tabs")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func update(items newItems: [TabBarItem], selectedIndex newSelected: Int) {
        if dragging != nil {
            pendingUpdate = (newItems, newSelected)
            return
        }
        let countChanged = newItems.count != tabViews.count
        if countChanged {
            tabViews.forEach { $0.removeFromSuperview() }
            tabViews = newItems.indices.map { _ in
                let view = TabItemView()
                view.bar = self
                addSubview(view, positioned: .below, relativeTo: newTabButton)
                return view
            }
        }
        let hasRemote = newItems.contains { $0.remote != nil }
        for (i, item) in newItems.enumerated() {
            tabViews[i].barHasRemote = hasRemote
            tabViews[i].configure(item: item, selected: i == newSelected)
        }
        let selectionChanged = newSelected != selectedIndex
        items = newItems
        selectedIndex = newSelected
        if countChanged || selectionChanged { needsLayout = true }
        updateOverflowButton()
    }

    func beginRename(at index: Int) {
        if !visibleRange.contains(index) {
            needsLayout = true
            layoutSubtreeIfNeeded() // bring the selected tab into view first
        }
        tabViews[safe: index]?.beginRename()
    }

    // MARK: layout

    /// Width for tabs, keeping a strip on the right for dragging the window.
    private var availableWidth: CGFloat {
        max(0, bounds.width - tabsStart - (allowsNewTab ? Self.newTabButtonWidth : 0) - (moreButton == nil ? 0 : Self.moreButtonWidth)
            - collapseWidth - revealWidth - updateWidth - 24)
    }

    /// How many tabs fit at a readable width.
    private var capacity: Int {
        let all = Int(availableWidth / Self.minTabWidth)
        if tabViews.count <= all { return tabViews.count }
        return max(1, Int((availableWidth - Self.overflowButtonWidth) / Self.minTabWidth))
    }

    var isOverflowing: Bool { capacity < tabViews.count }

    /// Indices of the tabs on screen.
    var visibleRange: Range<Int> {
        let shown = capacity
        if shown >= tabViews.count { return 0..<tabViews.count }
        var first = min(max(firstVisible, 0), tabViews.count - shown)
        if selectedIndex < first { first = selectedIndex }
        if selectedIndex >= first + shown { first = selectedIndex - shown + 1 }
        return first..<(first + shown)
    }

    private var tabWidth: CGFloat {
        let shown = max(1, capacity)
        let room = availableWidth - (isOverflowing ? Self.overflowButtonWidth : 0)
        return min(Self.maxTabWidth, max(Self.minTabWidth, (room / CGFloat(shown)).rounded(.down)))
    }

    private func frameForTab(at index: Int) -> NSRect {
        let slot = CGFloat(index - visibleRange.lowerBound)
        return NSRect(x: tabsStart + slot * tabWidth, y: 0, width: tabWidth, height: bounds.height - 1)
    }

    override func layout() {
        super.layout()
        let range = visibleRange
        firstVisible = range.lowerBound
        for (i, view) in tabViews.enumerated() where view !== dragging?.view {
            view.isHidden = !range.contains(i)
            if !view.isHidden { view.frame = frameForTab(at: i) }
        }
        var x = tabsStart + CGFloat(range.count) * tabWidth
        sidebarButton.frame = NSRect(x: leadingInset, y: 0, width: Self.sidebarButtonWidth, height: bounds.height - 1)
        overflowButton.isHidden = !isOverflowing
        if isOverflowing {
            overflowButton.frame = NSRect(x: x, y: 0, width: Self.overflowButtonWidth, height: bounds.height - 1)
            x += Self.overflowButtonWidth
        }
        let more: CGFloat = moreButton == nil ? 0 : Self.moreButtonWidth
        newTabButton.frame = NSRect(x: min(x, bounds.width - Self.newTabButtonWidth - more - collapseWidth - revealWidth - updateWidth), y: 0,
                                    width: Self.newTabButtonWidth, height: bounds.height - 1)
        moreButton?.frame = NSRect(x: bounds.width - Self.moreButtonWidth - 4, y: 0, width: Self.moreButtonWidth, height: bounds.height - 1)
        collapseButton.frame = NSRect(x: bounds.width - more - 4 - Self.collapseButtonWidth, y: 0,
                                      width: Self.collapseButtonWidth, height: bounds.height - 1)
        revealButton.frame = NSRect(x: bounds.width - more - 4 - collapseWidth - Self.collapseButtonWidth, y: 0,
                                    width: Self.collapseButtonWidth, height: bounds.height - 1)
        if !updateButton.isHidden {
            let width = updateButton.width
            updateButton.frame = NSRect(x: bounds.width - more - 4 - collapseWidth - revealWidth - 4 - width, y: 0,
                                        width: width, height: bounds.height - 1)
        }
        updateOverflowButton()
    }

    /// The hidden tabs' count and their most urgent status (attention > failed > done > working).
    private func updateOverflowButton() {
        guard isOverflowing else { return }
        let range = visibleRange
        let hidden = items.indices.filter { !range.contains($0) }.map { items[$0].state }
        let urgency: [TabState] = [.attention, .failed, .done, .working]
        overflowButton.configure(hiddenCount: hidden.count, state: urgency.first(where: hidden.contains) ?? .idle)
    }

    @objc private func collapseClicked() { onToggleCollapse?() }
    @objc private func revealClicked() { onReveal?() }
    @objc private func updateClicked() { onUpdate?() }

    @objc private func showOverflowMenu() {
        let menu = NSMenu()
        let range = visibleRange
        let listsRemote = items.contains { $0.remote != nil }
        for (i, item) in items.enumerated() {
            let title = Typography.shortened(item.title, to: 60) // the full title is in the tooltip
            let entry = NSMenuItem(title: title, action: #selector(overflowMenuSelected(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = i
            entry.image = listsRemote ? StatusGlyph.image(for: item.state, remote: item.remote) : StatusGlyph.image(for: item.state)
            entry.state = i == selectedIndex ? .on : .off
            entry.toolTip = item.tooltip
            // Tabs already on screen are dimmed; same menu font as the others.
            if range.contains(i) {
                entry.attributedTitle = NSAttributedString(string: title, attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 0),
                ])
            }
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: overflowButton.frame.minX, y: overflowButton.frame.maxY), in: self)
    }

    @objc private func overflowMenuSelected(_ sender: NSMenuItem) {
        delegate?.tabBar(self, didSelect: sender.tag)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: mouse on the empty part of the bar drags the window

    override func mouseDown(with event: NSEvent) {
        guard dragsWindow else { return }
        if event.clickCount == 2 {
            // Same as double-clicking any title bar: System Settings > Desktop & Dock decides.
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window?.performMiniaturize(nil)
            case "None": break
            default: window?.performZoom(nil)
            }
        } else {
            window?.performDrag(with: event)
        }
    }

    @objc private func newTabClicked() {
        delegate?.tabBarDidRequestNewTab(self)
    }

    // MARK: called by TabItemView

    fileprivate func index(of view: TabItemView) -> Int? {
        tabViews.firstIndex { $0 === view }
    }

    fileprivate func itemMouseDown(_ view: TabItemView, event: NSEvent) {
        guard let index = index(of: view) else { return }
        if event.clickCount == 2 {
            if allowsRename { view.beginRename() }
            return
        }
        delegate?.tabBar(self, didSelect: index)
        trackDrag(of: view, from: event)
    }

    fileprivate func itemClose(_ view: TabItemView) {
        guard let index = index(of: view) else { return }
        delegate?.tabBar(self, didClose: index)
    }

    fileprivate func itemRenamed(_ view: TabItemView, to title: String?) {
        guard let index = index(of: view) else { return }
        delegate?.tabBar(self, didRename: index, to: title)
    }

    fileprivate func itemEndedEditing(_ view: TabItemView) {
        delegate?.tabBarDidEndEditing(self)
    }

    /// Drag a tab sideways to reorder; the other tabs slide out of the way.
    private func trackDrag(of view: TabItemView, from event: NSEvent) {
        guard let window, tabViews.count > 1, let startIndex = index(of: view) else { return }
        let startX = convert(event.locationInWindow, from: nil).x
        let grabOffset = startX - view.frame.minX
        var moved = false

        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { stop.pointee = true; return }
            let x = self.convert(event.locationInWindow, from: nil).x
            if event.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            if !moved && abs(x - startX) < 4 { return }
            if !moved {
                moved = true
                self.dragging = (view, grabOffset)
                view.isDragging = true
            }
            let range = self.visibleRange
            let minX = self.tabsStart
            let maxX = self.tabsStart + CGFloat(range.count - 1) * self.tabWidth
            view.frame.origin.x = min(max(x - grabOffset, minX), maxX)
            // Reorder the array live as the dragged tab's centre crosses its neighbours (within the visible tabs).
            let centre = view.frame.midX - self.tabsStart
            let target = min(max(Int(centre / self.tabWidth) + range.lowerBound, range.lowerBound), range.upperBound - 1)
            if let current = self.index(of: view), current != target {
                self.tabViews.remove(at: current)
                self.tabViews.insert(view, at: target)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    for (i, other) in self.tabViews.enumerated() where other !== view {
                        other.animator().frame = self.frameForTab(at: i)
                    }
                }
            }
        }

        guard moved else { return }
        dragging = nil
        view.isDragging = false
        let pending = pendingUpdate
        pendingUpdate = nil
        if let pending, pending.items.count != tabViews.count {
            // A tab opened or closed mid-drag: the positions no longer mean anything. Drop the reorder.
            update(items: pending.items, selectedIndex: pending.selected)
            return
        }
        let endIndex = index(of: view) ?? startIndex
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            view.animator().frame = frameForTab(at: endIndex)
        }
        if endIndex != startIndex {
            // Restore the model order; the delegate moves the tab and calls update(items:).
            tabViews.remove(at: endIndex)
            tabViews.insert(view, at: startIndex)
            delegate?.tabBar(self, didMove: startIndex, to: endIndex) // refreshes us with current items
            needsLayout = true
        } else if let pending {
            update(items: pending.items, selectedIndex: pending.selected)
        }
    }
}

// MARK: - one tab

private final class TabItemView: NSView, NSTextFieldDelegate {
    weak var bar: TabBarView?
    private let dot = StatusDotView()
    private let iconView = NSImageView()
    /// A remote tab's server mark, between the status mark and the title.
    private let remoteMark = RemoteMarkView()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    /// "⌘1": how to get to this tab from the keyboard.
    private let hint = NSTextField(labelWithString: "")
    private var renameField: NSTextField?
    private var hovering = false { didSet { refresh() } }
    private var selected = false
    var isDragging = false { didSet { alphaValue = isDragging ? 0.85 : 1; layer?.zPosition = isDragging ? 10 : 0 } }
    /// Some tab in the bar runs on a server: every tab then leaves "⌘2" the room a remote one has (its title
    /// starts after the server mark), so all of them show it or none does.
    var barHasRemote = false { didSet { if barHasRemote != oldValue { needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        label.font = .systemFont(ofSize: 12.5)
        Typography.singleLine(label, truncation: .byTruncatingMiddle)
        addSubview(label)
        addSubview(dot)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isHidden = true
        addSubview(iconView)
        remoteMark.isHidden = true
        addSubview(remoteMark)

        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.contentTintColor = Theme.textDim
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close tab (⌘W)"
        addSubview(closeButton)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Theme.textDim
        hint.alignment = .right
        Typography.singleLine(hint, truncation: .byClipping)
        hint.isHidden = true
        hint.setAccessibilityElement(false) // said in the tab's own help instead
        addSubview(hint)

        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var item: TabBarItem?
    var shownShortcut: String? { hint.isHidden ? nil : hint.stringValue }

    // Called several times a second: touch only what changed (re-setting a tooltip resets it).
    func configure(item newItem: TabBarItem, selected isSelected: Bool) {
        guard newItem != item || isSelected != selected else { return }
        if newItem.title != item?.title || newItem.shorterTitles != item?.shorterTitles {
            label.stringValue = newItem.title
            if !newItem.shorterTitles.isEmpty { needsLayout = true } // layout may shorten it
        }
        if label.lineBreakMode != newItem.truncation { label.lineBreakMode = newItem.truncation }
        let tip = newItem.tooltip + (newItem.shortcut.map { "\n\($0) switches to this tab" } ?? "")
        if toolTip != tip { toolTip = tip }
        if hint.stringValue != newItem.shortcut ?? "" {
            hint.stringValue = newItem.shortcut ?? ""
            needsLayout = true
        }
        setAccessibilityHelp(newItem.shortcut.map { "\($0) switches to this tab" })
        dot.state = newItem.state
        if iconView.image !== newItem.icon { iconView.image = newItem.icon }
        iconView.isHidden = newItem.icon == nil
        dot.isHidden = newItem.icon != nil
        if (newItem.remote == nil) != (item?.remote == nil) { needsLayout = true } // the title moves over, or back
        remoteMark.link = newItem.remote?.link
        remoteMark.isHidden = newItem.remote == nil
        item = newItem
        selected = isSelected
        // "web-1: app (connecting), Remote: web-1 (deploy@203.0.113.5), connecting": a state that is only
        // the connection's comes once, in the remote part.
        let spoken = [newItem.title, newItem.accessibilityStatus, newItem.remote?.summary ?? ""]
        setAccessibilityLabel(spoken.filter { !$0.isEmpty }.joined(separator: ", "))
        setAccessibilityValue(isSelected)
        refresh()
    }

    /// For the self-test: the server mark's connection, if it shows one.
    var shownRemoteLink: RemoteLink? { remoteMark.isHidden ? nil : remoteMark.link }

    private func refresh() {
        layer?.backgroundColor = (selected ? Theme.background : hovering ? Theme.tabHover : .clear).cgColor
        label.textColor = selected || hovering ? Theme.text : Theme.textDim
        remoteMark.tint = label.textColor ?? Theme.textDim
        // Unsaved: a dot that turns into the close button under the pointer.
        let modified = item?.modified == true
        let closeHidden = !(selected || hovering || modified)
        if closeButton.isHidden != closeHidden {
            closeButton.isHidden = closeHidden
            needsLayout = true // the shortcut moves into its place, or out of it
        }
        let symbol = modified && !hovering ? "circle.fill" : "xmark"
        if closeButton.image?.accessibilityDescription != (symbol == "xmark" ? "Close Tab" : "Unsaved changes") {
            closeButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol == "xmark" ? "Close Tab" : "Unsaved changes")?
                .withSymbolConfiguration(.init(pointSize: symbol == "xmark" ? 9 : 7, weight: .semibold))
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        dot.frame = NSRect(x: 12, y: (h - 10) / 2, width: 10, height: 10)
        iconView.frame = NSRect(x: 10, y: (h - 16) / 2, width: 16, height: 16)
        closeButton.frame = NSRect(x: bounds.width - 24, y: (h - 18) / 2, width: 18, height: 18)
        // A remote tab: the status mark keeps its column (the same place on every tab), and the server
        // mark goes before the title, like an icon of the title.
        // Its server sits on the title's centre line; the dot hangs a point lower.
        remoteMark.frame = NSRect(x: 25, y: (h - 16) / 2, width: RemoteMarkView.size.width, height: RemoteMarkView.size.height)
        let remoteLabelX = remoteMark.frame.maxX + 3
        let labelX: CGFloat = remoteMark.isHidden ? 29 : remoteLabelX
        let labelHeight = label.intrinsicContentSize.height
        // The shortcut: in the close button's place while that is hidden, else just before it, as long as
        // the title keeps room to be read.
        let hintWidth = hint.stringValue.isEmpty ? 0 : ceil(hint.intrinsicContentSize.width)
        let titleStart = barHasRemote ? remoteLabelX : labelX
        func hintEnd(closeShown: Bool) -> CGFloat? {
            let end = closeShown ? bounds.width - 27 : bounds.width - 9
            return hintWidth == 0 || end - hintWidth - 6 - titleStart < (closeShown ? 56 : 40) ? nil : end
        }
        func titleWidth(hintEnd: CGFloat?) -> CGFloat {
            max(0, min(bounds.width - 28, hintEnd.map { $0 - hintWidth - 6 } ?? .infinity) - labelX)
        }
        // A remote tab's words are picked for the tab without its × (as most tabs are) and stay when the ×
        // shows, selected or under the pointer: its ⌘N gives way to them. Else the tab you are looking at
        // would say less, and a pointer passing over it would drop and add "web-1: " or "(connecting)".
        let restWidth = titleWidth(hintEnd: hintEnd(closeShown: false))
        let words = fittedTitle(within: restWidth)
        var shownHintEnd = hintEnd(closeShown: !closeButton.isHidden)
        if item?.shorterTitles.isEmpty == false, let words, fits(words, within: restWidth),
           !fits(words, within: titleWidth(hintEnd: shownHintEnd)) {
            shownHintEnd = nil
        }
        hint.isHidden = shownHintEnd == nil
        if let shownHintEnd {
            let hintHeight = hint.intrinsicContentSize.height
            hint.frame = NSRect(x: shownHintEnd - hintWidth, y: (h - hintHeight) / 2, width: hintWidth, height: hintHeight)
        }
        label.frame = NSRect(x: labelX, y: (h - labelHeight) / 2, width: titleWidth(hintEnd: shownHintEnd), height: labelHeight)
        if let words, label.stringValue != words { label.stringValue = words }
        renameField?.frame = NSRect(x: labelX - 3, y: (h - 22) / 2, width: max(40, bounds.width - labelX - 26), height: 22)
    }

    /// A remote tab too narrow for "web-1: app (connecting)" says less rather than "web-1: a…g)": first
    /// "web-1: " goes (the mark says it is on a server, the tooltip which one), then the note (the dot on
    /// the mark says it by shape), leaving "app", as a narrow local tab shows "ne…rm". The note goes last:
    /// it is the one thing the tab says in words that colour-blind users would otherwise have to read off a
    /// 7 pt dot.
    private func fittedTitle(within width: CGFloat) -> String? {
        guard let item else { return nil }
        if fits(item.title, within: width) { return item.title }
        return item.shorterTitles.first { fits($0, within: width) } ?? item.shorterTitles.last ?? item.title
    }

    private func fits(_ title: String, within width: CGFloat) -> Bool {
        (title as NSString).size(withAttributes: [.font: label.font as Any]).width + 4 <= width
    }

    /// For the self-test: the title as the tab shows it, shortened to fit.
    var shownTitle: String { label.stringValue }

    override func draw(_ dirtyRect: NSRect) {
        Theme.border.setFill()
        NSRect(x: bounds.width - 1, y: 8, width: 1, height: bounds.height - 16).fill()
        if selected {
            Theme.accent.setFill()
            NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        bar?.itemMouseDown(self, event: event)
    }

    // Middle-click closes, like a browser.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { bar?.itemClose(self) }
    }

    @objc private func closeClicked() {
        bar?.itemClose(self)
    }

    override func accessibilityPerformPress() -> Bool {
        if let bar, let index = bar.index(of: self) {
            bar.delegate?.tabBar(bar, didSelect: index)
            return true
        }
        return false
    }

    // MARK: rename

    var isEditing: Bool { renameField != nil }

    func beginRename() {
        guard renameField == nil else { return }
        let field = NSTextField(string: item?.editableTitle ?? item?.title ?? label.stringValue)
        field.font = label.font
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.placeholderString = "Tab name"
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
        field.removeFromSuperview()
        label.isHidden = false
        if renameCancelled {
            renameCancelled = false
        } else {
            // An empty name goes back to the automatic title.
            bar?.itemRenamed(self, to: text.isEmpty ? nil : text)
        }
        bar?.itemEndedEditing(self)
    }
}

// MARK: - status glyphs

/// Status as shape and colour, so it reads for colour-blind users too: a spinner for working,
/// a check for done, a cross for failed, an exclamation mark for attention.
enum StatusGlyph {
    static func symbolName(for state: TabState) -> String? {
        switch state {
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .working: return "circle.dotted"
        case .idle: return nil
        }
    }

    static func color(for state: TabState) -> NSColor {
        switch state {
        case .done: return Theme.done
        case .failed: return Theme.failed
        case .attention: return Theme.attention
        case .working, .idle: return Theme.working
        }
    }

    /// A tinted image, for menus.
    static func image(for state: TabState, size: CGFloat = 12) -> NSImage? {
        guard let name = symbolName(for: state) else { return nil }
        // Palette mode paints each layer: the mark (✓ ✕ !) white, the circle in the state's colour.
        // With a single colour the mark would vanish into the circle.
        let colors: [NSColor] = state == .working ? [color(for: state)] : [.white, color(for: state)]
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
            .applying(.init(paletteColors: colors))
        return NSImage(systemSymbolName: name, accessibilityDescription: state.rawValue)?.withSymbolConfiguration(config)
    }

    /// For a menu that lists remote tabs: the status mark, then the server mark, each in a column of its
    /// own on every item, so the titles still line up.
    static func image(for state: TabState, remote: RemoteMark?) -> NSImage {
        let status = image(for: state)
        let markSize = RemoteMarkView.size
        return NSImage(size: NSSize(width: 18 + markSize.width, height: markSize.height), flipped: true) { rect in
            if let status {
                let size = status.size
                status.draw(in: NSRect(x: (14 - size.width) / 2, y: (rect.height - size.height) / 2, width: size.width, height: size.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            if let remote {
                RemoteMarkView.draw(remote.link, tint: .secondaryLabelColor, in: NSRect(x: 18, y: 0, width: markSize.width, height: markSize.height))
            }
            return true
        }
    }
}

private final class StatusDotView: NSView {
    private let ring = CAShapeLayer()
    private let glyph = NSImageView()

    var state: TabState = .idle {
        didSet { if state != oldValue { apply() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.lineCap = .round
        layer?.addSublayer(ring)
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.wantsLayer = true
        addSubview(glyph)
        apply()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        glyph.frame = bounds.insetBy(dx: -1, dy: -1)
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func apply() {
        ring.removeAllAnimations()
        glyph.layer?.removeAllAnimations()
        ring.isHidden = state != .working
        glyph.isHidden = state == .working || state == .idle
        switch state {
        case .working:
            ring.strokeColor = Theme.working.cgColor
            ring.strokeStart = 0
            ring.strokeEnd = 0.7
            if !reduceMotion {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = -2 * Double.pi
                spin.duration = 0.8
                spin.repeatCount = .infinity
                ring.add(spin, forKey: "spin")
            }
        case .done, .failed, .attention:
            glyph.image = StatusGlyph.image(for: state, size: 11)
            if state == .attention, !reduceMotion {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.35
                pulse.duration = 0.6
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                glyph.layer?.add(pulse, forKey: "pulse")
            }
        case .idle:
            break
        }
    }
}

// MARK: - remote mark

/// A remote tab's server mark: a server with the connection's dot cut into its corner. The dot says it
/// by shape as well as colour: filled green when connected, an amber ring while on its way (connecting,
/// a login), red with a bar when lost (the server fades). Once the shell ended there is no connection to
/// show or make: no dot, the server alone, faded. Local tabs have none: remote is the exception that
/// stands out.
final class RemoteMarkView: NSView {
    /// The 11 pt glyph's image is 16 × 13; the dot reaches 3 pt past its corner.
    static let size = NSSize(width: 19, height: 17)

    var link: RemoteLink? { didSet { if link != oldValue { needsDisplay = true } } }
    var tint: NSColor = Theme.textDim { didSet { if tint != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false) // the tab, or the line it is on, says it in words
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if let link { Self.draw(link, tint: tint, in: bounds) }
    }

    /// nil once the shell ended: nothing to reconnect, and the status mark says how it ended.
    static func dotColor(for link: RemoteLink) -> NSColor? {
        switch link {
        case .connected: return Theme.done
        case .disconnected: return Theme.failed
        case .ended: return nil
        case .connecting, .waiting, .logIn: return Theme.attention
        }
    }

    /// Draws into a flipped context: the tab's view, or a menu's image.
    static func draw(_ link: RemoteLink, tint: NSColor, in rect: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(.init(paletteColors: [tint]))
        guard let context = NSGraphicsContext.current?.cgContext,
              let glyph = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        else { return }
        let glyphRect = NSRect(x: rect.minX, y: rect.minY + 1, width: glyph.size.width, height: glyph.size.height)
        // Faded when disconnected or ended, but not below 3:1 against the bar: it still says "a server".
        let fraction: CGFloat = link == .disconnected || link == .ended ? 0.7 : 1
        guard let color = dotColor(for: link) else {
            glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: fraction, respectFlipped: true, hints: nil)
            return
        }
        let d: CGFloat = 7
        let dot = NSRect(x: glyphRect.maxX - d / 2 - 0.5, y: glyphRect.maxY - d / 2 - 0.5, width: d, height: d)
        // The dot is cut into the server, so it reads on any background (a tab, its hover, a menu).
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: fraction, respectFlipped: true, hints: nil)
        context.setBlendMode(.clear)
        context.fillEllipse(in: dot.insetBy(dx: -1.5, dy: -1.5))
        context.endTransparencyLayer()
        context.restoreGState()
        if link.isOnItsWay {
            let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            color.setStroke()
            ring.stroke()
            return
        }
        color.setFill()
        NSBezierPath(ovalIn: dot).fill()
        if link == .disconnected {
            NSColor.white.setFill()
            NSRect(x: dot.minX + 1.75, y: dot.midY - 0.65, width: d - 3.5, height: 1.3).fill()
        }
    }
}

// MARK: - overflow button

private final class OverflowButton: NSButton {
    private let dot = StatusDotView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .regularSquare
        isBordered = false
        font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        contentTintColor = Theme.textDim
        addSubview(dot)
        setAccessibilityLabel("More tabs")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(hiddenCount: Int, state: TabState) {
        let text = NSMutableAttributedString(string: "» \(hiddenCount)", attributes: [
            .foregroundColor: Theme.textDim, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ])
        // Room for the status dot after the count is kerning, not padding spaces, and only when a dot shows.
        if state != .idle { text.addAttribute(.kern, value: 14, range: NSRange(location: text.length - 1, length: 1)) }
        attributedTitle = text
        dot.state = state
        toolTip = "\(hiddenCount) more tab\(hiddenCount == 1 ? "" : "s")"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // At the end of the centred title, so a two-digit count never runs into it.
        let titleWidth = attributedTitle.size().width
        dot.frame = NSRect(x: (bounds.width + titleWidth) / 2 - 10, y: (bounds.height - 10) / 2, width: 10, height: 10)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// A borderless icon button that does not drag the window (it sits in the title-bar strip).
final class HoverButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }
}
