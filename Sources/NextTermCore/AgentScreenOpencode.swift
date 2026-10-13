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

        /// A key as OpenCode prints the user's binds: a modifier and key ("ctrl+p"), a leader sequence as two
        /// ("ctrl+x p"), or a key with no modifier that these hints can have ("tab", "f1"). Such a key is a word in prose
        /// too ("set up these commands"), so it counts only at the row's start or after a gap of two spaces, as the
        /// footer sets its hints apart (gap={2}, prompt/index.tsx L1655-1685, 1.19).
        static let modifiers: String = #"(?:(?:ctrl|alt|shift|super|meta|hyper|cmd|option)\+)+"#
        static let modifiedKey: String = #"(?:^|\s)"# + modifiers + #"[^\s+]+(?:\s(?:"# + modifiers + #")?[^\s+]{1,12})?"#
        static let plainKey: String = #"(?:^|\s{2})(?:tab|f\d{1,2})"#

        /// The footer while it waits for a prompt (1.19, 2.0): "<key> agents" and "<key> commands" ending the row or
        /// followed by the sidebar's gap, the keys being the user's own (`agent.cycle` and `command.palette.show`,
        /// "tab" and "ctrl+p" by default); shell mode's "esc exit shell mode"; the empty prompt's "Ask anything…".
        static let footerKeys: String = "(?:" + modifiedKey + "|" + plainKey + #")\s+(?:commands|agents)(?=\s{2,}|\s*$)"#
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
        /// Between a command's last row and the buttons: the box's bottom padding and the buttons' top one. Less, and
        /// the command fills the box (15 rows at most) and runs on under the buttons (permission.tsx L640-660, 1.19).
        static let boxPadding = 2
        /// 2.0's body while "Always allow" is selected, in place of the request's own: what it would save
        /// (`permissionAlwaysLines`, "This will always allow shell for this project.", or the patterns after it).
        static let alwaysBody = "This will always allow "
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

        /// The question form's hint row (1.19), its hints in this order: "⇆ tab" when it asks several questions, or one
        /// with several answers; "↑↓ select" while it shows options; "enter submit" (or confirm, or toggle); "esc
        /// dismiss" (question.tsx L486-509).
        static let formDismiss = "esc dismiss"
        static let formEnter = "enter "
        static let formSelect = "↑↓ select"
        static let formTabs = "⇆ tab"
        /// Said after a question that takes several answers, and left out of its words.
        static let selectAll = " (select all that apply)"
        /// The last tab of a form with several questions: the answers to send.
        static let review = "Review"
        static let option = pattern(#"^(\d{1,2})\.\s+\S"#)
        /// How far up options and their descriptions reach: past this, a numbered line is the transcript's.
        static let optionGap = 8
        /// Where a row's text starts when the session column is empty on it: what follows is the sidebar.
        static let sidebarIndent = 20
        /// The sidebar shows only in a pane wider than 120 columns, beside a session column at least this wide.
        static let sidebarFrom = 78
        /// The longest question shown; a longer one is cut, ending in "…".
        static let longest = 200

        private static func pattern(_ text: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: text, options: [.caseInsensitive])
        }
    }
}

extension AgentScreen.Opencode {
    /// What OpenCode's screen says, in the bottom `scannedLines` of it: a question, its working hint, its footer alone
    /// (ready), or nothing of its own (idle, for every agent's shapes to read).
    static func activity(_ lines: [String]) -> AgentActivity {
        if let asked = permission(in: lines) ?? form(in: lines) { return .asking(shown(asked)) }
        let bottom = lines.suffix(AgentScreen.promptLines)
        if bottom.contains(where: { found(working, in: $0) }) { return .working }
        if bottom.contains(where: { found(ready, in: $0) }) { return .ready }
        return .idle
    }

