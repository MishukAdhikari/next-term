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

/// A tab's scrollback, saved at an update quit and shown again above the relaunched shell's first prompt (R4, KTD9). Only
/// an update quit saves it, and only the launch that claims that update's marker reads it back.
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
///   then each two adjacent rows joined, so a secret split by one wrap is still found;
/// - the line of a command that held a secret (`holdsSecret`) is blanked, not masked;
/// - an agent's pane keeps only what came before the agent's command;
/// - only the latest `Limits` are kept.
/// `CommandSecrets.mayKeep` is never used on it: it refuses any text with a newline. Each newline is written as CR LF.
public enum ScrollbackText {
    /// A row of a terminal's buffer.
    public struct Row: Equatable, Sendable {
        /// What it holds. A cell nothing was written to (one a tab moved past) reads as U+0000, a blank.
        public var text: String
        /// The terminal wrapped a line onto it: it goes on from the row before. Nil when the buffer did not say, as for
        /// the normal buffer of a pane in the alternate screen (`rows(bufferData:)`).
        public var wrapped: Bool?

        public init(_ text: String, wrapped: Bool? = false) {
            self.text = text
            self.wrapped = wrapped
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

        public init(row: Int, shown: [String]) {
            self.row = row
            lines = shown.map { (line: String) -> Int in ScrollbackText.fingerprint(ScrollbackText.normalized(line)) }
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

    /// The text saved for `rows`, the first of them at scroll-invariant row `firstRow` (nil: rows with no number to go
    /// by, and echoes are found by what they showed): the lines of `dropped` blanked, as much as `extent` keeps, at most
    /// `limits`, masked, each newline as CR LF. Empty when nothing is kept.
    public static func saved(_ rows: [Row], firstRow: Int? = 0, dropped: [Echo] = [], extent: Extent = .all,
                             limits: Limits = .standard) -> String {
        saved(rows, firstRow: firstRow, dropped: dropped, extent: extent, limits: limits, masking: CommandSecrets.mask)
    }

    /// `saved`, with `mask` in place of `CommandSecrets.mask`.
    static func saved(_ rows: [Row], firstRow: Int? = 0, dropped: [Echo], extent: Extent, limits: Limits,
                      masking mask: (String) -> String) -> String {
        let flagged = !rows.contains { (row: Row) -> Bool in row.wrapped == nil }
        var lines = logicalLines(rows, firstRow: firstRow ?? 0)
        let index = dropped.isEmpty && extent == .all ? nil : LineIndex(lines, numbered: firstRow != nil)
        if case .before(let echo) = extent {
            guard let echo, let start = index?.start(of: echo) else { return "" }
            lines.removeSubrange(start...)
        }
        var blank = Set<Int>()
        for echo in dropped {
            for start in index?.places(of: echo) ?? [] where start < lines.count {
                blank.formUnion(start..<min(start + echo.lines.count, lines.count))
            }
        }
        let prompts = continuationPrompts(lines, blank: blank)
        let range = kept(lines, blank: blank, prompts: prompts, flagged: flagged, limits: limits)
        var out = masked(lines, range, blank: blank, prompts: prompts, mask: mask)
        if !flagged { maskPairs(&out, mask: mask) }
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
    }

    static func logicalLines(_ rows: [Row], firstRow: Int) -> [Line] {
        var raw: [Line] = []
        raw.reserveCapacity(rows.count)
        for (offset, row) in rows.enumerated() {
            if row.wrapped == true, !raw.isEmpty {
                raw[raw.count - 1].text += row.text
            } else {
                raw.append(Line(text: row.text, row: firstRow + offset, cutAtTop: offset == 0 && row.wrapped == true))
            }
        }
        for index in raw.indices { raw[index].text = normalized(raw[index].text) }
        return raw
    }

    /// `text` as saved: sanitized, an empty cell (U+0000) as a blank, trimmed at the right.
    static func normalized(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\u{0}" || scalar == "\n" {
                kept.append(" ")
            } else if TerminalText.isKept(scalar) {
                kept.append(scalar)
            }
        }
        while let last = kept.last, last == " " || last == "\t" { kept.removeLast() }
        return String(kept)
    }

    static func fingerprint(_ text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        return hasher.finalize()
    }

    /// Where echoes are among the lines: at their row, or by what they showed.
    struct LineIndex {
        let prints: [Int]
        let byRow: [Int: Int]
        let byPrint: [Int: [Int]]

        init(_ lines: [Line], numbered: Bool) {
            prints = lines.map { (line: Line) -> Int in ScrollbackText.fingerprint(line.text) }
            var byRow: [Int: Int] = [:]
            var byPrint: [Int: [Int]] = [:]
            for (index, line) in lines.enumerated() {
                if numbered { byRow[line.row] = index }
                byPrint[prints[index], default: []].append(index)
            }
            self.byRow = byRow
            self.byPrint = byPrint
        }

        func matches(_ echo: Echo, at start: Int) -> Bool {
            guard !echo.lines.isEmpty, start + echo.lines.count <= prints.count else { return false }
            return echo.lines.indices.allSatisfy { (offset: Int) -> Bool in prints[start + offset] == echo.lines[offset] }
        }

        /// Every place it shows.
        func places(of echo: Echo) -> [Int] {
            guard let first = echo.lines.first else { return [] }
            return (byPrint[first] ?? []).filter { (start: Int) -> Bool in matches(echo, at: start) }
        }

