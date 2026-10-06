import Foundation

/// How a foreground program behaves, which decides what "finished" means for its tab.
public enum CommandKind: Equatable, Sendable {
    /// Runs and exits: `make`, `npm install`, `sleep 10`. Working until it exits.
    case command
    /// An AI agent that stays in the foreground and goes quiet when it wants you: `claude`, `codex`.
    case agent
    /// Long-lived and interactive: `vim`, `ssh`, a REPL. Never reported as "done".
    case interactive
}

public enum CommandClassifier {
    static let agents: Set<String> = [
        "claude", "claude-code", "codex", "gemini", "aider", "opencode", "amp", "cursor-agent",
        "goose", "crush", "qwen", "copilot", "droid", "kiro", "q",
    ]
    static let interactive: Set<String> = [
        "vim", "nvim", "vi", "nano", "emacs", "less", "more", "man", "top", "htop", "btop",
        "ssh", "mosh", "tmux", "screen", "zellij", "mysql", "psql", "sqlite3", "redis-cli",
        "ipython", "lazygit", "tig", "watch", "k9s",
    ]
    /// REPLs and shells are interactive only without a script argument: `node` yes, `node build.js` no.
    static let repls: Set<String> = ["python", "python3", "node", "irb", "php", "bash", "zsh", "fish", "sh", "bun", "deno"]
    static let wrappers: Set<String> = ["sudo", "npx", "bunx", "pnpx", "exec", "nohup", "time", "env", "command", "noglob", "nice"]

    /// `FOO=1 sudo npx @anthropic-ai/claude-code --resume` -> ("claude-code", ["--resume"])
    public static func parse(_ commandLine: String) -> (name: String, args: [String]) {
        let words = commandLine.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        for (i, word) in words.enumerated() {
            if word.hasPrefix("-") || isAssignment(word) { continue }
            let unquoted = word.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            let base = unquoted.split(separator: "/").last.map(String.init) ?? unquoted
            if base.isEmpty || wrappers.contains(base) { continue }
            return (base, Array(words[(i + 1)...]))
        }
        return ("", [])
    }

    public static func programName(_ commandLine: String) -> String { parse(commandLine).name }

    public static func kind(of commandLine: String) -> CommandKind {
        let (name, args) = parse(commandLine)
        if name.isEmpty { return .command }
        if agents.contains(name) { return .agent }
        if interactive.contains(name) || args.contains("tinker") { return .interactive }
        let stem = name.replacingOccurrences(of: #"[0-9.]+$"#, with: "", options: .regularExpression) // python3.12 -> python
        if repls.contains(name) || repls.contains(stem) {
            let onlyFlags = args.allSatisfy { $0.hasPrefix("-") && $0 != "-c" && $0 != "-e" }
            if onlyFlags { return .interactive }
        }
        return .command
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
        let key = word[..<eq]
        guard let first = key.first, first == "_" || first.isLetter else { return false }
        return key.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}
