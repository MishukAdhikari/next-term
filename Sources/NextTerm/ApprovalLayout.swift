import AppKit
import NextTermCore

/// The parts every window that asks the user for a yes is made of (the secret approval panel, an agent's MCP request,
/// a key request): one type scale, the agent's words set apart as its own, a disclosure row that works as one control,
/// a command box that wraps only between words or path parts, and one row of buttons with a single primary.
///
/// The primary (Allow, Approve, Save, Run) is the rightmost button, filled with the accent colour and semibold, so it
/// reads as the action at a glance (PrimaryButton). It is pressed only by a click: these windows come up while the user
/// types elsewhere, so Return never answers them, nor Tab then Space. Escape declines, which is always safe. A choice
/// that can't be undone (Remove) is filled red instead.
@MainActor
enum ApprovalLayout {
    /// The windows' inner width: their content less the 20-point margins either side (DialogFit.insets).
    static func inner(_ width: CGFloat) -> CGFloat { width - 40 }

    // MARK: type

    /// The one heading: what is asked, in plain words (the window's own title bar stays hidden).
    static func heading(_ text: String, width: CGFloat) -> NSTextField {
        styled(text, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor, width: width)
    }

    /// Body text: what happens, the facts that matter.
    static func body(_ text: String, width: CGFloat) -> NSTextField {
        styled(text, font: .systemFont(ofSize: 12), color: .labelColor, width: width)
    }

    /// Secondary text: who asked, notes, a key's purpose.
    static func secondary(_ text: String, width: CGFloat) -> NSTextField {
        styled(text, font: .systemFont(ofSize: 11), color: .secondaryLabelColor, width: width)
    }

    /// A small caption over a block (The agent says).
    static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Wrapping text with a little more than the default leading (120% at the least, as body text reads best).
    static func styled(_ text: String, font: NSFont, color: NSColor, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.15
        paragraph.lineBreakMode = .byWordWrapping
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
        label.preferredMaxLayoutWidth = width
        return label
    }

    // MARK: the agent's words

    /// The agent's own words, set apart so they never read as Next Term's: a caption, then the words in plain text,
    /// indented beside a thin rule. No quote marks, no italics (the frame does that work).
    static func agentWords(_ words: String, who: String?, width: CGFloat) -> NSView {
        let speaker: String = who.map { "\($0) says" } ?? "The agent says"
        let caption = caption(speaker)
        let text = body(words, width: width - 12)
        text.toolTip = "These are the agent\u{2019}s words, not Next Term\u{2019}s."
        text.setAccessibilityLabel("\(speaker), in its own words")
        let rule = NSBox()
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = .separatorColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.widthAnchor.constraint(equalToConstant: 2).isActive = true
        let block = NSStackView(views: [rule, text])
        block.orientation = .horizontal
        block.alignment = .top
        block.spacing = 10
        rule.heightAnchor.constraint(equalTo: text.heightAnchor).isActive = true
        let stack = NSStackView(views: [caption, block])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        caption.setAccessibilityElement(false)
        return stack
    }

    // MARK: groups

    /// Views that belong together, 4 points apart; groups sit 16 points apart in the window.
    static func group(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    static let groupSpacing: CGFloat = 16

    // MARK: buttons

    /// How the primary button looks: tinted with the accent for a yes, or marked destructive for one that can't be
    /// undone.
    enum PrimaryLook {
        case accent, destructive
    }

    /// The window's buttons: `left` (rarer choices, such as Decline and Stop Asking) at the start, then Decline and the
    /// primary at the end. Decline takes Escape; the primary takes no key and never the keyboard, so only a click
    /// presses it. It stands as tall as Decline's bezel.
    static func buttonRow(left: [NSButton], decline: NSButton, primary: PrimaryButton, look: PrimaryLook = .accent) -> NSStackView {
        for button in left + [decline, primary] {
            button.bezelStyle = .rounded
            button.keyEquivalent = ""
        }
        decline.keyEquivalent = "\u{1b}" // Escape declines, which is always safe
        primary.refusesFirstResponder = true
        primary.look = look
        let row = NSStackView(views: left + [NSView(), decline, primary])
        row.spacing = 8
        primary.heightAnchor.constraint(equalTo: decline.heightAnchor).isActive = true
        return row
    }

    /// An alert's chosen button (an NSAlert, key while it shows, so AppKit's own tint draws): tinted and semibold, or
    /// marked destructive.
    static func style(_ primary: NSButton, look: PrimaryLook) {
        primary.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        switch look {
        case .accent:
            primary.bezelColor = .controlAccentColor
            primary.hasDestructiveAction = false
        case .destructive:
            primary.bezelColor = nil
            primary.hasDestructiveAction = true
        }
    }
}

/// The approval windows' primary: filled with the accent colour (red for one that can't be undone), a white semibold
/// title, darker while pressed and faded while disabled. It draws its own fill because these windows never become key,
/// and AppKit draws a tint, a default button and a prominent button only in the key window: anything else would be as
/// grey as Decline beside it.
@MainActor
final class PrimaryButton: NSButton {
    var look: ApprovalLayout.PrimaryLook = .accent {
        didSet { restyle() }
    }

