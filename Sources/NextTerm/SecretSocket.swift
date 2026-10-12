import AppKit
import Darwin
import NextTermCore

/// `secret_run` on the app's MCP socket: the `nxtrm secret run` wrapper's one request, answered on its own
/// connection. It is not an MCP tool: `MCPServer.respond` never sees it, and an agent's `nxtrm mcp` bridge answers a
/// tool call by that name itself with "Unknown tool".
///
/// - **The peer.** Its audit token must pass `PeerCode` (the running code is this program, run by this user), its
///   whole argv must read `…/NextTerm --cli secret run …` (or the self-test form, only while the app is in self-test),
///   and that argv must equal the `argv_full` it sent. Anything else gets `refused`, with no panel and a `refused`
///   line in the audit log.
/// - **Before any panel.** Arguments holding a stored value get `value_in_command`; a name not stored, `unknown`.
/// - **The asker.** The tab is the one whose shell is above the wrapper; the agent, the first process above it that
///   classifies as one, going by its program's name.
/// - **Waiting.** It loops on `poll` while `SecretRequests` decides. A readable socket with `recv(MSG_PEEK)` giving 0
///   means the wrapper left: its request becomes a pending card.
/// - **The answer** is written only to this connection, as its own line, never through `encodeAnswer`, and its
///   buffer is wiped after.
enum SecretSocket {
    static let tool = "secret_run"
    /// How many parents are walked to find the agent above a wrapper.
    static let parentsWalked = 20

