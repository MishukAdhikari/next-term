import Foundation

// import_secrets' path rules, and its window's banner. An agent names a file; Next Term reads it only after the user
// picks the keys in the import window, and the agent hears back names and counts, never what the file holds. So a file
// `read_file` refuses (a .env, an export) may be named here, inside or outside the open projects. The vault's own
// folder, ~/Library/Keychains, ~/.ssh and ~/.gnupg never are, as named, through a link or by the data volume's own path,
// and a file there answers as a missing one does: a refusal never says whether a protected file exists.

extension SecretSources {
    /// Why a path an agent named can't be imported from: a class, never more of the file.
    public enum PathRefusal: Error, Equatable, Sendable {
        /// Nothing there, nothing Next Term may look at, or a protected folder: one class for all three.
        case notFound
        /// A relative path, with no tab's folder to resolve it against.
        case notAbsolute
        /// Larger than its reader takes.
        case tooLarge
        /// A folder, a device or a pipe.
        case notAFile

        public var reasonClass: String {
            switch self {
            case .notFound: return "not found or protected"
            case .notAbsolute: return "not an absolute path"
            case .tooLarge: return "too large"
            case .notAFile: return "not a file"
            }
        }

        /// The refusal's note, as the agent gets it.
        public var note: String { "Next Term can't import from that path: \(reasonClass)." }
    }

    /// The folders in the home folder an import never reads from.
    public static let protectedHomeFolders: [String] = ["Library/Keychains", ".ssh", ".gnupg"]
    /// The longest path an agent may name.
    public static let maxPathLength = 4096

    /// The file `path` names, with its links followed, when an agent may ask to import it: an absolute path (`~/` is
    /// the home folder's), or one relative to `folder`, the caller's tab's folder; outside `vaultFolder` and the
    /// protected home folders, both as named and as resolved, matched without regard to case, and by disk and inode
    /// for any other name of them (the data volume's own `/System/Volumes/Data/…`); a regular file of at most
    /// `maxBytes`, or `maxArchiveBytes` for a 1Password export (`.1pux`). It comes back by the path the rest of the Mac
    /// uses. Nothing is opened: the reader checks the file again as it reads it.
    public static func checkPath(_ path: String, home: String, vaultFolder: String,
                                 folder: String? = nil) -> Result<String, PathRefusal> {
        guard let given = absolute(path, home: home, folder: folder) else { return .failure(.notAbsolute) }
        let named: String = URL(fileURLWithPath: given).standardizedFileURL.path
        let real: String = usualPath(canonicalPath(given))
        let fences: [String] = protectedFolders(home: home, vaultFolder: vaultFolder)
        if isInside(named, fences) || isInside(real, fences) { return .failure(.notFound) }
        if isInside(real, fenceIDs: protectedIDs(home: home, vaultFolder: vaultFolder)) { return .failure(.notFound) }
        var info = stat()
        guard stat(real, &info) == 0 else { return .failure(.notFound) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .failure(.notAFile) }
        let isArchive: Bool = real.lowercased().hasSuffix(".1pux")
        let cap: Int = isArchive ? maxArchiveBytes : maxBytes
        guard Int(info.st_size) <= cap else { return .failure(.tooLarge) }
        return .success(real)
    }

    /// `path` as an absolute path: as given, from the home folder for `~/`, or from `folder`; nil for a relative path
    /// with no folder, or an empty one.
    static func absolute(_ path: String, home: String, folder: String?) -> String? {
        if path.hasPrefix("/") { return path }
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        guard !path.isEmpty, let folder, folder.hasPrefix("/") else { return nil }
        return folder.hasSuffix("/") ? folder + path : folder + "/" + path
    }

    /// The protected folders, as named and as resolved, in lower case.
    static func protectedFolders(home: String, vaultFolder: String) -> [String] {
        let homeFolders: [String] = protectedHomeFolders.map { (folder: String) -> String in home + "/" + folder }
        var fences: [String] = []
        for folder in homeFolders + [vaultFolder] {
            let standard: String = URL(fileURLWithPath: folder).standardizedFileURL.path
            for form in [standard, canonicalPath(standard)] where !fences.contains(form.lowercased()) {
                fences.append(form.lowercased())
            }
        }
        return fences
    }

    /// Whether `path` is one of `fences` or inside one, without regard to case: the Mac's disks usually ignore it.
    static func isInside(_ path: String, _ fences: [String]) -> Bool {
        let lower: String = path.lowercased()
        return fences.contains { (fence: String) -> Bool in lower == fence || lower.hasPrefix(fence + "/") }
    }
}

// MARK: - The same file by another name

extension SecretSources {
    /// A file or folder by its disk and inode, whatever path reaches it.
    struct FileID: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    /// The data volume's own path to everything in it, `/Users` and `/private` among them.
    static let dataVolume = "/System/Volumes/Data"

    /// `path`'s disk and inode, with links followed; nil when nothing is there.
    static func fileID(_ path: String) -> FileID? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileID(device: info.st_dev, inode: info.st_ino)
    }

    /// The protected folders that exist, by disk and inode. One that doesn't exist holds nothing to protect.
    static func protectedIDs(home: String, vaultFolder: String) -> [FileID] {
        let folders: [String] = protectedHomeFolders.map { (folder: String) -> String in home + "/" + folder }
        return (folders + [vaultFolder]).compactMap(fileID)
    }

    /// Whether `path`, or a folder it is in, is one of the folders `fenceIDs` names.
    static func isInside(_ path: String, fenceIDs: [FileID]) -> Bool {
        guard !fenceIDs.isEmpty else { return false }
        var current: String = path
        while true {
            if let id = fileID(current), fenceIDs.contains(id) { return true }
            let parent: String = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return false }
            current = parent
        }
    }

    /// A resolved path on the data volume's own name (`/System/Volumes/Data/Users/…`) as the rest of the Mac names the
    /// same file (`/Users/…`), so it is fenced, shown and matched as that; any other path as it is.
    static func usualPath(_ path: String) -> String {
        let prefix: String = dataVolume + "/"
        guard path.lowercased().hasPrefix(prefix.lowercased()) else { return path }
        let rest: String = String(path.dropFirst(prefix.count))
        let usual: String = canonicalPath("/" + rest)
        guard let id = fileID(path), fileID(usual) == id else { return path }
        return usual
    }
}

// MARK: - The import window's banner

extension SecretSources {
    /// Who asks, as the banner starts: "Claude Code in shop-web", "An agent in tab 3 of rag-api", "An agent outside
    /// Next Term’s tabs". `agent` goes by its program's name; `project` is the tab's project folder.
    public static func askerText(agent: String?, tab: String?, project: String?) -> String {
        let name: String? = project.map { (path: String) -> String in (path as NSString).lastPathComponent }
        if let agent { return name.map { (project: String) -> String in "\(agent) in \(project)" } ?? agent }
        guard let tab else { return "An agent outside Next Term\u{2019}s tabs" }
        return name.map { (project: String) -> String in "An agent in \(tab) of \(project)" } ?? "An agent in \(tab)"
    }

    /// A path as the banner shows it: from `~` inside the home folder, else whole.
    public static func shownPath(_ path: String, home: String) -> String {
        guard !home.isEmpty, path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// "Claude Code in shop-web asks to import keys from ~/Code/shop-web/.env.local: Move the app's keys out of
    /// .env.local". With no reason, the sentence ends at the source.
    public static func askBanner(asker: String, from source: String, reason: String?) -> String {
        let said: String = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let head: String = "\(asker) asks to import keys from \(source)"
        return said.isEmpty ? head + "." : head + ": " + said
    }
}
