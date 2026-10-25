import Foundation

/// Next Term's skill library over MCP (list_skills, get_skill): any agent in a tab, whatever it reads itself (Claude
/// Code, Codex, Gemini CLI, OpenCode, Command Code…), can use the skills of its project, the user's, and Next Term's
/// own. Nothing is written anywhere: the library only reads, and Next Term's own skills live in the app.
///
/// It finds them as the agents do (their docs, October 2026):
/// - The project's: the skill folders in the agent's folder and each one above it up to the repository's top, at most
///   ten, never the home folder (Codex walks to the repository's top, Command Code ten folders up; Claude Code reads
///   its folder's and, in a monorepo, the nested ones).
/// - The user's: the same folders in the home folder, and OpenCode's in its config folder too
///   (`~/.config/opencode/skills`). Then Next Term's own (BuiltInSkill).
/// - A name in more than one place: the agent's own rule picks the copy (Claude Code takes the user's over the
///   project's; Command Code the project's, `.commandcode` before `.agents`; OpenCode its own folders' first, the
///   user's `~/.opencode`, the project's, then its config folder's, and never a copy whose SKILL.md gives no name;
///   Codex shows both, and the nearer comes first here), and every other copy is named, so nothing is hidden.
/// - Each skill says whether the asking agent loads it itself (`native`): it needs get_skill only for the others.
public enum SkillLibrary {
    public enum Scope: String, Sendable, CaseIterable {
        /// In the project's folders (`.claude/skills` and the like, in the agent's folder or one above it).
        case project
        /// In the user's folders (`~/.agents/skills`, `~/.claude/skills`…).
        case personal
        /// One of Next Term's own.
        case nextTerm = "next-term"
    }

    /// One copy of a skill.
    public struct Copy: Equatable, Sendable {
        public let name: String
        public let description: String
        public let scope: Scope
        /// The skill's folder; nil for Next Term's own.
        public let folder: String?
        /// Where it is, as said: ".claude/skills" (at the project's top), "packages/web/.agents/skills",
        /// "~/.agents/skills", "Next Term".
        public let place: String
        /// The skill folder it is in (".claude/skills"); nil for Next Term's own.
        public let kind: String?
        /// Its SKILL.md's front matter gives a name: OpenCode skips one that doesn't.
        public var hasName = true
    }

    /// A skill as the asking agent gets it: the copy its rule picks, whether it loads that name itself, and where
    /// the other copies are.
    public struct Entry: Equatable, Sendable {
        public let copy: Copy
        public let native: Bool
        public let others: [Copy]
        public var name: String { copy.name }
    }

    /// The folders agents read, in a project or the home folder: the shared one (Codex, Gemini CLI, OpenCode, Copilot
    /// CLI, Command Code…), Claude Code's, Codex's older one, Command Code's, and OpenCode's own (`skills`, and the
    /// older `skill`), which among the user's are in its config folder too (`personalFolders`).
    static let folders = [".agents/skills", ".claude/skills", ".codex/skills", ".commandcode/skills", ".opencode/skills", ".opencode/skill"]
    /// OpenCode's own folders: in a project's `.opencode`, and among the user's in its config folder.
    static let opencodeFolders = [".opencode/skills", ".opencode/skill"]
    /// How far up the project's folders are looked for, as Command Code does.
    static let levels = 10

    /// The agent asking, by its program's name (CommandKind.agentName): the folders it reads itself and which copy of
    /// a name it takes. An agent Next Term doesn't know reads none itself, and gets the nearest copy.
    public struct Reader: Equatable, Sendable {
        public let program: String?
        /// The folders it reads itself, in its own order, in a project and in the home folder.
        let project: [String]
        let personal: [String]
        /// Its copy of a name in both is the user's (Claude Code).
        let personalFirst: Bool
        /// Folders whose copies come before every other, the project's and then the user's: OpenCode keeps the copy it
        /// reads last, and reads its own folders after the shared and Claude Code's, the project's included.
        var preferred: [String] = []
        /// Places among the user's that come before even those, as said (`~/.opencode/skills`): OpenCode reads
        /// `.opencode` in the home folder after the project's (ConfigPaths.directories, 1.19).
        var readLast: [String] = []
        /// It skips a copy whose SKILL.md gives no name (OpenCode).
        var needsName = false

