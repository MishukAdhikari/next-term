import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The todo folder: where a task's file goes (TodoFile), so tomorrow's agent in the project reads it with its own file
/// tools and no extra permission.
/// - **In the project** by default: `todo/` at its top, or the path Settings › Tasks names. In a linked worktree it is
///   in the main checkout, so tasks outlive the worktree and every worktree shares one list. The path must stay inside
///   the project once `..` and links are resolved, and never in `.git`. A missing folder is made, with its parents,
///   only as a task is added.
/// - **One absolute folder** for every project, or for windows with no project: it must be there, and is never made.
///   One in a protected place (~/Documents, iCloud Drive) is not looked at until the user adds a task there.
/// - Files are written create-only: Next Term never changes a file another program may have open, and a name taken
///   meanwhile gets the next number.
public enum TodoFolder {
    public enum Resolution: Equatable, Sendable {
        /// Inside the project whose top folder (the main checkout's, for a linked worktree) is `root`; `mustCreate`
        /// when the folder is not there yet.
        case inProject(URL, root: String, mustCreate: Bool)
        /// An absolute folder, there as far as can be told without asking macOS. `project`: the main checkout of the
        /// window's project, which the file then names; nil for a window with no project.
        case shared(URL, project: String?)
        /// An absolute folder that is not there (an unmounted disk?): never made.
        case missing(URL)
        /// No project, and no folder for windows outside projects.
        case noProject
        /// The setting can't be used, with why.
        case refused(String)

        /// The folder the file goes in, when there is one to write to.
        public var folder: URL? {
            switch self {
            case .inProject(let url, _, _), .shared(let url, _): return url
            case .missing, .noProject, .refused: return nil
            }
        }

        /// The folder is made as the task is added.
        public var createsFolder: Bool {
            if case .inProject(_, _, true) = self { return true }
            return false
        }
    }

    /// Why a task's file was not written; nothing was.
    public enum Failure: Error, Equatable, LocalizedError {
        case missing(String)
        case notAFolder(String)
        case outsideProject
        case allNamesTaken

        public var errorDescription: String? {
            switch self {
            case .missing(let folder): return "The todo folder \(folder) is not there (an unmounted disk?)."
            case .notAFolder(let folder): return "\(folder) is a file, not a folder."
            case .outsideProject: return "The todo folder is outside the project now."
            case .allNamesTaken: return "Every name for this task is taken, up to -\(TodoFile.lastNumber), on this day."
            }
        }
    }

    /// The folder for a task in `project` (nil: a window with no project), as `settings` say. A folder outside the
    /// project is looked at only when it is not in a protected place (`places`); nothing is made.
    public static func resolve(project: String?, settings: TaskSettings, places: ProtectedPlaces = .current,
                               home: String = NSHomeDirectory()) -> Resolution {
        guard let project else {
            guard let outside = settings.outsideFolder else { return .noProject }
            return absolute(outside, project: nil, places: places, home: home)
        }
        let linked = WorktreeWindow.repository(ofLinkedWorktree: project)
        let root = canonicalPath(linked?.mainCheckout ?? project)
        if settings.isShared { return absolute(settings.folder, project: root, places: places, home: home) }
        return inside(root, settings.folder)
    }

