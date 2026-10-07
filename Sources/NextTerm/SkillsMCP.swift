import AppKit
import NextTermCore

/// The Skills library's MCP tools. list_skills only reads. install_skill and remove_skill are requests:
/// the user sees each in an AgentApprovalWindow and decides; nothing is fetched or written on an agent's
/// say alone. One request is open at a time (others get `busy`). After the user declines, the asker
/// (its tab, or every caller outside Next Term's tabs) is told "declined" for ten minutes, or until
/// quit with Decline and Stop Asking, and a source declined once stays declined whatever ref or path is
/// asked next; no asker gets more than ten requests a session. A call answers within `answerWithin`
/// seconds, with `pending` and a request id to ask again with when the user has not decided yet (some
/// clients give up on a tool after 60 seconds).
@MainActor
enum SkillsMCP {
    typealias Reply = MCPControl.Reply

    /// How long a call waits for the user's decision before answering `pending`.
    static var answerWithin: TimeInterval = 50
    /// How long an asker is refused after a decline, and how many requests it may make in a session.
    static var cooldown: TimeInterval = 600
    static let maxRequestsPerAsker = 10

    final class Request {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        /// What is asked, for spotting the same request again: "install:owner/repo" or "remove:name".
        let key: String
        /// Who asked: a tab's id, or "outside" for callers outside Next Term's tabs.
        let asker: String
        /// The final answer, once the user has decided.
        var answer: [String: Any]?
        var waiters: [(token: UUID, reply: Reply)] = []
        /// The asking tab's id, to notice it closing.
        let callerTab: UUID?
        var window: AgentApprovalWindow?
        var review: SkillsReviewSheet?
        /// The fetch running after Fetch and Review, cancelled when the user declines.
        var task: Task<Void, Never>?

        init(key: String, asker: String, callerTab: UUID?) {
            self.key = key
            self.asker = asker
            self.callerTab = callerTab
        }
    }

    /// Requests by id; answered ones are dropped ten minutes after their answer.
    static var requests: [String: Request] = [:]
    static var open: Request? { requests.values.first { $0.answer == nil } }
    /// Sources and names declined until quit.
    static var declined = Set<String>()
    /// Askers refused until this date, or for good (Decline and Stop Asking).
    static var quietUntil: [String: Date] = [:]
    static var askedCount: [String: Int] = [:]

    static func call(_ tool: String, _ arguments: [String: Any], caller: TerminalTab?, reply: @escaping Reply) {
        switch tool {
        case "list_skills": Task { reply(MCPControl.ok(await listSkills())) }
        default: Task { await ask(tool, arguments, caller: caller, reply: reply) }
        }
    }

    // MARK: listing

