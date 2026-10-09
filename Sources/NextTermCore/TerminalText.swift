import Foundation

/// Text a restore feeds into a terminal that no program in it printed: a restored tab's note, the divider above it,
/// replayed scrollback (KTD9). Any of it can hold what a file, a folder name or a server put there, so only printable
/// text, newlines and tabs get through. Every C0 control (ESC, BEL and CR among them), DEL and C1 control goes, and with
/// them the start of every sequence a terminal answers or acts on: a status or attributes query, a clipboard write, a
/// title report, the end of a bracketed paste, Next Term's own integration channel.
///
/// What is left of a sequence (`[6n`) is plain text. The terminal's convertEol stays off, so the live terminal is
/// unchanged: `feedable` writes each newline as CR LF instead.
///
/// It keeps text from starting a sequence, not from joining one already open: fed while the terminal is inside one
/// (the shell's own output split across reads), it becomes part of it. Feed it only between sequences, as before the
/// restored shell has printed anything.
public enum TerminalText {
    /// `text` with only printable characters, newlines and tabs. A C1 control is one scalar however it came (UTF-8
    /// carries U+009B as C2 9B), so it goes too.
    public static func sanitize(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where isKept(scalar) { kept.append(scalar) }
        return String(kept)
    }

    /// Bytes read as UTF-8, sanitized. A byte that is not UTF-8, such as a lone 8-bit CSI (0x9B), reads as U+FFFD,
    /// which a terminal only shows.
    public static func sanitize<Bytes: Collection>(utf8 bytes: Bytes) -> String where Bytes.Element == UInt8 {
        sanitize(String(decoding: bytes, as: UTF8.self))
    }

    /// Sanitized, on one line: each newline, tab, and line or paragraph separator a space. What a note or a list line
    /// is. A character a put-back line may not hold (KTD7), one that shows nothing or turns the text around it (bidi,
    /// zero-width, format), shows as U+FFFD, so a folder or host name cannot make a note read as something else.
    public static func oneLine(_ text: String) -> String {
        var line = String.UnicodeScalarView()
        for scalar in sanitize(text).unicodeScalars {
            if scalar == "\t" || SessionSnapshot.Command.isLineBreak(scalar) {
                line.append(" ")
            } else if SessionSnapshot.Command.isUnsafe(scalar) {
                line.append("\u{FFFD}")
            } else {
                line.append(scalar)
            }
        }
        return String(line)
    }

    /// Sanitized and ready to feed: each newline written as CR LF.
    public static func feedable(_ text: String) -> String {
        var fed = String.UnicodeScalarView()
        for scalar in sanitize(text).unicodeScalars {
            if scalar == "\n" { fed.append("\r") }
            fed.append(scalar)
        }
        return String(fed)
    }

    /// Printable, a newline or a tab.
    static func isKept(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A: return true
        case 0x00...0x1F, 0x7F...0x9F: return false
        default: return true
        }
    }
}

// MARK: - Scrollback

