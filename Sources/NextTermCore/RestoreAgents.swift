import Foundation

// The agents a restore knows, and what it may do for each (the plan's agent evidence matrix): the program, the id
// pattern, the resume form and the options, all read from each agent's AgentCLI entry (KTD20); the put-back line every
// agent with a resume form gets (KTD7); and, for Claude Code, Codex and Qwen Code alone, the options a resume may carry
// and the gate an automatic resume must pass (KTD5).
//
// A put-back line is the user's own launch with the resume form and the id: the launcher replayed with the options typed
// after it, or the program and argv's options, never a prompt word, a form or a one-shot option. An automatic resume runs
// the recorded absolute path through `/usr/bin/env -u <auto-continue variables>`, with the resume form, the plain options
// and the permission options the typed line confirmed. Both are one plain line, quoted with ShellQuote.

/// The agents a restore knows: SessionSnapshot.Agent, which maps to AgentKind where the session list knows the
/// agent too, so AgentKind's exhaustive switches stay as they are.
public typealias RestoreAgent = SessionSnapshot.Agent

/// An agent's launch options as a restore reads them, with the running build's table (KTD5, KTD7, KTD20).
public struct LaunchReading: Equatable, Sendable {
    /// The words a put-back line keeps, in order: every option but a form, a one-shot option, or one whose value the
    /// table can't tell from a prompt word.
    public var line: [String]
    /// The plain options an automatic resume carries, as words, in order.
    public var plain: [String]
    /// The permission options it carries, each as its words, in order: argv and the typed line both show them.
    public var permissions: [[String]]
    /// The options left off the line, by name: the table can't tell their value from a prompt word.
    public var leftOff: [String]
    /// An automatic resume may carry every option: each plain one within its pattern, each permission one within its
    /// pattern and shown by the typed line too. A code-loading option, one the table does not know, or options not known
    /// at all send the agent to the line.
    public var allowed: Bool

    public init(line: [String] = [], plain: [String] = [], permissions: [[String]] = [], leftOff: [String] = [], allowed: Bool = true) {
        self.line = line
        self.plain = plain
        self.permissions = permissions
        self.leftOff = leftOff
        self.allowed = allowed
    }

    /// What an automatic resume carries after the resume form: the plain options, then the permission options.
    public var carried: [String] { plain + permissions.flatMap { $0 } }

    mutating func leaveOff(_ name: String) {
        allowed = false
        if !leftOff.contains(name) { leftOff.append(name) }
    }
}

/// An agent's put-back line (KTD7), with what its note says of it.
public struct PutBack: Equatable, Sendable {
    public var line: String
    /// It holds the resume form with the session's id.
    public var namesSession: Bool
    /// The options it leaves off, by name: the table can't tell their value from a prompt word.
    public var leftOff: [String]

    public init(line: String, namesSession: Bool, leftOff: [String]) {
        self.line = line
        self.namesSession = namesSession
        self.leftOff = leftOff
    }
}

// MARK: - The matrix

extension SessionSnapshot.Agent {
    /// The agent a tab's program is, from the name CommandClassifier worked out: by the table's names alone, or, for a
    /// name other programs share (Cursor's `agent`, Command Code's `cmd`), only when one of `paths` lies in its own
    /// install.
    public init?(program: String, at paths: [String] = []) {
        guard let agent = Self.allCases.first(where: { $0.cli.runs(program: program, at: paths) }) else { return nil }
        self = agent
    }

    public init(kind: AgentKind) {
        switch kind {
        case .claude: self = .claude
        case .codex: self = .codex
        case .commandCode: self = .commandCode
        case .gemini: self = .gemini
        case .qwen: self = .qwen
        case .opencode: self = .opencode
        case .cursor: self = .cursor
        case .copilot: self = .copilot
        }
    }

