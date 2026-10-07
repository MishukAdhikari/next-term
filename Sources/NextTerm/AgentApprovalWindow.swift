import AppKit

/// A request from an agent that only the user can grant, in a window of its own: who asked (the tab, or
/// "an agent outside Next Term's tabs" when the caller can't be found), what the agent says in its own
/// words (shown as such, never as Next Term's), and the user's two choices.
///
/// Agents ask at moments of their own choosing, so the window never takes the keyboard: it opens in
/// front without becoming key (typing to a terminal keeps going to the terminal), bounces the Dock icon
/// when Next Term is in the background, and has no default button, so no Return meant for something
/// else answers it. Any agent action that needs a person's yes can use it.
@MainActor
final class AgentApprovalWindow: NSWindowController, NSWindowDelegate {
    struct Request {
        var title: String
        /// Who asked, as Next Term knows it.
        var requester: String
        /// The agent's own words (its reason), if it gave any.
        var agentWords: String?
        /// What would happen, in plain words.
        var details: String
        var approveTitle: String
        var declineTitle = "Decline"
    }

    private let request: Request
    private let onApprove: (AgentApprovalWindow) -> Void
    private let onDecline: () -> Void
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let requesterLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var approveButton: NSButton!
    private(set) var declineButton: NSButton!
    private var answered = false

    init(_ request: Request, approve: @escaping (AgentApprovalWindow) -> Void, decline: @escaping () -> Void) {
        self.request = request
        onApprove = approve
        onDecline = decline
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260), styleMask: [.titled, .closable, .utilityWindow],
                             backing: .buffered, defer: false)
        window.title = request.title
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isFloatingPanel = false
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(wrappingLabelWithString: request.title)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        requesterLabel.stringValue = "Asked by \(request.requester)."
        requesterLabel.textColor = .secondaryLabelColor
        var views: [NSView] = [title, requesterLabel]
        if let words = request.agentWords?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty {
            let quote = NSTextField(wrappingLabelWithString: "The agent says: “\(String(words.prefix(500)))”")
            quote.font = .systemFont(ofSize: 12).withTraits(.italic)
            quote.toolTip = "These are the agent's words, not Next Term's."
            views.append(quote)
        }
        let details = NSTextField(wrappingLabelWithString: request.details)
        details.font = .systemFont(ofSize: 12)
        views.append(details)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.isHidden = true
        views.append(statusLabel)

        declineButton = NSButton(title: request.declineTitle, target: self, action: #selector(decline))
        approveButton = NSButton(title: request.approveTitle, target: self, action: #selector(approve))
        for button in [declineButton!, approveButton!] {
            button.bezelStyle = .rounded
            button.keyEquivalent = "" // no default button: see the type's comment
        }
        let buttons = NSStackView(views: [NSView(), declineButton, approveButton])
        buttons.spacing = 8
        views.append(buttons)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 480),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
        ])
        for view in views where view is NSTextField { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true }
    }

    /// Shows the window in front without taking the keyboard; bounces the Dock icon if Next Term is not
    /// the active app.
    func present() {
        guard let window else { return }
        window.layoutIfNeeded()
        window.center()
        window.orderFront(nil)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// A line under the request: progress ("Fetching…") or a problem.
    func setStatus(_ text: String, problem: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = problem ? .systemRed : .secondaryLabelColor
        statusLabel.isHidden = text.isEmpty
    }

    /// The agent's tab closed, or it stopped asking: what the user decides still happens.
    func requesterGone() {
        requesterLabel.stringValue = "Asked by \(request.requester), which has gone since. What you decide still happens."
    }

    /// Lets the user act again (after a failed attempt), or holds the buttons while something runs.
    func setBusy(_ busy: Bool) {
        approveButton.isEnabled = !busy
        declineButton.isEnabled = !busy
    }

    @objc private func approve() { onApprove(self) }

    @objc private func decline() {
        guard !answered else { return }
        answered = true
        onDecline()
        close()
    }

    /// Ends the request after an approval went through.
    func finish() {
        answered = true
        close()
    }

    /// Closing the window without choosing is a decline.
    func windowWillClose(_ notification: Notification) {
        guard !answered else { return }
        answered = true
        onDecline()
    }
}

private extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        NSFont(descriptor: fontDescriptor.withSymbolicTraits(traits), size: pointSize) ?? self
    }
}