    /// A question's words as Next Term passes them on (the decision notification, list_tabs, read_tab, wait_for_tab):
    /// secrets masked (`CommandSecrets.mask`: auth headers, tokens, URL passwords in a command or a WebFetch URL),
    /// before the cut, so no part of one is left; at most `longest` characters, a cut one ending in "…".
    static func shown(_ words: String) -> String {
        let masked = CommandSecrets.mask(words)
        guard masked.count > longest else { return masked }
        return String(masked.prefix(longest - 1)) + "…"
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
    /// required: " and its title, with the whole command after a shell command's ("Shell command ($ npm test)"), or
    /// the command alone where no title is drawn; with 2.0's "Always allow" selected and no title, the first line of
    /// what it would save, which `sameRequest` takes for the request read before. A step: its header and its first
    /// line. Without its header on screen (a prompt taller than the lines read), the header's words alone; nil for the
    /// reject step, which only its header tells from other dialogs.
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
        if title.isEmpty || title == shellTitle { shell = commandText(from: top + 1, above: row, in: lines) ?? "" }
        if title.isEmpty, shell.isEmpty, let saved = body.first(where: { $0.hasPrefix(alwaysBody) }) {
            return header + ": " + saved
        }
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

    // MARK: a shell request's command

    /// The command of a shell request, from its "$ " row (at `first` or below) down to the buttons at `buttons`: a long
    /// command wraps and one with line breaks takes a row for each, all in one text (permission.tsx, `"$ " + command`),
    /// so every row with text is joined, with spaces. Less than `boxPadding` blank rows above the buttons, and the
    /// command runs on under them: it ends in "…". Nil without a "$ " row.
    static func commandText(from first: Int, above buttons: Int, in lines: [String]) -> String? {
        let sidebar = sidebarColumn(in: lines)
        let rows: [String] = (first..<buttons).map { commandCell(lines[$0], sidebar: sidebar) }
        guard let start = rows.firstIndex(where: { $0.hasPrefix(command) }) else { return nil }
        let shown = rows[start...].filter { !$0.isEmpty }
        let last = rows.lastIndex(where: { !$0.isEmpty }) ?? start
        let text = shown.joined(separator: " ")
        return rows.count - 1 - last < boxPadding ? text + " …" : text
    }

    /// A row of a command: as `cell`, but cut only where the sidebar's text starts (`sidebar`, after a gap), never at
    /// spaces inside the command, which `cell` would take for that gap.
    static func commandCell(_ line: String, sidebar: Int?) -> String {
        var text = Substring(line)
        if let sidebar, line.count > sidebar {
            let session = line.prefix(sidebar)
            if session.hasSuffix("  ") { text = session }
        }
        var rest = text.drop { $0.isWhitespace || AgentScreen.boxSides.contains($0) }
        while let last = rest.last, last.isWhitespace || AgentScreen.boxSides.contains(last) { rest = rest.dropLast() }
        return String(rest)
    }

    /// The column the sidebar's text starts at, in characters: the commonest start of a row whose session column is
    /// empty (`sidebarStart`). Nil when no row shows the sidebar.
    static func sidebarColumn(in lines: [String]) -> Int? {
        var counts: [Int: Int] = [:]
        for line in lines {
            if let start = sidebarStart(line) { counts[start, default: 0] += 1 }
        }
        let commonest = counts.max { (a: (key: Int, value: Int), b: (key: Int, value: Int)) -> Bool in
            a.value == b.value ? a.key > b.key : a.value < b.value
        }
        return commonest?.key
    }

    /// Where a row's text starts when the session column is empty on it: after the border, `sidebarIndent` or more
    /// blanks, and at `sidebarFrom` or past it. Nil for any other row.
    static func sidebarStart(_ line: String) -> Int? {
        var column = 0
        var blanks = 0
        for character in line {
            if character.isWhitespace {
                blanks += 1
            } else if AgentScreen.boxSides.contains(character) {
                blanks = 0
            } else {
                return blanks >= sidebarIndent && column >= sidebarFrom ? column : nil
            }
            column += 1
        }
        return nil
    }
}

extension AgentScreen.Opencode {
    // MARK: the question form

    /// The question form whose hint row is in the last `promptLines` of `lines`, with option 1 above it: its question
    /// (lines joined, without " (select all that apply)"); or its last tab, which has no options: what it reviews.
    /// Hint words without either are the transcript's, not the form.
    static func form(in lines: [String]) -> String? {
        let start = max(0, lines.count - AgentScreen.promptLines)
        guard let hint = (start..<lines.count).last(where: { isFormHint(lines[$0]) }) else { return nil }
        guard cell(lines[hint]).contains(formSelect) else { return reviewed(above: hint, in: lines) }
        guard let first = firstOption(above: hint, in: lines) else { return nil }
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

    /// The form's hint row: it starts with one of its hints, as the form draws them, and holds "enter" and "esc dismiss".
    static func isFormHint(_ line: String) -> Bool {
        let text = cell(line)
        guard [formTabs, formSelect, formEnter].contains(where: { text.hasPrefix($0) }) else { return false }
        return text.contains(formDismiss) && text.contains(formEnter)
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

extension AgentScreen {
    /// Whether `read`, the question on screen now, is `shown`, the question the tab reports, read with less of it:
    /// TabStatus then keeps the words that name the request, and the question's number, so its id and its notification
    /// stay. Only OpenCode's permission prompt reads so (`Opencode.sameRequest`).
    static func sameQuestion(_ shown: String, _ read: String) -> Bool {
        Opencode.sameRequest(shown, read)
    }
}

extension AgentScreen.Opencode {
    /// The same permission request, read with less of it: its header alone (the rest above the lines read, as in a
    /// fullscreen prompt on a tall screen), or, for a shell request in 2.0, which draws no title, what "Always allow"
    /// would save, drawn in place of the command while that button is selected (permission.tsx, `body={(option) => …}`).
    /// Any other words are another request.
    static func sameRequest(_ shown: String, _ read: String) -> Bool {
        let request = permissionHeader + ": "
        guard shown.hasPrefix(request) else { return false }
        if read == permissionHeader { return true }
        return read.hasPrefix(request + alwaysBody) && shown.hasPrefix(request + command)
    }
}
