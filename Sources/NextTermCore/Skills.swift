import CryptoKit
import Foundation

// The Skills library's model of what is on the Mac: which agent loads which skill, from where, and
// which copies have drifted apart. Pure file reading here; the app does the writing (see SkillsStore).
//
// A skill is a folder holding SKILL.md (Agent Skills standard). Where agents look (as of
// October 2026):
// - Claude Code reads ~/.claude/skills only. It does not read ~/.agents/skills.
// - Codex reads ~/.agents/skills and its older ~/.codex/skills; a name in both is listed twice.
// - Command Code reads ~/.commandcode/skills and ~/.agents/skills; its own folder wins a name, and it
//   skips a skill whose `name` differs from its folder name.
// So one real copy in ~/.agents/skills plus a link in ~/.claude/skills reaches all three.

/// The agents the library manages skills for.
public enum SkillAgent: String, CaseIterable, Codable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case commandCode = "command-code"

    public var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .commandCode: return "Command Code"
        }
    }

    /// How a skill is used by name in that agent.
    public func trigger(_ name: String) -> String {
        switch self {
        case .claudeCode, .commandCode: return "/\(name)"
        case .codex: return "$\(name)"
        }
    }

    /// Whether a new skill is seen in a session that is already open.
    public var reload: String {
        switch self {
        case .claudeCode: return "seen at once"
        case .codex: return "seen at once (or in a new session)"
        case .commandCode: return "seen in a new session"
        }
    }
}

/// A folder skills live in.
public struct SkillRoot: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// ~/.agents/skills: the shared folder (Codex and Command Code read it; Claude Code through links).
        case shared
        /// ~/.claude/skills
        case claude
        /// ~/.codex/skills (Codex's older folder, still read)
        case codex
        /// ~/.commandcode/skills
        case commandCode
    }

    public let kind: Kind
    public let path: String
    /// Where the folder really is: some people link a whole folder to another (`~/.claude/skills` ->
    /// `~/.agents/skills`), and then both names are one folder.
    public let realPath: String
    /// Agents that read this folder through another folder linked to it.
    public var alsoReadBy: [SkillAgent] = []

    public init(kind: Kind, path: String) {
        self.kind = kind
        self.path = path
        realPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Agents that read this folder.
    public var readers: [SkillAgent] {
        var agents: [SkillAgent]
        switch kind {
        case .shared: agents = [.codex, .commandCode]
        case .claude: agents = [.claudeCode]
        case .codex: agents = [.codex]
        case .commandCode: agents = [.commandCode]
        }
        return agents + alsoReadBy.filter { !agents.contains($0) }
    }

    public var title: String {
        switch kind {
        case .shared: return "~/.agents/skills"
        case .claude: return "~/.claude/skills"
        case .codex: return "~/.codex/skills"
        case .commandCode: return "~/.commandcode/skills"
        }
    }

    /// The personal skill folders, in a home folder.
    public static func personal(home: String) -> [SkillRoot] {
        func at(_ path: String) -> String { (home as NSString).appendingPathComponent(path) }
        return [
            SkillRoot(kind: .shared, path: at(".agents/skills")),
            SkillRoot(kind: .claude, path: at(".claude/skills")),
            SkillRoot(kind: .codex, path: at(".codex/skills")),
            SkillRoot(kind: .commandCode, path: at(".commandcode/skills")),
        ]
    }
}

/// What a SKILL.md says about itself (its YAML front matter, the fields that matter here).
public struct SkillFrontMatter: Equatable, Sendable {
    public var name: String?
    public var description: String?
    public var license: String?
    /// Tools the skill pre-approves while it runs (Claude Code, Command Code).
    public var allowedTools: String?
    /// The standard's `compatibility` field (at most 500 characters).
    public var compatibility: String?
    /// `user-invocable: false`: Claude Code offers no /name for it; the agent uses it on its own.
    public var userInvocable: Bool?
    /// Every top-level key, for the review sheet's "what it may do".
    public var keys: [String] = []

