import Foundation

// Each agent's own words, in one compiled table (KTD20): the programs it runs as, the shape of its session ids, the
// resume form Next Term adds to a line, and the options a restore must read in one. An option is known by how many
// values it takes, which tells its value from a prompt word, and by its class, which says what a restore does with it.
// Nothing else of an agent's CLI is kept here: the user's own launch (an alias, a function) carries the rest, and keeps
// up with the CLI by itself.
//
// One place for every change:
// - a new agent: a RestoreAgent case and its entry here, plus a capture source if it has its own session file;
// - a renamed flag: the new spelling beside the old one (the CLIs keep both for months), and a new `checked`;
// - a new resume form: a new `resume`, with the old form's words moved into the `form` class, so that an old typed line
//   does not carry them.
// Options are classified at restore with the running build's table, so the build after an update reads an old
// snapshot with what it knows now. Before each release, `scripts/agent-cli-check.sh` checks the table against each
// installed agent's help, and the release sets `checked` from what it prints.

/// One agent's words (KTD20).
public struct AgentCLI: Sendable {
    /// A word of the resume form.
    public enum Word: Equatable, Sendable, ExpressibleByStringLiteral {
        case text(String)
        /// The session id.
        case id
        /// `<option>=<id>`, one word: Copilot's `--resume=<id>`.
        case joinedID(String)
        /// The session's folder, when it is a plain absolute path. Otherwise it is left out with the word before it.
        case folder

        public init(stringLiteral value: String) { self = .text(value) }
    }

    /// How many values an option takes.
    public enum Values: Equatable, Sendable {
        case none
        /// The value after `=`, else the next word unless it starts with `-`. A command's is the next word that is no
        /// option's (Codex's `resume <id>`).
        case one
        /// The value after `=`, then every word up to the next option (`--add-dir a b`).
        case many
    }

    /// What a restore does with an option (KTD20).
    public enum Class: String, CaseIterable, Sendable {
        /// Names or picks a session (resume, continue, fork, a session id): dropped, as the resume form names its own.
        case form
        /// Runs the agent once, or hands it a prompt (`-p`, `exec`): dropped, as a resume never sends a prompt again.
        case oneShot
        /// Kept. An automatic resume carries it when its values fit its pattern.
        case plain
        /// What the agent may do without asking: kept, as the user chose it.
        case permission
        /// Loads code, settings or instructions: kept on the line, never run automatically.
        case codeLoading
    }

    /// The values an automatic resume may carry: ASCII letters and digits, with `extra` after the first, at most `most`
    /// bytes. A carried value is still quoted on the line.
    public struct ValuePattern: Equatable, Sendable {
        public var extra: String
        public var most: Int

        /// A model: `opus`, `opus[1m]`, `gpt-5.1-codex`, `anthropic/claude-sonnet-4`.
        public static let model = ValuePattern(extra: "._:/-[]", most: 64)
        /// A mode or a policy: `plan`, `bypassPermissions`, `on-request`, `workspace-write`.
        public static let mode = ValuePattern(extra: "_-", most: 32)
        /// Tool names and rules: `Edit`, `Bash(git *)`, `mcp__github__get_issue`.
        public static let tools = ValuePattern(extra: "_-.:*(),/ ", most: 256)

        public func matches(_ value: String) -> Bool {
            value.utf8.count <= most && AgentCLI.isToken(value.utf8, extra: extra)
        }
    }

    /// An option or a command the table knows.
    public struct Option: Equatable, Sendable {
        public var kind: Class
        public var values: Values
        /// What its values must fit for an automatic resume to carry them. Nil carries none.
        public var pattern: ValuePattern?
        /// A form whose value is the session id (`--resume <id>`, Codex's `resume <id>`).
        public var namesSession: Bool

