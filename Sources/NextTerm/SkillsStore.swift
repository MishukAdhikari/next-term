import AppKit
import CryptoKit
import NextTermCore

/// The Skills library's hands: it carries out steps on disk (SkillStep) and remembers the last change
/// so one Undo puts everything back. Folders go to the Trash; links are removed and remade exactly.
/// Nothing here runs without the user having seen the steps (the unify sheet, the review sheet).
enum SkillsStore {
    /// The home folder the library reads and writes. The self-test points it at a folder of its own.
    nonisolated(unsafe) static var home = NSHomeDirectory()
    /// Posted after a change on disk, so open views reload.
    static let changed = Notification.Name("NextTermSkillsChanged")

    static func inventory() -> SkillInventory { SkillInventory.scan(home: home) }

    /// Next Term's own folder for the library: the undo record, the install records, downloads being reviewed.
    static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Next Term", isDirectory: true)
        return home == NSHomeDirectory() ? base : base.appendingPathComponent("skills-test-\(getpid())", isDirectory: true)
    }

    // MARK: undo

    /// What one change did, so it can be undone: each entry in the order it was done.
    struct Change: Codable {
        enum Kind: String, Codable { case trashed, removedLink, created, rewrote }
        struct Entry: Codable {
            var kind: Kind
            /// Where it was (trashed, removedLink) or what was made (created, rewrote).
            var path: String
            /// The Trash's copy of a trashed item; the target of a removed link.
            var other: String?
            /// For rewrote: the file's text before (nil: there was no file).
            var previous: String?
            /// For created and rewrote: a fingerprint of what the change left there, so Undo can tell
            /// whether anything touched it since.
            var left: String?
        }
        var title: String
        var entries: [Entry] = []
        var date = Date()
    }

    private static var undoFile: URL { supportFolder.appendingPathComponent("skills-undo.json") }

    /// The change Undo would reverse, if any (it survives quitting).
    static var lastChange: Change? {
        guard let data = try? Data(contentsOf: undoFile) else { return nil }
        return try? JSONDecoder().decode(Change.self, from: data)
    }

    private static func remember(_ change: Change?) {
        if let change, let data = try? JSONEncoder().encode(change) {
            try? FileManager.default.createDirectory(at: undoFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: undoFile, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: undoFile)
        }
    }

    /// What is at a path now, in a form that changes when anything there changes: a link's target, a
    /// folder's content hash, a file's SHA-256. nil: nothing is there.
    static func fingerprint(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return "link:" + ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "")
        case S_IFDIR: return "folder:" + (SkillHash.folder(path) ?? "")
        default:
            let data = FileManager.default.contents(atPath: path) ?? Data()
            return "file:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: doing

    struct Failure: Error { let message: String }

    /// Carries out the steps in order. On the first failure, what was done so far is undone, and the
    /// error says which step failed. On success, the change becomes the one Undo reverses.
    @discardableResult
    static func apply(_ steps: [SkillStep], title: String) -> Result<Void, Failure> {
        var change = Change(title: title)
        let manager = FileManager.default
        for step in steps {
            do {
                switch step {
                case .trash(let path):
                    var info = stat()
                    guard lstat(path, &info) == 0 else { continue } // already gone
                    if (info.st_mode & S_IFMT) == S_IFLNK {
                        // A link: remove the link itself, never what it points to; remember its target.
                        let target = try manager.destinationOfSymbolicLink(atPath: path)
                        guard unlink(path) == 0 else { throw Failure(message: "Could not remove the link \(SkillStep.short(path)).") }
                        change.entries.append(.init(kind: .removedLink, path: path, other: target))
                    } else {
                        var trashed: NSURL?
                        try manager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &trashed)
                        change.entries.append(.init(kind: .trashed, path: path, other: trashed?.path))
                    }
                case .copy(let from, let to):
                    guard !manager.fileExists(atPath: to) else { throw Failure(message: "\(SkillStep.short(to)) is already there.") }
                    try manager.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try manager.copyItem(atPath: from, toPath: to)
                    change.entries.append(.init(kind: .created, path: to, left: fingerprint(to)))
                case .link(let at, let to):
                    try manager.createDirectory(atPath: (at as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try manager.createSymbolicLink(atPath: at, withDestinationPath: SkillUnify.relativeTarget(at: at, to: to))
                    change.entries.append(.init(kind: .created, path: at, left: fingerprint(at)))
                case .write(let path, let text):
                    let previous = manager.fileExists(atPath: path) ? try String(contentsOfFile: path, encoding: .utf8) : nil
                    try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try text.write(toFile: path, atomically: true, encoding: .utf8)
                    change.entries.append(.init(kind: .rewrote, path: path, previous: previous, left: fingerprint(path)))
                }
            } catch {
                _ = reverse(change)
                let message = (error as? Failure)?.message ?? error.localizedDescription
                notify()
                return .failure(Failure(message: "\(step.summary) failed: \(message) Nothing was changed."))
            }
        }
        remember(change)
        notify()
        return .success(())
    }

    /// Why the last change can't be undone exactly any more, or nil: something it made was changed or
    /// removed since (an edit, an update, another tool), something it removed has come back, or the
    /// Trash no longer holds what it moved there.
    static func undoBlocker(_ change: Change) -> String? {
        var lastAt: [String: Change.Entry] = [:]
        for entry in change.entries { lastAt[entry.path] = entry }
        for (path, entry) in lastAt.sorted(by: { $0.key < $1.key }) {
            let now = fingerprint(path)
            switch entry.kind {
            case .created, .rewrote:
                if now != entry.left { return "\(SkillStep.short(path)) has changed since “\(change.title)”." }
            case .trashed, .removedLink:
                if now != nil { return "Something new is at \(SkillStep.short(path)) since “\(change.title)”." }
            }
        }
        for entry in change.entries where entry.kind == .trashed {
            guard let trashed = entry.other, FileManager.default.fileExists(atPath: trashed) else {
                return "The Trash no longer holds \(SkillStep.short(entry.path))."
            }
        }
        return nil
    }

    /// Reverses the last change: what was made goes, what was trashed comes back, links are remade,
    /// rewritten files get their old text. Refused, with nothing touched, if anything changed since.
    @discardableResult
    static func undo() -> Result<Void, Failure> {
        guard let change = lastChange else { return .failure(Failure(message: "There is nothing to undo.")) }
        if let blocker = undoBlocker(change) {
            return .failure(Failure(message: blocker + " Undo would overwrite that, so nothing was changed."))
        }
        let result = reverse(change)
        if case .success = result { remember(nil) }
        notify()
        return result
    }

    private static func reverse(_ change: Change) -> Result<Void, Failure> {
        let manager = FileManager.default
        var problems: [String] = []
        for entry in change.entries.reversed() {
            switch entry.kind {
            case .created:
                var info = stat()
                guard lstat(entry.path, &info) == 0 else { continue }
                if (info.st_mode & S_IFMT) == S_IFLNK { unlink(entry.path) } else {
                    do { try manager.removeItem(atPath: entry.path) } catch { problems.append(SkillStep.short(entry.path)) }
                }
            case .trashed:
                guard let trashed = entry.other else { problems.append(SkillStep.short(entry.path)); continue }
                do {
                    try manager.createDirectory(atPath: (entry.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try manager.moveItem(atPath: trashed, toPath: entry.path)
                } catch { problems.append(SkillStep.short(entry.path)) }
            case .removedLink:
                guard let target = entry.other else { continue }
                do { try manager.createSymbolicLink(atPath: entry.path, withDestinationPath: target) } catch { problems.append(SkillStep.short(entry.path)) }
            case .rewrote:
                do {
                    if let previous = entry.previous {
                        try previous.write(toFile: entry.path, atomically: true, encoding: .utf8)
                    } else if manager.fileExists(atPath: entry.path) {
                        try manager.removeItem(atPath: entry.path)
                    }
                } catch { problems.append(SkillStep.short(entry.path)) }
            }
        }
        return problems.isEmpty ? .success(()) : .failure(Failure(message: "Could not put back: " + problems.joined(separator: ", ") + "."))
    }

    private static func notify() {
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
