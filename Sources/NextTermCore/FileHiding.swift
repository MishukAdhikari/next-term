import Foundation

/// Settings › Editor › Hide in sidebar: files and folders the project sidebar leaves out, by pattern, read the
/// way .gitignore reads them. A pattern without "/" hides that name at any depth ("node_modules", "*.pyc"); one
/// with "/" is relative to the folder the sidebar shows ("/build", "docs/_site"); a "/" at the end hides only
/// folders. "*" and "?" stay within a name, "**" spans folders, "[abc]" is one of those characters and "{a,b}"
/// either word. The sidebar's own (.git, .DS_Store) are hidden whatever this holds.
public struct FileHiding: Sendable {
    struct Pattern: Sendable {
        /// Matched against the whole path below the root (anchored), else against the last name.
        let anchored: Bool
        let foldersOnly: Bool
        /// The pattern with its braces spelled out, one per alternative.
        let globs: [[Character]]
    }

    public let root: String
    let patterns: [Pattern]

    public init(patterns: [String], root: String) {
        self.root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        self.patterns = patterns.compactMap(Self.pattern)
    }

    public var isEmpty: Bool { patterns.isEmpty }

    /// A setting's text as patterns: one per line or between commas, blanks dropped, each once.
    public static func patterns(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The patterns as the setting shows them.
    public static func text(of patterns: [String]) -> String { patterns.joined(separator: ", ") }

    /// A glob as VS Code's `files.exclude` and Zed's `file_scan_exclusions` write it, relative to the project's
    /// folder with "**/" for any depth, as a pattern here: "**/node_modules" is "node_modules", "build" is "/build",
    /// and "dist/**" the folder "/dist/". Nil for nothing, and for the names the sidebar hides anyway.
    public static func pattern(fromProjectGlob glob: String) -> String? {
        var text = glob.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("./") { text.removeFirst(2) }
        var folder = false
        if text.hasSuffix("/**") {
            text.removeLast(3)
            folder = true
        } else if text.count > 1, text.hasSuffix("/") {
            text.removeLast()
            folder = true
        }
        guard !text.isEmpty, text != "**", text != "/" else { return nil }
        let name = text.hasPrefix("**/") ? String(text.dropFirst(3)) : nil
        if let name, !name.isEmpty, !name.contains("/") {
            if FileNode.hiddenNames.contains(name) { return nil }
            return name + (folder ? "/" : "")
        }
        if FileNode.hiddenNames.contains(text) { return nil }
        return (text.hasPrefix("/") ? text : "/" + text) + (folder ? "/" : "")
    }

    static func pattern(_ raw: String) -> Pattern? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var foldersOnly = false
        while text.count > 1, text.hasSuffix("/") {
            text.removeLast()
            foldersOnly = true
        }
        var anchored = text.contains("/")
        while text.hasPrefix("/") {
            text.removeFirst()
            anchored = true
        }
        guard !text.isEmpty, text != "/" else { return nil }
        return Pattern(anchored: anchored, foldersOnly: foldersOnly, globs: expandBraces(text).map(Array.init))
    }

