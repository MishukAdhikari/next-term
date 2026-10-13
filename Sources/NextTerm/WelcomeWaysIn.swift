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
