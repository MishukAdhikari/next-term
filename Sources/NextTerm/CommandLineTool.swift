import AppKit
import Darwin
import NextTermCore

/// `nxtrm`: the app binary run as a command line tool (`NextTerm --cli …`, through the `nxtrm` script in
/// the bundle). It never starts the user interface: it hands the request to the running Next Term, or
/// starts it with the request.
enum CommandLineTool {
    static func run(_ arguments: [String]) -> Never {
        // `nxtrm mcp`: the MCP server agents start (see MCPServer). A file named "mcp" is `nxtrm ./mcp`.
        if arguments == ["mcp"] { MCPBridge.run() }
        // The self-test's stand-in for opencode, run from a tab (SelfTestIDELinks.swift).
        if arguments.count == 3, arguments[0] == "--self-test-ide-client" { SelfTest.runIDEStandIn(port: arguments[1], output: arguments[2]) }
        // `nxtrm secret run …`, `nxtrm secret import …` and `nxtrm secret help` (Secrets). `nxtrm secret` alone still
        // opens a file named secret.
        if arguments.count >= 2, arguments[0] == "secret" {
            if arguments[1] == "run" { SecretWrapper.run(Array(arguments.dropFirst(2))) }
            if arguments[1] == "import" { SecretPipe.run(Array(arguments.dropFirst(2))) }
            if ["help", "-h", "--help"].contains(arguments[1]) {
                print(SecretRun.help)
                exit(0)
            }
        }
        #if DEBUG
        // The self-test's wrapper (SecretWrapper.runSelfTest); the app refuses this form outside the self-test, and a
        // release build has no such form at all.
        if arguments.count >= 5, arguments[0] == "--self-test-secret-wrapper", arguments[3] == "secret", arguments[4] == "run" {
            SecretWrapper.runSelfTest(arguments)
        }
        #endif
        switch CommandLineOpen.parse(arguments, cwd: FileManager.default.currentDirectoryPath) {
        case .help:
            print(CommandLineOpen.usage)
            exit(0)
        case .version:
            print("Next Term " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "(development build)"))
            exit(0)
        case .error(let message):
            FileHandle.standardError.write(Data("nxtrm: \(message)\n".utf8))
            exit(2)
        case .open(var command):
            for item in command.items where item.isNew {
                guard FileManager.default.createFile(atPath: item.path, contents: nil) else {
                    FileHandle.standardError.write(Data("nxtrm: \(item.path): could not create the file\n".utf8))
                    exit(1)
                }
            }
            command.app = Bundle.main.bundlePath
            deliver(command)
        }
    }

    private static func deliver(_ command: OpenCommand) -> Never {
        guard Bundle.main.bundlePath.hasSuffix(".app"),
              let json = try? JSONEncoder().encode(command), let text = String(data: json, encoding: .utf8) else {
            FileHandle.standardError.write(Data("nxtrm: run the copy inside Next Term.app\n".utf8))
            exit(1)
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != me && $0.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if running {
            DistributedNotificationCenter.default().postNotificationName(
                .init(CommandLineOpen.notificationName), object: nil, userInfo: ["request": text], deliverImmediately: true)
        } else {
            configuration.arguments = ["--open-request", text]
        }
        // Launch, or bring the running app to the front (the system lets Launch Services do that).
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            failure = error
            done.signal()
        }
        _ = done.wait(timeout: .now() + 30)
        if let failure {
            FileHandle.standardError.write(Data("nxtrm: could not open Next Term: \(failure.localizedDescription)\n".utf8))
            exit(1)
        }
        exit(0)
    }

    // MARK: installing

    /// The `nxtrm` script inside the app, or nil in a development build.
    static var script: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("bin/\(CommandLineOpen.toolName)"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// Where the password route links it, when no folder on PATH takes it without one.
    static let installPath = "/usr/local/bin/" + CommandLineOpen.toolName

    /// An app run from a disk image or a quarantine location moves; a link to it would break.
    static var isInStableLocation: Bool {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") { return false }
        let readOnly = (try? Bundle.main.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return !readOnly
    }

    /// What /usr/local/bin/nxtrm points at, if it is a link.
    private static var installedTarget: String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: installPath)
    }

    static var isInstalled: Bool { script != nil && installedTarget == script?.path }

    /// Where `nxtrm` goes for other terminals (CommandLineLink.plan). Reading the login shell's PATH can
    /// take seconds the first time: call it off the main thread.
    static func plan(for script: String, path: [String]? = nil, home: String = NSHomeDirectory()) -> CommandLineLink.Plan {
        CommandLineLink.plan(path: path ?? searchPath, home: home, script: script, isWritable: isWritableFolder, entry: entry(at:),
                             isOurs: isOurs)
    }

    /// A link Next Term made: into a copy of the app (CommandLineLink.isOurs) that, while it is there, is
    /// Next Term by its bundle identifier. One into a copy that has moved or gone still is.
    static func isOurs(_ target: String) -> Bool {
        guard CommandLineLink.isOurs(target) else { return false }
        let app = String(target.dropLast(CommandLineLink.bundledPath.count))
        guard FileManager.default.fileExists(atPath: app) else { return true }
        let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist")
        guard let identifier = info?["CFBundleIdentifier"] as? String else { return false }
        return identifier == CommandLineLink.bundleIdentifier || identifier == Bundle.main.bundleIdentifier
    }

    /// The login shell's PATH; when it could not be read, the one macOS gives every login shell
    /// (/etc/paths and /etc/paths.d), for the menu command. A launch uses only the login shell's.
    private static var searchPath: [String] {
        let probed = LoginShell.shellPath
        return probed.isEmpty ? standardPath : probed
    }

    /// The PATH macOS gives every login shell, from /etc/paths and /etc/paths.d.
    static var standardPath: [String] {
        let extras = (try? FileManager.default.contentsOfDirectory(atPath: "/etc/paths.d")) ?? []
        var folders: [String] = []
        for file in ["/etc/paths"] + extras.sorted().map({ "/etc/paths.d/" + $0 }) {
            let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            folders += text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return folders
    }

    static func entry(at path: String) -> CommandLineLink.Entry {
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            // fileExists follows the link.
            return FileManager.default.fileExists(atPath: path) ? .link(target) : .brokenLink(target)
        }
        return (try? FileManager.default.attributesOfItem(atPath: path)) == nil ? .nothing : .file
    }

    static func isWritableFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        return FileManager.default.isWritableFile(atPath: path)
    }

    /// Links `path` to the script, replacing only a Next Term link. True when it points at the script.
    @discardableResult
    static func link(_ path: String, to script: String) -> Bool {
        switch entry(at: path) {
        case .file:
            return false
        case .link(let target), .brokenLink(let target):
            if target == script { return true }
            guard isOurs(target) else { return false }
            try? FileManager.default.removeItem(atPath: path)
        case .nothing:
            break
        }
        return (try? FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: script)) != nil
    }

    /// At launch: link `nxtrm` for other terminals where that needs no password (tabs in Next Term always
    /// have it), as `plan` says. When no folder on PATH can take it, nothing asks: the password route is
    /// Next Term › Install Command Line Tool (nxtrm)…, or an agent's run_command, which the user sees first.
    static func registerQuietly() {
        guard let script = script?.path, isInStableLocation else { return }
        DispatchQueue.global(qos: .utility).async {
            // Never on a guessed PATH: /etc/paths has neither /opt/homebrew/bin nor ~/.local/bin, so a slow
            // login shell would leave a link where the user's own PATH has none. A later launch decides.
            let path = LoginShell.shellPath
            guard !path.isEmpty else { return }
            register(script, path: path)
        }
    }

    /// The link a launch made without asking: once the user deletes it, no launch makes another.
    static let linkedKey = "commandLineToolLink"

    /// A launch's part: links as `plan` says, except that once the link a launch made is deleted, no new
    /// one is made (Install Command Line Tool… puts it back). A link of Next Term's is still repointed.
    @discardableResult
    static func register(_ script: String, path: [String], home: String = NSHomeDirectory()) -> CommandLineLink.Plan {
        let chosen = plan(for: script, path: path, home: home)
        guard case .link(let candidate) = chosen else { return chosen }
        if entry(at: candidate) == .nothing, let made = UserDefaults.standard.string(forKey: linkedKey), entry(at: made) == .nothing {
            return chosen
        }
        if link(candidate, to: script) {
            UserDefaults.standard.set(candidate, forKey: linkedKey)
        } else {
            NSLog("Next Term: could not link \(candidate)")
        }
        return chosen
    }

    // MARK: the key project window

    /// The key window, if it is a project window and no sheet or modal window is in the way: where a notice
    /// that waits for the user's attention goes.
    static func freeProjectWindow(key: NSWindow?, modal: NSWindow?) -> NSWindow? {
        guard let key, key.windowController is TerminalWindowController, modal == nil, key.attachedSheet == nil else { return nil }
        return key
    }

    // MARK: the menu command

    private static func tell(_ title: String, _ text: String, style: NSAlert.Style = .informational, in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private static let usage = "In any terminal: “nxtrm .” opens the folder as a project, “nxtrm file:42” opens a file at line 42."

    /// Next Term › Install Command Line Tool: in a folder on PATH that takes it without a password, as at
    /// launch; otherwise in /usr/local/bin, asking for an administrator password.
    static func install(from window: NSWindow?) {
        guard let script else {
            return tell("Only the installed app has the command", "Build the app with scripts/build-dmg.sh, or run it from Applications.",
                        style: .warning, in: window)
        }
        guard isInStableLocation else {
            return tell("Move Next Term to Applications first",
                        "It is running from a disk image or a temporary location, and the command would stop working once it moves.",
                        style: .warning, in: window)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let path = searchPath
            let chosen = plan(for: script.path, path: path)
            let onPath = CommandLineLink.folders(path).contains((installPath as NSString).deletingLastPathComponent)
            DispatchQueue.main.async { install(script.path, as: chosen, onPath: onPath, from: window) }
        }
    }

    /// The command the password route runs as root to link `path`: only where nothing is, or over a link
    /// Next Term made. Nil over anything else, which is never replaced.
    static func rootCommand(linking path: String, to script: String) -> String? {
        let flags: String
        switch entry(at: path) {
        case .nothing:
            flags = "-sh" // fails, rather than replaces, if something turns up meanwhile
        case .link(let target), .brokenLink(let target):
            guard target == script || isOurs(target) else { return nil }
            flags = "-sfh"
        case .file:
            return nil
        }
        let directory = (path as NSString).deletingLastPathComponent
        return "/bin/mkdir -p \(ShellQuote.quote(directory)) && /bin/ln \(flags) \(ShellQuote.quote(script)) \(ShellQuote.quote(path))"
    }

    private static func install(_ script: String, as plan: CommandLineLink.Plan, onPath: Bool, from window: NSWindow?) {
        let name = CommandLineOpen.toolName
        switch plan {
        case .linked(let path):
            return tell("“\(name)” is installed", "\(path) opens this Next Term. " + usage, in: window)
        case .link(let path):
            if link(path, to: script) { return tell("“\(name)” is installed", "As \(path). " + usage, in: window) }
            return tell("“\(name)” could not be installed", "Next Term could not write \(path).", style: .warning, in: window)
        case .taken(let path):
            return tell("Another “\(name)” is installed", "\(path) is not Next Term’s; remove it first.", style: .warning, in: window)
        case .unavailable:
            break
        }
        // Every login shell has /usr/local/bin on PATH, unless a startup file sets PATH from scratch.
        let directory = (installPath as NSString).deletingLastPathComponent
        let offPath = onPath ? "" : " \(directory) is not on your shell’s PATH, though: add it there for other terminals to find “\(name)”."
        guard let shell = rootCommand(linking: installPath, to: script) else {
            return tell("Another “\(name)” is installed", "\(installPath) is not Next Term’s; remove it first.", style: .warning, in: window)
        }
        if entry(at: installPath) == .link(script) {
            return tell("“\(name)” is installed", "\(installPath) opens this Next Term." + offPath, in: window)
        }
        var installed = false
        if FileManager.default.isWritableFile(atPath: directory) {
            installed = link(installPath, to: script)
        } else {
            // One password prompt, as editors do for their command line tools.
            let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            var error: NSDictionary?
            NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
            installed = error == nil && isInstalled
            if let error, (error[NSAppleScript.errorNumber] as? Int) == -128 { return } // cancelled
        }
        if installed {
            tell("“\(name)” is installed", onPath ? usage : "As \(installPath)." + offPath, in: window)
        } else {
            tell("“\(name)” could not be installed", "Next Term could not write \(installPath).", style: .warning, in: window)
        }
    }
}

