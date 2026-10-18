import AppKit
import NextTermCore

/// Runs one herdr command (HerdrCommand) for a tab that shows herdr: on its host, over the tab's own ssh connection, as
/// every check does (it never logs in), or for herdr in a local tab, as a process on this Mac (runHere). On a host, two
/// at a time per connection beside the status check, as sshd's MaxSessions leaves room for (10 by default, and each tab
/// is one); the others wait their turn, up to their own time limit. Text for an agent goes on the script's stdin, never
/// into it, and here as one argument no shell reads. A command that changes what herdr shows (a prompt, keys, a focus)
/// asks for a check soon after, so the tab follows. Completions run on the main thread.
enum HerdrRunner {
    /// The most commands running at once on one connection, besides the status check.
    static let perConnection = 2

    private static var running: [String: Int] = [:]
    private static var waiting: [String: [() -> Void]] = [:]

    /// Runs `command` for `tab`, with `input` as the text it sends (prompt, text), within `timeout` seconds of now.
    /// `machine`: one of the machines saved in the tab's herdr on this Mac, reached through that herdr (`--machine`).
    static func run(_ command: HerdrCommand, for tab: TerminalTab, machine: String? = nil, input: String? = nil, timeout: TimeInterval = 15,
                    completion: @escaping (HerdrResult) -> Void) {
        run(command, for: tab, machine: machine, input: input, timeout: timeout) { result, _ in completion(result) }
    }

    /// The same, also saying which verb answered ("tab focus" when this herdr had no `agent focus`).
    static func run(_ command: HerdrCommand, for tab: TerminalTab, machine: String? = nil, input: String? = nil, timeout: TimeInterval = 15,
                    reporting completion: @escaping (HerdrResult, _ verb: String?) -> Void) {
        if tab.remote == nil, let client = tab.localHerdr {
            return runHere(command, client: client, machine: machine, input: input, timeout: timeout, completion: completion)
        }
        if machine != nil { return completion(.unreachable("herdr's saved machines are reached only through a herdr on this Mac."), nil) }
        guard let remote = tab.remote, remote.keep == .herdr, !tab.fellBack, let path = tab.controlPath else {
            return completion(.unreachable("That tab does not show herdr."), nil)
        }
        let session = remote.herdrSession
        guard let script = command.script(session: session) else {
            return completion(.error(code: "", message: command.refusal(session: session) ?? "That herdr command cannot be built."), nil)
        }
        let deadline = TerminalTab.now + timeout
        let host = remote.host
        take(path) { done in
            let left = deadline - TerminalTab.now
            guard left >= 1 else {
                done()
                return completion(.unreachable("\(host.name) is busy with other herdr commands; nothing was sent. Try again."), nil)
            }
            RemoteConnection.run(host, path: path, script: script, input: input.map { Data($0.utf8) }, timeout: left) { output in
                done()
                completion(result(output, readsText: command.readsText), HerdrResult.lastVerb(output.output))
                if command.changesHerdr { RemotePoller.shared.pollSoon(path) }
            }
        }
    }

    /// herdr on this Mac (a local tab's client): its argument lists run one by one off the main thread, no shell between,
    /// the text as one argument; an attempt whose verb this herdr lacks gives way to the next.
    private static func runHere(_ command: HerdrCommand, client: LocalHerdrClient, machine: String?, input: String?,
                                timeout: TimeInterval, completion: @escaping (HerdrResult, String?) -> Void) {
        // A machine has its own herdr session, and herdr's list of machines is no session's: the client's session is not
        // passed with either, which herdr would refuse.
        let session = machine == nil && command != .machines ? client.session : nil
        guard let attempts = command.argv(executable: client.executable, session: session, machine: machine, text: input) else {
            let refusal = command.refusal(session: session, machine: machine) ?? "That herdr command cannot be built."
            return completion(.error(code: "", message: refusal), nil)
        }
        let environment = client.processEnvironment
        let deadline = Date().addingTimeInterval(timeout)
        DispatchQueue.global(qos: .utility).async {
            let (result, verb) = runAttempts(attempts, command: command, environment: environment, deadline: deadline)
            DispatchQueue.main.async {
                completion(result, verb)
                if command.changesHerdr { LocalHerdrWatch.shared.checkSoon() }
            }
        }
    }

    /// The attempts in turn, off the main thread: the first whose verb this herdr has answers; a call after the first
    /// in an attempt runs only when the one before it worked.
    private static func runAttempts(_ attempts: [[[String]]], command: HerdrCommand, environment: [String: String],
                                    deadline: Date) -> (HerdrResult, String?) {
        var verb: String?
        for attempt in attempts {
            var said: HerdrResult = .cut
            for call in attempt {
                verb = HerdrCommand.verb(of: call)
                let left = deadline.timeIntervalSinceNow
                guard left >= 1 else { return (.unreachable("herdr did not answer in time."), verb) }
                let ran = LocalHerdr.run(call, environment: environment, timeout: left)
                if let failure = ran.failure { return (.unreachable(failure), verb) }
                said = ran.output.count > HerdrResult.outputCap ? .cut
                    : HerdrResult.make(exit: ran.status, out: ran.output, err: ran.errors, firstVerb: command.verb, text: command.readsText)
                if ran.status != 0 { break } // the call after it in this attempt never runs
            }
            if case .unsupported = said { continue }
            return (said, verb)
        }
        return (.unsupported(command.verb), verb)
    }

    /// Moves herdr's view to `pane` in `tab` (the agent's own herdr tab, as `tab focus` for an older herdr).
    static func focus(_ pane: String, in tab: TerminalTab, completion: @escaping (HerdrResult) -> Void) {
        let herdrTab = tab.herdrTracker.agents.first { $0.paneID == pane }?.tabID
        run(.focus(pane: pane, tab: herdrTab), for: tab, completion: completion)
    }

    /// What `pane` shows now.
    static func readVisible(_ pane: String, in tab: TerminalTab, completion: @escaping (HerdrResult) -> Void) {
        run(.read(pane: pane, source: .visible, lines: nil), for: tab, completion: completion)
    }

    /// What ssh's answer says: the script's, or why there is none.
    private static func result(_ output: RemoteConnection.Output, readsText: Bool) -> HerdrResult {
        guard RemoteShell.payload(output.output) != nil else { return .unreachable(output.problem) }
        let said = HerdrResult.parse(output.output, text: readsText)
        if said == .cut, output.timedOut { return .unreachable("The host did not answer in time.") }
        return said
    }

    /// Runs `body` once the connection has room; it calls the closure it is given when its command is done.
    private static func take(_ path: String, _ body: @escaping (_ done: @escaping () -> Void) -> Void) {
        let start = {
            running[path, default: 0] += 1
            var finished = false
            body {
                guard !finished else { return }
                finished = true
                running[path, default: 1] -= 1
                if let next = waiting[path]?.first {
                    waiting[path]?.removeFirst()
                    next()
                }
            }
        }
        if running[path, default: 0] < perConnection { return start() }
        waiting[path, default: []].append(start)
    }
}
