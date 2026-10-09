import AppKit
import Darwin
import NextTermCore

/// Runs one Suggest a Command request: the agent CLI the user chose, or Apple's on-device model (OnDeviceSuggestion).
/// The agent runs in a process group of its own, in an empty folder made for it, with none of Next Term's variables
/// (no MCP socket, no nonce), with no tools and no MCP (CommandSuggestion's arguments), and the prompt on its stdin.
/// 60 s or Cancel ends it, and its whole process group with it; so does its own exit, so nothing it started stays.
final class CommandSuggestionRunner {
    typealias Answer = Result<CommandSuggestion.Suggestion, CommandSuggestion.Failure>

    static let timeout: TimeInterval = 60
    #if DEBUG
    /// The self-test's stand-in agent and a shorter time limit; what the last agent was given, for its checks.
    nonisolated(unsafe) static var testProgram: String?
    nonisolated(unsafe) static var testTimeout: TimeInterval?
    nonisolated(unsafe) static var lastFolder: String?
    nonisolated(unsafe) static var lastArguments: [String] = []
    #endif

    /// One request per tab.
    private static var running: [ObjectIdentifier: CommandSuggestionRunner] = [:]

    private let lock = NSLock()
    private var pid: pid_t = 0
    /// The agent has exited and its group was ended: no signal may go to its id any more.
    private var reaped = false
    private var stopped: String?
    private var task: Task<Void, Never>?

    static func isRunning(for tab: TerminalTab) -> Bool { running[ObjectIdentifier(tab)] != nil }

    /// Asks the chosen agent for `tab` (nil when one is already asking for it). `done` runs on the main thread,
    /// once, unless the request is cancelled.
    static func start(for tab: TerminalTab, choice: String, prompt: String, done: @escaping (Answer) -> Void) -> CommandSuggestionRunner? {
        let key = ObjectIdentifier(tab)
        guard running[key] == nil else { return nil }
        let runner = CommandSuggestionRunner()
        running[key] = runner
        let finish: (Answer?) -> Void = { answer in
            DispatchQueue.main.async {
                guard running[key] === runner else { return }
                running[key] = nil
                if let answer { done(answer) }
            }
        }
        if choice == CompletionPreferences.onDevice {
            // Cancel and the time limit end it from here, whether or not the model notices: a late answer is dropped.
            runner.task = Task {
                let answer: Answer
                do {
                    answer = CommandSuggestion.check(try await OnDeviceSuggestion.suggest(prompt))
                } catch {
                    answer = .failure(.agent("Apple’s on-device model could not answer: \(error.localizedDescription)"))
                }
                if !Task.isCancelled { finish(answer) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak runner] in
                guard let runner, running[key] === runner else { return }
                runner.task?.cancel()
                finish(.failure(.agent("Apple’s on-device model took more than \(Int(limit)) s, so it was stopped.")))
            }
            return runner
        }
        guard let adapter = CommandSuggestion.adapter(choice) else {
            finish(.failure(.agent("No agent is chosen for Suggest a Command.")))
            return runner
        }
        DispatchQueue.global(qos: .userInitiated).async {
            finish(runner.run(adapter, prompt: prompt))
        }
        return runner
    }

    private static var limit: TimeInterval {
        #if DEBUG
        if let testTimeout { return testTimeout }
        #endif
        return timeout
    }

    /// Ends the request: the agent's process group goes (TERM, then KILL), and `done` isn't called. From the main
    /// thread (the panel closing), the tab has no request from then on: not one main-queue turn later, by which time
    /// the agent's group can be gone already.
    func cancel() {
        task?.cancel()
        stop(because: "cancelled")
        let forget = { [self] in
            if let key = Self.running.first(where: { $0.value === self })?.key { Self.running[key] = nil }
        }
        if Thread.isMainThread { forget() } else { DispatchQueue.main.async(execute: forget) }
    }