    /// The agent a process runs, as the kernel shows it, judged strictly (CommandClassifier.agentName): by its
    /// executable's or argv[0]'s name, an agent's own install, or the script an interpreter runs (an npm install's
    /// `bin/claude` link, run by node). A name other programs share counts only when what runs lies in that agent's own
    /// install, every link resolved; so does an install the classifier does not know, such as Cursor's own node running
    /// its `index.js`. One the matrix does not know is `.unknown`, still an agent; a process that runs none, such as a
    /// dev server in a folder named like an agent, is nil.
    public init?(process: AgentProcess) {
        // OpenCode's servers (`opencode serve`, `web`, `acp`) run no session a tab could resume: their tab is a command's.
        if CommandClassifier.runsServer(executable: process.executable, arguments: process.arguments) { return nil }
        guard let name = CommandClassifier.agentName(executable: process.executable, arguments: process.arguments) else {
            guard let agent = Self.installed(at: Self.installPaths(of: process, resolved: false)) else { return nil }
            self = agent
            return
        }
        self = Self(program: name) ?? Self(program: name, at: Self.installPaths(of: process, resolved: true)) ?? .unknown
    }

    /// The agent whose own install one of `paths` lies in.
    static func installed(at paths: [String]) -> Self? {
        allCases.first { $0.cli.isInstall(paths) }
    }

    /// Where a process's code lies: its executable, and the script an interpreter runs, with that script's real path when
    /// `resolved` (npm's `bin/cmd` link leads into Command Code's package).
    static func installPaths(of process: AgentProcess, resolved: Bool) -> [String] {
        guard let index = scriptIndex(argv: process.arguments, executable: process.executable) else { return [process.executable] }
        let word = process.arguments[index]
        let folder = process.directory.map { $0 + "/" + word }
        guard let script = word.hasPrefix("/") ? word : folder else { return [process.executable] }
        return [process.executable, script] + (resolved ? [canonicalPath(script)] : [])
    }

    /// The agent a typed line runs, judged as strictly: `.unknown` for one the matrix does not know, nil for none.
    public init?(line: String) {
        guard let name = CommandClassifier.agentName(line) else { return nil }
        self = Self(program: name) ?? .unknown
    }

    /// It runs itself again in a child whose own record is the session's: Codex's npm build starts its native binary,
    /// Qwen Code restarts node with more memory. Another agent's copy below it is one its tools ran: another session.
    public var relaunchesItself: Bool { self == .codex || self == .qwen }

