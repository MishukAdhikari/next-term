import Darwin
import Foundation
import NextTermCore

/// Remote access's tunnel (U10): finds `cloudflared` and `tailscale`, runs the chosen tunnel as Next Term's own child
/// only while Remote access is on, checks it every 10 seconds, restarts it when it exits, and ends it on Turn Off
/// within 3 seconds or at quit in place (R31, R32, R37, R42). It takes U9's seam in the controller
/// (`RemoteAccessTunnelRunner`) and reports to its reducer.
///
/// - Cloudflare: `cloudflared` 2025.4.0 or later, with U6's arguments: its own settings file, metrics on a free
///   loopback port picked each start, and the token through a pipe on its standard input, written once and closed
///   (R30). Neither its arguments nor its environment hold the token. `/ready` and `/config` are read through a URL
///   session with no proxy and no cache. The first time it is ready, the hostname from `/config` waits for the user
///   (Confirm Host); a different one later stops it. Connected with no routing for 2 minutes, it stops.
/// - Funnel: `tailscale status --json` first, then `tailscale funnel http://127.0.0.1:<port>` in the foreground, so
///   the share ends with the child, and `tailscale funnel status --json` at each check.
/// - Your own server (U15): the system ssh with U15's arguments, one reverse forward from the server's
///   `127.0.0.1:<server port>` to the door and nothing else, on a connection of its own. It never prompts and never
///   takes a host key: an unknown or changed one stops it (R47). Before each start, `ssh -G` with the same arguments
///   shows what the user's ssh config adds, and a forward of its own refuses the start. A login that needs the user
///   opens a remote tab on the server, and ssh starts again once that tab's login got through (R47): in front right
///   after the user's Turn On, otherwise in the background with the Mac told, so nothing typed in Next Term goes
///   to the server; none when a master connection is up, since a tab joining it logs in to nothing. It is On once
///   the server took the forward, which ssh's lines say; its exit is handled after the lines before it. Its
///   environment is a remote tab's: no MCP socket, the login shell's PATH and ssh agent.
/// - Every child gets a watchdog (`nxtrm tunnel-guard`, RemoteAccessTunnelGuard) that ends it within 5 seconds if
///   Next Term exits any other way, and a `0600` pid record that names it and this Next Term, deleted once it is gone.
///   The record is written off the main thread, since each write flushes to the disk itself.
/// - Each child runs in a process group of its own (`Process` does that), and every end signals the group, so a tool
///   that a wrapper script runs without `exec`, such as the Tailscale app's `tailscale`, ends with it.
/// - Its output is kept in memory only: the last 20 lines, the token and anything `MCPRedaction` finds masked. The
///   token itself is dropped at Turn Off and at quit; the masked lines stay for Settings.
///
/// The decisions are Core's (`RemoteAccessTunnelWatch`, `RemoteAccessTunnelConfig`); this holds the processes, the
/// timers and the reads. Under a debug `--self-test`, U12 may shorten the timings and put stand-ins in place of the
/// tools; nothing else changes.
@MainActor
final class RemoteAccessTunnel: RemoteAccessTunnelRunner {
    typealias Config = RemoteAccessTunnelConfig
    typealias Start = RemoteAccessPidRecord.Start

    /// The check interval and the watch's waits. Only a debug build under `--self-test` may shorten them (U12).
    struct Timings: Equatable {
        var check: TimeInterval = Config.checkInterval
        var limits = RemoteAccessTunnelWatch.Limits.standard

        static let standard = Timings()

        #if DEBUG
        /// What U12 sets before it turns Remote access on, read only under `--self-test`.
        nonisolated(unsafe) static var selfTest: Timings?
        #endif

        static var current: Timings {
            #if DEBUG
            if SelfTest.isRequested, let shortened = selfTest { return shortened }
            #endif
            return .standard
        }
    }

    #if DEBUG
    /// The self-test's stand-ins for the tools (U12), read only under `--self-test`. The program runs with the real
    /// arguments and environment, and gets the token on its standard input as `cloudflared` would.
    struct StandIn {
        /// Run in place of `cloudflared` or `tailscale`; nil: the tool is missing.
        var program: String?
        /// What the version flag prints, in place of running the program for it.
        var version = "cloudflared version 2026.10.0"
        /// `tailscale status --json` and `tailscale funnel status --json`, in place of the CLI.
        var tailscaleStatus: (@Sendable () -> Data?)?
        var funnelStatus: (@Sendable () -> Data?)?
        /// The in-process metrics server's port, in place of the free one picked each start.
        var metricsPort: Int?
    }

