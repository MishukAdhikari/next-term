import CryptoKit
import Foundation
import NextTermCore

/// What a rollback keeps for its Undo (GitActions.rollback), taken before anything changes: a copy of each file that
/// comes back from HEAD (in a folder of its own in Next Term's Application Support folder, at its path in the project,
/// kept a week whatever happens, so a crash or a quit never loses one), the index entries (`git ls-files --stage`), the
/// paths marked with `git add -N`, where each path it sent to the Trash went (the Trash is their copy), and a
/// fingerprint of each path as the rollback left it, so Undo never overwrites a change made since.
final class RollbackBackup: @unchecked Sendable { // made, and its files sent to the Trash, off the main thread; used on it after
    /// The worktree and its repository, as they were when the rollback was asked for: Undo runs there, whatever the
    /// window shows by then.
    let root: String
    let repository: String
    let touched: [String]
    let entries: [String: Rollback.IndexEntry]
    let intentToAdd: Set<String>
    /// The folder the copies are in.
    let folder: URL
    /// The paths HEAD's file comes back to with nothing of the user's there to send to the Trash first: these have copies.
    private let restored: [String]
    private let toTrash: [String]
    /// The paths whose file goes to the Trash and HEAD's comes back in its place.
    private let trashedThenRestored: Set<String>
    /// Each restored path's copy; one with no file before has none.
    private var copies: [String: URL] = [:]
    /// Parent folders a restore makes that weren't there: Undo takes them away again when it leaves them empty.
    private var madeFolders: [String] = []
    private var inTrash: [String: URL] = [:]
    /// Each path's fingerprint once rolled back; nil: nothing there.
    private var after: [String: String?] = [:]

    /// How long the copies are kept.
    static let kept: TimeInterval = 7 * 24 * 3600

