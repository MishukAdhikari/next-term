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
        /// The hints while the prompt is fullscreen (1.19, 2.0): its key's, "minimize", before the others.
        static let shrinkHint = pattern(#"\sminimize\s+⇆\s+select\s+enter\s+confirm"#)
        /// 2.0's rows, where Esc on a fullscreen prompt only shrinks it (SessionQuestion's `dismiss`); 1.19's rejects.
        static let shrinkingRows: [[String]] = [buttonRows[1], buttonRows[2]]
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
    /// What OpenCode's screen says, in the rows the host passes (its whole screen): a question, its working hint, its
    /// footer alone (ready), or nothing of its own (idle, for every agent's shapes to read).
    static func activity(_ lines: [String], mask: SecretMask = .current) -> AgentActivity {
        if let asked = permission(in: lines, mask: mask) ?? form(in: lines, mask: mask) { return .asking(shown(asked, mask: mask)) }
        let bottom = lines.suffix(AgentScreen.promptLines)
        if bottom.contains(where: { found(working, in: $0) }) { return .working }
        if bottom.contains(where: { found(ready, in: $0) }) { return .ready }
        return .idle
    }

    /// A question's words as Next Term passes them on (the decision notification, list_tabs, read_tab, wait_for_tab):
    /// secrets masked (`CommandSecrets.mask`: auth headers, tokens, URL passwords in a command or a WebFetch URL),
    /// before the cut, so no part of one is left; at most `longest` characters, a cut one ending in "…". Stored keys
    /// were masked over the rows `words` was read from before they were joined (`mask`), so a key OpenCode's box wraps
    /// mid-token shows in neither row.
    static func shown(_ words: String, mask: SecretMask = .current) -> String {
        let masked = CommandSecrets.mask(words, mask: mask)
        guard masked.count > longest else { return masked }
        return String(masked.prefix(longest - 1)) + "…"
    }

    // MARK: the permission prompt

    /// The permission prompt, or a step after it, whose buttons (or the reject step's hints) are in the last
    /// `promptLines` of `lines`: its words, read from its header down.
    static func permission(in lines: [String], mask: SecretMask = .current) -> String? {
        permissionPrompt(in: lines, mask: mask)?.words
    }

    /// `permission(in:)`, with the row of its buttons and their labels; no labels for the reject step, which has none.
    static func permissionPrompt(in lines: [String], mask: SecretMask = .current) -> (row: Int, labels: [String]?, words: String)? {
        let start = max(0, lines.count - AgentScreen.promptLines)
        for row in (start..<lines.count).reversed() {
            if let labels = buttons(at: row, in: lines) {
                let header = labels == confirmButtons ? alwaysHeader : permissionHeader
                guard let asked = words(under: header, above: row, in: lines, mask: mask) else { return nil }
                return (row, labels, asked)
            }
            // Other dialogs show these hints too: only under its own header is it the reject step.
            if rejectHints.allSatisfy({ lines[row].contains($0) }),
               let asked = words(under: rejectHeader, above: row, in: lines, mask: mask) {
                return (row, nil, asked)
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
    /// what it would save (`alwaysShown`). A step: its header and its first line. Without its header in the rows read,
    /// the header's words alone, a question of its own; nil for the reject step, which only its header tells from other
    /// dialogs. The body's rows are masked together first (`SecretMask.mask(rows:)`), so a stored key the box wraps
    /// shows in neither.
    static func words(under header: String, above row: Int, in lines: [String], mask: SecretMask = .current) -> String? {
        guard let top = (0..<row).reversed().first(where: { headerText(cell(lines[$0])) == header }) else {
            return header == rejectHeader ? nil : header
        }
        let cells: [String] = ((top + 1)..<row).map { (index: Int) -> String in cell(lines[index]) }
        let body: [String] = mask.mask(rows: cells)
        guard header == permissionHeader else {
            guard let first = body.first(where: { !$0.isEmpty }) else { return header }
            return header + ": " + first
        }
        let line = body.first ?? ""
        let title = line.hasPrefix(command) ? "" : withoutIcon(line)
        var shell = ""
        if title.isEmpty || title == shellTitle { shell = commandText(from: top + 1, above: row, in: lines, mask: mask) ?? "" }
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
    /// so every row with text is joined, with spaces, stored keys masked over the rows first (`AgentScreen.maskedQuestion`):
    /// a key the box wraps mid-token is one "•••". Less than `boxPadding` blank rows above the buttons, and the command
    /// runs on under them: it ends in "…". Nil without a "$ " row.
    static func commandText(from first: Int, above buttons: Int, in lines: [String], mask: SecretMask = .current) -> String? {
        let sidebar = sidebarColumn(in: lines)
        let rows: [String] = (first..<buttons).map { commandCell(lines[$0], sidebar: sidebar) }
        guard let start = rows.firstIndex(where: { $0.hasPrefix(command) }) else { return nil }
        let shown = rows[start...].filter { !$0.isEmpty }
        let last = rows.lastIndex(where: { !$0.isEmpty }) ?? start
        let text = AgentScreen.maskedQuestion(Array(shown), mask: mask)
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
    /// (lines joined, stored keys masked over them first as `AgentScreen.maskedQuestion` does, without " (select all that
    /// apply)"); or its last tab, which has no options: what it reviews. Hint words without either are the transcript's,
    /// not the form.
    static func form(in lines: [String], mask: SecretMask = .current) -> String? {
        let start = max(0, lines.count - AgentScreen.promptLines)
        guard let hint = (start..<lines.count).last(where: { isFormHint(lines[$0]) }) else { return nil }
        guard cell(lines[hint]).contains(formSelect) else { return reviewed(above: hint, in: lines, mask: mask) }
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
        var asked = AgentScreen.maskedQuestion(words, mask: mask)
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

    /// The last tab of a form with several questions: "Review: " and each answer under it ("Database: SQLite"), stored
    /// keys masked over the answers' rows first.
    static func reviewed(above hint: Int, in lines: [String], mask: SecretMask = .current) -> String? {
        guard lines[hint].contains(formTabs), let top = (0..<hint).last(where: { cell(lines[$0]) == review }) else { return nil }
        let cells: [String] = ((top + 1)..<hint).map { (index: Int) -> String in cell(lines[index]) }
        let answers: [String] = mask.mask(rows: cells).filter { (text: String) -> Bool in !text.isEmpty }
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
    /// Whether `read`, the question on screen now, is what `shown`, the question read before, became when its own
    /// selection moved: a new question all the same (its words no longer name the request, and OpenCode can swap
    /// requests under them), with no second notification, and the move answer_agent's arrows make on the way to that
    /// button. Only OpenCode's permission prompt reads so (`Opencode.alwaysShown`).
    public static func selectionMoved(from shown: String, to read: String) -> Bool {
        Opencode.alwaysShown(after: shown, read: read)
    }
}

extension AgentScreen.Opencode {
    /// A shell request in 2.0, which draws no title, read with its command (`shown`), then with what "Always allow"
    /// would save drawn in place of it once that button is selected (`read`; permission.tsx, `body={(option) => …}`).
    /// Only that way round: back from it, the command shown may be another request's, as OpenCode keeps the selection
    /// when one request follows another.
    static func alwaysShown(after shown: String, read: String) -> Bool {
        let request = permissionHeader + ": "
        return shown.hasPrefix(request + command) && read.hasPrefix(request + alwaysBody)
    }
}

extension AgentScreen {
    /// The menu under the question a tab's agent asks, read from its rows, colours and all. In a tab that shows OpenCode
    /// (`opencode`), OpenCode's own buttons and options, the selected button told by its background; an OpenCode tab that
    /// shows none of OpenCode's shapes, and every other tab, reads its rows' text as `menu(screenLines:)` does.
    public static func menu(screenRows rows: [ScreenRow], opencode: Bool, mask: SecretMask = .current) -> AgentMenu? {
        let lines: [String] = rows.map { (row: ScreenRow) -> String in row.text }
        guard opencode else { return menu(screenLines: lines, mask: mask) }
        guard Opencode.activity(lines, mask: mask) != .idle else { return menu(screenLines: lines, mask: mask) }
        return Opencode.menu(rows, mask: mask)
    }

    /// The menu under `question` in a tab that shows OpenCode, for an agent to read, as `menu(asking:screenLines:shown:)`
    /// gives every other tab's: read from `rows`, colours and all (`menu(screenRows:opencode:)`), its question matched on
    /// them, with its options' words from `shown`, the same rows' text with stored keys masked over whole lines
    /// (`SecretMask.mask(window:rows:text:)`), so a key that starts above the rows read shows none of it either. A
    /// permission prompt's buttons are OpenCode's own words. A screen that shows none of OpenCode's shapes is read as
    /// every other tab's. Nil when either reads no menu, its question is another, or the two count different options.
    public static func menu(asking question: String, screenRows rows: [ScreenRow], shown: [String],
                            mask: SecretMask = .current) -> AgentMenu? {
        let lines: [String] = rows.map { (row: ScreenRow) -> String in row.text }
        let masked: [String] = Array(shown.suffix(lines.count))
        guard Opencode.activity(lines, mask: mask) != .idle else {
            return menu(asking: question, screenLines: lines, shown: masked, mask: mask)
        }
        guard let read = Opencode.menu(rows, mask: mask), read.asks(question) else { return nil }
        guard read.style == .digits else { return read }
        guard let form = Opencode.singleForm(in: masked, mask: mask), form.options.count == read.choices.count else { return nil }
        let choices: [String] = form.options.map { (label: String) -> String in CommandSecrets.mask(label, mask: mask) }
        return AgentMenu(question: question, style: read.style, choices: choices, highlighted: read.highlighted,
                         escape: read.escape, shrinksFirst: read.shrinksFirst, blocked: read.blocked)
    }

    /// Why the question in a tab that shows OpenCode has no menu to pick from, said for the caller: a form with several
    /// questions or answers, its review, or the reject step's text box. Nil for every other screen and tab.
    public static func menuRefusal(screenRows rows: [ScreenRow], opencode: Bool) -> String? {
        guard opencode else { return nil }
        let lines: [String] = rows.map { (row: ScreenRow) -> String in row.text }
        return Opencode.refusal(lines)
    }
}

extension AgentScreen.Opencode {
    // MARK: answering

    /// The choices Esc picks by itself, wherever the selection is (`escapeKey`, permission.tsx, 1.19 and 2.0).
    static let escapeChoices = ["Reject", "Cancel"]
    /// The form's row for an answer of your own: its digit opens a text box, so it is not a choice to pick.
    static let ownAnswer = "Type your own answer"
    static let severalQuestions = "This form asks several questions; press_keys can answer it: a digit picks, Right goes to the next question."
    static let severalAnswers = "This question takes several answers; press_keys can answer it: a digit picks or drops one, Right goes on to Confirm, and Return sends."
    static let reviewRefusal = "This form shows its answers to review; press_keys can answer it: Return sends them, Left goes back to a question."
    static let rejectStepRefusal = "This step asks what OpenCode should do instead, with no choices; nothing was typed. send_to_tab types a message and sends it; press_keys [\"enter\"] sends none, and [\"escape\"] goes back."
    static let ownAnswerOpen = "A box for an answer of your own is open under “Type your own answer” (or shows one typed before), and a digit could go into it; nothing was typed. read_tab shows the form, and press_keys can answer."
    static let ownAnswerSelected = "The selection is on “Type your own answer”, where OpenCode can take a digit into the answer; nothing was typed. press_keys can answer: Up to an option, then its digit or Return."
    static let optionNotShown = "That screen does not show which option is selected, and on “Type your own answer” OpenCode can take a digit into the answer; nothing was typed. press_keys can answer."

    /// The menu under OpenCode's question in the rows the host passes, as `activity` reads the question:
    /// - a permission prompt or its confirm step: its buttons, a row, the selected one told by its background
    ///   (`ScreenRow.selected`), Esc for Reject or Cancel (twice on 2.0's fullscreen prompt, which the first only shrinks);
    /// - a form with one question and one answer: its options, masked as the question is, each picked and sent by its
    ///   digit unless the digit could go into an answer of your own (`digitsRefusal`).
    ///
    /// Nil for the reject step and for a form with several questions or answers (`refusal` says why).
    static func menu(_ rows: [ScreenRow], mask: SecretMask = .current) -> AgentMenu? {
        let lines: [String] = rows.map { (row: ScreenRow) -> String in row.text }
        if let prompt = permissionPrompt(in: lines, mask: mask) {
            guard let labels = prompt.labels else { return nil }
            let selected: Int? = rows[prompt.row].selected(among: labels)
            let escape: Int? = labels.firstIndex { (label: String) -> Bool in escapeChoices.contains(label) }
            let shrinks: Bool = shrinkingRows.contains(labels) && fullscreen(at: prompt.row, in: lines)
            return AgentMenu(question: shown(prompt.words, mask: mask), style: .row, choices: labels, highlighted: selected,
                             escape: escape, shrinksFirst: shrinks)
        }
        guard let asked = form(in: lines, mask: mask), let single = singleForm(in: lines, mask: mask) else { return nil }
        let choices: [String] = single.options.map { (label: String) -> String in CommandSecrets.mask(label, mask: mask) }
        let held: String? = digitsRefusal(rows, single)
        return AgentMenu(question: shown(asked, mask: mask), style: .digits, choices: choices, highlighted: nil, blocked: held)
    }

    /// Whether the prompt whose buttons are at `row` shows fullscreen: its hints, beside the buttons or under them, say
    /// "minimize".
    static func fullscreen(at row: Int, in lines: [String]) -> Bool {
        let hints: ArraySlice<String> = lines[row..<min(row + 3, lines.count)]
        return hints.contains { (line: String) -> Bool in found([shrinkHint], in: line) }
    }

    /// A form that asks one question with one answer, from option 1 down to its hint row (`hint`): its options without
    /// the row for an answer of your own, the row of each, and that row's (`own`), when it has one. Nil for a form that
    /// shows "⇆ tab" (several questions, or one with several answers, as question.tsx draws it), or options with
    /// checkboxes. The labels are cut from the rows with stored keys masked over them first (`SecretMask.mask(rows:)`),
    /// so a key an option's row wraps onto the next shows no half.
    static func singleForm(in lines: [String], mask: SecretMask = .current) -> SingleForm? {
        let start = max(0, lines.count - AgentScreen.promptLines)
        guard let hint = (start..<lines.count).last(where: { isFormHint(lines[$0]) }), !lines[hint].contains(formTabs),
              cell(lines[hint]).contains(formSelect), let first = firstOption(above: hint, in: lines) else { return nil }
        let cells: [String] = (first..<hint).map { (row: Int) -> String in cell(lines[row]) }
        let masked: [String] = mask.mask(rows: cells)
        var options: [String] = []
        var rows: [Int] = []
        for row in first..<hint {
            guard let number = optionNumber(cells[row - first]), number == options.count + 1 else { continue }
            options.append(optionLabel(masked[row - first]))
            rows.append(row)
        }
        var own: Int?
        if options.last == ownAnswer {
            options.removeLast()
            own = rows.removeLast()
        }
        let boxed = options.contains { (label: String) -> Bool in isCheckbox(label) }
        return options.isEmpty || boxed ? nil : SingleForm(options: options, rows: rows, own: own, hint: hint)
    }

    struct SingleForm {
        let options: [String]
        let rows: [Int]
        let own: Int?
        let hint: Int
    }

    /// Why a digit might not pick an option of `form` now; nil when it does. OpenCode 1.19 turns its digit keys off while
    /// its box for an answer of your own is open under that row (question.tsx, `enabled: !store.editing`), and 2.0 takes
    /// a key into that answer while its row is selected (form.tsx, its key intercept). So, with that row on screen, a
    /// digit needs no row drawn under it (the box, its placeholder, or an answer typed before) and another option shown
    /// selected (`selectedRow`: 1.19 draws it on a background of its own, 2.0 marks it by its text's colour alone).
    static func digitsRefusal(_ rows: [ScreenRow], _ form: SingleForm) -> String? {
        guard let own = form.own else { return nil }
        let below: Range<Int> = (own + 1)..<form.hint
        if below.contains(where: { (row: Int) -> Bool in !cell(rows[row].text).isEmpty }) { return ownAnswerOpen }
        let options: [Int] = form.rows + [own]
        guard let selected = selectedRow(rows, among: options) else { return optionNotShown }
        return selected == own ? ownAnswerSelected : nil
    }

    /// Which of `options` (rows of the form's options) shows selected: the one whose number is on a background of its
    /// own, off the box's just before it. Nil unless exactly one is.
    static func selectedRow(_ rows: [ScreenRow], among options: [Int]) -> Int? {
        let marked: [Int] = options.filter { (row: Int) -> Bool in
            let line: ScreenRow = rows[row]
            guard let digit = line.text.firstIndex(where: { (character: Character) -> Bool in character.isNumber }) else { return false }
            let offset: Int = line.text.distance(from: line.text.startIndex, to: digit)
            return offset > 0 && line.background(at: offset) != line.background(at: offset - 1)
        }
        return marked.count == 1 ? marked[0] : nil
    }

    /// An option's label: after its number, without the " ✓" a picked one shows.
    static func optionLabel(_ text: String) -> String {
        var label = text.drop { $0 != "." }.dropFirst().drop { $0.isWhitespace }
        if label.hasSuffix(" ✓") { label = label.dropLast(2) }
        return label.trimmingCharacters(in: .whitespaces)
    }

    /// "[ ] Lint", "[✓] Unit tests": an option of a question that takes several answers.
    static func isCheckbox(_ label: String) -> Bool {
        label.hasPrefix("[") && label.dropFirst(2).hasPrefix("] ")
    }

    /// Why OpenCode's question on screen has no menu: the reject step, a form's review, or a form with several answers or
    /// questions. Nil when it has one, or asks nothing.
    static func refusal(_ lines: [String]) -> String? {
        if let prompt = permissionPrompt(in: lines) { return prompt.labels == nil ? rejectStepRefusal : nil }
        let start = max(0, lines.count - AgentScreen.promptLines)
        guard form(in: lines) != nil, let hint = (start..<lines.count).last(where: { isFormHint(lines[$0]) }),
              lines[hint].contains(formTabs) else { return nil }
        guard cell(lines[hint]).contains(formSelect) else { return reviewRefusal }
        let boxed = lines[start..<hint].contains { (line: String) -> Bool in
            let text = cell(line)
            return optionNumber(text) != nil && isCheckbox(optionLabel(text))
        }
        return boxed ? severalAnswers : severalQuestions
    }
}
