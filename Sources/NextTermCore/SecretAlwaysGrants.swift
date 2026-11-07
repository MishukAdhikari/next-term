import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// "Always in <project>", "Always in <worktree>" and "Always in this folder": approvals that outlast Next Term, the rules
// alone. A grant names who (an agent in one of Next Term's own tabs, by its executable's file and signature, and its
// script under an interpreter: its kind is only the label), which keys (each by name, ENVNAME and a digest of its sealed
// value, so a key changed, renamed or added again asks again), what for (a digest of the whole definition: the resolved
// executable and its file, the arguments, the keys, the run folder and the files that change what it does; or a hub
// server's URL, header templates and list) and where (a folder whose path and inode it keeps). It is kept in its own
// sealed file (SecretAlwaysFile.swift) and holds no value. Anything different asks again; nothing here is the requester's
// word but the folder, which only ever narrows where a grant holds.

/// A file as an Always grant binds it: device, inode, size, and the two times the kernel keeps. `changed` (ctime) moves
/// with every write to the file and its every metadata change, and no program can set it back, so a file rewritten in
/// place with its old size and modification time still reads as another.
public struct SecretFileStamp: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    /// Nanoseconds since 1970.
    public let modified: Int64
    public let changed: Int64

    public init(device: UInt64, inode: UInt64, size: Int64, modified: Int64, changed: Int64) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modified = modified
        self.changed = changed
    }

    /// The stamp of the file at `path`, links followed; nil when there is none.
    public static func of(_ path: String) -> SecretFileStamp? {
        var info = stat()
        guard !path.isEmpty, stat(path, &info) == 0 else { return nil }
        func nanos(_ time: timespec) -> Int64 { Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec) }
        return SecretFileStamp(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino), size: Int64(info.st_size),
                               modified: nanos(info.st_mtimespec), changed: nanos(info.st_ctimespec))
    }
}

/// Who an Always grant answers: the agent's executable (resolved, with its stamp), its code-signing Team ID when the
/// running code is validly signed, and under an interpreter the script it runs and that script's SHA-256. An update of
/// the agent is another identity, so it asks again.
public struct SecretAgentIdentity: Codable, Hashable, Sendable {
    public var path: String
    public var stamp: SecretFileStamp
    public var team: String?
    public var script: String?
    public var scriptDigest: String?

    public init(path: String, stamp: SecretFileStamp, team: String? = nil, script: String? = nil, scriptDigest: String? = nil) {
        self.path = path
        self.stamp = stamp
        self.team = team
        self.script = script
        self.scriptDigest = scriptDigest
    }
}

/// Where an Always grant holds: a folder (the project's root, a linked worktree's root, or the run folder alone), by its
/// canonical path and the device and inode it had, so a folder moved, or deleted and made again under its path, asks
/// again.
public struct SecretAlwaysScope: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The repository's main checkout and every linked worktree of it (as git itself says), or the open project
        /// outside git.
        case project
        /// One linked worktree.
        case worktree
        /// The run folder alone.
        case folder
    }

    public var kind: Kind
    public var path: String
    public var device: UInt64
    public var inode: UInt64
    /// Whether the volume tells names apart by case: APFS as most Macs have it does not.
    public var caseSensitive: Bool

    public init(kind: Kind, path: String, device: UInt64, inode: UInt64, caseSensitive: Bool) {
        self.kind = kind
        self.path = path
        self.device = device
        self.inode = inode
        self.caseSensitive = caseSensitive
    }

    /// The scope of `kind` at `path` (canonical) as it is now: nil when nothing is there.
    public static func at(_ path: String, kind: Kind) -> SecretAlwaysScope? {
        var info = stat()
        guard path.hasPrefix("/"), stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return SecretAlwaysScope(kind: kind, path: path, device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
                                 caseSensitive: isCaseSensitive(path))
    }

    /// Whether the volume holding `path` tells names apart by case.
    public static func isCaseSensitive(_ path: String) -> Bool {
        let value = pathconf(path, _PC_CASE_SENSITIVE)
        return value == 1
    }

    /// Whether a request run in `folder` (canonical), whose repository's main checkout git says is `project`, is where it
    /// holds: the folder itself, or inside it by whole path components (`/a/app` never holds for `/a/app-evil`), and for a
    /// project also any linked worktree of it, wherever that is. The root must still be the folder it was (`identify`
    /// gives its device and inode now).
    public func covers(folder: String, project: String?, identify: (String) -> (device: UInt64, inode: UInt64)?) -> Bool {
        guard let now = identify(path), now.device == device, now.inode == inode else { return false }
        switch kind {
        case .folder: return Self.same(folder, path, caseSensitive: caseSensitive)
        case .worktree: return Self.contains(path, folder, caseSensitive: caseSensitive)
        case .project:
            if Self.contains(path, folder, caseSensitive: caseSensitive) { return true }
            return project.map { Self.same($0, path, caseSensitive: caseSensitive) } ?? false
        }
    }

    /// A folder's device and inode now, links followed.
    public static func identify(_ path: String) -> (device: UInt64, inode: UInt64)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return (UInt64(UInt32(bitPattern: info.st_dev)), UInt64(info.st_ino))
    }

    /// A path's components: absolute, with no `.`, `..` or empty ones, or nil for a path that isn't absolute or climbs
    /// out of the root.
    public static func components(_ path: String) -> [String]? {
        guard path.hasPrefix("/") else { return nil }
        var out: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            switch part {
            case ".": continue
            case "..":
                guard !out.isEmpty else { return nil }
                out.removeLast()
            default: out.append(part)
            }
        }
        return out
    }

    /// Whether `inner` is `root` or inside it, by whole components. The root `/` holds nothing: Always there would hold
    /// everywhere.
    public static func contains(_ root: String, _ inner: String, caseSensitive: Bool) -> Bool {
        guard let base = components(root), let path = components(inner), !base.isEmpty, path.count >= base.count else { return false }
        return zip(base, path).allSatisfy { equal($0, $1, caseSensitive: caseSensitive) }
    }

    public static func same(_ one: String, _ other: String, caseSensitive: Bool) -> Bool {
        guard let a = components(one), let b = components(other), !a.isEmpty, a.count == b.count else { return false }
        return zip(a, b).allSatisfy { equal($0, $1, caseSensitive: caseSensitive) }
    }

    static func equal(_ a: String, _ b: String, caseSensitive: Bool) -> Bool {
        caseSensitive ? a == b : a.compare(b, options: [.caseInsensitive]) == .orderedSame
    }
}

