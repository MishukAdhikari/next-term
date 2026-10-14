import Foundation

/// The places macOS guards with a privacy prompt ("Next Term would like to access files in your Documents folder"): a
/// listing of one, or a look at a file in it, asks the user, and the answer is kept. Next Term itself only goes there
/// when the user did something that goes there. Every walk it starts on its own (the Databases scan and the rescans file
/// changes set off, git's status, Go to File and Find in Files, the PATH probes at launch, the Welcome window's look at
/// its projects) leaves out each protected place below the folder it starts from (`walk(from:)`), so a prompt never comes
/// from nowhere. The folder it starts from is walked whatever it is in: the user chose it, and a project in ~/Documents
/// is scanned as any other once it is open.
public struct ProtectedPlaces: Sendable, Equatable {
    /// The home folder, as the kernel spells it.
    public let home: String
    /// Every protected place, absolute: those in `homeFolders` under `home`, then `systemFolders`.
    public let places: [String]
    /// The folders that are never a project (ProjectRoot.isNeverRoot): /, /Volumes, the home folder and its ~/Library.
    public let neverRoots: [String]

    /// Under the home folder: the folders macOS asks about, and ~/Library, which holds what it asks about too (Calendars,
    /// Contacts, other apps' data), with iCloud Drive (Mobile Documents) and the cloud-storage folders (Dropbox, Google
    /// Drive, OneDrive) in it. Photos and the Music library are in Pictures and Music.
    public static let homeFolders = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Library",
                                     "Library/Mobile Documents", "Library/CloudStorage"]
    /// Outside it: other disks, removable and network volumes.
    public static let systemFolders = ["/Volumes"]

    /// `home` is spelled as the kernel spells it (`/tmp` is `/private/tmp`); the places in it are never looked at.
    public init(home: String) { self.init(homes: [home]) }

    /// The places of each home folder, the first one `home`.
    init(homes: [String]) {
        let homes: [String] = homes.map { (home: String) -> String in Self.trimmed(canonicalPath(home)) }
        home = homes.first ?? "/"
        let inHomes: [String] = homes.flatMap { (home: String) -> [String] in
            Self.homeFolders.map { (folder: String) -> String in home + "/" + folder }
        }
        places = inHomes + Self.systemFolders
        neverRoots = ["/", "/Volumes"] + homes.flatMap { (home: String) -> [String] in [home, home + "/Library"] }
    }

    /// The user's.
    private static let user = ProtectedPlaces(home: NSHomeDirectory())

    /// This Mac's: the user's home folder's. In a debug build the self-test gives it a home of its own (`homeForTest`),
    /// so its windows and walks meet a Desktop and a Documents it made, the user's own still protected beside it.
    public static var current: ProtectedPlaces {
        #if DEBUG
        if let home = homeForTest { return ProtectedPlaces(homes: [home, user.home]) }
        #endif
        return user
    }

    /// `path` is never a project: /, /Volumes, the home folder or its ~/Library (ProjectRoot.isNeverRoot).
    public func isNeverRoot(_ path: String) -> Bool {
        let path: String = Self.trimmed(URL(fileURLWithPath: path).standardizedFileURL.path)
        return neverRoots.contains(path)
    }

    #if DEBUG
    /// The self-test's home folder, `current`'s `home` while it is set: its places are protected beside the user's, and
    /// it is never a project, as the user's is not.
    nonisolated(unsafe) public static var homeForTest: String?
    #endif

    /// `path` is a protected place, or inside one. Read from its spelling alone: nothing on disk is looked at, as a look
    /// is what macOS asks about.
    public func holds(_ path: String) -> Bool {
        let path: String = Self.trimmed(path)
        return places.contains { (place: String) -> Bool in path == place || path.hasPrefix(place + "/") }
    }

    /// The protected places below `root`, relative to it: "Desktop" from the home folder, "me/Desktop" from /Users.
    /// None from a folder inside one, but those inside it (~/Library/CloudStorage from ~/Library).
    public func below(_ root: String) -> [String] {
        let root: String = Self.trimmed(canonicalPath(root))
        let prefix: String = root == "/" ? "/" : root + "/"
        return places.compactMap { (place: String) -> String? in
            place.hasPrefix(prefix) ? String(place.dropFirst(prefix.count)) : nil
        }
    }

    /// What a walk from `root` leaves out, asked of each folder before it is listed.
    public func walk(from root: String) -> Walk { Walk(root: root, skipped: Set(below(root))) }

    /// One walk's rule: never into a protected place below its root, nor anything in one.
    public struct Walk: Sendable {
        /// Where the walk starts, as its caller spells it.
        public let root: String
        /// The protected places below it, relative to it.
        public let skipped: Set<String>

        /// Whether the walk may list `relative`, a folder below its root as the walk spells it from there ("src/app").
        public func mayEnter(_ relative: String) -> Bool {
            guard !skipped.isEmpty else { return true }
            if skipped.contains(relative) { return false }
            return !skipped.contains { (place: String) -> Bool in relative.hasPrefix(place + "/") }
        }

        /// git's pathspecs for the same rule, from the root: "." and an exclude for each place below it, so git never
        /// opens them (an excluded folder is not read at all). Empty when nothing is left out, as git then needs none.
        public var gitPathspecs: [String] {
            guard !skipped.isEmpty else { return [] }
            return ["."] + skipped.sorted().map { (place: String) -> String in ":(exclude,literal)" + place }
        }
    }

    /// Without a trailing slash, but "/" as it is.
    static func trimmed(_ path: String) -> String {
        var path: String = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    #if DEBUG
    /// For the self-test: every folder the walks list while it records, so it can check none was a protected place.
    public static let listed = ListedFolders()

    /// The folders listed so far, from any thread.
    public final class ListedFolders: @unchecked Sendable {
        private let lock = NSLock()
        private var recording = false
        private var folders: [String] = []

        /// Starts afresh.
        public func start() {
            lock.lock()
            recording = true
            folders = []
            lock.unlock()
        }

        /// What was listed since `start`, and stops.
        public func stop() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            recording = false
            return folders
        }

        public func note(_ folder: String) {
            lock.lock()
            if recording { folders.append(folder) }
            lock.unlock()
        }
    }
    #endif

    /// A walk lists `folder` (debug builds note it for the self-test; release builds do nothing).
    @inline(__always)
    public static func noteListed(_ folder: @autoclosure () -> String) {
        #if DEBUG
        listed.note(folder())
        #endif
    }
}

