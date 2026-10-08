import Foundation

// What Claude Code's own files say about plugins, for the skills review (as of October 2026). Read only:
// Next Term never writes any of them for a skill. Only ~/.claude in the home folder is read; a
// CLAUDE_CONFIG_DIR elsewhere is not followed.
// - ~/.claude/settings.json: `enabledPlugins`. A skill folder linked into ~/.claude/skills loads as the
//   plugin "<name>@skills-dir"; that key set to false keeps Claude Code from loading anything from the
//   folder, not even its skill, until the user turns it on in /plugin (hand checks H1 and H4). Keys are
//   compared exactly (H2). Claude Code reads the file with JSON.parse: the last of two equal keys wins,
//   and a comment makes the file unreadable.
// - ~/.claude/plugins/installed_plugins.json: plugins installed from a marketplace. Version 2 keys
//   `plugins` by "name@marketplace", each with a list of installs and their scope (managed, user, project
//   or local); version 1 kept one install, for the user. An installed plugin of the same name wins over a
//   skills-dir folder, even turned off; installed for a project, only in that project (H7).
// - ~/.claude/plugins/synced/<bucket>/<name>/.claude-plugin/plugin.json: plugins synced from claude.ai.
//   A skills-dir folder of the same name replaces one in Claude Code sessions.

public enum SkillClaudeSettings {
    /// What Claude Code adds to a skills-dir plugin's name for its key in `enabledPlugins`.
    public static let sentinel = "@skills-dir"

    /// The `enabledPlugins` key of the skills-dir plugin with this name.
    public static func key(_ plugin: String) -> String { plugin + sentinel }

    /// A plugin installed from a marketplace.
    public struct Installed: Equatable, Sendable {
        public let name: String
        public let marketplace: String
        /// Its installs' scopes, as written: "managed", "user", "project" or "local".
        public let scopes: [String]
        /// `enabledPlugins`' value for "name@marketplace" in ~/.claude/settings.json; nil: not there.
        public let enabled: Bool?

        public init(name: String, marketplace: String, scopes: [String], enabled: Bool?) {
            self.name = name
            self.marketplace = marketplace
            self.scopes = scopes
            self.enabled = enabled
        }

        /// Installed for the user, or by the organization: Claude Code keeps it in every folder.
        public var everywhere: Bool { scopes.contains("user") || scopes.contains("managed") }
    }

    /// A plugin synced from claude.ai.
    public struct Synced: Equatable, Sendable {
        public let name: String
        public let displayName: String?

        public init(name: String, displayName: String?) {
            self.name = name
            self.displayName = displayName
        }
    }

    /// What the review and the install read: taken off the main thread when the skill is fetched, and
    /// again right before Install, which refuses when it changed.
    public struct Snapshot: Equatable, Sendable {
        /// `enabledPlugins` values for the keys asked for, when they are true or false.
        public var values: [String: Bool]
        public var installed: [Installed]
        public var synced: [Synced]

        public init(values: [String: Bool] = [:], installed: [Installed] = [], synced: [Synced] = []) {
            self.values = values
            self.installed = installed
            self.synced = synced
        }

        /// The value of the skills-dir plugin's key; nil: not there (or not asked for).
        public func value(for plugin: String) -> Bool? { values[SkillClaudeSettings.key(plugin)] }
    }

    /// Reads the three places in `home`. `keys`: the `enabledPlugins` keys whose values are wanted. A file
    /// that can't be read gives nothing from it, never a failure.
    public static func snapshot(home: String, keys: [String]) -> Snapshot {
        let enabled = enabledPlugins(home: home)
        var values: [String: Bool] = [:]
        for key in keys { values[key] = enabled[key] }
        let plugins = (home as NSString).appendingPathComponent(".claude/plugins")
        let installedFile = (plugins as NSString).appendingPathComponent("installed_plugins.json")
        let installed = Self.installed(read(installedFile), enabled: enabled)
        let synced = Self.synced(folder: (plugins as NSString).appendingPathComponent("synced"))
        return Snapshot(values: values, installed: installed, synced: synced)
    }

    /// Every true or false value in `enabledPlugins` of ~/.claude/settings.json in `home`.
    public static func enabledPlugins(home: String) -> [String: Bool] {
        let path = (home as NSString).appendingPathComponent(".claude/settings.json")
        return read(path).map(enabledPlugins) ?? [:]
    }

    /// The values as JSON.parse leaves them: the last `enabledPlugins`, and in it the last of two equal
    /// keys. Values other than true and false are left out. A file that is not strict JSON gives none.
    static func enabledPlugins(_ data: Data) -> [String: Bool] {
        guard case .success(let root) = SkillJSONText.parse(data), root.kind == .object,
              let plugins = root.member("enabledPlugins").last?.value, plugins.kind == .object else { return [:] }
        let bytes = [UInt8](data)
        var values: [String: Bool] = [:]
        for member in plugins.members {
            guard member.value.kind == .bool, bytes.indices.contains(member.value.range.lowerBound) else {
                values[member.key] = nil
                continue
            }
            values[member.key] = bytes[member.value.range.lowerBound] == UInt8(ascii: "t")
        }
        return values
    }

    /// The plugins in installed_plugins.json, by name.
    static func installed(_ data: Data?, enabled: [String: Bool]) -> [Installed] {
        guard let data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plugins = json["plugins"] as? [String: Any] else { return [] }
        var result: [Installed] = []
        for (id, value) in plugins {
            let installs: [Any]
            if let list = value as? [Any] { installs = list } else if value is [String: Any] { installs = [value] } else { continue }
            var scopes: [String] = []
            for case let install as [String: Any] in installs {
                // An install without a scope is version 1's, which installed for the user.
                guard let scope = install["scope"] else {
                    scopes.append("user")
                    continue
                }
                if let scope = scope as? String { scopes.append(scope) }
            }
            guard !scopes.isEmpty else { continue }
            let (name, marketplace) = split(id)
            result.append(Installed(name: name, marketplace: marketplace, scopes: scopes, enabled: enabled[id]))
        }
        return result.sorted { ($0.name, $0.marketplace) < ($1.name, $1.marketplace) }
    }

    /// "name@marketplace" split at the last `@`.
    static func split(_ id: String) -> (String, String) {
        guard let at = id.lastIndex(of: "@") else { return (id, "") }
        return (String(id[..<at]), String(id[id.index(after: at)...]))
    }

    /// The manifests in synced/<bucket>/<name>/.claude-plugin/plugin.json. Dot folders are skipped; a
    /// manifest without a name stands for the folder's. One that can't be read is left out.
    static func synced(folder: String) -> [Synced] {
        let manager = FileManager.default
        var result: [Synced] = []
        for bucket in visible(folder) {
            let bucketPath = (folder as NSString).appendingPathComponent(bucket)
            for name in visible(bucketPath) {
                let manifest = ((bucketPath as NSString).appendingPathComponent(name) as NSString).appendingPathComponent(".claude-plugin/plugin.json")
                guard manager.fileExists(atPath: manifest), let data = read(manifest),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                let declared = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let display = (json["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                result.append(Synced(name: declared ?? name, displayName: display))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// A folder's entries that don't start with a dot, sorted; none when it is not a folder.
    static func visible(_ folder: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// A regular file's bytes (a link is followed), up to the review's 5 MB cap; nil otherwise.
    static func read(_ path: String) -> Data? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) <= SkillReview.maxReadSize else { return nil }
        return FileManager.default.contents(atPath: path)
    }
}
