import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// What to find, and where.
public struct SearchQuery: Equatable, Sendable {
    public var text: String
    public var isRegex = false
    public var matchCase = false
    public var wholeWord = false
    /// File masks: "*.php", "src/**/*.ts". A leading "!" excludes: "!*.min.js", "!tests/**".
    public var masks: [String] = []

    public init(text: String, isRegex: Bool = false, matchCase: Bool = false, wholeWord: Bool = false, masks: [String] = []) {
        self.text = text
        self.isRegex = isRegex
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.masks = masks
    }

    /// The pattern to search with. Throws for an invalid regular expression.
    public func expression() throws -> NSRegularExpression {
        var pattern = isRegex ? text : NSRegularExpression.escapedPattern(for: text)
        if wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        return try NSRegularExpression(pattern: pattern, options: matchCase ? [] : [.caseInsensitive])
    }

    /// Whether a project-relative path passes the masks: it must match one include (if any) and no exclude.
    public func includes(_ relativePath: String) -> Bool {
        let includes = masks.filter { !$0.hasPrefix("!") && !$0.isEmpty }
        let excludes = masks.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) }.filter { !$0.isEmpty }
        if excludes.contains(where: { Self.glob($0, matches: relativePath) }) { return false }
        return includes.isEmpty || includes.contains { Self.glob($0, matches: relativePath) }
    }

    /// "*.php" matches the file name anywhere; a mask with "/" matches the whole relative path, where
    /// "**" spans folders.
    static func glob(_ mask: String, matches path: String) -> Bool {
        if !mask.contains("/") {
            let name = path.split(separator: "/").last.map(String.init) ?? path
            return fnmatch(mask, name, 0) == 0
        }
        // fnmatch without FNM_PATHNAME lets "*" cross "/", which is what "**" means here.
        let pattern = mask.replacingOccurrences(of: "**/", with: "*").replacingOccurrences(of: "**", with: "*")
        return fnmatch(pattern, path, 0) == 0 || fnmatch(pattern, path, FNM_LEADING_DIR) == 0
    }
}

/// One match. Ranges are UTF-16 offsets within `lineText` (as NSString/NSRange count).
public struct SearchMatch: Hashable, Sendable {
    public let relativePath: String
    /// 1-based.
    public let line: Int
    public let lineText: String
    public let range: NSRange
    public var matchedText: String { (lineText as NSString).substring(with: range) }
}

/// The order results are listed in when searching from a file: that file, then files of its type, then the
/// rest, each group by path. "Same type" is the full compound extension first (`blade.php`), then the
/// last one (`php`).
public struct ResultOrder: Sendable {
    public let current: String?
    let compound: String?
    let plain: String?

    /// `current`: the file being edited, relative to the search root (nil: plain path order).
    public init(current: String?) {
        self.current = current
        guard let current else { compound = nil; plain = nil; return }
        let name = (current as NSString).lastPathComponent.lowercased()
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        // "welcome.blade.php" -> "blade.php"; ".env" has no type to group by.
        compound = parts.count > 2 && !parts[0].isEmpty ? parts.suffix(2).joined(separator: ".") : nil
        plain = parts.count > 1 && !(parts.count == 2 && parts[0].isEmpty) ? String(parts.last!) : nil
    }

    public func rank(_ path: String) -> Int {
        guard current != nil else { return 0 }
        if path == current { return 0 }
        let name = (path as NSString).lastPathComponent.lowercased()
        if let compound, name.hasSuffix("." + compound) { return 1 }
        if let plain, name.hasSuffix("." + plain) { return 2 }
        return 3
    }

    /// Whether `a` is listed before `b`.
    public func precedes(_ a: String, _ b: String) -> Bool {
        let ra = rank(a), rb = rank(b)
        return ra != rb ? ra < rb : a < b
    }

    /// "php" for the panel's button.
    public var typeLabel: String? { compound ?? plain }
}

public struct FileMatches: Sendable {
    public let relativePath: String
    public let matches: [SearchMatch]
}

public enum ProjectSearch {
    public static let maxFileSize = 5_000_000
    public static let maxMatches = 20_000
    /// Folders never worth searching when git cannot tell us what is ignored.
    static let skippedFolders: Set<String> = [".git", "node_modules", "vendor", ".build", "build", "dist", "DerivedData", ".next", ".venv", "__pycache__"]