    /// The session list's agent, when it knows this one.
    public var kind: AgentKind? {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .commandCode: return .commandCode
        case .gemini: return .gemini
        case .qwen: return .qwen
        case .opencode: return .opencode
        case .cursor: return .cursor
        case .copilot: return .copilot
        case .amp, .junie, .kiro, .goose, .agy, .aider, .unknown: return nil
        }
    }

    public var name: String {
        if let kind { return kind.name }
        switch self {
        case .amp: return "Amp"
        case .junie: return "Junie"
        case .kiro: return "Kiro CLI"
        case .goose: return "Goose"
        case .agy: return "agy"
        case .aider: return "Aider"
        default: return "Agent"
        }
    }

    /// The program its line starts with.
    public var program: String? { cli.programs.first }

    /// Only these resume by themselves: their own session file gives the exact id (KTD5).
    public var resumesAutomatically: Bool { fileSource != nil }

    /// The agent's own record of a running process that makes its id exact.
    public var fileSource: SessionSnapshot.IDSource? {
        switch self {
        case .claude: return .sessionFile
        case .codex: return .openRollout
        case .qwen: return .runtimeFile
        default: return nil
        }
    }

    /// It can be resumed from the command line. agy and Aider cannot: they get a note (R7).
    public var hasResumeForm: Bool { cli.resume != nil }

    /// Its resume form's words after the program, with `id`: the subcommand its options belong to, then the resume
    /// form. Codex's names the session's folder when that is a plain absolute path.
    func resumeWords(id: String, folder: String?) -> [String]? {
        cli.resumeWords(id: id, folder: folder).map { cli.subcommand + $0 }
    }

    // MARK: ids

    /// Shaped like this agent's session ids (its table's id pattern), and safe as one word of a line.
    public func isSessionID(_ id: String) -> Bool { cli.isSessionID(id) }

    /// An option's name (`--model`, `-m`) or a subcommand (`exec`), holding nothing shaped like a secret: what a
    /// note may show of a word.
    static func isOptionName(_ name: String) -> Bool {
        let body = name.utf8.drop { $0 == UInt8(ascii: "-") }
        guard name.utf8.count - body.count <= 2, body.count <= 48, AgentCLI.isToken(body, extra: "._-") else { return false }
        return CommandSecrets.mayKeep(name)
    }

    /// The session `arguments` (the agent's own, after its program) resume, when one is named in this agent's
    /// pattern. The session list's agents read it as the list does; the rest, from the form the table says names it.
    public func resumedID(in arguments: [String]) -> String? {
        let id: String?
        if let kind, let program {
            id = kind.resumedID(in: ([program] + arguments.map(ShellQuote.quote)).joined(separator: " "))
        } else {
            id = cli.read(arguments).session
        }
        return id.flatMap { isSessionID($0) ? $0 : nil }
    }

    // MARK: arguments

    /// The agent's own arguments in a typed line, and whether its program is the first word there (no assignment,
    /// wrapper or option before it). A name the agent shares with other programs (`cmd`) counts here, as the process
    /// has shown it runs from the agent's own install.
    public func arguments(inLine line: String) -> (arguments: [String], plain: Bool)? {
        for segment in CommandClassifier.segments(line) {
            let words = AgentKind.words(segment)
            guard let index = CommandClassifier.programIndex(words) else { continue }
            let run = Array(words[index...])
            let name = CommandClassifier.baseName(run[0])
            if cli.programs.contains(name) || cli.installedNames.contains(name) { return (Array(run.dropFirst()), index == 0) }
            if let script = Self.scriptIndex(argv: run, executable: ""), Self.scriptAgent(run[script]) == self {
                return (Array(run[(script + 1)...]), index == 0)
            }
        }
        return nil
    }

    /// The agent's own arguments in a process's argv: after the program, or after the script an interpreter runs.
    public static func arguments(argv: [String], executable: String) -> [String] {
        guard let script = scriptIndex(argv: argv, executable: executable) else { return Array(argv.dropFirst()) }
        return Array(argv[(script + 1)...])
    }

    /// Where the script is in an interpreter's argv (`node …/cli.js`): the first word after it that is not an option.
    static func scriptIndex(argv: [String], executable: String) -> Int? {
        guard let first = argv.first else { return nil }
        let names = [first, executable].map { CommandClassifier.stem(CommandClassifier.baseName($0)) }
        guard names.contains(where: CommandClassifier.interpreters.contains) else { return nil }
        return argv.indices.dropFirst().first { !argv[$0].hasPrefix("-") }
    }

    /// The agent a script is, by its name or its own package (CommandClassifier.scriptAgentName), or by an install the
    /// classifier does not know (Cursor's `index.js`). A name other programs share counts only in the agent's install.
    static func scriptAgent(_ script: String) -> Self? {
        guard let name = CommandClassifier.scriptAgentName(script) else { return installed(at: [script]) }
        return Self(program: name, at: [script]) ?? .unknown
    }

    // MARK: the put-back line

    /// The resume form with `id` alone: the put-back line of a launch with no options (Evidence.putBack). The program
    /// alone when there is no id or it fails the agent's pattern; nil for an agent with no resume form (R7).
    public func putBackLine(id: String?, folder: String? = nil) -> String? {
        SessionSnapshot.Evidence(agent: self, options: []).putBack(id: id, folder: folder)?.line
    }
}

// MARK: - Options

