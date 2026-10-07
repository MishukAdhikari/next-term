import AppKit
import NextTermCore

/// Keeps Next Term's MCP server registered in the user's agents while "Let agents control Next Term" is
/// on, and removes it when that is turned off. Only the installed app registers (a development build or
/// a copy running from a disk image would leave a path that soon breaks), and never during the self-test.
enum MCPRegistration {
    /// Per agent (`MCPRegistrar.Target.id`, and "claude"), what the last pass found.
    nonisolated(unsafe) private(set) static var statuses: [String: MCPRegistrar.Status] = [:]
    private static let queue = DispatchQueue(label: "nextterm.mcp-registration")
    /// What waits for the Claude app to quit: true adds Next Term, false takes it out (nil: nothing). Its file is
    /// edited only while it is closed (see `MCPRegistrar.claudeAppBundle`).
    nonisolated(unsafe) private static var claudeAppWaiting: Bool?
    /// The desktop apps the last pass found (`MCPRegistrar.Target.apps`), named in the summary.
    nonisolated(unsafe) private static var appsFound: Set<String> = []

    /// Posted on the main thread when a pass is done (Settings shows the result).
    static let changed = Notification.Name("NextTermMCPRegistrationsChanged")

    /// Registers (on) or unregisters (off) everywhere, off the main thread. `claudeAppOnly`: just the Claude app's
    /// files (when it quits, and at launch with the setting off, in case it was open when the setting was turned off);
    /// `quit`: the Claude app that just quit, not counted as open.
    static func update(on: Bool, claudeAppOnly: Bool = false, quit: pid_t? = nil) {
        guard !SelfTest.isRequested, let script = CommandLineTool.script, CommandLineTool.isInStableLocation else { return }
        let command = script.path
        let apps = installedApps
        queue.async {
            // The Claude app has no program to look for, so its own pass needs no login shell.
            let programs = claudeAppOnly ? [:] : LoginShell.programs
            let found = programs.merging(apps) { program, _ in program }
            let targets = MCPRegistrar.targets().filter { !claudeAppOnly || $0.readOnceBy != nil }
            let pass = MCPRegistrar.pass(targets, command: on ? command : nil, found: found) { isOpen($0, except: quit) }
            var results = pass.statuses
            if !claudeAppOnly { results["claude"] = claude(on: on, command: command, program: found["claude"]) }
            DispatchQueue.main.async {
                statuses = MCPRegistrar.merged(statuses, results, whole: !claudeAppOnly)
                claudeAppWaiting = pass.waiting
                appsFound = Set(apps.keys)
                NotificationCenter.default.post(name: changed, object: nil)
            }
        }
    }

    /// An app is running, not counting `quit` (the one that just quit may still be listed when its notice comes).
    private static func isOpen(_ bundle: String, except quit: pid_t?) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains { !$0.isTerminated && $0.processIdentifier != quit }
    }

    /// Desktop apps that read an agent's file (`MCPRegistrar.Target.apps`): bundle identifier → path.
    private static var installedApps: [String: String] {
        var found: [String: String] = [:]
        for id in MCPRegistrar.targets().flatMap(\.apps) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { found[id] = url.path }
        }
        return found
    }

    /// When the Claude app quits, the edit that waited for it is made, with the setting as it is then.
    static func watchClaudeApp() {
        let center = NSWorkspace.shared.notificationCenter
        _ = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let app, app.bundleIdentifier == MCPRegistrar.claudeAppBundle else { return }
            let on = MainActor.assumeIsolated { AppDelegate.shared.agentControl }
            update(on: on, claudeAppOnly: true, quit: app.processIdentifier)
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
    static var summary: String { MCPRegistrar.summary(statuses, apps: appsFound) }

    /// For Settings: " Quit and reopen the Claude app to add it there too." while that waits (`on`: the setting), or
    /// why its file was left alone.
    static func claudeAppNote(on: Bool) -> String {
        MCPRegistrar.claudeAppNote(waiting: claudeAppWaiting, on: on, statuses: statuses)
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
    /// The command reads the environment with /usr/bin/env, so it is the same text in zsh, bash, fish and
    /// tcsh (fish and csh reject `${VAR:-}`, and fish's "$PATH" is a list joined by spaces).
    private static let probed: (path: [String], sshAuthSock: String?) = {
        defer { isProbed = true }
        let marker = "__NEXTTERM_ENV__"
        guard let output = capture(shell, ["-l", "-i", "-c", "/usr/bin/printf %s \(marker); /usr/bin/env; /usr/bin/printf %s \(marker)"], timeout: 5)
        else { return ([], nil) }
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3 else { return ([], nil) }
        var path: [String] = []
        var socket: String?
        for line in parts[1].split(separator: "\n") {
            if line.hasPrefix("PATH=") { path = line.dropFirst(5).split(separator: ":").map(String.init) }
            if line.hasPrefix("SSH_AUTH_SOCK="), line.count > 14 { socket = String(line.dropFirst(14)) }
        }
        return (path, socket)
    }()

    /// The probe has run (reading `path` or `sshAuthSock` will not wait for it).
    nonisolated(unsafe) static var isProbed = false

    /// Runs the probe off the main thread, if it has not run yet.
    static func warmUp() {
        guard !isProbed else { return }
        DispatchQueue.global(qos: .utility).async { _ = path }
    }

    /// SSH_AUTH_SOCK as the user's shell sets it (nil: the shell leaves launchd's in place).
    static var sshAuthSock: String? { probed.sshAuthSock }

    /// PATH exactly as the login shell sets it, nothing added (empty: the probe failed).
    static var shellPath: [String] { probed.path }

    /// PATH from an interactive login shell (5 s at most), plus the usual install folders.
    static let path: [String] = {
        let home = NSHomeDirectory()
        var directories = probed.path
        directories += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                        "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.claude/local", "\(home)/.opencode/bin",
                        "\(home)/.amp/bin", "\(home)/.cargo/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
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
