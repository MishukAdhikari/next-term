import AppKit
import NextTermCore

/// Next Term's own panel before a stored key is used: who asks, which keys and what each is for, the full
/// command, the folder, the warnings, the agent's words as its own, and how long an approval lasts. After Allow comes
/// the Touch ID or Mac password sheet.
///
/// It follows `AgentApprovalWindow`'s rules: it never takes the keyboard on its own (`becomesKeyOnlyIfNeeded`), it has
/// no default button (Allow is the primary, rightmost and tinted, pressed by a click only; Escape declines), Allow
/// refuses first responder, and closing it declines. So a request reaches the user wherever
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
        /// "How long"'s choices, in order (`SecretApprovalChoices.offered`).
        var choices: [SecretRequests.How] = [.once, .fifteenMinutes]
        /// The keys set to ask for Touch ID every time they're used, which leave only Allow once: said under it.
        var askingEveryUse: [String] = []
    }

    static let fifteenMinutesNote = "Only this agent, these keys, this exact command and folder. Anything different asks again."
    static let wrapperRestartNote = "Covers starting it again. A server already running keeps going."

    static let cardText = "This MCP server stopped waiting. Allow it, then restart it in your agent (in Claude Code: /mcp, then Reconnect)."
    static let stoppedDuringApprovalText = "This MCP server stopped waiting. Restart it within 2 minutes to use this approval."

    private let content: Content
    private let onAllow: (SecretRequests.How) -> Void
    private let onDecline: (_ stopAsking: Bool) -> Void
    private let onPause: () -> Void

    private(set) var allowButton: PrimaryButton!
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
        panel.titleVisibility = .hidden // the heading says it once; the title stays for VoiceOver and the Window menu
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
        rows.spacing = ApprovalLayout.groupSpacing
        rows.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 10, right: 20)
        rows.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        cardLabel.font = .systemFont(ofSize: 12)
        cardLabel.textColor = .labelColor
        cardLabel.isHidden = true
        statusLabel.isHidden = true
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        let pinned = NSStackView(views: [howLongView(), cardLabel, waitingRow(), statusLabel, buttonRow()].compactMap { $0 })
        pinned.orientation = .vertical
        pinned.alignment = .leading
        pinned.spacing = 8
        pinned.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 20, right: 20)
        pinned.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scroll)
        view.addSubview(pinned)
        let inner = ApprovalLayout.inner(Self.width)
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
        for row in rows.arrangedSubviews { constraints.append(row.widthAnchor.constraint(equalToConstant: inner)) }
        for row in pinned.arrangedSubviews { constraints.append(row.widthAnchor.constraint(equalToConstant: inner)) }
        NSLayoutConstraint.activate(constraints)
        let height = scroll.heightAnchor.constraint(equalToConstant: 200)
        height.isActive = true
        scrollHeight = height
        rowsStack = rows
        pinnedStack = pinned
        fitHeight()
    }

    private var rowsStack: NSStackView?
    private var pinnedStack: NSStackView?

    /// The rows' height, up to about 70% of the screen's visible height with "How long" and the buttons below; again
    /// whenever what shows changes (Details, the card, the waiting line), so nothing lands below the fold unseen.
    private func fitHeight() {
        guard let rows = rowsStack, let pinned = pinnedStack else { return }
        rows.layoutSubtreeIfNeeded()
        pinned.layoutSubtreeIfNeeded()
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800
        let room = max(160, visible * 0.7 - pinned.fittingSize.height)
        scrollHeight?.constant = min(rows.fittingSize.height, room)
    }

    /// Groups, 16 points apart: what is asked and the agent's words; the command and folder; the notice and warnings; the
    /// keys; who asked; Details. The window's title bar stays empty: the heading says it once.
    private func rowViews() -> [NSView] {
        let inner = ApprovalLayout.inner(Self.width)
        var groups: [NSView] = []
        var top: [NSView] = [ApprovalLayout.heading(Self.sanitized(content.title, limit: 200), width: inner)]
        if let words = content.agentWords.map({ Self.sanitized($0, limit: 500) }), !words.isEmpty {
            top.append(ApprovalLayout.agentWords(words, who: content.askedBy.agent.map { Self.sanitized($0, limit: 60) }, width: inner))
        }
        groups.append(ApprovalLayout.group(top))
        let what: [NSView] = commandRows() + folderRows()
        if !what.isEmpty { groups.append(ApprovalLayout.group(what)) }
        var warnings: [NSView] = []
        if let notice = content.notice { warnings.append(ApprovalLayout.body(notice, width: inner)) }
        for warning in content.warnings { warnings.append(warningRow(warning)) }
        if !warnings.isEmpty { groups.append(ApprovalLayout.group(warnings)) }
        groups.append(ApprovalLayout.group(content.keys.map(keyRow)))
        groups.append(askedByRow())
        groups.append(detailsRow())
        return groups
    }

    /// A key: its name, then what it's for (a note an agent wrote says so) and when it was last used.
    private func keyRow(_ key: Content.KeyRow) -> NSView {
        let inner = ApprovalLayout.inner(Self.width)
        let name = NSTextField(labelWithString: key.name)
        name.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        var purpose: String = key.purpose.isEmpty ? "No note of what it\u{2019}s for" : Self.sanitized(key.purpose, limit: 200)
        if key.purposeByAgent { purpose = "Note by an agent: " + purpose }
        let used: String = key.lastUsed == SecretRequests.neverUsed ? "Never used" : "Last used \(key.lastUsed)"
        var lines: [NSView] = [name, ApprovalLayout.secondary("\(purpose). \(used).", width: inner)]
        if key.writeOnly { lines.append(ApprovalLayout.secondary(SecretNewKeyDefaults.neverShownHelp, width: inner)) }
        let stack = ApprovalLayout.group(lines)
        stack.spacing = 2
        return stack
    }

    /// The command as it runs, in a box that wraps only between words or path parts.
    private func commandRows() -> [NSView] {
        guard !content.command.isEmpty else { return [] } // store_secret runs nothing
        let shown = Self.shownCommand(content.command, limit: 4000)
        let box = CommandBox(shown, width: ApprovalLayout.inner(Self.width))
        commandBox = box
        return [box]
    }

    private(set) var commandBox: CommandBox?

    /// The folder, and each key that goes in under another name, in the command's own type under it.
    private func folderRows() -> [NSView] {
        var lines = content.folder.isEmpty ? [] : ["in " + Self.sanitized(content.folder, limit: 1000)]
        for key in content.keys where key.envName != key.name { lines.append("\(key.name) as \(key.envName)") }
        guard !lines.isEmpty else { return [] }
        let label = NSTextField(wrappingLabelWithString: lines.joined(separator: "\n"))
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = ApprovalLayout.inner(Self.width)
        label.setAccessibilityLabel("Folder and names: " + lines.joined(separator: ", "))
        return [label]
    }

    private func warningRow(_ text: String) -> NSView {
        let shown = Self.sanitized(text, limit: 400)
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning") ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.setAccessibilityElement(false)
        let label = ApprovalLayout.body(shown, width: ApprovalLayout.inner(Self.width) - 24)
        label.setAccessibilityElement(false) // the row speaks for it, once
        let row = NSStackView(views: [icon, label])
        row.alignment = .firstBaseline
        row.spacing = 6
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.staticText)
        row.setAccessibilityLabel("Warning: \(shown)")
        return row
    }

    /// Who asked, in one line: "Asked by Codex (going by its program’s name), tab 2 in ~/Code/app". The rest (the
    /// checked nxtrm, a title a program set) is in Details.
    private func askedByRow() -> NSView {
        let facts = content.askedBy
        var who: String = facts.agent.map { "\(Self.sanitized($0, limit: 60)) (going by its program\u{2019}s name)" } ?? "a program"
        if let connection = facts.connection {
            who = "the remote connection \u{201C}\(Self.sanitized(connection, limit: 80))\u{201D}"
        } else if let tab = facts.tab {
            who += ", " + tab + (facts.project.map { " in " + RecentProjects.abbreviate(Self.sanitized($0, limit: 300), home: NSHomeDirectory()) } ?? "")
        } else {
            who += " outside Next Term\u{2019}s tabs"
        }
        let line = ApprovalLayout.secondary("Asked by " + who, width: ApprovalLayout.inner(Self.width))
        return line
    }

    /// Details, closed: how it runs (the same on every request, so not in the way), the checked nxtrm, a title a program
    /// set, the process, the program and its arguments.
    private func detailsRow() -> NSView {
        let facts = content.askedBy
        var lines: [String] = []
        if content.runsAsShell { lines.append("Runs as a shell command (/bin/sh -c)") }
        if !content.command.isEmpty { lines.append(SecretRun.environmentNote(keys: content.keys.count)) }
        if facts.checkedNxtrm { lines.append("Asked through Next Term\u{2019}s own nxtrm (checked)") }
        if let title = facts.programTitle.map({ Self.sanitized($0, limit: 80) }), !title.isEmpty {
            lines.append("Tab title (set by a program): \(title)")
        }
        if let pid = facts.pid { lines.append("Process: \(pid)") }
        if let executable = facts.executable { lines.append("Program: \(Self.sanitized(executable, limit: 1000))") }
        let arguments = facts.arguments.isEmpty ? content.argv : facts.arguments
        if !arguments.isEmpty {
            lines.append("\(arguments.count) \(arguments.count == 1 ? "argument" : "arguments"):")
            lines.append(contentsOf: arguments.prefix(200).map { "  " + Self.escaped(Self.masked($0)) })
            if arguments.count > 200 { lines.append("  \u{2026} and \(arguments.count - 200) more") }
        }
        let body = NSTextField(wrappingLabelWithString: lines.joined(separator: "\n"))
        body.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = ApprovalLayout.inner(Self.width)
        body.isSelectable = true
        detailsBox.orientation = .vertical
        detailsBox.alignment = .leading
        detailsBox.addArrangedSubview(body)
        let row = DisclosureRow(title: "Details", content: detailsBox)
        row.onToggle = { [weak self] in self?.fitHeight() }
        detailsDisclosure = row.triangle
        return row
    }

    /// "How long", only when there is a choice: with one (a remote request, a key that asks for Touch ID every time)
    /// the radio stays, hidden, and a line says why Allow once is all there is.
    private func howLongView() -> NSView? {
        guard content.offersHowLong else { return nil }
        let inner = ApprovalLayout.inner(Self.width)
        var views: [NSView] = []
        func radio(_ title: String, _ how: SecretRequests.How, note: String?) {
            let button = NSButton(radioButtonWithTitle: title, target: self, action: #selector(choseHowLong(_:)))
            durationChoice[how] = button
            views.append(button)
            if let note {
                let label = ApprovalLayout.secondary(note, width: inner - 20)
                let indented = NSStackView(views: [label])
                indented.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
                views.append(indented)
            }
        }
        let asking: String? = content.askingEveryUse.isEmpty ? nil : Self.askingNote(content.askingEveryUse)
        radio("Allow once", .once, note: nil)
        if content.choices.contains(.fifteenMinutes) {
            let note = content.isWrapper ? Self.fifteenMinutesNote + " " + Self.wrapperRestartNote : Self.fifteenMinutesNote
            radio("Allow for 15 minutes", .fifteenMinutes, note: note)
        }
        if content.choices.contains(.untilLock) {
            let agent = content.askedBy.agent ?? "this program"
            radio("Allow this command until the Mac locks", .untilLock,
                  note: "For this exact command, started by \(agent) in this folder. Ends when you lock the Mac, it goes to sleep, "
                    + "or Next Term quits. Revoke it in Settings \u{203A} Secrets.")
        }
        if content.choices.contains(.session) {
            // The widest: last, and plain about what ends it.
            let agent = content.askedBy.agent ?? "this agent"
            radio("Allow for this session", .session,
                  note: "These keys, for any command \(agent) runs with them, until \(agent) exits, its tab closes or another agent "
                    + "types into it, a key changes, or Next Term quits. Locking the Mac or switching users doesn\u{2019}t end it. A command "
                    + "Next Term would warn about still asks. Revoke it in Settings \u{203A} Secrets.")
        }
        durationChoice[.once]?.state = .on
        guard durationChoice.count > 1 else {
            // One choice is no choice: the radio stays (the panel's state reads it), out of sight.
            let only = views.compactMap { $0 as? NSButton }
            only.forEach { $0.isHidden = true }
            let line = ApprovalLayout.secondary(asking ?? "A remote connection\u{2019}s request is allowed once at a time.", width: inner)
            let stack = ApprovalLayout.group(only + [line])
            return stack
        }
        if let asking { views.insert(ApprovalLayout.secondary(asking, width: inner), at: 0) }
        let caption = ApprovalLayout.caption("How long")
        return ApprovalLayout.group([caption] + views)
    }

    /// Requests waiting behind this one, and the hour's pause that declines them all, beside it (also in the Secrets
    /// menu): only while some wait.
    private func waitingRow() -> NSView {
        pauseButton = NSButton(title: "Pause Key Requests for 1 Hour\u{2026}", target: self, action: #selector(pause))
        pauseButton.bezelStyle = .rounded
        pauseButton.controlSize = .small
        pauseButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pauseButton.keyEquivalent = ""
        waitingLabel.font = .systemFont(ofSize: 11)
        waitingLabel.textColor = .secondaryLabelColor
        let row = NSStackView(views: [waitingLabel, NSView(), pauseButton])
        row.spacing = 8
        waitingRowView = row
        setWaiting(content.waiting)
        return row
    }

    private var waitingRowView: NSStackView?

    /// Decline and Stop Asking at the start; Decline (Escape) and Allow at the end, Allow the primary, by a click only.
    private func buttonRow() -> NSView {
        stopButton = NSButton(title: "Decline and Stop Asking", target: self, action: #selector(declineAndStop))
        declineButton = NSButton(title: "Decline", target: self, action: #selector(decline))
        allowButton = PrimaryButton(title: content.allowTitle, target: self, action: #selector(allow))
        return ApprovalLayout.buttonRow(left: [stopButton], decline: declineButton, primary: allowButton)
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
        // The hour's pause is for a flood of requests: beside them while some wait, and never on store_secret's panel.
        pauseButton?.isHidden = count == 0 || !content.offersHowLong
        waitingRowView?.isHidden = count == 0
        fitHeight()
    }

    /// Allow is waiting for Touch ID or the password: the panel says so, and nothing else can be pressed.
    func setBusy(_ busy: Bool) {
        isBusy = busy
        for button in [allowButton, declineButton, stopButton, pauseButton] { button?.isEnabled = !busy }
        for button in durationChoice.values { button.isEnabled = !busy }
        if oncePausesWhenGone, cardLabel.isHidden == false { durationChoice[.once]?.isEnabled = false }
        window?.standardWindowButton(.closeButton)?.isEnabled = !busy
        setStatus(busy ? "Waiting for Touch ID or your password…" : "")
    }

    /// Touch ID or the password was cancelled or failed: back to where the user was.
    func notApproved() {
        setStatus("Not approved.")
    }

    /// Its wrapper stopped waiting: a pending card, "Allow for 15 minutes" chosen and "Allow once" off. With only Allow
    /// once offered (a key that asks every time), it stays on: its one use waits 2 minutes for the restart.
    func markGone() {
        cardLabel.stringValue = Self.cardText
        cardLabel.isHidden = false
        fitHeight()
        if oncePausesWhenGone {
            select(.fifteenMinutes)
            durationChoice[.once]?.isEnabled = false
        }
        announce(Self.cardText)
    }

    /// Whether a pending card turns Allow once off: only when Allow for 15 minutes is there to take its place.
    private var oncePausesWhenGone: Bool { durationChoice[.fifteenMinutes] != nil }

    /// "GITHUB_TOKEN asks for Touch ID every time it’s used, so only Allow once is offered."
    static func askingNote(_ names: [String]) -> String {
        let one: Bool = names.count == 1
        let verb: String = one ? "asks" : "ask"
        let used: String = one ? "it\u{2019}s used" : "they\u{2019}re used"
        return "\(SecretRun.keysText(names)) \(verb) for Touch ID every time \(used), so only Allow once is offered."
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
        let escape: Any? = alert.escapePressesCancel() // Cancel holds Return, so Escape is given back to it
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if let escape { NSEvent.removeMonitor(escape) }
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
                + "MCP servers that need keys won\u{2019}t start."
            // As the menu's: Return cancels, as the pause declines every request and ends every approval.
            let pause = alert.addButton(withTitle: "Pause for 1 Hour")
            pause.keyEquivalent = ""
            pause.hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
            return alert
        }
        alert.informativeText = menuPauseText
        let pause = alert.addButton(withTitle: "Pause for 1 Hour")
        pause.keyEquivalent = ""
        pause.hasDestructiveAction = true
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
        return "A program outside Next Term’s tabs \(tail)"
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
