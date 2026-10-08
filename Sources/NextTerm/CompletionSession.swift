import AppKit
import NextTermCore

/// One tab's side of Tab completion: its CompletionState, the list it shows, the private keys it sends, and the
/// one ordered writer to the shell. While an answer is owed, every write (the user's keys, an agent's text
/// over MCP) waits and then goes out in order, after the answer: at most 120 ms.
///
/// Next Term's own engine answers a `tab` report within 120 ms: no candidate is "native" (zsh's own Tab), one is
/// "insert", more is "open", and the list shows at the first `line` for that id. On zsh's path no answer is
/// ever sent: zsh's matches come in `comp` marks, with a Loading row if they take over 150 ms.
///
/// A server tab whose shell has no hook takes a path of its own (RemoteCompletion): the word is read off the
/// screen once the keys typed have echoed, its folder is listed over the connection, and what is chosen goes on
/// the line as keys. Nothing private is ever sent to that shell.
final class CompletionSession {
    private(set) weak var tab: TerminalTab?
    private(set) var state = CompletionState()
    /// The open list's rows; nil while Loading, or with no list open.
    private(set) var list: CompletionList?
    /// The window's controller redraws the popup when the list or the state changes.
    var onChange: ((CompletionSession) -> Void)?

    /// Writes waiting for the answer, in order; a Tab pressed meanwhile waits among them.
    private enum Held {
        case bytes(ArraySlice<UInt8>)
        case tab
    }
    private var held: [Held] = []
    /// A bracketed paste runs on: its Return is text, not a key.
    private var inPaste = false
    private var heldPaste = false
    private var holdTimer: DispatchWorkItem?
    private var loadingTimer: DispatchWorkItem?
    private var assembler = CompAssembler()
    private let lister = PathLister()
    /// The caret's row (from the top of the scrollback) where the list opened: output that moves it with no
    /// line report closes the list.
    private var caretRow: Int?
    private var lineInOutput = false

    /// For the self-test: `tab` reports read, the last `done`, what the last real Tab became, and (debug builds
    /// only) the last write to pass the gate.
    private(set) var reports = 0
    private(set) var lastDone: (id: Int, outcome: CompletionProtocol.Outcome)?
    #if DEBUG
    private(set) var lastWrite: [UInt8] = []
    #endif
    enum TabOutcome: Equatable {
        case none
        case plain
        case privateKey(Int)
        /// A server's folder listed for the word on its screen.
        case listing(Int)
    }
    private(set) var lastTab = TabOutcome.none
    /// Writes to the shell so far: a question answered after one came lets its Tab go.
    private(set) var writes = 0
    /// Config keys sent since the shell last said where zsh-autocomplete stands (a few at most).
    private var configs = 0

    /// A server tab with no hook: the word its Tab is for, read off the screen, and the Tab's deadline.
    private var screenWord: ScreenWord?
    private var screenDeadline: DispatchWorkItem?
    /// Status reports from the server since the last Return: its prompt is trusted from the second (the first
    /// may come from a check that started before Return).
    private(set) var reportsSinceReturn = 0
    /// The last report gave the server shell's folder: listings relative to it can be kept.
    private(set) var serverFolderKnown = false
    /// The last write to the shell and the last output from it: a key has echoed once output came after it.
    private var lastInputAt: TimeInterval = 0
    private var lastOutputAt: TimeInterval = 0

    init(tab: TerminalTab) {
        self.tab = tab
    }

    private var view: NextTermView? { tab?.view }

    /// A list is open (shown or about to be): the window's keys go to it.
    var isListOpen: Bool { state.openID != nil }
    /// The popup shows: the list, or the Loading row.
    var isShown: Bool { state.openID != nil && state.shown }

    // MARK: writes

    /// Every write to the shell passes here (NextTermView.send, after interceptInput). True: it waits, and goes
    /// out later in order.
    func gate(_ data: ArraySlice<UInt8>) -> Bool {
        writes += 1
        // Only a key the user pressed may go on with the list open; an agent's text, a drop, a paste close it.
        if isListOpen {
            var probe = inPaste
            let scan = InputScan.scan(data, inPaste: &probe)
            let dispatching = (view?.window as? TerminalWindow)?.dispatchingKey ?? false
            if !dispatching || scan.pasteStarts { closeList() }
        }
        guard state.holding else {
            note(data)
            return false
        }
        held.append(.bytes(data))
        // Keys typed while a server's folder is listed: the shell's own Tab goes first, then they do, and the
        // listing is dropped. A Tab is never sent late.
        if state.path == .screen, let id = state.pendingID {
            screenAnswer(id, .native)
            return true
        }
        // Return and the like end the Tab at once: zsh's own Tab, then the keys, in order.
        if InputScan.scan(data, inPaste: &heldPaste).disarms, let id = state.pendingID {
            if state.path == .engine { answer(id, .native) } else { state.disarm() }
            release()
            changed()
        }
        return true
    }

