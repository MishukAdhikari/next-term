import Foundation

// Write with Agent, in the commit sheet: an agent CLI that is installed writes the commit message from
// the changes that will be committed. It runs headless in an empty folder of its own, never in the
// repository (whose settings could run hooks or send the changes elsewhere), with the changes on standard
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

    /// Claude Code with no tools at all (it only writes), no MCP servers, no session kept, and only your
    /// own settings: none of a project's hooks or environment.
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
            return ["-p", "--output-format", "text", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "user", "--tools", ""]
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

    /// What the agent is asked, with the recent commits' subjects for the house style. Amending, `replacing`
    /// is the last commit's message: the new commit takes its place.
    public static func prompt(recentSubjects: [String], replacing lastMessage: String? = nil) -> String {
        var text = "Write the commit message for the changes below. Reply with the message alone, as it should be committed: no code fences, "
            + "no quotes, nothing before or after it. The first line is a summary of at most 72 characters; if the change needs explaining, "
            + "a blank line and a short body follow."
        if !recentSubjects.isEmpty {
            text += " Write it the way this repository's recent commits are written:\n" + recentSubjects.map { "- " + $0 }.joined(separator: "\n")
        }
        if let lastMessage {
            text += "\n\nThis commit will replace the last commit (it is amended), so the changes below include what that commit did. "
                + "Its message was:\n\n" + lastMessage
        }
        return text + "\n\nThe changes:"
    }

    /// The last commit's whole message, for amending it; nil without one.
    public static func lastMessage(at root: String, git: String) -> String? {
        guard let data = GitRunner.run(git, ["-C", root, "--no-optional-locks", "log", "-1", "--format=%B"], timeout: 10) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// What an amended commit is compared with: the last commit's parent, or for a first commit the
    /// empty tree (whose id depends on the repository's hash).
    static func amendBase(at root: String, git: String) -> String? {
        let parent = GitRunner.run(git, ["-C", root, "--no-optional-locks", "rev-parse", "--verify", "--quiet", "HEAD~1"], timeout: 10, acceptedStatus: [0, 1])
        let id = parent.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if !id.isEmpty { return id }
        let empty = GitRunner.run(git, ["-C", root, "hash-object", "-t", "tree", "--stdin"], timeout: 10, input: Data())
        let tree = empty.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return tree.isEmpty ? nil : tree
    }

    /// The subjects of the last commits here, newest first (none in a repository without one).
    public static func recentSubjects(at root: String, git: String, count: Int = 8) -> [String] {
        guard let data = GitRunner.run(git, ["-C", root, "--no-optional-locks", "log", "-n", String(count), "--format=%s"], timeout: 10,
                                       acceptedStatus: [0, 128]) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// What will be committed, as the agent reads it: the staged diff; with nothing staged, every change
    /// (the tracked files against HEAD, then each new file with the start of its text). `amending`, the
    /// last commit's changes too, as the amended commit holds them. What the agent reads goes on to its
    /// vendor, so the get_diff rules apply: files that usually hold secrets are named and left out, and
    /// secret-looking values are masked. At most `limit` bytes, with a line saying when the rest was cut.
    public static func changes(at root: String, git: String, staged: Bool, newFiles: [String] = [], amending: Bool = false,
                               limit: Int = 60_000) -> String {
        let options = ["--no-color", "--no-ext-diff", "--no-textconv", "-M"]
        let base = ["-C", root, "--no-optional-locks", "-c", "core.quotepath=off", "diff"]
        var text = "", rest = 0
        // Masked as they go in, until the limit: the rest is only counted.
        func add(_ piece: String) {
            if text.utf8.count > limit { rest += piece.utf8.count } else { text += MCPRedaction.redact(piece).text }
        }
        // What is staged is compared with HEAD (before a first commit, with nothing); the work tree with HEAD
        // too, and before a first commit the new files are all there is.
        var args = staged ? base + ["--cached"] + options : base + options
        if amending, let parent = amendBase(at: root, git: git) {
            args += [parent, "--"]
        } else if !staged {
            args += ["HEAD", "--"]
        }
        let diff = GitRunner.run(git, args, timeout: 20, acceptedStatus: [0, 128])
        for file in UnifiedDiff.parse(diff.map { String(decoding: $0, as: UTF8.self) } ?? "") {
            add(shown(file))
        }
        if !staged {
            for path in newFiles.prefix(40) {
                add(newFile(path, in: root))
                if text.utf8.count > limit { break }
            }
        }
        guard text.utf8.count > limit else { return text }
        let cut = String(decoding: Array(text.utf8.prefix(limit)), as: UTF8.self)
        return cut + "\n[The rest of the changes is cut here: \(text.utf8.count - limit + rest) more bytes.]\n"
    }

    /// A file's diff as the agent reads it, or only its name when it (or the name it had) usually holds secrets.
    static func shown(_ file: FileDiff) -> String {
        let reason = [file.newPath, file.oldPath].compactMap { $0 }.lazy.compactMap(MCPProjects.secretReason).first
        guard let reason else { return UnifiedDiff.render(file) }
        return "Left out: \(file.path) (it \(reason))\n"
    }

    /// A new file, as the agent reads it: its name and the start of its text (a folder by its name, and a
    /// file that usually holds secrets by its name alone).
    static func newFile(_ path: String, in root: String) -> String {
        if path.hasSuffix("/") { return "\nNew folder: \(path)\n" }
        if let reason = MCPProjects.secretReason(path) { return "\nNew file: \(path) (left out: it \(reason))\n" }
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

    /// Asks `agent` (at `path`), the changes on standard input; its answer, or why there is none. It runs in
    /// the run's own folder, not the repository: an agent reads the settings of the folder it starts in
    /// (Claude Code's hooks and environment, Gemini CLI's MCP servers), and a repository you cloned can set
    /// those to run its commands or send what the agent reads to another server.
    public func run(_ agent: CommitMessageAgent, path: String, prompt: String, changes: String,
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
        process.currentDirectoryURL = folder
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