        public init(program: String?) {
            self.program = program
            switch program {
            case "claude", "claude-code":
                (project, personal, personalFirst) = ([".claude/skills"], [".claude/skills"], true)
            case "codex":
                (project, personal, personalFirst) = ([".agents/skills"], [".agents/skills", ".codex/skills"], false)
            case "commandcode", "command-code", "cmd":
                let own = [".commandcode/skills", ".agents/skills"]
                (project, personal, personalFirst) = (own, own, false)
            case "opencode":
                let own = SkillLibrary.opencodeFolders + [".agents/skills", ".claude/skills"]
                (project, personal, personalFirst, preferred) = (own, own, false, SkillLibrary.opencodeFolders)
                readLast = SkillLibrary.opencodeFolders.map { "~/" + $0 }
                needsName = true
            case "amp", "cursor-agent", "goose": // SkillReaders.claude: they read Claude Code's too
                let own = [".agents/skills", ".claude/skills"]
                (project, personal, personalFirst) = (own, own, false)
            case "gemini", "gemini-cli", "qwen", "qwen-code", "copilot", "junie": // SkillReaders.shared
                (project, personal, personalFirst) = ([".agents/skills"], [".agents/skills"], false)
            default:
                (project, personal, personalFirst) = ([], [], false)
            }
        }

        /// The folders in the order this agent ranks them: its own first.
        func order(_ own: [String]) -> [String] { own + SkillLibrary.folders.filter { !own.contains($0) } }

        /// It reads that copy's folder itself.
        public func reads(_ copy: Copy) -> Bool {
            guard let kind = copy.kind, copy.hasName || !needsName else { return false }
            return (copy.scope == .project ? project : personal).contains(kind)
        }
    }

    /// The folders a project's skills are looked for in, nearest first: `start` and each folder above it, up to the
    /// repository's top (a folder with `.git`), at most `levels`, never `home` or above it. Outside a repository, the
    /// ten folders up to the home folder.
    public static func projectFolders(from start: String, home: String) -> [String] {
        let home = canonicalPath(home)
        var path = canonicalPath(start), chain: [String] = []
        while chain.count < levels, path != home, path != "/", !home.hasPrefix(path + "/") {
            chain.append(path)
            if FileManager.default.fileExists(atPath: path + "/.git") { return chain }
            path = (path as NSString).deletingLastPathComponent
        }
        return chain
    }

    /// Every copy there is for an agent working in `start`, read once: the project's by folder, nearest first, the
    /// user's, and Next Term's own. `rank` orders them for each agent.
    public struct Found: Sendable {
        let levels: [[Copy]]
        let personal: [Copy]
        let own: [Copy]
    }

    /// Where one of `folders` is among the user's, and how it is said: in the home folder, and OpenCode's in its config
    /// folder too (`~/.config/opencode`, or where the login shell's XDG_CONFIG_HOME puts it for the user's own home, as
    /// SkillRoot.personal finds them; `environment`: those variables instead). The home folder's `.opencode` comes first:
    /// OpenCode reads it last.
    static func personalFolders(_ kind: String, home: String, environment: [String: String]? = nil) -> [(path: String, place: String)] {
        let inHome: (path: String, place: String) = (home + "/" + kind, "~/" + kind)
        guard opencodeFolders.contains(kind) else { return [inHome] }
        let config = OpencodePaths.configFolder(home: home, environment: environment ?? OpencodePaths.environment(home: home))
        let path = config + "/" + (kind as NSString).lastPathComponent
        let place: String = path.hasPrefix(home + "/") ? "~/" + String(path.dropFirst(home.count + 1)) : path
        return [inHome, (path, place)]
    }

