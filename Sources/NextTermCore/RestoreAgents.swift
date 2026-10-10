import Foundation

// The agents a restore knows, and what it may do for each (the plan's agent evidence matrix): the program, the id
// pattern, the resume form and the options, all read from each agent's AgentCLI entry (KTD20); the put-back line every
// agent with a resume form gets (KTD7); and, for Claude Code, Codex and Qwen Code alone, the options a resume may carry
// and the gate an automatic resume must pass (KTD5).
//
// A put-back line is the resume form with the id and nothing else: no prompt words, no options, no environment
// prefix. An automatic resume runs the recorded absolute path through `/usr/bin/env -u <auto-continue variables>`,
// with only options its agent allows. Both are one plain line, quoted with ShellQuote.

/// The agents a restore knows: SessionSnapshot.Agent, which maps to AgentKind where the session list knows the
/// agent too, so AgentKind's exhaustive switches stay as they are.
public typealias RestoreAgent = SessionSnapshot.Agent

/// What capture made of an agent's options.
public struct AgentOptions: Equatable, Sendable {
    /// The options an automatic resume carries, as words: `--model`, `opus`.
    public var carried: [String]
    /// The names of the rest, for a note. Never a value.
    public var leftOff: [String]
    /// Nothing was left off, so an automatic resume runs as the agent ran.
    public var allowed: Bool

    public init(carried: [String], leftOff: [String], allowed: Bool) {
        self.carried = carried
        self.leftOff = leftOff
        self.allowed = allowed
    }

    mutating func leaveOff(_ name: String) {
        allowed = false
        if RestoreAgent.isOptionName(name), !leftOff.contains(name), leftOff.count < SessionSnapshot.Evidence.mostOptions {
            leftOff.append(name)
        }
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

    /// The line put back on the prompt, unrun (R6): the resume form with `id`, or the program alone when there is no
    /// id or it fails the agent's pattern. Nil for an agent with no resume form (R7).
    public func putBackLine(id: String?, folder: String? = nil) -> String? {
        guard hasResumeForm, let program else { return nil }
        guard let id, isSessionID(id) else { return program }
        let forms = [resumeWords(id: id, folder: folder), resumeWords(id: id, folder: nil)].compactMap { $0 }
        for words in forms {
            let line = ([program] + words).map(ShellQuote.quote).joined(separator: " ")
            if SessionSnapshot.Command.problem(with: line) == nil { return line }
        }
        return program
    }
}

// MARK: - Options

extension SessionSnapshot.Agent {
    /// What capture keeps of the agent's own arguments (after its program), read with its table: the plain options an
    /// automatic resume may carry, with values within their patterns; the names of the rest; and whether anything was
    /// left off. Prompt words and forms are neither: a resume never re-sends a prompt (R8), and forms its own. Only
    /// Claude Code, Codex and Qwen Code carry any, as only they resume by themselves.
    public func options(in arguments: [String]) -> AgentOptions {
        var options = AgentOptions(carried: [], leftOff: [], allowed: true)
        for piece in cli.read(arguments).pieces {
            switch piece {
            case .word:
                continue
            case .unknown(let name, _):
                options.leaveOff(name)
            case .known(let name, let values, let option):
                if option.kind == .form { continue }
                if resumesAutomatically, option.kind == .plain, option.carries(values) {
                    options.carried += [name] + values
                } else {
                    options.leaveOff(name)
                }
            }
        }
        let most = SessionSnapshot.Evidence.mostOptions
        if options.carried.count > most || !CommandSecrets.mayKeep(options.carried.joined(separator: " ")) {
            options.carried = []
            options.allowed = false
        }
        return options
    }

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

    /// The permission options a typed line, or an alias's expansion, shows for this agent (KTD5). None when the line
    /// does not run it, or its options cannot be kept whole.
    public func confirmedOptions(inLine line: String) -> [SessionSnapshot.LaunchOption] {
        guard let run = arguments(inLine: line), let options = launchOptions(in: run.arguments) else { return [] }
        return options.filter { cli.options[$0.name]?.kind == .permission }
    }

    /// `flags` are exactly what this agent's resume may carry.
    func carries(_ flags: [String]) -> Bool {
        guard !flags.isEmpty else { return true }
        let read = options(in: flags)
        return read.allowed && read.carried == flags
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
    /// An option was left off, or one carried is not the agent's to carry.
    case flags
    /// An environment prefix, a wrapper or an alias: the line did not run as typed.
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
        if !flagsAllowed || !agent.carries(flags) { failed.append(.flags) }
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
    /// script agent's interpreter and script), the resume form with the id, and the options it may carry. Nil when
    /// any of it is missing or not one plain line, or the code recorded is not the agent (`codeIsTheAgent`). It holds no
    /// prompt words. Only the gate hands it out (`.resume`).
    var resumeCommand: String? {
        guard agent.resumesAutomatically, let id = sessionID, agent.isSessionID(id), agent.carries(flags),
              SnapshotText.plainPath(sessionFolder, max: SessionSnapshot.Limits.standard.path) != nil, codeIsTheAgent,
              let paths = codePaths, let words = agent.resumeWords(id: id, folder: sessionFolder) else { return nil }
        let limit = SessionSnapshot.Limits.standard.path
        guard paths.allSatisfy({ SnapshotText.plainPath($0, max: limit) != nil }) else { return nil }
        let unset = agent.autoContinueVariables.flatMap { ["-u", $0] }
        let line = (["/usr/bin/env"] + unset + paths + words + flags).map(ShellQuote.quote).joined(separator: " ")
        return SessionSnapshot.Command.problem(with: line) == nil ? line : nil
    }
}
