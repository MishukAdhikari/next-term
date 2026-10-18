import AppKit
import CoreText
import NextTermCore

/// The suggestion while typing, drawn over the terminal (a subview of NextTermView, at the bottom of its subviews, under
/// SwiftTerm's caret) at the terminal's cells, in its font, from the cursor's cell: never text in the grid, so nothing
/// that reads the terminal (copy, Find, MCP, the scrollback saved at quit, VoiceOver) ever finds it. A click goes through
/// it to the terminal. Its ObjC name is stable for the perf budget's shim, which stamps `ghostShown(_:)` and its drawing.
@objc(NTGhostText)
final class GhostTextView: NSView {
    private(set) var text = ""
    /// The cells each character takes.
    private var widths: [Int] = []
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var colour = NSColor.gray
    private var underline = false
    private var cell = CGSize(width: 8, height: 16)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    /// Shows `text`, fitted already (GhostClip), with its first cell at `origin` (the cursor's, in the terminal's
    /// coordinates): `cell` is the terminal's cell, and the baseline is SwiftTerm's, its font's descent and leading above the
    /// cell's bottom.
    func show(_ text: String, at origin: CGPoint, cell: CGSize, font: NSFont, colour: NSColor, underline: Bool) {
        let widths = text.map(GhostClip.cells)
        let frame = NSRect(x: origin.x, y: origin.y, width: CGFloat(widths.reduce(0, +)) * cell.width, height: cell.height)
        let same = text == self.text && frame == self.frame && font == self.font && colour == self.colour && underline == self.underline
        self.text = text
        self.widths = widths
        self.cell = cell
        self.font = font
        self.colour = colour
        self.underline = underline
        if self.frame != frame { self.frame = frame }
        isHidden = false
        if !same { needsDisplay = true }
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        text = ""
    }

    /// Called once a suggestion is placed, with the uptime the shell's report it answers was read at: the perf budget's
    /// stamp (its shim swizzles it). Nothing is counted here.
    @objc dynamic func ghostShown(_ arrival: Double) {}

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let baseline = ceil(CTFontGetDescent(font) + CTFontGetLeading(font))
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
        context.saveGState()
        context.textMatrix = .identity
        var column = 0
        for (character, width) in zip(text, widths) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: attributes))
            context.textPosition = CGPoint(x: CGFloat(column) * cell.width, y: baseline)
            CTLineDraw(line, context)
            column += width
        }
        if underline {
            // Differentiate Without Colour: a dotted line under it says it isn't typed.
            context.setStrokeColor(colour.cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [1, 2])
            let y = max(0.5, baseline - 1.5)
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: CGFloat(column) * cell.width, y: y))
            context.strokePath()
        }
        context.restoreGState()
    }
}


/// A small notice in a tab, at the top or the bottom of its terminal, away from the cursor's row so it never covers the
/// line being typed: a line that says what it is about, its buttons, and a close button. None of them takes the keyboard,
/// so typing goes on in the terminal. Suggestions while typing use it to ask once where a plugin draws its own, and for
/// their first-use hint.
final class GhostNotice: NSView {
    let text: String
    private var actions: [() -> Void] = []
    private let onClose: () -> Void

    /// `buttons` in order, then the close button, labelled `closeLabel` for VoiceOver.
    init(_ text: String, buttons: [(title: String, action: () -> Void)], closeLabel: String, onClose: @escaping () -> Void) {
        self.text = text
        self.onClose = onClose
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(text)

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .white
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [label]
        for (index, button) in buttons.enumerated() {
            let control = NSButton(title: button.title, target: self, action: #selector(pressed(_:)))
            control.tag = index
            control.bezelStyle = .inline
            control.controlSize = .small
            control.refusesFirstResponder = true
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            actions.append(button.action)
            views.append(control)
        }
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: closeLabel) ?? NSImage(),
                             target: self, action: #selector(closed(_:)))
        close.isBordered = false
        close.contentTintColor = NSColor.white.withAlphaComponent(0.8)
        close.refusesFirstResponder = true
        close.setAccessibilityLabel(closeLabel)
        close.toolTip = closeLabel
        views.append(close)
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Pinned to the edge of `view` away from the cursor's row (the bottom when the prompt is in the top half: a new tab,
    /// after a clear), centred, never wider than it; said once to VoiceOver, quietly. Neither notice outlives its line, so
    /// the cursor never moves to the other half under it.
    func show(in view: NextTermView) {
        view.addSubview(self)
        let terminal = view.getTerminal()
        let cursorInTopHalf = terminal.getCursorLocation().y < terminal.rows / 2
        let edge = cursorInTopHalf
            ? bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6)
            : topAnchor.constraint(equalTo: view.topAnchor, constant: 6)
        NSLayoutConstraint.activate([
            edge,
            centerXAnchor.constraint(equalTo: view.centerXAnchor),
            widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -16),
        ])
        let element: Any = view.window ?? NSApp as Any
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    /// The button titled `title`, for the self-test.
    func button(_ title: String) -> NSButton? {
        subviews.first?.subviews.compactMap { $0 as? NSButton }.first { $0.title == title }
    }

    /// The close button, for the self-test.
    var closeButton: NSButton? { subviews.first?.subviews.compactMap { $0 as? NSButton }.last }

    @objc private func pressed(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }

    @objc private func closed(_ sender: NSButton) { onClose() }
}
