import AppKit
import NextTermCore

/// "How do you like to work?": three layouts side by side, each a card with a drawn preview, its name and one line. A
/// click on a card sets its layout in every window, through set_layout's own path (MCPWriteControl.applyLayout), and
/// closes the sheet. Skip, the default button, and Escape change nothing. Shown once over a new install's first Welcome
/// window (AppDelegate), and from Settings › General › Choose a Layout… any time.
final class LayoutPickerSheet: NSWindowController, NSWindowDelegate {
    /// The sheet showing now, if any: a second ask brings nothing new.
    private(set) static weak var current: LayoutPickerSheet?
    /// Kept while it shows: the window that holds it does not.
    private static var showing: LayoutPickerSheet?

    let titleLabel = NSTextField(labelWithString: LayoutPicker.title)
    let cards: [LayoutCard] = LayoutPreset.allCases.map { LayoutCard(preset: $0) }
    let footerLabel = NSTextField(wrappingLabelWithString: LayoutPicker.footer)
    let skipButton = NSButton(title: LayoutPicker.skipTitle, target: nil, action: nil)
    /// What was chosen, once a card was; nil after Skip or Escape.
    private(set) var chosen: LayoutPreset?
    private weak var parentWindow: NSWindow?
    private var onClose: ((LayoutPreset?) -> Void)?

    /// Shows the sheet over `parent` (nothing new if one shows already). `onClose` hears the layout chosen, or nil.
    @discardableResult
    static func present(over parent: NSWindow, onClose: ((LayoutPreset?) -> Void)? = nil) -> LayoutPickerSheet? {
        if let current, current.window?.isVisible == true { return current }
        guard parent.attachedSheet == nil else { return nil }
        let sheet = LayoutPickerSheet()
        sheet.onClose = onClose
        sheet.parentWindow = parent
        sheet.window?.appearance = parent.appearance
        showing = sheet
        current = sheet
        parent.beginSheet(sheet.window!) { _ in }
        return sheet
    }

    init() {
        let panel = LayoutPickerPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 320), styleMask: [.titled], backing: .buffered,
                                      defer: false)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.cancelHandler = { [weak self] in self?.skip() }
        build(in: panel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build(in panel: NSPanel) {
        let content = NSView()
        panel.contentView = content
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.setAccessibilityRole(.staticText)

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        var previous: LayoutCard?
        for card in cards {
            card.target = self
            card.action = #selector(cardChosen(_:))
            card.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(card)
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: row.topAnchor),
                card.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                card.leadingAnchor.constraint(equalTo: previous?.trailingAnchor ?? row.leadingAnchor, constant: previous == nil ? 0 : 12),
            ])
            if let previous { card.widthAnchor.constraint(equalTo: previous.widthAnchor).isActive = true }
            previous = card
        }
        previous?.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
        // As short as the tallest card's words allow, every card as tall.
        let short = row.heightAnchor.constraint(equalToConstant: 0)
        short.priority = .defaultLow
        short.isActive = true

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        // The cards' row less Skip and the gap: two short lines at most, beside the button.
        footerLabel.preferredMaxLayoutWidth = CGFloat(cards.count) * LayoutCard.width + CGFloat(cards.count - 1) * 12 - 120
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        skipButton.bezelStyle = .rounded
        skipButton.keyEquivalent = "\r" // the default: highlighted, and Return's
        skipButton.target = self
        skipButton.action = #selector(skipClicked)
        skipButton.setContentHuggingPriority(.required, for: .horizontal)
        skipButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let foot = NSStackView(views: [footerLabel, skipButton])
        foot.orientation = .horizontal
        foot.alignment = .centerY
        foot.spacing = 20

        for view in [titleLabel, row, foot] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            row.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            foot.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 18),
            foot.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            foot.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            foot.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        panel.layoutIfNeeded()
        panel.setContentSize(content.fittingSize)
        // No card takes the keyboard as the sheet opens: Return is Skip's, and the cards are choices, a Tab away.
        panel.initialFirstResponder = skipButton
    }

    @objc private func cardChosen(_ sender: LayoutCard) { choose(sender.preset) }

    @objc private func skipClicked() { skip() }

    /// The layout in every window, as set_layout and Settings set it, then the sheet closes.
    func choose(_ preset: LayoutPreset) {
        chosen = preset
        MCPWriteControl.applyLayout(preset.change, in: nil, asked: true)
        finish()
    }

    /// Nothing changes.
    func skip() {
        chosen = nil
        finish()
    }

    private func finish() {
        guard let window else { return }
        if let parent = window.sheetParent ?? parentWindow { parent.endSheet(window) } else { window.orderOut(nil) }
        let done = onClose
        onClose = nil
        done?(chosen)
        if Self.showing === self { Self.showing = nil }
    }
}

