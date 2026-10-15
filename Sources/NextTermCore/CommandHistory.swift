import Foundation

/// Next Term's record of the commands you ran in its zsh tabs, for suggestions while typing: one entry per distinct line,
/// with when it last ran, how many times, whether it ever succeeded and its last exit, and its folder and repository.
/// Never an agent's line, nor one with a secret (CommandAuthor, `keeps`).
///
/// Built to answer "the newest lines that start with this" in well under a millisecond at `maxEntries`: every line's UTF-8
/// bytes sit in one buffer, each entry is a fixed-size record, folders and repositories are interned, and one index of the
/// live records is sorted by their ASCII-folded bytes, then their exact bytes. A query finds the prefix's range by two
/// binary searches, keeps only exact-case matches when the prefix has a capital (smart case), and takes the newest few.
/// Because ranking is the same total order for every prefix (when it last ran, then the asking folder, the repository and
/// the count), the newest match for a longer prefix is the newest for the shorter one whenever that still matches: typing
/// through a suggestion needs no new query.
public struct CommandHistory: Sendable {
    /// Entries kept at most: past it the least recently run go, a hundredth at a time.
    public static let maxEntries = 100_000
    /// The longest line kept, in bytes.
    public static let maxLineBytes = 2048
    /// Folders and repositories kept at most, and the longest kept: past either, a run keeps none.
    public static let maxFolders = 20_000
    public static let maxFolderBytes = 1024
    /// How many matches a query gives by default: the first that passes the checks (GhostValidation) is shown.
    public static let queryLimit = 8

    /// One distinct line and what is known of its runs.
    public struct Entry: Equatable, Sendable {
        public var line: String
        /// When it last started, in milliseconds since 1970.
        public var lastRun: Int64
        public var count: Int
        /// Runs that ended in success (`succeeded(exit:)`).
        public var successes: Int
        /// The last run's exit, nil when no run of it was seen to end.
        public var lastExit: Int32?
        public var folder: String?
        public var repo: String?

        public init(line: String, lastRun: Int64, count: Int = 1, successes: Int = 0, lastExit: Int32? = nil, folder: String? = nil,
                    repo: String? = nil) {
            self.line = line
            self.lastRun = lastRun
            self.count = count
            self.successes = successes
            self.lastExit = lastExit
            self.folder = folder
            self.repo = repo
        }

        public var everSucceeded: Bool { successes > 0 }
    }

    public typealias Candidate = Entry

    /// An entry's record: where its line's bytes are, and its facts. Ids are places in `records`, stable until storage is
    /// compacted, which keeps their order.
    struct Record: Sendable {
        var offset: Int32
        var length: UInt16
        var alive: Bool
        var lastRun: Int64
        var count: UInt32
        var successes: UInt32
        var lastExit: Int32
        var folder: Int32
        var repo: Int32
    }

    static let noExit = Int32.min

    private var bytes: [UInt8] = []
    private var records: [Record] = []
    /// The live records' ids, sorted by folded bytes, then exact bytes.
    private var index: [Int32] = []
    private var deadBytes = 0
    private var deadRecords = 0
    private var folders = Interner()
    private var repos = Interner()

    public init() {}

    /// Live entries.
    public var count: Int { index.count }

    // MARK: what is kept

    /// The line as it is kept, or nil when it isn't: trailing blanks trimmed; refused when `CommandSecrets.mayKeep` refuses
    /// it (a secret, a leading space, a line break), over `maxLineBytes`, or blank.
    public static func kept(_ line: String) -> String? { kept(line, mask: .current) }

    static func kept(_ line: String, mask: SecretMask) -> String? {
        guard let trimmed = shaped(line), CommandSecrets.mayKeep(trimmed, mask: mask) else { return nil }
        return trimmed
    }

    /// The line trimmed of trailing blanks, if it has the shape of one kept: not blank, within `maxLineBytes`, no leading
    /// blank and no line break. What a line already kept is looked up by, with no secret check again (a whole file loads
    /// so); a suggestion's line is checked again before it shows.
    static func shaped(_ line: String) -> String? {
        var scalars = line.unicodeScalars[...]
        while let last = scalars.last, last == " " || last == "\t" { scalars = scalars.dropLast() }
        guard let first = scalars.first, first != " ", first != "\t", scalars.count <= maxLineBytes else { return nil }
        guard !scalars.contains(where: { $0 == "\n" || $0 == "\r" }) else { return nil }
        let trimmed = String(scalars)
        return trimmed.utf8.count <= maxLineBytes ? trimmed : nil
    }

    public static func keeps(_ line: String) -> Bool { kept(line) != nil }

