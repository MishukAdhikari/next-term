import CryptoKit
import Foundation

/// Where a skill comes from on GitHub: `owner/repo`, `owner/repo/path/to/skill`, or a github.com link to
/// a repository, a folder (`/tree/<ref>/<path>`) or a SKILL.md (`/blob/<ref>/<path>/SKILL.md`).
public struct SkillSource: Equatable, Sendable {
    public var owner: String
    public var repo: String
    /// A branch, tag or commit, when the link names one (nil: the default branch).
    public var ref: String?
    /// The skill's folder inside the repository ("" for the repository's root).
    public var path: String

    public init(owner: String, repo: String, ref: String? = nil, path: String = "") {
        self.owner = owner
        self.repo = repo
        self.ref = ref
        self.path = path
    }

    /// "owner/repo" or "owner/repo/path": what the lock file of `npx skills` records as the source.
    public var shortName: String { "\(owner)/\(repo)" }

    /// The repository's page; owner and repo are checked when parsed, so this always builds.
    public var repositoryURL: URL { URL(string: "https://github.com/\(owner)/\(repo)") ?? URL(fileURLWithPath: "/") }

    /// Whether owner, repo and path are all things GitHub could hold (sources read from a lock file or a
    /// record were never parsed, so they are checked before use).
    public var isValid: Bool { Self.validOwner(owner) && Self.validRepo(repo) && Self.validPath(path) }

    /// GitHub's rules: owner up to 39 characters of letters, digits and single hyphens; a repository
    /// name of letters, digits, `.`, `-` and `_`.
    public static func validOwner(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 39 && !text.hasPrefix("-")
            && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }
    }

    public static func validRepo(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 100 && text != "." && text != ".."
            && text.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "._-".unicodeScalars.contains($0) }
    }

    /// Folder paths inside a repository: no `..`, no absolute paths, no control characters.
    public static func validPath(_ path: String) -> Bool {
        if path.isEmpty { return true }
        if path.hasPrefix("/") || path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }

    /// Reads what a user pastes. nil: not a GitHub skill source.
    public static func parse(_ input: String) -> SkillSource? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        if text.lowercased().hasPrefix("www.") { text = String(text.dropFirst(4)) }
        var parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.first?.lowercased() == "github.com" { parts.removeFirst() }
        else if text.contains(".") && text.split(separator: "/").first?.contains(".") == true { return nil } // another host
        guard parts.count >= 2 else { return nil }
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard validOwner(parts[0]), validRepo(repo) else { return nil }
        var source = SkillSource(owner: parts[0], repo: repo)
        var rest = Array(parts.dropFirst(2))
        if let kind = rest.first, kind == "tree" || kind == "blob", rest.count >= 2 {
            source.ref = rest[1]
            rest = Array(rest.dropFirst(2))
            if kind == "blob", let last = rest.last, last.lowercased() == "skill.md" { rest.removeLast() }
        }
        source.path = rest.joined(separator: "/")
        if let last = rest.last, last.lowercased() == "skill.md" { source.path = rest.dropLast().joined(separator: "/") }
        guard validPath(source.path) else { return nil }
        return source
    }
}

/// Git's own content hashes, computed in Swift: a downloaded skill folder is the commit's folder exactly
/// when its tree hash equals the tree GitHub lists for that path at that commit.
public enum GitHash {
    static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hexBytes(_ hex: String) -> Data {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return data
    }

    /// A blob's hash: sha1("blob <size>\0" + content).
    public static func blob(_ content: Data) -> String {
        sha1(Data("blob \(content.count)\0".utf8) + content)
    }

