import AppKit
import NextTermCore

struct TabBarItem: Equatable {
    var title: String
    var state: TabState
    var tooltip: String
    var accessibilityStatus: String
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
    static let minTabWidth: CGFloat = 72
    static let maxTabWidth: CGFloat = 220
    static let newTabButtonWidth: CGFloat = 36

    weak var delegate: TabBarViewDelegate?
    /// Space reserved on the left for the traffic-light buttons.
    var leadingInset: CGFloat = 78 { didSet { needsLayout = true } }

    private(set) var items: [TabBarItem] = []
    private(set) var selectedIndex = 0
    private var tabViews: [TabItemView] = []
    private let newTabButton = NSButton()
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
        newTabButton.toolTip = "New Tab (⌘T)"
        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked)
        addSubview(newTabButton)

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
        items = newItems
        selectedIndex = newSelected
        if countChanged { needsLayout = true }
    }

    func beginRename(at index: Int) {
        tabViews[safe: index]?.beginRename()
    }

    // MARK: layout

    private var tabWidth: CGFloat {
        guard !tabViews.isEmpty else { return Self.maxTabWidth }
        let available = bounds.width - leadingInset - Self.newTabButtonWidth - 40 // keep a strip for dragging the window
        return min(Self.maxTabWidth, max(Self.minTabWidth, (available / CGFloat(tabViews.count)).rounded(.down)))
    }

    private func frameForTab(at index: Int) -> NSRect {
        NSRect(x: leadingInset + CGFloat(index) * tabWidth, y: 0, width: tabWidth, height: bounds.height - 1)
    }

    override func layout() {
        super.layout()
        for (i, view) in tabViews.enumerated() where view !== dragging?.view {
            view.frame = frameForTab(at: i)
        }
        let end = leadingInset + CGFloat(tabViews.count) * tabWidth
        newTabButton.frame = NSRect(x: min(end, bounds.width - Self.newTabButtonWidth), y: 0,
                                    width: Self.newTabButtonWidth, height: bounds.height - 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: mouse on the empty part of the bar drags the window

    override func mouseDown(with event: NSEvent) {
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
            view.beginRename()
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
            let minX = self.leadingInset
            let maxX = self.leadingInset + CGFloat(self.tabViews.count - 1) * self.tabWidth
            view.frame.origin.x = min(max(x - grabOffset, minX), maxX)
            // Reorder the array live as the dragged tab's centre crosses its neighbours.
            let centre = view.frame.midX - self.leadingInset
            let target = min(max(Int(centre / self.tabWidth), 0), self.tabViews.count - 1)
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
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.maximumNumberOfLines = 1
        addSubview(label)
        addSubview(dot)

        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.contentTintColor = Theme.textDim
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close Tab (⌘W)"
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
        if toolTip != newItem.tooltip { toolTip = newItem.tooltip }
        dot.state = newItem.state
        item = newItem
        selected = isSelected
        setAccessibilityLabel("\(newItem.title), \(newItem.accessibilityStatus)")
        setAccessibilityValue(isSelected)
        refresh()
    }

    private func refresh() {
        layer?.backgroundColor = (selected ? Theme.background : hovering ? Theme.tabHover : .clear).cgColor
        label.textColor = selected || hovering ? Theme.text : Theme.textDim
        closeButton.isHidden = !(selected || hovering)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        dot.frame = NSRect(x: 12, y: (h - 10) / 2, width: 10, height: 10)
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
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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

// MARK: - status dot

private final class StatusDotView: NSView {
    private let ring = CAShapeLayer()
    private let fill = CALayer()

    var state: TabState = .idle {
        didSet { if state != oldValue { apply() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.lineCap = .round
        layer?.addSublayer(fill)
        layer?.addSublayer(ring)
        apply()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        fill.frame = bounds
        fill.cornerRadius = bounds.width / 2
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func apply() {
        ring.removeAllAnimations()
        fill.removeAllAnimations()
        ring.isHidden = state != .working
        fill.isHidden = state == .working || state == .idle
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
        case .done:
            fill.backgroundColor = Theme.done.cgColor
        case .failed:
            fill.backgroundColor = Theme.failed.cgColor
        case .attention:
            fill.backgroundColor = Theme.attention.cgColor
            if !reduceMotion {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.35
                pulse.duration = 0.6
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                fill.add(pulse, forKey: "pulse")
            }
        case .idle:
            break
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
