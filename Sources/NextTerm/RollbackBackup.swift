import CryptoKit
import Foundation
import NextTermCore

/// What a rollback keeps for its Undo (GitActions.rollback): each file as it was (a copy in a folder of its own, or
/// that there was none), the index entries (`git ls-files --stage`), the paths marked with `git add -N`, the files it
/// sent to the Trash (Undo takes them back out), and a fingerprint of each file as the rollback left it, so Undo never
/// overwrites a change made since.
final class RollbackBackup {
    let root: String
    let paths: [String]
    let entries: [String: Rollback.IndexEntry]
    let intentToAdd: Set<String>
    private let folder: URL
    /// Each path's copy; a path with no file before has none.
    private var copies: [String: URL] = [:]
    private var trashed: [String: URL] = [:]
    /// Each file's fingerprint once rolled back; nil: no file.
    private var after: [String: String?] = [:]

    /// Nil when the index can't be read or a file can't be copied: then nothing is rolled back.
    init?(root: String, paths: [String], git: String, intentToAdd: Set<String>) {
        self.root = root
        self.paths = paths
        self.intentToAdd = intentToAdd
        guard let entries = Rollback.readIndexEntries(paths, root: root, git: git) else { return nil }
        self.entries = entries
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("next-term-rollback-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        for (index, path) in paths.enumerated() {
            let file = url(of: path)
            guard FileManager.default.fileExists(atPath: file.path) || Self.isLink(file) else { continue }
            let copy = folder.appendingPathComponent(String(index))
            guard (try? FileManager.default.copyItem(at: file, to: copy)) != nil else {
                discard()
                return nil
            }
            copies[path] = copy
        }
    }

    private func url(of path: String) -> URL { URL(fileURLWithPath: root).appendingPathComponent(path) }

    private static func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// A file HEAD doesn't have, to the Trash (or, if the Trash refuses it, removed: its copy is kept here).
    func trash(_ path: String) {
        let file = url(of: path)
        var inTrash: NSURL?
        if (try? FileManager.default.trashItem(at: file, resultingItemURL: &inTrash)) != nil, let inTrash {
            trashed[path] = inTrash as URL
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Each file as the rollback left it, to know at Undo whether it changed since.
    func noteAfter() {
        for path in paths { after[path] = Self.fingerprint(url(of: path)) }
    }

    /// The first file that changed since the rollback, if any.
    func changedSince() -> String? {
        paths.first { path in after[path].map { $0 != Self.fingerprint(url(of: path)) } ?? false }
    }

    private static func fingerprint(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return isLink(url) ? "link" : nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The files back as they were: out of the Trash when they went there, else from their copy; a path that had no
    /// file has none again (what was there is HEAD's, which git keeps).
    func restoreFiles() {
        let fm = FileManager.default
        for path in paths {
            let file = url(of: path)
            if fm.fileExists(atPath: file.path) || Self.isLink(file) { try? fm.removeItem(at: file) }
            guard let copy = copies[path] else { continue }
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let inTrash = trashed[path], (try? fm.moveItem(at: inTrash, to: file)) != nil { continue }
            try? fm.copyItem(at: copy, to: file)
        }
    }

    /// The copies gone, once Undo is done or no longer possible.
    func discard() { try? FileManager.default.removeItem(at: folder) }
}
