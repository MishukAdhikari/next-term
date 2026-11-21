import AppKit
import NextTermCore

/// The prompt box's "/" menu: the agent's commands that match what is typed, in a small panel just above the box, as a
/// completion list is. ↑ and ↓ choose, Tab completes the name (for an argument after it), Return sends the command,
/// Esc closes the menu, and a click sends it too. It never takes the keyboard: the box keeps it the whole time.
final class SlashMenu: NSObject {
    private(set) var items: [ChatCommand] = []
    private(set) var selected = 0
    /// A click on a row: the box sends that command.
    var onPick: ((ChatCommand) -> Void)?

    private var panel: NSPanel?
    private let stack = NSStackView()

    static let rowHeight: CGFloat = 24
    static let inset: CGFloat = 4

    var isShown: Bool { panel?.isVisible == true }
    var current: ChatCommand? { items.indices.contains(selected) ? items[selected] : nil }

    /// Shows `items` above `box`, the first chosen; with none, the menu goes.
    func show(_ items: [ChatCommand], above box: NSView) {
        guard !items.isEmpty, let parent = box.window else { return hide() }
        let keep = current?.name
        self.items = items
        selected = items.firstIndex { $0.name == keep } ?? 0
        let panel = self.panel ?? makePanel()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, item) in items.enumerated() {
            let row = SlashMenuRow(item: item)
            row.onClick = { [weak self] in self?.pick(index) }
            row.onHover = { [weak self] in self?.choose(index) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -Self.inset * 2).isActive = true
        }
        mark()
        let inWindow = box.convert(box.bounds, to: nil)
        let onScreen = parent.convertToScreen(inWindow)
        let height = CGFloat(items.count) * Self.rowHeight + Self.inset * 2
        let frame = NSRect(x: onScreen.minX, y: onScreen.maxY + 4, width: max(onScreen.width, 280), height: height)
        panel.setFrame(frame, display: true)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        announce()
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        items = []
        selected = 0
    }

    /// ↑ (-1) or ↓ (+1), round the ends.
    func move(_ step: Int) {
        guard !items.isEmpty else { return }
        choose((selected + step + items.count) % items.count)
        announce()
    }

    private func choose(_ index: Int) {
        guard items.indices.contains(index), index != selected else { return }
        selected = index
        mark()
    }

    private func pick(_ index: Int) {
        guard items.indices.contains(index) else { return }
        onPick?(items[index])
    }

    private func mark() {
        for (index, row) in stack.arrangedSubviews.enumerated() { (row as? SlashMenuRow)?.chosen = index == selected }
    }

    /// VoiceOver hears the chosen command, as a menu's item is read.
    private func announce() {
        guard let item = current else { return }
        let words = "/" + item.name + (item.description.isEmpty ? "" : ", " + item.description)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])
        panel.contentView = effect
        panel.setAccessibilityElement(false)
        self.panel = panel
        return panel
    }
}

/// One row: the command's name, then what it does, dimmer, on one line cut at the end.
private final class SlashMenuRow: NSView {
    let item: ChatCommand
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var chosen = false {
        didSet { if chosen != oldValue { needsDisplay = true } }
    }

    init(item: ChatCommand) {
        self.item = item
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: SlashMenu.rowHeight).isActive = true
        toolTip = item.description.isEmpty ? nil : item.description
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel("/" + item.name + (item.description.isEmpty ? "" : ", " + item.description))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if chosen {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let nameColor: NSColor = chosen ? .alternateSelectedControlTextColor : .labelColor
        let detailColor: NSColor = chosen ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: "/" + item.name, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .medium), .foregroundColor: nameColor, .paragraphStyle: paragraph,
        ])
        if !item.description.isEmpty {
            text.append(NSAttributedString(string: "   " + item.description, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: detailColor, .paragraphStyle: paragraph,
            ]))
        }
        let height = text.size().height
        let rect = NSRect(x: 8, y: ((bounds.height - height) / 2).rounded(), width: bounds.width - 16, height: height)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
