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
    /// Each second while the sheet or the panel is up: the open decisions read again, and while waiting the waited tabs
    /// and the countdown.
    private var timer: Timer?
    private var waitStarted: Date?
    private var countdownEnds: Date?
    /// The countdown ended while a sheet, a modal window or a quit's question was up: the update waits for it to close,
    /// then counts down again.
    private var countdownHeld = false
    /// A press's quit, waiting for an operation the update waits for (UpdateHolds).
    private var pendingQuit: UpdateConsent?
    /// Why the last press has not quit yet, shown until the next press.
    private(set) var note: String?

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

    /// Opens the sheet for the staged `version`, planned from the open windows, its box where the user last left it. Shown
    /// again while it is up (the Update button, a check), it comes forward with the plan now and the user's choices kept;
    /// while a wait is under way, the wait panel comes forward instead.
    func show(version: AppVersion, from entry: UpdateFlow.Entry) {
        if var flow, flow.version == version.description {
            if isWaiting {
                panel?.present()
                return
            }
            flow.replan(UpdatePlanning.plan())
            self.flow = flow
            presentSheet()
            return
        }
        guard Self.mayStart else { return }
        // Another version is staged now: what was up for the one before goes, its wait with it.
        if flow != nil { closeAll() }
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
        if flow != nil { closeAll() }
        flow = again
        presentSheet()
        announce("The update was not started: what happens to your tabs changed. Check the update sheet again.")
    }

    // MARK: presses

    func pressed(_ button: UpdateButton) {
        guard var flow else { return }
        note = nil
        pendingQuit = nil
        let effect = flow.press(button)
        self.flow = flow
        apply(effect)
    }

    /// The box, on the sheet or the wait panel: saved where the next sheet's box starts from. That is never consent: the
    /// press, or the countdown's end, reads the box (R28).
    func keepChanged(_ on: Bool) {
        guard var flow else { return }
        flow.setKeep(on)
        self.flow = flow
        if flow.keepEnabled { AppDelegate.shared.launchDefaults.set(flow.keep, forKey: UpdateFlow.rememberKey) }
        render()
    }

    /// "Wait for this", on a busy tab's line.
    func waitedChanged(_ pane: UUID, _ on: Bool) {
        guard var flow else { return }
        flow.setWaited(pane, on)
        self.flow = flow
        render()
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
        guard flow != nil else { return }
        switch effect {
        case .none:
            render()
        case .quit(let consent):
            quit(consent)
        case .close, .endWait:
            closeAll()
        case .startWait:
            closeSheet()
            waitStarted = Date()
            showPanel()
        case .startCountdown:
            closeSheet()
            if waitStarted == nil { waitStarted = Date() }
            showPanel()
            startCountdown(announcing: "Every tab you waited for is done. Updating in 10 seconds.")
        case .showAgain:
            stopWaitClock()
            panel?.close()
            panel = nil
            presentSheet()
            announce("The update was not started: what happens to your tabs changed. Check the update sheet again.")
        }
    }

    /// Quits under the consent, once no operation the update waits for runs (UpdateHolds). Never quietly refused: over a
    /// sheet, a modal window or a quit's question the sheet or the panel stays and says why, and a countdown waits for it
    /// to close, then counts down again; with another version staged since, the sheet shows for that one. A quit the user
    /// then cancels leaves the update staged.
    private func quit(_ consent: UpdateConsent) {
        let running = UpdateHolds.shared.running
        guard running.isEmpty else {
            pendingQuit = consent
            say("The update starts once what you approved has finished: " + running.joined(separator: "; ") + ".")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.pendingQuit == consent else { return }
                self.quit(consent)
            }
            return
        }
        pendingQuit = nil
        if let refusal = Updater.shared.quitRefusal(for: consent) { return refused(refusal) }
        closeAll()
        Updater.shared.quitForUpdate(consent)
    }

    private func refused(_ refusal: UpdateQuitRefusal) {
        guard let flow else { return }
        switch refusal {
        case .dialogOpen:
            if flow.state == .countdown {
                countdownHeld = true
                countdownEnds = nil
            }
            say(flow.heldLine)
        case .otherVersion:
            closeAll()
            Updater.shared.offerStaged()
            if sheet != nil { announce("Another version of the update is ready. Check the update sheet again.") }
        }
    }

    /// Why nothing quit yet, on the sheet or the panel, and for VoiceOver once.
    private func say(_ text: String) {
        guard note != text else { return }
        note = text
        render()
        announce(text)
    }

    private func presentSheet() {
        let sheet = self.sheet ?? UpdateSheetController()
        self.sheet = sheet
        render()
        sheet.present(over: Self.frontWindow)
        startTimer()
    }

    private func showPanel() {
        let panel = self.panel ?? UpdateWaitPanel()
        self.panel = panel
        render()
        panel.present()
        startTimer()
    }

    private func closeSheet() {
        sheet?.close()
        sheet = nil
    }

    private func startCountdown(announcing text: String) {
        countdownHeld = false
        countdownEnds = Date().addingTimeInterval(UpdateFlow.countdown)
        render()
        announce(text)
    }

    /// What is up, drawn from the flow, the open decisions now and the note. Each draws only what changed.
    private func render() {
        guard let flow else { return }
        let decisions = UpdateHolds.shared.openDecisions
        sheet?.render(flow, decisions: decisions, note: note)
        panel?.render(flow, elapsed: elapsed, remaining: remaining, decisions: decisions, note: note)
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { UpdateKeepSessions.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Each second: the open decisions read again; while waiting, the waited tabs read again; in the countdown, the time
    /// counted, and at its end the plan again. A countdown held for a dialog counts down again once it is closed. A quit
    /// pressed already, waiting for what the user approved, holds the rest.
    private func tick() {
        guard var flow else { return stopTimer() }
        guard pendingQuit == nil else { return render() }
        switch flow.state {
        case .idle, .busy:
            render()
        case .waiting:
            let effect = flow.refresh(UpdatePlanning.refreshed(flow.plan))
            self.flow = flow
            apply(effect)
        case .countdown:
            if countdownHeld {
                guard Self.mayStart else { return render() }
                note = nil
                return startCountdown(announcing: "Updating in 10 seconds.")
            }
            guard let ends = countdownEnds, Date() >= ends else { return render() }
            countdownEnds = nil
            let effect = flow.countdownEnded(UpdatePlanning.plan())
            self.flow = flow
            apply(effect)
        }
    }

    private var elapsed: TimeInterval { waitStarted.map { Date().timeIntervalSince($0) } ?? 0 }

    private var remaining: Int? {
        guard let countdownEnds else { return nil }
        return max(0, Int(countdownEnds.timeIntervalSinceNow.rounded(.up)))
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func stopWaitClock() {
        countdownEnds = nil
        countdownHeld = false
        waitStarted = nil
    }

    /// The sheet's close button: as Cancel, unless a wait goes on in the panel.
    func sheetClosed(_ controller: UpdateSheetController) {
        guard sheet === controller else { return }
        sheet = nil
        if !isWaiting { closeAll() }
    }

    private func closeAll() {
        stopTimer()
        stopWaitClock()
        pendingQuit = nil
        note = nil
        sheet?.close()
        sheet = nil
        panel?.close()
        panel = nil
        flow = nil
    }

    /// For VoiceOver: the countdown started, the sheet showed again, or why nothing quit.
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
        // Nothing is staged after the relaunch: one check now brings the Update button back, as the alert says.
        if let outcome = decision.installAlert {
            Updater.shared.checkAgainQuietly()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(name) was not installed"
            alert.informativeText = UpdateFlow.installFailedText(outcome)
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(releasePage(version)) }
        } else if decision.didNotInstallNote {
            Updater.shared.checkAgainQuietly()
            let alert = NSAlert()
            alert.messageText = "\(name) did not install"
            alert.informativeText = UpdateFlow.didNotInstallText
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
        let freed = freedAtQuit(controllers)
        let planned = RestorePlanning.plan(snapshot, kind: .update, safeMode: false, quitConsent: false, freed: freed)
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
                    pane.jobs = pane.busy && !frontBusy(tab)
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

    /// The sessions the update quit frees: those only processes in this Next Term's local tabs hold, such as a tab's own
    /// running claude. The quit hangs up each tab's shell and what runs in it, so after the relaunch these sessions are
    /// free and resume; read now, while their claude still runs, they would read as taken (R14, KTD5).
    private static func freedAtQuit(_ controllers: [TerminalWindowController]) -> Set<String> {
        let shells: [pid_t] = controllers.flatMap(\.tabs).compactMap { (tab: TerminalTab) -> pid_t? in
            guard tab.remote == nil, !tab.exited else { return nil }
            let pid = tab.view.process.shellPid
            return pid > 0 ? pid : nil
        }
        guard !shells.isEmpty else { return [] }
        let holders = AgentSessions.claudeHolders(home: RestorePlanning.agentHome)
        return SessionLookup.freedAtQuit(holders: holders) { (pid: Int32) -> Bool in
            shells.contains { (shell: pid_t) -> Bool in ProcessInspector.descends(pid, from: shell) }
        }
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
                pane.jobs = pane.busy && !frontBusy(tab)
                return pane
            }
        }
        plan.refusal = refusal
        return plan
    }

    /// Busy (R15, KTD16): a local tab with an agent working or waiting on the user, a running command, or a background or
    /// suspended job, which the update stops as ⌘Q's "Quitting stops…" says. A remote tab never is: what tmux or herdr
    /// keeps runs on, and a plain ssh tab only loses its connection.
    static func isBusy(_ tab: TerminalTab) -> Bool {
        guard tab.remote == nil, !tab.exited else { return false }
        return frontBusy(tab) || holdsJobs(tab)
    }

    /// What runs in front keeps the tab busy: a command, or an agent working or waiting on the user.
    private static func frontBusy(_ tab: TerminalTab) -> Bool {
        let status = tab.status
        guard status.running else { return false }
        guard status.kind == .agent else { return true }
        return status.state == .working || status.state == .attention
    }

    /// Background or suspended jobs, as "Quitting stops…" counts them (TerminalTab.closeWarning): the integration's
    /// count, or without it the shell's own child processes while nothing runs in front.
    static func holdsJobs(_ tab: TerminalTab) -> Bool {
        let status = tab.status
        if status.integrated { return status.jobs > 0 }
        return !status.running && !ProcessInspector.childProcessNames(of: tab.view.process.shellPid).isEmpty
    }

    /// Why sessions can't be kept: a translocated copy, or no session saved (no sessions folder, the save gate still
    /// closed, or the last save failed).
    static var refusal: KeepRefusal? {
        if SessionLaunch.isTranslocated(bundlePath: Bundle.main.bundlePath) { return .translocated }
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
/// restart drops. The sheet lists the open decisions, always; the update quit answers each one with a definite no. Agent
/// diff proposals are read from each editor area as they are, without editing it; the agents' approval panels
/// (AgentApprovalWindow: a skill to install or remove, an MCP write) register as they open and are let go as they close.
@MainActor
final class UpdateHolds: NSObject {
    static let shared = UpdateHolds()

    private var decisions: [(id: UUID, title: String, cancel: () -> Void)] = []
    private var operations: [UUID: String] = [:]
    private var panels = OpenPanels<AgentApprovalWindow>()

    /// An approval panel opens (AgentApprovalWindow's `present`): until it closes, the sheet lists it while it asks, the
    /// update quit waits for it once its approved change is under way, and declines it otherwise.
    func register(_ panel: AgentApprovalWindow) {
        guard let window = panel.window, panels.register(panel) else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(panelWillClose(_:)), name: NSWindow.willCloseNotification,
                                               object: window)
    }

    @objc private func panelWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        for panel in panels.all where panel.window === window { panels.unregister(panel) }
    }

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

    /// The operations the update waits for, now: each registered one, and each approved change an approval panel shows
    /// under way.
    var running: [String] {
        let approved: [String] = panels.all.filter { Self.committed($0) }.map { Self.title($0) }
        return Array(operations.values) + approved
    }

    /// The decisions the restart drops: each agent's diff proposal waiting in an editor, each approval panel waiting for
    /// an answer, then each registered one.
    var openDecisions: [String] {
        var lines: [String] = []
        for controller in AppDelegate.shared.controllers {
            for pane in controller.editorArea.proposals {
                guard let proposal = pane.proposal else { continue }
                lines.append(TerminalText.oneLine("\(proposal.author)’s proposed change to \(pane.path)"))
            }
        }
        let asking: [String] = panels.all.filter { !Self.committed($0) }.map { Self.title($0) }
        return lines + asking + decisions.map { TerminalText.oneLine($0.title) }
    }

    /// At the update quit: every open decision answered "no", so its asker gets a definite answer. An approval panel
    /// closed unanswered declines (AgentApprovalWindow's own rule); one whose approved change is under way was waited for.
    func cancelAll() {
        let open = decisions
        decisions = []
        for decision in open { decision.cancel() }
        for panel in panels.all where !Self.committed(panel) { panel.close() }
    }

    /// Its approved change has started and can't be stopped: the panel holds Decline (`setCommitted`).
    private static func committed(_ panel: AgentApprovalWindow) -> Bool {
        panel.declineButton?.isEnabled == false
    }

    private static func title(_ panel: AgentApprovalWindow) -> String {
        TerminalText.oneLine(panel.window?.title ?? "An agent’s request")
    }
}

