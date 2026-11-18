import AppKit
import NextTermCore

/// The raised card the chat's open permission or question docks above the input as (plan 037 R3, KTD5, KTD6): the
/// lead ("Claude Code asks to:") and the action in full, selectable so a command can be copied, then one button per
/// choice, the highlighted one in the accent colour. With the keyboard: ↑/↓ (and ←/→) move, Return picks the highlighted
/// choice, 1–9 pick, Esc picks the reject choice. Keys within 400 ms of the card appearing are dropped, so a Return
/// already on its way doesn't answer it.
final class ChatDecisionCard: ChatCardView {
    private let icon = NSImageView()
    private let lead = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let title = NSTextField(wrappingLabelWithString: "")
    private let buttons = ChatButtonRow()
    private let keysLine = NSTextField(labelWithString: "")

    private(set) var decision: ChatDecision?
    /// When this request first showed: the 400 ms guard counts from it.
    private var shownAt = Date.distantPast
    private var announced = false

    static let guardInterval: TimeInterval = 0.4

    var onChoose: ((Int) -> Void)?
    var onMove: ((Int) -> Void)?

    override init() {
        super.init()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        for label in [lead, hint, keysLine] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        hint.alignment = .right
        hint.setAccessibilityElement(false)
        keysLine.setAccessibilityElement(false)
        title.isSelectable = true
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let top = Self.headRow([icon, lead, hint])
        let column = addColumn([top, title, buttons, keysLine], spacedAfter: title)
        NSLayoutConstraint.activate([
            top.widthAnchor.constraint(equalTo: column.widthAnchor),
            title.widthAnchor.constraint(equalTo: column.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `decision`. A new request (another title or other choices) restarts the 400 ms guard. `agent` names who
    /// asks; `draftWaits`: the input holds a draft, so the card says Tab reaches it.
    func show(_ decision: ChatDecision, agent: String, sizes: ChatTextSizes, draftWaits: Bool) {
        let isNew = self.decision.map { $0.title != decision.title || $0.choices != decision.choices } ?? true
        if isNew {
            shownAt = Date()
            announced = false
        }
        self.decision = decision
        let small = NSFont.systemFont(ofSize: CGFloat(sizes.secondary))
        let symbol = decision.isQuestion ? "questionmark.bubble" : "hand.raised"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: CGFloat(sizes.secondary) + 1, weight: .medium))
        icon.contentTintColor = Theme.attention
        lead.font = .systemFont(ofSize: CGFloat(sizes.secondary), weight: .medium)
        lead.textColor = .secondaryLabelColor
        lead.stringValue = decision.lead ?? (agent + " asks")
        hint.font = small
        hint.textColor = .tertiaryLabelColor
        hint.stringValue = draftWaits && !hasKeyboard ? "Tab to answer" : ""
        title.font = decision.isQuestion ? .systemFont(ofSize: CGFloat(sizes.body), weight: .medium)
            : .monospacedSystemFont(ofSize: CGFloat(sizes.monospaced), weight: .regular)
        title.textColor = .labelColor
        title.stringValue = decision.title
        keysLine.font = small
        keysLine.textColor = .tertiaryLabelColor
        let count = decision.choices.count
        var keys = "\u{2191}\u{2193} move  \u{00B7}  Return chooses"
        if count > 1 { keys += "  \u{00B7}  1\u{2013}\(min(count, 9)) pick" }
        if decision.rejectIndex != nil { keys += "  \u{00B7}  Esc rejects" }
        keysLine.stringValue = keys
        buttons.show(decision.choices.map { choice in
            ChatButtonRow.Item(title: choice.name, accent: choice.number - 1 == decision.highlighted,
                               label: "\(choice.name), \(choice.number) of \(count)",
                               tip: choice.needsMac ? "Asks on your Mac first (\(choice.number))" : "Press \(choice.number)")
        }) { [weak self] index in self?.pick(index, byKey: false) }
        let words = (decision.lead.map { $0 + " " } ?? "") + decision.title
        setAccessibilityLabel(words)
        needsLayout = true
    }

    /// Says the request once to VoiceOver, when the tab is in front.
    func announceOnce(agent: String) {
        guard !announced, let decision, let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor else { return }
        announced = true
        let first = decision.choices.first?.name ?? ""
        let words = decision.isQuestion ? "\(agent) asks: \(decision.title)" : "\(agent) asks to run \(decision.title). \(first)"
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    override func layout() {
        super.layout()
        fitWidth(of: title)
    }

    // MARK: keys

    /// Within the guard: a key on its way from before the card showed.
    private var guarded: Bool { Date().timeIntervalSince(shownAt) < Self.guardInterval }

    private func pick(_ index: Int, byKey: Bool) {
        guard let decision, decision.choices.indices.contains(index) else { return NSSound.beep() }
        if byKey, guarded { return }
        onChoose?(index)
    }

    override func keyDown(with event: NSEvent) {
        guard let decision else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags.isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 126, 123: if !guarded { onMove?(-1) } // ↑ ←
        case 125, 124: if !guarded { onMove?(1) } // ↓ →
        case 36, 76: pick(decision.highlighted, byKey: true) // Return, Enter
        case 53: if let reject = decision.rejectIndex { pick(reject, byKey: true) } else { NSSound.beep() }
        default:
            if let character = event.charactersIgnoringModifiers?.first, let digit = character.wholeNumberValue, (1...9).contains(digit) {
                pick(digit - 1, byKey: true)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        guard let reject = decision?.rejectIndex else { return }
        pick(reject, byKey: true)
    }

    override func becomeFirstResponder() -> Bool {
        let made = super.becomeFirstResponder()
        if made { hint.stringValue = "" }
        return made
    }
}

/// The raised panel the decision card and the end card share: a rounded window-coloured fill with a hairline edge,
/// and a focus ring while it has the keyboard.
class ChatCardView: NSView {
    private(set) var hasKeyboard = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        wantsLayer = true
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor }

    /// The card's padding: 12 points above and below, 14 either side.
    private static let padding = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

    /// The row along a card's top: its symbol and words, centred on one line.
    static func headRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// `views` top to bottom inside the card's padding, 8 points apart and 12 after `spaced`; hidden ones take no room.
    func addColumn(_ views: [NSView], spacedAfter spaced: NSView) -> NSStackView {
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.setCustomSpacing(12, after: spaced)
        column.detachesHiddenViews = true
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let padding = Self.padding
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: padding.top),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding.left),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding.right),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding.bottom),
        ])
        return column
    }

    /// A wrapping label wraps at the width inside the card's padding.
    func fitWidth(of label: NSTextField) {
        let width = bounds.width - Self.padding.left - Self.padding.right
        if width > 0, label.preferredMaxLayoutWidth != width {
            label.preferredMaxLayoutWidth = width
            label.invalidateIntrinsicContentSize()
        }
    }

    override func becomeFirstResponder() -> Bool {
        hasKeyboard = true
        noteFocusRingMaskChanged()
        return true
    }

    override func resignFirstResponder() -> Bool {
        hasKeyboard = false
        noteFocusRingMaskChanged()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// A row of push buttons that wraps onto more lines when the card is narrow. The accent one is drawn in the accent
/// colour (the highlighted choice). Buttons are real controls with their own labels and tooltips.
final class ChatButtonRow: NSView {
    struct Item: Equatable {
        var title: String
        var accent: Bool
        var label: String
        var tip: String?
    }

    private var items: [Item] = []
    private(set) var buttons: [NSButton] = []
    private var onPick: ((Int) -> Void)?
    private var height: CGFloat = 24

    override var isFlipped: Bool { true }

    func show(_ items: [Item], onPick: @escaping (Int) -> Void) {
        self.onPick = onPick
        guard items != self.items else { return }
        self.items = items
        if buttons.count != items.count {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = items.indices.map { index in
                let button = NSButton(title: "", target: self, action: #selector(clicked(_:)))
                button.bezelStyle = .rounded
                button.controlSize = .regular
                button.tag = index
                addSubview(button)
                return button
            }
        }
        for (button, item) in zip(buttons, items) {
            button.title = item.title
            button.bezelColor = item.accent ? .controlAccentColor : nil
            button.keyEquivalent = ""
            button.toolTip = item.tip
            button.setAccessibilityLabel(item.label)
            button.sizeToFit()
        }
        needsLayout = true
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    @objc private func clicked(_ sender: NSButton) {
        onPick?(sender.tag)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }

    /// The highlighted choice also gets an accent outline, which shows in an inactive window too (the accent bezel
    /// shows only while the window is key).
    override func draw(_ dirtyRect: NSRect) {
        guard let index = items.firstIndex(where: \.accent), buttons.indices.contains(index) else { return }
        let frame = buttons[index].frame.insetBy(dx: 1, dy: 2)
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        path.lineWidth = 2
        path.stroke()
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        let gap: CGFloat = 8
        for button in buttons {
            let size = button.fittingSize
            if x > 0, x + size.width > bounds.width {
                x = 0
                y += lineHeight + gap
                lineHeight = 0
            }
            button.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + gap
            lineHeight = max(lineHeight, size.height)
        }
        let total = buttons.isEmpty ? 0 : y + lineHeight
        if total != height {
            height = total
            invalidateIntrinsicContentSize()
        }
    }
}
