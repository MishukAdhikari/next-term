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
    /// Every protected place, absolute: those in `homeFolders` under `home`, then `systemFolders`, then each spelled
    /// through the data volume (/System/Volumes/Data/Users/me/Desktop is ~/Desktop, by its firmlink).
    public let places: [String]
    /// The folders that are never a project (ProjectRoot.isNeverRoot): /, /Volumes, the data volume, the home folder and
    /// its ~/Library, each spelled through the data volume too.
    public let neverRoots: [String]
    /// Each home folder, every spelling: in one, only its own places (`homeFolders`) are protected, even when it is on a
    /// disk in /Volumes.
    let homeRoots: [String]

    /// Under the home folder: the folders macOS asks about, and ~/Library, which holds what it asks about too (Calendars,
    /// Contacts, other apps' data), with iCloud Drive (Mobile Documents) and the cloud-storage folders (Dropbox, Google
    /// Drive, OneDrive) in it. Photos and the Music library are in Pictures and Music. And the Trash, which macOS opens
    /// only to an app with Full Disk Access.
    public static let homeFolders = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Library",
                                     "Library/Mobile Documents", "Library/CloudStorage", ".Trash"]
    /// Outside it: other disks, removable and network volumes.
    public static let systemFolders = ["/Volumes"]
    /// The data volume. /Users and /Volumes are firmlinks into it, so a folder spelled through it is the same folder, and
    /// realpath(3) keeps that spelling as typed.
    static let dataVolume = "/System/Volumes/Data"
    /// `systemFolders`, spelled both ways.
    static let systemPlaces: [String] = systemFolders + systemFolders.map { (place: String) -> String in dataVolume + place }

    /// `home` is spelled as the kernel spells it (`/tmp` is `/private/tmp`); the places in it are never looked at.
    public init(home: String) { self.init(homes: [home]) }

    /// The places of each home folder, the first one `home`.
    init(homes: [String]) {
        let homes: [String] = homes.map { (home: String) -> String in Self.trimmed(canonicalPath(home)) }
        home = homes.first ?? "/"
        let inHomes: [String] = homes.flatMap { (home: String) -> [String] in
            Self.homeFolders.map { (folder: String) -> String in home + "/" + folder }
        }
        // The standardized spellings after, for `holds`: `below` and the walks start from the kernel's spelling.
        let standardHomes: [String] = inHomes.map(Self.standardized).filter { (place: String) -> Bool in !inHomes.contains(place) }
        // And through the data volume, matched by their spelling as the others: a shell's $PWD keeps what was typed, and
        // a walk from / reaches each place that way too (System/Volumes/Data/Users/me/Desktop).
        let firmlinked: [String] = (inHomes + Self.systemFolders).map { (place: String) -> String in Self.dataVolume + place }
        places = inHomes + Self.systemFolders + standardHomes + firmlinked
        // Both spellings of each: the kernel's (/private/var/…), and Foundation's standardized one (/var/…), which
        // ProjectRoot.find gives; then the data volume's.
        let roots: [String] = homes.flatMap { (home: String) -> [String] in [home, home + "/Library"] }
        let spelled: [String] = roots + roots.map(Self.standardized)
        let dataRoots: [String] = (["/Volumes"] + roots).map { (root: String) -> String in Self.dataVolume + root }
        var seen: Set<String> = []
        let never: [String] = ["/", "/Volumes", Self.dataVolume] + spelled + dataRoots
        neverRoots = never.filter { (root: String) -> Bool in seen.insert(root).inserted }
        let dataHomes: [String] = homes.map { (home: String) -> String in Self.dataVolume + home }
        homeRoots = homes + homes.map(Self.standardized) + dataHomes
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

    /// `path` is never a project: /, /Volumes, the data volume, the home folder or its ~/Library (ProjectRoot.isNeverRoot),
    /// however it is spelled.
    public func isNeverRoot(_ path: String) -> Bool {
        if neverRoots.contains(Self.trimmed(path)) || neverRoots.contains(Self.standardized(path)) { return true }
        // A differently cased spelling (/users/me, as typed, on a case-insensitive disk) is the home folder too: the
        // kernel's spelling says so. Each folder asked about is one a tab is in, or one about to be read.
        return neverRoots.contains(Self.trimmed(canonicalPath(path)))
    }

    /// Foundation's spelling of `path`: `.` and `..` resolved, /private/var as /var, no trailing slash.
    static func standardized(_ path: String) -> String {
        trimmed(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    #if DEBUG
    /// The self-test's home folder, `current`'s `home` while it is set: its places are protected beside the user's, and
    /// it is never a project, as the user's is not.
    nonisolated(unsafe) public static var homeForTest: String?
    #endif

    /// `path` is a protected place, or inside one. Read from its spelling alone: nothing on disk is looked at, as a look
    /// is what macOS asks about.
    public func holds(_ path: String) -> Bool { place(holding: path) != nil }

    /// The innermost protected place that is `path` or holds it, nil when none does; from its spelling alone, as `holds`.
    /// A home folder on another disk (/Volumes/Data/me) is not a protected place as a whole: in a home, only its own are.
    func place(holding path: String) -> String? {
        let path: String = Self.trimmed(path)
        let inside: (String) -> Bool = { (place: String) -> Bool in path == place || path.hasPrefix(place + "/") }
        let inHome: Bool = homeRoots.contains(where: inside)
        let holding: [String] = places.filter { (place: String) -> Bool in
            inside(place) && !(inHome && Self.systemPlaces.contains(place))
        }
        return holding.max { (a: String, b: String) -> Bool in a.count < b.count }
    }

    /// A look at `target`, where the link at `link` points, is one macOS asks about and the user has not asked for:
    /// `target` is in a protected place that `link` is not in (a link in ~ to ~/Documents/notes). From the spellings
    /// alone. A link inside the same place (one the user opened) may be followed, as the place's own files are read.
    public func isUnopened(_ target: String, from link: String) -> Bool {
        guard let place: String = place(holding: target) else { return false }
        let link: String = Self.trimmed(link)
        return !(link == place || link.hasPrefix(place + "/"))
    }

    /// Whether a saved project at `path`, in a protected place, is listed as there without a look in it. One on a disk
    /// in /Volumes is there while that disk is mounted (`mounted`, as `mountPoints` reads them), so one on an unplugged
    /// disk is left out and comes back with the disk; one in a place of the home folder is, and is checked when it is
    /// opened.
    public static func seemsThere(_ path: String, mounted: Set<String>) -> Bool {
        guard path.hasPrefix("/Volumes/") else { return true }
        let name: String = path.dropFirst("/Volumes/".count).split(separator: "/").first.map(String.init) ?? ""
        return mounted.contains("/Volumes/" + name)
    }

    /// The folders volumes are mounted on (/, /Volumes/Backup, …), from the kernel's mount table: nothing on any volume
    /// is read, so no disk's prompt comes from it.
    public static func mountPoints() -> Set<String> {
        let count: Int32 = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        let entries = UnsafeMutablePointer<statfs>.allocate(capacity: Int(count))
        defer { entries.deallocate() }
        let size: Int32 = Int32(MemoryLayout<statfs>.stride) * count
        let filled: Int32 = getfsstat(entries, size, MNT_NOWAIT)
        var points: Set<String> = []
        for index in 0..<Int(max(0, min(filled, count))) {
            let point: String = withUnsafeBytes(of: entries[index].f_mntonname) { (raw: UnsafeRawBufferPointer) -> String in
                String(decoding: raw.prefix { (byte: UInt8) -> Bool in byte != 0 }, as: UTF8.self)
            }
            points.insert(point)
        }
        return points
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

        /// git's pathspecs for the same rule, from the root: "." and an exclude for each place below it. Empty when
        /// nothing is left out, as git then needs none. They keep git out of an excluded place only while it lists no
        /// untracked files there or nothing in the place is tracked: listing them (`--others`, `--untracked-files`), git
        /// opens every folder on its way to a tracked file, an excluded one too. So from a root with places left out, git
        /// lists no untracked files, and every command it runs there gets these.
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
