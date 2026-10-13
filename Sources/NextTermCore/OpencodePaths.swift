import Foundation

/// Where OpenCode keeps its config and its sessions, by OpenCode's own rules (`Global.Path`, `Database.path()`).
/// Its folders follow XDG: `$XDG_CONFIG_HOME/opencode` and `$XDG_DATA_HOME/opencode` when those are absolute, else
/// `~/.config/opencode` and `~/.local/share/opencode`. Its database is `OPENCODE_DB` when that is set (`:memory:` keeps
/// nothing on disk, and a relative name is taken in the data folder), else `opencode.db` in the data folder, or
/// `opencode-<channel>.db` beside it for a build of another channel unless `OPENCODE_DISABLE_CHANNEL_DB` is 1 or true.
///
/// What decides is the user's login shell, read by its probe (`shellEnvironment`): a Finder-launched app's own
/// environment lacks what .zshrc sets. Every function also takes the environment, for tests.
public enum OpencodePaths {
    /// The variables that move OpenCode's folders or pick its database, in the order the login shell's probe reads them.
    public static let variables = ["XDG_DATA_HOME", "XDG_CONFIG_HOME", "OPENCODE_DB", "OPENCODE_DISABLE_CHANNEL_DB"]

    /// At most this many channel databases are read beside the main one.
    static let channelLimit = 4

    private static let lock = NSLock()
    nonisolated(unsafe) private static var shell: [String: String] = [:]

    /// `variables` as the user's login shell sets them, from `shellValues`: set once when its probe finishes, empty
    /// until then (so the defaults apply in the first seconds after launch).
    public static var shellEnvironment: [String: String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return shell
        }
        set {
            lock.lock()
            shell = newValue
            lock.unlock()
        }
    }

    /// The environment that decides for the stores in `home`: the login shell's for the user's own home, none for any
    /// other (a test's or the self-test's made-up home, which must never lead to the user's real store).
    public static func environment(home: String) -> [String: String] {
        let own = (NSHomeDirectory() as NSString).standardizingPath
        return (home as NSString).standardizingPath == own ? shellEnvironment : [:]
    }

    /// What the probe printed for each of `variables` (printenv's value and its newline) as the environment kept:
    /// one trailing newline is dropped, and a value that is empty or still has a line break is left out, as are names
    /// not in `variables`.
    public static func shellValues(_ printed: [String: String]) -> [String: String] {
        var kept: [String: String] = [:]
        for name in variables {
            guard var value = printed[name] else { continue }
            if value.hasSuffix("\n") { value.removeLast() }
            guard !value.isEmpty, !value.contains(where: \.isNewline) else { continue }
            kept[name] = value
        }
        return kept
    }

    /// OpenCode's config folder: `$XDG_CONFIG_HOME/opencode`, or `~/.config/opencode`.
    public static func configFolder(home: String, environment: [String: String]) -> String {
        folder(environment["XDG_CONFIG_HOME"], home: home, fallback: ".config")
    }

    /// OpenCode's data folder, where its databases are: `$XDG_DATA_HOME/opencode`, or `~/.local/share/opencode`.
    public static func dataFolder(home: String, environment: [String: String]) -> String {
        folder(environment["XDG_DATA_HOME"], home: home, fallback: ".local/share")
    }

    /// The database OpenCode opens on its main channel, which may not exist yet; nil when `OPENCODE_DB` is `:memory:`.
    public static func database(home: String, environment: [String: String]) -> String? {
        let data = dataFolder(home: home, environment: environment)
        guard let named = nonEmpty(environment["OPENCODE_DB"]) else { return (data as NSString).appendingPathComponent("opencode.db") }
        if named == ":memory:" { return nil }
        if named.hasPrefix("/") { return named }
        return joined(data, named)
    }

    /// `folder` and a relative `path`, with `.` and `..` worked out by name as OpenCode's `path.join` does.
    static func joined(_ folder: String, _ path: String) -> String {
        var parts: [Substring] = []
        for part in (folder + "/" + path).split(separator: "/") where part != "." {
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The databases to read OpenCode's sessions from, only those that exist: `OPENCODE_DB`'s alone when it is set;
    /// else `opencode.db`, then the channel databases beside it, the most lately written first and at most
    /// `channelLimit` (Next Term can't know which channel's build is installed, so it reads each it finds).
    public static func databases(home: String, environment: [String: String]) -> [String] {
        guard let main = database(home: home, environment: environment) else { return [] }
        let found = isRegularFile(main) ? [main] : []
        guard nonEmpty(environment["OPENCODE_DB"]) == nil, !channelsDisabled(environment) else { return found }
        let data = dataFolder(home: home, environment: environment)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: data)) ?? []
        let channels = names.filter(isChannelDatabase).compactMap { (name: String) -> (path: String, written: Date)? in
            let path = (data as NSString).appendingPathComponent(name)
            guard isRegularFile(path) else { return nil }
            // A database in use is written through its log, which its own date can lag far behind.
            return (path, AgentStoreFiles.latest([path, path + "-wal"]) ?? .distantPast)
        }
        let newest = channels.sorted { (a: (path: String, written: Date), b: (path: String, written: Date)) -> Bool in
            a.written != b.written ? a.written > b.written : a.path < b.path
        }
        return found + newest.prefix(channelLimit).map(\.path)
    }

    /// `opencode-<channel>.db`, the channel as OpenCode writes it into the name (letters, digits, `.`, `_` and `-`).
    static func isChannelDatabase(_ name: String) -> Bool {
        guard name.hasPrefix("opencode-"), name.hasSuffix(".db") else { return false }
        let channel = name.dropFirst("opencode-".count).dropLast(".db".count)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !channel.isEmpty && channel.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// OpenCode keeps to `opencode.db` whatever its channel when this is 1 or true.
    static func channelsDisabled(_ environment: [String: String]) -> Bool {
        ["1", "true"].contains(environment["OPENCODE_DISABLE_CHANNEL_DB"] ?? "")
    }

    /// `<base>/opencode` for an absolute XDG base, else `~/<fallback>/opencode` (a relative base is ignored).
    private static func folder(_ base: String?, home: String, fallback: String) -> String {
        if let base = nonEmpty(base), base.hasPrefix("/") { return (base as NSString).appendingPathComponent("opencode") }
        return (home as NSString).appendingPathComponent(fallback + "/opencode")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
