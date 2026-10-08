import Foundation

/// Something to show an agent: a file or folder, optionally lines in it, optionally code that is not on
/// disk (deleted lines, an unsaved buffer, terminal output).
public struct ContextItem: Equatable, Sendable {
    public var path: String
    public var lines: ClosedRange<Int>?
    public var isFolder = false
    /// "unstaged change, +4 −2" and the like.
    public var note: String?
    /// Inline code, only when it is not on disk.
    public var code: String?
    /// Fence language for `code` ("swift", "diff", "text").
    public var language = "text"

    public init(path: String, lines: ClosedRange<Int>? = nil, isFolder: Bool = false, note: String? = nil,
                code: String? = nil, language: String = "text") {
        self.path = path
        self.lines = lines
        self.isFolder = isFolder
        self.note = note
        self.code = code
        self.language = language
    }
}

/// How an agent wants files referenced. Kept as data: agents change their syntax between releases.
public enum AgentDialect: String, Sendable {
    /// Claude Code: `@src/a.ts#L42-58 ` (and opencode). Contents are attached by the agent.
    case atHash
    /// `@src/a.ts` with the lines in prose: Copilot CLI (line syntax unknown), and Gemini / Qwen Code,
    /// which read the whole file for `@path` and drop any line suffix before the model sees it.
    /// Folders stay plain paths: `@folder` reads everything in it, recursively.
    case atProse
    /// Everyone else, and unknown agents: `src/a.ts:42-58`. Every model reads it; no agent turns it into
    /// a mode switch or an inlined file.
    case plain

    public static func forProgram(_ name: String) -> AgentDialect {
        switch name {
        case "claude", "claude-code", "claude.exe", "opencode": return .atHash
        case "copilot", "gemini", "gemini-cli", "qwen", "qwen-code": return .atProse
        default: return .plain
        }
    }

    /// Claude collapses a paste longer than this into "[Pasted text]" and treats it as data, so the
    /// instruction part stays within it.
    var inlineLimit: (lines: Int, characters: Int)? {
        self == .atHash ? (3, 800) : nil
    }
}

/// Builds what gets pasted into an agent's input. The bytes are bracketed-pasted by the terminal tab;
/// this decides only their content.
public enum AgentPrompt {
    /// Inline code beyond this is referenced instead of pasted.
    public static let maxInlineLines = 200
    public static let maxInlineBytes = 16_384

    public static func reference(_ item: ContextItem, dialect: AgentDialect) -> String {
        let quoted = item.path.contains(" ") ? "\"\(item.path)\"" : item.path
        var ref: String
        switch dialect {
        case .atHash:
            ref = "@" + quoted + (item.isFolder && !item.path.hasSuffix("/") ? "/" : "")
            if let lines = item.lines {
                // `#L` inside quotes is unverified for Claude: say the lines in prose instead.
                ref += item.path.contains(" ") ? " (lines \(lines.lowerBound)-\(lines.upperBound))"
                    : (lines.count == 1 ? "#L\(lines.lowerBound)" : "#L\(lines.lowerBound)-\(lines.upperBound)")
            }
        case .atProse:
            if item.isFolder {
                ref = item.path + (item.path.hasSuffix("/") ? "" : "/") + " (folder)"
            } else {
                ref = "@" + quoted
                if let lines = item.lines { ref += lines.count == 1 ? " (line \(lines.lowerBound))" : " (lines \(lines.lowerBound)-\(lines.upperBound))" }
            }
        case .plain:
            ref = item.path + (item.isFolder && !item.path.hasSuffix("/") ? "/" : "")
            if let lines = item.lines { ref += lines.count == 1 ? ":\(lines.lowerBound)" : ":\(lines.lowerBound)-\(lines.upperBound)" }
            if item.isFolder { ref += " (folder)" }
        }
        if let note = item.note { ref += " (\(note))" }
        return ref
    }