    /// Bytes on their way to the shell: what they mean for the state.
    private func note(_ data: ArraySlice<UInt8>) {
        #if DEBUG
        lastWrite = Array(data)
        #endif
        let open = isListOpen
        let scan = InputScan.scan(data, inPaste: &inPaste)
        lastInputAt = TerminalTab.now
        if scan.disarms { reportsSinceReturn = 0 }
        state.input(scan)
        if open, !isListOpen {
            listClosed()
            changed()
        }
    }

    /// Next Term's own keys, past the gate.
    private func write(_ bytes: [UInt8]) {
        view?.sendPastGate(ArraySlice(bytes))
    }

    /// The held writes go out in order, up to a Tab that starts holding again.
    private func release() {
        while !state.holding, !held.isEmpty {
            switch held.removeFirst() {
            case .bytes(let data):
                note(data)
                view?.sendPastGate(data)
            case .tab:
                // A Tab pressed while the answer was owed follows the rule of the state the answer left.
                if !realTab() { pass([0x09]) }
            }
        }
        heldPaste = inPaste
    }

    private func pass(_ bytes: [UInt8]) {
        note(ArraySlice(bytes))
        view?.sendPastGate(ArraySlice(bytes))
    }

    // MARK: Tab

    /// A real Tab from the keyboard (CompletionController), in a tab that can take it. False: not Armed, so
    /// the key goes on as a plain ^I.
    func realTab() -> Bool {
        if usesScreen { return screenTab() }
        if state.holding {
            held.append(.tab)
            return true
        }
        guard let id = state.startTab() else {
            lastTab = .plain
            return false
        }
        lastTab = .privateKey(id)
        heldPaste = inPaste
        list = nil
        assembler.reset()
        write(CompletionProtocol.tabKey(id: id, wait: serverWait))
        let hold = DispatchWorkItem { [weak self] in self?.holdExpired(id) }
        holdTimer?.cancel()
        holdTimer = hold
        DispatchQueue.main.asyncAfter(deadline: .now() + answerWithin, execute: hold)
        if state.path == .completionSystem {
            let loading = DispatchWorkItem { [weak self] in self?.loadingDue(id) }
            loadingTimer?.cancel()
            loadingTimer = loading
            DispatchQueue.main.asyncAfter(deadline: .now() + CompletionProtocol.shellWait, execute: loading)
        }
        return true
    }

    /// A real Tab the plugin that owns Tab keeps: a plain ^I. False: the key goes on as it is
    /// (CompletionController).
    func plainTab() -> Bool {
        lastTab = .plain
        return false
    }

    /// The plain ^I for a Tab that waited for the question: what the key would have sent.
    func sendPlainTab() {
        lastTab = .plain
        view?.send(txt: "\t")
    }

    /// 120 ms: on Next Term's own path the answer is "native" now; either way the held writes go out.
    private func holdExpired(_ id: Int) {
        if state.holdExpired(id) { write(CompletionProtocol.nativeAnswer(id: id)) }
        release()
        changed()
    }

    /// 150 ms on zsh's path with nothing back: the list opens with a Loading row.
    private func loadingDue(_ id: Int) {
        state.loadingDue(id)
        changed()
    }

    /// Next Term's answer to a `tab` report.
    private func answer(_ id: Int, _ verdict: CompletionState.Verdict, word: String = "") {
        guard state.pendingID == id else { return }
        holdTimer?.cancel()
        switch verdict {
        case .native: write(CompletionProtocol.nativeAnswer(id: id))
        case .insert: write(CompletionProtocol.insertAnswer(id: id, word: word))
        case .open: write(CompletionProtocol.openAnswer(id: id))
        }
        state.answered(id, verdict)
    }

    // MARK: Next Term's own engine

