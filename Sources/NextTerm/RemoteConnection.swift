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

    /// Tabs per master connection. sshd allows MaxSessions sessions on one connection (10 by default):
    /// every tab is one, and so is every check (the 2 s poll, an MCP check, the sheet's list). Past 7
    /// tabs, a host's tabs open a second master (one more login), then a third.
    static let tabsPerMaster = 7

    static func controlPath(_ host: RemoteHost, slot: Int = 0) -> String {
        (controlDirectory as NSString).appendingPathComponent(SSHArguments.controlName(host) + (slot > 0 ? "-\(slot)" : ""))
    }

    /// The master a tab starting now joins: the first one of its host with room for it.
    static func slot(for tab: TerminalTab, host: RemoteHost) -> Int {
        let name = SSHArguments.controlName(host)
        let others = AppDelegate.shared.controllers.flatMap(\.tabs).filter {
            $0 !== tab && !$0.exited && $0.controlSlot != nil && $0.remote.map { SSHArguments.controlName($0.host) == name } == true
        }
        var slot = 0
        while others.filter({ $0.controlSlot == slot }).count >= tabsPerMaster { slot += 1 }
        return slot
    }

    /// A live master of the host, for checks that are not about one tab (MCP, the sheet): the first.
    static func alivePath(_ host: RemoteHost) -> String? {
        (0..<4).map { controlPath(host, slot: $0) }.first(where: masterAlive(path:))
    }

    /// The host's first master connection is up (a tab opened it).
    static func masterAlive(_ host: RemoteHost) -> Bool { alivePath(host) != nil }

    /// A master connection is up: background checks can ride on it. A socket file alone is not enough
    /// (one left by a crash refuses connections): it must accept one. A dead socket in Next Term's own
    /// folder is removed.
    static func masterAlive(path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { return false }
        if MCPControlServer.answers(path) { return true }
        if info.st_uid == getuid(), (path as NSString).deletingLastPathComponent == controlDirectory { unlink(path) }
        return false
    }

    /// Next Term's ssh config (see SSHArguments.configText): written once per launch, in a private folder
    /// whose path has no spaces. ssh passes it to ProxyJump hops on a shell command line, unquoted, so
    /// "Application Support" would split; with no such folder, no -F (the -o rules still hold for the
    /// target host).
    static let configFile: String? = {
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("nt-ssh")
        let path = (folder as NSString).appendingPathComponent("ssh_config")
        guard privateFolder(folder), !path.contains(where: { $0.isWhitespace || "'\"\\$`;&|<>()*?[]#~".contains($0) }) else { return nil }
        let previous = umask(0o077)
        defer { umask(previous) }
        guard (try? SSHArguments.configText.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return nil }
        chmod(path, 0o600)
        return path
    }()

    // MARK: one login per host

    /// The tab logging in to a host (by control path) while no master exists yet. Other tabs for that
    /// host wait for its connection instead of each asking for the password (restore at launch,
    /// reconnecting after a drop, a split while the first tab is still at ssh's prompt).
    private final class Login {
        weak var tab: TerminalTab?
        init(_ tab: TerminalTab) { self.tab = tab }
    }
    private static var logins: [String: Login] = [:]

    /// Whether `tab` may start ssh on the master at `path` now. A tab that starts with no master opens
    /// it: this copy of Next Term then owns that master, and closes it at quit.
    static func mayConnect(_ tab: TerminalTab, to host: RemoteHost, path: String) -> Bool {
        if masterAlive(path: path) { logins[path] = nil; return true }
        if let other = loginTab(path: path), other !== tab { return false }
        logins[path] = Login(tab)
        owned.insert(path)
        masters[path] = host
        return true
    }

    /// The tab logging in on that master right now (it may be showing ssh's password or host-key prompt).
    static func loginTab(path: String) -> TerminalTab? {
        guard let other = logins[path]?.tab, !other.exited, !other.disconnected, !other.remoteConnected else { return nil }
        return other
    }

    static func loginTab(for host: RemoteHost) -> TerminalTab? {
        (0..<4).lazy.compactMap { loginTab(path: controlPath(host, slot: $0)) }.first
    }

    /// The tab's ssh ended, or it was closed: it no longer holds up the others.
    static func doneConnecting(_ tab: TerminalTab) {
        logins = logins.filter { $0.value.tab != nil && $0.value.tab !== tab }
    }

    /// ssh's arguments for a tab; `token` is this connection's (see RemoteShell.tabScript).
    static func tabArguments(_ remote: RemoteTab, path: String, tabKey: String, token: String) -> [String] {
        let script = RemoteShell.tabScript(keep: remote.keep, directory: remote.directory, session: remote.session, tabID: tabKey, token: token,
                                           completionHook: RemoteCompletionConsent.startsHooked(remote))
        return SSHArguments.tab(remote.host, controlPath: path, configFile: configFile, command: RemoteShell.command(script))
    }

    /// The environment ssh starts with: a fresh terminal's, without anything that points back at this
    /// Mac (Next Term's MCP socket, the IDE links), with the PATH and ssh agent the user's login shell
    /// sets (a Finder-launched app has launchd's: ProxyCommand tools and agent-held keys would be
    /// missing). ssh sends none of it to the host unless the user's SendEnv says so.
    static func environment() -> [String] {
        var env = TerminalEnvironment.clean(ProcessInfo.processInfo.environment)
        env.removeValue(forKey: MCPServer.socketVariable)
        env.removeValue(forKey: ShellIntegration.nonceVariable)
        // The login shell's PATH first, then what the app has, then the system's: ProxyCommand runs
        // through $SHELL -c and needs sh, nc and the user's tools. Never waits for the probe: until it
        // is done (a remote tab opened in the first seconds), the app's own environment.
        var path: [String] = []
        if LoginShell.isProbed { path += LoginShell.path } else { LoginShell.warmUp() }
        path += (env["PATH"] ?? "").split(separator: ":").map(String.init) + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        env["PATH"] = path.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        if LoginShell.isProbed, let socket = LoginShell.sshAuthSock { env["SSH_AUTH_SOCK"] = socket }
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
    /// `input` goes to the script's stdin (a secret that must never be on a command line); without it, nothing.
    static func run(_ host: RemoteHost, path chosen: String? = nil, script: String, input: Data? = nil, timeout: TimeInterval = 20,
                    completion: @escaping (Output) -> Void) {
        guard let path = chosen ?? alivePath(host), masterAlive(path: path) else {
            return completion(Output(status: -2, output: "", error: "There is no open connection to \(host.name): Next Term's checks never log in on their own. Open a remote tab on it first; checks then use that tab's connection."))
        }
        if let since = refused[path], TerminalTab.now - since < 30 {
            return completion(Output(status: -3, output: "", error: refusedNote(host)))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = SSHArguments.exec(host, controlPath: path, configFile: configFile, command: RemoteShell.command(script))
        process.environment = Dictionary(environment().compactMap { pair -> (String, String)? in
            guard let eq = pair.firstIndex(of: "=") else { return nil }
            return (String(pair[..<eq]), String(pair[pair.index(after: eq)...]))
        }, uniquingKeysWith: { first, _ in first })
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        DispatchQueue.global(qos: .utility).async {
            do { try process.run() } catch {
                DispatchQueue.main.async { completion(Output(status: -1, output: "", error: "Could not start ssh: \(error.localizedDescription)")) }
                return
            }
            if let stdin, let input {
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
            }
            var timedOut = false
            let deadline = DispatchWorkItem { [weak process] in
                guard let process, process.isRunning else { return }
                timedOut = true
                process.terminate()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            var errorData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                errorData = read(err.fileHandleForReading, limit: 64 * 1024, process: process)
                group.leave()
            }
            // What a host prints is bounded: a diff is cut on the host, and nothing else is large.
            let outputData = read(out.fileHandleForReading, limit: 8 * 1024 * 1024, process: process)
            group.wait()
            process.waitUntilExit()
            deadline.cancel()
            var result = Output(status: process.terminationStatus, output: String(decoding: outputData, as: UTF8.self),
                                error: String(decoding: errorData, as: UTF8.self), timedOut: timedOut)
            DispatchQueue.main.async {
                // sshd allows MaxSessions (10 by default) sessions on one connection: every tab is one.
                if result.error.contains("refused by peer") || result.error.contains("administratively prohibited") {
                    refused[path] = TerminalTab.now
                    result.error = refusedNote(host)
                }
                completion(result)
            }
        }
    }

    /// Reads to the end, keeping at most `limit` bytes; past it, ssh is stopped (a host cannot flood the app).
    private static func read(_ handle: FileHandle, limit: Int, process: Process) -> Data {
        var data = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty else { break }
            if data.count < limit {
                data.append(chunk.prefix(limit - data.count))
            } else if process.isRunning {
                process.terminate()
            }
        }
        return data
    }

    /// Control paths whose master refused a session lately, and when.
    private static var refused: [String: TimeInterval] = [:]

    /// A host's master refuses more sessions, if it did in the last 30 s: for list_tabs and the checks.
    static func refusal(_ host: RemoteHost) -> String? {
        let recent = (0..<4).contains { slot in refused[controlPath(host, slot: slot)].map { TerminalTab.now - $0 < 30 } ?? false }
        return recent ? refusedNote(host) : nil
    }

    private static func refusedNote(_ host: RemoteHost) -> String {
        "\(host.name) refuses more sessions on one connection (sshd's MaxSessions is lower than its default 10 there; each remote tab is one, and each check one more). Close some tabs on it, or raise MaxSessions in the host's sshd_config. Checks pause for 30 s."
    }

    // MARK: quitting

    /// Masters this copy of Next Term opened, by control path (a host edited while connected has two).
    /// Only those are closed at quit: another running copy may share a master it opened.
    private static var owned: Set<String> = []
    private static var masters: [String: RemoteHost] = [:]

    /// Closes the master connections this copy opened (tabs are gone by now). Sessions kept by tmux or
    /// herdr keep running on their hosts.
    static func shutdown() {
        let group = DispatchGroup()
        for path in owned {
            guard let host = masters[path], FileManager.default.fileExists(atPath: path) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: sshPath)
            process.arguments = SSHArguments.exit(host, controlPath: path)
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

    /// Ends one of Next Term's tmux sessions on a host (End Session, MCP close_tab with force). Over the
    /// host's open connection, like every check.
    /// `completion` gets nil when the session ended, else why it could not be ended.
    static func endSession(_ host: RemoteHost, session: String, completion: @escaping (String?) -> Void) {
        run(host, script: RemoteShell.killSessionScript(session: session) + "\nprintf 'ended\\n'", timeout: 15) { output in
            let ended = RemoteShell.payload(output.output)?.contains { $0 == "ended" } == true
            completion(ended ? nil : output.problem)
        }
    }

    // MARK: tabs kept across launches

    private static let recordsKey = "remoteTabs"

    private static var restored = false
    /// Records not yet reopened: saving waits until they are (it would forget them).
    private static var restoring = false

    /// Saves the open remote tabs that something keeps on their host (tmux, herdr), to reattach next
    /// time. Called as they change (by the poller) and at quit, so a crash loses nothing. Not before the
    /// last launch's tabs were restored, which would forget them.
    static func saveTabs(_ controllers: [TerminalWindowController]) {
        guard restored, !restoring, !SelfTest.isRequested else { return }
        let records = controllers.flatMap { controller in
            controller.groups.flatMap(\.panes).compactMap { tab -> RemoteTabRecord? in
                guard let remote = tab.remote, !tab.exited, remote.keep != .off, !tab.fellBack else { return nil }
                return RemoteTabRecord(hostID: remote.host.id, destination: remote.host.destination, port: remote.host.port,
                                       directory: remote.keep == .tmux ? remote.directory : tab.directory,
                                       session: remote.session, keep: remote.keep, project: controller.project, title: tab.userTitle)
            }
        }
        guard let data = try? JSONEncoder().encode(records), data != UserDefaults.standard.data(forKey: recordsKey) else { return }
        UserDefaults.standard.set(data, forKey: recordsKey)
    }

    /// Reattaches the tabs kept last time, in the window of the project they were in, in their order
    /// (split panes come back as tabs of their own). Once per launch, once the launch has its window: not
    /// under the first-launch folder chooser. A host re-pointed since (another destination or port) is
    /// not followed: its tabs are left out, and the user is told.
    static func restoreTabs(attempt: Int = 0) {
        guard !restored, !restoring else { return }
        let app: AppDelegate = AppDelegate.shared
        // As long as a dialog is up (the first-launch folder chooser), and a while for the first window.
        if NSApp.modalWindow != nil || (app.controllers.isEmpty && attempt < 240) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { restoreTabs(attempt: attempt + 1) }
            return
        }
        guard !SelfTest.isRequested, let data = UserDefaults.standard.data(forKey: recordsKey),
              let records = try? JSONDecoder().decode([RemoteTabRecord].self, from: data), !records.isEmpty else {
            restored = true
            return
        }
        restoring = true
        // ssh needs the login shell's PATH and agent: read them off the main thread first.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = LoginShell.path
            DispatchQueue.main.async {
                reopen(records)
                restoring = false
                restored = true
            }
        }
    }

    private static func reopen(_ records: [RemoteTabRecord]) {
        let app: AppDelegate = AppDelegate.shared
        var skipped: [String] = []
        for record in records {
            guard let host = RemoteHosts.all.first(where: { $0.id == record.hostID }) else {
                skipped.append("a tab on a host that was removed (\(record.destination ?? "?"))")
                continue
            }
            if let destination = record.destination, destination != host.destination || record.port != host.port {
                skipped.append("“\(host.name)”, which now points to \(host.destination) instead of \(destination)")
                continue
            }
            guard RemoteHost.directoryProblem(record.directory) == nil else { continue }
            let controller = app.controllers.first { $0.project == record.project && record.project != nil }
                ?? app.controllers.first ?? app.openWindow(directory: nil)
            let tab = controller.addRemoteTab(RemoteTab(host: host, directory: record.directory, session: record.session, keep: record.keep),
                                              select: false, atEnd: true)
            if let title = record.title { tab.userTitle = title }
            controller.refresh()
        }
        guard !skipped.isEmpty, let window = app.controllers.first?.window else { return }
        let alert = NSAlert()
        alert.messageText = skipped.count == 1 ? "A kept remote tab was not reopened" : "\(skipped.count) kept remote tabs were not reopened"
        alert.informativeText = "Next Term does not follow a host that changed since: " + Set(skipped).sorted().joined(separator: "; ")
            + ". Their sessions keep running there; New Remote Tab lists them once you connect to the host."
        alert.beginSheetModal(for: window)
    }
}

