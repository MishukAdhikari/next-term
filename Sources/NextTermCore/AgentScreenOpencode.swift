import Foundation

extension AgentScreen {
    /// A tab's program titles itself as OpenCode does: "OpenCode" on its home screen and for a session with no title
    /// yet, "OC | <session title>" otherwise. OpenCode's screen shapes apply to such a tab whatever runs in front, as
    /// in a remote tab or one kept in tmux, which passes the title on.
    public static func isOpencode(title: String) -> Bool {
        let shown = title.trimmingCharacters(in: .whitespaces)
        return shown == "OpenCode" || shown.hasPrefix("OC | ")
    }

    /// OpenCode's own screen, read only in a tab that shows OpenCode (`activity(screenLines:opencode:)`). OpenCode (a
    /// TypeScript TUI on OpenTUI, in the alternate screen) draws no "esc to interrupt" and no "Do you want to…?": its
    /// footer says "esc interrupt" while it works and names its keys ("ctrl+p commands") while it waits, and it asks
    /// in a box with a "┃" border, "△ Permission required" over a row of buttons, or a question with numbered options
    /// over its "esc dismiss" hint. It hides its prompt and footer while it asks.
    ///
    /// Every string is data, with the OpenCode line it was read from: 1.19 (npm opencode-ai) or 2.0 (npm
    /// @opencode/cli). A new release of OpenCode is a change to these tables.
    enum Opencode {
        /// The footer's hint while it works (1.19): "esc interrupt", "esc again to interrupt" after one Esc, and the
        /// --mini footer's "esc stop". The "esc" is fixed text, not the user's key.
        static let working: [NSRegularExpression] = [
            #"(?:^|\s)esc\s+interrupt\b"#,
            #"(?:^|\s)esc\s+again\s+to\s+interrupt\b"#,
            #"(?:^|\s)esc\s+stop\b"#,
        ].map(pattern)

        /// A key as OpenCode prints the user's binds: a modifier and key ("ctrl+p"), or a named key ("tab", "f1").
        /// A leader sequence prints as two ("ctrl+x p"). Never a bare word, so prose ("the commands") is not one.
        static let key: String = #"(?:(?:ctrl|alt|shift|super|meta|hyper|cmd|option)\+)+[^\s+]+"#
            + #"|tab|esc|escape|enter|return|space|backspace|delete|del|insert|home|end|pgup|pgdn|up|down|left|right|f\d{1,2}"#
        static let nextKey: String = #"(?:\s(?:(?:ctrl|alt|shift|super|meta|hyper|cmd|option)\+)*[^\s+]{1,12})?"#

        /// The footer while it waits for a prompt (1.19, 2.0): "<key> agents" and "<key> commands" ending the row or
        /// followed by the sidebar's gap, the keys being the user's own (`agent.cycle` and `command.palette.show`,
        /// "tab" and "ctrl+p" by default); shell mode's "esc exit shell mode"; the empty prompt's "Ask anything…".
        static let footerKeys: String = {
            let named: String = #"(?:^|\s)(?:"# + key + ")" + nextKey
            return named + #"\s+(?:commands|agents)(?=\s{2,}|\s*$)"#
        }()
        static let ready: [NSRegularExpression] = [
            footerKeys,
            #"(?:^|\s)esc\s+exit\s+shell\s+mode\b"#,
            #"Ask anything…"#,
        ].map(pattern)

        /// The permission prompt's header (1.19, 2.0), with a title line under it in 1.19 ("# Shell command",
        /// "→ Edit src/app.ts"; 2.0 draws none for a shell command), and its body: "$ npm test" for a command.
        static let permissionHeader = "Permission required"
        static let shellTitle = "Shell command"
        static let command = "$ "
        /// The step after "Allow always" (1.19): confirm with Confirm or Cancel. 2.0 saves at once, with no step.
        static let alwaysHeader = "Always allow"
        /// The step after "Reject" on a sub-agent's request (1.19, 2.0): a text box for what to do instead.
        static let rejectHeader = "Reject permission"
        /// The warning sign before each header.
        static let headerSign = "△ "

