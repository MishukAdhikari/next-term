import AppKit
import NextTermCore

/// herdr's client in front of a local tab: its process, the executable to run herdr's commands with, the session it
/// shows, and the variables of its environment that name its server (HerdrClient.variables, and only those).
struct LocalHerdrClient: Equatable {
    var pid: pid_t
    var executable: String
    var session: String?
    var environment: [String: String]

    /// Which herdr server it is: the same executable, session and socket are one server, asked once.
    var server: String {
        let socket = environment["HERDR_SOCKET_PATH"] ?? "", config = environment["XDG_CONFIG_HOME"] ?? ""
        return [executable, session ?? "", socket, config].joined(separator: "\u{0}")
    }

    /// The environment a herdr command runs with on this Mac: the app's, without herdr's variables, then the client's.
    /// For a named session the socket variables stay out, as on a server (they would name the default session's).
    var processEnvironment: [String: String] {
        var env = TerminalEnvironment.clean(ProcessInfo.processInfo.environment).filter { !$0.key.hasPrefix("HERDR_") }
        env.removeValue(forKey: MCPServer.socketVariable)
        for (name, value) in environment where session == nil || name == "XDG_CONFIG_HOME" { env[name] = value }
        return env
    }
}

/// Runs herdr on this Mac: one process, no shell, its output and errors read to their caps, ended at its time limit.
enum LocalHerdr {
    struct Ran {
        var status: Int32
        var output: Data
        var errors: Data
        /// Why it never ran (no such file, not executable), or nil.
        var failure: String?
    }

    /// Off the main thread only: it waits for herdr.
    static func run(_ argv: [String], environment: [String: String], timeout: TimeInterval) -> Ran {
        guard let executable = argv.first else { return Ran(status: -1, output: Data(), errors: Data(), failure: "No herdr to run.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return Ran(status: -1, output: Data(), errors: Data(), failure: "herdr at \(executable) did not run: \(error.localizedDescription)")
        }
        let deadline = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        var errors = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errors = read(err.fileHandleForReading, limit: HerdrResult.errorCap)
            group.leave()
        }
        let output = read(out.fileHandleForReading, limit: HerdrResult.outputCap + 1)
        group.wait()
        process.waitUntilExit()
        deadline.cancel()
        return Ran(status: process.terminationStatus, output: output, errors: errors)
    }

    /// To the end, keeping at most `limit` bytes.
    private static func read(_ handle: FileHandle, limit: Int) -> Data {
        var data = Data()
        while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
            if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
        }
        return data
    }
}

/// The 2-second check for herdr run in local tabs, as the status check is for a server's: while a tab has herdr's client
/// in front, one `herdr agent list` per herdr server (and `herdr tab list` when one of its tabs is on screen and no agent
/// has herdr's focus), off the main thread, through the client's own herdr and its own socket. It stops when no tab
/// needs it. Next Term only reads this herdr: it never starts, keeps or restores it.
final class LocalHerdrWatch {
    static let shared = LocalHerdrWatch()

    private final class Followed {
        weak var tab: TerminalTab?
        init(_ tab: TerminalTab) { self.tab = tab }
    }

    private var tabs: [Followed] = []
    private var timer: Timer?
    private var inFlight: Set<String> = []
    private var soon = false

    /// `tab` has herdr's client in front now (`on`), or no longer.
    func follow(_ tab: TerminalTab, _ on: Bool) {
        tabs.removeAll { $0.tab == nil || $0.tab === tab }
        if on { tabs.append(Followed(tab)) }
        if tabs.isEmpty {
            timer?.invalidate()
            timer = nil
            machineWatches.values.forEach { $0.end() }
            machineWatches = [:]
            return
        }
        if timer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if on { checkSoon() }
    }

    /// A check within 300 ms (a command changed what herdr shows, or a tab started following it).
    func checkSoon() {
        guard !soon else { return }
        soon = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.soon = false
            self?.check()
        }
    }

    /// The machines saved in each herdr server here, by server, read through its first tab (HerdrMachineWatch).
    private var machineWatches: [String: HerdrMachineWatch] = [:]

    /// The machines of the herdr `tab` runs, while it is followed.
    func machines(of tab: TerminalTab) -> HerdrMachineWatch? {
        tab.localHerdr.flatMap { machineWatches[$0.server] }
    }

    /// Every herdr server's machines, followed now.
    var allMachines: [HerdrMachineWatch] { Array(machineWatches.values) }

    private func check() {
        let followed = tabs.compactMap(\.tab).filter { !$0.exited && $0.localHerdr != nil }
        let servers = Dictionary(grouping: followed, by: { $0.localHerdr!.server })
        followMachines(servers)
        for (server, group) in servers where !inFlight.contains(server) {
            guard let client = group.first?.localHerdr else { continue }
            inFlight.insert(server)
            let wantsFocus = group.contains(where: \.isOnScreen)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let report = Self.report(client, wantsFocus: wantsFocus)
                DispatchQueue.main.async {
                    self?.inFlight.remove(server)
                    for tab in group where tab.localHerdr?.server == server { tab.applyHerdr(report) }
                }
            }
        }
    }

    /// Each herdr server's machines, read through its first tab; a server no tab runs any more stops being read.
    private func followMachines(_ servers: [String: [TerminalTab]]) {
        for (server, watch) in machineWatches {
            let reader = servers[server]?.first
            guard reader == nil || reader !== watch.tab else { continue }
            watch.end()
            machineWatches[server] = nil
        }
        for (server, group) in servers {
            guard let first = group.first else { continue }
            let watch = machineWatches[server] ?? HerdrMachineWatch(tab: first)
            machineWatches[server] = watch
            watch.check()
        }
    }

    /// What the client's herdr lists: its agents (`agent list`, else `pane list` before herdr 0.5.10), and the focused tab
    /// when asked and no agent has the focus.
    private static func report(_ client: LocalHerdrClient, wantsFocus: Bool) -> HerdrReport {
        let env = client.processEnvironment
        var listing = HerdrListing.cut
        let attempts = HerdrCommand.list.argv(executable: client.executable, session: client.session, text: nil) ?? []
        for (attempt, verb) in zip(attempts, ["agent", "pane"]) {
            guard let call = attempt.first else { continue }
            let ran = LocalHerdr.run(call, environment: env, timeout: 10)
            if let failure = ran.failure {
                listing = .failed(failure)
                break
            }
            let said = String(decoding: ran.errors, as: UTF8.self) + " " + String(decoding: ran.output, as: UTF8.self)
            if verb == "agent", HerdrResult.saysUnsupported(exit: ran.status, said: said) { continue }
            listing = ran.output.count > HerdrResult.outputCap ? .cut : HerdrAgent.listing(output: said, exit: ran.status, command: verb)
            break
        }
        var report = HerdrReport(path: client.executable, how: "local", listing: listing, session: client.session)
        if wantsFocus, case .agents(let agents) = listing, !agents.contains(where: \.focused),
           let call = HerdrCommand.tabs.argv(executable: client.executable, session: client.session, text: nil)?.first?.first {
            let ran = LocalHerdr.run(call, environment: env, timeout: 10)
            if ran.status == 0 { report.focusedTab = HerdrTabs.focusedTab(String(decoding: ran.output, as: UTF8.self)) }
        }
        return report
    }
}