/// The way a request came.
public enum SecretAlwaysDoor: String, Codable, Sendable {
    /// `run_with_secrets`.
    case tool
    /// `nxtrm secret run`.
    case wrapper
    /// A hub server at a URL: Next Term sends the key itself, the agent never sees it.
    case hub
}

/// What a request runs or reaches, every part an Always grant binds: any change gives another digest, so it asks again.
public struct SecretAlwaysDefinition: Codable, Equatable, Sendable {
    public var door: SecretAlwaysDoor
    /// The command's words (run_with_secrets' simple command, a wrapper's argv after `--`); empty for a hub server.
    public var words: [String] = []
    /// The executable they resolve to, its stamp, and its Team ID when signed.
    public var executable: String?
    public var executableStamp: SecretFileStamp?
    public var executableTeam: String?
    /// NAME → ENVNAME.
    public var keys: [String: String]
    /// The run folder, canonical.
    public var folder: String = ""
    /// A digest of the `PATH` the command resolves with, when Next Term knows it.
    public var pathDigest: String?
    /// The variables the panel warns about, by name, with a digest of each value.
    public var warned: [String: String] = [:]
    /// Digests of the files that change what it does: `.env`, `.npmrc`, the git hooks.
    public var files: [String: String] = [:]
    /// A hub server: its URL, its header templates as written (never a filled value), its list and that list's digest.
    public var url: String?
    public var headers: [String: String] = [:]
    public var list: String?
    public var listDigest: String?

    public init(door: SecretAlwaysDoor, keys: [String: String]) {
        self.door = door
        self.keys = keys
    }

    /// SHA-256 of every part, as sorted JSON.
    public var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: Data("nextterm always definition/1\u{0}".utf8) + data).map { String(format: "%02x", $0) }.joined()
    }
}

