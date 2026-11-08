import Foundation

/// Which folders a Claude Code session may start in (plan 035 R8). `claude -p` loads a folder's hooks, `.mcp.json`,
/// plugins and CLAUDE.md with no trust dialog of its own, so Next Term asks on the Mac, by click only, before the first
/// session in a folder, and keeps the answer in its own list: the app writes it (AgentSessionSocket's `trust_folder`),
/// never the session, so nothing typed into a tab can grant it.
///
/// A folder is trusted only when its canonical path (symlinks resolved, `..` gone) is listed exactly: a subfolder is
/// asked on its own, and a parent's trust never covers it. Known limit (KTD5): the list lives in the app's defaults,
/// which any process running as the user could edit; an agent with a shell can already run `claude` itself.
public enum AgentSessionTrust {
    /// The app's defaults key for the list of trusted folders' canonical paths.
    public static let defaultsKey = "agentSessionTrustedFolders"

    /// What the session says when it can't ask the app (it runs outside a Next Term tab) and the folder isn't trusted.
    public static let outsideNote = "Run claude in a terminal tab there once, or start the session from Next Term."

    /// The input line while the Mac's question is open.
    public static let waitingLine = "Waiting for your OK on the Mac to trust this folder\u{2026}"

    /// The question the Mac asks.
    public static func question(folder: String) -> String {
        "Claude Code will run the hooks and MCP servers of \(folder). Trust this folder?"
    }

    /// `path` as the list keeps it: `~` expanded, made absolute, `.` and `..` gone and symlinks resolved. A path that
    /// doesn't exist is only tidied, as there is nothing to resolve.
    public static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/")
            ? expanded
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        return canonicalPath(absolute)
    }

    /// Whether `folder` is in `list`, exactly, by its canonical path.
    public static func isTrusted(_ folder: String, in list: [String]) -> Bool {
        let wanted = canonical(folder)
        return list.contains { $0 == wanted }
    }

    /// `list` with `folder`'s canonical path added once.
    public static func adding(_ folder: String, to list: [String]) -> [String] {
        let path = canonical(folder)
        return list.contains(path) ? list : list + [path]
    }

    /// `list` without `folder` (the self-test cleans up its own folders).
    public static func removing(_ folder: String, from list: [String]) -> [String] {
        let path = canonical(folder)
        return list.filter { $0 != path }
    }

    /// The list as `defaults` holds it.
    public static func list(in defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: defaultsKey) ?? []
    }
}