    /// A `tab` report: what the word completes, listed off the main thread. The answer goes out when the
    /// listing is in, if the 120 ms aren't up.
    private func engine(_ report: CompletionProtocol.TabReport) {
        guard let context = CompletionContext.analyze(report) else { return answer(report.id, .native) }
        let id = report.id
        // A hooked server's shell: its folder is listed there, over the tab's connection.
        if tab?.remote != nil { return serverEngine(id, context) }
        let started = lister.start(context.folder) { [weak self] listing in
            let prepared = PathCompletion.Prepared(listing, foldersOnly: context.kind == .folders, hidden: context.showsHidden)
            let result = listing.readable ? prepared.candidates(context.typed) : PathCompletion.Result()
            DispatchQueue.main.async {
                self?.engineAnswered(id, context: context, listing: listing, prepared: prepared, result: result)
            }
        }
        // A listing that is still stuck (a hung volume): zsh's own Tab, at once.
        if !started { answer(id, .native) }
    }

    private func engineAnswered(_ id: Int, context: CompletionContext, listing: PathCompletion.Listing,
                                prepared: PathCompletion.Prepared, result: PathCompletion.Result) {
        guard state.pendingID == id else { return }
        switch CompletionVerdict.of(result, context: context) {
        case .native:
            answer(id, .native)
        case .insert(let word):
            answer(id, .insert, word: word)
        case .open:
            list = CompletionList(id: id, context: context, listing: listing, prepared: prepared, result: result)
            answer(id, .open)
        }
        release()
        changed()
    }

    // MARK: the shell's marks

    func handle(_ message: CompletionProtocol.Message) {
        switch message {
        case .arm(let arm):
            if state.arm?.sameLine(as: arm) == true, state.phase != .disarmed {
                // Only zsh-autocomplete's state changed (a config key): the line and anything in flight stay.
                state.update(arm)
            } else {
                // A new line or keymap: a list still open on the shell's side is over.
                if let id = state.openID, state.path != .screen { write(CompletionProtocol.close(id: id)) }
                state.armed(arm)
                listClosed()
            }
            syncQuiet()
        case .tab(let report):
            guard state.pendingID == report.id, state.path == .engine else { return }
            reports += 1
            engine(report)
        case .comp(let chunk):
            comp(chunk)
        case .done(let id, let outcome):
            lastDone = (id, outcome)
            let mine = state.pendingID == id || state.openID == id
            state.done(id, outcome)
            if mine { listClosed() }
        case .line(let report):
            line(report)
        }
        release()
        changed()
    }

    /// zsh's matches: the list once every chunk is in.
    private func comp(_ chunk: CompletionProtocol.CompChunk) {
        guard state.pendingID == chunk.id || state.openID == chunk.id, state.path == .completionSystem else { return }
        guard let matches = assembler.add(chunk) else { return }
        loadingTimer?.cancel()
        list = CompletionList(id: chunk.id, matches: matches, total: chunk.total, stem: chunk.stem, stemUnquoted: chunk.stemUnquoted)
        state.listed(chunk.id)
    }

    private func line(_ report: CompletionProtocol.LineReport) {
        guard state.openID == report.id else { return }
        if report.left {
            state.line(report)
            return listClosed()
        }
        lineInOutput = true
        if let list {
            // The word no longer fits the list (another folder, a closed quote): it closes.
            if !list.update(word: report.word, unquoted: report.unquoted) { return closeList() }
        } else if state.path == .completionSystem, assembler.isIncomplete(report.id) {
            // Some of zsh's chunks never came: zsh's own Tab instead.
            return cannotShow()
        }
        state.line(report)
    }

    /// A command started: nothing in flight survives it.
    func disarm() {
        holdTimer?.cancel()
        state.disarm()
        listClosed()
        release()
        changed()
    }

    /// The shell was replaced (`exec zsh`): the new one has no hook until it says so.
    func shellReplaced() {
        disarm()
        state.forget()
    }

    /// The plugin that owns Tab in this shell, if one does.
    var owner: CompletionOwner.Plugin? { state.arm.flatMap(CompletionOwner.plugin) }

