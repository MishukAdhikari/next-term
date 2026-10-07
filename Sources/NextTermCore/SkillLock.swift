import Foundation

/// `~/.agents/.skill-lock.json`, the record `npx skills` (vercel-labs/skills) keeps of what it installed.
/// Next Term writes its installs there too, in the same shape (version 3), so both tools list the same
/// skills and neither reports the other's as changed. Every other entry and field is kept as it was.
/// A version above 3 is a format Next Term does not know: it then leaves the file alone.
public enum SkillLock {
    public static let version = 3

    /// The lock file's path. XDG_STATE_HOME counts only as an absolute path (the XDG rules: a relative
    /// value is ignored), as `npx skills` resolves it.
    public static func path(home: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let state = environment["XDG_STATE_HOME"], state.hasPrefix("/") {
            return ((state as NSString).standardizingPath as NSString).appendingPathComponent("skills/.skill-lock.json")
        }
        return (home as NSString).appendingPathComponent(".agents/.skill-lock.json")
    }

    public struct Entry: Equatable, Sendable {
        public var source: String
        /// "github", "local", "git"…; nil when the entry doesn't say.
        public var sourceType: String?
        public var sourceUrl: String
        /// SKILL.md's path in the repository ("SKILL.md", or "skills/pdf/SKILL.md").
        public var skillPath: String
        /// The skill folder's git tree hash; for a skill at the repository's root, the commit (as the
        /// CLI records it).
        public var skillFolderHash: String
        /// The branch or tag it was installed from, when the CLI recorded one.
        public var ref: String?
        /// nil when the entry has none, or one Next Term can't read: an update then keeps what is there.
        public var installedAt: Date?
        public var updatedAt: Date

        public init(source: String, sourceType: String? = "github", sourceUrl: String, skillPath: String, skillFolderHash: String,
                    ref: String? = nil, installedAt: Date?, updatedAt: Date) {
            self.source = source
            self.sourceType = sourceType
            self.sourceUrl = sourceUrl
            self.skillPath = skillPath
            self.skillFolderHash = skillFolderHash
            self.ref = ref
            self.installedAt = installedAt
            self.updatedAt = updatedAt
        }
    }

    public enum Problem: Error, Equatable {
        /// The file is in a newer format than Next Term knows.
        case newerVersion(Int)
        /// The file is not JSON Next Term can read.
        case unreadable
    }

    static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let plainDateFormatter = ISO8601DateFormatter()