    static func listSkills() async -> [String: Any] {
        let inventory = await SkillsStore.scan()
        let tracked = Dictionary(await SkillsInstaller.tracked().map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let recorded = Set(SkillsInstaller.records().map(\.name))
        let skills: [[String: Any]] = inventory.rows.map { row in
            var agents: [String: String] = [:]
            for agent in SkillAgent.allCases {
                let load = row.load(for: agent)
                agents[agent.rawValue] = load.skippedBecause != nil ? "skipped" : load.used == nil ? "none" : load.switchedOff ? "off" : "loads"
            }
            var item: [String: Any] = ["name": row.name, "agents": agents]
            if let description = row.distinctCopies.first?.frontMatter?.description { item["description"] = String(description.prefix(300)) }
            if let source = tracked[row.name] {
                item["source"] = source.source.shortName + (source.path.isEmpty ? "" : "/" + source.path)
                item["installed_by"] = recorded.contains(row.name) ? "next-term" : "npx skills"
            }
            switch SkillsInstaller.updates[row.name] {
            case .available?: item["update"] = "available"
            case .current?: item["update"] = "none"
            default: break
            }
            if row.health != .ok { item["state"] = SkillsSettingsView.stateText(row) }
            return item
        }
        return ["skills": skills]
    }

    // MARK: requests

    static func ask(_ tool: String, _ arguments: [String: Any], caller: TerminalTab?, reply: @escaping Reply) async {
        if let id = (arguments["request_id"] as? String)?.lowercased(), !id.isEmpty {
            guard let request = requests[id] else { return reply(MCPControl.fail("No request with that id; answered requests are forgotten after ten minutes.")) }
            return wait(request, reply: reply)
        }
        let reason = arguments["reason"] as? String
        let asker = caller.map { $0.id.uuidString } ?? "outside"
        let key: String
        var source: SkillSource?
        var removeName: String?
        if tool == "install_skill" {
            guard let text = arguments["source"] as? String, let parsed = SkillSource.parse(text) else {
                return reply(MCPControl.fail("Give source as owner/repo, owner/repo/path/to/skill, or a github.com link to a public repository."))
            }
            source = parsed
            // Declining a repository declines it whatever branch, commit or folder is asked next.
            key = "install:\(parsed.shortName)".lowercased()
        } else {
            guard let name = arguments["name"] as? String, !name.isEmpty else { return reply(MCPControl.fail("Give the skill's name, as list_skills shows it.")) }
            let (_, _, installed) = await SkillsInstaller.removal(name)
            guard installed else {
                return reply(MCPControl.fail("\(name) was not installed by Next Term or npx skills, so it can't be removed through a request; list_skills shows where each skill came from."))
            }
            removeName = name
            key = "remove:" + name
        }
        if declined.contains(key) {
            return reply(MCPControl.ok(["status": "declined", "note": "The user declined this earlier; it stays declined until Next Term quits."]))
        }
        if let until = quietUntil[asker], until > Date() {
            return reply(MCPControl.ok(["status": "declined", "note": "The user declined a request from you; do not ask again for now."]))
        }
        if let open {
            if open.key == key, open.asker == asker { return wait(open, reply: reply) }
            return reply(MCPControl.ok(["status": "busy", "note": "Another request is waiting for the user. Ask again later."]))
        }
        guard askedCount[asker, default: 0] < maxRequestsPerAsker else {
            return reply(MCPControl.ok(["status": "declined", "note": "Too many requests this session; ask the user directly instead."]))
        }
        askedCount[asker, default: 0] += 1
        let request = Request(key: key, asker: asker, callerTab: caller?.id)
        requests[request.id] = request
        let requester = describe(caller)
        if let source {
            openInstall(request, source: source, requester: requester, reason: reason)
        } else if let removeName {
            let (steps, leftovers, _) = await SkillsInstaller.removal(removeName)
            openRemove(request, name: removeName, steps: steps, leftovers: leftovers, requester: requester, reason: reason)
        }
        wait(request, reply: reply)
    }

    static func describe(_ caller: TerminalTab?) -> String {
        guard let caller else { return "an agent outside Next Term's tabs (another terminal or an editor)" }
        let project = MCPControl.controller(of: caller)?.project.map { " in \(($0 as NSString).lastPathComponent)" } ?? ""
        return "the agent in the tab “\(caller.title)”\(project)"
    }

    /// Answers with the request's outcome, or `pending` after `answerWithin` seconds.
    static func wait(_ request: Request, reply: @escaping Reply) {
        if let answer = request.answer { return reply(MCPControl.ok(answer)) }
        let token = UUID()
        request.waiters.append((token, reply))
        DispatchQueue.main.asyncAfter(deadline: .now() + answerWithin) {
            MainActor.assumeIsolated {
                guard let index = request.waiters.firstIndex(where: { $0.token == token }) else { return }
                request.waiters.remove(at: index)
                reply(MCPControl.ok(["status": "pending", "request_id": request.id,
                                     "note": "The user has not decided yet. Call again with only request_id to keep waiting."]))
            }
        }
    }

    static func resolve(_ request: Request, _ answer: [String: Any], stopAsking: Bool = false) {
        guard request.answer == nil else { return }
        request.answer = answer
        if answer["status"] as? String == "declined" {
            declined.insert(request.key)
            quietUntil[request.asker] = stopAsking ? .distantFuture : Date().addingTimeInterval(cooldown)
            request.task?.cancel()
        }
        let waiters = request.waiters
        request.waiters = []
        for waiter in waiters { waiter.reply(MCPControl.ok(answer)) }
        request.window = nil
        request.review = nil
        request.task = nil
        // The answer stays for a while, for an agent asking again with the id; then it is forgotten.
        let id = request.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { MainActor.assumeIsolated { _ = requests.removeValue(forKey: id) } }
    }

    /// While the request is open, notices the asking tab closing.
    static func watchRequester(_ request: Request) {
        guard let tab = request.callerTab else { return }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard request.answer == nil, let window = request.window else { return timer.invalidate() }
                if !AppDelegate.shared.controllers.flatMap(\.tabs).contains(where: { $0.id == tab }) {
                    window.requesterGone()
                    timer.invalidate()
                }
            }
        }
    }

    // MARK: install

    static func openInstall(_ request: Request, source: SkillSource, requester: String, reason: String?) {
        let place = "github.com/\(source.shortName)" + (source.path.isEmpty ? "" : "/" + source.path) + (source.ref.map { " (\($0))" } ?? "")
        let details = "From \(place). Nothing has been fetched yet: Fetch and Review downloads one commit and shows you every file before anything is installed."
        let window = AgentApprovalWindow(.init(title: "An agent asks to install a skill", requester: requester, agentWords: reason,
                                               details: details, approveTitle: "Fetch and Review…", stopTitle: "Decline and Stop Asking"),
                                         approve: { window in fetchAndReview(request, source: source, approval: window) },
                                         decline: { stop in resolve(request, ["status": "declined"], stopAsking: stop) })
        request.window = window
        window.present()
        watchRequester(request)
    }

    static func fetchAndReview(_ request: Request, source: SkillSource, approval: AgentApprovalWindow) {
        approval.setBusy(true)
        approval.setStatus("Fetching \(source.shortName)… Decline stops it.")
        request.task = Task {
            do {
                let fetched = try await SkillsInstaller.fetch(source)
                // Declined (or closed) while fetching: nothing opens.
                guard request.answer == nil, !Task.isCancelled else { return fetched.discard() }
                let sheet = SkillsReviewSheet(fetched: fetched) { names in
                    if let names {
                        resolve(request, ["status": "installed", "skills": names])
                    } else {
                        resolve(request, ["status": "declined"])
                    }
                }
                sheet.onDownloadGone = { message in
                    resolve(request, ["status": "failed", "note": message])
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "The skills were not changed"
                    alert.informativeText = message
                    alert.runModal()
                }
                request.review = sheet
                approval.finish()
                // Like the request, the review never takes the keyboard on its own: the user clicks into it.
                sheet.window?.center()
                sheet.window?.orderFront(nil)
                if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            } catch {
                guard request.answer == nil else { return }
                approval.setStatus((error as? SkillsGitHub.Failure)?.message ?? error.localizedDescription, problem: true)
                approval.setBusy(false)
            }
        }
    }

    // MARK: remove

    static func openRemove(_ request: Request, name: String, steps shown: [SkillStep], leftovers: [String], requester: String, reason: String?) {
        var lines = shown.map { "• " + $0.summary }
        lines.append("Agent sessions open now keep it until they restart.")
        lines += leftovers.map { "• " + $0 }
        lines.append("Undo in Settings › Skills puts it back.")
        let window = AgentApprovalWindow(.init(title: "An agent asks to remove the skill “\(name)”", requester: requester, agentWords: reason,
                                               details: lines.joined(separator: "\n"), approveTitle: "Remove", stopTitle: "Decline and Stop Asking"),
                                         approve: { window in
                                             window.setBusy(true)
                                             request.task = Task {
                                                 // Worked out again now: what the user saw must still be what happens.
                                                 let (steps, _, _) = await SkillsInstaller.removal(name)
                                                 // Declined meanwhile: the agent was told so, and nothing is removed.
                                                 guard request.answer == nil, !Task.isCancelled else { return }
                                                 guard steps == shown else {
                                                     window.setStatus("The skill changed since this request opened. Nothing was removed.", problem: true)
                                                     window.setBusy(false)
                                                     return
                                                 }
                                                 // From here the removal happens (it may wait for another change first).
                                                 window.setCommitted(true)
                                                 switch await SkillsStore.apply(steps, title: "Remove \(name)") {
                                                 case .success:
                                                     resolve(request, ["status": "removed", "skill": name])
                                                     window.finish()
                                                 case .failure(let failure):
                                                     window.setStatus(failure.message, problem: true)
                                                     window.setCommitted(false)
                                                 }
                                             }
                                         },
                                         decline: { stop in resolve(request, ["status": "declined"], stopAsking: stop) })
        request.window = window
        window.present()
        watchRequester(request)
    }
}