extension SessionSnapshot.Agent {
    /// The options in the agent's own arguments (after its program) as a file keeps them (U2): in order, each with its
    /// values as the arguments gave them. Prompt words, forms and one-shot options are none of them, as a resume never
    /// sends a prompt again (R8) and names its own session. An option the table does not know keeps a value `=` joins
    /// to it; a word after it may be its value or a prompt's, so it is marked unclear and the word is not kept. Nil when
    /// they cannot be kept whole (SessionSnapshot.LaunchOption.kept).
    public func launchOptions(in arguments: [String]) -> [SessionSnapshot.LaunchOption]? {
        let reading = cli.read(arguments)
        var options: [SessionSnapshot.LaunchOption] = []
        for (index, piece) in reading.pieces.enumerated() {
            switch piece {
            case .word:
                continue
            case .known(_, _, let option):
                if option.kind == .form || option.kind == .oneShot { continue }
                options.append(SessionSnapshot.LaunchOption(reading.given[index]))
            case .unknown(_, let value):
                let next = reading.pieces.indices.contains(index + 1) ? reading.pieces[index + 1] : nil
                let wordAfter: Bool
                if case .word = next { wordAfter = true } else { wordAfter = false }
                options.append(SessionSnapshot.LaunchOption(reading.given[index], unclear: value == nil && wordAfter))
            }
        }
        return SessionSnapshot.LaunchOption.kept(options)
    }

    /// The permission options a typed line, or an alias's expansion, shows for this agent (KTD5): in its last command,
    /// the one that started the agent, as the launcher and the typed-line check read it. An earlier command that names the
    /// agent ran and ended before it (`claude --dangerously-skip-permissions --version; cad`), and confirms nothing. None
    /// when that command does not run the agent, or its options cannot be kept whole.
    public func confirmedOptions(inLine line: String) -> [SessionSnapshot.LaunchOption] {
        guard let last = CommandClassifier.segments(line).last, let run = arguments(inLine: last),
              let options = launchOptions(in: run.arguments) else { return [] }
        return options.filter { cli.options[$0.name]?.kind == .permission }
    }

    /// `options` (argv's, as a record keeps them) read with the running build's table (KTD20): what a put-back line
    /// keeps, what an automatic resume carries, and what is left off. A form or a one-shot option is dropped. An option
    /// whose value capture could not tell from a prompt word is left off and named, unless the table now knows it takes
    /// none. A word capture's table read as an option's value, which this table reads as no value of it, is a prompt word
    /// now (R8): the line keeps only the words the option takes, and an option this table no longer knows is left off with
    /// it. `confirmed` holds the permission options the nonce-verified typed or alias-expanded line showed: a permission
    /// option is carried only when argv and that line both show it, as a process can rewrite its own argv (KTD5).
    public func reading(_ options: [SessionSnapshot.LaunchOption], confirmed: [SessionSnapshot.LaunchOption]) -> LaunchReading {
        var reading = LaunchReading()
        var shown: [[String]] = confirmed.filter { cli.options[$0.name]?.kind == .permission }.map(\.words)
        for option in options {
            let read = cli.read(option.words)
            guard let first = read.pieces.first, let given = read.given.first else { continue }
            // Its words read as this option and its values alone, as capture's table read them.
            let whole = read.pieces.count == 1
            switch first {
            case .known(let name, let values, let known):
                if known.kind == .form || known.kind == .oneShot { continue }
                if option.unclear, known.values != .none || !whole {
                    reading.leaveOff(name)
                    continue
                }
                reading.line += given
                guard whole, known.carries(values) else {
                    reading.allowed = false
                    continue
                }
                switch known.kind {
                case .plain:
                    reading.plain += option.words
                case .permission:
                    if let index = shown.firstIndex(of: option.words) {
                        shown.remove(at: index)
                        reading.permissions.append(option.words)
                    } else {
                        reading.allowed = false
                    }
                case .codeLoading, .form, .oneShot:
                    reading.allowed = false
                }
            case .unknown(let name, _):
                if option.unclear || !whole {
                    reading.leaveOff(name)
                } else {
                    reading.line += option.words
                    reading.allowed = false
                }
            case .word:
                reading.allowed = false
            }
        }
        // The typed line showed a permission option argv does not: they disagree, so nothing runs by itself.
        if !shown.isEmpty { reading.allowed = false }
        return reading
    }

