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
        "claude", "claude-code", "claude.exe", "codex", "gemini", "gemini-cli", "aider", "opencode", "opencode-ai", "opencode2",
        "opencode.exe", "amp", "cursor-agent", "goose", "crush", "qwen", "qwen-code", "copilot", "droid", "kiro", "kiro-cli", "q",
        "kimi", "plandex", "cline", "junie", "commandcode", "command-code", "cmd", "auggie", "agy",
    ]
    /// Other names an agent runs by, and the name Next Term knows it by everywhere (its status, its notices, its session
    /// list): npm's native `claude.exe` and `opencode.exe`, OpenCode's npm package `opencode-ai`, OpenCode 2's `opencode2`.
    static let otherNames: [String: String] = [
        "claude.exe": "claude", "opencode-ai": "opencode", "opencode2": "opencode", "opencode.exe": "opencode",
    ]
    /// Wrappers whose word is a package to fetch and run, `name@version` or `@scope/name@version`: `npx opencode-ai@latest`.
    /// `dlx` stands for a package manager's own (`dlxManagers`).
    static let packageRunners: Set<String> = ["npx", "bunx", "pnpx", "dlx"]
    /// Package managers, with the subcommand that runs a package as `npx` does: `pnpm dlx opencode-ai`, `bun x opencode-ai`.
    static let dlxManagers: [String: String] = ["pnpm": "dlx", "yarn": "dlx", "bun": "x"]
    /// Packages whose program is not their last word: OpenCode 2's `@opencode/cli` runs as `opencode`.
    static let packagePrograms: [String: String] = ["@opencode/cli": "opencode"]
    /// OpenCode's servers: a headless server, a web server, and ACP over stdio for an editor. Each runs as a command, as
    /// none shows the TUI an agent tab reads; `attach` shows it, so it stays an agent.
    static let opencodeServers: Set<String> = ["serve", "web", "acp"]
    /// Pieces of an executable or script path that give an agent away when its name does not:
    /// Claude Code's native installer runs as ".../claude/versions/2.1.280", the npm build as node + cli.js.
    static let agentPathHints = [
        "@anthropic-ai/claude-code", "/claude/versions/", "/claude-code/", "@openai/codex", "/codex/",
        "@google/gemini-cli", "/opencode", "@opencode/cli", "/aider", "@qwen-code/", "/cursor-agent",
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
    /// A wrapper's options whose value is the next word: `env -u NAME claude` runs claude, as a resume does, and
    /// `npx -p opencode-ai opencode` runs opencode, the package's program.
    static let wrapperValueOptions: [String: Set<String>] = ["env": ["-u", "--unset", "-C", "--chdir"], "npx": ["-p", "--package"]]
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
        guard let found = program(in: words) else { return ("", []) }
        return (found.name, Array(words[(found.index + 1)...]))
    }

    /// Where the program is among a simple command's words.
    static func programIndex(_ words: [String]) -> Int? {
        program(in: words)?.index
    }

    /// Where the program is among a simple command's words, past options, assignments and wrappers, the value a wrapper's
    /// option takes (`env -u NAME`, `npx -p opencode-ai`), and a package manager's `dlx` or `x`; and its name. A package
    /// runner's word names its package's program (`packageProgram`), and an agent's other name the one Next Term knows it
    /// by (`knownName`).
    public static func program(in words: [String]) -> (index: Int, name: String)? {
        var wrapper = ""
        var skipNext = false
        for (index, word) in words.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if word.hasPrefix("-") {
                skipNext = wrapperValueOptions[wrapper]?.contains(word) == true
                continue
            }
            if isAssignment(word) { continue }
            let base = baseName(word)
            if base.isEmpty { continue }
            if wrappers.contains(base) {
                wrapper = base
                continue
            }
            if let run = dlxManagers[base], index + 1 < words.count, words[index + 1] == run {
                wrapper = "dlx"
                skipNext = true
                continue
            }
            let name = packageRunners.contains(wrapper) ? packageProgram(word) : base
            return (index, knownName(name))
        }
        return nil
    }

    /// The program a package runner's word runs: the package's, without its version (`opencode-ai@latest` is
    /// opencode-ai, `@anthropic-ai/claude-code@2.1.280` claude-code), by `packagePrograms` or the package's last word.
    /// Only an `@` after the last `/` starts a version: one before it is a URL's (`https://user:token@host/org/tool`),
    /// whose credential must never become the program's name.
    static func packageProgram(_ word: String) -> String {
        let unquoted = Substring(word.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")))
        let lastPart = unquoted[(unquoted.lastIndex(of: "/") ?? unquoted.startIndex)...]
        let version = lastPart.lastIndex(of: "@").flatMap { (at: Substring.Index) -> Substring.Index? in
            at == unquoted.startIndex ? nil : at
        }
        let package: Substring = version.map { unquoted[..<$0] } ?? unquoted
        return packagePrograms[String(package)] ?? baseName(String(package))
    }

    /// The name Next Term knows a program by: an agent's other name (`otherNames`) is its own, any other name stays.
    public static func knownName(_ name: String) -> String {
        otherNames[name] ?? name
    }

    /// OpenCode's words start one of its servers (`opencode serve`, `opencode --port 4096 web`): its first word that is no
    /// option and no option's value, read with OpenCode's table (AgentCLI.opencode), as its own parser gives each option
    /// that takes a value the next word. A command the table knows comes first (`opencode run serve`): no server.
    static func isServer(_ name: String, args: [String]) -> Bool {
        guard knownName(name) == "opencode" else { return false }
        for piece in AgentCLI.opencode.read(args).pieces {
            switch piece {
            case .word(let word):
                return opencodeServers.contains(word)
            case .known(let option, _, _):
                if !AgentCLI.isOption(option) { return false }
            case .unknown:
                continue
            }
        }
        return false
    }

    /// The program a command line is about: the agent if there is one, else the first command that is
    /// not set-up (`cd`, `export`, `nvm use`), else the first. An agent run as a script names the agent
    /// (`node …/@anthropic-ai/claude-code/cli.js` is claude), judged by `scriptAgentName`.
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
        if let agent = parsed.first(where: { kind(name: $0.name, args: $0.args) == .agent }) {
            // An agent run as a script names the agent (`scriptAgentName`), and its arguments are the script's.
            guard !agents.contains(agent.name), let index = agent.args.firstIndex(where: { !$0.hasPrefix("-") }),
                  let named = scriptAgentName(agent.args[index]) else { return agent }
            return (named, Array(agent.args[(index + 1)...]))
        }
        return parsed.first { !setup.contains($0.name) } ?? parsed.first
    }

    /// The agent a command line runs, judged strictly, as a restore needs: a program known as an agent, or an
    /// interpreter running an agent's script (`scriptAgentName`). A dev server in a folder named like an agent is none.
    public static func agentName(_ commandLine: String) -> String? {
        for (name, args) in segments(commandLine).map(parse) where !name.isEmpty {
            if agents.contains(name) {
                // OpenCode's servers run no agent a tab reads or resumes.
                if isServer(name, args: args) { continue }
                return knownName(name)
            }
            guard interpreters.contains(stem(name)), let at = args.firstIndex(where: { !$0.hasPrefix("-") }),
                  let agent = scriptAgentName(args[at]) else { continue }
            if !isServer(agent, args: Array(args[(at + 1)...])) { return agent }
        }
        return nil
    }

    /// The agent a process runs, judged as strictly: its executable's or argv[0]'s name is an agent's, its executable
    /// lies in an agent's own install (`strictAgentHint`), or it is an interpreter running an agent's script. An OpenCode
    /// server is OpenCode too, as its tools call Next Term as OpenCode; `runsServer` tells it from the TUI.
    public static func agentName(executable: String, arguments: [String]) -> String? {
        let names = [baseName(executable), arguments.first.map(baseName) ?? ""]
        if let known = names.first(where: agents.contains) { return knownName(known) }
        if let hinted = strictAgentHint(in: executable) { return hinted }
        guard names.contains(where: { interpreters.contains(stem($0)) }),
              let script = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return nil }
        return scriptAgentName(script)
    }

    /// The agent the script an interpreter runs is: by the script's own name (`bin/claude`, `codex.js`, `-m aider`),
    /// or by `strictAgentHint`.
    static func scriptAgentName(_ script: String) -> String? {
        let name = baseName(script)
        let suffix = [".js", ".mjs", ".cjs", ".ts", ".py"].first { name.hasSuffix($0) }
        let bare = suffix.map { String(name.dropLast($0.count)) } ?? name
        if agents.contains(bare) { return knownName(bare) }
        return strictAgentHint(in: script)
    }

    /// The process runs one of OpenCode's servers (`opencode serve`, `web`, `acp`), a command: by its program's words,
    /// after argv[0] or after the script an interpreter runs.
    public static func runsServer(executable: String, arguments: [String]) -> Bool {
        guard agentName(executable: executable, arguments: arguments) == "opencode" else { return false }
        var script: Int?
        if interpreters.contains(stem(baseName(arguments.first ?? executable))) {
            script = arguments.indices.dropFirst().first(where: { (index: Int) -> Bool in !arguments[index].hasPrefix("-") })
        }
        let words: [String] = script.map { (index: Int) -> [String] in Array(arguments[(index + 1)...]) } ?? Array(arguments.dropFirst())
        return isServer("opencode", args: words)
    }

    /// The agent a path gives away wherever it lies: a package only that agent has (`@openai/codex`), its versions
    /// folder, or a folder hint (`/codex/`, `/opencode`) inside node_modules. A folder hint elsewhere is a project
    /// folder named like the agent (`~/Code/codex/server.js`), and names none.
    static func strictAgentHint(in path: String) -> String? {
        let packaged = path.range(of: "/node_modules/", options: .caseInsensitive).map { String(path[$0.lowerBound...]) } ?? ""
        let hint = agentPathHints.first { hint in
            let anywhere = hint.hasPrefix("@") || hint.hasSuffix("/versions/")
            return containsHint(anywhere ? path : packaged, hint)
        }
        return hint.map(agentName(forHint:))
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
        if agents.contains(name) { return isServer(name, args: args) ? .command : .agent }
        if interpreters.contains(stem(name)),
           let at = args.firstIndex(where: { !$0.hasPrefix("-") }), containsAgentHint(args[at]) {
            let agent = scriptAgentName(args[at]) ?? hintedAgentName(in: args[at]) ?? ""
            return isServer(agent, args: Array(args[(at + 1)...])) ? .command : .agent
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
        if isAgent(process) {
            return runsServer(executable: process.executablePath, arguments: process.arguments) ? .command : .agent
        }
        let (name, args) = parse(process.commandLine)
        return kind(name: name.isEmpty ? baseName(process.name) : name, args: args)
    }

    public static func programName(of process: ForegroundProcess) -> String {
        if isAgent(process) {
            let names = ([process.name] + process.arguments.prefix(1)).map(baseName)
            if let known = names.first(where: { agents.contains($0) }) { return knownName(known) }
            if let hinted = hintedAgentName(in: process.executablePath + " " + process.arguments.prefix(3).joined(separator: " ")) {
                return hinted
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

    /// The agent the first path hint in `text` gives away, by its program name.
    static func hintedAgentName(in text: String) -> String? {
        agentPathHints.first { containsHint(text, $0) }.map(agentName(forHint:))
    }

    /// The program name of the agent a path hint gives away.
    private static func agentName(forHint hint: String) -> String {
        if hint.contains("claude") { return "claude" }
        if hint.contains("codex") { return "codex" }
        if hint.contains("gemini") { return "gemini" }
        if hint.contains("command-code") { return "commandcode" }
        if hint.contains("junie") { return "junie" }
        if hint.contains("opencode") { return "opencode" }
        return baseName(hint.trimmingCharacters(in: CharacterSet(charactersIn: "/@")))
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
