import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What an agent wrote when Wrap Up asked for a handoff, read leniently: Done, Next, Open questions and How to resume
/// under any heading style, Next's list lines as tomorrow's tasks, and whatever else kept as it is. The parser is pure
/// and never fails; it only ever sees text the caller has masked, and keeps it in `raw` for the sheet to show.
public struct Handoff: Equatable, Sendable {
    /// The four sections the request asks for, in its order.
    public enum Section: String, CaseIterable, Sendable {
        case done, next, openQuestions, howToResume
    }

    /// One list line: its text as typed (inline Markdown kept), and whether the agent ticked it `[x]`.
    public struct Item: Equatable, Sendable {
        public var text: String
        public var done: Bool

        public init(text: String, done: Bool = false) {
            self.text = text
            self.done = done
        }
    }

    /// A section under a heading that is none of the four, kept with its heading as written.
    public struct Other: Equatable, Sendable {
        public var heading: String
        public var lines: [String]

        public init(heading: String, lines: [String]) {
            self.heading = heading
            self.lines = lines
        }
    }

    /// The longest item, in characters, as the Add Task sheet's title: longer is cut at a word with "…".
    public static let itemLength = 200

    /// The masked text as read.
    public let raw: String
    /// The file was longer than was read: only its start is here.
    public let truncated: Bool
    /// Each section found, with its lines, blank lines at either end left out; a section found twice is one.
    public let sections: [Section: [String]]
    /// Sections under other headings, in order; one with no text is left out.
    public let other: [Other]
    /// Which of the four were found.
    public let shape: HandoffShape
    /// The Next section's items: tomorrow's tasks.
    public let next: [Item]

    public func lines(in section: Section) -> [String] { sections[section] ?? [] }

    /// A section's list lines as items, the same way Next's are read.
    public func items(in section: Section) -> [Item] { Self.items(lines(in: section)) }
}

/// Whether a handoff followed the requested shape.
public enum HandoffShape: Equatable, Sendable {
    /// All four sections are there.
    case full
    /// Some are; these are not, in the request's order.
    case partial(missing: [Handoff.Section])
    /// None of the four headings is there.
    case none
}

extension Handoff {
    /// The heading words each section is known by, lower case.
    static let names: [String: Section] = [
        "done": .done, "completed": .done, "what i did": .done,
        "next": .next, "next steps": .next, "todo": .next, "to do": .next, "follow-ups": .next,
        "follow ups": .next, "followups": .next,
        "open questions": .openQuestions, "questions": .openQuestions, "blocked": .openQuestions,
        "blockers": .openQuestions,
        "how to resume": .howToResume, "resume": .howToResume, "to resume": .howToResume,
    ]

    /// Reads `text` (masked already) into its sections. `truncated` says the text is only the file's start.
    public static func parse(_ text: String, truncated: Bool = false) -> Handoff {
        var found: [Section: [String]] = [:]
        var other: [Other] = []
        var section: Section?
        var otherIndex: Int?
        var inFence = false
        for line in Self.lines(text) {
            let heading: (name: String, shown: String)? = inFence ? nil : Self.heading(line)
            if let heading {
                if let known = names[heading.name] {
                    section = known
                    otherIndex = nil
                    if found[known] == nil { found[known] = [] }
                } else {
                    section = nil
                    other.append(Other(heading: heading.shown, lines: []))
                    otherIndex = other.count - 1
                }
                continue
            }
            if isFence(line) { inFence.toggle() }
            if let section {
                found[section, default: []].append(line)
            } else if let otherIndex {
                other[otherIndex].lines.append(line)
            }
        }
        let sections: [Section: [String]] = found.mapValues(trimmedBlank)
        let kept: [Other] = other.map { Other(heading: $0.heading, lines: trimmedBlank($0.lines)) }
        let nextItems: [Item] = items(sections[.next] ?? [])
        return Handoff(raw: text, truncated: truncated, sections: sections, other: kept.filter { !$0.lines.isEmpty },
                       shape: shape(found: Set(sections.keys)), next: nextItems)
    }

    static func shape(found: Set<Section>) -> HandoffShape {
        let missing: [Section] = Section.allCases.filter { !found.contains($0) }
        if missing.isEmpty { return .full }
        if missing.count == Section.allCases.count { return .none }
        return .partial(missing: missing)
    }

    /// The text's lines, a Windows line end read as a plain one.
    static func lines(_ text: String) -> [String] {
        let split = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lines: [String] = split.map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        return lines.last == "" ? Array(lines.dropLast()) : lines
    }

    static func trimmedBlank(_ lines: [String]) -> [String] {
        func blank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.firstIndex(where: { !blank($0) }),
              let last = lines.lastIndex(where: { !blank($0) }) else { return [] }
        return Array(lines[first...last])
    }

    /// A fenced code block's first or last line: headings and list lines inside one are text.
    static func isFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }
}

// MARK: headings and items