/// One Always approval.
public struct SecretAlwaysGrant: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    /// The agent's kind, for the label alone ("Codex").
    public let agent: String
    public let identity: SecretAgentIdentity
    public let door: SecretAlwaysDoor
    /// NAME → ENVNAME.
    public let keys: [String: String]
    /// NAME → a digest of its sealed value when the grant was made (`SecretVault.Entry.valueMark`).
    public let marks: [String: String]
    /// `SecretAlwaysDefinition.digest`.
    public let definition: String
    /// What Settings shows: the command, or the server's name and URL.
    public let summary: String
    public let scope: SecretAlwaysScope
    public let made: Date
    public var lastUsed: Date?

    public init(id: String = UUID().uuidString.lowercased(), agent: String, identity: SecretAgentIdentity, door: SecretAlwaysDoor,
                keys: [String: String], marks: [String: String], definition: String, summary: String, scope: SecretAlwaysScope,
                made: Date = Date(), lastUsed: Date? = nil) {
        self.id = id
        self.agent = agent
        self.identity = identity
        self.door = door
        self.keys = keys
        self.marks = marks
        self.definition = definition
        self.summary = summary
        self.scope = scope
        self.made = SignInFile.whole(made)
        self.lastUsed = lastUsed.map(SignInFile.whole)
    }

    public var names: [String] { keys.keys.sorted() }

    /// Whether it answers `ask`: the same identity, door, keys and values, definition, from a folder it covers.
    public func answers(_ ask: SecretAlwaysAsk, identify: (String) -> (device: UInt64, inode: UInt64)? = SecretAlwaysScope.identify) -> Bool {
        guard !keys.isEmpty, ask.identity == identity, ask.door == door, ask.keys == keys, ask.marks == marks,
              ask.definition == definition else { return false }
        return scope.covers(folder: ask.folder, project: ask.project, identify: identify)
    }

    /// Whether `other` is this grant again: every fact the same but its id and dates.
    public func isSame(as other: SecretAlwaysGrant) -> Bool {
        identity == other.identity && door == other.door && keys == other.keys && marks == other.marks && definition == other.definition
            && scope == other.scope
    }
}

/// A request's facts, as a grant is matched against them. Made by the app from what the kernel and the files say.
public struct SecretAlwaysAsk: Equatable, Sendable {
    public var identity: SecretAgentIdentity
    public var door: SecretAlwaysDoor
    public var keys: [String: String]
    public var marks: [String: String]
    public var definition: String
    /// Where it runs (a hub server: the tab's folder), canonical, and the main checkout of its repository.
    public var folder: String
    public var project: String?

    public init(identity: SecretAgentIdentity, door: SecretAlwaysDoor, keys: [String: String], marks: [String: String],
                definition: String, folder: String, project: String? = nil) {
        self.identity = identity
        self.door = door
        self.keys = keys
        self.marks = marks
        self.definition = definition
        self.folder = folder
        self.project = project
    }
}

public enum SecretAlwaysGrants {
    /// The most kept: past it, the oldest go.
    public static let maxCount = 200

    public static func first(answering ask: SecretAlwaysAsk, in grants: [SecretAlwaysGrant],
                             identify: (String) -> (device: UInt64, inode: UInt64)? = SecretAlwaysScope.identify) -> SecretAlwaysGrant? {
        grants.first { $0.answers(ask, identify: identify) }
    }

    /// `grants` with `grant` added: the same one made earlier goes, and the oldest past `maxCount`.
    public static func adding(_ grant: SecretAlwaysGrant, to grants: [SecretAlwaysGrant]) -> [SecretAlwaysGrant] {
        var list = grants.filter { !$0.isSame(as: grant) && $0.id != grant.id }
        list.append(grant)
        if list.count > maxCount { list.removeFirst(list.count - maxCount) }
        return list
    }

    /// The grants still true of the vault `index`: each key there under its name, its value the one it was made with.
    /// The rest can never answer again (a key changed, renamed or deleted), so they go.
    public static func kept(_ grants: [SecretAlwaysGrant], in index: SecretVault.Index) -> [SecretAlwaysGrant] {
        grants.filter { grant in
            grant.marks.allSatisfy { name, mark in index.entry(named: name).map { !$0.isSignIns && $0.valueMark == mark } ?? false }
        }
    }

    /// The grants that hold `name`.
    public static func holding(_ name: String, in grants: [SecretAlwaysGrant]) -> [SecretAlwaysGrant] {
        grants.filter { $0.keys[name] != nil }
    }
}

// MARK: - where Always is offered

/// Whether Always is offered for a command, and if not, why, in a line the panel shows: "Always isn’t offered: …".
public enum SecretAlwaysRules {
    public static let lead = "Always isn\u{2019}t offered: "

    /// The facts about a command that decide it.
    public struct Command: Sendable {
        /// The words it runs (a wrapper's argv; run_with_secrets' one simple command, when it is one).
        public var words: [String]
        /// run_with_secrets' text uses the shell's own syntax: more than one command, a pipe, `$`, a redirection, a glob.
        public var usesShellSyntax = false
        /// The panel's warnings.
        public var warnings: [String] = []
        /// The executable the words resolve to (canonical), nil when Next Term couldn't find it.
        public var executable: String?
        /// The script an interpreter runs, canonical.
        public var script: String?
        /// The run folder's repository runs git hooks.
        public var hasHooks = false