/// The sheet's window: Escape skips.
final class LayoutPickerPanel: NSPanel {
    var cancelHandler: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { cancelHandler?() }
    override var canBecomeKey: Bool { true }
}

/// One layout: its preview, its name and its line, as one button. A hover shows a soft fill, a press a little more; the
/// focus ring follows its rounded corners; VoiceOver reads "IDE layout: …".
final class LayoutCard: NSButton {
    let preset: LayoutPreset
    let preview: LayoutPreview
    let nameLabel: NSTextField
    let lineLabel: NSTextField
    static let radius: CGFloat = 10
    static let padding: CGFloat = 10
    static let width: CGFloat = LayoutPreview.size.width + 2 * padding
    private(set) var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?

    init(preset: LayoutPreset) {
        self.preset = preset
        preview = LayoutPreview(preset: preset)
        nameLabel = NSTextField(labelWithString: preset.name)
        lineLabel = NSTextField(wrappingLabelWithString: preset.line)
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .noImage
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        lineLabel.font = .systemFont(ofSize: 11)
        lineLabel.textColor = .secondaryLabelColor
        lineLabel.preferredMaxLayoutWidth = LayoutPreview.size.width - 2
        lineLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        for view in [preview, nameLabel, lineLabel] as [NSView] {
            view.setAccessibilityElement(false)
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let pad = Self.padding
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            preview.centerXAnchor.constraint(equalTo: centerXAnchor),
            preview.widthAnchor.constraint(equalToConstant: LayoutPreview.size.width),
            preview.heightAnchor.constraint(equalToConstant: LayoutPreview.size.height),
            preview.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: pad),
            nameLabel.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 10),
            nameLabel.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: preview.trailingAnchor),
            lineLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            lineLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            lineLabel.widthAnchor.constraint(equalToConstant: LayoutPreview.size.width - 2),
            lineLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -pad - 2),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
        setAccessibilityLabel(preset.accessibilityLabel)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The whole card is the button: a click on its words or its preview too.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) && !isHidden ? self : nil
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// No motion to reduce: the fill changes at once, as macOS's own list rows do.
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.radius, yRadius: Self.radius)
        let fill: NSColor = isHighlighted ? .labelColor.withAlphaComponent(0.10) : hovering ? .labelColor.withAlphaComponent(0.05) : .clear
        fill.setFill()
        shape.fill()
        (hovering || isHighlighted ? NSColor.separatorColor.withAlphaComponent(1) : NSColor.separatorColor.withAlphaComponent(0.6)).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius).fill()
    }
}

/// A layout drawn as rounded shapes, no words: the window column, the project sidebar, the editor, the terminal and its
/// tab strip or tab list, in Next Term's colours, light or dark as the window around it.
final class LayoutPreview: NSView {
    static let size = NSSize(width: 180, height: 112)
    let preset: LayoutPreset