extension Handoff {
    /// A heading line: `#` to `######`, a line in bold alone (`**Next**`, `__Next__`), or a line ending in `:` with
    /// nothing after it whose words are one of the four sections' (a sentence ending in a colon is text). `name` is
    /// lower case with `#*_:` and spaces trimmed; `shown` keeps the case.
    static func heading(_ line: String) -> (name: String, shown: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }.count
        let atx = (1...6).contains(hashes) && (trimmed.count == hashes || trimmed.dropFirst(hashes).first == " ")
        let bold = isBoldAlone(trimmed, "**") || isBoldAlone(trimmed, "__")
        let colon = trimmed.hasSuffix(":") && listItem(line) == nil
        guard atx || bold || colon else { return nil }
        let marks = CharacterSet(charactersIn: "#*_: ").union(.whitespaces)
        let shown = trimmed.trimmingCharacters(in: marks)
        let name = shown.lowercased()
        if !atx && !bold && names[name] == nil { return nil }
        return (name, shown)
    }

    static func isBoldAlone(_ line: String, _ mark: String) -> Bool {
        guard line.count > 2 * mark.count, line.hasPrefix(mark), line.hasSuffix(mark) else { return false }
        let inner = line.dropFirst(mark.count).dropLast(mark.count)
        return !inner.contains(mark)
    }

    /// A list line's text and box: `- `, `* `, `+ `, `1. ` or `1) `, then an optional `[ ]`, `[x]` or `[X]`.
    static func listItem(_ line: String) -> (text: String, done: Bool)? {
        let body = line.drop { $0 == " " || $0 == "\t" }
        var rest: Substring
        if let first = body.first, "-*+".contains(first) {
            rest = body.dropFirst()
        } else {
            let digits = body.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count) else { return nil }
            let after = body.dropFirst(digits.count)
            guard let mark = after.first, mark == "." || mark == ")" else { return nil }
            rest = after.dropFirst()
        }
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        rest = rest.drop { $0 == " " || $0 == "\t" }
        var done = false
        for box in ["[ ]", "[x]", "[X]"] where rest.hasPrefix(box) {
            let after = rest.dropFirst(box.count)
            guard after.isEmpty || after.first == " " || after.first == "\t" else { break }
            done = box != "[ ]"
            rest = after
            break
        }
        return (rest.trimmingCharacters(in: .whitespaces), done)
    }

    /// The items in a section's lines. Indented lines after an item join it with a space; a nested list line is its
    /// own item. A section with no list line at all gives one item per line of text. Code blocks are left out.
    static func items(_ lines: [String]) -> [Item] {
        var listed: [Item] = []
        var plain: [Item] = []
        var current: Int?
        var inFence = false
        for line in lines {
            if isFence(line) {
                inFence.toggle()
                current = nil
                continue
            }
            if inFence { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let item = listItem(line) {
                listed.append(Item(text: item.text, done: item.done))
                current = listed.count - 1
            } else if trimmed.isEmpty {
                current = nil
            } else if let index = current, line.first == " " || line.first == "\t" {
                let joined = listed[index].text.isEmpty ? trimmed : listed[index].text + " " + trimmed
                listed[index].text = joined
            } else {
                current = nil
                plain.append(Item(text: trimmed))
            }
        }
        return cleaned(listed.isEmpty ? plain : listed)
    }

    /// Each item cut to `itemLength`; empty ones, rules (`- - -`) and exact repeats of an earlier one left out.
    static func cleaned(_ items: [Item]) -> [Item] {
        var seen: Set<String> = []
        var kept: [Item] = []
        let rule = CharacterSet(charactersIn: "-*_= ")
        for item in items {
            let text = cut(item.text)
            guard !text.unicodeScalars.allSatisfy({ rule.contains($0) }) else { continue }
            guard seen.insert(text).inserted else { continue }
            kept.append(Item(text: text, done: item.done))
        }
        return kept
    }

    /// Over `itemLength` characters: cut at the last space before the limit, with "…" added.
    static func cut(_ text: String) -> String {
        guard text.count > itemLength else { return text }
        let head = text.prefix(itemLength - 1)
        let words = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return words.trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Reading a handoff file: the file itself, never a link to one, at most `limit` bytes of it, decoded as the editor
/// decodes text and masked before anything holds it. Nothing read is logged.
public enum HandoffFile {
    /// How much of a handoff is read: a file longer than this is not a handoff, and the review must stay quick.
    public static let limit = 256 * 1024

    public enum Read: Equatable, Sendable {
        case text(Handoff)
        /// No file by that name yet.
        case missing
        /// A link, a folder or anything else that is not a plain file: never followed or read.
        case notPlainFile
        /// Not text: binary, or an encoding the editor doesn't read.
        case notText
        /// There, but it can't be opened.
        case unreadable
    }

    /// The handoff at `url`, masked with `mask` and parsed.
    public static func read(_ url: URL, mask: (String) -> String = { SecretMask.current.mask($0) },
                            limit: Int = limit) -> Read {
        let path = url.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let attributes else {
            return FileManager.default.fileExists(atPath: path) || isLink(path) ? .unreadable : .missing
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return .notPlainFile }
        // O_NOFOLLOW: a link swapped in after the look above is refused, not followed.
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return errno == ELOOP ? .notPlainFile : .unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .notPlainFile }
        guard let data = try? handle.read(upToCount: limit + 1) else { return .unreadable }
        let truncated = data.count > limit
        guard let text = decode(truncated ? Data(data.prefix(limit)) : data, cut: truncated) else { return .notText }
        return .text(Handoff.parse(mask(text), truncated: truncated))
    }

    static func isLink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    /// The text in `data`. When the data was cut, up to three bytes of a letter cut in half are left off its end.
    static func decode(_ data: Data, cut: Bool) -> String? {
        let tries: Int = cut ? min(3, data.count) : 0
        for drop in 0...tries {
            if let decoded = TextFile.decode(Data(data.dropLast(drop))) { return decoded.text }
        }
        return nil
    }
}
