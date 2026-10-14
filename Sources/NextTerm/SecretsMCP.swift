import AppKit
import CryptoKit
import NextTermCore

/// Secrets' MCP tools: `list_secrets`, `request_secret`, `store_secret` and `run_with_secrets`.
/// Names in, status out: no answer holds a stored key's value, and a request id only reports status.
///
/// - `list_secrets` reads the index; it needs no Touch ID.
/// - The three that ask go through `SecretRequests`' one queue and its limits, to the request window or the panel, then
///   Touch ID or the Mac password. They answer within 50 seconds, or `pending` with a `request_id` to ask again with.
/// - `run_with_secrets` makes a ticket, opens a tab (or uses the one given) and types only the ticket's line there. The
///   wrapper in that tab redeems it, so the panel shows that tab's real environment before Allow; the command runs with
///   the keys in its environment only, never the tab's shell's.
@MainActor
enum SecretsMCP {
    typealias Reply = MCPControl.Reply

    /// How long a call waits for the user before answering `pending` (the self-test shortens it).
    static var answerWithin: TimeInterval = 50

    /// One asking tool call, findable by its id until ten minutes after its answer.
    final class Call {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let asker: String
        let tool: String
        var answer: [String: Any]?
        var waiters: [(token: UUID, reply: Reply)] = []

        init(asker: String, tool: String) {
            self.asker = asker
            self.tool = tool
        }
    }

    static var calls: [String: Call] = [:]

    /// Why a call is refused, as its note says.
    struct Refusal: Error {
        let note: String
        init(_ note: String) { self.note = note }
    }

    static let cantOpenNote = "Secrets can't be opened on this Mac. The user can see why in Settings › Secrets."
    static let listNote = "Values are never returned. Use run_with_secrets, or nxtrm secret run in an MCP server's config."
    static let atTheMacNote = "Only someone at the Mac can add keys."

    /// A call through the remote door: one with a `requester`, or a `connection`.
    static func isRemote(requester: String?, connection: String?) -> Bool { requester != nil || connection != nil }

    /// The remote rules hold whatever `approval` says: a connection's "Ask on this Mac before changes" being off
    /// (`.preApprovedByGrant`) never lets `run_with_secrets` skip its panel and Touch ID, so `approval` is not read here.
    /// A remote `run_with_secrets` shows the panel with the connection's name and only "Allow once", and never makes or
    /// uses a grant (`SecretRequests`). Remote `request_secret` and `store_secret` are refused. `list_secrets` is the
    /// same as on the Mac: names, never a value.
    static func call(_ tool: String, _ arguments: [String: Any], caller: TerminalTab?, pid: pid_t?, approval: MCPApproval = .askOnMac,
                     requester: String? = nil, connection: String? = nil, reply: @escaping Reply) {
        if tool == "list_secrets" { return reply(MCPControl.ok(listSecrets())) }
        if isRemote(requester: requester, connection: connection), tool == "request_secret" || tool == "store_secret" {
            let name = (arguments["name"] as? String).flatMap { StoredSecretName.isValid($0) ? $0 : nil }
            let who = "the remote connection “\(connectionName(requester ?? "a remote connection"))”"
            SecretsStore.shared.record(SecretAudit.Line(event: .refused, names: name.map { [$0] } ?? [], who: who,
                                                        outcome: "\(tool) from a remote connection: only someone at the Mac can add keys"))
            return reply(answer(.refused, note: atTheMacNote))
        }
        let asker = MCPWriteControl.asker(connection: connection, requester: requester, caller: caller)
        if let id = (arguments["request_id"] as? String)?.lowercased(), !id.isEmpty {
            guard let call = calls[id], call.asker == asker, call.tool == tool else { return reply(answer(.refused, note: "No such request.")) }
            return wait(call, reply: reply)
        }
        let facts = askedBy(caller: caller, pid: pid, requester: requester, connection: connection)
        let words = (arguments["reason"] as? String).map { String($0.prefix(4000)) }
        switch tool {
        case "request_secret": requestSecret(arguments, asker: asker, facts: facts, words: words, reply: reply)
        case "store_secret": storeSecret(arguments, asker: asker, facts: facts, words: words, reply: reply)
        default: runWithSecrets(arguments, caller: caller, asker: asker, facts: facts, words: words, reply: reply)
        }
    }

