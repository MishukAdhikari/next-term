import Foundation

/// The words typed in a search box, matched the one way every list search here matches: the projects on the
/// Welcome window, and agent sessions there and in ⌥⌘O. Each word must be somewhere in the text, in any order,
/// with case and accents ignored ("resume" finds "Résumé").
public struct SearchWords: Sendable, Equatable {
    /// Folded, in the order typed.
    public let words: [String]

    public init(_ query: String) {
        words = query.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
    }

    public var isEmpty: Bool { words.isEmpty }

    /// What text is compared by: case and accents taken off.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// No words match everything.
    public func matches(_ text: String) -> Bool {
        guard !words.isEmpty else { return true }
        let folded = Self.fold(text)
        return words.allSatisfy { folded.contains($0) }
    }
}

extension AgentSession {
    /// A sessions search looks only at what the session's row shows (its title, agent, branch and model), all
    /// read with the list already: never the transcript, its folder or its id.
    public func matches(_ search: SearchWords) -> Bool {
        guard !search.isEmpty else { return true }
        let fields = [title, agent.name, gitBranch ?? "", model ?? ""]
        return search.matches(fields.joined(separator: " "))
    }
}

extension AgentSessions {
    /// The sessions matching `query` (`SearchWords`), in the order given.
    public static func matching(_ sessions: [AgentSession], _ query: String) -> [AgentSession] {
        let search = SearchWords(query)
        return search.isEmpty ? sessions : sessions.filter { $0.matches(search) }
    }
}
