import Foundation

// Write with Agent, in the commit sheet: an agent CLI that is installed writes the commit message from
// the changes that will be committed. It runs headless in the repository, with the changes on standard
// input, for a minute at most; its answer goes in the message field, and nothing is committed. The changes
// go to that agent and nowhere else. Design: claudedocs/research_next-term-git-branches (8.14).

/// An agent CLI that can write a commit message, and how to ask it.
public struct CommitMessageAgent: Equatable, Sendable {
    /// The command: "claude".
    public let program: String
    /// What people call it: "Claude Code".
    public let name: String
    /// The prompt goes as `-p <prompt>`, the changes alone on standard input (Gemini CLI and Qwen Code put
    /// the two together); otherwise both go on standard input.
    let promptAsArgument: Bool

    /// Claude Code with no tools at all (it only writes), no MCP servers, and no session kept.
    public static let claude = CommitMessageAgent(program: "claude", name: "Claude Code", promptAsArgument: false)
    /// Codex in a read-only sandbox, nothing kept; its last message goes to a file.
    public static let codex = CommitMessageAgent(program: "codex", name: "Codex", promptAsArgument: false)
    public static let gemini = CommitMessageAgent(program: "gemini", name: "Gemini CLI", promptAsArgument: true)
    public static let qwen = CommitMessageAgent(program: "qwen", name: "Qwen Code", promptAsArgument: true)

    /// In the order they are tried.
    public static let known = [claude, codex, gemini, qwen]

    /// The arguments after the program. Codex writes its answer to `answerFile`; the others print it.
    public func arguments(prompt: String, answerFile: String) -> [String] {
        switch program {
        case "claude":
            // --tools takes a list: last, so nothing after it is read as a tool's name.
            return ["-p", "--output-format", "text", "--no-session-persistence", "--strict-mcp-config", "--tools", ""]
        case "codex":
            return ["exec", "--ephemeral", "--sandbox", "read-only", "--skip-git-repo-check", "--color", "never", "--output-last-message", answerFile, "-"]
        default:
            return ["-p", prompt]
        }
    }

    /// What goes on standard input.
    public func input(prompt: String, changes: String) -> String {
        promptAsArgument ? changes : prompt + "\n\n" + changes
    }

    /// The agent to ask, and where it is: the first of `preferring` (the agents working in this folder)
    /// that is known and installed, else the first installed in `known` order. Nil when none is installed.
    public static func find(preferring: [String] = [], in path: [String],
                            isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> (agent: CommitMessageAgent, path: String)? {
        let preferred = preferring.compactMap { program in known.first { $0.program == program } }
        for agent in preferred + known {
            for directory in path {
                let candidate = (directory as NSString).appendingPathComponent(agent.program)
                if isExecutable(candidate) { return (agent, candidate) }
            }
        }
        return nil
    }

    /// What the agent is asked, with the recent commits' subjects for the house style.
    public static func prompt(recentSubjects: [String]) -> String {
        var text = "Write the commit message for the changes below. Reply with the message alone, as it should be committed: no code fences, "
            + "no quotes, nothing before or after it. The first line is a summary of at most 72 characters; if the change needs explaining, "
            + "a blank line and a short body follow."
        if !recentSubjects.isEmpty {
            text += " Write it the way this repository's recent commits are written:\n" + recentSubjects.map { "- " + $0 }.joined(separator: "\n")
        }
        return text + "\n\nThe changes:"
    }

    /// The subjects of the last commits here, newest first (none in a repository without one).
    public static func recentSubjects(at root: String, git: String, count: Int = 8) -> [String] {
        guard let data = GitRunner.run(git, ["-C", root, "--no-optional-locks", "log", "-n", String(count), "--format=%s"], timeout: 10,
                                       acceptedStatus: [0, 128]) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// What will be committed, as the agent reads it: the staged diff; with nothing staged, every change
    /// (the tracked files against HEAD, then each new file with the start of its text). At most `limit`
    /// bytes, with a line saying when the rest was cut.
    public static func changes(at root: String, git: String, staged: Bool, newFiles: [String] = [], limit: Int = 60_000) -> String {
        let options = ["--no-color", "--no-ext-diff", "--no-textconv", "-M"]
        let base = ["-C", root, "--no-optional-locks", "-c", "core.quotepath=off", "diff"]
        var text: String
        if staged {
            text = GitRunner.run(git, base + ["--cached"] + options, timeout: 20).map { String(decoding: $0, as: UTF8.self) } ?? ""
        } else {
            // Without a first commit there is no HEAD to compare with: the new files are all there is.
            let tracked = GitRunner.run(git, base + options + ["HEAD", "--"], timeout: 20, acceptedStatus: [0, 128])
            text = tracked.map { String(decoding: $0, as: UTF8.self) } ?? ""
            for path in newFiles.prefix(40) {
                text += newFile(path, in: root)
                if text.utf8.count > limit { break }
            }
        }
        guard text.utf8.count > limit else { return text }
        let cut = String(decoding: Array(text.utf8.prefix(limit)), as: UTF8.self)
        return cut + "\n[The rest of the changes is cut here: \(text.utf8.count - limit) more bytes.]\n"
    }

    /// A new file, as the agent reads it: its name and the start of its text (a folder by its name).
    static func newFile(_ path: String, in root: String) -> String {
        if path.hasSuffix("/") { return "\nNew folder: \(path)\n" }
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "\nNew file: \(path)\n" }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4000)) ?? Data()
        guard let text = String(data: head, encoding: .utf8), !head.contains(0) else { return "\nNew file: \(path) (binary)\n" }
        return "\nNew file: \(path)\n" + text + (head.count == 4000 ? "\n[…]\n" : "\n")
    }

    /// The answer as a message: without code fences, terminal colours, surrounding quotes or blank lines.
    public static func message(from output: String) -> String {
        var lines = output.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        for quote in ["\"", "'", "`"] where text.count > 1 && text.hasPrefix(quote) && text.hasSuffix(quote) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // No more than one blank line in a row.
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return text
    }
}