        /// Where its command started: at its row when it shows there, else the last place it shows.
        func start(of echo: Echo) -> Int? {
            if let start = byRow[echo.row], matches(echo, at: start) { return start }
            return places(of: echo).last
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

    /// Whether a line goes on to a continuation row: it ends in a backslash, a pipe or `&&` (`||` ends in a pipe).
    static func goesOn(_ line: String) -> Bool {
        line.hasSuffix("\\") || line.hasSuffix("|") || line.hasSuffix("&&")
    }

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

    /// The lines kept: the latest, within `limits`, without blank ones at the end. A line cut from what went before it
    /// goes too: a PS2 row whose start was left out, a line whose start scrolled off the buffer, and without wrap flags
    /// the first row kept, which may be the end of a wrapped line.
    static func kept(_ lines: [Line], blank: Set<Int>, prompts: [Int: String], flagged: Bool, limits: Limits) -> Range<Int> {
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
        if start > 0 {
            if !flagged { start = min(start + 1, end) }
        } else if start < end, lines[start].cutAtTop {
            start += 1
        }
        while start < end, prompts[start] != nil { start += 1 }
        return start..<end
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

    /// Rows without wrap flags: each two adjacent rows masked joined, as one line, and what that masks more taken into
    /// both rows, where it lies.
    static func maskPairs(_ out: inout [String], mask: (String) -> String) {
        let pairs = out.indices.dropLast().filter { (index: Int) -> Bool in !out[index].isEmpty && !out[index + 1].isEmpty }
        guard !pairs.isEmpty else { return }
        let scalars = out.map { (row: String) -> [Unicode.Scalar] in Array(row.unicodeScalars) }
        let joined = pairs.map { (index: Int) -> String in
            String(String.UnicodeScalarView(scalars[index] + scalars[index + 1]))
        }
        var masks = mask(joined.joined(separator: "\n")).components(separatedBy: "\n")
        if masks.count != joined.count { masks = joined.map(mask) }
        var spans: [Int: [Range<Int>]] = [:]
        for (number, index) in pairs.enumerated() where masks[number] != joined[number] {
            let first = scalars[index].count
            guard let span = changed(Array(joined[number].unicodeScalars), Array(masks[number].unicodeScalars)) else { continue }
            if span.lowerBound < first { spans[index, default: []].append(span.lowerBound..<min(span.upperBound, first)) }
            if span.upperBound > first {
                spans[index + 1, default: []].append(max(span.lowerBound, first) - first..<span.upperBound - first)
            }
        }
        for (index, list) in spans { out[index] = masking(scalars[index], list) }
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
        for span in spans.sorted(by: { (a: Range<Int>, b: Range<Int>) -> Bool in a.lowerBound < b.lowerBound }) {
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

    // MARK: the alternate screen

    /// The rows of a terminal's normal buffer as text (`getBufferAsData`), as it is read while the alternate screen is
    /// on: one a line, with no wrap flags. The other half of a wide character reads as U+0000 there: it goes.
    public static func rows(bufferData data: Data) -> [Row] {
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.map { (line: String) -> Row in Row(withoutWideHalves(line), wrapped: nil) }
    }

    static func withoutWideHalves(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        var afterWide = false
        for scalar in text.unicodeScalars {
            if scalar == "\u{0}", afterWide {
                afterWide = false
                continue
            }
            kept.append(scalar)
            afterWide = isWide(scalar)
        }
        return String(kept)
    }

    /// Takes two cells: the East Asian wide and fullwidth blocks, and the emoji ones. Close enough to know the empty cell
    /// after it for its other half.
    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF: return true
        case 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6: return true
        case 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD: return true
        default: return false
        }
    }

    // MARK: files

    public static let filePrefix = "scrollback-"

    /// The file a pane's scrollback is saved in at the update quit that writes `marker`: two UUIDs, so it can name
    /// nothing outside the sessions folder, whatever the snapshot says.
    public static func fileName(marker: UUID, pane: UUID) -> String {
        filePrefix + marker.uuidString.lowercased() + "-" + pane.uuidString.lowercased()
    }

    /// The marker and pane a scrollback file is named for; nil for any other name.
    public static func parseFileName(_ name: String) -> (marker: UUID, pane: UUID)? {
        guard name.hasPrefix(filePrefix) else { return nil }
        let ids = name.dropFirst(filePrefix.count)
        guard ids.utf8.count == 73, let marker = UUID(uuidString: String(ids.prefix(36))),
              let pane = UUID(uuidString: String(ids.suffix(36))), fileName(marker: marker, pane: pane) == name else { return nil }
        return (marker, pane)
    }

    /// Of the names in a sessions folder, the scrollback files to read, by pane, and every scrollback file, each removed
    /// once read or unread: only those named for the claimed `marker` are read (none without one), and only for a pane
    /// the snapshot names.
    public static func sort(_ names: [String], marker: UUID?, panes: Set<UUID>) -> (read: [UUID: String], remove: [String]) {
        var read: [UUID: String] = [:]
        var remove: [String] = []
        for name in names where name.hasPrefix(filePrefix) {
            remove.append(name)
            guard let marker, let ids = parseFileName(name), ids.marker == marker, panes.contains(ids.pane) else { continue }
            read[ids.pane] = name
        }
        return (read, remove)
    }

    // MARK: showing it again

    /// The line under the restored scrollback. Agent questions are read only below it (`below`).
    public static let divider = "── Restored from before the update ──"

    /// What a restored tab shows before its shell starts: the saved scrollback, sanitized again (its file is read as
    /// untrusted) with each newline as CR LF, then the divider, dim.
    public static func preface(_ scrollback: String) -> String {
        let text = TerminalText.feedable(scrollback)
        let lines = text.isEmpty || text.hasSuffix("\r\n") ? text : text + "\r\n"
        return lines + "\u{1B}[2m" + TerminalText.oneLine(divider) + "\u{1B}[0m\r\n"
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
}
