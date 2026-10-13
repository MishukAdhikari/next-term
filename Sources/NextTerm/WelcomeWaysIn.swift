import AppKit
import NextTermCore

/// The line under the Welcome list that says what the keys do for the selection: "↩ go to window", "⌘↩ new window",
/// "esc close", or with nothing selected the three ways in with their keys (`SwitcherHint`). Its parts are set apart by
/// `Typography.gap`, never typed spaces, and the key glyphs are in the line's own font.
final class SwitcherHintLine: NSTextField {
    static let lineFont = NSFont.systemFont(ofSize: 11)
    static let partGap: CGFloat = 14
    /// The parts shown, for the self-test.
    private(set) var parts: [String] = []

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = Self.lineFont
        textColor = Theme.textDim
        Typography.singleLine(self, truncation: .byTruncatingTail)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ parts: [String]) {
        guard parts != self.parts else { return }
        self.parts = parts
        let font: NSFont = Self.lineFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.textDim]
        let line = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 { line.append(Typography.gap(Self.partGap, font: font)) }
            line.append(NSAttributedString(string: part, attributes: attributes))
        }
        attributedStringValue = Typography.truncating(line, .byTruncatingTail)
        setAccessibilityLabel(parts.joined(separator: ", "))
    }
}

// MARK: - the three ways in

/// What a way in does when clicked, as the menu command does: Open… the folder panel (over the Welcome window when it
/// is in front), Connect to Server… the remote sheet, New Terminal a window with a shell. And the command whose key its
/// tooltip names: Open… is File › Open Project…'s key here.
extension SwitcherWayIn {
    var action: Selector {
        switch self {
        case .open: return #selector(AppDelegate.chooseProjectFolder(_:))
        case .connect: return #selector(AppDelegate.newRemoteTab(_:))
        case .newTerminal: return #selector(AppDelegate.newWindow(_:))
        }
    }

    var keyAction: Selector {
        switch self {
        case .open: return #selector(AppDelegate.openProjectPanel(_:))
        case .connect, .newTerminal: return action
        }
    }
}

/// What a way-in row and a first-launch card share: a button that draws only a fill in its shape, under the pointer or
/// while pressed, over labels that take no clicks and that VoiceOver never reads on their own. The button's title stays
/// the visible title, which VoiceOver reads, and its tooltip names what it opens and the key the menus give it. It never
/// has a key equivalent, so Return stays the selection's, and it is never the default button.
class WayInButton: NSButton {
    let way: SwitcherWayIn
    private var tip: ShortcutToolTip?

    init(_ way: SwitcherWayIn) {
        self.way = way
        super.init(frame: .zero)
        title = way.title
        // The labels draw it: image only, with no image, so the cell draws nothing, pressed or not.
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        keyEquivalent = ""
        target = NSApp.delegate
        action = way.action
        setAccessibilityLabel(way.title)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        tip = ShortcutToolTip(self, way.help, way.keyAction)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Puts `views` inside, laid out by constraints and silent to VoiceOver (a label is heard through its cell).
    func add(_ views: [NSView]) {
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityElement(false)
            (view as? NSControl)?.cell?.setAccessibilityElement(false)
            addSubview(view)
        }
    }

    /// The fill's shape.
    var shape: NSBezierPath { NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5) }
    /// The fill with the pointer elsewhere: none for a row, the card's own for a card.
    var restingFill: NSColor? { nil }

    /// Whether the pointer is over it now, read when drawn: a flag set on entering would stay on after a click closed
    /// the window under the pointer, and light the row at the next show.
    private var pointerInside: Bool {
        guard let window, window.isVisible else { return false }
        let point: NSPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        let lit: Bool = isHighlighted || pointerInside
        guard let fill = lit ? Theme.tabHover : restingFill else { return }
        fill.setFill()
        shape.fill()
    }

    // With the keyboard (Full Keyboard Access), the ring goes round the fill's shape.
    override func drawFocusRingMask() { shape.fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    /// The labels inside take no clicks: anywhere on it is the button.
    override func hitTest(_ point: NSPoint) -> NSView? { !isHidden && frame.contains(point) ? self : nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self))
    }

    override func mouseEntered(with event: NSEvent) { needsDisplay = true }
    override func mouseExited(with event: NSEvent) { needsDisplay = true }

    /// A key label: tabular figures, as the heading's count, never cut.
    static func keyLabel() -> NSTextField {
        let key = NSTextField(labelWithString: "")
        key.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        key.textColor = Theme.textDim
        Typography.singleLine(key, truncation: .byClipping)
        key.setContentCompressionResistancePriority(.required, for: .horizontal)
        return key
    }
}

