import Foundation

/// Where `nxtrm` is linked for terminals outside Next Term (its own tabs always have it): a folder that is
/// already on the login shell's PATH, is meant for commands the user installs, and can be written without
/// a password. A PATH entry is never added, and nothing but a Next Term link is ever replaced.
public enum CommandLineLink {
    /// What a folder on PATH holds under the tool's name.
    public enum Entry: Equatable, Sendable {
        case nothing
        /// A symbolic link, and where it points.
        case link(String)
        /// A file or folder of its own.
        case file
    }

    public enum Plan: Equatable, Sendable {
        /// A link to this copy of the app comes first on PATH: nothing to do.
        case linked(String)
        /// Link this path to the app: it is free, or Next Term's own link to another copy (moved, or older).
        case link(String)
        /// Another `nxtrm` comes first on PATH: left as it is.
        case taken(String)
        /// No folder on PATH takes it without a password.
        case unavailable
    }

    /// The folders a link may be added to, in no particular order (PATH decides): the user's own, and
    /// Homebrew's, which belong to the user when Homebrew installed them. Others on PATH (version
    /// managers' shims, a language's own tools, a project's) are someone else's to manage.
    public static func commandFolders(home: String) -> [String] {
        [home + "/.local/bin", home + "/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    /// A link Next Term made, to some copy of the app: `…/Contents/Resources/bin/nxtrm`.
    public static func isOurs(_ target: String) -> Bool {
        target.hasSuffix("/Contents/Resources/bin/" + CommandLineOpen.toolName)
    }

    /// The folders of a PATH value, as the shell searches them: absolute ones only, `~` expanded, without
    /// a trailing slash, each once.
    public static func folders(_ path: [String], home: String) -> [String] {
        var seen = Set<String>()
        var folders: [String] = []
        for entry in path {
            var folder = entry
            if folder == "~" || folder.hasPrefix("~/") { folder = home + String(folder.dropFirst()) }
            while folder.count > 1 && folder.hasSuffix("/") { folder.removeLast() }
            guard folder.hasPrefix("/"), seen.insert(folder).inserted else { continue }
            folders.append(folder)
        }
        return folders
    }

    /// Walks PATH in order, as the shell does. The first `nxtrm` there decides: this app's link (done),
    /// Next Term's link to another copy (repointed, when its folder is writable; else passed over), or
    /// anyone else's (left alone, and not shadowed by one of ours). With none, the first command folder
    /// that `isWritable` takes it.
    public static func plan(path: [String], home: String, script: String,
                            isWritable: (String) -> Bool, entry: (String) -> Entry) -> Plan {
        let allowed = Set(commandFolders(home: home))
        var free: String?
        for folder in folders(path, home: home) {
            let candidate = folder + "/" + CommandLineOpen.toolName
            // A Next Term's own bin folder, on PATH because the app was started from one of its tabs.
            if isOurs(candidate) { continue }
            switch entry(candidate) {
            case .link(let target) where target == script:
                return .linked(candidate)
            case .link(let target) where isOurs(target):
                if isWritable(folder) { return .link(candidate) }
            case .link, .file:
                return .taken(candidate)
            case .nothing:
                if free == nil, allowed.contains(folder), isWritable(folder) { free = candidate }
            }
        }
        return free.map { .link($0) } ?? .unavailable
    }

    /// The first-launch offer of the password route, when no folder takes the link: once per version
    /// ("Not Now" asks again after an update), never after "Don't Ask Again". `remembered` is the
    /// version it was last shown in, or `declined`.
    public static func shouldOffer(remembered: String?, version: String) -> Bool {
        remembered != declined && remembered != version
    }

    public static let declined = "never"
}
