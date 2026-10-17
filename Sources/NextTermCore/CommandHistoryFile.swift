import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The record of your commands (CommandHistory) as it is kept on disk: `commands.log` in History.noindex
/// (CommandHistoryFolder), a text log that each run of a command appends one line to, compacted now and then. Tab-separated,
/// `\`, tab, newline and carriage return escaped as `\\`, `\t`, `\n` and `\r`:
///
///     nextterm-history 1                                                       the header
///     f <id> <path>                                                            a folder
///     r <id> <path>                                                            a repository (its common git folder)
///     c <last ms> <count> <successes> <last exit|-> <folder|-> <repo|-> <next> <line>   an entry's state after a run
///     x <sha-256>                                                              a line of the shell's own history, forgotten
///
/// `<next>` is what followed the entry's runs (the next command on an empty line): `-`, or how many times any command did,
/// then each one's line by its FNV-1a hash with how often, as `5/0123456789abcdef:3,fedcba9876543210:2`.
///
/// The last `c` for a line wins. A folder's or repository's id is its path's FNV-1a hash, so two copies of Next Term
/// appending to one log name each place alike. A forgotten line of the shell's history is kept by its hash alone, never its
/// text. A damaged line is skipped; a header of another version leaves the record empty and the file as it is.
public enum CommandHistoryFile {
    public static let header = "nextterm-history 1"
    /// What is read at most; the lines after it are not.
    public static let maxReadBytes = 64 * 1024 * 1024
    /// Forgotten lines kept at most.
    public static let maxForgotten = 10_000
    /// A log this big is compacted, whatever its compacted size was.
    public static let compactAt = 32 * 1024 * 1024

    /// What a log holds.
    public struct Contents: Sendable {
        public var history = CommandHistory()
        /// Forgotten lines of the shell's own history, by their SHA-256.
        public var forgotten: Set<String> = []
        /// The folder and repository ids the log names already: a run in one of them appends no `f` or `r` line.
        public var named: Set<String> = []
        /// The header is another version's: nothing is read, and nothing may be written to it.
        public var otherVersion = false
        /// The `c` lines read: over twice the entries, the log is worth compacting.
        public var runs = 0

        public init() {}
    }

    public static func decode(_ data: Data) -> Contents {
        var contents = Contents()
        let start = Data((header + "\n").utf8)
        guard data.starts(with: start) else {
            // Nothing, or a header cut short, is an empty log; anything else is another version's.
            contents.otherVersion = !start.starts(with: data)
            return contents
        }
        var folders: [String: String] = [:], repos: [String: String] = [:]
        var entries: [CommandHistory.Entry] = []
        var rest = data.dropFirst(start.count)
        // A last line with no line break was cut (the read's cap, a write that stopped): it is not read.
        while let end = rest.firstIndex(of: 0x0A) {
            let bytes = rest[rest.startIndex..<end]
            rest = rest[(end + 1)...]
            guard let line = String(bytes: bytes, encoding: .utf8) else { continue }
            let fields = line.split(separator: "\t", maxSplits: 8, omittingEmptySubsequences: false)
            switch fields.first {
            case "f"?, "r"?:
                guard fields.count == 3, isID(fields[1]), let path = unescape(fields[2]), path.hasPrefix("/"),
                      path.utf8.count <= CommandHistory.maxFolderBytes else { continue }
                if fields[0] == "f", folders.count < CommandHistory.maxFolders { folders[String(fields[1])] = path }
                if fields[0] == "r", repos.count < CommandHistory.maxFolders { repos[String(fields[1])] = path }
                contents.named.insert(String(fields[0]) + String(fields[1]))
            case "c"?:
                guard fields.count == 9, let entry = entry(fields, folders: folders, repos: repos) else { continue }
                entries.append(entry)
                contents.runs += 1
            case "x"?:
                guard fields.count == 2, isHex(fields[1], length: 64), contents.forgotten.count < maxForgotten else { continue }
                contents.forgotten.insert(String(fields[1]))
            default:
                continue
            }
        }
        contents.history.load(entries)
        return contents
    }

