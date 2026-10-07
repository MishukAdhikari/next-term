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
    /// The lines a host passes: the bottom of the screen. Hints and prompts count only in the last
    /// `promptLines` of them; Claude Code's question form is taller, and its question may sit higher.
    public static let scannedLines = 40
    /// Agents draw their status and prompts at the bottom: one further up is history.
    static let promptLines = 24

    /// "✻ Pondering… (12s · ↓ 1.2k tokens · esc to interrupt)", "Working (5s • esc to interrupt)",
    /// Gemini's "(esc to cancel, 12s)".
    static let working: [NSRegularExpression] = [
        #"\besc\s+to\s+interrupt\b"#,
        #"\(esc to cancel,\s*\d+\s*s\)"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// A question a person has to answer. "Ready to submit your answers?" ends Claude Code's form when
    /// it asks more than one question.
    static let question = try! NSRegularExpression(
        pattern: #"^[\s│|>❯›*•·]*((?:Do you want to|Would you like to|Allow|Approve|Ready to submit your answers)\b[^?\n]{0,200}\?)"#,
        options: [.caseInsensitive, .anchorsMatchLines])

    /// Choices drawn under such a question.
    static let choices: [NSRegularExpression] = [
        #"Yes, and don['’]t ask again"#,
        #"^[\s│|>❯›]*(?:1\.|\[1\]|1\))\s*Yes\b"#,
        #"No, and tell \w+ what to do differently"#,
        #"Enter to select"#,
        #"\(y/n\)|\[y/N\]|\[Y/n\]"#,
        #"^[\s│|>❯›]*1\.\s*Submit answers$"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive, .anchorsMatchLines]) }

    /// Claude Code's question form (its AskUserQuestion tool): the question and the options are the
    /// model's own words, so the form is known by its own rows under the options instead: "Chat about
    /// this", or the "Type something." row for an answer of your own, and the "Enter to select" hint.
    static let formRow = try! NSRegularExpression(pattern: #"^(?:\d{1,2}\.\s+)?(?:Chat about this|(?:\[.\]\s+)?Type something\.?)$"#)
    static let formHint = "Enter to select"
    /// An option of the form, at the left edge (a preview box beside the list can hold numbered lines too).
    static let formOption = try! NSRegularExpression(pattern: #"^\s{0,3}(?:[❯›>]\s+)?(\d{1,2})\.\s+(\S.*)$"#)
    /// What the form says when its question has scrolled out of reach.
    static let formFallback = "Choose one of the options"

    public static func activity(screenLines lines: [String]) -> AgentActivity {
        let bottom = Array(lines.suffix(scannedLines))
        // A question with its choices on screen wins: the agent is blocked on you.
        if let asked = form(in: bottom)?.question ?? prompt(in: bottom)?.question { return .asking(asked) }
        let text = bottom.suffix(promptLines).joined(separator: "\n")
        let range = NSRange(location: 0, length: (text as NSString).length)
        if working.contains(where: { $0.firstMatch(in: text, range: range) != nil }) { return .working }
        return .idle
    }

    /// A question with fixed words ("Do you want to…?") and its choices, in the last `promptLines`
    /// of `lines`: the question and the row it is on.
    static func prompt(in lines: [String]) -> (row: Int, question: String)? {
        let start = max(0, lines.count - promptLines)
        let text = lines[start...].joined(separator: "\n")
        guard choices.contains(where: { matches($0, text) }) else { return nil }
        for row in start..<lines.count {
            let line = lines[row]
            let ns = line as NSString
            guard let match = question.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let asked = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            return (row, String(asked.prefix(200)))
        }
        return nil
    }

    /// Claude Code's question form, its own rows in the last `promptLines` of `lines`: the question
    /// above its options (a long one wraps, drawn with a "│" gutter) and the row of option 1. The row
    /// is nil when the options reach above `lines`.
    static func form(in lines: [String]) -> (row: Int?, question: String)? {
        let start = max(0, lines.count - promptLines)
        guard lines[start...].contains(where: { $0.contains(formHint) }),
              let mark = lines[start...].lastIndex(where: { matches(formRow, splitCursor(inner($0)).rest) }) else { return nil }
        // Up from the form's own rows, the options count down to 1.
        var expected: Int?
        var first: Int?
        var row = mark - 1
        while row >= 0, first == nil {
            if let (number, _) = formOptionLabel(lines[row]) {
                guard expected == nil || number == expected else { return (nil, formFallback) }
                if number == 1 { first = row }
                expected = number - 1
            }
            row -= 1
        }
        guard let first else { return (nil, formFallback) }
        var above = first - 1
        while above >= 0, inner(lines[above]).isEmpty { above -= 1 }
        var words: [String] = []
        while above >= 0, !isEdge(inner(lines[above])) {
            words.insert(inner(lines[above]), at: 0)
            above -= 1
        }
        let asked = words.joined(separator: " ")
        return (first, asked.isEmpty ? formFallback : String(asked.prefix(200)))
    }

    /// The number and label of a form's option row, without a preview drawn beside it.
    static func formOptionLabel(_ line: String) -> (Int, String)? {
        let ns = line as NSString
        guard let match = formOption.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              let number = Int(ns.substring(with: match.range(at: 1))) else { return nil }
        var label = ns.substring(with: match.range(at: 2))
        if let gap = label.range(of: "   ") { label = String(label[..<gap.lowerBound]) }
        return (number, label.trimmingCharacters(in: .whitespaces))
    }
}

/// The choices drawn under an agent's question, read from its screen, and the keys that pick one.
public struct AgentMenu: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        /// A list: the arrow keys move its cursor and Return picks (Claude Code, Codex, Gemini CLI, Command Code).
        case list
        /// A "(y/n)" prompt: a letter, then Return.
        case yesNo
    }

    /// The question the choices answer, as `AgentScreen.activity` reads it.
    public let question: String
    public let style: Style
    public let choices: [String]
    /// The choice the list's cursor is on (0-based), nil when the screen draws none.
    public let highlighted: Int?

    public init(question: String, style: Style, choices: [String], highlighted: Int?) {
        self.question = question
        self.style = style
        self.choices = choices
        self.highlighted = highlighted
    }

    /// The 0-based choice an answer names: `choice` as numbered on screen (1-based), or `answer`, a
    /// choice's words ("Yes", or y/n for a y/n prompt). The error is a sentence for the caller.
    public func index(choice: Int?, answer: String?) -> Result<Int, AgentMenuError> {
        let listed = choices.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "; ")
        if let choice {
            guard (1...choices.count).contains(choice) else {
                return .failure(.init("choice is 1 to \(choices.count) here: \(listed)."))
            }
            return .success(choice - 1)
        }
        guard let raw = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .failure(.init("Give choice (its number) or answer (its words). The choices: \(listed)."))
        }
        if let number = Int(raw) { return index(choice: number, answer: nil) }
        let wanted = Self.normalized(raw)
        if style == .yesNo {
            if ["y", "yes"].contains(wanted) { return .success(0) }
            if ["n", "no"].contains(wanted) { return .success(1) }
        }
        let labels = choices.map(Self.normalized)
        if let exact = labels.firstIndex(of: wanted) { return .success(exact) }
        let starting = labels.indices.filter { labels[$0].hasPrefix(wanted) }
        if starting.count == 1 { return .success(starting[0]) }
        return .failure(.init("“\(raw)” is \(starting.isEmpty ? "not one of the choices" : "the start of more than one choice"); give its number. The choices: \(listed)."))
    }

    /// The keys that pick choice `index` (key names as press_keys takes them): the arrows from the
    /// cursor to it, then Return; for a y/n prompt, the letter and Return. Arrows, not the choice's
    /// digit: some agents pick on the digit alone, and the Return after it would answer whatever comes
    /// next. Nil when the list's cursor is not drawn, so where the arrows would start is unknown.
    public func keys(toPick index: Int) -> [String]? {
        guard choices.indices.contains(index) else { return nil }
        switch style {
        case .yesNo:
            return [index == 0 ? "y" : "n", "enter"]
        case .list:
            guard let highlighted else { return nil }
            return Array(repeating: index > highlighted ? "down" : "up", count: abs(index - highlighted)) + ["enter"]
        }
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespaces)
    }
}

