import Foundation

/// Next Term's own folder and file engine for Tab completion, where zsh's completion system isn't loaded: a
/// folder read with readdir (its d_type says folder, file or link without a stat), then ranked by
/// CompletionRanking. Only the links and unknown types among the matches shown get a stat. A folder that
/// can't be read in time gives no candidates, so zsh's own Tab answers.
public enum PathCompletion {
    public static let maxEntries = 20_000
    public static let maxSeconds = 0.1
    public static let maxShown = CompletionProtocol.maxMatches

    public enum Kind: Equatable, Sendable {
        case folder
        case file
        /// A symbolic link: a folder or a file once followed, or broken.
        case link
        /// The file system didn't say (some network volumes).
        case unknown
    }

    public struct Entry: Equatable, Sendable {
        /// The name on disk, byte for byte: what is inserted.
        public var name: [UInt8]
        public var kind: Kind

        public init(name: [UInt8], kind: Kind) {
            self.name = name
            self.kind = kind
        }

        public init(_ name: String, _ kind: Kind) {
            self.init(name: Array(name.utf8), kind: kind)
        }

        /// The name as text; bytes that aren't UTF-8 show as U+FFFD.
        public var display: String { String(decoding: name, as: UTF8.self) }
        public var isHidden: Bool { name.first == UInt8(ascii: ".") }
    }

    public struct Listing: Sendable {
        public var folder: String
        /// The entries kept: at most `maxEntries`.
        public var entries: [Entry]
        /// Entries read past the cap, counted only, by whether they would be shown.
        public var uncounted = Counts()
        /// Every entry was read and kept.
        public var complete: Bool
        /// Every entry was read (kept or counted).
        public var allSeen: Bool
        /// False: the folder couldn't be read, or not in time. No candidates then.
        public var readable: Bool

        public init(folder: String, entries: [Entry], complete: Bool = true, allSeen: Bool = true, readable: Bool = true) {
            self.folder = folder
            self.entries = entries
            self.complete = complete
            self.allSeen = allSeen
            self.readable = readable
        }
    }

    /// Entries counted but not kept: folders and others, hidden or not.
    public struct Counts: Equatable, Sendable {
        public var folders = 0
        public var hiddenFolders = 0
        public var others = 0
        public var hiddenOthers = 0
        public init() {}
    }

    public struct Candidate: Equatable, Sendable {
        public var name: [UInt8]
        public var display: String
        public var isFolder: Bool
        /// A folder that can't be entered (shown dimmed).
        public var enterable: Bool
        public var prefix: Bool
        public var highlights: [Int]
    }

    public struct Result: Equatable, Sendable {
        /// The best `maxShown` at most.
        public var candidates: [Candidate]
        /// How many match in all; `exact` false when the folder had more entries than were kept.
        public var total: Int
        public var exact: Bool

        public init(candidates: [Candidate] = [], total: Int = 0, exact: Bool = true) {
            self.candidates = candidates
            self.total = total
            self.exact = exact
        }
    }

    /// Lists `entry` by entry, calling `found` for each until it returns false. False: the folder can't be read.
    public typealias Reader = (_ folder: String, _ found: (Entry) -> Bool) -> Bool

    /// Reads `folder`, keeping `limit` entries and counting the rest, within `seconds`. Past the time with the
    /// entries not all kept, the listing is unreadable; past it once `limit` are kept, they stand.
    public static func list(_ folder: String, limit: Int = maxEntries, seconds: Double = maxSeconds,
                            read: Reader = readDirectory) -> Listing {
        let start = DispatchTime.now().uptimeNanoseconds
        let budget = UInt64(seconds * 1_000_000_000)
        var listing = Listing(folder: folder, entries: [])
        var seen = 0
        var late = false
        let readable = read(folder) { entry in
            seen += 1
            if seen & 63 == 0, DispatchTime.now().uptimeNanoseconds - start > budget {
                late = true
                return false
            }
            if listing.entries.count < limit {
                listing.entries.append(entry)
            } else {
                count(entry, into: &listing.uncounted)
            }
            return true
        }
        if !readable || (late && listing.entries.count < limit) {
            return Listing(folder: folder, entries: [], complete: false, allSeen: false, readable: false)
        }
        listing.allSeen = !late
        listing.complete = !late && listing.entries.count < limit
        return listing
    }

    private static func count(_ entry: Entry, into counts: inout Counts) {
        switch (entry.kind == .folder, entry.isHidden) {
        case (true, false): counts.folders += 1
        case (true, true): counts.hiddenFolders += 1
        case (false, false): counts.others += 1
        case (false, true): counts.hiddenOthers += 1
        }
    }

    /// readdir: `.` and `..` left out; d_type for the kind.
    public static func readDirectory(_ folder: String, _ found: (Entry) -> Bool) -> Bool {
        guard let dir = opendir(folder) else { return false }
        defer { closedir(dir) }
        while let pointer = readdir(dir) {
            let length = Int(pointer.pointee.d_namlen)
            let name: [UInt8] = withUnsafeBytes(of: &pointer.pointee.d_name) { Array($0.prefix(length)) }
            if name == [0x2E] || name == [0x2E, 0x2E] { continue }
            let kind: Kind
            switch Int32(pointer.pointee.d_type) {
            case DT_DIR: kind = .folder
            case DT_LNK: kind = .link
            case DT_UNKNOWN: kind = .unknown
            default: kind = .file
            }
            if !found(Entry(name: name, kind: kind)) { break }
        }
        return true
    }

