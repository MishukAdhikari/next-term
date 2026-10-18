import AppKit
import NextTermCore
import SwiftTerm

/// One tab's side of suggestions while typing: its line's state (GhostState), the overlay (GhostTextView), the record's
/// answers and their checks.
///
/// Each report of the line from the ghost hook goes to the state with the gates as they are now. A new line asks the record
/// (CommandHistoryStore, off the main thread), and the first candidate that passes the checks (GhostValidation, on another
/// queue, two at a time at most, given 150 ms) shows if the line is still the one asked for. The overlay is placed only once
/// the shell's redraw is on screen: on the output after the report, or on the next turn of the main queue, once the cells
/// left of the cursor end with the line; not within 50 ms, it hides. Output that moves the cursor after that hides it until
/// the next report, and so do a resize, a scroll back, marked text, a paste, a selection and the window going to the back.
///
/// Where zsh-autosuggestions draws its own (GhostOwner), none of Next Term's show until the user chooses: a notice in the
/// tab asks once, at an idle prompt. Next Term's chosen, the hook turns the plugin's off in this shell (an `o` frame, sent
/// only at an idle line, so nothing typed ahead can read it); the plugin's chosen again, it gives them back.
final class GhostSession {
    /// How long a suggestion's checks may take; one later shows nothing.
    static let checkDeadline: TimeInterval = 0.15
    /// How long a placement waits for the shell's redraw to be on screen.
    static let redrawWait: TimeInterval = 0.05
    /// Checks of a tab's that may run at once.
    static let maxChecks = 2
    /// How long the first-use hint stays, unless its line ends first.
    static let hintTime: TimeInterval = 8

    private(set) weak var tab: TerminalTab?
    private(set) var state = GhostState()
    /// The hook's last `ghost` mark: whether zsh-autosuggestions draws suggestions in this shell.
    private(set) var hook: GhostProtocol.Hook?
    /// Since when a suggestion waits to be placed (the shell's redraw), and where it went (the cursor's cell).
    private var placing: TimeInterval?
    private var placed: (x: Int, y: Int)?
    private var checks = 0
    /// The newest candidates waiting for a check, while two are out.
    private var waiting: (gen: Int, candidates: [CommandHistory.Entry], folder: String, fromShell: Bool)?
    /// When to ask the shell's own history (the cold start).
    private var fallback = GhostFallback()
    /// A bracketed paste runs on in what is written to the shell: its Return is text, not a key.
    private var inPaste = false
    /// The command that usually follows yours just ended, checked, waiting for the empty line after `afterLine`.
    private var nextCommand: (afterLine: Int, command: String)?
    /// When the last report was read: the perf budget's start.
    private var arrival: TimeInterval = 0
    private var resignObserver: NSObjectProtocol?
    private weak var observedWindow: NSWindow?

    /// For the self-test: asks of the record, and suggestions placed.
    private(set) var asks = 0
    private(set) var shows = 0

    /// The hook turned zsh-autosuggestions' suggestions off in this shell (at its start, or by an `o` frame), so it may give
    /// them back.
    private(set) var tookOver = false
    /// A take-over (true) or a give-back (false) waiting for an idle line.
    private var pendingOwner: Bool?
    /// When a command last ended here, and when a key of yours last came: the question waits for an idle prompt.
    private var endedAt: TimeInterval?
    private var keyAt: TimeInterval = 0
    /// The question was asked in this tab this launch.
    private var asked = false
    /// The notice showing in the tab, and the plugin it asks about.
    private(set) var notice: GhostNotice?
    private var noticePlugin: GhostOwner.Plugin?
    /// The first-use hint showing in the tab, and the line it came on.
    private(set) var hint: GhostNotice?
    private var hintLine: Int?
    /// What VoiceOver hears, and when (GhostAnnouncer).
    private var announcer = GhostAnnouncer()
    /// For the self-test: announcements made.
    private(set) var announcements = 0

