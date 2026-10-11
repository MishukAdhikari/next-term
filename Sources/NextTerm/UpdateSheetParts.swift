import AppKit
import NextTermCore

/// The update sheet's or the wait panel's buttons, none of them the default (R15). The row is rebuilt only when the state's
/// buttons change, never on the panel's second-by-second redraw, so a click whose press and release fall on either side of
/// a tick still lands, and VoiceOver's focus stays on the button it was on. A press is told by the button's kind.
@MainActor
final class UpdateButtonRow: NSStackView {
    private(set) var buttons: [UpdateButton: NSButton] = [:]
    private var shown: [UpdateButton] = []
    /// ⎋ presses Cancel (the sheet's). No other button has a key.
    var escapeCancels = false

    /// Shows `kinds` in order, after a flexible space. True when the row was rebuilt.
    @discardableResult
    func show(_ kinds: [UpdateButton]) -> Bool {
        guard kinds != shown else { return false }
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = [:]
        addArrangedSubview(NSView())
        for kind in kinds {
            let button = NSButton(title: kind.title, target: self, action: #selector(press(_:)))
            button.bezelStyle = .rounded
            // No default button: Return presses nothing (R15). Cancel may take ⎋, which asks for nothing.
            button.keyEquivalent = escapeCancels && kind == .cancel ? "\u{1b}" : ""
            button.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
            buttons[kind] = button
            addArrangedSubview(button)
        }
        shown = kinds
        return true
    }

    /// By the button's kind, so a press is never dropped for a button drawn again; the flow takes only its state's buttons.
    @objc private func press(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let kind = UpdateButton(rawValue: raw) else { return }
        UpdateKeepSessions.shared.pressed(kind)
    }
}

/// A list on the update sheet or the wait panel that grows with its lines up to `maxHeight`, then scrolls: the busy tabs,
/// the details and the open decisions, so the checkbox and the buttons stay on the screen however many there are.
@MainActor
final class UpdateListScroll: NSScrollView {
    let stack = NSStackView()
    var maxHeight: CGFloat
    private var height: NSLayoutConstraint?

    init(maxHeight: CGFloat, bordered: Bool, insets: NSEdgeInsets = NSEdgeInsetsZero, spacing: CGFloat = 2) {
        self.maxHeight = maxHeight
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        documentView = document
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = bordered ? .bezelBorder : .noBorder
        drawsBackground = bordered
        translatesAutoresizingMaskIntoConstraints = false
        let height = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            height,
        ])
        self.height = height
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The height it takes now.
    var shownHeight: CGFloat { height?.constant ?? 0 }

    /// The height its lines need now, up to `maxHeight`.
    func fit() {
        let border: CGFloat = borderType == .noBorder ? 0 : 2
        height?.constant = min(stack.fittingSize.height + border, maxHeight)
    }
}

/// A view whose origin is at the top, so a list starts at the top of its scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension NSTextField {
    /// Sets the text only when it changed: a label drawn again each second keeps VoiceOver where it was.
    func showIfChanged(_ text: String) {
        if stringValue != text { stringValue = text }
    }
}