/// One of the three ways in as a row at the foot of the Welcome list, in the list's geometry: its symbol in the gutter,
/// its title where the names start, and at the right the key its menu command has now.
final class WayInRow: WayInButton {
    static let height: CGFloat = 28
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let key = WayInButton.keyLabel()

    override init(_ way: SwitcherWayIn) {
        super.init(way)
        icon.image = NSImage(systemSymbolName: way.symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.contentTintColor = Theme.textDim
        label.stringValue = way.title
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.text
        Typography.singleLine(label, truncation: .byTruncatingTail)
        key.alignment = .right
        add([icon, label, key])
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: SwitcherRowStyle.gutterCenter),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SwitcherRowStyle.nameX),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: key.leadingAnchor, constant: -8),
            key.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            key.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The list's selection shape (`GoToFileRowView`), so a row under the pointer lines up with a selected one.
    override var shape: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5)
    }

    /// The key its menu command has now, or none.
    func show(key chord: KeyChord?) {
        key.stringValue = chord?.display ?? ""
        key.isHidden = chord == nil
        needsDisplay = true
    }

    /// For the self-test: the key shown at the right.
    var shownKey: String? { key.isHidden ? nil : key.stringValue }
}

/// Open…, Connect to Server… and New Terminal at the foot of the Welcome list's column, in that order, as three rows
/// alike. They sit outside the list, so ↑ and ↓ never land on one; their keys and Full Keyboard Access reach them.
final class WaysInRows: NSStackView {
    let rows: [WayInRow] = SwitcherWayIn.allCases.map { (way: SwitcherWayIn) -> WayInRow in WayInRow(way) }

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        for row in rows {
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Start")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func row(_ way: SwitcherWayIn) -> WayInRow {
        rows.first { (row: WayInRow) -> Bool in row.way == way } ?? rows[0]
    }

    /// The keys the menus give the three now.
    func show(_ keys: SwitcherWaysIn) {
        for row in rows { row.show(key: keys.key(for: row.way)) }
    }
}

/// One of the three ways in as a first-launch card: its symbol, its title, one sentence on what it opens, and its key,
/// centred, on a fill of its own. No border: the fill is the card.
final class WayInCard: WayInButton {
    static let padding: CGFloat = 14
    /// The sentence's line height: 16 on 12 pt, 133 percent.
    static let lineHeight: CGFloat = 16
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let sentence = NSTextField(wrappingLabelWithString: "")
    private let key = WayInButton.keyLabel()

    override init(_ way: SwitcherWayIn) {
        super.init(way)
        icon.image = NSImage(systemSymbolName: way.symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        icon.contentTintColor = Theme.textDim
        label.stringValue = way.title
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = Theme.text
        label.alignment = .center
        // Two lines at most, in the narrowest window; one wherever there is room.
        label.maximumNumberOfLines = 2
        sentence.attributedStringValue = Self.sentenceText(way.sentence)
        key.alignment = .center
        add([icon, label, sentence, key])
        let pad: CGFloat = Self.padding
        let low = heightAnchor.constraint(equalToConstant: 0)
        low.priority = .defaultLow // as short as its text allows
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            sentence.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            sentence.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            sentence.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            // The keys sit at the foot, so the three line up whatever their sentences' lengths.
            key.topAnchor.constraint(greaterThanOrEqualTo: sentence.bottomAnchor, constant: 12),
            key.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            key.centerXAnchor.constraint(equalTo: centerXAnchor),
            low,
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// 12 pt on 16, centred, wrapping at words. The line's extra height goes above the text, so the baseline is raised
    /// by half of it to centre the text in its line.
    private static func sentenceText(_ text: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        let natural: CGFloat = font.ascender - font.descender + font.leading
        let raise: CGFloat = max(0, (lineHeight - natural) / 2)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: Theme.textDim, .paragraphStyle: style, .baselineOffset: raise,
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }

    override var shape: NSBezierPath { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8) }
    override var restingFill: NSColor? { Theme.bar }

    /// The wrapping labels wrap at the card's width, less its padding.
    override func layout() {
        let width: CGFloat = max(0, bounds.width - 2 * Self.padding)
        if label.preferredMaxLayoutWidth != width { label.preferredMaxLayoutWidth = width }
        if sentence.preferredMaxLayoutWidth != width { sentence.preferredMaxLayoutWidth = width }
        super.layout()
    }

    /// VoiceOver hears the title, then the sentence and the tooltip with its key.
    override func accessibilityHelp() -> String? {
        let tip: String = toolTip ?? way.help
        return way.sentence + " " + tip
    }

    func show(key chord: KeyChord?) {
        key.stringValue = chord?.display ?? ""
        key.isHidden = chord == nil
        needsDisplay = true
    }

    /// For the self-test: what the card says, its title, sentence and key.
    var shownText: [String] { [label.stringValue, sentence.stringValue, key.isHidden ? "" : key.stringValue] }
}

/// The right pane on a launch with nothing to list: the three ways in as cards of equal width, 16 pt apart, in the
/// rows' order, centred. A click on one, or its key, does what its row does.
final class WaysInCards: NSView {
    let cards: [WayInCard] = SwitcherWayIn.allCases.map { (way: SwitcherWayIn) -> WayInCard in WayInCard(way) }
    private let stack = NSStackView()
    /// As wide as three cards of about 176 pt; narrower windows narrow them.
    static let width: CGFloat = 560