        /// `values` are what an automatic resume may carry for it: as many as it takes, each within its pattern.
        public func carries(_ values: [String]) -> Bool {
            switch self.values {
            case .none: return values.isEmpty
            case .one: return values.count == 1 && pattern?.matches(values[0]) == true
            case .many: return !values.isEmpty && values.allSatisfy { pattern?.matches($0) == true }
            }
        }
    }

    /// Options and commands that share an `Option`. A name with no leading `-` is a command: it counts only among the
    /// first words that are no option's (Codex's `exec`, Amp's `threads continue`).
    public struct Group: Sendable {
        public var names: [String]
        public var option: Option

        /// Forms whose value is the session id.
        static func session(_ names: String...) -> Group {
            Group(names: names, option: Option(kind: .form, values: .one, pattern: nil, namesSession: true))
        }

        static func form(_ names: String..., values: Values = .none) -> Group {
            Group(names: names, option: Option(kind: .form, values: values, pattern: nil, namesSession: false))
        }

        static func oneShot(_ names: String..., values: Values = .none) -> Group {
            Group(names: names, option: Option(kind: .oneShot, values: values, pattern: nil, namesSession: false))
        }

        /// Plain options: with `value`, each takes one value of that pattern; without, none.
        static func plain(_ names: String..., value: ValuePattern? = nil) -> Group {
            let option = Option(kind: .plain, values: value == nil ? .none : .one, pattern: value, namesSession: false)
            return Group(names: names, option: option)
        }

        /// Permission options: with `value`, each takes one value of that pattern, or with `many`, several; without,
        /// none.
        static func permission(_ names: String..., value: ValuePattern? = nil, many: Bool = false) -> Group {
            let values: Values = value == nil ? .none : many ? .many : .one
            return Group(names: names, option: Option(kind: .permission, values: values, pattern: value, namesSession: false))
        }

        static func codeLoading(_ names: String..., values: Values = .one) -> Group {
            Group(names: names, option: Option(kind: .codeLoading, values: values, pattern: nil, namesSession: false))
        }
    }

    /// The shape of an agent's session ids, each at most 128 long.
    public enum IDPattern: Equatable, Sendable {
        case uuid
        /// `prefix`, then ASCII letters and digits, with `extra` after the first.
        case token(prefix: String, extra: String)

        public func matches(_ id: String) -> Bool {
            guard (1...128).contains(id.utf8.count) else { return false }
            switch self {
            case .uuid:
                return id.utf8.count == 36 && UUID(uuidString: id) != nil
            case .token(let prefix, let extra):
                guard id.hasPrefix(prefix) else { return false }
                return AgentCLI.isToken(id.utf8.dropFirst(prefix.utf8.count), extra: extra)
            }
        }
    }

    /// When the entry was last checked against the agent.
    public struct Checked: Equatable, Sendable {
        /// The version whose help it was checked against; nil when only the agent's documentation was read.
        public var version: String?
        /// `yyyy-MM-dd`.
        public var date: String
    }

    /// The names it runs by. Each names the agent alone, and its line starts with the first.
    public let programs: [String]
    /// Names other programs share (Cursor's `agent`, Command Code's `cmd`): each names the agent only for a file in its
    /// own install (`pathHints`).
    public let installedNames: [String]
    /// Pieces of a path only the agent's own install has: a package or a versions folder, never a folder hint a
    /// project could share.
    public let pathHints: [String]
    /// Nil for an agent with no resume form.
    public let idPattern: IDPattern?
    /// The words a line puts after the program and before the options it keeps: the subcommand those options belong to
    /// (Kiro's `chat`, Goose's `session`).
    public let subcommand: [String]
    /// The resume form, after the options a line keeps. Codex's goes after the global options and names the folder.
    /// Nil for an agent that cannot be resumed from the command line: it gets a note (R7).
    public let resume: [Word]?
    /// Its options and commands, by class.
    public let groups: [Group]
    /// The same, by name.
    public let options: [String: Option]
    /// Options its `--help` leaves out, which the release check does not look for.
    public let hidden: Set<String>
    public let checked: Checked

