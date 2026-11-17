import AppKit
import NextTermCore

/// forward_prompt (plan 042): prompts the user typed into an agent's tab by mistake go to the session they were meant for.
///
/// - **Only the user's own prompts.** When the caller runs Claude Code or Codex, each prompt must be one of the user's
///   turns at the tail of its transcript (PromptHandover.isUsersPrompt), so text from a file or a tool result never goes
///   across as the user's request.
/// - **Which session.** Agent tabs on this Mac in every window (never the caller's), then closed Claude Code and Codex
///   sessions of the open and recent projects, ranked in Core (PromptHandover.rank). One clear match is sent; several
///   ask the user on the Mac (HandoverPicker); `session` names the one the user chose after a not_moved answer.
/// - **Delivery.** Only into an agent that is its tab's running program and idle (never working, never asking a
///   question, where Return would answer it, never starting), checked before the paste and again before the Return; a
///   closed session is resumed in a tab first. An agent gone meanwhile gets nothing: a bare shell would run the text.
/// - **The answer.** Text and the same facts as structured JSON; of other candidates only id, project, agent and whether
///   open. Past 50 seconds it answers pending with a request_id.
@MainActor
enum MCPHandoverControl {
    typealias Reply = MCPControl.Reply

    /// How long a call waits before answering pending (the bridge waits the tool's 60 s and more).
    static var answerWithin: TimeInterval = 50
    /// How long delivery waits for the target to be idle, and a resumed session to start.
    static var readyWithin: TimeInterval = 600
    static var resumeWithin: TimeInterval = 120

    /// A hand-over still running, or finished and not yet collected, by request id.
    final class Run {
        let id = UUID().uuidString.lowercased()
        var result: MCPServer.CallResult?
        var waiting: [Reply] = []
        func finish(_ answer: MCPServer.CallResult) {
            guard result == nil else { return }
            result = answer
            let replies = waiting
            waiting = []
            for reply in replies { reply(answer) }
        }
    }

    private(set) static var runs: [String: Run] = [:]

