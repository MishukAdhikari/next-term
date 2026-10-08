import AppKit
import NextTermCore

/// One tab's side of Tab completion: its CompletionState, the list it shows, the private keys it sends, and the
/// one ordered writer to the shell. While an answer is owed, every write (the user's keys, an agent's text
/// over MCP) waits and then goes out in order, after the answer: at most 120 ms.
///
/// Next Term's own engine answers a `tab` report within 120 ms: no candidate is "native" (zsh's own Tab), one is
/// "insert", more is "open", and the list shows at the first `line` for that id. On zsh's path no answer is
/// ever sent: zsh's matches come in `comp` marks, with a Loading row if they take over 150 ms.
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
    }
    private(set) var lastTab = TabOutcome.none

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
        state.input(InputScan.scan(data, inPaste: &inPaste))
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
        write(CompletionProtocol.frame(.tab, id: id))
        let hold = DispatchWorkItem { [weak self] in self?.holdExpired(id) }
        holdTimer?.cancel()
        holdTimer = hold
        DispatchQueue.main.asyncAfter(deadline: .now() + CompletionProtocol.answerWithin, execute: hold)
        if state.path == .completionSystem {
            let loading = DispatchWorkItem { [weak self] in self?.loadingDue(id) }
            loadingTimer?.cancel()
            loadingTimer = loading
            DispatchQueue.main.asyncAfter(deadline: .now() + CompletionProtocol.shellWait, execute: loading)
        }
        return true
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
            // A new line or keymap: a list still open on the shell's side is over.
            if let id = state.openID { write(CompletionProtocol.close(id: id)) }
            state.armed(arm)
            listClosed()
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

    /// Who answers this tab's Tab, for its tooltip.
    var engineLabel: String {
        guard CompletionPreferences.isOn, let arm = state.arm else { return "Tab completion: the shell’s own" }
        return arm.completionSystem ? "Tab completion: Next Term’s list, with zsh’s completions" : "Tab completion: Next Term’s list of folders and files"
    }

    // MARK: the list

    /// Puts row `index` on the line, and closes the list.
    func accept(_ index: Int) {
        guard isListOpen, let list else { return }
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
        write(CompletionProtocol.close(id: id))
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
        assembler.reset()
    }

    private func changed() {
        onChange?(self)
    }

    /// Output reached the terminal: with the list shown, output that moves the caret's row without a line
    /// report (a background job printing) closes it.
    func output() {
        guard isShown, let view else {
            lineInOutput = false
            return
        }
        let terminal = view.getTerminal()
        let row = terminal.getTopVisibleRow() + terminal.getCursorLocation().y
        if lineInOutput || caretRow == nil {
            caretRow = row
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