    init(tab: TerminalTab) {
        self.tab = tab
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    private(set) lazy var overlay: GhostTextView = {
        let overlay = GhostTextView(frame: .zero)
        // SwiftTerm draws its rows from the top of the (unflipped) view: a height change within a row's keeps it on its row.
        overlay.autoresizingMask = [.minYMargin]
        tab?.view.addSubview(overlay, positioned: .below, relativeTo: nil)
        return overlay
    }()

    /// The overlay shows a suggestion now.
    var isShowing: Bool { state.shown != nil && placing == nil && overlayMade && !overlay.isHidden }
    private var overlayMade = false

    // MARK: the shell's marks

    func handle(_ message: GhostProtocol.Message) {
        switch message {
        case .hook(let hook):
            // The first mark of a shell told to take over: the plugin is off because Next Term asked.
            if self.hook == nil, !hook.enabled, let plugin = GhostOwner.loaded(hook), let start = tab?.ghostStart {
                tookOver = start.contains(plugin == .atuin ? "a" : "t")
            }
            self.hook = hook
            sync()
        case .buffer(let report):
            arrival = TerminalTab.now
            // The hint's line ended (^C, Return): it goes.
            if let hintLine, report.line != hintLine { hideHint() }
            follow(state.report(report, gates: gates()))
            if nextCommand != nil { offerNext() }
            sendOwnerIfIdle()
            considerAsking(report)
        case .fallback(let gen, let line):
            shellAnswered(gen, line)
        }
    }

    private func follow(_ step: GhostState.Step) {
        switch step {
        case .ask(let gen, let prefix):
            hideOverlay()
            ask(gen, prefix)
        case .trimmed:
            announcer.typed(at: TerminalTab.now)
            placeAfterRedraw()
        case .hidden:
            hideOverlay()
        case .none:
            break
        }
    }

    /// The record, for the newest commands starting with `prefix` from the tab's folder; then the checks.
    private func ask(_ gen: Int, _ prefix: String) {
        guard let tab else { return }
        asks += 1
        let folder = tab.directory
        CommandHistoryStore.shared.query(prefix: prefix, folder: folder) { [weak self] candidates in
            self?.answered(gen, candidates, folder: folder)
        }
    }

    private func answered(_ gen: Int, _ candidates: [CommandHistory.Entry], folder: String) {
        guard state.asked == gen else { return }
        guard !candidates.isEmpty else { return askShellSoon(gen) }
        check(gen, candidates, folder: folder)
    }

    /// The checks for generation `gen`'s candidates, on a queue of their own. With two of the tab's out already (a folder
    /// on a slow volume), the newest waits for one of them to finish, and replaces any older one waiting. A line from the
    /// shell's own history (`fromShell`) must be one the record would keep: no secret, no leading space, one line.
    private func check(_ gen: Int, _ candidates: [CommandHistory.Entry], folder: String, fromShell: Bool = false) {
        guard checks < Self.maxChecks else {
            waiting = (gen, candidates, folder, fromShell)
            return
        }
        checks += 1
        let started = TerminalTab.now
        let home = NSHomeDirectory()
        DispatchQueue.global(qos: .userInitiated).async {
            let mayShow: (String) -> Bool = fromShell ? { CommandHistory.keeps($0) } : { CommandSecrets.mayKeep($0) }
            let chosen = GhostValidation.first(candidates, cwd: folder, home: home, probe: .disk, mayShow: mayShow)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.checked(gen, chosen, late: TerminalTab.now - started > Self.checkDeadline, fromShell: fromShell)
            }
        }
    }

    private func checked(_ gen: Int, _ chosen: CommandHistory.Entry?, late: Bool, fromShell: Bool) {
        checks -= 1
        if let next = waiting {
            waiting = nil
            if state.asked == next.gen { check(next.gen, next.candidates, folder: next.folder, fromShell: next.fromShell) }
        }
        // None of the record's passed: the shell's own history may have one.
        if chosen == nil, !late, !fromShell, state.asked == gen { return askShellSoon(gen) }
        guard !late, let chosen, state.answer(gen: gen, command: chosen.line) else { return }
        announcer.suggested(chosen.line, at: TerminalTab.now)
        placeAfterRedraw()
    }

    // MARK: the shell's own history (the cold start)