    private static func entry(_ fields: [Substring], folders: [String: String], repos: [String: String]) -> CommandHistory.Entry? {
        guard let lastRun = Int64(fields[1]), lastRun >= 0, let count = Int(fields[2]), count >= 1, let successes = Int(fields[3]),
              successes >= 0, let line = unescape(fields[8]) else { return nil }
        let exit: Int32?
        if fields[4] == "-" { exit = nil } else if let code = Int32(fields[4]) { exit = code } else { return nil }
        let folder = fields[5] == "-" ? nil : folders[String(fields[5])]
        let repo = fields[6] == "-" ? nil : repos[String(fields[6])]
        // What followed it, when it reads: an entry is never lost over it.
        let next = followers(fields[7])
        return CommandHistory.Entry(line: line, lastRun: lastRun, count: count, successes: successes, lastExit: exit, folder: folder,
                                    repo: repo, followers: next?.list ?? [], followed: next?.total ?? 0)
    }

    /// The `<next>` field read: nil for `-` or one this format never writes.
    static func followers(_ field: Substring) -> (total: Int, list: [CommandHistory.Follower])? {
        guard field != "-", let slash = field.firstIndex(of: "/"), let total = Int(field[..<slash]), total >= 0 else { return nil }
        var list: [CommandHistory.Follower] = []
        for item in field[field.index(after: slash)...].split(separator: ",") {
            let parts = item.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, isHex(parts[0], length: 16), let hash = UInt64(parts[0], radix: 16), let count = Int(parts[1]),
                  count > 0, list.count < CommandHistory.maxFollowers else { return nil }
            list.append(CommandHistory.Follower(hash: hash, count: count))
        }
        return (total, list)
    }

    /// The `<next>` field for `entry`.
    static func followersField(_ entry: CommandHistory.Entry) -> String {
        guard !entry.followers.isEmpty else { return "-" }
        let list = entry.followers.map { (follower: CommandHistory.Follower) -> String in
            let digits = String(follower.hash, radix: 16)
            return String(repeating: "0", count: 16 - digits.count) + digits + ":" + String(follower.count)
        }
        return String(entry.followed) + "/" + list.joined(separator: ",")
    }

    /// The whole log for `history` and `forgotten`, as compaction writes it.
    public static func encode(_ history: CommandHistory, forgotten: Set<String>) -> Data {
        var named: Set<String> = []
        return encode(history, forgotten: forgotten, named: &named)
    }

    /// `encode`, with the folder and repository ids it names.
    public static func encode(_ history: CommandHistory, forgotten: Set<String>, named: inout Set<String>) -> Data {
        named = []
        var out = Data((header + "\n").utf8)
        for entry in history.entries() { out += entryLines(entry, named: &named) }
        for hash in forgotten.sorted().prefix(maxForgotten) { out += forgottenLine(hash) }
        return out
    }

    /// Whether `log` holds a state of a line that `history` has not seen: another copy of Next Term ran it since.
    public static func hasNews(_ log: CommandHistory, for history: CommandHistory) -> Bool {
        log.entries().contains { (entry: CommandHistory.Entry) -> Bool in
            guard let held = history.entry(for: entry.line) else { return true }
            return (entry.lastRun, entry.count, entry.followed) > (held.lastRun, held.count, held.followed)
        }
    }

    /// What one run appends: an `f` and an `r` line for a folder or repository the log doesn't name yet (`named`, which
    /// gains them), then the entry's state as a `c` line.
    public static func entryLines(_ entry: CommandHistory.Entry, named: inout Set<String>) -> Data {
        var out = ""
        func place(_ kind: String, _ path: String?) -> String {
            guard let path, path.hasPrefix("/"), path.utf8.count <= CommandHistory.maxFolderBytes else { return "-" }
            let id = self.id(of: path)
            if named.insert(kind + id).inserted { out += "\(kind)\t\(id)\t\(escape(path))\n" }
            return id
        }
        let folder = place("f", entry.folder), repo = place("r", entry.repo)
        let exit = entry.lastExit.map(String.init) ?? "-"
        let next = followersField(entry)
        let fields = ["c", String(entry.lastRun), String(entry.count), String(entry.successes), exit, folder, repo, next, escape(entry.line)]
        out += fields.joined(separator: "\t") + "\n"
        return Data(out.utf8)
    }

    /// A forgotten line of the shell's own history, by its hash (`hash(of:)`).
    public static func forgottenLine(_ hash: String) -> Data { Data("x\t\(hash)\n".utf8) }

