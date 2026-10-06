import AppKit
import NextTermCore

/// Keeps Next Term's MCP server registered in the user's agents while "Let agents control Next Term" is
/// on, and removes it when that is turned off. Only the installed app registers (a development build or
/// a copy running from a disk image would leave a path that soon breaks), and never during the self-test.
enum MCPRegistration {
    /// Per agent (`MCPRegistrar.Target.id`, and "claude"), what the last pass found.
    nonisolated(unsafe) private(set) static var statuses: [String: MCPRegistrar.Status] = [:]
    private static let queue = DispatchQueue(label: "nextterm.mcp-registration")

    static var names: [String: String] {
        var names = ["claude": "Claude Code"]
        for target in MCPRegistrar.targets() { names[target.id] = target.name }
        return names
    }

    /// Posted on the main thread when a pass is done (Settings shows the result).
    static let changed = Notification.Name("NextTermMCPRegistrationsChanged")

    /// Registers (on) or unregisters (off) everywhere, off the main thread.
    static func update(on: Bool) {
        guard !SelfTest.isRequested, let script = CommandLineTool.script, CommandLineTool.isInStableLocation else { return }
        let command = script.path
        queue.async {
            let programs = LoginShell.programs
            var results: [String: MCPRegistrar.Status] = [:]
            for target in MCPRegistrar.targets() {
                let installed = MCPRegistrar.isInstalled(target, found: programs)
                results[target.id] = on ? MCPRegistrar.register(target, command: command, programInstalled: installed)
                                        : MCPRegistrar.unregister(target)
            }
            results["claude"] = claude(on: on, command: command, program: programs["claude"])
            DispatchQueue.main.async {
                statuses = results
                NotificationCenter.default.post(name: changed, object: nil)
            }
        }
    }

    /// Claude Code rewrites `~/.claude.json` itself (under its own lock), so it is changed through its
    /// command line: `claude mcp add-json … --scope user`.
    private static func claude(on: Bool, command: String, program: String?) -> MCPRegistrar.Status {
        let config = (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
        let text = isRegularFile(config) ? (try? String(contentsOfFile: config, encoding: .utf8)) : nil
        let entry = MCPRegistrar.claudeEntry(configuration: text)
        if entry == .taken { return .nameTaken }
        guard let program else { return .notInstalled }
        func run(_ arguments: [String]) -> Bool { LoginShell.run(program, arguments) == 0 }
        switch (on, entry) {
        case (true, .ours(let current)) where current == command:
            return .alreadyRegistered
        case (true, .ours):
            // Another copy of the app: point it here.
            _ = run(["mcp", "remove", "--scope", "user", MCPRegistrar.serverName])
            fallthrough
        case (true, .absent):
            let added = run(["mcp", "add-json", "--scope", "user", MCPRegistrar.serverName, MCPRegistrar.claudeJSON(command: command)])
            return added ? .registered : .skipped("claude mcp add-json failed")
        case (false, .ours):
            return run(["mcp", "remove", "--scope", "user", MCPRegistrar.serverName]) ? .removed : .skipped("claude mcp remove failed")
        default:
            return .removed
        }
    }

    /// For Settings: "Registered in Claude Code, Codex and Cursor."
    static var summary: String {
        let names = self.names
        let registered = statuses.filter { $0.value == .registered || $0.value == .alreadyRegistered }.keys
            .compactMap { names[$0] }.sorted()
        let taken = statuses.filter { $0.value == .nameTaken }.keys.compactMap { names[$0] }.sorted()
        var text = registered.isEmpty ? "Not registered in any agent yet." : "Registered in " + ListFormatter.localizedString(byJoining: registered) + "."
        if !taken.isEmpty {
            text += " " + ListFormatter.localizedString(byJoining: taken) + " already " + (taken.count == 1 ? "has" : "have") + " another server named “next-term”, left as it is."
        }
        return text
    }
}

/// The user's login shell, for what a Finder-launched app cannot see: the PATH set in .zshrc and
/// .zprofile, where agents installed with npm, Homebrew or their own installers live.
enum LoginShell {
    /// Program name → path, for the agents Next Term registers in. Read once per launch.
    static let programs: [String: String] = {
        let names = Set(MCPRegistrar.targets().flatMap(\.programs) + ["claude"])
        var found: [String: String] = [:]
        for directory in path {
            for name in names where found[name] == nil {
                let candidate = (directory as NSString).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate) { found[name] = candidate }
            }
        }
        return found
    }()

    /// What an interactive login shell (5 s at most) sets that a Finder-launched app lacks: PATH, and the
    /// ssh agent socket (Secretive, 1Password, gpg-agent for a YubiKey are set up in .zshrc). One probe
    /// per launch serves the agents' registration and remote tabs' ssh.
    private static let probed: (path: [String], sshAuthSock: String?) = {
        let marker = "__NEXTTERM_ENV__"
        guard let output = capture(shell, ["-l", "-i", "-c", "printf '\(marker)%s\(marker)%s\(marker)' \"$PATH\" \"${SSH_AUTH_SOCK:-}\""], timeout: 5)
        else { return ([], nil) }
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 4 else { return ([], nil) }
        let socket = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        return (parts[1].split(separator: ":").map(String.init), socket.isEmpty ? nil : socket)
    }()

    /// SSH_AUTH_SOCK as the user's shell sets it (nil: the shell leaves launchd's in place).
    static var sshAuthSock: String? { probed.sshAuthSock }

    /// PATH from an interactive login shell (5 s at most), plus the usual install folders.
    static let path: [String] = {
        let home = NSHomeDirectory()
        var directories = probed.path
        directories += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                        "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.claude/local", "\(home)/.opencode/bin",
                        "\(home)/.amp/bin", "\(home)/.cargo/bin"]
        var seen = Set<String>()
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
    }()

    private static var shell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell { return String(cString: shell) }
        return "/bin/zsh"
    }

    /// Runs a program with the login PATH and a clean environment; its exit status (nil: did not finish).
    @discardableResult
    static func run(_ program: String, _ arguments: [String], timeout: TimeInterval = 30) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        var environment = TerminalEnvironment.clean(ProcessInfo.processInfo.environment)
        environment["PATH"] = path.joined(separator: ":")
        environment["DISABLE_AUTOUPDATER"] = "1" // a configuration change, not the moment to update Claude Code
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return wait(process, timeout: timeout)
    }

    private static func capture(_ program: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        process.environment = TerminalEnvironment.clean(ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // A file, not a pipe: a background job the shell starts can keep a pipe open forever.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("nextterm-path-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer { try? FileManager.default.removeItem(at: output) }
        process.standardOutput = handle
        let status = wait(process, timeout: timeout)
        try? handle.close()
        guard status != nil, let data = try? Data(contentsOf: output) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func wait(_ process: Process, timeout: TimeInterval) -> Int32? {
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        return process.terminationStatus
    }
}