    nonisolated(unsafe) static var standIn: StandIn?

    nonisolated static var activeStandIn: StandIn? {
        SelfTest.isRequested ? standIn : nil
    }
    #endif

    var report: ((RemoteAccessStatus.Event) -> Void)?
    /// A tunnel line for the audit log, beside the reducer's own (R39): a login tab opened (U15).
    var audit: ((String, String?) -> Void)?
    /// A notification on the Mac: a login tab opened in the background (U15).
    var notify: ((String, String) -> Void)?

    /// The child's last lines, masked (Settings, U11).
    private(set) var output = RemoteAccessTunnelOutput()
    /// What Settings warns about while it runs: a `cloudflared` system service or an existing Funnel share (R34), an
    /// old `cloudflared`, and the route's warnings.
    private(set) var warnings: [String] = []

    /// The Remote access folder: the pid record and `cloudflared`'s settings file.
    private let folder: URL
    private var run: Run?
    /// Children of earlier runs still ending on timers, by pid, so quit can end them in place.
    private var ending: [pid_t: Child] = [:]

    init(folder: URL) {
        self.folder = folder
    }

    #if DEBUG
    /// The running child and its watchdog, for the self-test.
    var childPid: pid_t? { run?.child?.pid }
    var watchdogPid: pid_t? { run?.child?.watchdog?.processIdentifier }
    #endif

    // MARK: the seam (U9)