    /// A run that ended so counts as having run well: exit 0, or interrupted by the user or its terminal (SIGHUP, SIGINT,
    /// SIGPIPE, SIGTERM: 129, 130, 141, 143), so a dev server stopped with ⌃C stays suggestible.
    public static func succeeded(exit: Int32) -> Bool { [0, 129, 130, 141, 143].contains(exit) }

    // MARK: changing it

    /// A run of `line` that started at `time` (ms since 1970) in `folder` and `repo`: the entry as it is now, or nil when
    /// the line isn't kept. Its count goes up, and its time, folder and repository are the latest run's.
    @discardableResult
    public mutating func record(_ line: String, folder: String?, repo: String?, at time: Int64) -> Entry? {
        record(line, folder: folder, repo: repo, at: time, mask: .current)
    }

    @discardableResult
    mutating func record(_ line: String, folder: String?, repo: String?, at time: Int64, mask: SecretMask) -> Entry? {
        guard let kept = Self.kept(line, mask: mask) else { return nil }
        let line = Array(kept.utf8)
        let place = find(line)
        let id: Int32
        if place.found {
            id = index[place.position]
            records[Int(id)].count &+= 1
            if time >= records[Int(id)].lastRun {
                records[Int(id)].lastRun = time
                records[Int(id)].folder = folders.id(for: folder)
                records[Int(id)].repo = repos.id(for: repo)
            }
        } else {
            id = append(line, lastRun: time, count: 1, successes: 0, lastExit: Self.noExit, folder: folders.id(for: folder),
                        repo: repos.id(for: repo))
            index.insert(id, at: place.position)
            if index.count > Self.maxEntries {
                dropOldest(Self.maxEntries / 100)
                // It was among the oldest itself (a run recorded late).
                let now = find(line)
                return now.found ? entry(index[now.position]) : nil
            }
        }
        return entry(id)
    }

    /// The run of `line` just recorded ended with `exit`.
    public mutating func ended(_ line: String, exit: Int32) {
        guard let kept = Self.shaped(line) else { return }
        let place = find(Array(kept.utf8))
        guard place.found else { return }
        let id = Int(index[place.position])
        records[id].lastExit = exit
        if Self.succeeded(exit: exit) { records[id].successes &+= 1 }
    }

    /// `line` is gone from the record.
    public mutating func forget(_ line: String) {
        guard let kept = Self.shaped(line) else { return }
        let place = find(Array(kept.utf8))
        guard place.found else { return }
        let id = index.remove(at: place.position)
        kill(id)
        compactIfNeeded()
    }

    public mutating func clear() {
        self = CommandHistory()
    }

    /// Entries as the history file keeps them, in its order: the last for a line wins. The index is sorted once, at the
    /// end, so a whole file loads in one pass.
    public mutating func load(_ entries: [Entry]) {
        var places: [[UInt8]: Int32] = [:]
        for entry in entries {
            guard let kept = Self.shaped(entry.line) else { continue }
            let line = Array(kept.utf8)
            let lastExit = entry.lastExit ?? Self.noExit
            let folder = folders.id(for: entry.folder), repo = repos.id(for: entry.repo)
            let count = UInt32(clamping: max(1, entry.count)), successes = UInt32(clamping: max(0, entry.successes))
            if let id = places[line] {
                records[Int(id)].lastRun = entry.lastRun
                records[Int(id)].count = count
                records[Int(id)].successes = successes
                records[Int(id)].lastExit = lastExit
                records[Int(id)].folder = folder
                records[Int(id)].repo = repo
            } else {
                places[line] = append(line, lastRun: entry.lastRun, count: count, successes: successes, lastExit: lastExit,
                                      folder: folder, repo: repo)
            }
        }
        rebuildIndex()
        if index.count > Self.maxEntries { dropOldest(index.count - Self.maxEntries) }
    }

    /// Every live entry, oldest record first: what the history file writes back.
    public func entries() -> [Entry] {
        records.indices.compactMap { records[$0].alive ? entry(Int32($0)) : nil }
    }

    // MARK: asking it

    /// The newest lines longer than `prefix` that start with it, newest first, at most `limit`: case-blind unless the
    /// prefix has a capital (smart case, ASCII letters only, so `é` compares exactly). Runs at the same millisecond go by
    /// the asking `folder`, then `repo`, then how often they ran.
    public func query(prefix: String, folder: String? = nil, repo: String? = nil, limit: Int = queryLimit) -> [Entry] {
        search(prefix: prefix, folder: folder, repo: repo, limit: limit).entries
    }