    /// Nil when the index can't be read or a file can't be copied: then nothing is rolled back.
    init?(plan: Rollback.Plan, root: String, repository: String, git: String, snapshot: GitSnapshot) {
        self.root = root
        self.repository = repository
        touched = Rollback.touched(plan.steps)
        let toTrash = Rollback.trashed(plan.steps)
        self.toTrash = toTrash
        // A path that goes to the Trash before HEAD's comes back has the Trash for its copy.
        let fromHead = Rollback.restoredPaths(plan.steps)
        restored = fromHead.filter { !toTrash.contains($0) }
        trashedThenRestored = Set(fromHead).intersection(toTrash)
        intentToAdd = Rollback.intentToAdd(touched, in: snapshot)
        guard let entries = Rollback.readIndexEntries(touched, root: root, git: git), let folder = Self.newFolder(for: root) else { return nil }
        self.entries = entries
        self.folder = folder
        let fm = FileManager.default
        for path in restored {
            guard Rollback.diskKind(path, root: root) != .none else {
                var parent = (path as NSString).deletingLastPathComponent
                while !parent.isEmpty, Rollback.diskKind(parent, root: root) == .none, !madeFolders.contains(parent) {
                    madeFolders.append(parent)
                    parent = (parent as NSString).deletingLastPathComponent
                }
                continue
            }
            let copy = folder.appendingPathComponent("files").appendingPathComponent(path)
            do {
                try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: url(of: path), to: copy)
            } catch {
                discard()
                return nil
            }
            copies[path] = copy
        }
        // Deepest first, for Undo.
        madeFolders.sort { $0.count > $1.count }
    }

    private func url(of path: String) -> URL { URL(fileURLWithPath: root).appendingPathComponent(path) }

    // MARK: the folder

    /// Where the copies go: Next Term's folder in Application Support, or the plain self-test's own temporary one.
    private static var parent: URL? {
        if SelfTest.mode == .plain {
            return FileManager.default.temporaryDirectory.appendingPathComponent("next-term-selftest-rollbacks-\(getpid())", isDirectory: true)
        }
        return SelfTest.supportFolder?.appendingPathComponent("Rollbacks", isDirectory: true)
    }

    /// A new folder named by the time and the project ("2026-10-11 140322 next-term"), with a note in it saying what
    /// it is; the folders older than a week are removed first.
    private static func newFolder(for root: String) -> URL? {
        guard let parent else { return nil }
        let fm = FileManager.default
        sweep(parent)
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HHmmss"
        let name = format.string(from: Date()) + " " + (root as NSString).lastPathComponent
        var folder = parent.appendingPathComponent(name, isDirectory: true)
        var number = 2
        while fm.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(name) \(number)", isDirectory: true)
            number += 1
        }
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        let note = "Copies of the files Git › Rollback… put back to the last commit in \(root), as they were before it.\n"
            + "Undo, on the notice after the rollback, puts them back. Next Term removes this folder after a week.\n"
        try? note.write(to: folder.appendingPathComponent("About these files.txt"), atomically: true, encoding: .utf8)
        return folder
    }

    /// Removes the folders made more than a week ago.
    private static func sweep(_ parent: URL) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for folder in folders {
            guard let made = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                  Date().timeIntervalSince(made) > kept else { continue }
            try? fm.removeItem(at: folder)
        }
    }

    // MARK: the rollback

    /// The paths HEAD doesn't have, to the Trash, before git changes anything. Nil when all went; else the first that
    /// couldn't, with those that went put back: a file that can't go to the Trash is never deleted instead.
    func trash() -> String? {
        let fm = FileManager.default
        // A new file deleted again since it was staged has nothing on disk: only the index holds it.
        for path in toTrash where Rollback.diskKind(path, root: root) != .none {
            var moved: NSURL?
            if (try? fm.trashItem(at: url(of: path), resultingItemURL: &moved)) != nil, let moved {
                inTrash[path] = moved as URL
                continue
            }
            _ = putBackFromTrash()
            return path
        }
        return nil
    }

    /// The paths sent to the Trash, back where they were; those that couldn't come back.
    private func putBackFromTrash() -> [String] {
        var missed: [String] = []
        for (path, moved) in inTrash {
            let file = url(of: path)
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: moved, to: file)
                inTrash[path] = nil
            } catch {
                missed.append(path)
            }
        }
        return missed
    }

    /// Each path as the rollback left it, to know at Undo whether it changed since.
    func noteAfter() {
        for path in touched { after[path] = Self.fingerprint(url(of: path)) }
    }

    /// The first path that changed since the rollback, if any.
    func changedSince() -> String? {
        touched.first { path in after[path].map { $0 != Self.fingerprint(url(of: path)) } ?? false }
    }

    private static func fingerprint(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return "folder"
        case S_IFLNK: return "link:" + ((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "")
        default:
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return "unreadable" }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: Undo

    /// The files back as they were: what HEAD put back taken away again (git keeps it), then each copy put back, and
    /// what went to the Trash taken back out. Returns the paths that couldn't come back; a folder there now is never
    /// removed. Run before the index is put back.
    func restoreFiles() -> [String] {
        let fm = FileManager.default
        var missed: [String] = []
        // HEAD’s file at `path` taken away; false when it can’t be, or a folder is there.
        func clear(_ path: String) -> Bool {
            switch Rollback.diskKind(path, root: root) {
            case .none: return true
            case .directory: return false
            case .file, .link: return (try? fm.removeItem(at: url(of: path))) != nil
            }
        }
        for path in restored {
            // Still as it was (a rollback that stopped before git put it back): left alone.
            if let copy = copies[path], Self.fingerprint(copy) == Self.fingerprint(url(of: path)) { continue }
            guard clear(path) else {
                missed.append(path)
                continue
            }
            guard let copy = copies[path] else { continue }
            do {
                try fm.createDirectory(at: url(of: path).deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: copy, to: url(of: path))
            } catch {
                missed.append(path)
            }
        }
        // A rename's old path, or a deleted file's with an untracked one over it, holds HEAD's file now; the Trash
        // has what was there.
        for path in trashedThenRestored where inTrash[path] != nil && !clear(path) { missed.append(path) }
        missed += putBackFromTrash().filter { !missed.contains($0) }
        for parent in madeFolders { rmdir(url(of: parent).path) } // only when empty
        return missed
    }

    /// The copies gone, once Undo is done.
    func discard() { try? FileManager.default.removeItem(at: folder) }
}
