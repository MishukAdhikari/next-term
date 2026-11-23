import Foundation

/// One command the prompt box's "/" menu offers: what is typed after the slash, and a short line on what it does.
public struct ChatCommand: Equatable, Sendable {
    public enum Source: String, Sendable {
        /// The agent's own, built in.
        case builtIn
        /// The user's or the project's: a skill, a custom command or a saved prompt.
        case custom
        /// Reported by an agent session itself (ACP's available commands).
        case session
    }

    public let name: String
    public let description: String
    public let source: Source
    /// It opens a screen of the agent's own (a picker, a settings screen): sent from the chat view, the terminal shows,
    /// since the chat cannot draw that screen.
    public let opensScreen: Bool

    public init(name: String, description: String, source: Source, opensScreen: Bool = false) {
        self.name = name
        self.description = description
        self.source = source
        self.opensScreen = opensScreen
    }
}

/// The commands the prompt box's "/" menu offers, and which of them match what is typed. Pure, apart from `custom`,
/// which reads the user's and the project's command files.
public enum ChatCommands {
    /// The most rows the menu shows; typing more narrows it.
    public static let shownAtMost = 8

    /// The agent's own commands, as it documents them. Only those that work from a typed line: a command whose screen
    /// the chat cannot draw is marked, so sending it from the chat shows the terminal.
    public static func builtIn(for agent: AgentKind) -> [ChatCommand] {
        func c(_ name: String, _ description: String, screen: Bool = false) -> ChatCommand {
            ChatCommand(name: name, description: description, source: .builtIn, opensScreen: screen)
        }
        switch agent {
        case .claude:
            return [
                c("add-dir", "Add a folder Claude Code may work in"),
                c("agents", "Manage subagents", screen: true),
                c("clear", "Start the conversation over"),
                c("compact", "Compact the conversation, with an optional focus"),
                c("config", "Open settings", screen: true),
                c("context", "Show what fills the context"),
                c("doctor", "Check the installation", screen: true),
                c("export", "Export the conversation", screen: true),
                c("help", "Show help and the commands", screen: true),
                c("hooks", "Manage hooks", screen: true),
                c("init", "Write a CLAUDE.md for this project"),
                c("mcp", "Manage MCP servers", screen: true),
                c("memory", "Edit memory files", screen: true),
                c("model", "Choose the model", screen: true),
                c("permissions", "Manage what may run without asking", screen: true),
                c("resume", "Resume an earlier conversation", screen: true),
                c("review", "Review a pull request"),
                c("rewind", "Go back to an earlier point", screen: true),
                c("status", "Show the version, model and account", screen: true),
                c("usage", "Show the plan's usage limits", screen: true),
            ]
        case .codex:
            return [
                c("approvals", "Choose what Codex may do without asking", screen: true),
                c("compact", "Summarise the conversation to free context"),
                c("diff", "Show the git diff, untracked files included"),
                c("init", "Write an AGENTS.md for this project"),
                c("mcp", "List the MCP tools"),
                c("mention", "Mention a file"),
                c("model", "Choose the model and reasoning effort", screen: true),
                c("new", "Start a new conversation"),
                c("review", "Review the current changes", screen: true),
                c("status", "Show the session's settings and token usage"),
            ]
        default:
            return []
        }
    }

    /// The user's and the project's own commands for `agent` working in `folder`: Claude Code's skills and its command
    /// files (`.claude/commands/*.md`, the project's and the user's), and Codex's saved prompts (`~/.codex/prompts`,
    /// typed as `prompts:name`). A name the agent has built in is left to the built-in.
    public static func custom(for agent: AgentKind, folder: String?, home: String) -> [ChatCommand] {
        var found: [ChatCommand] = []
        func add(_ name: String, _ description: String) {
            guard !name.isEmpty, !name.contains(where: \.isWhitespace), !found.contains(where: { $0.name == name }) else { return }
            found.append(ChatCommand(name: name, description: description, source: .custom))
        }
        switch agent {
        case .claude:
            let projects = folder.map { SkillLibrary.projectFolders(from: $0, home: home) } ?? []
            for dir in projects.map({ $0 + "/.claude/commands" }) + [home + "/.claude/commands"] {
                for (name, text) in markdownFiles(in: dir) { add(name, summary(of: text)) }
            }
            let skills = SkillLibrary.entries(from: folder, home: home, nextTerm: [], reader: .init(program: "claude"))
            for entry in skills where entry.native { add(entry.name, entry.copy.description) }
        case .codex:
            for (name, text) in markdownFiles(in: home + "/.codex/prompts") { add("prompts:" + name, summary(of: text)) }
        default:
            break
        }
        let builtIns = Set(builtIn(for: agent).map(\.name))
        return found.filter { !builtIns.contains($0.name) }
    }

    /// An agent session's own commands (ACP's available commands), which take the place of any list kept here.
    public static func session(_ names: [String]) -> [ChatCommand] {
        var seen = Set<String>()
        return names.compactMap { raw in
            let name = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return ChatCommand(name: name, description: "", source: .session)
        }
    }

    /// What is being typed as a command: the text after a leading "/" while it is one word on the first line, else
    /// nil (the menu shows only then). "/" alone gives "".
    public static func typed(_ text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let word = text.dropFirst()
        guard !word.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        return String(word)
    }

    /// The commands that match `typed`: those whose name starts with it, then those that hold it, each set by name,
    /// at most `shownAtMost`. Case is ignored. A name typed in full and alone matches nothing more to offer: the menu
    /// goes, so Return sends it as typed.
    public static func matches(_ commands: [ChatCommand], typed: String) -> [ChatCommand] {
        let word = typed.lowercased()
        let starts = commands.filter { $0.name.lowercased().hasPrefix(word) }.sorted { $0.name < $1.name }
        let holds = word.isEmpty ? [] : commands.filter {
            let name = $0.name.lowercased()
            return !name.hasPrefix(word) && name.contains(word)
        }.sorted { $0.name < $1.name }
        let all = starts + holds
        if all.count == 1, all[0].name.lowercased() == word { return [] }
        return Array(all.prefix(shownAtMost))
    }

    /// The `.md` files in `dir`, by name without the extension, with their text.
    static func markdownFiles(in dir: String) -> [(String, String)] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
        return names.prefix(200).compactMap { file in
            let path = dir + "/" + file
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size < 256 * 1024,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            return (String(file.dropLast(3)), text)
        }
    }

    /// A command file's line for the menu: its front matter's `description`, else its first line of text.
    static func summary(of text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            for line in lines[1..<end] where line.hasPrefix("description:") {
                var value = line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                    value = String(value.dropFirst().dropLast())
                }
                if !value.isEmpty { return value }
            }
            lines = Array(lines[(end + 1)...])
        }
        let first = lines.first { !$0.isEmpty } ?? ""
        return String(first.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).prefix(120))
    }
}
