import Foundation

/// How a foreground program behaves, which decides what "finished" means for its tab.
public enum CommandKind: Int, Comparable, Sendable {
    /// Runs and exits: `make`, `npm install`, `sleep 10`. Working until it exits.
    case command
    /// Long-lived and interactive: `vim`, `ssh`, a REPL. Never reported as "done".
    case interactive
    /// An AI agent that stays in the foreground and goes quiet when it wants you: `claude`, `codex`.
    case agent

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// What the kernel says is running in the foreground of a tab.
public struct ForegroundProcess: Equatable, Sendable {
    /// The shell itself is in front: no job is running.
    public var isShell: Bool
    /// Kernel process name (`proc_name`), e.g. "claude", "node", "2.1.280".
    public var name: String
    /// argv, if readable.
    public var arguments: [String]
    /// Full path of the executable, if readable.
    public var executablePath: String

    public init(isShell: Bool, name: String, arguments: [String] = [], executablePath: String = "") {
        self.isShell = isShell
        self.name = name
        self.arguments = arguments
        self.executablePath = executablePath
    }

    /// A command line for display and classification.
    public var commandLine: String {
        arguments.isEmpty ? name : arguments.prefix(12).joined(separator: " ")
    }
}

public enum CommandClassifier {
    static let agents: Set<String> = [
        "claude", "claude-code", "claude.exe", "codex", "gemini", "gemini-cli", "aider", "opencode", "amp",
        "cursor-agent", "goose", "crush", "qwen", "qwen-code", "copilot", "droid", "kiro", "kiro-cli", "q",
        "kimi", "plandex", "cline", "junie", "commandcode", "command-code", "cmd", "auggie",
    ]
    /// Pieces of an executable or script path that give an agent away when its name does not:
    /// Claude Code's native installer runs as ".../claude/versions/2.1.280", the npm build as node + cli.js.
    static let agentPathHints = [
        "@anthropic-ai/claude-code", "/claude/versions/", "/claude-code/", "@openai/codex", "/codex/",
        "@google/gemini-cli", "/opencode", "/aider", "@qwen-code/", "/cursor-agent",
        "/command-code/", "/junie/versions/", "@augmentcode/",
    ]
    static let interactive: Set<String> = [
        "vim", "nvim", "vi", "nano", "emacs", "less", "more", "man", "top", "htop", "btop",
        "ssh", "mosh", "tmux", "screen", "zellij", "mysql", "psql", "sqlite3", "redis-cli",
        "ipython", "lazygit", "tig", "watch", "k9s",
    ]
    /// REPLs and shells are interactive only without a script argument: `node` yes, `node build.js` no.
    static let repls: Set<String> = ["python", "python3", "node", "irb", "php", "bash", "zsh", "fish", "sh", "bun", "deno"]
    /// Runtimes that run an agent from a script path (`node …/@anthropic-ai/claude-code/cli.js`).
    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby"]
    static let wrappers: Set<String> = [
        "sudo", "doas", "npx", "bunx", "pnpx", "uvx", "pipx", "exec", "nohup", "time", "env", "command", "builtin",
        "noglob", "nocorrect", "nice", "caffeinate", "arch", "timeout", "gtimeout",
    ]
    /// Commands that set things up for the real one: `cd x && make` is about `make`.
    static let setup: Set<String> = ["cd", "pushd", "popd", "export", "source", ".", "set", "unset", "alias", "nvm", "eval", "clear"]

    // MARK: command lines (what the shell reports)

