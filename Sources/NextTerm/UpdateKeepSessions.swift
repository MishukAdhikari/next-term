import AppKit
import NextTermCore

/// The update sheet (plan 003's U11, R14-R19, R28): what happens to each tab before anything quits, with one checkbox,
/// "Reopen windows and resume sessions after the update", and the buttons UpdateFlow gives each state. It replaces the
/// "ready to relaunch" alert at every place a staged update can relaunch: a manual check with the update staged, the
/// Update button and the end of a download (Updater).
///
/// The sheet opens by itself, often while the user types, so it never takes the keyboard when it opens and no button is
/// the default: Return confirms nothing. A click into it gives it the keyboard, and then Tab and Space work as usual. Only
/// "Update Now", or "Wait for Them" at its countdown's end, creates the update consent (KTD2); no file, defaults key,
/// test switch or MCP tool can. "Wait for Them" opens the wait panel, which never takes the keyboard either (KTD16).
@MainActor
final class UpdateKeepSessions {
    static let shared = UpdateKeepSessions()

    /// What the sheet or the wait panel shows, while either is up.
    private(set) var flow: UpdateFlow?
    private(set) var sheet: UpdateSheetController?
    private(set) var panel: UpdateWaitPanel?
    private var timer: Timer?
    private var waitStarted: Date?
    private var countdownEnds: Date?

    /// A wait for busy tabs is under way ("Wait for Them", then its countdown). MCP refuses new work elsewhere while it is.
    var isWaiting: Bool {
        guard let state = flow?.state else { return false }
        return state == .waiting || state == .countdown
    }

    /// The sheet, never over a sheet, a modal window or a quit's question: then the update stays on the Update button.
    static var mayStart: Bool {
        let sheet = NSApp.windows.contains { $0.attachedSheet != nil }
        return UpdateFlow.mayStart(sheetAttached: sheet, modalWindow: NSApp.modalWindow != nil,
                                   askingToQuit: AppDelegate.shared.askingToQuit)
    }

    /// Opens the sheet for the staged `version`, planned from the open windows, its box where the user last left it. While
    /// a wait is under way, the wait panel comes forward instead.
    func show(version: AppVersion, from entry: UpdateFlow.Entry) {
        if isWaiting, flow?.version == version.description {
            panel?.present()
            return
        }
        guard Self.mayStart else { return }
        let remembered = AppDelegate.shared.launchDefaults.object(forKey: UpdateFlow.rememberKey) as? Bool
        flow = UpdateFlow(version: version.description, plan: UpdatePlanning.plan(), remembered: remembered, from: entry)
        presentSheet()
    }

    /// The update quit found the plan worse than the one its consent covered (QuitPolicy): its quit was cancelled and the
    /// consent cleared. The sheet shows again, with the plan now and the lines that made it worse marked, and its confirm
    /// gives a fresh consent.
    func showAgain(_ update: UpdateQuit) {
        guard Self.mayStart else { return }
        let worse = UpdateFlow.worse(update.current, than: update.consent)
        var again = UpdateFlow(version: update.consent.version, plan: update.current, remembered: update.consent.keep)
        again.showAgain(update.current, marking: worse?.panes ?? [])
        flow = again
        endTimer()
        panel?.close()
        panel = nil
        presentSheet()
        announce("The update was not started: what happens to your tabs changed. Check the update sheet again.")
    }

    // MARK: presses

    func pressed(_ button: UpdateButton) {
        guard var flow else { return }
        let effect = flow.press(button)
        self.flow = flow
        apply(effect)
    }

    /// The box: saved where the next sheet's box starts from. That is never consent: the press reads the box (R28).
    func keepChanged(_ on: Bool) {
        guard var flow else { return }
        flow.setKeep(on)
        self.flow = flow
        if flow.keepEnabled { AppDelegate.shared.launchDefaults.set(flow.keep, forKey: UpdateFlow.rememberKey) }
        sheet?.render(flow)
    }

    /// "Wait for this", on a busy tab's line.
    func waitedChanged(_ pane: UUID, _ on: Bool) {
        guard var flow else { return }
        flow.setWaited(pane, on)
        self.flow = flow
        sheet?.render(flow)
    }

