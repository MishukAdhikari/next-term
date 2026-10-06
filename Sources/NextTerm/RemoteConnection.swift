import AppKit
import Darwin
import NextTermCore

/// A tab on a server: which host, which folder there, and the session that keeps it (Connect VPS).
struct RemoteTab {
    var host: RemoteHost
    var directory: String
    /// Next Term's tmux session for this tab (tmux mode); a name either way, for the tab's records.
    var session: String
    var keep: KeepMode

    init(host: RemoteHost, directory: String? = nil, session: String? = nil, keep: KeepMode? = nil) {
        self.host = host
        let folder = directory ?? host.directory
        self.directory = folder
        self.session = session.map(RemoteShell.safeName).flatMap { $0.isEmpty ? nil : $0 } ?? RemoteShell.newSessionName(directory: folder)
        self.keep = keep ?? host.keep
    }

    /// Another tab on the same host, in `directory`, with its own session (a split beside this one).
    func sibling(directory: String) -> RemoteTab { RemoteTab(host: host, directory: directory, keep: keep) }
}

/// The hosts the user saved. In the app's defaults: no passwords or keys, only where to connect.
enum RemoteHosts {
    private static let key = "remoteHosts"

    static var all: [RemoteHost] {
        get { RemoteHost.decodeList(UserDefaults.standard.data(forKey: key)) }
        set { UserDefaults.standard.set(RemoteHost.encodeList(newValue), forKey: key) }
    }

    /// By id, then name, then destination (MCP callers use any of them).
    static func find(_ reference: String) -> RemoteHost? {
        let hosts = all
        let wanted = reference.trimmingCharacters(in: .whitespaces)
        return hosts.first { $0.id == wanted } ?? hosts.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
            ?? hosts.first { $0.destination == wanted }
    }

    /// Adds the host, or replaces the saved one with the same id.
    static func save(_ host: RemoteHost) {
        var hosts = all
        if let index = hosts.firstIndex(where: { $0.id == host.id }) { hosts[index] = host } else { hosts.append(host) }
        all = hosts
    }

    static func remove(id: String) {
        all = all.filter { $0.id != id }
    }
}

/// The ssh side of remote tabs: the system /usr/bin/ssh (so the user's keys, agent, ~/.ssh/config,
/// ProxyJump and UseKeychain all work), one master connection per host shared by its tabs and checks.
enum RemoteConnection {
    #if DEBUG
    /// The self-test's stand-in ssh (CI has no sshd). Debug builds only: a release always runs /usr/bin/ssh.
    nonisolated(unsafe) static var testSSHPath: String?
    #endif

    static var sshPath: String {
        #if DEBUG
        if let testSSHPath { return testSSHPath }
        #endif
        return "/usr/bin/ssh"
    }

    /// Where the master connections' sockets live: a 0700 folder of the user's own. Application Support
    /// when the path is short enough for a Unix socket, else the user's private temporary folder.
    static let controlDirectory: String = {
        let support = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Next Term/ssh")
        let fallback = (NSTemporaryDirectory() as NSString).appendingPathComponent("nt-ssh")
        for folder in [support, fallback] where folder.utf8.count + 1 + 16 <= SSHArguments.maxControlPathBytes {
            if privateFolder(folder) { return folder }
        }
        return fallback
    }()

    /// Creates `path` 0700, or checks an existing one: a real folder (not a link), ours, closed to others.
    private static func privateFolder(_ path: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { return false }
        if info.st_mode & 0o077 != 0 { return chmod(path, 0o700) == 0 }
        return true
    }

    static func controlPath(_ host: RemoteHost) -> String {
        (controlDirectory as NSString).appendingPathComponent(SSHArguments.controlName(host))
    }

    /// The host's master connection is up (a tab opened it): background checks can ride on it.
    static func masterExists(_ host: RemoteHost) -> Bool {
        FileManager.default.fileExists(atPath: controlPath(host))
    }

    /// ssh's arguments for a tab.
    static func tabArguments(_ remote: RemoteTab, tabKey: String) -> [String] {
        used.insert(remote.host.id)
        hosts[remote.host.id] = remote.host
        let script = RemoteShell.tabScript(keep: remote.keep, directory: remote.directory, session: remote.session, tabID: tabKey)
        return SSHArguments.tab(remote.host, controlPath: controlPath(remote.host), command: RemoteShell.command(script))
    }

