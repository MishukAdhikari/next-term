import Foundation

/// A row of the Git Diff tab's changed files: a folder that holds changes, or a changed file.
public struct ChangeTreeNode: Equatable, Sendable {
    /// What the row shows: the file's name, or the folder's ("app"; "src/lib" when a folder holds only
    /// another folder, the two are one row).
    public let name: String
    /// From the work tree's root: the file's path, or the folder's.
    public let path: String
    /// Nil for a folder.
    public let file: ChangedFile?
    public var children: [ChangeTreeNode]
    /// Lines added and removed below a folder, and how many files; a file's own.
    public let stats: LineStats

    public init(name: String, path: String, file: ChangedFile?, children: [ChangeTreeNode] = [], stats: LineStats = LineStats()) {
        self.name = name
        self.path = path
        self.file = file
        self.children = children
        self.stats = stats
    }

    public var isFolder: Bool { file == nil }
}

public enum ChangeTree {
    /// The files as a tree of only the folders that hold them: folders first, then files, each in Finder's
    /// order ("file2" before "file10"); a folder holding nothing but one folder joined with it.
    public static func build(_ files: [ChangedFile]) -> [ChangeTreeNode] {
        let top = Folder()
        for file in files {
            var folder = top
            for part in file.path.split(separator: "/").dropLast().map(String.init) {
                if let next = folder.folders[part] {
                    folder = next
                } else {
                    let next = Folder()
                    folder.folders[part] = next
                    folder = next
                }
            }
            folder.files.append(file)
        }
        return nodes(of: top, prefix: "")
    }

    private final class Folder {
        var folders: [String: Folder] = [:]
        var files: [ChangedFile] = []
    }

    private static func before(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }

    private static func nodes(of folder: Folder, prefix: String) -> [ChangeTreeNode] {
        var result: [ChangeTreeNode] = []
        for name in folder.folders.keys.sorted(by: before) {
            guard var inner = folder.folders[name] else { continue }
            var label = name
            while inner.files.isEmpty, inner.folders.count == 1, let only = inner.folders.first {
                label += "/" + only.key
                inner = only.value
            }
            let path = prefix + label
            let children = nodes(of: inner, prefix: path + "/")
            let stats = children.reduce(LineStats()) { $0 + $1.stats }
            result.append(ChangeTreeNode(name: label, path: path, file: nil, children: children, stats: stats))
        }
        let files = folder.files.sorted { before(($0.path as NSString).lastPathComponent, ($1.path as NSString).lastPathComponent) }
        for file in files {
            let stats = LineStats(added: file.added ?? 0, removed: file.removed ?? 0, files: 1)
            result.append(ChangeTreeNode(name: (file.path as NSString).lastPathComponent, path: file.path, file: file, stats: stats))
        }
        return result
    }

    /// The files in the order the tree shows them, top to bottom.
    public static func files(in nodes: [ChangeTreeNode]) -> [ChangedFile] {
        nodes.flatMap { node in node.file.map { [$0] } ?? files(in: node.children) }
    }

    /// Where the selection goes when the file at `path` leaves the list: the next file that stays, in the
    /// order the list had (`old`), else the one before it; nil when none stays.
    public static func neighbour(of path: String, in old: [String], keeping new: Set<String>) -> String? {
        guard let at = old.firstIndex(of: path) else { return nil }
        if let next = old[(at + 1)...].first(where: { new.contains($0) }) { return next }
        return old[..<at].last { new.contains($0) }
    }
}
