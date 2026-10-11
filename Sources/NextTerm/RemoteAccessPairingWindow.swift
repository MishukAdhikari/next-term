import AppKit
import LocalAuthentication
import NextTermCore

/// Connect a Client (U8): the window where the user lets a new Remote access connection in, on the Mac.
///
/// Opening it opens pairing for 10 minutes (R11), with the code field and a countdown. The browser that adds the
/// connector shows a 6-digit code; the user types it here. A code that matches a waiting request shows that request:
/// where it goes back to (claude.ai or chatgpt.com) in large type, the name the app gave itself (its own words, not
/// Next Term's), a name for the connection, the options view with Read only picked, and when the connection ends.
/// Allow then asks for Touch ID or the Mac password, and only then does the connection exist (R12).
///
/// It follows AgentApprovalWindow's rules, not its code (KTD8): its own panel, and no default button, so no Return
/// meant for something else allows anything. Requests arriving never alert the Mac: no Dock bounce, no notification,
/// nothing in this window until their code is typed, so a stranger's request stays unseen (R14). Allow is enabled only
/// for a matching code, a second after its request shows. Closing the window before a code matched ends pairing and
/// declines nothing, and waiting browsers get the closed page; after a match, Decline or closing declines that request.
/// Five wrong codes close pairing, and so does a new public hostname. Connect a Client again then opens a new window.
@MainActor
final class RemoteAccessPairingWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    /// The window while it is open: one at a time.
    private(set) static var current: RemoteAccessPairingWindow?

    /// Allow waits this long after a request shows, so a click meant for something else can't land on it.
    static let allowDelay: TimeInterval = 1
    static let width: CGFloat = 520

    /// Opens pairing for 10 minutes and shows the window at once, ready for the code. A window already open comes
    /// to the front, its pairing as it was; one whose pairing ended closes, and a new one opens with pairing open
    /// again. Nil while no public hostname is saved: no browser can pair then.
    @discardableResult
    static func open(state: RemoteAccessDoorState) -> RemoteAccessPairingWindow? {
        if let current, current.state === state, !current.closedPairing {
            current.window?.makeKeyAndOrderFront(nil)
            return current
        }
        current?.close()
        guard let host = state.host, let ends = state.update({ authority, now -> Date in
            authority.openPairing(now: now)
            return authority.pairingEnds ?? now
        }) else { return nil }
        let controller = RemoteAccessPairingWindow(state: state, host: host, ends: ends)
        current = controller
        controller.present()
        return controller
    }

    /// Remote access turned off: the window closes, as closing it by hand does.
    static func close(for state: RemoteAccessDoorState? = nil) {
        guard let current, state == nil || current.state === state else { return }
        current.close()
    }

    let state: RemoteAccessDoorState
    /// The public hostname the window shows. A new one closes pairing (R17).
    let host: String
    /// When pairing closes by itself.
    let ends: Date
    /// The request whose code was typed.
    private(set) var matched: RemoteAccessOAuth.PairingRequest?
    /// The connection Allow made.
    private(set) var approved: RemoteAccessOAuth.Grant?

    let codeField = NSTextField()
    let countdownLabel = NSTextField(labelWithString: "")
    let hostLabel = NSTextField(labelWithString: "")
    let clientWordsLabel = NSTextField(wrappingLabelWithString: "")
    let nameField = NSTextField()
    let optionsView = RemoteAccessOptionsView(options: RemoteAccessPreset.preselected.options, showsList: false)
    let expiryLabel = NSTextField(wrappingLabelWithString: "")
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var declineButton: NSButton!
    private(set) var allowButton: NSButton!

    private let stack = NSStackView()
    private let requestSection = NSStackView()
    private var timer: Timer?
    private var allowTimer: Timer?
    private var answered = false
    /// Touch ID or the password is being asked; cancelling it takes the system's dialog away.
    private var confirming: RemoteAccessConfirmation.Asking?
    private var closedPairing = false

    private init(state: RemoteAccessDoorState, host: String, ends: Date) {
        self.state = state
        self.host = host
        self.ends = ends
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 240),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Connect a Client"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = false
        super.init(window: panel)
        panel.delegate = self
        build(host: host)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: building

    private func build(host: String) {
        guard let content = window?.contentView else { return }
        let title = NSTextField(wrappingLabelWithString: "Type the code from the browser")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let steps = NSTextField(wrappingLabelWithString: "In claude.ai or chatgpt.com, add the connector "
            + "https://\(host)/mcp. Its sign-in page shows a code. Type it here.")
        steps.font = .systemFont(ofSize: 12)
        steps.textColor = .secondaryLabelColor
        steps.isSelectable = true

        codeField.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
        codeField.placeholderString = "000000"
        codeField.alignment = .center
        codeField.delegate = self
        codeField.setAccessibilityLabel("Code from the browser")
        codeField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countdownLabel.textColor = .secondaryLabelColor
        let codeLabel = NSTextField(labelWithString: "Code")
        let codeRow = NSStackView(views: [codeLabel, codeField, countdownLabel])
        codeRow.spacing = 10

        buildRequestSection()
        requestSection.isHidden = true

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.isHidden = true

        declineButton = NSButton(title: "Cancel", target: self, action: #selector(decline))
        allowButton = NSButton(title: "Allow", target: self, action: #selector(allow))
        for button in [declineButton!, allowButton!] {
            button.bezelStyle = .rounded
            button.keyEquivalent = "" // no default button: see the type's comment
        }
        // Only a click allows: never Return, nor Tab then Space with keyboard navigation on.
        allowButton.refusesFirstResponder = true
        allowButton.isEnabled = false
        let buttons = NSStackView(views: [NSView(), declineButton, allowButton])
        buttons.spacing = 8

        let views: [NSView] = [title, steps, codeRow, requestSection, statusLabel, buttons]
        for view in views { stack.addArrangedSubview(view) }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: codeRow)
        stack.setCustomSpacing(14, after: requestSection)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let inner = Self.width - 36
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            buttons.widthAnchor.constraint(equalToConstant: inner),
        ])
        for label in [title, steps, statusLabel] {
            label.preferredMaxLayoutWidth = inner
            label.widthAnchor.constraint(equalToConstant: inner).isActive = true
        }
    }

    /// What shows once a code matched: the request, the name, the options and when the connection ends.
    private func buildRequestSection() {
        let inner = Self.width - 36
        let goesTo = NSTextField(labelWithString: "Goes back to")
        goesTo.font = .systemFont(ofSize: 11)
        goesTo.textColor = .secondaryLabelColor
        hostLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        let words = NSFont.systemFont(ofSize: 12)
        clientWordsLabel.font = NSFontManager.shared.convert(words, toHaveTrait: .italicFontMask)
        clientWordsLabel.toolTip = "These are the app's own words, not Next Term's."
        clientWordsLabel.preferredMaxLayoutWidth = inner

        nameField.font = .systemFont(ofSize: 13)
        nameField.setAccessibilityLabel("Name of this connection")
        nameField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let nameLabel = NSTextField(labelWithString: "Name")
        let nameRow = NSStackView(views: [nameLabel, nameField])
        nameRow.spacing = 10

        let allows = NSTextField(labelWithString: "What it may do")
        allows.font = .systemFont(ofSize: 11)
        allows.textColor = .secondaryLabelColor
        optionsView.onChange = { [weak self] _ in self?.optionsChanged() }

        expiryLabel.font = .systemFont(ofSize: 11)
        expiryLabel.textColor = .secondaryLabelColor
        expiryLabel.preferredMaxLayoutWidth = inner

        let views: [NSView] = [goesTo, hostLabel, clientWordsLabel, nameRow, allows, optionsView, expiryLabel]
        for view in views { requestSection.addArrangedSubview(view) }
        requestSection.orientation = .vertical
        requestSection.alignment = .leading
        requestSection.spacing = 8
        requestSection.setCustomSpacing(2, after: goesTo)
        requestSection.setCustomSpacing(12, after: nameRow)
        requestSection.setCustomSpacing(4, after: allows)
        for label in [clientWordsLabel, expiryLabel] {
            label.widthAnchor.constraint(equalToConstant: inner).isActive = true
        }
    }

    // MARK: showing

    private func present() {
        guard let window else { return }
        updateCountdown()
        fit()
        window.center()
        // The user clicked Connect a Client, so the window takes the keyboard for the code. It never bounces the Dock.
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(codeField)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The window's height follows what shows; its top edge stays where it is, unless the window would then reach
    /// below the screen's bottom: it moves up then, as far as the top of the screen, so Allow stays in sight.
    private func fit() {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var placed = window.frame
        placed.origin.y = placed.maxY - frame.height
        placed.size = frame.size
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            placed.origin.y = max(placed.origin.y, visible.minY)
            placed.origin.y = min(placed.origin.y, visible.maxY - placed.height)
        }
        window.setFrame(placed, display: true)
    }

    private func setStatus(_ text: String, problem: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = problem ? .systemRed : .secondaryLabelColor
        statusLabel.isHidden = text.isEmpty
        fit()
    }

    // MARK: the countdown

    private func tick() {
        updateCountdown()
        guard !closedPairing else { return }
        if state.host != host {
            pairingEnded(Self.hostChanged)
        } else if state.now >= ends {
            pairingEnded(Self.timedOut)
        }
    }

    private func updateCountdown() {
        guard !closedPairing else { return }
        let left = max(0, Int(ends.timeIntervalSince(state.now).rounded(.up)))
        countdownLabel.stringValue = String(format: "Pairing closes in %d:%02d", left / 60, left % 60)
    }

    /// Pairing is over (time ran out, five wrong codes, or the request went): nothing here can allow any more.
    private func pairingEnded(_ text: String) {
        closedPairing = true
        cancelConfirming()
        timer?.invalidate()
        timer = nil
        allowTimer?.invalidate()
        allowTimer = nil
        countdownLabel.stringValue = "Pairing closed"
        codeField.isEnabled = false
        allowButton.isEnabled = false
        declineButton.title = "Close"
        setStatus(text, problem: true)
    }

    // MARK: the code

    /// Only digits, at most six; at six, the code is checked.
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === codeField else { return }
        let digits = String(codeField.stringValue.filter(\.isASCII).filter(\.isNumber).prefix(6))
        if digits != codeField.stringValue { codeField.stringValue = digits }
        guard digits.count == 6, matched == nil, !closedPairing else { return }
        check(digits)
    }

    /// Checks a code as typing six digits does.
    func check(_ code: String) {
        guard matched == nil, !closedPairing else { return }
        guard let match = state.update({ authority, now in authority.match(code: code, now: now) }) else {
            return pairingEnded("Remote access has no public hostname now, so no browser can pair.")
        }
        switch match {
        case .request(let request):
            show(request)
        case .noMatch:
            setStatus("No browser is waiting with that code. Check the code on its page and type it again.", problem: true)
            codeField.currentEditor()?.selectAll(nil)
        case .closed:
            if state.host != host {
                pairingEnded(Self.hostChanged)
            } else {
                pairingEnded(state.now >= ends ? Self.timedOut : Self.wrongCodes)
            }
        }
    }

    /// A code matched: the request, with Read only picked and Allow enabled a second later.
    private func show(_ request: RemoteAccessOAuth.PairingRequest) {
        matched = request
        codeField.isEditable = false
        codeField.isSelectable = false
        hostLabel.stringValue = request.redirectHost
        if let words = request.clientName, !words.isEmpty {
            clientWordsLabel.stringValue = "It calls itself “\(words)”."
            clientWordsLabel.isHidden = false
        } else {
            clientWordsLabel.isHidden = true
        }
        nameField.stringValue = request.suggestedName
        expiryLabel.stringValue = Self.expiry(from: state.now)
        declineButton.title = "Decline"
        requestSection.isHidden = false
        setStatus("")
        window?.makeFirstResponder(nameField)
        let allowTimer = Timer(timeInterval: Self.allowDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.enableAllow() }
        }
        RunLoop.main.add(allowTimer, forMode: .common)
        self.allowTimer = allowTimer
    }

    private func enableAllow() {
        allowTimer = nil
        guard matched != nil, !closedPairing, !answered, confirming == nil else { return }
        allowButton.isEnabled = true
    }

    private func optionsChanged() {
        fit()
    }

    // MARK: answers

    /// Allow: Touch ID or the Mac password, then the connection exists with the name and the options shown.
    @objc private func allow() {
        guard let request = matched, allowButton.isEnabled, !answered, confirming == nil, !closedPairing else { return }
        let options = optionsView.options
        let name = Self.name(nameField.stringValue, request: request)
        allowButton.isEnabled = false
        setStatus("Confirm on this Mac…")
        confirming = RemoteAccessConfirmation.ask(Self.reason(name: name, options: options)) { [weak self] confirmed in
            guard let self else { return }
            self.confirming = nil
            guard !self.answered, !self.closedPairing else { return }
            guard confirmed else {
                self.allowButton.isEnabled = true
                return self.setStatus("Not confirmed, so nothing changed. Click Allow to try again.", problem: true)
            }
            // What the user confirmed must still be what shows.
            guard self.optionsView.options == options, Self.name(self.nameField.stringValue, request: request) == name else {
                self.allowButton.isEnabled = true
                return self.setStatus("The options changed while you confirmed. Click Allow again.", problem: true)
            }
            self.approve(request, name: name, options: options)
        }
    }

    /// The grant is saved before the browser can get its code: a save that fails allows nothing, and the request
    /// still waits for Allow.
    private func approve(_ request: RemoteAccessOAuth.PairingRequest, name: String, options: RemoteAccessOptions) {
        let result: RemoteAccessDoorState.Approval?
        do {
            result = try state.approve(request.id, name: name, options: options)
        } catch {
            allowButton.isEnabled = true
            return setStatus("Next Term could not save this connection, so nothing changed. Click Allow to try again.",
                             problem: true)
        }
        switch result {
        case .success(let grant):
            approved = grant
            answered = true
            close()
        case .failure(.pairingClosed), nil:
            pairingEnded(state.host == host ? Self.closedFirst : Self.hostChanged)
        case .failure(.noRequest):
            pairingEnded("That browser stopped waiting. Add the connector again, then click Connect a Client.")
        }
    }

    /// Decline after a match; Cancel or Close before one. Either way the window closes.
    @objc private func decline() {
        close()
    }

    /// Closing is a decline once a code matched, and ends pairing either way.
    func windowWillClose(_ notification: Notification) {
        cancelConfirming()
        timer?.invalidate()
        timer = nil
        allowTimer?.invalidate()
        allowTimer = nil
        if !answered {
            answered = true
            let request = matched
            _ = state.update { authority, now in
                if let request { authority.decline(request.id, now: now) }
                authority.closePairing(now: now)
            }
        }
        if Self.current === self { Self.current = nil }
    }

    /// Takes the Touch ID or password dialog away when nothing here can be allowed any more. Its answer then
    /// changes nothing.
    private func cancelConfirming() {
        confirming?.cancel()
        confirming = nil
    }

    // MARK: words

    /// The name the grant will keep, as Touch ID's reason names it: the name typed without hidden characters, cut
    /// as the grant cuts it, or the suggested one when nothing is left.
    static func name(_ typed: String, request: RemoteAccessOAuth.PairingRequest) -> String {
        RemoteAccessOAuth.grantName(typed, suggested: request.suggestedName)
    }

    static let timedOut = "Pairing closed after 10 minutes. Click Connect a Client to start again."
    static let wrongCodes = "Pairing closed after five wrong codes. Click Connect a Client to start again."
    static let closedFirst = "Pairing closed before you allowed it. Click Connect a Client to start again."
    static let hostChanged = "Pairing closed because the public hostname changed. "
        + "Click Connect a Client to start again."

    /// Touch ID's reason, which macOS shows as "Next Term is trying to …": it names what the preset allows.
    static func reason(name: String, options: RemoteAccessOptions) -> String {
        switch options.preset {
        case .readOnly: return "allow “\(name)” to read your tabs and files in Next Term"
        case .control: return "allow “\(name)” to control Next Term"
        case .custom: return "allow “\(name)” to use Next Term with the options you picked"
        }
    }

    /// When the connection ends (R17), and where to end it sooner.
    static func expiry(from now: Date) -> String {
        let idle = Int(RemoteAccessOAuth.grantIdleLimit / 86_400)
        let last = now.addingTimeInterval(RemoteAccessOAuth.grantLifetime)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "It ends after \(idle) days without use, and on \(formatter.string(from: last)) at the latest. "
            + "Revoke it any time in Settings › Remote Access."
    }
}