    init(programs: [String], installedNames: [String] = [], pathHints: [String] = [], idPattern: IDPattern?, subcommand: [String] = [],
         resume: [Word]?, options groups: [Group], hidden: Set<String> = [], checked: Checked) {
        self.programs = programs
        self.installedNames = installedNames
        self.pathHints = pathHints
        self.idPattern = idPattern
        self.subcommand = subcommand
        self.resume = resume
        self.groups = groups
        let named = groups.flatMap { group in group.names.map { ($0, group.option) } }
        self.options = Dictionary(named, uniquingKeysWith: { first, _ in first })
        self.hidden = hidden
        self.checked = checked
    }

    /// The names of its options and commands in `kind`, in the table's order.
    public func names(_ kind: Class) -> [String] {
        groups.filter { $0.option.kind == kind }.flatMap(\.names)
    }

    // MARK: programs

    /// `program` names this agent: by name alone, or, for a name other programs share, when one of `paths` lies in its
    /// own install.
    public func runs(program: String, at paths: [String]) -> Bool {
        programs.contains(program) || (installedNames.contains(program) && isInstall(paths))
    }

    /// One of `paths` lies in the agent's own install.
    public func isInstall(_ paths: [String]) -> Bool {
        paths.contains { path in pathHints.contains { path.range(of: $0, options: .caseInsensitive) != nil } }
    }

    // MARK: the resume form

    /// Shaped like this agent's session ids, and safe as one word of a line.
    public func isSessionID(_ id: String) -> Bool {
        guard resume != nil, let idPattern else { return false }
        return idPattern.matches(id)
    }

    /// The resume form's words with `id`; nil for an agent that has none. The folder goes in only as a plain absolute
    /// path: otherwise it is left out, with the word before it.
    public func resumeWords(id: String, folder: String?) -> [String]? {
        guard let resume else { return nil }
        let plain = SnapshotText.plainPath(folder, max: SessionSnapshot.Limits.standard.path)
        var words: [String] = []
        for word in resume {
            switch word {
            case .text(let text): words.append(text)
            case .id: words.append(id)
            case .joinedID(let option): words.append(option + "=" + id)
            case .folder:
                if let plain {
                    words.append(plain)
                } else if !words.isEmpty {
                    words.removeLast()
                }
            }
        }
        return words
    }

    // MARK: reading arguments

    /// One piece of an agent's arguments, as the table reads them.
    public enum Piece: Equatable, Sendable {
        /// An option or a command the table knows, with the values it took: `--model=opus` and `--model opus` both
        /// give `["opus"]`.
        case known(String, values: [String], Option)
        /// An option the table does not know, with the value `=` joins to it. A word after it stays a word: only the
        /// agent knows whether that is its value.
        case unknown(String, value: String?)
        /// A word that is no option, no option's value and no command: a prompt word, or any word after `--`.
        case word(String)
    }

    /// An agent's arguments read with the table, in order.
    public struct Reading: Equatable, Sendable {
        public var pieces: [Piece] = []
        /// The session a form names, as given: not yet checked against the id pattern.
        public var session: String?

        /// The command at `index` takes `value`.
        mutating func fill(_ index: Int, with value: String) {
            guard case .known(let name, _, let option) = pieces[index] else { return }
            pieces[index] = .known(name, values: [value], option)
            if option.namesSession, session == nil { session = value }
        }
    }

