import AppKit
import NextTermCore

/// The banner an agent's import_secrets request puts under the import sheet's title (`SecretImportAsk`): who asks, from
/// where, and why; its Asked by facts; that a key the vault has is replaced only by the user's tick; and Decline and
/// Stop Asking, as request_secret's window has it.
extension SecretImportAsk {
    /// The banner under a sheet's title: who asks, from where, and the agent's reason, then its Asked by facts. The
    /// agent's words are shown as its own and never become a key's purpose.
    static func addBanner(_ ask: SecretImportAsk, to window: NSWindow?) {
        guard let stack = window?.contentView?.subviews.first(where: { (view: NSView) -> Bool in view is NSStackView })
            as? NSStackView, !stack.arrangedSubviews.isEmpty else { return }
        let banner: NSView = bannerView(ask)
        stack.insertArrangedSubview(banner, at: 1)
        banner.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
    }

    static func bannerView(_ ask: SecretImportAsk) -> NSView {
        let said: String = SecretApprovalPanel.sanitized(ask.banner, limit: 700)
        let line = NSTextField(wrappingLabelWithString: said)
        line.font = .systemFont(ofSize: 12, weight: .semibold)
        line.setAccessibilityLabel("Request: " + said)
        let facts: String = "Asked by \(SecretApprovalPanel.sanitized(ask.askedBy, limit: 300))."
        let asked = NSTextField(wrappingLabelWithString: facts)
        asked.font = .systemFont(ofSize: 11)
        asked.textColor = .secondaryLabelColor
        let replace = NSTextField(wrappingLabelWithString: replaceLine)
        replace.font = .systemFont(ofSize: 11)
        replace.textColor = .secondaryLabelColor
        let stop = SecretImportStopButton(ask)
        ask.stopButton = stop
        let stack = NSStackView(views: [line, asked, replace, stop])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.setCustomSpacing(8, after: replace)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
        box.identifier = NSUserInterfaceItemIdentifier(bannerID)
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        for label in [line, asked, replace] {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
        return box
    }

    static let bannerID = "import-secrets-banner"
    static let replaceLine = "The agent learns only the names you import and counts. A key you already have is "
        + "replaced only if you tick its row."
}

/// The banner's Decline and Stop Asking: the agent's request is declined, and it is asked nothing more until Next Term
/// quits. Off once the request has ended, as after a copy-in.
final class SecretImportStopButton: NSButton {
    private weak var ask: SecretImportAsk?

    init(_ ask: SecretImportAsk) {
        self.ask = ask
        super.init(frame: .zero)
        title = "Decline and Stop Asking"
        setButtonType(.momentaryPushIn)
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        keyEquivalent = ""
        isEnabled = !ask.hasEnded
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func clicked() { ask?.declineAndStopAsking() }
}
