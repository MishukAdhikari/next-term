import AppKit

/// An alert whose last choice stands apart, under the others and past a rule with "or" in it: a destructive alternative
/// (Close and Remove Worktree), which NSAlert can't put there (it always moves Cancel to the bottom) nor set apart.
/// Laid out as NSAlert lays out a sheet on macOS 26: 260 points wide, the title and text centered, full-width large
/// buttons, Return for the first and Escape for Cancel. It answers as NSAlert does: .alertFirstButtonReturn for the
/// first button, and so on, the alternative last.
final class AlternativeAlert: NSObject {
    /// The one up now, for the self-test.
    private(set) static var current: AlternativeAlert?

    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 200), styleMask: [.titled, .fullSizeContentView],
                                backing: .buffered, defer: true)
    /// The buttons top to bottom, the alternative last.
    private(set) var buttons: [NSButton] = []
    private weak var parent: NSWindow?

    /// `note`: under the alternative, in small type: what it does besides what its title says.
    init(title: String, info: String, buttons titles: [String], alternative: String, note: String?) {
        super.init()
        let textWidth: CGFloat = 220, buttonWidth: CGFloat = 228
        func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.alignment = .center
            field.font = font
            field.textColor = color
            field.preferredMaxLayoutWidth = textWidth
            field.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
            return field
        }
        func button(_ title: String) -> NSButton {
            let button = NSButton(title: title, target: self, action: #selector(pressed(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .large
            button.tag = buttons.count
            button.widthAnchor.constraint(equalToConstant: buttonWidth).isActive = true
            buttons.append(button)
            return button
        }
        let heading = label(title, font: .boldSystemFont(ofSize: 13))
        let body = label(info, font: .systemFont(ofSize: 13))
        let choices = titles.map(button)
        choices.first?.keyEquivalent = "\r"
        choices.first { $0.title == "Cancel" }?.keyEquivalent = "\u{1b}"
        let apart = button(alternative)
        apart.hasDestructiveAction = true
        // Red as NSAlert's destructive buttons are: a push button's title takes no tint.
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        apart.attributedTitle = NSAttributedString(string: alternative, attributes: [
            .foregroundColor: NSColor.systemRed, .font: apart.font ?? .systemFont(ofSize: 13), .paragraphStyle: centered,
        ])

        let lines = [NSBox(), NSBox()]
        for line in lines { line.boxType = .separator }
        let orLabel = NSTextField(labelWithString: "or")
        orLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        orLabel.textColor = .secondaryLabelColor
        let rule = NSStackView(views: [lines[0], orLabel, lines[1]])
        rule.spacing = 8
        rule.widthAnchor.constraint(equalToConstant: buttonWidth).isActive = true
        lines[0].widthAnchor.constraint(equalTo: lines[1].widthAnchor).isActive = true

        var views: [NSView] = [heading] + (info.isEmpty ? [] : [body]) + choices + [rule, apart]
        let small = note.map { label($0, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor) }
        if let small { views.append(small) }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 16, bottom: 16, right: 16)
        stack.setCustomSpacing(10, after: heading)
        stack.setCustomSpacing(16, after: info.isEmpty ? heading : body)
        if let last = choices.last { stack.setCustomSpacing(12, after: last) }
        stack.setCustomSpacing(12, after: rule)
        stack.setCustomSpacing(6, after: apart)
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
    }

    /// Over `window` as a sheet; `completion` gets the answer once it is down.
    func begin(over window: NSWindow, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        parent = window
        Self.current = self
        window.beginSheet(panel) { response in
            if Self.current === self { Self.current = nil }
            completion(response)
        }
    }

    @objc private func pressed(_ sender: NSButton) {
        let response = NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + sender.tag)
        parent?.endSheet(panel, returnCode: response)
    }
}