    /// The agent's own arguments (after its program) read with the table: each option with the values it takes, each
    /// command among the first words, and every other word.
    public func read(_ arguments: [String]) -> Reading {
        var reading = Reading()
        var index = 0
        var inCommands = true
        var awaiting: Int?
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            if word == "--" {
                reading.pieces += arguments[index...].map { Piece.word($0) }
                break
            }
            guard Self.isOption(word) else {
                if let command = awaiting {
                    reading.fill(command, with: word)
                    awaiting = nil
                    inCommands = false
                } else if inCommands, let option = options[word] {
                    reading.pieces.append(.known(word, values: [], option))
                    if option.values != .none { awaiting = reading.pieces.count - 1 }
                } else {
                    inCommands = false
                    reading.pieces.append(.word(word))
                }
                continue
            }
            let parts = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            let joined = parts.count > 1 ? String(parts[1]) : nil
            guard let option = options[name] else {
                reading.pieces.append(.unknown(name, value: joined))
                continue
            }
            var values = joined.map { [$0] } ?? []
            while option.values == .many || (option.values == .one && values.isEmpty),
                  index < arguments.count, !Self.isOption(arguments[index]) {
                values.append(arguments[index])
                index += 1
            }
            reading.pieces.append(.known(name, values: values, option))
            if option.namesSession, reading.session == nil { reading.session = values.first }
        }
        return reading
    }

    /// An option's word: it starts with `-`, and is more than `-` (stdin).
    static func isOption(_ word: String) -> Bool { word.hasPrefix("-") && word != "-" }

    /// Letters and digits first, then those or `extra`.
    static func isToken<Bytes: Collection>(_ bytes: Bytes, extra: String) -> Bool where Bytes.Element == UInt8 {
        guard let first = bytes.first, isAlphanumeric(first) else { return false }
        let allowed = Set(extra.utf8)
        return bytes.allSatisfy { isAlphanumeric($0) || allowed.contains($0) }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }
}

// MARK: - The table

extension SessionSnapshot.Agent {
    /// The agent's words (KTD20). The switch is exhaustive, so an agent with no entry does not compile.
    public var cli: AgentCLI {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .qwen: return .qwen
        case .copilot: return .copilot
        case .gemini: return .gemini
        case .cursor: return .cursor
        case .opencode: return .opencode
        case .amp: return .amp
        case .junie: return .junie
        case .commandCode: return .commandCode
        case .kiro: return .kiro
        case .goose: return .goose
        case .agy: return .agy
        case .aider: return .aider
        case .unknown: return .unknown
        }
    }
}

extension AgentCLI {
    /// A token id: letters and digits first, then those or `._:-_`.
    private static let plainID = IDPattern.token(prefix: "", extra: "._:_-")

    static let claude = AgentCLI(
        programs: ["claude", "claude-code", "claude.exe"],
        pathHints: ["@anthropic-ai/claude-code", "/claude/versions/"],
        idPattern: .uuid,
        resume: ["--resume", .id],
        options: [
            .session("--resume", "-r", "--session-id"),
            .form("--continue", "-c", "--fork-session"),
            .form("--from-pr", "--teleport", values: .one),
            .oneShot("-p", "--print"),
            .plain("--model", "--fallback-model", value: .model),
            .plain("--verbose"),
            .permission("--dangerously-skip-permissions", "--allow-dangerously-skip-permissions"),
            .permission("--permission-mode", value: .mode),
            .permission("--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools", value: .tools, many: true),
            .codeLoading("--settings", "--plugin-dir", "--system-prompt", "--system-prompt-file", "--append-system-prompt",
                         "--append-system-prompt-file", "--agents", "--setting-sources"),
            .codeLoading("--mcp-config", "--add-dir", values: .many),
            .codeLoading("--strict-mcp-config", values: .none),
        ],
        hidden: ["--system-prompt-file", "--append-system-prompt-file"],
        checked: Checked(version: "2.1.280", date: "2026-10-11"))