    // MARK: listing

    static func listSecrets() -> [String: Any] {
        let store = SecretsStore.shared
        store.reloadIfChanged()
        guard let index = store.index else { return ["vault": "none", "secrets": [Any](), "note": listNote] }
        switch store.protection {
        case .cantOpen: return ["vault": "cant_open", "secrets": [Any](), "note": cantOpenNote]
        case .tampered: return ["vault": "tampered", "secrets": [Any](), "note": cantOpenNote]
        default: break
        }
        let time = ISO8601DateFormatter()
        let now = Date()
        let secrets: [[String: Any]] = index.entries.map { (entry: SecretVault.Entry) -> [String: Any] in
            let row: [String: Any] = [
                "name": entry.name,
                "for": entry.purpose,
                "purpose_by": entry.purposeBy.rawValue,
                "added_by": entry.addedByUser ? "user" : "agent",
                "write_only": entry.writeOnly,
                "last_used": store.lastUse[entry.name].map { time.string(from: $0.time) } as Any? ?? NSNull(),
            ]
            // The page's provider, never its link; the day the value was set, and whether its reminder has passed.
            let source: [String: Any] = MCPServer.secretSourceFacts(entry, now: now)
            return row.merging(source) { (kept: Any, _: Any) -> Any in kept }
        }
        let protectedBy: String
        switch SecretsStore.protection(of: index) {
        case .secureEnclaveWithRecovery: protectedBy = "secure-enclave-and-keychain"
        case .lessProtected: protectedBy = "keychain"
        default: protectedBy = "secure-enclave"
        }
        return ["vault": "ok", "secrets": secrets, "protected_by": protectedBy, "note": listNote]
    }

    // MARK: who asks

    /// Next Term's facts about the caller, for the panel's Asked by rows: its tab and project, its agent going by its
    /// program's name, the title a program set, its process; or the remote connection.
    static func askedBy(caller: TerminalTab?, pid: pid_t?, requester: String?, connection: String? = nil) -> SecretRequests.AskedBy {
        var facts = SecretRequests.AskedBy()
        if isRemote(requester: requester, connection: connection) {
            // A remote request is one with a connection, named or not: the panel and the ticket then treat it so.
            facts.connection = requester.map(connectionName) ?? "a remote connection"
            return facts
        }
        if let pid {
            facts.pid = pid
            facts.executable = ProcessInspector.commandLine(of: pid)?.path
        }
        guard let caller, let controller = MCPControl.controller(of: caller) else { return facts }
        let position = controller.groups.firstIndex { $0.contains(caller) }.map { $0 + 1 }
        facts.tab = position.map { "tab \($0)" } ?? "a tab"
        facts.tabID = caller.id
        facts.project = controller.project
        if caller.status.running, caller.status.kind == .agent { facts.agent = AgentName.of(program: caller.status.program) }
        if caller.status.running, caller.title != caller.status.program { facts.programTitle = caller.title }
        return facts
    }

    /// The remote door names a connection as "the connection “Claude, phone”": the panel wants the name alone.
    static func connectionName(_ requester: String) -> String {
        guard let open = requester.firstIndex(of: "“"), let close = requester.lastIndex(of: "”"), open < close else { return requester }
        return String(requester[requester.index(after: open)..<close])
    }

    /// Who asks, as a title starts: "Codex", "An agent in tab 2", "An agent outside Next Term's tabs".
    static func subject(_ facts: SecretRequests.AskedBy) -> String {
        if let connection = facts.connection { return "The remote connection “\(connection)”" }
        if let agent = facts.agent { return agent }
        if let tab = facts.tab { return "An agent in \(tab)" }
        return "An agent outside Next Term's tabs"
    }

