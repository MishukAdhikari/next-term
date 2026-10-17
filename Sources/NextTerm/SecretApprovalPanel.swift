import AppKit
import NextTermCore

/// Next Term's own panel before a stored key is used: who asks, which keys and what each is for, the full
/// command, the folder, the warnings, the agent's words as its own, and how long an approval lasts. After Allow comes
/// the Touch ID or Mac password sheet.
///
/// It follows `AgentApprovalWindow`'s rules: it never takes the keyboard on its own (`becomesKeyOnlyIfNeeded`), it has
/// no default button, Allow refuses first responder, and closing it declines. So a request reaches the user wherever
/// they are, it also never activates Next Term (`.nonactivatingPanel`), joins every Space and shows over a full-screen
/// window, floats while it waits, and bounces the Dock icon when Next Term is in the background.
@MainActor
final class SecretApprovalPanel: NSWindowController, NSWindowDelegate {
    /// What the panel shows. Text from programs (the agent's words, a tab title) is masked and sanitized here before it
    /// is shown; the command is masked, with what would not show as itself escaped.
    struct Content {
        struct KeyRow {
            var name: String
            var envName: String
            var purpose: String
            var purposeByAgent: Bool
            var writeOnly: Bool
            var lastUsed: String
        }

        var title: String
        var keys: [KeyRow]
        var command: String
        var runsAsShell: Bool
        var folder: String
        var warnings: [String]
        var agentWords: String?
        var askedBy: SecretRequests.AskedBy
        var argv: [String]
        var isWrapper: Bool
        var isRemote: Bool
        /// A line of its own above the warnings: store_secret's, for instance.
        var notice: String?
        var waiting: Int
        /// store_secret has no "How long", and saves instead of allowing.
        var offersHowLong = true
        var allowTitle = "Allow"
    }

    static let fifteenMinutesNote = "Only this agent, these keys, this exact command and folder. Anything different asks again."
    static let wrapperRestartNote = "Covers starting it again. A server already running keeps going."

    static let cardText = "This MCP server stopped waiting. Allow it, then restart it in your agent (in Claude Code: /mcp, then Reconnect)."
    static let stoppedDuringApprovalText = "This MCP server stopped waiting. Restart it within 2 minutes to use this approval."

    private let content: Content
    private let onAllow: (SecretRequests.How) -> Void
    private let onDecline: (_ stopAsking: Bool) -> Void
    private let onPause: () -> Void

    private(set) var allowButton: NSButton!
    private(set) var declineButton: NSButton!
    private(set) var stopButton: NSButton!
    private(set) var pauseButton: NSButton!
    /// "How long": a radio button for each choice offered.
    private(set) var durationChoice: [SecretRequests.How: NSButton] = [:]
    private(set) var detailsDisclosure: NSButton!
    /// The confirm "Pause Key Requests for 1 Hour…" shows, while it is up.
    private(set) var pauseAlert: NSAlert?
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let waitingLabel = NSTextField(labelWithString: "")
    private let cardLabel = NSTextField(wrappingLabelWithString: "")
    private let detailsBox = NSStackView()
    private var scrollHeight: NSLayoutConstraint?
    private var answered = false
    private(set) var isBusy = false
    /// Called when its window closes, however it closes.
    var onClosed: (() -> Void)?