    /// Whether the sidebar leaves out this file or folder (`path` absolute, below the root).
    public func hides(_ path: String, isDirectory: Bool) -> Bool {
        guard !patterns.isEmpty else { return false }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return false }
        let relative = Array(path.dropFirst(prefix.count))
        let name = Array((path as NSString).lastPathComponent)
        for pattern in patterns where isDirectory || !pattern.foldersOnly {
            let subject = pattern.anchored ? relative : name
            if pattern.globs.contains(where: { Self.matches($0[...], subject[...]) }) { return true }
        }
        return false
    }

    // MARK: matching

    /// "{a,b}c" → ["ac", "bc"], braces inside braces too. An unclosed brace is kept as it is.
    static func expandBraces(_ text: String) -> [String] {
        let characters = Array(text)
        var depth = 0
        var open: Int?
        var commas: [Int] = []
        for (index, character) in characters.enumerated() {
            if character == "{" {
                if depth == 0 { open = index; commas = [] }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                guard depth == 0, let start = open else { continue }
                let head = String(characters[..<start]), tail = String(characters[(index + 1)...])
                var parts: [String] = []
                var from = start + 1
                for comma in commas + [index] {
                    parts.append(String(characters[from..<comma]))
                    from = comma + 1
                }
                return parts.flatMap { part in expandBraces(head + part + tail) }
            } else if character == ",", depth == 1 {
                commas.append(index)
            }
        }
        return [text]
    }

    /// A glob against a path or a name: "**/" is any number of folders, "**" anything, "*" any run within a name,
    /// "?" one character of a name, "[…]" one of a set ("!" or "^" first: not of it), "\" the next character as itself.
    static func matches(_ glob: ArraySlice<Character>, _ text: ArraySlice<Character>) -> Bool {
        var glob = glob, text = text
        while let first = glob.first {
            switch first {
            case "*":
                if glob.dropFirst().first == "*" {
                    var rest = glob.dropFirst(2)
                    if rest.first == "/" {
                        rest = rest.dropFirst()
                        // Zero folders, or any number of them.
                        if matches(rest, text) { return true }
                        var remaining = text
                        while let slash = remaining.firstIndex(of: "/") {
                            remaining = remaining[remaining.index(after: slash)...]
                            if matches(rest, remaining) { return true }
                        }
                        return false
                    }
                    if rest.isEmpty { return true }
                    var remaining = text
                    while true {
                        if matches(rest, remaining) { return true }
                        guard !remaining.isEmpty else { return false }
                        remaining = remaining.dropFirst()
                    }
                }
                let rest = glob.dropFirst()
                var remaining = text
                while true {
                    if matches(rest, remaining) { return true }
                    guard let next = remaining.first, next != "/" else { return false }
                    remaining = remaining.dropFirst()
                }
            case "?":
                guard let next = text.first, next != "/" else { return false }
                glob = glob.dropFirst()
                text = text.dropFirst()
            case "[":
                guard let next = text.first, next != "/", let set = characterSet(glob) else {
                    // An unclosed "[" is itself.
                    guard text.first == "[" else { return false }
                    glob = glob.dropFirst()
                    text = text.dropFirst()
                    continue
                }
                guard set.matches(next) else { return false }
                glob = glob.dropFirst(set.length)
                text = text.dropFirst()
            case "\\" where glob.count > 1:
                let escaped = glob[glob.index(after: glob.startIndex)]
                guard text.first == escaped else { return false }
                glob = glob.dropFirst(2)
                text = text.dropFirst()
            default:
                guard text.first == first else { return false }
                glob = glob.dropFirst()
                text = text.dropFirst()
            }
        }
        return text.isEmpty
    }

    struct CharacterClass {
        let negated: Bool
        let ranges: [ClosedRange<Character>]
        /// How many characters of the glob it takes, brackets included.
        let length: Int

        func matches(_ character: Character) -> Bool {
            ranges.contains { $0.contains(character) } != negated
        }
    }

    /// The "[…]" at the start of `glob`, or nil when it never closes.
    static func characterSet(_ glob: ArraySlice<Character>) -> CharacterClass? {
        var index = glob.index(after: glob.startIndex)
        var negated = false
        if index < glob.endIndex, glob[index] == "!" || glob[index] == "^" {
            negated = true
            index = glob.index(after: index)
        }
        var ranges: [ClosedRange<Character>] = []
        var first = true
        while index < glob.endIndex {
            let character = glob[index]
            if character == "]" && !first {
                return CharacterClass(negated: negated, ranges: ranges, length: glob.distance(from: glob.startIndex, to: index) + 1)
            }
            first = false
            let dash = glob.index(after: index)
            if dash < glob.endIndex, glob[dash] == "-" {
                let end = glob.index(after: dash)
                if end < glob.endIndex, glob[end] != "]", character <= glob[end] {
                    ranges.append(character...glob[end])
                    index = glob.index(after: end)
                    continue
                }
            }
            ranges.append(character...character)
            index = dash
        }
        return nil
    }
}