        public init(words: [String], usesShellSyntax: Bool = false, warnings: [String] = [], executable: String? = nil,
                    script: String? = nil, hasHooks: Bool = false) {
            self.words = words
            self.usesShellSyntax = usesShellSyntax
            self.warnings = warnings
            self.executable = executable
            self.script = script
            self.hasHooks = hasHooks
        }
    }

    /// Runners whose own files say what runs, so the same words run other code tomorrow.
    static let fileRunners: [String: String] = [
        "make": "the Makefile", "gmake": "the Makefile", "just": "the justfile", "task": "the Taskfile", "rake": "the Rakefile",
        "gradle": "the build file", "gradlew": "the build file", "mvn": "the pom", "cargo": "Cargo.toml", "tox": "tox.ini",
        "nox": "the noxfile", "invoke": "tasks.py", "turbo": "turbo.json", "nx": "the workspace",
    ]
    /// Package managers whose `run` (and the like) runs a script package.json names.
    static let packageManagers: Set<String> = ["npm", "pnpm", "yarn", "bun"]
    static let packageScripts: Set<String> = ["run", "run-script", "exec", "test", "start", "x", "dlx"]
    /// Interpreters: what they run is a script and whatever it loads.
    public static let interpreters: Set<String> = [
        "node", "nodejs", "bun", "deno", "python", "python3", "ruby", "perl", "php", "lua", "Rscript", "osascript", "java", "tsx",
        "ts-node",
    ]

    /// Why Always isn't offered for `command`, or nil when it is. `scopes`: the folders a grant would hold in, and
    /// `writable`: whether this user (so any agent running as them) can change a folder or file.
    public static func refusal(_ command: Command, scopes: [String], writable: (String) -> Bool) -> String? {
        if command.usesShellSyntax {
            return lead + "the command uses the shell\u{2019}s own syntax, so what runs can change around it."
        }
        if let warning = command.warnings.first { return lead + short(warning) }
        let (program, rest) = SecretRun.program(of: command.words)
        if program.isEmpty { return lead + "Next Term couldn\u{2019}t tell what this command runs." }
        if let file = fileRunners[program] { return lead + "\(program) runs whatever \(file) says at the time." }
        if packageManagers.contains(program), let verb = rest.first(where: { !$0.hasPrefix("-") }),
           packageScripts.contains(verb) || program == "yarn" && !["add", "install"].contains(verb) {
            return lead + "\(program) \(verb) runs whatever package.json says at the time."
        }
        if program == "git", command.hasHooks { return lead + "this repository\u{2019}s git hooks run with the key." }
        if SecretRun.shells.contains(program) { return lead + "this command starts a shell." }
        guard let executable = command.executable else { return lead + "Next Term couldn\u{2019}t find \(program)." }
        let name = (executable as NSString).lastPathComponent
        if isChangeable(executable, scopes: scopes, writable: writable) {
            return lead + "\(name) is in a folder your agents can change."
        }
        if interpreters.contains(program) || interpreters.contains(name) {
            guard let script = command.script else { return lead + "Next Term couldn\u{2019}t tell which script \(name) runs." }
            if isChangeable(script, scopes: scopes, writable: writable) {
                return lead + "\(name) runs \((script as NSString).lastPathComponent), which your agents can change."
            }
        }
        return nil
    }

    /// A file inside a scope's folder, or one this user can change, or whose folder this user can write.
    static func isChangeable(_ path: String, scopes: [String], writable: (String) -> Bool) -> Bool {
        if scopes.contains(where: { SecretAlwaysScope.contains($0, path, caseSensitive: false) }) { return true }
        return writable(path) || writable((path as NSString).deletingLastPathComponent)
    }

    /// A warning made short for "Always isn’t offered: …".
    static func short(_ warning: String) -> String {
        if let runs = warning.range(of: " runs the newest ") {
            let lead = warning[..<runs.lowerBound]
            return "\(lead) fetches new code each time."
        }
        if warning.hasPrefix("This command starts a shell") { return "this command starts a shell." }
        if warning.hasPrefix("This command starts an agent") { return "this command starts an agent." }
        if let space = warning.firstIndex(of: " "), warning.contains(" is set") {
            return "\(warning[..<space]) is set in its environment."
        }
        if warning.hasPrefix(".env in this folder") { return "this folder\u{2019}s .env can send the key elsewhere." }
        return "Next Term warns about this command."
    }