    public static func gather(from start: String?, home: String, nextTerm: [BuiltInSkill]) -> Found {
        let chain = start.map { projectFolders(from: $0, home: home) } ?? []
        let top = chain.last
        let levels = chain.map { folder in
            let relative = folder == top ? "" : String(folder.dropFirst((top?.count ?? 0) + 1)) + "/"
            return folders.flatMap { kind in read(folder + "/" + kind, scope: .project, kind: kind, place: relative + kind) }
        }
        let personal = folders.flatMap { (kind: String) -> [Copy] in
            personalFolders(kind, home: home).flatMap { read($0.path, scope: .personal, kind: kind, place: $0.place) }
        }
        let own = nextTerm.map { Copy(name: $0.name, description: $0.description, scope: .nextTerm, folder: nil, place: "Next Term", kind: nil) }
        return Found(levels: levels, personal: personal, own: own)
    }

    /// Every skill for an agent working in `start` (nil: no project), one entry a name, in the order its rule ranks
    /// them. `nextTerm`: Next Term's own that are offered (BuiltInSkill.offered).
    public static func entries(from start: String?, home: String, nextTerm: [BuiltInSkill], reader: Reader = Reader(program: nil)) -> [Entry] {
        rank(gather(from: start, home: home, nextTerm: nextTerm), reader: reader)
    }

    /// The copies found, as `reader` gets them: in each folder its own skill folders first, the project's before the
    /// user's (the user's first for Claude Code), Next Term's last; one entry a name.
    public static func rank(_ found: Found, reader: Reader) -> [Entry] {
        func ordered(_ copies: [Copy], _ own: [String]) -> [Copy] {
            let order = reader.order(own)
            return copies.enumerated().sorted { a, b in
                (order.firstIndex(of: a.element.kind ?? "") ?? order.count, a.offset) < (order.firstIndex(of: b.element.kind ?? "") ?? order.count, b.offset)
            }.map(\.element)
        }
        let project = found.levels.flatMap { ordered($0, reader.project) }
        let personal = ordered(found.personal, reader.personal)
        let both: [Copy] = reader.personalFirst ? personal + project : project + personal
        let isLast = { (copy: Copy) -> Bool in copy.scope == .personal && reader.readLast.contains(copy.place) }
        let isPreferred = { (copy: Copy) -> Bool in !isLast(copy) && reader.preferred.contains(copy.kind ?? "") }
        var ranked: [Copy] = both.filter(isLast)
        ranked += both.filter(isPreferred)
        ranked += both.filter { (copy: Copy) -> Bool in !isLast(copy) && !isPreferred(copy) }
        ranked += found.own
        var byName: [String: [Copy]] = [:], names: [String] = []
        for copy in ranked {
            if byName[copy.name] == nil { names.append(copy.name) }
            byName[copy.name, default: []].append(copy)
        }
        return names.map { name in
            let copies = byName[name] ?? []
            // The same folder reached twice (a link from ~/.claude/skills to the shared copy) is one copy.
            var seen = Set<String>(), distinct: [Copy] = []
            for copy in copies where seen.insert(copy.folder.map(canonicalPath) ?? copy.place).inserted { distinct.append(copy) }
            // A skill the agent loads itself is the copy it loads: Claude Code's rule ranks the user's over the
            // project's, but among the folders it reads.
            let used = distinct.firstIndex { copy in reader.reads(copy) || copies.contains { reader.reads($0) && sameFolder($0, copy) } }
            guard let used else { return Entry(copy: distinct[0], native: false, others: Array(distinct.dropFirst())) }
            var others = distinct
            return Entry(copy: others.remove(at: used), native: true, others: others)
        }
    }

    /// A project's skills as Settings › Skills shows them: each name with a copy in the project, A to Z, with those
    /// copies (nearest first, a link and its folder once), and what each of the three agents gets here, ranked as
    /// list_skills ranks them for it.
    public struct Overview: Sendable {
        public struct Skill: Equatable, Sendable {
            public let name: String
            public let description: String
            public let copies: [Copy]
        }
        public let skills: [Skill]
        public let byAgent: [SkillAgent: [Entry]]
        /// How many of the user's own skills there are (each name once).
        public let personal: Int

        public func entry(_ name: String, for agent: SkillAgent) -> Entry? { byAgent[agent]?.first { $0.name == name } }
    }