    func start(_ kind: Config.Kind, port: UInt16, host: String?, token: Config.Token?, server: Config.OwnServer?,
               askedAt: Date?) {
        stop()
        output = RemoteAccessTunnelOutput(token: token)
        setWarnings([])
        let timings = Timings.current
        let watch = RemoteAccessTunnelWatch(kind: kind, host: host, port: Int(port), limits: timings.limits,
                                            server: server, askedAt: askedAt)
        switch kind {
        case .advanced:
            // The user's own tunnel: the controller never starts one.
            return
        case .ownServer:
            guard server != nil else {
                report?(.tunnelFailed(Config.serverNeeded))
                return
            }
        case .cloudflare:
            guard token != nil else {
                report?(.tunnelFailed(RemoteAccessStatus.tokenNeeded))
                return
            }
        case .funnel:
            break
        }
        let run = Run(kind: kind, port: Int(port), token: token, watch: watch, timings: timings)
        run.server = server
        self.run = run
        let folder = self.folder
        // Read here, on the main thread, as remote tabs read it: its first read sets the process's umask a moment.
        let ssh = server.map { SSHStart(server: $0, doorPort: Int(port), configFile: RemoteConnection.configFile) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let prepared = Self.prepare(kind, folder: folder, ssh: ssh)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.prepared(prepared, for: run) }
            }
        }
    }

    /// Turn Off: SIGTERM now, again after 1 second, SIGKILL 2.9 seconds in, on timers, to the child's process group;
    /// the pid record goes once it is gone. The token goes from memory at once.
    func stop() {
        output.forgetToken()
        guard let run else { return }
        self.run = nil
        run.cancelTimers()
        run.token = nil
        guard let child = run.child else { return }
        run.child = nil
        retire(child)
    }

    /// Quit: every child, this run's and any still ending on timers, ended in place together, counted from when quit
    /// began, so each gets the whole 3 seconds.
    func stopNow(from began: DispatchTime) {
        output.forgetToken()
        if let run {
            self.run = nil
            run.cancelTimers()
            run.token = nil
            if let child = run.child { ending[child.pid] = child }
            run.child = nil
        }
        let children = Array(ending.values)
        ending.removeAll()
        let targets = children.map { RemoteAccessProcesses.Target(pid: $0.pid, start: $0.start) }
        let ended = RemoteAccessProcesses.endNow(targets, from: began)
        for (child, gone) in zip(children, ended) where gone {
            RemoteAccessProcesses.forget(child.pid, start: child.start, in: folder, now: true)
        }
    }

    /// Ends a child that no longer serves this run, and what is left of its process group, on timers; its record goes
    /// once all of it is gone. Quit ends it in place if it is still ending then.
    private func retire(_ child: Child) {
        ending[child.pid] = child
        let folder = self.folder
        RemoteAccessProcesses.end(child.pid, start: child.start) { [weak self] gone in
            if let self, self.ending[child.pid]?.start == child.start { self.ending[child.pid] = nil }
            if gone { RemoteAccessProcesses.forget(child.pid, start: child.start, in: folder) }
        }
    }

    /// Confirm Host, or Funnel's first hostname, saved: the checks name it from now on.
    func use(host: String) {
        run?.watch.use(host: host)
    }

    /// After a wake: a check at once.
    func checkNow() {
        guard let run, run.child != nil else { return }
        check(run)
    }

    // MARK: starting

    /// What a start found off the main thread: the program, the login PATH, Settings' warnings, `cloudflared`'s
    /// settings file, and ssh's environment and config file.
    struct Prepared: Sendable {
        var program: String
        var loginPath: [String]
        var warnings: [String]
        var settings: URL?
        var sshEnvironment: [String: String]?
        var sshConfig: String?
    }

    /// Your own server's start, gathered on the main thread: the server, the door's port and Next Term's ssh config.
    struct SSHStart: Sendable {
        var server: Config.OwnServer
        var doorPort: Int
        var configFile: String?
    }

    /// Finds the tool and checks it can run: `cloudflared` 2025.4.0 or later (R30), with its settings file written
    /// here, or Tailscale logged in, or ssh's settings for your own server. With Funnel or HTTPS not enabled for the
    /// tailnet, `tailscale funnel` starts anyway: it prints its own message with the link that enables it, and
    /// waits. Reads `LoginShell.path`, whose first read can take 5 seconds, and flushes the settings file to the
    /// disk, so never on the main thread.
    nonisolated static func prepare(_ kind: Config.Kind, folder: URL,
                                    ssh: SSHStart? = nil) -> Result<Prepared, Problem> {
        let loginPath = LoginShell.path
        if kind == .ownServer {
            guard let ssh else { return .failure(Problem(Config.serverNeeded)) }
            return prepareSSH(ssh, loginPath: loginPath)
        }
        let tool: Config.Tool = kind == .funnel ? .tailscale : .cloudflared
        guard let program = locate(tool, loginPath: loginPath) else { return .failure(Problem(tool.missing)) }
        let environment = toolEnvironment(loginPath: loginPath)
        var prepared = Prepared(program: program, loginPath: loginPath, warnings: [])
        if kind == .cloudflare {
            let output = versionOutput(of: program, environment: environment)
            if let problem = Config.cloudflaredStartProblem(versionOutput: output) { return .failure(Problem(problem)) }
            if let version = output.flatMap(Config.cloudflaredVersion), version.isOutdated(now: Date()) {
                prepared.warnings.append(Config.outdatedWarning(version))
            }
            let services = Config.cloudflaredServices(home: NSHomeDirectory())
            if services.contains(where: FileManager.default.fileExists(atPath:)) {
                prepared.warnings.append(Config.cloudflaredServiceWarning)
            }
            do {
                prepared.settings = try Config.writeCloudflaredSettings(in: folder)
            } catch {
                return .failure(Problem("Next Term could not write cloudflared's settings: \(error)"))
            }
        } else {
            let status = tailscaleStatus(program, environment: environment)
            guard let status else { return .failure(Problem(Config.TailscaleProblem.unreadable.message)) }
            switch Config.funnelStart(Config.tailscaleStatus(status)) {
            case .go: break
            case .waitForEnabling(let warning): prepared.warnings.append(warning)
            case .refuse(let reason): return .failure(Problem(reason))
            }
            let share = funnelStatus(program, environment: environment)
            if let share, Config.funnelShareExists(share) { prepared.warnings.append(Config.funnelShareWarning) }
        }
        return .success(prepared)
    }

    /// The system ssh, as remote tabs run it (RemoteConnection): its path (the self-test's stand-in in a debug
    /// build), the environment of a remote tab's ssh, with the login shell's PATH and ssh agent and without Next
    /// Term's MCP socket, and Next Term's ssh config, so ProxyJump hops ask about host keys too. After
    /// `LoginShell.path`, so the environment has what the login shell sets.
    ///
    /// Then `ssh -G` with the child's arguments, which connects to nothing: a forward the user's ssh config adds for
    /// the server, or none for the door, refuses the start (`Config.sshSettingsProblem`). A stand-in ssh answers
    /// `-G` as ssh prints it, the door's `remoteforward` line at least.
    nonisolated static func prepareSSH(_ ssh: SSHStart, loginPath: [String]) -> Result<Prepared, Problem> {
        let program = RemoteConnection.sshPath
        guard FileManager.default.isExecutableFile(atPath: program) else {
            return .failure(Problem("Next Term can't find ssh at \(program)."))
        }
        var environment: [String: String] = [:]
        for pair in RemoteConnection.environment() {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<equals])
            if environment[key] == nil { environment[key] = String(pair[pair.index(after: equals)...]) }
        }
        let check = Config.sshCheckArguments(ssh.server, doorPort: ssh.doorPort, configFile: ssh.configFile)
        // Longer than a version's read: a Match exec or a canonical hostname lookup in the config runs here too.
        let data = capture(program, check, environment: environment, timeout: 10)
        let printed = data.map { String(decoding: $0, as: UTF8.self) }
        if let problem = Config.sshSettingsProblem(printed, server: ssh.server, doorPort: ssh.doorPort) {
            return .failure(Problem(problem))
        }
        var prepared = Prepared(program: program, loginPath: loginPath, warnings: [])
        prepared.sshEnvironment = environment
        prepared.sshConfig = ssh.configFile
        return .success(prepared)
    }

    /// Why a start can't go on, as the status shows it.
    struct Problem: Error, Sendable {
        var message: String
        init(_ message: String) { self.message = message }
    }

    private func prepared(_ result: Result<Prepared, Problem>, for run: Run) {
        guard self.run === run else { return }
        switch result {
        case .failure(let problem):
            report?(.tunnelFailed(problem.message))
        case .success(let prepared):
            run.prepared = prepared
            setWarnings(prepared.warnings)
            launch(run)
            guard self.run === run else { return }
            run.startChecks { [weak self] in self?.tick(run) }
        }
    }

    /// Starts the child (first, or again after an exit), its watchdog and its pid record.
    private func launch(_ run: Run) {
        guard self.run === run, run.child == nil, let prepared = run.prepared else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: prepared.program)
        var input: Data?
        var metricsPort: Int?
        switch run.kind {
        case .cloudflare:
            guard let token = run.token else { return fail(RemoteAccessStatus.tokenNeeded) }
            guard let settings = cloudflaredSettings(prepared) else { return }
            guard let port = Self.metricsPort() else {
                return fail("No loopback port is free for cloudflared's metrics.")
            }
            metricsPort = port
            process.arguments = Config.cloudflaredArguments(metricsPort: port, configFile: settings.path)
            let base = ProcessInfo.processInfo.environment
            process.environment = Config.cloudflaredEnvironment(token: token, loginPath: prepared.loginPath, base: base)
            input = Config.cloudflaredInput(token)
        case .ownServer:
            guard let server = run.server else { return fail(Config.serverNeeded) }
            process.arguments = Config.sshArguments(server, doorPort: run.port, configFile: prepared.sshConfig)
            process.environment = prepared.sshEnvironment
        default:
            process.arguments = Config.funnelArguments(port: run.port)
            process.environment = Self.toolEnvironment(loginPath: prepared.loginPath)
        }
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        let printed = Pipe()
        process.standardOutput = printed
        process.standardError = printed
        // ssh's lines are read for what they say, and its exit waits for them (U15). They reach the main thread
        // after this launch returns, so after the watch knows the child started.
        let lines = run.kind == .ownServer ? Lines() : nil
        run.lines = lines
        listen(to: printed, for: run, lines: lines)
        process.terminationHandler = { [weak self] ended in
            let pid = ended.processIdentifier
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.exited(pid, in: run) }
            }
        }
        do {
            try process.run()
        } catch {
            printed.fileHandleForReading.readabilityHandler = nil
            let names: [Config.Kind: String] = [.funnel: "tailscale", .ownServer: "ssh"]
            let name = names[run.kind] ?? "cloudflared"
            return fail("Next Term could not start \(name): \(error.localizedDescription)")
        }
        // Written once and closed, so cloudflared reads it to its end. A child already gone is no SIGPIPE, and no
        // exception, for Next Term.
        if let stdin, let input {
            let writer = stdin.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? writer.write(contentsOf: input)
            try? writer.close()
        }
        let pid = process.processIdentifier
        guard let start = RemoteAccessProcesses.start(of: pid) else {
            // Gone already. Its termination handler finds no child, so the exit is counted here, and it restarts;
            // ssh's once its lines are read.
            perform(run.watch.started(at: Date()), in: run)
            guard let lines else { return perform(run.watch.exited(at: Date()), in: run) }
            lines.afterOutput { [weak self] in
                guard let self, self.run === run, run.lines === lines, run.child == nil else { return }
                self.perform(run.watch.exited(at: Date()), in: run)
            }
            return
        }
        if let record = RemoteAccessProcesses.record(for: pid) { RemoteAccessProcesses.save(record, in: folder) }
        let watchdog = RemoteAccessTunnelGuard.launch(child: pid, start: start)
        run.child = Child(process: process, pid: pid, start: start, metricsPort: metricsPort, watchdog: watchdog)
        perform(run.watch.started(at: Date()), in: run)
    }

    /// The settings file `prepare` wrote, or written again here when something deleted it since (rare, so its flush
    /// on the main thread is too). Nil when it can't be, and the run fails.
    private func cloudflaredSettings(_ prepared: Prepared) -> URL? {
        if let settings = prepared.settings, FileManager.default.fileExists(atPath: settings.path) { return settings }
        do {
            return try Config.writeCloudflaredSettings(in: folder)
        } catch {
            fail("Next Term could not write cloudflared's settings: \(error)")
            return nil
        }
    }

    private func fail(_ reason: String) {
        report?(.tunnelFailed(reason))
    }

    /// The child exited by itself: what is left of its process group is ended and then its record goes, and the
    /// watch says when it restarts. ssh's exit waits for the end of its output, at most a second, so the watch has
    /// every line that says why before it (U15).
    private func exited(_ pid: pid_t, in run: Run) {
        guard self.run === run, let child = run.child, child.pid == pid else { return }
        guard run.kind == .ownServer, let lines = run.lines else { return handleExit(pid, in: run) }
        lines.afterOutput { [weak self] in self?.handleExit(pid, in: run) }
    }

    private func handleExit(_ pid: pid_t, in run: Run) {
        guard self.run === run, let child = run.child, child.pid == pid else { return }
        run.child = nil
        run.checking = false
        retire(child)
        perform(run.watch.exited(at: Date()), in: run)
    }

    /// Reports in order; one may stop this run (a route change), and then the rest are dropped.
    private func perform(_ outputs: [RemoteAccessTunnelWatch.Output], in run: Run) {
        for output in outputs {
            guard self.run === run else { return }
            switch output {
            case .report(let event):
                report?(event)
            case .restart(let wait):
                run.restart(after: wait) { [weak self] in self?.launch(run) }
            case .openLoginTab(let inFront):
                openLoginTab(run, inFront: inFront)
            }
        }
        guard self.run === run, let prepared = run.prepared else { return }
        setWarnings(prepared.warnings + run.watch.warnings.map(\.message))
    }

    // MARK: checks (R32, R33)

    private func tick(_ run: Run) {
        guard self.run === run else { return }
        // ssh says where it stands in its lines, and ends when its connection does: no check to make.
        guard run.child != nil, run.kind != .ownServer else { return perform(run.watch.tick(at: Date()), in: run) }
        check(run)
    }

    private func check(_ run: Run) {
        guard run.kind != .ownServer else { return }
        guard let child = run.child, let prepared = run.prepared, !run.checking else { return }
        if run.kind == .cloudflare, child.metricsPort == nil { return }
        run.checking = true
        let done: @Sendable (RemoteAccessTunnelWatch.Check) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.checked(result, pid: child.pid, in: run) }
            }
        }
        switch run.kind {
        case .cloudflare:
            guard let port = child.metricsPort else { return }
            Self.readMetrics(port: port, done: done)
        default:
            let program = prepared.program
            let environment = Self.toolEnvironment(loginPath: prepared.loginPath)
            DispatchQueue.global(qos: .utility).async {
                let name = Self.tailscaleStatus(program, environment: environment).map(Config.tailscaleStatus)
                let share = Self.funnelStatus(program, environment: environment)
                done(.funnel(name: name, share: share))
            }
        }
    }

    private func checked(_ result: RemoteAccessTunnelWatch.Check, pid: pid_t, in run: Run) {
        guard self.run === run, run.child?.pid == pid else { return }
        run.checking = false
        perform(run.watch.checked(result, at: Date()), in: run)
    }

    /// `/ready` and `/config` at once, through a session with no proxy, no cache and no cookies.
    nonisolated private static func readMetrics(port: Int,
                                                done: @escaping @Sendable (RemoteAccessTunnelWatch.Check) -> Void) {
        let replies = Replies()
        let group = DispatchGroup()
        for path in [Config.MetricsPath.ready, .config] {
            group.enter()
            var request = URLRequest(url: Config.metricsURL(port: port, path: path))
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            metrics.dataTask(with: request) { data, response, _ in
                let status = (response as? HTTPURLResponse)?.statusCode
                if let status, let data { replies.set(path, status: status, body: data) }
                group.leave()
            }.resume()
        }
        group.notify(queue: .global(qos: .utility)) {
            let (ready, config) = replies.read()
            done(.cloudflare(ready: ready, config: config))
        }
    }

    nonisolated private static let metrics: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        return URLSession(configuration: configuration)
    }()

    /// The two metrics replies, filled from the session's queue.
    private final class Replies: @unchecked Sendable {
        private let lock = NSLock()
        private var ready: (status: Int, body: Data)?
        private var config: Data?

        func set(_ path: Config.MetricsPath, status: Int, body: Data) {
            lock.lock()
            defer { lock.unlock() }
            switch path {
            case .ready: ready = (status, body)
            case .config: config = status == 200 ? body : nil
            }
        }

        func read() -> ((status: Int, body: Data)?, Data?) {
            lock.lock()
            defer { lock.unlock() }
            return (ready, config)
        }
    }

    // MARK: output and warnings

    /// The child's output, kept masked; nothing else sees it. ssh's is read line by line for what it says (U15).
    private func listen(to pipe: Pipe, for run: Run, lines: Lines?) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                guard let lines else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.outputEnded(lines, in: run) }
                }
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.run === run else { return }
                    guard let lines else { return self.output.append(data) }
                    self.received(data, into: lines, in: run)
                }
            }
        }
    }

    /// ssh's output as it comes: each line to the watch, and the ones Settings keeps to the output.
    private func received(_ data: Data, into lines: Lines, in run: Run) {
        said(lines.reader.read(data), from: lines, in: run)
    }

    /// Only the newest child's lines count: one already handled says nothing about the next.
    private func said(_ read: [String], from lines: Lines, in run: Run) {
        guard let serverPort = run.server?.port else { return }
        for line in read {
            guard self.run === run, run.lines === lines else { return }
            if Config.keepsSSHLine(line) { output.append(Data((line + "\n").utf8)) }
            guard let meaning = Config.sshLine(line, serverPort: serverPort) else { continue }
            perform(run.watch.ssh(meaning, at: Date()), in: run)
        }
    }

    /// ssh's output ended: its last line is read, then an exit that waited for it is handled.
    private func outputEnded(_ lines: Lines, in run: Run) {
        guard !lines.ended else { return }
        said(lines.reader.finish(), from: lines, in: run)
        lines.outputEnded()
    }

    private func setWarnings(_ new: [String]) {
        guard new != warnings else { return }
        warnings = new
        NotificationCenter.default.post(name: RemoteAccess.didChange, object: nil)
    }

    // MARK: the tools

    /// The clean environment with the login PATH, as LoginShell runs tools; for `cloudflared` U6's builds its own.
    nonisolated static func toolEnvironment(loginPath: [String]) -> [String: String] {
        var environment = TerminalEnvironment.clean(ProcessInfo.processInfo.environment)
        environment["PATH"] = loginPath.joined(separator: ":")
        return environment
    }

    nonisolated static func locate(_ tool: Config.Tool, loginPath: [String]) -> String? {
        #if DEBUG
        if let standIn = activeStandIn { return standIn.program }
        #endif
        return Config.locate(tool, loginPath: loginPath, home: NSHomeDirectory(),
                             isExecutable: FileManager.default.isExecutableFile(atPath:))
    }

    /// What `cloudflared --version` prints, within 5 seconds.
    nonisolated static func versionOutput(of program: String, environment: [String: String]) -> String? {
        #if DEBUG
        if let standIn = activeStandIn { return standIn.version }
        #endif
        return capture(program, ["--version"], environment: environment).map { String(decoding: $0, as: UTF8.self) }
    }

    nonisolated static func tailscaleStatus(_ program: String, environment: [String: String]) -> Data? {
        #if DEBUG
        if let standIn = activeStandIn { return standIn.tailscaleStatus?() }
        #endif
        return capture(program, Config.tailscaleStatusArguments, environment: environment)
    }

    nonisolated static func funnelStatus(_ program: String, environment: [String: String]) -> Data? {
        #if DEBUG
        if let standIn = activeStandIn { return standIn.funnelStatus?() }
        #endif
        return capture(program, Config.funnelStatusArguments, environment: environment)
    }

    /// A tool's standard output, at most 4 MB, or nil when it can't run, prints nothing, or takes longer than
    /// `timeout` (then it is ended with its process group, so a tool a wrapper script runs ends too).
    nonisolated static func capture(_ program: String, _ arguments: [String], environment: [String: String],
                                    timeout: TimeInterval = 5) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        let pid = process.processIdentifier
        let start = RemoteAccessProcesses.start(of: pid)
        let reader = Reader(pipe.fileHandleForReading, limit: 4 * 1024 * 1024)
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            if let start { RemoteAccessProcesses.endNow(pid, start: start, from: .now()) }
            return nil
        }
        guard let data = reader.wait(timeout: 1), !data.isEmpty else { return nil }
        return data
    }

    /// Reads a pipe to its end on its own thread, so a large status never fills the pipe and stalls the tool.
    private final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let done = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle, limit: Int) {
            DispatchQueue.global(qos: .utility).async {
                var read = Data()
                while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
                    if read.count < limit { read.append(chunk) }
                }
                self.lock.lock()
                self.data = read
                self.lock.unlock()
                self.done.signal()
            }
        }

        func wait(timeout: TimeInterval) -> Data? {
            guard done.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    /// A port nothing holds on 127.0.0.1, for `cloudflared`'s metrics: the one the kernel gives a socket bound to
    /// port 0, closed at once.
    nonisolated static func metricsPort() -> Int? {
        #if DEBUG
        if let port = activeStandIn?.metricsPort { return port }
        #endif
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, size) }
        }
        guard bound == 0 else { return nil }
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard named == 0 else { return nil }
        let port = Int(UInt16(bigEndian: address.sin_port))
        return port > 0 ? port : nil
    }

    // MARK: your own server's login (U15)

    /// ssh needs the user to log in: a remote tab on the server, where ssh asks, and ssh starts again once that
    /// tab's login got through. The tab closing first stops Remote access (R47). In front only right after the
    /// user's own Turn On; otherwise it opens in the background and the Mac says where, so nothing the user is
    /// typing goes to the server. With a master connection up, a new tab would join it and log in to nothing,
    /// which gets the child no key: no tab, and it stops, saying what ssh needs.
    private func openLoginTab(_ run: Run, inFront: Bool) {
        guard self.run === run, let server = run.server else { return }
        if RemoteConnection.masterAlive(server.host) {
            return perform(run.watch.loginWontHelp(at: Date()), in: run)
        }
        let tab = RemoteAccessServerTab.open(server.host, inFront: inFront)
        audit?("login_tab", "\(server.name), \(inFront ? "in front" : "in the background")")
        if !inFront {
            let notice = Config.sshLoginTabNotice(server.name)
            notify?(notice.title, notice.body)
        }
        run.waitForLogin { [weak self, weak tab] in
            guard let self, self.run === run else { return true }
            if let tab, tab.remoteConnected, !tab.disconnected {
                self.perform(run.watch.loggedIn(at: Date()), in: run)
                return true
            }
            guard let tab, RemoteAccessServerTab.isOpen(tab), !tab.exited else {
                self.perform(run.watch.loginEnded(at: Date()), in: run)
                return true
            }
            return false
        }
    }

    // MARK: one run

    /// A running child.
    struct Child {
        let process: Process
        let pid: pid_t
        let start: Start
        /// `cloudflared`'s metrics port; nil for Funnel.
        let metricsPort: Int?
        let watchdog: Process?
    }

    /// One ssh child's output, read on the main thread, so its exit is handled after its last line: once its
    /// output ended, or a second after the exit when something it started still holds the pipe.
    @MainActor
    final class Lines {
        var reader = Config.SSHLines()
        private(set) var ended = false
        private var exit: (@MainActor () -> Void)?

        /// Runs `body` once the output ended, or a second from now, whichever comes first; once.
        func afterOutput(_ body: @escaping @MainActor () -> Void) {
            guard exit == nil else { return }
            guard !ended else { return body() }
            exit = body
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.runExit() }
            }
        }

        func outputEnded() {
            ended = true
            runExit()
        }

        private func runExit() {
            let body = exit
            exit = nil
            body?()
        }
    }

    /// One start, until Turn Off: its child (one at a time), its watch and its timers. A reply for another run is
    /// dropped.
    private final class Run: @unchecked Sendable { // read and changed on the main thread only
        let kind: Config.Kind
        let port: Int
        /// Read at each launch; dropped when the run ends, though a closure of its child may still hold the run.
        var token: Config.Token?
        /// Your own server and its server port.
        var server: Config.OwnServer?
        /// The newest ssh child's output.
        var lines: Lines?
        var watch: RemoteAccessTunnelWatch
        let timings: Timings
        var prepared: Prepared?
        var child: Child?
        var checking = false
        private var checks: DispatchSourceTimer?
        private var restart: DispatchSourceTimer?
        private var login: DispatchSourceTimer?

        init(kind: Config.Kind, port: Int, token: Config.Token?, watch: RemoteAccessTunnelWatch, timings: Timings) {
            self.kind = kind
            self.port = port
            self.token = token
            self.watch = watch
            self.timings = timings
        }

        /// A check every interval, the first one 2 seconds after the start, when a tunnel is usually up.
        func startChecks(_ body: @escaping @MainActor () -> Void) {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + min(2, timings.check), repeating: timings.check)
            timer.setEventHandler { MainActor.assumeIsolated { body() } }
            checks = timer
            timer.resume()
        }

        func restart(after wait: TimeInterval, _ body: @escaping @MainActor () -> Void) {
            restart?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + wait)
            timer.setEventHandler { MainActor.assumeIsolated { body() } }
            restart = timer
            timer.resume()
        }

        /// Asks `body` twice a second until it says it is done: whether the login tab's login got through.
        func waitForLogin(_ body: @escaping @MainActor () -> Bool) {
            login?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard body() else { return }
                    self?.login?.cancel()
                    self?.login = nil
                }
            }
            login = timer
            timer.resume()
        }

        func cancelTimers() {
            for timer in [checks, restart, login].compactMap({ $0 }) {
                timer.cancel()
                timer.setEventHandler(handler: nil)
            }
            checks = nil
            restart = nil
            login = nil
        }
    }
}