    /// An absolute folder, `~` for `home`.
    static func absolute(_ path: String, project: String?, places: ProtectedPlaces, home: String) -> Resolution {
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst() : path
        guard let normal = lexical("/", expanded) else { return .refused("Settings › Tasks names \(path), which is not a folder.") }
        let url = URL(fileURLWithPath: normal)
        // A look in a protected place is what macOS asks about: it waits for the user's Add or Approve.
        if places.holds(normal) { return .shared(url, project: project) }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normal, isDirectory: &isFolder) else { return .missing(url) }
        guard isFolder.boolValue else { return .refused(Failure.notAFolder(shown(normal, home: home)).errorDescription ?? "") }
        return .shared(URL(fileURLWithPath: canonicalPath(normal)), project: project)
    }

    /// Why a folder setting can't be used, from its words alone, as Settings › Tasks says it while it is typed: a path in
    /// each project that leaves the project or goes into git's own folder. nil for one that can, and for an absolute one.
    public static func problem(with setting: String) -> String? {
        let folder = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty, !TaskSettings.isAbsolute(folder) else { return nil }
        guard !folder.contains("\0"), let path = lexical("/project", folder), path.hasPrefix("/project/") else {
            return "That is outside the project: name a folder inside it, such as todo."
        }
        if path.split(separator: "/").contains(where: { $0.lowercased() == ".git" }) {
            return "That is in git’s own folder: name another, such as todo."
        }
        return nil
    }

    /// `relative` in the project at `root` (a real path): inside it once `..` and links are resolved, and not in `.git`.
    static func inside(_ root: String, _ relative: String) -> Resolution {
        if let problem = problem(with: relative) { return .refused("Settings › Tasks names \(relative). " + problem) }
        let outside = Resolution.refused("Settings › Tasks names \(relative), which is outside the project; name a folder inside it, such as todo.")
        guard let path = lexical(root, relative), path.hasPrefix(root + "/") else { return outside }
        // The links on the part that is there resolved: a link to a folder elsewhere is outside.
        var existing = path
        var rest: [String] = []
        while existing.count > root.count, access(existing, F_OK) != 0 {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        let real = ([canonicalPath(existing)] + rest).joined(separator: "/")
        guard real.hasPrefix(root + "/") else { return outside }
        if rest.isEmpty {
            var isFolder: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: real, isDirectory: &isFolder)
            guard isFolder.boolValue else { return .refused(Failure.notAFolder(String(real.dropFirst(root.count + 1))).errorDescription ?? "") }
        }
        return .inProject(URL(fileURLWithPath: real), root: root, mustCreate: !rest.isEmpty)
    }

    /// `relative` joined to `base` with `.` and `..` worked out from the words alone; nil when `..` would leave `base`.
    static func lexical(_ base: String, _ relative: String) -> String? {
        var parts = base.split(separator: "/").map(String.init)
        let floor = relative.hasPrefix("/") ? 0 : parts.count
        if relative.hasPrefix("/") { parts = [] }
        for part in relative.split(separator: "/") where part != "." {
            if part == ".." {
                guard parts.count > floor else { return nil }
                parts.removeLast()
            } else {
                parts.append(String(part))
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Writes `text` as a new file in the folder, under the first of `names` (TodoFile.names) that is free, and returns
    /// it. A folder in the project is made first when it is not there; an absolute one must be. A file is never written
    /// over: one that turns up under a name meanwhile moves the task to the next name.
    public static func create(_ text: String, names: [String], in resolution: Resolution, home: String = NSHomeDirectory()) throws -> URL {
        let folder: URL
        switch resolution {
        case .inProject(let url, let root, _):
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            guard canonicalPath(url.path).hasPrefix(root + "/") else { throw Failure.outsideProject }
            folder = url
        case .shared(let url, _):
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { throw Failure.missing(shown(url.path, home: home)) }
            guard isFolder.boolValue else { throw Failure.notAFolder(shown(url.path, home: home)) }
            folder = url
        case .missing(let url):
            throw Failure.missing(shown(url.path, home: home))
        case .noProject, .refused:
            throw Failure.outsideProject
        }
        let data = Data(text.utf8)
        for name in names where !name.isEmpty && !name.contains("/") && name != "." && name != ".." {
            let file = folder.appendingPathComponent(name)
            var info = stat()
            if lstat(file.path, &info) == 0 { continue }
            do {
                try TextFile.write(data, to: file, expecting: .noFile)
                return file
            } catch SafeWrite.Failure.changed {
                continue // one turned up there meanwhile
            }
        }
        throw Failure.allNamesTaken
    }

    /// A task with this slug was added to `folder` within `seconds` of `now`: its file (`<date>-<slug>.md`, or with a
    /// number) was made since. Lists the folder: only after the user's action for a folder in a protected place.
    public static func recentDuplicate(slug: String, in folder: URL, now: Date, within seconds: TimeInterval = 60) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        for name in names where isFile(name, of: slug) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            guard let made = (attributes?[.creationDate] ?? attributes?[.modificationDate]) as? Date else { continue }
            if now.timeIntervalSince(made) <= seconds, made.timeIntervalSince(now) < seconds { return true }
        }
        return false
    }

    /// `name` is a todo file's name for `slug`: a date, the slug, maybe a number, `.md`.
    static func isFile(_ name: String, of slug: String) -> Bool {
        guard name.hasSuffix(".md") else { return false }
        let stem = name.dropLast(3)
        guard stem.count > 11, TaskDay(String(stem.prefix(10))) != nil, stem.dropFirst(10).first == "-" else { return false }
        let rest = String(stem.dropFirst(11))
        if rest == slug { return true }
        guard rest.hasPrefix(slug + "-") else { return false }
        let number = rest.dropFirst(slug.count + 1)
        return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Whether the file still holds what was written: Undo moves it to the Trash only then.
    public static func isUnchanged(_ url: URL, _ text: String) -> Bool {
        FileManager.default.contents(atPath: url.path) == Data(text.utf8)
    }

    /// Where a file named `name` goes, as the sheet and the approval say it: `todo/2026-10-15-x.md in next-term`, or
    /// `~/Notes/Todo/2026-10-15-x.md`.
    public static func shownFile(_ name: String, in resolution: Resolution, home: String = NSHomeDirectory()) -> String {
        switch resolution {
        case .inProject(let url, let root, _):
            let relative = String(url.path.dropFirst(root.count + 1))
            return relative + "/" + name + " in " + (root as NSString).lastPathComponent
        case .shared(let url, _), .missing(let url):
            return shown(url.path, home: home) + "/" + name
        case .noProject, .refused:
            return name
        }
    }

    /// A path with the home folder as `~`.
    public static func shown(_ path: String, home: String = NSHomeDirectory()) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
