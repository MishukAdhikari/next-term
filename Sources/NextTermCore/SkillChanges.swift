import CryptoKit
import Darwin
import Foundation

/// Carrying out SkillSteps on disk, and undoing them, so that nothing is lost on the way:
/// - Before anything is touched, every step is checked: a folder that is read-only or locked (Finder's
///   Lock), or a file that can't be read, stops the change with a reason, and nothing moves.
/// - What is replaced goes to the Trash; links are removed and remade exactly. Undo moves what a change
///   made to the Trash too, rather than deleting it, so anything a check could miss stays recoverable.
/// - If a step fails, what was done is put back. If that fails too, the message says so, and what is
///   left to put back is kept for Undo, which can then finish the job.
/// - Undo first checks that everything the change left is still exactly as it left it (an exact
///   fingerprint that leaves nothing out), and refuses, changing nothing, when it isn't.
public struct SkillChanges {
    public struct Failure: Error, Equatable, Sendable {
        public let message: String
        public init(message: String) { self.message = message }
    }

    /// One change, recorded for Undo.
    public struct Change: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case trashed, removedLink, created, moved, editedLock, editedRecord }
        public struct Entry: Codable, Equatable, Sendable {
            public var kind: Kind
            /// Where it was (trashed, removedLink), what was made or moved into place (created, moved),
            /// or the file edited (editedLock, editedRecord).
            public var path: String
            /// trashed: the Trash's copy. removedLink: the link's target. moved: where it came from.
            /// edited: the entry's name.
            public var other: String?
            /// edited: the entry before, as the file held it (nil: there was none).
            public var previous: String?
            /// created, moved: a fingerprint of what the step left. edited: the entry after (nil: removed).
            public var left: String?

            public init(kind: Kind, path: String, other: String? = nil, previous: String? = nil, left: String? = nil) {
                self.kind = kind
                self.path = path
                self.other = other
                self.previous = previous
                self.left = left
            }
        }
        public var title: String
        public var entries: [Entry]
        public var date: Date

        public init(title: String, entries: [Entry] = [], date: Date = Date()) {
            self.title = title
            self.entries = entries
            self.date = date
        }
    }

    /// Where the change Undo would reverse is kept (it survives quitting).
    public let undoFile: String
    /// Moves an item to the Trash and says where it went.
    public let trash: (String) throws -> String

    public init(undoFile: String, trash: @escaping (String) throws -> String = SkillChanges.systemTrash) {
        self.undoFile = undoFile
        self.trash = trash
    }

    /// The Finder's Trash.
    public static func systemTrash(_ path: String) throws -> String {
        var result: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
        guard let moved = result?.path else {
            throw Failure(message: "\(SkillStep.short(path)) went to the Trash, but macOS did not say where.")
        }
        return moved
    }

    /// A folder standing in for the Trash (tests, and the self-test's own home).
    public static func folderTrash(_ folder: String) -> (String) throws -> String {
        { path in
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let target = (folder as NSString).appendingPathComponent(UUID().uuidString + "-" + (path as NSString).lastPathComponent)
            try FileManager.default.moveItem(atPath: path, toPath: target)
            return target
        }
    }

    // MARK: the record

    public var lastChange: Change? {
        guard let data = FileManager.default.contents(atPath: undoFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Change.self, from: data)
    }

    func remember(_ change: Change?) {
        guard let change, !change.entries.isEmpty else {
            try? FileManager.default.removeItem(atPath: undoFile)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(change) else { return }
        try? FileManager.default.createDirectory(atPath: (undoFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: undoFile), options: .atomic)
    }

    // MARK: checks before doing anything

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func isLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    static func isLocked(_ info: stat) -> Bool {
        let locks = UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND) | UInt32(SF_IMMUTABLE) | UInt32(SF_APPEND)
        return info.st_flags & locks != 0
    }

    /// The nearest folder above `path` that exists can take a new entry.
    static func canCreate(in path: String) -> Bool {
        var folder = (path as NSString).deletingLastPathComponent
        while !folder.isEmpty {
            if FileManager.default.fileExists(atPath: folder) { return access(folder, W_OK) == 0 }
            let up = (folder as NSString).deletingLastPathComponent
            if up == folder { break }
            folder = up
        }
        return false
    }

    /// Why an item can't be moved (to the Trash, or into place), or nil.
    static func moveProblem(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let short = SkillStep.short(path)
        if isLocked(info) { return "\(short) is locked (Finder's Lock). Unlock it first." }
        if access((path as NSString).deletingLastPathComponent, W_OK) != 0 { return "The folder holding \(short) is read-only." }
        // Moving a folder to another folder rewrites its "..": the folder itself must be writable.
        if (info.st_mode & S_IFMT) == S_IFDIR, access(path, W_OK) != 0 { return "\(short) is read-only. Make it writable first." }
        return nil
    }

    /// Why a folder can't be copied so that the copy can later be moved or put away again, or nil: a
    /// read-only folder, a locked item or an unreadable file inside it.
    static func treeProblem(_ path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return "\(SkillStep.short(path)) is not there any more." }
        if isLocked(info) { return "\(SkillStep.short(path)) is locked (Finder's Lock). Unlock it first." }
        if (info.st_mode & S_IFMT) == S_IFDIR, info.st_mode & S_IWUSR == 0 { return "\(SkillStep.short(path)) is read-only. Make it writable first." }
        guard let walker = FileManager.default.enumerator(atPath: path) else { return nil }
        while let relative = walker.nextObject() as? String {
            let full = (path as NSString).appendingPathComponent(relative)
            guard lstat(full, &info) == 0 else { continue }
            let short = SkillStep.short(full)
            if isLocked(info) { return "\(short) is locked (Finder's Lock). Unlock it first." }
            switch info.st_mode & S_IFMT {
            case S_IFDIR where info.st_mode & S_IWUSR == 0: return "\(short) is a read-only folder. Make it writable first."
            case S_IFREG where access(full, R_OK) != 0: return "\(short) can't be read."
            default: continue
            }
        }
        return nil
    }

    /// Checks every step against the disk as it will be when that step runs. nil: all can run.
    func preflight(_ steps: [SkillStep]) -> String? {
        var gone = Set<String>()
        var made = Set<String>()
        func isFree(_ path: String) -> Bool { made.contains(path) ? false : gone.contains(path) || !Self.exists(path) }
        for step in steps {
            switch step {
            case .trash(let path):
                guard Self.exists(path), !gone.contains(path) else { continue }
                if !made.contains(path), let problem = Self.moveProblem(path) { return problem }
                gone.insert(path)
                made.remove(path)
            case .copy(let from, let to):
                if let problem = Self.treeProblem(from) { return problem }
                guard isFree(to) else { return "\(SkillStep.short(to)) is already there." }
                guard Self.canCreate(in: to) else { return "The folder for \(SkillStep.short(to)) is read-only." }
                made.insert(to)
            case .move(let from, let to):
                guard made.contains(from) || Self.exists(from) else { return "\(SkillStep.short(from)) is not there." }
                guard isFree(to) else { return "\(SkillStep.short(to)) is already there." }
                guard Self.canCreate(in: to) else { return "The folder for \(SkillStep.short(to)) is read-only." }
                made.remove(from)
                gone.insert(from)
                made.insert(to)
            case .link(let at, _):
                guard isFree(at) else { return "\(SkillStep.short(at)) is already there." }
                guard Self.canCreate(in: at) else { return "The folder for \(SkillStep.short(at)) is read-only." }
                made.insert(at)
            case .lockEntry(let path, _, _), .recordEntry(let path, _, _):
                let real = Self.resolvedFile(path)
                if Self.exists(real), access(real, W_OK) != 0 { return "\(SkillStep.short(path)) is read-only." }
                if !Self.exists(real), !Self.canCreate(in: real) { return "The folder for \(SkillStep.short(path)) is read-only." }
            }
        }
        return nil
    }

    // MARK: fingerprints

    /// What is at a path, exactly: a link's target; a file's mode and content; a folder's every entry
    /// (git data and caches included). Unreadable entries count by size, date and inode. nil: nothing there.
    public static func fingerprint(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return "link:" + ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "")
        case S_IFREG: return "file:" + describe(path, info)
        case S_IFDIR:
            var lines: [String] = []
            let walker = FileManager.default.enumerator(atPath: path)
            while let relative = walker?.nextObject() as? String {
                let full = (path as NSString).appendingPathComponent(relative)
                var entry = stat()
                guard lstat(full, &entry) == 0 else { continue }
                lines.append(relative + "\0" + describe(full, entry))
            }
            var hasher = SHA256()
            hasher.update(data: Data(String(format: "%o", info.st_mode & 0o7777).utf8))
            for line in lines.sorted() { hasher.update(data: Data((line + "\n").utf8)) }
            return "folder:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
        default: return "other:\(info.st_mode)"
        }
    }

    static func describe(_ path: String, _ info: stat) -> String {
        let mode = String(format: "%o", info.st_mode)
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return "\(mode) link " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "")
        case S_IFREG:
            if let digest = SkillHash.fileDigest(path) { return "\(mode) \(info.st_size) \(digest)" }
            return "\(mode) \(info.st_size) unreadable \(info.st_mtimespec.tv_sec) \(info.st_ino)"
        default: return mode
        }
    }

    /// A file path with a link resolved (a lock file kept in a dotfiles folder): writes go to the real file.
    static func resolvedFile(_ path: String) -> String {
        guard isLink(path), let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    /// The real path of a folder, or of the nearest one above it that exists, plus the rest.
    static func realPath(_ path: String) -> String {
        if let real = realpath(path, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path, !parent.isEmpty else { return path }
        return (realPath(parent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    /// The target to write in a link at `at` so that it reaches `to`: relative between the two real
    /// folders (the system resolves a link from where it physically is, so a ~/.claude that is itself a
    /// link to a dotfiles folder counts), or absolute when they share nothing below the root.
    static func linkTarget(at: String, to: String) -> String {
        let from = realPath((at as NSString).deletingLastPathComponent)
        let target = realPath(to)
        let fromParts = from.split(separator: "/")
        let targetParts = target.split(separator: "/")
        var common = 0
        while common < fromParts.count, common < targetParts.count, fromParts[common] == targetParts[common] { common += 1 }
        guard common > 1 else { return target }
        let ups = Array(repeating: "..", count: fromParts.count - common)
        return (ups + targetParts[common...].map(String.init)).joined(separator: "/")
    }

    // MARK: doing

    /// Carries out the steps in order, after checking them all. On a failure, what was done so far is
    /// put back; the message says whether that worked. On success, the change becomes the one Undo
    /// reverses.
    public func apply(_ steps: [SkillStep], title: String) -> Result<Void, Failure> {
        if let problem = preflight(steps) { return .failure(Failure(message: problem + " Nothing was changed.")) }
        var change = Change(title: title)
        let manager = FileManager.default
        for step in steps {
            do {
                switch step {
                case .trash(let path):
                    guard Self.exists(path) else { continue } // already gone
                    if Self.isLink(path) {
                        // A link: remove the link itself, never what it points to; remember its target.
                        let target = try manager.destinationOfSymbolicLink(atPath: path)
                        guard unlink(path) == 0 else { throw Failure(message: "Could not remove the link \(SkillStep.short(path)).") }
                        change.entries.append(.init(kind: .removedLink, path: path, other: target))
                    } else {
                        let trashed = try trash(path)
                        change.entries.append(.init(kind: .trashed, path: path, other: trashed))
                    }
                case .copy(let from, let to):
                    guard !Self.exists(to) else { throw Failure(message: "\(SkillStep.short(to)) is already there.") }
                    try manager.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    // Recorded before copying, so a copy that fails half-way is put away too.
                    change.entries.append(.init(kind: .created, path: to))
                    try manager.copyItem(atPath: from, toPath: to)
                    change.entries[change.entries.count - 1].left = Self.fingerprint(to)
                case .move(let from, let to):
                    guard !Self.exists(to) else { throw Failure(message: "\(SkillStep.short(to)) is already there.") }
                    try manager.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try manager.moveItem(atPath: from, toPath: to)
                    change.entries.append(.init(kind: .moved, path: to, other: from, left: Self.fingerprint(to)))
                case .link(let at, let to):
                    try manager.createDirectory(atPath: (at as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try manager.createSymbolicLink(atPath: at, withDestinationPath: Self.linkTarget(at: at, to: to))
                    change.entries.append(.init(kind: .created, path: at, left: Self.fingerprint(at)))
                    // The link must reach a skill, or Claude Code would be left without it.
                    var isFolder: ObjCBool = false
                    let skill = (at as NSString).appendingPathComponent("SKILL.md")
                    guard manager.fileExists(atPath: at, isDirectory: &isFolder), isFolder.boolValue,
                          manager.fileExists(atPath: skill) || manager.fileExists(atPath: (at as NSString).appendingPathComponent("skill.md")) else {
                        throw Failure(message: "The link \(SkillStep.short(at)) does not reach the skill.")
                    }
                case .lockEntry(let path, let name, let entry):
                    let real = Self.resolvedFile(path)
                    let text = Self.exists(real) ? try String(contentsOfFile: real, encoding: .utf8) : nil
                    let before = SkillLock.rawItem(text, name: name)
                    let updated: String
                    switch SkillLock.updated(text, name: name, entry: entry) {
                    case .success(let new): updated = new
                    case .failure: throw Failure(message: "\(SkillStep.short(path)) is in a format Next Term does not know.")
                    }
                    try manager.createDirectory(atPath: (real as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try updated.write(toFile: real, atomically: true, encoding: .utf8)
                    change.entries.append(.init(kind: .editedLock, path: real, other: name, previous: before, left: SkillLock.rawItem(updated, name: name)))
                case .recordEntry(let path, let name, let record):
                    var records = SkillRecord.decodeList(manager.contents(atPath: path))
                    let before = records.first { $0.name == name }?.raw()
                    records.removeAll { $0.name == name }
                    if let record { records.append(record) }
                    try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try SkillRecord.encodeList(records).write(to: URL(fileURLWithPath: path), options: .atomic)
                    change.entries.append(.init(kind: .editedRecord, path: path, other: name, previous: before, left: record?.raw()))
                }
            } catch {
                let message = (error as? Failure)?.message ?? error.localizedDescription
                let left = reverse(change.entries)
                if left.problems.isEmpty {
                    remember(nil)
                    return .failure(Failure(message: "\(step.summary) failed: \(message) Nothing was changed."))
                }
                // What could not be put back stays recorded, so Undo can finish once the cause is fixed.
                remember(Change(title: title, entries: left.remaining))
                return .failure(Failure(message: "\(step.summary) failed: \(message) Next Term could not put back \(left.problems.joined(separator: ", ")). "
                                        + "Earlier versions are in the Trash, and Undo can try again."))
            }
        }
        remember(change)
        return .success(())
    }

    // MARK: undoing

    /// Why the last change can't be undone exactly, or nil: something it made was changed or removed
    /// since (an edit, an update, another tool), something it removed has come back, an item it would
    /// move is read-only or locked, or the Trash no longer holds what it moved there.
    public func undoBlocker(_ change: Change) -> String? {
        var expected: [String: String?] = [:]
        var edits: [String: Change.Entry] = [:]
        for entry in change.entries {
            switch entry.kind {
            case .trashed, .removedLink: expected[entry.path] = .some(nil)
            case .created: expected[entry.path] = .some(entry.left)
            case .moved:
                if let from = entry.other { expected[from] = .some(nil) }
                expected[entry.path] = .some(entry.left)
            case .editedLock, .editedRecord: edits[entry.path + "\0" + (entry.other ?? "")] = entry
            }
        }
        for (path, wanted) in expected.sorted(by: { $0.key < $1.key }) {
            let now = Self.fingerprint(path)
            if now != wanted {
                if wanted == nil { return "Something new is at \(SkillStep.short(path)) since “\(change.title)”." }
                return "\(SkillStep.short(path)) has changed since “\(change.title)”."
            }
            if wanted != nil, !Self.isLink(path), let problem = Self.moveProblem(path) { return problem }
        }
        for entry in edits.values {
            let name = entry.other ?? ""
            let now: String?
            if entry.kind == .editedLock {
                now = SkillLock.rawItem(try? String(contentsOfFile: entry.path, encoding: .utf8), name: name)
            } else {
                now = SkillRecord.decodeList(FileManager.default.contents(atPath: entry.path)).first { $0.name == name }?.raw()
            }
            if now != entry.left { return "\(name) in \(SkillStep.short(entry.path)) has changed since “\(change.title)”." }
        }
        for entry in change.entries where entry.kind == .trashed {
            guard let trashed = entry.other, Self.exists(trashed) else { return "The Trash no longer holds \(SkillStep.short(entry.path))." }
        }
        return nil
    }

    /// Reverses the last change: what was made goes to the Trash, what was trashed comes back, links
    /// are remade, entries get their old values. Refused, with nothing touched, if anything changed
    /// since. If it stops part-way, what is left stays recorded, so Undo can finish later.
    public func undo() -> Result<Void, Failure> {
        guard let change = lastChange else { return .failure(Failure(message: "There is nothing to undo.")) }
        if let blocker = undoBlocker(change) {
            return .failure(Failure(message: blocker + " Undo would overwrite that, so nothing was changed."))
        }
        let left = reverse(change.entries)
        if left.problems.isEmpty {
            remember(nil)
            return .success(())
        }
        remember(Change(title: change.title, entries: left.remaining, date: change.date))
        return .failure(Failure(message: "Could not put back \(left.problems.joined(separator: ", ")). Undo can try again."))
    }

    /// Reverses entries, newest first, and stops at the first that fails: `remaining` is that one and
    /// everything before it (still undoable later), `problems` says what failed.
    func reverse(_ entries: [Change.Entry]) -> (remaining: [Change.Entry], problems: [String]) {
        let manager = FileManager.default
        for index in entries.indices.reversed() {
            let entry = entries[index]
            do {
                switch entry.kind {
                case .created:
                    if Self.isLink(entry.path) {
                        guard unlink(entry.path) == 0 else { throw Failure(message: "unlink") }
                    } else if Self.exists(entry.path) {
                        _ = try trash(entry.path)
                    }
                case .moved:
                    guard let from = entry.other else { break }
                    if Self.exists(entry.path) {
                        try manager.createDirectory(atPath: (from as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                        try manager.moveItem(atPath: entry.path, toPath: from)
                    }
                case .trashed:
                    guard let trashed = entry.other else { throw Failure(message: "where it went is unknown") }
                    // Something in the way (a half-made copy): it goes to the Trash first.
                    if Self.exists(entry.path) { _ = try trash(entry.path) }
                    try manager.createDirectory(atPath: (entry.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try manager.moveItem(atPath: trashed, toPath: entry.path)
                case .removedLink:
                    guard let target = entry.other else { break }
                    if Self.exists(entry.path) { _ = try trash(entry.path) }
                    try manager.createSymbolicLink(atPath: entry.path, withDestinationPath: target)
                case .editedLock:
                    let text = Self.exists(entry.path) ? try String(contentsOfFile: entry.path, encoding: .utf8) : nil
                    guard case .success(let restored) = SkillLock.replacingRawItem(text, name: entry.other ?? "", raw: entry.previous) else {
                        throw Failure(message: "unreadable")
                    }
                    try restored.write(toFile: entry.path, atomically: true, encoding: .utf8)
                case .editedRecord:
                    var records = SkillRecord.decodeList(manager.contents(atPath: entry.path))
                    records.removeAll { $0.name == entry.other }
                    if let previous = entry.previous.flatMap(SkillRecord.fromRaw) { records.append(previous) }
                    try SkillRecord.encodeList(records).write(to: URL(fileURLWithPath: entry.path), options: .atomic)
                }
            } catch {
                return (Array(entries[...index]), [SkillStep.short(entry.path)])
            }
        }
        return ([], [])
    }
}