    /// Files to search: git's tracked and untracked-but-not-ignored files when `root` is in a repository,
    /// else a walk that skips the usual dependency and build folders. Paths relative to `root`.
    public static func files(in root: String, git: String?) -> [String] {
        if let git, let data = GitRunner.run(git, ["-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"], timeout: 30) {
            let paths = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            if !paths.isEmpty { return Array(Set(paths)).sorted() }
        }
        var result: [String] = []
        let base = URL(fileURLWithPath: root)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) else { return [] }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if skippedFolders.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let path = url.path.hasPrefix(base.path + "/") ? String(url.path.dropFirst(base.path.count + 1)) : url.lastPathComponent
            result.append(path)
        }
        return result.sorted()
    }

    /// Text of a file if it is searchable: not too big, not binary, valid UTF-8.
    static func text(of url: URL) -> String? {
        guard isRegularFile(url.path), let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxFileSize,
              let data = try? Data(contentsOf: url), !data.prefix(8000).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The matches in one text, line by line.
    public static func matches(in text: String, relativePath: String, expression: NSRegularExpression, limit: Int = maxMatches) -> [SearchMatch] {
        // Same line splitting as replace(), so line numbers always agree.
        var found: [SearchMatch] = []
        for (index, (line, _)) in splitLines(text).enumerated() {
            let ns = line as NSString
            for result in expression.matches(in: line, range: NSRange(location: 0, length: ns.length)) where result.range.length > 0 {
                found.append(SearchMatch(relativePath: relativePath, line: index + 1, lineText: line, range: result.range))
                if found.count >= limit { return found }
            }
        }
        return found
    }

    /// Searches files in parallel. Results arrive per file through `found`, from background threads.
    /// Returns the number of matches, stopping at `maxMatches` or when `isCancelled` says so.
    @discardableResult
    public static func search(root: String, files: [String], query: SearchQuery,
                              isCancelled: @escaping () -> Bool = { false },
                              found: @escaping (FileMatches) -> Void) throws -> Int {
        let expression = try query.expression()
        let candidates = files.filter(query.includes)
        let lock = NSLock()
        var total = 0
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            if isCancelled() { return }
            lock.lock()
            let full = total >= maxMatches
            lock.unlock()
            if full { return }
            let path = candidates[index]
            guard let text = text(of: URL(fileURLWithPath: root).appendingPathComponent(path)) else { return }
            let matches = Self.matches(in: text, relativePath: path, expression: expression)
            guard !matches.isEmpty else { return }
            lock.lock()
            total += matches.count
            lock.unlock()
            found(FileMatches(relativePath: path, matches: matches))
        }
        return total
    }

    /// What a replacement does to one line, for previews: the line with the match replaced.
    public static func preview(_ match: SearchMatch, replacement: String, query: SearchQuery) -> String? {
        guard let expression = try? query.expression() else { return nil }
        let ns = match.lineText as NSString
        guard let result = expression.firstMatch(in: match.lineText, range: match.range) else { return nil }
        let template = query.isRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        let replaced = expression.replacementString(for: result, in: match.lineText, offset: 0, template: template)
        return ns.replacingCharacters(in: match.range, with: replaced)
    }

    public struct ReplaceResult: Equatable, Sendable {
        public var replaced = 0
        /// Selected matches that were no longer there (the file changed since the search).
        public var skipped = 0
        /// The file before the change, for undo.
        public var original: Data?
    }

    /// Replaces the selected matches in one file. The file is read again and searched again first:
    /// a match is replaced only if it is still on the same line with the same text, so edits made since
    /// the search (by you or an agent) are never overwritten. Keeps the file's permissions.
    public static func replace(_ selected: [SearchMatch], in root: String, with replacement: String,
                               query: SearchQuery) throws -> ReplaceResult {
        guard let first = selected.first else { return ReplaceResult() }
        let url = URL(fileURLWithPath: root).appendingPathComponent(first.relativePath)
        let original = try Data(contentsOf: url)
        guard let text = String(data: original, encoding: .utf8) else {
            throw NSError(domain: "NextTerm", code: 10, userInfo: [NSLocalizedDescriptionKey: "\(first.relativePath) is not UTF-8 text."])
        }
        let expression = try query.expression()
        let wanted = Set(selected.map { Key(line: $0.line, location: $0.range.location, text: $0.matchedText) })
        let template = query.isRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)

        // Walk the current text line by line (keeping its own line endings) and rebuild it.
        var output = ""
        var result = ReplaceResult()
        var lineNumber = 0
        var matchedKeys = Set<Key>()
        for (line, ending) in splitLines(text) {
            lineNumber += 1
            let ns = line as NSString
            var newLine = line
            var shift = 0
            for match in expression.matches(in: line, range: NSRange(location: 0, length: ns.length)) where match.range.length > 0 {
                let key = Key(line: lineNumber, location: match.range.location, text: ns.substring(with: match.range))
                guard wanted.contains(key) else { continue }
                let replaced = expression.replacementString(for: match, in: line, offset: 0, template: template)
                let range = NSRange(location: match.range.location + shift, length: match.range.length)
                newLine = (newLine as NSString).replacingCharacters(in: range, with: replaced)
                shift += (replaced as NSString).length - match.range.length
                matchedKeys.insert(key)
                result.replaced += 1
            }
            output += newLine + ending
        }
        result.skipped = wanted.subtracting(matchedKeys).count
        guard result.replaced > 0 else { return result }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        try Data(output.utf8).write(to: url, options: .atomic)
        if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        result.original = original
        return result
    }

    private struct Key: Hashable {
        let line: Int
        let location: Int
        let text: String
    }

    /// Lines with their own endings ("\n", "\r\n" or none), so a rewrite keeps the file's line endings.
    static func splitLines(_ text: String) -> [(String, String)] {
        var lines: [(String, String)] = []
        var current = ""
        var iterator = text.makeIterator()
        while let ch = iterator.next() {
            if ch == "\r\n" { lines.append((current, "\r\n")); current = ""; continue }
            if ch == "\n" { lines.append((current, "\n")); current = ""; continue }
            current.append(ch)
        }
        if !current.isEmpty || lines.isEmpty { lines.append((current, "")) }
        return lines
    }
}
