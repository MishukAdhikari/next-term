import Foundation

/// The posted record's file: `Tasks.noindex/posted.jsonl` in Next Term's folder in Application Support. The folder is
/// made 0700 and the file 0600; a link or any other thing planted at either name is refused, never followed. Lines
/// are appended with `O_APPEND`, and only the newest 2 MB are ever read, from the end. Removing a line or pruning old
/// ones rewrites the file through a temporary file and a rename.
public final class TaskRecordFile: @unchecked Sendable {
    public static let folderName = "Tasks.noindex"
    public static let fileName = "posted.jsonl"
    /// The most read back: the newest lines, which are all the record is asked about.
    public static let readCap = 2 << 20

    public enum Failure: Error, Equatable {
        /// What is at the folder's name is not a folder only this user can reach.
        case notPrivate
        /// What is at the file's name is not a plain file of this user's.
        case refused
        case system(Int32)
    }

    public let folder: URL
    let owner: uid_t

    public init(support: URL, owner: uid_t = geteuid()) {
        folder = support.appendingPathComponent(Self.folderName, isDirectory: true)
        self.owner = owner
    }

    public var path: String { folder.appendingPathComponent(Self.fileName).path }

    /// Makes the folder, 0700, when nothing is at its name; else checks that it is private.
    public func ensure() throws {
        let parent = folder.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: attributes)
        }
        var info = stat()
        if lstat(folder.path, &info) != 0 {
            _ = try? PrivateFolder.make(at: folder, owner: owner) // another copy may make it meanwhile: checked below
        }
        guard PrivateFolder.isPrivate(folder.path, owner: owner) else { throw Failure.notPrivate }
    }

    /// Appends one entry's line.
    public func append(_ entry: TaskRecord.Entry) throws {
        let line = try TaskRecord.line(entry)
        try ensure()
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw errno == ELOOP ? Failure.refused : Failure.system(errno) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, isOwnFile(info) else { throw Failure.refused }
        try line.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count, let base = buffer.baseAddress {
                let count = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.system(count < 0 ? errno : EIO) }
                offset += count
            }
        }
    }

    /// The entries in the newest `cap` bytes, oldest first; none when there is no file yet.
    public func read(cap: Int = TaskRecordFile.readCap) throws -> [TaskRecord.Entry] {
        guard let tail = try readTail(cap: cap) else { return [] }
        return TaskRecord.parse(tail.data)
    }

    /// Drops the line of the item `itemID` made in `kind` (a reminder removed by Undo).
    public func remove(itemID: String, kind: TaskDestination.Kind) throws {
        try rewrite { entries in
            entries.filter { $0.itemID != itemID || $0.kind != kind }
        }
    }

    /// Drops the lines older than 30 days.
    public func prune(now: Date) throws {
        try rewrite { TaskRecord.pruned($0, now: now) }
    }

    /// Rewrites the file with what `change` keeps of its entries, through a temporary file and a rename. A file the
    /// read didn't take whole keeps only its newest lines. When it changed between the read and the write, it is read
    /// and changed once more.
    func rewrite(_ change: ([TaskRecord.Entry]) -> [TaskRecord.Entry]) throws {
        try ensure()
        for attempt in 0..<2 {
            guard let tail = try readTail(cap: Self.readCap) else { return }
            let old = TaskRecord.parse(tail.data)
            let kept = change(old)
            if kept == old, tail.whole { return }
            var data = Data()
            for entry in kept { data.append(try TaskRecord.line(entry)) }
            let expected: SafeWrite.Expectation = tail.whole ? .contents(tail.data) : .anything
            var info = stat()
            guard lstat(path, &info) == 0, isOwnFile(info) else { throw Failure.refused }
            do {
                try SafeWrite.replace(path, with: data, expecting: expected, newFileMode: 0o600)
                return
            } catch SafeWrite.Failure.changed where attempt == 0 {
                continue
            }
        }
    }

    /// The file's newest `cap` bytes, from the first whole line in them, and whether that is all of it; nil when there
    /// is no file.
    func readTail(cap: Int) throws -> (data: Data, whole: Bool)? {
        guard PrivateFolder.isPrivate(folder.path, owner: owner) else {
            var info = stat()
            if lstat(folder.path, &info) != 0, errno == ENOENT { return nil }
            throw Failure.notPrivate
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
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
        let size = Int(info.st_size)
        let start = max(0, size - cap)
        if start > 0, lseek(descriptor, off_t(start), SEEK_SET) < 0 { throw Failure.system(errno) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < cap {
            let wanted = min(buffer.count, cap - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, wanted) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Failure.system(errno) }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        guard start > 0 else { return (data, true) }
        // Started inside a line: it begins after the first newline.
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return (Data(), false) }
        return (Data(data[data.index(after: newline)...]), false)
    }

    func isOwnFile(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == owner && info.st_nlink == 1
    }
}
