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
///
/// ⇥ or → on a folder row goes into it (CompletionDrill): the name and `/` go on the line and the same list shows what
/// is inside; ⌫ that takes the `/`, or ←, goes back up. Writes wait while the folder is listed, as they wait for a Tab's
/// answer. The list's own keys pressed meanwhile (↓ ↑ too) wait in one queue with the keys typed after them
/// (CompletionKeyQueue), and act in order: a key after letters typed first waits for the shell's word with them.
final class CompletionSession {
    private(set) weak var tab: TerminalTab?
    private(set) var state = CompletionState()
    /// The open list's rows; nil while Loading, or with no list open.
    private(set) var list: CompletionList?
    /// The window's controller redraws the popup when the list or the state changes.
    var onChange: ((CompletionSession) -> Void)?
    /// The row the popup has chosen (the window's controller).
    var selection: (() -> Int)?

    /// Writes waiting for the answer, in order; a Tab pressed meanwhile waits among them.
    private enum Held {
        case bytes(ArraySlice<UInt8>)
        case tab
    }
    private var held: [Held] = []
    /// A Tab pressed while another was in flight, past the hold (zsh's own completion can take seconds): it waits for
    /// that Tab's outcome (followTab). A key typed meanwhile drops it.
    private var tabWaiting = false
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
    /// For the self-test: folders gone into, what the last one came to, and lists gone back up to.
    private(set) var drills = 0
    private(set) var lastDrill: CompletionDrill.Step?
    private(set) var backUps = 0