    // MARK: request_secret

    static func requestSecret(_ arguments: [String: Any], asker: String, facts: SecretRequests.AskedBy, words: String?,
                              reply: @escaping Reply) {
        guard let name = arguments["name"] as? String, StoredSecretName.isValid(name) else {
            return reply(answer(.refused, note: "Give name: capital letters, digits and _, starting with a letter, at most 64 characters."))
        }
        let store = SecretsStore.shared
        store.reloadIfChanged()
        if store.protection == .cantOpen || store.protection == .tampered { return reply(answer(.cantOpen, note: cantOpenNote)) }
        let binding = SecretBinding(source: .tool, asker: asker, program: "request_secret", command: ["request_secret", name],
                                    keys: [name: name], folder: "")
        let requests = SecretRequests.shared
        if let refusal = requests.precheck(asker: asker, binding: binding, names: [name], command: nil, folder: nil) {
            return reply(MCPControl.ok(answer(for: .refused(refusal), tool: "request_secret")))
        }
        let request = SecretRequests.Request(binding: binding, keys: [SecretRequests.Key(name: name, envName: name)], command: "", argv: [],
                                             folder: "", warnings: [], agentWords: words, askedBy: facts, program: "request_secret",
                                             isRemote: facts.connection != nil)
        let purpose = StoredSecretName.purpose(fromReason: words ?? "")
        request.kind = .add(SecretRequestWindow.Content(title: "\(subject(facts)) asks you to add \(name)",
                                                        askedBy: SecretRequests.who(request), agentWords: words, name: name, purpose: purpose))
        let call = Call(asker: asker, tool: "request_secret")
        calls[call.id] = call
        requests.ask(request) { decision in resolve(call, answer(for: decision, tool: "request_secret")) }
        wait(call, reply: reply)
    }

    // MARK: store_secret

    static func storeSecret(_ arguments: [String: Any], asker: String, facts: SecretRequests.AskedBy, words: String?,
                            reply: @escaping Reply) {
        guard let name = arguments["name"] as? String, StoredSecretName.isValid(name) else {
            return reply(answer(.refused, note: "Give name: capital letters, digits and _, starting with a letter, at most 64 characters."))
        }
        guard let text = arguments["value"] as? String, let value = checkedValue(text) else {
            return reply(answer(.refused, note: "Give value: the key on one line, at most 16 KB, with no line breaks."))
        }
        let store = SecretsStore.shared
        store.reloadIfChanged()
        if store.protection == .cantOpen || store.protection == .tampered { return reply(answer(.cantOpen, note: cantOpenNote)) }
        // The same value asked again is the same request; the binding keeps a keyed digest of it, never the value.
        let binding = SecretBinding(source: .tool, asker: asker, program: "store_secret", command: ["store_secret", name], keys: [name: name],
                                    folder: "", target: "value:" + valueDigest(value))
        let requests = SecretRequests.shared
        if let refusal = requests.precheck(asker: asker, binding: binding, names: [name], command: nil, folder: nil) {
            return reply(MCPControl.ok(answer(for: .refused(refusal), tool: "store_secret")))
        }
        let request = SecretRequests.Request(binding: binding, keys: [SecretRequests.Key(name: name, envName: name)], command: "", argv: [],
                                             folder: "", warnings: [], agentWords: words, askedBy: facts, program: "store_secret",
                                             isRemote: facts.connection != nil)
        request.kind = .store(value)
        let who = subject(facts)
        if let stored = store.index?.entry(named: name) {
            let day = SecretRequests.dayText(stored.created)
            if stored.addedByUser {
                request.titleOverride = "\(who) asks to replace \(name), a key you added"
                request.warnings = ["This replaces the key you added on \(day). Commands and MCP servers that use it will get the agent's value."]
            } else {
                request.titleOverride = "\(who) asks to replace \(name), a key an agent saved"
                request.warnings = ["Replaces the key an agent saved on \(day). Commands and MCP servers that use it will get the agent's value."]
            }
        } else {
            request.titleOverride = "\(who) asks to save a key it holds"
        }
        request.notice = "This key is already in the agent's conversation. Next Term keeps it out of what agents read from now on. "
            + "Consider rotating it."
        let call = Call(asker: asker, tool: "store_secret")
        calls[call.id] = call
        requests.ask(request) { decision in resolve(call, answer(for: decision, tool: "store_secret")) }
        wait(call, reply: reply)
    }