/// A tab's scrollback, saved at an update quit or a quit under "Resume where I left off", and shown again above the
/// relaunched shell's first prompt (R4, KTD9). Only the launch that restores that quit reads it back.
///
/// What is saved is plain text, sanitized, then masked through `CommandSecrets.mask`, best effort:
/// - the rows of a line the terminal wrapped are masked as one line, so a token printed across a wrap is found;
/// - a command's PS2 continuation rows are joined to the line before them, as a continuation row alone names no tool. A
///   row is one when it starts with zsh's PS2, which names what it continues (`dquote> `), or with a bare `> ` after a
///   line that goes on (`goesOn`): known by their text, they are found in a shell without the integration, on a server,
///   and after a resize rewraps the buffer. After a line that ends in a backslash (`app --password \`) the join adds a
///   newline alone: a second backslash would make `\\` the value and leave the secret on the next row. After any other
///   line (`echo pw |`) it adds a backslash and a newline, which `mask` reads as a blank. The PS2 prompt stays out of what
///   is masked and in what is saved. A quoted value that a PS2 row closes (`--password "` then `> s3cret"`) is still
///   missed;
/// - rows without wrap flags (the normal buffer of a pane in the alternate screen, read as text) are masked each alone,
///   then as the lines they probably were, two at a time (`maskAcrossRows`);
/// - the line of a command that held a secret (`holdsSecret`) is blanked, not masked: found at its row, or by what it
///   showed, over as many rows as it takes where they have no wrap flags;
/// - an agent's pane keeps only what came before the agent's command;
/// - only the latest `Limits` are kept, and a part whose start was cut off goes (`kept`).
/// `CommandSecrets.mayKeep` is never used on it: it refuses any text with a newline. Each newline is written as CR LF.
public enum ScrollbackText {
    /// A row of a terminal's buffer.
    public struct Row: Equatable, Sendable {
        /// What it holds. A cell nothing was written to (one a tab moved past) reads as U+0000, a blank.
        public var text: String
        /// The terminal wrapped a line onto it: it goes on from the row before. Nil when the buffer did not say, as for
        /// the normal buffer of a pane in the alternate screen (`rows(bufferData:columns:)`).
        public var wrapped: Bool?
        /// Without wrap flags: what it holds reaches the right edge, as on every row a line wrapped from. Nil when not
        /// known, and then it may go on to the next row with a blank between them or without.
        public var full: Bool?

        public init(_ text: String, wrapped: Bool? = false, full: Bool? = nil) {
            self.text = text
            self.wrapped = wrapped
            self.full = full
        }
    }

    /// Where a command's line showed when the shell integration reported its start, to find it again at the quit: the
    /// line of a command that held a secret is blanked, and an agent's pane keeps what came before its command. Rows move
    /// when a resize rewraps the buffer, so a line no longer at its row is found by what it showed.
    public struct Echo: Equatable, Sendable {
        /// The row its first line started on, counted from the top of the scrollback (scroll-invariant).
        public var row: Int
        /// Each of its lines as it showed (prompt included, wrapped rows joined) as a fingerprint for this run of the
        /// app: a line that held a secret is never kept as text.
        public var lines: [Int]
        /// Each of its lines without its blanks, as a fingerprint, and how many characters are left so. Rows read
        /// without wrap flags do not say where a line wrapped, nor whether a blank at a row's end was trimmed: there it is
        /// found by these, over as many rows as it takes.
        public var bare: [Int]
        public var bareCounts: [Int]

        public init(row: Int, shown: [String]) {
            self.row = row
            let normalized = shown.map { (line: String) -> String in ScrollbackText.normalized(line) }
            lines = normalized.map { (line: String) -> Int in ScrollbackText.fingerprint(line) }
            let bare = normalized.map { (line: String) -> [Unicode.Scalar] in ScrollbackText.bare(line) }
            self.bare = bare.map { (scalars: [Unicode.Scalar]) -> Int in ScrollbackText.fingerprint(bare: [scalars]) }
            bareCounts = bare.map { (scalars: [Unicode.Scalar]) -> Int in scalars.count }
        }
    }

    /// How much of a pane's scrollback is kept.
    public enum Extent: Equatable, Sendable {
        case all
        /// An agent's pane: only what came before its command showed, at the echo's row or else where it last shows.
        /// Nothing when the command is not known (nil) or not found.
        case before(Echo?)
    }

    /// The most of a pane's scrollback that is kept: the latest lines.
    public struct Limits: Equatable, Sendable {
        public var lines: Int
        /// Of the saved text, each line counted with a CR LF.
        public var bytes: Int

        public init(lines: Int, bytes: Int) {
            self.lines = lines
            self.bytes = bytes
        }

        public static let standard = Limits(lines: 5_000, bytes: 512 * 1024)
    }