    init() {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .top
        stack.spacing = 16
        for card in cards { stack.addArrangedSubview(card) }
        // One height for the three, the tallest's, so their keys line up.
        for card in cards.dropFirst() { card.heightAnchor.constraint(equalTo: cards[0].heightAnchor).isActive = true }
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.group)
        stack.setAccessibilityLabel("Start")
        addSubview(stack)
        let wide = stack.widthAnchor.constraint(equalToConstant: Self.width)
        wide.priority = .defaultHigh
        // A little above the middle, clear of the footer below.
        let middle = stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -16)
        middle.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 40),
            wide,
            middle,
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func card(_ way: SwitcherWayIn) -> WayInCard {
        cards.first { (card: WayInCard) -> Bool in card.way == way } ?? cards[0]
    }

    /// The keys the menus give the three now.
    func show(_ keys: SwitcherWaysIn) {
        for card in cards { card.show(key: keys.key(for: card.way)) }
    }
}

// MARK: - At launch

/// "At launch:" and its pop-up at the foot of the right pane, for the user who wants a shell at every launch and never
/// this window. The same setting as Settings › General, with its three choices titled as its radio buttons are
/// (`LaunchOpens.title`), read and saved as it does, so one setting reads the same in both places and a change in
/// either shows in the other.
final class AtLaunchFooter: NSView {
    let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let label = NSTextField(labelWithString: "At launch:")
    /// Where the choice is kept: the defaults the launch reads it from.
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init(frame: .zero)
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.font = font
        label.textColor = Theme.textDim
        // The pop-up has the label's words for its name: VoiceOver reads them once, with it.
        label.setAccessibilityElement(false)
        label.cell?.setAccessibilityElement(false)
        popUp.controlSize = .small
        popUp.font = font
        for choice in LaunchOpens.allCases { popUp.addItem(withTitle: choice.title) }
        popUp.target = self
        popUp.action = #selector(chosen)
        popUp.setAccessibilityLabel("At launch")
        popUp.toolTip = "What Next Term opens at a launch that names no folder and restores nothing, as in Settings › General"
        // In the narrowest window it gives way to the buttons beside it, its title cut with an ellipsis.
        popUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [label, popUp] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.firstBaselineAnchor.constraint(equalTo: popUp.firstBaselineAnchor),
            popUp.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            popUp.trailingAnchor.constraint(equalTo: trailingAnchor),
            popUp.topAnchor.constraint(equalTo: topAnchor),
            popUp.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refresh()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(refresh), name: LaunchSettings.changed, object: nil)
        // An import or its Undo can change it too.
        center.addObserver(self, selector: #selector(refresh), name: ImportCoordinator.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The choice saved now, as the next launch reads it.
    @objc func refresh() {
        let opens: LaunchOpens = LaunchSettings(defaults: defaults).opens
        popUp.selectItem(at: LaunchOpens.allCases.firstIndex(of: opens) ?? 0)
    }

    /// The choice the pop-up shows.
    var choice: LaunchOpens { LaunchOpens.allCases[safe: popUp.indexOfSelectedItem] ?? .standard }

    /// For the self-test: `choice` picked, as a pick in the pop-up does.
    func choose(_ choice: LaunchOpens) {
        popUp.selectItem(at: LaunchOpens.allCases.firstIndex(of: choice) ?? 0)
        chosen()
    }

    @objc private func chosen() {
        guard let choice = LaunchOpens.allCases[safe: popUp.indexOfSelectedItem] else { return }
        var settings = LaunchSettings(defaults: defaults)
        settings.opens = choice
        settings.save(.opens, to: defaults)
        NotificationCenter.default.post(name: LaunchSettings.changed, object: self)
    }
}