    /// The words of a run_with_secrets command when it is one plain command: words of letters, digits and
    /// `_ . / : @ % + = , - ~` (a leading `~` alone), each bare or in quotes with no `$`, `` ` `` or `\` inside, and no
    /// assignment first. Nil when it uses the shell's own syntax.
    public static func plainWords(_ command: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@%+=,-")
        for character in command {
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "$" || character == "`" || character == "\\" || character == "\n" {
                    return nil
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case " ", "\t":
                if inWord { words.append(current) }
                current = ""
                inWord = false
            case "'", "\"":
                quote = character
                inWord = true
            default:
                guard plain.contains(character) else { return nil }
                current.append(character)
                inWord = true
            }
        }
        guard quote == nil else { return nil }
        if inWord { words.append(current) }
        guard let first = words.first, !SecretRun.isAssignment(first) else { return nil }
        return words
    }
}

// MARK: - places

/// Where a folder is, for the Always choices: the main checkout of its repository and the linked worktree it is in, as
/// git itself resolves them (never a `.git` file alone, which anyone can make), else the open project that holds it.
public struct SecretPlaces: Equatable, Sendable {
    public var folder: String
    public var project: String?
    public var worktree: String?

    public init(folder: String, project: String? = nil, worktree: String? = nil) {
        self.folder = folder
        self.project = project
        self.worktree = worktree
    }

    /// The places of `folder` (canonical): `git -C folder rev-parse` gives its work tree's top, its own git folder and
    /// the common one. A linked worktree's git folder isn't the common one; its main checkout is the common folder's
    /// parent. Outside git, the deepest of `projects` that holds it. Home and `/` are never a project.
    public static func of(_ folder: String, git: String?, projects: [String] = [], home: String = NSHomeDirectory()) -> SecretPlaces {
        var places = SecretPlaces(folder: folder)
        if let git, let found = resolve(folder, git: git) {
            places.project = found.project
            places.worktree = found.worktree
        } else {
            places.project = projects.map(canonicalPath).filter { SecretAlwaysScope.contains($0, folder, caseSensitive: true) }
                .max { $0.count < $1.count }
        }
        let broad = ["/", canonicalPath(home)]
        if let project = places.project, broad.contains(where: { SecretAlwaysScope.same($0, project, caseSensitive: true) }) || project == "/" {
            places.project = nil
        }
        if let worktree = places.worktree, broad.contains(where: { SecretAlwaysScope.same($0, worktree, caseSensitive: true) }) {
            places.worktree = nil
        }
        return places
    }

    /// git's own answer: the main checkout, and the linked worktree when the folder is in one.
    static func resolve(_ folder: String, git: String) -> (project: String, worktree: String?)? {
        let arguments = ["-C", folder, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"]
        guard let data = GitRunner.run(git, arguments, timeout: 5), let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map { String($0) }
        guard lines.count == 3 else { return nil }
        let top = canonicalPath(lines[0])
        let gitDir = canonicalPath(lines[1])
        let common = canonicalPath(lines[2])
        guard top.hasPrefix("/"), gitDir.hasPrefix("/"), common.hasPrefix("/") else { return nil }
        let own = canonicalPath(top + "/.git")
        // A checkout of its own: its git folder is its own `.git` folder, never one a `.git` file elsewhere names.
        if gitDir == common { return gitDir == own && isFolder(gitDir) ? (top, nil) : nil }
        // A linked worktree: git's own record of it (its git folder's `gitdir`) names this worktree's `.git`, and the main
        // checkout is the common folder's parent, whose `.git` that folder is.
        guard let back = try? String(contentsOfFile: gitDir + "/gitdir", encoding: .utf8),
              canonicalPath(back.trimmingCharacters(in: .whitespacesAndNewlines)) == own,
              (common as NSString).lastPathComponent == ".git", isFolder(common) else { return nil }
        let main = canonicalPath((common as NSString).deletingLastPathComponent)
        return (main, top)
    }

    static func isFolder(_ path: String) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
    }

    /// The Always scopes these places offer, widest first: the project, the worktree (in a linked one), the folder.
    public var scopes: [SecretAlwaysScope.Kind] {
        var scopes: [SecretAlwaysScope.Kind] = []
        if project != nil { scopes.append(.project) }
        if worktree != nil { scopes.append(.worktree) }
        if !(project.map { SecretAlwaysScope.same($0, folder, caseSensitive: true) } ?? false)
            && !(worktree.map { SecretAlwaysScope.same($0, folder, caseSensitive: true) } ?? false) || scopes.isEmpty {
            scopes.append(.folder)
        }
        return scopes
    }

    /// The root a scope's grant holds at.
    public func path(for kind: SecretAlwaysScope.Kind) -> String? {
        switch kind {
        case .project: return project
        case .worktree: return worktree
        case .folder: return folder
        }
    }
}