    // MARK: environment and config

    /// Variables that send it to another provider, account or store. A resume needs the shell's to match (KTD5). Only
    /// base URLs, config folders, and model and provider selectors: they are compared as digests, and a key, token or
    /// header variable is never digested (AgentEvidence.mayDigest).
    public var routingVariables: [String] {
        switch self {
        case .claude:
            return ["ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
                    "CLAUDE_CODE_USE_FOUNDRY", "ANTHROPIC_VERTEX_PROJECT_ID", "CLOUD_ML_REGION", "AWS_PROFILE", "AWS_REGION",
                    "AWS_DEFAULT_REGION", "HTTPS_PROXY"]
        case .codex: return ["CODEX_HOME", "OPENAI_BASE_URL", "OPENAI_ORGANIZATION", "OPENAI_PROJECT", "HTTPS_PROXY"]
        case .qwen: return ["OPENAI_BASE_URL", "OPENAI_MODEL", "HTTPS_PROXY"]
        default: return []
        }
    }

    /// Variables that make it continue a cut-off turn by itself. A resume unsets them, and one set means no
    /// automatic resume.
    public var autoContinueVariables: [String] {
        switch self {
        case .claude:
            return ["CLAUDE_CODE_RESUME_INTERRUPTED_TURN", "CLAUDE_CODE_RESUME_INTERRUPTED_TURN_MAX_AGE_MS", "CLAUDE_CODE_RESUME_PROMPT"]
        case .copilot: return ["COPILOT_ENABLE_INTERRUPTED_SESSION_RESTORE"]
        default: return []
        }
    }

    /// The project config it reads, relative to a folder: one changed after it started sends it to the line.
    public var projectConfigFiles: [String] {
        switch self {
        case .claude: return [".claude/settings.json", ".claude/settings.local.json", ".mcp.json"]
        case .codex: return [".codex/config.toml"]
        case .qwen: return [".qwen/settings.json"]
        default: return []
        }
    }
}

// MARK: - The gate

/// A check of the automatic-resume gate (KTD5).
public enum ResumeCheck: String, CaseIterable, Sendable {
    /// Not Claude Code, Codex or Qwen Code.
    case automatic
    /// The id is not exact through the agent's own session file.
    case sessionFile
    /// No id, or not in the agent's pattern.
    case idPattern
    /// An option an automatic resume may not carry: a code-loading one, one the table does not know or whose value it
    /// can't tell, a value outside its pattern, or a permission option argv and the typed line do not both show; or the
    /// options are not known.
    case flags
    /// An environment prefix, a wrapper, a function, or an alias that holds one: the line did not run as typed.
    case typedLine
    /// Its provider or config variables differed from the shell's.
    case routing
    /// An auto-continue variable is set, in its environment or its settings.
    case autoContinue
    /// The session is not in its store, or a live process holds it.
    case session
    /// The store its session file was read in is gone, is no longer that real folder, is not the user's alone, or lies
    /// where a tab can write: a project, the tab's or session's folder, a temporary folder (KTD4).
    case store
    /// The session's folder is gone, someone else's, writable by others or not local.
    case folder
    /// What runs no longer resolves.
    case executable
    /// What runs lies in a project, the tab's or session's folder, or a temporary folder.
    case location
    /// What runs is not a regular file of the user's or root's, or others can write it.
    case ownership
    /// A project config it reads changed after it started, or code that config starts and a tab can write did (a
    /// script in a project, the tab's or session's folder, or a temporary folder), or its start is not known.
    case projectConfig
}

public enum ResumeVerdict: Equatable, Sendable {
    /// Every check passed: run this once the shell is ready.
    case resume(String)
    /// Put the resume form back on the line (R6). The checks that failed.
    case onTheLine([ResumeCheck])
    /// No resume form: a note (R7).
    case note
}