/// Every 2 seconds, one check per connection for all of its tabs: whether each tab's own login reached
/// the host, what runs in front of its shell (so agents get the same status as local ones), its folder
/// and jobs, and herdr's agents. Only as a session on a master a tab opened: a check never logs in.
/// When a master is up, kept tabs on it that lost their connection are reconnected.
final class RemotePoller {
    static let shared = RemotePoller()
    private var timer: Timer?
    private var inFlight: Set<String> = []

    func start() {
        guard timer == nil else { return }
        // ssh's environment needs the login shell's PATH and agent: read once, off the main thread,
        // before the first remote tab asks for it.
        if !SelfTest.isRequested { LoginShell.warmUp() }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func poll() {
        let controllers = AppDelegate.shared.controllers
        RemoteConnection.saveTabs(controllers)
        let remoteTabs = controllers.flatMap(\.tabs).filter { $0.remote != nil && !$0.exited }
        // A master came up again (another tab reconnected, or the network is back): kept tabs that lost
        // theirs with it come back at once, once, without waiting for their timers.
        for tab in remoteTabs where tab.wakesWithMaster && tab.disconnected {
            if let path = tab.controlPath, RemoteConnection.masterAlive(path: path) { tab.reconnect() }
        }
        let tabs = remoteTabs.filter { !$0.disconnected && $0.controlPath != nil }
        // By connection (control path), not host id: a host edited while its tabs are open has two.
        for (path, hostTabs) in Dictionary(grouping: tabs, by: { $0.controlPath! }) where !inFlight.contains(path) {
            guard let host = hostTabs.first?.remote?.host, RemoteConnection.masterAlive(path: path) else { continue }
            inFlight.insert(path)
            let specs = hostTabs.map { (id: $0.remoteKey, keep: $0.remote!.keep, session: $0.remote!.session) }
            RemoteConnection.run(host, path: path, script: RemoteShell.pollScript(tabs: specs), timeout: 10) { [weak self] result in
                self?.inFlight.remove(path)
                guard let poll = RemotePoll.parse(result.output) else { return }
                for tab in hostTabs {
                    if let report = poll.tabs[tab.remoteKey] { tab.applyRemote(report) }
                    if tab.remote?.keep == .herdr, let agents = poll.herdr { tab.applyHerdr(agents) }
                }
            }
        }
    }
}
