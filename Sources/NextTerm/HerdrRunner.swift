import AppKit
import NextTermCore

/// Runs one herdr command (HerdrCommand) for a tab that shows herdr, on its host, over the tab's own ssh connection, as
/// every check does (it never logs in). Two at a time per connection beside the status check, as sshd's MaxSessions
/// leaves room for (10 by default, and each tab is one); the others wait their turn, up to their own time limit. Text for
/// an agent goes on the script's stdin, never into it. A command that changes what herdr shows (a prompt, keys, a focus)
/// asks for a check soon after, so the tab follows. Completions run on the main thread.
enum HerdrRunner {
    /// The most commands running at once on one connection, besides the status check.
    static let perConnection = 2

    private static var running: [String: Int] = [:]
    private static var waiting: [String: [() -> Void]] = [:]

    /// Runs `command` for `tab`, with `input` as the text it sends (prompt, text), within `timeout` seconds of now.
    static func run(_ command: HerdrCommand, for tab: TerminalTab, input: String? = nil, timeout: TimeInterval = 15,
                    completion: @escaping (HerdrResult) -> Void) {
        run(command, for: tab, input: input, timeout: timeout) { result, _ in completion(result) }
    }

    /// The same, also saying which verb answered ("tab focus" when this herdr had no `agent focus`).
    static func run(_ command: HerdrCommand, for tab: TerminalTab, input: String? = nil, timeout: TimeInterval = 15,
                    reporting completion: @escaping (HerdrResult, _ verb: String?) -> Void) {
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