    static let codex = AgentCLI(
        programs: ["codex"],
        pathHints: ["@openai/codex"],
        idPattern: .uuid,
        resume: ["resume", .id, "-C", .folder],
        options: [
            .session("resume", "fork"),
            .form("--last", "--all"),
            .form("-C", "--cd", values: .one),
            .oneShot("exec", "e", "review"),
            .plain("-m", "--model", value: .model),
            .permission("--dangerously-bypass-approvals-and-sandbox", "--yolo", "--full-auto"),
            .permission("-a", "--ask-for-approval", "-s", "--sandbox", "-P", "--permission-profile", value: .mode),
            .codeLoading("-c", "--config", "-p", "--profile", "--add-dir", "--enable", "--disable"),
        ],
        hidden: ["--yolo", "--full-auto", "-P", "--permission-profile"],
        checked: Checked(version: "0.154.0", date: "2026-10-11"))

    static let qwen = AgentCLI(
        programs: ["qwen", "qwen-code"],
        pathHints: ["@qwen-code/"],
        idPattern: .uuid,
        resume: ["--resume", .id],
        options: [
            .session("--resume", "-r", "--session-id"),
            .form("--continue", "-c", "--fork-session"),
            .oneShot("-p", "--prompt", "-i", "--prompt-interactive", values: .one),
            .plain("-m", "--model", value: .model),
            .permission("-y", "--yolo"),
            .permission("--approval-mode", value: .mode),
            .permission("--allowed-tools", value: .tools, many: true),
            .codeLoading("-e", "--extensions", "--include-directories", "--allowed-mcp-server-names", values: .many),
            .codeLoading("--sandbox-image", "--openai-base-url", "--openai-api-key", "--proxy"),
            .codeLoading("-s", "--sandbox", values: .none),
        ],
        checked: Checked(version: nil, date: "2026-10-10"))

    static let copilot = AgentCLI(
        programs: ["copilot"],
        idPattern: .uuid,
        resume: [.joinedID("--resume")],
        options: [
            .session("--resume", "-r", "--session-id"),
            .form("--continue"),
            .oneShot("-p", "--prompt", values: .one),
            .plain("--model", value: .model),
            .permission("--allow-all", "--yolo", "--allow-all-tools", "--allow-all-paths", "--allow-all-urls", "--autopilot"),
            .permission("--allow-tool", "--deny-tool", value: .tools, many: true),
            .codeLoading("--add-dir", "--additional-mcp-config"),
        ],
        checked: Checked(version: nil, date: "2026-10-10"))

    static let gemini = AgentCLI(
        programs: ["gemini", "gemini-cli"],
        pathHints: ["@google/gemini-cli"],
        idPattern: .uuid,
        resume: ["--resume", .id],
        options: [
            .session("--resume", "-r", "--session-id"),
            .oneShot("-p", "--prompt", "-i", "--prompt-interactive", values: .one),
            .plain("-m", "--model", value: .model),
            .permission("-y", "--yolo"),
            .permission("--approval-mode", value: .mode),
            .permission("--allowed-tools", value: .tools, many: true),
            .codeLoading("-e", "--extensions", "--include-directories", "--allowed-mcp-server-names", values: .many),
            .codeLoading("-s", "--sandbox", values: .none),
        ],
        checked: Checked(version: nil, date: "2026-10-10"))

    /// Its install runs its own node on `index.js` in a versions folder, and links `cursor-agent` and `agent` to it.
    static let cursor = AgentCLI(
        programs: ["cursor-agent"],
        installedNames: ["agent"],
        pathHints: ["/cursor-agent/versions/"],
        idPattern: plainID,
        resume: ["--resume", .id],
        options: [
            .session("--resume"),
            .form("resume", "ls"),
            .oneShot("-p", "--print"),
            .plain("-m", "--model", value: .model),
            .permission("-f", "--force", "--yolo"),
        ],
        hidden: ["--yolo"],
        checked: Checked(version: nil, date: "2026-10-10"))