extension ProjectRoot {
    /// Never a project, whoever asks: the home folder, /, /Volumes and ~/Library, the folders every other one is in (the
    /// protected places among them). A git repository there is none either: dotfiles kept in ~ make it a work tree, and
    /// its status would read the whole home folder. A window whose tab is in one shows no files. `home`: the user's when
    /// nil (ProtectedPlaces.current).
    public static func isNeverRoot(_ path: String, home: String? = nil) -> Bool {
        let places: ProtectedPlaces = home.map { (home: String) -> ProtectedPlaces in ProtectedPlaces(home: home) } ?? .current
        return places.isNeverRoot(path)
    }

    /// The project `directory` is in, by that rule: its nearest git work tree, else the directory itself (as `find`), but
    /// never a folder that is never a project. In a repository that may not be one (dotfiles in ~) it is the directory
    /// itself, as outside a repository. nil when that is never one either: a shell in the home folder has no project.
    public static func project(from directory: String, home: String? = nil, fileManager: FileManager = .default) -> String? {
        let places: ProtectedPlaces = home.map { (home: String) -> ProtectedPlaces in ProtectedPlaces(home: home) } ?? .current
        let found: String = find(from: directory, home: places.home, fileManager: fileManager)
        if !places.isNeverRoot(found) { return found }
        let own: String = URL(fileURLWithPath: directory).standardizedFileURL.path
        return places.isNeverRoot(own) ? nil : own
    }
}