    /// "Show" on a waited tab that needs an answer: its window and tab in front.
    func showTab(_ id: UUID) {
        for controller in AppDelegate.shared.controllers {
            guard let tab = controller.tabs.first(where: { $0.id == id }) else { continue }
            controller.show(tab)
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }
    }

    private func apply(_ effect: UpdateFlow.Effect) {
        guard let flow else { return }
        switch effect {
        case .none:
            sheet?.render(flow)
            panel?.render(flow, elapsed: elapsed, remaining: remaining)
        case .quit(let consent):
            closeAll()
            quit(consent)
        case .close:
            closeAll()
        case .startWait:
            sheet?.close()
            sheet = nil
            waitStarted = Date()
            showPanel(flow)
        case .startCountdown:
            sheet?.close()
            sheet = nil
            if waitStarted == nil { waitStarted = Date() }
            countdownEnds = Date().addingTimeInterval(UpdateFlow.countdown)
            showPanel(flow)
            announce("Every tab you waited for is done. Updating in 10 seconds.")
        case .endWait:
            closeAll()
        case .showAgain:
            endTimer()
            panel?.close()
            panel = nil
            presentSheet()
            announce("The update was not started: what happens to your tabs changed. Check the update sheet again.")
        }
    }

    /// Quits under the consent, once no operation the update waits for runs (UpdateHolds). A quit that is cancelled, or
    /// refused because a sheet or a modal window came up meanwhile, leaves the update staged.
    private func quit(_ consent: UpdateConsent) {
        guard UpdateHolds.shared.running.isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.quit(consent) }
            return
        }
        Updater.shared.quitForUpdate(consent)
    }

    private func presentSheet() {
        guard let flow else { return }
        let sheet = self.sheet ?? UpdateSheetController()
        self.sheet = sheet
        sheet.render(flow, decisions: UpdateHolds.shared.openDecisions)
        sheet.present(over: Self.frontWindow)
    }

    private func showPanel(_ flow: UpdateFlow) {
        let panel = self.panel ?? UpdateWaitPanel()
        self.panel = panel
        panel.render(flow, elapsed: elapsed, remaining: remaining)
        panel.present()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { UpdateKeepSessions.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Each second while waiting: the waited tabs read again, the countdown counted, and at its end the plan again.
    private func tick() {
        guard var flow else { return endTimer() }
        switch flow.state {
        case .waiting:
            let effect = flow.refresh(UpdatePlanning.refreshed(flow.plan))
            self.flow = flow
            apply(effect)
        case .countdown:
            guard let ends = countdownEnds, Date() >= ends else {
                panel?.render(flow, elapsed: elapsed, remaining: remaining)
                return
            }
            countdownEnds = nil
            let effect = flow.countdownEnded(UpdatePlanning.plan())
            self.flow = flow
            apply(effect)
        case .idle, .busy:
            endTimer()
        }
    }

    private var elapsed: TimeInterval { waitStarted.map { Date().timeIntervalSince($0) } ?? 0 }

    private var remaining: Int? {
        guard let countdownEnds else { return nil }
        return max(0, Int(countdownEnds.timeIntervalSinceNow.rounded(.up)))
    }

    private func endTimer() {
        timer?.invalidate()
        timer = nil
        countdownEnds = nil
        waitStarted = nil
    }

    /// The sheet's close button: as Cancel, unless a wait goes on in the panel.
    func sheetClosed(_ controller: UpdateSheetController) {
        guard sheet === controller else { return }
        sheet = nil
        if !isWaiting { closeAll() }
    }

    private func closeAll() {
        endTimer()
        sheet?.close()
        sheet = nil
        panel?.close()
        panel = nil
        flow = nil
    }

    /// For VoiceOver: the countdown started, or the sheet showed again.
    private func announce(_ text: String) {
        let element: Any
        if let window = panel?.window ?? sheet?.window { element = window } else { element = NSApp as Any }
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The terminal window in front, which the sheet sits over.
    private static var frontWindow: NSWindow? {
        let candidates = [NSApp.mainWindow, NSApp.keyWindow] + NSApp.orderedWindows
        return candidates.compactMap { $0 }.first { window in window.isVisible && !window.isMiniaturized && window is TerminalWindow }
    }

    // MARK: the install's result

    private static var told = false

    /// After a relaunch the install could not finish: one alert from its result file, with the download-failure alert's
    /// buttons; or else, when the update did not install and no result said so, the one note. Once per launch (R18).
    static func tellInstallResult() {
        guard !told, let found = SessionRestore.shared.found else { return }
        told = true
        let decision = found.decision
        let version = found.snapshot?.header.pendingToVersion
        let name = version.map { "Next Term \($0)" } ?? "The update"
        if let outcome = decision.installAlert {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(name) was not installed"
            let kept = outcome == .failedRestoredBackup
                ? "The new version could not be put in place, so this version was opened from its backup."
                : "The new version could not be put in place, so this version opened again."
            alert.informativeText = kept + " The Update button still offers it.\n\nYou can download it from the release page instead."
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(releasePage(version)) }
        } else if decision.didNotInstallNote {
            let alert = NSAlert()
            alert.messageText = "\(name) did not install"
            alert.informativeText = "This version opened again. The Update button still offers the update."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private static func releasePage(_ version: String?) -> URL {
        guard let version, let url = URL(string: "https://github.com/\(Updater.repository)/releases/tag/v\(version)") else {
            return Updater.latestPage
        }
        return url
    }
}

// MARK: - The plan

/// The update sheet's plan, from the open windows: each pane captured as the quit would save it, planned as the update's
/// relaunch would restore it (RestorePlanning, kind update), with whether it is busy, and why sessions can't be kept.
@MainActor
enum UpdatePlanning {
    static func plan() -> UpdatePlan {
        let controllers = AppDelegate.shared.controllers
        let header = SessionSnapshot.Header(launchID: UUID(), generation: 0, clean: false, savedAt: Date())
        let snapshot = SessionSnapshot(header: header, windows: SessionCapture.windows(controllers))
        let planned = RestorePlanning.plan(snapshot, kind: .update, safeMode: false, quitConsent: false)
        var plans: [UUID: PanePlan] = [:]
        for plan in planned.plans where plans[plan.pane] == nil { plans[plan.pane] = plan }
        let leftOut = Set(SessionRestore.shared.lastSave?.panesLeftOut ?? [])
        let windows: [UpdateWindow] = controllers.map { (controller: TerminalWindowController) -> UpdateWindow in
            var panes: [UpdatePane] = []
            for group in controller.groups {
                for (index, tab) in group.panes.enumerated() {
                    let plan = plans[tab.id]
                    let outcome: RestoreOutcome = plan?.outcome ?? (tab.remote == nil ? .idle : .freshConnection)
                    var pane = UpdatePane(id: tab.id, name: name(of: tab), split: index > 0, outcome: outcome,
                                          listLine: plan?.listLine ?? "opens in its folder")
                    pane.busy = isBusy(tab)
                    pane.agent = tab.status.running && tab.status.kind == .agent
                    pane.remote = tab.remote != nil
                    pane.serving = tab.servedURL != nil
                    pane.leftOut = leftOut.contains(tab.id)
                    panes.append(pane)
                }
            }
            return UpdateWindow(name: name(of: controller), panes: panes)
        }
        return UpdatePlan(windows: windows, refusal: refusal)
    }

    /// The same plan, with each pane's busy state read again and the closed tabs gone: what the wait reads each second.
    static func refreshed(_ plan: UpdatePlan) -> UpdatePlan {
        var tabs: [UUID: TerminalTab] = [:]
        for tab in AppDelegate.shared.controllers.flatMap(\.tabs) { tabs[tab.id] = tab }
        var plan = plan
        for index in plan.windows.indices {
            plan.windows[index].panes = plan.windows[index].panes.compactMap { (pane: UpdatePane) -> UpdatePane? in
                guard let tab = tabs[pane.id] else { return nil }
                var pane = pane
                pane.busy = isBusy(tab)
                return pane
            }
        }
        plan.refusal = refusal
        return plan
    }

    /// Busy (R15, KTD16): a local tab with an agent working or waiting on the user, or a running command. A remote tab
    /// never is: what tmux or herdr keeps runs on, and a plain ssh tab only loses its connection.
    static func isBusy(_ tab: TerminalTab) -> Bool {
        let status = tab.status
        guard tab.remote == nil, !tab.exited, status.running else { return false }
        guard status.kind == .agent else { return true }
        return status.state == .working || status.state == .attention
    }

    /// Why sessions can't be kept: a translocated copy, or no session saved (no sessions folder, the save gate still
    /// closed, or the last save failed).
    static var refusal: KeepRefusal? {
        if Bundle.main.bundlePath.contains("/AppTranslocation/") { return .translocated }
        let sessions = SessionRestore.shared
        guard sessions.files != nil, sessions.lastSave?.succeeded == true else { return .notSaved }
        return nil
    }

    /// A tab's title, or its folder's name.
    static func name(of tab: TerminalTab) -> String {
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return TerminalText.oneLine(title) }
        let folder = (tab.liveDirectory as NSString).lastPathComponent
        return folder.isEmpty ? "Terminal" : folder
    }

    /// A window's project folder's name, or its title.
    static func name(of controller: TerminalWindowController) -> String {
        if let project = controller.project { return (project as NSString).lastPathComponent }
        let title = controller.window?.title ?? ""
        return title.isEmpty ? "Terminal" : title
    }
}

// MARK: - Holds

/// What the restart would cut off: operations the update waits for, and decisions only the user can make that the
/// restart drops. The sheet lists the open decisions, always; the update quit answers each registered one with a definite
/// no. Agent diff proposals are read from each editor area as they are, without editing it.
@MainActor
final class UpdateHolds {
    static let shared = UpdateHolds()

    private var decisions: [(id: UUID, title: String, cancel: () -> Void)] = []
    private var operations: [UUID: String] = [:]

    /// A decision open now (an agent's approval request): listed on the sheet, and answered "no" at the update quit.
    /// `close` it once it is answered.
    @discardableResult
    func open(decision title: String, cancel: @escaping () -> Void) -> UUID {
        let id = UUID()
        decisions.append((id, title, cancel))
        return id
    }

    func close(_ id: UUID) {
        decisions.removeAll { $0.id == id }
    }

    /// An operation the update quit waits for: it starts with `begin`, and `end` lets the quit go.
    func begin(_ title: String) -> UUID {
        let id = UUID()
        operations[id] = title
        return id
    }

    func end(_ id: UUID) {
        operations[id] = nil
    }

    /// The operations the update waits for, now.
    var running: [String] { Array(operations.values) }

    /// The decisions the restart drops: each agent's diff proposal waiting in an editor, then each registered one.
    var openDecisions: [String] {
        var lines: [String] = []
        for controller in AppDelegate.shared.controllers {
            for pane in controller.editorArea.proposals {
                guard let proposal = pane.proposal else { continue }
                lines.append(TerminalText.oneLine("\(proposal.author)’s proposed change to \(pane.path)"))
            }
        }
        return lines + decisions.map { TerminalText.oneLine($0.title) }
    }

    /// At the update quit: every registered decision answered "no", so its asker gets a definite answer.
    func cancelAll() {
        let open = decisions
        decisions = []
        for decision in open { decision.cancel() }
    }
}

// MARK: - The sheet

/// The update sheet's window, over the front terminal window without taking the keyboard (as the update window is
/// presented). Its buttons are exposed for the self-test.
@MainActor
final class UpdateSheetController: NSWindowController, NSWindowDelegate {
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(wrappingLabelWithString: UpdateFlow.subtitle)
    let busyStack = NSStackView()
    let keepBox = NSButton(checkboxWithTitle: UpdateFlow.checkboxTitle, target: nil, action: nil)
    let refusalLabel = NSTextField(wrappingLabelWithString: "")
    let summaryLabel = NSTextField(wrappingLabelWithString: "")
    let detailsToggle = NSButton(title: "", target: nil, action: nil)
    let detailsStack = NSStackView()
    private let detailsScroll = NSScrollView()
    let decisionsStack = NSStackView()
    /// Notes another feature adds (Remote access stopping), shown under the decisions; none yet.
    let notesStack = NSStackView()
    let buttonRow = NSStackView()
    /// The buttons now, by kind.
    private(set) var buttons: [UpdateButton: NSButton] = [:]
    /// Each busy tab's "Wait for this", by pane.
    private(set) var waitBoxes: [UUID: NSButton] = [:]
    private weak var parentWindow: NSWindow?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Software Update"
        window.isReleasedWhenClosed = false
        window.animationBehavior = .alertPanel
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        busyStack.orientation = .vertical
        busyStack.alignment = .leading
        busyStack.spacing = 4
        keepBox.target = self
        keepBox.action = #selector(keepChanged)
        refusalLabel.font = .systemFont(ofSize: 12)
        refusalLabel.textColor = .secondaryLabelColor
        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.setAccessibilityLabel("Summary")
        detailsToggle.bezelStyle = .disclosure
        detailsToggle.setButtonType(.pushOnPushOff)
        detailsToggle.state = .off
        detailsToggle.target = self
        detailsToggle.action = #selector(toggleDetails)
        detailsToggle.setAccessibilityLabel("Show Details")
        let detailsTitle = NSTextField(labelWithString: "Show Details")
        detailsTitle.font = .systemFont(ofSize: 12)
        let detailsRow = NSStackView(views: [detailsToggle, detailsTitle])
        detailsRow.spacing = 4
        detailsStack.orientation = .vertical
        detailsStack.alignment = .leading
        detailsStack.spacing = 2
        detailsStack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        detailsStack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(detailsStack)
        detailsScroll.documentView = document
        detailsScroll.hasVerticalScroller = true
        detailsScroll.autohidesScrollers = true
        detailsScroll.borderType = .bezelBorder
        detailsScroll.isHidden = true
        NSLayoutConstraint.activate([
            detailsStack.topAnchor.constraint(equalTo: document.topAnchor),
            detailsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            detailsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            detailsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: detailsScroll.contentView.widthAnchor),
            detailsScroll.heightAnchor.constraint(equalToConstant: 160),
        ])
        for stack in [decisionsStack, notesStack] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
        }
        notesStack.isHidden = true
        buttonRow.spacing = 8

        let stack = NSStackView(views: [titleLabel, subtitleLabel, busyStack, keepBox, refusalLabel, summaryLabel, detailsRow,
                                        detailsScroll, decisionsStack, notesStack, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(4, after: keepBox)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        // The checkbox and the buttons stay in view however long the lists get: the details scroll past a fixed height.
        for view in [subtitleLabel, refusalLabel, summaryLabel, detailsScroll, buttonRow] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 520).isActive = true
        window?.contentView = stack
        window?.initialFirstResponder = nil
    }

    /// Shows `flow`: the busy tabs first, each with "Wait for this"; the box; the summary; the details; the open decisions;
    /// and the state's buttons, none of them the default.
    func render(_ flow: UpdateFlow, decisions: [String]? = nil) {
        titleLabel.stringValue = flow.title
        busyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        waitBoxes = [:]
        let busy = flow.busyPanes
        busyStack.isHidden = busy.isEmpty || flow.state != .busy
        for pane in busy where flow.state == .busy {
            let line = NSTextField(labelWithString: pane.name + ": " + flow.line(pane))
            line.font = .systemFont(ofSize: 12)
            line.lineBreakMode = .byTruncatingTail
            line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            line.setAccessibilityLabel(pane.name + ", " + flow.line(pane))
            let box = NSButton(checkboxWithTitle: "Wait for this", target: self, action: #selector(waitChanged(_:)))
            box.state = flow.waitSet.contains(pane.id) ? .on : .off
            box.identifier = NSUserInterfaceItemIdentifier(pane.id.uuidString)
            box.setAccessibilityLabel("Wait for \(pane.name)")
            waitBoxes[pane.id] = box
            let row = NSStackView(views: [line, NSView(), box])
            row.spacing = 8
            busyStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: busyStack.widthAnchor).isActive = true
        }
        busyStack.translatesAutoresizingMaskIntoConstraints = false
        keepBox.state = flow.keep ? .on : .off
        keepBox.isEnabled = flow.keepEnabled
        refusalLabel.stringValue = flow.plan.refusal?.text ?? ""
        refusalLabel.isHidden = flow.plan.refusal == nil
        summaryLabel.stringValue = flow.summary
        detailsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for detail in flow.details {
            let line = NSTextField(labelWithString: (detail.changed ? "• " : "") + detail.text)
            line.font = detail.indent == 0 ? .systemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 12)
            line.lineBreakMode = .byTruncatingTail
            line.setAccessibilityLabel(detail.changed ? detail.label + ", changed" : detail.label)
            let indent = NSView()
            indent.widthAnchor.constraint(equalToConstant: CGFloat(detail.indent) * 14).isActive = true
            detailsStack.addArrangedSubview(NSStackView(views: [indent, line]))
        }
        if let decisions {
            decisionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            decisionsStack.isHidden = decisions.isEmpty
            if !decisions.isEmpty {
                let head = NSTextField(labelWithString: "The restart drops these open decisions:")
                head.font = .systemFont(ofSize: 12, weight: .semibold)
                decisionsStack.addArrangedSubview(head)
                for decision in decisions {
                    let line = NSTextField(labelWithString: "• " + decision)
                    line.font = .systemFont(ofSize: 12)
                    line.lineBreakMode = .byTruncatingTail
                    decisionsStack.addArrangedSubview(line)
                }
            }
        }
        renderButtons(flow)
        if let window, let content = window.contentView { window.setContentSize(content.fittingSize) }
    }

    private func renderButtons(_ flow: UpdateFlow) {
        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = [:]
        var views: [NSView] = [NSView()]
        for kind in flow.buttons {
            let button = NSButton(title: kind.title, target: self, action: #selector(press(_:)))
            button.bezelStyle = .rounded
            // No default button: Return presses nothing (R15). Cancel takes ⎋, which asks for nothing.
            button.keyEquivalent = kind == .cancel ? "\u{1b}" : ""
            button.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
            buttons[kind] = button
            views.append(button)
        }
        for view in views { buttonRow.addArrangedSubview(view) }
    }

    /// The button for `kind` in the state shown, for the self-test.
    func button(_ kind: UpdateButton) -> NSButton? { buttons[kind] }

    /// Over `parent` (it moves with it and stays above it until answered), or centred on its own, never taking the
    /// keyboard: someone typing to an agent keeps typing, and a Return meant for the terminal confirms nothing.
    func present(over parent: NSWindow?) {
        guard let window else { return }
        if window.isVisible { return }
        if let parent, parent.isVisible, !parent.isMiniaturized {
            let size = window.frame.size
            var origin = NSPoint(x: parent.frame.midX - size.width / 2, y: parent.frame.maxY - size.height - 64)
            if let screen = (parent.screen ?? NSScreen.main)?.visibleFrame {
                origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
                origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
            }
            window.setFrameOrigin(origin)
            parent.addChildWindow(window, ordered: .above)
            parentWindow = parent
            NotificationCenter.default.addObserver(self, selector: #selector(parentWillClose(_:)), name: NSWindow.willCloseNotification,
                                                   object: parent)
        } else {
            window.center()
        }
        window.orderFront(nil)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Its window closing would take this one with it: it stays, on its own.
    @objc private func parentWillClose(_ note: Notification) {
        guard let window, let parent = note.object as? NSWindow else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: parent)
        parent.removeChildWindow(window)
        parentWindow = nil
    }

    @objc private func press(_ sender: NSButton) {
        guard let kind = buttons.first(where: { $0.value === sender })?.key else { return }
        UpdateKeepSessions.shared.pressed(kind)
    }

    @objc private func keepChanged() {
        UpdateKeepSessions.shared.keepChanged(keepBox.state == .on)
    }

    @objc private func waitChanged(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        UpdateKeepSessions.shared.waitedChanged(id, sender.state == .on)
    }

    @objc private func toggleDetails() {
        detailsScroll.isHidden = detailsToggle.state != .on
        if let window, let content = window.contentView { window.setContentSize(content.fittingSize) }
    }

    /// The details shown, for the self-test.
    var detailsShown: Bool { !detailsScroll.isHidden }

    /// The details' lines as shown.
    var detailLines: [String] {
        detailsStack.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.last as? NSTextField }.map(\.stringValue)
    }

    override func close() {
        if let parent = parentWindow, let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: parent)
            parent.removeChildWindow(window)
        }
        parentWindow = nil
        window?.delegate = nil
        super.close()
    }

    /// The close button answers as Cancel does: nothing quits, and the update stays staged.
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { UpdateKeepSessions.shared.sheetClosed(self) }
    }
}