    /// Going into a folder: its deadline, and what then puts the name on the line alone.
    private var drillTimer: DispatchWorkItem?
    private var drillFallback: (() -> Void)?
    /// On zsh's path, the list gone from and its row, while zsh lists what is inside (for a refusal, and for ⌫).
    private var drillFrom: (list: CompletionList, row: Int)?
    /// The list's keys pressed while it walks (⇥ or →, ↩︎, ←, ↓ ↑), and the keys typed after them, in order: they act
    /// once the list they act on shows.
    private var queue = CompletionKeyQueue()
    /// ← on a server's screen, until what was typed has echoed and the keys back up are typed: the list's keys wait.
    private var upPending = false
    /// ↩︎ on a server's screen, until what was typed has echoed and the name's keys are typed: the same.
    private var acceptPending = false
    /// A folder is being listed, or ← or ↩︎ waits for an echo on a server's screen: the list's keys wait.
    var isWalking: Bool { state.isDrilling || upPending || acceptPending }
    /// The list's keys wait (and a click does nothing): it walks, or keys from before still do.
    var keysWait: Bool { isWalking || !queue.isEmpty }
    /// The `sync` asked of the hook for keys that wait after letters typed (its id, and its deadline), and the last id.
    private var syncToken: Int?
    private var syncCount = 0
    private var syncDeadline: DispatchWorkItem?
    /// The same on a server's screen: since when keys that wait have waited for what was typed to echo, and the next look.
    private var echoSince: TimeInterval?
    private var echoPoll: DispatchWorkItem?
    /// The row the keys that waited moved to (↓ ↑), for the popup to choose as it shows that list.
    private weak var chosenList: CompletionList?
    private var chosenRow = 0
    /// zsh's single-match rule went into a folder for this Tab (`into`): its list is what is inside, for VoiceOver.
    private var intoID: Int?
    /// The single-match rule while what is inside is listed: what goes on the line alone if it isn't in time.
    private var singleInsert: (id: Int, word: String)?
    private var singleKeys: (id: Int, keys: (erase: Int, text: String))?
    /// A server's screen, after going into a folder (or back up with ←): the word the screen shows once the keys have
    /// echoed, and until when what is on the way to it is let be. Going in, a word in that folder is it; going up
    /// (`exact`), only that word.
    private var drillEcho: (word: ScreenWord, until: TimeInterval, exact: Bool)?
    /// Next Term's own engine keeps one id from the Tab to the folder gone into and back up, so the hook reports each
    /// take that keeps the list open (into a folder, ← back up) under that id: the words those reports will have,
    /// oldest first. A report for one a later take has gone past (→ then ← at once) is old news for the list showing.
    private var takeEchoes: [String] = []
    /// The list VoiceOver was told of already ("In projects, 12 items"), so the popup doesn't say it again.
    private(set) weak var announced: CompletionList?

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
        // Typed after a list key that waits: it goes out after that key acts.
        if queue.type(Array(data)) { return true }
        guard state.holding || !held.isEmpty else {
            tabWaiting = false
            note(data)
            return false
        }
        held.append(.bytes(data))
        // Keys a closed list let go are still on their way out: these go after them.
        if !state.holding {
            release()
            return true
        }
        // Keys typed while a server's folder is listed: the shell's own Tab goes first (or the one folder, alone),
        // then they do, and the listing is dropped. A Tab is never sent late.
        if state.path == .screen, let id = state.pendingID {
            screenGiveUp(id)
            return true
        }
        // Return and the like end the Tab at once: zsh's own Tab (or the one folder, alone), then the keys, in order.
        if InputScan.scan(data, inPaste: &heldPaste).disarms, let id = state.pendingID {
            if state.path == .engine {
                if let single = singleInsert, single.id == id {
                    singleInsert = nil
                    answer(id, .insert, word: single.word)
                } else {
                    answer(id, .native)
                }
            } else {
                state.disarm()
            }
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
        queue.typed()
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

    /// The held writes go out in order, up to a Tab that starts holding again; then a Tab that waits follows the state
    /// it now finds, and so do the list's keys that wait (and the keys typed after them, which a list that closes lets go).
    private func release() {
        repeat {
            while !state.holding, !held.isEmpty {
                switch held.removeFirst() {
                case .bytes(let data):
                    // Typed after a Tab that waits: that Tab is dropped.
                    tabWaiting = false
                    note(data)
                    view?.sendPastGate(data)
                case .tab:
                    followTab()
                }
            }
            heldPaste = inPaste
            if tabWaiting, !state.holding { followTab() }
            if !queue.isEmpty { followKeys() }
        } while !state.holding && !held.isEmpty
    }

    /// A Tab pressed while another was in flight follows the rule of the state that one left. Still in flight, it
    /// waits. An open list takes it as its own Tab once its rows show (the first row goes in, as zsh's second Tab
    /// puts in its first match), and before that it waits; under the Loading row it does nothing, as a Tab pressed
    /// there does. Armed: the private key again. Stepped back or Disarmed: a plain ^I, zsh's own second Tab. So it
    /// never reaches zsh as ^I beside a list of Next Term's.
    private func followTab() {
        tabWaiting = false
        if state.pendingID != nil || state.isDrilling {
            tabWaiting = true
        } else if isListOpen {
            guard let list else { return } // Loading
            if !state.shown || list.rows.isEmpty {
                tabWaiting = true
            } else {
                tab(on: list.preferredRow ?? 0)
            }
        } else if !realTab() {
            pass([0x09])
        }
    }

    /// A list key pressed while the list walks waits, in order with the others and the keys typed after it.
    private func wait(_ key: CompletionKeyQueue.Key) {
        let showing = state.shown && list?.rows.isEmpty == false ? list : nil
        queue.add(key, on: showing, row: selection?() ?? 0)
    }

    /// The keys that waited, in order, each on the list showing then, and the keys typed after them; until one walks
    /// again. If the list closed meanwhile (the name went in alone), its keys never reach the shell, and the keys typed
    /// after them go out.
    private func followKeys() {
        var moved: (list: CompletionList, row: Int)?
        follow: while !queue.isEmpty {
            guard isListOpen else {
                held += queue.close().map { .bytes(ArraySlice($0)) }
                break
            }
            switch queue.next(list: state.shown ? list : nil, busy: isWalking, hold: state.holding || upPending || acceptPending) {
            case .idle, .wait:
                break follow
            case .line:
                guard lineIsIn() else { break follow }
                queue.lineIn()
            case .send(let bytes):
                let data = ArraySlice(bytes)
                tabWaiting = false
                note(data)
                view?.sendPastGate(data)
            case let .act(key, row):
                guard let list else { break follow }
                switch key {
                case .tab: tab(on: row)
                case .enter: accept(row)
                case .left: if list.parent != nil { goUp() }
                case .move: moved = (list, row)
                }
            }
        }
        if let moved, moved.list === list {
            chosenList = moved.list
            chosenRow = moved.row
            changed()
        }
    }

    /// Keys typed went to the shell since the walk began: whether the shell's word with them is in, so the keys that
    /// wait act on the list narrowed for it. On a server's screen, once what was typed has echoed and the output has
    /// rested (300 ms at most); through the hook, once its `sync` comes back (asked for here).
    private func lineIsIn() -> Bool {
        guard let tab else { return true }
        if state.path == .screen {
            let since = echoSince ?? TerminalTab.now
            echoSince = since
            if settled(tab) || TerminalTab.now - since >= 0.3 {
                echoSince = nil
                return true
            }
            if echoPoll == nil {
                let poll = DispatchWorkItem { [weak self] in
                    self?.echoPoll = nil
                    self?.release()
                }
                echoPoll = poll
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.015, execute: poll)
            }
            return false
        }
        guard state.arm?.drills == true else { return true }
        if syncToken == nil {
            syncCount = syncCount % 999_999 + 1
            syncToken = syncCount
            write(CompletionProtocol.sync(id: syncCount))
            let deadline = DispatchWorkItem { [weak self] in self?.syncLate() }
            syncDeadline?.cancel()
            syncDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + (tab.remote == nil ? CompletionProtocol.frameWait : RemoteCompletion.deadline),
                                          execute: deadline)
        }
        return false
    }

    /// The hook's `sync` didn't come in time: the list's keys that waited go, and the keys typed after them go out.
    private func syncLate() {
        guard syncToken != nil else { return }
        syncToken = nil
        held += queue.close().map { .bytes(ArraySlice($0)) }
        release()
        changed()
    }

    /// The row the keys that waited moved to, for the popup showing `list` (once).
    func takeChosenRow(for list: CompletionList?) -> Int? {
        defer { chosenList = nil }
        guard let list, chosenList === list, list.rows.indices.contains(chosenRow) else { return nil }
        return chosenRow
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
        // Another Tab is in flight: this one waits for its outcome, among the held writes while they are held.
        if state.holding {
            held.append(.tab)
            return true
        }
        if state.pendingID != nil {
            tabWaiting = true
            return true
        }
        // Armed, and nothing else has the terminal (TerminalTab.shellAlone): the private key.
        guard state.isArmed, tab?.shellAlone == true, let id = state.startTab() else {
            lastTab = .plain
            return false
        }
        lastTab = .privateKey(id)
        heldPaste = inPaste
        list = nil
        intoID = nil
        assembler.reset()
        // On zsh's path the hook puts one folder in and lists what is inside by itself (the single-match rule).
        let drill = state.path == .completionSystem && state.arm?.drills == true
        write(CompletionProtocol.tabKey(id: id, wait: serverWait, quiet: quietWanted, drill: drill))
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

    /// A Tab on an open list whose rows haven't come yet: it waits for them, as one pressed while the Tab was in
    /// flight does (followTab). Under the Loading row it does nothing.
    private func tabBeforeRows() {
        guard isListOpen, let list, !state.shown || list.rows.isEmpty else { return }
        tabWaiting = true
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

    /// 120 ms: on Next Term's own path the answer is "native" now, or the one folder alone when what is inside wasn't
    /// listed in time; either way the held writes go out.
    private func holdExpired(_ id: Int) {
        if let single = singleInsert, single.id == id, state.pendingID == id {
            singleInsert = nil
            answer(id, .insert, word: single.word)
        } else if state.holdExpired(id) {
            write(CompletionProtocol.nativeAnswer(id: id))
        }
        release()
        changed()
    }

    /// 150 ms on zsh's path with nothing back: the list opens with a Loading row.
    private func loadingDue(_ id: Int) {
        state.loadingDue(id)
        release()
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
            // The single-match rule: one folder that can be entered goes in, with what is inside listed.
            if state.arm?.drills == true, let only = CompletionDrill.single(result), let into = context.drilled(into: only.name),
               singleDrill(id, word: word, name: only.display, into: into) { return }
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
                // Only zsh-autocomplete's state changed (a config key, or a Tab key's q): the line and anything in flight stay.
                state.update(arm)
            } else {
                // A new line or keymap: a list still open on the shell's side is over, and a Tab that waits with it.
                closeKeys()
                tabWaiting = false
                state.armed(arm)
                listClosed()
            }
        case .tab(let report):
            guard state.pendingID == report.id, state.path == .engine else { return }
            reports += 1
            engine(report)
        case .comp(let chunk):
            comp(chunk)
        case .done(let id, let outcome):
            lastDone = (id, outcome)
            if state.drillID == id, state.path == .completionSystem {
                zshDrillDone(id, outcome)
            } else {
                let mine = state.pendingID == id || state.openID == id
                state.done(id, outcome)
                if mine { listClosed() }
            }
        case .line(let report):
            line(report)
        case .sync(let id):
            // Every key typed before the `sync` key is in the reports before this: the keys that wait follow.
            if id == syncToken {
                syncToken = nil
                syncDeadline?.cancel()
                queue.lineIn()
            }
        case .into(let id):
            if state.pendingID == id, state.path == .completionSystem { intoID = id }
        }
        release()
        changed()
    }

    /// zsh's matches: the list once every chunk is in.
    private func comp(_ chunk: CompletionProtocol.CompChunk) {
        guard state.pendingID == chunk.id || state.openID == chunk.id || state.drillID == chunk.id, state.path == .completionSystem else { return }
        guard let matches = assembler.add(chunk) else { return }
        loadingTimer?.cancel()
        let made = CompletionList(id: chunk.id, matches: matches, total: chunk.total, stem: chunk.stem, stemUnquoted: chunk.stemUnquoted)
        if state.drillID == chunk.id, let from = drillFrom {
            // What is inside the folder gone into: the list gone from is kept for ⌫.
            holdTimer?.cancel()
            drillFrom = nil
            made.drilled(from: from.list, row: from.row)
            lastDrill = .into
            announce(into: made.drilledName ?? "", made)
        } else if intoID == chunk.id {
            // zsh's single-match rule went into the one folder: what is inside.
            intoID = nil
            announce(into: CompletionDrill.folderName(chunk.stemUnquoted), made)
        }
        list = made
        state.listed(chunk.id)
    }

    private func line(_ report: CompletionProtocol.LineReport) {
        guard state.openID == report.id else { return }
        if report.left {
            state.line(report)
            return listClosed()
        }
        lineInOutput = true
        // Going into a folder: the row was taken as the list stood when ⇥ was pressed.
        if state.isDrilling { return state.line(report) }
        // The word of a take another take has gone on from since: the list showing is that one's.
        if let at = takeEchoes.firstIndex(of: report.word) {
            takeEchoes.removeFirst(at + 1)
            if !takeEchoes.isEmpty { return state.line(report) }
        }
        if let list {
            // ⌫ took the `/` after a folder gone into: back up.
            if let above = list.backUp(word: report.word) { return wentBackUp(above) }
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
        tabWaiting = false
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

    /// zsh-autocomplete's list as you type: off where Next Term's list answers Tab, on where it doesn't. nil when the
    /// shell's last `arm` says it is so already, or it isn't loaded.
    private var quietWanted: Bool? {
        guard let arm = state.arm, arm.plugins.contains("autocomplete") else { return nil }
        let want = CompletionPreferences.quietsAutocomplete
        return want == arm.quieted ? nil : want
    }

    /// The choice changed (Settings, the question): a config key to a shell at its prompt whose last `arm` says
    /// otherwise. Never at a new prompt by itself, where a command typed ahead of it would read the key: a tab starts
    /// as the choice stands (TerminalTab.environment), and each Tab key says it again where it differs.
    func syncQuiet() {
        guard state.isArmed, tab?.shellAlone == true, let want = quietWanted else { return }
        write(CompletionProtocol.frame(.config, id: 0, fields: [want ? "q1" : "q0"]))
    }

    /// A choice or the mode changed: every tab's zsh-autocomplete follows it.
    static func syncAll() {
        for controller in AppDelegate.shared?.controllers ?? [] {
            for tab in controller.tabs {
                tab.completion.syncQuiet()
                tab.delegate?.tabDidChange(tab)
            }
        }
    }

    // MARK: the list

    /// ⇥, → or ← on the open list (CompletionController), with `row` chosen (nil: no rows show yet), as
    /// CompletionDrill.action has it: into a folder, the name on the line as ↩︎ puts it, a beep on a folder that can't
    /// be entered, back up from a folder gone into, or a wait (for the rows, or for the folder being listed). False:
    /// the list closed, and the key goes on to the shell (← at the top, → with no rows: the cursor moves).
    func walk(_ key: CompletionDrill.Key, row: Int?) -> Bool {
        guard isListOpen else { return false }
        let index = row.flatMap { list?.rows.indices.contains($0) == true ? $0 : nil }
        let target = index.flatMap { list?.tabTarget($0) }
        let action = CompletionDrill.action(key, on: target, inside: list?.parent != nil, drills: entersFolders, drilling: keysWait)
        switch action {
        case .goIn, .putOnLine, .beep: if let index { tab(on: index) }
        case .backUp: goUp()
        case .closeAndPass:
            closeList()
            return false
        case .wait:
            if keysWait { wait(key == .left ? .left : .tab) } else if key == .tab { tabBeforeRows() }
        }
        return true
    }

    /// The shell's hook goes into folders (a server's from before doesn't: ⇥ is ↩︎ there until its shell starts again);
    /// a server's screen always does.
    private var entersFolders: Bool { state.path == .screen || state.arm?.drills == true }

    /// ⇥ or → on row `index` of the open list (walk, or a Tab that waited for the rows): into a folder row; a beep on a
    /// folder that can't be entered; anything else goes on the line as ↩︎ puts it. While a folder is being listed it
    /// waits, for the folder's list.
    func tab(on index: Int) {
        guard isListOpen, let list, list.rows.indices.contains(index) else { return }
        if isWalking { return wait(.tab) }
        tabWaiting = false
        switch CompletionDrill.action(.tab, on: list.tabTarget(index), inside: list.parent != nil, drills: entersFolders) {
        case .goIn: drill(index, list)
        case .beep: NSSound.beep()
        default: accept(index)
        }
    }

    /// ↩︎ on row `index`: while the list walks it waits, then takes the row chosen in the list showing then.
    func enter(on index: Int) {
        guard isListOpen else { return }
        if keysWait { return wait(.enter) }
        accept(index)
    }

    /// ↓ ↑ (⌃N ⌃P, ⇧⇥) while the list walks: they wait with its other keys, and move the row the next one takes. False:
    /// the popup moves its row now.
    func choose(by delta: Int) -> Bool {
        guard isListOpen, keysWait else { return false }
        wait(.move(delta))
        return true
    }

    /// Puts row `index` on the line, and closes the list.
    func accept(_ index: Int) {
        guard isListOpen, let list else { return }
        tabWaiting = false
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
    /// reporting the line. Keys held while a folder was listed go out.
    func closeList() {
        tabWaiting = false
        guard state.openID != nil else { return }
        closeKeys()
        state.closed()
        listClosed()
        release()
        changed()
    }

    /// The close keys for the lists open on the shell's side: the open one, and the one zsh is making for a folder gone
    /// into.
    private func closeKeys() {
        guard let id = state.openID, state.path != .screen else { return }
        write(CompletionProtocol.close(id: id))
        if let to = state.drillID, to != id { write(CompletionProtocol.close(id: to)) }
    }

    /// The list can't be shown (its window isn't in front): on zsh's path zsh lists as it would by itself;
    /// Next Term's own list just closes.
    func cannotShow() {
        tabWaiting = false
        if state.isDrilling { return closeList() }
        guard let id = state.openID ?? state.pendingID else { return }
        if state.path == .completionSystem {
            write(CompletionProtocol.frame(.native, id: id))
            state.steppedBack(id)
            listClosed()
            release()
            changed()
        } else {
            closeList()
        }
    }

    private func listClosed() {
        loadingTimer?.cancel()
        drillTimer?.cancel()
        drillFallback = nil
        drillFrom = nil
        drillEcho = nil
        takeEchoes = []
        singleInsert = nil
        singleKeys = nil
        // The list's keys that waited go; the keys typed after them go out after the writes held before them.
        held += queue.close().map { .bytes(ArraySlice($0)) }
        syncToken = nil
        syncDeadline?.cancel()
        echoPoll?.cancel()
        echoPoll = nil
        echoSince = nil
        chosenList = nil
        intoID = nil
        upPending = false
        acceptPending = false
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

    /// The tab's connection dropped. A plain tab's shell went with it, and a reconnected one may have no hook (one
    /// removed on the server); a tmux pane's shell is reached again as it was. Either way what its hook said no
    /// longer holds until it says so again, so no private key goes out before then, and its prompt is trusted again
    /// only from new status reports.
    func connectionLost() {
        shellReplaced()
        reportsSinceReturn = 0
    }

    /// A status report for this server tab (TerminalTab.applyRemote): what it says about the prompt, whether it
    /// gave the shell's folder (not where there is no /proc), and that folder to prefetch. A host whose hook is
    /// allowed is checked for it now and then, while Tab completion is on and the connection has room: the check is
    /// a session of its own, and may bring the hook up to date.
    func remoteReport(folder: Bool) {
        reportsSinceReturn += 1
        serverFolderKnown = folder
        guard let tab else { return }
        if reportsSinceReturn >= 2 { RemoteCompletion.shared.prefetch(tab) }
        if let host = tab.remote?.host, CompletionPreferences.isOn, RemoteCompletion.shared.hasRoom(for: tab) {
            RemoteCompletionConsent.verify(host)
        }
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
            screenGiveUp(id)
            return true
        }
        guard screenReady, let id = state.startScreenTab() else {
            lastTab = .plain
            return false
        }
        lastTab = .listing(id)
        heldPaste = inPaste
        list = nil
        let deadline = DispatchWorkItem { [weak self] in self?.screenGiveUp(id) }
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
            let keys = made.screenCandidate(0).flatMap { made.screenInsertion($0, at: word) }
            // The single-match rule: one folder that can be entered goes in, with what is inside listed.
            if let keys, made.tabTarget(0) == .folder, let into = made.drillScreen(0), screenSingle(id, keys: keys, into: into) { return }
            screenAnswer(id, .insert, keys: keys)
        case .open:
            list = made
            screenAnswer(id, .open)
        }
    }

    /// The Tab can't wait any more for what it listed (its deadline, a key typed, another Tab): the shell's own Tab, or
    /// the one folder whose inside was being listed, alone.
    private func screenGiveUp(_ id: Int) {
        if let single = singleKeys, single.id == id {
            singleKeys = nil
            return screenAnswer(id, .insert, keys: single.keys)
        }
        screenAnswer(id, .native)
    }

    /// One folder goes in on a server's screen: what is inside is listed within the Tab's deadline. False: it can't be
    /// listed now, so the name goes in alone.
    private func screenSingle(_ id: Int, keys: (erase: Int, text: String), into: ScreenWord) -> Bool {
        guard let tab, let request = RemoteCompletion.shared.request(typed: into.folder, in: tab) else { return false }
        singleKeys = (id, keys)
        let listing = RemoteCompletion.shared.list(request, for: tab) { [weak self] result in
            self?.screenSingleListed(id, keys: keys, into: into, result)
        }
        if !listing { singleKeys = nil }
        return listing
    }

    private func screenSingleListed(_ id: Int, keys: (erase: Int, text: String), into: ScreenWord, _ result: RemoteListing.Result?) {
        guard state.pendingID == id, state.path == .screen, singleKeys?.id == id else { return }
        singleKeys = nil
        guard let result else { return screenAnswer(id, .insert, keys: keys) }
        let inside = CompletionList(id: id, screen: into, listing: result.listing, disk: result.disk, shell: result.quoting)
        guard !inside.rows.isEmpty else { return screenAnswer(id, .insert, keys: keys) }
        screenDeadline?.cancel()
        typeOnScreen(keys)
        list = inside
        drillEcho = (into, TerminalTab.now + 1, false)
        announce(into: String(into.folder.dropLast().split(separator: "/").last ?? ""), inside)
        screenAnswer(id, .open)
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
        if text.isEmpty {
            // Only Backspaces (← back up): no empty paste after them.
        } else if view.getTerminal().bracketedPasteMode {
            bytes += Array("\u{1b}[200~".utf8) + text + Array("\u{1b}[201~".utf8)
        } else {
            bytes += text
        }
        pass(bytes)
    }

    /// Output in a server tab with its list shown: a key echoed, so the list narrows to the word on screen, or the
    /// line changed around it, and it closes. Right after going into a folder, the name and `/` are still echoing: what
    /// is on the way doesn't close it (a second at most). ⌫ that took the `/` goes back up.
    fileprivate func screenOutput() {
        guard isShown, let list, let tab, !state.isDrilling else { return }
        guard let left = tab.lineLeftOfCursor() else { return closeList() }
        let read = ScreenWord.read(left)
        if let echo = drillEcho {
            let arrived = read.map { $0.before == echo.word.before && (echo.exact ? $0.word == echo.word.word : $0.folder == echo.word.folder) } ?? false
            if !arrived, TerminalTab.now < echo.until { return }
            drillEcho = nil
            // Going in, the name never echoed; going up, the screen moved on past the word: it is read as it is now.
            if !arrived, !echo.exact { return closeList() }
        }
        if let read, let above = list.backUp(screen: read) { return wentBackUp(above) }
        guard let now = list.screenWord?.next(left), list.update(screen: now) else { return closeList() }
        changed()
    }

    /// A row chosen on a server's list: once what was typed has echoed (300 ms at most), the keys that put it in
    /// place of the name on screen. The list's keys wait meanwhile; the keys typed after them go out after the name.
    fileprivate func screenAccept(_ candidate: PathCompletion.Candidate, text: String, _ list: CompletionList, since start: TimeInterval) {
        acceptPending = false
        guard state.openID == list.id, let tab else { return release() }
        if !settled(tab), TerminalTab.now - start < 0.3 {
            acceptPending = true
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
        release()
    }
}

// MARK: going into a folder (CompletionDrill)

extension CompletionSession {
    /// ⇥ on a folder row: on each of the list's paths, the folder is listed, then its name and `/` go on the line and the
    /// list shows what is inside. Nothing inside: the name goes in alone and the list closes; it can't be entered: a beep,
    /// and the list stays; not listed in time: the name goes in alone.
    fileprivate func drill(_ index: Int, _ list: CompletionList) {
        // Keys typed before ⇥ are the list's own: only those typed from now on make a key that waits ask for the word.
        queue.walkBegan()
        switch state.path {
        case .engine?: engineDrill(index, list)
        case .completionSystem?: zshDrill(index, list)
        case .screen?: screenDrill(index, list)
        case nil: break
        }
    }

    /// The deadline for a folder Next Term lists: past it, `fallback` puts the name on the line alone.
    private func startDrill(_ to: Int, within seconds: TimeInterval, fallback: @escaping () -> Void) {
        drills += 1
        drillFallback = fallback
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.state.drillID == to, let fallback = self.drillFallback else { return }
            self.lastDrill = .wentIn
            fallback()
        }
        drillTimer?.cancel()
        drillTimer = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: deadline)
    }

    /// Next Term's own engine: the folder listed on this Mac (0.1 s at most) or on a hooked server (its listing's
    /// deadline), and the take that keeps the list open.
    private func engineDrill(_ index: Int, _ list: CompletionList) {
        guard let into = list.drillContext(index), let take = list.drillTake(index) else { return accept(index) }
        guard let to = state.startDrill() else { return }
        let name = list.rows[index].text
        let wentIn = { [weak self] in self?.drillWentIn(index, list) ?? () }
        let finish: (PathCompletion.Listing, PathCompletion.Prepared, PathCompletion.Result) -> Void = { [weak self] listing, prepared, result in
            self?.engineDrilled(to, name: name, take: take, from: (list, index), into: into, listing, prepared, result)
        }
        if let tab, tab.remote != nil {
            startDrill(to, within: RemoteCompletion.deadline, fallback: wentIn)
            guard let request = RemoteCompletion.shared.request(absolute: into.folder, in: tab) else { return wentIn() }
            let listing = RemoteCompletion.shared.list(request, for: tab) { result in
                guard let result else {
                    let unread = PathCompletion.Listing(folder: into.folder, entries: [], complete: false, allSeen: false, readable: false)
                    return finish(unread, PathCompletion.Prepared(unread, foldersOnly: true, hidden: false), PathCompletion.Result())
                }
                let prepared = PathCompletion.Prepared(result.listing, foldersOnly: into.kind == .folders, hidden: into.showsHidden, disk: result.disk)
                finish(result.listing, prepared, prepared.candidates(into.typed))
            }
            if !listing { wentIn() }
            return
        }
        startDrill(to, within: CompletionProtocol.answerWithin, fallback: wentIn)
        let started = lister.start(into.folder) { listing in
            let prepared = PathCompletion.Prepared(listing, foldersOnly: into.kind == .folders, hidden: into.showsHidden)
            let result = listing.readable ? prepared.candidates(into.typed) : PathCompletion.Result()
            DispatchQueue.main.async { finish(listing, prepared, result) }
        }
        // A listing still stuck (a hung volume): the name goes in alone.
        if !started { wentIn() }
    }

    private func engineDrilled(_ to: Int, name: String, take: [UInt8], from: (list: CompletionList, row: Int), into: CompletionContext,
                               _ listing: PathCompletion.Listing, _ prepared: PathCompletion.Prepared, _ result: PathCompletion.Result) {
        guard state.drillID == to, state.path == .engine || state.path == .completionSystem, list === from.list else { return }
        drillTimer?.cancel()
        let step = CompletionDrill.step(listing, shown: result.candidates.count)
        lastDrill = step
        switch step {
        case .wentIn:
            return drillWentIn(from.row, from.list)
        case .refused:
            NSSound.beep()
            state.drilled(.refused)
        case .into:
            let inside = CompletionList(id: from.list.id, context: into, listing: listing, prepared: prepared, result: result)
            inside.drilled(from: from.list, row: from.row)
            write(take)
            takeEchoes.append(inside.word)
            list = inside
            state.drilled(.into)
            announce(into: name, inside)
        }
        drillFallback = nil
        release()
        changed()
    }

    /// The name goes on the line alone and the list closes, as ↩︎ puts it; then the keys held meanwhile.
    private func drillWentIn(_ index: Int, _ list: CompletionList) {
        guard state.isDrilling else { return }
        drillTimer?.cancel()
        drillFallback = nil
        lastDrill = .wentIn
        accept(index)
        release()
    }

    /// zsh's path: the hook puts the folder in as zsh's own Tab would and sends what is inside under a new id (comp), or
    /// says nothing is inside (done inserted) or it can't be entered (done kept). Writes wait 120 ms, as for a Tab; a
    /// Loading row shows past 150 ms.
    private func zshDrill(_ index: Int, _ list: CompletionList) {
        guard let to = state.startDrill() else { return }
        guard let key = list.drillTake(index, to: to) else {
            state.drilled(.refused)
            return accept(index)
        }
        drills += 1
        drillFrom = (list, index)
        assembler.reset()
        write(key)
        let hold = DispatchWorkItem { [weak self] in self?.holdExpired(to) }
        holdTimer?.cancel()
        holdTimer = hold
        DispatchQueue.main.asyncAfter(deadline: .now() + answerWithin, execute: hold)
        let loading = DispatchWorkItem { [weak self] in
            guard let self, self.state.drillID == to else { return }
            self.list = nil
            self.changed()
        }
        loadingTimer?.cancel()
        loadingTimer = loading
        DispatchQueue.main.asyncAfter(deadline: .now() + CompletionProtocol.shellWait, execute: loading)
    }

    /// zsh's word on a folder gone into: nothing inside (the name went in, the list closes), or it can't be entered
    /// (a beep; the list as it was).
    fileprivate func zshDrillDone(_ id: Int, _ outcome: CompletionProtocol.Outcome) {
        holdTimer?.cancel()
        loadingTimer?.cancel()
        let from = drillFrom
        drillFrom = nil
        state.done(id, outcome)
        if outcome == .kept {
            lastDrill = .refused
            NSSound.beep()
            if list == nil { list = from?.list }
        } else {
            lastDrill = .wentIn
            listClosed()
            if let from, from.list.rows.indices.contains(from.row) { CompletionPopup.announce("Inserted \(from.list.rows[from.row].text)") }
        }
    }

    /// A server's screen: the folder listed over the connection within the listing's deadline, then the name's keys.
    private func screenDrill(_ index: Int, _ list: CompletionList) {
        guard let tab, let candidate = list.screenCandidate(index), let into = list.drillScreen(index),
              let request = RemoteCompletion.shared.request(typed: into.folder, in: tab) else { return accept(index) }
        guard let to = state.startDrill() else { return }
        let start = TerminalTab.now
        let wentIn = { [weak self] in self?.screenDrillWentIn(to, candidate, list, since: start) ?? () }
        startDrill(to, within: RemoteCompletion.deadline, fallback: wentIn)
        let listing = RemoteCompletion.shared.list(request, for: tab) { [weak self] result in
            self?.screenDrilled(to, from: (list, index), candidate: candidate, into: into, result, since: start)
        }
        if !listing { wentIn() }
    }

    /// The keys typed before ⇥ (`start`) echo before the screen's word is read, as for ↩︎ (screenAccept): 300 ms at most.
    /// A listing kept from a moment ago comes back at once, before they have. True: `retry` runs again shortly.
    private func echoPending(since start: TimeInterval, _ retry: @escaping () -> Void) -> Bool {
        guard let tab, !settled(tab), TerminalTab.now - start < 0.3 else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015, execute: retry)
        return true
    }

    private func screenDrilled(_ to: Int, from: (list: CompletionList, row: Int), candidate: PathCompletion.Candidate, into: ScreenWord,
                               _ result: RemoteListing.Result?, since start: TimeInterval) {
        guard state.drillID == to, state.path == .screen, list === from.list, let tab else { return }
        drillTimer?.cancel()
        drillFallback = nil
        if echoPending(since: start, { [weak self] in self?.screenDrilled(to, from: from, candidate: candidate, into: into, result, since: start) }) {
            return
        }
        guard let result else {
            lastDrill = .refused
            NSSound.beep()
            state.drilled(.refused)
            release()
            return changed()
        }
        let inside = CompletionList(id: from.list.id, screen: into, listing: result.listing, disk: result.disk, shell: result.quoting)
        guard !inside.rows.isEmpty else { return screenDrillWentIn(to, candidate, from.list, since: start) }
        guard let left = tab.lineLeftOfCursor(), let now = from.list.screenWord?.next(left),
              let keys = from.list.screenInsertion(candidate, at: now) else {
            NSSound.beep()
            return closeList()
        }
        inside.drilled(from: from.list, row: from.row)
        typeOnScreen(keys)
        list = inside
        drillEcho = (into, TerminalTab.now + 1, false)
        state.drilled(.into)
        lastDrill = .into
        announce(into: from.list.rows.indices.contains(from.row) ? from.list.rows[from.row].text : "", inside)
        release()
        changed()
    }

    /// On a server's screen: the name's keys alone, and the list closes; then the keys held meanwhile.
    private func screenDrillWentIn(_ to: Int, _ candidate: PathCompletion.Candidate, _ list: CompletionList, since start: TimeInterval) {
        guard state.drillID == to, let tab else { return }
        drillTimer?.cancel()
        drillFallback = nil
        if echoPending(since: start, { [weak self] in self?.screenDrillWentIn(to, candidate, list, since: start) }) { return }
        lastDrill = .wentIn
        guard let left = tab.lineLeftOfCursor(), let now = list.screenWord?.next(left), let keys = list.screenInsertion(candidate, at: now) else {
            NSSound.beep()
            return closeList()
        }
        state.drilled(.wentIn)
        listClosed()
        typeOnScreen(keys)
        release()
        changed()
        CompletionPopup.announce("Inserted \(String(decoding: candidate.name, as: UTF8.self))/")
    }

    /// ⌫ took the `/` after a folder gone into: the list it was gone into from, as it was, with that folder chosen. On
    /// zsh's path the hook opens that list again too.
    fileprivate func wentBackUp(_ above: CompletionList) {
        guard let list else { return }
        if state.path == .completionSystem {
            write(CompletionProtocol.backUp(id: list.id, to: above.id))
            state.reopened(above.id)
        }
        showUp(above)
    }

    /// ← in a folder gone into: the word it was gone into from goes back on the line in place of the word now (Next
    /// Term's take on its own engine, the hook's `u` on zsh's path, keys on a server's screen), and the list it was gone
    /// into from shows, as it was, with that folder chosen.
    fileprivate func goUp() {
        guard let list, list.parent != nil else { return }
        if state.path == .screen { return screenUp(list, since: TerminalTab.now) }
        guard let take = list.upTake(), let above = list.goUp() else { return NSSound.beep() }
        write(take)
        if state.path == .completionSystem { state.reopened(above.id) } else { takeEchoes.append(above.word) }
        showUp(above)
    }

    /// ← on a server's screen: once what was typed has echoed (300 ms at most), Backspaces back to the word gone in
    /// from (and the rest of it, typed). The list that was open meanwhile stays until the screen shows that word.
    private func screenUp(_ list: CompletionList, since start: TimeInterval) {
        upPending = false
        guard state.openID == list.id, self.list === list, !state.isDrilling, let tab else { return release() }
        if !settled(tab), TerminalTab.now - start < 0.3 {
            upPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in self?.screenUp(list, since: start) }
            return
        }
        defer { release() }
        guard let left = tab.lineLeftOfCursor(), let now = list.screenWord?.next(left), let keys = list.upKeys(at: now),
              let above = list.goUp(), let word = above.screenWord else { return NSSound.beep() }
        typeOnScreen(keys)
        drillEcho = (word, TerminalTab.now + 1, true)
        showUp(above)
    }

    /// The list gone back up to shows, its folder chosen; VoiceOver says so ("Back up, projects, 3 of 5").
    private func showUp(_ above: CompletionList) {
        list = above
        backUps += 1
        if let row = above.preferredRow {
            announced = above
            CompletionPopup.announce(CompletionDrill.backUpAnnouncement(above.rows[row].text, row: row, of: above.rows.count))
        }
        changed()
    }

    /// The single-match rule on Next Term's own engine: the one folder's inside, listed within the Tab's answer time.
    /// Past it (holdExpired), or with nothing inside, the name goes in alone. False: it can't be listed now.
    fileprivate func singleDrill(_ id: Int, word: String, name: String, into: CompletionContext) -> Bool {
        let finish: (PathCompletion.Listing, PathCompletion.Prepared, PathCompletion.Result) -> Void = { [weak self] listing, prepared, result in
            self?.singleListed(id, word: word, name: name, into: into, listing, prepared, result)
        }
        singleInsert = (id, word)
        var started: Bool
        if let tab, tab.remote != nil {
            guard let request = RemoteCompletion.shared.request(absolute: into.folder, in: tab) else {
                singleInsert = nil
                return false
            }
            started = RemoteCompletion.shared.list(request, for: tab) { result in
                guard let result else {
                    let unread = PathCompletion.Listing(folder: into.folder, entries: [], complete: false, allSeen: false, readable: false)
                    return finish(unread, PathCompletion.Prepared(unread, foldersOnly: true, hidden: false), PathCompletion.Result())
                }
                let prepared = PathCompletion.Prepared(result.listing, foldersOnly: into.kind == .folders, hidden: into.showsHidden, disk: result.disk)
                finish(result.listing, prepared, prepared.candidates(into.typed))
            }
        } else {
            started = lister.start(into.folder) { listing in
                let prepared = PathCompletion.Prepared(listing, foldersOnly: into.kind == .folders, hidden: into.showsHidden)
                let result = listing.readable ? prepared.candidates(into.typed) : PathCompletion.Result()
                DispatchQueue.main.async { finish(listing, prepared, result) }
            }
        }
        if !started, singleInsert?.id == id { singleInsert = nil }
        return started
    }

    private func singleListed(_ id: Int, word: String, name: String, into: CompletionContext, _ listing: PathCompletion.Listing,
                              _ prepared: PathCompletion.Prepared, _ result: PathCompletion.Result) {
        guard state.pendingID == id, singleInsert?.id == id else { return }
        singleInsert = nil
        if CompletionDrill.step(listing, shown: result.candidates.count) == .into {
            holdTimer?.cancel()
            let inside = CompletionList(id: id, context: into, listing: listing, prepared: prepared, result: result)
            list = inside
            write(CompletionProtocol.insertAnswer(id: id, word: word, open: true))
            state.answered(id, .open)
            announce(into: name, inside)
        } else {
            answer(id, .insert, word: word)
        }
        release()
        changed()
    }

    /// VoiceOver, on going into a folder: "In projects, 12 items".
    fileprivate func announce(into name: String, _ inside: CompletionList) {
        announced = inside
        let folder = name.hasSuffix("/") ? String(name.dropLast()) : name
        CompletionPopup.announce(CompletionDrill.announcement(into: folder, total: inside.total, exact: inside.exact))
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