    init(_ content: Content, onAllow: @escaping (SecretRequests.How) -> Void, onDecline: @escaping (_ stopAsking: Bool) -> Void,
         onPause: @escaping () -> Void) {
        self.content = content
        self.onAllow = onAllow
        self.onDecline = onDecline
        self.onPause = onPause
        let style: NSWindow.StyleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400), styleMask: style,
                            backing: .buffered, defer: false)
        panel.title = Self.sanitized(content.title, limit: 200)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static let width: CGFloat = 520

    // MARK: building

    private func build() {
        guard let view = window?.contentView else { return }
        let rows = NSStackView(views: rowViews())
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        rows.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 10, right: 18)
        rows.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let pinned = NSStackView(views: [howLongView(), statusLabel, buttonRow()].compactMap { $0 })
        pinned.orientation = .vertical
        pinned.alignment = .leading
        pinned.spacing = 8
        pinned.edgeInsets = NSEdgeInsets(top: 8, left: 18, bottom: 16, right: 18)
        pinned.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.isHidden = true
        statusLabel.font = .systemFont(ofSize: 12)

        view.addSubview(scroll)
        view.addSubview(pinned)
        let inner = Self.width - 36
        var constraints = [
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pinned.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            pinned.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pinned.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pinned.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: Self.width),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ]
        for row in rows.arrangedSubviews { constraints.append(row.widthAnchor.constraint(lessThanOrEqualToConstant: inner)) }
        for row in rows.arrangedSubviews where row is NSTextField || row is NSStackView {
            constraints.append(row.widthAnchor.constraint(equalToConstant: inner))
        }
        for row in pinned.arrangedSubviews { constraints.append(row.widthAnchor.constraint(equalToConstant: inner)) }
        NSLayoutConstraint.activate(constraints)
        let height = scroll.heightAnchor.constraint(equalToConstant: 200)
        height.isActive = true
        scrollHeight = height
        fitHeight(rows: rows, pinned: pinned)
    }

    /// The rows' height, up to about 70% of the screen's visible height with "How long" and the buttons below.
    private func fitHeight(rows: NSStackView, pinned: NSStackView) {
        rows.layoutSubtreeIfNeeded()
        pinned.layoutSubtreeIfNeeded()
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800
        let room = max(160, visible * 0.7 - pinned.fittingSize.height)
        scrollHeight?.constant = min(rows.fittingSize.height, room)
    }

    private func rowViews() -> [NSView] {
        var views: [NSView] = []
        let title = Self.label(Self.sanitized(content.title, limit: 200), size: 14, weight: .semibold)
        views.append(title)
        for key in content.keys { views.append(keyRow(key)) }
        views.append(contentsOf: commandRows())
        views.append(contentsOf: folderRows())
        if let notice = content.notice { views.append(Self.label(notice, size: 12, weight: .medium)) }
        for warning in content.warnings { views.append(warningRow(warning)) }
        if let words = content.agentWords.map({ Self.sanitized($0, limit: 500) }), !words.isEmpty {
            let quote = Self.label("The agent says: “\(words)”", size: 12)
            quote.font = NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
            quote.toolTip = "These are the agent's words, not Next Term's."
            quote.setAccessibilityLabel("The agent says, in its own words: \(words)")
            views.append(quote)
        }
        views.append(contentsOf: askedByRows())
        views.append(detailsRow())
        cardLabel.font = .systemFont(ofSize: 12, weight: .medium)
        cardLabel.isHidden = true
        views.append(cardLabel)
        waitingLabel.font = .systemFont(ofSize: 11)
        waitingLabel.textColor = .secondaryLabelColor
        views.append(waitingLabel)
        setWaiting(content.waiting)
        return views
    }

    private func keyRow(_ key: Content.KeyRow) -> NSView {
        let name = Self.label(key.name, size: 12, weight: .semibold)
        name.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        var parts: [NSView] = [name]
        if key.writeOnly {
            let badge = Self.label("Write-only", size: 10, weight: .medium)
            badge.textColor = .secondaryLabelColor
            badge.setAccessibilityLabel("Write-only")
            parts.append(badge)
        }
        let line = NSStackView(views: parts)
        line.spacing = 8
        var purpose = key.purpose.isEmpty ? "No note of what it's for" : Self.sanitized(key.purpose, limit: 200)
        if key.purposeByAgent { purpose += " (an agent wrote this)" }
        let about = Self.label("\(purpose). Last used: \(key.lastUsed).", size: 11)
        about.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [line, about])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func commandRows() -> [NSView] {
        guard !content.command.isEmpty else { return [] } // store_secret runs nothing
        let shown = Self.shownCommand(content.command, limit: 4000)
        let command = NSTextField(wrappingLabelWithString: shown)
        command.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        command.preferredMaxLayoutWidth = Self.width - 36
        command.isSelectable = true
        command.setAccessibilityLabel("Command: \(shown)")
        var views: [NSView] = [command]
        if content.runsAsShell {
            let shell = Self.label("Runs as a shell command", size: 11)
            shell.textColor = .secondaryLabelColor
            views.append(shell)
        }
        // Under the command: any program running as the user can read its environment while it runs.
        let readable = Self.label(SecretRun.environmentNote(keys: content.keys.count), size: 11)
        readable.textColor = .secondaryLabelColor
        views.append(readable)
        return views
    }

    private func folderRows() -> [NSView] {
        var lines = content.folder.isEmpty ? [] : ["Folder: \(Self.sanitized(content.folder, limit: 1000))"]
        for key in content.keys where key.envName != key.name { lines.append("\(key.name) → \(key.envName)") }
        guard !lines.isEmpty else { return [] }
        let label = Self.label(lines.joined(separator: "\n"), size: 12)
        return [label]
    }

    private func warningRow(_ text: String) -> NSView {
        let shown = Self.sanitized(text, limit: 400)
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning") ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.setAccessibilityElement(false)
        let label = Self.label(shown, size: 12)
        label.preferredMaxLayoutWidth = Self.width - 36 - 24
        let row = NSStackView(views: [icon, label])
        row.alignment = .firstBaseline
        row.spacing = 6
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.staticText)
        row.setAccessibilityLabel("Warning: \(shown)")
        return row
    }

    private func askedByRows() -> [NSView] {
        let facts = content.askedBy
        var lines: [String] = []
        if let agent = facts.agent { lines.append("\(Self.sanitized(agent, limit: 60)), going by its program's name") }
        if facts.checkedNxtrm { lines.append("Asked through Next Term's own nxtrm (checked)") }
        if let connection = facts.connection {
            lines.append("The remote connection “\(Self.sanitized(connection, limit: 80))”")
        } else if let tab = facts.tab {
            lines.append(tab + (facts.project.map { ", project \(Self.sanitized($0, limit: 300))" } ?? ""))
        } else {
            lines.append("A program outside Next Term's tabs")
        }
        if let title = facts.programTitle.map({ Self.sanitized($0, limit: 80) }), !title.isEmpty {
            lines.append("Tab title (set by a program): \(title)")
        }
        let heading = Self.label("Asked by", size: 12, weight: .semibold)
        let body = Self.label(lines.joined(separator: "\n"), size: 12)
        return [heading, body]
    }

    private func detailsRow() -> NSView {
        detailsDisclosure = NSButton(title: "Details", target: self, action: #selector(toggleDetails))
        detailsDisclosure.setButtonType(.pushOnPushOff)
        detailsDisclosure.bezelStyle = .disclosure
        detailsDisclosure.state = .off
        detailsDisclosure.setAccessibilityLabel("Details")
        let title = Self.label("Details", size: 12)
        let header = NSStackView(views: [detailsDisclosure, title])
        header.spacing = 4
        var lines: [String] = []
        if let pid = content.askedBy.pid { lines.append("Process: \(pid)") }
        if let executable = content.askedBy.executable { lines.append("Program: \(Self.sanitized(executable, limit: 1000))") }
        let arguments = content.askedBy.arguments.isEmpty ? content.argv : content.askedBy.arguments
        if !arguments.isEmpty {
            lines.append("\(arguments.count) \(arguments.count == 1 ? "argument" : "arguments"):")
            lines.append(contentsOf: arguments.prefix(200).map { "  " + Self.escaped(Self.masked($0)) })
            if arguments.count > 200 { lines.append("  … and \(arguments.count - 200) more") }
        }
        if content.runsAsShell { lines.append("Runs with /bin/sh -c") }
        let body = NSTextField(wrappingLabelWithString: lines.joined(separator: "\n"))
        body.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        body.preferredMaxLayoutWidth = Self.width - 36
        body.isSelectable = true
        detailsBox.orientation = .vertical
        detailsBox.alignment = .leading
        detailsBox.addArrangedSubview(body)
        detailsBox.isHidden = true
        let stack = NSStackView(views: [header, detailsBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func howLongView() -> NSView? {
        guard content.offersHowLong else { return nil }
        var views: [NSView] = []
        func radio(_ title: String, _ how: SecretRequests.How, note: String?) {
            let button = NSButton(radioButtonWithTitle: title, target: self, action: #selector(choseHowLong(_:)))
            durationChoice[how] = button
            views.append(button)
            if let note {
                let label = Self.label(note, size: 11)
                label.textColor = .secondaryLabelColor
                views.append(label)
            }
        }
        radio("Allow once", .once, note: nil)
        if !content.isRemote {
            let note = content.isWrapper ? Self.fifteenMinutesNote + " " + Self.wrapperRestartNote : Self.fifteenMinutesNote
            radio("Allow for 15 minutes", .fifteenMinutes, note: note)
            if content.isWrapper {
                let agent = content.askedBy.agent ?? "this program"
                radio("Allow this command until the Mac locks", .untilLock,
                      note: "For this exact command, started by \(agent) in this folder. Ends when you lock the Mac, it goes to sleep, "
                        + "or Next Term quits. Revoke it in Settings › Secrets.")
            }
        }
        durationChoice[.once]?.state = .on
        let heading = Self.label("How long", size: 12, weight: .semibold)
        let stack = NSStackView(views: [heading] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func buttonRow() -> NSView {
        pauseButton = NSButton(title: "Pause Key Requests for 1 Hour…", target: self, action: #selector(pause))
        stopButton = NSButton(title: "Decline and Stop Asking", target: self, action: #selector(declineAndStop))
        declineButton = NSButton(title: "Decline", target: self, action: #selector(decline))
        allowButton = NSButton(title: content.allowTitle, target: self, action: #selector(allow))
        for button in [pauseButton, stopButton, declineButton, allowButton] {
            button?.bezelStyle = .rounded
            button?.keyEquivalent = "" // no default button
        }
        // Only a click allows: never Return, nor Tab then Space with keyboard navigation on.
        allowButton.refusesFirstResponder = true
        // store_secret's panel has no "How long" and no hour pause: Decline and Stop Asking, Decline, Save.
        pauseButton.isHidden = !content.offersHowLong
        let row = NSStackView(views: [pauseButton, NSView(), stopButton, declineButton, allowButton])
        row.spacing = 8
        return row
    }

    // MARK: showing

    /// In front on the current Space without activating Next Term or taking the keyboard, floating while it waits. The
    /// Dock icon bounces when Next Term is in the background: until it is active, for a wrapper's request.
    func present(urgent: Bool) {
        guard let window else { return }
        window.level = .floating
        window.layoutIfNeeded()
        window.center()
        window.orderFrontRegardless()
        if !NSApp.isActive { NSApp.requestUserAttention(urgent ? .criticalRequest : .informationalRequest) }
    }

    var selectedHow: SecretRequests.How {
        durationChoice.first { $0.value.state == .on }?.key ?? .once
    }

    func select(_ how: SecretRequests.How) {
        for (choice, button) in durationChoice { button.state = choice == how ? .on : .off }
    }

    func setWaiting(_ count: Int) {
        waitingLabel.stringValue = count == 0 ? "" : "\(count) more \(count == 1 ? "request" : "requests") waiting"
        waitingLabel.isHidden = count == 0
    }

    /// Allow is waiting for Touch ID or the password: the panel says so, and nothing else can be pressed.
    func setBusy(_ busy: Bool) {
        isBusy = busy
        for button in [allowButton, declineButton, stopButton, pauseButton] { button?.isEnabled = !busy }
        for button in durationChoice.values { button.isEnabled = !busy }
        if !content.isRemote, cardLabel.isHidden == false { durationChoice[.once]?.isEnabled = false }
        window?.standardWindowButton(.closeButton)?.isEnabled = !busy
        setStatus(busy ? "Waiting for Touch ID or your password…" : "")
    }

    /// Touch ID or the password was cancelled or failed: back to where the user was.
    func notApproved() {
        setStatus("Not approved.")
    }

    /// Its wrapper stopped waiting: a pending card, "Allow for 15 minutes" chosen and "Allow once" off.
    func markGone() {
        cardLabel.stringValue = Self.cardText
        cardLabel.isHidden = false
        if durationChoice[.fifteenMinutes] != nil { select(.fifteenMinutes) }
        durationChoice[.once]?.isEnabled = false
        announce(Self.cardText)
    }

    /// An identical request took the card over: its wrapper waits again.
    func markBack() {
        cardLabel.isHidden = true
        durationChoice[.once]?.isEnabled = !isBusy
    }

    /// The wrapper left during Touch ID after "Allow once": a one-use approval waits 2 minutes.
    func showStoppedDuringApproval() {
        answered = true
        window?.level = .normal // nothing waits on it any more
        setBusy(false)
        for button in [allowButton, declineButton, stopButton, pauseButton] { button?.isEnabled = false }
        for button in durationChoice.values { button.isEnabled = false }
        cardLabel.stringValue = Self.stoppedDuringApprovalText
        cardLabel.isHidden = false
        setStatus("")
        announce(Self.stoppedDuringApprovalText)
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.isHidden = text.isEmpty
        if !text.isEmpty { announce(text) }
    }

    private func announce(_ text: String) {
        guard let window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Ends the panel after its request was answered.
    func finish() {
        answered = true
        window?.level = .normal
        close()
    }

    // MARK: actions

    @objc private func choseHowLong(_ sender: NSButton) {
        for button in durationChoice.values where button !== sender { button.state = .off }
        sender.state = .on
    }

    @objc private func toggleDetails() {
        detailsBox.isHidden = detailsDisclosure.state != .on
    }

    @objc private func allow() {
        guard !answered, !isBusy else { return }
        onAllow(selectedHow)
    }

    @objc private func decline() { answer(stopAsking: false) }

    @objc private func declineAndStop() { answer(stopAsking: true) }

    private func answer(stopAsking: Bool) {
        guard !answered, !isBusy else { return }
        answered = true
        onDecline(stopAsking)
        close()
    }

    @objc private func pause() {
        guard !answered, !isBusy, let window else { return }
        let alert = Self.makePauseAlert()
        pauseAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pauseAlert = nil
                guard response == .alertFirstButtonReturn, !self.answered else { return }
                self.answered = true
                self.onPause()
                self.close()
            }
        }
    }

    /// Pause's confirm. From the panel it names "this" request. From Secrets › Pause Key Requests for 1 Hour…
    /// (`fromMenu`) there may be no request on screen, and it is a sheet on the Secrets window whose default button,
    /// Return, is Cancel.
    static func makePauseAlert(fromMenu: Bool = false) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Pause key requests for an hour?"
        guard fromMenu else {
            alert.informativeText = "This declines this and every waiting request, refuses new ones for an hour, and ends every approval you gave. "
                + "MCP servers that need keys won't start."
            alert.addButton(withTitle: "Pause for 1 Hour")
            alert.addButton(withTitle: "Cancel")
            return alert
        }
        alert.informativeText = menuPauseText
        alert.addButton(withTitle: "Pause for 1 Hour").keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r" // Return cancels
        return alert
    }

    /// The menu's Pause confirm: the panel's, with no "this".
    static let menuPauseText = "This declines every waiting request, refuses new ones for an hour, and ends every approval "
        + "you gave. MCP servers that need keys won\u{2019}t start."

    /// Closing the panel without choosing is a decline.
    func windowWillClose(_ notification: Notification) {
        let closed = onClosed
        onClosed = nil
        closed?()
        guard !answered else { return }
        answered = true
        onDecline(false)
    }

    // MARK: text

    /// The panel's title: who asks to run or start which program with which keys.
    static func title(_ request: SecretRequests.Request) -> String {
        if let title = request.titleOverride { return title }
        let keys = SecretReason.keys(request.names)
        let verb = request.isWrapper ? "start" : "run"
        let tail = "asks to \(verb) \(request.program) with \(keys)"
        let facts = request.askedBy
        if let connection = facts.connection { return "The remote connection “\(connection)” \(tail)" }
        if let agent = facts.agent { return "\(agent) \(tail)" }
        if let tab = facts.tab { return "A command in \(tab) \(tail)" }
        return "A program outside Next Term's tabs \(tail)"
    }

    /// "5 min ago by Claude Code", from a `use` line.
    static func lastUsedText(_ line: SecretAudit.Line) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let when = formatter.localizedString(for: line.time, relativeTo: Date())
        guard let who = line.who?.components(separatedBy: " (").first, !who.isEmpty else { return when }
        return "\(when) by \(who)"
    }

    static func masked(_ text: String) -> String { SecretMask.current.mask(text) }

    /// Text from a program, as the panel shows it: stored keys masked, control, bidi and zero-width characters taken
    /// out, line breaks made spaces, and cut at `limit` characters.
    static func sanitized(_ text: String, limit: Int) -> String {
        let scalars = masked(text).unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if scalar == "\n" || scalar == "\r" || scalar == "\t" { return " " }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned: return nil
            default: return scalar
            }
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        let clean = String(view)
        return clean.count > limit ? String(clean.prefix(limit - 1)) + "…" : clean
    }

    /// The command as the panel shows it: stored keys masked, and each character that would not show as itself (a
    /// control or format character, a separator, an unassigned one) written as an escape, never taken out or made a
    /// space. So the text shown is the text that runs.
    static func shownCommand(_ text: String, limit: Int) -> String {
        var out = String.UnicodeScalarView()
        for scalar in masked(text).unicodeScalars {
            switch scalar {
            case "\n": out.append(contentsOf: "\\n".unicodeScalars)
            case "\r": out.append(contentsOf: "\\r".unicodeScalars)
            case "\t": out.append(contentsOf: "\\t".unicodeScalars)
            default:
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
                    out.append(contentsOf: ("\\u{" + String(scalar.value, radix: 16) + "}").unicodeScalars)
                default:
                    out.append(scalar)
                }
            }
        }
        let shown = String(out)
        return shown.count > limit ? String(shown.prefix(limit - 1)) + "…" : shown
    }

    /// An argument as Details shows it: as it is, or quoted with its spaces, quotes and control characters escaped.
    static func escaped(_ token: String) -> String {
        if !token.isEmpty, token.unicodeScalars.allSatisfy(isPlain) { return token }
        var out = "\""
        for scalar in token.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                let category = scalar.properties.generalCategory
                if scalar.value < 0x20 || scalar.value == 0x7F || category == .format || category == .control {
                    out += "\\u{" + String(scalar.value, radix: 16) + "}"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Not a space, a quote, a backslash, a control or a format character.
    static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value <= 0x20 || scalar.value == 0x7F { return false }
        if scalar == "\"" || scalar == "'" || scalar == "\\" { return false }
        let category = scalar.properties.generalCategory
        return category != .format && category != .control
    }

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.preferredMaxLayoutWidth = width - 36
        return label
    }
}

/// A document view whose rows start at the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