    private func stop(because reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !reaped, stopped == nil else { return }
        stopped = reason
        // Not started yet: run() stops it as it starts.
        guard pid > 0 else { return }
        killpg(pid, SIGTERM)
        let group = pid
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if !self.reaped { killpg(group, SIGKILL) }
            self.lock.unlock()
        }
    }

    // MARK: the agent's process

    private func run(_ adapter: CommandSuggestion.Adapter, prompt: String) -> Answer? {
        guard let program = Self.program(adapter) else {
            return .failure(.agent("\(adapter.name) wasn’t found on your shell’s PATH."))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nt-suggest-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil else {
            return .failure(.agent("Next Term could not make an empty folder for the agent."))
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        #if DEBUG
        Self.lastFolder = folder.path
        Self.lastArguments = adapter.arguments
        #endif
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&errors) == 0 else { return .failure(.agent("Next Term could not start the agent.")) }
        let spawned = Self.spawn(program, adapter.arguments, environment: Self.environment(folder: folder.path), folder: folder.path,
                                 stdin: input[0], stdout: output[1], stderr: errors[1])
        close(input[0])
        close(output[1])
        close(errors[1])
        guard let child = spawned else {
            close(input[1])
            close(output[0])
            close(errors[0])
            return .failure(.agent("\(adapter.name) could not be started."))
        }
        lock.lock()
        pid = child
        if stopped != nil { killpg(child, SIGTERM) }
        lock.unlock()
        let deadline = DispatchWorkItem { [weak self] in self?.stop(because: "timed out") }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.limit, execute: deadline)

        // The answer and the errors, read side by side from the start (an agent that writes before it reads its
        // input never waits on a full pipe); then the prompt and the end of input (an agent that quits first is no
        // SIGPIPE for Next Term).
        var answer = Data(), complaint = Data()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            answer = Self.readAll(output[0], limit: CommandSuggestion.maxAnswerBytes + 1)
            reading.leave()
        }
        reading.enter()
        DispatchQueue.global().async {
            complaint = Self.readAll(errors[0], limit: 16_384)
            reading.leave()
        }
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
        Self.writeAll(input[1], Array(prompt.utf8))
        close(input[1])
        // Its exit, seen before it is reaped: its group goes then, while its id can't belong to anything else.
        var info = siginfo_t()
        _ = waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT)
        lock.lock()
        killpg(child, SIGKILL)
        var status: Int32 = 0
        waitpid(child, &status, 0)
        reaped = true
        let reason = stopped
        lock.unlock()
        deadline.cancel()
        reading.wait()
        close(output[0])
        close(errors[0])

        if reason == "cancelled" { return nil }
        if reason == "timed out" {
            return .failure(.agent("\(adapter.name) took more than \(Int(Self.limit)) s, so it was stopped."))
        }
        let text = String(decoding: answer, as: UTF8.self)
        let parsed = CommandSuggestion.parse(text)
        let exited = status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        if exited != 0, case .failure(.malformed) = parsed {
            let said = String(decoding: complaint, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let last = said.split(separator: "\n").last.map(String.init) ?? ""
            return .failure(.agent("\(adapter.name) stopped with status \(exited)" + (last.isEmpty ? "." : ": \(last.prefix(300))")))
        }
        return parsed
    }

    /// The agent's program: the stand-in in the self-test, else where the login shell's PATH has it.
    private static func program(_ adapter: CommandSuggestion.Adapter) -> String? {
        #if DEBUG
        if let testProgram { return testProgram }
        #endif
        return LoginShell.programs[adapter.program]
    }

    /// A fresh terminal's environment with the login shell's PATH, and nothing of Next Term's: no MCP socket, no
    /// nonce, no editor link.
    static func environment(folder: String) -> [String: String] {
        var env = TerminalEnvironment.clean(ProcessInfo.processInfo.environment)
        for key in env.keys where key.hasPrefix("NEXTTERM") || key == MCPServer.socketVariable || key.hasPrefix("CLAUDE_CODE_SSE") {
            env[key] = nil
        }
        env["PATH"] = LoginShell.path.joined(separator: ":")
        env["PWD"] = folder
        env["DISABLE_AUTOUPDATER"] = "1"
        if env["LANG"]?.isEmpty ?? true { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    /// posix_spawn into a new process group, in `folder`, with only the three descriptors given.
    private static func spawn(_ program: String, _ arguments: [String], environment: [String: String], folder: String,
                              stdin: Int32, stdout: Int32, stderr: Int32) -> pid_t? {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own group, no other descriptor, no signal blocked, and SIGPIPE as a fresh program has it.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        posix_spawn_file_actions_addchdir_np(&actions, folder)
        let argv: [UnsafeMutablePointer<CChar>?] = ([program] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, program, &actions, &attributes, argv, envp)
        return status == 0 ? pid : nil
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written <= 0 { return }
            offset += written
        }
    }

    /// Reads to the end, keeping `limit` bytes at most (and reading on, so the agent never blocks on a full pipe).
    private static func readAll(_ fd: Int32, limit: Int) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            if data.count < limit { data.append(contentsOf: buffer[0..<min(count, limit - data.count)]) }
        }
        return data
    }
}