// MARK: - detection and Test Connection (U11)

extension RemoteAccessTunnel {
    /// What Settings shows of the tools: where each is, its version, and the warnings (R29, R34).
    struct Detection: Equatable, Sendable {
        struct Found: Equatable, Sendable {
            var path: String
            /// The version for display, or nil when it didn't answer.
            var version: String?
            /// `cloudflared` only: older than 2025.4.0, or its version can't be read, so it can't start (R30).
            var tooOld = false
        }

        var cloudflared: Found?
        var tailscale: Found?
        /// `tailscale status --json`: the Mac's name when it is logged in with Funnel allowed, or why not. Settings'
        /// guided mode recommends Funnel from it (R49).
        var tailscaleStatus: Result<String, Config.TailscaleProblem>?
        var warnings: [String] = []
    }

    /// Looks for both tools and reads their versions (5 seconds each), off the main thread; `done` gets them on
    /// it. When Settings opens; a start looks again.
    static func detect(_ done: @escaping @MainActor (Detection) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = detectNow()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(found) }
            }
        }
    }

    nonisolated static func detectNow() -> Detection {
        let loginPath = LoginShell.path
        let environment = toolEnvironment(loginPath: loginPath)
        var detection = Detection()
        if let program = locate(.cloudflared, loginPath: loginPath) {
            let output = versionOutput(of: program, environment: environment)
            let version = output.flatMap(Config.cloudflaredVersion)
            let tooOld = Config.cloudflaredStartProblem(versionOutput: output) != nil
            detection.cloudflared = Detection.Found(path: program, version: version?.text, tooOld: tooOld)
            if let version, version.isOutdated(now: Date()) {
                detection.warnings.append(Config.outdatedWarning(version))
            }
        }
        let services = Config.cloudflaredServices(home: NSHomeDirectory())
        if services.contains(where: FileManager.default.fileExists(atPath:)) {
            detection.warnings.append(Config.cloudflaredServiceWarning)
        }
        if let program = locate(.tailscale, loginPath: loginPath) {
            let printed = tailscaleVersion(of: program, environment: environment)
            detection.tailscale = Detection.Found(path: program, version: printed.flatMap(Config.tailscaleVersion))
            let status = tailscaleStatus(program, environment: environment)
            detection.tailscaleStatus = status.map(Config.tailscaleStatus) ?? .failure(.unreadable)
            if let share = funnelStatus(program, environment: environment), Config.funnelShareExists(share) {
                detection.warnings.append(Config.funnelShareWarning)
            }
        }
        return detection
    }

    nonisolated private static func tailscaleVersion(of program: String, environment: [String: String]) -> String? {
        #if DEBUG
        if activeStandIn != nil { return "1.104.1" }
        #endif
        return capture(program, ["version"], environment: environment).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Test Connection, only on a click (R36): the resource metadata through the public URL, within 15 seconds, and
    /// what came back in a sentence.
    static func testConnection(kind: Config.Kind, host: String, done: @escaping @MainActor (String) -> Void) {
        let test = RemoteAccessConnectionTest.self
        let answer: @Sendable (RemoteAccessConnectionTest.Answer) -> Void = { answer in
            let message = test.message(answer, kind: kind, host: host)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(message) }
            }
        }
        guard let url = test.url(host: host) else { return answer(.failed(.other)) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: test.timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = test.timeout
        let session = URLSession(configuration: configuration)
        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            if let response = response as? HTTPURLResponse {
                let server = response.value(forHTTPHeaderField: "Server")
                return answer(.response(status: response.statusCode, body: data ?? Data(), server: server))
            }
            let code = (error as? URLError)?.code ?? .unknown
            answer(.failed(test.failure(code)))
        }.resume()
    }
}