        /// The rows of buttons, each in its order on screen.
        static let buttonRows: [[String]] = [
            ["Allow once", "Allow always", "Reject"], // 1.19
            ["Allow once", "Always allow", "Reject"], // 2.0
            ["Allow once", "Reject"], // 2.0, a request with nothing to save
            confirmButtons, // 1.19, "Always allow"'s step
        ]
        static let confirmButtons = ["Confirm", "Cancel"]
        static let buttonPatterns: [(labels: [String], row: NSRegularExpression)] = buttonRows.map {
            (labels: [String]) -> (labels: [String], row: NSRegularExpression) in
            let words: String = labels.map(NSRegularExpression.escapedPattern(for:)).joined(separator: #"\s+"#)
            return (labels, pattern("^" + words + #"(?=\s|$)"#))
        }
        /// Beside the buttons, or under them in a pane narrower than 80 columns.
        static let buttonHint = "enter confirm"
        /// Under "Reject permission"'s text box, which has no buttons.
        static let rejectHints = ["enter confirm", "esc cancel"]

        /// The question form's hint row (1.19): "esc dismiss" with "enter submit" (or confirm, or toggle); "↑↓ select"
        /// while it shows options; "⇆ tab" when it asks several questions, or one with several answers.
        static let formDismiss = "esc dismiss"
        static let formEnter = "enter "
        static let formSelect = "↑↓ select"
        static let formTabs = "⇆ tab"
        /// Said after a question that takes several answers, and left out of its words.
        static let selectAll = " (select all that apply)"
        /// The last tab of a form with several questions: the answers to send.
        static let review = "Review"
        /// A form whose words can't be read here.
        static let formUnread = "OpenCode asks a question"
        static let option = pattern(#"^(\d{1,2})\.\s+\S"#)
        /// How far up options and their descriptions reach: past this, a numbered line is the transcript's.
        static let optionGap = 8
        /// Where a row's text starts when the session column is empty on it: what follows is the sidebar.
        static let sidebarIndent = 20

        private static func pattern(_ text: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: text, options: [.caseInsensitive])
        }
    }
}

extension AgentScreen.Opencode {
    /// What OpenCode's screen says, in the bottom `scannedLines` of it: a question, its working hint, its footer alone
    /// (ready), or nothing of its own (idle, for every agent's shapes to read).
    static func activity(_ lines: [String]) -> AgentActivity {
        if let asked = permission(in: lines) ?? form(in: lines) { return .asking(String(asked.prefix(200))) }
        let bottom = lines.suffix(AgentScreen.promptLines)
        if bottom.contains(where: { found(working, in: $0) }) { return .working }
        if bottom.contains(where: { found(ready, in: $0) }) { return .ready }
        return .idle
    }

    // MARK: the permission prompt

    /// The permission prompt, or a step after it, whose buttons (or the reject step's hints) are in the last
    /// `promptLines` of `lines`: its words, read from its header down.
    static func permission(in lines: [String]) -> String? {
        let start = max(0, lines.count - AgentScreen.promptLines)
        for row in (start..<lines.count).reversed() {
            if let labels = buttons(at: row, in: lines) {
                return words(under: labels == confirmButtons ? alwaysHeader : permissionHeader, above: row, in: lines)
            }
            // Other dialogs show these hints too: only under its own header is it the reject step.
            if rejectHints.allSatisfy({ lines[row].contains($0) }), let asked = words(under: rejectHeader, above: row, in: lines) {
                return asked
            }
        }
        return nil
    }

    /// The labels of the row of buttons at `row`, its hint beside it or under it; nil for any other row.
    static func buttons(at row: Int, in lines: [String]) -> [String]? {
        let text = unboxed(lines[row])
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let set = buttonPatterns.first(where: { $0.row.firstMatch(in: text, range: range) != nil }) else { return nil }
        let hinted = lines[row..<min(row + 3, lines.count)].contains { $0.contains(buttonHint) }
        return hinted ? set.labels : nil
    }

    /// The words of the prompt under `header`, the nearest header above `row`. The permission prompt: "Permission
    /// required: " and its title, with the command after a shell command's ("Shell command ($ npm test)"), or the
    /// command alone where no title is drawn. A step: its header and its first line. Without its header on screen (a
    /// prompt taller than the lines read), the header's words alone; nil for the reject step, which only its header
    /// tells from other dialogs.
    static func words(under header: String, above row: Int, in lines: [String]) -> String? {
        guard let top = (0..<row).reversed().first(where: { headerText(cell(lines[$0])) == header }) else {
            return header == rejectHeader ? nil : header
        }
        let body: [String] = ((top + 1)..<row).map { cell(lines[$0]) }
        guard header == permissionHeader else {
            guard let first = body.first(where: { !$0.isEmpty }) else { return header }
            return header + ": " + first
        }
        let line = body.first ?? ""
        let title = line.hasPrefix(command) ? "" : withoutIcon(line)
        var shell = ""
        if title.isEmpty || title == shellTitle { shell = body.first { $0.hasPrefix(command) } ?? "" }
        switch (title.isEmpty, shell.isEmpty) {
        case (false, false): return "\(header): \(title) (\(shell))"
        case (false, true): return "\(header): \(title)"
        case (true, false): return "\(header): \(shell)"
        case (true, true): return header
        }
    }

    /// A header's words without the warning sign before them.
    static func headerText(_ text: String) -> String {
        text.hasPrefix(headerSign) ? String(text.dropFirst(headerSign.count)) : text
    }

    /// A title line without the icon OpenCode draws before it ("# Shell command", "→ Edit src/app.ts").
    static func withoutIcon(_ text: String) -> String {
        guard let first = text.first, !first.isLetter, !first.isNumber, text.dropFirst().first == " " else { return text }
        return String(text.dropFirst(2))
    }
}

extension AgentScreen.Opencode {
    // MARK: the question form

    /// The question form whose hint row is in the last `promptLines` of `lines`: its question (lines joined, without
    /// " (select all that apply)"), what its last tab reviews, or `formUnread`.
    static func form(in lines: [String]) -> String? {
        let start = max(0, lines.count - AgentScreen.promptLines)
        guard let hint = (start..<lines.count).last(where: { isFormHint(lines[$0]) }) else { return nil }
        guard lines[hint].contains(formSelect) else { return reviewed(above: hint, in: lines) ?? formUnread }
        guard let first = firstOption(above: hint, in: lines) else { return formUnread }
        var above = first - 1
        while above >= 0, cell(lines[above]).isEmpty { above -= 1 }
        var words: [String] = []
        while above >= 0 {
            let text = cell(lines[above])
            if text.isEmpty { break }
            words.insert(text, at: 0)
            above -= 1
        }
        var asked = words.joined(separator: " ")
        if asked.hasSuffix(selectAll) { asked.removeLast(selectAll.count) }
        return asked.isEmpty ? AgentScreen.formFallback : asked
    }

    static func isFormHint(_ line: String) -> Bool {
        line.contains(formDismiss) && line.contains(formEnter)
    }

    /// The row of option 1, the options counted down from the hint row (descriptions and a typed answer between them);
    /// nil when they don't count down to 1 within `optionGap` rows of each other.
    static func firstOption(above hint: Int, in lines: [String]) -> Int? {
        var expected: Int?
        var last = hint
        var row = hint - 1
        while row >= 0, last - row <= optionGap {
            if let number = optionNumber(cell(lines[row])) {
                guard expected == nil || number == expected else { return nil }
                if number == 1 { return row }
                expected = number - 1
                last = row
            }
            row -= 1
        }
        return nil
    }

    static func optionNumber(_ text: String) -> Int? {
        let ns = text as NSString
        guard let match = option.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Int(ns.substring(with: match.range(at: 1)))
    }

    /// The last tab of a form with several questions: "Review: " and each answer under it ("Database: SQLite").
    static func reviewed(above hint: Int, in lines: [String]) -> String? {
        guard lines[hint].contains(formTabs), let top = (0..<hint).last(where: { cell(lines[$0]) == review }) else { return nil }
        let answers = ((top + 1)..<hint).map { cell(lines[$0]) }.filter { !$0.isEmpty }
        return answers.isEmpty ? review : review + ": " + answers.joined(separator: "; ")
    }

    // MARK: rows

    /// A row without the "┃" border (or "│") and the spaces before its text.
    static func unboxed(_ line: String) -> String {
        String(line.drop { $0.isWhitespace || AgentScreen.boxSides.contains($0) })
    }

    /// A row of the session column: without its border and indent, and without what OpenCode draws beside the column
    /// in a pane wider than 120 columns (its sidebar, after a gap of three spaces or more). Empty when the column is
    /// empty on that row: the sidebar's text then starts `sidebarIndent` or more columns in.
    static func cell(_ line: String) -> String {
        var indent = 0
        var rest = Substring(line)
        while let first = rest.first, first.isWhitespace || AgentScreen.boxSides.contains(first) {
            indent = first.isWhitespace ? indent + 1 : 0
            rest = rest.dropFirst()
        }
        if indent >= sidebarIndent { return "" }
        if let gap = rest.range(of: "   ") { rest = rest[..<gap.lowerBound] }
        while let last = rest.last, last.isWhitespace || AgentScreen.boxSides.contains(last) { rest = rest.dropLast() }
        return String(rest)
    }

    static func found(_ patterns: [NSRegularExpression], in line: String) -> Bool {
        let range = NSRange(location: 0, length: (line as NSString).length)
        return patterns.contains { $0.firstMatch(in: line, range: range) != nil }
    }
}
