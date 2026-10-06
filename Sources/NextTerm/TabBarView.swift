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
        for (i, item) in newItems.enumerated() {
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
        max(0, bounds.width - leadingInset - (allowsNewTab ? Self.newTabButtonWidth : 0) - 24)
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
        return NSRect(x: leadingInset + slot * tabWidth, y: 0, width: tabWidth, height: bounds.height - 1)
    }

    override func layout() {
        super.layout()
        let range = visibleRange
        firstVisible = range.lowerBound
        for (i, view) in tabViews.enumerated() where view !== dragging?.view {
            view.isHidden = !range.contains(i)
            if !view.isHidden { view.frame = frameForTab(at: i) }
        }
        var x = leadingInset + CGFloat(range.count) * tabWidth
        overflowButton.isHidden = !isOverflowing
        if isOverflowing {
            overflowButton.frame = NSRect(x: x, y: 0, width: Self.overflowButtonWidth, height: bounds.height - 1)
            x += Self.overflowButtonWidth
        }
        newTabButton.frame = NSRect(x: min(x, bounds.width - Self.newTabButtonWidth), y: 0,
                                    width: Self.newTabButtonWidth, height: bounds.height - 1)
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

    @objc private func showOverflowMenu() {
        let menu = NSMenu()
        let range = visibleRange
        for (i, item) in items.enumerated() {
            let title = Typography.shortened(item.title, to: 60) // the full title is in the tooltip
            let entry = NSMenuItem(title: title, action: #selector(overflowMenuSelected(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = i
            entry.image = StatusGlyph.image(for: item.state)
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
            let minX = self.leadingInset
            let maxX = self.leadingInset + CGFloat(range.count - 1) * self.tabWidth
            view.frame.origin.x = min(max(x - grabOffset, minX), maxX)
            // Reorder the array live as the dragged tab's centre crosses its neighbours (within the visible tabs).
            let centre = view.frame.midX - self.leadingInset
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
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var renameField: NSTextField?
    private var hovering = false { didSet { refresh() } }
    private var selected = false
    var isDragging = false { didSet { alphaValue = isDragging ? 0.85 : 1; layer?.zPosition = isDragging ? 10 : 0 } }

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

        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.contentTintColor = Theme.textDim
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close tab (⌘W)"
        addSubview(closeButton)

        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var item: TabBarItem?

    // Called several times a second: touch only what changed (re-setting a tooltip resets it).
    func configure(item newItem: TabBarItem, selected isSelected: Bool) {
        guard newItem != item || isSelected != selected else { return }
        if label.stringValue != newItem.title { label.stringValue = newItem.title }
        if label.lineBreakMode != newItem.truncation { label.lineBreakMode = newItem.truncation }
        if toolTip != newItem.tooltip { toolTip = newItem.tooltip }
        dot.state = newItem.state
        if iconView.image !== newItem.icon { iconView.image = newItem.icon }
        iconView.isHidden = newItem.icon == nil
        dot.isHidden = newItem.icon != nil
        item = newItem
        selected = isSelected
        setAccessibilityLabel("\(newItem.title), \(newItem.accessibilityStatus)")
        setAccessibilityValue(isSelected)
        refresh()
    }

    private func refresh() {
        layer?.backgroundColor = (selected ? Theme.background : hovering ? Theme.tabHover : .clear).cgColor
        label.textColor = selected || hovering ? Theme.text : Theme.textDim
        // Unsaved: a dot that turns into the close button under the pointer.
        let modified = item?.modified == true
        closeButton.isHidden = !(selected || hovering || modified)
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
        let labelX: CGFloat = 29
        let labelHeight = label.intrinsicContentSize.height
        label.frame = NSRect(x: labelX, y: (h - labelHeight) / 2, width: max(0, bounds.width - labelX - 28), height: labelHeight)
        renameField?.frame = NSRect(x: labelX - 3, y: (h - 22) / 2, width: max(40, bounds.width - labelX - 26), height: 22)
    }

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
        let field = NSTextField(string: label.stringValue)
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