    /// Splits a command line into simple commands at `&&`, `||`, `;`, `|`, `&` and newlines,
    /// outside quotes. `cd x && "a b" | less` -> ["cd x", "\"a b\"", "less"].
    public static func segments(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for ch in line {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && quote != "'" { current.append(ch); escaped = true; continue }
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "'", "\"":
                quote = ch
                current.append(ch)
            case "&", "|", ";", "\n":
                parts.append(current)
                current = ""
            default:
                current.append(ch)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `FOO=1 sudo npx @anthropic-ai/claude-code --resume` -> ("claude-code", ["--resume"])
    public static func parse(_ simpleCommand: String) -> (name: String, args: [String]) {
        let words = simpleCommand.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        for (i, word) in words.enumerated() {
            if word.hasPrefix("-") || isAssignment(word) { continue }
            let base = baseName(word)
            if base.isEmpty || wrappers.contains(base) { continue }
            return (base, Array(words[(i + 1)...]))
        }
        return ("", [])
    }

    /// The program a command line is about: the agent if there is one, else the first command that is
    /// not set-up (`cd`, `export`, `nvm use`), else the first.
    public static func programName(_ commandLine: String) -> String {
        programCommand(commandLine)?.name ?? ""
    }

    /// That program with its arguments, as the close alerts name what runs: `PATH=~/bin:$PATH claude --resume`
    /// -> "claude --resume", `cd web && npm run dev` -> "npm run dev".
    public static func programLine(_ commandLine: String) -> String {
        programCommand(commandLine).map { ([$0.name] + $0.args).joined(separator: " ") } ?? ""
    }

    private static func programCommand(_ commandLine: String) -> (name: String, args: [String])? {
        let parsed = segments(commandLine).map(parse).filter { !$0.name.isEmpty }
        if let agent = parsed.first(where: { kind(name: $0.name, args: $0.args) == .agent }) { return agent }
        return parsed.first { !setup.contains($0.name) } ?? parsed.first
    }

    /// The strongest kind among the line's simple commands: `cd ~/app && claude` is an agent.
    public static func kind(of commandLine: String) -> CommandKind {
        segments(commandLine).map { segment -> CommandKind in
            let (name, args) = parse(segment)
            return kind(name: name, args: args)
        }.max() ?? .command
    }

    static func kind(name: String, args: [String]) -> CommandKind {
        if name.isEmpty { return .command }
        if agents.contains(name) { return .agent }
        if interpreters.contains(stem(name)),
           let script = args.first(where: { !$0.hasPrefix("-") }), containsAgentHint(script) {
            return .agent
        }
        if interactive.contains(name) || args.contains("tinker") { return .interactive }
        if repls.contains(name) || repls.contains(stem(name)) {
            let onlyFlags = args.allSatisfy { $0.hasPrefix("-") && $0 != "-c" && $0 != "-e" }
            if onlyFlags { return .interactive }
        }
        return .command
    }

    // MARK: processes (what the kernel reports)

    /// Classifies the process in the foreground. This sees through shell functions and aliases,
    /// which the command line cannot: `claude-auto-danger` (a function) runs a process named claude.
    public static func kind(of process: ForegroundProcess) -> CommandKind {
        if isAgent(process) { return .agent }
        let (name, args) = parse(process.commandLine)
        return kind(name: name.isEmpty ? baseName(process.name) : name, args: args)
    }

    public static func programName(of process: ForegroundProcess) -> String {
        if isAgent(process) {
            let names = ([process.name] + process.arguments.prefix(1)).map(baseName)
            if let known = names.first(where: { agents.contains($0) }) { return known == "claude.exe" ? "claude" : known }
            for hint in agentPathHints where containsHint(process.executablePath + " " + process.arguments.prefix(3).joined(separator: " "), hint) {
                return hint.contains("claude") ? "claude" : hint.contains("codex") ? "codex"
                    : hint.contains("gemini") ? "gemini" : hint.contains("command-code") ? "commandcode"
                    : hint.contains("junie") ? "junie"
                    : baseName(hint.trimmingCharacters(in: CharacterSet(charactersIn: "/@")))
            }
        }
        let name = parse(process.commandLine).name
        return name.isEmpty ? baseName(process.name) : name
    }

    static func isAgent(_ process: ForegroundProcess) -> Bool {
        let argv0 = process.arguments.first.map(baseName) ?? ""
        if agents.contains(baseName(process.name)) || agents.contains(argv0) || agents.contains(baseName(process.executablePath)) {
            return true
        }
        if containsAgentHint(process.executablePath) { return true }
        if interpreters.contains(stem(argv0.isEmpty ? baseName(process.name) : argv0)),
           let script = process.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }), containsAgentHint(script) {
            return true
        }
        return false
    }

    // MARK: helpers

    static func containsAgentHint(_ path: String) -> Bool {
        agentPathHints.contains { containsHint(path, $0) }
    }

    private static func containsHint(_ text: String, _ hint: String) -> Bool {
        text.range(of: hint, options: .caseInsensitive) != nil
    }

    static func baseName(_ word: String) -> String {
        let unquoted = word.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        let last = unquoted.split(separator: "/").last.map(String.init) ?? unquoted
        return last.hasPrefix("-") ? String(last.dropFirst()) : last // "-zsh", a login shell's argv[0]
    }

    /// "python3.12" -> "python"
    static func stem(_ name: String) -> String {
        name.replacingOccurrences(of: #"[0-9.]+$"#, with: "", options: .regularExpression)
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
        let key = word[..<eq]
        guard let first = key.first, first == "_" || first.isLetter else { return false }
        return key.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}