/// Touch ID or the Mac password before a Remote access connection gets its options: at pairing (U8), and at Edit…
/// in Settings (U11). The self-test answers with a stand-in instead, only in a debug build under `--self-test`
/// (KTD18), so a release build always asks the real way.
@MainActor
enum RemoteAccessConfirmation {
    #if DEBUG
    /// The self-test's stand-in for Touch ID: it gets the reason and answers at once. Read only under `--self-test`.
    static var standIn: ((String) -> Bool)?
    /// The reason the last confirmation asked with, for the self-test.
    private(set) static var lastReason: String?
    #endif

    /// One question being asked. `cancel` takes the system's dialog away, and `done` then gets false.
    final class Asking {
        fileprivate var context: LAContext?

        fileprivate init(_ context: LAContext?) {
            self.context = context
        }

        func cancel() {
            context?.invalidate()
            context = nil
        }
    }

    /// Asks, and tells `done` on the main thread whether the user confirmed. A Mac that can't ask counts as no.
    static func ask(_ reason: String, done: @escaping @MainActor (Bool) -> Void) -> Asking {
        #if DEBUG
        if SelfTest.isRequested, let standIn {
            lastReason = reason
            let answer = standIn(reason)
            DispatchQueue.main.async { done(answer) }
            return Asking(nil)
        }
        #endif
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            DispatchQueue.main.async { done(false) }
            return Asking(nil)
        }
        // Kept until it answers, so the system's dialog has its context the whole time.
        let key = ObjectIdentifier(context)
        asking[key] = context
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async {
                asking[key] = nil
                done(success)
            }
        }
        return Asking(context)
    }

    /// The contexts whose dialogs are open.
    private static var asking: [ObjectIdentifier: LAContext] = [:]
}
