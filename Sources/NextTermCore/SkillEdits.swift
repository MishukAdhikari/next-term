import Foundation

/// Whether an installed skill was changed on disk since it was installed: what the update sheet warns
/// about before an update replaces it. Caches Python writes when a skill runs, Finder's notes, and what
/// `npx skills` leaves out when it copies (metadata.json, caches, .git) are not edits.
public enum SkillEdits {
    /// Names that never count as an edit.
    static let ignored: Set<String> = [".DS_Store", "__pycache__", "__pypackages__", ".git", "metadata.json"]

    /// The installed copy's git tree hash, without what running it or Finder adds: compared with the
    /// tree Next Term recorded at install (an install never holds compiled Python; the review refuses it).
    public static func installedHash(_ folder: String) -> String? {
        GitHash.folder(folder, ignoring: [".DS_Store", "__pycache__", "__pypackages__"])
    }

    /// One file in a GitHub tree listing.
    public struct Blob: Equatable, Sendable {
        public let sha: String
        public let link: Bool
        public init(sha: String, link: Bool) {
            self.sha = sha
            self.link = link
        }
    }

    /// Compares a copy `npx skills` made with its source tree, file by file (the CLI leaves files out and
    /// copies what links point to, so one tree hash can't match). true: changed; false: the same;
    /// nil: can't tell (the tree holds a link).
    public static func differs(_ folder: String, from tree: [String: Blob]) -> Bool? {
        if tree.values.contains(where: \.link) { return nil }
        let expected = tree.filter { path, _ in !path.split(separator: "/").contains { ignored.contains(String($0)) } }
        var seen = Set<String>()
        let walker = FileManager.default.enumerator(atPath: folder)
        while let relative = walker?.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            if ignored.contains(name) {
                if walker?.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { walker?.skipDescendants() }
                continue
            }
            guard walker?.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
            let full = (folder as NSString).appendingPathComponent(relative)
            let size = (walker?.fileAttributes?[.size] as? NSNumber)?.intValue ?? 0
            guard let blob = expected[relative], GitHash.blob(file: full, size: size) == blob.sha else { return true }
            seen.insert(relative)
        }
        return seen.count != expected.count
    }
}