    /// `query`, with how many records it looked at: the binary searches' probes and the range's records.
    func search(prefix: String, folder: String?, repo: String?, limit: Int) -> (entries: [Entry], examined: Int) {
        let typed = Array(prefix.utf8)
        guard !typed.isEmpty, limit > 0, !index.isEmpty else { return ([], 0) }
        let folded = typed.map(Self.fold)
        let exact = typed.contains { $0 >= 0x41 && $0 <= 0x5A }
        let asking = (folder: folders.existing(folder), repo: repos.existing(repo))
        var examined = 0
        var best: [Int32] = []
        bytes.withUnsafeBufferPointer { buffer in
            let low = bound(folded, in: buffer, after: false, examined: &examined)
            let high = bound(folded, in: buffer, after: true, examined: &examined)
            for position in low..<high {
                examined += 1
                let id = index[position]
                let record = records[Int(id)]
                guard Int(record.length) > typed.count else { continue }
                if exact, !Self.starts(record, with: typed, in: buffer) { continue }
                Self.keepBest(id, in: &best, limit: limit) { self.ranks($0, above: $1, asking: asking) }
            }
        }
        return (best.map(entry), examined)
    }

    /// The order every query ranks by: the newer run first; at the same millisecond, the asking folder's, then its
    /// repository's, then the one run more often; then the older record, so the order is total.
    private func ranks(_ a: Int32, above b: Int32, asking: (folder: Int32, repo: Int32)) -> Bool {
        let x = records[Int(a)], y = records[Int(b)]
        if x.lastRun != y.lastRun { return x.lastRun > y.lastRun }
        let xFolder = asking.folder >= 0 && x.folder == asking.folder, yFolder = asking.folder >= 0 && y.folder == asking.folder
        if xFolder != yFolder { return xFolder }
        let xRepo = asking.repo >= 0 && x.repo == asking.repo, yRepo = asking.repo >= 0 && y.repo == asking.repo
        if xRepo != yRepo { return xRepo }
        if x.count != y.count { return x.count > y.count }
        return a < b
    }

    /// Keeps `id` among the `limit` best, best first.
    private static func keepBest(_ id: Int32, in best: inout [Int32], limit: Int, ranks: (Int32, Int32) -> Bool) {
        if best.count == limit, let last = best.last, !ranks(id, last) { return }
        var at = best.count
        while at > 0, ranks(id, best[at - 1]) { at -= 1 }
        best.insert(id, at: at)
        if best.count > limit { best.removeLast() }
    }

    // MARK: the index

    static func fold(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte }

