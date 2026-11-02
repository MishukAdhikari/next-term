import AppKit
import NextTermCore

/// apply_setup's ask: one window for an agent's whole setup plan, a tickable row per change (AgentSetup.Row), so the
/// user approves it once instead of a window for the settings, another for the layout and the import window after them.
///
/// It is an approval window (ApprovalLayout): it opens in front without taking the keyboard, names who asks and sets the
/// agent's words apart as its own, and has one primary, Apply N Changes, whose count follows the ticks and which only a
/// click presses. Cancel takes Escape, and closing the window cancels too. With nothing ticked, Apply is disabled.
@MainActor
final class AgentSetupWindow: NSWindowController, NSWindowDelegate {
    struct Request {
        /// Who asked, as Next Term knows it.
        var requester: String
        /// The agent's own words (its reason), if it gave any.
        var agentWords: String?
        var rows: [AgentSetup.Row]
        /// The rows ticked at first.
        var ticked: Set<String>
        /// Lines under the rows: an earlier Undo that would go, a file's warning.
        var notes: [String]
    }

    private let request: Request
    private let onApply: (_ ticked: Set<String>, _ window: AgentSetupWindow) -> Void
    private let onCancel: () -> Void
    private var boxes: [(box: NSButton, row: AgentSetup.Row)] = []
    private(set) var applyButton: PrimaryButton!
    private(set) var cancelButton: NSButton!
    private var answered = false

    static let title = "An agent asks to set up Next Term"
    private static let width: CGFloat = 500

    init(_ request: Request, apply: @escaping (_ ticked: Set<String>, _ window: AgentSetupWindow) -> Void, cancel: @escaping () -> Void) {
        self.request = request
        onApply = apply
        onCancel = cancel
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300), styleMask: [.titled, .closable, .utilityWindow],
                             backing: .buffered, defer: false)
        window.title = Self.title
        window.keepsItsOwnFrame()
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

    /// Groups, 16 points apart: what is asked and the agent's words; the rows, in a box of their own that scrolls when
    /// the plan is long; the notes and who asked; then Cancel and the primary.
    private func build() {
        guard let content = window?.contentView else { return }
        let inner = ApprovalLayout.inner(Self.width)
        var top: [NSView] = [ApprovalLayout.heading(Self.title, width: inner)]
        if let raw = request.agentWords {
            let words = SecretApprovalPanel.sanitized(raw.trimmingCharacters(in: .whitespacesAndNewlines), limit: 500)
            if !words.isEmpty { top.append(ApprovalLayout.agentWords(words, who: nil, width: inner)) }
        }
        top.append(ApprovalLayout.secondary("Only the rows you tick change, and only when you click Apply. Next Term › Undo Agent Setup… puts them back.",
                                            width: inner))

        let list = UpdateListScroll(maxHeight: 300, bordered: false, spacing: 6)
        for row in request.rows {
            let box = NSButton(checkboxWithTitle: SecretApprovalPanel.sanitized(row.title, limit: 200), target: self, action: #selector(recount))
            box.state = request.ticked.contains(row.id) ? .on : .off
            box.identifier = .init(row.id)
            boxes.append((box, row))
            guard let detail = row.detail else {
                list.stack.addArrangedSubview(box)
                continue
            }
            // The line under a row lines up with its title, past the checkbox.
            let line = ApprovalLayout.secondary(detail, width: inner - 40)
            let indented = NSStackView(views: [line])
            indented.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
            list.stack.addArrangedSubview(ApprovalLayout.group([box, indented]))
        }

        var lower: [NSView] = request.notes.map { ApprovalLayout.secondary($0, width: inner) }
        lower.append(ApprovalLayout.secondary("Asked by \(request.requester).", width: inner))

        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        applyButton = PrimaryButton(title: "Apply", target: self, action: #selector(apply))
        let buttons = ApprovalLayout.buttonRow(left: [], decline: cancelButton, primary: applyButton)
        let views: [NSView] = [ApprovalLayout.group(top), list, ApprovalLayout.group(lower), buttons]

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = ApprovalLayout.groupSpacing
        stack.edgeInsets = DialogFit.insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        for view in views { view.widthAnchor.constraint(equalToConstant: inner).isActive = true }
        recount()
        list.fit()
        DialogFit.fit(window, width: Self.width)
    }

    /// The rows ticked now.
    var ticked: Set<String> { Set(boxes.filter { $0.box.state == .on }.map(\.row.id)) }

    /// The primary says what Apply changes, and is disabled with nothing ticked.
    @objc private func recount() {
        let count = AgentSetup.count(boxes.map(\.row), ticked: ticked)
        applyButton.title = AgentSetup.applyTitle(count)
        applyButton.isEnabled = count > 0
    }

    /// Shows the window in front without taking the keyboard; bounces the Dock icon if Next Term is not the active app.
    func present() {
        guard let window else { return }
        window.layoutIfNeeded()
        window.center()
        window.orderFront(nil)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    @objc private func apply() {
        guard !answered else { return }
        answered = true
        onApply(ticked, self)
    }

    @objc private func cancel() {
        guard !answered else { return }
        answered = true
        onCancel()
        close()
    }

    /// Ends the request after Apply went through.
    func finish() {
        answered = true
        close()
    }

    /// Closing the window without choosing cancels.
    func windowWillClose(_ notification: Notification) {
        guard !answered else { return }
        answered = true
        onCancel()
    }
}