/// One run of an agent for a commit message, which can be stopped. `run` blocks: call it off the main thread.
public final class CommitMessageRun: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case message(String)
        /// It ended without an answer: why, in its own last line.
        case failed(String)
        case timedOut
        case stopped
    }

    private let lock = NSLock()
    private var process: Process?
    private var isStopped = false

    public init() {}

    /// Stops it (from any thread): the agent is asked to quit, and the run ends as `.stopped`.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        isStopped = true
        process?.terminate()
    }

    private var stopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    /// Asks `agent` (at `path`) in `root`, the changes on standard input; its answer, or why there is none.
    public func run(_ agent: CommitMessageAgent, path: String, prompt: String, changes: String, in root: String,
                    environment: [String: String], timeout: TimeInterval = 60) -> Outcome {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("next-term-message-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else {
            return .failed("Could not make a temporary folder.")
        }
        defer { try? fm.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input"), output = folder.appendingPathComponent("output")
        let errors = folder.appendingPathComponent("errors"), answer = folder.appendingPathComponent("answer")
        guard fm.createFile(atPath: input.path, contents: Data(agent.input(prompt: prompt, changes: changes).utf8)),
              fm.createFile(atPath: output.path, contents: nil), fm.createFile(atPath: errors.path, contents: nil),
              let stdin = try? FileHandle(forReadingFrom: input), let stdout = try? FileHandle(forWritingTo: output),
              let stderr = try? FileHandle(forWritingTo: errors) else { return .failed("Could not make a temporary file.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = agent.arguments(prompt: prompt, answerFile: answer.path)
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        lock.lock()
        if isStopped {
            lock.unlock()
            return .stopped
        }
        do { try process.run() } catch {
            lock.unlock()
            return .failed(error.localizedDescription)
        }
        self.process = process
        lock.unlock()
        try? stdin.close()
        try? stdout.close()
        try? stderr.close()
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        if stopped { return .stopped }
        if timedOut { return .timedOut }
        let read = { (url: URL) in (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        // Codex's last message is in its file; what it printed is the fallback.
        let written = read(answer)
        let said = CommitMessageAgent.message(from: written.isEmpty ? read(output) : written)
        guard process.terminationStatus == 0 else {
            let last = (read(errors) + "\n" + read(output)).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
            return .failed(last.map { String($0.prefix(200)) } ?? "It stopped with exit status \(process.terminationStatus).")
        }
        return said.isEmpty ? .failed("It answered with nothing.") : .message(said)
    }
}