    /// Who answers this tab's Tab, for its tooltip.
    var engineLabel: String {
        if CompletionPreferences.isOn, usesScreen { return "Tab completion: Next Term’s list of the server’s folders and files, over ssh" }
        guard CompletionPreferences.isOn, let arm = state.arm else { return "Tab completion: the shell’s own" }
        if let owner {
            switch CompletionPreferences.answer(for: owner) {
            case .plugin: return "Tab completion: \(owner.name), your choice"
            case .ask: return "Tab completion: \(owner.name) until you choose (Next Term asks at the first Tab)"
            case .nextTerm: break
            }
        }
        return arm.completionSystem ? "Tab completion: Next Term’s list, with zsh’s completions" : "Tab completion: Next Term’s list of folders and files"
    }

    /// zsh-autocomplete's list as you type goes off where Next Term's list answers Tab, and back on where it
    /// doesn't: a config key to a shell at its prompt whose last `arm` says otherwise.
    func syncQuiet() {
        guard let arm = state.arm, arm.plugins.contains("autocomplete"), state.isArmed else { return }
        let want = CompletionPreferences.quietsAutocomplete
        guard want != arm.quieted else {
            configs = 0
            return
        }
        guard configs < 3 else { return }
        configs += 1
        write(CompletionProtocol.frame(.config, id: 0, fields: [want ? "q1" : "q0"]))
    }

    /// A choice or the mode changed: every tab's zsh-autocomplete follows it.
    static func syncAll() {
        for controller in AppDelegate.shared?.controllers ?? [] {
            for tab in controller.tabs {
                tab.completion.configs = 0
                tab.completion.syncQuiet()
                tab.delegate?.tabDidChange(tab)
            }
        }
    }

    // MARK: the list

    /// Puts row `index` on the line, and closes the list.
    func accept(_ index: Int) {
        guard isListOpen, let list else { return }
        if state.path == .screen {
            guard let candidate = list.screenCandidate(index) else { return }
            return screenAccept(candidate, text: list.rows[index].text, list, since: TerminalTab.now)
        }
        guard let bytes = list.take(index) else {
            NSSound.beep()
            return closeList()
        }
        let text = list.rows[index].text
        write(bytes)
        state.closed()
        listClosed()
        changed()
        CompletionPopup.announce("Inserted \(text)")
    }

    /// Closes the list with nothing chosen (Esc, a click elsewhere, the window going): the shell stops
    /// reporting the line.
    func closeList() {
        guard let id = state.openID else { return }
        if state.path != .screen { write(CompletionProtocol.close(id: id)) }
        state.closed()
        listClosed()
        changed()
    }

    /// The list can't be shown (its window isn't in front): on zsh's path zsh lists as it would by itself;
    /// Next Term's own list just closes.
    func cannotShow() {
        guard let id = state.openID ?? state.pendingID else { return }
        if state.path == .completionSystem {
            write(CompletionProtocol.frame(.native, id: id))
            state.steppedBack(id)
            listClosed()
            changed()
        } else {
            closeList()
        }
    }

    private func listClosed() {
        loadingTimer?.cancel()
        list = nil
        caretRow = nil
        screenWord = nil
        assembler.reset()
    }

    private func changed() {
        onChange?(self)
    }

    /// Output reached the terminal: with the list shown, output that moves the caret's row without a line
    /// report (a background job printing) closes it.
    func output() {
        lastOutputAt = TerminalTab.now
        if state.path == .screen { return screenOutput() }
        guard isShown, let view else {
            lineInOutput = false
            return
        }
        let terminal = view.getTerminal()
        let row = terminal.getTopVisibleRow() + terminal.getCursorLocation().y
        if lineInOutput || caretRow == nil {
            caretRow = row
            // The line is drawn now: the list moves to where its word is.
            changed()
        } else if row != caretRow {
            closeList()
        }
        lineInOutput = false
    }

    /// The terminal's size or font changed: the list's place is gone.
    func viewChanged() {
        closeList()
    }
}

// MARK: Suggest a Command's line

extension CompletionSession {
    /// The shell's hook is at its prompt here and takes a whole line (one edit, several lines too).
    var takesLine: Bool {
        state.arm != nil && (state.isArmed || state.phase == .steppedBack) && !state.holding
    }

    /// Puts `line` in place of the line being edited, through the hook. It never runs.
    func takeLine(_ line: String) {
        guard takesLine else { return }
        closeList()
        write(CompletionProtocol.takeLine(line))
    }
}

// MARK: a server's screen