    /// Serves one wrapper's request on the serve thread. The MCP server's call closes `fd` when this returns, once.
    static func handle(fd: Int32, arguments: [String: Any], peer: pid_t?, auditToken token: audit_token_t?) {
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        guard let token, let pid = peer, PeerCode.pid(token) == pid, PeerCode.current.isThisProgram(auditToken: token) else {
            return refuse(fd, reason: "the program at the socket is not Next Term's own nxtrm", pid: peer, names: [])
        }
        guard let request = SecretRun.Request.decode(arguments) else {
            return refuse(fd, reason: "the request could not be read", pid: pid, names: [])
        }
        guard let full = ProcessInspector.fullCommandLine(of: pid) else {
            return refuse(fd, reason: "its arguments are over the caps or can't be read", pid: pid, names: request.names)
        }
        guard isWrapper(full.arguments, selfTest: SelfTest.isRequested), full.arguments == request.argvFull else {
            return refuse(fd, reason: "its arguments are not nxtrm secret run's", pid: pid, names: request.names)
        }
        if PeerCode.usesPathFallback, !PeerCode.isSameProcess(socket: fd, as: token) {
            return refuse(fd, reason: "the process changed while it asked", pid: pid, names: request.names)
        }
        // What can be known off the main thread: the agent above it, the folder's .env, the warnings.
        let agent = agentAbove(pid)
        let envDigest = SecretRun.envFileDigest(directory: request.directory)
        var warnings = request.warn.keys.sorted().map(SecretRun.warningText)
        warnings += SecretRun.warnings(argv: request.argv)
        warnings += SecretRun.envFileWarnings(directory: request.directory)
        let waiter = Waiter()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                ask(request, pid: pid, full: full, agent: agent, envDigest: envDigest, warnings: warnings, waiter: waiter)
            }
        }
        wait(on: fd, for: waiter)
    }

    /// Whether `arguments` (as the kernel has them) are the wrapper's: `…/NextTerm --cli secret run …`, or in the
    /// self-test `…/NextTerm --cli --self-test-secret-wrapper <socket> <wait> secret run …`.
    static func isWrapper(_ arguments: [String], selfTest: Bool) -> Bool {
        guard arguments.count >= 4, (arguments[0] as NSString).lastPathComponent == "NextTerm", arguments[1] == "--cli" else { return false }
        if arguments[2] == "secret", arguments[3] == "run" { return true }
        guard selfTest, arguments.count >= 7, arguments[2] == "--self-test-secret-wrapper" else { return false }
        return arguments[5] == "secret" && arguments[6] == "run"
    }

    // MARK: asking, on the main thread

    /// Holds the answer the main thread decides, for the serve thread waiting on the socket.
    final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: SecretRun.Answer?
        /// Where this wrapper's reply waits, set on the main thread once it is asked.
        private var waiting: SecretRequests.Waiting?

        func set(_ answer: SecretRun.Answer) {
            lock.lock()
            self.answer = answer
            lock.unlock()
        }

        func take() -> SecretRun.Answer? {
            lock.lock()
            defer { lock.unlock() }
            return answer
        }

        func asked(_ waiting: SecretRequests.Waiting?) {
            lock.lock()
            self.waiting = waiting
            lock.unlock()
        }

        var asking: SecretRequests.Waiting? {
            lock.lock()
            defer { lock.unlock() }
            return waiting
        }
    }

    @MainActor
    private static func ask(_ request: SecretRun.Request, pid: pid_t, full: (path: String, arguments: [String]), agent: Agent?,
                            envDigest: String, warnings: [String], waiter: Waiter) {
        let store = SecretsStore.shared
        if request.argv.contains(where: { SecretMask.current.masked($0).count > 0 }) {
            return waiter.set(SecretRun.Answer(status: .valueInCommand, names: request.names))
        }
        if store.protection == .cantOpen || store.protection == .tampered {
            return waiter.set(SecretRun.Answer(status: .cantOpen, names: request.names))
        }
        if let missing = request.names.first(where: { store.index?.entry(named: $0) == nil }) {
            return waiter.set(SecretRun.Answer(status: .unknown, name: missing, names: request.names))
        }
        let tabs = AppDelegate.shared.controllers.flatMap(\.tabs)
        let tab = ClaudeIDEServer.tab(for: pid, among: tabs)
        if let ticket = request.ticket {
            return waiter.asked(SecretRequests.shared.redeem(ticket: ticket, peerTab: tab, request: request) { waiter.set($0) })
        }
        var facts = SecretRequests.AskedBy()
        facts.agent = agent?.name
        facts.checkedNxtrm = true
        facts.pid = pid
        facts.executable = full.path
        facts.arguments = full.arguments
        if let tab, let controller = MCPControl.controller(of: tab) {
            let position = controller.groups.firstIndex { $0.contains(tab) }.map { $0 + 1 }
            facts.tab = position.map { "tab \($0)" } ?? "a tab"
            facts.tabID = tab.id
            facts.project = controller.project
            if tab.status.running, tab.title != tab.status.program { facts.programTitle = tab.title }
        }
        let binding = SecretRun.binding(request: request, agentPath: agent?.path, agentScript: agent?.script,
                                        program: agent?.program ?? "", envDigest: envDigest)
        let keys = request.names.map { SecretRequests.Key(name: $0, envName: request.map[$0] ?? $0) }
        let shown = request.argv.map(SecretApprovalPanel.escaped).joined(separator: " ")
        let program = ((request.argv.first ?? "") as NSString).lastPathComponent
        let asking = SecretRequests.Request(binding: binding, keys: keys, command: shown, argv: request.argv, folder: request.directory,
                                            warnings: warnings, agentWords: nil, askedBy: facts, program: program, isRemote: false)
        let waiting = SecretRequests.shared.ask(asking) { decision in
            waiter.set(answer(for: decision, request: request))
        }
        waiter.asked(waiting)
    }

    /// The wrapper's answer for a decision. Values go only into an `allowed` answer.
    @MainActor
    static func answer(for decision: SecretRequests.Decision, request: SecretRun.Request,
                       argv: [String]? = nil, directory: String? = nil) -> SecretRun.Answer {
        switch decision {
        case .allowed(let values, _):
            var environment: [String: String] = [:]
            for (name, envName) in request.map {
                guard let value = values[name]?.utf8String() else { return SecretRun.Answer(status: .refused, names: request.names) }
                environment[envName] = value
            }
            let stored = SecretsStore.shared.index?.names ?? []
            return SecretRun.Answer(status: .allowed, environment: environment,
                                    remove: SecretRun.removed(stored: stored, approved: Array(request.map.values)),
                                    argv: argv, directory: directory, names: request.names)
        case .declined:
            return SecretRun.Answer(status: .declined, names: request.names)
        case .refused(let refusal):
            switch refusal {
            case .busy: return SecretRun.Answer(status: .busy, names: request.names)
            case .stopped: return SecretRun.Answer(status: .stopped, names: request.names)
            case .limited: return SecretRun.Answer(status: .limited, names: request.names)
            case .paused(_, let until):
                return SecretRun.Answer(status: .paused, names: request.names, until: until.timeIntervalSince1970)
            case .declining(let until):
                return SecretRun.Answer(status: .declining, names: request.names, until: until.timeIntervalSince1970)
            }
        case .failed(let failure):
            switch failure {
            case .vault(.cantOpen), .vault(.tampered): return SecretRun.Answer(status: .cantOpen, names: request.names)
            case .vault(.noSuchKey(let name)): return SecretRun.Answer(status: .unknown, name: name, names: request.names)
            default: return SecretRun.Answer(status: .refused, names: request.names)
            }
        case .notStarted:
            return SecretRun.Answer(status: .expired, names: request.names)
        case .saved, .unanswered:
            return SecretRun.Answer(status: .refused, names: request.names)
        }
    }

    // MARK: waiting, on the serve thread

    /// Waits for the answer, watching for the wrapper leaving; writes the answer when it comes.
    private static func wait(on fd: Int32, for waiter: Waiter) {
        var scratch = [UInt8](repeating: 0, count: 256)
        while true {
            if let answer = waiter.take() { return write(answer, to: fd) }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 1000)
            guard ready > 0 else { continue }
            var byte: UInt8 = 0
            let peeked = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if peeked == 0 || (peeked < 0 && errno != EAGAIN && errno != EINTR) {
                // The wrapper left: its reply goes. A wrapper's request becomes a pending card, a ticket's ends unanswered,
                // unless an identical request that took it over still waits. Read on the main thread, after the ask
                // queued there first, so a wrapper that leaves at once is not missed.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let waiting = waiter.asking else { return }
                        if waiting.request.isWrapper {
                            SecretRequests.shared.wrapperLeft(waiting)
                        } else {
                            SecretRequests.shared.callerLeft(waiting)
                        }
                    }
                }
                return
            }
            // It sent more than its one line: read and drop it.
            _ = recv(fd, &scratch, scratch.count, MSG_DONTWAIT)
        }
    }

    private static func write(_ answer: SecretRun.Answer, to fd: Int32) {
        var data = answer.line()
        defer { SecretBytes.wipe(&data) }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count, let base = raw.baseAddress {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                if written <= 0 { break }
                offset += written
            }
        }
    }

    /// `refused`, with no panel, and a `refused` line in the audit log.
    private static func refuse(_ fd: Int32, reason: String, pid: pid_t?, names: [String]) {
        write(SecretRun.Answer(status: .refused, names: names), to: fd)
        let who = "a program at Next Term's socket" + (pid.map { " (process \($0))" } ?? "")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                SecretsStore.shared.record(SecretAudit.Line(event: .refused, names: names, who: who, outcome: reason))
            }
        }
    }

    // MARK: the agent above

    /// An agent found above a wrapper in the process tree, going by its program's name.
    struct Agent {
        var name: String
        var program: String
        /// Its executable's path, and its script when it runs under an interpreter.
        var path: String
        var script: String?
    }

    /// The first process above `pid`, up to 20 parents, that classifies as an agent.
    static func agentAbove(_ pid: pid_t) -> Agent? {
        var current = parent(of: pid)
        for _ in 0..<parentsWalked {
            // Next Term itself is the top of its tabs: what started it is not the tab's agent.
            guard let process = current, process > 1, process != getpid() else { return nil }
            if let (path, arguments) = ProcessInspector.commandLine(of: process) {
                let name = ProcessInspector.processName(process) ?? (path as NSString).lastPathComponent
                let foreground = ForegroundProcess(isShell: false, name: name, arguments: arguments, executablePath: path)
                if CommandClassifier.kind(of: foreground) == .agent {
                    let program = CommandClassifier.programName(of: foreground)
                    let base = ((arguments.first ?? path) as NSString).lastPathComponent
                    let interpreted = ["node", "bun", "deno", "python", "python3", "ruby"].contains(base)
                    let script = interpreted ? arguments.dropFirst().first { !$0.hasPrefix("-") } : nil
                    return Agent(name: AgentName.of(program: program), program: program, path: path, script: script)
                }
            }
            current = parent(of: process)
        }
        return nil
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }
}