    /// A file's blob hash, read 1 MB at a time (a large file never sits in memory whole).
    public static func blob(file path: String, size: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\0".utf8))
        var read = 0
        while true {
            // nil (or empty) is the end of the file; a throw is a read that failed.
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            read += chunk.count
            hasher.update(data: chunk)
        }
        guard read == size else { return nil } // changed while being read
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One entry of a tree.
    public struct Entry: Sendable {
        public enum Kind: Sendable { case file, executable, link, tree }
        public let name: String
        public let kind: Kind
        public let hash: String

        var mode: String {
            switch kind {
            case .file: return "100644"
            case .executable: return "100755"
            case .link: return "120000"
            case .tree: return "40000"
            }
        }
    }

    /// A tree's hash. Entries are sorted the way git sorts them: by name, a folder as if its name ended in "/".
    public static func tree(_ entries: [Entry]) -> String {
        let sorted = entries.sorted { a, b in
            let ka = a.kind == .tree ? a.name + "/" : a.name
            let kb = b.kind == .tree ? b.name + "/" : b.name
            return Array(ka.utf8).lexicographicallyPrecedes(Array(kb.utf8))
        }
        var body = Data()
        for entry in sorted {
            body += Data("\(entry.mode) \(entry.name)\0".utf8)
            body += hexBytes(entry.hash)
        }
        return sha1(Data("tree \(body.count)\0".utf8) + body)
    }

    /// The tree hash of a folder on disk, as git would compute it. Empty folders are left out (git does
    /// not record them); a link's content is its target. `ignoring`: names left out at every level (Finder's
    /// .DS_Store, when comparing an installed copy with what was installed).
    public static func folder(_ path: String, ignoring: Set<String> = []) -> String? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: path) else { return nil }
        var entries: [Entry] = []
        for name in names where !ignoring.contains(name) {
            let full = (path as NSString).appendingPathComponent(name)
            var info = stat()
            guard lstat(full, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                guard let target = try? manager.destinationOfSymbolicLink(atPath: full) else { return nil }
                entries.append(Entry(name: name, kind: .link, hash: blob(Data(target.utf8))))
            case S_IFDIR:
                guard let sub = folder(full, ignoring: ignoring) else { return nil }
                if sub == emptyTree { continue }
                entries.append(Entry(name: name, kind: .tree, hash: sub))
            case S_IFREG:
                guard let hash = blob(file: full, size: Int(info.st_size)) else { return nil }
                let executable = info.st_mode & 0o100 != 0
                entries.append(Entry(name: name, kind: executable ? .executable : .file, hash: hash))
            default:
                return nil // a device, a pipe: not something a skill holds
            }
        }
        return tree(entries)
    }

    /// The hash of a tree with nothing in it.
    public static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
}

/// A skill folder in a commit's file listing: its path and git tree hash.
public struct SkillFolder: Equatable, Sendable {
    /// The skill's folder in the repository ("" for the root).
    public let path: String
    /// That folder's git tree hash at the commit.
    public let tree: String
    /// Every file and folder inside it, relative to it, spelled as committed: tar may unpack a name in
    /// another spelling, and the tree hash covers names byte for byte.
    public let entries: [String]
    /// SKILL.md's path (what the lock file records).
    public var skillPath: String { path.isEmpty ? "SKILL.md" : path + "/SKILL.md" }

    public init(path: String, tree: String, entries: [String] = []) {
        self.path = path
        self.tree = tree
        self.entries = entries
    }
}