    /// A folder's or repository's id: its path's FNV-1a 64-bit hash, in hex.
    public static func id(of path: String) -> String {
        let value = fnv1a(path.utf8)
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    static func isID(_ field: Substring) -> Bool { isHex(field, length: 16) }

    /// `length` lower-case hex digits, as this format writes them.
    static func isHex(_ field: Substring, length: Int) -> Bool {
        field.utf8.count == length && field.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// FNV-1a, 64 bits.
    public static func fnv1a<Bytes: Sequence>(_ bytes: Bytes) -> UInt64 where Bytes.Element == UInt8 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// A line's SHA-256, in hex: how a forgotten line of the shell's history is kept.
    public static func hash(of line: String) -> String {
        SHA256.hash(data: Data(line.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text.unicodeScalars {
            switch character {
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.unicodeScalars.append(character)
            }
        }
        return out
    }

    /// nil for an escape this format never writes, or a raw control character it would have escaped: a damaged line.
    static func unescape(_ field: Substring) -> String? {
        var out = String.UnicodeScalarView()
        var scalars = field.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            if scalar == "\r" || scalar == "\t" { return nil }
            guard scalar == "\\" else {
                out.append(scalar)
                continue
            }
            switch scalars.next() {
            case "\\"?: out.append("\\")
            case "t"?: out.append("\t")
            case "n"?: out.append("\n")
            case "r"?: out.append("\r")
            default: return nil
            }
        }
        return String(out)
    }

    /// The entries of both, each line's later state (a later run, then more runs, then more followed) kept: what a
    /// compaction writes when another copy of Next Term appended to the log meanwhile. Lines in `dropping` are left out
    /// (forgotten since), and so is any follower they were.
    public static func merge(_ a: CommandHistory, _ b: CommandHistory, dropping: Set<String> = []) -> CommandHistory {
        var byLine: [String: CommandHistory.Entry] = [:]
        var order: [String] = []
        let dropped = Set(dropping.map { fnv1a($0.utf8) })
        for var entry in a.entries() + b.entries() where !dropping.contains(entry.line) {
            if !dropped.isEmpty {
                let gone = entry.followers.filter { dropped.contains($0.hash) }.reduce(0) { $0 + $1.count }
                entry.followers.removeAll { dropped.contains($0.hash) }
                entry.followed = max(0, entry.followed - gone)
            }
            if let held = byLine[entry.line] {
                if (entry.lastRun, entry.count, entry.followed) > (held.lastRun, held.count, held.followed) { byLine[entry.line] = entry }
            } else {
                byLine[entry.line] = entry
                order.append(entry.line)
            }
        }
        var merged = CommandHistory()
        merged.load(order.compactMap { byLine[$0] })
        return merged
    }
}

// MARK: the folder

/// `Application Support/Next Term/History.noindex`: `commands.log` and `commands.lock`.
///
/// - **Private.** Made 0700 with `PrivateFolder.make(at:)` and checked with `PrivateFolder.isPrivate` before each use: a
///   link, a file or another user's folder at its name is refused, never followed. Its `.noindex` name keeps Spotlight out.
/// - **Untrusted when read.** The log is opened without following a link and without waiting on a named pipe, and read
///   only when it is a plain file of this user's with no other name, up to the caller's cap.
/// - **Appends** open the log, write one run's lines and close it, under `flock(LOCK_SH)` on `commands.lock`, so a second
///   copy of Next Term appends to the file that is there.
/// - **Compaction** holds `LOCK_EX`: it reads the log again, merges, and replaces it through `SafeWrite.replace` expecting
///   the bytes it read, once more when they changed meanwhile.
public final class CommandHistoryFolder: @unchecked Sendable {
    public static let folderName = "History.noindex"
    public static let logName = "commands.log"
    public static let lockName = "commands.lock"

    /// Why nothing was read or written.
    public enum Failure: Error, Equatable, LocalizedError {
        /// What is at the folder's name is not a folder only this user can reach.
        case notPrivate
        /// What is at a file's name is not a plain file of this user's: a link, a folder, a file with a second name.
        case refused
        /// The log changed between the read and the write, and again on the retry.
        case changed
        case write(SafeWrite.Failure)
        case system(Int32)

        public var errorDescription: String? {
            switch self {
            case .notPrivate: return "Next Term’s history folder is not one only you can open, so Next Term doesn’t use it."
            case .refused: return "The file in Next Term’s history folder is not a plain file of yours, so Next Term doesn’t read it."
            case .changed: return "The history file changed while it was being saved, so nothing was saved."
            case .write(let failure): return failure.errorDescription
            case .system(let code): return String(cString: strerror(code)) + "."
            }
        }
    }

    public let url: URL
    let owner: uid_t
    /// Runs just before a compaction writes: the tests append there.
    var beforeWrite: (() -> Void)?

    /// The folder in Next Term's own folder in Application Support (`support`).
    public convenience init(support: URL, owner: uid_t = geteuid()) {
        self.init(url: support.appendingPathComponent(Self.folderName, isDirectory: true), owner: owner)
    }

    public init(url: URL, owner: uid_t = geteuid()) {
        self.url = url
        self.owner = owner
    }

    public var logPath: String { url.appendingPathComponent(Self.logName).path }
    private var lockPath: String { url.appendingPathComponent(Self.lockName).path }

    /// Makes the folder, 0700, when nothing is at its name; else checks that it is private.
    public func ensure() throws {
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        if lstat(url.path, &info) != 0 {
            do {
                _ = try PrivateFolder.make(at: url, owner: owner)
            } catch {
                guard lstat(url.path, &info) == 0 else { throw error } // another copy made it meanwhile: checked below
            }
        }
        try checkPrivate()
    }

    public func checkPrivate() throws {
        guard PrivateFolder.isPrivate(url.path, owner: owner) else { throw Failure.notPrivate }
    }

    /// The log's first `cap` bytes, read as untrusted input, and whether that is all of it; nil when there is none.
    public func read(cap: Int = CommandHistoryFile.maxReadBytes) throws -> (data: Data, whole: Bool)? {
        try checkPrivate()
        let descriptor = open(logPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: return nil
            case ELOOP: throw Failure.refused
            default: throw Failure.system(errno)
            }
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Failure.system(errno) }
        guard isOwnFile(info) else { throw Failure.refused }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < cap {
            let wanted = min(buffer.count, cap - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, wanted) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Failure.system(errno) }
            if count == 0 { return (data, true) }
            data.append(contentsOf: buffer[0..<count])
        }
        // At the cap: whole only if nothing follows.
        var probe: UInt8 = 0
        return (data, Darwin.read(descriptor, &probe, 1) == 0)
    }

    /// The log's size in bytes, 0 when there is none.
    public var size: Int {
        var info = stat()
        return lstat(logPath, &info) == 0 ? Int(info.st_size) : 0
    }

    /// Appends one run's lines, under the shared lock. A new log gets the header first.
    public func append(_ lines: Data) throws {
        try ensure()
        try withLock(LOCK_SH) {
            let descriptor = open(logPath, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw errno == ELOOP ? Failure.refused : Failure.system(errno) }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, isOwnFile(info) else { throw Failure.refused }
            let bytes = info.st_size == 0 ? Data((CommandHistoryFile.header + "\n").utf8) + lines : lines
            try write(bytes, to: descriptor)
        }
    }

    /// Rewrites the log under the exclusive lock: `merge` gets what it holds now (nil when there is none) and returns what
    /// to write, or nil to write nothing. When the log changed between the read and the write, it is read again and
    /// merged once more. A log too big to read whole is left as it is.
    @discardableResult
    public func compact(_ merge: (Data?) throws -> Data?) throws -> Data? {
        try ensure()
        return try withLock(LOCK_EX) {
            for attempt in 0..<2 {
                let current = try read()
                if let current, !current.whole { return nil }
                guard let new = try merge(current?.data) else { return nil }
                beforeWrite?()
                var info = stat()
                if lstat(logPath, &info) == 0 {
                    guard isOwnFile(info) else { throw Failure.refused }
                }
                do {
                    try SafeWrite.replace(logPath, with: new, expecting: current.map { .contents($0.data) } ?? .noFile, newFileMode: 0o600)
                    return new
                } catch SafeWrite.Failure.changed where attempt == 0 {
                    continue
                } catch SafeWrite.Failure.changed {
                    throw Failure.changed
                } catch let failure as SafeWrite.Failure {
                    throw Failure.write(failure)
                }
            }
            throw Failure.changed
        }
    }

    /// Removes the log, under the exclusive lock. Nothing happens when there is no folder.
    public func clear() throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        try withLock(LOCK_EX) {
            guard unlink(logPath) == 0 || errno == ENOENT else { throw Failure.system(errno) }
        }
    }

    /// Runs `body` holding `flock(operation)` on `commands.lock`, waiting for another copy of Next Term to let it go.
    private func withLock<T>(_ operation: Int32, _ body: () throws -> T) throws -> T {
        try checkPrivate()
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw errno == ELOOP ? Failure.refused : Failure.system(errno) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner else { throw Failure.refused }
        while flock(descriptor, operation) != 0 {
            guard errno == EINTR else { throw Failure.system(errno) }
        }
        return try body()
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count, let base = buffer.baseAddress {
                let count = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.system(count < 0 ? errno : EIO) }
                offset += count
            }
        }
    }

    func isOwnFile(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == owner && info.st_nlink == 1
    }
}