    /// The environment ssh starts with: a fresh terminal's, without anything that points back at this
    /// Mac (Next Term's MCP socket, the IDE links). ssh sends none of it unless the user's SendEnv says so.
    static func environment() -> [String] {
        var env = TerminalEnvironment.clean(ProcessInfo.processInfo.environment)
        env.removeValue(forKey: MCPServer.socketVariable)
        env.removeValue(forKey: ShellIntegration.nonceVariable)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"]?.isEmpty ?? true { env["LANG"] = "en_US.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }
    }

    // MARK: background commands

    struct Output {
        var status: Int32
        var output: String
        var error: String
        var timedOut = false

        /// ssh's last words, for a person: the remote error, or why ssh gave up.
        var problem: String {
            if timedOut { return "The host did not answer in time." }
            let text = error.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return String(text.suffix(600)) }
            return "ssh ended with status \(status)."
        }
    }

    /// Runs a script on the host (base64 to /bin/sh there) without a terminal. Never prompts (BatchMode):
    /// it rides on a tab's open connection, or on a key the agent holds. `completion` runs on the main thread.
    static func run(_ host: RemoteHost, script: String, timeout: TimeInterval = 20, completion: @escaping (Output) -> Void) {
        used.insert(host.id)
        hosts[host.id] = host
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = SSHArguments.exec(host, controlPath: controlPath(host), command: RemoteShell.command(script))
        process.environment = Dictionary(environment().compactMap { pair -> (String, String)? in
            guard let eq = pair.firstIndex(of: "=") else { return nil }
            return (String(pair[..<eq]), String(pair[pair.index(after: eq)...]))
        }, uniquingKeysWith: { first, _ in first })
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        DispatchQueue.global(qos: .utility).async {
            do { try process.run() } catch {
                DispatchQueue.main.async { completion(Output(status: -1, output: "", error: "Could not start ssh: \(error.localizedDescription)")) }
                return
            }
            var timedOut = false
            let deadline = DispatchWorkItem {
                guard process.isRunning else { return }
                timedOut = true
                process.terminate()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            var errorData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                errorData = err.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let outputData = out.fileHandleForReading.readDataToEndOfFile()
            group.wait()
            process.waitUntilExit()
            deadline.cancel()
            let result = Output(status: process.terminationStatus, output: String(decoding: outputData, as: UTF8.self),
                                error: String(decoding: errorData, as: UTF8.self), timedOut: timedOut)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: quitting

    /// Hosts this run connected to, to close their masters at quit.
    private static var used: Set<String> = []
    private static var hosts: [String: RemoteHost] = [:]

    /// Closes the master connections (tabs are gone by now). Sessions kept by tmux or herdr keep running
    /// on their hosts.
    static func shutdown() {
        let group = DispatchGroup()
        for id in used {
            guard let host = hosts[id], masterExists(host) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: sshPath)
            process.arguments = SSHArguments.exit(host, controlPath: controlPath(host))
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            group.enter()
            DispatchQueue.global().async {
                process.waitUntilExit()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 2)
    }

    // MARK: tabs kept across launches

    private static let recordsKey = "remoteTabs"

    /// Saves the open remote tabs that something keeps on their host (tmux, herdr), to reattach next time.
    static func saveTabs(_ controllers: [TerminalWindowController]) {
        let records = controllers.flatMap { controller in
            controller.tabs.compactMap { tab -> RemoteTabRecord? in
                guard let remote = tab.remote, remote.keep != .off else { return nil }
                return RemoteTabRecord(hostID: remote.host.id, directory: tab.directory, session: remote.session,
                                       keep: remote.keep, project: controller.project, title: tab.userTitle)
            }
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: recordsKey)
    }

    /// Reattaches the tabs kept last time, in the window of the project they were in.
    static func restoreTabs() {
        guard let data = UserDefaults.standard.data(forKey: recordsKey),
              let records = try? JSONDecoder().decode([RemoteTabRecord].self, from: data) else { return }
        UserDefaults.standard.removeObject(forKey: recordsKey)
        let app: AppDelegate = AppDelegate.shared
        for record in records {
            guard let host = RemoteHosts.find(record.hostID), RemoteHost.directoryProblem(record.directory) == nil else { continue }
            let controller = app.controllers.first { $0.project == record.project && record.project != nil }
                ?? app.controllers.first ?? app.openWindow(directory: nil)
            let tab = controller.addRemoteTab(RemoteTab(host: host, directory: record.directory, session: record.session, keep: record.keep),
                                              select: false)
            if let title = record.title { tab.userTitle = title }
            controller.refresh()
        }
    }
}

/// Every 2 seconds, one check per host for all of its tabs: what runs in front of each tab's shell (so
/// agents get the same status as local ones), its folder, and herdr's agents. Only over a master
/// connection a tab already opened: a check never opens a connection or asks for anything.
final class RemotePoller {
    static let shared = RemotePoller()
    private var timer: Timer?
    private var inFlight: Set<String> = []

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func poll() {
        let tabs = AppDelegate.shared.controllers.flatMap(\.tabs).filter { $0.remote != nil && !$0.exited && !$0.disconnected }
        for (hostID, hostTabs) in Dictionary(grouping: tabs, by: { $0.remote!.host.id }) where !inFlight.contains(hostID) {
            guard let host = hostTabs.first?.remote?.host, RemoteConnection.masterExists(host) else { continue }
            inFlight.insert(hostID)
            let specs = hostTabs.map { (id: $0.remoteKey, keep: $0.remote!.keep, session: $0.remote!.session) }
            RemoteConnection.run(host, script: RemoteShell.pollScript(tabs: specs), timeout: 10) { [weak self] result in
                self?.inFlight.remove(hostID)
                guard let poll = RemotePoll.parse(result.output) else { return }
                for tab in hostTabs {
                    if let report = poll.tabs[tab.remoteKey] { tab.applyRemote(report) }
                    if tab.remote?.keep == .herdr, let agents = poll.herdr { tab.applyHerdr(agents) }
                }
            }
        }
    }
}