/// What the gate reads of the Mac as it is at restore.
public struct ResumeFacts: Sendable {
    public var user: uid_t
    /// By the path the evidence records: the executable, interpreter, script, session folder and store. A path
    /// missing here leads nowhere.
    public var files: [String: FileFacts]
    /// Folders the agent's code must lie outside: every open project, the tab's folder, the session's folder.
    public var outside: [String]
    public var temporaryFolders: [String]
    /// The session is in its store and no live process holds it (checked when the action runs).
    public var sessionAvailable: Bool
    /// A project config the agent reads, or code that config starts in `outside` or `temporaryFolders`, changed after
    /// the agent started, or that cannot be told.
    public var projectConfigChanged: Bool
    public var settingsAutoContinue: Bool

    /// A fact not given reads as the answer that resumes nothing.
    public init(user: uid_t = geteuid(), files: [String: FileFacts] = [:], outside: [String] = [], temporaryFolders: [String] = [],
                sessionAvailable: Bool = false, projectConfigChanged: Bool = true, settingsAutoContinue: Bool = true) {
        self.user = user
        self.files = files
        self.outside = outside
        self.temporaryFolders = temporaryFolders
        self.sessionAvailable = sessionAvailable
        self.projectConfigChanged = projectConfigChanged
        self.settingsAutoContinue = settingsAutoContinue
    }

    /// The facts for `evidence`, read from the file system now.
    public static func read(for evidence: SessionSnapshot.Evidence, projects: [String], tabFolder: String?, sessionAvailable: Bool,
                            home: String = NSHomeDirectory()) -> ResumeFacts {
        var facts = ResumeFacts(sessionAvailable: sessionAvailable)
        let paths = [evidence.executable, evidence.interpreter, evidence.script, evidence.sessionFolder, evidence.store]
        for path in paths.compactMap({ $0 }) {
            facts.files[path] = FileFacts.read(path)
        }
        facts.outside = (projects + [tabFolder, evidence.sessionFolder].compactMap { $0 }).map(canonicalPath)
        facts.temporaryFolders = AgentEvidence.temporaryFolders()
        let folder = evidence.sessionFolder ?? tabFolder
        if let folder {
            let agent = evidence.agent
            let start = evidence.startedAt
            let within = facts.outside + facts.temporaryFolders
            facts.projectConfigChanged = AgentEvidence.projectConfigChanged(agent: agent, folder: folder, since: start, home: home)
                || AgentEvidence.projectCodeChanged(agent: agent, folder: folder, since: start, within: within, home: home)
        }
        let claude = evidence.agent == .claude
        facts.settingsAutoContinue = claude && AgentEvidence.claudeSettingsAutoContinue(home: home, store: evidence.store, folder: folder)
        return facts
    }

    /// `path` lies in a folder the agent's code must stay out of.
    func forbids(_ path: String) -> Bool {
        (outside + temporaryFolders).contains { folder in
            path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
        }
    }
}

extension SessionSnapshot.Evidence {
    /// The automatic-resume gate (KTD5): every check must pass for Claude Code, Codex or Qwen Code to resume by
    /// itself. Whether the restore is an update restore is the planner's to know: a crash restore never resumes.
    public func gate(_ facts: ResumeFacts) -> ResumeVerdict {
        guard agent.hasResumeForm else { return .note }
        var failed: [ResumeCheck] = []
        if !agent.resumesAutomatically { failed.append(.automatic) }
        if agent.fileSource == nil || source != agent.fileSource { failed.append(.sessionFile) }
        if !(sessionID.map(agent.isSessionID) ?? false) { failed.append(.idPattern) }
        if !launch.allowed { failed.append(.flags) }
        if !ranAsTyped { failed.append(.typedLine) }
        if !routingMatchesShell { failed.append(.routing) }
        if !autoContinueOff || facts.settingsAutoContinue { failed.append(.autoContinue) }
        if !facts.sessionAvailable { failed.append(.session) }
        if !storeIsSafe(facts) { failed.append(.store) }
        if !folderIsSafe(facts) { failed.append(.folder) }
        failed += codeProblems(facts)
        if startedAt == nil || facts.projectConfigChanged { failed.append(.projectConfig) }
        guard failed.isEmpty else { return .onTheLine(failed) }
        guard let command = resumeCommand else { return .onTheLine([.executable]) }
        return .resume(command)
    }