    /// The pastes to make, in order: the instruction with references first, then any code as a second
    /// paste (Claude shows it as "[Pasted text]" data that the typed instruction refers to).
    public static func segments(instruction: String, items: [ContextItem], dialect: AgentDialect) -> [String] {
        var head = sanitize(instruction).trimmingCharacters(in: .whitespacesAndNewlines)
        let refs = items.map { reference($0, dialect: dialect) }
        switch dialect {
        case .atHash, .atProse:
            // One line, mentions separated by spaces, and a space after the last mention so a completion
            // popup does not take the developer's Enter.
            let joined = refs.joined(separator: " ")
            head = [head, joined].filter { !$0.isEmpty }.joined(separator: " ") + (refs.isEmpty ? "" : " ")
        case .plain:
            if refs.count == 1 && !head.contains("\n") {
                head = head.isEmpty ? refs[0] : head + ": " + refs[0]
            } else if !refs.isEmpty {
                head += (head.isEmpty ? "" : "\n\n") + "Context:\n" + refs.map { "- " + $0 }.joined(separator: "\n")
            }
        }
        head = defuseLeadingCommand(head)
        var result = [head]
        let blocks = items.compactMap { item -> String? in
            guard let code = item.code, !code.isEmpty else { return nil }
            return block(code, language: item.language)
        }
        if !blocks.isEmpty { result.append(blocks.joined(separator: "\n\n")) }
        return result
    }

    /// Code in a fence an agent reads as data. The fence is one backtick longer than the longest run of them
    /// in the code, so no line in it can close the fence early and be read as what you wrote.
    static func block(_ code: String, language: String) -> String {
        let clean = sanitize(code)
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(clean) + 1))
        return fence + language + "\n" + clean + (clean.hasSuffix("\n") ? "" : "\n") + fence
    }

    private static func longestBacktickRun(_ text: String) -> Int {
        var longest = 0
        var run = 0
        for character in text {
            if character == "`" {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return longest
    }

    /// Text selected in a terminal (output, an error) for an agent's prompt: a fenced block, so it reads as
    /// what the terminal showed, never as an instruction. Spaces at the ends of lines and blank lines around
    /// it go.
    public static func quote(_ text: String) -> String {
        var lines = sanitize(text).components(separatedBy: "\n").map { line in
            line.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        return block(lines.joined(separator: "\n"), language: "text")
    }

    /// The same on one line, for an agent that takes no pastes (a line break would send the prompt): the
    /// words joined by single spaces, never starting with a command marker.
    public static func quoteOnOneLine(_ text: String) -> String {
        let words = sanitize(text).split(whereSeparator: \.isWhitespace)
        return defuseLeadingCommand(words.joined(separator: " "))
    }

    /// Whether the instruction part is short enough for the dialect to keep it inline as typed text.
    public static func fitsInline(_ segment: String, dialect: AgentDialect) -> Bool {
        guard let limit = dialect.inlineLimit else { return true }
        return segment.count <= limit.characters && segment.split(separator: "\n", omittingEmptySubsequences: false).count <= limit.lines
    }

    /// Whether inline code should become a reference or a snapshot file instead.
    public static func isTooLargeToInline(_ code: String) -> Bool {
        code.utf8.count > maxInlineBytes || code.split(separator: "\n", omittingEmptySubsequences: false).count > maxInlineLines
    }

    /// Characters an agent treats as a command when they come first: `!` shell mode, `/` slash commands,
    /// `$` shell mode (Amp), `&` background, `?` help, `#` memory.
    static let commandMarkers: Set<Character> = ["!", "/", "$", "&", "?", "#"]

    /// Never start with a command marker: put a harmless word first.
    static func defuseLeadingCommand(_ text: String) -> String {
        guard let first = text.first, commandMarkers.contains(first) else { return text }
        return "Note: " + text
    }

    /// Removes everything that could act instead of being read: C0 controls except tab and newline, ESC,
    /// DEL, C1 controls (so a payload can never end the bracketed paste and type commands), bidi
    /// overrides, tag characters, zero-width spaces and every other format, private-use or unassigned
    /// character (invisible text, and Claude drops an Enter after them). CRLF becomes LF. Zero-width
    /// joiners stay (emoji).
    public static func sanitize(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return String(String.UnicodeScalarView(normalized.unicodeScalars.filter { scalar in
            let v = scalar.value
            if v == 0x09 || v == 0x0A { return true }
            if v < 0x20 || (0x7F...0x9F).contains(v) { return false }
            if (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) || v == 0x200E || v == 0x200F { return false }
            if (0xE0000...0xE007F).contains(v) { return false }
            if v == 0x200B || v == 0xFEFF || v == 0x2060 { return false }
            // Every other invisible formatting character, private-use and unassigned code point; the
            // zero-width joiner stays, because emoji are built with it.
            switch scalar.properties.generalCategory {
            case .format: return v == 0x200D
            case .privateUse, .unassigned: return false
            default: return true
            }
        }))
    }
}
