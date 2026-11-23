import AppKit
import NextTermCore

/// The connector bar: one quiet line along the bottom of a window's work area, shown when an agent in that window needed
/// one of the user's MCP servers and only the user can mend it (MCPConnectorAttention has the rules and the words). One
/// primary button, which signs in, retries or opens Settings › MCP Servers; Not Now, which holds it for that server until
/// it needs something else; while the browser is out, its progress and Cancel; once mended, "connected" for a moment.
/// Never at launch, never a modal, never in the agent's text, and it takes no key: Return still goes to the terminal.
final class MCPConnectorBar: NSView {
    static let height: CGFloat = 32

    private let glyph = NSImageView()
    private let spinner = NSProgressIndicator()
    private let message = NSTextField(labelWithString: "")
    private let settingsButton = MCPConnectorBar.quiet("MCP Servers\u{2026}")
    private let notNow = MCPConnectorBar.quiet("Not Now")
    private let cancel = MCPConnectorBar.quiet("Cancel")
    private let primary = NSButton(title: "", target: nil, action: nil)
    var heightConstraint: NSLayoutConstraint?

    var onPrimary: (() -> Void)?
    var onNotNow: (() -> Void)?
    var onSettings: (() -> Void)?
    var onCancel: (() -> Void)?

    /// What it says now, for the self-test.
    private(set) var shown: MCPConnectorAttention.Words?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        themedBackground(Theme.bar)
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("MCP server")

        glyph.imageScaling = .scaleProportionallyDown
        glyph.setAccessibilityElement(false)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        message.font = .systemFont(ofSize: 12)
        message.textColor = Theme.text
        Typography.singleLine(message, truncation: .byTruncatingTail)
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.setContentHuggingPriority(.defaultLow, for: .horizontal)

        primary.bezelStyle = .rounded
        primary.controlSize = .small
        primary.font = .systemFont(ofSize: 11, weight: .medium)
        primary.bezelColor = Theme.system(.accent)
        primary.keyEquivalent = "" // Return stays the terminal's
        primary.target = self
        primary.action = #selector(primaryClicked)
        notNow.target = self
        notNow.action = #selector(notNowClicked)
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)
        cancel.target = self
        cancel.action = #selector(cancelClicked)

        let lead = NSStackView(views: [glyph, spinner, message])
        lead.orientation = .horizontal
        lead.spacing = 7
        let trail = NSStackView(views: [settingsButton, notNow, cancel, primary])
        trail.orientation = .horizontal
        trail.spacing = 6
        trail.setHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [lead, trail])
        row.orientation = .horizontal
        row.distribution = .fill
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let line = NSBox()
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = Theme.border
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            row.heightAnchor.constraint(equalToConstant: Self.height - 1),
            glyph.widthAnchor.constraint(equalToConstant: 14),
            glyph.heightAnchor.constraint(equalToConstant: 14),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func quiet(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = Theme.textDim
        button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: Theme.textDim, .font: NSFont.systemFont(ofSize: 11)])
        button.setButtonType(.momentaryChange)
        return button
    }

    /// Shows `words`, or hides the bar for nil. `settings`: offer MCP Servers… beside Not Now.
    func show(_ words: MCPConnectorAttention.Words?, settings: Bool = true, cancellable: Bool = false) {
        shown = words
        guard let words else { return setVisible(false) }
        message.stringValue = words.message
        message.toolTip = words.detail.map { words.message + "\n\n" + $0 } ?? words.message
        let working = words.glyph == .working
        spinner.isHidden = !working
        if working { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        glyph.isHidden = working
        glyph.image = Self.image(words.glyph)
        glyph.contentTintColor = Self.tint(words.glyph)
        primary.isHidden = words.primary == nil
        primary.title = words.primary ?? ""
        let asking = words.action != nil
        notNow.isHidden = !asking
        settingsButton.isHidden = !asking || !settings || words.action == .openSettings
        cancel.isHidden = !cancellable
        setAccessibilityLabel("MCP server: " + words.message)
        let appearing = isHidden
        setVisible(true)
        if appearing || words.glyph == .done {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: words.message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    private func setVisible(_ visible: Bool) {
        guard visible == isHidden else { return }
        let target: CGFloat = visible ? Self.height : 0
        if visible { isHidden = false }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduce ? 0 : 0.18
            context.allowsImplicitAnimation = true
            heightConstraint?.animator().constant = target
            superview?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shown == nil else { return }
                self.isHidden = true
            }
        })
    }

    private static func image(_ glyph: MCPConnectorAttention.Glyph) -> NSImage? {
        let name: String
        switch glyph {
        case .needsYou: name = "person.crop.circle.badge.exclamationmark"
        case .offline: name = "bolt.horizontal.circle"
        case .failed: name = "exclamationmark.circle"
        case .done: name = "checkmark.circle.fill"
        case .working: return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    private static func tint(_ glyph: MCPConnectorAttention.Glyph) -> NSColor {
        switch glyph {
        case .needsYou: return Theme.attention
        case .offline, .working: return Theme.textDim
        case .failed: return Theme.failed
        case .done: return Theme.done
        }
    }

    @objc private func primaryClicked() { onPrimary?() }
    @objc private func notNowClicked() { onNotNow?() }
    @objc private func settingsClicked() { onSettings?() }
    @objc private func cancelClicked() { onCancel?() }

    #if DEBUG
    /// The buttons a user can press now, by title, for the self-test.
    var buttonsForTest: [String] { [settingsButton, notNow, cancel, primary].filter { !$0.isHidden }.map(\.title) }
    var primaryKeyForTest: String { primary.keyEquivalent }
    func pressForTest(_ title: String) { [settingsButton, notNow, cancel, primary].first { !$0.isHidden && $0.title == title }?.performClick(nil) }
    #endif
}