    /// The session's folder exists, is the user's, others cannot write it, and it is on a local volume.
    private func folderIsSafe(_ facts: ResumeFacts) -> Bool {
        guard let folder = sessionFolder, let found = facts.files[folder] else { return false }
        return found.isDirectory && found.owner == facts.user && !found.othersCanWrite && found.isLocal
    }

    /// The store capture read the session file in is still that real folder, the user's alone, and outside every
    /// folder a tab can write.
    private func storeIsSafe(_ facts: ResumeFacts) -> Bool {
        guard let store, let found = facts.files[store] else { return false }
        let owned = found.isDirectory && found.owner == facts.user && !found.othersCanWrite
        return owned && found.realPath == store && !facts.forbids(found.realPath)
    }

    /// What runs (the executable, or a script agent's interpreter and script), by real path: there, a regular file of
    /// the user's or root's that others cannot write, outside projects and temporary folders. The resume runs the
    /// recorded path, so each link it passes on the way must lie outside them too: one there could be pointed
    /// elsewhere between this check and the run.
    private func codeProblems(_ facts: ResumeFacts) -> [ResumeCheck] {
        guard let paths = codePaths else { return [.executable] }
        var problems: [ResumeCheck] = []
        for path in paths {
            guard let file = facts.files[path] else {
                problems.append(.executable)
                continue
            }
            if facts.forbids(file.realPath) || file.linksFollowed.contains(where: facts.forbids) { problems.append(.location) }
            let owned = file.owner == facts.user || file.owner == 0
            if !file.isRegular || !owned || file.othersCanWrite { problems.append(.ownership) }
        }
        return ResumeCheck.allCases.filter(problems.contains)
    }

    /// Whether the code the snapshot records is this agent, judged as capture judged the process
    /// (CommandClassifier.agentName): the executable by its own name or its agent's install, or an interpreter running
    /// the agent's script. The snapshot is read as untrusted: a recorded `/bin/zsh` for Codex would run `./resume`.
    private var codeIsTheAgent: Bool {
        if let interpreter {
            let name = CommandClassifier.stem(CommandClassifier.baseName(interpreter))
            guard CommandClassifier.interpreters.contains(name), let script else { return false }
            return RestoreAgent.scriptAgent(script) == agent
        }
        guard let executable else { return false }
        let name = CommandClassifier.agentName(executable: executable, arguments: [executable])
        return name.flatMap { RestoreAgent(program: $0, at: [executable]) } == agent
    }

    /// The executable; for a script agent, its interpreter and script, both needed.
    private var codePaths: [String]? {
        if let interpreter {
            guard let script else { return nil }
            return [interpreter, script]
        }
        return executable.map { [$0] }
    }

    /// The automatic resume (KTD5): `/usr/bin/env -u <auto-continue variables>`, the recorded absolute path (a
    /// script agent's interpreter and script), the resume form with the id, the plain options and the permission options
    /// the typed line confirmed (`launch`). Nil when any of it is missing or not one plain line, an option may not be
    /// carried, or the code recorded is not the agent (`codeIsTheAgent`). It holds no prompt words. Only the gate hands it
    /// out (`.resume`).
    var resumeCommand: String? {
        let launch = self.launch
        guard agent.resumesAutomatically, let id = sessionID, agent.isSessionID(id), launch.allowed,
              SnapshotText.plainPath(sessionFolder, max: SessionSnapshot.Limits.standard.path) != nil, codeIsTheAgent,
              let paths = codePaths, let words = agent.resumeWords(id: id, folder: sessionFolder) else { return nil }
        let limit = SessionSnapshot.Limits.standard.path
        guard paths.allSatisfy({ SnapshotText.plainPath($0, max: limit) != nil }) else { return nil }
        let unset = agent.autoContinueVariables.flatMap { ["-u", $0] }
        let line = (["/usr/bin/env"] + unset + paths + words + launch.carried).map(ShellQuote.quote).joined(separator: " ")
        return SessionSnapshot.Command.problem(with: line) == nil ? line : nil
    }
}

