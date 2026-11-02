import AppKit
import NextTermCore

/// Tells the user, once, that Next Term added its tools to their agents (MCPRegistrationNotice): as a card at the top of
/// the Welcome window when that is up, or else as a notice at the bottom of the project window in front, whose Details…
/// shows the same words and files. Keep leaves things as they are; Remove does what turning off Settings › Editor › “Let
/// agents control Next Term” does. A notice due while no window is up waits for the first one to become key.
@MainActor
enum MCPRegistrationAnnouncer {
    private static var pending: MCPRegistrationNotice?
    private static var watch: NSObjectProtocol?

    /// After a whole pass with the setting on: its statuses.
    static func passDone(_ statuses: [String: MCPRegistrar.Status]) {
        guard let notice = MCPRegistrationNotice.due(statuses, shown: MCPRegistrationNotice.shown(in: .standard)) else { return }
        pending = notice
        if present() { return }
        guard watch == nil else { return }
        watch = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard present(), let watch else { return }
                NotificationCenter.default.removeObserver(watch)
                Self.watch = nil
            }
        }
    }

    /// Shows the pending notice where it can be seen; false: no window for it yet.
    private static func present() -> Bool {
        guard let notice = pending else { return true }
        let app = AppDelegate.shared
        if let welcome = app?.welcomeController, welcome.window?.isVisible == true {
            welcome.showRegistrationNotice(notice)
        } else if let window = projectWindow {
            GitToast.whenFree {
                GitToast.show(notice.headline, in: window, button: "Keep", action: {}, other: "Details…",
                              otherAction: { [weak window] in details(notice, over: window) })
            }
        } else {
            return false
        }
        notice.remember(in: .standard)
        pending = nil
        return true
    }

    /// The project window in front, or the last one used.
    private static var projectWindow: NSWindow? {
        if let key = NSApp.keyWindow?.windowController as? TerminalWindowController { return key.window }
        return AppDelegate.shared?.controllers.last(where: { $0.window?.isVisible == true })?.window
    }

    /// The notice's words and each agent's file, over `window`, with Keep and Remove.
    private static func details(_ notice: MCPRegistrationNotice, over window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = notice.headline
        alert.informativeText = notice.meaning + "\n\n" + notice.fileLines.joined(separator: "\n")
        let keep = alert.addButton(withTitle: "Keep")
        ApprovalLayout.style(keep, look: .accent)
        alert.addButton(withTitle: "Remove")
        let done: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn { remove(notice, from: window) }
        }
        if let window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }

    /// Remove: agent control off, which takes Next Term out of every agent it was added to, then says so.
    static func remove(_ notice: MCPRegistrationNotice, from window: NSWindow?) {
        AppDelegate.shared.agentControl = false
        GitToast.show("Removed from " + notice.agentList
                      + ". Settings › Editor › “Let agents control Next Term” adds it back.", in: window)
    }
}

/// The Welcome window's card for MCPRegistrationNotice: the sentence, Details (each agent's file), and Remove beside the
/// primary, Keep. Keep takes no key, so Return stays the Welcome list's.
@MainActor
final class MCPRegistrationCard: NSView {
    private let message = NSTextField(wrappingLabelWithString: "")
    private let files = NSTextField(wrappingLabelWithString: "")
    private var details: DisclosureRow!
    private var notice: MCPRegistrationNotice?
    /// Called once Keep or Remove is pressed, for the window to take the card away.
    var onDone: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.tabHover.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = WorkSplitView.line.cgColor
        message.font = .systemFont(ofSize: 12.5)
        message.textColor = Theme.text
        files.font = .systemFont(ofSize: 11)
        files.textColor = Theme.textDim
        files.isSelectable = true
        details = DisclosureRow(title: "Details", content: files)
        let remove = NSButton(title: "Remove", target: self, action: #selector(removePressed))
        let keep = PrimaryButton(title: "Keep", target: self, action: #selector(keepPressed))
        for button in [remove, keep] as [NSButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.keyEquivalent = ""
        }
        keep.refusesFirstResponder = true
        keep.heightAnchor.constraint(equalTo: remove.heightAnchor).isActive = true
        let buttons = NSStackView(views: [remove, keep])
        buttons.spacing = 8
        let bottom = NSStackView(views: [details, NSView(), buttons])
        bottom.alignment = .top
        let stack = NSStackView(views: [message, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -26),
            message.widthAnchor.constraint(equalTo: bottom.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The sentence and the files wrap at the card's width, and the card stands as tall as they then are.
    override func layout() {
        super.layout()
        for label in [message, files] where label.frame.width > 0 && label.preferredMaxLayoutWidth != label.frame.width {
            label.preferredMaxLayoutWidth = label.frame.width
        }
    }

    func show(_ notice: MCPRegistrationNotice) {
        self.notice = notice
        message.stringValue = notice.message
        files.stringValue = notice.fileLines.joined(separator: "\n")
        setAccessibilityLabel(notice.headline)
    }

    /// The card's sentence, for the self-test.
    var text: String { message.stringValue }

    @objc private func keepPressed() { onDone?() }

    @objc private func removePressed() {
        let window = self.window
        onDone?()
        if let notice { MCPRegistrationAnnouncer.remove(notice, from: window) }
    }
}