extension CompletionSession {
    /// A server tab whose shell has no hook (no `arm` has come from it): Tab completion reads its screen.
    var usesScreen: Bool { tab?.remote != nil && state.arm == nil }

    /// A server tab kept in Next Term's tmux: tmux draws it on the alternate screen, its pane's cursor where the
    /// shell's is.
    var inTmux: Bool { tab?.remote?.keep == .tmux && tab?.fellBack == false }

    /// The server's shell is at its prompt and can complete from the screen now: connected, two status reports
    /// since the last Return, and room on its connection. Without these, a plain ^I at once.
    var screenReady: Bool {
        guard let tab, usesScreen, CompletionPreferences.isOn else { return false }
        guard tab.remoteConnected, !tab.disconnected, !tab.exited, tab.remoteReady, !tab.status.running else { return false }
        return reportsSinceReturn >= 2 && RemoteCompletion.shared.hasRoom(for: tab)
    }

    /// A status report for this server tab (TerminalTab.applyRemote): what it says about the prompt, whether it
    /// gave the shell's folder (not where there is no /proc), and that folder to prefetch. A host whose hook is
    /// allowed is checked for it now and then.
    func remoteReport(folder: Bool) {
        reportsSinceReturn += 1
        serverFolderKnown = folder
        if let tab, reportsSinceReturn >= 2 { RemoteCompletion.shared.prefetch(tab) }
        if let host = tab?.remote?.host { RemoteCompletionConsent.verify(host) }
    }

    /// How long a Tab's answer may take: 120 ms on this Mac; on a hooked server, a little less than its hook waits.
    fileprivate var answerWithin: TimeInterval {
        guard let wait = serverWait else { return CompletionProtocol.answerWithin }
        return wait - 0.05
    }

    /// How long a hooked server's hook waits for the answer to a Tab, said in the Tab's own key: two listings'
    /// time on its connection and some, 150 to 600 ms. nil on this Mac.
    fileprivate var serverWait: TimeInterval? {
        guard let tab, tab.remote != nil else { return nil }
        return min(0.6, max(0.15, 2 * RemoteCompletion.shared.roundTrip(for: tab) + 0.12))
    }

    /// A hooked server's `tab` report: its folder listed on the server, over the tab's connection (one listing at a
    /// time; none on a crowded connection), answered as Next Term's own engine answers.
    fileprivate func serverEngine(_ id: Int, _ context: CompletionContext) {
        guard let tab, let request = RemoteCompletion.shared.request(absolute: context.folder, in: tab) else { return answer(id, .native) }
        let listing = RemoteCompletion.shared.list(request, for: tab) { [weak self] result in
            guard let self else { return }
            guard let result else {
                self.answer(id, .native)
                self.release()
                return self.changed()
            }
            let prepared = PathCompletion.Prepared(result.listing, foldersOnly: context.kind == .folders, hidden: context.showsHidden,
                                                   disk: result.disk)
            self.engineAnswered(id, context: context, listing: result.listing, prepared: prepared, result: prepared.candidates(context.typed))
        }
        if !listing { answer(id, .native) }
    }