// MARK: - The put-back line

extension SessionSnapshot.Evidence {
    /// Its options read with the running build's table (KTD20). Options not known keep nothing and carry nothing.
    public var launch: LaunchReading {
        guard let options else { return LaunchReading(allowed: false) }
        return agent.reading(options, confirmed: confirmed)
    }

    /// The line put back on the prompt, unrun (R6, KTD7): the user's launch with the resume form and `id`. A launcher
    /// that passes its arguments on is replayed with the options typed after it, and brings its own back itself (an
    /// environment prefix too); otherwise the line is rebuilt from the program and argv's options. Kiro's and Goose's
    /// options belong to a subcommand that a launcher may hold or not, which nothing shows, so theirs is always rebuilt.
    /// With no id, or one outside the agent's pattern, the launch goes back without the resume form. Nil for an agent with
    /// no resume form (R7).
    public func putBack(id: String?, folder: String? = nil) -> PutBack? {
        guard agent.hasResumeForm, let program = agent.program else { return nil }
        let cli = agent.cli
        let options = self.options ?? []
        let replayed = replayedLauncher
        let kept = agent.reading(replayed.map { Array(options.suffix($0.typed)) } ?? options, confirmed: [])
        let start = replayed.map { [$0.word] } ?? [program]
        let launch = start + (kept.line.isEmpty ? [] : cli.subcommand) + kept.line
        var candidates: [(words: [String], namesSession: Bool)] = []
        if let id, agent.isSessionID(id) {
            for place in [folder, nil] {
                guard let resume = cli.resumeWords(id: id, folder: place) else { continue }
                candidates.append((start + cli.subcommand + kept.line + resume, true))
            }
        }
        candidates.append((launch, false))
        for candidate in candidates {
            let line = candidate.words.map(ShellQuote.quote).joined(separator: " ")
            if SessionSnapshot.Command.problem(with: line) == nil {
                return PutBack(line: line, namesSession: candidate.namesSession, leftOff: kept.leftOff)
            }
        }
        return PutBack(line: program, namesSession: false, leftOff: [])
    }

    /// The launcher a put-back line replays (KTD7): the record's, unless the agent's options belong to a subcommand, the
    /// count typed after it is not one the options hold, or one of its own options is unclear: its word was typed after
    /// the launcher, and a replay would split the two (an earlier build kept such a launcher). Nil when the line is
    /// rebuilt from the program.
    public var replayedLauncher: SessionSnapshot.Launcher? {
        let options = self.options ?? []
        guard let launcher, agent.cli.subcommand.isEmpty, (0...options.count).contains(launcher.typed),
              !options.dropLast(launcher.typed).contains(where: \.unclear) else { return nil }
        return launcher
    }

    /// The launcher a put-back line replays with the resume form and `id` alone, none of the options typed after it, as
    /// in `cw --resume S` (KTD6): the start watch's fallback after that line failed, so a launcher that sets the agent's
    /// store still finds the session. Nil with no launcher replayed, or no line that names the session.
    public func launcherResume(id: String, folder: String? = nil) -> String? {
        guard let launcher = replayedLauncher else { return nil }
        var bare = self
        bare.launcher = SessionSnapshot.Launcher(word: launcher.word, typed: 0)
        guard let back = bare.putBack(id: id, folder: folder), back.namesSession else { return nil }
        return back.line
    }
}