    public init() {}

    /// Reads the front matter: the block between the first two `---` lines. Handles `key: value`,
    /// quoted values and block scalars (`|`, `>`), which is what skills use; not a full YAML parser.
    public static func parse(_ text: String) -> SkillFrontMatter? {
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        let block = Array(lines[..<end])
        var result = SkillFrontMatter()
        var index = 0
        while index < block.count {
            let line = block[index]
            index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.hasPrefix("#") else { continue }
            result.keys.append(key)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("|") || value.hasPrefix(">") {
                // A block scalar: the indented lines that follow.
                let folded = value.hasPrefix(">")
                var parts: [String] = []
                while index < block.count, block[index].isEmpty || block[index].hasPrefix(" ") || block[index].hasPrefix("\t") {
                    parts.append(block[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                while parts.last?.isEmpty == true { parts.removeLast() }
                value = parts.joined(separator: folded ? " " : "\n")
            } else if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
                if q == "\"" { value = value.replacingOccurrences(of: "\\\"", with: "\"") } else { value = value.replacingOccurrences(of: "''", with: "'") }
            } else if value.isEmpty {
                // A nested map or list (metadata:, allowed-tools as a list): keep the key, skip its lines.
                var items: [String] = []
                while index < block.count, block[index].isEmpty || block[index].hasPrefix(" ") || block[index].hasPrefix("\t") {
                    let item = block[index].trimmingCharacters(in: .whitespaces)
                    if item.hasPrefix("- ") { items.append(String(item.dropFirst(2))) }
                    index += 1
                }
                if key == "allowed-tools", !items.isEmpty { result.allowedTools = items.joined(separator: " ") }
                continue
            }
            switch key {
            case "name": result.name = value
            case "description": result.description = value
            case "license": result.license = value
            case "allowed-tools": result.allowedTools = value
            case "compatibility": result.compatibility = value
            case "user-invocable": result.userInvocable = value.lowercased() != "false"
            default: break
            }
        }
        return result
    }

    /// Names Claude Code keeps for itself: `synced` is the folder claude.ai's skills arrive in.
    public static let reservedNames: Set<String> = ["synced", "anthropic-skills"]

    /// Why a skill breaks the shared standard (agentskills.io), or nil: `name` must be 1–64 lowercase
    /// letters, digits and hyphens (ASCII only, so no look-alike letters), without a leading, trailing
    /// or double hyphen, and equal the folder's name; a description of 1–1024 characters; compatibility
    /// of at most 500. Command Code skips such skills without saying so.
    public func problem(folder: String) -> String? {
        guard let name, !name.isEmpty else { return "SKILL.md has no name." }
        if name != folder { return "Its name (“\(name)”) differs from its folder (“\(folder)”)." }
        if let problem = Self.nameProblem(name) { return problem }
        guard let description, !description.isEmpty else { return "SKILL.md has no description." }
        if description.count > 1024 { return "Its description is longer than 1,024 characters." }
        if let compatibility, compatibility.count > 500 { return "Its compatibility field is longer than 500 characters." }
        return nil
    }

    /// Why a name can't be a skill's folder name, or nil.
    public static func nameProblem(_ name: String) -> String? {
        if name.isEmpty || name.count > 64 { return "A name must be 1 to 64 characters long." }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        if !name.unicodeScalars.allSatisfy(allowed.contains) || name.hasPrefix("-") || name.hasSuffix("-") || name.contains("--") {
            return "Its name may only hold lowercase letters, digits and single hyphens."
        }
        if reservedNames.contains(name) { return "“\(name)” is a name Claude Code keeps for itself." }
        return nil
    }
}

/// One folder (or link to one) that holds a skill.
public struct SkillCopy: Equatable, Sendable {
    public let root: SkillRoot
    /// The entry in the root: <root>/<name>.
    public let path: String
    /// Where its files really are (the link's target for a link).
    public let realPath: String
    public let isLink: Bool
    /// A link whose target is gone, or a folder without SKILL.md.
    public let broken: Bool
    public let frontMatter: SkillFrontMatter?
    /// SHA-256 over the folder's files (see SkillHash.folder), computed only when a name has more than
    /// one copy to compare; nil otherwise, and when broken.
    public var contentHash: String?
    /// The plugin the folder also is (.claude-plugin/plugin.json): Codex then lists it as plugin:name.
    public var pluginName: String?
    /// The folder is a git clone (has .git): its history is part of what Unify would move.
    public var hasGit: Bool { FileManager.default.fileExists(atPath: (realPath as NSString).appendingPathComponent(".git")) }
    /// The folder holds files that run: scripts or executables (read when asked).
    public var hasScripts: Bool { !broken && SkillHash.hasScripts(realPath) }

    public var name: String { (path as NSString).lastPathComponent }

    /// How the skill is used by name in an agent; nil: the agent uses it on its own (no command).
    public func trigger(for agent: SkillAgent) -> String? {
        switch agent {
        case .claudeCode: return frontMatter?.userInvocable == false ? nil : agent.trigger(name)
        case .codex: return pluginName.map { "$\($0):\(name)" } ?? agent.trigger(name)
        case .commandCode: return agent.trigger(name)
        }
    }
}

/// Content hashes for skill folders.
public enum SkillHash {
    /// What does not make two hand-made copies of a skill different: caches, Finder's notes, installed
    /// packages. (Only for comparing local copies: what was installed is checked with GitHash, and
    /// Undo with SkillChanges.fingerprint, which leave nothing out.)
    static let ignored: Set<String> = [".DS_Store", "__pycache__", ".git", "node_modules", ".venv"]

    /// SHA-256 over every file's path relative to the folder, its executable bit and its content's
    /// SHA-256, in path order. Two folders with the same files hash the same wherever they are. Files
    /// are read in pieces, so a large one never sits in memory whole. A folder that is a git clone
    /// hashes differently from the same files without history, so the two never count as identical.
    public static func folder(_ path: String) -> String? {
        let manager = FileManager.default
        guard let walker = manager.enumerator(atPath: path) else { return nil }
        var entries: [(String, Bool, String)] = []
        while let relative = walker.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            if ignored.contains(name) {
                if walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { walker.skipDescendants() }
                continue
            }
            let type = walker.fileAttributes?[.type] as? FileAttributeType
            let full = (path as NSString).appendingPathComponent(relative)
            if type == .typeSymbolicLink {
                let target = (try? manager.destinationOfSymbolicLink(atPath: full)) ?? ""
                entries.append((relative, false, "link:" + target))
                continue
            }
            guard type == .typeRegular else { continue }
            let mode = (walker.fileAttributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
            entries.append((relative, mode & 0o111 != 0, fileDigest(full) ?? "unreadable"))
        }
        var hasher = SHA256()
        if let state = gitState(path) { hasher.update(data: Data(("git\0" + state + "\0").utf8)) }
        for (relative, executable, digest) in entries.sorted(by: { $0.0 < $1.0 }) {
            hasher.update(data: Data("\(relative)\0\(executable ? 1 : 0)\0\(digest)\0".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// What defines a clone's history: HEAD, packed refs and every ref (a worktree's .git file instead),
    /// so two clones of the same files at different commits or branches never count as identical.
    static func gitState(_ path: String) -> String? {
        let git = (path as NSString).appendingPathComponent(".git")
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git, isDirectory: &isFolder) else { return nil }
        guard isFolder.boolValue else { return "file:" + (fileDigest(git) ?? "unreadable") }
        var lines: [String] = []
        for name in ["HEAD", "packed-refs"] {
            if let digest = fileDigest((git as NSString).appendingPathComponent(name)) { lines.append(name + "=" + digest) }
        }
        let refs = (git as NSString).appendingPathComponent("refs")
        let walker = FileManager.default.enumerator(atPath: refs)
        while let relative = walker?.nextObject() as? String {
            let full = (refs as NSString).appendingPathComponent(relative)
            var folder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &folder), !folder.boolValue else { continue }
            lines.append("refs/" + relative + "=" + (fileDigest(full) ?? "unreadable"))
        }
        return lines.sorted().joined(separator: "\n")
    }

    /// SHA-256 of a file's content, read 1 MB at a time; nil when it can't be read.
    public static func fileDigest(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // nil (or empty) is the end of the file; a throw is a read that failed.
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a folder holds files that run: a script extension, a shebang, or an executable bit.
    public static func hasScripts(_ path: String) -> Bool {
        let manager = FileManager.default
        guard let walker = manager.enumerator(atPath: path) else { return false }
        let scriptExtensions: Set<String> = ["sh", "bash", "zsh", "py", "js", "mjs", "cjs", "ts", "rb", "pl", "php", "ps1", "command"]
        while let relative = walker.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            if ignored.contains(name) {
                if walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { walker.skipDescendants() }
                continue
            }
            guard walker.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
            if scriptExtensions.contains((name as NSString).pathExtension.lowercased()) { return true }
            let mode = (walker.fileAttributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
            if mode & 0o111 != 0 { return true }
        }
        return false
    }
}

/// Every personal skill on the Mac, grouped by name, with what each agent loads.
public struct SkillInventory: Sendable {
    public let home: String
    /// The personal folders, each real folder once: a folder linked to another one is left out, and the
    /// agents reading it are added to the other's readers.
    public let roots: [SkillRoot]
    public let rows: [SkillRow]

    public func root(_ kind: SkillRoot.Kind) -> SkillRoot? { roots.first { $0.kind == kind } }

    /// Whether a path is inside one of the personal skill folders (rather than, say, the developer's own
    /// repository that a skill links to).
    public func isInsideRoots(_ path: String) -> Bool {
        roots.contains { path.hasPrefix($0.realPath + "/") }
    }

    /// Reads the personal skill folders under `home`, and each agent's own on/off switches. Never writes.
    public static func scan(home: String) -> SkillInventory {
        var roots: [SkillRoot] = []
        for root in SkillRoot.personal(home: home) {
            if let index = roots.firstIndex(where: { $0.realPath == root.realPath }) {
                roots[index].alsoReadBy += root.readers
            } else {
                roots.append(root)
            }
        }
        let switches = SkillSwitches.read(home: home)
        var copies: [String: [SkillCopy]] = [:]
        for root in roots {
            for copy in scan(root) { copies[copy.name, default: []].append(copy) }
        }
        let rows = copies.map { name, list -> SkillRow in
            var sorted = list.sorted { $0.root.kind.order < $1.root.kind.order }
            // Content is compared only where there is something to compare: two or more real folders.
            if Set(sorted.filter { !$0.broken }.map(\.realPath)).count > 1 {
                for index in sorted.indices where !sorted[index].broken { sorted[index].contentHash = SkillHash.folder(sorted[index].realPath) }
            }
            return SkillRow(name: name, copies: sorted, offKeys: switches.offKeys(name: name, copies: sorted))
        }
        return SkillInventory(home: home, roots: roots, rows: rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    /// The skills in one folder. Folders Next Term must never treat as personal skills are left out:
    /// claude.ai's synced skills (`synced`), Codex's own (`.system`), and hidden folders.
    static func scan(_ root: SkillRoot) -> [SkillCopy] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.sorted().compactMap { name -> SkillCopy? in
            if name.hasPrefix(".") { return nil }
            if root.kind == .claude && name == "synced" { return nil }
            let path = (root.path as NSString).appendingPathComponent(name)
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            let isLink = (info.st_mode & S_IFMT) == S_IFLNK
            let inRealRoot = (root.realPath as NSString).appendingPathComponent(name)
            let real = isLink ? URL(fileURLWithPath: inRealRoot).resolvingSymlinksInPath().path : inRealRoot
            var isFolder: ObjCBool = false
            let exists = manager.fileExists(atPath: real, isDirectory: &isFolder)
            if !isLink && !(exists && isFolder.boolValue) { return nil } // a stray file
            let skillFile = ["SKILL.md", "skill.md"].map { (real as NSString).appendingPathComponent($0) }
                .first { manager.fileExists(atPath: $0) }
            guard exists, isFolder.boolValue, let skillFile else {
                return SkillCopy(root: root, path: path, realPath: real, isLink: isLink, broken: true, frontMatter: nil, contentHash: nil)
            }
            let text = (try? String(contentsOfFile: skillFile, encoding: .utf8)) ?? ""
            let plugin = (real as NSString).appendingPathComponent(".claude-plugin/plugin.json")
            let pluginName = FileManager.default.contents(atPath: plugin)
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["name"] as? String
            return SkillCopy(root: root, path: path, realPath: real, isLink: isLink, broken: false,
                             frontMatter: SkillFrontMatter.parse(text), contentHash: nil, pluginName: pluginName)
        }
    }
}

extension SkillRoot.Kind {
    /// Shared first, then Claude Code, Codex, Command Code.
    public var order: Int {
        switch self {
        case .shared: return 0
        case .claude: return 1
        case .codex: return 2
        case .commandCode: return 3
        }
    }
}

/// One skill name and every copy of it.
public struct SkillRow: Equatable, Sendable {
    public let name: String
    public let copies: [SkillCopy]
    /// The keys in each agent's own settings that switch this skill off: names in Claude Code's
    /// skillOverrides, paths or names in Codex's [[skills.config]] with enabled = false.
    public var offKeys: [SkillAgent: Set<String>] = [:]

    /// Agents whose own settings switch this skill off.
    public var off: Set<SkillAgent> { Set(offKeys.filter { !$0.value.isEmpty }.keys) }

    public enum Health: String, Sendable {
        /// One copy (links to it count as the same copy), loaded the same way by every agent that has it.
        case ok
        /// Several copies with the same content.
        case duplicated
        /// Several copies whose content differs.
        case drifted
        /// A link to nothing, or a folder without SKILL.md.
        case broken
    }

    /// What one agent loads for this name.
    public struct Load: Equatable, Sendable {
        /// The copy the agent uses (nil: it has none, or skips the one it has).
        public let used: SkillCopy?
        /// Copies the agent also has but ignores for this name (shadowed), or lists a second time (Codex).
        public let others: [SkillCopy]
        /// Why the agent skips its copy (Command Code's strict name check), or nil.
        public let skippedBecause: String?
        /// The agent's own settings switch the skill off: it has a copy but does not load it.
        public var switchedOff = false
    }

    public func load(for agent: SkillAgent) -> Load {
        var load = rawLoad(for: agent)
        if off.contains(agent), load.used != nil { load.switchedOff = true }
        return load
    }

    func rawLoad(for agent: SkillAgent) -> Load {
        let readable = copies.filter { !$0.broken && $0.root.readers.contains(agent) }
        switch agent {
        case .claudeCode:
            // Its own folder, or the shared one when ~/.claude/skills is a link to it.
            let used = readable.first { $0.root.kind == .claude } ?? readable.first { $0.root.kind == .shared }
            return Load(used: used, others: [], skippedBecause: nil)
        case .codex:
            // Codex keeps both: the shared copy and the one in ~/.codex/skills are each listed.
            let shared = readable.first { $0.root.kind == .shared }
            let own = readable.first { $0.root.kind == .codex }
            var others: [SkillCopy] = []
            if let shared, let own, !sameContent(shared, own) { others = [own] }
            return Load(used: shared ?? own, others: others, skippedBecause: nil)
        case .commandCode:
            // Its own folder wins; a name that breaks the standard is skipped.
            let own = readable.first { $0.root.kind == .commandCode }
            let shared = readable.first { $0.root.kind == .shared }
            guard let used = own ?? shared else { return Load(used: nil, others: [], skippedBecause: nil) }
            let shadowed = own != nil && shared != nil && !sameFolder(own!, shared!) ? [shared!] : []
            if let problem = used.frontMatter?.problem(folder: name) {
                return Load(used: nil, others: [used] + shadowed, skippedBecause: problem)
            }
            return Load(used: used, others: shadowed, skippedBecause: nil)
        }
    }

    /// The distinct copies: links to one folder, and the folder itself, count once.
    public var distinctCopies: [SkillCopy] {
        var seen = Set<String>()
        return copies.filter { !$0.broken && seen.insert($0.realPath).inserted }
    }

    public var health: Health {
        if copies.contains(where: \.broken) { return .broken }
        let distinct = distinctCopies
        if distinct.count <= 1 { return .ok }
        return Set(distinct.compactMap(\.contentHash)).count > 1 ? .drifted : .duplicated
    }

    /// Why a copy can't be the one Unify keeps (it would break the standard, so Command Code would skip
    /// the result), or nil.
    public func cannotWin(_ copy: SkillCopy) -> String? {
        if copy.broken { return "It is broken." }
        guard let front = copy.frontMatter else { return "Its SKILL.md has no front matter." }
        return front.problem(folder: name)
    }

    /// Already the library's shape: one real copy in the shared folder, and Claude Code (if it has the
    /// skill) through a link to it; nothing in ~/.codex/skills or ~/.commandcode/skills.
    public var isUnified: Bool {
        // The shared entry is a real folder, or a link to the developer's own folder elsewhere.
        guard let shared = copies.first(where: { $0.root.kind == .shared && !$0.broken }) else { return false }
        return copies.allSatisfy { copy in
            switch copy.root.kind {
            case .shared: return copy == shared
            case .claude: return copy.isLink && copy.realPath == shared.realPath
            case .codex, .commandCode: return false
            }
        }
    }

    func sameFolder(_ a: SkillCopy, _ b: SkillCopy) -> Bool { a.realPath == b.realPath }
    func sameContent(_ a: SkillCopy, _ b: SkillCopy) -> Bool { a.realPath == b.realPath || (a.contentHash != nil && a.contentHash == b.contentHash) }
}

// MARK: - Unify

/// One step on disk. Every step can be undone: Trash moves go back, created things are removed.
public enum SkillStep: Equatable, Sendable {
    /// Move to the Trash (a folder, or a link: the link itself, never what it points to).
    case trash(String)
    /// Copy a folder's files (following its own entries, never links that leave it) to a new path.
    case copy(from: String, to: String)
    /// Make a relative symlink at `at` pointing to `to`.
    case link(at: String, to: String)
    /// Move a folder Next Term made (a staging copy) into place.
    case move(from: String, to: String)
    /// Set (or, for nil, remove) one skill's entry in the lock file of `npx skills`, read and written
    /// when the step runs, so entries added meanwhile stay.
    case lockEntry(path: String, name: String, entry: SkillLock.Entry?)
    /// Set (or remove) one skill in Next Term's own record of installs, the same way.
    case recordEntry(path: String, name: String, record: SkillRecord?)

    public var summary: String {
        switch self {
        case .trash(let path): return "Move \(Self.short(path)) to the Trash"
        case .copy(let from, let to): return "Copy \(Self.short(from)) to \(Self.short(to))"
        case .link(let at, let to): return "Link \(Self.short(at)) to \(Self.short(to))"
        case .move(let from, let to): return "Move \(Self.short(from)) to \(Self.short(to))"
        case .lockEntry(let path, let name, let entry):
            return entry == nil ? "Remove \(name) from \(Self.short(path))" : "Record \(name) in \(Self.short(path))"
        case .recordEntry(_, let name, let record):
            return record == nil ? "Forget that Next Term installed \(name)" : "Remember where \(name) came from"
        }
    }

    public static func short(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

public enum SkillUnify {
    /// The steps that leave one copy of `row` in the shared folder, with `winner`'s content, linked for
    /// Claude Code when Claude Code had the skill, and nothing in ~/.codex/skills or ~/.commandcode/skills.
    /// `winner` must be one of the row's copies, and one `row.cannotWin` accepts. Steps are in a safe
    /// order: the new shared copy exists before anything goes.
    ///
    /// Links: removing one removes the link only, never what it points to. A winner that links to a
    /// folder outside the agent folders (the developer's own repository) stays where it is: the shared
    /// entry becomes a link to it. Folders linked as a whole (`~/.claude/skills` -> `~/.agents/skills`)
    /// are one folder (SkillInventory.roots), so nothing in them is moved or linked to itself.
    /// Where Unify stages a copy: Next Term's own folder, never an agent's (a leftover there would load as
    /// a skill).
    public static func stagingFolder(home: String, name: String) -> String {
        (home as NSString).appendingPathComponent("Library/Application Support/Next Term/skill-staging/\(name)-\(UUID().uuidString.prefix(8))")
    }

    public static func plan(_ row: SkillRow, winner: SkillCopy, in inventory: SkillInventory, staging: String? = nil) -> [SkillStep] {
        guard let sharedRoot = inventory.root(.shared) else { return [] }
        let shared = (sharedRoot.path as NSString).appendingPathComponent(row.name)
        var steps: [SkillStep] = []
        let existingShared = row.copies.first { $0.root.kind == .shared }
        let outside = { (copy: SkillCopy) in copy.isLink && !inventory.isInsideRoots(copy.realPath) }
        var winnerIsShared = false
        if let existingShared, existingShared.realPath == winner.realPath {
            winnerIsShared = !existingShared.isLink || outside(existingShared)
        }
        if !winnerIsShared {
            if outside(winner) {
                if existingShared != nil { steps.append(.trash(shared)) }
                steps.append(.link(at: shared, to: winner.realPath))
            } else {
                // The winner's files are copied aside first, then the older shared copy goes, then the
                // copy moves into place.
                let staging = staging ?? stagingFolder(home: inventory.home, name: row.name)
                steps.append(.copy(from: winner.realPath, to: staging))
                if existingShared != nil { steps.append(.trash(shared)) }
                steps.append(.move(from: staging, to: shared))
            }
        }
        // Claude Code (when it had the skill, and its folder is not the shared one): a link to the shared copy.
        if let claudeRoot = inventory.root(.claude), let claudeCopy = row.copies.first(where: { $0.root.kind == .claude }) {
            let claude = (claudeRoot.path as NSString).appendingPathComponent(row.name)
            let finalReal = winnerIsShared ? existingShared?.realPath : nil
            let alreadyLinked = claudeCopy.isLink && finalReal != nil && claudeCopy.realPath == finalReal
            if !alreadyLinked {
                steps.append(.trash(claude))
                steps.append(.link(at: claude, to: shared))
            }
        }
        // Codex and Command Code read the shared folder: their own copies (or links) go.
        for copy in row.copies where copy.root.kind == .codex || copy.root.kind == .commandCode {
            steps.append(.trash(copy.path))
        }
        return steps
    }

    /// Agents that load the skill after Unify but not before: whoever reads the shared folder, and
    /// whoever had it switched off by the strict name check. The sheet names them (scripts included).
    public static func gained(_ row: SkillRow, in inventory: SkillInventory) -> [SkillAgent] {
        var after = Set(inventory.root(.shared)?.readers ?? [])
        if row.copies.contains(where: { $0.root.kind == .claude }) { after.insert(.claudeCode) }
        return SkillAgent.allCases.filter { after.contains($0) && row.load(for: $0).used == nil }
    }

    /// Agents whose own off switch would stop matching after Unify, so the skill would come back on:
    /// Claude Code keys its switch by the skill's name (Unify keeps only a copy named like its folder),
    /// Codex by the copy's path (Unify moves it to the shared folder).
    public static func switchesLost(_ row: SkillRow, in inventory: SkillInventory) -> [SkillAgent] {
        guard let sharedRoot = inventory.root(.shared) else { return [] }
        let shared = (sharedRoot.path as NSString).appendingPathComponent(row.name)
        let realShared = (sharedRoot.realPath as NSString).appendingPathComponent(row.name)
        var after: [SkillAgent: Set<String>] = [.claudeCode: [row.name]]
        after[.codex] = [row.name, shared, realShared, shared + "/SKILL.md", realShared + "/SKILL.md"]
        return SkillAgent.allCases.filter { agent in
            guard let keys = row.offKeys[agent], !keys.isEmpty else { return false }
            return keys.isDisjoint(with: after[agent] ?? [])
        }
    }

    /// The relative link target from `at` to `to` (`../../.agents/skills/name`), as `npx skills` makes it.
    public static func relativeTarget(at: String, to: String) -> String {
        let from = (at as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        let target = to.split(separator: "/").map(String.init)
        var common = 0
        while common < from.count, common < target.count, from[common] == target[common] { common += 1 }
        let ups = Array(repeating: "..", count: from.count - common)
        return (ups + target[common...]).joined(separator: "/")
    }
}

// MARK: - Each agent's own switches

/// Skills an agent's own settings switch off: Claude Code's `skillOverrides` in ~/.claude/settings.json
/// (keyed by the skill's name, "off"), and Codex's `[[skills.config]]` tables in ~/.codex/config.toml
/// (a `path` or `name` with `enabled = false`). Command Code's store is not read yet.
public struct SkillSwitches: Sendable {
    public var claudeOff: Set<String> = []
    /// Paths (a skill folder or its SKILL.md) and names Codex has switched off.
    public var codexOff: Set<String> = []

    public init() {}

    public static func read(home: String) -> SkillSwitches {
        var switches = SkillSwitches()
        let settings = (home as NSString).appendingPathComponent(".claude/settings.json")
        if let data = FileManager.default.contents(atPath: settings),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let overrides = json["skillOverrides"] as? [String: Any] {
            for (name, value) in overrides where (value as? String)?.lowercased() == "off" || (value as? Bool) == false {
                switches.claudeOff.insert(name)
            }
        }
        let config = (home as NSString).appendingPathComponent(".codex/config.toml")
        if let text = try? String(contentsOfFile: config, encoding: .utf8) {
            switches.codexOff = codexOff(text)
        }
        return switches
    }

    /// The `path` and `name` of every [[skills.config]] table with `enabled = false`.
    static func codexOff(_ text: String) -> Set<String> {
        var result = Set<String>()
        var inTable = false
        var keys: [String: String] = [:]
        func finish() {
            if inTable, keys["enabled"] == "false" {
                if let path = keys["path"] { result.insert(path) }
                if let name = keys["name"] { result.insert(name) }
            }
            keys = [:]
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                finish()
                inTable = line.replacingOccurrences(of: " ", with: "") == "[[skills.config]]"
                continue
            }
            guard inTable, let equals = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"" || value.first == "'", let close = value.dropFirst().firstIndex(of: value.first!) {
                value = String(value[value.index(after: value.startIndex)..<close])
            } else if let hash = value.firstIndex(of: "#") {
                value = value[..<hash].trimmingCharacters(in: .whitespaces)
            }
            keys[key] = value
        }
        finish()
        return result
    }

    /// The keys that switch off a skill with these copies, per agent.
    public func offKeys(name: String, copies: [SkillCopy]) -> [SkillAgent: Set<String>] {
        var result: [SkillAgent: Set<String>] = [:]
        let names = Set([name] + copies.compactMap { $0.frontMatter?.name })
        let claude = claudeOff.intersection(names)
        if !claude.isEmpty { result[.claudeCode] = claude }
        var codexKeys = names
        for copy in copies {
            for folder in [copy.path, copy.realPath] {
                codexKeys.insert(folder)
                codexKeys.insert((folder as NSString).appendingPathComponent("SKILL.md"))
            }
        }
        let codex = codexOff.intersection(codexKeys)
        if !codex.isEmpty { result[.codex] = codex }
        return result
    }
}