/// `nxtrm mcp`: MCP over stdio for an agent, one JSON-RPC message per line. `initialize` and `tools/list`
/// are answered here at once; each tool call goes to the running app over its socket. Ends when the
/// agent closes stdin.
///
/// The MCP hub rides it (MCPBridgeHub): as it starts, the bridge asks the app which servers the user connected apply to
/// its agent. While none does, every answer is as it was before the hub; once one does, tools/list ends with the
/// catalog, whose calls the bridge answers itself, running the servers as its children.
enum MCPBridge {
    private static let output = NSLock()

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let environment = ProcessInfo.processInfo.environment
        let socket = environment[MCPServer.socketVariable].flatMap { $0.isEmpty ? nil : $0 } ?? MCPServer.socketPath()
        // Next Term's own skills, first, for an agent in a Next Term tab; next-term-tabs while the setting is on.
        let offering = UserDefaults.standard.object(forKey: "agentsOfferTabs") as? Bool ?? true
        let instructions = MCPServer.instructions(inTab: MCPServer.runsUnder(executable: Bundle.main.executablePath ?? ""), offeringTabs: offering)
        let calls = DispatchGroup()
        #if DEBUG
        // The self-test's shorter progress interval (SelfTestOpencodeProgress).
        let progressEvery = MCPProgress.interval(testSeconds: environment["NEXTTERM_TEST_MCP_PROGRESS_SECONDS"])
        #else
        let progressEvery = MCPProgress.interval
        #endif
        let progress = MCPProgress.Tickers(every: progressEvery, send: send)
        let hub = MCPBridgeHub(socket: socket, version: version, environment: environment)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            let messages = (object as? [[String: Any]]) ?? [(object as? [String: Any]) ?? [:]]
            for message in messages {
                progress.cancel(message) // notifications/cancelled: that call's progress stops
                if message["method"] as? String == "tools/call" {
                    // Calls can take long (wait_for_tab): answer pings and other calls meanwhile. One that carries a
                    // progress token gets progress until its answer is sent (MCPProgress).
                    progress.answer(message, in: calls) {
                        // Only a catalog tool's call waits for the hub's plan; Next Term's own go to the app as they did.
                        let session = MCPHubCatalog.isCatalogTool(MCPBridgeHub.toolName(message)) ? hub.session : nil
                        return MCPServer.respond(to: message, version: version, extra: session?.tools ?? [],
                                                 callExtra: { session?.call($0, $1) ?? [:] }, call: { forward($0, $1, socket: socket) })
                    }
                } else {
                    // The tool list is the one place the hub shows: it waits for the plan (MCPBridgeHub.planWait at most).
                    let session = message["method"] as? String == "tools/list" ? hub.session : nil
                    if let response = MCPServer.respond(to: message, version: version, instructions: instructions,
                                                        extra: session?.tools ?? [],
                                                        call: { _, _ in MCPServer.CallResult(text: "") }) {
                        send(response)
                    }
                }
            }
        }
        progress.stopAll() // stdin closed: the calls in flight send no more progress
        calls.wait() // stdin closed: finish the answers in flight (a caller may still read them), then go
        hub.stop() // the session's servers end with it
        exit(0)
    }

    private static func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        output.lock()
        FileHandle.standardOutput.write(data)
        output.unlock()
    }

    /// One tool call through the app's socket. While Next Term restarts (its socket refuses, or a connection ends with no
    /// answer), a tool that only reads is tried again for about 20 seconds, and one that changes anything fails at once
    /// (MCPServer.retryDelay, KTD17).
    static func forward(_ tool: String, _ arguments: [String: Any], socket path: String) -> MCPServer.CallResult {
        // When a try first found Next Term restarting: the retries are counted from then.
        var restartedAt: Date?
        while true {
            let failure: MCPServer.SocketFailure
            switch attempt(tool, arguments, socket: path) {
            case .success(let result): return result
            case .failure(let failed): failure = failed
            }
            if failure.meansRestarting && restartedAt == nil { restartedAt = Date() }
            let elapsed = restartedAt.map { (since: Date) -> TimeInterval in Date().timeIntervalSince(since) } ?? 0
            let restarting = restartedAt != nil
            guard let delay = MCPServer.retryDelay(tool, after: failure, restarting: restarting, elapsed: elapsed) else {
                return MCPServer.failedAnswer(tool, failure, restarting: restarting)
            }
            Thread.sleep(forTimeInterval: delay)
        }
    }

    /// Connects to the app's socket: the descriptor, or how it failed.
    private static func connect(_ path: String) -> Result<Int32, MCPServer.SocketFailure> {
        let fd = MCPSocket.connect(path: path)
        // Refused and missing by errno; any other failure, a path too long for a socket included, is unreachable.
        guard fd >= 0 else { return .failure(MCPServer.SocketFailure(connectError: errno)) }
        return .success(fd)
    }

    /// One try: the app's answer, or how the socket failed. `wait`: how long the answer may take (the tool's own by default).
    static func attempt(_ tool: String, _ arguments: [String: Any], socket path: String,
                        wait: TimeInterval? = nil) -> Result<MCPServer.CallResult, MCPServer.SocketFailure> {
        let fd: Int32
        switch connect(path) {
        case .success(let connected): fd = connected
        case .failure(let failure): return .failure(failure)
        }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let waitSeconds = tool == "wait_for_tab" ? Double(min(300, arguments["timeout_seconds"] as? Int ?? 50)) : (MCPServer.tool(named: tool)?.timeout ?? 30)
        var timeout = timeval(tv_sec: Int(wait.map { max(1, $0) } ?? min(1900, waitSeconds + 30)), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let caller = MCPServer.herdrCaller(ProcessInfo.processInfo.environment) // the herdr pane this agent runs in, if any
        guard let request = MCPServer.request(tool: tool, arguments: arguments, caller: caller) else {
            return .success(MCPServer.CallResult(text: "The arguments are not valid JSON.", isError: true))
        }
        let sent = request.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        guard sent else { return .failure(.notSent) }
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var ended = false
        while !answer.contains(0x0A) {
            let count = read(fd, &buffer, buffer.count)
            // 0: the connection ended; -1 with SO_RCVTIMEO: the wait ran out.
            if count == 0 { ended = true }
            if count <= 0 { break }
            answer.append(contentsOf: buffer[0..<count])
        }
        guard let end = answer.firstIndex(of: 0x0A), let result = MCPServer.decodeAnswer(answer[..<end]) else {
            return .failure(ended ? .endedWithoutAnswer : .timedOut)
        }
        return .success(result)
    }
}