    /// What a link or an unknown entry is, followed: a folder, a file, or nothing (broken).
    public enum Followed: Sendable {
        case folder
        case file
        case missing
    }

    /// `path`: the bytes of an absolute path (a name on disk need not be UTF-8).
    public static func follow(_ path: [UInt8]) -> Followed {
        var info = stat()
        let found = (path + [0]).withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) { stat($0.baseAddress!, &info) == 0 }
        }
        guard found else { return .missing }
        return info.st_mode & S_IFMT == S_IFDIR ? .folder : .file
    }

    public static func canEnter(_ path: [UInt8]) -> Bool {
        (path + [0]).withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) { access($0.baseAddress!, X_OK) == 0 }
        }
    }

    /// How a listing's links are followed and its folders tried: on this Mac's disk, or as a server said
    /// (RemoteListing).
    public struct Disk: Sendable {
        public var follow: @Sendable ([UInt8]) -> Followed
        public var canEnter: @Sendable ([UInt8]) -> Bool

        public init(follow: @escaping @Sendable ([UInt8]) -> Followed, canEnter: @escaping @Sendable ([UInt8]) -> Bool) {
            self.follow = follow
            self.canEnter = canEnter
        }

        public static let local = Disk(follow: { PathCompletion.follow($0) }, canEnter: { PathCompletion.canEnter($0) })
    }

    /// A listing narrowed to what a completion can offer (folders only or not, hidden or not), ranked again
    /// for each word typed.
    public final class Prepared: @unchecked Sendable {
        public let folder: String
        public let foldersOnly: Bool
        public let hidden: Bool
        public let disk: Disk
        private let entries: [Entry]
        private let ranking: CompletionRanking
        private let extra: Int
        private let complete: Bool
        private let allSeen: Bool
        /// What a link followed or a folder entered gave, by entry, so narrowing the list again asks the disk
        /// nothing new. One thread at a time uses a Prepared.
        private var followed: [Int: Followed] = [:]
        private var entered: [Int: Bool] = [:]

        public init(_ listing: Listing, foldersOnly: Bool, hidden: Bool, disk: Disk = .local) {
            folder = listing.folder
            self.foldersOnly = foldersOnly
            self.hidden = hidden
            self.disk = disk
            let kept = listing.entries.filter { entry in
                (hidden || !entry.isHidden) && (!foldersOnly || entry.kind != .file)
            }
            entries = kept
            ranking = CompletionRanking(names: kept.map(\.display))
            let counts = listing.uncounted
            let folders = counts.folders + (hidden ? counts.hiddenFolders : 0)
            let others = foldersOnly ? 0 : counts.others + (hidden ? counts.hiddenOthers : 0)
            extra = folders + others
            complete = listing.complete
            allSeen = listing.allSeen
        }

        /// The candidates for the name typed so far, best first, `limit` at most. `follow` and `canEnter` take
        /// absolute paths as bytes (tests stand in for the disk); without them, the listing's own `disk` answers.
        public func candidates(_ typed: String, limit: Int = maxShown, follow: (([UInt8]) -> Followed)? = nil,
                               canEnter: (([UInt8]) -> Bool)? = nil) -> Result {
            let follow = follow ?? disk.follow
            let canEnter = canEnter ?? disk.canEnter
            let ranked = ranking.rank(typed)
            let base = Array(folder.utf8) + (folder.hasSuffix("/") ? [] : [UInt8(ascii: "/")])
            var shown: [Candidate] = []
            var dropped = 0
            for item in ranked {
                if shown.count >= limit { break }
                let entry = entries[item.index]
                let path = base + entry.name
                var isFolder = entry.kind == .folder
                if entry.kind == .link || entry.kind == .unknown {
                    let kind = followed[item.index] ?? follow(path)
                    followed[item.index] = kind
                    // A link to nothing names no folder; as a path it is still a name.
                    if foldersOnly, kind != .folder {
                        dropped += 1
                        continue
                    }
                    isFolder = kind == .folder
                }
                var enterable = true
                if isFolder {
                    enterable = entered[item.index] ?? canEnter(path)
                    entered[item.index] = enterable
                }
                shown.append(Candidate(name: entry.name, display: entry.display, isFolder: isFolder, enterable: enterable,
                                       prefix: item.prefix, highlights: item.highlights))
            }
            let unread = typed.isEmpty ? extra : 0
            let total = ranked.count - dropped + unread
            return Result(candidates: shown, total: total, exact: complete || (typed.isEmpty && allSeen))
        }
    }
}

/// One folder listing at a time per tab: readdir can hang on a stuck volume and can't be stopped, so while one
/// is still running another Tab gets no listing (zsh's own Tab answers) and starts no thread.
public final class PathLister: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private let read: (String) -> PathCompletion.Listing
    private let queue = DispatchQueue(label: "nextterm.tab-completion", qos: .userInitiated)

    public init(read: @escaping (String) -> PathCompletion.Listing = { PathCompletion.list($0) }) {
        self.read = read
    }

    public var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return busy
    }

    /// Lists `folder` off the calling thread and hands the listing to `done` (on that queue). False, and
    /// nothing started, while the last listing is still running.
    public func start(_ folder: String, done: @escaping (PathCompletion.Listing) -> Void) -> Bool {
        lock.lock()
        if busy {
            lock.unlock()
            return false
        }
        busy = true
        lock.unlock()
        queue.async { [self] in
            let listing = read(folder)
            lock.lock()
            busy = false
            lock.unlock()
            done(listing)
        }
        return true
    }
}
