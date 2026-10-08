import Foundation

/// Suggest a Command (opt-in, off by default): a sentence turned into one shell command by the user's own agent
/// CLI or Apple's on-device model, put on the line and never run. Next Term has no AI of its own: this only builds
/// what the agent is given (its arguments, with no tools and no MCP; the prompt, redacted) and checks what comes
/// back. The app runs it (CommandSuggestionRunner) only when the user presses the shortcut and submits.
public enum CommandSuggestion {
    /// An agent CLI that can be run with no tools and no MCP, and how. The prompt goes on stdin, never on the
    /// command line (where any user on the Mac could read it in `ps`).
    public struct Adapter: Equatable, Sendable {
        public let id: String
        public let name: String
        /// The program, found on the login shell's PATH.
        public let program: String
        public let arguments: [String]
        /// When its flags were last checked, and against which version.
        public let checked: String
    }

    /// The JSON the agent's answer must fit: one command.
    public static let schema = #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"],"additionalProperties":false}"#

    /// Claude Code in print mode: JSON out with the schema, every built-in tool off, MCP off three ways (no
    /// servers, only those given, every MCP tool denied), one turn, no saved session, and safe mode, so the
    /// user's hooks, plugins and CLAUDE.md don't run or load. Nothing it could be asked would prompt.
    public static let claude = Adapter(
        id: "claude", name: "Claude Code", program: "claude",
        arguments: ["-p", "--output-format", "json", "--json-schema", schema, "--tools", "", "--strict-mcp-config", "--mcp-config",
                    #"{"mcpServers":{}}"#, "--disallowedTools", "mcp__*", "--max-turns", "1", "--no-session-persistence",
                    "--permission-prompts", "none", "--disable-slash-commands", "--safe-mode"],
        checked: "2026-10-08, Claude Code 2.1.280")

    /// The agents Next Term can ask.
    public static let adapters: [Adapter] = [claude]

    /// The agents left out, and why: each must run with no tools and no MCP, and that wasn't true or couldn't be
    /// checked. (Checked 2026-10-08.)
    public static let leftOut: [(name: String, why: String)] = [
        ("Codex", "codex exec has no way to turn all of its tools off, only to sandbox them; a read-only sandbox limits them but doesn't remove them (0.154.0)"),
        ("Copilot CLI", "its flags for running with no tools and no MCP couldn't be checked here"),
        ("opencode", "its flags for running with no tools and no MCP couldn't be checked here"),
    ]

    public static func adapter(_ id: String) -> Adapter? { adapters.first { $0.id == id } }

    // MARK: the prompt

    public struct Request: Equatable, Sendable {
        public var sentence: String
        public var directory: String
        public var shell: String
        /// The last command, as typed, and how it ended.
        public var lastCommand: String?
        public var lastExit: Int32?
        /// Recent output: only what the user saw and confirmed for this one request.
        public var output: String?

        public init(sentence: String, directory: String, shell: String, lastCommand: String? = nil, lastExit: Int32? = nil, output: String? = nil) {
            self.sentence = sentence
            self.directory = directory
            self.shell = shell
            self.lastCommand = lastCommand
            self.lastExit = lastExit
            self.output = output
        }
    }

    /// Output sent at most, from its end.
    public static let maxOutput = 8000

    /// The last command as sent: secrets masked.
    public static func redactedCommand(_ command: String) -> String { masked(command) }

    /// Recent output as sent: its end, secrets masked (command lines typed at a prompt are in it too).
    public static func redactedOutput(_ output: String) -> String { masked(String(output.suffix(maxOutput))) }

    /// The command-line secret detector's masking (CommandSecrets): MCPRedaction's secrets, and the shapes secrets
    /// take on a command line, such as `-p…`, `--password=…` and `API_KEY=…`.
    static func masked(_ text: String) -> String { CommandSecrets.mask(text) }

    /// What the agent is asked: the sentence, the folder, the shell, the last command and how it ended (redacted),
    /// and recent output only when the user confirmed it (redacted too).
    public static func prompt(_ request: Request) -> String {
        var lines = [
            "Turn the request below into one shell command for \(request.shell). Answer with the command only, as the `command` field: no explanation, no code fence. It will be put on the user's command line for them to read and run themselves; it is never run for them.",
            "",
            "Shell: \(request.shell)",
            "Folder: \(request.directory)",
        ]
        if let last = request.lastCommand, !last.isEmpty {
            let ended = request.lastExit.map { " (exit \($0))" } ?? ""
            lines.append("Last command: \(redactedCommand(last))\(ended)")
        }
        if let output = request.output, !output.isEmpty {
            lines += ["Recent output:", "<<<", redactedOutput(output), ">>>"]
        }
        lines += ["", "Request: \(request.sentence)"]
        return lines.joined(separator: "\n")
    }