/// The MCP hub in a bridge: the plan the app gives for this agent, asked for as the bridge starts so tools/list rarely
/// waits, and the session that runs its servers (MCPHubSession). No list of the user's (the app isn't even asked), no
/// app, no tab, or no server: no plan, and the catalog stays out of every answer.
final class MCPBridgeHub: @unchecked Sendable {
    /// The longest the app's plan is waited for: within Codex's 10-second start-up wait, with room for the rest.
    static let planWait: TimeInterval = 5

    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var made: MCPHubSession?
    private var terminate: DispatchSourceSignal?

    init(socket: String, version: String, environment: [String: String]) {
        let fetch: MCPHubSession.Refresh = { Self.plan(socket: socket) }
        let nxtrm = [Bundle.main.executablePath ?? CommandLine.arguments[0], "--cli"]
        // No list of the user's, no server (R17): the app isn't asked, and nothing waits. The file is made with the first
        // server the user adds (MCPHubScope.save); a project's list starts nothing until the user approves it, and that
        // approval, when it comes, is kept in the user's list too.
        guard FileManager.default.fileExists(atPath: Self.userFile(environment)) else {
            made = MCPHubSession(plan: nil, refresh: { nil }, nxtrm: nxtrm, environment: environment, version: version)
            ready.signal()
            return
        }
        // How a start ended goes to the app, never waited for: Settings › MCP Servers shows the last one.
        let report: MCPHubSession.Report = { server, list, failure, tools in
            DispatchQueue.global(qos: .utility).async {
                var arguments: [String: Any] = ["server": server, "list": list, "tools": tools]
                if let failure { arguments["failure"] = failure }
                _ = MCPBridge.attempt(MCPHubPlan.reportTool, arguments, socket: socket, wait: 2)
            }
        }
        // A remote server is reached by the app, which alone fills its keys in: the bridge runs as the user under the
        // agent, so a key it held, or could ask the socket for, the agent could read too.
        let remote: MCPHubSession.Remote = { arguments, wait in
            guard case .success(let answer) = MCPBridge.attempt(MCPHubPlan.remoteTool, arguments, socket: socket, wait: wait) else { return nil }
            return (answer.text, answer.isError)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let session = MCPHubSession(plan: fetch(), refresh: fetch, nxtrm: nxtrm, environment: environment, version: version,
                                        report: report, remote: remote)
            self.lock.lock()
            self.made = session
            self.lock.unlock()
            if session.isActive { self.stopOnTerminate() }
            self.ready.signal()
        }
    }