    static let opencode = AgentCLI(
        programs: ["opencode"],
        pathHints: ["/node_modules/opencode-ai/"],
        idPattern: .token(prefix: "ses_", extra: ""),
        resume: ["-s", .id],
        options: [
            .session("-s", "--session"),
            .form("-c", "--continue", "--fork"),
            .oneShot("run"),
            .oneShot("--prompt", values: .one),
            .plain("-m", "--model", value: .model),
            .plain("--agent", value: .mode),
            .permission("--auto", "--yolo", "--dangerously-skip-permissions"),
        ],
        hidden: ["--yolo", "--dangerously-skip-permissions"],
        checked: Checked(version: nil, date: "2026-10-10"))

    /// It no longer asks before acting, so it has no permission options.
    static let amp = AgentCLI(
        programs: ["amp"],
        idPattern: .token(prefix: "T-", extra: "-"),
        resume: ["threads", "continue", .id],
        options: [
            .form("threads"),
            .session("continue"),
            .oneShot("-x", "--execute", values: .one),
        ],
        checked: Checked(version: nil, date: "2026-10-10"))

    static let junie = AgentCLI(
        programs: ["junie"],
        pathHints: ["/junie/versions/"],
        idPattern: plainID,
        resume: ["--session-id", .id, "--resume"],
        options: [
            .session("--session-id"),
            .form("--resume"),
            .permission("--brave"),
        ],
        checked: Checked(version: nil, date: "2026-10-10"))

    static let commandCode = AgentCLI(
        programs: ["command-code", "commandcode"],
        installedNames: ["cmd"],
        pathHints: ["/node_modules/command-code/"],
        idPattern: plainID,
        resume: ["--resume", .id],
        options: [
            .session("--resume", "-r", "--session"),
            .form("--continue", "-c", "--fork-session"),
            .oneShot("-p", "--print", values: .one),
            .plain("-m", "--model", value: .model),
            .plain("--effort", value: .mode),
            .permission("--yolo", "--dangerously-skip-permissions", "--accept-edits", "--plan", "-t", "--trust"),
            .permission("--permission-mode", value: .mode),
            .codeLoading("--add-dir", "--mod", "--skill", "--config"),
        ],
        hidden: ["--dangerously-skip-permissions"],
        checked: Checked(version: "1.74.3", date: "2026-10-11"))

    static let kiro = AgentCLI(
        programs: ["kiro-cli", "kiro"],
        idPattern: plainID,
        subcommand: ["chat"],
        resume: ["--resume-id", .id],
        options: [
            .form("chat"),
            .session("--resume-id"),
            .form("--resume", "-r"),
            .oneShot("--no-interactive"),
            .plain("--model", value: .model),
            .permission("--trust-all-tools"),
            .permission("--trust-tools", value: .tools),
        ],
        checked: Checked(version: nil, date: "2026-10-10"))

    /// It reads its mode from `GOOSE_MODE`, so it has no permission options.
    static let goose = AgentCLI(
        programs: ["goose"],
        idPattern: plainID,
        subcommand: ["session"],
        resume: ["--resume", "--session-id", .id],
        options: [
            .form("session"),
            .oneShot("run"),
            .session("--session-id"),
            .form("--resume", "-r"),
            .form("--name", "-n", values: .one),
            .plain("--debug"),
            .codeLoading("--with-extension", "--with-builtin", "--with-remote-extension"),
        ],
        checked: Checked(version: nil, date: "2026-10-10"))

    /// No resume from the command line: its note says to use `/resume` (R7).
    static let agy = AgentCLI(programs: ["agy"], idPattern: nil, resume: nil, options: [],
                              checked: Checked(version: nil, date: "2026-10-10"))

    /// No resume from the command line: its note names `--restore-chat-history`, and `--yes-always` (R7).
    static let aider = AgentCLI(
        programs: ["aider"],
        idPattern: nil,
        resume: nil,
        options: [
            .plain("--model", value: .model),
            .permission("--yes-always"),
        ],
        checked: Checked(version: nil, date: "2026-10-10"))

    /// An agent the table does not know: no words of its own.
    static let unknown = AgentCLI(programs: [], idPattern: nil, resume: nil, options: [], checked: Checked(version: nil, date: ""))
}