    /// The quit a scrollback was saved at, which the divider under it names.
    public enum SavedAt: Equatable, Sendable {
        /// An update's: its files are named for the update's marker.
        case update
        /// One under "Resume where I left off": its files are named for the launch id of the snapshot it saved.
        case quit

        /// The line under the restored scrollback. Agent questions are read only below it (`below`).
        public var divider: String {
            switch self {
            case .update: return "── Restored from before the update ──"
            case .quit: return "── Restored from before Next Term quit ──"
            }
        }
    }

    /// Whether a command's line is left out of the scrollback, its echo blanked: as typed (its continuation lines joined as
    /// PS2 rows are) or with its aliases expanded, it holds a secret that `CommandSecrets.mask` finds, or it starts with a
    /// blank, which keeps a line out of the shell's history.
    public static func holdsSecret(typed: String, expanded: String? = nil) -> Bool {
        if typed.hasPrefix(" ") || typed.hasPrefix("\t") { return true }
        for line in [typed, expanded ?? ""] where !line.isEmpty {
            let joined = continued(line.components(separatedBy: "\n"))
            if CommandSecrets.mask(joined) != joined { return true }
        }
        return false
    }

    /// Lines joined as continuation rows are: after a line that ends in a backslash a newline alone, after any other a
    /// backslash and a newline, which `CommandSecrets.mask` reads as a blank between words.
    static func continued(_ lines: [String]) -> String {
        var text = ""
        for (index, line) in lines.enumerated() {
            if index > 0 { text += text.hasSuffix("\\") ? "\n" : "\\\n" }
            text += line
        }
        return text
    }

    /// The text saved for `rows`, the first of them at scroll-invariant row `firstRow`: 0 is the top of the terminal's
    /// history, with nothing before it; nil, rows with no number to go by, and echoes are found by what they showed. The
    /// lines of `dropped` blanked, as much as `extent` keeps, at most `limits`, masked, each newline as CR LF. Empty when
    /// nothing is kept.
    public static func saved(_ rows: [Row], firstRow: Int? = 0, dropped: [Echo] = [], extent: Extent = .all,
                             limits: Limits = .standard) -> String {
        saved(rows, firstRow: firstRow, dropped: dropped, extent: extent, limits: limits, masking: CommandSecrets.mask)
    }

    /// `saved`, with `mask` in place of `CommandSecrets.mask`.
    static func saved(_ rows: [Row], firstRow: Int? = 0, dropped: [Echo], extent: Extent, limits: Limits,
                      masking mask: (String) -> String) -> String {
        let flagged = !rows.contains { (row: Row) -> Bool in row.wrapped == nil }
        var lines = logicalLines(rows, firstRow: firstRow ?? 0)
        let index = dropped.isEmpty && extent == .all ? nil : LineIndex(lines, numbered: firstRow != nil, flagged: flagged)
        if case .before(let echo) = extent {
            guard let echo, let start = index?.start(of: echo) else { return "" }
            lines.removeSubrange(start...)
        }
        var blank = Set<Int>()
        for echo in dropped {
            for place in index?.places(of: echo) ?? [] {
                blank.formUnion(place.clamped(to: 0..<lines.count))
            }
        }
        let prompts = continuationPrompts(lines, blank: blank)
        let range = kept(lines, blank: blank, prompts: prompts, flagged: flagged, atTop: firstRow == 0, limits: limits)
        var out = masked(lines, range, blank: blank, prompts: prompts, mask: mask)
        if !flagged { maskAcrossRows(&out, lines, range, blank: blank, mask: mask) }
        return capped(out, bytes: limits.bytes).joined(separator: "\r\n")
    }

    // MARK: lines

    /// A line as the terminal held it: its rows joined where the terminal wrapped them.
    struct Line {
        /// As saved (`normalized`).
        var text: String
        /// The row it starts on.
        var row: Int
        /// It goes on from a row no longer in the buffer: its start scrolled off.
        var cutAtTop: Bool
        /// Its last row filled the width (`Row.full`).
        var full: Bool?
        /// Blanks at its end were trimmed.
        var trimmed: Bool = false
    }