    /// A date as the CLI writes it, with or without fractions of a second.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return dateFormatter.date(from: text) ?? plainDateFormatter.date(from: text)
    }

    /// The entries in the file (an absent file has none).
    public static func entries(at path: String) -> Result<[String: Entry], Problem> {
        guard let data = FileManager.default.contents(atPath: path) else { return .success([:]) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.unreadable) }
        if let version = object["version"] as? Int, version > Self.version { return .failure(.newerVersion(version)) }
        var result: [String: Entry] = [:]
        for (name, value) in object["skills"] as? [String: Any] ?? [:] {
            guard let item = value as? [String: Any] else { continue }
            result[name] = Entry(source: item["source"] as? String ?? "", sourceType: item["sourceType"] as? String,
                                 sourceUrl: item["sourceUrl"] as? String ?? "", skillPath: item["skillPath"] as? String ?? "SKILL.md",
                                 skillFolderHash: item["skillFolderHash"] as? String ?? "", ref: item["ref"] as? String,
                                 installedAt: date(item["installedAt"]), updatedAt: date(item["updatedAt"]) ?? .distantPast)
        }
        return .success(result)
    }

    static func parse(_ text: String?) -> Result<[String: Any], Problem> {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .success(["version": Self.version, "skills": [String: Any]()])
        }
        guard var parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return .failure(.unreadable) }
        if let version = parsed["version"] as? Int, version > Self.version { return .failure(.newerVersion(version)) }
        if parsed["version"] == nil { parsed["version"] = Self.version }
        return .success(parsed)
    }

    static func serialize(_ object: Any) -> Result<String, Problem> {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return .failure(.unreadable)
        }
        return .success(String(decoding: data, as: UTF8.self) + "\n")
    }

    /// The file's new text with `name` set to `entry` (or removed, for nil). Other entries, and fields
    /// of this one that Next Term has no use for, stay as they were.
    public static func updated(_ text: String?, name: String, entry: Entry?) -> Result<String, Problem> {
        var object: [String: Any]
        switch parse(text) {
        case .success(let parsed): object = parsed
        case .failure(let problem): return .failure(problem)
        }
        var skills = object["skills"] as? [String: Any] ?? [:]
        if let entry {
            var item = skills[name] as? [String: Any] ?? [:]
            item["source"] = entry.source
            item["sourceType"] = entry.sourceType ?? "github"
            item["sourceUrl"] = entry.sourceUrl
            item["skillPath"] = entry.skillPath
            item["skillFolderHash"] = entry.skillFolderHash
            if let ref = entry.ref { item["ref"] = ref }
            // An unreadable or missing date stays as it was rather than becoming year 1.
            if let installedAt = entry.installedAt { item["installedAt"] = dateFormatter.string(from: installedAt) }
            else if item["installedAt"] == nil { item["installedAt"] = dateFormatter.string(from: entry.updatedAt) }
            item["updatedAt"] = dateFormatter.string(from: entry.updatedAt)
            skills[name] = item
        } else {
            skills.removeValue(forKey: name)
        }
        object["skills"] = skills
        return serialize(object)
    }

    /// One entry exactly as the file holds it (keys sorted), or nil: what Undo puts back and checks.
    public static func rawItem(_ text: String?, name: String) -> String? {
        guard case .success(let object) = parse(text), let item = (object["skills"] as? [String: Any])?[name],
              let data = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The file's text with one entry set back to `raw` (rawItem's form), or removed for nil.
    public static func replacingRawItem(_ text: String?, name: String, raw: String?) -> Result<String, Problem> {
        var object: [String: Any]
        switch parse(text) {
        case .success(let parsed): object = parsed
        case .failure(let problem): return .failure(problem)
        }
        var skills = object["skills"] as? [String: Any] ?? [:]
        if let raw, let item = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) { skills[name] = item } else { skills.removeValue(forKey: name) }
        object["skills"] = skills
        return serialize(object)
    }
}

/// What Next Term itself remembers about the skills it installed: the exact commit and hashes reviewed,
/// so an update check compares like with like and a change on disk is noticed.
public struct SkillRecord: Codable, Equatable, Sendable {
    public var name: String
    public var owner: String
    public var repo: String
    /// The folder in the repository ("" for its root).
    public var path: String
    /// The branch or tag asked for, if any (updates follow it).
    public var ref: String?
    public var commit: String
    /// The folder's git tree hash at that commit.
    public var tree: String
    /// The git tree hash of the files as installed (GitHash.folder, .DS_Store left out): a different
    /// value later means someone changed the installed copy.
    public var contentHash: String
    public var installedAt: Date
    /// Whether Next Term linked it for Claude Code.
    public var linkedForClaude: Bool

    public init(name: String, owner: String, repo: String, path: String, ref: String?, commit: String, tree: String,
                contentHash: String, installedAt: Date, linkedForClaude: Bool) {
        self.name = name
        self.owner = owner
        self.repo = repo
        self.path = path
        self.ref = ref
        self.commit = commit
        self.tree = tree
        self.contentHash = contentHash
        self.installedAt = installedAt
        self.linkedForClaude = linkedForClaude
    }

    public var source: SkillSource { SkillSource(owner: owner, repo: repo, ref: ref, path: path) }

    public static func decodeList(_ data: Data?) -> [SkillRecord] {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SkillRecord].self, from: data)) ?? []
    }

    public static func encodeList(_ records: [SkillRecord]) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(records.sorted { $0.name < $1.name })) ?? Data("[]".utf8)
    }

    /// One record as compact JSON (what Undo puts back and checks).
    public func raw() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }

    public static func fromRaw(_ raw: String) -> SkillRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SkillRecord.self, from: Data(raw.utf8))
    }
}
