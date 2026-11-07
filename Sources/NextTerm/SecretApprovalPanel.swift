import AppKit
import NextTermCore

/// Next Term's own panel before a stored key is used: one heading (who wants which key), a card of four aligned rows
/// (Who, Key, For, In), the warnings, and one primary, Allow, with a Remember pop-up beside it: Only this time, the
/// lasting choices the request may have (15 minutes, until the Mac locks, this session) and the Always choices. Details
/// keeps the facts that are the same on every request. After Allow comes the Touch ID or Mac password sheet.
///
/// It follows `AgentApprovalWindow`'s rules: it never takes the keyboard on its own (`becomesKeyOnlyIfNeeded`), Allow
/// is the one primary, rightmost and tinted, and refuses first responder, Escape declines and closing it declines. Once
/// the user has clicked into it, Return is Allow with what Remember shows, which starts as Only this time: never an
/// Always by accident. So a request reaches the user wherever they are, it also never activates Next Term
/// (`.nonactivatingPanel`), joins every Space and shows over a full-screen window, floats while it waits, and bounces
/// the Dock icon when Next Term is in the background.
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

        /// The Always choices as the panel words them, or why there are none.
        struct Always {
            /// Each choice offered, with its pop-up title ("Always in app").
            var labels: [SecretRequests.How: String] = [:]
            /// "Always isn’t offered: …", when that is so.
            var refusal: String?
            /// A command that bridges to a server at a URL: "Use as an MCP Server" adds it.
            var bridge: SecretAlwaysBridge.Server?
            var agent: String
            /// The program an Always grant binds (the agent's executable, and its script under an interpreter): the Who
            /// row's tooltip, so a program that only goes by an agent's name shows what it is.
            var program: String?
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
        /// store_secret has no Remember, and saves instead of allowing.
        var offersHowLong = true
        var allowTitle = "Allow"
        /// Remember's choices, in order (`SecretApprovalChoices.offered`).
        var choices: [SecretRequests.How] = [.once, .fifteenMinutes]
        /// The keys set to ask for Touch ID every time they're used: said under Remember.
        var askingEveryUse: [String] = []
        /// A remote MCP server's keys: `command` is its URL, and Next Term sends the keys in the headers itself.
        var reachesURL = false
        /// A hub server's name, for the For row.
        var serverName: String?
        /// The In row's name for the folder (the project's or worktree's, with the path inside it), when known.
        var place: String?
        var always: Always?
    }

    static let headersNote = "Next Term sends the key in its requests to this server itself. The agent gets only the server\u{2019}s answers."

    static let fifteenMinutesNote = "Only this agent, these keys, this exact command and folder. Anything different asks again."
    static let wrapperRestartNote = "Covers starting it again. A server already running keeps going."

    static let cardText = "This MCP server stopped waiting. Allow it, then restart it in your agent (in Claude Code: /mcp, then Reconnect)."
    static let stoppedDuringApprovalText = "This MCP server stopped waiting. Restart it within 2 minutes to use this approval."

    private let content: Content
    private let onAllow: (SecretRequests.How) -> Void
    private let onDecline: (_ stopAsking: Bool) -> Void
    private let onPause: () -> Void
    /// "Use as an MCP Server": the server to add, for a command that bridges to one.
    var onUseAsServer: ((SecretAlwaysBridge.Server) -> Void)?

    private(set) var allowButton: PrimaryButton!
    private(set) var declineButton: NSButton!
    private(set) var stopButton: NSButton!
    private(set) var pauseButton: NSButton!
    private(set) var serverButton: NSButton?
    /// Remember's pop-up, and an item for each choice it offers, by its choice.
    private(set) var rememberPopUp: NSPopUpButton?
    private(set) var durationChoice: [SecretRequests.How: RememberItem] = [:]
    private(set) var detailsDisclosure: NSButton!
    /// The confirm "Pause Key Requests for 1 Hour…" shows, while it is up.
    private(set) var pauseAlert: NSAlert?
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let waitingLabel = NSTextField(labelWithString: "")
    private let cardLabel = NSTextField(wrappingLabelWithString: "")
    /// What the choice Remember shows means, under it.
    private let rememberNote = NSTextField(wrappingLabelWithString: "")
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
        panel.keepsItsOwnFrame()
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
    /// The card's label column: Who, Key, For, In.
    static let labelWidth: CGFloat = 44

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
        let pinned = NSStackView(views: [cardLabel, waitingRow(), rememberView(), statusLabel, buttonRow()].compactMap { $0 })
        pinned.orientation = .vertical
        pinned.alignment = .leading
        pinned.spacing = 10
        pinned.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 20, right: 20)
        pinned.translatesAutoresizingMaskIntoConstraints = false
        pinned.setHuggingPriority(.required, for: .vertical)

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

    /// The rows' height, up to about 70% of the screen's visible height with Remember and the buttons below; again
    /// whenever what shows changes (Details, the card, the waiting line, Remember's note), so nothing lands below the fold
    /// unseen.
    private func fitHeight() {
        guard let rows = rowsStack, let pinned = pinnedStack else { return }
        rows.layoutSubtreeIfNeeded()
        pinned.layoutSubtreeIfNeeded()
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800
        let room = max(160, visible * 0.7 - pinned.fittingSize.height)
        let scroll = min(rows.fittingSize.height, room)
        scrollHeight?.constant = scroll
        // The window as tall as what it holds, its top edge where it was: a line hidden again takes its room with it.
        guard let window else { return }
        let content = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: scroll + pinned.fittingSize.height))
        var frame = window.frame
        guard abs(frame.height - content.height) > 0.5 else { return }
        frame.origin.y += frame.height - content.height
        frame.size.height = content.height
        window.setFrame(frame, display: window.isVisible)
    }

    /// Groups, 16 points apart: the heading and the agent's words; the card; the notice and warnings; Details. The
    /// window's title bar stays empty: the heading says it once.
    private func rowViews() -> [NSView] {
        let inner = ApprovalLayout.inner(Self.width)
        var groups: [NSView] = []
        var top: [NSView] = [ApprovalLayout.heading(Self.sanitized(content.title, limit: 200), width: inner)]
        if let words = content.agentWords.map({ Self.sanitized($0, limit: 500) }), !words.isEmpty {
            top.append(ApprovalLayout.agentWords(words, who: content.askedBy.agent.map { Self.sanitized($0, limit: 60) }, width: inner))
        }
        groups.append(ApprovalLayout.group(top))
        groups.append(card())
        var warnings: [NSView] = []
        if let notice = content.notice { warnings.append(ApprovalLayout.body(notice, width: inner)) }
        for warning in content.warnings { warnings.append(warningRow(warning)) }
        if !warnings.isEmpty {
            let group = ApprovalLayout.group(warnings)
            group.spacing = 6
            groups.append(group)
        }
        groups.append(detailsRow())
        return groups
    }

    // MARK: the card

    /// Who, Key, For and In, each a quiet label in one column beside its symbol and its value, in a light box.
    private func card() -> NSView {
        let inner = ApprovalLayout.inner(Self.width)
        let valueWidth = inner - 24 - Self.labelWidth - 18 - 16
        var rows: [NSView] = []
        let who = ApprovalLayout.body(whoText(), width: valueWidth)
        if let program = content.always?.program { who.toolTip = Self.sanitized(program, limit: 1000) }
        rows.append(cardRow("person.crop.circle", "Who", [who]))
        if !content.keys.isEmpty {
            rows.append(cardRow("key", content.keys.count == 1 ? "Key" : "Keys", content.keys.map { keyValue($0, width: valueWidth) }))
        }
        if let what = forValue(width: valueWidth) {
            rows.append(cardRow(content.reachesURL ? "globe" : "terminal", "For", [what]))
        }
        if !content.folder.isEmpty {
            let place = Self.sanitized(content.place ?? (content.folder as NSString).lastPathComponent, limit: 200)
            let label = ApprovalLayout.body(place, width: valueWidth)
            label.toolTip = Self.sanitized(content.folder, limit: 1000)
            label.setAccessibilityLabel("In \(place), \(Self.sanitized(content.folder, limit: 1000))")
            rows.append(cardRow("folder", "In", [label]))
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let box = CardBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    /// One row of the card: the symbol, the label, then the value lines, top-aligned on the first line.
    private func cardRow(_ symbol: String, _ label: String, _ values: [NSView]) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: 11)
        name.textColor = .secondaryLabelColor
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        name.setAccessibilityElement(false)
        let column = NSStackView(views: values)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        let row = NSStackView(views: [icon, name, column])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 0
        row.setCustomSpacing(6, after: icon)
        row.setCustomSpacing(10, after: name)
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel(label)
        return row
    }

    /// "Codex in a Next Term tab in app", "a program outside Next Term’s tabs", "the remote connection “phone”".
    private func whoText() -> String {
        let facts = content.askedBy
        if let connection = facts.connection { return "The remote connection \u{201C}\(Self.sanitized(connection, limit: 80))\u{201D}" }
        let who = facts.agent.map { Self.sanitized($0, limit: 60) } ?? (facts.tab == nil ? "A program" : "A command")
        guard facts.tab != nil else { return who + " outside Next Term\u{2019}s tabs" }
        let project = facts.project.map { " in " + Self.sanitized(($0 as NSString).lastPathComponent, limit: 120) } ?? ""
        return who + " in a Next Term tab" + project
    }

    /// A key: its name in the command's type (and the variable it goes in as), then what it's for in two lines at most,
    /// the whole of it in the tooltip, and when it was last used.
    private func keyValue(_ key: Content.KeyRow, width: CGFloat) -> NSView {
        let shown = key.envName == key.name ? key.name : "\(key.name) as \(key.envName)"
        let name = NSTextField(labelWithString: shown)
        name.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        name.isSelectable = true
        var purpose: String = key.purpose.isEmpty ? "No note of what it\u{2019}s for" : Self.sanitized(key.purpose, limit: 200)
        if key.purposeByAgent { purpose = "Note by an agent: " + purpose }
        let used: String = key.lastUsed == SecretRequests.neverUsed ? "Never used" : "Last used \(key.lastUsed)"
        let note = ApprovalLayout.secondary("\(purpose). \(used).", width: width)
        note.maximumNumberOfLines = 2
        note.cell?.truncatesLastVisibleLine = true
        note.lineBreakMode = .byTruncatingTail
        note.toolTip = "\(purpose). \(used)."
        var lines: [NSView] = [name, note]
        if key.writeOnly { lines.append(ApprovalLayout.secondary(SecretNewKeyDefaults.neverShownHelp, width: width)) }
        let stack = ApprovalLayout.group(lines)
        stack.spacing = 2
        return stack
    }

    /// The command as it runs, in a box that wraps only between words or path parts and can be selected; for a hub
    /// server, its name and URL.
    private func forValue(width: CGFloat) -> NSView? {
        guard !content.command.isEmpty else { return nil } // store_secret runs nothing
        if content.reachesURL {
            let name = content.serverName.map { Self.sanitized($0, limit: 120) + " \u{00B7} " } ?? ""
            let label = ApprovalLayout.body(name + Self.sanitized(content.command, limit: 2000), width: width)
            label.isSelectable = true
            return label
        }
        let box = CommandBox(Self.shownCommand(content.command, limit: 4000), width: width)
        commandBox = box
        return box
    }

    private(set) var commandBox: CommandBox?

    private func warningRow(_ text: String) -> NSView {
        let shown = Self.sanitized(text, limit: 400)
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning") ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
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

    /// Details, closed: how it runs (the same on every request, so not in the way), who asked as Next Term knows it (the
    /// agent going by its program's name, the checked nxtrm, a title a program set), the process, the program and its
    /// arguments.
    private func detailsRow() -> NSView {
        let facts = content.askedBy
        var lines: [String] = []
        if let agent = facts.agent { lines.append("Asked by \(Self.sanitized(agent, limit: 60)) (going by its program\u{2019}s name)") }
        if let tab = facts.tab {
            let project = facts.project.map { " of " + RecentProjects.abbreviate(Self.sanitized($0, limit: 300), home: NSHomeDirectory()) } ?? ""
            lines.append("From \(tab)\(project)")
        }
        if content.runsAsShell { lines.append("Runs as a shell command (/bin/sh -c)") }
        if !content.command.isEmpty { lines.append(content.reachesURL ? Self.headersNote : SecretRun.environmentNote(keys: content.keys.count)) }
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

    // MARK: Remember

    /// Each choice's title in Remember.
    func title(of how: SecretRequests.How) -> String {
        switch how {
        case .once: return "Only this time"
        case .fifteenMinutes: return "For 15 minutes"
        case .untilLock: return "Until the Mac locks"
        case .session: return "For this session"
        case .alwaysProject, .alwaysWorktree, .alwaysFolder: return content.always?.labels[how] ?? "Always"
        }
    }

    /// Remember, only when there is a choice: a pop-up of the choices (Only this time first and chosen, the Always ones
    /// after a separator), and under it what the chosen one means. With one choice the pop-up stays, hidden, and a line
    /// says why Only this time is all there is; why Always isn't offered, when that is so, with "Use as an MCP Server"
    /// for a command that bridges to one.
    private func rememberView() -> NSView? {
        guard content.offersHowLong else { return nil }
        let inner = ApprovalLayout.inner(Self.width)
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.controlSize = .regular
        popUp.target = self
        popUp.action = #selector(choseRemember(_:))
        popUp.setAccessibilityLabel("Remember")
        var sawAlways = false
        for how in content.choices {
            if how.isAlways, !sawAlways {
                sawAlways = true
                if popUp.numberOfItems > 0 { popUp.menu?.addItem(.separator()) }
            }
            popUp.addItem(withTitle: title(of: how))
            guard let item = popUp.lastItem else { continue }
            item.representedObject = how.rawValue
            durationChoice[how] = RememberItem(item, in: popUp, panel: self)
        }
        popUp.selectItem(at: 0)
        rememberPopUp = popUp
        rememberNote.font = .systemFont(ofSize: 11)
        rememberNote.textColor = .secondaryLabelColor
        rememberNote.preferredMaxLayoutWidth = inner
        var lines: [NSView] = []
        let caption = ApprovalLayout.caption("Remember")
        caption.setAccessibilityElement(false)
        let row = NSStackView(views: [caption, popUp])
        row.spacing = 8
        row.alignment = .firstBaseline
        if durationChoice.count > 1 {
            lines.append(row)
            lines.append(rememberNote)
        } else {
            // One choice is no choice: the pop-up stays (the panel's state reads it), out of sight.
            row.isHidden = true
            lines.append(row)
            let only = content.askingEveryUse.isEmpty
                ? (content.isRemote ? "A remote connection\u{2019}s request is allowed once at a time." : nil)
                : Self.askingNote(content.askingEveryUse)
            if let only { lines.append(ApprovalLayout.secondary(only, width: inner)) }
        }
        if let refusal = content.always?.refusal {
            lines.append(ApprovalLayout.secondary(Self.sanitized(refusal, limit: 300), width: inner))
        }
        if let bridge = content.always?.bridge {
            let button = NSButton(title: "Use as an MCP Server\u{2026}", target: self, action: #selector(useAsServer))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.toolTip = "Adds \(Self.sanitized(bridge.url, limit: 200)) to Settings \u{203A} MCP Servers with the same key. Next Term "
                + "sends the key itself, so the agent never sees it, and Always is offered there."
            serverButton = button
            lines.append(button)
        }
        updateRememberNote()
        let group = ApprovalLayout.group(lines)
        group.spacing = 4
        return lines.isEmpty ? nil : group
    }

    /// What the choice Remember shows means.
    private func updateRememberNote() {
        let how = selectedHow
        let agent = content.always?.agent ?? content.askedBy.agent ?? "this agent"
        var text: String?
        switch how {
        case .once:
            text = content.askingEveryUse.isEmpty || durationChoice.count <= 1 ? nil
                : Self.askingNote(content.askingEveryUse).replacingOccurrences(of: ", so only Allow once is offered", with: "")
        case .fifteenMinutes:
            text = content.isWrapper ? Self.fifteenMinutesNote + " " + Self.wrapperRestartNote : Self.fifteenMinutesNote
        case .untilLock:
            text = "For this exact command, started by \(agent) in this folder. Ends when you lock the Mac, it goes to sleep, "
                + "or Next Term quits. Revoke it in Settings \u{203A} Secrets."
        case .session:
            text = "These keys, for any command \(agent) runs with them, until \(agent) exits, its tab closes or another agent "
                + "types into it, a key changes, or Next Term quits. Locking the Mac or switching users doesn\u{2019}t end it. A command "
                + "Next Term would warn about still asks. Revoke it in Settings \u{203A} Secrets."
        case .alwaysProject, .alwaysWorktree, .alwaysFolder:
            let what = content.reachesURL ? "this server" : "this exact command"
            let place: String
            switch how {
            case .alwaysProject: place = "anywhere in this project and its worktrees"
            case .alwaysWorktree: place = "anywhere in this worktree"
            default: place = "in this folder"
            }
            text = "\(agent) can use \(SecretRun.keysText(content.keys.map(\.name))) for \(what) \(place), with Touch ID once each time "
                + "Next Term opens and no panel. Anything different asks again. Remove it in Settings \u{203A} Secrets."
            if !content.askingEveryUse.isEmpty {
                let one = content.askingEveryUse.count == 1
                text = "\(SecretRun.keysText(content.askingEveryUse)) \(one ? "asks" : "ask") for Touch ID every time; for \(what) "
                    + "\(one ? "it" : "they") will ask once each time Next Term opens, and Allow asks for Touch ID to confirm. Elsewhere "
                    + "\(one ? "it" : "they") still \(one ? "asks" : "ask") every time."
            }
        }
        rememberNote.stringValue = text ?? ""
        rememberNote.isHidden = text == nil
        fitHeight()
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

    /// Decline and Stop Asking at the start, small and quiet; Decline (Escape) and Allow at the end, Allow the one
    /// primary. Return is Allow with what Remember shows, once the user is in the panel.
    private func buttonRow() -> NSView {
        stopButton = NSButton(title: "Decline and Stop Asking", target: self, action: #selector(declineAndStop))
        declineButton = NSButton(title: "Decline", target: self, action: #selector(decline))
        allowButton = PrimaryButton(title: content.allowTitle, target: self, action: #selector(allow))
        let row = ApprovalLayout.buttonRow(left: [stopButton], decline: declineButton, primary: allowButton)
        stopButton.controlSize = .small
        stopButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        allowButton.keyEquivalent = "\r"
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
        guard let raw = rememberPopUp?.selectedItem?.representedObject as? String else { return .once }
        return SecretRequests.How(rawValue: raw) ?? .once
    }

    func select(_ how: SecretRequests.How) {
        guard let item = durationChoice[how]?.item else { return }
        rememberPopUp?.select(item)
        updateRememberNote()
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
        for button in [allowButton, declineButton, stopButton, pauseButton, serverButton] { button?.isEnabled = !busy }
        rememberPopUp?.isEnabled = !busy
        if oncePausesWhenGone, cardLabel.isHidden == false { durationChoice[.once]?.isEnabled = false }
        window?.standardWindowButton(.closeButton)?.isEnabled = !busy
        setStatus(busy ? "Waiting for Touch ID or your password\u{2026}" : "")
    }

    /// A line in the panel's status: what went wrong with an action it started.
    func showNote(_ text: String) {
        setStatus(text)
    }

    /// Touch ID or the password was cancelled or failed: back to where the user was.
    func notApproved() {
        setStatus("Not approved.")
    }

    /// Its wrapper stopped waiting: a pending card, "For 15 minutes" chosen and "Only this time" off. With only that
    /// offered (a key that asks every time), it stays on: its one use waits 2 minutes for the restart.
    func markGone() {
        cardLabel.stringValue = Self.cardText
        cardLabel.isHidden = false
        fitHeight()
        if oncePausesWhenGone {
            if selectedHow == .once { select(.fifteenMinutes) }
            durationChoice[.once]?.isEnabled = false
        }
        announce(Self.cardText)
    }

    /// Whether a pending card turns Only this time off: only when For 15 minutes is there to take its place.
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

    /// The wrapper left during Touch ID after "Only this time": a one-use approval waits 2 minutes.
    func showStoppedDuringApproval() {
        answered = true
        window?.level = .normal // nothing waits on it any more
        setBusy(false)
        for button in [allowButton, declineButton, stopButton, pauseButton, serverButton] { button?.isEnabled = false }
        rememberPopUp?.isEnabled = false
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

    @objc private func choseRemember(_ sender: NSPopUpButton) {
        updateRememberNote()
    }

    @objc private func useAsServer() {
        guard !answered, !isBusy, let bridge = content.always?.bridge else { return }
        onUseAsServer?(bridge)
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

    /// The panel's title: who wants which key ("Codex wants to use API_TOKEN", "… wants to use 2 keys"). What it runs
    /// or reaches is the card's For row.
    static func title(_ request: SecretRequests.Request) -> String {
        if let title = request.titleOverride { return title }
        let keys = request.names.count == 1 ? request.names[0] : "\(request.names.count) keys"
        let tail = "wants to use \(keys)"
        let facts = request.askedBy
        if let connection = facts.connection { return "The remote connection \u{201C}\(connection)\u{201D} \(tail)" }
        if let agent = facts.agent { return "\(agent) \(tail)" }
        if let tab = facts.tab { return "A command in \(tab) \(tail)" }
        return "A program outside Next Term\u{2019}s tabs \(tail)"
    }

    /// "5 min ago by Claude Code", from a `use` line.
    static func lastUsedText(_ line: SecretAudit.Line) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        // Under a minute is "just now", never "in 0s" from a clock a moment apart.
        let when = abs(line.time.timeIntervalSinceNow) < 60 ? "just now" : formatter.localizedString(for: line.time, relativeTo: Date())
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

/// The card's light box, its fill set as it draws, so it follows the appearance and Increase Contrast.
private final class CardBox: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        layer?.borderWidth = 1
        layer?.borderColor = (contrast ? NSColor.separatorColor : NSColor.separatorColor.withAlphaComponent(0.5)).cgColor
    }
}

/// One of Remember's choices, as the self-test and the pending card use it: chosen or not, enabled or not, chosen by a
/// click.
@MainActor
final class RememberItem {
    let item: NSMenuItem
    private weak var popUp: NSPopUpButton?
    private weak var panel: SecretApprovalPanel?

    init(_ item: NSMenuItem, in popUp: NSPopUpButton, panel: SecretApprovalPanel) {
        self.item = item
        self.popUp = popUp
        self.panel = panel
    }

    var state: NSControl.StateValue { popUp?.selectedItem === item ? .on : .off }

    var isEnabled: Bool {
        get { item.isEnabled }
        set {
            popUp?.autoenablesItems = false
            item.isEnabled = newValue
        }
    }

    var title: String { item.title }

    /// Chooses it, as a click in the pop-up would.
    func performClick(_ sender: Any?) {
        guard isEnabled, let raw = item.representedObject as? String, let how = SecretRequests.How(rawValue: raw) else { return }
        panel?.select(how)
    }
}