    static func logicalLines(_ rows: [Row], firstRow: Int) -> [Line] {
        var raw: [Line] = []
        raw.reserveCapacity(rows.count)
        for (offset, row) in rows.enumerated() {
            if row.wrapped == true, !raw.isEmpty {
                raw[raw.count - 1].text += row.text
                raw[raw.count - 1].full = row.full
            } else {
                let cut = offset == 0 && row.wrapped == true
                raw.append(Line(text: row.text, row: firstRow + offset, cutAtTop: cut, full: row.full))
            }
        }
        for index in raw.indices {
            let normal = normalizing(raw[index].text)
            raw[index].text = normal.text
            raw[index].trimmed = normal.trimmed
        }
        return raw
    }

    /// `text` as saved: sanitized, an empty cell (U+0000) as a blank, trimmed at the right.
    static func normalized(_ text: String) -> String {
        normalizing(text).text
    }

    /// `normalized`, and whether blanks were trimmed from its end.
    static func normalizing(_ text: String) -> (text: String, trimmed: Bool) {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\u{0}" || scalar == "\n" {
                kept.append(" ")
            } else if TerminalText.isKept(scalar) {
                kept.append(scalar)
            }
        }
        var trimmed = false
        while let last = kept.last, last == " " || last == "\t" {
            kept.removeLast()
            trimmed = true
        }
        return (String(kept), trimmed)
    }

    static func fingerprint(_ text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        return hasher.finalize()
    }

    /// Where echoes are among the lines: at their row, or by what they showed. Without wrap flags each line is a row,
    /// and an echo is found by its text without blanks (`BareRows`).
    struct LineIndex {
        let prints: [Int]
        let byRow: [Int: Int]
        let byPrint: [Int: [Int]]
        let bare: BareRows?

        init(_ lines: [Line], numbered: Bool, flagged: Bool) {
            guard flagged else {
                prints = []
                byRow = [:]
                byPrint = [:]
                bare = BareRows(lines)
                return
            }
            prints = lines.map { (line: Line) -> Int in ScrollbackText.fingerprint(line.text) }
            var byRow: [Int: Int] = [:]
            var byPrint: [Int: [Int]] = [:]
            for (index, line) in lines.enumerated() {
                if numbered { byRow[line.row] = index }
                byPrint[prints[index], default: []].append(index)
            }
            self.byRow = byRow
            self.byPrint = byPrint
            bare = nil
        }

        func matches(_ echo: Echo, at start: Int) -> Bool {
            guard !echo.lines.isEmpty, start + echo.lines.count <= prints.count else { return false }
            return echo.lines.indices.allSatisfy { (offset: Int) -> Bool in prints[start + offset] == echo.lines[offset] }
        }

        /// Every place it shows, as the lines it takes.
        func places(of echo: Echo) -> [Range<Int>] {
            if let bare { return bare.places(of: echo) }
            guard let first = echo.lines.first else { return [] }
            let starts = (byPrint[first] ?? []).filter { (start: Int) -> Bool in matches(echo, at: start) }
            return starts.map { (start: Int) -> Range<Int> in start..<start + echo.lines.count }
        }

        /// Where its command started: at its row when it shows there, else the last place it shows.
        func start(of echo: Echo) -> Int? {
            if bare == nil, let start = byRow[echo.row], matches(echo, at: start) { return start }
            return places(of: echo).last?.lowerBound
        }
    }

    // MARK: PS2 rows

    /// What zsh's PS2 (`%_> `) names: what a continuation row continues, several at once in `cmdand dquote> `.
    static let zshContinues: Set<String> = [
        "for", "while", "repeat", "select", "until", "if", "then", "else", "elif", "elif-then", "math", "cond", "cmdor",
        "cmdand", "pipe", "errpipe", "foreach", "case", "function", "subsh", "cursh", "array", "quote", "dquote", "bquote",
        "cmdsubst", "mathsubst", "heredoc", "heredocd", "brace", "braceparam", "always",
    ]

    /// The PS2 prompt `text` starts with, and whether it names what it continues: zsh's (`dquote> `), or a bare `> `
    /// (bash's, and zsh's after a backslash).
    static func ps2Prompt(_ text: String) -> (text: String, named: Bool)? {
        let start = text.prefix(80)
        guard let marker = start.range(of: "> ") else { return nil }
        let prompt = String(start[..<marker.upperBound])
        let names = start[..<marker.lowerBound]
        if names.isEmpty { return (prompt, false) }
        let named = names.split(separator: " ", omittingEmptySubsequences: false).allSatisfy { (name: Substring) -> Bool in
            zshContinues.contains(String(name))
        }
        return named ? (prompt, true) : nil
    }

    /// Whether a line goes on to a continuation row: it ends in a backslash, a pipe or `&&` (`||` ends in a pipe), or in
    /// a here-document's word (`<<EOF`), whose lines follow.
    static func goesOn(_ line: String) -> Bool {
        if line.hasSuffix("\\") || line.hasSuffix("|") || line.hasSuffix("&&") { return true }
        guard line.contains("<<") else { return false }
        return line.range(of: hereDocumentAtEnd, options: .regularExpression) != nil
    }

    /// A here-document's operator and word, ending a line.
    static let hereDocumentAtEnd = #"(?<!<)<<-?[ \t]*['"\\]?[A-Za-z0-9_.\-]+['"]?$"#

    /// The PS2 prompt of each line that continues the one before it: a row with zsh's PS2, which names what it continues,
    /// or a bare `> ` after a line that goes on (`goesOn`); a line quoted with `> ` in other output continues nothing. A
    /// blanked line neither continues nor is continued.
    static func continuationPrompts(_ lines: [Line], blank: Set<Int>) -> [Int: String] {
        var prompts: [Int: String] = [:]
        var before: String?
        for (index, line) in lines.enumerated() {
            if blank.contains(index) {
                before = nil
                continue
            }
            var content = line.text
            if let before, !before.isEmpty, let prompt = ps2Prompt(line.text), prompt.named || goesOn(before) {
                prompts[index] = prompt.text
                content = String(line.text.dropFirst(prompt.text.count))
            }
            before = content
        }
        return prompts
    }

    // MARK: keeping and masking

    /// The lines kept: the latest, within `limits`, without blank ones at the end. What was cut from what went before it,
    /// by the cap or off the top of the buffer (unless the lines start at the top of the terminal's history, `atTop`),
    /// goes too, as alone it could not be masked:
    /// - a line whose start scrolled off the buffer, and a first line that reads as a PS2 row;
    /// - without wrap flags, the first row kept, which may be the end of a wrapped line, unless the row before it did not
    ///   fill the width, and the rows after it while each before them did;
    /// - the body of a private key whose start is not kept;
    /// - a PS2 row whose start is not kept.
    static func kept(_ lines: [Line], blank: Set<Int>, prompts: [Int: String], flagged: Bool, atTop: Bool,
                     limits: Limits) -> Range<Int> {
        var end = lines.count
        while end > 0, blank.contains(end - 1) || lines[end - 1].text.isEmpty { end -= 1 }
        var start = end
        var bytes = 0
        while start > 0, end - start < limits.lines {
            let size = (blank.contains(start - 1) ? 0 : lines[start - 1].text.utf8.count) + 2
            guard bytes + size <= limits.bytes else { break }
            bytes += size
            start -= 1
        }
        let cut = start > 0 || !atTop
        if !flagged, cut {
            if start == 0 || lines[start - 1].full != false { start = min(start + 1, end) }
            while start < end, lines[start - 1].full == true { start += 1 }
        } else if start == 0, start < end, lines[0].cutAtTop || (!atTop && ps2Prompt(lines[0].text) != nil) {
            start += 1
        }
        if cut, let after = afterKeyEnd(lines, start..<end) { start = after }
        while start < end, prompts[start] != nil { start += 1 }
        return start..<end
    }

    /// The line after the end of a private key whose start is not among `lines[range]`, if one ends before any starts: its
    /// body, masked a line at a time, could read as paths.
    static func afterKeyEnd(_ lines: [Line], _ range: Range<Int>) -> Int? {
        for index in range where lines[index].text.contains("PRIVATE KEY") {
            if lines[index].text.contains("-----END ") { return index + 1 }
            if lines[index].text.contains("-----BEGIN ") { return nil }
        }
        return nil
    }

    /// `lines[range]` masked, in one pass when no newline is lost (the usual case), else a line and its continuation rows
    /// at a time. A continuation row is joined to the line before it without its PS2 prompt, which it keeps. A line that
    /// still loses a newline (`echo "pw` then `dquote> " | sudo -S ls`: what is echoed spans the join) is masked whole,
    /// with its continuation rows.
    static func masked(_ lines: [Line], _ range: Range<Int>, blank: Set<Int>, prompts: [Int: String],
                       mask: (String) -> String) -> [String] {
        var groups: [Range<Int>] = []
        for index in range {
            if prompts[index] != nil, let last = groups.last {
                groups[groups.count - 1] = last.lowerBound..<index + 1
            } else {
                groups.append(index..<index + 1)
            }
        }
        // What each line is masked as, and the lines a backslash was added after.
        var contents: [Int: String] = [:]
        var added = Set<Int>()
        let texts = groups.map { (group: Range<Int>) -> String in
            var text = ""
            for index in group {
                let line = lines[index]
                let content = blank.contains(index) ? "" : prompts[index].map { (prompt: String) -> String in
                    String(line.text.dropFirst(prompt.count))
                } ?? line.text
                if index > group.lowerBound {
                    let goesOnItself = text.hasSuffix("\\")
                    if !goesOnItself { added.insert(index - 1) }
                    text += goesOnItself ? "\n" : "\\\n"
                }
                contents[index] = content
                text += content
            }
            return text
        }
        let whole = mask(texts.joined(separator: "\n")).components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(range.count)
        var next = 0
        for (number, group) in groups.enumerated() {
            let parts: [String]
            if whole.count == range.count {
                parts = Array(whole[next..<next + group.count])
            } else {
                parts = mask(texts[number]).components(separatedBy: "\n")
            }
            next += group.count
            for (offset, index) in group.enumerated() {
                out.append(line(index, parts.count == group.count ? parts[offset] : nil, blank: blank, prompts: prompts,
                                added: added))
            }
        }
        return out
    }

    /// Line `index` as saved from its masked `part`; nil when its group lost a newline, and is masked whole.
    private static func line(_ index: Int, _ part: String?, blank: Set<Int>, prompts: [Int: String], added: Set<Int>) -> String {
        if blank.contains(index) { return "" }
        guard var part else { return (prompts[index] ?? "") + MCPRedaction.mask }
        if added.contains(index), part.hasSuffix("\\") { part.removeLast() }
        return (prompts[index] ?? "") + part
    }

    /// The part of `text` that masking changed: from the first difference to the last.
    static func changed(_ text: [Unicode.Scalar], _ masked: [Unicode.Scalar]) -> Range<Int>? {
        var prefix = 0
        while prefix < text.count, prefix < masked.count, text[prefix] == masked[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < text.count - prefix, suffix < masked.count - prefix,
              text[text.count - 1 - suffix] == masked[masked.count - 1 - suffix] {
            suffix += 1
        }
        let span = prefix..<text.count - suffix
        return span.isEmpty ? nil : span
    }

    /// `row` with each of `spans` masked, those that touch as one.
    static func masking(_ row: [Unicode.Scalar], _ spans: [Range<Int>]) -> String {
        var merged: [Range<Int>] = []
        let sorted = spans.sorted { (a: Range<Int>, b: Range<Int>) -> Bool in a.lowerBound < b.lowerBound }
        for span in sorted where !span.isEmpty {
            if let last = merged.last, span.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        var result = String.UnicodeScalarView()
        var at = 0
        for span in merged {
            result.append(contentsOf: row[at..<span.lowerBound])
            result.append(contentsOf: MCPRedaction.mask.unicodeScalars)
            at = span.upperBound
        }
        result.append(contentsOf: row[at...])
        return String(result)
    }

    /// The latest of `lines` that fit in `bytes`, each counted with its CR LF: masking can make a line longer.
    static func capped(_ lines: [String], bytes: Int) -> ArraySlice<String> {
        var total = 0
        var start = lines.count
        while start > 0 {
            let size = lines[start - 1].utf8.count + 2
            guard total + size <= bytes else { break }
            total += size
            start -= 1
        }
        return lines[start...]
    }

    // MARK: showing it again

    /// What a restored tab shows before its shell starts: the saved scrollback, sanitized again (its file is read as
    /// untrusted) with each newline as CR LF, then the divider for the quit it was saved at, dim.
    public static func preface(_ scrollback: String, savedAt: SavedAt) -> String {
        let text = TerminalText.feedable(scrollback)
        let lines = text.isEmpty || text.hasSuffix("\r\n") ? text : text + "\r\n"
        return lines + "\u{1B}[2m" + TerminalText.oneLine(savedAt.divider) + "\u{1B}[0m\r\n"
    }

    /// The rows of `tail`, the screen's last, below the last divider in it: a question replayed above it asks nothing.
    /// In a narrow pane the divider wraps over rows, and the row before the wrap loses its trailing blank, so blanks are
    /// not compared.
    public static func below(divider: String, in tail: [String]) -> [String] {
        let target = divider.filter { (character: Character) -> Bool in character != " " }
        guard !target.isEmpty else { return tail }
        for start in tail.indices.reversed() {
            var shown = tail[start].filter { (character: Character) -> Bool in character != " " }
            guard !shown.isEmpty, target.hasPrefix(shown) else { continue }
            var end = start + 1
            while shown != target, end < tail.count {
                let next = tail[end].filter { (character: Character) -> Bool in character != " " }
                guard !next.isEmpty, target.hasPrefix(shown + next) else { break }
                shown += next
                end += 1
            }
            if shown == target { return Array(tail[end...]) }
        }
        return tail
    }

    /// The rows of `tail`, rows `first...` of the screen, below the divider whose last row is `row`: only the divider
    /// there counts, so a program that prints the same text below it hides nothing. A row above the tail leaves all of it
    /// below. Where the row no longer holds the divider (the screen was cleared since), or is not known (`nil`: the width
    /// changed since, and rows were wrapped again), it is found by its text (`below(divider:in:)`).
    public static func below(divider: String, row: Int?, in tail: [String], first: Int) -> [String] {
        guard let row else { return below(divider: divider, in: tail) }
        if row < first { return tail }
        let last = row - first
        guard last < tail.count, ends(divider, at: last, in: tail) else { return below(divider: divider, in: tail) }
        return Array(tail[(last + 1)...])
    }

    /// Whether the rows of `tail` up to `last` end with `divider`, blanks not compared. Its first rows may be above the
    /// tail.
    static func ends(_ divider: String, at last: Int, in tail: [String]) -> Bool {
        let target = divider.filter { (character: Character) -> Bool in character != " " }
        var shown = ""
        for index in stride(from: last, through: 0, by: -1) {
            let part = tail[index].filter { (character: Character) -> Bool in character != " " }
            guard !part.isEmpty, target.hasSuffix(part + shown) else { return false }
            shown = part + shown
            if shown == target { return true }
        }
        return !shown.isEmpty
    }
}