    static func call(_ arguments: [String: Any], caller: TerminalTab?, reply: @escaping Reply) {
        if let id = arguments["request_id"] as? String {
            guard let run = runs[id] else { return reply(fail("No hand-over with that request_id is waiting.")) }
            return wait(on: run, reply: reply)
        }
        if let extra = arguments.keys.first(where: { !MCPServer.handoverArguments.contains($0) }) {
            return reply(fail("forward_prompt takes no \(extra)."))
        }
        let prompts = (arguments["prompts"] as? [Any] ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !prompts.isEmpty else { return reply(fail("Pass the prompts meant for the other session, in the order given.")) }
        let hint = arguments["hint"] as? String ?? ""
        let note = arguments["note"] as? String
        let images = (arguments["images"] as? [Any] ?? []).compactMap { $0 as? String }
        if let image = images.first(where: { !$0.hasPrefix("/") || !FileManager.default.fileExists(atPath: $0) }) {
            return reply(fail("Not an image file on this Mac (give an absolute path): \(image)"))
        }
        let chosen = arguments["session"] as? String
        let run = Run()
        runs[run.id] = run
        wait(on: run, reply: reply)
        let from = caller.map { $0.title } ?? "another"
        let request = Request(prompts: prompts, hint: hint, note: note, images: images, from: from, callerID: caller?.id,
                              callerTranscript: caller.flatMap(transcript(of:)))
        let excluded = caller.map { [$0.id] } ?? []
        let tabs = openCandidates(excluding: excluded)
        let projects = Array(Set(AppDelegate.shared.controllers.compactMap(\.project) + AppDelegate.shared.recentProjects))
        Task.detached {
            let check = request.callerTranscript.map { userTurns(at: $0) }
            let open = tabs.map { item -> PromptHandover.Candidate in
                var candidate = item.candidate
                candidate.recentPrompts = item.transcript.map { userTurns(at: $0) } ?? []
                return candidate
            }
            let closed = closedCandidates(in: projects, excludingSessions: Set(tabs.compactMap(\.sessionID)))
            await MainActor.run {
                if let turns = check, !turns.isEmpty,
                   let stray = request.prompts.first(where: { !PromptHandover.isUsersPrompt($0, among: turns) }) {
                    let shown = stray.count > 80 ? String(stray.prefix(79)) + "\u{2026}" : stray
                    return run.finish(fail("Nothing moved: \u{201C}\(shown)\u{201D} isn\u{2019}t one of the user\u{2019}s recent prompts here. "
                        + "Pass only prompts the user typed to you."))
                }
                decide(request, candidates: open + closed.map(\.candidate), closed: closed, chosen: chosen, run: run)
            }
        }
    }

    // MARK: the request

    struct Request {
        var prompts: [String]
        var hint: String
        var note: String?
        var images: [String]
        var from: String
        var callerID: UUID?
        var callerTranscript: Transcript?
    }

    struct Transcript: Sendable {
        let path: String
        let kind: AgentTranscript.Kind
    }

    struct OpenItem: Sendable {
        var candidate: PromptHandover.Candidate
        var transcript: Transcript?
        var sessionID: String?
    }

    struct ClosedItem: Sendable {
        var candidate: PromptHandover.Candidate
        var session: AgentSession
    }

    /// Agent tabs on this Mac in every window, except `excluded`.
    static func openCandidates(excluding excluded: [UUID]) -> [OpenItem] {
        MCPControl.allTabs.compactMap { tab -> OpenItem? in
            guard !excluded.contains(tab.id), tab.remote == nil, !tab.exited, tab.status.running, tab.status.kind == .agent else { return nil }
            let kind = AgentKind(program: tab.status.program)
            let folder = MCPControl.controller(of: tab)?.project ?? tab.directory
            let candidate = PromptHandover.Candidate(id: tab.id.uuidString.lowercased(), open: true, agent: kind?.name ?? tab.status.program,
                                                     folder: folder, title: tab.title)
            let pid = tcgetpgrp(tab.view.process.childfd)
            let session = kind.flatMap { kind in (pid > 0 ? AgentSessions.sessionID(of: kind, pid: pid, home: SessionStore.home) : nil) ?? kind.resumedID(in: tab.status.command) }
            return OpenItem(candidate: candidate, transcript: transcript(of: tab), sessionID: session)
        }
    }

    /// The transcript of the agent running in `tab`, for Claude Code and Codex.
    static func transcript(of tab: TerminalTab) -> Transcript? {
        guard tab.remote == nil, let kind = AgentKind(program: tab.status.program) else { return nil }
        let pid = tcgetpgrp(tab.view.process.childfd)
        let id = (pid > 0 ? AgentSessions.sessionID(of: kind, pid: pid, home: SessionStore.home) : nil) ?? kind.resumedID(in: tab.status.command)
        guard case .success(let locator) = AgentTranscript.locate(agent: kind, sessionID: id),
              case .success(let path) = AgentTranscript.only(AgentTranscript.candidates(locator, home: SessionStore.home,
                                                                                        environment: ProcessInfo.processInfo.environment))
        else { return nil }
        return Transcript(path: path, kind: locator.kind)
    }

    /// The user's turns at the tail of a transcript, oldest first; none when it can't be read.
    nonisolated static func userTurns(at transcript: Transcript) -> [String] {
        guard let read = AgentTranscript.readTail(transcript.path),
              let turns = AgentTranscript.turns(tail: read.tail, kind: transcript.kind) else { return [] }
        return turns.filter { $0.role == .user }.map(\.text).suffix(12)
    }

    /// Closed Claude Code and Codex sessions of `projects`, newest first, none of them open in a tab.
    nonisolated static func closedCandidates(in projects: [String], excludingSessions open: Set<String>, limit: Int = 40) -> [ClosedItem] {
        var seen = Set<String>()
        var sessions: [AgentSession] = []
        for project in projects {
            for session in AgentSessions.list(project: project, home: SessionStore.home, perAgent: 20).sessions
            where (session.agent == .claude || session.agent == .codex) && !session.isRunning && !open.contains(session.id) {
                if seen.insert(session.identity).inserted { sessions.append(session) }
            }
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit).map { session in
            ClosedItem(candidate: PromptHandover.Candidate(id: session.identity, open: false, agent: session.agent.name,
                                                           folder: session.cwd, title: session.title, branch: session.gitBranch),
                       session: session)
        }
    }

    // MARK: deciding

    static func decide(_ request: Request, candidates: [PromptHandover.Candidate], closed: [ClosedItem], chosen: String?, run: Run) {
        let text = PromptHandover.message(prompts: request.prompts, from: request.from, note: request.note, images: request.images)
        func go(_ candidate: PromptHandover.Candidate) {
            if candidate.open {
                guard let tab = MCPControl.allTabs.first(where: { $0.id.uuidString.lowercased() == candidate.id }) else {
                    return run.finish(notMoved("That tab is gone.", candidates: candidates))
                }
                deliver(text, to: tab, candidate: candidate, resumed: false, run: run)
            } else if let item = closed.first(where: { $0.candidate.id == candidate.id }) {
                resume(item, then: text, run: run)
            } else {
                run.finish(notMoved("That session is gone.", candidates: candidates))
            }
        }
        if let chosen {
            guard let candidate = candidates.first(where: { $0.id == chosen }) else {
                return run.finish(notMoved("No candidate has that session id.", candidates: candidates))
            }
            return go(candidate)
        }
        let ranking = PromptHandover.rank(candidates, hint: request.hint, prompts: request.prompts)
        if ranking.clear, let best = ranking.best { return go(best) }
        // Several fit, or none clearly: the user chooses, from the ones that matched first, then the rest.
        let shown = ranking.ranked.map(\.candidate) + candidates.filter { candidate in !ranking.ranked.contains { $0.candidate.id == candidate.id } }
        guard !shown.isEmpty else { return run.finish(notMoved("No other agent session is open or saved here.", candidates: [])) }
        HandoverPicker.ask(HandoverPicker.Request(text: text, from: request.from, candidates: Array(shown.prefix(12)))) { picked in
            guard let picked else {
                return run.finish(notMoved("The user didn\u{2019}t choose a session, so nothing moved.", candidates: Array(shown.prefix(12))))
            }
            go(picked)
        }
    }

    // MARK: delivering

    /// The agent is its tab's running program, on this Mac, and the tab takes input.
    static func agentRuns(in tab: TerminalTab) -> Bool {
        !tab.exited && tab.remote == nil && tab.status.running && tab.status.kind == .agent && MCPControl.canType(tab)
    }

    /// Idle or done, never working, asking or starting.
    static func isReady(_ tab: TerminalTab) -> Bool {
        guard agentRuns(in: tab), !MCPControl.isStarting(tab) else { return false }
        return tab.status.state == .idle || tab.status.state == .done
    }

    /// How long the target must stay ready before anything is typed: a freshly resumed agent can look idle for a moment
    /// before its trust or update question shows.
    static var settle: (open: TimeInterval, resumed: TimeInterval) = (1, 3)

    /// Waits until the target is ready and has stayed so, then pastes the text and presses Return, checking again
    /// before the Return.
    static func deliver(_ text: String, to tab: TerminalTab, candidate: PromptHandover.Candidate, resumed: Bool, run: Run) {
        let deadline = TerminalTab.now + readyWithin
        var goneSince: TimeInterval?
        var readySince: TimeInterval?
        func look() {
            if isReady(tab) {
                let since = readySince ?? TerminalTab.now
                readySince = since
                if TerminalTab.now - since < (resumed ? settle.resumed : settle.open) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { look() } }
                    return
                }
                guard tab.view.getTerminal().bracketedPasteMode || !text.contains("\n") else {
                    return run.finish(fail("\(candidate.agent) in that tab doesn\u{2019}t take a pasted block, so nothing was typed."))
                }
                let typed = tab.view.typeText(text)
                MCPControl.sent(to: tab)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    MainActor.assumeIsolated {
                        guard agentRuns(in: tab), tab.status.state != .attention else {
                            return run.finish(fail("The text is in \(candidate.agent)\u{2019}s prompt in that tab but wasn\u{2019}t sent: "
                                + "it started asking something. The user can send it there."))
                        }
                        tab.submitOwnLine(typed)
                        run.finish(delivered(candidate, tab: tab, resumed: resumed))
                    }
                }
                return
            }
            readySince = nil
            if !agentRuns(in: tab) || tab.exited {
                // A moment between the shell and the agent is not "gone"; three seconds of no agent is.
                let since = goneSince ?? TerminalTab.now
                goneSince = since
                if TerminalTab.now - since > 3 || tab.exited {
                    return run.finish(fail("\(candidate.agent) is no longer running in that tab, so nothing was typed there."))
                }
            } else {
                goneSince = nil
            }
            guard TerminalTab.now < deadline else {
                return run.finish(fail("\(candidate.agent) in that tab stayed busy, so nothing was typed. Try again when it\u{2019}s done."))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { look() } }
        }
        look()
    }

    /// Opens a closed session in a tab of its project's window, then delivers once its agent runs and is idle.
    static func resume(_ item: ClosedItem, then text: String, run: Run) {
        let folder = FileManager.default.fileExists(atPath: item.session.cwd) ? item.session.cwd : item.candidate.folder
        guard FileManager.default.fileExists(atPath: folder) else {
            return run.finish(fail("That session\u{2019}s folder is gone, so it wasn\u{2019}t resumed."))
        }
        let (controller, _) = MCPControl.window(for: canonicalPath(folder))
        let tab = controller.addTab(directory: folder, select: false, byAgent: true)
        tab.userTitle = item.session.title
        _ = controller.presentForAgent(tab)
        controller.refresh()
        MCPControl.whenReady(tab, until: TerminalTab.now + 3) {
            MainActor.assumeIsolated { runResume(item, in: tab, then: text, run: run) }
        }
    }

    /// Types the session's resume command, then delivers once its agent has started.
    private static func runResume(_ item: ClosedItem, in tab: TerminalTab, then text: String, run: Run) {
        MCPControl.type(SessionStore.commandPrefix + item.session.resumeCommand(), into: tab, submit: true)
        let deadline = TerminalTab.now + resumeWithin
        func look() {
            if agentRuns(in: tab) { return deliver(text, to: tab, candidate: item.candidate, resumed: true, run: run) }
            guard TerminalTab.now < deadline, !tab.exited else {
                return run.finish(fail("\(item.candidate.agent) didn\u{2019}t start in the new tab, so nothing was typed there."))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { look() } }
        }
        look()
    }

    // MARK: answers

    static func wait(on run: Run, reply: @escaping Reply) {
        if let result = run.result {
            runs[run.id] = nil
            return reply(result)
        }
        var answered = false
        run.waiting.append { result in
            guard !answered else { return }
            answered = true
            runs[run.id] = nil
            reply(result)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + answerWithin) {
            MainActor.assumeIsolated {
                guard !answered else { return }
                answered = true
                let info: [String: Any] = ["status": "pending", "request_id": run.id,
                                           "note": "Still handing the prompts over (the target is busy or starting). Call forward_prompt again with this request_id."]
                reply(answer("Still handing the prompts over; call forward_prompt again with request_id \(run.id).", info))
            }
        }
    }

    static func delivered(_ candidate: PromptHandover.Candidate, tab: TerminalTab, resumed: Bool) -> MCPServer.CallResult {
        let project = candidate.project
        let info: [String: Any] = ["status": "delivered", "tab_id": tab.id.uuidString.lowercased(), "project": project,
                                   "agent": candidate.agent, "resumed": resumed]
        let how = resumed ? ", in a tab Next Term opened to resume that session" : ""
        return answer("Delivered to \(candidate.agent) in \(project)\(how). Stop work on those prompts, keep any changes you made, "
            + "and tell the user where they went and what you had changed.", info)
    }

    static func notMoved(_ why: String, candidates: [PromptHandover.Candidate]) -> MCPServer.CallResult {
        let listed: [[String: Any]] = candidates.map { ["id": $0.id, "project": $0.project, "agent": $0.agent, "open": $0.open] }
        let names = candidates.prefix(8).map { "\($0.project) (\($0.agent)\($0.open ? "" : ", closed"))" }.joined(separator: "; ")
        let text = why + (names.isEmpty ? "" : " Candidates: \(names). Ask the user which, then call forward_prompt again with its session id.")
        return answer(text, ["status": "not_moved", "candidates": listed, "note": why], isError: true)
    }

    static func answer(_ text: String, _ info: [String: Any], isError: Bool = false) -> MCPServer.CallResult {
        MCPServer.CallResult(text: text, isError: isError, structured: MCPServer.json(info))
    }

    static func fail(_ text: String) -> MCPServer.CallResult {
        answer(text, ["status": "not_moved", "note": text], isError: true)
    }
}
