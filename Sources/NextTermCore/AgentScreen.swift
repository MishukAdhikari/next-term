import Foundation

/// What an AI agent is doing, read from its own screen.
public enum AgentActivity: Equatable, Sendable {
    /// The agent's UI says it is working ("esc to interrupt").
    case working
    /// It is asking for a decision (a permission prompt); the question, if found.
    case asking(String)
    /// None of the above: waiting for your next prompt.
    case idle
}

/// Reads the bottom of an agent's screen the way a person would: agent UIs (Ink, Ratatui) show an
/// "esc to interrupt" hint only while working, and a question with numbered choices when they need a
/// decision. This syncs the tab's status with the agent itself, instead of guessing from output, which
/// keeps flowing when an idle agent redraws a status line or clock.
///
/// The hints are data, checked against the installed agents' own strings (Claude Code 2.1, Codex 0.154,
/// Command Code 1.5x, Gemini CLI).
public enum AgentScreen {
    /// Only the last lines matter: agents draw their status and prompts at the bottom.
    public static let scannedLines = 24

    /// "✻ Pondering… (12s · ↓ 1.2k tokens · esc to interrupt)", "Working (5s • esc to interrupt)",
    /// Gemini's "(esc to cancel, 12s)".
    static let working: [NSRegularExpression] = [
        #"\besc\s+to\s+interrupt\b"#,
        #"\(esc to cancel,\s*\d+\s*s\)"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// A question a person has to answer.
    static let question = try! NSRegularExpression(
        pattern: #"^[\s│|>❯›*•·]*((?:Do you want to|Would you like to|Allow|Approve)\b[^?\n]{0,200}\?)"#,
        options: [.caseInsensitive, .anchorsMatchLines])

    /// Choices drawn under such a question.
    static let choices: [NSRegularExpression] = [
        #"Yes, and don['’]t ask again"#,
        #"^[\s│|>❯›]*(?:1\.|\[1\]|1\))\s*Yes\b"#,
        #"No, and tell \w+ what to do differently"#,
        #"Enter to select"#,
        #"\(y/n\)|\[y/N\]|\[Y/n\]"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive, .anchorsMatchLines]) }

    public static func activity(screenLines lines: [String]) -> AgentActivity {
        let bottom = lines.suffix(scannedLines)
        let text = bottom.joined(separator: "\n")
        let range = NSRange(location: 0, length: (text as NSString).length)
        // A question with its choices on screen wins: the agent is blocked on you.
        if let match = question.firstMatch(in: text, range: range),
           choices.contains(where: { $0.firstMatch(in: text, range: range) != nil }) {
            let asked = (text as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            return .asking(String(asked.prefix(200)))
        }
        if working.contains(where: { $0.firstMatch(in: text, range: range) != nil }) { return .working }
        return .idle
    }
}