    // MARK: the answer

    public struct Suggestion: Equatable, Sendable {
        public var command: String
        /// More than one line: it goes on the line only where the shell takes it as one edit.
        public var multiline: Bool
        /// The command with invisible or direction-changing characters spelled out, for the panel.
        public var shown: String
        public var hasHidden: Bool
        /// What it does that deserves a second look; never a reason to refuse it.
        public var notes: [String]
    }

    public enum Failure: Error, Equatable, Sendable {
        case empty
        case controlCharacters
        case tooLong
        case malformed(String)
        /// The agent said why it couldn't answer.
        case agent(String)

        public var message: String {
            switch self {
            case .empty: return "The agent gave no command."
            case .controlCharacters: return "The agent’s answer held control characters, so it was not put on the line."
            case .tooLong: return "The agent’s answer was too long to be one command."
            case .malformed(let what): return "The agent’s answer could not be read (\(what))."
            case .agent(let why): return why.isEmpty ? "The agent could not answer." : why
            }
        }
    }

    /// Answers longer than these are not one command (the command in UTF-8 bytes: escaped for the shell's hook,
    /// it stays well inside one private key's 64 KiB).
    public static let maxAnswerBytes = 65_536
    public static let maxCommand = 4096

    /// Claude Code's JSON result: `structured_output.command`, else `result` (a JSON object or the command itself).
    public static func parse(_ output: String) -> Result<Suggestion, Failure> {
        guard output.utf8.count <= maxAnswerBytes else { return .failure(.tooLong) }
        guard let data = output.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.malformed("not JSON"))
        }
        if object["is_error"] as? Bool == true {
            return .failure(.agent(String((object["result"] as? String ?? "").prefix(600))))
        }
        if let structured = object["structured_output"] as? [String: Any], let command = structured["command"] as? String {
            return check(command)
        }
        guard let result = object["result"] as? String else { return .failure(.malformed("no result")) }
        if let inner = result.data(using: .utf8), let fields = try? JSONSerialization.jsonObject(with: inner) as? [String: Any],
           let command = fields["command"] as? String {
            return check(command)
        }
        return check(result)
    }

    /// One command, checked: a code fence around it goes; control characters other than a newline refuse it;
    /// invisible and direction-changing characters are spelled out for the panel; risky parts get a note.
    public static func check(_ answer: String) -> Result<Suggestion, Failure> {
        var text = answer.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        text = unfenced(text)
        guard !text.isEmpty else { return .failure(.empty) }
        guard text.utf8.count <= maxCommand else { return .failure(.tooLong) }
        if text.unicodeScalars.contains(where: { $0 != "\n" && ShellQuote.isControl($0) }) { return .failure(.controlCharacters) }
        let hidden = text.unicodeScalars.contains(where: WordQuote.isHidden)
        let shown = text.split(separator: "\n", omittingEmptySubsequences: false).map { CompletionRanking.visible(String($0)) }.joined(separator: "\n")
        return .success(Suggestion(command: text, multiline: text.contains("\n"), shown: shown, hasHidden: hidden, notes: notes(text)))
    }

    /// ```sh … ``` or `…` around the whole answer: what's inside.
    static func unfenced(_ text: String) -> String {
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 {
            var inner = text.dropFirst(3).dropLast(3)
            if let newline = inner.firstIndex(of: "\n"), !inner[..<newline].contains(" ") { inner = inner[inner.index(after: newline)...] }
            return inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("`"), text.hasSuffix("`"), text.count >= 2, !text.dropFirst().dropLast().contains("`") {
            return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Quiet notes for what deserves a second look before Return.
    static let risks: [(pattern: String, note: String)] = [
        (#"(^|[\s;&|(])sudo\b"#, "It runs as root (sudo)."),
        (#"(^|[\s;&|(])rm\s+(-[a-zA-Z]*[rR]|--recursive)"#, "It deletes folders and what is in them (rm -r)."),
        (#"(^|[\s;&|(])dd\s"#, "It writes raw blocks (dd)."),
        (#"(^|[\s;&|(])mkfs"#, "It formats a disk (mkfs)."),
        (#"(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(ba|z|da)?sh\b"#, "It runs a script straight from the network."),
        (#"(^|\s)--force\b|(^|\s)-f\b.*\bpush\b|\bpush\b.*(^|\s)-f\b"#, "It forces (--force)."),
    ]

    static func notes(_ command: String) -> [String] {
        risks.compactMap { risk in
            command.range(of: risk.pattern, options: .regularExpression) == nil ? nil : risk.note
        }
    }
}
