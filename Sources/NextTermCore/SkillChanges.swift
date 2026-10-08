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
public struct SkillChanges: Sendable {
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
            /// edited: the file did not exist before, so putting the entry back removes the file again
            /// when nothing else was written to it.
            public var newFile: Bool?

            public init(kind: Kind, path: String, other: String? = nil, previous: String? = nil, left: String? = nil, newFile: Bool? = nil) {
                self.kind = kind
                self.path = path
                self.other = other
                self.previous = previous
                self.left = left
                self.newFile = newFile
            }

            /// Moved to the Trash, but the Trash did not say where: only the Finder's Put Back can bring
            /// it back, so it is never kept for Undo.
            var isLost: Bool { kind == .trashed && other == nil }
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
    public let trash: @Sendable (String) throws -> String

    public init(undoFile: String, trash: @escaping @Sendable (String) throws -> String = { try SkillChanges.systemTrash($0) }) {
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
    public static func folderTrash(_ folder: String) -> @Sendable (String) throws -> String {
        { path in
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let target = (folder as NSString).appendingPathComponent(UUID().uuidString + "-" + (path as NSString).lastPathComponent)
            try FileManager.default.moveItem(atPath: path, toPath: target)
            return target
        }
    }

    // MARK: the record

    /// The changes Undo can still reverse, oldest first. Normally one; when putting back a failed change
    /// itself failed, what is left of it sits on top of the change before it, so neither is lost.
    var changes: [Change] {
        guard let data = FileManager.default.contents(atPath: undoFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let list = (try? decoder.decode([Change].self, from: data)) ?? (try? decoder.decode(Change.self, from: data)).map { [$0] } ?? []
        // A record from before lost entries were left out: one that holds nothing else has nothing to
        // undo, and would only block the change below it. Others keep them, so Undo can name them.
        return list.filter { change in change.entries.contains { !$0.isLost } }
    }

    /// The change Undo would reverse next.
    public var lastChange: Change? { changes.last }

    func store(_ list: [Change]) {
        let kept = list.filter { !$0.entries.isEmpty }
        guard !kept.isEmpty else {
            try? FileManager.default.removeItem(atPath: undoFile)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(kept) else { return }
        try? FileManager.default.createDirectory(atPath: (undoFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? SafeWrite.replace(undoFile, with: data)
    }

    // MARK: checks before doing anything

    /// Writes a lock file or the records over the bytes `read` from it (nil: there was none), through `SafeWrite`: a
    /// save in between (the `skills` command's own) is kept, and this step fails instead. New files are 0644, as the
    /// `skills` command makes them.
    static func write(_ data: Data, to path: String, over read: Data?) throws {
        try SafeWrite.replace(path, with: data, expecting: read.map { .contents($0) } ?? .noFile, newFileMode: 0o644)
    }

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
            case S_IFDIR where info.st_mode & (S_IRUSR | S_IXUSR) != (S_IRUSR | S_IXUSR): return "\(short) is a folder that can't be read."
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
                if real != path, !FileManager.default.fileExists(atPath: (real as NSString).deletingLastPathComponent) {
                    return "\(SkillStep.short(path)) links to \(SkillStep.short(real)), which is missing."
                }
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
    /// A link to a file that doesn't exist yet resolves to where it points.
    static func resolvedFile(_ path: String) -> String {
        guard isLink(path) else { return path }
        if let real = realpath(path, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return path }
        if destination.hasPrefix("/") { return (destination as NSString).standardizingPath }
        let folder = realPath((path as NSString).deletingLastPathComponent)
        return ((folder as NSString).appendingPathComponent(destination) as NSString).standardizingPath
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
        // The folder holding `to`, not `to` itself: a link to the shared entry must stay a link to it,
        // even when that entry is itself a link (to the developer's own folder).
        let target = (realPath((to as NSString).deletingLastPathComponent) as NSString).appendingPathComponent((to as NSString).lastPathComponent)
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
    /// put back; the message says whether that worked. `verify` runs once every step is done and, by
    /// saying what is wrong, has the change put back the same way (an install that doesn't match what
    /// was reviewed). On success, the change becomes the one Undo reverses, unless it changed nothing
    /// (a second removal planned before the first ran), when the earlier one stays. `precheck` runs
    /// first and, by saying what is wrong, stops the change before anything moves (the steps were
    /// worked out before another change landed).
    public func apply(_ steps: [SkillStep], title: String, precheck: (() -> String?)? = nil,
                      verify: (() -> String?)? = nil) -> Result<Void, Failure> {
        if let problem = precheck?() { return .failure(Failure(message: problem + " Nothing was changed.")) }
        if let problem = preflight(steps) { return .failure(Failure(message: problem + " Nothing was changed.")) }
        var change = Change(title: title)
        let manager = FileManager.default
        let earlier = changes
        // What is done so far, kept above the earlier change after each step that touches the user's
        // folders: a crash or Force Quit part-way still leaves an Undo that puts things back.
        func journal() { store(earlier + [change]) }
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
                        journal()
                    } else {
                        do {
                            change.entries.append(.init(kind: .trashed, path: path, other: try trash(path)))
                            journal()
                        } catch where !Self.exists(path) {
                            // It left its place (into the Trash) but where is unknown: recorded, so putting
                            // back reports it rather than claiming nothing changed.
                            change.entries.append(.init(kind: .trashed, path: path, other: nil))
                            throw error
                        }
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
                    guard let staged = change.entries.lastIndex(where: { $0.kind == .created && $0.path == from }) else {
                        try manager.moveItem(atPath: from, toPath: to)
                        change.entries.append(.init(kind: .moved, path: to, other: from, left: Self.fingerprint(to)))
                        continue
                    }
                    // A copy this change made (a staging copy) takes its place: from then on it counts as
                    // made there, so putting back or Undo removes it from its place, not by way of the
                    // staging folder. Recorded before moving, so a move that fails or a crash half-way is
                    // put away too. Moving doesn't change what the copy holds, so its fingerprint stays.
                    let left = change.entries[staged].left
                    change.entries.append(.init(kind: .created, path: to, left: left))
                    journal()
                    try manager.moveItem(atPath: from, toPath: to)
                    change.entries.remove(at: staged)
                    if left == nil { change.entries[change.entries.count - 1].left = Self.fingerprint(to) }
                    journal()
                case .link(let at, let to):
                    try manager.createDirectory(atPath: (at as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try manager.createSymbolicLink(atPath: at, withDestinationPath: Self.linkTarget(at: at, to: to))
                    change.entries.append(.init(kind: .created, path: at, left: Self.fingerprint(at)))
                    journal()
                    // The link must reach a skill, or Claude Code would be left without it.
                    var isFolder: ObjCBool = false
                    let skill = (at as NSString).appendingPathComponent("SKILL.md")
                    guard manager.fileExists(atPath: at, isDirectory: &isFolder), isFolder.boolValue,
                          manager.fileExists(atPath: skill) || manager.fileExists(atPath: (at as NSString).appendingPathComponent("skill.md")) else {
                        throw Failure(message: "The link \(SkillStep.short(at)) does not reach the skill.")
                    }
                case .lockEntry(let path, let name, let entry):
                    let real = Self.resolvedFile(path)
                    let read = Self.exists(real) ? manager.contents(atPath: real) : nil
                    let text = Self.exists(real) ? try String(contentsOfFile: real, encoding: .utf8) : nil
                    let before = SkillLock.rawItem(text, name: name)
                    let updated: String
                    switch SkillLock.updated(text, name: name, entry: entry) {
                    case .success(let new): updated = new
                    case .failure: throw Failure(message: "\(SkillStep.short(path)) is in a format Next Term does not know.")
                    }
                    let after = SkillLock.rawItem(updated, name: name)
                    guard after != before else { continue } // already as wanted: nothing to write or undo
                    try manager.createDirectory(atPath: (real as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    let newFile: Bool? = text == nil ? true : nil
                    try Self.write(Data(updated.utf8), to: real, over: read)
                    change.entries.append(.init(kind: .editedLock, path: real, other: name, previous: before, left: after, newFile: newFile))
                    journal()
                case .recordEntry(let path, let name, let record):
                    let read = manager.contents(atPath: path)
                    var records = SkillRecord.decodeList(read)
                    let before = records.first { $0.name == name }?.raw()
                    guard record?.raw() != before else { continue } // already as wanted
                    records.removeAll { $0.name == name }
                    if let record { records.append(record) }
                    try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    let newFile: Bool? = Self.exists(path) ? nil : true
                    try Self.write(SkillRecord.encodeList(records), to: path, over: read)
                    change.entries.append(.init(kind: .editedRecord, path: path, other: name, previous: before, left: record?.raw(), newFile: newFile))
                    journal()
                }
            } catch {
                let message = (error as? Failure)?.message ?? error.localizedDescription
                return putBack(change, title: title, problem: "\(step.summary) failed: \(message)", earlier: earlier)
            }
        }
        if let problem = verify?() { return putBack(change, title: title, problem: problem, earlier: earlier) }
        if !change.entries.isEmpty { store([change]) }
        return .success(())
    }

    /// Puts back what a change that stopped part-way did, and says how that went. `earlier`: the
    /// changes Undo could reverse before this one began (its journal is replaced).
    func putBack(_ change: Change, title: String, problem: String, earlier: [Change]) -> Result<Void, Failure> {
        let left = reverse(change.entries, rollback: true) { remaining in
            self.store(earlier + [Change(title: title, entries: remaining, date: change.date)])
        }
        var message = problem
        for path in left.lost { message += " To put \(path) back, use Put Back on it in the Finder's Trash." }
        if left.problems.isEmpty {
            // The disk is as it was: the earlier change's Undo stays as it is.
            store(earlier)
            return .failure(Failure(message: message + (left.lost.isEmpty ? " Nothing was changed." : " Nothing else was changed.")))
        }
        // What could not be put back stays recorded, above the earlier change, so Undo can finish this
        // one once the cause is fixed and then still reverse the earlier one. Recorded as it is now
        // (the check that stopped it may have found it changed since the step), so Undo isn't refused.
        var remaining = left.remaining
        for index in remaining.indices where remaining[index].kind == .created || remaining[index].kind == .moved {
            remaining[index].left = Self.fingerprint(remaining[index].path)
        }
        store(earlier + [Change(title: title, entries: remaining)])
        message += " Next Term could not put back \(left.problems.joined(separator: ", "))."
        let made = remaining.filter { $0.kind == .created || $0.kind == .moved }.map { SkillStep.short($0.path) }
        if !made.isEmpty { message += " What it made is still at \(made.joined(separator: ", "))." }
        if remaining.contains(where: { $0.kind == .trashed }) { message += " Earlier versions are in the Trash." }
        return .failure(Failure(message: message + " Undo can try again."))
    }

    // MARK: undoing

    /// Why the last change can't be undone exactly, or nil: something it made was changed or removed
    /// since (an edit, an update, another tool), something it removed has come back, an item it would
    /// move is read-only or locked, or the Trash no longer holds what it moved there.
    public func undoBlocker(_ change: Change) -> String? {
        var expected: [String: String?] = [:]
        var edits: [String: Change.Entry] = [:]
        for entry in change.entries where !entry.isLost {
            switch entry.kind {
            case .trashed, .removedLink: expected[entry.path] = .some(nil)
            case .created:
                // Gone: nothing to remove. No fingerprint (a crash part-way through making or removing it):
                // what is there is what it was making, so nothing is expected of it.
                guard Self.exists(entry.path) else { continue }
                if let left = entry.left { expected[entry.path] = .some(left) } else { expected.removeValue(forKey: entry.path) }
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
            guard let trashed = entry.other else { continue }
            guard Self.exists(trashed) else { return "The Trash no longer holds \(SkillStep.short(entry.path))." }
        }
        return nil
    }

    /// Reverses the last change: what was made goes to the Trash, what was trashed comes back, links
    /// are remade, entries get their old values. Refused, with nothing touched, if anything changed
    /// since, or if the last change is no longer the one the user confirmed (`expected`: another change
    /// landed in between). If it stops part-way, what is left stays recorded, so Undo can finish later.
    public func undo(expecting expected: Change? = nil) -> Result<Void, Failure> {
        guard let change = lastChange else { return .failure(Failure(message: "There is nothing to undo.")) }
        if let expected, change != expected {
            let now = change.title == expected.title ? "a later “\(change.title)”" : "“\(change.title)”"
            return .failure(Failure(message: "The last change is now \(now), not the one you confirmed. Nothing was undone."))
        }
        if let blocker = undoBlocker(change) {
            return .failure(Failure(message: blocker + " Undo would overwrite that, so nothing was changed."))
        }
        let left = reverse(change.entries, rollback: false)
        var list = changes
        if !list.isEmpty { list.removeLast() }
        if left.problems.isEmpty {
            store(list)
            guard left.lost.isEmpty else {
                // A record from before lost entries were left out: the rest is undone, and the user is
                // told where the remainder is.
                let lost = left.lost.joined(separator: ", ")
                return .failure(Failure(message: "“\(change.title)” was undone, except \(lost): it is in the Trash, and macOS did not say where. "
                                        + "Use Put Back on it in the Finder."))
            }
            return .success(())
        }
        store(list + [Change(title: change.title, entries: left.remaining, date: change.date)])
        return .failure(Failure(message: "Could not put back \(left.problems.joined(separator: ", ")). Undo can try again."))
    }

    /// Makes a tree this change made removable again: a copy keeps its source's folder modes, and a
    /// folder without write or search permission can't be emptied.
    static func makeRemovable(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return }
        chmod(path, (info.st_mode & 0o7777) | S_IRWXU)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
            makeRemovable((path as NSString).appendingPathComponent(name))
        }
    }

    /// Reverses entries, newest first, and stops at the first that fails: `remaining` is that one and
    /// everything before it (still undoable later), `problems` says what failed. An item the Trash took
    /// without saying where is skipped and listed in `lost`. A rollback (the same change, moments
    /// after) deletes what it made itself; Undo moves it to the Trash.
    /// `progress` gets what is still to be reversed after each step, so a journal can stay current: a
    /// crash part-way through putting a change back then leaves an Undo that finishes the job.
    func reverse(_ entries: [Change.Entry], rollback: Bool,
                 progress: (([Change.Entry]) -> Void)? = nil) -> (remaining: [Change.Entry], problems: [String], lost: [String]) {
        let manager = FileManager.default
        var lost: [String] = []
        for index in entries.indices.reversed() {
            let entry = entries[index]
            if entry.isLost {
                lost.append(SkillStep.short(entry.path))
                continue
            }
            do {
                switch entry.kind {
                case .created:
                    if Self.isLink(entry.path) {
                        guard unlink(entry.path) == 0 else { throw Failure(message: "unlink") }
                    } else if Self.exists(entry.path) {
                        if rollback {
                            // Recorded without its fingerprint first: after a crash part-way through the
                            // removal, Undo removes what is left of it rather than refusing.
                            var pending = Array(entries[...index]).filter { !$0.isLost }
                            if let last = pending.indices.last { pending[last].left = nil }
                            progress?(pending)
                            Self.makeRemovable(entry.path)
                            try manager.removeItem(atPath: entry.path)
                        } else {
                            do { _ = try trash(entry.path) } catch where !Self.exists(entry.path) {
                                // Put away, though the Trash did not say where: done.
                            }
                        }
                    }
                case .moved:
                    guard let from = entry.other else { break }
                    if Self.exists(entry.path) {
                        try manager.createDirectory(atPath: (from as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                        try manager.moveItem(atPath: entry.path, toPath: from)
                    }
                case .trashed:
                    guard let trashed = entry.other else { break }
                    // Something in the way (a half-made copy): it goes to the Trash first.
                    if Self.exists(entry.path) { _ = try trash(entry.path) }
                    guard Self.exists(trashed) else { throw Failure(message: "not in the Trash") }
                    try manager.createDirectory(atPath: (entry.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try manager.moveItem(atPath: trashed, toPath: entry.path)
                case .removedLink:
                    guard let target = entry.other else { break }
                    if Self.exists(entry.path) { _ = try trash(entry.path) }
                    try manager.createDirectory(atPath: (entry.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try manager.createSymbolicLink(atPath: entry.path, withDestinationPath: target)
                case .editedLock:
                    let read = Self.exists(entry.path) ? manager.contents(atPath: entry.path) : nil
                    let text = Self.exists(entry.path) ? try String(contentsOfFile: entry.path, encoding: .utf8) : nil
                    guard case .success(let restored) = SkillLock.replacingRawItem(text, name: entry.other ?? "", raw: entry.previous) else {
                        throw Failure(message: "unreadable")
                    }
                    if entry.newFile == true, SkillLock.holdsNothing(restored) {
                        try manager.removeItem(atPath: entry.path) // made by this change, and empty again
                    } else {
                        try Self.write(Data(restored.utf8), to: entry.path, over: read)
                    }
                case .editedRecord:
                    let read = manager.contents(atPath: entry.path)
                    var records = SkillRecord.decodeList(read)
                    records.removeAll { $0.name == entry.other }
                    if let previous = entry.previous.flatMap(SkillRecord.fromRaw) { records.append(previous) }
                    if entry.newFile == true, records.isEmpty {
                        try manager.removeItem(atPath: entry.path) // made by this change, and empty again
                    } else {
                        try Self.write(SkillRecord.encodeList(records), to: entry.path, over: read)
                    }
                }
                progress?(entries[..<index].filter { !$0.isLost })
            } catch {
                let earlier = entries[...index]
                lost += earlier.filter { $0.isLost }.map { SkillStep.short($0.path) }
                return (earlier.filter { !$0.isLost }, [SkillStep.short(entry.path)], lost)
            }
        }
        return ([], [], lost)
    }
}
