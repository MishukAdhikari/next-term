import Foundation

/// Handing prompts typed into the wrong agent's tab to the session they were meant for (plan 042): which session
/// they fit, and what the target is given. The app gathers the candidates and delivers (MCPHandoverControl); this is
/// the pure part, so the matching is tested without tabs.
///
/// A candidate is scored against the user's words about the target (`hint`: "find the cs tab") and the prompts
/// themselves, on its project folder's name, its title, its branch and its recent prompts. A folder's short names
/// count as its name: the initials of its words ("coding-sessions" → "cs") and the words run together. One candidate
/// well ahead of the next is a clear match; anything else is the user's to choose.
public enum PromptHandover {
    public struct Candidate: Equatable, Sendable {
        /// A tab's id, or a closed session's agent and id ("claude:…").
        public var id: String
        /// Open in a tab now, or a closed session that is resumed first.
        public var open: Bool
        /// The agent, as the user knows it ("Claude Code").
        public var agent: String
        /// The project's folder, absolute.
        public var folder: String
        public var title: String
        public var branch: String?
        /// The user's latest prompts in that session, newest last.
        public var recentPrompts: [String]

        public init(id: String, open: Bool, agent: String, folder: String, title: String, branch: String? = nil,
                    recentPrompts: [String] = []) {
            self.id = id
            self.open = open
            self.agent = agent
            self.folder = folder
            self.title = title
            self.branch = branch
            self.recentPrompts = recentPrompts
        }

        /// The folder's last part.
        public var project: String { (folder as NSString).lastPathComponent }
    }

    public struct Ranked: Equatable, Sendable {
        public var candidate: Candidate
        public var score: Int
    }

    public struct Ranking: Equatable, Sendable {
        /// Best first; candidates that matched nothing are left out.
        public var ranked: [Ranked]
        /// The first is far enough ahead of the rest to send without asking.
        public var clear: Bool

        public var best: Candidate? { ranked.first?.candidate }
    }

    /// The least a clear match scores, and how far ahead of the next it must be.
    static let clearScore = 30
    static let clearLead = 20

    /// Ranks `candidates` for the user's `hint` and the `prompts` being moved.
    public static func rank(_ candidates: [Candidate], hint: String, prompts: [String]) -> Ranking {
        let hintWords = words(hint).filter { !hintNoise.contains($0) }
        let promptWords = Set(prompts.flatMap { words($0) }).subtracting(promptNoise)
        var ranked: [Ranked] = []
        for candidate in candidates {
            let score = self.score(candidate, hint: hintWords, prompts: promptWords)
            if score > 0 { ranked.append(Ranked(candidate: candidate, score: score)) }
        }
        ranked.sort { $0.score != $1.score ? $0.score > $1.score : ($0.candidate.open && !$1.candidate.open) }
        let clear: Bool = {
            guard let first = ranked.first, first.score >= clearScore else { return false }
            guard ranked.count > 1 else { return true }
            return first.score - ranked[1].score >= clearLead
        }()
        return Ranking(ranked: ranked, clear: clear)
    }

    static func score(_ candidate: Candidate, hint: [String], prompts: Set<String>) -> Int {
        let nameWords = words(candidate.project)
        let titleWords = Set(words(candidate.title) + words(candidate.branch ?? ""))
        let aliases = Set(shortNames(candidate.project))
        let names = Set(nameWords).union(aliases)
        var score = 0
        for word in hint {
            if aliases.contains(word) { score += 40 }
            else if names.contains(word) { score += 30 }
            else if titleWords.contains(word) { score += 20 }
            else if word.count >= 3, (names.union(titleWords)).contains(where: { $0.hasPrefix(word) }) { score += 10 }
        }
        let recent = Set(candidate.recentPrompts.flatMap { words($0) })
        for word in prompts {
            if aliases.contains(word) || names.contains(word) { score += 12 }
            else if titleWords.contains(word) { score += 6 }
            if word.count >= 3, recent.contains(word) { score += 3 }
        }
        if score > 0, candidate.open { score += 2 }
        return score
    }

    /// A folder's short names: its words' initials when it has two or more ("coding-sessions" → "cs"), and its words
    /// run together ("codingsessions").
    public static func shortNames(_ name: String) -> [String] {
        let parts = words(name, splittingCase: true, keepShort: true)
        var names = [parts.joined()]
        if parts.count >= 2 { names.append(String(parts.compactMap(\.first))) }
        return names.filter { !$0.isEmpty }
    }

    /// Lowercased words of letters and digits, two characters or more (or any, with `keepShort`), split at camelCase
    /// humps too when asked.
    static func words(_ text: String, splittingCase: Bool = false, keepShort: Bool = false) -> [String] {
        var out: [String] = []
        var current = ""
        var previousLower = false
        func flush() {
            if current.count >= (keepShort ? 1 : 2) { out.append(current.lowercased()) }
            current = ""
        }
        for character in text {
            if character.isLetter || character.isNumber {
                if splittingCase, character.isUppercase, previousLower { flush() }
                current.append(character)
                previousLower = character.isLowercase
            } else {
                flush()
                previousLower = false
            }
        }
        flush()
        return out
    }

    /// Words about the mix-up, never about the target.
    static let hintNoise: Set<String> = [
        "hey", "wait", "find", "the", "tab", "tabs", "in", "to", "it", "my", "me", "this", "that", "there", "here", "please",
        "go", "send", "give", "meant", "for", "was", "mistakenly", "mistake", "wrong", "ignore", "working", "work", "on",
        "prompt", "prompts", "given", "gave", "session", "agent", "window", "one", "other", "another", "of", "is", "and",
        "next", "term", "nextterm",
    ]

    /// Words too common in prompts to tell sessions apart.
    static let promptNoise: Set<String> = [
        "the", "to", "and", "or", "it", "is", "in", "on", "of", "for", "with", "that", "this", "what", "now", "just",
        "all", "each", "should", "show", "add", "make", "do", "don", "dont", "not", "be", "can", "maybe", "best", "like",
        "something", "great", "sure", "how", "you", "we", "me", "my", "so", "if", "then", "but", "at", "as", "an",
    ]

    // MARK: what the target is given

    /// The text typed into the target: one line on where it came from and what was done there, then the prompts in the
    /// order the user typed them, each image as its quoted path after the prompts.
    public static func message(prompts: [String], from tab: String, note: String?, images: [String] = []) -> String {
        let fromTab = tab.trimmingCharacters(in: .whitespacesAndNewlines)
        var lead = "(Moved here from the \u{201C}" + (fromTab.isEmpty ? "other" : String(fromTab.prefix(80)))
            + "\u{201D} tab, where the user typed this by mistake."
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            lead += " There: " + String(note.prefix(600))
        }
        lead += ")"
        var parts = [lead]
        parts += prompts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !images.isEmpty { parts.append(images.map(quoted).joined(separator: " ")) }
        return parts.joined(separator: "\n\n")
    }

    /// A path in single quotes, as a terminal paste of a file gives it.
    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
