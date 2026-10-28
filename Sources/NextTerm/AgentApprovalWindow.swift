import AppKit

/// A request from an agent that only the user can grant, in a window of its own: who asked (the tab, or
/// "an agent outside Next Term's tabs" when the caller can't be found), what the agent says in its own
/// words (shown as such, never as Next Term's), and the user's two choices.
///
/// Agents ask at moments of their own choosing, so the window never takes the keyboard: it opens in
/// front without becoming key (typing to a terminal keeps going to the terminal), bounces the Dock icon
/// when Next Term is in the background, and has no default button: its primary (Approve) is the rightmost, tinted
/// button, but only a click presses it, so no Return meant for something else answers it; Escape declines. Any agent
/// action that needs a person's yes can use it (ApprovalLayout).
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
        /// A third choice that declines and stops further requests from the same asker, or nil.
        var stopTitle: String?
        /// How the primary looks: tinted for a yes, marked destructive for one that can't be undone (Remove).
        var primaryLook: ApprovalLayout.PrimaryLook = .accent
        /// A command the approval runs, shown as it will be typed, in its own box over the details (run_command).
        var command: String?
    }

    private let request: Request
    private let onApprove: (AgentApprovalWindow) -> Void
    private let onDecline: (_ stopAsking: Bool) -> Void
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let requesterLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var approveButton: NSButton!
    private(set) var declineButton: NSButton!
    private(set) var stopButton: NSButton?
    private var answered = false

    /// `decline` is told whether the user also asked to stop further requests.
    init(_ request: Request, approve: @escaping (AgentApprovalWindow) -> Void, decline: @escaping (_ stopAsking: Bool) -> Void) {
        self.request = request
        onApprove = approve
        onDecline = decline
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260), styleMask: [.titled, .closable, .utilityWindow],
                             backing: .buffered, defer: false)
        window.title = request.title
        window.titleVisibility = .hidden // the heading says it once; the title stays for VoiceOver and the Window menu
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isFloatingPanel = false
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static let width: CGFloat = 480

    /// Groups, 16 points apart: what is asked and the agent's words; what would happen (a command first, in its box); who
    /// asked; then Decline and the primary.
    private func build() {
        guard let content = window?.contentView else { return }
        let inner = ApprovalLayout.inner(Self.width)
        var top: [NSView] = [ApprovalLayout.heading(SecretApprovalPanel.sanitized(request.title, limit: 200), width: inner)]
        if let raw = request.agentWords {
            let words = SecretApprovalPanel.sanitized(raw.trimmingCharacters(in: .whitespacesAndNewlines), limit: 500)
            if !words.isEmpty { top.append(ApprovalLayout.agentWords(words, who: nil, width: inner)) }
        }
        let details = ApprovalLayout.body(request.details, width: inner - 20) // room for the scroller
        // Long details (a task's whole file) scroll in a box of their own, so Decline and Approve stay on the screen.
        let detailsBox = UpdateListScroll(maxHeight: 320, bordered: false)
        detailsBox.stack.addArrangedSubview(details)
        requesterLabel.attributedStringValue = ApprovalLayout.secondary("Asked by \(request.requester).", width: inner).attributedStringValue
        requesterLabel.preferredMaxLayoutWidth = inner
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.isHidden = true

        declineButton = NSButton(title: request.declineTitle, target: self, action: #selector(decline))
        approveButton = NSButton(title: request.approveTitle, target: self, action: #selector(approve))
        if let stopTitle = request.stopTitle { stopButton = NSButton(title: stopTitle, target: self, action: #selector(declineAndStop)) }
        let buttons = ApprovalLayout.buttonRow(left: [stopButton].compactMap { $0 }, decline: declineButton, primary: approveButton,
                                               look: request.primaryLook)
        let what: NSView = request.command.map { ApprovalLayout.group([CommandBox($0, width: inner), detailsBox]) } ?? detailsBox
        let views: [NSView] = [ApprovalLayout.group(top), what, requesterLabel, ApprovalLayout.group([statusLabel, buttons])]

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = ApprovalLayout.groupSpacing
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            buttons.widthAnchor.constraint(equalToConstant: inner),
        ])
        for view in views { view.widthAnchor.constraint(equalToConstant: inner).isActive = true }
        detailsBox.fit()
    }

    /// Shows the window in front without taking the keyboard; bounces the Dock icon if Next Term is not
    /// the active app.
    func present() {
        guard let window else { return }
        window.layoutIfNeeded()
        window.center()
        window.orderFront(nil)
        UpdateHolds.shared.register(self) // an update lists it, waits for or declines it, until it closes
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
        let text = "Asked by \(request.requester), which has gone since. What you decide still happens."
        requesterLabel.attributedStringValue = ApprovalLayout.secondary(text, width: ApprovalLayout.inner(Self.width)).attributedStringValue
    }

    /// Holds approving (and the close button) while something runs; Decline stays, to stop it.
    func setBusy(_ busy: Bool) {
        approveButton.isEnabled = !busy
        window?.standardWindowButton(.closeButton)?.isEnabled = !busy
    }

    /// The approved action has started and can't be stopped: Decline would only tell the agent
    /// something untrue, so it is held too.
    func setCommitted(_ committed: Bool) {
        setBusy(committed)
        declineButton.isEnabled = !committed
        stopButton?.isEnabled = !committed
    }

    @objc private func approve() { onApprove(self) }

    @objc private func decline() { answer(stopAsking: false) }

    @objc private func declineAndStop() { answer(stopAsking: true) }

    private func answer(stopAsking: Bool) {
        guard !answered else { return }
        answered = true
        onDecline(stopAsking)
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
        onDecline(false)
    }
}
