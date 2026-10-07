import AppKit
import NextTermCore

/// `nxtrm`: the app binary run as a command line tool (`NextTerm --cli …`, through the `nxtrm` script in
/// the bundle). It never starts the user interface: it hands the request to the running Next Term, or
/// starts it with the request.
enum CommandLineTool {
    static func run(_ arguments: [String]) -> Never {
        // `nxtrm mcp`: the MCP server agents start (see MCPServer). A file named "mcp" is `nxtrm ./mcp`.
        if arguments == ["mcp"] { MCPBridge.run() }
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
    /// have it), as `plan` says. When no folder on PATH can take it, offer the password route.
    static func registerQuietly() {
        guard let script = script?.path, isInStableLocation else { return }
        DispatchQueue.global(qos: .utility).async {
            // Never on a guessed PATH: /etc/paths has neither /opt/homebrew/bin nor ~/.local/bin, so a slow
            // login shell would bring the password offer where neither needs one. A later launch decides.
            let path = LoginShell.shellPath
            guard !path.isEmpty, register(script, path: path) == .unavailable else { return }
            DispatchQueue.main.async { offer() }
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

    // MARK: the first-launch offer

    /// The version the offer was last shown in, or CommandLineLink.declined.
    static let offerKey = "commandLineToolOffer"

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Set while the offer waits for a project window.
    private static var offerWait: NSObjectProtocol?

    /// No folder on PATH takes `nxtrm` without a password: offer the password route, once per version, on
    /// a project window once nothing else is in the way, however long the launch's own windows (the folder
    /// chooser, Import, Welcome) take. Until then it waits for a project window to become key.
    private static func offer() {
        let remembered = UserDefaults.standard.string(forKey: offerKey)
        guard CommandLineLink.shouldOffer(remembered: remembered, version: version), offerWait == nil, !showOffer() else { return }
        offerWait = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            // Once the change is over: a sheet or modal session that is ending is still there when it posts.
            DispatchQueue.main.async {
                guard let wait = offerWait, showOffer() else { return }
                NotificationCenter.default.removeObserver(wait)
                offerWait = nil
            }
        }
    }

    /// Shows the offer on the key project window, unless a sheet or modal window is in the way. True when
    /// it is shown, or no longer needed.
    private static func showOffer() -> Bool {
        if isInstalled { return true } // with the menu command, meanwhile
        guard let window = offerWindow(key: NSApp.keyWindow, modal: NSApp.modalWindow) else { return false }
        UserDefaults.standard.set(version, forKey: offerKey)
        offerAlert().beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                DispatchQueue.main.async { install(from: window) }
            } else if response == .alertThirdButtonReturn {
                UserDefaults.standard.set(CommandLineLink.declined, forKey: offerKey)
            }
        }
        return true
    }

    /// Where the offer goes: the key window, if it is a project window and no sheet or modal window is in
    /// the way.
    static func offerWindow(key: NSWindow?, modal: NSWindow?) -> NSWindow? {
        guard let key, key.windowController is TerminalWindowController, modal == nil, key.attachedSheet == nil else { return nil }
        return key
    }

    static func offerAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Install the “\(CommandLineOpen.toolName)” command?"
        alert.informativeText = """
            Then “nxtrm .” opens a folder in Next Term from any terminal, and “nxtrm file:42” a file at a line \
            (Next Term’s own tabs have it already). No folder on your PATH takes it without a password, so this \
            links \(installPath) and asks for your administrator password once. You can also do it later from \
            Next Term › Install Command Line Tool (nxtrm)…
            """
        alert.addButton(withTitle: "Install…")
        alert.addButton(withTitle: "Not Now").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Don’t Ask Again")
        return alert
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
enum MCPBridge {
    private static let output = NSLock()

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let environment = ProcessInfo.processInfo.environment
        let socket = environment[MCPServer.socketVariable].flatMap { $0.isEmpty ? nil : $0 } ?? MCPServer.socketPath()
        let calls = DispatchGroup()
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            let messages = (object as? [[String: Any]]) ?? [(object as? [String: Any]) ?? [:]]
            for message in messages {
                if message["method"] as? String == "tools/call" {
                    // Calls can take long (wait_for_tab): answer pings and other calls meanwhile.
                    DispatchQueue.global().async(group: calls) {
                        if let response = MCPServer.respond(to: message, version: version, call: { forward($0, $1, socket: socket) }) {
                            send(response)
                        }
                    }
                } else if let response = MCPServer.respond(to: message, version: version, call: { _, _ in MCPServer.CallResult(text: "") }) {
                    send(response)
                }
            }
        }
        calls.wait() // stdin closed: finish the answers in flight (a caller may still read them), then go
        exit(0)
    }

    private static func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        output.lock()
        FileHandle.standardOutput.write(data)
        output.unlock()
    }

    static func forward(_ tool: String, _ arguments: [String: Any], socket path: String) -> MCPServer.CallResult {
        let fd = MCPControlServer.connectSocket(path)
        guard fd >= 0 else {
            return MCPServer.CallResult(text: "Next Term is not running, or “Let agents control Next Term” is off in its Settings. Open Next Term and try again.", isError: true)
        }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let waitSeconds = tool == "wait_for_tab" ? Double(min(300, arguments["timeout_seconds"] as? Int ?? 50)) : (MCPServer.tool(named: tool)?.timeout ?? 30)
        var timeout = timeval(tv_sec: Int(min(1900, waitSeconds + 30)), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let request = MCPServer.request(tool: tool, arguments: arguments) else {
            return MCPServer.CallResult(text: "The arguments are not valid JSON.", isError: true)
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
        guard sent else { return MCPServer.CallResult(text: "Next Term closed the connection.", isError: true) }
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !answer.contains(0x0A) {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            answer.append(contentsOf: buffer[0..<count])
        }
        guard let end = answer.firstIndex(of: 0x0A), let result = MCPServer.decodeAnswer(answer[..<end]) else {
            return MCPServer.CallResult(text: "Next Term did not answer in time.", isError: true)
        }
        return result
    }
}