// MARK: - The sheet

/// The update sheet's window, over the front terminal window without taking the keyboard (as the update window is
/// presented). Its buttons are exposed for the self-test. Drawn again each second, it changes only what changed, so a
/// click or VoiceOver's focus stays where it is; its lists scroll past a few lines, and it is never taller than the screen.
@MainActor
final class UpdateSheetController: NSWindowController, NSWindowDelegate {
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(wrappingLabelWithString: UpdateFlow.subtitle)
    /// The busy tabs, each with "Wait for this".
    let busyList = UpdateListScroll(maxHeight: 132, bordered: false, spacing: 4)
    let keepBox = NSButton(checkboxWithTitle: UpdateFlow.checkboxTitle, target: nil, action: nil)
    let refusalLabel = NSTextField(wrappingLabelWithString: "")
    let summaryLabel = NSTextField(wrappingLabelWithString: "")
    let detailsToggle = NSButton(title: "", target: nil, action: nil)
    let detailsList = UpdateListScroll(maxHeight: 160, bordered: true, insets: NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8))
    let decisionsList = UpdateListScroll(maxHeight: 88, bordered: false)
    /// Notes another feature adds (Remote access stopping), shown under the decisions; none yet.
    let notesStack = NSStackView()
    /// Why the last press has not quit yet (a dialog is open, an approved change finishes).
    let noteLabel = NSTextField(wrappingLabelWithString: "")
    let buttonRow = UpdateButtonRow()
    /// Each busy tab's "Wait for this", by pane.
    private(set) var waitBoxes: [UUID: NSButton] = [:]
    private var busyLines: [UUID: NSTextField] = [:]
    private var busyShown: [UUID] = []
    private var detailsDrawn: [UpdateDetail]?
    private var decisionsShown: [String]?
    private weak var parentWindow: NSWindow?

    var busyStack: NSStackView { busyList.stack }
    var detailsStack: NSStackView { detailsList.stack }
    var decisionsStack: NSStackView { decisionsList.stack }

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
        busyList.isHidden = true
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
        detailsList.isHidden = true
        decisionsList.isHidden = true
        notesStack.orientation = .vertical
        notesStack.alignment = .leading
        notesStack.spacing = 2
        notesStack.isHidden = true
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.isHidden = true
        buttonRow.spacing = 8
        buttonRow.escapeCancels = true

        let stack = NSStackView(views: [titleLabel, subtitleLabel, busyList, keepBox, refusalLabel, summaryLabel, detailsRow,
                                        detailsList, decisionsList, notesStack, noteLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(4, after: keepBox)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        // The checkbox and the buttons stay in view however long the lists get: each scrolls past its height.
        let wide: [NSView] = [subtitleLabel, busyList, refusalLabel, summaryLabel, detailsList, decisionsList, noteLabel, buttonRow]
        for view in wide {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 520).isActive = true
        window?.contentView = stack
        window?.initialFirstResponder = nil
    }

    /// Shows `flow`: the busy tabs first, each with "Wait for this"; the box; the summary; the details; the open decisions;
    /// why the last press has not quit; and the state's buttons, none of them the default.
    func render(_ flow: UpdateFlow, decisions: [String], note: String?) {
        titleLabel.showIfChanged(flow.title)
        var resized = renderBusy(flow)
        let keep: NSControl.StateValue = flow.keep ? .on : .off
        if keepBox.state != keep { keepBox.state = keep }
        if keepBox.isEnabled != flow.keepEnabled { keepBox.isEnabled = flow.keepEnabled }
        let refusal = flow.plan.refusal?.text ?? ""
        if refusalLabel.stringValue != refusal || refusalLabel.isHidden != refusal.isEmpty {
            refusalLabel.stringValue = refusal
            refusalLabel.isHidden = refusal.isEmpty
            resized = true
        }
        summaryLabel.showIfChanged(flow.summary)
        resized = renderDetails(flow.details) || resized
        resized = renderDecisions(decisions) || resized
        if noteLabel.stringValue != (note ?? "") || noteLabel.isHidden != (note == nil) {
            noteLabel.stringValue = note ?? ""
            noteLabel.isHidden = note == nil
            resized = true
        }
        resized = buttonRow.show(flow.buttons) || resized
        if resized { fit() }
    }

    /// The busy tabs, listed first while the sheet is busy: built again only when they change, else their words and boxes.
    private func renderBusy(_ flow: UpdateFlow) -> Bool {
        let busy: [UpdatePane] = flow.state == .busy ? flow.busyPanes : []
        var rebuilt = false
        if busy.map(\.id) != busyShown {
            busyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            waitBoxes = [:]
            busyLines = [:]
            for pane in busy {
                let line = NSTextField(labelWithString: "")
                line.font = .systemFont(ofSize: 12)
                line.lineBreakMode = .byTruncatingTail
                line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let box = NSButton(checkboxWithTitle: "Wait for this", target: self, action: #selector(waitChanged(_:)))
                box.identifier = NSUserInterfaceItemIdentifier(pane.id.uuidString)
                waitBoxes[pane.id] = box
                busyLines[pane.id] = line
                let row = NSStackView(views: [line, NSView(), box])
                row.spacing = 8
                busyStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: busyStack.widthAnchor).isActive = true
            }
            busyShown = busy.map(\.id)
            busyList.isHidden = busy.isEmpty
            rebuilt = true
        }
        for pane in busy {
            let words = flow.line(pane)
            if let line = busyLines[pane.id], line.stringValue != pane.name + ": " + words {
                line.stringValue = pane.name + ": " + words
                line.setAccessibilityLabel(pane.name + ", " + words)
            }
            guard let box = waitBoxes[pane.id] else { continue }
            let state: NSControl.StateValue = flow.waitSet.contains(pane.id) ? .on : .off
            if box.state != state { box.state = state }
            let label = "Wait for \(pane.name)"
            if box.accessibilityLabel() != label { box.setAccessibilityLabel(label) }
        }
        return rebuilt
    }

    private func renderDetails(_ details: [UpdateDetail]) -> Bool {
        guard details != detailsDrawn else { return false }
        detailsDrawn = details
        detailsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for detail in details {
            let line = NSTextField(labelWithString: (detail.changed ? "• " : "") + detail.text)
            line.font = detail.indent == 0 ? .systemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 12)
            line.lineBreakMode = .byTruncatingTail
            line.setAccessibilityLabel(detail.changed ? detail.label + ", changed" : detail.label)
            let indent = NSView()
            indent.widthAnchor.constraint(equalToConstant: CGFloat(detail.indent) * 14).isActive = true
            detailsStack.addArrangedSubview(NSStackView(views: [indent, line]))
        }
        return true
    }

    /// The open decisions the restart drops, read again each second: one asked for after the sheet opened is listed too.
    private func renderDecisions(_ decisions: [String]) -> Bool {
        guard decisions != decisionsShown else { return false }
        decisionsShown = decisions
        decisionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        decisionsList.isHidden = decisions.isEmpty
        guard !decisions.isEmpty else { return true }
        let head = NSTextField(labelWithString: "The restart drops these open decisions:")
        head.font = .systemFont(ofSize: 12, weight: .semibold)
        decisionsStack.addArrangedSubview(head)
        for decision in decisions {
            let line = NSTextField(labelWithString: "• " + decision)
            line.font = .systemFont(ofSize: 12)
            line.lineBreakMode = .byTruncatingTail
            decisionsStack.addArrangedSubview(line)
        }
        return true
    }

    /// The lists at the heights their lines need, the window at its content's, its top edge where it was, and never
    /// taller than the screen: the details give up height first, then the busy tabs, then the decisions.
    private func fit() {
        guard let window, let content = window.contentView else { return }
        let lists: [(list: UpdateListScroll, height: CGFloat)] = [(detailsList, 160), (busyList, 132), (decisionsList, 88)]
        for (list, height) in lists {
            list.maxHeight = height
            list.fit()
        }
        let screen = (window.screen ?? parentWindow?.screen ?? NSScreen.main)?.visibleFrame
        let chrome = window.frame.height - window.contentLayoutRect.height
        if let screen {
            var excess = content.fittingSize.height + chrome + 24 - screen.height
            for (list, _) in lists where excess > 0 && !list.isHidden {
                let cut = min(max(0, list.shownHeight - 44), excess)
                list.maxHeight = list.shownHeight - cut
                list.fit()
                excess -= cut
            }
        }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let screen, window.isVisible { frame.origin.y = min(max(frame.origin.y, screen.minY), screen.maxY - frame.height) }
        window.setFrame(frame, display: window.isVisible)
    }

    /// The button for `kind` in the state shown, for the self-test.
    func button(_ kind: UpdateButton) -> NSButton? { buttonRow.buttons[kind] }

    /// Over `parent` (it moves with it and stays above it until answered), or centred on its own, never taking the
    /// keyboard: someone typing to an agent keeps typing, and a Return meant for the terminal confirms nothing. Shown
    /// already, it comes forward.
    func present(over parent: NSWindow?) {
        guard let window else { return }
        if window.isVisible {
            window.orderFront(nil)
            return
        }
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

    @objc private func keepChanged() {
        UpdateKeepSessions.shared.keepChanged(keepBox.state == .on)
    }

    @objc private func waitChanged(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        UpdateKeepSessions.shared.waitedChanged(id, sender.state == .on)
    }

    @objc private func toggleDetails() {
        detailsList.isHidden = detailsToggle.state != .on
        fit()
    }

    /// The details shown, for the self-test.
    var detailsShown: Bool { !detailsList.isHidden }

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

// MARK: - The wait panel

/// "Wait for Them" (KTD16): the waited tabs with their state, "working" or "needs your answer" with a Show button that
/// brings that tab forward; the time waited, with no automatic timeout; the sheet's box; the open decisions the restart
/// drops; "Update Now" and "Stop Waiting". Once every waited tab is done, "Updating in 10 s" with Cancel. It never takes
/// the keyboard. Drawn again each second, it changes only what changed, so a click or VoiceOver's focus stays put.
@MainActor
final class UpdateWaitPanel: NSWindowController, NSWindowDelegate {
    let titleLabel = NSTextField(labelWithString: "")
    let tabsStack = NSStackView()
    let timeLabel = NSTextField(labelWithString: "")
    /// The sheet's box, the same in every state: the consent reads it at the press or the countdown's end.
    let keepBox = NSButton(checkboxWithTitle: UpdateFlow.checkboxTitle, target: nil, action: nil)
    let decisionsList = UpdateListScroll(maxHeight: 88, bordered: false)
    /// Why the update has not quit yet.
    let noteLabel = NSTextField(wrappingLabelWithString: "")
    let buttonRow = UpdateButtonRow()
    /// Each "Show", by pane.
    private(set) var showButtons: [UUID: NSButton] = [:]
    /// The rows shown, by pane, and whether each asks: built again only when these change.
    private var rowsShown: [(id: UUID, asks: Bool)] = []
    private var rowLines: [UUID: NSTextField] = [:]
    private var decisionsShown: [String]?

    var decisionsStack: NSStackView { decisionsList.stack }

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
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
        keepBox.target = self
        keepBox.action = #selector(keepChanged)
        decisionsList.isHidden = true
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.isHidden = true
        buttonRow.spacing = 8
        let stack = NSStackView(views: [titleLabel, tabsStack, timeLabel, keepBox, decisionsList, noteLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for view in [decisionsList, noteLabel, buttonRow] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 420).isActive = true
        window?.contentView = stack
    }

    func render(_ flow: UpdateFlow, elapsed: TimeInterval, remaining: Int?, decisions: [String], note: String?) {
        let counting = flow.state == .countdown
        titleLabel.showIfChanged(counting ? "Updating in \(remaining ?? Int(UpdateFlow.countdown)) s"
            : "Waiting to update to \(flow.version)")
        var resized = renderTabs(flow, counting: counting)
        let seconds = Int(elapsed)
        timeLabel.showIfChanged(String(format: "Waiting %d:%02d", seconds / 60, seconds % 60))
        if timeLabel.isHidden != counting {
            timeLabel.isHidden = counting
            resized = true
        }
        let keep: NSControl.StateValue = flow.keep ? .on : .off
        if keepBox.state != keep { keepBox.state = keep }
        if keepBox.isEnabled != flow.keepEnabled { keepBox.isEnabled = flow.keepEnabled }
        resized = renderDecisions(decisions) || resized
        if noteLabel.stringValue != (note ?? "") || noteLabel.isHidden != (note == nil) {
            noteLabel.stringValue = note ?? ""
            noteLabel.isHidden = note == nil
            resized = true
        }
        resized = buttonRow.show(flow.buttons) || resized
        if resized, let window, let content = window.contentView {
            // Its top edge stays where it is: the panel sits at the top of the screen.
            decisionsList.fit()
            let top = window.frame.maxY
            window.setContentSize(content.fittingSize)
            if window.isVisible { window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top)) }
        }
    }

    /// The waited tabs, each with its state: built again only when the tabs, or which of them ask, change.
    private func renderTabs(_ flow: UpdateFlow, counting: Bool) -> Bool {
        var tabs: [UUID: TerminalTab] = [:]
        for tab in AppDelegate.shared.controllers.flatMap(\.tabs) { tabs[tab.id] = tab }
        let waited: [UpdatePane] = counting ? [] : flow.plan.panes.filter { flow.waitSet.contains($0.id) }
        let rows: [(pane: UpdatePane, asks: Bool, state: String)] = waited.map {
            (pane: UpdatePane) -> (pane: UpdatePane, asks: Bool, state: String) in
            let tab = tabs[pane.id]
            let asks = tab?.status.state == .attention
            return (pane, asks, asks ? "needs your answer" : Self.state(of: tab))
        }
        var rebuilt = false
        let shape = rows.map { (id: $0.pane.id, asks: $0.asks) }
        if !shape.elementsEqual(rowsShown, by: { $0.id == $1.id && $0.asks == $1.asks }) {
            tabsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            showButtons = [:]
            rowLines = [:]
            for row in rows {
                let line = NSTextField(labelWithString: "")
                line.font = .systemFont(ofSize: 12)
                line.lineBreakMode = .byTruncatingTail
                rowLines[row.pane.id] = line
                var views: [NSView] = [line]
                if row.asks {
                    let show = NSButton(title: "Show", target: self, action: #selector(showTab(_:)))
                    show.bezelStyle = .rounded
                    show.controlSize = .small
                    show.identifier = NSUserInterfaceItemIdentifier(row.pane.id.uuidString)
                    show.setAccessibilityLabel("Show \(row.pane.name)")
                    showButtons[row.pane.id] = show
                    views.append(show)
                }
                let stack = NSStackView(views: views)
                stack.spacing = 8
                tabsStack.addArrangedSubview(stack)
            }
            rowsShown = shape
            rebuilt = true
        }
        for row in rows { rowLines[row.pane.id]?.showIfChanged(row.pane.name + ": " + row.state) }
        if tabsStack.isHidden != rows.isEmpty {
            tabsStack.isHidden = rows.isEmpty
            rebuilt = true
        }
        return rebuilt
    }

    /// A waited tab that does not ask: "working", or, when only its jobs keep it busy, what they are doing.
    private static func state(of tab: TerminalTab?) -> String {
        guard let status = tab?.status, !status.running, status.jobs > 0 else { return "working" }
        return status.jobSummary.contains("(running)") ? "a job runs in the background" : "a job is suspended"
    }

    private func renderDecisions(_ decisions: [String]) -> Bool {
        guard decisions != decisionsShown else { return false }
        decisionsShown = decisions
        decisionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        decisionsList.isHidden = decisions.isEmpty
        guard !decisions.isEmpty else { return true }
        let head = NSTextField(labelWithString: "The restart drops these open decisions:")
        head.font = .systemFont(ofSize: 12, weight: .semibold)
        decisionsStack.addArrangedSubview(head)
        for decision in decisions {
            let line = NSTextField(labelWithString: "• " + decision)
            line.font = .systemFont(ofSize: 12)
            line.lineBreakMode = .byTruncatingTail
            decisionsStack.addArrangedSubview(line)
        }
        return true
    }

    func button(_ kind: UpdateButton) -> NSButton? { buttonRow.buttons[kind] }

    /// In front, at the top right of the screen, without taking the keyboard.
    func present() {
        guard let window else { return }
        if !window.isVisible, let screen = (NSApp.mainWindow?.screen ?? NSScreen.main)?.visibleFrame {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 20, y: screen.maxY - size.height - 20))
        }
        window.orderFront(nil)
    }

    @objc private func keepChanged() {
        UpdateKeepSessions.shared.keepChanged(keepBox.state == .on)
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