    /// The first place in the index whose line's folded start is at or past `folded` (`after`: past every line that starts
    /// with it).
    private func bound(_ folded: [UInt8], in buffer: UnsafeBufferPointer<UInt8>, after: Bool, examined: inout Int) -> Int {
        var low = 0, high = index.count
        while low < high {
            let mid = (low + high) / 2
            examined += 1
            let order = Self.comparePrefix(records[Int(index[mid])], folded, in: buffer)
            if order < 0 || (after && order == 0) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// A record's folded bytes against a folded prefix: 0 when the line starts with it, else which sorts first.
    private static func comparePrefix(_ record: Record, _ folded: [UInt8], in buffer: UnsafeBufferPointer<UInt8>) -> Int {
        let start = Int(record.offset), length = Int(record.length)
        for i in 0..<min(length, folded.count) {
            let byte = fold(buffer[start + i])
            if byte != folded[i] { return byte < folded[i] ? -1 : 1 }
        }
        return length < folded.count ? -1 : 0
    }

    private static func starts(_ record: Record, with typed: [UInt8], in buffer: UnsafeBufferPointer<UInt8>) -> Bool {
        let start = Int(record.offset)
        for i in typed.indices where buffer[start + i] != typed[i] { return false }
        return true
    }

    /// Two lines in the index's order: folded bytes, then exact bytes.
    private static func compare(_ a: UnsafeBufferPointer<UInt8>.SubSequence, _ b: UnsafeBufferPointer<UInt8>.SubSequence) -> Int {
        var exact = 0
        var i = a.startIndex, j = b.startIndex
        while i < a.endIndex, j < b.endIndex {
            let x = a[i], y = b[j]
            if x != y {
                let fx = fold(x), fy = fold(y)
                if fx != fy { return fx < fy ? -1 : 1 }
                if exact == 0 { exact = x < y ? -1 : 1 }
            }
            i += 1
            j += 1
        }
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        return exact
    }

    /// Where `line` is in the index, or would go.
    private func find(_ line: [UInt8]) -> (found: Bool, position: Int) {
        guard !index.isEmpty else { return (false, 0) }
        return bytes.withUnsafeBufferPointer { buffer in
            line.withUnsafeBufferPointer { wanted in
                var low = 0, high = index.count
                while low < high {
                    let mid = (low + high) / 2
                    let order = Self.compare(slice(records[Int(index[mid])], buffer), wanted[...])
                    if order == 0 { return (true, mid) }
                    if order < 0 { low = mid + 1 } else { high = mid }
                }
                return (false, low)
            }
        }
    }

    private func slice(_ record: Record, _ buffer: UnsafeBufferPointer<UInt8>) -> UnsafeBufferPointer<UInt8>.SubSequence {
        buffer[Int(record.offset)..<(Int(record.offset) + Int(record.length))]
    }

    private mutating func rebuildIndex() {
        let live = records.indices.filter { records[$0].alive }.map { Int32($0) }
        index = bytes.withUnsafeBufferPointer { buffer in
            live.sorted { Self.compare(slice(records[Int($0)], buffer), slice(records[Int($1)], buffer)) < 0 }
        }
    }

    // MARK: storage

    private mutating func append(_ line: [UInt8], lastRun: Int64, count: UInt32, successes: UInt32, lastExit: Int32, folder: Int32,
                                 repo: Int32) -> Int32 {
        let record = Record(offset: Int32(bytes.count), length: UInt16(line.count), alive: true, lastRun: lastRun, count: count,
                            successes: successes, lastExit: lastExit, folder: folder, repo: repo)
        bytes += line
        records.append(record)
        return Int32(records.count - 1)
    }

    private mutating func kill(_ id: Int32) {
        guard records[Int(id)].alive else { return }
        records[Int(id)].alive = false
        deadBytes += Int(records[Int(id)].length)
        deadRecords += 1
    }

    /// The `amount` least recently run go, in one scan.
    private mutating func dropOldest(_ amount: Int) {
        guard amount > 0 else { return }
        let oldest = index.sorted { (a: Int32, b: Int32) -> Bool in
            let x = records[Int(a)].lastRun, y = records[Int(b)].lastRun
            return x != y ? x < y : a < b
        }
        for id in oldest.prefix(amount) { kill(id) }
        index.removeAll { !records[Int($0)].alive }
        compactIfNeeded()
    }

    /// Over a quarter of the bytes or records dead: the live ones are packed again, in their order, so ids keep their order.
    private mutating func compactIfNeeded() {
        guard deadBytes > bytes.count / 4 || deadRecords > records.count / 4, deadRecords > 0 else { return }
        var packed: [UInt8] = []
        packed.reserveCapacity(bytes.count - deadBytes)
        var kept: [Record] = []
        kept.reserveCapacity(records.count - deadRecords)
        var moved = [Int32](repeating: -1, count: records.count)
        for (id, record) in records.enumerated() where record.alive {
            var copy = record
            copy.offset = Int32(packed.count)
            packed += bytes[Int(record.offset)..<(Int(record.offset) + Int(record.length))]
            moved[id] = Int32(kept.count)
            kept.append(copy)
        }
        bytes = packed
        records = kept
        index = index.map { moved[Int($0)] }
        deadBytes = 0
        deadRecords = 0
    }

    private func entry(_ id: Int32) -> Entry {
        let record = records[Int(id)]
        let line = String(decoding: bytes[Int(record.offset)..<(Int(record.offset) + Int(record.length))], as: UTF8.self)
        return Entry(line: line, lastRun: record.lastRun, count: Int(record.count), successes: Int(record.successes),
                     lastExit: record.lastExit == Self.noExit ? nil : record.lastExit, folder: folders.name(record.folder),
                     repo: repos.name(record.repo))
    }
}

/// Names kept once each (folders, repositories), by a small id: -1 for none.
struct Interner: Sendable {
    private(set) var names: [String] = []
    private var ids: [String: Int32] = [:]

    /// `name`'s id, made for it if need be; -1 for none, a name over `maxFolderBytes`, or one past `maxFolders`.
    mutating func id(for name: String?) -> Int32 {
        guard let name, !name.isEmpty, name.utf8.count <= CommandHistory.maxFolderBytes else { return -1 }
        if let id = ids[name] { return id }
        guard names.count < CommandHistory.maxFolders else { return -1 }
        names.append(name)
        ids[name] = Int32(names.count - 1)
        return Int32(names.count - 1)
    }

    /// `name`'s id when it has one, else -1: asking makes none.
    func existing(_ name: String?) -> Int32 { name.flatMap { ids[$0] } ?? -1 }

    func name(_ id: Int32) -> String? { id >= 0 && Int(id) < names.count ? names[Int(id)] : nil }
}
