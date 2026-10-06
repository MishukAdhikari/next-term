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

    static var isInstalled: Bool { installedTarget == script?.path }

    /// At launch: link /usr/local/bin/nxtrm to this app when that needs no password, so other terminals
    /// have it too (tabs in Next Term always do). Never replaces anything that is not a Next Term link.
    static func registerQuietly() {
        guard let script, isInStableLocation, !isInstalled else { return }
        let directory = (installPath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: directory) else { return }
        if let current = installedTarget {
            // Ours from an older copy of the app (moved, or a different version): repoint it.
            guard current.hasSuffix("/Contents/Resources/bin/\(CommandLineOpen.toolName)") else { return }
            try? FileManager.default.removeItem(atPath: installPath)
        } else if FileManager.default.fileExists(atPath: installPath) {
            return // someone else's nxtrm
        }
        try? FileManager.default.createSymbolicLink(atPath: installPath, withDestinationPath: script.path)
    }

    /// Shell menu: link it, asking for an administrator password when /usr/local/bin needs one.
    static func install(from window: NSWindow?) {
        func tell(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
            let alert = NSAlert()
            alert.alertStyle = style
            alert.messageText = title
            alert.informativeText = text
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
        guard let script else {
            return tell("Only the installed app has the command", "Build the app with scripts/build-dmg.sh, or run it from Applications.", style: .warning)
        }
        guard isInStableLocation else {
            return tell("Move Next Term to Applications first",
                        "It is running from a disk image or a temporary location, and the command would stop working once it moves.",
                        style: .warning)
        }
        if let current = installedTarget, !current.hasSuffix("/Contents/Resources/bin/\(CommandLineOpen.toolName)") {
            return tell("Another “\(CommandLineOpen.toolName)” is installed", "\(installPath) is not Next Term’s; remove it first.", style: .warning)
        }
        let directory = (installPath as NSString).deletingLastPathComponent
        var installed = false
        if FileManager.default.isWritableFile(atPath: directory) {
            try? FileManager.default.removeItem(atPath: installPath)
            installed = (try? FileManager.default.createSymbolicLink(atPath: installPath, withDestinationPath: script.path)) != nil
        } else {
            // One password prompt, as editors do for their command line tools.
            let shell = "/bin/mkdir -p \(ShellQuote.quote(directory)) && /bin/ln -sfh \(ShellQuote.quote(script.path)) \(ShellQuote.quote(installPath))"
            let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            var error: NSDictionary?
            NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
            installed = error == nil && isInstalled
            if let error, (error[NSAppleScript.errorNumber] as? Int) == -128 { return } // cancelled
        }
        if installed {
            tell("“\(CommandLineOpen.toolName)” is installed",
                 "In any terminal: “nxtrm .” opens the folder as a project, “nxtrm file:42” opens a file at line 42.")
        } else {
            tell("“\(CommandLineOpen.toolName)” could not be installed", "Next Term could not write \(installPath).", style: .warning)
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