public struct AgentMenuError: Error, Equatable, Sendable {
    public let text: String
    public init(_ text: String) { self.text = text }
}

extension AgentScreen {
    /// The id of the question a tab's agent is asking (MCP's answer_agent takes it back): it changes
    /// whenever the tab asks a new question, even in the same words (`serial` is
    /// TabStatus.questionSerial), so an answer meant for one question never lands on the next. Not a
    /// secret, only a guard against stale answers.
    public static func questionID(tab: String, serial: Int, question: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a
        for byte in "\(tab.lowercased())\n\(serial)\n\(question)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return "q_" + String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// The cursor agents draw beside the chosen line of a list.
    static let cursors: Set<Character> = ["❯", "›", ">", "▶", "▸", "●", "→", "➜"]
    /// An unchosen radio button (some lists draw one on every other line).
    static let unchosen: Set<Character> = ["○", "◯"]
    static let numberedChoice = try! NSRegularExpression(pattern: #"^(?:(\d{1,2})[.)]|\[(\d{1,2})\])\s+(\S.*)$"#)
    static let yesNo = try! NSRegularExpression(pattern: #"\(y/n\)|\[y/N\]|\[Y/n\]"#, options: [.caseInsensitive])
    /// A key hint after a choice: "(esc)", "(shift+tab)", Codex's "(y)".
    static let keyHint = try! NSRegularExpression(pattern: #"\s*\((?:esc|tab|shift\+tab|ctrl\+\w|\w)\)$"#, options: [.caseInsensitive])

    /// The menu under the question an agent is asking (the one `activity` reports), or nil if the
    /// screen shows none.
    public static func menu(screenLines lines: [String]) -> AgentMenu? {
        let bottom = Array(lines.suffix(scannedLines))
        if let asked = form(in: bottom) {
            guard let first = asked.row else { return nil }
            return formMenu(bottom, first: first, question: asked.question)
        }
        guard let (row, asked) = prompt(in: bottom) else { return nil }
        if matches(yesNo, bottom[row]) || (row + 1 < bottom.count && matches(yesNo, bottom[row + 1])) {
            return AgentMenu(question: asked, style: .yesNo, choices: ["Yes", "No"], highlighted: nil)
        }
        var choices: [String] = []
        var highlighted: Int?
        var numbered = false
        var started = false
        for index in (row + 1)..<bottom.count {
            let line = inner(bottom[index])
            if isEdge(line) {
                if started { break }
                continue
            }
            let (cursor, rest) = splitCursor(line)
            if let (number, label) = numberedLabel(rest) {
                guard !started || numbered, number == choices.count + 1 else {
                    if started { break }
                    continue
                }
                numbered = true
                started = true
                if cursor { highlighted = choices.count }
                choices.append(label)
                continue
            }
            if numbered { continue } // a long choice wrapped onto the next line
            guard cursor || started else { continue }
            if !started {
                // An unnumbered list whose cursor is not on its first line: the lines just above are choices too.
                started = true
                var above = index - 1
                while above > row {
                    let previous = inner(bottom[above])
                    if isEdge(previous) { break }
                    choices.insert(clean(splitCursor(previous).rest), at: 0)
                    above -= 1
                }
            }
            if cursor { highlighted = choices.count }
            choices.append(clean(rest))
        }
        guard choices.count >= 2 else { return nil }
        return AgentMenu(question: asked, style: .list, choices: choices, highlighted: highlighted)
    }

    /// The form's options, from option 1 down to its own rows. The row for an answer of your own
    /// ("Type something.", or what was typed there) and "Chat about this" are not choices, but the
    /// cursor can sit on them. Nil for a question that takes several answers (its options have
    /// checkboxes): one choice and Return does not answer it.
    private static func formMenu(_ lines: [String], first: Int, question: String) -> AgentMenu? {
        var choices: [String] = []
        var highlighted: Int?
        var chatNumbered: Bool?
        for line in lines[first...] {
            let (cursor, rest) = splitCursor(inner(line))
            if rest.hasSuffix("Chat about this"), matches(formRow, rest) {
                let number = numberedLabel(rest)?.0
                if cursor { highlighted = number.map { $0 - 1 } ?? choices.count }
                chatNumbered = number != nil
                break
            }
            guard let (number, label) = formOptionLabel(line), number == choices.count + 1 else { continue }
            if cursor { highlighted = choices.count }
            choices.append(label)
        }
        // Beside a preview there is no row of your own; otherwise it is the last numbered one.
        if chatNumbered != false, !choices.isEmpty { choices.removeLast() }
        guard choices.count >= 2, !choices.contains(where: { $0.hasPrefix("[") && $0.dropFirst(2).hasPrefix("]") }) else { return nil }
        return AgentMenu(question: question, style: .list, choices: choices, highlighted: highlighted)
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// A line without the box an agent may draw around its prompt.
    private static func inner(_ line: String) -> String {
        var text = Substring(line)
        while let first = text.first, first == "│" || first == "|" || first.isWhitespace { text = text.dropFirst() }
        while let last = text.last, last == "│" || last == "|" || last.isWhitespace { text = text.dropLast() }
        return String(text)
    }

    /// A blank line, a box's edge, or the hint line under a list: where the choices end.
    private static func isEdge(_ line: String) -> Bool {
        if line.isEmpty { return true }
        if let first = line.first, "╭╰┌└─━═".contains(first) { return true }
        let lower = line.lowercased()
        return ["enter to select", "esc to cancel", "to navigate", "↑↓", "↑/↓"].contains { lower.contains($0) }
    }

    private static func splitCursor(_ line: String) -> (cursor: Bool, rest: String) {
        guard let first = line.first else { return (false, line) }
        let rest = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        if cursors.contains(first), line.dropFirst().first?.isWhitespace ?? false { return (true, rest) }
        if unchosen.contains(first) { return (false, rest) }
        return (false, line)
    }

    private static func numberedLabel(_ text: String) -> (Int, String)? {
        let ns = text as NSString
        guard let match = numberedChoice.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let digits = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
        guard let number = Int(ns.substring(with: digits)) else { return nil }
        return (number, clean(ns.substring(with: match.range(at: 3))))
    }

    private static func clean(_ label: String) -> String {
        let range = NSRange(location: 0, length: (label as NSString).length)
        return keyHint.stringByReplacingMatches(in: label, range: range, withTemplate: "").trimmingCharacters(in: .whitespaces)
    }
}