    private static let padding: CGFloat = 14

    /// Made by NSButton's `init(title:target:action:)`, which sets a bezel first: borderless from here on.
    private func restyle() {
        isBordered = false
        wantsLayer = true
        bezelColor = look == .accent ? .controlAccentColor : .systemRed
        hasDestructiveAction = look == .destructive
        let colour = NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.6)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        super.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), .foregroundColor: colour, .paragraphStyle: paragraph,
        ])
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    override var title: String {
        get { super.title }
        set {
            super.title = newValue
            restyle()
        }
    }

    override var isEnabled: Bool {
        didSet { restyle() }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        return NSSize(width: ceil(text.width) + Self.padding * 2, height: max(ceil(text.height) + 8, 22))
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let fill: NSColor = look == .accent ? .controlAccentColor : .systemRed
        let shown = isHighlighted ? fill.blended(withFraction: 0.25, of: .black) ?? fill : fill
        layer?.cornerRadius = 6
        layer?.backgroundColor = shown.withAlphaComponent(isEnabled ? 1 : 0.45).cgColor
    }
}

/// A disclosure that works as one control: the triangle and its words both open it, and VoiceOver hears one
/// "Details, collapsed" (the triangle's own title is empty, as every other disclosure's in the app, so it never draws
/// its words twice or broken).
@MainActor
final class DisclosureRow: NSStackView {
    let triangle = NSButton(title: "", target: nil, action: nil)
    private let words: NSButton
    private let content: NSView
    /// Called after it opens or closes, for the window to fit its new height.
    var onToggle: (() -> Void)?

    init(title: String, content: NSView) {
        self.content = content
        words = NSButton(title: title, target: nil, action: nil)
        super.init(frame: .zero)
        triangle.setButtonType(.pushOnPushOff)
        triangle.bezelStyle = .disclosure
        triangle.state = .off
        triangle.target = self
        triangle.action = #selector(toggled)
        triangle.setAccessibilityLabel(title)
        words.isBordered = false
        words.font = .systemFont(ofSize: 12)
        words.contentTintColor = .labelColor
        words.target = self
        words.action = #selector(wordsClicked)
        words.setAccessibilityElement(false)
        words.refusesFirstResponder = true // the triangle is the one keyboard stop, as it is the one VoiceOver element
        let header = NSStackView(views: [triangle, words])
        header.spacing = 2
        content.isHidden = true
        orientation = .vertical
        alignment = .leading
        spacing = 4
        addArrangedSubview(header)
        addArrangedSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var isOpen: Bool { triangle.state == .on }

    @objc private func wordsClicked() {
        triangle.state = triangle.state == .on ? .off : .on
        toggled()
    }

    @objc private func toggled() {
        content.isHidden = triangle.state != .on
        onToggle?()
    }
}

/// A command shown as it runs, in a light box: it wraps only after a space or a slash (between words or path parts),
/// so a long path never breaks mid-name, and nothing is added to the text, so a copy is the command itself.
@MainActor
final class CommandBox: NSView, NSLayoutManagerDelegate {
    let text: NSTextView
    private let width: CGFloat

    init(_ command: String, width: CGFloat) {
        self.width = width
        text = NSTextView(frame: NSRect(x: 0, y: 0, width: width - 16, height: 20))
        super.init(frame: .zero)
        text.string = command
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textColor = .labelColor
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.layoutManager?.delegate = self
        text.setAccessibilityLabel("Command") // its value is the command
        wantsLayer = true
        addSubview(text)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // The fill is set as the box draws, so it follows the window's appearance (dark, light) and Increase Contrast.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        layer?.borderWidth = contrast ? 1 : 0
        layer?.borderColor = contrast ? NSColor.separatorColor.cgColor : nil
    }

    override var intrinsicContentSize: NSSize {
        guard let manager = text.layoutManager, let container = text.textContainer else { return NSSize(width: width, height: 24) }
        container.containerSize = NSSize(width: width - 16, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used: NSRect = manager.usedRect(for: container)
        return NSSize(width: width, height: ceil(used.height) + 12)
    }

    override func layout() {
        super.layout()
        text.frame = NSRect(x: 8, y: 6, width: width - 16, height: bounds.height - 12)
    }

    /// Breaks only where a person would: before a character that follows a space or a slash.
    nonisolated func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
        guard charIndex > 0, let storage = layoutManager.textStorage else { return true }
        let string = storage.string as NSString
        guard charIndex <= string.length else { return true }
        let before: unichar = string.character(at: charIndex - 1)
        return before == 0x20 || before == 0x2F
    }
}