    /// A real Tab in a server tab with no hook. Keys typed until it is answered wait; one typed then sends the
    /// shell's own Tab first. False: a plain ^I, at once.
    fileprivate func screenTab() -> Bool {
        if state.holding, state.path == .screen, let id = state.pendingID {
            held.append(.tab)
            screenAnswer(id, .native)
            return true
        }
        guard screenReady, let id = state.startScreenTab() else {
            lastTab = .plain
            return false
        }
        lastTab = .listing(id)
        heldPaste = inPaste
        list = nil
        let deadline = DispatchWorkItem { [weak self] in self?.screenAnswer(id, .native) }
        screenDeadline?.cancel()
        screenDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + RemoteCompletion.deadline, execute: deadline)
        screenSettled(id, since: TerminalTab.now)
        return true
    }

    /// The keys typed have all echoed and the output has rested for a round trip: what is on screen is what the
    /// shell has. Until then (250 ms at most) the word isn't read.
    private func settled(_ tab: TerminalTab) -> Bool {
        lastOutputAt >= lastInputAt && TerminalTab.now - lastOutputAt >= RemoteCompletion.shared.roundTrip(for: tab)
    }

    private func screenSettled(_ id: Int, since start: TimeInterval) {
        guard state.pendingID == id, state.path == .screen, let tab else { return }
        guard settled(tab) else {
            guard TerminalTab.now - start < 0.25 else { return screenAnswer(id, .native) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in self?.screenSettled(id, since: start) }
            return
        }
        guard !tab.view.getTerminal().isCurrentBufferAlternate || inTmux, let left = tab.lineLeftOfCursor(), let word = ScreenWord.read(left),
              let request = RemoteCompletion.shared.request(for: word, in: tab) else { return screenAnswer(id, .native) }
        screenWord = word
        let listing = RemoteCompletion.shared.list(request, for: tab) { [weak self] result in self?.screenListed(id, result) }
        if !listing { screenAnswer(id, .native) }
    }

    private func screenListed(_ id: Int, _ result: RemoteListing.Result?) {
        guard state.pendingID == id, state.path == .screen, let word = screenWord else { return }
        guard let result else { return screenAnswer(id, .native) }
        let made = CompletionList(id: id, screen: word, listing: result.listing, disk: result.disk, shell: result.quoting)
        switch made.screenVerdict {
        case .native:
            screenAnswer(id, .native)
        case .insert:
            screenAnswer(id, .insert, keys: made.screenCandidate(0).flatMap { made.screenInsertion($0, at: word) })
        case .open:
            list = made
            screenAnswer(id, .open)
        }
    }

    /// The answer to a Tab on a server's screen: the shell's own Tab (a plain ^I), a name put on the line as keys,
    /// or the list. The keys typed meanwhile go out after it, in order.
    private func screenAnswer(_ id: Int, _ verdict: CompletionState.Verdict, keys: (erase: Int, text: String)? = nil) {
        guard state.pendingID == id, state.path == .screen else { return }
        screenDeadline?.cancel()
        var answer = verdict
        if answer == .insert, keys == nil { answer = .native }
        switch answer {
        case .native: pass([0x09])
        case .insert: if let keys { typeOnScreen(keys) }
        case .open: break
        }
        state.answered(id, answer)
        if answer != .open { listClosed() }
        release()
        changed()
    }

    /// Keys that put a name on a server's line: Backspaces for what goes, then the text, as a paste where the
    /// shell takes one (so it goes in as it is).
    private func typeOnScreen(_ keys: (erase: Int, text: String)) {
        guard let view else { return }
        var bytes = [UInt8](repeating: 0x7F, count: keys.erase)
        let text = Array(keys.text.utf8)
        if view.getTerminal().bracketedPasteMode {
            bytes += Array("\u{1b}[200~".utf8) + text + Array("\u{1b}[201~".utf8)
        } else {
            bytes += text
        }
        pass(bytes)
    }

    /// Output in a server tab with its list shown: a key echoed, so the list narrows to the word on screen, or the
    /// line changed around it, and it closes.
    fileprivate func screenOutput() {
        guard isShown, let list, let tab else { return }
        guard let left = tab.lineLeftOfCursor(), let now = list.screenWord?.next(left), list.update(screen: now) else { return closeList() }
        changed()
    }

    /// A row chosen on a server's list: once what was typed has echoed (300 ms at most), the keys that put it in
    /// place of the name on screen.
    fileprivate func screenAccept(_ candidate: PathCompletion.Candidate, text: String, _ list: CompletionList, since start: TimeInterval) {
        guard state.openID == list.id, let tab else { return }
        if !settled(tab), TerminalTab.now - start < 0.3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in self?.screenAccept(candidate, text: text, list, since: start) }
            return
        }
        guard let left = tab.lineLeftOfCursor(), let now = list.screenWord?.next(left), let keys = list.screenInsertion(candidate, at: now) else {
            NSSound.beep()
            return closeList()
        }
        state.closed()
        listClosed()
        typeOnScreen(keys)
        changed()
        CompletionPopup.announce("Inserted \(text)")
    }
}

extension TerminalTab {
    #if DEBUG
    /// The self-test's stand-in for the user's zsh config folder, for the tabs it opens.
    nonisolated(unsafe) static var testUserZDOTDIR: String?
    #endif

    /// Where the user's own zsh config is (the integration's .zshenv hands over to it).
    static func userZDOTDIR(_ env: [String: String]) -> String {
        #if DEBUG
        if let testUserZDOTDIR { return testUserZDOTDIR }
        #endif
        return env["ZDOTDIR"] ?? ""
    }
}