    init(preset: LayoutPreset) {
        self.preset = preset
        super.init(frame: NSRect(origin: .zero, size: Self.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Each colour the theme's own for the picture (UIToken.picker*), light or dark as the window around it.
    private enum Palette {
        static let window = Theme.ui(.pickerWindow)
        static let panel = Theme.ui(.pickerPanel)
        static let editor = Theme.ui(.pickerEditor)
        static let terminal = Theme.ui(.pickerTerminal)
        static let list = Theme.ui(.pickerList)
        static let line = Theme.ui(.ink).withAlphaComponent(0.10)
        static let dot = Theme.pair(light: Theme.ui(.ink).withAlphaComponent(0.16), dark: Theme.ui(.ink).withAlphaComponent(0.18))
        static let border = Theme.pair(light: Theme.ui(.ink).withAlphaComponent(0.12), dark: Theme.ui(.ink).withAlphaComponent(0.10))
        static let accent = Theme.accent
    }

    private func box(_ rect: NSRect, _ color: NSColor, radius: CGFloat = 3) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    /// Short rows of faint bars: files in the sidebar, code in the editor.
    private func bars(in rect: NSRect, widths: [CGFloat], step: CGFloat = 7, inset: CGFloat = 5) {
        var y = rect.minY + inset
        for width in widths {
            guard y + 3 <= rect.maxY - inset else { return }
            box(NSRect(x: rect.minX + inset, y: y, width: min(width, rect.width - 2 * inset), height: 3), Palette.line, radius: 1.5)
            y += step
        }
    }

    /// The window column: a dot per window, the one in front in the accent.
    private func column(_ rect: NSRect) {
        box(rect, Palette.panel)
        for index in 0..<3 {
            let dot = NSRect(x: rect.midX - 3, y: rect.minY + 5 + CGFloat(index) * 9, width: 6, height: 6)
            box(dot, index == 0 ? Palette.accent : Palette.dot, radius: 3)
        }
    }

    /// The terminal, with its tabs in a strip along its top or listed down its left.
    private func terminal(_ rect: NSRect, tabsListed: Bool) {
        box(rect, Palette.terminal)
        if tabsListed {
            let list = NSRect(x: rect.minX, y: rect.minY, width: 28, height: rect.height)
            box(list, Palette.list)
            for index in 0..<3 {
                let row = NSRect(x: list.minX + 4, y: list.minY + 4 + CGFloat(index) * 7, width: list.width - 8, height: 4)
                box(row, index == 0 ? Palette.accent : Palette.dot, radius: 2)
            }
            bars(in: NSRect(x: list.maxX, y: rect.minY, width: rect.width - list.width, height: rect.height), widths: [34, 22, 40], step: 6)
        } else {
            let strip = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 8)
            box(strip, Palette.list)
            for index in 0..<2 {
                let tab = NSRect(x: strip.minX + 4 + CGFloat(index) * 22, y: strip.minY + 2, width: 18, height: 4)
                box(tab, index == 0 ? Palette.accent : Palette.dot, radius: 2)
            }
            bars(in: NSRect(x: rect.minX, y: strip.maxY, width: rect.width, height: rect.height - strip.height), widths: [30, 20, 38], step: 6)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let outer = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: outer, xRadius: 7, yRadius: 7)
        Palette.window.setFill()
        shape.fill()
        Palette.border.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        // The title bar's three buttons, muted.
        for index in 0..<3 {
            box(NSRect(x: outer.minX + 7 + CGFloat(index) * 7, y: outer.minY + 5, width: 4, height: 4), Palette.dot, radius: 2)
        }
        let gap: CGFloat = 3
        var body = NSRect(x: outer.minX + 5, y: outer.minY + 13, width: outer.width - 10, height: outer.height - 18)
        let columnWidth: CGFloat = 14, sidebarWidth: CGFloat = 38
        func takeLeft(_ width: CGFloat) -> NSRect {
            let part = NSRect(x: body.minX, y: body.minY, width: width, height: body.height)
            body = NSRect(x: part.maxX + gap, y: body.minY, width: body.width - width - gap, height: body.height)
            return part
        }
        func takeRight(_ width: CGFloat) -> NSRect {
            let part = NSRect(x: body.maxX - width, y: body.minY, width: width, height: body.height)
            body = NSRect(x: body.minX, y: body.minY, width: body.width - width - gap, height: body.height)
            return part
        }
        switch preset {
        case .ide, .agents:
            column(takeRight(columnWidth))
            let sidebar = takeLeft(sidebarWidth)
            box(sidebar, Palette.panel)
            bars(in: sidebar, widths: [22, 16, 26, 18, 14, 20, 12, 24, 16, 20, 14, 22])
            let editorHeight = (body.height - gap) * 0.52
            let editor = NSRect(x: body.minX, y: body.minY, width: body.width, height: editorHeight)
            box(editor, Palette.editor)
            bars(in: editor, widths: [44, 66, 52, 30, 58])
            terminal(NSRect(x: body.minX, y: editor.maxY + gap, width: body.width, height: body.height - editorHeight - gap),
                     tabsListed: preset == .agents)
        case .terminal:
            column(takeLeft(columnWidth))
            let sidebar = takeLeft(sidebarWidth)
            box(sidebar, Palette.panel)
            bars(in: sidebar, widths: [22, 16, 26, 18, 14, 20, 12, 24, 16, 20, 14, 22])
            let terminalWidth = (body.width - gap) * 0.5
            terminal(takeRight(terminalWidth), tabsListed: false)
            box(body, Palette.editor)
            bars(in: body, widths: [30, 44, 36, 20, 40, 26, 34, 18, 38, 28, 32, 22])
        }
    }
}
