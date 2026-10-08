import AppKit
import NextTermCore

/// One tab's side of Tab completion: its CompletionState, the private keys it sends, and the one ordered
/// writer to the shell. While an answer is owed, every write (the user's keys, an agent's text over MCP)
/// waits and then goes out in order, after the answer: at most 120 ms.
final class CompletionSession {
    private weak var tab: TerminalTab?
    private(set) var state = CompletionState()
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

    // MARK: writes

    /// Every write to the shell passes here (NextTermView.send, after interceptInput). True: it waits, and goes
    /// out later in order.
    func gate(_ data: ArraySlice<UInt8>) -> Bool {
        guard state.holding else {
            note(data)
            return false
        }
        held.append(.bytes(data))
        // Return and the like end the Tab at once: zsh's own Tab, then the keys, in order.
        if InputScan.scan(data, inPaste: &heldPaste).disarms, let id = state.pendingID {
            if state.path == .engine { answer(id, .native) } else { state.disarm() }
            release()
        }
        return true
    }

    /// Bytes on their way to the shell: what they mean for the state.
    private func note(_ data: ArraySlice<UInt8>) {
        #if DEBUG
        lastWrite = Array(data)
        #endif
        state.input(InputScan.scan(data, inPaste: &inPaste))
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
        write(CompletionProtocol.frame(.tab, id: id))
        let work = DispatchWorkItem { [weak self] in self?.holdExpired(id) }
        holdTimer?.cancel()
        holdTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CompletionProtocol.answerWithin, execute: work)
        return true
    }

    /// 120 ms: on Next Term's own path the answer is "native" now; either way the held writes go out.
    private func holdExpired(_ id: Int) {
        if state.holdExpired(id) { write(CompletionProtocol.nativeAnswer(id: id)) }
        release()
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

    // MARK: the shell's marks

    func handle(_ message: CompletionProtocol.Message) {
        switch message {
        case .arm(let arm):
            state.armed(arm)
        case .tab(let report):
            guard state.pendingID == report.id, state.path == .engine else { return }
            reports += 1
            // The line report only, for now: zsh's own Tab answers.
            answer(report.id, .native)
        case .done(let id, let outcome):
            lastDone = (id, outcome)
            state.done(id, outcome)
        case .comp, .line:
            break
        }
        release()
    }

    /// A command started, or the shell was replaced: nothing in flight survives it.
    func disarm() {
        holdTimer?.cancel()
        state.disarm()
        release()
    }
}
