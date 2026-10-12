import Foundation

/// Next Term's skill library over MCP (list_skills, get_skill): any agent in a tab, whatever it reads itself (Claude
/// Code, Codex, Gemini CLI, opencode, Command Code…), can use the skills of its project, the user's, and Next Term's
/// own. Nothing is written anywhere: the library only reads, and Next Term's own skills live in the app.
///
/// It finds them as the agents do (their docs, October 2026):
/// - The project's: the skill folders in the agent's folder and each one above it up to the repository's top, at most
///   ten, never the home folder (Codex walks to the repository's top, Command Code ten folders up; Claude Code reads
///   its folder's and, in a monorepo, the nested ones).
/// - The user's: the same folders in the home folder. Then Next Term's own (BuiltInSkill).
/// - A name in more than one place: the agent's own rule picks the copy (Claude Code takes the user's over the
///   project's; Command Code the project's, `.commandcode` before `.agents`; Codex shows both, and the nearer comes
///   first here), and every other copy is named, so nothing is hidden.
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
        let kind: String?
    }

    /// A skill as the asking agent gets it: the copy its rule picks, whether it loads that name itself, and where
    /// the other copies are.
    public struct Entry: Equatable, Sendable {
        public let copy: Copy
        public let native: Bool
        public let others: [Copy]
        public var name: String { copy.name }
    }

    /// The folders agents read, in a project or the home folder: the shared one (Codex, Gemini CLI, opencode, Copilot
    /// CLI, Command Code…), Claude Code's, Codex's older one and Command Code's.
    static let folders = [".agents/skills", ".claude/skills", ".codex/skills", ".commandcode/skills"]
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
            case "opencode", "amp", "cursor-agent", "goose": // SkillReaders.claude: they read Claude Code's too
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

        func reads(_ copy: Copy) -> Bool {
            guard let kind = copy.kind else { return false }
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

    /// Every skill for an agent working in `start` (nil: no project), one entry a name, in the order its rule ranks
    /// them. `nextTerm`: Next Term's own are offered (Settings › Editor › Agents offer to run parallel work in tabs).
    public static func entries(from start: String?, home: String, nextTerm: Bool, reader: Reader = Reader(program: nil)) -> [Entry] {
        let chain = start.map { projectFolders(from: $0, home: home) } ?? []
        let top = chain.last
        var project: [Copy] = []
        for folder in chain {
            let relative = folder == top ? "" : String(folder.dropFirst((top?.count ?? 0) + 1)) + "/"
            for kind in reader.order(reader.project) {
                project += read(folder + "/" + kind, scope: .project, kind: kind, place: relative + kind)
            }
        }
        var personal: [Copy] = []
        for kind in reader.order(reader.personal) {
            personal += read(home + "/" + kind, scope: .personal, kind: kind, place: "~/" + kind)
        }
        var own: [Copy] = []
        if nextTerm {
            own.append(Copy(name: BuiltInSkill.name, description: BuiltInSkill.description, scope: .nextTerm, folder: nil,
                            place: "Next Term", kind: nil))
        }
        let ranked = (reader.personalFirst ? personal + project : project + personal) + own
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

    /// Two copies are one folder (one reached through a link).
    static func sameFolder(_ a: Copy, _ b: Copy) -> Bool {
        guard let first = a.folder, let second = b.folder else { return false }
        return canonicalPath(first) == canonicalPath(second)
    }

    /// One skill as an agent gets it: its entry, its SKILL.md, and the other files in its folder (relative paths, at
    /// most 100, none from .git or node_modules). `scope`: that scope's copy rather than the one the rule picks. Nil
    /// when there is none.
    public static func skill(_ name: String, scope: Scope? = nil, from start: String?, home: String, nextTerm: Bool,
                             reader: Reader = Reader(program: nil)) -> (entry: Entry, copy: Copy, text: String, files: [String])? {
        guard let entry = entries(from: start, home: home, nextTerm: nextTerm, reader: reader).first(where: { $0.name == name }),
              let copy = ([entry.copy] + entry.others).first(where: { scope == nil || $0.scope == scope }) else { return nil }
        guard let folder = copy.folder else { return (entry, copy, BuiltInSkill.text, []) }
        guard let file = skillFile(in: folder), let text = readText(file) else { return nil }
        return (entry, copy, text, otherFiles(in: folder))
    }

    /// The skills in one folder: each folder in it holding SKILL.md (a link to one counts, as agents follow them).
    static func read(_ root: String, scope: Scope, kind: String, place: String) -> [Copy] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        return names.prefix(500).compactMap { name in
            let folder = root + "/" + name
            guard let file = skillFile(in: folder), let text = readText(file) else { return nil }
            let description = SkillFrontMatter.parse(text)?.description ?? ""
            return Copy(name: name, description: description, scope: scope, folder: folder, place: place, kind: kind)
        }
    }

    static func skillFile(in folder: String) -> String? {
        ["SKILL.md", "skill.md"].map { folder + "/" + $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// A SKILL.md's text, when it is a readable file under 256 KB.
    static func readText(_ file: String) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? Int, size <= 256 * 1024,
              let data = FileManager.default.contents(atPath: file) else { return nil }
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