    /// The session, once the plan came or its wait ran out (then, one with no plan: the catalog stays out).
    var session: MCPHubSession? {
        if ready.wait(timeout: .now() + Self.planWait) == .success { ready.signal() }
        lock.lock()
        defer { lock.unlock() }
        return made
    }

    /// Ends the servers the session started.
    func stop() {
        lock.lock()
        let session = made
        lock.unlock()
        session?.stop()
    }

    /// An agent that ends its servers with SIGTERM ends this bridge's servers too, before the bridge goes.
    private func stopOnTerminate() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler { [weak self] in
            self?.stop()
            exit(0)
        }
        source.resume()
        terminate = source
    }

    /// The user's list, whose being there is the bridge's sign that a server may apply.
    static func userFile(_ environment: [String: String]) -> String {
        #if DEBUG
        // The self-test's own list (SelfTestMCPHub), which its app reads through MCPHubControl.userFile.
        if let file = environment[selfTestUserFileVariable], !file.isEmpty { return file }
        #endif
        return MCPHubScope.userPath()
    }

    #if DEBUG
    static let selfTestUserFileVariable = "NEXTTERM_SELFTEST_MCP_HUB_FILE"
    #endif

    /// The app's plan for this bridge's agent, or nil (no app, no tab, no server).
    static func plan(socket: String) -> MCPHubPlan? {
        guard case .success(let answer) = MCPBridge.attempt(MCPHubPlan.tool, [:], socket: socket, wait: planWait), !answer.isError else {
            return nil
        }
        return MCPHubPlan.decode(answer.text)
    }

    static func toolName(_ message: [String: Any]) -> String {
        (message["params"] as? [String: Any])?["name"] as? String ?? ""
    }
}