    /// The record had nothing that passes for generation `gen`'s line: at a pause (no key for GhostFallback.idle), zsh's
    /// own in-memory history is asked, at an idle line, never again for a prefix it had nothing for or a line grown from
    /// one.
    private func askShellSoon(_ gen: Int) {
        let wait = max(0, keyAt + GhostFallback.idle - TerminalTab.now)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.01) { [weak self] in self?.askShell(gen) }
    }

    private func askShell(_ gen: Int) {
        guard let tab, state.asked == gen, let report = state.report, report.gen == gen, let prefix = report.buffer,
              TerminalTab.now - keyAt >= GhostFallback.idle, tab.lineReportIsCurrent, gates().open,
              let frame = GhostProtocol.fallbackFrame(gen: gen, prefix: prefix),
              fallback.shouldAsk(line: report.line, gen: gen, prefix: prefix) else { return }
        // Not typed: past Tab completion's writer, which holds nothing at an idle line, so the report stays current.
        tab.view.sendPastGate(frame[...])
    }

    /// The shell's answer: a line it holds that starts with what is typed, checked as the record's are (and never one you
    /// forgot) before it shows; one the record has is checked with how its runs went there (never one that never
    /// succeeded, or last exited 127). Nothing of it is recorded.
    private func shellAnswered(_ gen: Int, _ answer: String?) {
        guard let line = fallback.answer(gen: gen, line: answer), state.asked == gen, let folder = tab?.directory else { return }
        CommandHistoryStore.shared.facts(about: line) { [weak self] forgotten, known in
            guard let self, !forgotten, self.state.asked == gen else { return }
            self.check(gen, [known ?? CommandHistory.Entry(line: line, lastRun: 0)], folder: folder, fromShell: true)
        }
    }

    // MARK: placing it

    /// The overlay goes where the shell's redraw put the cursor, once it is on screen.
    private func placeAfterRedraw() {
        let started = TerminalTab.now
        placing = started
        DispatchQueue.main.async { [weak self] in self?.place(late: false) }
        // This placement's wait only: a newer one has its own.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.redrawWait) { [weak self] in
            guard let self, self.placing == started else { return }
            self.place(late: true)
        }
    }

    /// Places the suggestion when the cells left of the cursor end with the line's last 16 characters; past the wait, it
    /// hides.
    private func place(late: Bool) {
        guard let started = placing else { return }
        guard let shown = state.shown, let buffer = state.report?.buffer, let tab, gates().open else {
            placing = nil
            state.hide()
            return hideOverlay()
        }
        // An empty line has nothing to match: its prompt, drawn, says the redraw is on screen.
        let drawn = { (left: String) -> Bool in
            buffer.isEmpty ? left.contains { $0 != " " } : left.hasSuffix(String(buffer.suffix(16)))
        }
        guard let left = tab.lineLeftOfCursor(), drawn(left) else {
            if late || TerminalTab.now - started >= Self.redrawWait {
                placing = nil
                state.hide()
                hideOverlay()
            }
            return
        }
        placing = nil
        draw(shown, in: tab.view)
        announceWhenDue()
    }

    /// Draws the suggestion at the cursor; `fresh`, it was just placed (not drawn again in a new style): the perf
    /// budget's stamp, and the first-use hint.
    private func draw(_ shown: GhostSuggestion, in view: NextTermView, fresh: Bool = true) {
        let terminal = view.getTerminal()
        let cursor = terminal.getCursorLocation()
        let available = rightEdge(of: terminal, row: cursor.y, after: cursor.x) - cursor.x - 1
        guard let text = GhostClip.fit(shown.remainder, available: available) else {
            state.hide()
            return hideOverlay()
        }
        let cell = view.cellSize
        let origin = CGPoint(x: CGFloat(cursor.x) * cell.width, y: view.bounds.height - cell.height * CGFloat(cursor.y + 1))
        let workspace = NSWorkspace.shared
        overlayMade = true
        overlay.show(text, at: origin, cell: cell, font: view.font, colour: Self.colour(for: view),
                     underline: workspace.accessibilityDisplayShouldDifferentiateWithoutColor)
        placed = (cursor.x, cursor.y)
        watch(view.window)
        _ = Self.displayOptions
        guard fresh else { return }
        shows += 1
        overlay.ghostShown(arrival)
        showHintIfDue()
    }

    // MARK: VoiceOver

    #if DEBUG
    /// The self-test's word on whether VoiceOver is on.
    nonisolated(unsafe) static var testVoiceOver: Bool?
    #endif

    static var voiceOverOn: Bool {
        #if DEBUG
        if let testVoiceOver { return testVoiceOver }
        #endif
        return NSWorkspace.shared.isVoiceOverEnabled
    }

    /// While VoiceOver is on: a new suggestion is said once, quietly, half a second after typing stops, in the words
    /// Settings chose (GhostAnnouncer). The line VoiceOver reads never holds it.
    private func announceWhenDue() {
        guard Self.voiceOverOn, let due = announcer.dueAt else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due - TerminalTab.now) + 0.01) { [weak self] in self?.announce() }
    }

    private func announce() {
        guard isShowing, let text = announcer.due(at: TerminalTab.now, words: GhostPreferences.voiceOverWords) else {
            return announceWhenDue() // typing went on: later, if it still shows
        }
        announcements += 1
        let element: Any = tab?.view.window ?? NSApp as Any
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.low.rawValue])
    }

    /// The first-use hint, on the first two lines a suggestion shows on (across launches): the keys, and Turn Off, which
    /// turns suggestions off. It goes when its line ends, or after `hintTime`.
    private func showHintIfDue() {
        guard let line = state.report?.line, hintLine != line, hint == nil, notice == nil,
              GhostPreferences.hintsShown < GhostPreferences.hintLines, let view = tab?.view else { return }
        hintLine = line
        GhostPreferences.hintsShown += 1
        let hint = GhostNotice("→ accepts · Esc hides", buttons: [("Turn Off", { GhostPreferences.set(false) })],
                               closeLabel: "Close") { [weak self] in self?.hideHint() }
        hint.setAccessibilityLabel("Suggestion while typing: → accepts it, Esc hides it")
        hint.show(in: view)
        self.hint = hint
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hintTime) { [weak self, weak hint] in
            guard let self, let hint, self.hint === hint else { return }
            self.hideHint()
        }
    }

    private func hideHint() {
        hint?.removeFromSuperview()
        hint = nil
    }

    /// The first column right of the cursor with something drawn in it (a right prompt), or the row's end.
    private func rightEdge(of terminal: Terminal, row: Int, after column: Int) -> Int {
        guard let line = terminal.getLine(row: row) else { return terminal.cols }
        let end = min(terminal.cols, line.count)
        var x = column + 1
        while x < end {
            let character = line[x].getCharacter()
            if character != "\u{0}", character != " " { return x }
            x += 1
        }
        return terminal.cols
    }

    /// The suggestion's colour for the terminal's theme (GhostColour), made again only when the theme or Increase Contrast
    /// changed.
    private static var colourCache: (foreground: NSColor, background: NSColor, increase: Bool, colour: NSColor)?

    static func colour(for view: TerminalView) -> NSColor {
        let increase = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let foreground = view.nativeForegroundColor, background = view.nativeBackgroundColor
        if let cache = colourCache, cache.foreground === foreground, cache.background === background, cache.increase == increase {
            return cache.colour
        }
        let derived = GhostColour.derive(foreground: rgb(foreground), background: rgb(background), increaseContrast: increase)
        let colour = NSColor(hex: derived)
        colourCache = (foreground, background, increase, colour)
        return colour
    }

    static func rgb(_ colour: NSColor) -> UInt32 {
        guard let srgb = colour.usingColorSpace(.sRGB) else { return 0x808080 }
        func channel(_ value: CGFloat) -> UInt32 { UInt32(max(0, min(255, (value * 255).rounded()))) }
        return channel(srgb.redComponent) << 16 | channel(srgb.greenComponent) << 8 | channel(srgb.blueComponent)
    }

    /// Increase Contrast or Differentiate Without Colour turned on or off: a suggestion showing is drawn again at once, in its
    /// new colour and with or without its underline. Watched from the first suggestion drawn.
    private static let displayOptions: NSObjectProtocol = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            for controller in AppDelegate.shared?.controllers ?? [] {
                for tab in controller.tabs { tab.ghost.restyle() }
            }
        }

    /// The suggestion showing, drawn again where it is (the display options changed).
    private func restyle() {
        guard isShowing, let shown = state.shown, let view = tab?.view else { return }
        draw(shown, in: view, fresh: false)
    }

    /// The window going to the back hides the suggestion at once.
    private func watch(_ window: NSWindow?) {
        guard let window, window !== observedWindow else { return }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        observedWindow = window
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                queue: .main) { [weak self] _ in self?.hide() }
    }

    private func hideOverlay() {
        placed = nil
        announcer.hidden()
        if overlayMade { overlay.hide() }
    }

    // MARK: forgetting one

    /// Edit › Forget This Suggestion, or the terminal's menu: the command showing leaves the record, and its log at once,
    /// and its hash is kept, so the shell's own history, which holds it too, never suggests it again; the next match, if
    /// one passes the checks, shows instead. False: none shows.
    @discardableResult
    func forget() -> Bool {
        guard isShowing, let shown = state.shown, let report = state.report else { return false }
        // In this order on the record's queue, before the ask that follows.
        CommandHistoryStore.shared.forget(shown.command)
        CommandHistoryStore.shared.forgetFallback(shown.command)
        hide()
        follow(state.report(report, gates: gates()))
        return true
    }

    // MARK: keys (GhostController)

    /// A key that takes the suggestion showing, or Esc: true, taken, so SwiftTerm never sees it. An accept goes to the
    /// hook as a frame (GhostState.accept) through the tab's ordered writer, with the bytes the key sends otherwise,
    /// which the hook gives back to zsh where the line or the key's binding changed. Esc hides the suggestion for the
    /// rest of the line, and goes on to zsh in vi insert mode.
    func press(_ key: GhostKeys.Key) -> Bool {
        guard isShowing, let view = tab?.view else { return false }
        if key == .escape {
            let goesOn = state.escapeGoesOn
            state.escape()
            hideOverlay()
            return !goesOn
        }
        let terminal = view.getTerminal()
        let bytes = GhostKeys.bytes(key, applicationCursor: terminal.applicationCursor, optionAsMeta: view.optionAsMetaKey)
        guard let frame = state.accept(key, bytes: bytes) else { return false }
        placing = nil
        hideOverlay()
        view.send(data: frame[...])
        return true
    }

    // MARK: what the tab says

    /// The facts the state needs besides the line: the cheap ones first, the shell's process group last.
    private func gates() -> GhostGates {
        guard let tab, GhostPreferences.isOn, !GhostPreferences.privateMode else { return GhostGates(on: false) }
        let view = tab.view
        let window = view.window
        var gates = GhostGates()
        gates.viewReady = (!view.canScroll || view.scrollPosition >= 1) && !view.hasMarkedText()
        gates.noTabList = !tab.completion.isListOpen && tab.completion.state.pendingID == nil
        gates.focused = window?.isKeyWindow == true && window?.firstResponder === view && !view.awaitsChoice
        gates.notDriven = !MCPControl.isDriven(tab)
        // Where zsh-autosuggestions draws its own (the hook says it is on), none of Next Term's; a plugin's ghost on the line
        // keeps them off too (GhostState).
        gates.noPlugin = GhostOwner.owner(hook: hook, report: nil) == nil
        guard gates.open else { return gates }
        let terminal = view.getTerminal()
        gates.shellAlone = tab.remote == nil && !tab.status.running && !terminal.isCurrentBufferAlternate && tab.shellAlone
        return gates
    }

    /// Who shows suggestions in this tab, for its tooltip; nil where none can (a server, a shell without the hook).
    var label: String? {
        guard tab?.remote == nil, hook != nil else { return nil }
        guard GhostPreferences.isOn else { return "Suggestions: off" }
        if GhostPreferences.privateMode { return "Suggestions: off (Private Mode)" }
        guard let owner = GhostOwner.owner(hook: hook, report: state.report) else { return "Suggestions: Next Term’s" }
        let chosen = owner.canTakeOver && GhostPreferences.choice(for: owner) == .plugin
        return "Suggestions: \(owner.label)" + (chosen ? ", your choice" : "")
    }

    // MARK: a plugin that draws its own

    /// Follows the choice for this shell's plugin: Next Term's (and suggestions on), the plugin's go off where they are on;
    /// anything else, they come back where the hook turned them off. A notice answered elsewhere goes.
    func sync() {
        if !GhostPreferences.isOn || GhostPreferences.privateMode {
            hide()
            hideHint()
        }
        if let plugin = noticePlugin, GhostPreferences.answer(for: plugin) != .ask || !GhostPreferences.isOn { hideNotice() }
        pendingOwner = nil
        guard tab?.remote == nil, let hook, let plugin = GhostOwner.loaded(hook) else { return }
        let wanted = GhostPreferences.isOn && GhostPreferences.answer(for: plugin) == .nextTerm
        // Once a shell: one the user turned back on by hand keeps it.
        if wanted, hook.enabled, !tookOver { pendingOwner = true }
        if !wanted, tookOver { pendingOwner = false }
        sendOwnerIfIdle()
    }

    /// A choice was made or asked again, or suggestions went on or off: every tab follows it.
    static func syncAll() {
        for controller in AppDelegate.shared?.controllers ?? [] {
            for tab in controller.tabs {
                tab.ghost.sync()
                tab.delegate?.tabDidChange(tab)
            }
        }
    }

    /// The `o` frame waiting, sent once the line is idle: the shell has the terminal, and nothing was written since its
    /// last report, so what is sent can only reach the line editor.
    private func sendOwnerIfIdle() {
        guard let takeOver = pendingOwner, let tab, tab.lineReportIsCurrent else { return }
        pendingOwner = nil
        tookOver = takeOver
        // Not typed: past Tab completion's writer, which holds nothing at an idle line.
        tab.view.sendPastGate(GhostProtocol.ownerFrame(takeOver: takeOver)[...])
    }

    /// The question, once a launch in this tab, at an idle prompt: an empty line after a command ended here, no key of
    /// yours for a second (it waits for one), the tab neither driven by an agent nor waiting to be chosen.
    private func considerAsking(_ report: GhostProtocol.BufferReport) {
        guard mayAsk(on: report, sinceKey: .infinity) else { return }
        let wait = max(0, keyAt + GhostOwner.quietAfterKey - TerminalTab.now)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.05) { [weak self] in
            guard let self, let now = self.state.report, now.line == report.line,
                  self.mayAsk(on: now, sinceKey: TerminalTab.now - self.keyAt) else { return }
            self.askAbout(GhostOwner.owner(hook: self.hook, report: now))
        }
    }

    private func mayAsk(on report: GhostProtocol.BufferReport, sinceKey: TimeInterval) -> Bool {
        guard let plugin = GhostOwner.owner(hook: hook, report: report), notice == nil, GhostPreferences.isOn,
              let tab, tab.remote == nil, !tab.view.awaitsChoice, !MCPControl.isDriven(tab) else { return false }
        return GhostOwner.mayAsk(answer: GhostPreferences.answer(for: plugin), askedBefore: asked, lineEmpty: report.buffer == "",
                                 afterCommand: endedAt != nil, sinceKey: sinceKey)
    }

    private func askAbout(_ plugin: GhostOwner.Plugin?) {
        guard let plugin, let view = tab?.view, notice == nil else { return }
        asked = true
        let notice = GhostNotice(Self.question(plugin), buttons: [
            ("Use Next Term’s", { [weak self] in self?.noticeAnswered(plugin, .nextTerm) }),
            ("Keep \(plugin.name)", { [weak self] in self?.noticeAnswered(plugin, .plugin) }),
        ], closeLabel: "Not Now") { [weak self] in self?.noticeAnswered(plugin, nil) }
        notice.show(in: view)
        self.notice = notice
        noticePlugin = plugin
    }

    /// What the notice says, in the words Tab completion's question uses.
    static func question(_ plugin: GhostOwner.Plugin) -> String {
        let shows = plugin == .atuin ? "show" : "shows"
        return "\(plugin.name) \(shows) suggestions in this shell. Next Term can show its own instead, over the terminal, in its tabs"
            + " only: your files stay as they are. Settings › Terminal changes it."
    }

    /// The notice answered: a choice (nil: Not Now). Every tab follows it.
    private func noticeAnswered(_ plugin: GhostOwner.Plugin, _ choice: PluginChoice?) {
        hideNotice()
        if let choice { GhostPreferences.choose(choice, for: plugin) } else { GhostPreferences.dismissed(plugin) }
        Self.syncAll()
    }

    private func hideNotice() {
        notice?.removeFromSuperview()
        notice = nil
        noticePlugin = nil
    }

    /// A command ended in this tab: the next empty line is an idle prompt. When it was yours (`yours`, recorded), the
    /// record is asked what usually follows it, and that is checked as any suggestion is, for the empty line: within
    /// `checkDeadline`, and only while no later command has ended.
    func commandEnded(yours line: String?) {
        let ended = TerminalTab.now
        endedAt = ended
        nextCommand = nil
        guard let line, let folder = tab?.directory else { return }
        let after = state.report?.line ?? 0
        CommandHistoryStore.shared.next(after: line) { [weak self] next in
            guard let next else { return }
            let home = NSHomeDirectory()
            let started = TerminalTab.now
            DispatchQueue.global(qos: .userInitiated).async {
                let passed = GhostValidation.first([next], cwd: folder, home: home, probe: .disk) != nil
                DispatchQueue.main.async { [weak self] in
                    let late = TerminalTab.now - started > Self.checkDeadline
                    // Only the last command's end, checked in time.
                    guard let self, passed, !late, self.endedAt == ended else { return }
                    self.nextCommand = (after, next.line)
                    self.offerNext()
                }
            }
        }
    }

    /// The next command, on the empty line after the command it follows (now, or once the shell reports that line).
    private func offerNext() {
        guard let next = nextCommand, let report = state.report, report.line != next.afterLine else { return }
        nextCommand = nil
        guard report.buffer == "", state.offerNext(next.command, gates: gates()) else { return }
        announcer.suggested(next.command, at: TerminalTab.now)
        placeAfterRedraw()
    }

    // MARK: what happened in the tab

    /// Output reached the terminal: a placement waiting for the shell's redraw looks again; a suggestion placed hides when
    /// the cursor moved since.
    func output() {
        if placing != nil { return place(late: false) }
        guard let placed, let view = tab?.view else { return }
        let terminal = view.getTerminal()
        let cursor = terminal.getCursorLocation()
        if cursor.x != placed.x || cursor.y != placed.y || terminal.isCurrentBufferAlternate { hide() }
    }

    /// A key of yours in the tab (or a paste, a drop): suggestions may show on this line.
    func userKey() {
        keyAt = TerminalTab.now
        state.userKey()
    }

    /// Bytes on their way to the shell: one that ends the line (Return, ^C, ^D, ^Z, as Readiness reads them) hides the
    /// suggestion at once, so no key after it can send a frame that only the next program would read. An accept frame's
    /// payload is escaped, so it never ends one.
    func written(_ data: ArraySlice<UInt8>) {
        guard InputScan.scan(data, inPaste: &inPaste).disarms else { return }
        hide()
    }

    /// Hidden until the next report: a resize, a font change, a scroll back, marked text, a paste, a selection, the window
    /// going to the back, the keyboard going elsewhere, a line ending.
    func hide() {
        placing = nil
        state.hide()
        hideOverlay()
    }

    func viewChanged() { hide() }

    /// The view scrolled: hidden unless it is at the bottom.
    func scrolled() {
        guard let view = tab?.view, view.canScroll, view.scrollPosition < 1 else { return }
        hide()
    }

    /// A command started, or the line ended otherwise: nothing shows until the next line. A notice not answered goes, as
    /// you went on without it.
    func lineEnded() {
        placing = nil
        inPaste = false
        nextCommand = nil
        state.lineEnded()
        hideOverlay()
        hideNotice()
        hideHint()
    }

    /// The shell was replaced (`exec zsh`): the new one says what it is, and started with nothing taken over.
    func shellReplaced() {
        placing = nil
        inPaste = false
        state = GhostState()
        hook = nil
        tookOver = false
        pendingOwner = nil
        endedAt = nil
        nextCommand = nil
        hideOverlay()
        hideNotice()
        hideHint()
    }
}

extension GhostValidation.FileProbe {
    /// The disk, by `stat` and `access`: nothing is opened or run.
    static let disk = GhostValidation.FileProbe(
        exists: { path in
            var info = stat()
            return stat(path, &info) == 0
        },
        isFolder: { path in
            var info = stat()
            return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        },
        isExecutable: { path in
            var info = stat()
            return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
        })
}