/// GitHub's recursive tree listing (`git/trees/<sha>?recursive=1`), read for skill folders.
public enum SkillTreeListing {
    /// Every folder holding a SKILL.md, under `prefix` ("" for anywhere), sorted, and whether GitHub cut
    /// the listing short. nil: not a listing.
    public static func parse(_ data: Data, rootTree: String, prefix: String) -> (skills: [SkillFolder], truncated: Bool)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["tree"] as? [[String: Any]] else { return nil }
        var folders: [String: String] = ["": rootTree]
        var skillFolders: [String] = []
        var paths: [String] = []
        for entry in entries {
            guard let path = entry["path"] as? String, let type = entry["type"] as? String else { continue }
            if type == "tree" || type == "blob" { paths.append(path) }
            if type == "tree", let hash = entry["sha"] as? String { folders[path] = hash }
            if type == "blob", ["SKILL.md", "skill.md"].contains((path as NSString).lastPathComponent) {
                skillFolders.append((path as NSString).deletingLastPathComponent)
            }
        }
        // Split up: as one chain this is slow for the Swift 6.1 type checker.
        let plain = Set(skillFolders.filter(isPlainPath))
        let wanted = plain.filter { prefix.isEmpty || $0 == prefix || $0.hasPrefix(prefix + "/") }
        let found: [SkillFolder] = wanted.compactMap { folder in
            guard let tree = folders[folder] else { return nil }
            let inside = folder.isEmpty ? paths : paths.compactMap { $0.hasPrefix(folder + "/") ? String($0.dropFirst(folder.count + 1)) : nil }
            return SkillFolder(path: folder, tree: tree, entries: inside)
        }
        let truncated = json["truncated"] as? Bool ?? false
        return (found.sorted { $0.path < $1.path }, truncated)
    }

    /// tar reads `--include` as a pattern: a folder named with `*`, `?`, `[` or a backslash would match
    /// other folders (and dodge the unpack budget), so such folders, and names with control characters,
    /// are left out of what can be installed.
    static func isPlainPath(_ path: String) -> Bool {
        !path.unicodeScalars.contains { "*?[]\\".unicodeScalars.contains($0) || $0.value < 0x20 || $0.value == 0x7F }
    }

    /// A path as a tar pattern that matches only itself: the pattern characters escaped.
    public static func tarLiteral(_ path: String) -> String {
        var out = ""
        for character in path {
            if "\\*?[]".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// Folders as a `tar --null -T` list: each folder and everything in it, written as given and
    /// decomposed. tar compares a pattern with a name as the archive stores it, which is as committed,
    /// or decomposed when it comes from a pax header (the way macOS file names are: some ranges are
    /// left whole); only one spelling is in the archive. Raw bytes in a file, because arguments would
    /// reach tar decomposed.
    public static func tarPatternList(_ folders: [String]) -> Data {
        // By bytes: Swift's String equality would treat the spellings as one.
        var seen = Set<[UInt8]>()
        var out = Data()
        for folder in folders {
            for form in [folder, folder.decomposedStringWithCanonicalMapping, fileSystemDecomposed(folder)] {
                let literal = tarLiteral(form)
                for pattern in [literal, literal + "/*"] where seen.insert(Array(pattern.utf8)).inserted {
                    out.append(contentsOf: Array(pattern.utf8))
                    out.append(0)
                }
            }
        }
        return out
    }

    /// Decomposed as macOS file names are: characters in U+2000–U+2FFF, U+F900–U+FAFF and
    /// U+2F800–U+2FAFF stay whole.
    static func fileSystemDecomposed(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let whole = (0x2000...0x2FFF).contains(v) || (0xF900...0xFAFF).contains(v) || (0x2F800...0x2FAFF).contains(v)
            if whole { out.append(scalar) } else { out.append(contentsOf: String(scalar).decomposedStringWithCanonicalMapping.unicodeScalars) }
        }
        return String(out)
    }

    /// Whether `relative` (a/b/c) inside `root` is a folder reached through real folders only: a link
    /// on the way (or a name that matches another folder's case or spelling and is a link) could lead
    /// out of the download.
    public static func isRealFolder(_ relative: String, in root: String) -> Bool {
        var path = root
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        for component in relative.split(separator: "/") {
            path = (path as NSString).appendingPathComponent(String(component))
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        }
        return true
    }

    /// Puts back the committed spelling of names tar unpacked in another one (it decomposes names it
    /// reads from pax headers, which git uses for long paths). Only names with non-ASCII characters,
    /// only through real folders, and only renaming within a folder.
    public static func restoreSpelling(in folder: String, entries: [String]) {
        var listings: [String: [String]] = [:]
        let named = entries.filter { $0.utf8.contains { $0 >= 0x80 } }
        let ordered = named.sorted { $0.split(separator: "/").count < $1.split(separator: "/").count }
        for entry in ordered {
            let parentRelative = (entry as NSString).deletingLastPathComponent
            let want = (entry as NSString).lastPathComponent
            guard isRealFolder(parentRelative, in: folder) else { continue }
            let parent = parentRelative.isEmpty ? folder : (folder as NSString).appendingPathComponent(parentRelative)
            let names = listings[parent] ?? rawNames(in: parent)
            listings[parent] = names
            // Swift's == is canonical equivalence: the same name, in another spelling.
            guard let onDisk = names.first(where: { $0 == want && Array($0.utf8) != Array(want.utf8) }) else { continue }
            if rename((parent as NSString).appendingPathComponent(onDisk), (parent as NSString).appendingPathComponent(want)) == 0 {
                listings[parent] = nil
            }
        }
    }

    /// A folder's entry names exactly as stored (Foundation may change their spelling).
    static func rawNames(in folder: String) -> [String] {
        guard let handle = opendir(folder) else { return [] }
        defer { closedir(handle) }
        var names: [String] = []
        while let entry = readdir(handle) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// Whether tar's complaints are only about patterns that matched nothing (the spelling not in the
    /// archive): "tar: <name>: Not found in archive", then a closing line.
    public static func tarErrorsAreOnlyMissingNames(_ text: String) -> Bool {
        // Split on line feeds only: a name may hold other line separators (U+2028, U+0085).
        let lines = text.utf8.split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) }
        return lines.allSatisfy { line in
            line.hasSuffix(": Not found in archive") || line == "tar: Error exit delayed from previous errors."
        }
    }

    /// Whether GitHub's compare answer (`compare/<sha>...<default branch>`) shows the commit on the
    /// default branch: the branch is the commit, or comes after it. A commit only in a fork is "behind"
    /// or "diverged".
    public static func commitIsOnBranch(compareStatus: String?) -> Bool {
        compareStatus == "identical" || compareStatus == "ahead"
    }
}