    public static func overview(project: String, home: String, nextTerm: [BuiltInSkill]) -> Overview {
        let found = gather(from: project, home: home, nextTerm: nextTerm)
        var byAgent: [SkillAgent: [Entry]] = [:]
        for agent in SkillAgent.allCases { byAgent[agent] = rank(found, reader: Reader(program: agent.rawValue)) }
        var copies: [String: [Copy]] = [:], seen = Set<String>()
        for copy in found.levels.joined() where seen.insert(canonicalPath(copy.folder ?? copy.place)).inserted {
            copies[copy.name, default: []].append(copy)
        }
        let skills = copies.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            let list = copies[name] ?? []
            return Overview.Skill(name: name, description: list.first { !$0.description.isEmpty }?.description ?? "", copies: list)
        }
        return Overview(skills: skills, byAgent: byAgent, personal: Set(found.personal.map(\.name)).count)
    }

    /// Two copies are one folder (one reached through a link).
    static func sameFolder(_ a: Copy, _ b: Copy) -> Bool {
        guard let first = a.folder, let second = b.folder else { return false }
        return canonicalPath(first) == canonicalPath(second)
    }

    /// One skill as an agent gets it: its entry, its SKILL.md, and the other files in its folder (relative paths, at
    /// most 100, none from .git or node_modules). `scope`: that scope's copy rather than the one the rule picks. Nil
    /// when there is none.
    public static func skill(_ name: String, scope: Scope? = nil, from start: String?, home: String, nextTerm: [BuiltInSkill],
                             reader: Reader = Reader(program: nil)) -> (entry: Entry, copy: Copy, text: String, files: [String])? {
        guard let entry = entries(from: start, home: home, nextTerm: nextTerm, reader: reader).first(where: { $0.name == name }),
              let copy = ([entry.copy] + entry.others).first(where: { scope == nil || $0.scope == scope }) else { return nil }
        guard let folder = copy.folder else { return BuiltInSkill.named(copy.name).map { (entry, copy, $0.text, []) } }
        guard let file = skillFile(in: folder), let text = readText(file, in: folder) else { return nil }
        return (entry, copy, text, otherFiles(in: folder))
    }

    /// The skills in one folder: each folder in it holding SKILL.md (a link to one counts, as agents follow them).
    static func read(_ root: String, scope: Scope, kind: String, place: String) -> [Copy] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        return names.prefix(500).compactMap { name in
            let folder = root + "/" + name
            guard let file = skillFile(in: folder), let text = readText(file, in: folder) else { return nil }
            let front = SkillFrontMatter.parse(text)
            let named = front?.name?.isEmpty == false
            return Copy(name: name, description: front?.description ?? "", scope: scope, folder: folder, place: place, kind: kind, hasName: named)
        }
    }

    static func skillFile(in folder: String) -> String? {
        ["SKILL.md", "skill.md"].map { folder + "/" + $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// The most of a SKILL.md read.
    static let maxText = 256 * 1024

    /// A SKILL.md's text, read safely, since a cloned repository's skill folder is anyone's: only a regular file of at
    /// most 256 KB, inside the skill's own folder once every link is followed (a link from SKILL.md to the project's
    /// .env, or out of the folder, is refused), never one MCPProjects.secretReason names, and never more than 256 KB read
    /// (a link to /dev/zero, or a file growing, can't make it read on). A folder that is itself a link (Claude Code's
    /// link to the shared copy) is that folder. Nil otherwise.
    public static func readText(_ file: String, in folder: String) -> String? {
        let real = canonicalPath(file), top = canonicalPath(folder)
        guard real.hasPrefix(top + "/"), MCPProjects.secretReason(String(real.dropFirst(top.count + 1))) == nil else { return nil }
        // No link left to follow; nonblocking, so a FIFO put there after the check can't hold the read.
        let fd = open(real, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= off_t(maxText) else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= maxText {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        guard data.count <= maxText else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func otherFiles(in folder: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: folder) else { return [] }
        var files: [String] = []
        while let path = walker.nextObject() as? String, files.count < 100 {
            let name = (path as NSString).lastPathComponent
            if name == ".git" || name == "node_modules" { walker.skipDescendants(); continue }
            if path == "SKILL.md" || path == "skill.md" || name.hasPrefix(".") { continue }
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder + "/" + path, isDirectory: &isFolder), !isFolder.boolValue { files.append(path) }
        }
        return files.sorted()
    }
}