    /// The value as the vault takes it: trimmed, not empty, at most 16 KB, and no NUL, CR or LF.
    static func checkedValue(_ text: String) -> SecretBytes? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.count <= SecretVault.maxValueBytes,
              !trimmed.unicodeScalars.contains(where: { $0 == "\0" || $0 == "\r" || $0 == "\n" }) else { return nil }
        return SecretBytes(utf8: trimmed)
    }

    /// A per-launch key for the digests a binding keeps of a value.
    private static let digestKey = SymmetricKeyHolder()

    static func valueDigest(_ value: SecretBytes) -> String {
        digestKey.digest(value)
    }

    // MARK: run_with_secrets

    static func runWithSecrets(_ arguments: [String: Any], caller: TerminalTab?, asker: String, facts: SecretRequests.AskedBy,
                               words: String?, reply: @escaping Reply) {
        let invocation: SecretRun.Invocation
        switch parseKeys(arguments["secrets"]) {
        case .failure(let refusal): return reply(answer(.refused, note: refusal.note))
        case .success(let parsed): invocation = parsed
        }
        guard let command = (arguments["command"] as? String)?.trimmingCharacters(in: .whitespaces), !command.isEmpty,
              command.count <= 2000, SecretRun.isOneLine(command) else {
            return reply(answer(.refused, note: "Give command: one line, at most 2,000 characters."))
        }
        guard let folder = absoluteFolder(arguments["directory"]) else {
            return reply(answer(.refused, note: "Give directory: an absolute path to a folder on this Mac."))
        }
        let store = SecretsStore.shared
        store.reloadIfChanged()
        if store.protection == .cantOpen || store.protection == .tampered { return reply(answer(.cantOpen, note: cantOpenNote)) }
        if let missing = invocation.names.first(where: { store.index?.entry(named: $0) == nil }) {
            return reply(answer(.unknown, note: "No key named \(missing). request_secret asks the user to add it."))
        }
        if SecretMask.current.masked(command).count > 0 {
            return reply(answer(.valueInCommand, note: "The command holds a stored key's value; use its name."))
        }
        var target: TerminalTab?
        if let id = arguments["tab_id"] {
            switch givenTab(id, caller: caller, remote: facts.connection != nil) {
            case .failure(let refusal): return reply(answer(.refused, note: refusal.note))
            case .success(let tab): target = tab
            }
        }
        let keys = invocation.names.map { SecretRequests.Key(name: $0, envName: invocation.map[$0] ?? $0) }
        let program = SecretRun.programName(ofCommand: command)
        var notice: String?
        if let target, let controller = MCPControl.controller(of: target) {
            let position = controller.groups.firstIndex { $0.contains(target) }.map { "tab \($0 + 1)" } ?? "a tab"
            notice = "In \(position) “\(SecretApprovalPanel.sanitized(target.title, limit: 60))”, with that tab's environment."
        }
        // The limits first: a request they refuse opens no tab.
        let requests = SecretRequests.shared
        let targetWord = target.map { $0.id.uuidString } ?? "new"
        let preliminary = SecretBinding(source: .tool, asker: asker, program: program, command: [command],
                                        keys: invocation.map, folder: folder, target: targetWord,
                                        envDigest: SecretRun.envFileDigest(directory: folder))
        if let refusal = requests.precheck(asker: asker, binding: preliminary, names: invocation.names, command: command, folder: folder) {
            return reply(MCPControl.ok(answer(for: .refused(refusal), tool: "run_with_secrets")))
        }
        // A new tab comes forward as new_tab's does, and the answer says whether it was selected (AgentArrival).
        let ticketTab: TerminalTab
        let arrived: (selected: Bool, note: String?)?
        if let target {
            ticketTab = target
            arrived = nil
        } else {
            let made = newTab(folder: folder, program: program, keys: invocation.names, caller: caller)
            ticketTab = made.tab
            arrived = made.arrived
        }
        let tabID = ticketTab.id.uuidString.lowercased()
        // Every answer for a new tab says whether it was selected when it opened, and why its window stayed where it was.
        let told: ([String: Any]) -> [String: Any] = { result in
            arrived.map { MCPServer.withArrival(result, selected: $0.selected, note: $0.note) } ?? result
        }
        let call = Call(asker: asker, tool: "run_with_secrets")
        let ticket = SecretRequests.Ticket(asker: asker, keys: keys, command: command, folder: folder, target: targetWord,
                                           tabID: ticketTab.id, askedBy: facts, agentWords: words, program: program,
                                           isRemote: facts.connection != nil, notice: notice) { decision in
            var result = told(answer(for: decision, tool: "run_with_secrets"))
            result["tab_id"] = tabID
            resolve(call, result)
        }
        calls[call.id] = call
        requests.add(ticket)
        MCPControl.driven.insert(ticketTab.id)
        MCPControl.whenReady(ticketTab, until: TerminalTab.now + 5) {
            let shell = shellName(of: ticketTab)
            guard let line = ticketLine(ticket, shell: shell), MCPControl.canType(ticketTab) else {
                requests.drop(ticket)
                let note = SecretRun.untypableShells.contains(shell)
                    ? "This tab's shell (\(shell)) can't run the line Next Term types. Use a zsh or bash tab."
                    : "Next Term couldn't type the line in that tab."
                return resolve(call, told(["status": "refused", "note": note, "tab_id": tabID]))
            }
            MCPControl.type(line, into: ticketTab, submit: true)
            requests.typed(ticket)
        }
        wait(call, reply: reply)
    }

    /// `secrets` as names and ENVNAMEs, by `nxtrm secret run`'s rules: 1 to 20, each `NAME` or `NAME=ENVNAME`.
    static func parseKeys(_ value: Any?) -> Result<SecretRun.Invocation, Refusal> {
        let usage = "Give secrets as 1 to 20 keys, each NAME or NAME=ENVNAME."
        guard let pairs = value as? [String], (1...20).contains(pairs.count) else { return .failure(Refusal(usage)) }
        switch SecretRun.parse(pairs + ["--", "sh"]) {
        case .success(let invocation): return .success(invocation)
        case .failure(let error): return .failure(Refusal("\(usage) Here \(error.reason)."))
        }
    }

    static func absoluteFolder(_ value: Any?) -> String? {
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        let path = (raw as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }
        let real = canonicalPath(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return real
    }

    /// `tab_id`'s tab: a local tab at its own shell's prompt, not the caller's own, whose input line is the user's own,
    /// in a shell the line can be typed in.
    static func givenTab(_ id: Any, caller: TerminalTab?, remote: Bool) -> Result<TerminalTab, Refusal> {
        let tabs = AppDelegate.shared.controllers.flatMap(\.tabs)
        guard let text = (id as? String)?.lowercased(), let tab = tabs.first(where: { $0.id.uuidString.lowercased() == text }) else {
            return .failure(Refusal("No tab with that id; list_tabs shows them."))
        }
        if tab.remote != nil { return .failure(Refusal("That is a remote tab: keys are used on this Mac only. Give a local tab, or no tab_id for a new tab.")) }
        if tab === caller { return .failure(Refusal("That is your own tab; give another one, or no tab_id for a new tab.")) }
        if tab.exited || !tab.view.acceptsInput { return .failure(Refusal("That tab's shell has ended.")) }
        let shell = shellName(of: tab)
        let foreground = ProcessInspector.foreground(ptyFileDescriptor: tab.view.process.childfd, shellPid: tab.view.process.shellPid,
                                                     shellName: shell)
        guard foreground?.isShell == true, !tab.status.running else {
            return .failure(Refusal("That tab is running something. Give a tab at its shell's prompt, or no tab_id for a new tab."))
        }
        if let why = MCPInputLine.refusal(tab) { return .failure(Refusal(why)) }
        if SecretRun.untypableShells.contains(shell) {
            return .failure(Refusal("This tab's shell (\(shell)) can't run the line Next Term types. Use a zsh or bash tab."))
        }
        return .success(tab)
    }

    /// A new tab in the folder's window (new_tab's rule), never a reused one. As with new_tab, it takes no keyboard until
    /// the user clicks or chooses it, and its window comes forward as Settings › Editor › "When an agent opens a tab"
    /// says (AgentArrival); `arrived` is what the answer says of that, as it was when the tab opened
    /// (MCPServer.withArrival). Its title names the program and the keys; as with new_tab, the asking agent's tab is its
    /// opened_by, so an agent run there is that agent's worker and opens no tabs of its own unless the user asks it to.
    static func newTab(folder: String, program: String, keys: [String],
                       caller: TerminalTab?) -> (tab: TerminalTab, arrived: (selected: Bool, note: String?)) {
        let (controller, _) = MCPControl.window(for: folder)
        let tab = controller.addTab(directory: folder, select: false, byAgent: true)
        tab.openedBy = caller?.id
        tab.userTitle = "\(program) · with \(SecretReason.keys(keys))"
        let arrived = controller.presentForAgent(tab)
        controller.refresh()
        return (tab, arrived)
    }

    /// The tab's shell, by its process's name.
    static func shellName(of tab: TerminalTab) -> String {
        let pid = tab.view.process.shellPid
        if pid > 0, let name = ProcessInspector.processName(pid) { return name.hasPrefix("-") ? String(name.dropFirst()) : name }
        return ((ProcessInfo.processInfo.environment["SHELL"] ?? "zsh") as NSString).lastPathComponent
    }

    /// `<nxtrm> secret run --ticket <id>`, quoted for the shell. `<nxtrm>` is the app's `nxtrm` script, or its binary
    /// with `--cli`. In the self-test it is the self-test form, so it never dials the real socket; a release build has
    /// no such form, so its self-test gets no line.
    static func ticketLine(_ ticket: SecretRequests.Ticket, shell: String) -> String? {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let words: [String]
        if SelfTest.isRequested {
            #if DEBUG
            words = [executable, "--cli", "--self-test-secret-wrapper", SelfTest.mcpSocketPath, "25", "secret", "run", "--ticket", ticket.id]
            #else
            return nil // only a debug build has the self-test's wrapper form
            #endif
        } else if let script = CommandLineTool.script?.path {
            words = [script, "secret", "run", "--ticket", ticket.id]
        } else {
            words = [executable, "--cli", "secret", "run", "--ticket", ticket.id]
        }
        return SecretRun.typedLine(words, shell: shell)
    }

    // MARK: answers

    enum Status: String {
        case started, saved, declined, pending, busy, limited, unknown, refused
        case valueInCommand = "value_in_command"
        case cantOpen = "cant_open"
    }

    static func answer(_ status: Status, note: String) -> MCPServer.CallResult {
        MCPControl.ok(["status": status.rawValue, "note": note])
    }

    /// A decision as the tool answers it. Never a value: `allowed` becomes `started`.
    static func answer(for decision: SecretRequests.Decision, tool: String) -> [String: Any] {
        let nothing = tool == "run_with_secrets" ? "nothing ran" : "nothing was saved"
        switch decision {
        case .allowed(_, let how):
            let approved: String
            switch how {
            case .once, .remote: approved = "once"
            case .fifteenMinutes: approved = "for 15 minutes"
            case .untilLock: approved = "until the Mac locks"
            case .grant: approved = "by an earlier approval"
            }
            return ["status": Status.started.rawValue, "approved": approved,
                    "note": "The command runs in its tab with the keys in its environment. read_tab shows its screen, with stored keys masked."]
        case .saved(let name, let replaced):
            return ["status": Status.saved.rawValue, "name": name, "replaced": replaced]
        case .declined(let stopAsking):
            let note = stopAsking ? "The user chose Decline and Stop Asking: Next Term won't ask them for you again until it quits."
                : "The user declined, so \(nothing)."
            return ["status": Status.declined.rawValue, "note": note]
        case .refused(let refusal):
            return refusalAnswer(refusal)
        case .failed(let failure):
            switch failure {
            case .vault(.cantOpen), .vault(.tampered), .vault(.unlisted): return ["status": Status.cantOpen.rawValue, "note": cantOpenNote]
            case .vault(.noSuchKey(let name)):
                return ["status": Status.unknown.rawValue, "note": "No key named \(name). request_secret asks the user to add it."]
            default:
                return ["status": Status.refused.rawValue, "note": failure.errorDescription ?? "Next Term couldn't do it."]
            }
        case .notStarted:
            return ["status": Status.refused.rawValue, "note": "The tab's shell did not start nxtrm within 30 seconds."]
        case .unanswered:
            return ["status": Status.declined.rawValue, "note": "Nobody answered in Next Term, so \(nothing)."]
        case .usedAlready:
            return ["status": Status.refused.rawValue,
                    "note": "The user chose Allow once, which starts one command, and an identical call used it, so \(nothing) here."]
        }
    }

    static func refusalAnswer(_ refusal: SecretLimits.Refusal) -> [String: Any] {
        switch refusal {
        case .busy:
            return ["status": Status.busy.rawValue, "note": "Too many key requests are waiting. Try again later."]
        case .limited:
            return ["status": Status.limited.rawValue, "note": "This agent has asked too often. The user can resume it in Settings › Secrets."]
        case .paused(let declinedAt, _):
            return ["status": Status.declined.rawValue, "note": "paused because you declined this at \(SecretRequests.clockText(declinedAt))"]
        case .stopped:
            return ["status": Status.declined.rawValue,
                    "note": "The user chose Decline and Stop Asking for you: Next Term won't ask again until it quits."]
        case .declining(let until):
            return ["status": Status.declined.rawValue, "note": "Next Term is pausing key requests until \(SecretRequests.clockText(until))."]
        }
    }

    // MARK: waiting

    /// Answers with the call's outcome, or `pending` after `answerWithin` seconds.
    static func wait(_ call: Call, reply: @escaping Reply) {
        if let answer = call.answer { return reply(MCPControl.ok(answer)) }
        let token = UUID()
        call.waiters.append((token, reply))
        DispatchQueue.main.asyncAfter(deadline: .now() + answerWithin) {
            MainActor.assumeIsolated {
                guard let index = call.waiters.firstIndex(where: { $0.token == token }) else { return }
                call.waiters.remove(at: index)
                reply(MCPControl.ok(["status": Status.pending.rawValue, "request_id": call.id,
                                     "note": "The user has not decided yet. Call again with only request_id to keep waiting."]))
            }
        }
    }

    static func resolve(_ call: Call, _ answer: [String: Any]) {
        guard call.answer == nil else { return }
        call.answer = answer
        let waiters = call.waiters
        call.waiters = []
        for waiter in waiters { waiter.reply(MCPControl.ok(answer)) }
        let id = call.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { MainActor.assumeIsolated { _ = calls.removeValue(forKey: id) } }
    }
}

/// A random key made at launch, for the digests a request's binding keeps of a value: an HMAC, so the digest of a short
/// value can't be guessed from it.
final class SymmetricKeyHolder: @unchecked Sendable {
    private let key = SymmetricKey(size: .bits256)

    func digest(_ value: SecretBytes) -> String {
        value.withUnsafeBytes { bytes in
            HMAC<SHA256>.authenticationCode(for: bytes, using: key).map { String(format: "%02x", $0) }.joined()
        }
    }
}