/// A view whose origin is at the top, so the details list starts at the top of its scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - The wait panel

/// "Wait for Them" (KTD16): the waited tabs with their state, "working" or "needs your answer" with a Show button that
/// brings that tab forward; the time waited, with no automatic timeout; "Update Now" and "Stop Waiting". Once every
/// waited tab is done, "Updating in 10 s" with Cancel. It never takes the keyboard.
@MainActor
final class UpdateWaitPanel: NSWindowController, NSWindowDelegate {
    let titleLabel = NSTextField(labelWithString: "")
    let tabsStack = NSStackView()
    let timeLabel = NSTextField(labelWithString: "")
    let buttonRow = NSStackView()
    private(set) var buttons: [UpdateButton: NSButton] = [:]
    /// Each "Show", by pane.
    private(set) var showButtons: [UUID: NSButton] = [:]

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
                            styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Software Update"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        super.init(window: panel)
        panel.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        tabsStack.orientation = .vertical
        tabsStack.alignment = .leading
        tabsStack.spacing = 4
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        buttonRow.spacing = 8
        let stack = NSStackView(views: [titleLabel, tabsStack, timeLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        stack.widthAnchor.constraint(equalToConstant: 380).isActive = true
        window?.contentView = stack
    }

    func render(_ flow: UpdateFlow, elapsed: TimeInterval, remaining: Int?) {
        let counting = flow.state == .countdown
        titleLabel.stringValue = counting ? "Updating in \(remaining ?? Int(UpdateFlow.countdown)) s"
            : "Waiting to update to \(flow.version)"
        tabsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        showButtons = [:]
        var tabs: [UUID: TerminalTab] = [:]
        for tab in AppDelegate.shared.controllers.flatMap(\.tabs) { tabs[tab.id] = tab }
        let waited = flow.plan.panes.filter { flow.waitSet.contains($0.id) }
        for pane in waited where !counting {
            let asks = tabs[pane.id]?.status.state == .attention
            let line = NSTextField(labelWithString: pane.name + ": " + (asks ? "needs your answer" : "working"))
            line.font = .systemFont(ofSize: 12)
            line.lineBreakMode = .byTruncatingTail
            var views: [NSView] = [line]
            if asks {
                let show = NSButton(title: "Show", target: self, action: #selector(showTab(_:)))
                show.bezelStyle = .rounded
                show.controlSize = .small
                show.identifier = NSUserInterfaceItemIdentifier(pane.id.uuidString)
                show.setAccessibilityLabel("Show \(pane.name)")
                showButtons[pane.id] = show
                views.append(show)
            }
            let row = NSStackView(views: views)
            row.spacing = 8
            tabsStack.addArrangedSubview(row)
        }
        tabsStack.isHidden = counting || waited.isEmpty
        let seconds = Int(elapsed)
        timeLabel.stringValue = String(format: "Waiting %d:%02d", seconds / 60, seconds % 60)
        timeLabel.isHidden = counting
        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = [:]
        var views: [NSView] = [NSView()]
        for kind in flow.buttons {
            let button = NSButton(title: kind.title, target: self, action: #selector(press(_:)))
            button.bezelStyle = .rounded
            button.keyEquivalent = ""
            buttons[kind] = button
            views.append(button)
        }
        for view in views { buttonRow.addArrangedSubview(view) }
        if let window, let content = window.contentView { window.setContentSize(content.fittingSize) }
    }

    func button(_ kind: UpdateButton) -> NSButton? { buttons[kind] }

    /// In front, at the top right of the screen, without taking the keyboard.
    func present() {
        guard let window else { return }
        if !window.isVisible, let screen = (NSApp.mainWindow?.screen ?? NSScreen.main)?.visibleFrame {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 20, y: screen.maxY - size.height - 20))
        }
        window.orderFront(nil)
    }

    @objc private func press(_ sender: NSButton) {
        guard let kind = buttons.first(where: { $0.value === sender })?.key else { return }
        UpdateKeepSessions.shared.pressed(kind)
    }

    @objc private func showTab(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        UpdateKeepSessions.shared.showTab(id)
    }

    override func close() {
        window?.delegate = nil
        super.close()
    }
}
